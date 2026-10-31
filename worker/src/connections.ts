import {sharedAccess} from './devices';
import {dispatchEvent} from './alerts';
import {scheduleReminders} from './reminders';
import {deliverToBoth} from './dual-delivery';
import {timelineInsert,missingHeartbeat} from './timeline';
import {APIError,requireRole,type Alert,type Device,type Env} from './types';
import {sendConnectionPush,type PushResult} from './apns';
import {eventReference,recordDiagnostic,PushPreparationError,type Stage,type Outcome} from './diagnostics';
import {Latency} from './latency';

export async function connectionPreferences(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');
 if(typeof value.enabled!=='boolean'||Object.keys(value).some(k=>k!=='enabled'))throw new APIError(400,'Choose whether to enable connection alerts.');
 const access=sharedAccess(device);
 await env.DB.batch([
  env.DB.prepare(`UPDATE devices SET connection_alerts=? WHERE id=? AND ${access.sql}`).bind(Number(value.enabled),device.id,...access.args),
  env.DB.prepare(`UPDATE connection_notices SET status='cancelled' WHERE parent_id=? AND status IN ('pending','blocked','escalated') AND ?=0 AND ${access.sql}`).bind(device.id,Number(value.enabled),...access.args),
  env.DB.prepare(`DELETE FROM connection_notices WHERE parent_id=? AND state='offline' AND status='cancelled' AND ?=1 AND ${access.sql}`).bind(device.id,Number(value.enabled),...access.args),
  env.DB.prepare(`UPDATE events SET resolved_at=COALESCE(resolved_at,?) WHERE parent_id=? AND resolved_at IS NULL AND json_extract(payload,'$.type')='listener_disconnected' AND ?=0 AND ${access.sql}`).bind(new Date().toISOString(),device.id,Number(value.enabled),...access.args)
 ]);
 return {ok:true};
}

