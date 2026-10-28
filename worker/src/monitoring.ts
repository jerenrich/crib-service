import {APIError,requireRole,type Device,type Env} from './types';
import {onlyKeys,uuid} from './security';
import {pairFor} from './devices';
import type {Latency} from './latency';

type Pair={parent_id:string;listener_id:string;created_at:number};
type Command={id:string;enabled:number;status:'pending'|'applied'|'failed';created_at:number;expires_at:number};
export function monitoringCommandRepresentation(command:Command) {
 return {id:command.id,enabled:command.enabled===1,status:command.status==='pending'&&command.expires_at<=Date.now()?'expired':command.status,
  createdAt:new Date(command.created_at).toISOString(),expiresAt:new Date(command.expires_at).toISOString()};
}
export async function latestMonitoringCommand(env:Env,pair:Pair,latency?:Latency) {
 const statement=env.DB.prepare('SELECT * FROM monitoring_commands WHERE parent_id=? AND listener_id=? AND pair_created_at=? ORDER BY sequence DESC LIMIT 1')
  .bind(pair.parent_id,pair.listener_id,pair.created_at);
 const row=latency?await latency.read<Command>('reminder_control_ms',statement):await statement.first<Command>();
 return row?monitoringCommandRepresentation(row):null;
}
export async function requestMonitoring(env:Env,device:Device,value:Record<string,unknown>) {
 onlyKeys(value,['id','enabled']);const id=uuid(value.id);
 if(typeof value.enabled!=='boolean')throw new APIError(400,'Monitoring must be true or false.');
 const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Pair before controlling monitoring.');
 const now=Date.now(),enabled=Number(value.enabled),claim=crypto.randomUUID();
 // Listener requests report a local action. Parent requests await actual microphone confirmation.
 const status=device.role==='listener'?'applied':'pending';
 await env.DB.batch([
  env.DB.prepare(`INSERT INTO monitoring_commands(id,claim_id,parent_id,listener_id,pair_created_at,enabled,status,created_at,expires_at)
   SELECT ?,?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?) ON CONFLICT(id) DO NOTHING`)
   .bind(id,claim,pair.parent_id,pair.listener_id,pair.created_at,enabled,status,now,now+30000,pair.parent_id,pair.listener_id,pair.created_at),
  // Retire outstanding crying alerts as soon as Stop is requested. Test notifications stay independent.
  env.DB.prepare(`UPDATE events SET acknowledged_at=COALESCE(acknowledged_at,?) WHERE parent_id=? AND listener_id=?
   AND COALESCE(json_extract(payload,'$.isTest'),0)=0 AND ?=0
   AND EXISTS(SELECT 1 FROM monitoring_commands WHERE id=? AND claim_id=? AND parent_id=? AND listener_id=? AND enabled=0)`)
   .bind(new Date(now).toISOString(),pair.parent_id,pair.listener_id,enabled,id,claim,pair.parent_id,pair.listener_id)
 ]);
 const row=await env.DB.prepare('SELECT * FROM monitoring_commands WHERE id=? AND parent_id=? AND listener_id=? AND pair_created_at=?')
  .bind(id,pair.parent_id,pair.listener_id,pair.created_at).first<Command>();
 if(!row)throw new APIError(409,'Pairing changed.');
 if(row.enabled!==enabled)throw new APIError(409,'Monitoring request ID already used.');
 return monitoringCommandRepresentation(row);
}
export async function completeMonitoring(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'listener');onlyKeys(value,['id','succeeded']);const id=uuid(value.id);
 if(typeof value.succeeded!=='boolean')throw new APIError(400,'Invalid monitoring result.');
 const pair=await pairFor(env,device);if(!pair)throw new APIError(409,'Listener is not paired.');
 const result=await env.DB.prepare(`UPDATE monitoring_commands SET status=? WHERE id=? AND parent_id=? AND listener_id=? AND pair_created_at=?
  AND sequence=(SELECT MAX(sequence) FROM monitoring_commands WHERE parent_id=? AND listener_id=? AND pair_created_at=?)
  AND status='pending' AND expires_at>?`)
  .bind(value.succeeded?'applied':'failed',id,pair.parent_id,pair.listener_id,pair.created_at,pair.parent_id,pair.listener_id,pair.created_at,Date.now()).run();
 return {ok:result.meta.changes>0};
}

// A monitoring_failed episode ends once the Listener reports monitoring again.
// Compare Listener timestamps with each other, never with server time, so a
// skewed clock cannot let the pre-failure heartbeat retire the new alert.
// Reminders copy cryStartedAt (the stop time) but stamp createdAt on the server.
export const monitoringResumedSQL=`json_extract(events.payload,'$.type')='monitoring_failed' AND EXISTS(SELECT 1 FROM heartbeats h
 WHERE h.listener_id=events.listener_id AND json_extract(h.metadata,'$.monitoring')=1
 AND julianday(json_extract(h.metadata,'$.timestamp'))>julianday(json_extract(events.payload,'$.cryStartedAt')))`;
// A pending Stop suppresses late uploads; an applied Stop remains in force until
// either phone starts again. Never claim that this proves the microphone stopped.
export const stoppedMonitoringSQL=`EXISTS(SELECT 1 FROM monitoring_commands m JOIN pairs p
 ON p.parent_id=m.parent_id AND p.listener_id=m.listener_id AND p.created_at=m.pair_created_at
 WHERE m.parent_id=events.parent_id AND m.listener_id=events.listener_id AND m.enabled=0
 AND (m.status='applied' OR (m.status='pending' AND m.expires_at>?))
 AND m.sequence=(SELECT MAX(sequence) FROM monitoring_commands WHERE parent_id=m.parent_id AND listener_id=m.listener_id AND pair_created_at=m.pair_created_at))`;
