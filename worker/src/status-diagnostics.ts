import {recordDiagnostic,type Diagnostic} from './diagnostics';
import {safeTimingDetails} from './latency';
import type {Env} from './types';

// At most one ordinary successful status row every 30 seconds per isolate.
// Slow handlers always survive. No device identity, per-user cache or timer.
export class StatusDiagnosticSampler {
 private last?:number;
 private skipped=0;
 take(elapsed:number,now=Date.now()):{record:boolean;sampled:number} {
  if(elapsed<2000&&this.last!==undefined&&now>=this.last&&now-this.last<30000){
   this.skipped=Math.min(Number.MAX_SAFE_INTEGER,this.skipped+1);return {record:false,sampled:0};
  }
  const sampled=this.skipped;this.skipped=0;this.last=now;return {record:true,sampled};
 }
}
const sampler=new StatusDiagnosticSampler();
export function queueStatusDiagnostic(env:Env,ctx:Pick<ExecutionContext,'waitUntil'>,diagnostic:Diagnostic & {operation:'status';outcome:'ok'},
 sampling=sampler):'queued'|'sampled' {
 const decision=sampling.take(Math.max(0,Date.now()-diagnostic.started));
 if(!decision.record)return 'sampled';
 return queueSuccessfulDiagnostic(env,ctx,diagnostic,decision.sampled);
}
export function queueHeartbeatDiagnostic(env:Env,ctx:Pick<ExecutionContext,'waitUntil'>,diagnostic:Diagnostic & {operation:'heartbeat';outcome:'ok'}):'queued' {
 // Every heartbeat survives sampling. Only the successful response stops waiting
 // for its journal write; failures retain the synchronous diagnostic path.
 return queueSuccessfulDiagnostic(env,ctx,diagnostic);
}
function queueSuccessfulDiagnostic(env:Env,ctx:Pick<ExecutionContext,'waitUntil'>,diagnostic:Diagnostic & {operation:'status'|'heartbeat';outcome:'ok'},sampled=0):'queued' {
 const details=safeTimingDetails(diagnostic.details);
 const frozen={...diagnostic,details:{...(details?JSON.parse(details):{}),...(sampled?{status_successes_sampled:sampled}:{})}};
 ctx.waitUntil((async()=>{
  const started=performance.now();const saved=await recordDiagnostic(env,frozen);
  const elapsed=Math.max(0,performance.now()-started);
  // One bounded slow-journal observation, never recursive and never awaited by
  // the API response. Database outages can still lose this best-effort evidence.
  if(elapsed>=2000)await recordDiagnostic(env,{...frozen,operation:diagnostic.operation==='status'?'status_journal':'heartbeat_journal',stage:'storage',outcome:saved?'ok':'internal_error',
   details:{spans:{journal_ms:elapsed}}});
 })());
 return 'queued';
}