// Cron owns connection health, independently of either app being foregrounded.
// Atomic transition + unique notice key prevents duplicate notices across cron runs.
export async function flushConnections(env:Env,requestId=crypto.randomUUID()) {
 const now=Date.now();
 const rows=await env.DB.prepare(`SELECT p.parent_id,p.listener_id,h.received_at,h.metadata,s.state,p.created_at AS pair_created_at
 FROM pairs p JOIN heartbeats h ON h.listener_id=p.listener_id
 LEFT JOIN connection_states s ON s.listener_id=p.listener_id`).all<{parent_id:string;listener_id:string;received_at:string;metadata:string;state:string|null;pair_created_at:number}>();
 for(const row of rows.results){
  const active=JSON.parse(row.metadata).monitoring===true;
  const state=active?(now-Date.parse(row.received_at)>180000?'offline':'online'):'stopped';
  // Never warn about a device which has not started monitoring.
  if(!row.state){
   if(active)await env.DB.prepare("INSERT INTO connection_states(listener_id,state,changed_at) SELECT ?,'online',? WHERE EXISTS(SELECT 1 FROM pairs p JOIN heartbeats h ON h.listener_id=p.listener_id WHERE p.parent_id=? AND p.listener_id=? AND h.received_at=?) ON CONFLICT DO NOTHING").bind(row.listener_id,row.received_at,row.parent_id,row.listener_id,row.received_at).run();
   continue;
  }
  if(state==='offline')await timelineInsert(env,{parent_id:row.parent_id,listener_id:row.listener_id,created_at:row.pair_created_at},missingHeartbeat(row.received_at)).run();
  if(state===row.state&&state!=='offline')continue;
  await env.DB.batch([
   env.DB.prepare(`INSERT INTO connection_notices(id,listener_id,parent_id,state,observed_at,created_at)
    SELECT ?,?,?,?, ?,? FROM devices d JOIN pairs p ON p.parent_id=d.id
    JOIN connection_states s ON s.listener_id=p.listener_id JOIN heartbeats h ON h.listener_id=p.listener_id
    WHERE p.listener_id=? AND d.id=? AND d.connection_alerts=1 AND s.state=? AND h.received_at=? AND ?<>'online'
    AND (?<>'stopped' OR NOT EXISTS(SELECT 1 FROM events e WHERE e.parent_id=p.parent_id AND e.listener_id=p.listener_id
     AND e.resolved_at IS NULL AND json_extract(e.payload,'$.type')='monitoring_failed')) ON CONFLICT DO NOTHING`)
    .bind(crypto.randomUUID(),row.listener_id,row.parent_id,state,row.received_at,now,row.listener_id,row.parent_id,row.state,row.received_at,state,state),
   env.DB.prepare('UPDATE connection_states SET state=?,changed_at=? WHERE listener_id=? AND state=? AND EXISTS(SELECT 1 FROM heartbeats h WHERE h.listener_id=connection_states.listener_id AND h.received_at=?)').bind(state,row.received_at,row.listener_id,row.state,row.received_at)
  ]);
 }
 // Promote each outage into the ordinary persistent alert pipeline. The notice
 // UUID is the episode/idempotency key; cron retries never create a new episode.
 // Include sent legacy notices so an existing outage gains persistent reminders.
 const outages=await env.DB.prepare(`SELECT n.* FROM connection_notices n
  JOIN pairs p ON p.parent_id=n.parent_id AND p.listener_id=n.listener_id
  JOIN devices d ON d.id=p.parent_id JOIN heartbeats h ON h.listener_id=p.listener_id
  WHERE n.state='offline' AND n.status<>'cancelled' AND n.created_at>=p.created_at
   AND (n.status<>'escalated' OR NOT EXISTS(SELECT 1 FROM events e WHERE e.event_id=n.id))
   AND d.connection_alerts=1 AND json_extract(h.metadata,'$.monitoring')=1
   AND h.received_at=n.observed_at AND h.received_at<?
  ORDER BY n.created_at LIMIT 25`).bind(new Date(now-180000).toISOString())
  .all<{id:string;parent_id:string;listener_id:string;observed_at:string;created_at:number}>();
 for(const outage of outages.results){
  // Retain the shared wire shape for older clients: for this type, the start
  // is the last heartbeat and duration is the detection timeout, not crying.
  const event:Alert={eventId:outage.id,episodeId:outage.id,listenerId:outage.listener_id,
   type:'listener_disconnected',cryStartedAt:outage.observed_at,durationSeconds:180,
   createdAt:new Date(now).toISOString(),isRepeat:false};
  await env.DB.batch([
   env.DB.prepare(`INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at)
    SELECT ?,?,?,?,0,?,? WHERE EXISTS(SELECT 1 FROM pairs p JOIN devices d ON d.id=p.parent_id
     JOIN heartbeats h ON h.listener_id=p.listener_id WHERE p.parent_id=? AND p.listener_id=?
     AND p.created_at<=? AND d.connection_alerts=1 AND h.received_at=? AND json_extract(h.metadata,'$.monitoring')=1)
    ON CONFLICT DO NOTHING`).bind(event.eventId,event.episodeId,event.listenerId,outage.parent_id,JSON.stringify(event),now,
     outage.parent_id,outage.listener_id,outage.created_at,outage.observed_at),
   env.DB.prepare("UPDATE connection_notices SET status='escalated',lease_until=NULL WHERE id=? AND status<>'cancelled'").bind(outage.id)
  ]);
  // Always repair the timer, including after a failed first send or a snooze.
  try {await dispatchEvent(env,outage.id,requestId);}
  finally {await scheduleReminders(env,outage.parent_id);}
 }
 // Retire obsolete outage episodes before pending/recovery work can deliver them.
 await env.DB.prepare(`UPDATE events SET resolved_at=COALESCE(resolved_at,?)
  WHERE resolved_at IS NULL AND json_extract(payload,'$.type')='listener_disconnected' AND NOT EXISTS(
   SELECT 1 FROM pairs p JOIN devices d ON d.id=p.parent_id JOIN heartbeats h ON h.listener_id=p.listener_id
   WHERE p.parent_id=events.parent_id AND p.listener_id=events.listener_id AND d.connection_alerts=1
    AND json_extract(h.metadata,'$.monitoring')=1 AND h.received_at=json_extract(events.payload,'$.cryStartedAt')
    AND h.received_at<?)`).bind(new Date(now).toISOString(),new Date(now-180000).toISOString()).run();
 await env.DB.prepare(`UPDATE connection_notices SET status='cancelled',lease_until=NULL WHERE state='offline'
  AND NOT EXISTS(SELECT 1 FROM pairs p JOIN devices d ON d.id=p.parent_id JOIN heartbeats h ON h.listener_id=p.listener_id
   WHERE p.parent_id=connection_notices.parent_id AND p.listener_id=connection_notices.listener_id
    AND d.connection_alerts=1 AND json_extract(h.metadata,'$.monitoring')=1
    AND h.received_at=connection_notices.observed_at AND h.received_at<?)`)
  .bind(new Date(now-180000).toISOString()).run();
 // Recovery updates status/history quietly, including notices queued by older versions.
 await env.DB.prepare("UPDATE connection_notices SET status='cancelled',lease_until=NULL WHERE state='online' AND status IN ('pending','blocked')").run();
 const bothAccepted="delivery_state IS NOT NULL AND json_extract(delivery_state,'$.phone')='sent' AND json_extract(delivery_state,'$.watch')='sent'";
 const interrupted=await env.DB.prepare(`UPDATE connection_notices SET status=CASE WHEN ${bothAccepted} THEN 'sent' ELSE 'uncertain' END,
  sent_at=CASE WHEN ${bothAccepted} THEN COALESCE(sent_at,?) ELSE sent_at END,lease_until=NULL
  WHERE state<>'offline' AND status='sending' AND lease_until<? RETURNING id,attempts,status`).bind(new Date(now).toISOString(),now).all<{id:string;attempts:number;status:string}>();
 for(const notice of interrupted.results){
  let eventRef:string|undefined;try{eventRef=await eventReference(env,notice.id);}catch{/* Best effort. */}
  await recordDiagnostic(env,{requestId,started:now,operation:notice.status==='sent'?'dispatch_outcome':'dispatch',stage:'claim',outcome:notice.status==='sent'?'sent':'dispatch_interrupted',eventRef,attempt:notice.attempts,details:{dispatch_source:'connection'}});
 }
 const pending=await env.DB.prepare(`SELECT n.id FROM connection_notices n WHERE n.state<>'offline' AND n.status IN ('pending','blocked') AND n.next_attempt<=? ORDER BY n.created_at LIMIT 25`).bind(now).all<{id:string}>();
 for(const {id} of pending.results){
  const started=Date.now(),latency=new Latency();latency.details.dispatch_source='connection';
  let stage:Stage='claim',eventRef:string|undefined,attempt:number|undefined,target:'phone'|'watch'|undefined,result:PushResult|undefined;
  try{eventRef=await eventReference(env,id);}catch{/* Best effort. */}
  const record=(outcome:Outcome,operation:'dispatch'|'dispatch_skip'='dispatch')=>recordDiagnostic(env,{requestId,started,operation,stage,outcome,eventRef,target,httpStatus:result?.httpStatus,attempt,details:latency.details});
  try {
  const claimNow=Date.now();
  const notice=await latency.read<{id:string;parent_id:string;listener_id:string;state:string;created_at:number;attempts:number;lease_until:number;delivery_state:string|null}>('claim_ms',env.DB.prepare(`UPDATE connection_notices SET status='sending',lease_until=?,attempts=attempts+1,delivery_state=COALESCE(delivery_state,CASE WHEN EXISTS(SELECT 1 FROM devices WHERE id=connection_notices.parent_id AND push_token IS NOT NULL AND watch_push_token IS NOT NULL) THEN '{"phone":"pending","watch":"pending"}' ELSE NULL END) WHERE id=? AND status IN ('pending','blocked') AND next_attempt<=? RETURNING *`)
   .bind(claimNow+30000,id,claimNow));
  if(!notice){latency.details.exit_reason='not_pending';await record('claim_skipped','dispatch_skip');continue;}
  attempt=notice.attempts;stage='storage';
  const context=await latency.read<{push_token:string|null;watch_push_token:string|null;connection_alerts:number;received_at:string;metadata:string}>('destination_ms',env.DB.prepare(`SELECT d.push_token,d.watch_push_token,d.connection_alerts,h.received_at,h.metadata
   FROM pairs p JOIN devices d ON d.id=p.parent_id JOIN heartbeats h ON h.listener_id=p.listener_id
   WHERE p.parent_id=? AND p.listener_id=?`).bind(notice.parent_id,notice.listener_id)
   );
  const dispatchNow=Date.now();
  if(notice.lease_until<=dispatchNow){
   // No APNs call has started. Release only this still-owned attempt so a
   // delayed database reply does not discard a known-unsent warning.
   await latency.db('outcome_storage_ms',()=>env.DB.prepare("UPDATE connection_notices SET status='pending',lease_until=NULL,next_attempt=? WHERE id=? AND status='sending' AND attempts=? AND lease_until<=?")
    .bind(dispatchNow+4000,id,notice.attempts,dispatchNow).run());
   latency.details.exit_reason='not_pending';await record('claim_skipped','dispatch_skip');continue;
  }
  const current=context?(JSON.parse(context.metadata).monitoring===true?(dispatchNow-Date.parse(context.received_at)>180000?'offline':'online'):'stopped'):null;
  if((notice.state!=='offline'&&notice.state!=='stopped')||!context?.connection_alerts||current!==notice.state||dispatchNow-notice.created_at>600000){
   await latency.db('outcome_storage_ms',()=>env.DB.prepare("UPDATE connection_notices SET status='cancelled',lease_until=NULL WHERE id=? AND status='sending' AND attempts=?").bind(id,notice.attempts).run());
   await record('notice_cancelled','dispatch_skip');continue;
  }
  if(notice.delivery_state){
   const state=await deliverToBoth(env,{table:'connection_notices',id,parentId:notice.parent_id,attempt:notice.attempts,
    state:notice.delivery_state,phoneToken:context.push_token,watchToken:context.watch_push_token,
    requestId,eventRef,source:'connection',send:(destination,token,timing)=>sendConnectionPush(env,token,id,notice.state as 'offline'|'stopped',destination,timing)});
   latency.details.push_outcome=state==='pending'?'retry':state;
   await recordDiagnostic(env,{requestId,started,operation:'dispatch_outcome',stage:'storage',eventRef,attempt,
    outcome:state==='pending'?'retry':state,details:latency.details});
   continue;
  }
  target=context.watch_push_token?'watch':'phone';const token=context.watch_push_token??context.push_token;
  result={status:'blocked',reason:'no_push_token'};stage='push';
  if(token){try{result=await sendConnectionPush(env,token,id,notice.state,target,latency);}catch(error){latency.failure(error);result={status:'retry',reason:error instanceof PushPreparationError?error.code:'apns_configuration'};}}
  latency.details.push_outcome=result.status;stage='storage';const push=result;
  if(result.reason==='invalid_device_token'&&token){
   const column=target==='watch'?'watch_push_token':'push_token';
   await latency.db('outcome_storage_ms',()=>env.DB.batch([
    env.DB.prepare(`UPDATE devices SET ${column}=NULL WHERE id=? AND ${column}=?`).bind(notice.parent_id,token),
    env.DB.prepare("UPDATE connection_notices SET status='pending',next_attempt=?,lease_until=NULL WHERE id=? AND status='sending' AND attempts=?").bind(Date.now()+2000,id,notice.attempts)
   ]));
  } else {
   // Unknown acceptance is terminal; never replay it to another destination.
   await latency.db('outcome_storage_ms',()=>env.DB.prepare("UPDATE connection_notices SET status=?,next_attempt=?,lease_until=NULL,sent_at=CASE WHEN ?='sent' THEN ? ELSE sent_at END WHERE id=? AND status='sending' AND attempts=?")
    .bind(push.status==='retry'?'pending':push.status,Date.now()+Math.min(300000,2000*2**Math.min(notice.attempts,8)),push.status,new Date().toISOString(),id,notice.attempts).run());
  }
  await record(result.reason??result.status);
  }catch(error){latency.failure(error);await record('internal_error');throw error;}
 }
 await env.DB.prepare("DELETE FROM connection_notices WHERE (state<>'offline' OR status='cancelled') AND created_at<?").bind(now-7*86400000).run();
}
