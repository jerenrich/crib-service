import {APIError,requireRole,type Device,type Env,type Alert} from './types';
import {pairFor} from './devices';
import {sendPush,type PushResult} from './apns';
import {Latency} from './latency';
import {eventReference,recordDiagnostic,PushPreparationError} from './diagnostics';

// Compatibility for the released server-timer UI. Starting it is no longer allowed.
export function retiredWatchTest(device:Device,value?:Record<string,unknown>) {
 requireRole(device,'parent');
 if(value?.running!==undefined&&value.running!==false)
  throw new APIError(410,'Update the iPhone app to use the phone-controlled Watch test.');
 return {running:false,interval:5};
}

// Exactly one phone-triggered attempt. No alarm, persisted event or retry outbox.
export async function sendWatchTest(env:Env,device:Device,latency=new Latency(),requestId=crypto.randomUUID()) {
 const started=Date.now();latency.details.dispatch_source='watch_test';
 requireRole(device,'parent');
 const pair=await latency.measure('pair_ms',()=>pairFor(env,device));
 if(!pair)throw new APIError(409,'Pair a Listener first.');
 const watch=await latency.read<{watch_push_token:string|null}>('destination_ms',env.DB.prepare(`SELECT d.watch_push_token FROM devices d JOIN pairs p ON p.parent_id=d.id
  WHERE d.id=? AND p.listener_id=? AND p.created_at=?`)
  .bind(device.id,pair.listener_id,pair.created_at));
 if(!watch?.watch_push_token)throw new APIError(409,'Open the Watch app and enable alerts first.');
 const now=new Date(Date.now()).toISOString();
 const alert:Alert={eventId:crypto.randomUUID(),episodeId:crypto.randomUUID(),listenerId:pair.listener_id,
  type:'sustained_cry',cryStartedAt:now,durationSeconds:0,createdAt:now,isRepeat:true,isTest:true};
 let eventRef:string|undefined;try{eventRef=await eventReference(env,alert.eventId);latency.eventRef=eventRef;}catch{/* Best effort. */}
 let result:PushResult;
 try{result=await sendPush(env,watch.watch_push_token,alert,'watch',latency);}
 catch(error){latency.failure(error);result={status:'retry',reason:error instanceof PushPreparationError?error.code:'apns_configuration'};}
 latency.details.push_outcome=result.status;
 await recordDiagnostic(env,{requestId,started,operation:'watch_test_dispatch',stage:'push',outcome:result.reason??result.status,eventRef,target:'watch',attempt:1,httpStatus:result.httpStatus,details:latency.details});
 if(result.status!=='sent')throw new APIError(503,'Watch test delivery could not be confirmed. The test has stopped; try again.');
 return {ok:true};
}
