import {APIError,requireRole,type Alert,type Device,type Env,type StoredEvent} from './types';
import {alert as validateAlert,uuid} from './security';
import {pairFor} from './devices';
import {sendPush} from './apns';
export async function receiveAlert(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'listener');const alert=validateAlert(value);
 if(alert.listenerId!==device.id)throw new APIError(403,'Listener identity mismatch.');
 const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Listener is not paired.');
 const previous=await env.DB.prepare('SELECT * FROM events WHERE event_id=?').bind(alert.eventId).first<StoredEvent>();
 if(previous){
  if(previous.listener_id!==device.id||previous.payload!==JSON.stringify(alert))throw new APIError(409,'Event UUID already used for different metadata.');
 }else{
  // Unique index also prevents a buggy client creating another initial UUID for an episode.
  await env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT DO NOTHING')
   .bind(alert.eventId,alert.episodeId,device.id,pair.parent_id,Number(alert.isRepeat),JSON.stringify(alert),Date.now()).run();
 }
 let record=await env.DB.prepare('SELECT * FROM events WHERE event_id=?').bind(alert.eventId).first<StoredEvent>();
 if(record && (record.listener_id!==device.id || record.payload!==JSON.stringify(alert)))throw new APIError(409,'Event UUID already used for different metadata.');
 if(!record){
  record=await env.DB.prepare('SELECT * FROM events WHERE listener_id=? AND episode_id=? AND is_repeat=0').bind(device.id,alert.episodeId).first<StoredEvent>();
 }
 if(!record)throw new APIError(409,'Event conflict.');
 await dispatchEvent(env,record.event_id);
 const result=await env.DB.prepare('SELECT status,acknowledged_at FROM events WHERE event_id=?').bind(record.event_id).first<{status:string;acknowledged_at:string|null}>();
 return {status:result?.acknowledged_at?'acknowledged':result?.status??'pending'};
}
export async function dispatchEvent(env:Env,eventId:string):Promise<void> {
 const now=Date.now();
 const event=await env.DB.prepare("UPDATE events SET status='sending',lease_until=?,attempts=attempts+1,push_target=COALESCE(push_target,CASE WHEN (SELECT watch_push_token FROM devices WHERE id=events.parent_id) IS NOT NULL THEN 'watch' ELSE 'phone' END) WHERE event_id=? AND status='pending' AND acknowledged_at IS NULL AND next_attempt<=? RETURNING *").bind(now+30000,eventId,now).first<StoredEvent>();
 if(!event)return;
 // No replay after uncertain transport or a worker death during APNs dispatch. APNs does
 // not offer an exactly-once receipt transaction with D1. Surface uncertainty explicitly.
 if(now-Date.parse((JSON.parse(event.payload) as Alert).createdAt)>86400000){
  await env.DB.prepare("UPDATE events SET status='failed',last_error='expired_event',lease_until=NULL WHERE event_id=?").bind(eventId).run();return;
 }
 const target=event.push_target??'phone';
 const column=target==='watch'?'watch_push_token':'push_token';
 const parent=await env.DB.prepare(`SELECT ${column} AS token FROM devices WHERE id=?`).bind(event.parent_id).first<{token:string|null}>();
 if(!parent?.token){
  // A token upload can race with this read. Decide blocked/pending in the same
  // database statement that releases the claim, so either ordering can recover.
  await env.DB.prepare("UPDATE events SET status=CASE WHEN EXISTS(SELECT 1 FROM devices WHERE id=parent_id AND (push_token IS NOT NULL OR watch_push_token IS NOT NULL)) THEN 'pending' ELSE 'blocked' END,last_error='no_push_token',lease_until=NULL,push_target=NULL WHERE event_id=? AND status='sending'").bind(eventId).run();return;
 }
 let result;
 try{result=await sendPush(env,parent.token,JSON.parse(event.payload) as Alert,target);}
 catch{result={status:'retry' as const,reason:'apns_configuration'};}
 const status=result.status==='retry'?'pending':result.status;
 const next=now+Math.min(300000,2000*2**Math.min(event.attempts,8));
 if(result.reason==='invalid_device_token'){
  // Atomically invalidate only the rejected token and release the event. A
  // replacement uploaded during APNs dispatch must remain eligible for retry.
  await env.DB.batch([
   env.DB.prepare(`UPDATE devices SET ${column}=NULL WHERE id=? AND ${column}=?`).bind(event.parent_id,parent.token),
   env.DB.prepare("UPDATE events SET status=CASE WHEN EXISTS(SELECT 1 FROM devices WHERE id=parent_id AND (push_token IS NOT NULL OR watch_push_token IS NOT NULL)) THEN 'pending' ELSE 'blocked' END,next_attempt=0,lease_until=NULL,push_target=NULL,last_error=? WHERE event_id=? AND status='sending'").bind(result.reason,eventId)
  ]);
  return;
 }
 await env.DB.prepare('UPDATE events SET status=?,next_attempt=?,lease_until=NULL,sent_at=?,last_error=? WHERE event_id=? AND status=\'sending\'')
  .bind(status,next,status==='sent'?new Date().toISOString():null,result.reason??null,eventId).run();
}
export async function acknowledge(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');const id=uuid(value.eventId);
 const result=await env.DB.prepare('UPDATE events SET acknowledged_at=COALESCE(acknowledged_at,?) WHERE episode_id=(SELECT episode_id FROM events WHERE event_id=? AND parent_id=?) AND parent_id=?').bind(new Date().toISOString(),id,device.id,device.id).run();
 if(!result.meta.changes)throw new APIError(404,'Alert not found.');return {ok:true};
}
export async function flushPending(env:Env) {
 await env.DB.prepare("UPDATE events SET status='uncertain',last_error='dispatch_interrupted',lease_until=NULL WHERE status='sending' AND lease_until<?").bind(Date.now()).run();
 const events=await env.DB.prepare("SELECT event_id FROM events WHERE status='pending' AND acknowledged_at IS NULL AND next_attempt<=? ORDER BY created_at LIMIT 25").bind(Date.now()).all<{event_id:string}>();
 // Bounded fan-out; each row has an atomic database claim.
 for(let index=0;index<events.results.length;index+=5){await Promise.all(events.results.slice(index,index+5).map(event=>dispatchEvent(env,event.event_id)));}
 // Keep deduplication tombstones for 30 days. Codes are short-lived; claimed codes retain
 // enough time to recover a lost claim response. Status metadata retains max 100 episodes.
 await env.DB.batch([
  env.DB.prepare('DELETE FROM events WHERE created_at<?').bind(Date.now()-30*86400000),
  env.DB.prepare('DELETE FROM pairing_codes WHERE expires_at<?').bind(Date.now()-86400000),
  env.DB.prepare('DELETE FROM rate_limits WHERE window<?').bind(Math.floor(Date.now()/1000/600)-144)
 ]);
}
