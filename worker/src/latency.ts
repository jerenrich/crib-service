// Bounded numeric spans only. No SQL, exception text, tokens or payloads.
export const spans = ['rate_limit_ms','authentication_ms','authentication_hash_ms','authentication_lookup_ms','ip_rate_limit_ms','device_rate_limit_ms','status_pair_ms','status_snapshot_ms','heartbeat_admission_ms','heartbeat_snapshot_ms','heartbeat_storage_ms','heartbeat_receipt_ms','heartbeat_schedule_ms','alert_admission_ms','alert_snapshot_ms','body_read_ms','handler_ms','alert_prepare_ms','claim_ms','claim_receipt_ms','destination_ms',
 'token_decrypt_ms','provider_sign_ms','apns_fetch_ms','apns_body_ms','outcome_storage_ms','reminder_prepare_ms',
 'reminder_schedule_ms','reminder_snapshot_ms','reminder_pair_ms','reminder_control_ms','reminder_latest_ms','reminder_heartbeat_ms','reminder_original_ms','reminder_insert_ms','alarm_lag_ms','generated_to_dispatch_ms',
 'pair_ms','event_lookup_ms','event_insert_ms','event_reload_ms','event_episode_ms','response_read_ms','claim_observe_ms',
 'alarm_state_ms','alarm_arm_ms','alarm_finalize_ms','schedule_read_ms','schedule_state_ms','journal_ms','outcome_queue_ms','coordination_wait_ms',
 'maintenance_expiry_ms','maintenance_recovery_ms','maintenance_pending_ms','maintenance_dispatch_ms','maintenance_schedule_ms','maintenance_cleanup_ms','maintenance_connections_ms'] as const;
export type Span = typeof spans[number];
export const appleReasons = ['BadCollapseId','BadDeviceToken','BadExpirationDate','BadMessageId','BadPriority','BadTopic',
 'DeviceTokenNotForTopic','DuplicateHeaders','IdleTimeout','InvalidPushType','MissingDeviceToken','MissingTopic',
 'PayloadEmpty','TopicDisallowed','BadCertificate','BadCertificateEnvironment','ExpiredProviderToken','Forbidden',
 'InvalidProviderToken','MissingProviderToken','UnrelatedKeyIdInToken','BadEnvironmentKeyIdInToken','BadPath',
 'MethodNotAllowed','ExpiredToken','Unregistered','PayloadTooLarge','TooManyProviderTokenUpdates','TooManyRequests',
 'InternalServerError','ServiceUnavailable','Shutdown','unknown','unreadable'] as const;
