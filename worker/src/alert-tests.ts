import {APIError,type Alert,type Device,type Env} from './types';
import {pairFor} from './devices';
import {uuid} from './security';
import {sendPush,sendSilentCryAlarmPush,type PushResult} from './apns';
import {PhoneHeadStart} from './notification-coordination';
import {Latency} from './latency';
import {eventReference,recordDiagnostic} from './diagnostics';

type Pair={parent_id:string;listener_id:string;created_at:number;recipient_id?:string};
export interface AlertTestConfiguration {
 alarmKit:boolean;phone:boolean;watch:boolean;repeatInterval:number;count:number;
 sharedCollapseIDs:boolean;distinctRequestIDs:boolean;coalesceRepeats:boolean;groupNotifications:boolean;
 phoneHeadStartMS:number;
}
interface Session {
 id:string;configuration:AlertTestConfiguration;pair:Pair;startsAt:string;nextAt:string|null;
 completedCount:number;dispatching?:boolean;state:'scheduled'|'running'|'completed'|'stopped'|'failed';message:string|null;
}
export function alertTestConfiguration(value:Record<string,unknown>):AlertTestConfiguration {
 const booleans=['alarmKit','phone','watch','sharedCollapseIDs','distinctRequestIDs','coalesceRepeats','groupNotifications'] as const;
 const keys=[...booleans,'repeatInterval','count','phoneHeadStartMS'];
 if(Object.keys(value).some(k=>!keys.includes(k as typeof keys[number]))||booleans.some(k=>typeof value[k]!=='boolean')
  ||(!value.alarmKit&&!value.phone&&!value.watch)
  ||!Number.isInteger(value.repeatInterval)||!([1,2,5,10,15,30].includes(value.repeatInterval as number))
  ||!Number.isInteger(value.count)||(value.count as number)<1||(value.count as number)>20
  ||![0,350,500].includes(value.phoneHeadStartMS as number)
  ||(value.phoneHeadStartMS!==0&&(!value.phone||!value.watch)))throw new APIError(400,'Invalid alert test options.');
 return Object.fromEntries(keys.map(key=>[key,value[key]])) as unknown as AlertTestConfiguration;
}
function room(env:Env,pair:Pair) {
 return env.ALERT_TESTS.get(env.ALERT_TESTS.idFromName(`${pair.parent_id}|${pair.listener_id}|${pair.created_at}${pair.recipient_id?`|${pair.recipient_id}`:''}`));
}
export async function configureAlertTest(env:Env,device:Device,operation:'status'|'start'|'stop',value:Record<string,unknown>={}) {
 const pair:Pair|null=await pairFor(env,device);
 if(!pair)throw new APIError(409,'Pair both iPhones before testing.');
 if(device.role==='parent'&&device.id!==pair.parent_id)pair.recipient_id=device.id;
 let input:Record<string,unknown>={pair};
 if(operation==='start'){
  const id=uuid(value.id);
  if(!value.configuration||typeof value.configuration!=='object'||Array.isArray(value.configuration))throw new APIError(400,'Test options required.');
  input={pair,id,configuration:alertTestConfiguration(value.configuration as Record<string,unknown>)};
 }else if(operation==='stop')input={pair,id:uuid(value.id)};
 const response=await room(env,pair).fetch(new Request(`https://alert-tests/${operation}`,{method:'POST',body:JSON.stringify(input)}));
 const result=await response.json() as {error?:string};
 if(!response.ok)throw new APIError(response.status,result.error??'Test service unavailable.');
 return result;
}

