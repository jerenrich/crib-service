import {APIError, defaultConfiguration, requireRole, type Device, type Env} from './types';
import {constantTimeEqual, encryptToken, rateLimit, sha256, uuid} from './security';
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
export async function authenticate(env:Env,request:Request):Promise<Device> {
 const authorization=request.headers.get('authorization')??'';
 const match=/^Bearer ([0-9a-f-]+)\.([A-Za-z0-9+/]{43}=)$/i.exec(authorization);
 if(!match)throw new APIError(401,'Device authentication required.');
 const id=uuid(match[1]);const device=await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id).first<Device>();
 if(!device||!constantTimeEqual(device.secret_hash,await sha256(match[2])))throw new APIError(401,'Device authentication failed.');
 return device;
}
export async function savePushToken(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');
 if(typeof value.token!=='string'||!/^[0-9a-f]{64,200}$/i.test(value.token))throw new APIError(400,'Invalid APNs token.');
 await env.DB.batch([
  env.DB.prepare('UPDATE devices SET push_token=? WHERE id=?').bind(await encryptToken(env,value.token),device.id),
  env.DB.prepare("UPDATE events SET status='pending',next_attempt=0 WHERE parent_id=? AND status='blocked' AND acknowledged_at IS NULL").bind(device.id)
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
 return {ok:true};
}
export async function saveWatchPushToken(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');
 if(value.token!==null && (typeof value.token!=='string'||!/^[0-9a-f]{64,200}$/i.test(value.token)))throw new APIError(400,'Invalid Watch APNs token.');
 await env.DB.batch([
  env.DB.prepare('UPDATE devices SET watch_push_token=? WHERE id=?').bind(value.token===null?null:await encryptToken(env,value.token),device.id),
  env.DB.prepare("UPDATE events SET status='pending',next_attempt=0,push_target=NULL WHERE parent_id=? AND status='blocked' AND acknowledged_at IS NULL").bind(device.id)
 ]);
 return {ok:true};
}
