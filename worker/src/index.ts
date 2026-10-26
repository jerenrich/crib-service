import {retiredWatchTest,sendWatchTest,sendSilentAlarmTest} from './watch-test';
import {sendStandaloneProbe} from './watch-latency-probe';
import {requestMonitoring,completeMonitoring} from './monitoring';
import {timeline} from './timeline';
export {AlertReminders} from './reminders';
export {LiveSound} from './live-sound';
export {ProviderTokens} from './provider-token';
import {providerTokens} from './provider-token';
import {openLiveSound} from './live-sound';
import {APIError,type Env} from './types';
import {body,rateLimit} from './security';
import {admitAlert,admitHeartbeat,authenticate,register,savePushToken,saveWatchPushToken,saveSilentWatchAlarms,removeDeviceData,pairFor} from './devices';
import {connectionPreferences,flushConnections} from './connections';
import {createPairing,claimPairing} from './pairing';
import {receiveAlert,acknowledge,resumeAlerts,flushPending} from './alerts';
import {saveHeartbeat,listenerStatus,saveSettings} from './status';
import {operationFor,recordDiagnostic,observeLateWrites,type Stage} from './diagnostics';
import {queueStatusDiagnostic,queueHeartbeatDiagnostic} from './status-diagnostics';
import {startAlertProgress} from './alert-progress';
import {Latency} from './latency';

