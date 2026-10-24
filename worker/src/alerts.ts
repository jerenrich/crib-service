import {stoppedMonitoringSQL} from './monitoring';
import {scheduleReminders} from './reminders';
import {APIError,requireRole,type Alert,type Device,type Env,type StoredEvent} from './types';
import {alert as validateAlert,uuid,configuration} from './security';
import {pairFor} from './devices';
import {sendPush,type PushResult} from './apns';
import {eventReference,recordDiagnostic,PushPreparationError,type Outcome,type Stage} from './diagnostics';
export async function receiveAlert(env:Env,device:Device,value:Record<string,unknown>,requestId=crypto.randomUUID()) {
 requireRole(device,'listener');const alert=validateAlert(value);
 if(alert.listenerId!==device.id)throw new APIError(403,'Listener identity mismatch.');
 const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Listener is not paired.');
 if(Date.parse(alert.createdAt)<pair.created_at-2000)throw new APIError(409,'Alert belongs to an earlier pairing.');
 const previous=await env.DB.prepare('SELECT * FROM events WHERE event_id=?').bind(alert.eventId).first<StoredEvent>();
 if(previous){
  if(previous.listener_id!==device.id||previous.payload!==JSON.stringify(alert))throw new APIError(409,'Event UUID already used for different metadata.');
 }else{
  // Unique index also prevents a buggy client creating another initial UUID for an episode.
  await env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at) SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?) ON CONFLICT DO NOTHING')
   .bind(alert.eventId,alert.episodeId,device.id,pair.parent_id,Number(alert.isRepeat),JSON.stringify(alert),Date.now(),pair.parent_id,pair.listener_id,pair.created_at).run();
 }
 let record=await env.DB.prepare('SELECT * FROM events WHERE event_id=?').bind(alert.eventId).first<StoredEvent>();
 if(record && (record.listener_id!==device.id || record.payload!==JSON.stringify(alert)))throw new APIError(409,'Event UUID already used for different metadata.');
 if(!record){
  record=await env.DB.prepare('SELECT * FROM events WHERE listener_id=? AND episode_id=? AND is_repeat=0').bind(device.id,alert.episodeId).first<StoredEvent>();
 }
 if(!record)throw new APIError(409,'Event conflict.');
 // Older Listeners also use server reminders.
 if(!alert.isTest)await scheduleReminders(env,pair.parent_id);
 await dispatchEvent(env,record.event_id,requestId);
 const result=await env.DB.prepare('SELECT status,acknowledged_at FROM events WHERE event_id=?').bind(record.event_id).first<{status:string;acknowledged_at:string|null}>();
 return {status:result?.acknowledged_at?'acknowledged':result?.status??'pending'};
}
export async function dispatchEvent(env:Env,eventId:string,requestId=crypto.randomUUID()):Promise<void> {
 const now=Date.now();
 let stage:Stage='claim',eventRef:string|undefined,attempt:number|undefined,target:'phone'|'watch'|undefined;
 const record=(outcome:Outcome,httpStatus?:number)=>recordDiagnostic(env,{requestId,started:now,operation:'dispatch',stage,outcome,eventRef,attempt,target,httpStatus});
 try {
 // Diagnostic computation is best effort, just like journal writes.
 try { eventRef=await eventReference(env,eventId); } catch { /* No diagnostic identity available. */ }
 // Suppress uploads during a mute, including delayed offline outbox entries.
 await env.DB.prepare(`UPDATE events SET acknowledged_at=COALESCE(acknowledged_at,?) WHERE event_id=?
 AND COALESCE(json_extract(payload,'$.isTest'),0)=0 AND (
 EXISTS(SELECT 1 FROM devices d WHERE d.id=events.parent_id AND d.alerts_muted_until>0
 AND (d.alerts_muted_until>? OR CAST((julianday(json_extract(events.payload,'$.createdAt'))-2440587.5)*86400000 AS INTEGER) BETWEEN d.alerts_muted_at AND d.alerts_muted_until))
 OR EXISTS(SELECT 1 FROM alert_snoozes s JOIN pairs p ON p.parent_id=s.parent_id AND p.listener_id=s.listener_id AND p.created_at=s.pair_created_at
 WHERE s.parent_id=events.parent_id AND s.listener_id=events.listener_id
 AND CAST(ROUND((julianday(json_extract(events.payload,'$.createdAt'))-2440587.5)*86400000) AS INTEGER) BETWEEN s.started_at AND s.until_at)
 OR ${stoppedMonitoringSQL}
 OR EXISTS(SELECT 1 FROM monitoring_commands m JOIN pairs p ON p.parent_id=m.parent_id AND p.listener_id=m.listener_id AND p.created_at=m.pair_created_at
 WHERE m.parent_id=events.parent_id AND m.listener_id=events.listener_id AND m.enabled=0
 AND CAST(ROUND((julianday(json_extract(events.payload,'$.createdAt'))-2440587.5)*86400000) AS INTEGER)<=m.created_at)
 OR (is_repeat=1 AND EXISTS(SELECT 1 FROM events prior WHERE prior.parent_id=events.parent_id AND prior.episode_id=events.episode_id AND prior.acknowledged_at IS NOT NULL AND prior.created_at>=events.created_at))
 )`).bind(new Date(now).toISOString(),eventId,now,now).run();
 const event=await env.DB.prepare("UPDATE events SET status='sending',lease_until=?,attempts=attempts+1,push_target=COALESCE(push_target,CASE WHEN (SELECT watch_push_token FROM devices WHERE id=events.parent_id) IS NOT NULL THEN 'watch' ELSE 'phone' END) WHERE event_id=? AND status='pending' AND acknowledged_at IS NULL AND next_attempt<=? RETURNING *").bind(now+30000,eventId,now).first<StoredEvent>();
 if(!event)return;
 attempt=event.attempts;target=event.push_target??'phone';stage='storage';
 // No replay after uncertain transport or a worker death during APNs dispatch. APNs does
 // not offer an exactly-once receipt transaction with D1. Surface uncertainty explicitly.
 if(now-Date.parse((JSON.parse(event.payload) as Alert).createdAt)>86400000){
  await env.DB.prepare("UPDATE events SET status='failed',last_error='expired_event',lease_until=NULL WHERE event_id=?").bind(eventId).run();await record('expired_event');return;
 }
 const column=target==='watch'?'watch_push_token':'push_token';
 const parent=await env.DB.prepare(`SELECT ${column} AS token FROM devices WHERE id=?`).bind(event.parent_id).first<{token:string|null}>();
 if(!parent?.token){
  // A token upload can race with this read. Decide blocked/pending in the same
  // database statement that releases the claim, so either ordering can recover.
  await env.DB.prepare("UPDATE events SET status=CASE WHEN EXISTS(SELECT 1 FROM devices WHERE id=parent_id AND (push_token IS NOT NULL OR watch_push_token IS NOT NULL)) THEN 'pending' ELSE 'blocked' END,last_error='no_push_token',lease_until=NULL,push_target=NULL WHERE event_id=? AND status='sending'").bind(eventId).run();await record('no_push_token');return;
 }
 stage='push';
 let result:PushResult;
 try{result=await sendPush(env,parent.token,JSON.parse(event.payload) as Alert,target);}
 catch(error){result={status:'retry',reason:error instanceof PushPreparationError?error.code:'apns_configuration'};}
 const status=result.status==='retry'?'pending':result.status;
 const next=now+Math.min(300000,2000*2**Math.min(event.attempts,8));
 stage='storage';
 if(result.reason==='invalid_device_token'){
  // Atomically invalidate only the rejected token and release the event. A
  // replacement uploaded during APNs dispatch must remain eligible for retry.
  await env.DB.batch([
   env.DB.prepare(`UPDATE devices SET ${column}=NULL WHERE id=? AND ${column}=?`).bind(event.parent_id,parent.token),
   env.DB.prepare("UPDATE events SET status=CASE WHEN EXISTS(SELECT 1 FROM devices WHERE id=parent_id AND (push_token IS NOT NULL OR watch_push_token IS NOT NULL)) THEN 'pending' ELSE 'blocked' END,next_attempt=0,lease_until=NULL,push_target=NULL,last_error=? WHERE event_id=? AND status='sending'").bind(result.reason,eventId)
  ]);
  await record(result.reason,result.httpStatus);
  return;
 }
 await env.DB.prepare('UPDATE events SET status=?,next_attempt=?,lease_until=NULL,sent_at=?,last_error=? WHERE event_id=? AND status=\'sending\'')
  .bind(status,next,status==='sent'?new Date().toISOString():null,result.reason??null,eventId).run();
 await record(result.reason??result.status,result.httpStatus);
 } catch(error) { await record('internal_error');throw error; }
}
export async function acknowledge(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');const id=uuid(value.eventId);
 const event=await env.DB.prepare('SELECT * FROM events WHERE event_id=? AND parent_id=?').bind(id,device.id).first<StoredEvent>();
 if(!event)throw new APIError(404,'Alert not found.');
 if(event.acknowledged_at){
  if(!(JSON.parse(event.payload) as Alert).isTest)await scheduleReminders(env,device.id);
  return {ok:true};
 }
 const now=Date.now(),timestamp=new Date(now).toISOString();
 const pair=await pairFor(env,device);if(!pair||pair.listener_id!==event.listener_id)throw new APIError(409,'Pairing changed.');
 const isTest=(JSON.parse(event.payload) as Alert).isTest===true;
 const until=now+configuration(JSON.parse(device.config)).snoozeDuration*1000;
 const journalEvent={id:`ack:${id}`,kind:isTest?'test_acknowledged':'alert_acknowledged',occurredAt:timestamp,episodeID:event.episode_id,
  ...(isTest?{}:{endAt:new Date(until).toISOString()})};
 const journal=env.DB.prepare(`INSERT INTO timeline_events(id,parent_id,listener_id,pair_created_at,kind,occurred_at,payload)
  SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?)
  AND EXISTS(SELECT 1 FROM events WHERE event_id=? AND acknowledged_at IS NULL) ON CONFLICT DO NOTHING`)
  .bind(journalEvent.id,pair.parent_id,pair.listener_id,pair.created_at,journalEvent.kind,now,JSON.stringify(journalEvent),pair.parent_id,pair.listener_id,pair.created_at,id);
 if(isTest) {
  await env.DB.batch([journal,env.DB.prepare(`UPDATE events SET acknowledged_at=COALESCE(acknowledged_at,?) WHERE event_id=? AND parent_id=?
   AND EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?)`)
   .bind(timestamp,id,device.id,pair.parent_id,pair.listener_id,pair.created_at)]);
 }else{
  const claim=crypto.randomUUID();
  // A unique request claim gates every side effect in the same D1 transaction.
  // A duplicate or a request overtaken by unpairing cannot affect newer alerts.
  await env.DB.batch([
   env.DB.prepare(`INSERT INTO alert_snoozes(event_id,claim_id,parent_id,listener_id,pair_created_at,started_at,until_at)
    SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?)
    AND EXISTS(SELECT 1 FROM events WHERE event_id=? AND parent_id=? AND listener_id=? AND acknowledged_at IS NULL)
    ON CONFLICT DO NOTHING`).bind(id,claim,device.id,pair.listener_id,pair.created_at,now,until,pair.parent_id,pair.listener_id,pair.created_at,id,device.id,pair.listener_id),
   env.DB.prepare(`UPDATE devices SET alerts_muted_until=?,alerts_muted_at=? WHERE id=?
    AND EXISTS(SELECT 1 FROM alert_snoozes WHERE event_id=? AND claim_id=?)`).bind(until,now,device.id,id,claim),
   journal,
   env.DB.prepare(`UPDATE events SET acknowledged_at=COALESCE(acknowledged_at,?) WHERE parent_id=? AND listener_id=?
    AND COALESCE(json_extract(payload,'$.isTest'),0)=0
    AND EXISTS(SELECT 1 FROM alert_snoozes WHERE event_id=? AND claim_id=?)`).bind(timestamp,device.id,pair.listener_id,id,claim)
  ]);
  await scheduleReminders(env,device.id);
 }
 return {ok:true};
}
// End only the snooze the user saw. A delayed retry must not cancel a newer snooze.
export async function resumeAlerts(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');
 const expected=value.expectedUntil;
 if(typeof expected!=='number'||!Number.isSafeInteger(expected)||expected<=0)throw new APIError(400,'A valid snooze deadline is required.');
 const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Pair a Listener first.');
 const now=Date.now();
 const guardSQL=`EXISTS(SELECT 1 FROM devices d JOIN pairs p ON p.parent_id=d.id
  WHERE d.id=? AND d.alerts_muted_until=? AND p.listener_id=? AND p.created_at=?)`;
 const scope=[device.id,expected,pair.listener_id,pair.created_at];
 await env.DB.batch([
  // Retain the actual muted interval so delayed uploads from that interval stay silent.
  env.DB.prepare(`UPDATE timeline_events SET payload=json_set(payload,'$.endAt',?)
   WHERE parent_id=? AND listener_id=? AND pair_created_at=? AND kind='alert_acknowledged'
   AND id IN (SELECT 'ack:'||event_id FROM alert_snoozes WHERE parent_id=? AND until_at>?)
   AND ${guardSQL}`).bind(new Date(now).toISOString(),device.id,pair.listener_id,pair.created_at,device.id,now,...scope),
  env.DB.prepare(`UPDATE alert_snoozes SET until_at=? WHERE parent_id=? AND listener_id=? AND pair_created_at=? AND until_at>?
   AND ${guardSQL}`).bind(now,device.id,pair.listener_id,pair.created_at,now,...scope),
  // Keep a nonzero deadline: the reminder loop can resume a freshly confirmed ongoing cry.
  env.DB.prepare(`UPDATE devices SET alerts_muted_until=? WHERE id=? AND alerts_muted_until>? AND ${guardSQL}`)
   .bind(now,device.id,now,...scope)
 ]);
 await scheduleReminders(env,device.id);
 return {ok:true};
}
export async function flushPending(env:Env,requestId=crypto.randomUUID()) {
 // Expire diagnostic data before delivery work so a broken push path cannot defer expiry.
 try { await env.DB.prepare('DELETE FROM diagnostics WHERE recorded_at<?').bind(Date.now()-7*86400000).run(); }
 catch { await recordDiagnostic(env,{requestId,started:Date.now(),operation:'maintenance',stage:'cleanup',outcome:'diagnostic_cleanup_failed'}); }
 const interrupted=await env.DB.prepare("UPDATE events SET status='uncertain',last_error='dispatch_interrupted',lease_until=NULL WHERE status='sending' AND lease_until<? RETURNING event_id,attempts,push_target").bind(Date.now()).all<{event_id:string;attempts:number;push_target:'phone'|'watch'|null}>();
 for(const event of interrupted.results) {
  let eventRef:string|undefined;try {eventRef=await eventReference(env,event.event_id);}catch{/* Best effort. */}
  await recordDiagnostic(env,{requestId,started:Date.now(),operation:'dispatch',stage:'claim',outcome:'dispatch_interrupted',eventRef,attempt:event.attempts,target:event.push_target??undefined});
 }
 const events=await env.DB.prepare("SELECT event_id FROM events WHERE status='pending' AND acknowledged_at IS NULL AND next_attempt<=? ORDER BY created_at LIMIT 25").bind(Date.now()).all<{event_id:string}>();
 // Bounded fan-out; each row has an atomic database claim.
 for(let index=0;index<events.results.length;index+=5){await Promise.all(events.results.slice(index,index+5).map(event=>dispatchEvent(env,event.event_id,requestId)));}
 // Keep deduplication tombstones for 30 days. Codes are short-lived; claimed codes retain
 // enough time to recover a lost claim response. Status metadata retains max 100 episodes.
 await env.DB.batch([
  env.DB.prepare('DELETE FROM monitoring_commands WHERE created_at<? AND sequence NOT IN (SELECT MAX(sequence) FROM monitoring_commands GROUP BY parent_id,listener_id,pair_created_at)').bind(Date.now()-30*86400000),
  env.DB.prepare('DELETE FROM alert_snoozes WHERE until_at<?').bind(Date.now()-86400000),
  env.DB.prepare(`DELETE FROM timeline_events WHERE occurred_at<? AND id NOT IN (SELECT id FROM timeline_events t2 WHERE t2.parent_id=timeline_events.parent_id AND t2.listener_id=timeline_events.listener_id AND t2.pair_created_at=timeline_events.pair_created_at AND t2.kind IN ('coverage_active','coverage_stopped') ORDER BY occurred_at DESC LIMIT 1)`).bind(Date.now()-24*3600000),
  env.DB.prepare('DELETE FROM events WHERE created_at<?').bind(Date.now()-30*86400000),
  env.DB.prepare('DELETE FROM pairing_codes WHERE expires_at<?').bind(Date.now()-86400000),
  env.DB.prepare('DELETE FROM rate_limits WHERE window<?').bind(Math.floor(Date.now()/1000/600)-144)
 ]);
}
