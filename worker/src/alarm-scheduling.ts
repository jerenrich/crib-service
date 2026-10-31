import {eventReference,eventReferences,recordDiagnostics} from './diagnostics';
import type {AlarmAttemptDetails,Latency} from './latency';
import {APIError,requireRole,type Device,type Env} from './types';
import {uuid} from './security';

// Included in the existing delivery-claim transaction: no additional D1 round
// trip or independent timer on the normal notification path. Only its winner
// may reserve a request. Ordinary reminders keep their own cadence.
export function reserveAlarmRequest(env:Env,eventId:string,claimId:string,now:number):D1PreparedStatement {
 const same=`silent_alarm_cycles.listener_id=excluded.listener_id
  AND silent_alarm_cycles.pair_created_at=excluded.pair_created_at
  AND silent_alarm_cycles.cycle_at=excluded.cycle_at`;
 return env.DB.prepare(`INSERT INTO silent_alarm_cycles
  (parent_id,episode_id,listener_id,pair_created_at,cycle_at,cycle_id,first_requested_at,last_requested_at,request_count,request_claim_id,request_event_ids)
  SELECT e.parent_id,e.episode_id,e.listener_id,p.created_at,d.alerts_muted_until,?,?,?,1,?,json_array(e.event_id)
  FROM events e JOIN devices d ON d.id=e.parent_id JOIN pairs p ON p.parent_id=e.parent_id AND p.listener_id=e.listener_id
  WHERE e.event_id=? AND e.claim_id=? AND e.status='sending' AND e.acknowledged_at IS NULL AND e.resolved_at IS NULL
  AND d.silent_watch_alarms=1 AND d.alarm_app_wake=1 AND d.alarm_receipts_version=1 AND d.push_token IS NOT NULL AND d.alerts_muted_until<=?
  AND COALESCE(json_extract(e.payload,'$.isTest'),0)=0 AND COALESCE(e.delivery_mode,'')!='watch_only'
  AND (e.delivery_state IS NULL OR json_extract(e.delivery_state,'$.phone') IN ('pending','blocked'))
  ON CONFLICT(parent_id,episode_id) DO UPDATE SET
   listener_id=excluded.listener_id,pair_created_at=excluded.pair_created_at,cycle_at=excluded.cycle_at,
   cycle_id=CASE WHEN ${same} THEN silent_alarm_cycles.cycle_id ELSE excluded.cycle_id END,
   first_requested_at=CASE WHEN ${same} THEN silent_alarm_cycles.first_requested_at ELSE excluded.first_requested_at END,
   last_requested_at=excluded.last_requested_at,
   request_count=CASE WHEN ${same} THEN silent_alarm_cycles.request_count+1 ELSE 1 END,
   request_claim_id=excluded.request_claim_id,
   request_event_ids=CASE WHEN ${same} THEN json_insert(
    CASE WHEN json_array_length(silent_alarm_cycles.request_event_ids)>=32 THEN json_remove(silent_alarm_cycles.request_event_ids,'$[0]') ELSE silent_alarm_cycles.request_event_ids END,
    '$[#]',json_extract(excluded.request_event_ids,'$[0]')) ELSE excluded.request_event_ids END,confirmed_at=NULL
  WHERE NOT (${same}) OR (silent_alarm_cycles.confirmed_at IS NULL
   AND excluded.last_requested_at>=silent_alarm_cycles.last_requested_at+
    CASE WHEN silent_alarm_cycles.request_count<3 THEN 30000 ELSE 120000 END)`)
  .bind(crypto.randomUUID(),now,now,claimId,eventId,claimId,now);
}

