import {latestMonitoringCommand} from './monitoring';
import type {Alert,Env,Heartbeat,StoredEvent} from './types';
import {configuration} from './security';
import {dispatchEvent} from './alerts';

export const reminderInterval = 5000;

export async function scheduleReminders(env:Env,parentId:string):Promise<void> {
 const response=await env.ALERT_REMINDERS.getByName(parentId).fetch('https://reminders.internal/schedule',{
  method:'POST',body:parentId
 });
 if(!response.ok)throw new Error('Reminder scheduling unavailable.');
}

// One durable alarm per Parent, independent of microphone capture and app lifetime.
// D1 is authoritative for pairing, acknowledgements and mute state.
export class AlertReminders implements DurableObject {
 constructor(private ctx:DurableObjectState,private env:Env) {}
 async fetch(request:Request):Promise<Response> {
  const parentId=await request.text();
  return this.ctx.blockConcurrencyWhile(async()=>{
   await this.ctx.storage.put('parentId',parentId);
   // Duplicate uploads must not postpone an already scheduled reminder.
   const device=await this.env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parentId).first<{alerts_muted_until:number}>();
   if(device&&device.alerts_muted_until>Date.now())await this.ctx.storage.setAlarm(device.alerts_muted_until);
   else {
    const next=Date.now()+reminderInterval,scheduled=await this.ctx.storage.getAlarm();
    // Advance an older, slower timer without postponing any ready reminder.
    if(scheduled===null||scheduled>next)await this.ctx.storage.setAlarm(next);
   }
   return new Response(null,{status:204});
  });
 }
 async alarm():Promise<void> {
  await this.ctx.blockConcurrencyWhile(async()=>{
   const parentId=await this.ctx.storage.get<string>('parentId');
   if(!parentId)return;
   // Re-arm before external work so a transient DB/APNs failure cannot end reminders.
   await this.ctx.storage.setAlarm(Date.now()+reminderInterval);
   if(!await runReminder(this.env,parentId)) {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.delete('parentId');
   }
  });
 }
}

export async function runReminder(env:Env,parentId:string):Promise<boolean> {
 const now=Date.now();
 const pair=await env.DB.prepare('SELECT p.listener_id,p.created_at,d.alerts_muted_until,d.config FROM pairs p JOIN devices d ON d.id=p.parent_id WHERE p.parent_id=?')
  .bind(parentId).first<{listener_id:string;created_at:number;alerts_muted_until:number;config:string}>();
 if(!pair)return false;
 const control=await latestMonitoringCommand(env,{parent_id:parentId,listener_id:pair.listener_id,created_at:pair.created_at});
 if(control&&!control.enabled&&['pending','applied'].includes(control.status))return false;
 if(pair.alerts_muted_until>now)return true;
 // An expired upload may have arrived after a live alert. Skip that row rather
 // than letting it shut down reminders for every other outstanding episode.
 let previous=await env.DB.prepare("SELECT * FROM events WHERE parent_id=? AND listener_id=? AND acknowledged_at IS NULL AND resolved_at IS NULL AND COALESCE(last_error,'')!='expired_event' AND COALESCE(json_extract(payload,'$.isTest'),0)=0 ORDER BY created_at DESC,event_id DESC LIMIT 1")
  .bind(parentId,pair.listener_id).first<StoredEvent>();
 if(!previous) {
  // After a mute, require a fresh Listener update confirming sustained crying.
  if(!pair.alerts_muted_until)return false;
  const last=await env.DB.prepare('SELECT received_at,metadata FROM heartbeats WHERE listener_id=?').bind(pair.listener_id).first<{received_at:string;metadata:string}>();
  if(!last||now-Date.parse(last.received_at)>45000)return false;
  const heartbeat=JSON.parse(last.metadata) as Heartbeat;
  const episode=heartbeat.currentEpisode;
  if(!heartbeat.monitoring||heartbeat.state!=='crying'||!episode)return false;
  if((now-Date.parse(episode.startedAt))/1000<configuration(JSON.parse(pair.config)).alertDuration)return false;
  const original=await env.DB.prepare("SELECT * FROM events WHERE parent_id=? AND episode_id=? AND resolved_at IS NULL AND COALESCE(last_error,'')!='expired_event' AND COALESCE(json_extract(payload,'$.isTest'),0)=0 ORDER BY created_at DESC LIMIT 1")
   .bind(parentId,episode.id).first<StoredEvent>();
  if(!original)return false;
  previous=original;
 }
 // Preserve ordinary retry/backoff for an event not yet submitted.
 if(previous.acknowledged_at===null&&['pending','blocked','sending'].includes(previous.status)) {
  await dispatchEvent(env,previous.event_id);
  return true;
 }
 if(now-previous.created_at<reminderInterval)return true;
 const source=JSON.parse(previous.payload) as Alert;
 const event:Alert={...source,eventId:crypto.randomUUID(),isRepeat:true,createdAt:new Date(now).toISOString()};
 // Keep the original measured duration: a reminder is not evidence of more crying.
 const inserted=await env.DB.prepare(`INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at,reminder_of)
 SELECT ?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs p JOIN devices d ON d.id=p.parent_id WHERE p.parent_id=? AND p.listener_id=? AND d.alerts_muted_until<=?)
 AND (SELECT acknowledged_at FROM events WHERE event_id=?) IS ?
 ON CONFLICT DO NOTHING`)
  .bind(event.eventId,event.episodeId,pair.listener_id,parentId,1,JSON.stringify(event),now,previous.event_id,parentId,pair.listener_id,now,previous.event_id,previous.acknowledged_at).run();
 if(inserted.meta.changes)await dispatchEvent(env,event.eventId);
 return true;
}
