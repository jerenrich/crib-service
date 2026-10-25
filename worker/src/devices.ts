import {APIError, defaultConfiguration, requireRole, type Device, type Env} from './types';
import {Latency} from './latency';
import {constantTimeEqual, encryptToken, rateLimit, rateLimitStatement, sha256, uuid} from './security';
import {revokeLiveSound} from './live-sound';
export async function register(env:Env,value:Record<string,unknown>,ip:string) {
 await rateLimit(env,'register',ip,10,600);
 const id=uuid(value.deviceId);const {role,secret}=value;
 if(!['listener','parent'].includes(String(role))||typeof secret!=='string'||!/^[A-Za-z0-9+/]{43}=$/.test(secret))throw new APIError(400,'Invalid device registration.');
 const hash=await sha256(secret);
 const existing=await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id).first<Device>();
 if(existing){if(existing.role!==role||!constantTimeEqual(existing.secret_hash,hash))throw new APIError(409,'Device registration conflict.');return {ok:true};}
 await env.DB.prepare('INSERT INTO devices(id,role,secret_hash,created_at,config,connection_alerts) VALUES(?,?,?,?,?,1) ON CONFLICT(id) DO NOTHING').bind(id,role,hash,new Date().toISOString(),JSON.stringify(defaultConfiguration)).run();
 const saved=await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id).first<Device>();
 if(!saved||saved.role!==role||!constantTimeEqual(saved.secret_hash,hash))throw new APIError(409,'Device registration conflict.');
 return {ok:true};
}
function credentialFor(request:Request):{id:string;secret:string} {
 const authorization=request.headers.get('authorization')??'';
 const match=/^Bearer ([0-9a-f-]+)\.([A-Za-z0-9+/]{43}=)$/i.exec(authorization);
 if(!match)throw new APIError(401,'Device authentication required.');
 return {id:uuid(match[1]),secret:match[2]};
}
export async function authenticate(env:Env,request:Request,latency?:Latency):Promise<Device> {
 const {id,secret}=credentialFor(request);
 const statement=env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id);
 const device=latency?await latency.read<Device>('authentication_lookup_ms',statement):await statement.first<Device>();
 const hash=latency?await latency.measure('authentication_hash_ms',()=>sha256(secret)):await sha256(secret);
 if(!device||!constantTimeEqual(device.secret_hash,hash))throw new APIError(401,'Device authentication failed.');
 return device;
}
// One transaction/remote call instead of separate authentication and rate-limit
// calls. No cache, background admission, write retry or hedged mutation.
export async function admitAlert(env:Env,request:Request,latency:Latency):Promise<Device> {
 const {id,secret}=credentialFor(request);
 const [hash,key]=await latency.measure('authentication_hash_ms',()=>Promise.all([
  sha256(secret),sha256(`${env.PAIRING_PEPPER}|alert|${id}`)
 ]));
 const window=Math.floor(Date.now()/1000/600);
 const results=await latency.db<Device|{attempts:number}>('alert_admission_ms',()=>env.DB.batch<Device|{attempts:number}>([
  env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id),rateLimitStatement(env,key,window,{id,hash})
 ]));
 const device=results[0].results[0] as Device|undefined;
 if(!device||!constantTimeEqual(device.secret_hash,hash))throw new APIError(401,'Device authentication failed.');
 const budget=results[1].results[0] as {attempts:number}|undefined;
 if(!budget||budget.attempts>600)throw new APIError(429,'Too many requests. Try again later.');
 return device;
}
export async function savePushToken(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');
 if(typeof value.token!=='string'||!/^[0-9a-f]{64,200}$/i.test(value.token))throw new APIError(400,'Invalid APNs token.');
 await env.DB.batch([
  env.DB.prepare('UPDATE devices SET push_token=? WHERE id=?').bind(await encryptToken(env,value.token),device.id),
  env.DB.prepare("UPDATE events SET status='pending',next_attempt=0 WHERE parent_id=? AND status='blocked' AND acknowledged_at IS NULL AND resolved_at IS NULL").bind(device.id)
 ]);
 return {ok:true};
}
export async function pairFor(env:Env,device:Device):Promise<{parent_id:string;listener_id:string;created_at:number}|null> {
 return env.DB.prepare(`SELECT * FROM pairs WHERE ${device.role==='parent'?'parent_id':'listener_id'}=?`).bind(device.id).first();
}

// A single D1 transaction cancels queued delivery and revokes the old relationship.
// The counterpart retains its credential so it can pair with a replacement phone.
export async function removeDeviceData(env:Env,device:Device,deleteDevice=false) {
 const pair=await pairFor(env,device);
 const listener=pair?.listener_id??device.id, parent=pair?.parent_id??device.id;
 await env.DB.batch([
  env.DB.prepare('UPDATE devices SET alerts_muted_until=0,alerts_muted_at=0 WHERE id=?').bind(parent),
  env.DB.prepare('DELETE FROM monitoring_commands WHERE listener_id=? OR parent_id=?').bind(listener,parent),
  env.DB.prepare('DELETE FROM resolved_episodes WHERE listener_id=? OR parent_id=?').bind(listener,parent),
  env.DB.prepare('DELETE FROM alert_snoozes WHERE listener_id=? OR parent_id=?').bind(listener,parent),
  env.DB.prepare('DELETE FROM timeline_events WHERE listener_id=? OR parent_id=?').bind(listener,parent),
  env.DB.prepare('DELETE FROM connection_notices WHERE listener_id=? OR parent_id=?').bind(listener,parent),
  env.DB.prepare('DELETE FROM connection_states WHERE listener_id=?').bind(listener),
  env.DB.prepare('DELETE FROM events WHERE listener_id=? OR parent_id=?').bind(listener,parent),
  env.DB.prepare('DELETE FROM heartbeats WHERE listener_id=?').bind(listener),
  env.DB.prepare('DELETE FROM pairing_codes WHERE parent_id=? OR claimed_by=?').bind(parent,listener),
  env.DB.prepare('DELETE FROM pairs WHERE parent_id=? OR listener_id=?').bind(parent,listener),
  ...(deleteDevice?[env.DB.prepare('DELETE FROM devices WHERE id=?').bind(device.id)]:[])
 ]);
 if(pair){
  try{await revokeLiveSound(env,pair);}catch{
   // Removal already committed in D1. A display-channel outage must not turn
   // successful unpairing/deletion into a failure; sockets recheck the pairing.
  }
 }
 return {ok:true};
}
export async function saveWatchPushToken(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');
 if(value.token!==null && (typeof value.token!=='string'||!/^[0-9a-f]{64,200}$/i.test(value.token)))throw new APIError(400,'Invalid Watch APNs token.');
 await env.DB.batch([
  env.DB.prepare('UPDATE devices SET watch_push_token=? WHERE id=?').bind(value.token===null?null:await encryptToken(env,value.token),device.id),
  env.DB.prepare("UPDATE events SET status='pending',next_attempt=0,push_target=NULL WHERE parent_id=? AND status='blocked' AND acknowledged_at IS NULL AND resolved_at IS NULL").bind(device.id)
 ]);
 return {ok:true};
}