export default {
 async fetch(request:Request,env:Env,ctx?:ExecutionContext):Promise<Response> {
  const requestId=crypto.randomUUID(),started=Date.now(),latency=new Latency();
  observeLateWrites(env,latency,ctx,requestId,started);
  latency.details.colo=typeof request.cf?.colo==='string'?request.cf.colo:undefined;
  let operation=operationFor('', ''),stage:Stage='validation',stopProgress:(()=>void)|undefined;
  const respond=async(result:unknown,status:number,outcome:'ok'|'rejected'|'internal_error')=>{
   if((operation==='status'||operation==='heartbeat')&&outcome==='ok'&&ctx){
    const diagnostic={requestId,started,stage,outcome,httpStatus:status,details:latency.progressDetails()};
    const state=operation==='status'?queueStatusDiagnostic(env,ctx,{...diagnostic,operation}):queueHeartbeatDiagnostic(env,ctx,{...diagnostic,operation});
    return Response.json(result,{status,headers:{'cache-control':'no-store','x-content-type-options':'nosniff','x-request-id':requestId,
     'x-diagnostics-status':state,'x-diagnostics-elapsed-ms':'0','x-server-received-at-ms':String(started),'x-server-sent-at-ms':String(Date.now())}});
   }
   const journalStarted=performance.now();
   const saved=await latency.measure('journal_ms',()=>recordDiagnostic(env,{requestId,started,operation,stage,outcome,httpStatus:status,eventRef:latency.eventRef,details:latency.details}));
   return Response.json(result,{status,headers:{'cache-control':'no-store','x-content-type-options':'nosniff',
    'x-request-id':requestId,'x-diagnostics-status':saved?'recorded':'unavailable','x-diagnostics-elapsed-ms':String(Math.round(Math.max(0,performance.now()-journalStarted))),
    'x-server-received-at-ms':String(started),'x-server-sent-at-ms':String(Date.now())}});
  };
  try {
   const url=new URL(request.url);
   operation=operationFor(request.method,url.pathname);
   if(url.protocol!=='https:' && !['localhost','127.0.0.1','[::1]'].includes(url.hostname))throw new APIError(400,'HTTPS required.');
   if(url.search)throw new APIError(400,'Query strings are not accepted.');
   if(!env.PAIRING_PEPPER||env.PAIRING_PEPPER.length<32)throw new Error('Pairing configuration missing');
   const route=`${request.method} ${url.pathname}`;
   const ip=request.headers.get('CF-Connecting-IP')??'local';
   const alertUpload=route==='POST /v1/listener/event',heartbeatUpload=route==='POST /v1/listener/heartbeat';
   if(alertUpload){
    const clientRequestId=request.headers.get('x-client-request-id');
    if(clientRequestId&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(clientRequestId))latency.details.client_request_id=clientRequestId.toLowerCase();
    stopProgress=startAlertProgress(env,ctx,requestId,started,latency,()=>stage);
   }
   stage='rate_limit';
   // Both phones usually share one address (carrier NAT shares it more widely), so the
   // address bucket is only a flood ceiling. Crying alerts never depend on it.
   if(!alertUpload&&!heartbeatUpload)await latency.measure('rate_limit_ms',()=>rateLimit(env,'api',ip,3000,600,latency,'ip_rate_limit_ms'));
   let result:unknown;
   if(route==='POST /v1/device/register'){stage='handler';result=await latency.measure('handler_ms',async()=>register(env,await body(request),ip));}
   else{
    stage='authentication';
    const device=alertUpload?await admitAlert(env,request,latency):heartbeatUpload?await admitHeartbeat(env,request,ip,latency):await latency.measure('authentication_ms',()=>authenticate(env,request,latency));
    stage='rate_limit';
    // Separate budgets: a device's own polling must never delay a crying alert.
    const watchTestPush=route==='POST /v1/watch-test/push';
    if(!alertUpload&&!heartbeatUpload)await latency.measure('rate_limit_ms',()=>rateLimit(env,watchTestPush?'watch-test-push':'device',device.id,watchTestPush?660:600,600,latency,'device_rate_limit_ms'));
    stage='handler';
    const special=await latency.measure('handler_ms',async()=>{switch(route){
     case 'POST /v1/pairing/create':result=await createPairing(env,device);break;
     case 'POST /v1/pairing/claim':result=await claimPairing(env,device,await body(request),ip);break;
     case 'POST /v1/device/push-token':result=await savePushToken(env,device,await body(request));break;
     case 'POST /v1/device/watch-push-token':result=await saveWatchPushToken(env,device,await body(request));break;
     case 'POST /v1/diagnostics/apns':{
      if(device.role!=='parent')throw new APIError(403,'Only the Parent can check push readiness.');
      await rateLimit(env,'apns-readiness',device.id,6,600);
      // Check the persistent authority without sending a notification or
      // returning its bearer token. This never forces a token rotation.
      await latency.measure('provider_sign_ms',()=>providerTokens.get(env,latency,true));
      result={ready:true,tokenRef:latency.details.provider_token_ref,ageSeconds:latency.details.provider_token_age_s,source:latency.details.provider_token_source};break;
     }
     case 'POST /v1/silent-watch-alarms':result=await saveSilentWatchAlarms(env,device,await body(request));break;
     case 'POST /v1/pairing/remove':result=await removeDeviceData(env,device);break;
     case 'POST /v1/device/delete':result=await removeDeviceData(env,device,true);break;
     case 'POST /v1/connection-alerts':result=await connectionPreferences(env,device,await body(request));break;
     case 'POST /v1/watch-test/push':result=await sendWatchTest(env,device,latency,requestId);break;
     case 'POST /v1/watch-latency-probe/push':result=await sendStandaloneProbe(env,device,latency,requestId);break;
     case 'POST /v1/listener/silent-alarm-test':{
      if(device.role!=='listener')throw new APIError(403,'Only the Listener can send this test.');
      await rateLimit(env,'silent-alarm-test',device.id,6,600);
      result=await sendSilentAlarmTest(env,device,latency,requestId);break;
     }
     case 'GET /v1/watch-test':result=retiredWatchTest(device);break;
     case 'POST /v1/watch-test':result=retiredWatchTest(device,await body(request));break;
     case 'POST /v1/test-push':{
      if(device.role!=='parent')throw new APIError(403,'Only the Parent can request a test.');
      await rateLimit(env,'test-push',device.id,6,600);
      const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Pair a Listener first.');
      const listener=await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(pair.listener_id).first<import('./types').Device>();
      if(!listener)throw new APIError(409,'Listener unavailable.');
      const config=JSON.parse(device.config),now=new Date();
      result=await receiveAlert(env,listener,{eventId:crypto.randomUUID(),episodeId:crypto.randomUUID(),listenerId:listener.id,type:'sustained_cry',cryStartedAt:new Date(now.getTime()-config.alertDuration*1000).toISOString(),durationSeconds:config.alertDuration,createdAt:now.toISOString(),isRepeat:false,isTest:true},requestId,latency,ctx);
      break;
     }
     case 'POST /v1/listener/heartbeat':result=await saveHeartbeat(env,device,await latency.measure('body_read_ms',()=>body(request)),latency);break;
     case 'POST /v1/listener/event':result=await receiveAlert(env,device,await latency.measure('body_read_ms',()=>body(request)),requestId,latency,ctx);break;
     case 'GET /v1/timeline':result=await timeline(env,device);break;
     case 'GET /v1/listener/status':result=await listenerStatus(env,device,latency);break;
     case 'GET /v1/live-sound':return await openLiveSound(env,device,request);
     case 'POST /v1/monitoring':result=await requestMonitoring(env,device,await body(request));break;
     case 'POST /v1/monitoring/complete':result=await completeMonitoring(env,device,await body(request));break;
     case 'POST /v1/settings':result=await saveSettings(env,device,await body(request));break;
     case 'POST /v1/alert/resume':result=await resumeAlerts(env,device,await body(request));break;
     case 'POST /v1/alert/acknowledge':result=await acknowledge(env,device,await body(request));break;
     default:throw new APIError(404,'Endpoint not found.');
    }});
    if(special instanceof Response)return special;
   }
   return await respond(result,200,'ok');
  }catch(error){
   latency.failure(error);
   const expected=error instanceof APIError;
   return await respond({error:expected?error.message:'Server configuration or storage unavailable.'},expected?error.status:503,expected?'rejected':'internal_error');
  }finally{stopProgress?.();}
 },
 async scheduled(_controller:ScheduledController,env:Env,ctx?:ExecutionContext):Promise<void> {
  const requestId=crypto.randomUUID(),started=Date.now(),latency=new Latency();
  try {
   const results=await Promise.allSettled([flushPending(env,requestId,latency,ctx),latency.measure('maintenance_connections_ms',()=>flushConnections(env,requestId))]);
   if(results.some(result=>result.status==='rejected'))throw new Error('Maintenance failed.');
   await recordDiagnostic(env,{requestId,started,operation:'maintenance',stage:'handler',outcome:'ok',details:latency.details});
  } catch {
   await recordDiagnostic(env,{requestId,started,operation:'maintenance',stage:'handler',outcome:'internal_error',details:latency.details});
   // Preserve the failed-invocation metric without leaking a D1 exception/SQL value.
   throw new Error('Scheduled maintenance failed.');
  }
 }
} satisfies ExportedHandler<Env>;
