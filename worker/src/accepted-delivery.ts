import type {Env} from './types';
import {Latency,safeTimingDetails} from './latency';
import {recordDiagnostic,type Diagnostic} from './diagnostics';

// Functional outbox data, kept only until D1 confirms the result. Never store a
// token or request body here. A stored receipt authorizes persistence, not APNs replay.
export interface AcceptedDelivery {
 eventId:string; parentId:string; attempt:number; sentAt:string; nextAttempt:number;
 diagnostic:Diagnostic;
}
export function acceptedDelivery(eventId:string,parentId:string,attempt:number,nextAttempt:number,diagnostic:Diagnostic):AcceptedDelivery {
 const details=safeTimingDetails(diagnostic.details);
 return {eventId,parentId,attempt,nextAttempt,sentAt:new Date().toISOString(),
  diagnostic:{...diagnostic,details:details?JSON.parse(details):undefined}};
}
export async function queueAcceptedDelivery(env:Env,delivery:AcceptedDelivery):Promise<void> {
 // Only the Worker binding exposes this endpoint. No public API accepts receipts.
 const response=await env.ALERT_REMINDERS.getByName(delivery.parentId).fetch('https://reminders.internal/accepted',{
  method:'POST',body:JSON.stringify(delivery),headers:{'content-type':'application/json'}
 });
 if(!response.ok)throw new Error('Accepted delivery checkpoint unavailable.');
}
export async function persistAcceptedDelivery(env:Env,delivery:AcceptedDelivery,recovery=false):Promise<void> {
 const latency=new Latency();Object.assign(latency.details,structuredClone(delivery.diagnostic.details??{}));
 latency.details.durable_outcome=true;latency.details.outcome_recovery=recovery;
 latency.details.outcome_queue_age_ms=Math.max(0,Date.now()-Date.parse(delivery.sentAt));
 const diagnostic={...delivery.diagnostic,operation:recovery?'dispatch_outcome' as const:'dispatch' as const,details:latency.details};
 try {
  // A late reply/recovery cannot overwrite a later attempt or erase Snooze or
  // resolution. A confirmed Apple receipt can repair cron's interrupted lease.
  await latency.db('outcome_storage_ms',()=>env.DB.prepare(`UPDATE events SET status='sent',next_attempt=?,lease_until=NULL,sent_at=?,last_error=NULL
   WHERE event_id=? AND parent_id=? AND attempts=? AND (status='sending' OR (status='uncertain' AND last_error='dispatch_interrupted'))`)
   .bind(delivery.nextAttempt,delivery.sentAt,delivery.eventId,delivery.parentId,delivery.attempt).run());
  const started=performance.now();await recordDiagnostic(env,diagnostic);
  const journalMs=Math.max(0,performance.now()-started);
  // One extra row only for an unusually slow journal; never recurse on logging.
  if(journalMs>=2000)await recordDiagnostic(env,{...diagnostic,operation:'dispatch_outcome',stage:'cleanup',outcome:'ok',
   details:{spans:{journal_ms:journalMs},durable_outcome:true,outcome_recovery:recovery}});
 }catch(error){
  latency.failure(error);await recordDiagnostic(env,{...diagnostic,outcome:'internal_error'});throw error;
 }
}
