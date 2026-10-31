import type {Env} from './types';
import {safeTimingDetails,type TimingDetails} from './latency';

const routes = {
 'POST /v1/device/register':'register', 'POST /v1/device/push-token':'push_token',
 'POST /v1/device/watch-push-token':'watch_token', 'POST /v1/pairing/create':'pairing_create',
 'POST /v1/diagnostics/apns':'apns_readiness',
 'POST /v1/pairing/claim':'pairing_claim', 'POST /v1/listener/heartbeat':'heartbeat',
 'POST /v1/listener/event':'alert', 'GET /v1/listener/status':'status', 'GET /v1/timeline':'timeline',
 'POST /v1/monitoring':'monitoring', 'POST /v1/monitoring/complete':'monitoring_complete',
 'POST /v1/alert/resume':'resume_alerts', 'POST /v1/alert/stop':'stop_alerts',
 'POST /v1/settings':'settings', 'POST /v1/alert/acknowledge':'acknowledge',
 'POST /v1/pairing/remove':'unpair','POST /v1/device/delete':'delete_device',
 'POST /v1/caregivers/invite':'caregiver_invite','POST /v1/caregivers/join':'caregiver_join','POST /v1/caregivers/duty':'caregiver_duty',
 'POST /v1/watch-test/push':'test_push',
 'POST /v1/watch-latency-probe/push':'test_push',
 'POST /v1/listener/silent-alarm-test':'test_push',
 'POST /v1/silent-watch-alarms':'settings',
 'GET /v1/watch-test':'test_push','POST /v1/watch-test':'test_push',
 'POST /v1/alarm/scheduled':'alarm_scheduled','POST /v1/alarm/attempts':'alarm_attempts',
 'POST /v1/connection-alerts':'connection_preferences','POST /v1/test-push':'test_push','GET /v1/alert-test':'test_push','POST /v1/alert-test':'test_push','POST /v1/alert-test/stop':'test_push',
 'GET /v1/live-sound':'live_sound'
} as const;
export type Operation = typeof routes[keyof typeof routes] | 'unknown_route' | 'status_journal' | 'heartbeat_journal' | 'alert_progress' | 'database_late_reply' | 'dispatch' | 'dispatch_outcome' | 'dispatch_skip' | 'reminder_prepare' | 'maintenance' | 'reminder_schedule' | 'reminder_alarm' | 'watch_test_dispatch' | 'silent_alarm_test_dispatch' | 'silent_cry_alarm_dispatch' | 'alarm_attempt' | 'caregiver_routing';
export type Stage = 'validation' | 'rate_limit' | 'authentication' | 'handler' | 'claim' | 'push' | 'storage' | 'cleanup';
export type Outcome = 'ok' | 'rejected' | 'internal_error' | 'sent' | 'retry' | 'blocked' | 'uncertain' | 'failed'
 | 'expired_event' | 'no_push_token' | 'transport_unknown' | 'invalid_device_token' | 'provider_configuration'
 | 'apns_429' | 'apns_500' | 'apns_503' | 'apns_rejected' | 'apns_configuration' | 'dispatch_interrupted'
 | 'still_running' | PreparationFailure | 'claim_skipped' | 'notice_cancelled' | 'reminder_stopped' | 'reminder_not_created' | 'bad_topic' | 'missing_topic' | 'bad_priority' | 'bad_expiration' | 'bad_payload' | 'payload_too_large' | 'diagnostic_cleanup_failed';