export type AppleReason = typeof appleReasons[number];
const databaseMetrics=['calls','completed','errors','statements','sql_ms','rows_read','rows_written','attempts','retries','hedges','hedge_wins','unfinished','hedge_after_ms','hedge_timer_lag_ms'] as const;
interface StatementMetrics {index:number;sql_ms?:number;attempts?:number;colo?:string;region?:string;primary?:boolean}
type DatabaseMetrics=Partial<Record<typeof databaseMetrics[number],number>> & {statement_meta?:StatementMetrics[]};
const regions=['WNAM','ENAM','WEUR','EEUR','APAC','OC'];
export interface TimingDetails {
 spans?:Partial<Record<Span,number>>;
 db_stages?:Partial<Record<Span,DatabaseMetrics>>;
 db_calls?:number; db_sql_ms?:number; db_rows_read?:number; db_rows_written?:number; db_attempts?:number;
 apns_reason?:AppleReason; apns_environment?:'development'|'production';
 transport?:'timeout'|'network'; provider_token_cached?:boolean; provider_token_age_s?:number;
 provider_token_source?:'memory'|'in_flight'|'coordinator_reused'|'coordinator_created';provider_token_ref?:string;
 apns_started_at_ms?:number; apns_response_at_ms?:number; apns_unique_id?:string; colo?:string;
 error_kind?:'d1_overloaded'|'d1_timeout'|'d1_error'|'other';
 failed_span?:Span;
 claim_result_source?:'reply'|'receipt';claim_receipt_outcome?:'matched'|'missing'|'error';
 heartbeat_result_source?:'reply'|'receipt';heartbeat_receipt_outcome?:'matched'|'missing'|'error';
 client_request_id?:string;in_flight_span?:Span;in_flight_ms?:number;
 dispatch_source?:'upload'|'reminder'|'maintenance'|'connection'|'watch_test';
 observed_status?:'pending'|'sending'|'sent'|'blocked'|'uncertain'|'failed';
 exit_reason?:'acknowledged'|'resolved'|'in_flight'|'already_sent'|'backoff'|'not_pending'|'not_found'|'not_created'|'no_pair'|'monitoring_stopped'|'no_pending_alert'|'stale_heartbeat'|'not_crying'|'below_threshold'|'muted'|'not_due'|'superseded';
 push_outcome?:'sent'|'retry'|'blocked'|'uncertain'|'failed';
 observed_attempts?:number; next_attempt_at_ms?:number;
 preparation_started_at_ms?:number; preparation_finished_at_ms?:number;
 journal_failures_before_write?:number;status_successes_sampled?:number;
 late_write_kind?:'claim'|'heartbeat';recovered_after_ms?:number;
 coordination_mode?:'phone_head_start';phone_head_start_ms?:number;phone_head_start_cap_ms?:number;phone_head_start_observed_ms?:number;
 notification_route?:'watch_only';phone_suppressed?:boolean;phone_fallback?:boolean;
 phone_head_start_wait_outcome?:'head_start_elapsed'|'phone_unavailable'|'wait_cap';
 durable_outcome?:boolean;outcome_recovery?:boolean;outcome_queue_age_ms?:number;
}
export class Latency {
 readonly details:TimingDetails={spans:{}};
 private lateObserver?:{background:Pick<ExecutionContext,'waitUntil'>;record:(details:TimingDetails)=>Promise<unknown>};
 observeLateWrites(background:Pick<ExecutionContext,'waitUntil'>,record:(details:TimingDetails)=>Promise<unknown>):void {
  this.lateObserver={background,record};
 }
 private async lateWrite(kind:'claim'|'heartbeat',started:number,recoveredAfter:number,results?:D1Result<unknown>[],error?:unknown):Promise<void> {
  if(!this.lateObserver)return;
  // Independent trace: a late physical reply must not mutate the logical send's
  // frozen spans. Only provider metrics and fixed error categories survive.
  const late=new Latency(),stage=kind==='claim'?'claim_ms':'heartbeat_storage_ms';
  late.details.spans![stage]=Math.max(0,performance.now()-started);
  late.details.late_write_kind=kind;late.details.recovered_after_ms=recoveredAfter;
  late.databaseStarted(stage);
  if(results)late.databaseCompleted(stage,results);
  else {late.metric(stage,'errors');late.failure(error,stage);}
  try{await this.lateObserver.record(late.progressDetails());}catch{/* Best effort only. */}
 }
 private active?:{name:Span;started:number};
 private failureCause:unknown;
 private hasFailure=false;
 eventRef?:string;
 deliveryAttempt?:number;
 failure(error:unknown,span?:Span):void {
  const message=error instanceof Error?error.message:'';
  this.details.error_kind=/D1/i.test(message)?(/overload/i.test(message)?'d1_overloaded':/timeout|timed out/i.test(message)?'d1_timeout':'d1_error'):'other';
  if(!this.hasFailure||this.failureCause!==error){this.details.failed_span=span;this.failureCause=error;this.hasFailure=true;}
  else if(span&&!this.details.failed_span)this.details.failed_span=span;
 }
 async measure<T>(name:Span,work:()=>Promise<T>):Promise<T> {
  const start=performance.now(),previous=this.active,current={name,started:start};this.active=current;
  try{return await work();}catch(error){this.failure(error,name);throw error;}finally{
   this.details.spans![name]=(this.details.spans![name]??0)+Math.max(0,performance.now()-start);
   if(this.active===current)this.active=previous;
  }
 }
 progressDetails():TimingDetails {
  const details:TimingDetails={...this.details,...(this.active?{in_flight_span:this.active.name,in_flight_ms:Math.max(0,performance.now()-this.active.started)}:{})};
  // Freeze a bounded, sanitized copy before asynchronous journal I/O.
  return JSON.parse(safeTimingDetails(details)??'{}') as TimingDetails;
 }
 async db<T>(name:Span,work:()=>Promise<D1Result<T>|D1Result<T>[]>):Promise<D1Result<T>[]> {
  this.databaseStarted(name);
  try {
   const value=await this.measure(name,work),results=Array.isArray(value)?value:[value];
   this.databaseCompleted(name,results);return results;
  }catch(error){this.metric(name,'errors');throw error;}
 }
 private metric(name:Span,key:typeof databaseMetrics[number],amount=1) {
  const stages=this.details.db_stages??={},stage=stages[name]??={};
  stage[key]=(stage[key]??0)+amount;
 }
 private databaseStarted(name:Span) {
  this.details.db_calls=(this.details.db_calls??0)+1;this.metric(name,'calls');
 }
 private databaseCompleted<T>(name:Span,results:D1Result<T>[]) {
  this.metric(name,'completed');this.metric(name,'statements',results.length);
  for(const [index,result] of results.entries()){
   // Missing/malformed optional metrics must never turn a successful DB call into a failure.
   const meta=result.meta as (Partial<D1Meta> & {total_attempts?:number;served_by_colo?:string;served_by_region?:string;served_by_primary?:boolean;timings?:{sql_duration_ms?:number}})|undefined;
   const add=(aggregate:'db_sql_ms'|'db_rows_read'|'db_rows_written'|'db_attempts',key:'sql_ms'|'rows_read'|'rows_written'|'attempts',n:unknown)=>{
    if(typeof n==='number'&&Number.isFinite(n)&&n>=0){this.details[aggregate]=(this.details[aggregate]??0)+n;this.metric(name,key,n);}
   };
   add('db_sql_ms','sql_ms',meta?.duration);add('db_rows_read','rows_read',meta?.rows_read);add('db_rows_written','rows_written',meta?.rows_written);
   add('db_attempts','attempts',meta?.total_attempts);
   if(typeof meta?.total_attempts==='number'&&Number.isFinite(meta.total_attempts)&&meta.total_attempts>=1)this.metric(name,'retries',Math.max(0,meta.total_attempts-1));
   const statement:StatementMetrics={index};
   if(typeof meta?.duration==='number'&&Number.isFinite(meta.duration)&&meta.duration>=0)statement.sql_ms=meta.duration;
   if(typeof meta?.total_attempts==='number'&&Number.isSafeInteger(meta.total_attempts)&&meta.total_attempts>=1)statement.attempts=meta.total_attempts;
   if(typeof meta?.served_by_colo==='string'&&/^[A-Z]{3}$/.test(meta.served_by_colo))statement.colo=meta.served_by_colo;
   if(regions.includes(meta?.served_by_region??''))statement.region=meta!.served_by_region;
   if(typeof meta?.served_by_primary==='boolean')statement.primary=meta.served_by_primary;
   // Only add this object when location/retry metadata exists. Old providers and
   // malformed metrics remain optional; never retain arbitrary metadata keys.
   if(Object.keys(statement).length>1){
    const stage=this.details.db_stages![name]!;const statements=stage.statement_meta??=[];
    if(statements.length<16)statements.push(statement);
   }
  }
 }
 // Exactly one mutation and at most one ownership-receipt SELECT. This is
 // not a write retry: only a row bearing this invocation's unique claim ID may
 // replace the original reply. Ignore late results without changing the trace.
 async confirmedClaim<T,P>(write:()=>Promise<D1Result<T>[]>,receipt:()=>Promise<D1Result<P>>,afterMs=250) {
  return this.confirmedWrite('claim',write,receipt,afterMs);
 }
 async confirmedWrite<T,P>(kind:'claim'|'heartbeat',write:()=>Promise<D1Result<T>[]>,receipt:()=>Promise<D1Result<P>>,afterMs=250):Promise<
  {source:'reply';results:D1Result<T>[]} | {source:'receipt';receipt:P}> {
  const stage=kind==='claim'?'claim_ms':'heartbeat_storage_ms',proofStage=kind==='claim'?'claim_receipt_ms':'heartbeat_receipt_ms';
  const resultField=kind==='claim'?'claim_result_source':'heartbeat_result_source',proofField=kind==='claim'?'claim_receipt_outcome':'heartbeat_receipt_outcome';
  return this.measure(stage,()=>new Promise((resolve,reject)=>{
   let settled=false,proofStarted=false,proofDone=false,writeFailed=false,writeError:unknown;
   const writeAt=performance.now();let recoveredAfter=0,writeTask:Promise<void>|undefined;
   let proofAt=0,timer:ReturnType<typeof setTimeout>|undefined;
   const clear=()=>{if(timer!==undefined)clearTimeout(timer);};
   const rejected=()=>{if(!settled){settled=true;clear();reject(writeError);}};
   const prove=()=>{
    if(settled||proofStarted)return;
    clear();proofStarted=true;proofAt=performance.now();this.databaseStarted(proofStage);
    void (async()=>{
     try {
      const result=await receipt();if(settled)return;
      proofDone=true;this.details.spans![proofStage]=Math.max(0,performance.now()-proofAt);
      this.databaseCompleted(proofStage,[result]);
      const row=result.results[0];
      if(row){
       this.details[proofField]='matched';this.details[resultField]='receipt';
       if(!writeFailed)this.metric(stage,'unfinished');
       recoveredAfter=Math.max(0,performance.now()-writeAt);
       settled=true;clear();
       if(!writeFailed&&writeTask&&this.lateObserver)this.lateObserver.background.waitUntil(writeTask);
       resolve({source:'receipt',receipt:row});
      }else{this.details[proofField]='missing';if(writeFailed)rejected();}
     }catch{
      if(settled)return;
      proofDone=true;this.details.spans![proofStage]=Math.max(0,performance.now()-proofAt);
      this.metric(proofStage,'errors');this.details[proofField]='error';if(writeFailed)rejected();
     }
    })();
   };
   this.databaseStarted(stage);
   timer=setTimeout(prove,afterMs);
   writeTask=(async()=>{
    try {
     const results=await write();
     if(settled){await this.lateWrite(kind,writeAt,recoveredAfter,results);return;}
     this.databaseCompleted(stage,results);this.details[resultField]='reply';
     if(proofStarted&&!proofDone){this.metric(proofStage,'unfinished');this.details.spans![proofStage]=Math.max(0,performance.now()-proofAt);}
     settled=true;clear();resolve({source:'reply',results});
    }catch(error){
     if(settled){await this.lateWrite(kind,writeAt,recoveredAfter,undefined,error);return;}
     writeFailed=true;writeError=error;this.metric(stage,'errors');
     // A transport failure need not imply rollback. Check this request's own
     // committed ownership once; absence/error still fails closed.
     if(proofDone)rejected();else prove();
    }
   })();
  }));
 }
 // Only SELECT work belongs here. D1 cannot cancel a losing call: never use this
 // for writes, claims or APNs. One extra read is the full fallback budget.
 async readOnly<T>(name:Span,work:()=>Promise<D1Result<T>|D1Result<T>[]>,hedgeAfterMs=1500):Promise<D1Result<T>[]> {
  return this.measure(name,()=>new Promise<D1Result<T>[]>((resolve,reject)=>{
   let settled=false,started=0,failed=0,timer:ReturnType<typeof setTimeout>|undefined;
   const clear=()=>{if(timer!==undefined)clearTimeout(timer);};
   const attempt=async()=>{
    if(settled||started>=2)return;
    started++;this.databaseStarted(name);if(started===2)this.metric(name,'hedges');
    const index=started;
    try {
     const value=await work();
     // Freeze the trace when the logical read returns. Ignore late losers and
     // consume their errors so they cannot alter a later send's diagnostics.
     if(settled)return;
     const results=Array.isArray(value)?value:[value];this.databaseCompleted(name,results);
     if(index===2)this.metric(name,'hedge_wins');
     if(started-failed-1>0)this.metric(name,'unfinished',started-failed-1);
     settled=true;clear();resolve(results);
    }catch(error){
     if(settled)return;
     failed++;this.metric(name,'errors');
     if(started===1){clear();void attempt();}
     else if(failed===2){settled=true;clear();reject(error);}
    }
   };
   const timerStarted=performance.now();
   timer=setTimeout(()=>{
    if(!settled&&started===1){this.metric(name,'hedge_after_ms',hedgeAfterMs);this.metric(name,'hedge_timer_lag_ms',Math.max(0,performance.now()-timerStarted-hedgeAfterMs));}
    void attempt();
   },hedgeAfterMs);void attempt();
  }));
 }
 async read<T>(name:Span,statement:D1PreparedStatement):Promise<T|null> {
  const [result]=await this.db<T>(name,()=>statement.all<T>());return result.results[0]??null;
 }
}
// Enforce the privacy boundary even if a future caller passes extra properties.
export function safeTimingDetails(value:TimingDetails|undefined):string|null {
 if(!value)return null;
 const safe:Record<string,unknown>={};
 const number=(n:unknown)=>typeof n==='number'&&Number.isFinite(n)&&n>=0&&n<=1e15;
 const times:Record<string,number>={};
 for(const name of spans){const n=value.spans?.[name];if(number(n))times[name]=Math.round(n!*1000)/1000;}
 if(Object.keys(times).length)safe.spans=times;
 const stages:Record<string,Record<string,unknown>>={};
 for(const name of spans){
  const source=value.db_stages?.[name];if(!source)continue;
  const metrics:Record<string,unknown>={};
  for(const key of databaseMetrics){const n=source[key];if(number(n))metrics[key]=Math.round(n!*1000)/1000;}
  if(Array.isArray(source.statement_meta)){
   const statements:StatementMetrics[]=[];
   for(const item of source.statement_meta.slice(0,16)){
    if(!item||!Number.isInteger(item.index)||item.index<0||item.index>=1000)continue;
    const safe:StatementMetrics={index:item.index};
    if(number(item.sql_ms))safe.sql_ms=Math.round(item.sql_ms!*1000)/1000;
    if(Number.isSafeInteger(item.attempts)&&item.attempts!>=1&&item.attempts!<=1000)safe.attempts=item.attempts;
    if(typeof item.colo==='string'&&/^[A-Z]{3}$/.test(item.colo))safe.colo=item.colo;
    if(regions.includes(item.region??''))safe.region=item.region;
    if(typeof item.primary==='boolean')safe.primary=item.primary;
    statements.push(safe);
   }
   if(statements.length)metrics.statement_meta=statements;
  }
  if(Object.keys(metrics).length)stages[name]=metrics;
 }
 if(Object.keys(stages).length)safe.db_stages=stages;
 for(const name of ['db_calls','db_sql_ms','db_rows_read','db_rows_written','db_attempts','provider_token_age_s','apns_started_at_ms','apns_response_at_ms','observed_attempts','next_attempt_at_ms','preparation_started_at_ms','preparation_finished_at_ms','journal_failures_before_write','outcome_queue_age_ms','in_flight_ms','status_successes_sampled','recovered_after_ms','phone_head_start_ms','phone_head_start_cap_ms','phone_head_start_observed_ms'] as const){
  if(number(value[name]))safe[name]=value[name];
 }
 for(const name of ['durable_outcome','outcome_recovery'] as const)if(typeof value[name]==='boolean')safe[name]=value[name];
 if(value.coordination_mode==='phone_head_start')safe.coordination_mode=value.coordination_mode;
 if(value.notification_route==='watch_only')safe.notification_route=value.notification_route;
 if(typeof value.phone_suppressed==='boolean')safe.phone_suppressed=value.phone_suppressed;
 if(typeof value.phone_fallback==='boolean')safe.phone_fallback=value.phone_fallback;
 if(['head_start_elapsed','phone_unavailable','wait_cap'].includes(value.phone_head_start_wait_outcome!))safe.phone_head_start_wait_outcome=value.phone_head_start_wait_outcome;
 if(['claim','heartbeat'].includes(value.late_write_kind!))safe.late_write_kind=value.late_write_kind;
 if(['reply','receipt'].includes(value.claim_result_source!))safe.claim_result_source=value.claim_result_source;
 if(['reply','receipt'].includes(value.heartbeat_result_source!))safe.heartbeat_result_source=value.heartbeat_result_source;
 if(['matched','missing','error'].includes(value.claim_receipt_outcome!))safe.claim_receipt_outcome=value.claim_receipt_outcome;
 if(['matched','missing','error'].includes(value.heartbeat_receipt_outcome!))safe.heartbeat_receipt_outcome=value.heartbeat_receipt_outcome;
 if(typeof value.client_request_id==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value.client_request_id))safe.client_request_id=value.client_request_id.toLowerCase();
 if(spans.includes(value.in_flight_span!))safe.in_flight_span=value.in_flight_span;
 if(appleReasons.includes(value.apns_reason!))safe.apns_reason=value.apns_reason;
 if(['development','production'].includes(value.apns_environment!))safe.apns_environment=value.apns_environment;
 if(['timeout','network'].includes(value.transport!))safe.transport=value.transport;
 if(typeof value.apns_unique_id==='string'&&/^(?:[0-9a-f]{32,64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i.test(value.apns_unique_id))safe.apns_unique_id=value.apns_unique_id.toLowerCase();
 if(typeof value.colo==='string'&&/^[A-Z]{3}$/.test(value.colo))safe.colo=value.colo;
 if(['d1_overloaded','d1_timeout','d1_error','other'].includes(value.error_kind!))safe.error_kind=value.error_kind;
 if(typeof value.provider_token_cached==='boolean')safe.provider_token_cached=value.provider_token_cached;
 if(['memory','in_flight','coordinator_reused','coordinator_created'].includes(value.provider_token_source!))safe.provider_token_source=value.provider_token_source;
 if(typeof value.provider_token_ref==='string'&&/^[0-9a-f]{64}$/.test(value.provider_token_ref))safe.provider_token_ref=value.provider_token_ref;
 if(spans.includes(value.failed_span!))safe.failed_span=value.failed_span;
 if(['upload','reminder','maintenance','connection','watch_test'].includes(value.dispatch_source!))safe.dispatch_source=value.dispatch_source;
 if(['pending','sending','sent','blocked','uncertain','failed'].includes(value.observed_status!))safe.observed_status=value.observed_status;
 if(['sent','retry','blocked','uncertain','failed'].includes(value.push_outcome!))safe.push_outcome=value.push_outcome;
 if(['acknowledged','resolved','in_flight','already_sent','backoff','not_pending','not_found','not_created','no_pair','monitoring_stopped','no_pending_alert','stale_heartbeat','not_crying','below_threshold','muted','not_due','superseded'].includes(value.exit_reason!))safe.exit_reason=value.exit_reason;
 return Object.keys(safe).length?JSON.stringify(safe):null;
}
