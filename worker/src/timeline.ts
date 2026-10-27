import {APIError,type Device,type Env,type Heartbeat} from './types';
import {pairFor} from './devices';

export interface TimelineEvent {
 id:string; kind:string; occurredAt:string; endAt?:string; episodeID?:string;
 target?:string; count?:number; status?:string;
}
type Pair={parent_id:string;listener_id:string;created_at:number};
const hour=3600000;
export function timelineInsert(env:Env,pair:Pair,event:TimelineEvent) {
 return env.DB.prepare(`INSERT INTO timeline_events(id,parent_id,listener_id,pair_created_at,kind,occurred_at,payload)
 SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?)
 ON CONFLICT DO NOTHING`).bind(event.id,pair.parent_id,pair.listener_id,pair.created_at,event.kind,Date.parse(event.occurredAt),JSON.stringify(event),pair.parent_id,pair.listener_id,pair.created_at);
}
export function missingHeartbeat(last:string):TimelineEvent {
 return {id:`missing:${last}`,kind:'heartbeat_missing',occurredAt:new Date(Date.parse(last)+180000).toISOString(),endAt:last};
}
// Local transitions survive offline stop/restart cycles. Server observations support
// older Listeners and bound coverage without turning every heartbeat into a log row.
export function heartbeatTimeline(env:Env,pair:Pair,beat:Heartbeat,previous:{received_at:string;metadata:string}|null,now:number) {
 const stamp=new Date(now).toISOString(),events:TimelineEvent[]=[];
 const old=previous?JSON.parse(previous.metadata) as Heartbeat:null;
 for(const event of beat.timelineEvents??[]) {
  const at=Date.parse(event.occurredAt);
  if(at>=pair.created_at&&at>=now-24*hour&&at<=now+5000)events.push(event);
 }
 if(previous&&now-Date.parse(previous.received_at)>180000&&(old?.monitoring||old?.microphoneActive)){
  events.push(missingHeartbeat(previous.received_at));
  events.push({id:`restored:${previous.received_at}`,kind:'connection_restored',occurredAt:stamp,endAt:previous.received_at});
 }
 // Never describe the first observation as an exact start/stop time.
 if(!old||old.monitoring!==beat.monitoring||old.microphoneActive!==beat.microphoneActive||previous&&now-Date.parse(previous.received_at)>180000)
  events.push({id:`state:${stamp}`,kind:beat.monitoring?'monitoring_observed':beat.microphoneActive?'standby_observed':'stopped_observed',occurredAt:stamp});
 events.push({id:`coverage:${Math.floor(now/hour)}`,kind:beat.monitoring?'coverage_active':beat.microphoneActive?'coverage_standby':'coverage_stopped',occurredAt:stamp});
 if(old&&!(beat.timelineEvents?.length)) {
  if(old.powerConnected!==beat.powerConnected)events.push({id:`power:${stamp}`,kind:beat.powerConnected?'power_connected':'power_disconnected',occurredAt:stamp});
 }
 if(beat.batteryLevel!=null&&beat.batteryLevel<0.2&&!beat.powerConnected&&
    (!old||old.powerConnected||old.batteryLevel==null||old.batteryLevel>=0.2))
  events.push({id:`battery:${stamp}`,kind:'battery_low',occurredAt:stamp});
 const episodes=[...beat.episodes,...(beat.currentEpisode?[beat.currentEpisode]:[])];
 for(const episode of episodes){
  events.push({id:`cry:${episode.id}`,kind:'cry_started',occurredAt:episode.startedAt,episodeID:episode.id});
  if(episode.endedAt)events.push({id:`cry-end:${episode.id}`,kind:'cry_ended',occurredAt:episode.endedAt,endAt:episode.startedAt,episodeID:episode.id});
 }
 const accepted=events.filter(e=>Date.parse(e.occurredAt)>=pair.created_at&&Date.parse(e.occurredAt)<=now+5000&&
  (!e.episodeID||!e.endAt||Date.parse(e.endAt)>=pair.created_at));
 return [env.DB.prepare(`INSERT INTO timeline_events(id,parent_id,listener_id,pair_created_at,kind,occurred_at,payload)
  SELECT json_extract(value,'$.id'),?,?,?,json_extract(value,'$.kind'),
  CAST(ROUND((julianday(json_extract(value,'$.occurredAt'))-2440587.5)*86400000) AS INTEGER),value
  FROM json_each(?) WHERE EXISTS(SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?)
  ON CONFLICT DO NOTHING`).bind(pair.parent_id,pair.listener_id,pair.created_at,JSON.stringify(accepted),pair.parent_id,pair.listener_id,pair.created_at)];
}

