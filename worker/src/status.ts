import {APIError,defaultConfiguration,requireRole,type Device,type Env,type Heartbeat} from './types';
import {configuration,heartbeat as validateHeartbeat} from './security';
import {pairFor} from './devices';
export async function saveHeartbeat(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'listener');const heartbeat=validateHeartbeat(value);
 if(heartbeat.listenerId!==device.id)throw new APIError(403,'Listener identity mismatch.');
 const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Listener is not paired.');
 // Server receive time is authoritative for freshness, never a client's clock.
 await env.DB.prepare('INSERT INTO heartbeats(listener_id,received_at,metadata) VALUES(?,?,?) ON CONFLICT(listener_id) DO UPDATE SET received_at=excluded.received_at,metadata=excluded.metadata').bind(device.id,new Date().toISOString(),JSON.stringify(heartbeat)).run();
 const parent=await env.DB.prepare('SELECT config FROM devices WHERE id=?').bind(pair.parent_id).first<{config:string}>();
 return parent?JSON.parse(parent.config):defaultConfiguration;
}
export async function listenerStatus(env:Env,device:Device) {
 const pair=await pairFor(env,device);
 if(!pair)return {paired:false,watchPushRegistered:false,configuration:JSON.parse(device.config)};
 const [last,parent,events]=await Promise.all([
  env.DB.prepare('SELECT * FROM heartbeats WHERE listener_id=?').bind(pair.listener_id).first<{received_at:string;metadata:string}>(),
  env.DB.prepare('SELECT config,watch_push_token FROM devices WHERE id=?').bind(pair.parent_id).first<{config:string;watch_push_token:string|null}>(),
  env.DB.prepare('SELECT payload,status,sent_at,acknowledged_at,push_target FROM events WHERE parent_id=? ORDER BY created_at DESC LIMIT 100').bind(pair.parent_id).all<{payload:string;status:string;sent_at:string|null;acknowledged_at:string|null;push_target:string|null}>()
 ]);
 const metadata=last?JSON.parse(last.metadata) as Heartbeat:null;
 return {paired:true,listenerId:pair.listener_id,lastHeartbeat:last?.received_at??null,monitoring:metadata?.monitoring??false,batteryLevel:metadata?.batteryLevel??null,powerConnected:metadata?.powerConnected??false,state:metadata?.state??null,currentEpisode:metadata?.currentEpisode??null,episodes:metadata?.episodes??[],configuration:parent?JSON.parse(parent.config):defaultConfiguration,
 watchPushRegistered:parent?.watch_push_token!=null,
 alerts:events.results.map(event=>({...JSON.parse(event.payload),status:event.status,deliveryTarget:event.push_target,alertSentAt:event.sent_at,acknowledgedAt:event.acknowledged_at}))};
}
export async function saveSettings(env:Env,device:Device,value:Record<string,unknown>) {
 const config=configuration(value);const pair=await pairFor(env,device);
 if(!pair)throw new APIError(409,'Pair before changing shared settings.');
 await env.DB.prepare('UPDATE devices SET config=? WHERE id=?').bind(JSON.stringify(config),pair.parent_id).run();
 return {ok:true};
}
