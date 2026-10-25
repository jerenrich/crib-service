import {latestMonitoringCommand} from './monitoring';
import type {Alert,Env,Heartbeat,StoredEvent} from './types';
import {configuration} from './security';
import {dispatchEvent} from './alerts';
import {recordDiagnostic,eventReference} from './diagnostics';
import {Latency,type Span} from './latency';

export async function scheduleReminders(env:Env,parentId:string,onlyIfScheduled=false,requestId=crypto.randomUUID()):Promise<void> {
 const response=await env.ALERT_REMINDERS.getByName(parentId).fetch(`https://reminders.internal/${onlyIfScheduled?'refresh':'schedule'}`,{
  method:'POST',body:parentId,headers:{'x-diagnostics-request-id':requestId}
 });
 if(!response.ok)throw new Error('Reminder scheduling unavailable.');
}

// One durable alarm per Parent, independent of microphone capture and app lifetime.
// D1 is authoritative for pairing, acknowledgements and mute state.
export class AlertReminders implements DurableObject {
 private revision=0;
 constructor(private ctx:DurableObjectState,private env:Env) {}
 private async arm(at:number):Promise<void> {
  await this.ctx.storage.put('dueAt',at);
  await this.ctx.storage.setAlarm(at);
 }
 async fetch(request:Request):Promise<Response> {
  const started=Date.now(),latency=new Latency();
  const incoming=request.headers.get('x-diagnostics-request-id'),requestId=incoming&&/^[0-9a-f-]{36}$/i.test(incoming)?incoming:crypto.randomUUID();
  try {
  const parentId=await request.text(),refresh=new URL(request.url).pathname==='/refresh';
  // External D1 work must never hold the object's concurrency lock. Retry a stale
  // read if an alarm or scheduling request changed state while it was pending.
  while(true){
   const revision=this.revision;
   const device=await latency.read<{config:string;alerts_muted_until:number}>('schedule_read_ms',this.env.DB.prepare('SELECT config,alerts_muted_until FROM devices WHERE id=?').bind(parentId));
   const interval=device&&configuration(JSON.parse(device.config)).repeatInterval===2?2000:5000;
   const applied=await latency.measure('schedule_state_ms',()=>this.ctx.blockConcurrencyWhile(async()=>{
    if(this.revision!==revision)return false;
    const scheduled=await this.ctx.storage.getAlarm();
    if(refresh&&scheduled===null)return true;
    await this.ctx.storage.put({parentId,interval});
    const next=(device?.alerts_muted_until??0)>Date.now()?device!.alerts_muted_until:Date.now()+interval;
    // A current snooze postpones reminders; ordinary duplicate scheduling
    // only advances the timer. The revision check rejects stale reads.
    if((device?.alerts_muted_until??0)>Date.now()||scheduled===null||scheduled>next)await this.arm(next);
    this.revision++;
    return true;
   }));
   if(applied)return new Response(null,{status:204});
  }
  }catch(error){latency.failure(error);await recordDiagnostic(this.env,{requestId,started,operation:'reminder_schedule',stage:'storage',outcome:'internal_error',details:latency.details});throw new Error('Reminder scheduling unavailable.');}
  finally{if(Date.now()-started>=2000&&!latency.details.error_kind)await recordDiagnostic(this.env,{requestId,started,operation:'reminder_schedule',stage:'storage',outcome:'ok',details:latency.details});}
 }
 async alarm():Promise<void> {
  const started=Date.now(),latency=new Latency();latency.details.dispatch_source='reminder';
  try {
   const state=await latency.measure('alarm_state_ms',()=>this.ctx.blockConcurrencyWhile(async()=>{
    const saved=await this.ctx.storage.get<string|number>(['parentId','interval','dueAt']);
    const parentId=saved.get('parentId');if(typeof parentId!=='string')return;
    const interval=saved.get('interval')===2000?2000:5000,dueAt=saved.get('dueAt');
    if(typeof dueAt==='number')latency.details.spans!.alarm_lag_ms=Math.max(0,started-dueAt);
    await latency.measure('alarm_arm_ms',()=>this.arm(started+interval));
    return {parentId,interval,revision:++this.revision};
   }));
   if(!state){
    latency.details.exit_reason='not_found';
    await recordDiagnostic(this.env,{requestId:crypto.randomUUID(),started,operation:'reminder_alarm',stage:'storage',outcome:'reminder_stopped',details:latency.details});return;
   }
   let nextInterval=state.interval,mutedUntil=0;
   const keep=await runReminder(this.env,state.parentId,latency,(interval,mute)=>{nextInterval=interval;mutedUntil=mute;});
   await latency.measure('alarm_finalize_ms',()=>this.ctx.blockConcurrencyWhile(async()=>{
    if(this.revision!==state.revision){latency.details.exit_reason='superseded';return;}
    if(!keep){await this.ctx.storage.deleteAlarm();await this.ctx.storage.delete(['parentId','interval','dueAt']);}
    else if(nextInterval!==state.interval||mutedUntil>Date.now()){
     await this.ctx.storage.put('interval',nextInterval);
     await this.arm(Math.max(Date.now()+1,started+nextInterval,mutedUntil));
    }
    this.revision++;
   }));
   // Finalization happens after the dispatch row; retain unusually slow tail work.
   if((latency.details.spans!.alarm_finalize_ms??0)>=2000)await recordDiagnostic(this.env,{requestId:crypto.randomUUID(),started,operation:'reminder_alarm',stage:'storage',outcome:'ok',eventRef:latency.eventRef,details:latency.details});
  }catch(error){
   latency.failure(error);
   await recordDiagnostic(this.env,{requestId:crypto.randomUUID(),started,operation:'reminder_alarm',stage:'handler',outcome:'internal_error',eventRef:latency.eventRef,details:latency.details});
   throw new Error('Reminder alarm failed.');
  }
 }
}