export type PreparationFailure = 'token_decryption' | 'provider_signing' | 'apns_environment';
export class PushPreparationError extends Error {
 constructor(readonly code:PreparationFailure) { super(code); }
}
export interface Diagnostic {
 requestId:string; operation:Operation; stage:Stage; outcome:Outcome; started:number;
 httpStatus?:number; eventRef?:string; attempt?:number; target?:'phone'|'watch';
 details?:TimingDetails;
 // Frozen monotonic duration for records queued after functional work finishes.
 elapsedMS?:number;
}
export function operationFor(method:string,path:string):Operation {
 return routes[`${method} ${path}` as keyof typeof routes] ?? 'unknown_route';
}
// Only event-level pseudonyms; never hash or record device identities. Namespace prevents
// correlation with pairing/rate-limit hashes. The journal is deleted after seven days.
export async function eventReference(env:Env,eventId:string):Promise<string> {
 return (await eventReferences(env,[eventId]))[0];
}
/// One key import for any number of events; the signatures are local work, not storage calls.
export async function eventReferences(env:Env,eventIds:string[]):Promise<string[]> {
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(env.PAIRING_PEPPER),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 return Promise.all(eventIds.map(async eventId=>{
  const signature=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(`diagnostics:event:${eventId}`));
  return [...new Uint8Array(signature)].map(byte=>byte.toString(16).padStart(2,'0')).join('');
 }));
}
// Best-effort isolate-local evidence only. A restart loses unreported failures;
// concurrent successful rows may report overlapping counts, so do not sum them.
let journalFailures=0,reportedJournalFailures=0;
// Explicit columns prevent accidental object spreading of request/exception data.
// With `owner`, the reference requires ownership or current caregiver access,
// checked inside the insert so it costs no separate query.
function diagnosticInsert(env:Env,value:Diagnostic,details:TimingDetails|undefined,owner?:{eventId:string;parentId:string}):D1PreparedStatement {
 const release=env.CF_VERSION_METADATA?.id;
 const elapsed=typeof value.elapsedMS==='number'&&Number.isFinite(value.elapsedMS)&&value.elapsedMS>=0?value.elapsedMS:Math.max(0,Date.now()-value.started);
 const columns=[Date.now(),value.requestId,value.operation,value.stage,value.outcome,value.httpStatus??null,elapsed];
 const tail=[value.attempt??null,value.target??null,release && /^[0-9a-f-]{36}$/i.test(release)?release:null,safeTimingDetails(details)];
 if(!owner||!value.eventRef)return env.DB.prepare('INSERT INTO diagnostics(recorded_at,request_id,operation,stage,outcome,http_status,elapsed_ms,event_ref,attempt,target,release,details) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)')
  .bind(...columns,value.eventRef??null,...tail);
 return env.DB.prepare(`INSERT INTO diagnostics(recorded_at,request_id,operation,stage,outcome,http_status,elapsed_ms,event_ref,attempt,target,release,details)
  VALUES(?,?,?,?,?,?,?,CASE WHEN EXISTS(SELECT 1 FROM events e WHERE e.event_id=? AND (e.parent_id=? OR EXISTS(
   SELECT 1 FROM caregiver_families f JOIN pairs p ON p.parent_id=f.owner_id AND p.created_at=f.pair_created_at
   WHERE f.owner_id=e.parent_id AND f.partner_id=? AND p.listener_id=e.listener_id AND e.created_at>=p.created_at
   AND (COALESCE(json_extract(e.payload,'$.isTest'),0)=0 OR json_extract(e.payload,'$.targetCaregiverId')=?)
  ))) THEN ? END,?,?,?,?)`)
  .bind(...columns,owner.eventId,owner.parentId,owner.parentId,owner.parentId,value.eventRef,...tail);
}
export async function recordDiagnostic(env:Env,value:Diagnostic):Promise<boolean> {
 // Fail open: diagnostics must never change delivery or turn acceptance into a retry.
 try {
  const observedFailures=journalFailures;
  const details=observedFailures>reportedJournalFailures?{...value.details,journal_failures_before_write:observedFailures-reportedJournalFailures}:value.details;
  await diagnosticInsert(env,value,details).run();
  reportedJournalFailures=Math.max(reportedJournalFailures,observedFailures);
  return true;
 } catch { journalFailures=Math.min(Number.MAX_SAFE_INTEGER,journalFailures+1);return false; }
}
/// Several rows in one storage round trip; all are written or none. Returns the number written.
export async function recordDiagnostics(env:Env,values:(Diagnostic & {owner?:{eventId:string;parentId:string}})[]):Promise<number> {
 if(!values.length)return 0;
 try { await env.DB.batch(values.map(value=>diagnosticInsert(env,value,value.details,value.owner)));return values.length; }
 catch { journalFailures=Math.min(Number.MAX_SAFE_INTEGER,journalFailures+1);return 0; }
}

// No new query on the normal path. A recovered write is kept alive only within
// the platform's background lifetime; missing late rows remain explicitly unknown.
export function observeLateWrites(env:Env,latency:import('./latency').Latency,background:Pick<ExecutionContext,'waitUntil'>|undefined,requestId:string,started:number):void {
 if(!background)return;
 latency.observeLateWrites(background,async details=>{
  await recordDiagnostic(env,{requestId,started,operation:'database_late_reply',stage:details.late_write_kind==='claim'?'claim':'storage',
   outcome:details.error_kind?'internal_error':'ok',eventRef:latency.eventRef,attempt:latency.deliveryAttempt,
   details:{...details,dispatch_source:latency.details.dispatch_source,client_request_id:latency.details.client_request_id,colo:latency.details.colo}});
 });
}