// One bounded session per pairing. Each tick is reserved durably before any
// Apple request. Neither a crashed alarm callback nor an ambiguous send replays it.
export class AlertTests {
 constructor(private ctx:DurableObjectState,private env:Env){}
 async fetch(request:Request):Promise<Response> {
  return this.ctx.blockConcurrencyWhile(async()=>{
   const input=await request.json() as {pair:Pair;id?:string;configuration?:AlertTestConfiguration};
   let session=await this.ctx.storage.get<Session>('session');
   const operation=new URL(request.url).pathname;
   if(operation==='/status')return Response.json({session:session??null});
   if(operation==='/stop'){
    if(session && session.id===input.id){session.state='stopped';session.nextAt=null;await this.ctx.storage.put('session',session);await this.ctx.storage.deleteAlarm();}
    return Response.json({session:session??null});
   }
   if(operation!=='/start'||!input.id||!input.configuration)return Response.json({error:'Invalid test request.'},{status:400});
   if(session && session.id===input.id){
    if(JSON.stringify(session.configuration)!==JSON.stringify(input.configuration))return Response.json({error:'Test ID already used with different options.'},{status:409});
    if(session.nextAt&&session.state!=='stopped'&&await this.ctx.storage.getAlarm()===null)await this.ctx.storage.setAlarm(Date.parse(session.nextAt));
    return Response.json({session});
   }
   if(session&&['scheduled','running'].includes(session.state))return Response.json({error:'Stop the current test before starting another.'},{status:409});
   const tokens=await this.tokens(input.pair);
   if(!tokens)return Response.json({error:'Pairing changed. Reopen Test alert.'},{status:409});
   if((input.configuration.phone||input.configuration.alarmKit)&&!tokens.push_token)return Response.json({error:'Enable notifications on the Parent iPhone before this test.'},{status:409});
   if(input.configuration.watch&&!tokens.watch_push_token)return Response.json({error:'Open the Apple Watch app and enable direct alerts before this test.'},{status:409});
   // Tests use the real alarm path, so they need the same Parent setting.
   if(input.configuration.alarmKit&&tokens.silent_watch_alarms!==1)return Response.json({error:'Turn on Silent Watch alarms on the Parent iPhone before testing AlarmKit.'},{status:409});
   if(input.configuration.alarmKit&&tokens.alarm_app_wake===0&&tokens.alarm_extension!==1)return Response.json({error:'Select at least one alarm delivery method on the Parent iPhone before testing AlarmKit.'},{status:409});
   const startsAt=new Date(Date.now()+10000).toISOString();
   session={id:input.id,pair:input.pair,configuration:input.configuration,startsAt,nextAt:startsAt,completedCount:0,state:'scheduled',message:null};
   await this.ctx.storage.put('session',session);
   await this.ctx.storage.setAlarm(Date.parse(startsAt));
   return Response.json({session});
  });
 }
 private tokens(pair:Pair) {
  return this.env.DB.prepare(`SELECT d.push_token,d.watch_push_token,d.silent_watch_alarms,d.alarm_app_wake,d.alarm_extension FROM devices d JOIN pairs p ON p.parent_id=?
   WHERE d.id=? AND p.listener_id=? AND p.created_at=? AND (d.id=p.parent_id OR EXISTS(SELECT 1 FROM caregiver_families f WHERE f.owner_id=p.parent_id AND f.partner_id=d.id AND f.pair_created_at=p.created_at))`).bind(pair.parent_id,pair.recipient_id??pair.parent_id,pair.listener_id,pair.created_at)
   .first<{push_token:string|null;watch_push_token:string|null;silent_watch_alarms:number;alarm_app_wake:number;alarm_extension:number}>();
 }
 async alarm():Promise<void> {
  await this.ctx.blockConcurrencyWhile(async()=>{
   const session=await this.ctx.storage.get<Session>('session');
   if(!session||!session.nextAt||!['scheduled','running'].includes(session.state))return;
   // Ignore an early or duplicate callback; never compress missed intervals.
   if(Date.parse(session.nextAt)>Date.now()){await this.ctx.storage.setAlarm(Date.parse(session.nextAt));return;}
   const finish=async(state:Session['state'],message:string|null)=>{
    session.state=state;session.message=message;session.nextAt=null;
    await this.ctx.storage.put('session',session);await this.ctx.storage.deleteAlarm();
   };
   if(session.dispatching){await finish('failed','A previous round was interrupted. Test stopped without replaying any delivery.');return;}
   if(Date.now()>Date.parse(session.startsAt)+600000){await finish('failed','Test expired after 10 minutes.');return;}
   const tokens=await this.tokens(session.pair);
   if(!tokens){await finish('stopped','Pairing changed; test stopped.');return;}
   const options=session.configuration,now=new Date().toISOString();
   const alert:Alert={eventId:crypto.randomUUID(),episodeId:session.id,listenerId:session.pair.listener_id,type:'sustained_cry',
    cryStartedAt:now,createdAt:now,durationSeconds:0,isRepeat:session.completedCount>0,isTest:true,...(session.pair.recipient_id?{targetCaregiverId:session.pair.recipient_id}:{})};
   const nextRoundAt=Date.now()+options.repeatInterval*1000;
   session.completedCount++;
   session.state='running';session.dispatching=true;
   session.nextAt=new Date(Date.now()+30000).toISOString();
   // Checkpoint before sending; alarm retries can only advance to another tick.
   await this.ctx.storage.put('session',session);
   if(session.nextAt)await this.ctx.storage.setAlarm(Date.parse(session.nextAt));else await this.ctx.storage.deleteAlarm();
   try {
    // Retain normal test history/relevance/acknowledgement without enrolling the
    // real-alert retry outbox. A crash leaves this event uncertain, never pending.
    const inserted=await this.env.DB.prepare(`INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,status,attempts,created_at)
     SELECT ?,?,?,?,?,?,'uncertain',1,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?)`)
     .bind(alert.eventId,alert.episodeId,alert.listenerId,session.pair.parent_id,Number(alert.isRepeat),JSON.stringify(alert),Date.now(),
      session.pair.parent_id,session.pair.listener_id,session.pair.created_at).run();
    if(!inserted.meta.changes){await finish('stopped','Pairing changed; test stopped.');return;}
    const eventRef=await eventReference(this.env,alert.eventId);
    const collapseID=options.coalesceRepeats?session.id:alert.eventId;
    const identity={collapseID,separateCollapseIDs:!options.sharedCollapseIDs,distinctRequestID:options.distinctRequestIDs,
     threadID:options.groupNotifications?session.id:undefined,configuredTest:true};
    const head=options.phone&&options.watch&&options.phoneHeadStartMS?new PhoneHeadStart(options.phoneHeadStartMS):undefined;
    const targets:('phone'|'watch'|'alarm')[]=[];
    if(options.phone)targets.push('phone');if(options.watch)targets.push('watch');if(options.alarmKit)targets.push('alarm');
    const results=await Promise.all(targets.map(async target=>{
     const timing=new Latency();timing.eventRef=eventRef;timing.deliveryAttempt=1;
     const started=Date.now(),token=target==='watch'?tokens.watch_push_token:tokens.push_token;
     let result:PushResult={status:'blocked',reason:'no_push_token'};
     try {
      if(token)result=target==='alarm'
       ?await sendSilentCryAlarmPush(this.env,token,alert,timing,undefined,`alarm:${collapseID}`,{appWake:tokens.alarm_app_wake!==0,extension:tokens.alarm_extension===1})
       :await sendPush(this.env,token,alert,target,timing,false,head?.schedule(target,timing),identity);
     }catch{result={status:'failed',reason:'apns_configuration'};}
     finally{if(target==='phone')head?.phoneFinished();}
     await recordDiagnostic(this.env,{requestId:crypto.randomUUID(),started,operation:target==='alarm'?'silent_alarm_test_dispatch':'watch_test_dispatch',
      stage:'push',outcome:result.reason??result.status,eventRef,target:target==='watch'?'watch':'phone',attempt:1,httpStatus:result.httpStatus,details:timing.details});
     return result;
    }));
    const accepted=results.every(result=>result.status==='sent');
    await this.env.DB.prepare('UPDATE events SET status=?,sent_at=? WHERE event_id=?')
     .bind(accepted?'sent':'uncertain',accepted?new Date().toISOString():null,alert.eventId).run();
    if(!accepted){await finish('failed','A selected delivery could not be confirmed. Test stopped; an already sent notification may still arrive.');return;}
    session.dispatching=false;
    if(session.completedCount>=options.count){await finish('completed','Apple accepted all selected test deliveries. Confirm receipt on your devices.');return;}
    // Leave a full interval after a slow send, without replaying missed ticks.
    session.nextAt=new Date(nextRoundAt>Date.now()?nextRoundAt:Date.now()+options.repeatInterval*1000).toISOString();
    await this.ctx.storage.put('session',session);await this.ctx.storage.setAlarm(Date.parse(session.nextAt));
   }catch{await finish('failed','Test stopped because delivery status could not be saved. Already sent notifications may still arrive.');}
  });
 }
}
