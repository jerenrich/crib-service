import type {PushSchedule} from './notification-coordination';
import {decryptToken} from './security';
import type {Alert,Env} from './types';
import {PushPreparationError,type Outcome} from './diagnostics';
import {Latency,appleReasons,type AppleReason} from './latency';
import {providerTokens} from './provider-token';

export type PushResult = {status:'sent'|'retry'|'blocked'|'uncertain'|'failed';reason?:Outcome;httpStatus?:number};
export interface PushIdentityOptions {distinctRequestID?:boolean;separateCollapseIDs?:boolean}
export async function apnsToken(env:Env,latency?:Latency):Promise<string> {
 return providerTokens.get(env,latency);
}
export function payload(alert:Alert) {
 const minutes=Math.floor(alert.durationSeconds/60);const seconds=Math.floor(alert.durationSeconds%60);
 const unit=(value:number,name:string)=>`${value} ${name}${value===1?'':'s'}`;
 const duration=minutes>0?`${unit(minutes,'minute')}${seconds?` ${unit(seconds,'second')}`:''}`:unit(seconds,'second');
 const disconnected=alert.type==='listener_disconnected';
 const title=disconnected?'Listener connection lost':alert.isTest?'Test · Crib Service':alert.isRepeat?'Repeat alert · Check on baby':'Baby is crying';
 const body=disconnected?'No Listener update for at least 3 minutes. Check the nursery phone’s power, internet and monitoring. Snooze to pause alerts for the duration chosen in Settings.':alert.isRepeat&&!alert.isTest?'Crying was detected. Acknowledge this alert to snooze alerts for the duration chosen in Settings.':alert.isTest&&alert.isRepeat?'Repeating Watch alert test. Use Stop Watch test in iPhone Settings to end the test.':alert.isTest?`Test notification from your Listener. Simulated the ${duration} alert threshold.`:`Crying-like sound has continued for ${duration}. Started at ${new Date(alert.cryStartedAt).toISOString().slice(11,16)} UTC. Acknowledge to snooze alerts for the duration chosen in Settings.`;
 // Keep alerting metadata identical so both devices request system sound/haptics.
 // Device Silent Mode can mute audio while preserving Watch notification taps.
 return {aps:{alert:{title,body},category:'BABY_CRY_ALERT','interruption-level':'time-sensitive',sound:'default'},type:alert.type,...(disconnected?{connectionState:'offline'}:{}),eventId:alert.eventId,episodeId:alert.episodeId,cryStartedAt:alert.cryStartedAt,createdAt:alert.createdAt,durationSeconds:alert.durationSeconds,...(alert.isTest?{isTest:true}:{})};
}
export async function sendPush(env:Env,encryptedToken:string,alert:Alert,target:'phone'|'watch'='phone',latency=new Latency(),silentCryAlarm=false,schedule?:PushSchedule,identity:PushIdentityOptions={},alarmCycle?:string):Promise<PushResult> {
 latency.details.alarm_wake_requested=silentCryAlarm&&target==='phone'&&!alert.isTest;
 const diagnosticRef=latency.eventRef,deliveryAttempt=latency.deliveryAttempt;
 const correlation=diagnosticRef&&/^[0-9a-f]{64}$/.test(diagnosticRef)&&deliveryAttempt!==undefined&&Number.isSafeInteger(deliveryAttempt)&&deliveryAttempt>0&&deliveryAttempt<=1_000_000?{diagnosticRef,deliveryAttempt}:{};
 const content=payload(alert);
 // Transport and notification identities are separate controls. The logical
 // payload identity remains shared so acknowledging either copy handles one event.
 const requestID=identity.distinctRequestID?crypto.randomUUID():alert.eventId;
 if(identity.distinctRequestID){latency.details.apns_id_mode='distinct_request';latency.details.apns_request_id=requestID;}
 // Every repeat is a new notification. Only retries of the same event share an
 // identity; episode-wide replacement could merge distinct reminders.
 const collapseBase=alert.eventId;
 const collapseID=identity.separateCollapseIDs?`${target}:${collapseBase}`:collapseBase;
 if(identity.separateCollapseIDs){latency.details.apns_collapse_mode='target_scoped';latency.details.apns_collapse_basis='event';}
 return sendNotification(env,encryptedToken,requestID,{...content,...correlation,
  // AlarmKit is additive: retain the phone's normal sound/haptic request so
  // Apple can forward an alert while the separate direct Watch copy also alerts.
  ...(silentCryAlarm&&target==='phone'&&!alert.isTest?{silentCryAlarm:true,...(alarmCycle?{alarmCycleId:alarmCycle}:{}),aps:{...content.aps,'content-available':1}}:{})
 },target,alert.isRepeat?15:3600,collapseID,latency,schedule);
}
export async function sendSilentCryAlarmPush(env:Env,encryptedToken:string,alert:Alert,latency=new Latency(),alarmCycle?:string):Promise<PushResult> {
 latency.details.alarm_wake_requested=true;
 const content=payload(alert);
 // Separate APNs request ID, preserving event/episode identity for acknowledgement.
 return sendNotification(env,encryptedToken,crypto.randomUUID(),{...content,silentCryAlarm:true,...(alarmCycle?{alarmCycleId:alarmCycle}:{}),
  aps:{...content.aps,'content-available':1}},'phone',60,alert.episodeId,latency);
}
export async function sendConnectionPush(env:Env,encryptedToken:string,id:string,state:'offline'|'stopped',target:'phone'|'watch',latency=new Latency()):Promise<PushResult> {
 const title=state==='stopped'?'Listener monitoring stopped':'Listener connection lost';
 const body=state==='stopped'?'The Listener reports that monitoring has stopped. Check the nursery phone.':'No Listener update for at least 3 minutes. Check power, internet, and monitoring.';
 return sendNotification(env,encryptedToken,id,{aps:{alert:{title,body},'thread-id':'listener-connection','interruption-level':'time-sensitive',sound:'default'},connectionState:state},target,180,id,latency);
}
// A user-visible, soundless notification also requests background execution.
// It is deliberately separate from ordinary crying and Watch notification routing.
export async function sendSilentAlarmTestPush(env:Env,encryptedToken:string,alert:Alert,latency=new Latency()):Promise<PushResult> {
 const content={...payload(alert),silentAlarmTest:true,aps:{
  alert:{title:'Test · Silent alarm delivery',body:'Listener test received. If the Parent experiment is armed, it will try to start a silent alarm on your paired Watch.'},
  'content-available':1,category:'SILENT_ALARM_TEST','thread-id':alert.episodeId,'interruption-level':'time-sensitive'
 }};
 return sendNotification(env,encryptedToken,alert.eventId,content,'phone',60,alert.eventId,latency);
}
// Fixed, separate topic for the standalone proof of concept. Reuse the existing
// provider-token authority so the experiment cannot introduce JWT churn.
export async function sendWatchLatencyProbe(env:Env,encryptedToken:string,eventId:string,createdAt:string,latency:Latency):Promise<PushResult> {
 return sendNotification(env,encryptedToken,eventId,{aps:{alert:{title:'Test · Wrist Probe',body:'Standalone direct Watch notification'},
  sound:'default','interruption-level':'time-sensitive'},eventId,createdAt,isTest:true},'watch',60,eventId,latency,undefined,
  'com.jordanerenrich.cribservice.latencyprobe');
}
async function sendNotification(env:Env,encryptedToken:string,id:string,content:unknown,target:'phone'|'watch',expiration:number,collapseId=id,latency=new Latency(),schedule?:PushSchedule,topic?:string):Promise<PushResult> {
 // Errors before fetch are known not to have sent a notification and can safely retry.
 let deviceToken:string,jwt:string;
 try {deviceToken=await latency.measure('token_decrypt_ms',()=>decryptToken(env,encryptedToken));}catch{throw new PushPreparationError('token_decryption');}
 try {jwt=await latency.measure('provider_sign_ms',()=>apnsToken(env,latency));}catch{throw new PushPreparationError('provider_signing');}
 if(!['development','production'].includes(env.APNS_ENVIRONMENT))throw new PushPreparationError('apns_environment');
 const host=env.APNS_ENVIRONMENT==='production'?'api.push.apple.com':'api.sandbox.push.apple.com';
 if(schedule?.beforeRequest)await schedule.beforeRequest();
 let response:Response;
 const signal=AbortSignal.timeout(10000);
 latency.details.apns_environment=env.APNS_ENVIRONMENT as 'development'|'production';
 schedule?.requestStarted?.();
 latency.details.apns_started_at_ms=Date.now();
 try {
  response=await latency.measure('apns_fetch_ms',()=>fetch(`https://${host}/3/device/${deviceToken}`,{method:'POST',headers:{authorization:`bearer ${jwt}`,'apns-topic':topic??env.APNS_BUNDLE_ID+(target==='watch'?'.watchkitapp':''),'apns-push-type':'alert','apns-priority':'10','apns-id':id,'apns-collapse-id':collapseId,'apns-expiration':String(Math.floor(Date.now()/1000)+expiration),'content-type':'application/json'},body:JSON.stringify(content),signal}));
  latency.details.apns_response_at_ms=Date.now();
  latency.details.apns_unique_id=response.headers.get('apns-unique-id')??undefined;
 }catch{latency.details.transport=signal.aborted?'timeout':'network';return {status:'uncertain',reason:'transport_unknown'};}
 const httpStatus=response.status;
 if(response.status===200){
  // Acceptance is final. Release an unused response stream without letting
  // cleanup failure/delay change it into an ambiguous send or hold the alarm.
  try{void response.body?.cancel().catch(()=>{});}catch{/* Cleanup is best effort. */}
  return {status:'sent',httpStatus};
 }
 const reason=await latency.measure('apns_body_ms',()=>appleReason(response));
 latency.details.apns_reason=reason;
 if(response.status===429)return {status:'retry',reason:'apns_429',httpStatus};
 if(response.status===500)return {status:'retry',reason:'apns_500',httpStatus};
 if(response.status===503)return {status:'retry',reason:'apns_503',httpStatus};
 if(['BadDeviceToken','DeviceTokenNotForTopic','Unregistered','ExpiredToken'].includes(reason))return {status:'blocked',reason:'invalid_device_token',httpStatus};
 if(['ExpiredProviderToken','InvalidProviderToken','Forbidden','TopicDisallowed'].includes(reason))return {status:'retry',reason:'provider_configuration',httpStatus};
 const reasons:Record<string,Outcome>={BadTopic:'bad_topic',MissingTopic:'missing_topic',BadPriority:'bad_priority',BadExpirationDate:'bad_expiration',PayloadEmpty:'bad_payload',PayloadTooLarge:'payload_too_large'};
 const safeReason=Object.hasOwn(reasons,reason)?reasons[reason]:'apns_rejected';
 return {status:'failed',reason:safeReason,httpStatus};
}

// Rejection bodies are untrusted. Bound reads and keep only Apple's fixed codes.
async function appleReason(response:Response):Promise<AppleReason> {
 const reader=response.body?.getReader();if(!reader)return 'unreadable';
 try {
  let text='',size=0;const decoder=new TextDecoder();
  while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>4096)return 'unreadable';text+=decoder.decode(value,{stream:true});}
  text+=decoder.decode();
  const reason=(JSON.parse(text) as {reason?:unknown}).reason;
  return typeof reason==='string'&&appleReasons.includes(reason as AppleReason)?reason as AppleReason:'unknown';
 }catch{return 'unreadable';}finally{await reader.cancel().catch(()=>{});}
}
