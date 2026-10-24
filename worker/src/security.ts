import {validateTimelineEvents} from './timeline';
import {APIError, type Env, type Configuration, type Episode, type Alert, type Heartbeat} from './types';
export const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function uuid(value:unknown):string { if(typeof value!=='string'||!uuidPattern.test(value)) throw new APIError(400,'Invalid UUID.'); return value.toLowerCase(); }
export async function sha256(value:string):Promise<string> {const result = await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value));return [...new Uint8Array(result)].map(b=>b.toString(16).padStart(2,'0')).join('');}
export function constantTimeEqual(a:string,b:string):boolean {let diff=a.length^b.length;for(let i=0;i<Math.max(a.length,b.length);i++) diff|=(a.charCodeAt(i)||0)^(b.charCodeAt(i)||0);return diff===0;}
export async function body(request:Request):Promise<Record<string,unknown>> {
 if (!request.headers.get('content-type')?.startsWith('application/json')) throw new APIError(415,'JSON required.');
 // Read bounded bytes even if Content-Length is omitted or false.
 const reader=request.body?.getReader(); if(!reader) throw new APIError(400,'JSON body required.');
 let size=0;const chunks:Uint8Array[]=[];
 while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>65536){await reader.cancel();throw new APIError(413,'Body too large.');}chunks.push(value);}
 const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 try { const parsed:unknown=JSON.parse(new TextDecoder().decode(bytes)); if(!parsed||typeof parsed!=='object'||Array.isArray(parsed))throw new Error(); return parsed as Record<string,unknown>; }
 catch { throw new APIError(400,'Invalid JSON object.'); }
}
export function onlyKeys(value:Record<string,unknown>, keys:string[]) {if(Object.keys(value).some(key=>!keys.includes(key))) throw new APIError(400,'Unexpected metadata field. Audio and features are not accepted.');}
export function date(value:unknown):string {if(typeof value!=='string'||!/^\d{4}-\d{2}-\d{2}T/.test(value)||!Number.isFinite(Date.parse(value)))throw new APIError(400,'Invalid timestamp.');return new Date(value).toISOString();}
export function configuration(value:Record<string,unknown>):Configuration {
 // Accept and discard the retired field in saved settings and older requests.
 onlyKeys(value,['alertDuration','quietResetDuration','sensitivity','repeatInterval','absoluteThreshold','snoozeDuration']);
 const {alertDuration,quietResetDuration,repeatInterval,absoluteThreshold}=value;
 const snoozeDuration=value.snoozeDuration??60;
 if(!([60,120,300,600,900] as unknown[]).includes(snoozeDuration))throw new APIError(400,'Invalid snooze duration.');
 if(typeof alertDuration!=='number'||!Number.isFinite(alertDuration)||alertDuration<5||alertDuration>3600||typeof quietResetDuration!=='number'||![10,20,30,60].includes(quietResetDuration)||(repeatInterval!=null&&!([5,15,120,300] as unknown[]).includes(repeatInterval))||typeof absoluteThreshold!=='number'||!Number.isFinite(absoluteThreshold)||absoluteThreshold < -60||absoluteThreshold > -10)throw new APIError(400,'Invalid monitoring configuration.');
 return {alertDuration,quietResetDuration,repeatInterval:5,absoluteThreshold,snoozeDuration:snoozeDuration as number};
}
function episode(value:unknown):Episode {
 if(!value||typeof value!=='object'||Array.isArray(value))throw new APIError(400,'Invalid episode.');
 const v=value as Record<string,unknown>;onlyKeys(v,['id','startedAt','endedAt','alertSentAt']);
 const result:Episode={id:uuid(v.id),startedAt:date(v.startedAt)};
 if(v.endedAt!=null){result.endedAt=date(v.endedAt);if(Date.parse(result.endedAt)<Date.parse(result.startedAt))throw new APIError(400,'Invalid episode duration.');}
 if(v.alertSentAt!=null)result.alertSentAt=date(v.alertSentAt);
 return result;
}
export function heartbeat(value:Record<string,unknown>):Heartbeat {
 onlyKeys(value,['listenerId','timestamp','monitoring','batteryLevel','powerConnected','state','currentEpisode','episodes','appliedConfiguration','timelineEvents']);
 if(typeof value.monitoring!=='boolean'||typeof value.powerConnected!=='boolean'||!['quiet','possibleCry','crying'].includes(String(value.state))||!Array.isArray(value.episodes)||value.episodes.length>100||(value.batteryLevel!=null&&(typeof value.batteryLevel!=='number'||value.batteryLevel<0||value.batteryLevel>1)))throw new APIError(400,'Invalid heartbeat.');
 const timelineEvents=value.timelineEvents===undefined?undefined:validateTimelineEvents(value.timelineEvents);
 const result:Heartbeat={listenerId:uuid(value.listenerId), timestamp:date(value.timestamp),monitoring:value.monitoring,powerConnected:value.powerConnected,batteryLevel:value.batteryLevel as number|null|undefined,state:value.state as Heartbeat['state'],currentEpisode:value.currentEpisode==null?null:episode(value.currentEpisode),episodes:value.episodes.map(episode)};
 if(timelineEvents)result.timelineEvents=timelineEvents;
 if(value.appliedConfiguration!=null){
  if(typeof value.appliedConfiguration!=='object'||Array.isArray(value.appliedConfiguration))throw new APIError(400,'Invalid applied configuration.');
  result.appliedConfiguration=configuration(value.appliedConfiguration as Record<string,unknown>);
 }
 return result;
}
export function alert(value:Record<string,unknown>):Alert {
 onlyKeys(value,['eventId','episodeId','listenerId','type','cryStartedAt','durationSeconds','createdAt','isRepeat','isTest']);
 if(value.isTest!==undefined&&typeof value.isTest!=='boolean')throw new APIError(400,'Invalid test flag.');
 if(value.type!=='sustained_cry'||typeof value.isRepeat!=='boolean'||typeof value.durationSeconds!=='number'||!Number.isFinite(value.durationSeconds)||value.durationSeconds<0||value.durationSeconds>604800)throw new APIError(400,'Invalid alert.');
 const result:Alert={eventId:uuid(value.eventId),episodeId:uuid(value.episodeId),listenerId:uuid(value.listenerId),type:'sustained_cry',cryStartedAt:date(value.cryStartedAt),durationSeconds:value.durationSeconds,createdAt:date(value.createdAt),isRepeat:value.isRepeat};
 if(value.isTest!==undefined)result.isTest=value.isTest;
 if(Math.abs((Date.parse(result.createdAt)-Date.parse(result.cryStartedAt))/1000-result.durationSeconds)>2)throw new APIError(400,'Inconsistent alert duration.');
 return result;
}
export async function rateLimit(env:Env, scope:string, identifier:string, limit:number, windowSeconds:number):Promise<void> {
 const key=await sha256(`${env.PAIRING_PEPPER}|${scope}|${identifier}`);const window=Math.floor(Date.now()/1000/windowSeconds);
 const row=await env.DB.prepare('INSERT INTO rate_limits(key,window,attempts) VALUES (?,?,1) ON CONFLICT(key) DO UPDATE SET attempts=CASE WHEN window=excluded.window THEN attempts+1 ELSE 1 END, window=excluded.window RETURNING attempts').bind(key,window).first<{attempts:number}>();
 if((row?.attempts??limit+1)>limit)throw new APIError(429,'Too many requests. Try again later.');
}
function fromBase64(value:string):Uint8Array {return Uint8Array.from(atob(value),c=>c.charCodeAt(0));}
function toBase64(value:Uint8Array):string {return btoa(String.fromCharCode(...value));}
async function encryptionKey(env:Env):Promise<CryptoKey> {
 let bytes:Uint8Array;try{bytes=fromBase64(env.TOKEN_ENCRYPTION_KEY);}catch{throw new Error('Token encryption configuration missing');}
 if(bytes.length!==32)throw new Error('Token encryption configuration invalid');
 return crypto.subtle.importKey('raw',bytes,'AES-GCM',false,['encrypt','decrypt']);
}
export async function encryptToken(env:Env, token:string):Promise<string> {
 const iv=crypto.getRandomValues(new Uint8Array(12));const encrypted=await crypto.subtle.encrypt({name:'AES-GCM',iv},await encryptionKey(env),new TextEncoder().encode(token));
 return `${toBase64(iv)}.${toBase64(new Uint8Array(encrypted))}`;
}
export async function decryptToken(env:Env, encrypted:string):Promise<string> {
 const [iv,ciphertext]=encrypted.split('.');const result=await crypto.subtle.decrypt({name:'AES-GCM',iv:fromBase64(iv)},await encryptionKey(env),fromBase64(ciphertext));return new TextDecoder().decode(result);
}
