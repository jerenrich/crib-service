import {APIError,requireRole,type Device,type Env} from './types';
import {pairFor} from './devices';
import {rateLimit} from './security';
import {sendWatchLatencyProbe} from './apns';
import {eventReference,recordDiagnostic} from './diagnostics';
import {Latency} from './latency';

// An operator-created, unpaired temporary Parent owns only the probe token.
// Disabled unless its exact UUID is configured. Never touches a nursery pairing,
// creates reminders, accepts an arbitrary topic or automatically retries a send.
export async function sendStandaloneProbe(env:Env,device:Device,latency:Latency,requestId:string) {
 requireRole(device,'parent');
 if(!env.WATCH_LATENCY_PROBE_PARENT_ID||device.id!==env.WATCH_LATENCY_PROBE_PARENT_ID)
  throw new APIError(403,'Standalone Watch experiment is not enabled for this device.');
 if(await pairFor(env,device))throw new APIError(409,'Use an unpaired test registration for this experiment.');
 if(!device.push_token)throw new APIError(409,'Register the standalone Watch token first.');
 await rateLimit(env,'standalone-watch-probe',device.id,6,600);
 const eventId=crypto.randomUUID(),createdAt=new Date().toISOString(),started=Date.now();
 latency.eventRef=await eventReference(env,eventId);latency.deliveryAttempt=1;
 latency.details.dispatch_source='watch_test';
 const result=await sendWatchLatencyProbe(env,device.push_token,eventId,createdAt,latency);
 await recordDiagnostic(env,{requestId,started,operation:'watch_test_dispatch',stage:'push',
  outcome:result.reason??result.status,eventRef:latency.eventRef,target:'watch',attempt:1,
  httpStatus:result.httpStatus,details:latency.details});
 // Return known uncertainty as data: clients must never retry this POST blindly.
 return {eventId,createdAt,status:result.status,accepted:result.status==='sent',httpStatus:result.httpStatus};
}
