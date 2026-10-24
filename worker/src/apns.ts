import {decryptToken} from './security';
import type {Alert,Env} from './types';
import {PushPreparationError,type Outcome} from './diagnostics';

export type PushResult = {status:'sent'|'retry'|'blocked'|'uncertain'|'failed';reason?:Outcome;httpStatus?:number};
let cache: {identity:string;token:string;expires:number}|undefined;
function base64url(value:Uint8Array):string {return btoa(String.fromCharCode(...value)).replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');}
function encodedJSON(value:unknown):string {return base64url(new TextEncoder().encode(JSON.stringify(value)));}
export async function apnsToken(env:Env):Promise<string> {
 if(!env.APNS_KEY_ID||!env.APNS_TEAM_ID||!env.APNS_PRIVATE_KEY||!env.APNS_BUNDLE_ID)throw new Error('APNs configuration missing');
 const identity=`${env.APNS_KEY_ID}|${env.APNS_TEAM_ID}|${env.APNS_PRIVATE_KEY}`;
 const now=Math.floor(Date.now()/1000);
 if(cache?.identity===identity&&cache.expires>now)return cache.token;
 const pem=env.APNS_PRIVATE_KEY.replace(/\\n/g,'\n').replace(/-----[^-]+-----/g,'').replace(/\s/g,'');
 const key=await crypto.subtle.importKey('pkcs8',Uint8Array.from(atob(pem),c=>c.charCodeAt(0)),{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
 const input=`${encodedJSON({alg:'ES256',kid:env.APNS_KEY_ID})}.${encodedJSON({iss:env.APNS_TEAM_ID,iat:now})}`;
 const signature=await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,new TextEncoder().encode(input));
 const token=`${input}.${base64url(new Uint8Array(signature))}`;
 cache={identity,token,expires:now+3000};return token;
}
export function payload(alert:Alert,target:'phone'|'watch'='phone') {
 const minutes=Math.floor(alert.durationSeconds/60);const seconds=Math.floor(alert.durationSeconds%60);
 const duration=minutes>0?`${minutes} minute${minutes===1?'':'s'}${seconds?` ${seconds} seconds`:''}`:`${seconds} seconds`;
 const title=alert.isTest?'Test · Crib Service':alert.isRepeat?'Reminder · Check on baby':'Baby is crying';
 const body=alert.isRepeat&&!alert.isTest?'Crying was detected. Acknowledge this alert to snooze crying alerts for the duration chosen in Settings.':alert.isTest?`Test notification from your Listener. Simulated the ${duration} alert threshold.`:`Crying-like sound has continued for ${duration}. Started at ${new Date(alert.cryStartedAt).toISOString().slice(11,16)} UTC. Acknowledge to snooze crying alerts for the duration chosen in Settings.`;
 return {aps:{alert:{title,body},category:'BABY_CRY_ALERT','thread-id':alert.episodeId,...(target==='watch'?{sound:'default','interruption-level':'time-sensitive'}:{})},eventId:alert.eventId,episodeId:alert.episodeId,cryStartedAt:alert.cryStartedAt,createdAt:alert.createdAt,durationSeconds:alert.durationSeconds,...(alert.isTest?{isTest:true}:{})};
}
export async function sendPush(env:Env,encryptedToken:string,alert:Alert,target:'phone'|'watch'='phone'):Promise<PushResult> {
 return sendNotification(env,encryptedToken,alert.eventId,payload(alert,target),target,alert.isRepeat?5:3600,alert.isRepeat?alert.episodeId:alert.eventId);
}
export async function sendConnectionPush(env:Env,encryptedToken:string,id:string,state:'offline'|'stopped',target:'phone'|'watch'):Promise<PushResult> {
 const title=state==='stopped'?'Listener monitoring stopped':'Listener connection lost';
 const body=state==='stopped'?'The Listener reports that monitoring has stopped. Check the nursery phone.':'No Listener update for at least 3 minutes. Check power, internet, and monitoring.';
 return sendNotification(env,encryptedToken,id,{aps:{alert:{title,body},'thread-id':'listener-connection',...(target==='watch'?{sound:'default','interruption-level':'time-sensitive'}:{})},connectionState:state},target,180);
}
async function sendNotification(env:Env,encryptedToken:string,id:string,content:unknown,target:'phone'|'watch',expiration:number,collapseId=id):Promise<PushResult> {
 // Errors before fetch are known not to have sent a notification and can safely retry.
 let deviceToken:string,jwt:string;
 try {deviceToken=await decryptToken(env,encryptedToken);}catch{throw new PushPreparationError('token_decryption');}
 try {jwt=await apnsToken(env);}catch{throw new PushPreparationError('provider_signing');}
 if(!['development','production'].includes(env.APNS_ENVIRONMENT))throw new PushPreparationError('apns_environment');
 const host=env.APNS_ENVIRONMENT==='production'?'api.push.apple.com':'api.sandbox.push.apple.com';
 let response:Response;
 try {
  response=await fetch(`https://${host}/3/device/${deviceToken}`,{method:'POST',headers:{authorization:`bearer ${jwt}`,'apns-topic':env.APNS_BUNDLE_ID+(target==='watch'?'.watchkitapp':''),'apns-push-type':'alert','apns-priority':'10','apns-id':id,'apns-collapse-id':collapseId,'apns-expiration':String(Math.floor(Date.now()/1000)+expiration),'content-type':'application/json'},body:JSON.stringify(content),signal:AbortSignal.timeout(10000)});
 }catch{return {status:'uncertain',reason:'transport_unknown'};}
 const httpStatus=response.status;
 if(response.status===200)return {status:'sent',httpStatus};
 if(response.status===429)return {status:'retry',reason:'apns_429',httpStatus};
 if(response.status===500)return {status:'retry',reason:'apns_500',httpStatus};
 if(response.status===503)return {status:'retry',reason:'apns_503',httpStatus};
 let reason='rejected';try{const error=await response.json() as {reason?:string};reason=error.reason??reason;}catch{/* Empty rejection body remains a failure. */}
 if(['BadDeviceToken','DeviceTokenNotForTopic','Unregistered'].includes(reason))return {status:'blocked',reason:'invalid_device_token',httpStatus};
 if(['ExpiredProviderToken','InvalidProviderToken','Forbidden','TopicDisallowed'].includes(reason))return {status:'retry',reason:'provider_configuration',httpStatus};
 const reasons:Record<string,Outcome>={BadTopic:'bad_topic',MissingTopic:'missing_topic',BadPriority:'bad_priority',BadExpirationDate:'bad_expiration',PayloadEmpty:'bad_payload',PayloadTooLarge:'payload_too_large'};
 const safeReason=Object.hasOwn(reasons,reason)?reasons[reason]:'apns_rejected';
 return {status:'failed',reason:safeReason,httpStatus};
}
