import type {Alert,Env,Heartbeat,StoredEvent} from './types';
import {configuration} from './security';
import {dispatchEvent} from './alerts';
import {recordDiagnostic,eventReference} from './diagnostics';
import {Latency,type Span} from './latency';
import {persistAcceptedDelivery,type AcceptedDelivery} from './accepted-delivery';
import {monitoringResumedSQL} from './monitoring';

const outcomePrefix='accepted/';
interface ReminderDelivery {
 background?:Pick<ExecutionContext,'waitUntil'>;
 accepted?:(delivery:AcceptedDelivery)=>Promise<void>;
 acceptedFor?:(eventId:string)=>Promise<AcceptedDelivery|undefined>;
}

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
 private flushing?:Promise<void>;
 private freshOutcomes=new Set<string>();
 private recentAccepted=new Map<string,AcceptedDelivery>();
 constructor(private ctx:DurableObjectState,private env:Env) {}
 private async hasOutcomes():Promise<boolean> {
  return (await this.ctx.storage.list({prefix:outcomePrefix,limit:1})).size>0;
 }
 private identity(delivery:AcceptedDelivery):string {
  // Legacy receipts predate checkpoint IDs and remain recoverable after rollout.
  return delivery.checkpointId??`${delivery.eventId}/${delivery.attempt}/${delivery.sentAt}`;
 }
 private async accept(delivery:AcceptedDelivery,external=false):Promise<void> {
  const started=performance.now();
  await this.ctx.blockConcurrencyWhile(async()=>{
   const applied=await this.ctx.storage.transaction(async transaction=>{
    const key=outcomePrefix+delivery.eventId;
    const existing=await transaction.get<AcceptedDelivery>(key)??this.recentAccepted.get(delivery.eventId);
    // A delayed/retried checkpoint cannot replace a newer owned attempt or the
    // first result for the same attempt. Checkpointing never authorizes replay.
    if(existing&&existing.attempt>=delivery.attempt)return false;
    const saved=await transaction.get<string|number>(['parentId','interval']);
    const interval=saved.get('interval')===2000?2000:5000;
    await transaction.put({[key]:delivery,parentId:delivery.parentId,interval});
    const scheduled=await transaction.getAlarm(),next=Date.now()+interval;
    if(scheduled===null||scheduled>next){await transaction.put('dueAt',next);await transaction.setAlarm(next);}
    return true;
   });
   if(applied){
    this.queueTiming(delivery,started);this.rememberAccepted(delivery);this.freshOutcomes.add(this.identity(delivery));
    if(external)this.revision++;
   }
  });
 }
 private queueTiming(delivery:AcceptedDelivery,started:number):void {
  const details=delivery.diagnostic.details??={},spans=details.spans??={};
  spans.outcome_queue_ms=Math.max(0,performance.now()-started);
 }
 private rememberAccepted(delivery:AcceptedDelivery):void {
  const previous=this.recentAccepted.get(delivery.eventId);
  if(previous&&previous.attempt>=delivery.attempt)return;
  this.recentAccepted.set(delivery.eventId,delivery);
  if(this.recentAccepted.size>128)this.recentAccepted.delete(this.recentAccepted.keys().next().value!);
 }
 private async acceptedFor(eventId:string):Promise<AcceptedDelivery|undefined> {
  // A snapshot may predate the result write even after its durable receipt was
  // deleted. Keep bounded proof in this isolate until its in-flight reads finish.
  return await this.ctx.storage.get<AcceptedDelivery>(outcomePrefix+eventId)??this.recentAccepted.get(eventId);
 }
 private flushOutcomes():Promise<void> {
  if(this.flushing)return this.flushing;
  this.flushing=this.writeOutcomes().finally(()=>{this.flushing=undefined;});
  return this.flushing;
 }
 private async writeOutcomes():Promise<void> {
  const outcomes=await this.ctx.storage.list<AcceptedDelivery>({prefix:outcomePrefix,limit:16});
  // Bound background work and never hold the object's concurrency lock on D1.
  // Slow results can overlap the next alarm, which consults the durable receipt.
  const entries=[...outcomes];
  // Reserve connection capacity for the next snapshot/claim and its proof read.
  for(let index=0;index<entries.length;index+=2)await Promise.all(entries.slice(index,index+2).map(async([key,saved])=>{
   const cached=this.recentAccepted.get(saved.eventId);
   const delivery=cached&&this.identity(cached)===this.identity(saved)?cached:saved;
   this.rememberAccepted(delivery);
   const recovery=!this.freshOutcomes.delete(this.identity(delivery));
   try {
    await persistAcceptedDelivery(this.env,delivery,recovery);
    // A D1 flush can outlive a newer attempt's checkpoint. Delete only the
    // specific receipt that finished, under a short local transaction.
    await this.ctx.storage.transaction(async transaction=>{
     const current=await transaction.get<AcceptedDelivery>(key);
     if(current&&this.identity(current)===this.identity(delivery))await transaction.delete(key);
    });
   }
   catch {/* Keep the receipt for the next alarm; never retry the Apple send. */}
  }));
 }
 private async arm(at:number):Promise<void> {
  // Snooze can postpone delivery, but not recovery of an already accepted result.
  if(await this.hasOutcomes())at=Math.min(at,Date.now()+5000);
  await this.ctx.storage.put('dueAt',at);
  await this.ctx.storage.setAlarm(at);
 }
 async fetch(request:Request):Promise<Response> {
  const started=Date.now(),latency=new Latency();
  const incoming=request.headers.get('x-diagnostics-request-id'),requestId=incoming&&/^[0-9a-f-]{36}$/i.test(incoming)?incoming:crypto.randomUUID();
  try {
  if(new URL(request.url).pathname==='/accepted'){
   const delivery=await request.json<AcceptedDelivery>();
   await this.accept(delivery,true);
   this.ctx.waitUntil(this.flushOutcomes().catch(()=>{}));
   return new Response(null,{status:204});
  }
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
    if(await this.hasOutcomes())await this.arm(Date.now()+5000);
    latency.details.exit_reason='not_found';
    await recordDiagnostic(this.env,{requestId:crypto.randomUUID(),started,operation:'reminder_alarm',stage:'storage',outcome:'reminder_stopped',details:latency.details});return;
   }
   let nextInterval=state.interval,mutedUntil=0;
   const keep=await runReminder(this.env,state.parentId,latency,(interval,mute)=>{nextInterval=interval;mutedUntil=mute;},
    {accepted:delivery=>this.accept(delivery),acceptedFor:id=>this.acceptedFor(id),background:this.ctx});
   await latency.measure('alarm_finalize_ms',()=>this.ctx.blockConcurrencyWhile(async()=>{
    if(this.revision!==state.revision){latency.details.exit_reason='superseded';return;}
    if(!keep){
     if(await this.hasOutcomes())await this.arm(Date.now()+5000);
     else {await this.ctx.storage.deleteAlarm();await this.ctx.storage.delete(['parentId','interval','dueAt']);}
    }
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
  }finally{
   // D1 persistence and its journal are not part of the serialized alarm's tail.
   // Storage/flush failures keep the pre-armed alarm as the recovery mechanism.
   this.ctx.waitUntil(this.flushOutcomes().catch(()=>{}));
  }
 }
}

function partiallyAccepted(event:StoredEvent):boolean {
 if(!event.delivery_state)return false;
 try{return Object.values(JSON.parse(event.delivery_state) as Record<string,string>).includes('sent');}catch{return false;}
}

export async function runReminder(env:Env,parentId:string,latency=new Latency(),observed?:(interval:number,mutedUntil:number)=>void,delivery:ReminderDelivery={}):Promise<boolean> {
 const now=Date.now(),startedMono=performance.now();let handedOff=false,failed=false,stopped=false,eventId:string|undefined;
 latency.details.dispatch_source='reminder';latency.details.preparation_started_at_ms=now;
 const preparation=()=>{latency.details.spans!.reminder_prepare_ms=Math.max(0,performance.now()-startedMono);latency.details.preparation_finished_at_ms=Date.now();};
 const stop=(reason:typeof latency.details.exit_reason)=>{stopped=true;latency.details.exit_reason=reason;return false;};
 const send=async(id:string,insert?:D1PreparedStatement)=>{if(insert&&await env.DB.prepare('SELECT 1 FROM caregiver_families WHERE owner_id=? AND partner_id IS NOT NULL').bind(parentId).first()){await insert.run();insert=undefined;}eventId=id;preparation();handedOff=true;await dispatchEvent(env,id,undefined,latency,{insert,accepted:delivery.accepted,background:delivery.background});};
 try {
 const read=async<T>(name:Span,statement:D1PreparedStatement)=>{const [result]=await latency.readOnly<T>(name,()=>statement.all<T>());return result.results[0];};
 // One consistent read-only snapshot replaces three sequential round trips.
 // All statements scope themselves to the current pairing, so a fallback cannot
 // mix a cached pair with control/event state from a replacement pairing.
 const snapshot=await latency.readOnly<unknown>('reminder_snapshot_ms',()=>env.DB.batch([
  env.DB.prepare('SELECT p.listener_id,p.created_at,d.alerts_muted_until,d.config FROM pairs p JOIN devices d ON d.id=p.parent_id WHERE p.parent_id=?').bind(parentId),
  env.DB.prepare(`SELECT m.enabled,m.status,m.expires_at FROM monitoring_commands m JOIN pairs p
   ON p.parent_id=m.parent_id AND p.listener_id=m.listener_id AND p.created_at=m.pair_created_at
   WHERE p.parent_id=? ORDER BY m.sequence DESC LIMIT 1`).bind(parentId),
  env.DB.prepare(`SELECT e.* FROM events e JOIN pairs p ON p.parent_id=e.parent_id AND p.listener_id=e.listener_id
   WHERE p.parent_id=? AND e.acknowledged_at IS NULL AND e.resolved_at IS NULL AND COALESCE(e.last_error,'')!='expired_event'
   AND COALESCE(json_extract(e.payload,'$.isTest'),0)=0 ORDER BY e.created_at DESC,e.event_id DESC LIMIT 1`).bind(parentId)
 ]),250);
 const pair=snapshot[0].results[0] as {listener_id:string;created_at:number;alerts_muted_until:number;config:string}|undefined;
 if(!pair)return stop('no_pair');
 observed?.(configuration(JSON.parse(pair.config)).repeatInterval===2?2000:5000,pair.alerts_muted_until);
 const control=snapshot[1].results[0] as {enabled:number;status:string;expires_at:number}|undefined;
 if(control&&!control.enabled&&(control.status==='applied'||control.status==='pending'&&control.expires_at>Date.now()))return stop('monitoring_stopped');
 if(pair.alerts_muted_until>now){latency.details.exit_reason='muted';return true;}
 // An expired upload may have arrived after a live alert. Skip that row rather
 // than letting it shut down reminders for every other outstanding episode.
 let previous=snapshot[2].results[0] as StoredEvent|undefined;
 if(!previous) {
  // An outage needs no Listener execution to resume after Snooze. A newer
  // heartbeat or opt-out resolves it; never manufacture an outage from stale cry data.
  previous=await read<StoredEvent>('reminder_original_ms',env.DB.prepare(`SELECT e.* FROM events e
   JOIN pairs p ON p.parent_id=e.parent_id AND p.listener_id=e.listener_id
   JOIN devices d ON d.id=p.parent_id JOIN heartbeats h ON h.listener_id=p.listener_id
   WHERE e.parent_id=? AND e.resolved_at IS NULL AND json_extract(e.payload,'$.type')='listener_disconnected'
    AND d.connection_alerts=1 AND json_extract(h.metadata,'$.monitoring')=1
    AND h.received_at=json_extract(e.payload,'$.cryStartedAt') AND h.received_at<?
   ORDER BY e.created_at DESC LIMIT 1`).bind(parentId,new Date(now-180000).toISOString()));
 }
 if(!previous) {
  // Likewise resume an unexpected monitoring stop after Snooze until the Listener
  // reports monitoring again, a person stops it (control check above) or unpairs.
  previous=await read<StoredEvent>('reminder_original_ms',env.DB.prepare(`SELECT events.* FROM events
   JOIN pairs p ON p.parent_id=events.parent_id AND p.listener_id=events.listener_id
   WHERE events.parent_id=? AND events.resolved_at IS NULL AND COALESCE(events.last_error,'')!='expired_event'
    AND json_extract(events.payload,'$.type')='monitoring_failed' AND NOT (${monitoringResumedSQL})
   ORDER BY events.created_at DESC LIMIT 1`).bind(parentId));
 }
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
 // A durable Apple receipt outranks a stale 'sending' row. It cannot override
 // acknowledgement/resolution or authorize a retry of an uncertain APNs call.
 if(['sending','uncertain'].includes(previous.status)&&delivery.acceptedFor){
  const accepted=await delivery.acceptedFor(previous.event_id);
  if(accepted?.parentId===parentId&&accepted.attempt===previous.attempts){
   if(!accepted.dual||Object.values(accepted.dual.states).every(state=>state==='sent'))previous={...previous,status:'sent'};
   else if(Object.values(accepted.dual.states).includes('sent'))previous={...previous,status:'pending',delivery_state:JSON.stringify(accepted.dual.states)};
  }
 }
 // Preserve ordinary retry/backoff for an event not yet submitted. Once either
 // destination accepted it, the other destination's retry (cron) or missing token
 // must not hold back reminders: repeat on schedule, as for a fully sent event.
 if(previous.acknowledged_at===null&&(previous.status==='sending'
  ||['pending','blocked'].includes(previous.status)&&!partiallyAccepted(previous))) {
  await send(previous.event_id);
  return true;
 }
 if(now-previous.created_at<(configuration(JSON.parse(pair.config)).repeatInterval ?? 5)*1000){latency.details.exit_reason='not_due';return true;}
 const source=JSON.parse(previous.payload) as Alert;
 const event:Alert={...source,eventId:crypto.randomUUID(),isRepeat:true,createdAt:new Date(now).toISOString()};
 eventId=event.eventId;
 // Keep the original measured duration: a reminder is not evidence of more crying.
 const insert=env.DB.prepare(`INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at,reminder_of)
 SELECT ?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs p JOIN devices d ON d.id=p.parent_id WHERE p.parent_id=? AND p.listener_id=? AND d.alerts_muted_until<=?)
 AND EXISTS(SELECT 1 FROM events WHERE event_id=? AND resolved_at IS NULL AND acknowledged_at IS ?)
 ON CONFLICT DO NOTHING`)
  .bind(event.eventId,event.episodeId,pair.listener_id,parentId,1,JSON.stringify(event),now,previous.event_id,parentId,pair.listener_id,now,previous.event_id,previous.acknowledged_at);
 // Insertion, suppression guards, claim and token read commit together. Cron
 // cannot claim the inserted event before this caller receives its batch reply.
 await send(event.eventId,insert);
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
