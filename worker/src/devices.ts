import {APIError, defaultConfiguration, requireRole, type Device, type Env} from './types';
import {constantTimeEqual, encryptToken, rateLimit, sha256, uuid} from './security';
export async function register(env:Env,value:Record<string,unknown>,ip:string) {
 await rateLimit(env,'register',ip,10,600);
 const id=uuid(value.deviceId);const {role,secret}=value;
 if(!['listener','parent'].includes(String(role))||typeof secret!=='string'||!/^[A-Za-z0-9+/]{43}=$/.test(secret))throw new APIError(400,'Invalid device registration.');
 const hash=await sha256(secret);
 const existing=await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(id).first<Device>();
 if(existing){if(existing.role!==role||!constantTimeEqual(existing.secret_hash,hash))throw new APIError(409,'Device registration conflict.');return {ok:true};}
 await env.DB.prepare('INSERT INTO devices(id,role,secret_hash,created_at,config) VALUES(?,?,?,?,?) ON CONFLICT(id) DO NOTHING').bind(id,role,hash,new Date().toISOString(),JSON.stringify(defaultConfiguration)).run();
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
export async function pairFor(env:Env,device:Device):Promise<{parent_id:string;listener_id:string}|null> {
 return env.DB.prepare(`SELECT * FROM pairs WHERE ${device.role==='parent'?'parent_id':'listener_id'}=?`).bind(device.id).first();
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
