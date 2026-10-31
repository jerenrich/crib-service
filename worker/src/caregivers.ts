import {APIError,requireRole,type Device,type Env,type Alert,type StoredEvent} from './types';
import {pairFor} from './devices';
import {rateLimit,sha256,uuid} from './security';
import {sendPush} from './apns';
import {Latency} from './latency';
import {eventReference,recordDiagnostic} from './diagnostics';
import {stoppedMonitoringSQL} from './monitoring';
import {scheduleReminders} from './reminders';
import {revokeLiveSound} from './live-sound';

export interface Family {owner_id:string;partner_id:string|null;pair_created_at:number;primary_id:string;escalation_seconds:number;revision:number}
interface Caregiver {id:string;caregiver_name:string;secondary_enabled:number;push_token:string|null;watch_push_token:string|null;silent_watch_alarms:number;alarm_app_wake:number;alarm_extension:number;alarm_receipts_version?:number}
interface Plan {primary:string;secondary:string|null;after:number;started:number}
export async function familyFor(env:Env,device:Device):Promise<Family|null> {
 if(device.role!=='parent')return null;
 return env.DB.prepare(`SELECT f.* FROM caregiver_families f JOIN pairs p ON p.parent_id=f.owner_id AND p.created_at=f.pair_created_at WHERE f.owner_id=? OR f.partner_id=?`).bind(device.id,device.id).first<Family>();
}
export async function sharedDevice(env:Env,device:Device,family:Family|null):Promise<Device> {
 if(!family||family.owner_id===device.id)return device;
 const owner=await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(family.owner_id).first<Device>();
 if(!owner)throw new APIError(409,'Family unavailable. Refresh and pair again.');
 return {...owner,familyAuthorization:{memberId:device.id,pairCreatedAt:family.pair_created_at}};
}
export async function familyStatus(env:Env,device:Device,family=undefined as Family|null|undefined) {
 const f=family===undefined?await familyFor(env,device):family;
 if(!f)return null;
 const caregivers=await env.DB.prepare('SELECT id,caregiver_name,secondary_enabled,push_token,watch_push_token FROM devices WHERE id=? OR id=?').bind(f.owner_id,f.partner_id).all<Caregiver>();
 return {myId:device.id,primaryId:f.primary_id,revision:f.revision,escalationSeconds:f.escalation_seconds,caregivers:caregivers.results.map(d=>({id:d.id,name:d.caregiver_name,secondaryEnabled:d.secondary_enabled===1,phoneRegistered:!!d.push_token,watchRegistered:!!d.watch_push_token}))};
}
function name(value:unknown):string {if(typeof value!=='string'||!value.trim()||value.trim().length>40)throw new APIError(400,'Enter a name of 1–40 characters.');return value.trim();}
export async function inviteCaregiver(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');await rateLimit(env,'caregiver-invite',device.id,5,600);
 const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Pair the nursery iPhone first.');
 const family=await familyFor(env,device);if(family?.partner_id)throw new APIError(409,'Two caregivers are already connected.');
 const displayName=name(value.name),random=new Uint32Array(1);do{crypto.getRandomValues(random);}while(random[0]>=4294000000);const code=String(random[0]%1000000).padStart(6,'0');
 const hash=await sha256(`${env.PAIRING_PEPPER}|caregiver|${code}`),expires=Date.now()+600000;
 await env.DB.batch([
  env.DB.prepare('UPDATE devices SET caregiver_name=? WHERE id=?').bind(displayName,device.id),
  env.DB.prepare(`INSERT INTO caregiver_families(owner_id,pair_created_at,primary_id) SELECT parent_id,created_at,parent_id FROM pairs WHERE parent_id=? ON CONFLICT(owner_id) DO NOTHING`).bind(device.id),
  env.DB.prepare('DELETE FROM caregiver_invites WHERE owner_id=? OR expires_at<=?').bind(device.id,Date.now()),
  env.DB.prepare('INSERT INTO caregiver_invites(code_hash,owner_id,pair_created_at,expires_at) VALUES(?,?,?,?)').bind(hash,device.id,pair.created_at,expires)
 ]);
 return {code,expiresAt:new Date(expires).toISOString()};
}
export async function joinCaregiver(env:Env,device:Device,value:Record<string,unknown>,ip:string) {
 requireRole(device,'parent');await rateLimit(env,'caregiver-join',device.id,6,600);await rateLimit(env,'caregiver-join-ip',ip,20,600);
 if(typeof value.code!=='string'||!/^\d{6}$/.test(value.code))throw new APIError(400,'Enter the six-digit invitation code.');
 const displayName=name(value.name),hash=await sha256(`${env.PAIRING_PEPPER}|caregiver|${value.code}`);
 const prior=await env.DB.prepare('SELECT claimed_by FROM caregiver_invites WHERE code_hash=? AND claimed_by=?').bind(hash,device.id).first();
 if(prior&&await familyFor(env,device))return {paired:true};
 if(await pairFor(env,device)||await familyFor(env,device))throw new APIError(409,'This iPhone is already paired.');
 const result=await env.DB.batch([
  env.DB.prepare(`UPDATE caregiver_families SET partner_id=?,revision=revision+1 WHERE partner_id IS NULL AND NOT EXISTS(SELECT 1 FROM pairs WHERE parent_id=?) AND EXISTS(
   SELECT 1 FROM caregiver_invites i JOIN pairs p ON p.parent_id=i.owner_id AND p.created_at=i.pair_created_at
   WHERE i.code_hash=? AND i.expires_at>? AND i.claimed_by IS NULL AND i.owner_id=caregiver_families.owner_id AND i.pair_created_at=caregiver_families.pair_created_at)`)
   .bind(device.id,device.id,hash,Date.now()),
  env.DB.prepare(`UPDATE caregiver_invites SET claimed_by=? WHERE code_hash=? AND EXISTS(SELECT 1 FROM caregiver_families f WHERE f.owner_id=caregiver_invites.owner_id AND f.partner_id=?)`).bind(device.id,hash,device.id),
  env.DB.prepare('UPDATE devices SET caregiver_name=? WHERE id=?').bind(displayName,device.id),
  env.DB.prepare('DELETE FROM pairing_codes WHERE parent_id=? AND EXISTS(SELECT 1 FROM caregiver_families WHERE partner_id=?)').bind(device.id,device.id)
 ]);
 if(!result[0].meta.changes)throw new APIError(409,'Invitation expired, used, or family already full.');
 return {paired:true};
}
export async function updateDuty(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');const f=await familyFor(env,device);if(!f)throw new APIError(409,'Connect your family first.');
 if(value.revision!==f.revision)throw new APIError(409,'Duty changed on another iPhone. Refresh and try again.');
 const primary=value.primaryId===undefined?f.primary_id:uuid(value.primaryId);
 if(primary!==f.owner_id&&primary!==f.partner_id)throw new APIError(400,'Choose a connected caregiver as primary.');
 const delay=value.escalationSeconds===undefined?f.escalation_seconds:value.escalationSeconds;
 if(![60,120,180,300].includes(delay as number))throw new APIError(400,'Choose a valid escalation delay.');
 const target=value.caregiverId===undefined?device.id:uuid(value.caregiverId);
 if(target!==f.owner_id&&target!==f.partner_id)throw new APIError(403,'Caregiver is not in this family.');
 if(value.secondaryEnabled!==undefined&&typeof value.secondaryEnabled!=='boolean')throw new APIError(400,'Choose secondary availability.');
 const receipt=crypto.randomUUID();
 // A revision-qualified receipt makes the preference and role mutation atomic:
 // a concurrent loser cannot still overwrite someone's secondary preference.
 const result=await env.DB.batch([
  env.DB.prepare('UPDATE caregiver_families SET primary_id=?,escalation_seconds=?,revision=revision+1,mutation_id=? WHERE owner_id=? AND revision=? RETURNING revision').bind(primary,delay,receipt,f.owner_id,f.revision),
  ...(value.secondaryEnabled===undefined?[]:[env.DB.prepare(`UPDATE devices SET secondary_enabled=? WHERE id=? AND EXISTS(SELECT 1 FROM caregiver_families WHERE owner_id=? AND mutation_id=?)`).bind(Number(value.secondaryEnabled),target,f.owner_id,receipt)])
 ]);
 if(!result[0].meta.changes)throw new APIError(409,'Duty changed on another iPhone. Refresh and try again.');
 return familyStatus(env,device);
}
export async function detachCaregiver(env:Env,device:Device,f:Family,deleteDevice=false) {
 if(device.id===f.owner_id){await env.DB.batch([env.DB.prepare('DELETE FROM caregiver_invites WHERE owner_id=?').bind(f.owner_id),env.DB.prepare('DELETE FROM caregiver_families WHERE owner_id=?').bind(f.owner_id)]);return false;}
 await env.DB.batch([
  env.DB.prepare('UPDATE caregiver_families SET partner_id=NULL,primary_id=owner_id,revision=revision+1 WHERE owner_id=? AND partner_id=?').bind(f.owner_id,device.id),
  env.DB.prepare('DELETE FROM caregiver_invites WHERE claimed_by=?').bind(device.id),
  env.DB.prepare('DELETE FROM silent_alarm_cycles WHERE parent_id=?').bind(device.id),
  env.DB.prepare('UPDATE devices SET silent_watch_alarms=0 WHERE id=?').bind(device.id),
  ...(deleteDevice?[env.DB.prepare('DELETE FROM devices WHERE id=?').bind(device.id)]:[])
 ]);
 const pair=await env.DB.prepare('SELECT * FROM pairs WHERE parent_id=?').bind(f.owner_id).first<{parent_id:string;listener_id:string;created_at:number}>();if(pair)await revokeLiveSound(env,pair);await scheduleReminders(env,f.owner_id);return true;
}

