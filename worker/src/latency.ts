// Bounded numeric spans only. No SQL, exception text, tokens or payloads.
export const spans = ['rate_limit_ms','authentication_ms','handler_ms','alert_prepare_ms','claim_ms','destination_ms',
 'token_decrypt_ms','provider_sign_ms','apns_fetch_ms','apns_body_ms','outcome_storage_ms','reminder_prepare_ms',
 'reminder_schedule_ms','reminder_pair_ms','reminder_control_ms','reminder_latest_ms','reminder_heartbeat_ms','reminder_original_ms','reminder_insert_ms','alarm_lag_ms','generated_to_dispatch_ms'] as const;
export type Span = typeof spans[number];
export const appleReasons = ['BadCollapseId','BadDeviceToken','BadExpirationDate','BadMessageId','BadPriority','BadTopic',
 'DeviceTokenNotForTopic','DuplicateHeaders','IdleTimeout','InvalidPushType','MissingDeviceToken','MissingTopic',
 'PayloadEmpty','TopicDisallowed','BadCertificate','BadCertificateEnvironment','ExpiredProviderToken','Forbidden',
 'InvalidProviderToken','MissingProviderToken','UnrelatedKeyIdInToken','BadEnvironmentKeyIdInToken','BadPath',
 'MethodNotAllowed','ExpiredToken','Unregistered','PayloadTooLarge','TooManyProviderTokenUpdates','TooManyRequests',
 'InternalServerError','ServiceUnavailable','Shutdown','unknown','unreadable'] as const;
export type AppleReason = typeof appleReasons[number];
export interface TimingDetails {
 spans?:Partial<Record<Span,number>>;
 db_calls?:number; db_sql_ms?:number; db_rows_read?:number; db_rows_written?:number; db_attempts?:number;
 apns_reason?:AppleReason; apns_environment?:'development'|'production';
 transport?:'timeout'|'network'; provider_token_cached?:boolean; provider_token_age_s?:number;
 apns_started_at_ms?:number; apns_response_at_ms?:number; apns_unique_id?:string; colo?:string;
 error_kind?:'d1_overloaded'|'d1_timeout'|'d1_error'|'other';
}
export class Latency {
 readonly details:TimingDetails={spans:{}};
 failure(error:unknown):void {
  const message=error instanceof Error?error.message:'';
  this.details.error_kind=/D1/i.test(message)?(/overload/i.test(message)?'d1_overloaded':/timeout|timed out/i.test(message)?'d1_timeout':'d1_error'):'other';
 }
 async measure<T>(name:Span,work:()=>Promise<T>):Promise<T> {
  const start=Date.now();
  try{return await work();}catch(error){this.failure(error);throw error;}finally{this.details.spans![name]=(this.details.spans![name]??0)+Math.max(0,Date.now()-start);}
 }
 async db<T>(name:Span,work:()=>Promise<D1Result<T>|D1Result<T>[]>):Promise<D1Result<T>[]> {
  this.details.db_calls=(this.details.db_calls??0)+1;
  const value=await this.measure(name,work),results=Array.isArray(value)?value:[value];
  for(const result of results){
   const meta=result.meta as D1Meta & {total_attempts?:number};
   this.details.db_sql_ms=(this.details.db_sql_ms??0)+(meta.duration??0);
   this.details.db_rows_read=(this.details.db_rows_read??0)+(meta.rows_read??0);
   this.details.db_rows_written=(this.details.db_rows_written??0)+(meta.rows_written??0);
   this.details.db_attempts=(this.details.db_attempts??0)+(meta.total_attempts??1);
  }
  return results;
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
 for(const name of ['db_calls','db_sql_ms','db_rows_read','db_rows_written','db_attempts','provider_token_age_s','apns_started_at_ms','apns_response_at_ms'] as const){
  if(number(value[name]))safe[name]=value[name];
 }
 if(appleReasons.includes(value.apns_reason!))safe.apns_reason=value.apns_reason;
 if(['development','production'].includes(value.apns_environment!))safe.apns_environment=value.apns_environment;
 if(['timeout','network'].includes(value.transport!))safe.transport=value.transport;
 if(typeof value.apns_unique_id==='string'&&/^(?:[0-9a-f]{32,64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i.test(value.apns_unique_id))safe.apns_unique_id=value.apns_unique_id.toLowerCase();
 if(typeof value.colo==='string'&&/^[A-Z]{3}$/.test(value.colo))safe.colo=value.colo;
 if(['d1_overloaded','d1_timeout','d1_error','other'].includes(value.error_kind!))safe.error_kind=value.error_kind;
 if(typeof value.provider_token_cached==='boolean')safe.provider_token_cached=value.provider_token_cached;
 return Object.keys(safe).length?JSON.stringify(safe):null;
}
