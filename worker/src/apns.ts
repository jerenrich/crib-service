import {decryptToken} from './security';
import type {Alert,Env} from './types';

export type PushResult = {status:'sent'|'retry'|'blocked'|'uncertain'|'failed';reason?:string};
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
 const title=alert.isTest?'Test · Crib Service':'Baby is still crying';
 const body=alert.isTest?`Test notification from your Listener. Simulated the ${duration} alert threshold.`:`Crying-like sound has continued for ${duration}. Started at ${new Date(alert.cryStartedAt).toISOString().slice(11,16)} UTC.`;
 return {aps:{alert:{title,body},category:'BABY_CRY_ALERT','thread-id':alert.episodeId,...(target==='watch'?{sound:'default','interruption-level':'time-sensitive'}:{})},eventId:alert.eventId,episodeId:alert.episodeId,cryStartedAt:alert.cryStartedAt,createdAt:alert.createdAt,durationSeconds:alert.durationSeconds,...(alert.isTest?{isTest:true}:{})};
}
export async function sendPush(env:Env,encryptedToken:string,alert:Alert,target:'phone'|'watch'='phone'):Promise<PushResult> {
 // Errors before fetch are known not to have sent a notification and can safely retry.
 const deviceToken=await decryptToken(env,encryptedToken);const jwt=await apnsToken(env);
 if(!['development','production'].includes(env.APNS_ENVIRONMENT))throw new Error('Invalid APNs environment');
 const host=env.APNS_ENVIRONMENT==='production'?'api.push.apple.com':'api.sandbox.push.apple.com';
 let response:Response;
 try {
  response=await fetch(`https://${host}/3/device/${deviceToken}`,{method:'POST',headers:{authorization:`bearer ${jwt}`,'apns-topic':env.APNS_BUNDLE_ID+(target==='watch'?'.watchkitapp':''),'apns-push-type':'alert','apns-priority':'10','apns-id':alert.eventId,'apns-collapse-id':alert.eventId,'apns-expiration':String(Math.floor(Date.now()/1000)+3600),'content-type':'application/json'},body:JSON.stringify(payload(alert,target)),signal:AbortSignal.timeout(10000)});
 }catch{return {status:'uncertain',reason:'transport_unknown'};}
 if(response.status===200)return {status:'sent'};
 if([429,500,503].includes(response.status))return {status:'retry',reason:`apns_${response.status}`};
 let reason='rejected';try{const error=await response.json() as {reason?:string};reason=error.reason??reason;}catch{/* Empty rejection body remains a failure. */}
 if(['BadDeviceToken','DeviceTokenNotForTopic','Unregistered'].includes(reason))return {status:'blocked',reason:'invalid_device_token'};
 if(['ExpiredProviderToken','InvalidProviderToken','Forbidden','TopicDisallowed'].includes(reason))return {status:'retry',reason:'provider_configuration'};
 return {status:'failed',reason:'apns_rejected'};
}