export function planRecipients(plan:Plan,now:number):string[] {return [plan.primary,...(plan.secondary&&now>=plan.started+plan.after*1000?[plan.secondary]:[])];}
// Family events keep their own per-caregiver/per-destination receipts. They never
// reuse the legacy two-target receipt for a different phone after a duty swap.
export async function dispatchFamilyEvent(env:Env,eventId:string):Promise<boolean> {
 const event=await env.DB.prepare(`SELECT e.* FROM events e JOIN caregiver_families f ON f.owner_id=e.parent_id JOIN pairs p ON p.parent_id=f.owner_id AND p.created_at=f.pair_created_at WHERE e.event_id=?`).bind(eventId).first<StoredEvent & {caregiver_plan:string|null}>();
 if(!event)return false;
 const family=await env.DB.prepare('SELECT * FROM caregiver_families WHERE owner_id=?').bind(event.parent_id).first<Family>();if(!family?.partner_id)return false;
 const alert=JSON.parse(event.payload) as Alert;
 if(alert.isTest||alert.type!=='sustained_cry')return false;
 const now=Date.now(),claim=crypto.randomUUID();
 await env.DB.batch([
  env.DB.prepare(`UPDATE events SET resolved_at=(SELECT r.resolved_at FROM resolved_episodes r JOIN pairs p ON p.parent_id=r.parent_id AND p.listener_id=r.listener_id AND p.created_at=r.pair_created_at WHERE r.parent_id=events.parent_id AND r.listener_id=events.listener_id AND r.episode_id=events.episode_id) WHERE event_id=? AND resolved_at IS NULL`).bind(eventId),
  env.DB.prepare(`UPDATE events SET acknowledged_at=? WHERE event_id=? AND acknowledged_at IS NULL AND (
   EXISTS(SELECT 1 FROM devices d WHERE d.id=events.parent_id AND d.alerts_muted_until>? AND d.alerts_muted_until>0)
   OR EXISTS(SELECT 1 FROM alert_snoozes s JOIN pairs p ON p.parent_id=s.parent_id AND p.listener_id=s.listener_id AND p.created_at=s.pair_created_at WHERE s.parent_id=events.parent_id AND s.listener_id=events.listener_id AND events.created_at BETWEEN s.started_at AND s.until_at))`).bind(new Date(now).toISOString(),eventId,now),
  env.DB.prepare("UPDATE events SET status='failed',last_error='expired_event' WHERE event_id=? AND created_at<?").bind(eventId,now-86400000),
  env.DB.prepare("UPDATE caregiver_deliveries SET state='uncertain',lease_until=NULL WHERE event_id=? AND state='sending' AND lease_until<=?").bind(eventId,now)
 ]);
 const claimed=await env.DB.prepare(`UPDATE events SET status='sending',claim_id=?,lease_until=?,attempts=attempts+1 WHERE event_id=?
  AND status IN ('pending','blocked') AND acknowledged_at IS NULL AND resolved_at IS NULL AND next_attempt<=?
  AND EXISTS(SELECT 1 FROM pairs p JOIN devices d ON d.id=p.parent_id WHERE p.parent_id=events.parent_id AND p.listener_id=events.listener_id AND d.alerts_muted_until<=?)
  AND NOT (${stoppedMonitoringSQL}) RETURNING *`).bind(claim,now+30000,eventId,now,now,now).first();
 if(!claimed)return true;
 const f=await env.DB.prepare('SELECT * FROM caregiver_families WHERE owner_id=?').bind(event.parent_id).first<Family>();
 if(!f)return true;
 const caregivers=(await env.DB.prepare('SELECT * FROM devices WHERE id=? OR id=?').bind(f.owner_id,f.partner_id).all<Caregiver>()).results;
 let plan=event.caregiver_plan?JSON.parse(event.caregiver_plan) as Plan:null;
 if(!plan){
  const first=await env.DB.prepare('SELECT caregiver_plan,created_at FROM events WHERE parent_id=? AND episode_id=? ORDER BY created_at ASC,event_id ASC LIMIT 1').bind(event.parent_id,event.episode_id).first<{caregiver_plan:string|null;created_at:number}>();
  const secondary=caregivers.find(d=>d.id!==f.primary_id);
  plan=first?.caregiver_plan?JSON.parse(first.caregiver_plan) as Plan:{primary:f.primary_id,secondary:secondary?.secondary_enabled===1?secondary.id:null,after:f.escalation_seconds,started:now};
  await env.DB.prepare('UPDATE events SET caregiver_plan=? WHERE event_id=? AND claim_id=?').bind(JSON.stringify(plan),eventId,claim).run();
 }
 let accepted=false,retry=false,uncertain=false;
 for(const id of planRecipients(plan,now)){
  const recipient=caregivers.find(d=>d.id===id);if(!recipient||(id===plan.secondary&&recipient.secondary_enabled!==1))continue;
  for(const target of ['phone','watch'] as const){
   const token=target==='phone'?recipient.push_token:recipient.watch_push_token;
   if(!token){retry=true;continue;}
   await env.DB.prepare(`INSERT INTO caregiver_deliveries(event_id,device_id,target) VALUES(?,?,?) ON CONFLICT DO NOTHING`).bind(eventId,id,target).run();
   const receipt=await env.DB.prepare(`UPDATE caregiver_deliveries SET state='sending',claim_id=?,lease_until=? WHERE event_id=? AND device_id=? AND target=? AND state IN ('pending','blocked') RETURNING *`).bind(claim,now+30000,eventId,id,target).first();
   if(!receipt){const old=await env.DB.prepare('SELECT state FROM caregiver_deliveries WHERE event_id=? AND device_id=? AND target=?').bind(eventId,id,target).first<{state:string}>();accepted ||= old?.state==='sent';uncertain ||= old?.state==='uncertain';continue;}
   // Recheck revocation, episode resolution, mute and Stop immediately before APNs.
   const eligible=await env.DB.prepare(`SELECT 1 FROM events e JOIN pairs p ON p.parent_id=e.parent_id AND p.listener_id=e.listener_id JOIN caregiver_families f ON f.owner_id=p.parent_id AND f.pair_created_at=p.created_at JOIN devices d ON d.id=f.owner_id WHERE e.event_id=? AND e.claim_id=? AND e.acknowledged_at IS NULL AND e.resolved_at IS NULL AND d.alerts_muted_until<=? AND (f.owner_id=? OR f.partner_id=?) AND NOT (${stoppedMonitoringSQL.replaceAll('events.','e.')})`).bind(eventId,claim,Date.now(),id,id,Date.now()).first();
   if(!eligible){await env.DB.prepare("UPDATE caregiver_deliveries SET state='cancelled' WHERE event_id=? AND device_id=? AND target=? AND claim_id=?").bind(eventId,id,target,claim).run();continue;}
   const cycle=target==='phone'?await reserveFamilyAlarm(env,event,recipient,claim):undefined;
   const requestAlarm=recipient.silent_watch_alarms===1&&recipient.alarm_app_wake!==0&&(recipient.alarm_receipts_version!==1||!!cycle);
   let result:Awaited<ReturnType<typeof sendPush>>;
   const timing=new Latency(),started=Date.now();
   try{result=await sendPush(env,token,alert,target,timing,requestAlarm,undefined,{separateCollapseIDs:true,alarmExtension:recipient.silent_watch_alarms===1&&recipient.alarm_extension===1},cycle);}
   catch{result={status:'uncertain',reason:'internal_error'};}
   const status=result.status==='retry'?'pending':result.status;
   await env.DB.prepare('UPDATE caregiver_deliveries SET state=?,lease_until=NULL WHERE event_id=? AND device_id=? AND target=? AND claim_id=?').bind(status,eventId,id,target,claim).run();
   if(result.reason==='invalid_device_token')await env.DB.prepare(`UPDATE devices SET ${target==='phone'?'push_token':'watch_push_token'}=NULL WHERE id=? AND ${target==='phone'?'push_token':'watch_push_token'}=?`).bind(id,token).run();
   await recordDiagnostic(env,{requestId:crypto.randomUUID(),started,operation:'dispatch',stage:'storage',outcome:result.reason??result.status,eventRef:await eventReference(env,eventId),target,attempt:event.attempts+1,httpStatus:result.httpStatus,details:timing.details});
   accepted ||= status==='sent';retry ||= status==='pending'||status==='blocked';uncertain ||= status==='uncertain';
  }
 }
 await env.DB.prepare("UPDATE events SET status=?,sent_at=CASE WHEN ? THEN ? ELSE sent_at END,next_attempt=?,lease_until=NULL WHERE event_id=? AND claim_id=? AND status='sending'")
  .bind(accepted?'sent':uncertain?'uncertain':retry?'pending':'blocked',Number(accepted),new Date(now).toISOString(),now+5000,eventId,claim).run();
 return true;
}

