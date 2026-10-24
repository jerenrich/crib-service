import type {Env} from './types';

const routes = {
 'POST /v1/device/register':'register', 'POST /v1/device/push-token':'push_token',
 'POST /v1/device/watch-push-token':'watch_token', 'POST /v1/pairing/create':'pairing_create',
 'POST /v1/pairing/claim':'pairing_claim', 'POST /v1/listener/heartbeat':'heartbeat',
 'POST /v1/listener/event':'alert', 'GET /v1/listener/status':'status', 'GET /v1/timeline':'timeline',
 'POST /v1/monitoring':'monitoring', 'POST /v1/monitoring/complete':'monitoring_complete',
 'POST /v1/settings':'settings', 'POST /v1/alert/acknowledge':'acknowledge',
 'POST /v1/pairing/remove':'unpair','POST /v1/device/delete':'delete_device',
 'POST /v1/connection-alerts':'connection_preferences','POST /v1/test-push':'test_push'
} as const;
export type Operation = typeof routes[keyof typeof routes] | 'unknown_route' | 'dispatch' | 'maintenance';
export type Stage = 'validation' | 'rate_limit' | 'authentication' | 'handler' | 'claim' | 'push' | 'storage' | 'cleanup';
export type Outcome = 'ok' | 'rejected' | 'internal_error' | 'sent' | 'retry' | 'blocked' | 'uncertain' | 'failed'
 | 'expired_event' | 'no_push_token' | 'transport_unknown' | 'invalid_device_token' | 'provider_configuration'
 | 'apns_429' | 'apns_500' | 'apns_503' | 'apns_rejected' | 'apns_configuration' | 'dispatch_interrupted'
 | PreparationFailure | 'bad_topic' | 'missing_topic' | 'bad_priority' | 'bad_expiration' | 'bad_payload' | 'payload_too_large' | 'diagnostic_cleanup_failed';
export type PreparationFailure = 'token_decryption' | 'provider_signing' | 'apns_environment';
export class PushPreparationError extends Error {
 constructor(readonly code:PreparationFailure) { super(code); }
}
export interface Diagnostic {
 requestId:string; operation:Operation; stage:Stage; outcome:Outcome; started:number;
 httpStatus?:number; eventRef?:string; attempt?:number; target?:'phone'|'watch';
}
export function operationFor(method:string,path:string):Operation {
 return routes[`${method} ${path}` as keyof typeof routes] ?? 'unknown_route';
}
// Only event-level pseudonyms; never hash or record device identities. Namespace prevents
// correlation with pairing/rate-limit hashes. The journal is deleted after seven days.
export async function eventReference(env:Env,eventId:string):Promise<string> {
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(env.PAIRING_PEPPER),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const signature=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(`diagnostics:event:${eventId}`));
 return [...new Uint8Array(signature)].map(byte=>byte.toString(16).padStart(2,'0')).join('');
}
export async function recordDiagnostic(env:Env,value:Diagnostic):Promise<boolean> {
 // Explicit columns prevent accidental object spreading of request/exception data.
 // Fail open: diagnostics must never change delivery or turn acceptance into a retry.
 try {
  const release=env.CF_VERSION_METADATA?.id;
  await env.DB.prepare('INSERT INTO diagnostics(recorded_at,request_id,operation,stage,outcome,http_status,elapsed_ms,event_ref,attempt,target,release) VALUES(?,?,?,?,?,?,?,?,?,?,?)')
   .bind(Date.now(),value.requestId,value.operation,value.stage,value.outcome,value.httpStatus??null,
    Math.max(0,Date.now()-value.started),value.eventRef??null,value.attempt??null,value.target??null,
    release && /^[0-9a-f-]{36}$/i.test(release)?release:null).run();
  return true;
 } catch { return false; }
}
