import {monitoringCommandRepresentation,monitoringResumedSQL} from './monitoring';
import {Latency} from './latency';
import {heartbeatTimeline} from './timeline';
import {scheduleReminders} from './reminders';
import {APIError,defaultConfiguration,requireRole,type Device,type Env,type Heartbeat} from './types';
import {configuration,heartbeat as validateHeartbeat} from './security';
import {pairFor} from './devices';
export async function saveHeartbeat(env:Env,device:Device,value:Record<string,unknown>,latency=new Latency()) {
 requireRole(device,'listener');const heartbeat=validateHeartbeat(value);
 if(heartbeat.listenerId!==device.id)throw new APIError(403,'Listener identity mismatch.');
 const [snapshot]=await latency.readOnly<{parent_id:string;listener_id:string;created_at:number;received_at:string|null;metadata:string|null}>('heartbeat_snapshot_ms',()=>env.DB.prepare(`SELECT p.parent_id,p.listener_id,p.created_at,h.received_at,h.metadata
  FROM pairs p LEFT JOIN heartbeats h ON h.listener_id=p.listener_id WHERE p.listener_id=?`).bind(device.id).all(),250);
 const pair=snapshot.results[0];if(!pair)throw new APIError(409,'Listener is not paired.');
 // A replacement pairing must not resurrect the previous family's history.
 heartbeat.episodes=heartbeat.episodes.filter(e=>Date.parse(e.startedAt)>=pair.created_at);
 if(heartbeat.currentEpisode&&Date.parse(heartbeat.currentEpisode.startedAt)<pair.created_at)heartbeat.currentEpisode=null;
 const previous=pair.received_at&&pair.metadata?{received_at:pair.received_at,metadata:pair.metadata}:null;
 const observedAt=Date.now(),receiptID=crypto.randomUUID();
 // Server receive time is authoritative for freshness, never a client's clock.
 const heartbeatWrite=env.DB.prepare('INSERT INTO heartbeats(listener_id,received_at,metadata) SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?) ON CONFLICT(listener_id) DO UPDATE SET received_at=excluded.received_at,metadata=excluded.metadata').bind(device.id,new Date().toISOString(),JSON.stringify({...heartbeat,__heartbeatReceipt:receiptID}),pair.parent_id,pair.listener_id,pair.created_at);
 // Only an explicit quiet reset retires alerts. Interruption, suspension, a
 // missing heartbeat and old clients' ended episodes are not evidence of quiet.
 const resolutions=heartbeat.episodes.filter(e=>e.quietConfirmed===true&&e.endedAt&&e.id!==heartbeat.currentEpisode?.id);
 const resolutionWrites=resolutions.map(e=>env.DB.prepare(`INSERT INTO resolved_episodes(parent_id,listener_id,pair_created_at,episode_id,resolved_at)
  SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?)
  ON CONFLICT DO NOTHING`).bind(pair.parent_id,pair.listener_id,pair.created_at,e.id,new Date(observedAt).toISOString(),pair.parent_id,pair.listener_id,pair.created_at));
 const retire=env.DB.prepare(`UPDATE events SET resolved_at=COALESCE(resolved_at,?) WHERE parent_id=? AND listener_id=? AND resolved_at IS NULL AND acknowledged_at IS NULL
  AND COALESCE(json_extract(payload,'$.isTest'),0)=0
  AND EXISTS(SELECT 1 FROM resolved_episodes r JOIN pairs p ON p.parent_id=r.parent_id AND p.listener_id=r.listener_id AND p.created_at=r.pair_created_at
   WHERE r.parent_id=events.parent_id AND r.listener_id=events.listener_id AND r.episode_id=events.episode_id)`)
  .bind(new Date(observedAt).toISOString(),pair.parent_id,pair.listener_id);
 const online=env.DB.prepare("INSERT INTO connection_states(listener_id,state,changed_at) SELECT ?,'online',? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?) ON CONFLICT DO NOTHING").bind(device.id,new Date(observedAt).toISOString(),pair.parent_id,pair.listener_id,pair.created_at);
 type Parent={config:string;alerts_muted_until:number};
 const result=await latency.confirmedWrite<unknown,Parent>('heartbeat',()=>env.DB.batch([heartbeatWrite,...heartbeatTimeline(env,pair,heartbeat,previous,observedAt),...resolutionWrites,...(resolutions.length?[retire]:[]),...(heartbeat.monitoring?[online]:[]),
  env.DB.prepare("UPDATE events SET resolved_at=COALESCE(resolved_at,?) WHERE parent_id=? AND listener_id=? AND resolved_at IS NULL AND json_extract(payload,'$.type')='listener_disconnected' AND EXISTS(SELECT 1 FROM heartbeats h WHERE h.listener_id=events.listener_id AND json_extract(h.metadata,'$.__heartbeatReceipt')=?)").bind(new Date(observedAt).toISOString(),pair.parent_id,pair.listener_id,receiptID),
  // Monitoring again (from this heartbeat) ends an unexpected-stop episode.
  ...(heartbeat.monitoring?[env.DB.prepare(`UPDATE events SET resolved_at=COALESCE(resolved_at,?) WHERE parent_id=? AND listener_id=? AND resolved_at IS NULL AND ${monitoringResumedSQL}`).bind(new Date(observedAt).toISOString(),pair.parent_id,pair.listener_id)]:[]),
  env.DB.prepare('SELECT d.config,d.alerts_muted_until FROM devices d JOIN pairs p ON p.parent_id=d.id WHERE p.parent_id=? AND p.listener_id=? AND p.created_at=?').bind(pair.parent_id,pair.listener_id,pair.created_at)
 ]),()=>env.DB.prepare(`SELECT d.config,d.alerts_muted_until FROM heartbeats h
  JOIN pairs p ON p.listener_id=h.listener_id JOIN devices d ON d.id=p.parent_id
  WHERE p.parent_id=? AND p.listener_id=? AND p.created_at=? AND json_extract(h.metadata,'$.__heartbeatReceipt')=?`)
  .bind(pair.parent_id,pair.listener_id,pair.created_at,receiptID).all<Parent>());
 if(result.source==='reply'&&!result.results[0].meta.changes)throw new APIError(409,'Pairing changed. Pair again.');
 const parent=result.source==='receipt'?result.receipt:result.results[result.results.length-1].results[0] as Parent|undefined;
 // Re-arm after a stale/offline mute-expiry check when the Listener reconnects.
 if(parent?.alerts_muted_until&&heartbeat.monitoring&&heartbeat.state==='crying'&&heartbeat.currentEpisode)await latency.measure('heartbeat_schedule_ms',()=>scheduleReminders(env,pair.parent_id));
 return parent?configuration(JSON.parse(parent.config)):defaultConfiguration;
}
export async function listenerStatus(env:Env,device:Device,latency=new Latency()) {
 const pair=await latency.read<{parent_id:string;listener_id:string;created_at:number}>('status_pair_ms',env.DB.prepare(`SELECT * FROM pairs WHERE ${device.role==='parent'?'parent_id':'listener_id'}=?`).bind(device.id));
 const unpaired=()=>({paired:false,watchPushRegistered:false,serverTime:new Date().toISOString(),nextHeartbeatExpectedAt:null,notificationRelevance:{cryEpisodeIDs:[],testEventIDs:[]},configuration:configuration(JSON.parse(device.config))});
 if(!pair)return unpaired();
 // One consistent snapshot instead of five concurrent binding calls. This
 // reduces database/connection pressure from ordinary status polling.
 const snapshot=await latency.db<unknown>('status_snapshot_ms',()=>env.DB.batch([
  env.DB.prepare('SELECT * FROM heartbeats WHERE listener_id=?').bind(pair.listener_id),
  env.DB.prepare('SELECT d.config,d.push_token,d.watch_push_token,d.connection_alerts,d.alerts_muted_until,d.silent_watch_alarms,d.alarm_app_wake,d.alarm_extension FROM devices d JOIN pairs p ON p.parent_id=d.id WHERE p.parent_id=? AND p.listener_id=? AND p.created_at=?').bind(pair.parent_id,pair.listener_id,pair.created_at),
  env.DB.prepare('SELECT payload,status,sent_at,acknowledged_at,resolved_at,push_target,delivery_state FROM events WHERE parent_id=? ORDER BY created_at DESC LIMIT 100').bind(pair.parent_id),
  env.DB.prepare('SELECT * FROM monitoring_commands WHERE parent_id=? AND listener_id=? AND pair_created_at=? ORDER BY sequence DESC LIMIT 1').bind(pair.parent_id,pair.listener_id,pair.created_at),
  env.DB.prepare(`SELECT DISTINCT CASE WHEN COALESCE(json_extract(payload,'$.isTest'),0)=1 THEN event_id ELSE episode_id END AS id,
   COALESCE(json_extract(payload,'$.isTest'),0) AS test FROM events WHERE parent_id=? AND listener_id=? AND acknowledged_at IS NULL AND resolved_at IS NULL LIMIT 1001`)
   .bind(pair.parent_id,pair.listener_id)
 ]));
 const last=snapshot[0].results[0] as {received_at:string;metadata:string}|undefined;
 const parent=snapshot[1].results[0] as {config:string;push_token:string|null;watch_push_token:string|null;connection_alerts:number;alerts_muted_until:number;silent_watch_alarms:number;alarm_app_wake:number;alarm_extension:number}|undefined;
 // Reject a pairing changed between lookup and this consistent snapshot.
 if(!parent)return unpaired();
 const events=snapshot[2] as D1Result<{payload:string;status:string;sent_at:string|null;acknowledged_at:string|null;resolved_at:string|null;push_target:string|null;delivery_state:string|null}>;
 const command=snapshot[3].results[0] as {id:string;enabled:number;status:'pending'|'applied'|'failed';created_at:number;expires_at:number}|undefined;
 const monitoringCommand=command?monitoringCommandRepresentation(command):null;
 const relevant=snapshot[4] as D1Result<{id:string;test:number}>;
 const metadata=last?JSON.parse(last.metadata) as Heartbeat:null;
 // An estimate, not a deadline: the Listener waits 15 seconds after its response.
 // Keep this anchored to the stored heartbeat so repeated reads cannot postpone it.
 const nextHeartbeatExpectedAt=last&&(metadata?.monitoring||metadata?.microphoneActive)?new Date(Date.parse(last.received_at)+15000).toISOString():null;
 return {paired:true,pairingID:`${pair.parent_id}|${pair.listener_id}|${pair.created_at}`,listenerId:pair.listener_id,lastHeartbeat:last?.received_at??null,monitoring:metadata?.monitoring??false,microphoneActive:metadata?.microphoneActive??metadata?.monitoring??false,batteryLevel:metadata?.batteryLevel??null,powerConnected:metadata?.powerConnected??false,state:metadata?.state??null,currentEpisode:metadata?.currentEpisode??null,episodes:metadata?.episodes??[],configuration:parent?configuration(JSON.parse(parent.config)):defaultConfiguration,
 serverTime:new Date().toISOString(),nextHeartbeatExpectedAt,monitoringCommand,
 watchPushRegistered:parent?.watch_push_token!=null,phonePushRegistered:parent?.push_token!=null,
 silentWatchAlarmsEnabled:parent?.silent_watch_alarms===1,
 alarmMethods:{appWake:parent?.alarm_app_wake!==0,extension:parent?.alarm_extension===1},
 alertsMutedUntil:parent?.alerts_muted_until?new Date(parent.alerts_muted_until).toISOString():null,
 connectionAlertsEnabled:parent?.connection_alerts===1,listenerConfiguration:metadata?.appliedConfiguration?configuration({...metadata.appliedConfiguration}):null,
 notificationRelevance:relevant.results.length>1000?null:{cryEpisodeIDs:relevant.results.filter(e=>!e.test).map(e=>e.id),testEventIDs:relevant.results.filter(e=>e.test).map(e=>e.id)},
 alerts:events.results.map(event=>({...JSON.parse(event.payload),status:event.status,deliveryTarget:event.delivery_state?'both':event.push_target,deliveryState:event.delivery_state?JSON.parse(event.delivery_state):undefined,alertSentAt:event.sent_at,acknowledgedAt:event.acknowledged_at,resolvedAt:event.resolved_at}))};
}
export async function saveSettings(env:Env,device:Device,value:Record<string,unknown>) {
 const config=configuration(value);const pair=await pairFor(env,device);
 if(!pair)throw new APIError(409,'Pair before changing shared settings.');
 const result=await env.DB.prepare(`UPDATE devices SET config=? WHERE id=?
  AND EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?)`)
  .bind(JSON.stringify(config),pair.parent_id,pair.parent_id,pair.listener_id,pair.created_at).run();
 if(!result.meta.changes)throw new APIError(409,'Pairing changed. Refresh before changing settings.');
 // Apply a faster cadence to an already active reminder timer immediately.
 await scheduleReminders(env,pair.parent_id,true);
 return {ok:true};
}