export async function decorateFamilyStatus(env:Env,device:Device,f:Family,result:unknown) {
 const status=result as Record<string,unknown>;
 const rows=(await env.DB.prepare('SELECT event_id,episode_id,payload,caregiver_plan FROM events WHERE parent_id=? AND acknowledged_at IS NULL AND resolved_at IS NULL ORDER BY created_at DESC LIMIT 1001').bind(f.owner_id).all<{event_id:string;episode_id:string;payload:string;caregiver_plan:string|null}>()).results;
 const actual=device as Device & {watch_push_token:string|null;secondary_enabled:number;silent_watch_alarms:number;alarm_app_wake:number;alarm_extension:number;alarm_receipts_version?:number};
 const allowed=rows.filter(row=>{
  const alert=JSON.parse(row.payload) as Alert;
  if(alert.isTest)return device.id===(alert.targetCaregiverId??f.owner_id);
  if(alert.type!=='sustained_cry')return device.id===f.owner_id;
  const plan=row.caregiver_plan?JSON.parse(row.caregiver_plan) as Plan:null;
  if(!plan)return device.id===f.primary_id;
  return device.id===plan.primary||(device.id===plan.secondary&&actual.secondary_enabled===1&&Date.now()>=plan.started+plan.after*1000);
 });
 const ids=new Set(allowed.map(r=>r.event_id));
 return {...status,caregiverDuty:await familyStatus(env,device,f),phonePushRegistered:!!actual.push_token,watchPushRegistered:!!actual.watch_push_token,
 silentWatchAlarmsEnabled:actual.silent_watch_alarms===1,alarmMethods:{appWake:actual.alarm_app_wake!==0,extension:actual.alarm_extension===1},
 alerts:Array.isArray(status.alerts)?status.alerts.filter(a=>ids.has(a.eventId)||a.acknowledgedAt||a.resolvedAt):[],
 notificationRelevance:rows.length>1000?null:{cryEpisodeIDs:allowed.filter(r=>!(JSON.parse(r.payload) as Alert).isTest).map(r=>r.episode_id),testEventIDs:allowed.filter(r=>(JSON.parse(r.payload) as Alert).isTest).map(r=>r.event_id)}};
}


