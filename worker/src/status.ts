import {scheduleReminders} from './reminders';
import {APIError,defaultConfiguration,requireRole,type Device,type Env,type Heartbeat} from './types';
import {configuration,heartbeat as validateHeartbeat} from './security';
import {pairFor} from './devices';
export async function saveHeartbeat(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'listener');const heartbeat=validateHeartbeat(value);
 if(heartbeat.listenerId!==device.id)throw new APIError(403,'Listener identity mismatch.');
 const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Listener is not paired.');
 // A replacement pairing must not resurrect the previous family's history.
 heartbeat.episodes=heartbeat.episodes.filter(e=>Date.parse(e.startedAt)>=pair.created_at);
 if(heartbeat.currentEpisode&&Date.parse(heartbeat.currentEpisode.startedAt)<pair.created_at)heartbeat.currentEpisode=null;
 // Server receive time is authoritative for freshness, never a client's clock.
 const saved=await env.DB.prepare('INSERT INTO heartbeats(listener_id,received_at,metadata) SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?) ON CONFLICT(listener_id) DO UPDATE SET received_at=excluded.received_at,metadata=excluded.metadata').bind(device.id,new Date().toISOString(),JSON.stringify(heartbeat),pair.parent_id,pair.listener_id,pair.created_at).run();
 if(!saved.meta.changes)throw new APIError(409,'Pairing changed. Pair again.');
 if(heartbeat.monitoring)await env.DB.prepare("INSERT INTO connection_states(listener_id,state,changed_at) SELECT ?,'online',? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?) ON CONFLICT DO NOTHING").bind(device.id,new Date().toISOString(),pair.parent_id,pair.listener_id,pair.created_at).run();
 const parent=await env.DB.prepare('SELECT config,alerts_muted_until FROM devices WHERE id=?').bind(pair.parent_id).first<{config:string;alerts_muted_until:number}>();
 // Re-arm after a stale/offline mute-expiry check when the Listener reconnects.
 if(parent?.alerts_muted_until&&heartbeat.monitoring&&heartbeat.state==='crying'&&heartbeat.currentEpisode)await scheduleReminders(env,pair.parent_id);
 return parent?configuration(JSON.parse(parent.config)):defaultConfiguration;
}
export async function listenerStatus(env:Env,device:Device) {
 const pair=await pairFor(env,device);
 if(!pair)return {paired:false,watchPushRegistered:false,serverTime:new Date().toISOString(),nextHeartbeatExpectedAt:null,configuration:configuration(JSON.parse(device.config))};
 const [last,parent,events]=await Promise.all([
  env.DB.prepare('SELECT * FROM heartbeats WHERE listener_id=?').bind(pair.listener_id).first<{received_at:string;metadata:string}>(),
  env.DB.prepare('SELECT config,push_token,watch_push_token,connection_alerts,alerts_muted_until FROM devices WHERE id=?').bind(pair.parent_id).first<{config:string;push_token:string|null;watch_push_token:string|null;connection_alerts:number;alerts_muted_until:number}>(),
  env.DB.prepare('SELECT payload,status,sent_at,acknowledged_at,push_target FROM events WHERE parent_id=? ORDER BY created_at DESC LIMIT 100').bind(pair.parent_id).all<{payload:string;status:string;sent_at:string|null;acknowledged_at:string|null;push_target:string|null}>()
 ]);
 const metadata=last?JSON.parse(last.metadata) as Heartbeat:null;
 // An estimate, not a deadline: the Listener waits 15 seconds after its response.
 // Keep this anchored to the stored heartbeat so repeated reads cannot postpone it.
 const nextHeartbeatExpectedAt=last&&metadata?.monitoring?new Date(Date.parse(last.received_at)+15000).toISOString():null;
 return {paired:true,pairingID:`${pair.parent_id}|${pair.listener_id}|${pair.created_at}`,listenerId:pair.listener_id,lastHeartbeat:last?.received_at??null,monitoring:metadata?.monitoring??false,batteryLevel:metadata?.batteryLevel??null,powerConnected:metadata?.powerConnected??false,state:metadata?.state??null,currentEpisode:metadata?.currentEpisode??null,episodes:metadata?.episodes??[],configuration:parent?configuration(JSON.parse(parent.config)):defaultConfiguration,
 serverTime:new Date().toISOString(),nextHeartbeatExpectedAt,
 watchPushRegistered:parent?.watch_push_token!=null,phonePushRegistered:parent?.push_token!=null,
 alertsMutedUntil:parent?.alerts_muted_until?new Date(parent.alerts_muted_until).toISOString():null,
 connectionAlertsEnabled:parent?.connection_alerts===1,listenerConfiguration:metadata?.appliedConfiguration?configuration({...metadata.appliedConfiguration}):null,
 alerts:events.results.map(event=>({...JSON.parse(event.payload),status:event.status,deliveryTarget:event.push_target,alertSentAt:event.sent_at,acknowledgedAt:event.acknowledged_at}))};
}
export async function saveSettings(env:Env,device:Device,value:Record<string,unknown>) {
 const config=configuration(value);const pair=await pairFor(env,device);
 if(!pair)throw new APIError(409,'Pair before changing shared settings.');
 await env.DB.prepare('UPDATE devices SET config=? WHERE id=?').bind(JSON.stringify(config),pair.parent_id).run();
 return {ok:true};
}
