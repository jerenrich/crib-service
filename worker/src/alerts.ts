import {reserveAlarmRequest} from './alarm-scheduling';
import {phoneHeadStartFor} from './notification-coordination';
import {deliverToBoth} from './dual-delivery';
import {acceptedDelivery,queueAcceptedDelivery,type AcceptedDelivery} from './accepted-delivery';
import {stoppedMonitoringSQL} from './monitoring';
import {scheduleReminders} from './reminders';
import {Latency} from './latency';
import {APIError,requireRole,type Alert,type Device,type Env,type StoredEvent} from './types';
import {alert as validateAlert,uuid,configuration} from './security';
import {pairFor} from './devices';
import {sendPush,sendSilentCryAlarmPush,type PushResult} from './apns';
import {eventReference,recordDiagnostic,observeLateWrites,PushPreparationError,type Outcome,type Stage} from './diagnostics';
export async function receiveAlert(env:Env,device:Device,value:Record<string,unknown>,requestId=crypto.randomUUID(),latency=new Latency(),background?:Pick<ExecutionContext,'waitUntil'>) {
 latency.details.dispatch_source='upload';
 const {alert,pair,record}=await latency.measure('alert_prepare_ms',async()=>{
 requireRole(device,'listener');const alert=validateAlert(value);
 if(alert.listenerId!==device.id)throw new APIError(403,'Listener identity mismatch.');
 try{latency.eventRef=await eventReference(env,alert.eventId);}catch{/* Best effort. */}
 // Both reads share one consistent snapshot and one remote call. The bounded
 // fallback is read-only; insertion and delivery claims are never hedged.
 type Pair={parent_id:string;listener_id:string;created_at:number};
 const snapshot=await latency.readOnly<StoredEvent|Pair>('alert_snapshot_ms',()=>env.DB.batch<StoredEvent|Pair>([
  env.DB.prepare('SELECT * FROM events WHERE event_id=?').bind(alert.eventId),
  env.DB.prepare('SELECT * FROM pairs WHERE listener_id=?').bind(device.id)
 ]),250);
 const previous=snapshot[0].results[0] as StoredEvent|undefined;
 const pair=snapshot[1].results[0] as Pair|undefined;if(!pair)throw new APIError(409,'Listener is not paired.');
 if(Date.parse(alert.createdAt)<pair.created_at-2000)throw new APIError(409,'Alert belongs to an earlier pairing.');
 let record:StoredEvent|null=previous??null;
 if(previous){
  if(previous.listener_id!==device.id||previous.payload!==JSON.stringify(alert))throw new APIError(409,'Event UUID already used for different metadata.');
 }else{
  // Reload in the insertion transaction, including the winner of an event/episode
  // conflict. The exact pairing guard still prevents an upload after re-pairing.
  const inserted=await latency.db<StoredEvent>('event_insert_ms',()=>env.DB.batch<StoredEvent>([
   env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at) SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?) ON CONFLICT DO NOTHING')
    .bind(alert.eventId,alert.episodeId,device.id,pair.parent_id,Number(alert.isRepeat),JSON.stringify(alert),Date.now(),pair.parent_id,pair.listener_id,pair.created_at),
   env.DB.prepare('SELECT * FROM events WHERE event_id=?').bind(alert.eventId)
  ]));
  record=inserted[1].results[0]??null;
 }
 if(record && (record.listener_id!==device.id || record.payload!==JSON.stringify(alert)))throw new APIError(409,'Event UUID already used for different metadata.');
 if(!record){
  record=await latency.read<StoredEvent>('event_episode_ms',env.DB.prepare('SELECT * FROM events WHERE listener_id=? AND episode_id=? AND is_repeat=0').bind(device.id,alert.episodeId));
 }
 if(!record)throw new APIError(409,'Event conflict.');
 if(record.event_id!==alert.eventId){try{latency.eventRef=await eventReference(env,record.event_id);}catch{latency.eventRef=undefined;}}
 return {alert,pair,record};
 });
 // Start durable scheduling independently of push delivery. The minute recovery
 // job repairs an interrupted or failed scheduling request from stored events.
 try {await dispatchEvent(env,record.event_id,requestId,latency,
  background&&!alert.isTest?{accepted:delivery=>queueAcceptedDelivery(env,delivery),background}:{});}
 finally {
  if(!alert.isTest){
   const scheduling=scheduleRemindersSafely(env,pair.parent_id,requestId);
   if(background)background.waitUntil(scheduling);else await scheduling;
  }
 }
 const result=await latency.read<{status:string;acknowledged_at:string|null;resolved_at:string|null}>('response_read_ms',env.DB.prepare('SELECT status,acknowledged_at,resolved_at FROM events WHERE event_id=?').bind(record.event_id));
 return {status:result?.acknowledged_at?'acknowledged':result?.resolved_at?'resolved':
  result?.status==='sending'&&latency.details.push_outcome==='sent'?'sent':result?.status??'pending'};
}
async function scheduleRemindersSafely(env:Env,parentId:string,requestId:string):Promise<void> {
 const started=Date.now(),latency=new Latency();
 try {
  await latency.measure('reminder_schedule_ms',()=>scheduleReminders(env,parentId,false,requestId));
  if(Date.now()-started>=2000)await recordDiagnostic(env,{requestId,started,operation:'reminder_schedule',stage:'handler',outcome:'ok',details:latency.details});
 }
 catch {await recordDiagnostic(env,{requestId,started,operation:'reminder_schedule',stage:'handler',outcome:'internal_error',details:latency.details});}
}
export interface DispatchOptions {
 insert?:D1PreparedStatement;
 accepted?:(delivery:AcceptedDelivery)=>Promise<void>;
 background?:Pick<ExecutionContext,'waitUntil'>;
}
export async function dispatchEvent(env:Env,eventId:string,requestId=crypto.randomUUID(),latency=new Latency(),options:DispatchOptions={}):Promise<void> {
 const now=Date.now();
 observeLateWrites(env,latency,options.background,requestId,now);
 let stage:Stage='claim',eventRef:string|undefined,attempt:number|undefined,target:'phone'|'watch'|undefined;
 let pushResult:PushResult|undefined;
 let auxiliary:Promise<void>|undefined;
 const record=(outcome:Outcome,httpStatus?:number,operation:'dispatch'|'dispatch_skip'|'dispatch_outcome'='dispatch')=>recordDiagnostic(env,{requestId,started:now,operation,stage,outcome,eventRef,attempt,target,httpStatus,details:latency.details});
 try {
 // Diagnostic computation is best effort, just like journal writes.
 try { eventRef=latency.eventRef??await eventReference(env,eventId);latency.eventRef=eventRef; } catch { /* No diagnostic identity available. */ }
 // Tombstones also suppress an offline outbox upload after its episode settled.
 const claimId=crypto.randomUUID();
 // Routing experiments are test-only. Real cries retain both phone forwarding
 // and direct Watch delivery, with AlarmKit added to the phone notification.
 // Preserve any prior delivery receipt so accepted pushes are never replayed.
 const watchOnlySQL="parent_id=? AND push_target IS NULL AND delivery_state IS NULL AND COALESCE(json_extract(payload,'$.isTest'),0)=1 AND EXISTS(SELECT 1 FROM devices WHERE id=events.parent_id AND watch_push_token IS NOT NULL)";
 // Marked tests alone opt in. Pin the selected phone using the existing target
 // and single-target state, so disabling the flag cannot add a Watch on retry.
 // An existing Watch-only opt-in wins if both settings name the same Parent.
 const phoneOnlyParent=env.PHONE_ONLY_TEST_PARENT_ID===env.WATCH_ONLY_PARENT_ID?'':env.PHONE_ONLY_TEST_PARENT_ID??'';
 const phoneOnlySQL="parent_id=? AND push_target IS NULL AND delivery_state IS NULL AND COALESCE(json_extract(payload,'$.isTest'),0)=1 AND EXISTS(SELECT 1 FROM devices WHERE id=events.parent_id AND push_token IS NOT NULL)";
 type Destination={token:string|null;phone_token:string|null;watch_token:string|null;silent_watch_alarms:number;alarm_receipts_version?:number;alarm_cycle_id?:string|null;alarm_request_claim_id?:string|null};
 type Receipt=StoredEvent & Destination & {pair_current:number};
 const claim=await latency.confirmedClaim<StoredEvent|Destination,Receipt>(()=>env.DB.batch<StoredEvent|Destination>([...(options.insert?[options.insert]:[]),env.DB.prepare(`UPDATE events SET resolved_at=COALESCE(resolved_at,(SELECT r.resolved_at FROM resolved_episodes r
  JOIN pairs p ON p.parent_id=r.parent_id AND p.listener_id=r.listener_id AND p.created_at=r.pair_created_at
  WHERE r.parent_id=events.parent_id AND r.listener_id=events.listener_id AND r.episode_id=events.episode_id))
  WHERE event_id=? AND COALESCE(json_extract(payload,'$.isTest'),0)=0`).bind(eventId),
 // Suppress uploads during a mute, including delayed offline outbox entries.
 env.DB.prepare(`UPDATE events SET acknowledged_at=COALESCE(acknowledged_at,?) WHERE event_id=?
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
 )`).bind(new Date(now).toISOString(),eventId,now,now),
 env.DB.prepare(`UPDATE events SET status='sending',lease_until=?,claim_id=?,attempts=attempts+1,
  delivery_mode=COALESCE(delivery_mode,CASE WHEN ${watchOnlySQL} THEN 'watch_only' END),
  delivery_state=CASE WHEN delivery_mode='watch_only' OR (${watchOnlySQL}) OR (${phoneOnlySQL}) THEN NULL
   ELSE COALESCE(delivery_state,CASE WHEN push_target IS NULL AND EXISTS(SELECT 1 FROM devices WHERE id=events.parent_id AND push_token IS NOT NULL AND watch_push_token IS NOT NULL)
    THEN '{"phone":"pending","watch":"pending"}' ELSE NULL END) END,
  push_target=COALESCE(push_target,CASE WHEN ${phoneOnlySQL} THEN 'phone' WHEN (SELECT watch_push_token FROM devices WHERE id=events.parent_id) IS NOT NULL THEN 'watch' ELSE 'phone' END)
  WHERE event_id=? AND status='pending' AND acknowledged_at IS NULL AND resolved_at IS NULL AND next_attempt<=? RETURNING *`).bind(now+30000,claimId,env.WATCH_ONLY_PARENT_ID??'',env.WATCH_ONLY_PARENT_ID??'',phoneOnlyParent,phoneOnlyParent,eventId,now),
 // Read the selected token in the claim transaction, avoiding another remote
 // round trip. A losing claimant must still return before using this result.
 reserveAlarmRequest(env,eventId,claimId,now),
 env.DB.prepare(`SELECT CASE e.push_target WHEN 'watch' THEN d.watch_push_token ELSE d.push_token END AS token,d.push_token AS phone_token,d.watch_push_token AS watch_token,d.silent_watch_alarms,d.alarm_receipts_version,a.cycle_id AS alarm_cycle_id,a.request_claim_id AS alarm_request_claim_id
  FROM events e JOIN devices d ON d.id=e.parent_id LEFT JOIN silent_alarm_cycles a ON a.parent_id=e.parent_id AND a.episode_id=e.episode_id WHERE e.event_id=? AND e.status='sending'`).bind(eventId)]),
 ()=>env.DB.prepare(`SELECT e.*,CASE e.push_target WHEN 'watch' THEN d.watch_push_token ELSE d.push_token END AS token,d.push_token AS phone_token,d.watch_push_token AS watch_token,d.silent_watch_alarms,d.alarm_receipts_version,a.cycle_id AS alarm_cycle_id,a.request_claim_id AS alarm_request_claim_id,
 EXISTS(SELECT 1 FROM pairs p WHERE p.parent_id=e.parent_id AND p.listener_id=e.listener_id) AS pair_current
 FROM events e JOIN devices d ON d.id=e.parent_id LEFT JOIN silent_alarm_cycles a ON a.parent_id=e.parent_id AND a.episode_id=e.episode_id WHERE e.event_id=? AND e.claim_id=?`).bind(eventId,claimId).all<Receipt>());
 const claims=claim.source==='reply'?claim.results:undefined;
 const offset=options.insert?1:0;
 if(options.insert&&claims&&!claims[0].meta.changes){
  latency.details.exit_reason='not_created';await record('claim_skipped',undefined,'dispatch_skip');return;
 }
 const event=claim.source==='receipt'?claim.receipt:claims![offset+2].results[0] as StoredEvent|undefined;
 if(event){attempt=event.attempts;latency.deliveryAttempt=attempt;target=event.push_target??'phone';}
 if(claim.source==='receipt'){
  const current=claim.receipt;
  if(!current.pair_current||current.status!=='sending'||current.acknowledged_at||current.resolved_at){
   latency.details.observed_status=current.status as typeof latency.details.observed_status;
   latency.details.exit_reason=!current.pair_current?'no_pair':current.acknowledged_at?'acknowledged':current.resolved_at?'resolved':'not_pending';
   await record('claim_skipped',undefined,'dispatch_skip');return;
  }
 }
 if(!event){
  // Losing a claim is a diagnostic outcome too: retain this caller's preparation
  // spans, especially if cron saw an insert before the alarm's D1 reply arrived.
  try {
   const observed=await latency.read<Pick<StoredEvent,'status'|'attempts'|'acknowledged_at'|'resolved_at'|'next_attempt'>>('claim_observe_ms',env.DB.prepare('SELECT status,attempts,acknowledged_at,resolved_at,next_attempt FROM events WHERE event_id=?').bind(eventId));
   latency.details.observed_status=observed?.status as typeof latency.details.observed_status;
   latency.details.observed_attempts=observed?.attempts;
   latency.details.next_attempt_at_ms=observed?.next_attempt;
   latency.details.exit_reason=!observed?'not_found':observed.acknowledged_at?'acknowledged':observed.resolved_at?'resolved':observed.status==='sent'?'already_sent':observed.status==='sending'?'in_flight':observed.status==='pending'&&observed.next_attempt>Date.now()?'backoff':'not_pending';
  }catch{/* Optional observation must not turn a skipped send into a failure. */}
  await record('claim_skipped',undefined,'dispatch_skip');return;
 }
 // A delayed original reply cannot revive an already expired delivery lease.
 if((event.lease_until??0)<=Date.now()){
  latency.details.observed_status=event.status as typeof latency.details.observed_status;latency.details.exit_reason='not_pending';
  await record('claim_skipped',undefined,'dispatch_skip');return;
 }
 latency.details.spans!.generated_to_dispatch_ms=Math.max(0,now-event.created_at);
 stage='storage';
 const alert=JSON.parse(event.payload) as Alert;
 // Keep forwarded phone and direct Watch copies distinct for crying alerts,
 // including reminders. Both copies still acknowledge the same logical event.
 const identity={distinctRequestID:alert.isTest===true&&env.DISTINCT_APNS_ID_TEST_PARENT_ID===event.parent_id,
  separateCollapseIDs:!alert.isTest||env.SEPARATE_COLLAPSE_ID_TEST_PARENT_ID===event.parent_id};
 // No replay after uncertain transport or a worker death during APNs dispatch. APNs does
 // not offer an exactly-once receipt transaction with D1. Surface uncertainty explicitly.
 if(now-Date.parse(alert.createdAt)>86400000){
  await latency.db('outcome_storage_ms',()=>env.DB.prepare("UPDATE events SET status='failed',last_error='expired_event',lease_until=NULL WHERE event_id=?").bind(eventId).run());await record('expired_event');return;
 }
 if(event.delivery_mode==='watch_only'){
  latency.details.notification_route='watch_only';
  latency.details.phone_suppressed=target==='watch';latency.details.phone_fallback=target==='phone';
 }
 const column=target==='watch'?'watch_push_token':'push_token';
 const parent=claim.source==='receipt'?claim.receipt:claims![offset+4].results[0] as Destination|undefined;
 if(!event.delivery_state&&target==='phone'&&event.parent_id===phoneOnlyParent&&alert.isTest){
  latency.details.notification_route='phone_only_test';latency.details.watch_suppressed=!!parent?.watch_token;
 }
 const alarmCycle=parent?.alarm_receipts_version===1?(parent.alarm_request_claim_id===claimId?parent.alarm_cycle_id??undefined:undefined):undefined;
 const requestAlarm=parent?.silent_watch_alarms===1&&!alert.isTest&&(parent.alarm_receipts_version!==1||!!alarmCycle);
 if(event.delivery_state&&parent){
  stage='push';
  let checkpointed=false;
  const status=await deliverToBoth(env,{table:'events',id:eventId,parentId:event.parent_id,attempt:event.attempts,
   phoneHeadStartMS:phoneHeadStartFor(env,event.parent_id,alert.isTest===true),
   state:event.delivery_state,phoneToken:parent.phone_token,watchToken:parent.watch_token,requestId,eventRef,
   source:latency.details.dispatch_source,
   accepted:options.accepted?async delivery=>{await latency.measure('outcome_queue_ms',()=>options.accepted!(delivery));checkpointed=true;}:undefined,
   aggregate:{requestId,started:now,operation:'dispatch',stage:'storage',outcome:'sent',eventRef,attempt,details:latency.progressDetails()},
   send:(destination,token,timing,schedule)=>sendPush(env,token,alert,destination,timing,requestAlarm,schedule,identity,alarmCycle)});
  latency.details.push_outcome=status==='pending'?'retry':status;
  stage='storage';target=undefined;
  // The checkpoint's background persister owns the aggregate and target journals.
  if(!checkpointed)await record(status==='pending'?'retry':status,undefined,'dispatch_outcome');
  return;
 }
 if(!parent?.token){
  // A token upload can race with this read. Decide blocked/pending in the same
  // database statement that releases the claim, so either ordering can recover.
  await latency.db('outcome_storage_ms',()=>env.DB.prepare("UPDATE events SET status=CASE WHEN EXISTS(SELECT 1 FROM devices WHERE id=parent_id AND (push_token IS NOT NULL OR watch_push_token IS NOT NULL)) THEN 'pending' ELSE 'blocked' END,last_error='no_push_token',lease_until=NULL,push_target=NULL WHERE event_id=? AND status='sending'").bind(eventId).run());await record('no_push_token');return;
 }
 stage='push';
 const silentAlarm=requestAlarm&&event.delivery_mode!=='watch_only';
 // The original send and its receipt never depend on the auxiliary phone send.
 const primary=sendPush(env,parent.token,alert,target,latency,silentAlarm,undefined,identity,alarmCycle);
 if(silentAlarm&&target==='watch'&&parent.phone_token){
  auxiliary=(async()=>{
   const started=Date.now(),timing=new Latency();let result:PushResult;
   try{result=await sendSilentCryAlarmPush(env,parent.phone_token!,alert,timing,alarmCycle);}
   catch(error){result={status:'failed',reason:error instanceof PushPreparationError?error.code:'apns_configuration'};}
   await recordDiagnostic(env,{requestId,started,operation:'silent_cry_alarm_dispatch',stage:'push',outcome:result.reason??result.status,eventRef,target:'phone',attempt,httpStatus:result.httpStatus,details:timing.details});
  })().catch(()=>{});
  if(options.background){options.background.waitUntil(auxiliary);auxiliary=undefined;}
 }
 let result:PushResult;
 try{result=await primary;}
 catch(error){result={status:'retry',reason:error instanceof PushPreparationError?error.code:'apns_configuration'};}
 pushResult=result;latency.details.push_outcome=result.status;
 const status=result.status==='retry'?'pending':result.status;
 const next=now+Math.min(300000,2000*2**Math.min(event.attempts,8));
 stage='storage';
 if(result.status==='sent'&&options.accepted){
  await latency.measure('outcome_queue_ms',()=>options.accepted!(acceptedDelivery(eventId,event.parent_id,event.attempts,next,
   {requestId,started:now,operation:'dispatch',stage,outcome:'sent',eventRef,attempt,target,httpStatus:result.httpStatus,details:latency.details})));
  return;
 }
 if(result.reason==='invalid_device_token'){
  // Atomically invalidate only the rejected token and release the event. A
  // replacement uploaded during APNs dispatch must remain eligible for retry.
  await latency.db('outcome_storage_ms',()=>env.DB.batch([
   env.DB.prepare(`UPDATE devices SET ${column}=NULL WHERE id=? AND ${column}=?`).bind(event.parent_id,parent.token),
   env.DB.prepare("UPDATE events SET status=CASE WHEN EXISTS(SELECT 1 FROM devices WHERE id=parent_id AND (push_token IS NOT NULL OR watch_push_token IS NOT NULL)) THEN 'pending' ELSE 'blocked' END,next_attempt=0,lease_until=NULL,push_target=NULL,last_error=? WHERE event_id=? AND status='sending'").bind(result.reason,eventId)
  ]));
  await record(result.reason,result.httpStatus);
  return;
 }
 await latency.db('outcome_storage_ms',()=>env.DB.prepare('UPDATE events SET status=?,next_attempt=?,lease_until=NULL,sent_at=?,last_error=? WHERE event_id=? AND status=\'sending\'')
  .bind(status,next,status==='sent'?new Date().toISOString():null,result.reason??null,eventId).run());
 await record(result.reason??result.status,result.httpStatus);
 } catch(error) { latency.failure(error);await record('internal_error',pushResult?.httpStatus);throw error; }
 finally {if(auxiliary)await auxiliary;}
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
export async function flushPending(env:Env,requestId=crypto.randomUUID(),latency=new Latency(),background?:Pick<ExecutionContext,'waitUntil'>) {
 // Expire diagnostic data before delivery work so a broken push path cannot defer expiry.
 try { await latency.measure('maintenance_expiry_ms',()=>env.DB.prepare('DELETE FROM diagnostics WHERE recorded_at<?').bind(Date.now()-7*86400000).run()); }
 catch { await recordDiagnostic(env,{requestId,started:Date.now(),operation:'maintenance',stage:'cleanup',outcome:'diagnostic_cleanup_failed'}); }
 const bothAccepted="delivery_state IS NOT NULL AND json_extract(delivery_state,'$.phone')='sent' AND json_extract(delivery_state,'$.watch')='sent'";
 const interrupted=await latency.measure('maintenance_recovery_ms',()=>env.DB.prepare(`UPDATE events SET
  status=CASE WHEN ${bothAccepted} THEN 'sent' ELSE 'uncertain' END,
  last_error=CASE WHEN ${bothAccepted} THEN NULL ELSE 'dispatch_interrupted' END,
  sent_at=CASE WHEN ${bothAccepted} THEN COALESCE(sent_at,?) ELSE sent_at END,lease_until=NULL
  WHERE status='sending' AND lease_until<? RETURNING event_id,attempts,push_target,status`)
  .bind(new Date().toISOString(),Date.now()).all<{event_id:string;attempts:number;push_target:'phone'|'watch'|null;status:string}>());
 for(const event of interrupted.results) {
  let eventRef:string|undefined;try {eventRef=await eventReference(env,event.event_id);}catch{/* Best effort. */}
  await recordDiagnostic(env,{requestId,started:Date.now(),operation:event.status==='sent'?'dispatch_outcome':'dispatch',stage:'claim',outcome:event.status==='sent'?'sent':'dispatch_interrupted',eventRef,attempt:event.attempts,target:event.status==='sent'?undefined:event.push_target??undefined});
 }
 const events=await latency.measure('maintenance_pending_ms',()=>env.DB.prepare("SELECT event_id FROM events WHERE status='pending' AND acknowledged_at IS NULL AND resolved_at IS NULL AND next_attempt<=? ORDER BY created_at LIMIT 25").bind(Date.now()).all<{event_id:string}>());
 // Bound recovery fan-out to leave capacity for proof reads and connection notices.
 await latency.measure('maintenance_dispatch_ms',async()=>{for(let index=0;index<events.results.length;index+=2){await Promise.all(events.results.slice(index,index+2).map(event=>{const trace=new Latency();trace.details.dispatch_source='maintenance';return dispatchEvent(env,event.event_id,requestId,trace,{background});}));}});
 // Repair scheduling after a failed background request or worker reset. Bound
 // fan-out; existing alarms are never postponed by these idempotent refreshes.
 await latency.measure('maintenance_schedule_ms',async()=>{
 const parents=await env.DB.prepare(`SELECT DISTINCT parent_id FROM events WHERE acknowledged_at IS NULL AND resolved_at IS NULL
  AND status IN ('pending','blocked','sent','uncertain') AND COALESCE(last_error,'')!='expired_event'
  AND COALESCE(json_extract(payload,'$.isTest'),0)=0 ORDER BY parent_id LIMIT 25`).all<{parent_id:string}>();
 for(let index=0;index<parents.results.length;index+=5)await Promise.all(parents.results.slice(index,index+5).map(p=>scheduleRemindersSafely(env,p.parent_id,requestId)));
 });
 // Keep deduplication tombstones for 30 days. Codes are short-lived; claimed codes retain
 // enough time to recover a lost claim response. Status metadata retains max 100 episodes.
 await latency.measure('maintenance_cleanup_ms',()=>env.DB.batch([
  env.DB.prepare('DELETE FROM monitoring_commands WHERE created_at<? AND sequence NOT IN (SELECT MAX(sequence) FROM monitoring_commands GROUP BY parent_id,listener_id,pair_created_at)').bind(Date.now()-30*86400000),
  env.DB.prepare('DELETE FROM silent_alarm_cycles WHERE last_requested_at<?').bind(Date.now()-30*86400000),
  env.DB.prepare('DELETE FROM alert_snoozes WHERE until_at<?').bind(Date.now()-86400000),
  env.DB.prepare(`DELETE FROM timeline_events WHERE occurred_at<? AND id NOT IN (SELECT id FROM timeline_events t2 WHERE t2.parent_id=timeline_events.parent_id AND t2.listener_id=timeline_events.listener_id AND t2.pair_created_at=timeline_events.pair_created_at AND t2.kind IN ('coverage_active','coverage_stopped') ORDER BY occurred_at DESC LIMIT 1)`).bind(Date.now()-24*3600000),
  env.DB.prepare('DELETE FROM resolved_episodes WHERE resolved_at<?').bind(new Date(Date.now()-30*86400000).toISOString()),
  env.DB.prepare('DELETE FROM events WHERE created_at<?').bind(Date.now()-30*86400000),
  env.DB.prepare('DELETE FROM pairing_codes WHERE expires_at<?').bind(Date.now()-86400000),
  env.DB.prepare('DELETE FROM rate_limits WHERE window<?').bind(Math.floor(Date.now()/1000/600)-144)
 ]));
}
