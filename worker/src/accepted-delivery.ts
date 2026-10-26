import type {Env} from './types';
import {Latency,safeTimingDetails} from './latency';
import {recordDiagnostic,type Diagnostic} from './diagnostics';

// Functional outbox data, kept only until D1 confirms the result. Never store a
// token or request body here. A stored receipt authorizes persistence, not APNs replay.
export type DeliveryState='pending'|'sent'|'blocked'|'uncertain'|'failed';
export interface AcceptedDelivery {
 eventId:string; parentId:string; attempt:number; sentAt:string; nextAttempt:number;
 diagnostic:Diagnostic;
 checkpointId?:string;
 dual?:{states:Record<'phone'|'watch',DeliveryState>;diagnostics:Diagnostic[]};
}
export function acceptedDelivery(eventId:string,parentId:string,attempt:number,nextAttempt:number,diagnostic:Diagnostic):AcceptedDelivery {
 const details=safeTimingDetails(diagnostic.details);
 return {eventId,parentId,attempt,nextAttempt,checkpointId:crypto.randomUUID(),sentAt:new Date().toISOString(),
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
  const dual=delivery.dual;
  if(dual){
   await latency.db('outcome_storage_ms',()=>env.DB.prepare(`WITH states AS MATERIALIZED (
    SELECT
     CASE WHEN json_extract(?1,'$.phone')='blocked' AND EXISTS(SELECT 1 FROM devices WHERE id=?2 AND push_token IS NOT NULL)
      THEN 'pending' ELSE json_extract(?1,'$.phone') END AS phone,
     CASE WHEN json_extract(?1,'$.watch')='blocked' AND EXISTS(SELECT 1 FROM devices WHERE id=?2 AND watch_push_token IS NOT NULL)
      THEN 'pending' ELSE json_extract(?1,'$.watch') END AS watch
   ), outcome AS (
    SELECT phone,watch,CASE WHEN phone='sent' AND watch='sent' THEN 'sent'
     WHEN phone='pending' OR watch='pending' THEN 'pending'
     WHEN phone='blocked' OR watch='blocked' THEN 'blocked'
     WHEN phone='uncertain' OR watch='uncertain' THEN 'uncertain' ELSE 'failed' END AS status FROM states
   ) UPDATE events SET delivery_state=(SELECT json_object('phone',phone,'watch',watch) FROM outcome),
    status=(SELECT status FROM outcome),next_attempt=?3,lease_until=NULL,
    sent_at=CASE WHEN (SELECT status FROM outcome)='sent' THEN ?4 ELSE sent_at END,
    last_error=CASE (SELECT status FROM outcome) WHEN 'sent' THEN NULL WHEN 'uncertain' THEN 'transport_unknown' ELSE 'partial_delivery' END
    WHERE event_id=?5 AND parent_id=?2 AND attempts=?6
     AND (status='sending' OR (status='uncertain' AND last_error='dispatch_interrupted'))`)
    .bind(JSON.stringify(dual.states),delivery.parentId,delivery.nextAttempt,delivery.sentAt,delivery.eventId,delivery.attempt).run());
   // Target receipts retain Apple's individual responses; aggregate spans belong
   // only to the aggregate row. A failed journal never authorizes a second send.
   for(const target of dual.diagnostics)await recordDiagnostic(env,{...target,details:{...target.details,
    durable_outcome:true,outcome_recovery:recovery,outcome_queue_age_ms:latency.details.outcome_queue_age_ms}});
  }else await latency.db('outcome_storage_ms',()=>env.DB.prepare(`UPDATE events SET status='sent',next_attempt=?,lease_until=NULL,sent_at=?,last_error=NULL
   WHERE event_id=? AND parent_id=? AND attempts=? AND (status='sending' OR (status='uncertain' AND last_error='dispatch_interrupted'))`)
   .bind(delivery.nextAttempt,delivery.sentAt,delivery.eventId,delivery.parentId,delivery.attempt).run());
  const started=performance.now();await recordDiagnostic(env,diagnostic);
  const journalMs=Math.max(0,performance.now()-started);
  // One extra row only for an unusually slow journal; never recurse on logging.
  if(journalMs>=2000)await recordDiagnostic(env,{...diagnostic,operation:'dispatch_outcome',stage:'cleanup',outcome:'ok',
   details:{spans:{journal_ms:journalMs},durable_outcome:true,outcome_recovery:recovery}});
 }catch(error){
  latency.failure(error);
  if(delivery.dual)for(const target of delivery.dual.diagnostics)await recordDiagnostic(env,{...target,stage:'storage',outcome:'internal_error',
   details:{...target.details,durable_outcome:true,outcome_recovery:recovery,error_kind:latency.details.error_kind,failed_span:'outcome_storage_ms'}});
  await recordDiagnostic(env,{...diagnostic,outcome:'internal_error'});throw error;
 }
}
