import {APIError,type Env} from './types';
import {body,rateLimit} from './security';
import {authenticate,register,savePushToken,saveWatchPushToken} from './devices';
import {createPairing,claimPairing} from './pairing';
import {receiveAlert,acknowledge,flushPending} from './alerts';
import {saveHeartbeat,listenerStatus,saveSettings} from './status';

export default {
 async fetch(request:Request,env:Env):Promise<Response> {
  try {
   const url=new URL(request.url);
   if(url.protocol!=='https:' && !['localhost','127.0.0.1','[::1]'].includes(url.hostname))throw new APIError(400,'HTTPS required.');
   if(url.search)throw new APIError(400,'Query strings are not accepted.');
   if(!env.PAIRING_PEPPER||env.PAIRING_PEPPER.length<32)throw new Error('Pairing configuration missing');
   const route=`${request.method} ${url.pathname}`;
   const ip=request.headers.get('CF-Connecting-IP')??'local';
   await rateLimit(env,'api',ip,600,600);
   let result:unknown;
   if(route==='POST /v1/device/register')result=await register(env,await body(request),ip);
   else{
    const device=await authenticate(env,request);
    switch(route){
     case 'POST /v1/pairing/create':result=await createPairing(env,device);break;
     case 'POST /v1/pairing/claim':result=await claimPairing(env,device,await body(request),ip);break;
     case 'POST /v1/device/push-token':result=await savePushToken(env,device,await body(request));break;
     case 'POST /v1/device/watch-push-token':result=await saveWatchPushToken(env,device,await body(request));break;
     case 'POST /v1/listener/heartbeat':result=await saveHeartbeat(env,device,await body(request));break;
     case 'POST /v1/listener/event':result=await receiveAlert(env,device,await body(request));break;
     case 'GET /v1/listener/status':result=await listenerStatus(env,device);break;
     case 'POST /v1/settings':result=await saveSettings(env,device,await body(request));break;
     case 'POST /v1/alert/acknowledge':result=await acknowledge(env,device,await body(request));break;
     default:throw new APIError(404,'Endpoint not found.');
    }
   }
   return Response.json(result,{headers:{'cache-control':'no-store','x-content-type-options':'nosniff'}});
  }catch(error){
   const expected=error instanceof APIError;
   return Response.json({error:expected?error.message:'Server configuration or storage unavailable.'},{status:expected?error.status:503,headers:{'cache-control':'no-store','x-content-type-options':'nosniff'}});
  }
 },
 async scheduled(_controller:ScheduledController,env:Env):Promise<void> {await flushPending(env);}
} satisfies ExportedHandler<Env>;