async function reserveFamilyAlarm(env:Env,event:StoredEvent,recipient:Caregiver,claim:string):Promise<string|undefined> {
 if(recipient.alarm_receipts_version!==1||recipient.silent_watch_alarms!==1||recipient.alarm_app_wake===0)return undefined;
 const now=Date.now();
 const same=`silent_alarm_cycles.listener_id=excluded.listener_id AND silent_alarm_cycles.pair_created_at=excluded.pair_created_at AND silent_alarm_cycles.cycle_at=excluded.cycle_at`;
 const saved=await env.DB.prepare(`INSERT INTO silent_alarm_cycles
  (parent_id,episode_id,listener_id,pair_created_at,cycle_at,cycle_id,first_requested_at,last_requested_at,request_count,request_claim_id,request_event_ids)
  SELECT ?,e.episode_id,e.listener_id,p.created_at,d.alerts_muted_until,?,?,?,1,?,json_array(e.event_id)
  FROM events e JOIN pairs p ON p.parent_id=e.parent_id AND p.listener_id=e.listener_id JOIN devices d ON d.id=p.parent_id
  JOIN caregiver_families f ON f.owner_id=p.parent_id AND f.pair_created_at=p.created_at
  WHERE e.event_id=? AND e.claim_id=? AND e.acknowledged_at IS NULL AND e.resolved_at IS NULL AND d.alerts_muted_until<=? AND (f.owner_id=? OR f.partner_id=?)
  ON CONFLICT(parent_id,episode_id) DO UPDATE SET
   listener_id=excluded.listener_id,pair_created_at=excluded.pair_created_at,cycle_at=excluded.cycle_at,
   cycle_id=CASE WHEN ${same} THEN silent_alarm_cycles.cycle_id ELSE excluded.cycle_id END,
   first_requested_at=CASE WHEN ${same} THEN silent_alarm_cycles.first_requested_at ELSE excluded.first_requested_at END,
   last_requested_at=excluded.last_requested_at,
   request_count=CASE WHEN ${same} THEN silent_alarm_cycles.request_count+1 ELSE 1 END,
   request_claim_id=excluded.request_claim_id,
   request_event_ids=CASE WHEN ${same} THEN json_insert(CASE WHEN json_array_length(silent_alarm_cycles.request_event_ids)>=32 THEN json_remove(silent_alarm_cycles.request_event_ids,'$[0]') ELSE silent_alarm_cycles.request_event_ids END,'$[#]',json_extract(excluded.request_event_ids,'$[0]')) ELSE excluded.request_event_ids END,
   confirmed_at=NULL
  WHERE NOT (${same}) OR (silent_alarm_cycles.confirmed_at IS NULL AND excluded.last_requested_at>=silent_alarm_cycles.last_requested_at+CASE WHEN silent_alarm_cycles.request_count<3 THEN 30000 ELSE 120000 END)
  RETURNING cycle_id`).bind(recipient.id,crypto.randomUUID(),now,now,claim,event.event_id,claim,now,recipient.id,recipient.id).first<{cycle_id:string}>();
 return saved?.cycle_id;
}
