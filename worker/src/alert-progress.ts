import type {Env} from './types';
import {recordDiagnostic,type Stage} from './diagnostics';
import type {Latency} from './latency';

// One checkpoint only for an unusually slow initial upload. Ordinary requests
// cancel the timer without a journal write. The checkpoint never gates delivery.
export function startAlertProgress(env:Env,background:Pick<ExecutionContext,'waitUntil'>|undefined,
 requestId:string,started:number,latency:Latency,stage:()=>Stage,afterMs=10000):()=>void {
 if(!background)return ()=>{};
 let fired=false;
 let finish!:()=>void;
 const pending=new Promise<void>(resolve=>{finish=resolve;});
 const timer=setTimeout(()=>{
  fired=true;
  const details=latency.progressDetails(),eventRef=latency.eventRef;
  void recordDiagnostic(env,{requestId,started,operation:'alert_progress',stage:stage(),outcome:'still_running',eventRef,details}).then(()=>finish());
 },afterMs);
 background.waitUntil(pending);
 return ()=>{clearTimeout(timer);if(!fired)finish();};
}
