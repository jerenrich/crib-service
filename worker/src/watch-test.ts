import {APIError,requireRole,type Device,type Env,type Alert} from './types';
import {pairFor} from './devices';
import {sendPush} from './apns';

// Compatibility for the released server-timer UI. Starting it is no longer allowed.
export function retiredWatchTest(device:Device,value?:Record<string,unknown>) {
 requireRole(device,'parent');
 if(value?.running!==undefined&&value.running!==false)
  throw new APIError(410,'Update the iPhone app to use the phone-controlled Watch test.');
 return {running:false,interval:5};
}

// Exactly one phone-triggered attempt. No alarm, persisted event or retry outbox.
export async function sendWatchTest(env:Env,device:Device) {
 requireRole(device,'parent');
 const pair=await pairFor(env,device);
 if(!pair)throw new APIError(409,'Pair a Listener first.');
 const watch=await env.DB.prepare(`SELECT d.watch_push_token FROM devices d JOIN pairs p ON p.parent_id=d.id
  WHERE d.id=? AND p.listener_id=? AND p.created_at=?`)
  .bind(device.id,pair.listener_id,pair.created_at).first<{watch_push_token:string|null}>();
 if(!watch?.watch_push_token)throw new APIError(409,'Open the Watch app and enable alerts first.');
 const now=new Date(Date.now()).toISOString();
 const alert:Alert={eventId:crypto.randomUUID(),episodeId:crypto.randomUUID(),listenerId:pair.listener_id,
  type:'sustained_cry',cryStartedAt:now,durationSeconds:0,createdAt:now,isRepeat:true,isTest:true};
 const result=await sendPush(env,watch.watch_push_token,alert,'watch');
 if(result.status!=='sent')throw new APIError(503,'Watch test delivery could not be confirmed. The test has stopped; try again.');
 return {ok:true};
}
