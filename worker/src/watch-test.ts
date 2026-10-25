import {APIError,requireRole,type Device,type Env,type Alert} from './types';
import {pairFor} from './devices';
import {sendPush,type PushResult} from './apns';
import {Latency} from './latency';
import {eventReference,recordDiagnostic,PushPreparationError} from './diagnostics';

type Session={parentId:string;listenerId:string;pairedAt:number;interval:number;episodeId:string};
const stopped={running:false,interval:5};

export async function watchTest(env:Env,device:Device,value?:Record<string,unknown>) {
 requireRole(device,'parent');
 if(value&&(typeof value.running!=='boolean'||(value.running&&
  (typeof value.interval!=='number'||!Number.isInteger(value.interval)||value.interval<1||value.interval>10))))
  throw new APIError(400,'Choose a whole number of seconds between 1 and 10.');
 const pair=await pairFor(env,device);
 // Stopping remains available even after unpairing or losing Watch registration.
 if(value?.running) {
  if(!pair)throw new APIError(409,'Pair a Listener first.');
  const watch=await env.DB.prepare('SELECT watch_push_token FROM devices WHERE id=?').bind(device.id).first<{watch_push_token:string|null}>();
  if(!watch?.watch_push_token)throw new APIError(409,'Open the Watch app and enable alerts first.');
 }
 const response=await env.WATCH_TEST.getByName(device.id).fetch('https://watch-test.internal/',{
  method:'POST',body:JSON.stringify({parentId:device.id,...(value?{running:value.running,interval:value.interval}:{}),
   ...(pair?{listenerId:pair.listener_id,pairedAt:pair.created_at}:{})})
 });
 if(!response.ok)throw new Error('Watch test controls unavailable.');
 return response.json();
}

// A separate alarm keeps tests independent of crying reminders and phone lifetime.
export class WatchTest implements DurableObject {
 constructor(private ctx:DurableObjectState,private env:Env) {}
 private async stop() {
  await this.ctx.storage.deleteAlarm();
  await this.ctx.storage.delete('session');
 }
 async fetch(request:Request):Promise<Response> {
  const value=await request.json() as Session&{running?:boolean};
  return this.ctx.blockConcurrencyWhile(async()=>{
   let session=await this.ctx.storage.get<Session>('session');
   if(value.running===false||(session&&(session.listenerId!==value.listenerId||session.pairedAt!==value.pairedAt))) {
    await this.stop();session=undefined;
   }
   if(value.running===true) {
    session={parentId:value.parentId,listenerId:value.listenerId,pairedAt:value.pairedAt,interval:value.interval,episodeId:session?.episodeId??crypto.randomUUID()};
    await this.ctx.storage.put('session',session);
    await this.ctx.storage.setAlarm(Date.now()+session.interval*1000);
   }
   return Response.json(session?{running:true,interval:session.interval}:stopped);
  });
 }
 async alarm():Promise<void> {
  const started=Date.now(),latency=new Latency();
  await this.ctx.blockConcurrencyWhile(async()=>{
   const session=await this.ctx.storage.get<Session>('session');
   if(!session)return;
   // Re-arm before network work; failures never create a backlog of test pushes.
   await this.ctx.storage.setAlarm(Date.now()+session.interval*1000);
   const pair=await this.env.DB.prepare(`SELECT d.watch_push_token FROM pairs p JOIN devices d ON d.id=p.parent_id
    WHERE p.parent_id=? AND p.listener_id=? AND p.created_at=?`)
    .bind(session.parentId,session.listenerId,session.pairedAt).first<{watch_push_token:string|null}>();
   if(!pair?.watch_push_token){await this.stop();return;}
   const now=new Date(Date.now());
   const alert:Alert={eventId:crypto.randomUUID(),episodeId:session.episodeId,listenerId:session.listenerId,
    type:'sustained_cry',cryStartedAt:now.toISOString(),durationSeconds:0,createdAt:now.toISOString(),isRepeat:true,isTest:true};
   let eventRef:string|undefined;try{eventRef=await eventReference(this.env,alert.eventId);}catch{/* Best effort. */}
   let result:PushResult;
   try{result=await sendPush(this.env,pair.watch_push_token,alert,'watch',latency);}
   catch(error){latency.failure(error);result={status:'retry',reason:error instanceof PushPreparationError?error.code:'apns_configuration'};}
   await recordDiagnostic(this.env,{requestId:crypto.randomUUID(),started,operation:'watch_test_dispatch',stage:'push',outcome:result.reason??result.status,eventRef,target:'watch',attempt:1,httpStatus:result.httpStatus,details:latency.details});
   if(result.status==='blocked'||result.status==='failed')await this.stop();
  });
 }
}
