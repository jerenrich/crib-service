import {timelineInsert,missingHeartbeat} from './timeline';
import {APIError,requireRole,type Device,type Env} from './types';
import {sendConnectionPush,type PushResult} from './apns';
import {eventReference,recordDiagnostic} from './diagnostics';

export async function connectionPreferences(env:Env,device:Device,value:Record<string,unknown>) {
 requireRole(device,'parent');
 if(typeof value.enabled!=='boolean'||Object.keys(value).some(k=>k!=='enabled'))throw new APIError(400,'Choose whether to enable connection alerts.');
 await env.DB.batch([
  env.DB.prepare('UPDATE devices SET connection_alerts=? WHERE id=?').bind(Number(value.enabled),device.id),
  env.DB.prepare("UPDATE connection_notices SET status='cancelled' WHERE parent_id=? AND status IN ('pending','blocked') AND ?=0").bind(device.id,Number(value.enabled))
 ]);
 return {ok:true};
}

// Cron owns connection health, independently of either app being foregrounded.
// Atomic transition + unique notice key prevents duplicate notices across cron runs.
export async function flushConnections(env:Env,requestId=crypto.randomUUID()) {
 const now=Date.now();
 const rows=await env.DB.prepare(`SELECT p.parent_id,p.listener_id,h.received_at,h.metadata,s.state,p.created_at AS pair_created_at
 FROM pairs p JOIN heartbeats h ON h.listener_id=p.listener_id
 LEFT JOIN connection_states s ON s.listener_id=p.listener_id`).all<{parent_id:string;listener_id:string;received_at:string;metadata:string;state:string|null;pair_created_at:number}>();
 for(const row of rows.results){
  const active=JSON.parse(row.metadata).monitoring===true;
  const state=active?(now-Date.parse(row.received_at)>180000?'offline':'online'):'stopped';
  // Never warn about a device which has not started monitoring.
  if(!row.state){
   if(active)await env.DB.prepare("INSERT INTO connection_states(listener_id,state,changed_at) SELECT ?,'online',? WHERE EXISTS(SELECT 1 FROM pairs p JOIN heartbeats h ON h.listener_id=p.listener_id WHERE p.parent_id=? AND p.listener_id=? AND h.received_at=?) ON CONFLICT DO NOTHING").bind(row.listener_id,row.received_at,row.parent_id,row.listener_id,row.received_at).run();
   continue;
  }
  if(state==='offline')await timelineInsert(env,{parent_id:row.parent_id,listener_id:row.listener_id,created_at:row.pair_created_at},missingHeartbeat(row.received_at)).run();
  if(state===row.state)continue;
  await env.DB.batch([
   env.DB.prepare(`INSERT INTO connection_notices(id,listener_id,parent_id,state,observed_at,created_at)
    SELECT ?,?,?,?, ?,? FROM devices d JOIN pairs p ON p.parent_id=d.id
    JOIN connection_states s ON s.listener_id=p.listener_id JOIN heartbeats h ON h.listener_id=p.listener_id
    WHERE p.listener_id=? AND d.id=? AND d.connection_alerts=1 AND s.state=? AND h.received_at=? ON CONFLICT DO NOTHING`)
    .bind(crypto.randomUUID(),row.listener_id,row.parent_id,state,row.received_at,now,row.listener_id,row.parent_id,row.state,row.received_at),
   env.DB.prepare('UPDATE connection_states SET state=?,changed_at=? WHERE listener_id=? AND state=? AND EXISTS(SELECT 1 FROM heartbeats h WHERE h.listener_id=connection_states.listener_id AND h.received_at=?)').bind(state,row.received_at,row.listener_id,row.state,row.received_at)
  ]);
 }
 await env.DB.prepare("UPDATE connection_notices SET status='uncertain',lease_until=NULL WHERE status='sending' AND lease_until<?").bind(now).run();
 const pending=await env.DB.prepare(`SELECT n.id FROM connection_notices n WHERE n.status IN ('pending','blocked') AND n.next_attempt<=? ORDER BY n.created_at LIMIT 25`).bind(now).all<{id:string}>();
 for(const {id} of pending.results){
  const notice=await env.DB.prepare(`UPDATE connection_notices SET status='sending',lease_until=?,attempts=attempts+1 WHERE id=? AND status IN ('pending','blocked') RETURNING *`)
   .bind(now+30000,id).first<{id:string;parent_id:string;listener_id:string;state:string;created_at:number;attempts:number}>();
  if(!notice)continue;
  const context=await env.DB.prepare(`SELECT d.push_token,d.watch_push_token,d.connection_alerts,h.received_at,h.metadata
   FROM pairs p JOIN devices d ON d.id=p.parent_id JOIN heartbeats h ON h.listener_id=p.listener_id
   WHERE p.parent_id=? AND p.listener_id=?`).bind(notice.parent_id,notice.listener_id)
   .first<{push_token:string|null;watch_push_token:string|null;connection_alerts:number;received_at:string;metadata:string}>();
  const current=context?(JSON.parse(context.metadata).monitoring===true?(now-Date.parse(context.received_at)>180000?'offline':'online'):'stopped'):null;
  if(!context?.connection_alerts||current!==notice.state||now-notice.created_at>600000){
   await env.DB.prepare("UPDATE connection_notices SET status='cancelled',lease_until=NULL WHERE id=?").bind(id).run();continue;
  }
  const target=context.watch_push_token?'watch':'phone', token=context.watch_push_token??context.push_token;
  let result:PushResult={status:'blocked'};
  if(token){try{result=await sendConnectionPush(env,token,id,notice.state,target);}catch{result={status:'retry'};}}
  if(result.reason==='invalid_device_token'&&token){
   const column=target==='watch'?'watch_push_token':'push_token';
   await env.DB.batch([
    env.DB.prepare(`UPDATE devices SET ${column}=NULL WHERE id=? AND ${column}=?`).bind(notice.parent_id,token),
    env.DB.prepare("UPDATE connection_notices SET status='pending',next_attempt=?,lease_until=NULL WHERE id=?").bind(now+2000,id)
   ]);
  } else {
   // Unknown acceptance is terminal; never replay it to another destination.
   await env.DB.prepare("UPDATE connection_notices SET status=?,next_attempt=?,lease_until=NULL,sent_at=CASE WHEN ?='sent' THEN ? ELSE sent_at END WHERE id=?")
    .bind(result.status==='retry'?'pending':result.status,now+Math.min(300000,2000*2**Math.min(notice.attempts,8)),result.status,new Date().toISOString(),id).run();
  }
  let eventRef:string|undefined;try{eventRef=await eventReference(env,id);}catch{/* Diagnostics cannot change delivery. */}
  await recordDiagnostic(env,{requestId,started:now,operation:'dispatch',stage:'push',outcome:result.reason??result.status,eventRef,target,httpStatus:result.httpStatus});
 }
 await env.DB.prepare('DELETE FROM connection_notices WHERE created_at<?').bind(now-7*86400000).run();
}