export async function timeline(env:Env,device:Device) {
 const pair=await pairFor(env,device),now=Date.now(),cutoff=now-12*hour;
 const metadata=await env.DB.prepare('SELECT available_since FROM timeline_metadata WHERE id=1').first<{available_since:number}>();
 if(!pair)return {paired:false,serverTime:new Date(now).toISOString(),availableSince:new Date(now).toISOString(),events:[],truncated:false};
 const [journal,boundary,groups,notices,last]=await Promise.all([
  env.DB.prepare('SELECT payload FROM timeline_events WHERE parent_id=? AND listener_id=? AND pair_created_at=? AND occurred_at>=? AND occurred_at<=? ORDER BY occurred_at DESC,id LIMIT 1001')
   .bind(pair.parent_id,pair.listener_id,pair.created_at,cutoff,now).all<{payload:string}>(),
  env.DB.prepare(`SELECT payload FROM timeline_events WHERE parent_id=? AND listener_id=? AND pair_created_at=? AND occurred_at<?
   AND kind IN ('monitoring_started','monitoring_stopped','monitoring_paused','audio_interrupted','audio_resumed','monitoring_unverified','monitoring_observed','stopped_observed','standby_observed','heartbeat_missing','connection_restored','coverage_active','coverage_stopped','coverage_standby') ORDER BY occurred_at DESC,id DESC LIMIT 1`)
   .bind(pair.parent_id,pair.listener_id,pair.created_at,cutoff).first<{payload:string}>(),
  env.DB.prepare(`SELECT episode_id,CASE WHEN delivery_state IS NOT NULL THEN 'both' ELSE push_target END AS push_target,status,COALESCE(json_extract(payload,'$.isTest'),0) AS test,
   COALESCE(json_extract(payload,'$.type')='listener_disconnected',0) AS disconnected,COUNT(*) AS count,MIN(COALESCE(sent_at,json_extract(payload,'$.createdAt'))) AS first_at,
   MAX(COALESCE(sent_at,json_extract(payload,'$.createdAt'))) AS last_at
   FROM events WHERE parent_id=? AND listener_id=? AND created_at>=? AND
   COALESCE(sent_at,json_extract(payload,'$.createdAt'))>=? AND COALESCE(sent_at,json_extract(payload,'$.createdAt'))<=?
   AND (acknowledged_at IS NULL OR sent_at IS NOT NULL)
   GROUP BY episode_id,CASE WHEN delivery_state IS NOT NULL THEN 'both' ELSE push_target END,status,test,disconnected ORDER BY first_at DESC LIMIT 401`)
   .bind(pair.parent_id,pair.listener_id,pair.created_at,new Date(cutoff).toISOString(),new Date(now).toISOString())
   .all<{episode_id:string;push_target:string|null;status:string;test:number;disconnected:number;count:number;first_at:string;last_at:string}>(),
  env.DB.prepare(`SELECT id,state,status,sent_at,created_at FROM connection_notices WHERE parent_id=? AND listener_id=? AND created_at>=? ORDER BY created_at DESC LIMIT 201`)
   .bind(pair.parent_id,pair.listener_id,Math.max(pair.created_at,cutoff)).all<{id:string;state:string;status:string;sent_at:string|null;created_at:number}>(),
  env.DB.prepare('SELECT received_at,metadata FROM heartbeats WHERE listener_id=?').bind(pair.listener_id).first<{received_at:string;metadata:string}>()
 ]);
 const events:TimelineEvent[]=journal.results.slice(0,1000).map(row=>JSON.parse(row.payload) as TimelineEvent);
 if(boundary)events.push(JSON.parse(boundary.payload) as TimelineEvent);
 for(const group of groups.results.slice(0,400))events.push({id:`alerts:${group.episode_id}:${group.push_target}:${group.status}:${group.test}`,
  kind:group.test?'test_alert':group.disconnected?'connection_alert':'alert',occurredAt:group.first_at,endAt:group.last_at,episodeID:group.episode_id,
  target:group.push_target??undefined,count:group.count,status:group.status});
 for(const notice of notices.results.slice(0,200)){
  if(notice.status==='cancelled'||notice.status==='escalated')continue;
  events.push({id:`notice:${notice.id}`,kind:'connection_alert',occurredAt:notice.sent_at??new Date(notice.created_at).toISOString(),status:notice.status});
 }
 // A delayed cron must not leave the currently missing heartbeat invisible.
 if(last&&(JSON.parse(last.metadata).monitoring===true||JSON.parse(last.metadata).microphoneActive===true)&&now-Date.parse(last.received_at)>180000){
  const missing=missingHeartbeat(last.received_at);if(!events.some(e=>e.id===missing.id))events.push(missing);
 }
 events.sort((a,b)=>Date.parse(b.occurredAt)-Date.parse(a.occurredAt)||a.id.localeCompare(b.id));
 return {paired:true,serverTime:new Date(now).toISOString(),lastHeartbeat:last?.received_at??null,availableSince:new Date(Math.max(pair.created_at,metadata?.available_since??now)).toISOString(),events,
  truncated:journal.results.length>1000||groups.results.length>400||notices.results.length>200};
}