export async function runReminder(env:Env,parentId:string,latency=new Latency(),observed?:(interval:number,mutedUntil:number)=>void):Promise<boolean> {
 const now=Date.now();let handedOff=false,failed=false,stopped=false,eventId:string|undefined;
 latency.details.dispatch_source='reminder';latency.details.preparation_started_at_ms=now;
 const preparation=()=>{latency.details.spans!.reminder_prepare_ms=Date.now()-now;latency.details.preparation_finished_at_ms=Date.now();};
 const stop=(reason:typeof latency.details.exit_reason)=>{stopped=true;latency.details.exit_reason=reason;return false;};
 const send=async(id:string)=>{eventId=id;preparation();handedOff=true;await dispatchEvent(env,id,undefined,latency);};
 try {
 const read=async<T>(name:Span,statement:D1PreparedStatement)=>{const [result]=await latency.db<T>(name,()=>statement.all<T>());return result.results[0];};
 const pair=await read<{listener_id:string;created_at:number;alerts_muted_until:number;config:string}>('reminder_pair_ms',env.DB.prepare('SELECT p.listener_id,p.created_at,d.alerts_muted_until,d.config FROM pairs p JOIN devices d ON d.id=p.parent_id WHERE p.parent_id=?')
  .bind(parentId));
 if(!pair)return stop('no_pair');
 observed?.(configuration(JSON.parse(pair.config)).repeatInterval===2?2000:5000,pair.alerts_muted_until);
 const control=await latestMonitoringCommand(env,{parent_id:parentId,listener_id:pair.listener_id,created_at:pair.created_at},latency);
 if(control&&!control.enabled&&['pending','applied'].includes(control.status))return stop('monitoring_stopped');
 if(pair.alerts_muted_until>now){latency.details.exit_reason='muted';return true;}
 // An expired upload may have arrived after a live alert. Skip that row rather
 // than letting it shut down reminders for every other outstanding episode.
 let previous=await read<StoredEvent>('reminder_latest_ms',env.DB.prepare("SELECT * FROM events WHERE parent_id=? AND listener_id=? AND acknowledged_at IS NULL AND resolved_at IS NULL AND COALESCE(last_error,'')!='expired_event' AND COALESCE(json_extract(payload,'$.isTest'),0)=0 ORDER BY created_at DESC,event_id DESC LIMIT 1")
  .bind(parentId,pair.listener_id));
 if(!previous) {
  // After a mute, require a fresh Listener update confirming sustained crying.
  if(!pair.alerts_muted_until)return stop('no_pending_alert');
  const last=await read<{received_at:string;metadata:string}>('reminder_heartbeat_ms',env.DB.prepare('SELECT received_at,metadata FROM heartbeats WHERE listener_id=?').bind(pair.listener_id));
  if(!last||now-Date.parse(last.received_at)>45000)return stop('stale_heartbeat');
  const heartbeat=JSON.parse(last.metadata) as Heartbeat;
  const episode=heartbeat.currentEpisode;
  if(!heartbeat.monitoring||heartbeat.state!=='crying'||!episode)return stop('not_crying');
  if((now-Date.parse(episode.startedAt))/1000<configuration(JSON.parse(pair.config)).alertDuration)return stop('below_threshold');
  const original=await read<StoredEvent>('reminder_original_ms',env.DB.prepare("SELECT * FROM events WHERE parent_id=? AND episode_id=? AND resolved_at IS NULL AND COALESCE(last_error,'')!='expired_event' AND COALESCE(json_extract(payload,'$.isTest'),0)=0 ORDER BY created_at DESC LIMIT 1")
   .bind(parentId,episode.id));
  if(!original)return stop('no_pending_alert');
  previous=original;
 }
 // Preserve ordinary retry/backoff for an event not yet submitted.
 if(previous.acknowledged_at===null&&['pending','blocked','sending'].includes(previous.status)) {
  await send(previous.event_id);
  return true;
 }
 if(now-previous.created_at<(configuration(JSON.parse(pair.config)).repeatInterval ?? 5)*1000){latency.details.exit_reason='not_due';return true;}
 const source=JSON.parse(previous.payload) as Alert;
 const event:Alert={...source,eventId:crypto.randomUUID(),isRepeat:true,createdAt:new Date(now).toISOString()};
 eventId=event.eventId;
 // Keep the original measured duration: a reminder is not evidence of more crying.
 const [inserted]=await latency.db('reminder_insert_ms',()=>env.DB.prepare(`INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at,reminder_of)
 SELECT ?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs p JOIN devices d ON d.id=p.parent_id WHERE p.parent_id=? AND p.listener_id=? AND d.alerts_muted_until<=?)
 AND (SELECT acknowledged_at FROM events WHERE event_id=?) IS ?
 ON CONFLICT DO NOTHING`)
  .bind(event.eventId,event.episodeId,pair.listener_id,parentId,1,JSON.stringify(event),now,previous.event_id,parentId,pair.listener_id,now,previous.event_id,previous.acknowledged_at).run());
 if(inserted.meta.changes)await send(event.eventId);
 else latency.details.exit_reason='not_created';
 return true;
 }catch(error){failed=true;latency.failure(error);throw error;}
 finally {
  if(!handedOff){
   preparation();
   if(failed||stopped||eventId||Date.now()-now>=2000){
    let eventRef:string|undefined;try{if(eventId)eventRef=await eventReference(env,eventId);}catch{/* Best effort. */}
    await recordDiagnostic(env,{requestId:crypto.randomUUID(),started:now,operation:'reminder_prepare',stage:'storage',outcome:failed?'internal_error':stopped?'reminder_stopped':eventId?'reminder_not_created':'ok',eventRef,details:latency.details});
   }
  }
 }
}
