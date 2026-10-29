import {eventReference} from './diagnostics';
import type {Latency} from './latency';
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
  AND EXISTS(SELECT 1 FROM pairs p JOIN devices d ON d.id=p.parent_id
   WHERE p.parent_id=silent_alarm_cycles.parent_id AND p.listener_id=silent_alarm_cycles.listener_id
   AND p.created_at=silent_alarm_cycles.pair_created_at AND d.silent_watch_alarms=1
   AND d.alerts_muted_until=silent_alarm_cycles.cycle_at AND d.alerts_muted_until<=?)
  AND EXISTS(SELECT 1 FROM events e WHERE e.event_id=? AND e.parent_id=silent_alarm_cycles.parent_id
   AND e.listener_id=silent_alarm_cycles.listener_id AND e.episode_id=silent_alarm_cycles.episode_id
   AND e.event_id IN (SELECT value FROM json_each(silent_alarm_cycles.request_event_ids))
   AND e.acknowledged_at IS NULL AND e.resolved_at IS NULL AND COALESCE(json_extract(e.payload,'$.isTest'),0)=0)
  RETURNING cycle_id`).bind(now,device.id,episode,cycle,now,event).first();
 if(!result)throw new APIError(409,'Alarm scheduling cycle is no longer current.');
 return {ok:true};
}