// The cycle token prevents a delayed receipt from an earlier snooze/pairing
// from suppressing a new alarm. A receipt confirms scheduling, never a wrist tap.
export async function confirmAlarmScheduled(env:Env,device:Device,value:Record<string,unknown>,latency?:Latency) {
 requireRole(device,'parent');
 const episode=uuid(value.episodeId),cycle=uuid(value.cycleId),event=uuid(value.eventId),now=Date.now();
 if(latency)try{latency.eventRef=await eventReference(env,event);}catch{/* Best effort correlation. */}
 const result=await env.DB.prepare(`UPDATE silent_alarm_cycles SET confirmed_at=COALESCE(confirmed_at,?)
  WHERE parent_id=? AND episode_id=? AND cycle_id=?
  AND EXISTS(SELECT 1 FROM pairs p JOIN devices household ON household.id=p.parent_id JOIN devices d ON d.id=silent_alarm_cycles.parent_id
   WHERE p.listener_id=silent_alarm_cycles.listener_id
   AND (p.parent_id=d.id OR EXISTS(SELECT 1 FROM caregiver_families f WHERE f.owner_id=p.parent_id AND f.partner_id=d.id AND f.pair_created_at=p.created_at))
   AND p.created_at=silent_alarm_cycles.pair_created_at AND d.silent_watch_alarms=1
   AND household.alerts_muted_until=silent_alarm_cycles.cycle_at AND household.alerts_muted_until<=?)
  AND EXISTS(SELECT 1 FROM events e WHERE e.event_id=? AND (e.parent_id=silent_alarm_cycles.parent_id OR EXISTS(SELECT 1 FROM caregiver_families f WHERE f.owner_id=e.parent_id AND f.partner_id=silent_alarm_cycles.parent_id AND f.pair_created_at=silent_alarm_cycles.pair_created_at))
   AND e.listener_id=silent_alarm_cycles.listener_id AND e.episode_id=silent_alarm_cycles.episode_id
   AND e.event_id IN (SELECT value FROM json_each(silent_alarm_cycles.request_event_ids))
   AND e.acknowledged_at IS NULL AND e.resolved_at IS NULL AND COALESCE(json_extract(e.payload,'$.isTest'),0)=0)
  RETURNING cycle_id`).bind(now,device.id,episode,cycle,now,event).first();
 if(!result)throw new APIError(409,'Alarm scheduling cycle is no longer current.');
 return {ok:true};
}

// Device-reported AlarmKit attempts by either method, so delivery methods can be
// compared without pulling files from the phone. Diagnostics only: this never
// changes alert, alarm or receipt state. Each attempt becomes one bounded row.
export const maximumAlarmAttempts=20;
export async function recordAlarmAttempts(env:Env,device:Device,value:Record<string,unknown>,requestId:string) {
 requireRole(device,'parent');
 if(!Array.isArray(value.attempts)||value.attempts.length>maximumAlarmAttempts)throw new APIError(400,'Invalid alarm attempts.');
 const attempts=value.attempts.map(item=>alarmAttempt(item)).filter(item=>item!==null);
 // One storage round trip: each row keeps its event reference only for this Parent's own events.
 const references=await eventReferences(env,attempts.map(item=>item.eventId??''));
 const recorded=await recordDiagnostics(env,attempts.map(({eventId,started,details},index)=>({requestId,operation:'alarm_attempt' as const,stage:'handler' as const,
  outcome:'ok' as const,started,details:{alarm_attempt:details},...(eventId?{eventRef:references[index],owner:{eventId,parentId:device.id}}:{})})));
 return {ok:true,recorded,ignored:value.attempts.length-attempts.length};
}
function alarmAttempt(item:unknown):{eventId?:string;started:number;details:AlarmAttemptDetails}|null {
 if(!item||typeof item!=='object')return null;
 const v=item as Record<string,unknown>;
 if(!['app','extension'].includes(v.method as string)||!['scheduled','duplicate','rejected','failed','stopped','timed_out'].includes(v.outcome as string))return null;
 const ms=(n:unknown,max=3_600_000)=>typeof n==='number'&&Number.isFinite(n)&&n>=-max&&n<=max?Math.round(n):undefined;
 const flag=(b:unknown)=>typeof b==='boolean'?b:undefined;
 let eventId:string|undefined;
 try{eventId=v.eventId===undefined?undefined:uuid(v.eventId);}catch{return null;}
 const startedAt=typeof v.startedAtMs==='number'&&Number.isFinite(v.startedAtMs)?v.startedAtMs:Date.now();
 const details:AlarmAttemptDetails={method:v.method as AlarmAttemptDetails['method'],outcome:v.outcome as AlarmAttemptDetails['outcome'],
  reason:typeof v.reason==='string'&&/^[a-z_+]{1,64}$/.test(v.reason)?v.reason:undefined,test:flag(v.test),
  flags:Array.isArray(v.flags)?v.flags.filter(f=>f==='wake'||f==='extension'):undefined,
  push_to_start_ms:ms(v.pushToStartMs),handler_ms:ms(v.handlerMs),push_to_alarm_ms:ms(v.pushToAlarmMs),
  snapshot_age_ms:ms(v.snapshotAgeMs,90*86_400_000),evidence_applied:flag(v.evidenceApplied),
  charging:flag(v.charging),battery_pct:typeof v.batteryPct==='number'&&v.batteryPct>=0&&v.batteryPct<=100?Math.round(v.batteryPct):undefined,
  low_power:flag(v.lowPower),app_active:flag(v.appActive),protected_data:flag(v.protectedData),
  started_at_ms:startedAt>=0&&startedAt<=1e15?Math.round(startedAt):undefined};
 // `started` sets the row's elapsed_ms: time from the attempt to this upload.
 return {eventId,started:Math.min(Date.now(),Math.max(0,startedAt)),details};
}
