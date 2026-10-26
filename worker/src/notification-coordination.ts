import type {Env} from './types';
import type {Latency,TimingDetails} from './latency';

export interface PushSchedule {
 beforeRequest?:()=>Promise<void>;
 requestStarted?:()=>void;
}
// A trial must name one Parent and explicitly opt in. Invalid/absent settings
// preserve parallel delivery; no device identity is retained in diagnostic rows.
export function phoneHeadStartFor(env:Env,parentId:string):number {
 if(env.WATCH_PHONE_HEAD_START_PARENT_ID!==parentId)return 0;
 const text=env.WATCH_PHONE_HEAD_START_MS;
 if(!text||!/^\d{1,3}$/.test(text))return 0;
 const value=Number(text);return value>=1&&value<=500?value:0;
}
export const watchReadyWaitCapMS=500;
type WaitOutcome=NonNullable<TimingDetails['phone_head_start_wait_outcome']>;

// Start the head start at the actual phone APNs request, after token preparation.
// Independently cap the wait once the Watch is ready; neither a stalled phone
// preparation nor a stalled Apple response can indefinitely hold back the Watch.
export class PhoneHeadStart {
 private phoneStartedAt?:number;
 private phoneUnavailable=false;
 private wake?:()=>void;
 constructor(private headStartMS:number,private capMS=watchReadyWaitCapMS) {}
 schedule(target:'phone'|'watch',timing:Latency):PushSchedule {
  Object.assign(timing.details,{coordination_mode:'phone_head_start',phone_head_start_ms:this.headStartMS,phone_head_start_cap_ms:this.capMS});
  if(target==='phone')return {requestStarted:()=>{
   this.phoneStartedAt=performance.now();this.wake?.();
  }};
  return {beforeRequest:()=>timing.measure('coordination_wait_ms',async()=>{
   timing.details.phone_head_start_wait_outcome=await this.wait();
  }),requestStarted:()=>{
   if(this.phoneStartedAt!==undefined)timing.details.phone_head_start_observed_ms=Math.max(0,performance.now()-this.phoneStartedAt);
  }};
 }
 phoneFinished():void {
  if(this.phoneStartedAt===undefined){this.phoneUnavailable=true;this.wake?.();}
 }
 private wait():Promise<WaitOutcome> {
  const readyAt=performance.now();
  return new Promise(resolve=>{
   let done=false,timer:ReturnType<typeof setTimeout>|undefined;
   const clear=()=>{if(timer!==undefined){clearTimeout(timer);timer=undefined;}};
   const finish=(outcome:WaitOutcome)=>{done=true;clear();this.wake=undefined;resolve(outcome);};
   const check=()=>{
    if(done)return;clear();
    if(this.phoneUnavailable){finish('phone_unavailable');return;}
    const now=performance.now(),capRemaining=this.capMS-(now-readyAt);
    const headRemaining=this.phoneStartedAt===undefined?Infinity:this.headStartMS-(now-this.phoneStartedAt);
    if(headRemaining<=0){finish('head_start_elapsed');return;}
    if(capRemaining<=0){finish('wait_cap');return;}
    timer=setTimeout(check,Math.max(1,Math.min(capRemaining,headRemaining)));
   };
   this.wake=check;check();
  });
 }
}