export const localTimelineKinds=['monitoring_started','monitoring_stopped','monitoring_paused','audio_interrupted','audio_resumed','monitoring_unverified','power_connected','power_disconnected','network_lost','network_restored','cry_started','cry_ended'] as const;
export function validateTimelineEvents(value:unknown):TimelineEvent[] {
 if(!Array.isArray(value)||value.length>100)throw new APIError(400,'Invalid timeline batch.');
 return value.map(item=>{
  if(!item||typeof item!=='object'||Array.isArray(item))throw new APIError(400,'Invalid timeline event.');
  const v=item as Record<string,unknown>;
  const cry=v.kind==='cry_started'||v.kind==='cry_ended';
  const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const allowed=cry?['id','kind','occurredAt','episodeID','endAt']:['id','kind','occurredAt'];
  const validID=cry&&typeof v.episodeID==='string'&&uuid.test(v.episodeID)?
   v.id===`${v.kind==='cry_started'?'cry':'cry-end'}:${v.episodeID.toLowerCase()}`:typeof v.id==='string'&&uuid.test(v.id);
  if(Object.keys(v).some(key=>!allowed.includes(key))||!validID||
   !localTimelineKinds.includes(v.kind as typeof localTimelineKinds[number])||typeof v.occurredAt!=='string'||!Number.isFinite(Date.parse(v.occurredAt)))
   throw new APIError(400,'Invalid timeline event.');
  if(cry&&(typeof v.episodeID!=='string'||!uuid.test(v.episodeID)))throw new APIError(400,'Invalid timeline episode.');
  if(v.kind==='cry_ended'&&(typeof v.endAt!=='string'||!Number.isFinite(Date.parse(v.endAt))||Date.parse(v.endAt)>Date.parse(v.occurredAt)))
   throw new APIError(400,'Invalid timeline episode duration.');
  return {id:(v.id as string).toLowerCase(),kind:v.kind as string,occurredAt:new Date(v.occurredAt).toISOString(),
   ...(cry?{episodeID:(v.episodeID as string).toLowerCase()}:{}),...(v.kind==='cry_ended'?{endAt:new Date(v.endAt as string).toISOString()}:{})};
 });
}
