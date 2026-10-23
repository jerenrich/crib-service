import {APIError,requireRole,type Env,type Device} from './types';
import {rateLimit,sha256} from './security';
import {pairFor} from './devices';
export async function createPairing(env:Env,device:Device) {
 requireRole(device,'parent');await rateLimit(env,'pairing-create',device.id,5,600);
 if(await pairFor(env,device))throw new APIError(409,'This Parent is already paired.');
 // Rejection sampling avoids modulo bias in the six-digit code.
 const random=new Uint32Array(1);let n:number;do{crypto.getRandomValues(random);n=random[0];}while(n>=4294000000);
 const code=(n%1000000).toString().padStart(6,'0');const expires=Date.now()+600000;
 const hash=await sha256(`${env.PAIRING_PEPPER}|${code}`);
 await env.DB.prepare('DELETE FROM pairing_codes WHERE parent_id=? OR expires_at<=?').bind(device.id,Date.now()).run();
 try{await env.DB.prepare('INSERT INTO pairing_codes(code_hash,parent_id,expires_at) VALUES(?,?,?)').bind(hash,device.id,expires).run();}
 catch{throw new APIError(503,'Could not create a code. Try again.');}
 return {code,expiresAt:new Date(expires).toISOString()};
}
export async function claimPairing(env:Env,device:Device,value:Record<string,unknown>,ip:string) {
 requireRole(device,'listener');await rateLimit(env,'pairing-claim-device',device.id,6,600);await rateLimit(env,'pairing-claim-ip',ip,20,600);
 if(typeof value.code!=='string'||!/^\d{6}$/.test(value.code))throw new APIError(400,'Invalid pairing code.');
 const hash=await sha256(`${env.PAIRING_PEPPER}|${value.code}`);
 // D1 batch is atomic: a unique pair conflict rolls back consumption. Claim success is
 // recoverable after a lost HTTP response using claimed_by, without reopening the code.
 const previous=await env.DB.prepare('SELECT * FROM pairing_codes WHERE code_hash=? AND claimed_by=?').bind(hash,device.id).first();
 if(previous && await pairFor(env,device))return {paired:true};
 if(await pairFor(env,device))throw new APIError(409,'This Listener is already paired.');
 try {
  const result=await env.DB.batch([
   env.DB.prepare('UPDATE pairing_codes SET claimed_by=? WHERE code_hash=? AND expires_at>? AND claimed_by IS NULL').bind(device.id,hash,Date.now()),
   env.DB.prepare('INSERT INTO pairs(parent_id,listener_id,created_at) SELECT parent_id,claimed_by,? FROM pairing_codes WHERE code_hash=? AND claimed_by=?').bind(Date.now(),hash,device.id)
  ]);
  if(result[1].meta.changes!==1)throw new APIError(400,'Code expired or already used.');
 }catch(error){if(error instanceof APIError)throw error;throw new APIError(409,'Code unavailable or device already paired.');}
 return {paired:true};
}
