import {runReminder} from '../src/reminders';
import {env,applyD1Migrations,runInDurableObject,runDurableObjectAlarm} from 'cloudflare:test';
import {beforeAll,afterEach,beforeEach,describe,it,expect,vi} from 'vitest';
import worker from '../src/index';
import {defaultConfiguration,type Env,type Alert} from '../src/types';
import {payload,apnsToken} from '../src/apns';
import {ProviderTokenCache,providerTokens} from '../src/provider-token';
import {deliverToBoth} from '../src/dual-delivery';
import {encryptToken,decryptToken,sha256} from '../src/security';
import {flushPending,dispatchEvent} from '../src/alerts';
import {eventReference,recordDiagnostic} from '../src/diagnostics';
import {flushConnections} from '../src/connections';
import {soundFrame} from '../src/live-sound';
import {reserveAlarmRequest} from '../src/alarm-scheduling';

let testEnv:Env;
const secret=btoa('0123456789abcdef0123456789abcdef');
function device(role:'listener'|'parent'){return {deviceId:crypto.randomUUID(),role,secret};}
type TestDevice=ReturnType<typeof device>;
async function call(path:string,device?:TestDevice,body?:unknown,method='POST'){
 return worker.fetch(new Request(`https://monitor.test/v1/${path}`,{method,headers:{'content-type':'application/json','CF-Connecting-IP':'127.0.0.1',...(device?{authorization:`Bearer ${device.deviceId}.${device.secret}`}:{})},body:method==='GET'?undefined:JSON.stringify(body??{})}),testEnv);
}
async function register(d:TestDevice){expect((await call('device/register',undefined,d)).status).toBe(200);}
async function paired(){
 const parent=device('parent'),listener=device('listener');await register(parent);await register(listener);
 const code=await (await call('pairing/create',parent)).json() as {code:string;expiresAt:string};
 expect((await call('pairing/claim',listener,{code:code.code})).status).toBe(200);
 return {parent,listener,code};
}
function alert(listener:TestDevice):Alert {
 const started=new Date(Date.now()-300000).toISOString();
 return {eventId:crypto.randomUUID(),episodeId:crypto.randomUUID(),listenerId:listener.deviceId,type:'sustained_cry',cryStartedAt:started,durationSeconds:300,createdAt:new Date().toISOString(),isRepeat:false};
}
let pushResponses: (Response | Error | {body:string;status:number;headers?:Record<string,string>})[] = [];
let pushRequests: {url:string;init?:RequestInit}[] = [];
function mockPush(status=200,times=1){
 for(let i=0;i<times;i++)pushResponses.push({body:status===200?'':JSON.stringify({reason:'ServiceUnavailable'}),status});
}

beforeAll(async()=>{
 await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);
 testEnv={...env};
});
beforeEach(async()=>{
 await env.DB.batch(['resolved_episodes','monitoring_commands','alert_snoozes','timeline_events','diagnostics','connection_notices','connection_states','events','heartbeats','pairs','pairing_codes','devices','rate_limits'].map(table=>env.DB.prepare(`DELETE FROM ${table}`)));
 pushResponses=[];pushRequests=[];
 vi.stubGlobal('fetch',vi.fn(async(input:string|URL|Request,init?:RequestInit)=>{
  const url=String(input);expect(url).toMatch(/^https:\/\/api\.sandbox\.push\.apple\.com\/3\/device\//);
  pushRequests.push({url,init});
  const response=pushResponses.shift();if(!response)throw new Error('Unexpected external request');
  if(response instanceof Error)throw response;return response instanceof Response?response:new Response(response.body,{status:response.status,headers:response.headers});
 }));
});
afterEach(()=>{try{expect(pushResponses).toHaveLength(0);}finally{vi.unstubAllGlobals();vi.restoreAllMocks();}});

describe('shared settings pairing changes',()=>{
 it.each(['unpaired','replacement','same devices'] as const)('rejects an in-flight settings write after %s',async(change)=>{
  const {parent,listener}=await paired();
  // Give even a same-device re-pair a distinct relationship version.
  await env.DB.prepare('UPDATE pairs SET created_at=created_at-1 WHERE parent_id=?').bind(parent.deviceId).run();
  let entered!:()=>void,release!:()=>void;
  const ready=new Promise<void>(r=>{entered=r;}),gate=new Promise<void>(r=>{release=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();
   if(sql==='SELECT * FROM pairs WHERE listener_id=?'&&method==='first'){entered();await gate;}
   return result;
  });
  const request=new Request('https://monitor.test/v1/settings',{method:'POST',headers:{
   'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`
  },body:JSON.stringify({...defaultConfiguration,alertDuration:3600})});
  const pending=worker.fetch(request,{...testEnv,DB:db});await ready;
  try {
   expect((await call('pairing/remove',parent)).status).toBe(200);
   if(change!=='unpaired'){
    const next=change==='same devices'?listener:device('listener');
    if(change==='replacement')await register(next);
    const {code}=await (await call('pairing/create',parent)).json() as {code:string};
    expect((await call('pairing/claim',next,{code})).status).toBe(200);
    expect((await call('settings',next,{...defaultConfiguration,alertDuration:30})).status).toBe(200);
   }
  } finally { release(); }
  expect((await pending).status).toBe(409);
  const saved=await env.DB.prepare('SELECT config FROM devices WHERE id=?').bind(parent.deviceId).first<{config:string}>();
  expect(JSON.parse(saved!.config).alertDuration).toBe(change==='unpaired'?defaultConfiguration.alertDuration:30);
 });
});

describe('APNs readiness diagnostics',()=>{
 it('requires a Parent, returns only safe reuse evidence, sends no pushes and enforces its budget',async()=>{
  expect((await call('diagnostics/apns')).status).toBe(401);
  const parent=device('parent'),listener=device('listener');await register(parent);await register(listener);
  expect((await call('diagnostics/apns',listener)).status).toBe(403);
  let reference:string|undefined;
  for(let i=0;i<6;i++){
   const response=await call('diagnostics/apns',parent);expect(response.status).toBe(200);
   const result=await response.json() as {ready:boolean;tokenRef:string;ageSeconds:number;source:string};
   expect(Object.keys(result).sort()).toEqual(['ageSeconds','ready','source','tokenRef']);
   expect(result.ready).toBe(true);expect(result.tokenRef).toMatch(/^[0-9a-f]{64}$/);
   if(reference)expect(result.tokenRef).toBe(reference);reference=result.tokenRef;
  }
  expect((await call('diagnostics/apns',parent)).status).toBe(429);expect(pushRequests).toHaveLength(0);
 });
});

describe('connection alerts, readiness and replacement',()=>{
 const beat=(listener:TestDevice,monitoring=true,appliedConfiguration=defaultConfiguration)=>({listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring,powerConnected:true,state:'quiet',episodes:[],appliedConfiguration});
 async function stale(){await env.DB.prepare('UPDATE heartbeats SET received_at=?').bind(new Date(Date.now()-240000).toISOString()).run();}
 it('does not let a stale concurrent candidate bypass a newer retry backoff',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await call('listener/heartbeat',listener,beat(listener,false));
  let entered!:()=>void,release!:()=>void;
  const ready=new Promise<void>(r=>{entered=r;}),gate=new Promise<void>(r=>{release=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();
   if(sql.startsWith('SELECT n.id FROM connection_notices')&&method==='all'){entered();await gate;}
   return result;
  });
  vi.mocked(fetch).mockImplementation(async(input,init)=>{pushRequests.push({url:String(input),init});return new Response(JSON.stringify({reason:'ServiceUnavailable'}),{status:503});});
  const first=flushConnections({...testEnv,DB:db});await ready;
  try{await flushConnections(testEnv);}finally{release();await first;}
  expect(pushRequests).toHaveLength(1);
  expect(await env.DB.prepare('SELECT attempts,status FROM connection_notices').first()).toMatchObject({attempts:1,status:'pending'});
 });
 it('gives later notices fresh leases after an earlier send takes time',async()=>{
  for(const token of ['ab','cd']){
   const {parent,listener}=await paired();await call('device/push-token',parent,{token:token.repeat(32)});
   await call('listener/heartbeat',listener,beat(listener));
   await call('listener/heartbeat',listener,beat(listener,false));
  }
  const start=Date.now();vi.spyOn(Date,'now').mockReturnValue(start);
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});
   if(pushRequests.length===1)vi.mocked(Date.now).mockReturnValue(start+31000);
   else{
    const id=new Headers(init?.headers).get('apns-id');
    const claim=await env.DB.prepare('SELECT lease_until FROM connection_notices WHERE id=?').bind(id).first<{lease_until:number}>();
    expect(claim!.lease_until).toBeGreaterThan(Date.now());
   }
   return new Response(null,{status:200});
  });
  await flushConnections(testEnv);expect(pushRequests).toHaveLength(2);
  expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM connection_notices WHERE status='sent'").first()).toEqual({n:2});
 });
 it('does not send a connection warning after a claim reply arrives past its lease',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await call('listener/heartbeat',listener,beat(listener,false));
  const start=Date.now();vi.spyOn(Date,'now').mockReturnValue(start);
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();
   if(sql.startsWith("UPDATE connection_notices SET status='sending'")&&method==='all')vi.mocked(Date.now).mockReturnValue(start+31000);
   return result;
  });
  vi.mocked(fetch).mockImplementation(async(input,init)=>{pushRequests.push({url:String(input),init});return new Response(null,{status:200});});
  await flushConnections({...testEnv,DB:db});expect(pushRequests).toHaveLength(0);
  expect(await env.DB.prepare('SELECT status,lease_until FROM connection_notices').first()).toEqual({status:'pending',lease_until:null});
 });
 it('defaults connection alerts on, respects opt-out and emits one notice per outage with quiet recovery',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  expect((await call('connection-alerts',listener,{enabled:true})).status).toBe(403);
  expect((await call('connection-alerts',parent,{enabled:'yes'})).status).toBe(400);
  const initial=await (await call('listener/status',parent,undefined,'GET')).json() as {connectionAlertsEnabled:boolean};
  expect(initial.connectionAlertsEnabled).toBe(true);
  await call('connection-alerts',parent,{enabled:false});
  await call('listener/heartbeat',listener,beat(listener));
  await stale();await flushConnections(testEnv);expect(pushRequests).toHaveLength(0);
  await call('listener/heartbeat',listener,beat(listener));await flushConnections(testEnv);
  await call('connection-alerts',parent,{enabled:true});
  await stale();mockPush();await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);
  const content=JSON.parse(String(pushRequests[0].init?.body));expect(content.connectionState).toBe('offline');expect(content.eventId).toEqual(expect.any(String));expect(content.type).toBe('listener_disconnected');expect(content.aps.category).toBe('BABY_CRY_ALERT');
  expect(content.aps['interruption-level']).toBe('time-sensitive');expect(content.aps.sound).toBe('default');
  await call('listener/heartbeat',listener,beat(listener));await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);
  expect((await env.DB.prepare('SELECT state FROM connection_states WHERE listener_id=?').bind(listener.deviceId).first<{state:string}>())?.state).toBe('online');
  await stale();mockPush();await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(2);expect(JSON.parse(String(pushRequests[1].init?.body)).connectionState).toBe('offline');
 });
 it('defaults stopped-monitor warnings on but does not warn before first start',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener,false));await flushConnections(testEnv);expect(pushRequests).toHaveLength(0);
  await call('listener/heartbeat',listener,beat(listener));
  await call('listener/heartbeat',listener,beat(listener,false));mockPush();await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);expect(JSON.parse(String(pushRequests[0].init?.body)).connectionState).toBe('stopped');
 });
 it('uses scheduled checks to warn both devices after three minutes and shares the crying snooze',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));
  await env.DB.prepare('UPDATE devices SET alerts_muted_until=? WHERE id=?').bind(Date.now()+60000,parent.deviceId).run();
  const check=()=>worker.scheduled({} as ScheduledController,testEnv);
  await env.DB.prepare('UPDATE heartbeats SET received_at=?').bind(new Date(Date.now()-179000).toISOString()).run();
  await check();expect(pushRequests).toHaveLength(0);
  await env.DB.prepare('UPDATE heartbeats SET received_at=?').bind(new Date(Date.now()-181000).toISOString()).run();
  await check();await check();expect(pushRequests).toHaveLength(0);
  const clock=vi.spyOn(Date,'now').mockReturnValue(Date.now()+61000);
  mockPush(200,2);await runReminder(testEnv,parent.deviceId);clock.mockRestore();
  expect(pushRequests).toHaveLength(2);
  const content=JSON.parse(String(pushRequests.find(r=>r.url.includes('cd'.repeat(32)))!.init?.body));
  expect(JSON.parse(String(pushRequests.find(r=>r.url.includes('ab'.repeat(32)))!.init?.body)).aps['interruption-level']).toBe('time-sensitive');
  expect(content.connectionState).toBe('offline');
  expect(content.aps).toEqual(JSON.parse(String(pushRequests.find(r=>r.url.includes('ab'.repeat(32)))!.init?.body)).aps);
  expect(content.aps.alert.title).toBe('Listener connection lost');
  expect(content.aps.sound).toBe('default');
  expect(content.aps['interruption-level']).toBe('time-sensitive');
  expect((await env.DB.prepare("SELECT status FROM events ORDER BY created_at DESC LIMIT 1").first<{status:string}>())?.status).toBe('sent');
 });
 it('does not replay ambiguous health delivery and cancels obsolete outages',async()=>{
  const {parent,listener}=await paired();await call('connection-alerts',parent,{enabled:true});
  await call('device/push-token',parent,{token:'ab'.repeat(32)});await call('listener/heartbeat',listener,beat(listener));await stale();
  pushResponses.push(new Error('transport unknown'));await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);
  const notice=await env.DB.prepare('SELECT status FROM events').first<{status:string}>();expect(notice?.status).toBe('uncertain');
  await call('connection-alerts',parent,{enabled:false});await call('listener/heartbeat',listener,beat(listener));await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);
 });
 it('cancels an undelivered outage when the Listener recovers',async()=>{
  const {parent,listener}=await paired();await call('connection-alerts',parent,{enabled:true});
  await call('listener/heartbeat',listener,beat(listener));await stale();await flushConnections(testEnv);
  await call('listener/heartbeat',listener,beat(listener));await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await env.DB.prepare('UPDATE connection_notices SET next_attempt=0').run();await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(0);
  const offline=await env.DB.prepare("SELECT status FROM connection_notices WHERE state='offline'").first<{status:string}>();expect(offline?.status).toBe('cancelled');
 });
 it.each(['offline','stopped'] as const)('recovers quietly on the Watch after %s and cancels legacy recovery notices',async(state)=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));
  if(state==='offline')await stale();else await call('listener/heartbeat',listener,beat(listener,false));
  mockPush(200,2);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(2);
  expect(JSON.parse(String(pushRequests[0].init?.body)).connectionState).toBe(state);
  await call('listener/heartbeat',listener,beat(listener));
  for(const status of ['pending','blocked']){
   await env.DB.prepare("INSERT INTO connection_notices(id,listener_id,parent_id,state,observed_at,created_at,status,next_attempt) VALUES(?,?,?,'online',?,?,?,?)")
    .bind(crypto.randomUUID(),listener.deviceId,parent.deviceId,`${new Date().toISOString()}-${status}`,Date.now(),status,Date.now()+3600000).run();
  }
  await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(2);
  const notices=await env.DB.prepare("SELECT status FROM connection_notices WHERE state='online'").all<{status:string}>();
  expect(notices.results.map(n=>n.status)).toEqual(['cancelled','cancelled']);
  expect((await env.DB.prepare('SELECT state FROM connection_states WHERE listener_id=?').bind(listener.deviceId).first<{state:string}>())?.state).toBe('online');
 });
 it('retries explicit rejection once without duplicating concurrent dispatch',async()=>{
  const {parent,listener}=await paired();await call('connection-alerts',parent,{enabled:true});await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();mockPush(503);
  await flushConnections(testEnv);await env.DB.prepare('UPDATE events SET next_attempt=0').run();mockPush();
  await Promise.all([flushPending(testEnv),flushPending(testEnv)]);expect(pushRequests).toHaveLength(2);
  expect(pushRequests[0].init?.headers).toEqual(pushRequests[1].init?.headers);
 });
 it('invalidates only the rejected connection destination and never replays the accepted phone warning',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});
   return String(input).includes('cd'.repeat(32))?new Response(JSON.stringify({reason:'BadDeviceToken'}),{status:400}):new Response(null,{status:200});
  });
  await flushConnections(testEnv);
  await env.DB.prepare('UPDATE events SET next_attempt=0').run();await flushPending(testEnv);
  expect(pushRequests).toHaveLength(2);
  expect(await env.DB.prepare('SELECT watch_push_token FROM devices WHERE id=?').bind(parent.deviceId).first()).toMatchObject({watch_push_token:null});
  const saved=await env.DB.prepare('SELECT delivery_state FROM events').first<{delivery_state:string}>();
  expect(JSON.parse(saved!.delivery_state)).toEqual({phone:'sent',watch:'blocked'});
 });
 it('repeats a lost Listener without app execution, snoozes idempotently, resumes and resolves on recovery',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();
  const start=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(start);
  mockPush();await Promise.all([flushConnections(testEnv),flushConnections(testEnv)]);
  expect(pushRequests).toHaveLength(1);
  const first=JSON.parse(String(pushRequests[0].init?.body)) as Alert;
  clock.mockReturnValue(start+5_000);mockPush();expect(await runReminder(testEnv,parent.deviceId)).toBe(true);
  clock.mockReturnValue(start+20*60_000);mockPush();expect(await runReminder(testEnv,parent.deviceId)).toBe(true);
  const latest=JSON.parse(String(pushRequests.at(-1)?.init?.body)) as Alert;
  expect(latest.type).toBe('listener_disconnected');expect(latest.eventId).not.toBe(first.eventId);
  expect(latest.episodeId).toBe(first.episodeId);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {notificationRelevance:{cryEpisodeIDs:string[]};alerts:Alert[]};
  expect(status.notificationRelevance.cryEpisodeIDs).toContain(first.episodeId);
  expect(status.alerts[0].type).toBe('listener_disconnected');
  const timeline=await (await call('timeline',parent,undefined,'GET')).json() as {events:{kind:string;count?:number;status?:string}[]};
  expect(timeline.events.filter(e=>e.kind==='connection_alert')).toEqual([expect.objectContaining({count:3,status:'sent'})]);
  expect(timeline.events.filter(e=>e.kind==='alert')).toHaveLength(0);
  expect((await call('alert/acknowledge',parent,{eventId:latest.eventId})).status).toBe(200);
  const deadline=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  clock.mockReturnValue(start+20*60_000+30_000);
  await call('alert/acknowledge',parent,{eventId:latest.eventId});
  expect(await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first()).toEqual(deadline);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(true);expect(pushRequests).toHaveLength(3);
  clock.mockReturnValue(deadline!.alerts_muted_until+1);mockPush();expect(await runReminder(testEnv,parent.deviceId)).toBe(true);
  expect(pushRequests).toHaveLength(4);
  await call('listener/heartbeat',listener,beat(listener));
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  const recovered=await (await call('listener/status',parent,undefined,'GET')).json() as typeof status;
  expect(recovered.notificationRelevance.cryEpisodeIDs).not.toContain(first.episodeId);
  expect(pushRequests).toHaveLength(4);
 });
 it('repairs a lost snooze timer from server state without a Listener heartbeat',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();mockPush();await flushConnections(testEnv);
  const first=JSON.parse(String(pushRequests[0].init?.body));
  await call('alert/acknowledge',parent,{eventId:first.eventId});
  const stub=env.ALERT_REMINDERS.getByName(parent.deviceId);
  await runInDurableObject(stub,async(_instance,state)=>state.storage.deleteAlarm());
  await flushPending(testEnv);
  const deadline=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(await runInDurableObject(stub,async(_instance,state)=>state.storage.getAlarm())).toBe(deadline!.alerts_muted_until);
  expect(pushRequests).toHaveLength(1);
 });
 it('uses the configured AlarmKit delivery and scheduling receipt for an outage',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32),alarmReceiptsVersion:1});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  expect((await call('silent-watch-alarms',parent,{enabled:true})).status).toBe(200);
  await call('listener/heartbeat',listener,beat(listener));await stale();mockPush(200,2);await flushConnections(testEnv);
  const phone=JSON.parse(String(pushRequests.find(r=>r.url.includes('ab'.repeat(32)))!.init?.body));
  const watch=JSON.parse(String(pushRequests.find(r=>r.url.includes('cd'.repeat(32)))!.init?.body));
  expect(phone.type).toBe('listener_disconnected');expect(phone.silentCryAlarm).toBe(true);
  expect(phone.aps['content-available']).toBe(1);expect(watch.silentCryAlarm).toBeUndefined();
  expect(watch.eventId).toBe(phone.eventId);expect(phone.alarmCycleId).toEqual(expect.any(String));
  expect((await call('alarm/scheduled',parent,{episodeId:phone.episodeId,eventId:phone.eventId,cycleId:phone.alarmCycleId})).status).toBe(200);
  await call('connection-alerts',parent,{enabled:false});
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  expect((await call('alarm/scheduled',parent,{episodeId:phone.episodeId,eventId:phone.eventId,cycleId:phone.alarmCycleId})).status).toBe(409);
 });
 it('records device-reported alarm attempts as bounded diagnostics only',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();mockPush();await flushConnections(testEnv);
  const phone=JSON.parse(String(pushRequests[0].init?.body));
  const other=crypto.randomUUID(),started=Date.now()-5000;
  const response=await call('alarm/attempts',parent,{attempts:[
   {method:'extension',outcome:'scheduled',eventId:phone.eventId.toUpperCase(),test:false,flags:['extension','bogus'],pushToStartMs:180,handlerMs:240,pushToAlarmMs:1420,
    snapshotAgeMs:60000,evidenceApplied:false,charging:false,batteryPct:54,lowPower:false,protectedData:false,startedAtMs:started},
   {method:'app',outcome:'rejected',reason:'Error: secret text',eventId:other,handlerMs:12},
   {method:'carrier-pigeon',outcome:'scheduled'}]});
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ok:true,recorded:2,ignored:1});
  const rows=(await env.DB.prepare("SELECT event_ref,elapsed_ms,details FROM diagnostics WHERE operation='alarm_attempt' ORDER BY sequence").all<{event_ref:string|null;elapsed_ms:number;details:string}>()).results;
  expect(rows).toHaveLength(2);
  expect(rows[0].event_ref).toBe(await eventReference(testEnv,phone.eventId));
  expect(rows[0].elapsed_ms).toBeGreaterThanOrEqual(5000);
  expect(JSON.parse(rows[0].details).alarm_attempt).toEqual({method:'extension',outcome:'scheduled',test:false,flags:['extension'],push_to_start_ms:180,handler_ms:240,
   push_to_alarm_ms:1420,snapshot_age_ms:60000,evidence_applied:false,charging:false,battery_pct:54,low_power:false,protected_data:false,started_at_ms:started});
  // Another Parent's (or an unknown) event stays unlinked, and free text never reaches storage.
  expect(rows[1].event_ref).toBeNull();
  expect(rows[1].details).not.toContain('secret');
  // A real event reported by a different Parent is stored unlinked.
  const stranger=device('parent');await register(stranger);
  expect(await (await call('alarm/attempts',stranger,{attempts:[{method:'app',outcome:'scheduled',eventId:phone.eventId,handlerMs:5}]})).json()).toEqual({ok:true,recorded:1,ignored:0});
  const strangerRow=await env.DB.prepare("SELECT event_ref FROM diagnostics WHERE operation='alarm_attempt' ORDER BY sequence DESC LIMIT 1").first<{event_ref:string|null}>();
  expect(strangerRow!.event_ref).toBeNull();
  expect((await call('alarm/attempts',listener,{attempts:[]})).status).toBe(403);
  expect((await call('alarm/attempts',parent,{attempts:Array(21).fill({method:'app',outcome:'scheduled'})})).status).toBe(400);
 });
 it('suppresses a reminder if recovery overtakes its prepared snapshot',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();mockPush();await flushConnections(testEnv);
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+6000);
  let recovered=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();
   if(!recovered&&sql.startsWith('SELECT p.listener_id')&&method==='batch'){
    recovered=true;await call('listener/heartbeat',listener,beat(listener));
   }
   return result;
  });
  await runReminder({...testEnv,DB:db},parent.deviceId);
  expect(recovered).toBe(true);expect(pushRequests).toHaveLength(1);
 });
 it('starts a new episode when connection alerts are enabled during an existing outage',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('connection-alerts',parent,{enabled:false});
  await call('listener/heartbeat',listener,beat(listener));await stale();await flushConnections(testEnv);
  await call('connection-alerts',parent,{enabled:true});mockPush();await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);
  const first=JSON.parse(String(pushRequests[0].init?.body));
  await call('connection-alerts',parent,{enabled:false});expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  await call('connection-alerts',parent,{enabled:true});mockPush();await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(2);expect(JSON.parse(String(pushRequests[1].init?.body)).episodeId).not.toBe(first.episodeId);
 });
 it('upgrades a previously sent one-shot outage into a persistent episode',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();
  const last=await env.DB.prepare('SELECT received_at FROM heartbeats WHERE listener_id=?').bind(listener.deviceId).first<{received_at:string}>();
  const id=crypto.randomUUID();
  await env.DB.prepare("INSERT INTO connection_notices(id,parent_id,listener_id,state,observed_at,created_at,status) VALUES(?,?,?,'offline',?,?,'sent')")
   .bind(id,parent.deviceId,listener.deviceId,last!.received_at,Date.now()).run();
  mockPush();await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);expect(JSON.parse(String(pushRequests[0].init?.body)).episodeId).toBe(id);
  expect(await env.DB.prepare('SELECT status FROM connection_notices WHERE id=?').bind(id).first()).toEqual({status:'escalated'});
 });
 it('keeps desired settings separate from settings reported by the Listener',async()=>{
  const {parent,listener}=await paired();const desired={...defaultConfiguration,alertDuration:30};
  await call('settings',parent,desired);await call('listener/heartbeat',listener,beat(listener));
  let status=await (await call('listener/status',parent,undefined,'GET')).json() as {configuration:unknown;listenerConfiguration:unknown};
  expect(status.configuration).toEqual(desired);expect(status.listenerConfiguration).toEqual(defaultConfiguration);
  await call('listener/heartbeat',listener,beat(listener,true,desired));
  status=await (await call('listener/status',parent,undefined,'GET')).json() as typeof status;
  expect(status.listenerConfiguration).toEqual(desired);
  expect((await call('listener/heartbeat',listener,{...beat(listener),appliedConfiguration:{...desired,audio:'forbidden'}})).status).toBe(400);
 });
 it('lets only the paired parent request and acknowledge a marked real test',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  expect((await call('test-push',listener)).status).toBe(403);mockPush();expect((await call('test-push',parent)).status).toBe(200);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alerts:Alert[]};
  expect(status.alerts[0].isTest).toBe(true);expect(JSON.parse(String(pushRequests[0].init?.body)).isTest).toBe(true);
  expect((await call('alert/acknowledge',parent,{eventId:status.alerts[0].eventId})).status).toBe(200);
 });
 it('confirms earlier unconfirmed tests with one acknowledgement without touching real alerts or later tests',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();
  const tests=[0,1,2].map(()=>({...alert(listener),isTest:true}));const real=alert(listener);const later={...alert(listener),isTest:true};
  for(const event of [...tests,real,later])await call('listener/event',listener,event);
  // Order creation explicitly: two earlier tests, a real alert, then two tests after the confirmed one.
  const created=new Map([[tests[0].eventId,1000],[tests[1].eventId,2000],[real.eventId,1500],[tests[2].eventId,3000],[later.eventId,4000]]);
  for(const [id,at] of created)await env.DB.prepare('UPDATE events SET created_at=? WHERE event_id=?').bind(at,id).run();
  expect((await call('alert/acknowledge',parent,{eventId:tests[1].eventId})).status).toBe(200);
  const acknowledged=async(id:string)=>(await env.DB.prepare('SELECT acknowledged_at FROM events WHERE event_id=?').bind(id).first<{acknowledged_at:string|null}>())?.acknowledged_at!=null;
  expect(await acknowledged(tests[0].eventId)).toBe(true);expect(await acknowledged(tests[1].eventId)).toBe(true);
  expect(await acknowledged(tests[2].eventId)).toBe(false);expect(await acknowledged(later.eventId)).toBe(false);
  expect(await acknowledged(real.eventId)).toBe(false);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM timeline_events WHERE kind=?').bind('test_acknowledged').first()).toEqual({n:1});
  const mute=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(mute?.alerts_muted_until).toBe(0);
 });
 it('unpairs atomically, permits replacement and prevents old history replay',async()=>{
  const {parent,listener}=await paired();const other=await paired();const old=alert(listener);await call('listener/event',listener,old);
  await call('listener/heartbeat',listener,beat(listener));await call('listener/heartbeat',other.listener,beat(other.listener));
  expect((await call('pairing/remove',parent)).status).toBe(200);
  expect((await call('listener/heartbeat',listener,beat(listener))).status).toBe(409);
  const status=await (await call('listener/status',listener,undefined,'GET')).json() as {paired:boolean};expect(status.paired).toBe(false);
  expect((await env.DB.prepare('SELECT * FROM events WHERE event_id=?').bind(old.eventId).all()).results).toHaveLength(0);
  expect((await env.DB.prepare('SELECT * FROM pairs WHERE parent_id=?').bind(other.parent.deviceId).all()).results).toHaveLength(1);
  const code=await (await call('pairing/create',parent)).json() as {code:string};await call('pairing/claim',listener,{code:code.code});
  await env.DB.prepare('UPDATE pairs SET created_at=? WHERE parent_id=?').bind(Date.now()+5000,parent.deviceId).run();
  expect((await call('listener/event',listener,old)).status).toBe(409);
  await call('listener/heartbeat',listener,{...beat(listener),episodes:[{id:old.episodeId,startedAt:old.cryStartedAt}]});
  const fresh=await (await call('listener/status',parent,undefined,'GET')).json() as {episodes:unknown[]};expect(fresh.episodes).toHaveLength(0);
 });
 it('deletes only the caller registration and shared pair history',async()=>{
  const {parent,listener}=await paired();await call('listener/heartbeat',listener,beat(listener));
  expect((await call('device/delete',listener)).status).toBe(200);
  expect((await call('listener/status',listener,undefined,'GET')).status).toBe(401);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {paired:boolean};expect(status.paired).toBe(false);
  expect((await env.DB.prepare('SELECT * FROM heartbeats').all()).results).toHaveLength(0);
  expect((await call('pairing/create',parent)).status).toBe(200);
 });
});

describe('devices and secure pairing',()=>{
 it('requires credentials and rejects wrong roles',async()=>{
  expect((await call('listener/status',undefined,undefined,'GET')).status).toBe(401);
  const listener=device('listener');await register(listener);
  expect((await call('pairing/create',listener)).status).toBe(403);
  const wrong={...listener,secret:btoa('ffffffffffffffffffffffffffffffff')};
  expect((await call('listener/status',wrong,undefined,'GET')).status).toBe(401);
 });
 it('registration is idempotent without permitting secret replacement',async()=>{
  const d=device('parent');await register(d);await register(d);
  expect((await call('device/register',undefined,{...d,secret:btoa('ffffffffffffffffffffffffffffffff')})).status).toBe(409);
 });
 it('pairs once, recovers a lost claim response and rejects reuse',async()=>{
  const {parent,listener,code}=await paired();
  expect(code.code).toMatch(/^\d{6}$/);
  expect((await call('pairing/claim',listener,{code:code.code})).status).toBe(200);
  const other=device('listener');await register(other);
  expect((await call('pairing/claim',other,{code:code.code})).status).toBeGreaterThanOrEqual(400);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {paired:boolean;listenerId:string};
  expect(status.paired).toBe(true);expect(status.listenerId).toBe(listener.deviceId);
 });
 it('expires codes and throttles guessing',async()=>{
  const parent=device('parent'),listener=device('listener');await register(parent);await register(listener);
  const code=await (await call('pairing/create',parent)).json() as {code:string};
  await env.DB.prepare('UPDATE pairing_codes SET expires_at=0').run();
  expect((await call('pairing/claim',listener,{code:code.code})).status).toBe(400);
  for(let i=0;i<5;i++)await call('pairing/claim',listener,{code:'999999'});
  expect((await call('pairing/claim',listener,{code:'999999'})).status).toBe(429);
 });
 it('keeps crying alerts outside shared-address and per-device polling budgets',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const exhaust=async(scope:string,identifier:string,attempts:number)=>env.DB.prepare('INSERT OR REPLACE INTO rate_limits(key,window,attempts) VALUES(?,?,?)')
   .bind(await sha256(`${testEnv.PAIRING_PEPPER}|${scope}|${identifier}`),Math.floor(Date.now()/1000/600),attempts).run();
  await exhaust('device',listener.deviceId,600);
  expect((await call('listener/status',listener,undefined,'GET')).status).toBe(429);
  expect((await call('listener/status',parent,undefined,'GET')).status).toBe(200); // The Parent has its own budget.
  await exhaust('api','127.0.0.1',3000);
  expect((await call('listener/status',parent,undefined,'GET')).status).toBe(429);
  mockPush();
  expect(await (await call('listener/event',listener,alert(listener))).json()).toEqual({status:'sent'});
 });
 it('encrypts APNs tokens at rest and uses distinct random IVs',async()=>{
  const {parent}=await paired();const token='ab'.repeat(32);
  expect((await call('device/push-token',parent,{token})).status).toBe(200);
  const saved=await env.DB.prepare('SELECT push_token FROM devices WHERE id=?').bind(parent.deviceId).first<{push_token:string}>();
  expect(saved?.push_token).not.toContain(token);expect(await decryptToken(testEnv,saved?.push_token??'')).toBe(token);
  expect(await encryptToken(testEnv,token)).not.toEqual(saved?.push_token);
 });
});
describe('listener metadata and configuration',()=>{
 it('shares a five-second alert duration with the listener',async()=>{
  const {parent,listener}=await paired();const config={...defaultConfiguration,alertDuration:5};
  expect((await call('settings',parent,config)).status).toBe(200);
  const beat={listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[]};
  const response=await call('listener/heartbeat',listener,beat);
  expect(response.status).toBe(200);expect(await response.json()).toEqual(config);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {configuration:typeof config};
  expect(status.configuration).toEqual(config);
 });
 it('enforces alert duration bounds without overwriting saved settings',async()=>{
  const {parent}=await paired();const config={...defaultConfiguration,alertDuration:3600};
  expect((await call('settings',parent,config)).status).toBe(200);
  for(const alertDuration of [0,4.99,3600.01]){
   expect((await call('settings',parent,{...config,alertDuration})).status).toBe(400);
  }
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {configuration:typeof config};
  expect(status.configuration).toEqual(config);
 });
 it('validates absolute sound levels without overwriting saved settings',async()=>{
  const {parent}=await paired();
  for(const absoluteThreshold of [-60,-47.5,-35,-10]){
   expect((await call('settings',parent,{...defaultConfiguration,absoluteThreshold})).status).toBe(200);
  }
  for(const absoluteThreshold of [-60.01,-9.99,null,'-35']){
   expect((await call('settings',parent,{...defaultConfiguration,absoluteThreshold})).status).toBe(400);
  }
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {configuration:typeof defaultConfiguration};
  expect(status.configuration).toEqual({...defaultConfiguration,absoluteThreshold:-10});
 });
 it('discards retired sensitivity in stored configurations and older requests',async()=>{
  const {parent,listener}=await paired();const legacy={...defaultConfiguration,sensitivity:'high'};
  const unpaired=device('listener');await register(unpaired);
  await env.DB.prepare('UPDATE devices SET config=? WHERE id=?').bind(JSON.stringify(legacy),unpaired.deviceId).run();
  const unpairedStatus=await (await call('listener/status',unpaired,undefined,'GET')).json() as {paired:boolean;configuration:typeof defaultConfiguration};
  expect(unpairedStatus.paired).toBe(false);expect(unpairedStatus.configuration).toEqual(defaultConfiguration);
  await env.DB.prepare('UPDATE devices SET config=? WHERE id=?').bind(JSON.stringify(legacy),parent.deviceId).run();
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {configuration:typeof defaultConfiguration};
  expect(status.configuration).toEqual(defaultConfiguration);
  const beat={listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[]};
  expect(await (await call('listener/heartbeat',listener,beat)).json()).toEqual(defaultConfiguration);
  await env.DB.prepare('UPDATE heartbeats SET metadata=? WHERE listener_id=?').bind(JSON.stringify({...beat,appliedConfiguration:legacy}),listener.deviceId).run();
  const applied=await (await call('listener/status',parent,undefined,'GET')).json() as {listenerConfiguration:typeof defaultConfiguration};
  expect(applied.listenerConfiguration).toEqual(defaultConfiguration);
  expect((await call('settings',parent,legacy)).status).toBe(200);
  const saved=await env.DB.prepare('SELECT config FROM devices WHERE id=?').bind(parent.deviceId).first<{config:string}>();
  expect(JSON.parse(saved!.config)).toEqual(defaultConfiguration);
 });
 it('stores heartbeat with server freshness and shares settings',async()=>{
  const {parent,listener}=await paired();const config={...defaultConfiguration,alertDuration:60,absoluteThreshold:-45};
  expect((await call('settings',parent,config)).status).toBe(200);
  const beat={listenerId:listener.deviceId,timestamp:'2000-01-01T00:00:00Z',monitoring:true,batteryLevel:0.8,powerConnected:true,state:'quiet',episodes:[]};
  const response=await call('listener/heartbeat',listener,beat);expect(response.status).toBe(200);expect(await response.json()).toEqual(config);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {lastHeartbeat:string;monitoring:boolean;serverTime:string;nextHeartbeatExpectedAt:string};
  expect(Date.parse(status.lastHeartbeat)).toBeGreaterThan(Date.now()-5000);expect(status.monitoring).toBe(true);
  expect(Date.parse(status.nextHeartbeatExpectedAt)-Date.parse(status.lastHeartbeat)).toBe(15000);
  expect(Date.parse(status.serverTime)).toBeGreaterThanOrEqual(Date.parse(status.lastHeartbeat));
  const again=await (await call('listener/status',parent,undefined,'GET')).json() as typeof status;
  expect(again.nextHeartbeatExpectedAt).toBe(status.nextHeartbeatExpectedAt);
 });
 it('reports standby separately from off, schedules standby heartbeats, and accepts older listeners',async()=>{
  const {parent,listener}=await paired();
  const beat={listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:false,microphoneActive:true,powerConnected:true,state:'quiet',episodes:[]};
  expect((await call('listener/heartbeat',listener,beat)).status).toBe(200);
  const status=async()=>await (await call('listener/status',parent,undefined,'GET')).json() as {monitoring:boolean;microphoneActive:boolean;lastHeartbeat:string;nextHeartbeatExpectedAt:string|null};
  const standby=await status();expect(standby.monitoring).toBe(false);expect(standby.microphoneActive).toBe(true);
  expect(Date.parse(standby.nextHeartbeatExpectedAt!)-Date.parse(standby.lastHeartbeat)).toBe(15000);
  const stored=await env.DB.prepare('SELECT metadata FROM heartbeats WHERE listener_id=?').bind(listener.deviceId).first<{metadata:string}>();
  expect(JSON.parse(stored!.metadata).microphoneActive).toBe(true);
  expect((await call('listener/heartbeat',listener,{...beat,microphoneActive:false})).status).toBe(200);
  expect((await status()).microphoneActive).toBe(false);expect((await status()).nextHeartbeatExpectedAt).toBeNull();
  const {microphoneActive,...legacy}=beat;
  expect((await call('listener/heartbeat',listener,{...legacy,monitoring:true})).status).toBe(200);
  expect((await status()).microphoneActive).toBe(true);
 });
 it('rejects inconsistent or invalid microphone and standby detection states',async()=>{
  const {listener}=await paired();
  const beat={listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:false,microphoneActive:true,powerConnected:true,state:'quiet',episodes:[]};
  for(const invalid of [{microphoneActive:'true'},{monitoring:true,microphoneActive:false},{state:'crying'},{currentEpisode:{id:crypto.randomUUID(),startedAt:new Date().toISOString()}}]){
   expect((await call('listener/heartbeat',listener,{...beat,...invalid})).status).toBe(400);
  }
 });
 it('preserves standby transitions and marks stale standby coverage as missing',async()=>{
  const {parent,listener}=await paired();
  const paused={id:crypto.randomUUID(),kind:'monitoring_paused',occurredAt:new Date().toISOString()};
  const beat={listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:false,microphoneActive:true,powerConnected:true,state:'quiet',episodes:[],timelineEvents:[paused]};
  expect((await call('listener/heartbeat',listener,beat)).status).toBe(200);
  const history=async()=>await (await call('timeline',parent,undefined,'GET')).json() as {events:{kind:string}[]};
  const kinds=(await history()).events.map(e=>e.kind);
  expect(kinds).toContain('monitoring_paused');expect(kinds).toContain('standby_observed');expect(kinds).toContain('coverage_standby');
  await env.DB.prepare('UPDATE heartbeats SET received_at=? WHERE listener_id=?').bind(new Date(Date.now()-240000).toISOString(),listener.deviceId).run();
  expect((await history()).events.some(e=>e.kind==='heartbeat_missing')).toBe(true);
 });
 it('only predicts the next heartbeat for an actively monitoring Listener',async()=>{
  const {parent,listener}=await paired();
  const status=async()=>await (await call('listener/status',parent,undefined,'GET')).json() as {nextHeartbeatExpectedAt:string|null;serverTime:string};
  expect((await status()).nextHeartbeatExpectedAt).toBeNull();
  await call('listener/heartbeat',listener,{listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:false,powerConnected:true,state:'quiet',episodes:[]});
  expect((await status()).nextHeartbeatExpectedAt).toBeNull();
  await call('pairing/remove',parent);
  const unpaired=await status();
  expect(unpaired.nextHeartbeatExpectedAt).toBeNull();
  expect(Number.isFinite(Date.parse(unpaired.serverTime))).toBe(true);
 });
 it('rejects audio fields, identities and invalid settings',async()=>{
  const {parent,listener}=await paired();const beat={listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[]};
  expect((await call('listener/heartbeat',listener,{...beat,audio:'secret recording'})).status).toBe(400);
  expect((await call('listener/heartbeat',listener,{...beat,listenerId:parent.deviceId})).status).toBe(403);
  expect((await call('settings',parent,{...defaultConfiguration,alertDuration:-1})).status).toBe(400);
 });
 it('does not expose another pair status or acknowledge another parent alert',async()=>{
  const a=await paired(),b=await paired();const event=alert(a.listener);
  await call('listener/event',a.listener,event); // blocked: no token
  expect((await call('alert/acknowledge',b.parent,{eventId:event.eventId})).status).toBe(404);
  const status=await (await call('listener/status',b.parent,undefined,'GET')).json() as {alerts:unknown[]};expect(status.alerts).toHaveLength(0);
 });
});
describe('direct Apple Watch alerts',()=>{
 it('encrypts the Watch token, restricts registration to parents and supports removal',async()=>{
  const {parent,listener}=await paired();const token='cd'.repeat(32);
  expect((await call('device/watch-push-token',listener,{token})).status).toBe(403);
  expect((await call('device/watch-push-token',parent,{token:'invalid'})).status).toBe(400);
  expect((await call('device/watch-push-token',parent,{token})).status).toBe(200);
  const saved=await env.DB.prepare('SELECT watch_push_token AS token FROM devices WHERE id=?').bind(parent.deviceId).first<{token:string}>();
  expect(saved?.token).not.toContain(token);expect(await decryptToken(testEnv,saved!.token)).toBe(token);
  let status=await (await call('listener/status',parent,undefined,'GET')).json() as {watchPushRegistered:boolean};
  expect(status.watchPushRegistered).toBe(true);
  expect((await call('device/watch-push-token',parent,{token:null})).status).toBe(200);
  status=await (await call('listener/status',parent,undefined,'GET')).json() as {watchPushRegistered:boolean};
  expect(status.watchPushRegistered).toBe(false);
 });
 it.each([false,true])('sends a Time Sensitive alert to both registered devices once (test=%s)',async(isTest)=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const event={...alert(listener),...(isTest?{isTest:true}:{})};mockPush(200,2);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
  await call('listener/event',listener,event);await flushPending(testEnv);
  expect(pushRequests).toHaveLength(2);
  expect(new Headers(pushRequests[0].init?.headers).get('authorization')).toBe(new Headers(pushRequests[1].init?.headers).get('authorization'));
  for(const target of ['phone','watch']){
   const request=pushRequests.find(r=>r.url.includes((target==='phone'?'ab':'cd').repeat(32)))!;
   expect(new Headers(request.init?.headers).get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+(target==='watch'?'.watchkitapp':''));
   const content=JSON.parse(String(request.init?.body));
   expect(content).toMatchObject({aps:{category:'BABY_CRY_ALERT','interruption-level':'time-sensitive'},eventId:event.eventId,createdAt:event.createdAt});
   expect(content.aps.sound).toBe('default');
  }
  const [phone,watch]=pushRequests.map(r=>({headers:new Headers(r.init?.headers),body:JSON.parse(String(r.init?.body))}));
  expect(phone.body.aps).toEqual(watch.body.aps);
  for(const key of ['apns-id','apns-priority','apns-push-type'])expect(phone.headers.get(key)).toBe(watch.headers.get(key));
  expect(phone.headers.get('apns-id')).toBe(event.eventId);
  expect(phone.headers.get('apns-collapse-id')).toBe(isTest?event.eventId:`phone:${event.eventId}`);
  expect(watch.headers.get('apns-collapse-id')).toBe(isTest?event.eventId:`watch:${event.eventId}`);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alerts:{deliveryTarget:string;deliveryState:unknown}[]};
  expect(status.alerts[0]).toMatchObject({deliveryTarget:'both',deliveryState:{phone:'sent',watch:'sent'}});
 });
 it('keeps an accepted phone alert on the phone when a Watch registers later',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);mockPush();await call('listener/event',listener,event);
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await call('listener/event',listener,event);await flushPending(testEnv);
  expect(pushRequests).toHaveLength(1);expect(pushRequests[0].url).toContain('ab'.repeat(32));
 });
 it.each(['phone','watch'] as const)('retries only the explicitly rejected %s destination without duplicating its accepted partner',async(rejected)=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  let reject=true;
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});
   const failing=String(input).includes((rejected==='phone'?'ab':'cd').repeat(32))&&reject;
   return new Response(failing?JSON.stringify({reason:'ServiceUnavailable'}):null,{status:failing?503:200});
  });
  const event=alert(listener);expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'pending'});
  reject=false;await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();
  await Promise.all([flushPending(testEnv),flushPending(testEnv)]);
  expect(pushRequests).toHaveLength(3);
  expect(pushRequests.filter(r=>r.url.includes((rejected==='phone'?'ab':'cd').repeat(32)))).toHaveLength(2);
  for(const request of pushRequests){
   const headers=new Headers(request.init?.headers),target=headers.get('apns-topic')!.endsWith('.watchkitapp')?'watch':'phone';
   expect(headers.get('apns-collapse-id')).toBe(`${target}:${event.eventId}`);
   expect(headers.get('apns-id')).toBe(event.eventId);
  }
  expect(await env.DB.prepare('SELECT status,delivery_state FROM events WHERE event_id=?').bind(event.eventId).first()).toMatchObject({status:'sent',delivery_state:JSON.stringify({phone:'sent',watch:'sent'})});
 });
 it('keeps phone acceptance when the Watch token is invalid and retries only a replacement Watch token',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});
   return String(input).includes('cd'.repeat(32))?new Response(JSON.stringify({reason:'Unregistered'}),{status:410}):new Response(null,{status:200});
  });
  const event=alert(listener);expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'blocked'});
  await call('device/watch-push-token',parent,{token:'ef'.repeat(32)});await flushPending(testEnv);
  expect(pushRequests).toHaveLength(3);expect(pushRequests.filter(r=>r.url.includes('ab'.repeat(32)))).toHaveLength(1);
  expect(pushRequests[2].url).toContain('ef'.repeat(32));
 });
 it('does not replay an uncertain Watch delivery or the accepted phone delivery',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});if(String(input).includes('cd'.repeat(32)))throw new Error('connection lost');
   return new Response(null,{status:200});
  });
  const event=alert(listener);expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'uncertain'});
  await call('device/watch-push-token',parent,{token:null});await flushPending(testEnv);
  expect(pushRequests).toHaveLength(2);
  const saved=await env.DB.prepare('SELECT delivery_state FROM events WHERE event_id=?').bind(event.eventId).first<{delivery_state:string}>();
  expect(JSON.parse(saved!.delivery_state)).toEqual({phone:'sent',watch:'uncertain'});
 });
 it.each(['snooze','stop','resolve'] as const)('suppresses a pending second destination after %s',async(action)=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});const reject=String(input).includes('cd'.repeat(32));
   return new Response(reject?JSON.stringify({reason:'ServiceUnavailable'}):null,{status:reject?503:200});
  });
  await env.DB.prepare('UPDATE pairs SET created_at=? WHERE parent_id=?').bind(Date.now()-3600000,parent.deviceId).run();
  const event=alert(listener);await call('listener/event',listener,event);
  if(action==='snooze')expect((await call('alert/acknowledge',parent,{eventId:event.eventId})).status).toBe(200);
  if(action==='stop')expect((await call('monitoring',parent,{id:crypto.randomUUID(),enabled:false})).status).toBe(200);
  if(action==='resolve')expect((await call('listener/heartbeat',listener,{listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[{id:event.episodeId,startedAt:event.cryStartedAt,endedAt:new Date().toISOString(),quietConfirmed:true}]})).status).toBe(200);
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();await flushPending(testEnv);
  expect(pushRequests).toHaveLength(2);
 });
 it.each([['Unregistered',410,'blocked'],['ServiceUnavailable',503,'pending']] as const)('keeps reminding the accepted phone when the Watch is rejected with %s',async(reason,status,saved)=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await env.DB.prepare('UPDATE pairs SET created_at=created_at-600000 WHERE parent_id=?').bind(parent.deviceId).run();
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});
   return String(input).includes('cd'.repeat(32))?new Response(JSON.stringify({reason}),{status}):new Response(null,{status:200});
  });
  const event=alert(listener);await call('listener/event',listener,event);
  expect(await env.DB.prepare('SELECT status,delivery_state FROM events WHERE event_id=?').bind(event.eventId).first())
   .toMatchObject({status:saved,delivery_state:JSON.stringify({phone:'sent',watch:status===410?'blocked':'pending'})});
  const phone=()=>pushRequests.filter(r=>r.url.includes('ab'.repeat(32))).map(r=>JSON.parse(String(r.init?.body)) as Alert);
  const start=Date.now();
  for(let index=1;index<=3;index++){vi.spyOn(Date,'now').mockReturnValue(start+index*6000);expect(await runReminder(testEnv,parent.deviceId)).toBe(true);}
  // Without this, the Parent got one phone notification and no reminders until a new Watch token arrived.
  expect(phone()).toHaveLength(4);
  expect(phone().slice(1).every(p=>p.episodeId===event.episodeId&&(p as unknown as {aps:{alert:{title:string}}}).aps.alert.title.startsWith('Repeat alert'))).toBe(true);
  expect(new Set(phone().map(p=>p.eventId)).size).toBe(4);
 });
 it('does not let an unsent alert skip its own retry backoff',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await env.DB.prepare('UPDATE pairs SET created_at=created_at-600000 WHERE parent_id=?').bind(parent.deviceId).run();
  mockPush(503,2);const event=alert(listener);await call('listener/event',listener,event);
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+1000);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(true);expect(pushRequests).toHaveLength(2);
  expect(await env.DB.prepare('SELECT COUNT(*) AS count FROM events').first()).toEqual({count:1});
 });
 it('sends a new reminder to both destinations with the original event identity per delivery',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const event=alert(listener);mockPush(200,2);await call('listener/event',listener,event);
  await env.DB.prepare('UPDATE events SET created_at=? WHERE event_id=?').bind(Date.now()-6000,event.eventId).run();
  mockPush(200,2);await runReminder(testEnv,parent.deviceId);
  expect(pushRequests).toHaveLength(4);
  const repeat=pushRequests.slice(2).map(r=>JSON.parse(String(r.init?.body)));
  expect(repeat[0].eventId).toBe(repeat[1].eventId);expect(repeat[0].eventId).not.toBe(event.eventId);
  expect(repeat.every(p=>p.aps['interruption-level']==='time-sensitive')).toBe(true);
  expect(repeat[0].aps).toEqual(repeat[1].aps);expect(repeat[0].aps.sound).toBe('default');
  for(const request of pushRequests.slice(2)){
   const headers=new Headers(request.init?.headers);
   const target=headers.get('apns-topic')!.endsWith('.watchkitapp')?'watch':'phone';
   expect(headers.get('apns-id')).toBe(repeat[0].eventId);expect(headers.get('apns-collapse-id')).toBe(`${target}:${repeat[0].eventId}`);
   expect(repeat[0].aps['thread-id']).toBeUndefined();
  }
 });
 it('preserves a replacement token registered during rejection without replaying the other destination',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});
   if(String(input).includes('cd'.repeat(32))){
    await call('device/watch-push-token',parent,{token:'ef'.repeat(32)});
    return new Response(JSON.stringify({reason:'Unregistered'}),{status:410});
   }
   return new Response(null,{status:200});
  });
  const event=alert(listener);expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'pending'});
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();await flushPending(testEnv);
  expect(pushRequests).toHaveLength(3);expect(pushRequests[2].url).toContain('ef'.repeat(32));
 });
 it.each([true,false])('recovers an interrupted aggregate without replaying sends (both accepted=%s)',async(bothAccepted)=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const event={...alert(listener),isTest:true};mockPush(200,2);await call('listener/event',listener,event);
  const state={phone:'sent',watch:bothAccepted?'sent':'pending'};
  await env.DB.prepare("UPDATE events SET status='sending',sent_at=NULL,lease_until=0,delivery_state=? WHERE event_id=?")
   .bind(JSON.stringify(state),event.eventId).run();
  await flushPending(testEnv);expect(pushRequests).toHaveLength(2);
  const saved=await env.DB.prepare('SELECT status,sent_at FROM events WHERE event_id=?').bind(event.eventId).first<{status:string;sent_at:string|null}>();
  expect(saved!.status).toBe(bothAccepted?'sent':'uncertain');expect(Boolean(saved!.sent_at)).toBe(bothAccepted);
 });
 it('does not reawaken an acknowledged episode when the Watch registers',async()=>{
  const {parent,listener}=await paired();const event=alert(listener);
  await call('listener/event',listener,event);await call('alert/acknowledge',parent,{eventId:event.eventId});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});await flushPending(testEnv);
  expect(pushRequests).toHaveLength(0);
 });
});
describe('dual delivery race and persistence failures',()=>{
 it('honors an already recovered acceptance when finalization resumes late',async()=>{
  const {parent,listener}=await paired(),event={...alert(listener),isTest:true};await call('listener/event',listener,event);
  const state=JSON.stringify({phone:'pending',watch:'pending'});
  await env.DB.prepare("UPDATE events SET status='sending',attempts=1,lease_until=?,delivery_state=? WHERE event_id=?").bind(Date.now()+30000,state,event.eventId).run();
  let recovered=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();
   if(!recovered&&sql.startsWith('UPDATE events SET delivery_state=json_set')&&method==='batch'){
    const saved=await env.DB.prepare('SELECT delivery_state FROM events WHERE event_id=?').bind(event.eventId).first<{delivery_state:string}>();
    if(Object.values(JSON.parse(saved!.delivery_state)).every(s=>s==='sent')){
     recovered=true;await env.DB.prepare('UPDATE events SET lease_until=0 WHERE event_id=?').bind(event.eventId).run();await flushPending(testEnv);
    }
   }
   return result;
  });
  const send=vi.fn(async()=>({status:'sent' as const,httpStatus:200}));
  expect(await deliverToBoth({...testEnv,DB:db},{table:'events',id:event.eventId,parentId:parent.deviceId,attempt:1,state,phoneToken:'phone',watchToken:'watch',requestId:crypto.randomUUID(),send})).toBe('sent');
  expect(recovered).toBe(true);expect(send).toHaveBeenCalledTimes(2);
 });
 it.each([
  ['events','missing'],['events','invalid'],['connection_notices','missing'],['connection_notices','invalid']
 ] as const)('preserves a token upload before the %s claim is released (%s token)',async(table,kind)=>{
  const {parent,listener}=await paired(),event={...alert(listener),isTest:true};
  await call('listener/event',listener,event);await call('device/push-token',parent,{token:'ab'.repeat(32)});
  if(kind==='invalid')await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const key=table==='events'?'event_id':'id',state=JSON.stringify({phone:'sent',watch:'pending'});
  if(table==='events')await env.DB.prepare("UPDATE events SET status='sending',attempts=1,lease_until=?,delivery_state=? WHERE event_id=?").bind(Date.now()+30000,state,event.eventId).run();
  else await env.DB.prepare("INSERT INTO connection_notices(id,parent_id,listener_id,state,observed_at,created_at,status,attempts,lease_until,delivery_state) VALUES(?,?,?,'offline',?,?,'sending',1,?,?)").bind(event.eventId,parent.deviceId,listener.deviceId,new Date().toISOString(),Date.now(),Date.now()+30000,state).run();
  let registered=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();
   if(!registered&&(sql.startsWith(`UPDATE ${table} SET delivery_state=json_set`)||sql.startsWith('UPDATE devices SET watch_push_token=NULL'))&&method==='batch'){
    registered=true;await call('device/watch-push-token',parent,{token:'ef'.repeat(32)});
   }
   return result;
  });
  const tokenBefore=await env.DB.prepare('SELECT watch_push_token FROM devices WHERE id=?').bind(parent.deviceId).first<{watch_push_token:string|null}>();
  const send=vi.fn(async(_target:'phone'|'watch',_token:string,_timing:import('../src/latency').Latency):Promise<import('../src/apns').PushResult>=>({status:'blocked',reason:'invalid_device_token',httpStatus:410}));
  const options={table,id:event.eventId,parentId:parent.deviceId,attempt:1,state,phoneToken:'unused-accepted-phone',watchToken:tokenBefore!.watch_push_token,requestId:crypto.randomUUID(),send};
  expect(await deliverToBoth({...testEnv,DB:db},options)).toBe('pending');expect(registered).toBe(true);expect(send).toHaveBeenCalledTimes(kind==='missing'?0:1);
  const saved=await env.DB.prepare(`SELECT delivery_state FROM ${table} WHERE ${key}=?`).bind(event.eventId).first<{delivery_state:string}>();
  expect(JSON.parse(saved!.delivery_state)).toEqual({phone:'sent',watch:'pending'});
  const token=await env.DB.prepare('SELECT watch_push_token FROM devices WHERE id=?').bind(parent.deviceId).first<{watch_push_token:string}>();
  await env.DB.prepare(`UPDATE ${table} SET status='sending',attempts=2 WHERE ${key}=?`).bind(event.eventId).run();
  send.mockClear();send.mockResolvedValue({status:'sent',httpStatus:200});
  expect(await deliverToBoth(testEnv,{...options,attempt:2,state:saved!.delivery_state,watchToken:token!.watch_push_token})).toBe('sent');
  expect(send).toHaveBeenCalledTimes(1);expect(send.mock.calls[0][0]).toBe('watch');
 });
 it.each(['device/push-token','device/watch-push-token'])('wakes blocked connection notices when a token arrives afterward via %s',async(route)=>{
  const {parent,listener}=await paired(),id=crypto.randomUUID();
  await env.DB.prepare("INSERT INTO connection_notices(id,parent_id,listener_id,state,observed_at,created_at,status,next_attempt) VALUES(?,?,?,'offline',?,?,'blocked',?)")
   .bind(id,parent.deviceId,listener.deviceId,new Date().toISOString(),Date.now(),Date.now()+300000).run();
  await call(route,parent,{token:'ef'.repeat(32)});
  expect(await env.DB.prepare('SELECT status,next_attempt FROM connection_notices WHERE id=?').bind(id).first()).toEqual({status:'pending',next_attempt:0});
 });
 it('retains known Apple acceptance when a target outcome write fails',async()=>{
  const {parent,listener}=await paired(),event={...alert(listener),isTest:true};await call('listener/event',listener,event);
  const state=JSON.stringify({phone:'pending',watch:'pending'});
  await env.DB.prepare("UPDATE events SET status='sending',attempts=1,lease_until=?,delivery_state=? WHERE event_id=?").bind(Date.now()+30000,state,event.eventId).run();
  const db=interceptDB(async(sql,args,method,execute)=>{
   if(sql.startsWith('UPDATE events SET delivery_state=json_set')&&method==='batch'&&args[0]==='$.watch')throw new Error('D1 outcome unavailable');
   return execute();
  });
  const send=vi.fn(async(_target:unknown,_token:unknown,timing:import('../src/latency').Latency)=>{timing.details.spans!.apns_fetch_ms=12;return {status:'sent' as const,httpStatus:200};});
  await expect(deliverToBoth({...testEnv,DB:db},{table:'events',id:event.eventId,parentId:parent.deviceId,attempt:1,state,phoneToken:'phone',watchToken:'watch',requestId:crypto.randomUUID(),send})).rejects.toThrow('D1 outcome unavailable');
  const row=await env.DB.prepare("SELECT outcome,stage,http_status,details FROM diagnostics WHERE operation='dispatch' AND target='watch'").first<{outcome:string;stage:string;http_status:number;details:string}>();
  expect(row).toMatchObject({outcome:'internal_error',stage:'storage',http_status:200});
  expect(JSON.parse(row!.details)).toMatchObject({push_outcome:'sent',failed_span:'outcome_storage_ms',spans:{apns_fetch_ms:12}});
  await env.DB.prepare('UPDATE events SET lease_until=0 WHERE event_id=?').bind(event.eventId).run();await flushPending(testEnv);
  expect(send).toHaveBeenCalledTimes(2);
  expect(await env.DB.prepare('SELECT status FROM events WHERE event_id=?').bind(event.eventId).first()).toEqual({status:'uncertain'});
 });
});

describe('APNs and durable idempotent alerts',()=>{
 it('sends a clearly marked real test push to the paired parent once per event',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event={...alert(listener),isTest:true};mockPush();
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
  expect(pushRequests).toHaveLength(1);
  expect(pushRequests[0].url).toBe(`https://api.sandbox.push.apple.com/3/device/${'ab'.repeat(32)}`);
  const notification=JSON.parse(String(pushRequests[0].init?.body));
  expect(notification.aps.alert.title).toBe('Test · Crib Service');
  expect(notification.aps.alert.body).toContain('Simulated');
  expect(notification.aps.sound).toBe('default');
  expect(notification.isTest).toBe(true);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alerts:(Alert&{status:string})[];monitoring:boolean;episodes:unknown[]};
  expect(status.alerts[0]).toMatchObject({eventId:event.eventId,isTest:true,status:'sent'});
  expect(status.monitoring).toBe(false);expect(status.episodes).toHaveLength(0);
 });
 it('requires a paired listener and a boolean test flag',async()=>{
  const {parent,listener}=await paired();const event={...alert(listener),isTest:true};
  expect((await call('listener/event',parent,event)).status).toBe(403);
  const unpaired=device('listener');await register(unpaired);
  expect((await call('listener/event',unpaired,{...alert(unpaired),isTest:true})).status).toBe(409);
  expect((await call('listener/event',listener,{...event,isTest:'true'})).status).toBe(400);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'blocked'});
  expect(pushRequests).toHaveLength(0);
 });
 it('retries a rejected test push with its original identity and test label',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event={...alert(listener),isTest:true};mockPush(503);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'pending'});
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();mockPush();
  await flushPending(testEnv);
  expect(pushRequests).toHaveLength(2);
  for(const request of pushRequests){
   expect(JSON.parse(String(request.init?.body))).toMatchObject({eventId:event.eventId,isTest:true});
  }
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
 });
 it('requests default sound with Time Sensitive priority',async()=>{
  const notification=payload(alert(device('listener')));expect(notification.aps.sound).toBe('default');
  expect(notification.aps['interruption-level']).toBe('time-sensitive');
  expect(notification.aps.alert.title).toBe('Baby is crying');
  expect(notification).not.toHaveProperty('isTest');
  const timed=(durationSeconds:number)=>payload({...alert(device('listener')),durationSeconds}).aps.alert.body;
  expect(timed(1)).toContain('continued for 1 second.');
  expect(timed(61)).toContain('continued for 1 minute 1 second.');
  expect(timed(125)).toContain('continued for 2 minutes 5 seconds.');
  const token=await apnsToken(testEnv);expect(token.split('.')).toHaveLength(3);
  const header=JSON.parse(atob(token.split('.')[0]));expect(header.alg).toBe('ES256');
 });
 it('duplicate UUID and duplicate initial episode produce one push',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);mockPush();
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
  expect(await (await call('listener/event',listener,{...event,eventId:crypto.randomUUID()})).json()).toEqual({status:'sent'});
  const total=await env.DB.prepare('SELECT COUNT(*) AS count FROM events').first<{count:number}>();expect(total?.count).toBe(1);
  expect((await call('alert/acknowledge',parent,{eventId:event.eventId})).status).toBe(200);
 });
 it('concurrent duplicates atomically claim a single dispatch',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);mockPush();
  const responses=await Promise.all([call('listener/event',listener,event),call('listener/event',listener,event)]);
  expect(responses.every(r=>r.status===200)).toBe(true);
  const record=await env.DB.prepare('SELECT status,attempts FROM events WHERE event_id=?').bind(event.eventId).first<{status:string;attempts:number}>();
  expect(record).toEqual({status:'sent',attempts:1});expect(pushRequests).toHaveLength(1);
 });
 it('explicit APNs rejection retries with the same event and eventual acceptance',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);mockPush(503);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'pending'});
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();mockPush();
  await flushPending(testEnv);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
 });
 it('missing token remains visible and new token unblocks delivery',async()=>{
  const {parent,listener}=await paired();const event=alert(listener);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'blocked'});
  await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
 });
 it('transport ambiguity is visible and never blindly resent',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});const event=alert(listener);
  pushResponses.push(new Error('connection lost'));
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'uncertain'});
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'uncertain'});
  await flushPending(testEnv);
  const record=await env.DB.prepare('SELECT attempts FROM events WHERE event_id=?').bind(event.eventId).first<{attempts:number}>();expect(record?.attempts).toBe(1);
 });
 it('rejects changed metadata for an existing UUID',async()=>{
  const {listener}=await paired();const event=alert(listener);await call('listener/event',listener,event);
  expect((await call('listener/event',listener,{...event,isRepeat:true})).status).toBe(409);
 });
 it('retries a replacement token uploaded while APNs rejects the old token',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);
  vi.stubGlobal('fetch',vi.fn(async(input:string|URL|Request)=>{
   expect(String(input)).toContain('ab'.repeat(32));
   expect((await call('device/push-token',parent,{token:'cd'.repeat(32)})).status).toBe(200);
   return new Response(JSON.stringify({reason:'Unregistered'}),{status:410});
  }));
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'pending'});
  const saved=await env.DB.prepare('SELECT push_token FROM devices WHERE id=?').bind(parent.deviceId).first<{push_token:string}>();
  expect(await decryptToken(testEnv,saved!.push_token)).toBe('cd'.repeat(32));
  const retry=vi.fn(async(input:string|URL|Request)=>{
   expect(String(input)).toContain('cd'.repeat(32));return new Response('',{status:200});
  });
  vi.stubGlobal('fetch',retry);
  await flushPending(testEnv);
  expect(retry).toHaveBeenCalledTimes(1);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
 });
 it('blocks a rejected token until a later replacement arrives',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);
  pushResponses.push(new Response(JSON.stringify({reason:'BadDeviceToken'}),{status:400}));
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'blocked'});
  const saved=await env.DB.prepare('SELECT push_token FROM devices WHERE id=?').bind(parent.deviceId).first<{push_token:string|null}>();
  expect(saved?.push_token).toBeNull();
  await flushPending(testEnv);expect(pushRequests).toHaveLength(1);
  await call('device/push-token',parent,{token:'cd'.repeat(32)});mockPush();
  await flushPending(testEnv);
  expect(pushRequests).toHaveLength(2);
  expect(pushRequests[1].url).toContain('cd'.repeat(32));
 });
 it('does not dispatch acknowledged blocked alerts after a token upload or client retry',async()=>{
  const {parent,listener}=await paired();const event=alert(listener);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'blocked'});
  expect((await call('alert/acknowledge',parent,{eventId:event.eventId})).status).toBe(200);
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await flushPending(testEnv);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'acknowledged'});
  expect(pushRequests).toHaveLength(0);
  // Late reminders from older clients are silenced during the five-minute mute.
  expect(await (await call('listener/event',listener,{...event,eventId:crypto.randomUUID(),isRepeat:true})).json()).toEqual({status:'acknowledged'});
  expect(pushRequests).toHaveLength(0);
 });
 it('does not retry a pending APNs rejection once the Parent acknowledges it',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);mockPush(503);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'pending'});
  await call('alert/acknowledge',parent,{eventId:event.eventId});
  await env.DB.prepare('UPDATE events SET next_attempt=0').run();
  await flushPending(testEnv);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'acknowledged'});
  expect(pushRequests).toHaveLength(1);
 });
});

describe('private operational diagnostics',()=>{
 it('marks an upload silenced by a snooze or Stop separately from an earlier acknowledgement',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await env.DB.prepare('UPDATE pairs SET created_at=created_at-600000 WHERE parent_id=?').bind(parent.deviceId).run();
  const first=alert(listener);mockPush();await call('listener/event',listener,first);
  expect((await call('alert/acknowledge',parent,{eventId:first.eventId})).status).toBe(200);
  const reasons=async()=>(await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch_skip' ORDER BY sequence").all<{details:string}>()).results.map(r=>JSON.parse(r.details).exit_reason);
  const next=alert(listener);
  expect(await (await call('listener/event',listener,next)).json()).toEqual({status:'acknowledged'});
  expect(await reasons()).toEqual(['suppressed']);
  // A client retry of the same upload observes the earlier decision.
  await call('listener/event',listener,next);
  expect(await reasons()).toEqual(['suppressed','acknowledged']);
  expect(pushRequests).toHaveLength(1);
 });
 it('distinguishes preparation failures and sanitizes arbitrary APNs rejection text',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);
  const request=()=>new Request('https://monitor.test/v1/listener/event',{
   method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(event)
  });
  await worker.fetch(request(),{...testEnv,TOKEN_ENCRYPTION_KEY:'invalid-private-key-marker'});
  expect((await env.DB.prepare("SELECT outcome FROM diagnostics WHERE operation='dispatch'").all()).results).toEqual([{outcome:'token_decryption'}]);
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();
  pushResponses.push(new Response(JSON.stringify({reason:'private-apns-response-marker'}),{status:400}));
  await worker.fetch(request(),testEnv);
  const journal=(await env.DB.prepare("SELECT * FROM diagnostics WHERE operation='dispatch' ORDER BY sequence").all()).results;
  expect(journal[1]).toMatchObject({outcome:'apns_rejected',http_status:400,attempt:2});
  expect(JSON.stringify(journal)).not.toContain('private-apns-response-marker');
  expect(JSON.stringify(journal)).not.toContain('invalid-private-key-marker');
 });
 it('records interrupted dispatch and never retries uncertain acceptance',async()=>{
  const {listener}=await paired();const event=alert(listener);await call('listener/event',listener,event);
  await env.DB.prepare("UPDATE events SET status='sending',lease_until=? WHERE event_id=?").bind(Date.now()-1,event.eventId).run();
  await worker.scheduled({} as ScheduledController,testEnv);
  const row=await env.DB.prepare("SELECT outcome,event_ref FROM diagnostics WHERE outcome='dispatch_interrupted'").first();
  expect(row).toEqual({outcome:'dispatch_interrupted',event_ref:await eventReference(testEnv,event.eventId)});
  expect(pushRequests).toHaveLength(0);
 });
 it('correlates requests and cron retries without persisting private input',async()=>{
  const {parent,listener,code}=await paired();const token='ab'.repeat(32);
  await call('device/push-token',parent,{token});
  const event=alert(listener);mockPush(503);
  const response=await call('listener/event',listener,event);
  const requestId=response.headers.get('x-request-id');expect(requestId).toMatch(/^[0-9a-f-]{36}$/);
  expect(response.headers.get('x-diagnostics-status')).toBe('recorded');
  const ref=await eventReference(testEnv,event.eventId);
  const initial=await env.DB.prepare('SELECT * FROM diagnostics WHERE request_id=?').bind(requestId).all();
  expect(initial.results).toEqual(expect.arrayContaining([
   expect.objectContaining({operation:'alert',outcome:'ok',http_status:200}),
   expect.objectContaining({operation:'dispatch',outcome:'apns_503',event_ref:ref,target:'phone',attempt:1})
  ]));
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();mockPush();
  await worker.scheduled({} as ScheduledController,testEnv);
  const retries=await env.DB.prepare("SELECT outcome,attempt FROM diagnostics WHERE event_ref=? AND operation='dispatch' ORDER BY sequence").bind(ref).all();
  expect(retries.results).toEqual([{outcome:'apns_503',attempt:1},{outcome:'sent',attempt:2}]);
  // Deliberately hostile URLs/headers/body, including a spoofed correlation ID.
  await worker.fetch(new Request('https://monitor.test/private-url-marker?pairing=private-query-marker',{
   method:'POST',headers:{authorization:'Bearer private-auth-marker','x-request-id':'private-id-marker','CF-Connecting-IP':'192.0.2.42'},body:'private-body-marker'
  }),testEnv);
  const journal=JSON.stringify((await env.DB.prepare('SELECT * FROM diagnostics').all()).results);
  for(const privateValue of [secret,token,parent.deviceId,listener.deviceId,code.code,event.eventId,event.episodeId,event.cryStartedAt,
   'private-url-marker','private-query-marker','private-auth-marker','private-id-marker','private-body-marker','192.0.2.42']) {
   expect(journal).not.toContain(privateValue);
  }
 });
 it('keeps diagnostics failures out of API and delivery outcomes',async()=>{
  const {listener}=await paired();
  const failingDB=new Proxy(testEnv.DB,{get(target,key){
   if(key==='prepare')return (sql:string)=>{if(sql.startsWith('INSERT INTO diagnostics')||sql.startsWith('DELETE FROM diagnostics'))throw new Error('private-storage-error');return target.prepare(sql);};
   const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
  }});
   const response=await worker.fetch(new Request('https://monitor.test/v1/listener/event',{
    method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(alert(listener))
   }),{...testEnv,DB:failingDB});
   expect(response.status).toBe(200);expect(await response.json()).toEqual({status:'blocked'});
   expect(response.headers.get('x-diagnostics-status')).toBe('unavailable');
   expect(response.headers.get('x-request-id')).toMatch(/^[0-9a-f-]{36}$/);
   // A missing diagnostic table must not prevent scheduled delivery either.
   await env.DB.prepare("UPDATE events SET status='pending',next_attempt=0").run();
   const {parent}=await env.DB.prepare('SELECT parent_id AS parent FROM pairs WHERE listener_id=?').bind(listener.deviceId).first<{parent:string}>()??{};
   await env.DB.prepare('UPDATE devices SET push_token=? WHERE id=?').bind(await encryptToken(testEnv,'ab'.repeat(32)),parent!).run();
   mockPush();await worker.scheduled({} as ScheduledController,{...testEnv,DB:failingDB});
   expect(await env.DB.prepare('SELECT status FROM events').first()).toEqual({status:'sent'});
 });
 it('records unexpected failures without exception messages or SQL values',async()=>{
  const failingEnv={...testEnv,PAIRING_PEPPER:''};
  const response=await worker.fetch(new Request('https://monitor.test/v1/device/register',{method:'POST'}),failingEnv);
  expect(response.status).toBe(503);
  const record=await env.DB.prepare('SELECT * FROM diagnostics WHERE request_id=?').bind(response.headers.get('x-request-id')).first();
  expect(record).toMatchObject({operation:'register',stage:'validation',outcome:'internal_error',http_status:503});
  expect(JSON.stringify(record)).not.toContain('Pairing configuration missing');
 });
 it('expires the journal before dispatch, preserves recent entries, and records cron completion',async()=>{
  const old=crypto.randomUUID(),recent=crypto.randomUUID();
  for(const requestId of [old,recent])await recordDiagnostic(testEnv,{requestId,operation:'status',stage:'handler',outcome:'ok',started:Date.now()});
  await env.DB.prepare('UPDATE diagnostics SET recorded_at=? WHERE request_id=?').bind(Date.now()-8*86400000,old).run();
  await worker.scheduled({} as ScheduledController,testEnv);
  const rows=(await env.DB.prepare('SELECT request_id,operation,outcome FROM diagnostics').all()).results;
  expect(rows).not.toEqual(expect.arrayContaining([expect.objectContaining({request_id:old})]));
  expect(rows).toEqual(expect.arrayContaining([expect.objectContaining({request_id:recent}),expect.objectContaining({operation:'maintenance',outcome:'ok'})]));
 });
 it('enforces the volume bound even when cron is delayed',async()=>{
  // Advance the sequence to exercise the trigger without 10,000 writes.
  await recordDiagnostic(testEnv,{requestId:crypto.randomUUID(),operation:'status',stage:'handler',outcome:'ok',started:Date.now()});
  const first=await env.DB.prepare('SELECT sequence FROM diagnostics').first<{sequence:number}>();
  await env.DB.prepare("UPDATE sqlite_sequence SET seq=? WHERE name='diagnostics'").bind(first!.sequence+10000).run();
  await recordDiagnostic(testEnv,{requestId:crypto.randomUUID(),operation:'status',stage:'handler',outcome:'ok',started:Date.now()});
  expect((await env.DB.prepare('SELECT sequence FROM diagnostics').all()).results).toHaveLength(1);
 });
});

describe('configurable reminders and acknowledgement mute',()=>{
 async function ready() {
  const pair=await paired();await call('device/push-token',pair.parent,{token:'ab'.repeat(32)});
  // The simulated episode began five minutes ago, after this seeded pairing.
  await env.DB.prepare('UPDATE pairs SET created_at=created_at-600000 WHERE parent_id=?').bind(pair.parent.deviceId).run();
  const event=alert(pair.listener);mockPush();
  expect((await call('listener/event',pair.listener,event)).status).toBe(200);
  return {...pair,event};
 }
 function advance(seconds:number) {
  const time=Date.now()+seconds*1000;vi.spyOn(Date,'now').mockReturnValue(time);return time;
 }
 async function heartbeat(listener:TestDevice,event:Alert,state='crying') {
  await call('listener/heartbeat',listener,{listenerId:listener.deviceId,timestamp:new Date(Date.now()).toISOString(),monitoring:true,powerConnected:true,state,
   episodes:[],currentEpisode:state==='crying'?{id:event.episodeId,startedAt:event.cryStartedAt}:null});
  await env.DB.prepare('UPDATE heartbeats SET received_at=? WHERE listener_id=?').bind(new Date(Date.now()).toISOString(),listener.deviceId).run();
 }
 it('uses five seconds for new devices and migrates retired reminder choices',async()=>{
  const {parent}=await paired();
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {configuration:typeof defaultConfiguration};
  expect(status.configuration).toEqual({...defaultConfiguration,alertDuration:5,repeatInterval:5});
  for(const repeatInterval of [null,15,120,300]) {
   await call('settings',parent,{...defaultConfiguration,alertDuration:60,repeatInterval});
   const saved=await (await call('listener/status',parent,undefined,'GET')).json() as typeof status;
   expect(saved.configuration).toEqual({...defaultConfiguration,alertDuration:60,repeatInterval:5});
  }
 });
 it('shares frequent settings and re-arms an active timer at two seconds',async()=>{
  const {parent,listener,event}=await ready();
  expect((await call('settings',parent,{...defaultConfiguration,repeatInterval:2})).status).toBe(200);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {configuration:typeof defaultConfiguration};
  expect(status.configuration.repeatInterval).toBe(2);
  const config=await (await call('listener/heartbeat',listener,{listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'crying',episodes:[],currentEpisode:{id:event.episodeId,startedAt:event.cryStartedAt}})).json() as typeof defaultConfiguration;
  expect(config.repeatInterval).toBe(2);
  const stub=testEnv.ALERT_REMINDERS.getByName(parent.deviceId);
  const next=await runInDurableObject(stub,async(_instance,state)=>state.storage.getAlarm());
  expect(next).toBeGreaterThan(Date.now());expect(next).toBeLessThanOrEqual(Date.now()+2000);
  // The alarm's Worker runs in a separate isolate with its own clock and bindings.
  await runDurableObjectAlarm(stub);
  const following=await runInDurableObject(stub,async(_instance,state)=>state.storage.getAlarm());
  expect(following).toBeGreaterThan(Date.now());expect(following).toBeLessThanOrEqual(Date.now()+2000);
  advance(1);await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(1);
  advance(1);mockPush();await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(2);
  // Switching back must prevent another reminder before five seconds have passed.
  expect((await call('settings',listener,{...defaultConfiguration,repeatInterval:5})).status).toBe(200);
  advance(2);await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(2);
  advance(3);mockPush();await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(3);
 });
 it('does not accept unsupported one-second reminders',async()=>{
  const {parent}=await paired();
  expect((await call('settings',parent,{...defaultConfiguration,repeatInterval:1})).status).toBe(400);
 });
 it('persists a timer and duplicate uploads do not postpone it',async()=>{
  const {parent,listener,event}=await ready();
  const stub=testEnv.ALERT_REMINDERS.getByName(parent.deviceId);
  const first=await runInDurableObject(stub,async(_instance,state)=>state.storage.getAlarm());
  expect(first).toBeGreaterThan(Date.now());expect(first).toBeLessThanOrEqual(Date.now()+5000);
  await call('listener/event',listener,event);
  expect(await runInDurableObject(stub,async(_instance,state)=>state.storage.getAlarm())).toBe(first);
 });
 it('advances a persisted 15-second timer to the new five-second cadence',async()=>{
  const {parent,listener,event}=await ready();
  const stub=testEnv.ALERT_REMINDERS.getByName(parent.deviceId);
  await runInDurableObject(stub,async(_instance,state)=>state.storage.setAlarm(Date.now()+15000));
  await call('listener/event',listener,event);
  const next=await runInDurableObject(stub,async(_instance,state)=>state.storage.getAlarm());
  expect(next).toBeGreaterThan(Date.now());expect(next).toBeLessThanOrEqual(Date.now()+5000);
 });
 it('sends nothing before 5 seconds, then repeats even when the Listener is quiet',async()=>{
  const {parent,listener,event}=await ready();await heartbeat(listener,event,'quiet');
  advance(4);await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(1);
  advance(1);mockPush();await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(2);
  const reminder=JSON.parse(String(pushRequests[1].init?.body));
  expect(reminder.eventId).not.toBe(event.eventId);expect(reminder.episodeId).toBe(event.episodeId);
  expect(reminder.aps.alert.title).toBe('Repeat alert · Check on baby');expect(reminder.aps.alert.body).toContain('Settings');
  const headers=pushRequests[1].init?.headers as Record<string,string>;
  expect(Number(headers['apns-expiration'])).toBe(Math.floor(Date.now()/1000)+15);
  expect(headers['apns-collapse-id']).toBe(`phone:${reminder.eventId}`);
  advance(5);mockPush();await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(3);
  const later=JSON.parse(String(pushRequests[2].init?.body));
  expect(later.episodeId).toBe(event.episodeId);expect(later.eventId).not.toBe(reminder.eventId);
  const collapseIDs=pushRequests.map(r=>new Headers(r.init?.headers).get('apns-collapse-id'));
  expect(new Set(collapseIDs).size).toBe(3);
  for(const r of pushRequests)expect(JSON.parse(String(r.init?.body)).aps['thread-id']).toBeUndefined();
 });
 it('creates only one reminder for a source event under concurrent work',async()=>{
  const {parent}=await ready();advance(5);mockPush();
  await Promise.all([runReminder(testEnv,parent.deviceId),runReminder(testEnv,parent.deviceId)]);
  expect(pushRequests).toHaveLength(2);
 });
 it('acknowledges all crying alerts and idempotent retries do not extend the one-minute default',async()=>{
  const {parent,listener,event}=await ready();
  expect((await call('alert/acknowledge',parent,{eventId:event.eventId})).status).toBe(200);
  const mute=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(mute!.alerts_muted_until-Date.now()).toBeGreaterThan(59000);
  advance(15);await runReminder(testEnv,parent.deviceId);
  const later={...alert(listener),cryStartedAt:new Date(Date.now()-300000).toISOString(),createdAt:new Date(Date.now()).toISOString()};
  expect(await (await call('listener/event',listener,later)).json()).toEqual({status:'acknowledged'});
  await call('alert/acknowledge',parent,{eventId:event.eventId});
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alertsMutedUntil:string};
  expect(Date.parse(status.alertsMutedUntil)).toBe(mute!.alerts_muted_until);
  expect(pushRequests).toHaveLength(1);
 });
 it('resumes early, keeps muted uploads silent, and permits fresh ongoing-cry reminders',async()=>{
  const {parent,listener,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alertsMutedUntil:string};
  const expectedUntil=Date.parse(status.alertsMutedUntil),mutedAt=Date.now();
  advance(15);
  expect((await call('alert/resume',parent,{expectedUntil})).status).toBe(200);
  const resumed=Date.now();
  const window=await env.DB.prepare('SELECT until_at FROM alert_snoozes WHERE event_id=?').bind(event.eventId).first<{until_at:number}>();
  expect(window?.until_at).toBe(resumed);
  const late={...alert(listener),createdAt:new Date(mutedAt+5000).toISOString(),cryStartedAt:new Date(mutedAt+5000-300000).toISOString()};
  expect(await (await call('listener/event',listener,late)).json()).toEqual({status:'acknowledged'});
  advance(5);await heartbeat(listener,event);mockPush();await runReminder(testEnv,parent.deviceId);
  expect(pushRequests).toHaveLength(2);
  const reminder=JSON.parse(String(pushRequests[1].init?.body));
  await call('alert/acknowledge',parent,{eventId:reminder.eventId});
  const newer=await (await call('listener/status',parent,undefined,'GET')).json() as {alertsMutedUntil:string};
  // A lost response/retry for the earlier snooze cannot cancel this new one.
  await call('alert/resume',parent,{expectedUntil});
  const afterRetry=await (await call('listener/status',parent,undefined,'GET')).json() as {alertsMutedUntil:string};
  expect(afterRetry.alertsMutedUntil).toBe(newer.alertsMutedUntil);
 });
 it('restricts resume to the current pairing and validates the expected deadline',async()=>{
  const {parent,listener,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alertsMutedUntil:string};
  const expectedUntil=Date.parse(status.alertsMutedUntil);
  const unpaired=device('listener');await register(unpaired);
  expect((await call('alert/resume',unpaired,{expectedUntil})).status).toBe(409);
  expect((await call('alert/resume',parent,{})).status).toBe(400);
  const other=await paired();
  await call('alert/resume',other.parent,{expectedUntil});
  const unchanged=await (await call('listener/status',parent,undefined,'GET')).json() as {alertsMutedUntil:string};
  expect(unchanged.alertsMutedUntil).toBe(status.alertsMutedUntil);
 });
 it('does not restart reminders when monitoring stopped during a snooze',async()=>{
  const {parent,listener,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alertsMutedUntil:string};
  await call('monitoring',parent,{id:crypto.randomUUID(),enabled:false});advance(5);
  await call('alert/resume',parent,{expectedUntil:Date.parse(status.alertsMutedUntil)});
  await heartbeat(listener,event);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  expect(pushRequests).toHaveLength(1);
 });
 it('does not replay delayed offline alerts created during the mute after it expires',async()=>{
  const {parent,listener,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  const created=Date.now()+30000;
  const queued={...alert(listener),createdAt:new Date(created).toISOString(),cryStartedAt:new Date(created-300000).toISOString()};
  advance(61);
  expect(await (await call('listener/event',listener,queued)).json()).toEqual({status:'acknowledged'});
  expect(pushRequests).toHaveLength(1);
 });
 it('resumes an ongoing crying episode after the one-minute default and permits another acknowledgement',async()=>{
  const {parent,listener,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  advance(59);await heartbeat(listener,event);await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(1);
  advance(2);await heartbeat(listener,event);mockPush();await runReminder(testEnv,parent.deviceId);
  expect(pushRequests).toHaveLength(2);
  const reminder=JSON.parse(String(pushRequests[1].init?.body));
  expect((await call('alert/acknowledge',parent,{eventId:reminder.eventId})).status).toBe(200);
  advance(15);await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(2);
 });
 it('stops after the mute if quiet, stale, or unpaired',async()=>{
  const {parent,listener,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  advance(61);expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  await heartbeat(listener,event,'quiet');expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  await call('pairing/remove',parent);expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  expect(pushRequests).toHaveLength(1);
 });
 it('does not repeat test notifications or let their acknowledgement mute real alerts',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const test={...alert(listener),isTest:true};mockPush();await call('listener/event',listener,test);
  await call('alert/acknowledge',parent,{eventId:test.eventId});advance(15);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  const mute=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(mute?.alerts_muted_until).toBe(0);expect(pushRequests).toHaveLength(1);
 });
 it('clears the durable timer after unpairing and resets the mute for replacement',async()=>{
  const {parent,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  const stub=testEnv.ALERT_REMINDERS.getByName(parent.deviceId);
  const mute=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(await runInDurableObject(stub,async(_instance,state)=>state.storage.getAlarm())).toBe(mute!.alerts_muted_until);
  await call('pairing/remove',parent);
  expect(await runDurableObjectAlarm(stub)).toBe(true);
  expect(await runInDurableObject(stub,async(_instance,state)=>state.storage.getAlarm())).toBeNull();
  expect((await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>())?.alerts_muted_until).toBe(0);
 });
 it('does not acknowledge new alerts when retrying an old acknowledgement',async()=>{
  const {parent,listener,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  advance(61);const createdAt=new Date(Date.now()).toISOString();
  const later={...alert(listener),createdAt,cryStartedAt:createdAt,durationSeconds:0};mockPush();await call('listener/event',listener,later);
  await call('alert/acknowledge',parent,{eventId:event.eventId});
  const saved=await env.DB.prepare('SELECT acknowledged_at FROM events WHERE event_id=?').bind(later.eventId).first<{acknowledged_at:string|null}>();
  expect(saved?.acknowledged_at).toBeNull();
 });
 it('re-arms on a fresh heartbeat after a stale mute-expiry check',async()=>{
  const {parent,listener,event}=await ready();await call('alert/acknowledge',parent,{eventId:event.eventId});
  advance(61);expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  await heartbeat(listener,event);mockPush();expect(await runReminder(testEnv,parent.deviceId)).toBe(true);
  expect(pushRequests).toHaveLength(2);
 });
 it('keeps connection alerts active during the crying-alert mute',async()=>{
  const {parent,listener,event}=await ready();await heartbeat(listener,event);
  await call('alert/acknowledge',parent,{eventId:event.eventId});
  await call('listener/heartbeat',listener,{listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:false,powerConnected:true,state:'quiet',episodes:[]});
  mockPush();await flushConnections(testEnv);expect(pushRequests).toHaveLength(2);
  expect(JSON.parse(String(pushRequests[1].init?.body)).connectionState).toBe('stopped');
 });

 it('does not turn an expired initial offline event into a fresh reminder',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await env.DB.prepare('UPDATE pairs SET created_at=created_at-172800000 WHERE parent_id=?').bind(parent.deviceId).run();
  const created=Date.now()-90000000;
  const old={...alert(listener),createdAt:new Date(created).toISOString(),cryStartedAt:new Date(created-300000).toISOString()};
  expect(await (await call('listener/event',listener,old)).json()).toEqual({status:'failed'});
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);expect(pushRequests).toHaveLength(0);
 });

 it('uses the selected snooze without changing a snooze already in progress',async()=>{
  const {parent,event}=await ready();
  await call('settings',parent,{...defaultConfiguration,snoozeDuration:300});
  await call('alert/acknowledge',parent,{eventId:event.eventId});
  const first=await env.DB.prepare('SELECT alerts_muted_until,alerts_muted_at FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number;alerts_muted_at:number}>();
  expect(first!.alerts_muted_until-first!.alerts_muted_at).toBe(300000);
  await call('settings',parent,{...defaultConfiguration,snoozeDuration:60});
  const current=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(current!.alerts_muted_until).toBe(first!.alerts_muted_until);
  for(const snoozeDuration of [0,30,61,3600,'60'])expect((await call('settings',parent,{...defaultConfiguration,snoozeDuration})).status).toBe(400);
 });

});

describe('12-hour event timeline',()=>{
 const beat=(listener:TestDevice)=>({listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[]});
 async function setup(){const pair=await paired();await env.DB.prepare('UPDATE pairs SET created_at=?').bind(Date.now()-86400000).run();return pair;}
 async function history(d:TestDevice){const response=await call('timeline',d,undefined,'GET');expect(response.status).toBe(200);return await response.json() as {paired:boolean;events:import('../src/timeline').TimelineEvent[];truncated:boolean};}
 it('durably merges offline monitoring transitions and episodes without duplicate retries',async()=>{
  const {parent,listener}=await setup(),now=Date.now(),episodeID=crypto.randomUUID();
  const transitions=[{id:crypto.randomUUID(),kind:'monitoring_started',occurredAt:new Date(now-60000).toISOString()},{id:crypto.randomUUID(),kind:'monitoring_stopped',occurredAt:new Date(now-30000).toISOString()}];
  const value={...beat(listener),monitoring:false,timelineEvents:transitions,episodes:[{id:episodeID,startedAt:new Date(now-55000).toISOString(),endedAt:new Date(now-35000).toISOString()}]};
  expect((await call('listener/heartbeat',listener,value)).status).toBe(200);
  expect((await call('listener/heartbeat',listener,value)).status).toBe(200);
  const page=await history(parent),other=await history(listener);
  for(const kind of ['monitoring_started','monitoring_stopped','cry_started','cry_ended'])expect(page.events.filter(e=>e.kind===kind)).toHaveLength(1);
  expect(page.events).toEqual(other.events);expect(page.truncated).toBe(false);
  expect((await call('listener/heartbeat',listener,{...beat(listener),timelineEvents:[{...transitions[0],audio:'forbidden'}]})).status).toBe(400);
  expect((await call('listener/heartbeat',listener,{...beat(listener),timelineEvents:[{...transitions[0],kind:'alert_acknowledged'}]})).status).toBe(400);
 });
 it('groups all reminder sends and journals only explicit acknowledgement',async()=>{
  const {parent,listener}=await setup();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const initial=alert(listener);mockPush(200,3);
  for(let i=0;i<3;i++)expect((await call('listener/event',listener,{...initial,eventId:i===0?initial.eventId:crypto.randomUUID(),isRepeat:i!==0})).status).toBe(200);
  expect((await call('alert/acknowledge',parent,{eventId:initial.eventId})).status).toBe(200);
  expect((await call('alert/acknowledge',parent,{eventId:initial.eventId})).status).toBe(200);
  const suppressed={...alert(listener),createdAt:new Date().toISOString()};
  expect((await call('listener/event',listener,suppressed)).status).toBe(200);
  const page=await history(parent);
  expect(page.events.filter(e=>e.kind==='alert_acknowledged')).toHaveLength(1);
  const sent=page.events.filter(e=>e.kind==='alert');expect(sent).toHaveLength(1);expect(sent[0].count).toBe(3);expect(sent[0].status).toBe('sent');
  expect(page.events.find(e=>e.kind==='alert_acknowledged')?.endAt).toBeDefined();
 });
 it('records outages with connection alerts disabled and detects gaps before cron',async()=>{
  const {parent,listener}=await setup();await call('connection-alerts',parent,{enabled:false});
  await call('listener/heartbeat',listener,beat(listener));const last=new Date(Date.now()-240000).toISOString();
  await env.DB.prepare('UPDATE heartbeats SET received_at=?').bind(last).run();
  let page=await history(parent);expect(page.events.find(e=>e.kind==='heartbeat_missing')?.endAt).toBe(last);
  await flushConnections(testEnv);await flushConnections(testEnv);expect(pushRequests).toHaveLength(0);
  await call('listener/heartbeat',listener,beat(listener));page=await history(parent);
  expect(page.events.filter(e=>e.kind==='heartbeat_missing')).toHaveLength(1);
  expect(page.events.filter(e=>e.kind==='connection_restored')).toHaveLength(1);
 });
 it('isolates pairs and clears timeline data on unpairing and device deletion',async()=>{
  const {parent,listener}=await setup();const transition={id:crypto.randomUUID(),kind:'monitoring_started',occurredAt:new Date().toISOString()};
  await call('listener/heartbeat',listener,{...beat(listener),timelineEvents:[transition]});
  const outsider=device('parent');await register(outsider);expect((await history(outsider)).events).toHaveLength(0);
  expect((await call('pairing/remove',parent)).status).toBe(200);expect((await history(parent)).events).toHaveLength(0);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM timeline_events').first<{n:number}>()).toEqual({n:0});
  expect((await call('device/delete',listener)).status).toBe(200);
 });
 it('clips the window but retains a monitoring boundary before it',async()=>{
  const {parent,listener}=await setup();const pair=await env.DB.prepare('SELECT * FROM pairs').first<{parent_id:string;listener_id:string;created_at:number}>();
  const {timelineInsert}=await import('../src/timeline');
  for(const [hours,kind] of [[13,'monitoring_started'],[1,'power_connected']] as const)
   await timelineInsert(testEnv,pair!,{id:crypto.randomUUID(),kind,occurredAt:new Date(Date.now()-hours*3600000).toISOString()}).run();
  const page=await history(parent);expect(page.events.filter(e=>e.kind==='monitoring_started')).toHaveLength(1);
  expect(page.events.filter(e=>e.kind==='power_connected')).toHaveLength(1);
 });
});

it('accepts offline cry journal entries without relying on the latest 100 episodes',async()=>{
 const {parent,listener}=await paired();await env.DB.prepare('UPDATE pairs SET created_at=?').bind(Date.now()-86400000).run();
 const episodeID=crypto.randomUUID(),now=Date.now(),startedAt=new Date(now-10000).toISOString();
 const timelineEvents=[{id:`cry:${episodeID}`,kind:'cry_started',occurredAt:startedAt,episodeID},
  {id:`cry-end:${episodeID}`,kind:'cry_ended',occurredAt:new Date(now-5000).toISOString(),endAt:startedAt,episodeID}];
 const value={listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:false,powerConnected:true,state:'quiet',episodes:[],timelineEvents};
 expect((await call('listener/heartbeat',listener,value)).status).toBe(200);expect((await call('listener/heartbeat',listener,value)).status).toBe(200);
 const page=await (await call('timeline',parent,undefined,'GET')).json() as {events:import('../src/timeline').TimelineEvent[]};
 expect(page.events.filter(e=>e.episodeID===episodeID)).toHaveLength(2);
 expect((await call('listener/heartbeat',listener,{...value,timelineEvents:[{...timelineEvents[1],audioFeatures:[1]}]})).status).toBe(400);
});

// Hold an acknowledgement after its reads, immediately before the atomic write.
// This reproduces interleavings without sleeps or concurrent test timing guesses.
async function pausedAcknowledgement(parent:TestDevice,eventId:string) {
 const {acknowledge}=await import('../src/alerts');
 const registered=await env.DB.prepare('SELECT * FROM devices WHERE id=?').bind(parent.deviceId).first<import('../src/types').Device>();
 let release!:()=>void,ready!:()=>void;
 const gate=new Promise<void>(resolve=>{release=resolve;});
 const entered=new Promise<void>(resolve=>{ready=resolve;});
 const delayedDB=new Proxy(testEnv.DB,{get(target,prop){
  if(prop==='batch')return async(statements:D1PreparedStatement[])=>{ready();await gate;return target.batch(statements);};
  const member=Reflect.get(target,prop);return typeof member==='function'?member.bind(target):member;
 }});
 const pending=acknowledge({...testEnv,DB:delayedDB},registered!,{eventId});
 await entered;
 return async()=>{release();await pending;};
}

describe('alert delivery regressions',()=>{
 it('keeps reminders alive for a current alert when an expired outbox event arrives later',async()=>{
  const {parent,listener}=await paired();
  await env.DB.prepare('UPDATE pairs SET created_at=?').bind(Date.now()-172800000).run();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const current=alert(listener);mockPush();
  expect(await (await call('listener/event',listener,current)).json()).toEqual({status:'sent'});
  const now=Date.now();vi.spyOn(Date,'now').mockReturnValue(now+10000);
  const created=now-90000000;
  const expired={...alert(listener),createdAt:new Date(created).toISOString(),cryStartedAt:new Date(created-300000).toISOString()};
  expect(await (await call('listener/event',listener,expired)).json()).toEqual({status:'failed'});
  mockPush();expect(await runReminder(testEnv,parent.deviceId)).toBe(true);
  expect(pushRequests).toHaveLength(2);
  expect(JSON.parse(String(pushRequests[1].init?.body)).episodeId).toBe(current.episodeId);
 });
 it('suppresses earlier snoozes but still delivers alerts created between snoozes',async()=>{
  const {parent,listener}=await paired();
  await env.DB.prepare('UPDATE pairs SET created_at=?').bind(Date.now()-3600000).run();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const first=alert(listener);mockPush();await call('listener/event',listener,first);
  await call('alert/acknowledge',parent,{eventId:first.eventId});
  const now=Date.now();
  const delayed={...alert(listener),createdAt:new Date(now+30000).toISOString(),cryStartedAt:new Date(now-270000).toISOString()};
  vi.spyOn(Date,'now').mockReturnValue(now+65000);
  const second={...alert(listener),createdAt:new Date(now+65000).toISOString(),cryStartedAt:new Date(now-235000).toISOString()};
  mockPush();await call('listener/event',listener,second);
  await call('alert/acknowledge',parent,{eventId:second.eventId});
  vi.spyOn(Date,'now').mockReturnValue(now+130000);
  expect(await (await call('listener/event',listener,delayed)).json()).toEqual({status:'acknowledged'});
  expect(pushRequests).toHaveLength(2);
  const between={...alert(listener),createdAt:new Date(now+62000).toISOString(),cryStartedAt:new Date(now-238000).toISOString()};
  mockPush();expect(await (await call('listener/event',listener,between)).json()).toEqual({status:'sent'});
 });
 it('does not let a concurrent duplicate acknowledgement acknowledge a later alert',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const first=alert(listener);mockPush();await call('listener/event',listener,first);
  const finish=await pausedAcknowledgement(parent,first.eventId);
  let later:Alert;
  try {
   await call('alert/acknowledge',parent,{eventId:first.eventId});
   const time=Date.now()+65000;vi.spyOn(Date,'now').mockReturnValue(time);
   later={...alert(listener),createdAt:new Date(time).toISOString(),cryStartedAt:new Date(time-300000).toISOString()};
   mockPush();await call('listener/event',listener,later);
  }finally{await finish();}
  const row=await env.DB.prepare('SELECT acknowledged_at FROM events WHERE event_id=?').bind(later.eventId).first<{acknowledged_at:string|null}>();
  expect(row?.acknowledged_at).toBeNull();
  const muted=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(muted!.alerts_muted_until).toBeLessThanOrEqual(Date.now());
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM alert_snoozes').first()).toEqual({n:1});
  expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM timeline_events WHERE kind='alert_acknowledged'").first()).toEqual({n:1});
 });
 it('does not apply an old in-flight acknowledgement to a replacement pairing',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const first=alert(listener);mockPush();await call('listener/event',listener,first);
  const finish=await pausedAcknowledgement(parent,first.eventId);
  let later:Alert;
  try {
   expect((await call('pairing/remove',parent)).status).toBe(200);
   const code=await (await call('pairing/create',parent)).json() as {code:string};
   const replacement=device('listener');await register(replacement);
   expect((await call('pairing/claim',replacement,{code:code.code})).status).toBe(200);
   later=alert(replacement);mockPush();await call('listener/event',replacement,later);
  }finally{await finish();}
  const row=await env.DB.prepare('SELECT acknowledged_at FROM events WHERE event_id=?').bind(later.eventId).first<{acknowledged_at:string|null}>();
  expect(row?.acknowledged_at).toBeNull();
  const muted=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(muted!.alerts_muted_until).toBe(0);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM alert_snoozes').first()).toEqual({n:0});
  expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM timeline_events WHERE kind='alert_acknowledged'").first()).toEqual({n:0});
 });
 it('retains snoozes by their end time through cleanup and expires them afterward',async()=>{
  // This test intentionally travels a day backwards. Start with independent
  // token state rather than treating a real clock-regression refusal as a
  // notification or snooze failure. Other tests cover that refusal explicitly.
  const stub=env.APNS_PROVIDER_TOKENS.get(env.APNS_PROVIDER_TOKENS.newUniqueId());
  const isolated={...testEnv,APNS_PROVIDER_TOKENS:{getByName:()=>stub}} as unknown as Env;
  const tokenCache=new ProviderTokenCache();
  vi.spyOn(providerTokens,'get').mockImplementation((_env,latency,checkAuthority)=>tokenCache.get(isolated,latency,checkAuthority));
  const {parent,listener}=await paired();
  const now=Date.now(),start=now-86400000-600000,until=start+900000;
  await env.DB.prepare('UPDATE pairs SET created_at=?').bind(start-3600000).run();
  await call('settings',parent,{...defaultConfiguration,snoozeDuration:900});
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  vi.spyOn(Date,'now').mockReturnValue(start);
  const first={...alert(listener),createdAt:new Date(start).toISOString(),cryStartedAt:new Date(start-300000).toISOString()};
  mockPush();await call('listener/event',listener,first);
  await call('alert/acknowledge',parent,{eventId:first.eventId});
  vi.spyOn(Date,'now').mockReturnValue(now);
  // Isolate historical suppression from the compatibility/current-mute fields.
  await env.DB.prepare('UPDATE devices SET alerts_muted_at=0,alerts_muted_until=0 WHERE id=?').bind(parent.deviceId).run();
  await flushPending(testEnv);
  expect(await env.DB.prepare('SELECT until_at FROM alert_snoozes').first()).toEqual({until_at:until});
  const created=now-86400000+60000;
  const delayed={...alert(listener),createdAt:new Date(created).toISOString(),cryStartedAt:new Date(created-300000).toISOString()};
  expect(await (await call('listener/event',listener,delayed)).json()).toEqual({status:'acknowledged'});
  expect(pushRequests).toHaveLength(1);
  vi.spyOn(Date,'now').mockReturnValue(until+86400001);
  await flushPending(testEnv);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM alert_snoozes').first()).toEqual({n:0});
 });
 it.each(['pairing/remove','device/delete'])('clears snooze history on %s',async(path)=>{
  const {parent,listener}=await paired();
  const event=alert(listener);await call('listener/event',listener,event);
  await call('alert/acknowledge',parent,{eventId:event.eventId});
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM alert_snoozes').first()).toEqual({n:1});
  expect((await call(path,parent)).status).toBe(200);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM alert_snoozes').first()).toEqual({n:0});
 });
 it('migrates the last existing snooze before a later acknowledgement replaces it',async()=>{
  const {parent,listener}=await paired();
  const start=Date.now()-120000,until=start+60000;
  await env.DB.prepare('UPDATE pairs SET created_at=?').bind(start-60000).run();
  await env.DB.prepare('UPDATE devices SET alerts_muted_at=?,alerts_muted_until=? WHERE id=?').bind(start,until,parent.deviceId).run();
  const migration=env.TEST_MIGRATIONS.find(m=>m.name.includes('0008_alert_snoozes'))!;
  await env.DB.prepare('DROP TABLE alert_snoozes').run();
  await env.DB.batch(migration.queries.map(query=>env.DB.prepare(query)));
  await env.DB.prepare('UPDATE devices SET alerts_muted_at=0,alerts_muted_until=0 WHERE id=?').bind(parent.deviceId).run();
  const created=start+30000;
  const delayed={...alert(listener),createdAt:new Date(created).toISOString(),cryStartedAt:new Date(created-300000).toISOString()};
  expect(await (await call('listener/event',listener,delayed)).json()).toEqual({status:'acknowledged'});
  expect(pushRequests).toHaveLength(0);
 });
});

describe('live sound relay',()=>{
 const sockets:WebSocket[]=[];
 const frame=()=>({type:'levels' as const,sampledAt:Date.now()/1000,levels:Array.from({length:32},(_,i)=>-80+i),threshold:-45,state:'quiet' as const,alertDuration:30});
 class Reader {
  private queued:Record<string,unknown>[]=[];
  private waiting:((v:Record<string,unknown>)=>void)[]=[];
  constructor(readonly socket:WebSocket){
   socket.addEventListener('message',event=>{
    const value=JSON.parse(String(event.data)) as Record<string,unknown>;
    const next=this.waiting.shift();if(next)next(value);else this.queued.push(value);
   });
  }
  async next():Promise<Record<string,unknown>> {
   const value=this.queued.shift();if(value)return value;
   return new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(new Error('Live sound response timed out.')),2000);
    this.waiting.push(value=>{clearTimeout(timer);resolve(value);});
   });
  }
 }
 async function open(d:TestDevice){
  const response=await worker.fetch(new Request('https://monitor.test/v1/live-sound',{headers:{upgrade:'websocket',authorization:`Bearer ${d.deviceId}.${d.secret}`}}),testEnv);
  expect(response.status).toBe(101);
  const socket=response.webSocket!;sockets.push(socket);
  const reader=new Reader(socket);socket.accept();
  expect(await reader.next()).toEqual({type:'ready'});
  return reader;
 }
 afterEach(()=>{for(const socket of sockets.splice(0))socket.close(1000);});
 it('requires an authenticated pairing and a WebSocket upgrade',async()=>{
  const outsider=device('parent');await register(outsider);
  expect((await call('live-sound',undefined,undefined,'GET')).status).toBe(401);
  expect((await call('live-sound',outsider,undefined,'GET')).status).toBe(426);
  expect((await worker.fetch(new Request('https://monitor.test/v1/live-sound',{headers:{upgrade:'websocket',authorization:`Bearer ${outsider.deviceId}.${outsider.secret}`}}),testEnv)).status).toBe(409);
 });
 it('keeps both caregivers connected and replaces only the reconnecting phone',async()=>{
  const {parent,listener}=await paired(),partner=device('parent');await register(partner);
  const {code}=await(await call('caregivers/invite',parent,{name:'Jordan'})).json() as {code:string};
  expect((await call('caregivers/join',partner,{code,name:'Alex'})).status).toBe(200);
  const source=await open(listener);await source.next();
  const first=await open(parent);await source.next();
  const second=await open(partner);await source.next();
  const reconnected=await open(parent);await source.next();
  const firstChallenge=crypto.randomUUID(),secondChallenge=crypto.randomUUID();
  reconnected.socket.send(JSON.stringify({type:'ping',requestID:firstChallenge}));
  expect(await source.next()).toEqual({type:'viewing',active:true,requestID:firstChallenge});await reconnected.next();
  second.socket.send(JSON.stringify({type:'ping',requestID:secondChallenge}));
  expect(await source.next()).toEqual({type:'viewing',active:true,requestID:secondChallenge});await second.next();
  const value={...frame(),requestID:secondChallenge,requestIDs:[firstChallenge,secondChallenge]};source.socket.send(JSON.stringify(value));
  expect(await reconnected.next()).toEqual(value);expect(await second.next()).toEqual(value);
  expect(first.socket.readyState).not.toBe(WebSocket.OPEN);
 });
 it('revokes a departed caregiver on revalidation when immediate chart revocation fails',async()=>{
  const {parent,listener}=await paired(),partner=device('parent');await register(partner);
  const {code}=await(await call('caregivers/invite',parent,{name:'Jordan'})).json() as {code:string};
  await call('caregivers/join',partner,{code,name:'Alex'});
  const source=await open(listener);await source.next();
  const owner=await open(parent);await source.next();const invited=await open(partner);await source.next();
  const closed=new Promise<number>(resolve=>invited.socket.addEventListener('close',event=>resolve(event.code)));
  const failing=vi.spyOn(testEnv.LIVE_SOUND,'get').mockImplementation(()=>{throw new Error('Relay unavailable');});
  expect((await call('pairing/remove',partner)).status).toBe(200);failing.mockRestore();
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+16000);
  const value=frame();source.socket.send(JSON.stringify(value));
  expect(await closed).toBe(1008);expect(await owner.next()).toEqual(value);
 });
 it('relays the exact nursery chart only to its paired Parent and signals viewing demand',async()=>{
  const a=await paired(),b=await paired();
  const listener=await open(a.listener);
  expect(await listener.next()).toEqual({type:'viewing',active:false});
  const parent=await open(a.parent),other=await open(b.parent);
  expect(await listener.next()).toEqual({type:'viewing',active:true});
  const base=frame();
  const value={...base,levels:Array.from({length:120},(_,i)=>-80+i%40),notificationTimes:[base.sampledAt-25,base.sampledAt-3]};
  listener.socket.send(JSON.stringify(value));
  expect(await parent.next()).toEqual(value);
  other.socket.send(JSON.stringify({type:'ping'}));
  expect(await other.next()).toEqual({type:'pong'});
  // Numeric sound is not added to heartbeat/history or diagnostic storage.
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM heartbeats').first('n')).toBe(0);
  const rows=await env.DB.prepare('SELECT * FROM diagnostics').all();
  expect(JSON.stringify(rows.results)).not.toContain('levels');
  parent.socket.close(1000);
  expect(await listener.next()).toEqual({type:'viewing',active:false});
 });
 it.each([false,true])('closes an existing stream immediately on removal (delete=%s)',async(removeDevice)=>{
  const pair=await paired();const listener=await open(pair.listener);
  await listener.next();const parent=await open(pair.parent);await listener.next();
  const closed=new Promise<number>(resolve=>parent.socket.addEventListener('close',event=>resolve(event.code)));
  expect((await call(removeDevice?'device/delete':'pairing/remove',pair.parent)).status).toBe(200);
  expect(await closed).toBe(1008);
 });
 it('rejects Parent attempts to publish sound',async()=>{
  const pair=await paired();const parent=await open(pair.parent);
  const closed=new Promise<number>(resolve=>parent.socket.addEventListener('close',event=>resolve(event.code)));
  parent.socket.send(JSON.stringify(frame()));expect(await closed).toBe(1008);
 });
 it.each([false,true])('preserves device removal when the live relay is unavailable (delete=%s)',async(removeDevice)=>{
  const pair=await paired();
  vi.spyOn(testEnv.LIVE_SOUND,'get').mockImplementation(()=>{throw new Error('Relay unavailable');});
  expect((await call(removeDevice?'device/delete':'pairing/remove',pair.parent)).status).toBe(200);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM pairs').first('n')).toBe(0);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM devices WHERE id=?').bind(pair.parent.deviceId).first('n')).toBe(removeDevice?0:1);
 });
 it('allows a keepalive alongside a frame without treating it as a burst',async()=>{
  const pair=await paired();const listener=await open(pair.listener);await listener.next();
  const parent=await open(pair.parent);await listener.next();
  const value=frame();listener.socket.send(JSON.stringify(value));
  listener.socket.send(JSON.stringify({type:'ping'}));
  expect(await parent.next()).toEqual(value);
  expect(await listener.next()).toEqual({type:'pong'});
 });
 it('carries Parent freshness challenges through the Listener without changing chart values',async()=>{
  const pair=await paired();const listener=await open(pair.listener);await listener.next();
  const parent=await open(pair.parent);await listener.next();
  const requestID=crypto.randomUUID();parent.socket.send(JSON.stringify({type:'ping',requestID}));
  expect(await listener.next()).toEqual({type:'viewing',active:true,requestID});
  expect(await parent.next()).toEqual({type:'pong'});
  const value={...frame(),requestID};listener.socket.send(JSON.stringify(value));
  expect(await parent.next()).toEqual(value);
 });
 it('rejects recordings, extra fields, invalid scales, and oversized windows',()=>{
  expect(soundFrame(frame()).levels).toHaveLength(32);
  expect(soundFrame({...frame(),levels:Array(120).fill(-40)}).levels).toHaveLength(120);
  for(const value of [{...frame(),audio:'recording'},{...frame(),levels:[0]},{...frame(),requestIDs:['bad']},{...frame(),requestIDs:Array(17).fill(crypto.randomUUID())},
   {...frame(),levels:Array(32).fill(-101)},{...frame(),levels:Array(32).fill(NaN)},
   {...frame(),threshold:-90},{...frame(),episodeStartedAt:Date.now()/1000+100},
   {...frame(),levels:Array(121).fill(-40)},{...frame(),notificationTimes:[Date.now()/1000-31]},
   {...frame(),notificationTimes:[Date.now()/1000+1]},{...frame(),notificationTimes:[NaN]},
   {...frame(),notificationTimes:Array(33).fill(Date.now()/1000)}])expect(()=>soundFrame(value)).toThrow();
 });
});

describe('monitoring controls',()=>{
 const command=async(d:TestDevice,enabled:boolean,id=crypto.randomUUID())=>{
  const response=await call('monitoring',d,{id,enabled});expect(response.status).toBe(200);
  return await response.json() as {id:string;enabled:boolean;status:string;expiresAt:string};
 };
 const status=async(d:TestDevice)=>(await (await call('listener/status',d,undefined,'GET')).json()) as {monitoring:boolean;monitoringCommand:{id:string;status:string}|null};
 it('requires pairing, validates requests and restricts completion to the paired Listener',async()=>{
  const parent=device('parent');await register(parent);
  expect((await call('monitoring',parent,{id:crypto.randomUUID(),enabled:true})).status).toBe(409);
  const pair=await paired();
  expect((await call('monitoring',pair.parent,{id:crypto.randomUUID(),enabled:'yes'})).status).toBe(400);
  const request=await command(pair.parent,true);
  expect((await call('monitoring/complete',pair.parent,{id:request.id,succeeded:true})).status).toBe(403);
  const stranger=await paired();
  await call('monitoring/complete',stranger.listener,{id:request.id,succeeded:true});
  expect((await status(pair.parent)).monitoringCommand?.status).toBe('pending');
 });
 it('keeps requests pending until Listener confirmation and leaves observed monitoring truthful',async()=>{
  const {parent,listener}=await paired();const request=await command(parent,true);
  const pending=await status(parent);expect(pending.monitoring).toBe(false);expect(pending.monitoringCommand?.status).toBe('pending');
  expect((await status(listener)).monitoringCommand?.id).toBe(request.id);
  await call('monitoring/complete',listener,{id:request.id,succeeded:true});
  expect((await status(parent)).monitoringCommand?.status).toBe('applied');
  expect((await status(parent)).monitoring).toBe(false); // A separate heartbeat proves microphone activity.
 });
 it('expires unprocessed commands and records explicit startup failures',async()=>{
  const {parent,listener}=await paired();const failed=await command(parent,true);
  await call('monitoring/complete',listener,{id:failed.id,succeeded:false});
  expect((await status(parent)).monitoringCommand?.status).toBe('failed');
  const expired=await command(parent,true);
  await env.DB.prepare('UPDATE monitoring_commands SET expires_at=? WHERE id=?').bind(Date.now()-1,expired.id).run();
  await call('monitoring/complete',listener,{id:expired.id,succeeded:true});
  expect((await status(parent)).monitoringCommand?.status).toBe('expired');
 });
 it('lets local controls supersede remote requests and makes retries idempotent',async()=>{
  const {parent,listener}=await paired();const start=await command(parent,true);
  const stop=await command(listener,false);expect(stop.status).toBe('applied');
  await command(parent,true,start.id); // Lost response retry must not reorder the command log.
  await call('monitoring/complete',listener,{id:start.id,succeeded:true});
  expect((await status(parent)).monitoringCommand?.id).toBe(stop.id);
  expect((await status(parent)).monitoringCommand?.status).toBe('applied');
  expect((await call('monitoring',parent,{id:start.id,enabled:false})).status).toBe(409);
 });
 it('stops repeating alerts and suppresses delayed cry uploads, while allowing a new episode after restart',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const original=alert(listener);mockPush();await call('listener/event',listener,original);
  const late=alert(listener);await command(parent,false);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  expect((await (await call('listener/event',listener,late)).json() as {status:string}).status).toBe('acknowledged');
  expect(pushRequests).toHaveLength(1);
  await command(listener,true);
  const next=alert(listener);next.createdAt=new Date(Date.now()+10).toISOString();mockPush();
  expect((await (await call('listener/event',listener,next)).json() as {status:string}).status).toBe('sent');
  expect(pushRequests).toHaveLength(2);
 });
 it('removes monitoring commands on unpair and deletion',async()=>{
  const {parent,listener}=await paired();await command(parent,true);
  expect((await call('pairing/remove',listener)).status).toBe(200);
  expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM monitoring_commands').first<{n:number}>())?.n).toBe(0);
  const again=await paired();await command(again.parent,false);
  expect((await call('device/delete',again.parent)).status).toBe(200);
 });
});


describe('settled episode resolution and notification cleanup',()=>{
 async function setup(){
  const pair=await paired();
  await env.DB.prepare('UPDATE pairs SET created_at=? WHERE parent_id=?').bind(Date.now()-3600000,pair.parent.deviceId).run();
  return pair;
 }
 function beat(listener:TestDevice,event:Alert,quietConfirmed?:boolean){
  return {listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',
   episodes:[{id:event.episodeId,startedAt:event.cryStartedAt,endedAt:new Date().toISOString(),...(quietConfirmed===undefined?{}:{quietConfirmed})}]};
 }
 it('resolves confirmed quiet without acknowledging or snoozing, stops repeats and rejects late uploads',async()=>{
  const {parent,listener}=await setup(), event=alert(listener);
  await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();
  expect((await call('listener/event',listener,event)).status).toBe(200);
  expect((await call('listener/heartbeat',listener,beat(listener,event,true))).status).toBe(200);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as any;
  expect(status.alerts[0].resolvedAt).toBeTypeOf('string');expect(status.alerts[0].acknowledgedAt).toBeNull();
  expect(status.alertsMutedUntil).toBeNull();expect(status.notificationRelevance.cryEpisodeIDs).toEqual([]);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'resolved'});
  expect(await (await call('listener/event',listener,{...event,eventId:crypto.randomUUID(),isRepeat:true})).json()).toEqual({status:'resolved'});
  expect(pushRequests).toHaveLength(1);
  expect((await env.DB.prepare("SELECT * FROM timeline_events WHERE kind='alert_acknowledged'").all()).results).toHaveLength(0);
 });
 it.each([undefined,false])('keeps reminders for interrupted or legacy ended episodes (%s)',async(quietConfirmed)=>{
  const {parent,listener}=await setup(),event=alert(listener);
  await call('listener/event',listener,event);
  await call('listener/heartbeat',listener,beat(listener,event,quietConfirmed));
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as any;
  expect(status.alerts[0].resolvedAt).toBeNull();
  expect(status.notificationRelevance.cryEpisodeIDs).toEqual([event.episodeId]);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(true);
 });
 it('retains a newer crying episode and tests while resolving an older one, then snoozes all real alerts',async()=>{
  const {parent,listener}=await setup(),old=alert(listener),current=alert(listener),test={...alert(listener),isTest:true};
  for(const event of [old,current,test])await call('listener/event',listener,event);
  await call('listener/heartbeat',listener,{...beat(listener,old,true),state:'crying',currentEpisode:{id:current.episodeId,startedAt:current.cryStartedAt}});
  let status=await (await call('listener/status',parent,undefined,'GET')).json() as any;
  expect(status.notificationRelevance).toEqual({cryEpisodeIDs:[current.episodeId],testEventIDs:[test.eventId]});
  await call('alert/acknowledge',parent,{eventId:current.eventId});
  status=await (await call('listener/status',parent,undefined,'GET')).json() as any;
  expect(status.notificationRelevance).toEqual({cryEpisodeIDs:[],testEventIDs:[test.eventId]});
  await call('alert/acknowledge',parent,{eventId:test.eventId});
  status=await (await call('listener/status',parent,undefined,'GET')).json() as any;
  expect(status.notificationRelevance).toEqual({cryEpisodeIDs:[],testEventIDs:[]});
 });
 it('keeps relevance complete beyond the latest 100 displayed reminders and clears pairing tombstones',async()=>{
  const {parent,listener}=await setup(),old=alert(listener),current=alert(listener);
  await call('listener/event',listener,old);
  // Simulate the server reminder stream without issuing API requests/rate limits.
  await env.DB.batch(Array.from({length:105},(_,i)=>{
   const event={...current,eventId:crypto.randomUUID(),isRepeat:true};
   return env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at) VALUES(?,?,?,?,?,?,?)')
    .bind(event.eventId,event.episodeId,listener.deviceId,parent.deviceId,1,JSON.stringify(event),Date.now()+i);
  }));
  let status=await (await call('listener/status',parent,undefined,'GET')).json() as any;
  expect(status.alerts).toHaveLength(100);expect(status.notificationRelevance.cryEpisodeIDs.sort()).toEqual([old.episodeId,current.episodeId].sort());
  await call('listener/heartbeat',listener,beat(listener,old,true));
  expect((await env.DB.prepare('SELECT * FROM resolved_episodes').all()).results).toHaveLength(1);
  await call('pairing/remove',parent);
  expect((await env.DB.prepare('SELECT * FROM resolved_episodes').all()).results).toHaveLength(0);
  status=await (await call('listener/status',parent,undefined,'GET')).json() as any;
  expect(status.notificationRelevance).toEqual({cryEpisodeIDs:[],testEventIDs:[]});
 });
 it('rejects quiet confirmation without an ended episode or a boolean value',async()=>{
  const {listener}=await setup(),event=alert(listener),value=beat(listener,event,true);
  expect((await call('listener/heartbeat',listener,{...value,episodes:[{...value.episodes[0],endedAt:null}]})).status).toBe(400);
  expect((await call('listener/heartbeat',listener,{...value,episodes:[{...value.episodes[0],quietConfirmed:'yes'}]})).status).toBe(400);
 });
});

describe('latency path and diagnostic spans',()=>{
 it('returns the first push while reminder scheduling is still blocked',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  let release!:()=>void;const gate=new Promise<void>(resolve=>{release=resolve;});const jobs:Promise<unknown>[]=[];
  const slow={...testEnv,ALERT_REMINDERS:{getByName:()=>({fetch:async(input:string,init:RequestInit)=>{if(new URL(input).pathname==='/accepted')return testEnv.ALERT_REMINDERS.getByName(parent.deviceId).fetch(input,init);await gate;return new Response(null,{status:204});}})}} as unknown as Env;
  mockPush();
  try {
   const response=await worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(alert(listener))}),slow,{waitUntil:(job:Promise<unknown>)=>jobs.push(job)} as unknown as ExecutionContext);
   expect(await response.json()).toEqual({status:'sent'});expect(pushRequests).toHaveLength(1);expect(jobs).toHaveLength(2);
  }finally{release();await Promise.all(jobs);}
 });
 it('repairs failed background scheduling from durable events during maintenance',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const broken={...testEnv,ALERT_REMINDERS:{getByName:()=>({fetch:async()=>{throw new Error('private-scheduler-marker');}})}} as unknown as Env;
  mockPush();const response=await worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(alert(listener))}),broken);
  expect(await response.json()).toEqual({status:'sent'});
  const row=await env.DB.prepare("SELECT * FROM diagnostics WHERE operation='reminder_schedule'").first();
  expect(row).toMatchObject({outcome:'internal_error'});expect(JSON.stringify(row)).not.toContain('private-scheduler-marker');
  const stub=testEnv.ALERT_REMINDERS.getByName(parent.deviceId);
  expect(await runInDurableObject(stub,async(_i,state)=>state.storage.getAlarm())).toBeNull();
  await flushPending(testEnv);
  expect(await runInDurableObject(stub,async(_i,state)=>state.storage.getAlarm())).toBeGreaterThan(Date.now());expect(pushRequests).toHaveLength(1);
 });
 it.each(['TooManyRequests','TooManyProviderTokenUpdates'])('preserves Apple 429 subtype %s with spans on one dispatch row',async(reason)=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const appleID=crypto.randomUUID();pushResponses.push(new Response(JSON.stringify({reason,private:'private-body-marker'}),{status:429,headers:{'apns-unique-id':appleID,'private-header':'private-header-marker'}}));
  expect(await (await call('listener/event',listener,alert(listener))).json()).toEqual({status:'pending'});
  const rows=(await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch'").all<{details:string}>()).results;
  expect(rows).toHaveLength(1);const details=JSON.parse(rows[0].details);
  expect(details).toMatchObject({apns_reason:reason,apns_environment:'development',apns_unique_id:appleID,db_calls:5,provider_token_cached:expect.any(Boolean)});
  for(const span of ['claim_ms','token_decrypt_ms','provider_sign_ms','apns_fetch_ms','apns_body_ms','outcome_storage_ms'])expect(details.spans[span]).toBeGreaterThanOrEqual(0);
  expect(details.apns_response_at_ms).toBeGreaterThanOrEqual(details.apns_started_at_ms);
  expect(JSON.stringify(details)).not.toContain('private-body-marker');expect(JSON.stringify(details)).not.toContain('private-header-marker');
 });
 it('bounds hostile Apple bodies and identifiers without changing retry behavior',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  pushResponses.push(new Response(JSON.stringify({reason:'private-marker',extra:'x'.repeat(5000)}),{status:429,headers:{'apns-unique-id':'private-header-marker'}}));
  expect(await (await call('listener/event',listener,alert(listener))).json()).toEqual({status:'pending'});
  const row=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch'").first<{details:string}>();
  expect(JSON.parse(row!.details).apns_reason).toBe('unreadable');expect(row!.details).not.toContain('private-');
 });
 it('records transport uncertainty without exposing exception messages',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});pushResponses.push(new Error('private-transport-marker'));
  expect(await (await call('listener/event',listener,alert(listener))).json()).toEqual({status:'uncertain'});
  const row=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch'").first<{details:string}>();
  expect(JSON.parse(row!.details).transport).toBe('network');expect(row!.details).not.toContain('private-transport-marker');
 });
 it('rejects unknown detail keys, strings and invalid durations at the journal boundary',async()=>{
  await recordDiagnostic(testEnv,{requestId:crypto.randomUUID(),started:Date.now(),operation:'dispatch',stage:'push',outcome:'sent',details:{spans:{apns_fetch_ms:12,claim_ms:NaN,private:'private-marker'},apns_reason:'private-marker',apns_unique_id:'private-marker',apns_request_id:'private-marker',apns_id_mode:'private-marker',apns_collapse_mode:'private-marker',apns_collapse_basis:'private-marker',private:'private-marker',db_calls:-1} as unknown as import('../src/latency').TimingDetails});
  const row=await env.DB.prepare('SELECT details FROM diagnostics').first<{details:string}>();expect(JSON.parse(row!.details)).toEqual({spans:{apns_fetch_ms:12}});
 });
 it('allows scheduling during reminder I/O and preserves the fresh wakeup',async()=>{
  const {parent}=await paired();const {AlertReminders}=await import('../src/reminders');
  const values=new Map<string,unknown>([['parentId',parent.deviceId],['interval',5000]]);let alarm:number|null=Date.now()+5000;let chain=Promise.resolve();
  const ctx={waitUntil:(_work:Promise<unknown>)=>{},storage:{list:async()=>new Map(),get:async(key:string|string[])=>Array.isArray(key)?new Map(key.map(k=>[k,values.get(k)])):values.get(key),put:async(key:string|Record<string,unknown>,value?:unknown)=>{if(typeof key==='string')values.set(key,value);else for(const [k,v] of Object.entries(key))values.set(k,v);},getAlarm:async()=>alarm,setAlarm:async(n:number)=>{alarm=n;},deleteAlarm:async()=>{alarm=null;},delete:async(key:string|string[])=>{for(const k of Array.isArray(key)?key:[key])values.delete(k);}},blockConcurrencyWhile:<T>(work:()=>Promise<T>)=>{const result=chain.then(work);chain=result.then(()=>{},()=>{});return result;}} as unknown as DurableObjectState;
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{if(sql.startsWith('SELECT p.listener_id')&&method==='batch'){entered();await gate;}return execute();});
  const instance=new AlertReminders(ctx,{...testEnv,DB:db}),running=instance.alarm();await ready;
  try {expect((await instance.fetch(new Request('https://reminders.internal/schedule',{method:'POST',body:parent.deviceId}))).status).toBe(204);}finally{release();await running;}
  expect(alarm).not.toBeNull();expect(values.get('parentId')).toBe(parent.deviceId);
  await instance.alarm();expect(alarm).toBeNull();expect(values.has('parentId')).toBe(false);
 });
});


describe('phone-controlled Watch push test',()=>{
 it('retains Apple response subtypes for phone-controlled Watch test pushes',async()=>{
  const {parent}=await paired();await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  pushResponses.push({body:JSON.stringify({reason:'TooManyProviderTokenUpdates'}),status:429});
  const response=await call('watch-test/push',parent);expect(response.status).toBe(503);
  const row=await env.DB.prepare("SELECT outcome,details,request_id FROM diagnostics WHERE operation='watch_test_dispatch'").first<{outcome:string;details:string;request_id:string}>();
  expect(row?.outcome).toBe('apns_429');expect(JSON.parse(row!.details).apns_reason).toBe('TooManyProviderTokenUpdates');
  expect(row?.request_id).toBe(response.headers.get('x-request-id'));
 });

 it('disables the retired server timer and keeps Stop idempotent',async()=>{
  const {parent,listener}=await paired();
  expect((await call('watch-test',listener,{running:true,interval:5})).status).toBe(403);
  expect((await call('watch-test',parent,{running:true,interval:5})).status).toBe(410);
  expect(await (await call('watch-test',parent,undefined,'GET')).json()).toEqual({running:false,interval:5});
  expect(await (await call('watch-test',parent,{running:false})).json()).toEqual({running:false,interval:5});
 });
 it('requires a Parent, current pairing and registered Watch for each push',async()=>{
  const {parent,listener}=await paired();
  expect((await call('watch-test/push',listener)).status).toBe(403);
  expect((await call('watch-test/push',parent)).status).toBe(409);
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  mockPush();expect((await call('watch-test/push',parent)).status).toBe(200);
  await call('device/watch-push-token',parent,{token:null});
  expect((await call('watch-test/push',parent)).status).toBe(409);
  await call('pairing/remove',parent);
  expect((await call('watch-test/push',parent)).status).toBe(409);
  expect(pushRequests).toHaveLength(1);
 });
 it('sends exactly one short-lived Watch push per phone request and saves no retry work',async()=>{
  const {parent}=await paired();await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  for(let i=0;i<7;i++) { mockPush();expect((await call('watch-test/push',parent)).status).toBe(200); }
  expect(pushRequests).toHaveLength(7);
  const contents=pushRequests.map(request=>JSON.parse(String(request.init?.body)));
  expect(contents.every(content=>content.isTest===true)).toBe(true);
  expect(new Set(contents.map(content=>content.eventId)).size).toBe(7);
  const headers=pushRequests[0].init?.headers as Record<string,string>;
  expect(headers['apns-topic']).toMatch(/watchkitapp$/);
  expect(Number(headers['apns-expiration'])).toBeLessThanOrEqual(Math.floor(Date.now()/1000)+15);
  expect((await env.DB.prepare('SELECT * FROM events').all()).results).toHaveLength(0);
  await worker.scheduled({} as ScheduledController,testEnv);expect(pushRequests).toHaveLength(7);
 });
 it('does not retry a rejected or uncertain push after the iPhone stops requesting',async()=>{
  const {parent}=await paired();await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  mockPush(503);expect((await call('watch-test/push',parent)).status).toBe(503);
  pushResponses.push(new Error('Transport interrupted'));
  expect((await call('watch-test/push',parent)).status).toBe(503);
  await flushPending(testEnv);await worker.scheduled({} as ScheduledController,testEnv);
  expect(pushRequests).toHaveLength(2);
  expect((await env.DB.prepare('SELECT * FROM events').all()).results).toHaveLength(0);
 });
});

function interceptDB(work:(sql:string,args:unknown[],method:string,execute:()=>Promise<any>)=>Promise<any>):D1Database {
 const metadata=new WeakMap<object,{sql:string;args:unknown[]}>();
 return new Proxy(testEnv.DB,{get(db,key){
  if(key==='batch')return (statements:D1PreparedStatement[])=>{const first=metadata.get(statements[0]);return work(first?.sql??'',first?.args??[],'batch',()=>db.batch(statements));};
  if(key==='prepare')return (sql:string)=>{
   const wrap=(statement:D1PreparedStatement,args:unknown[]):D1PreparedStatement=>{const wrapped=new Proxy(statement,{get(target,name){
    if(name==='bind')return (...values:unknown[])=>wrap(target.bind(...values),values);
    const value=Reflect.get(target,name);
    if(typeof value==='function'&&['all','first','run','raw'].includes(String(name)))return (...values:unknown[])=>work(sql,args,String(name),()=>value.apply(target,values));
    return typeof value==='function'?value.bind(target):value;
   }});metadata.set(wrapped,{sql,args});return wrapped;};return wrap(db.prepare(sql),[]);
  };const value=Reflect.get(db,key);return typeof value==='function'?value.bind(db):value;
 }});
}

describe('diagnostic gap regressions',()=>{
 it('carries exact diagnostic references and attempt numbers through rejected and retried pushes',async()=>{
  const {parent,listener}=await paired();await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const event=alert(listener);mockPush(503);await call('listener/event',listener,event);
  await env.DB.prepare('UPDATE events SET next_attempt=0').run();mockPush();await flushPending(testEnv);
  const ref=await eventReference(testEnv,event.eventId);
  expect(pushRequests.map(r=>JSON.parse(String(r.init?.body))).map(p=>({ref:p.diagnosticRef,attempt:p.deliveryAttempt})))
   .toEqual([{ref,attempt:1},{ref,attempt:2}]);
  const rows=await env.DB.prepare("SELECT event_ref,attempt FROM diagnostics WHERE operation='dispatch' ORDER BY sequence").all();
  expect(rows.results).toEqual([{event_ref:ref,attempt:1},{event_ref:ref,attempt:2}]);
 });
 it('returns bounded server clock timestamps on the existing response',async()=>{
  const {parent}=await paired(),before=Date.now();const response=await call('listener/status',parent,undefined,'GET');
  const received=Number(response.headers.get('x-server-received-at-ms')),sent=Number(response.headers.get('x-server-sent-at-ms'));
  expect(received).toBeGreaterThanOrEqual(before);expect(sent).toBeGreaterThanOrEqual(received);expect(sent).toBeLessThanOrEqual(Date.now());
 });
 it('reports observed journal write failures on the next successful record',async()=>{
  const broken=interceptDB(async(sql,_args,_method,execute)=>{if(sql.startsWith('INSERT INTO diagnostics'))throw new Error('private-journal-error');return execute();});
  expect(await recordDiagnostic({...testEnv,DB:broken},{requestId:crypto.randomUUID(),started:Date.now(),operation:'maintenance',stage:'handler',outcome:'ok'})).toBe(false);
  const id=crypto.randomUUID();expect(await recordDiagnostic(testEnv,{requestId:id,started:Date.now(),operation:'maintenance',stage:'handler',outcome:'ok'})).toBe(true);
  const row=await env.DB.prepare('SELECT details FROM diagnostics WHERE request_id=?').bind(id).first<{details:string}>();
  expect(JSON.parse(row!.details).journal_failures_before_write).toBeGreaterThanOrEqual(1);expect(row!.details).not.toContain('private-journal-error');
  const next=crypto.randomUUID();await recordDiagnostic(testEnv,{requestId:next,started:Date.now(),operation:'maintenance',stage:'handler',outcome:'ok'});
  expect((await env.DB.prepare('SELECT details FROM diagnostics WHERE request_id=?').bind(next).first<{details:string|null}>())?.details).toBeNull();
 });
 it('uses two binding calls before reminder delivery and includes the current Watch token in the claim',async()=>{
  const {parent,listener}=await paired();await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);let replaced=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{
   if(method==='batch'&&sql.startsWith('INSERT INTO events(')){
    replaced=true;await env.DB.prepare('UPDATE devices SET watch_push_token=? WHERE id=?').bind(await encryptToken(testEnv,'ef'.repeat(32)),parent.deviceId).run();
   }
   return execute();
  });
  const {Latency}=await import('../src/latency');const latency=new Latency();mockPush();await runReminder({...testEnv,DB:db},parent.deviceId,latency);
  expect(replaced).toBe(true);expect(pushRequests).toHaveLength(2);expect(pushRequests[1].url).toContain('ef'.repeat(32));
  expect(latency.details.db_calls).toBe(3); // snapshot + atomic insert/claim/token before Apple; outcome after Apple
  expect(Object.keys(latency.details.db_stages!)).toEqual(['reminder_snapshot_ms','claim_ms','outcome_storage_ms']);
  expect(latency.details.db_stages?.reminder_snapshot_ms).toMatchObject({calls:1,completed:1});expect(latency.details.spans?.destination_ms).toBeUndefined();
 });
 it('uses one fallback after a stalled snapshot and observes a newer Stop without sending',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);
  let release!:()=>void,entered!:()=>void,reads=0;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{
   if(method==='batch'&&sql.startsWith('SELECT p.listener_id')){const index=++reads,result=await execute();if(index===1){entered();await gate;}return result;}return execute();
  });
  const {Latency}=await import('../src/latency');const latency=new Latency(),running=runReminder({...testEnv,DB:db},parent.deviceId,latency);await ready;
  try {
   expect((await call('monitoring',parent,{id:crypto.randomUUID(),enabled:false})).status).toBe(200);
   expect(await running).toBe(false);expect(reads).toBe(2);expect(pushRequests).toHaveLength(1);
   expect(latency.details).toMatchObject({exit_reason:'monitoring_stopped',db_stages:{reminder_snapshot_ms:{calls:2,completed:1,hedges:1,hedge_wins:1,unfinished:1,hedge_after_ms:250,hedge_timer_lag_ms:expect.any(Number)}}});
  }finally{release();await running;}
  expect((await env.DB.prepare('SELECT event_id FROM events').all()).results).toHaveLength(1);
 });
 it('keeps the atomic Stop guard when the original snapshot returns stale state',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);let stopped=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();if(method==='batch'&&sql.startsWith('SELECT p.listener_id')){stopped=true;await call('monitoring',parent,{id:crypto.randomUUID(),enabled:false});}return result;
  });
  await runReminder({...testEnv,DB:db},parent.deviceId);expect(stopped).toBe(true);expect(pushRequests).toHaveLength(1);
  expect((await env.DB.prepare('SELECT event_id FROM events').all()).results).toHaveLength(1);
 });
 it('recovers a committed claim reply by ownership without repeating the write or push',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);
  let release!:()=>void,entered!:()=>void,claims=0;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql.startsWith('INSERT INTO events(')){claims++;entered();await gate;}return result;});
  const {Latency}=await import('../src/latency');const latency=new Latency();mockPush();
  const running=runReminder({...testEnv,DB:db},parent.deviceId,latency);await ready;
  try {
   expect(await Promise.race([running,new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Committed claim still waited on its original reply')),1000))])).toBe(true);
   expect(claims).toBe(1);expect(pushRequests).toHaveLength(2);
   expect(latency.details).toMatchObject({claim_result_source:'receipt',claim_receipt_outcome:'matched',db_stages:{claim_ms:{calls:1,unfinished:1},claim_receipt_ms:{calls:1,completed:1}}});
   const frozen=JSON.stringify(latency.details);release();await new Promise(r=>setTimeout(r,10));expect(JSON.stringify(latency.details)).toBe(frozen);
  }finally{release();await running;}
  expect(pushRequests).toHaveLength(2);
 });
 it('claims an inserted reminder atomically before maintenance can observe it',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));
  const clock=Date.now();vi.spyOn(Date,'now').mockReturnValue(clock+10000);vi.spyOn(performance,'now').mockImplementation(()=>Date.now());
  let release!:()=>void,inserted!:()=>void,eventID='';const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{inserted=r;});
  const db=interceptDB(async(sql,args,method,execute)=>{const result=await execute();if(sql.startsWith('INSERT INTO events(')&&method==='batch'){eventID=String(args[0]);inserted();await gate;}return result;});
  const alarm=runReminder({...testEnv,DB:db},parent.deviceId);await ready;
  try {vi.spyOn(Date,'now').mockReturnValue(clock+13073);await flushPending(testEnv);expect(pushRequests).toHaveLength(1);}finally{mockPush();release();await alarm;}
  expect(pushRequests).toHaveLength(2);const ref=await eventReference(testEnv,eventID);
  expect((await env.DB.prepare("SELECT * FROM diagnostics WHERE operation='dispatch_skip' AND event_ref=?").bind(ref).all()).results).toHaveLength(0);
  const sent=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch' AND event_ref=?").bind(ref).first<{details:string}>();const details=JSON.parse(sent!.details);
  expect(details.dispatch_source).toBe('reminder');expect(details.spans.claim_ms).toBe(3073);expect(details.db_stages.claim_ms.statements).toBe(6);
 });
 it('retains the failing preparation query and sanitizes its exception',async()=>{
  const {parent}=await paired();const db=interceptDB(async(sql,_args,_method,execute)=>{if(sql.startsWith('SELECT p.listener_id'))throw new Error('D1_ERROR: timed out private-query-marker');return execute();});
  await expect(runReminder({...testEnv,DB:db},parent.deviceId)).rejects.toThrow();
  const row=await env.DB.prepare("SELECT outcome,details FROM diagnostics WHERE operation='reminder_prepare'").first<{outcome:string;details:string}>();
  expect(row?.outcome).toBe('internal_error');expect(JSON.parse(row!.details)).toMatchObject({failed_span:'reminder_snapshot_ms',error_kind:'d1_timeout'});expect(row!.details).not.toContain('private-query-marker');expect(pushRequests).toHaveLength(0);
 });
 it('logs durable-alarm storage failures before preparation starts',async()=>{
  const {parent}=await paired();const {AlertReminders}=await import('../src/reminders');
  const ctx={waitUntil:(_work:Promise<unknown>)=>{},blockConcurrencyWhile:<T>(work:()=>Promise<T>)=>work(),storage:{list:async()=>new Map(),get:async()=>new Map([['parentId',parent.deviceId]]),put:async()=>{throw new Error('private-alarm-storage-marker');}}} as unknown as DurableObjectState;
  await expect(new AlertReminders(ctx,testEnv).alarm()).rejects.toThrow('Reminder alarm failed.');
  const row=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='reminder_alarm'").first<{details:string}>();expect(JSON.parse(row!.details).failed_span).toBe('alarm_arm_ms');expect(row!.details).not.toContain('private-alarm-storage-marker');
 });
 it('records an insert overtaken by acknowledgement',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);
  const db=interceptDB(async(sql,_args,method,execute)=>{if(sql.startsWith('INSERT INTO events(')&&method==='batch')await env.DB.prepare('UPDATE events SET acknowledged_at=?').bind(new Date().toISOString()).run();return execute();});
  await runReminder({...testEnv,DB:db},parent.deviceId);
  const row=await env.DB.prepare("SELECT event_ref,details FROM diagnostics WHERE operation='dispatch_skip' AND outcome='claim_skipped'").first<{event_ref:string;details:string}>();expect(row?.event_ref).toMatch(/^[0-9a-f]{64}$/);expect(JSON.parse(row!.details).exit_reason).toBe('not_created');expect(pushRequests).toHaveLength(1);
 });
 it('keeps Apple acceptance when the outcome write fails and never resends',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();
  const db=interceptDB(async(sql,_args,method,execute)=>{if(sql.startsWith('UPDATE events SET status=?,next_attempt=')&&method==='run')throw new Error('D1_ERROR: private-outcome-write-marker');return execute();});
  const response=await worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(alert(listener))}),{...testEnv,DB:db});expect(response.status).toBe(503);
  const row=await env.DB.prepare("SELECT outcome,http_status,details FROM diagnostics WHERE operation='dispatch'").first<{outcome:string;http_status:number;details:string}>();expect(row).toMatchObject({outcome:'internal_error',http_status:200});expect(JSON.parse(row!.details)).toMatchObject({push_outcome:'sent',failed_span:'outcome_storage_ms'});expect(row!.details).not.toContain('private-outcome-write-marker');await flushPending(testEnv);expect(pushRequests).toHaveLength(1);
 });
 it('times failed initial preparation and the response journal write',async()=>{
  const {listener}=await paired();const db=interceptDB(async(sql,_args,_method,execute)=>{if(sql==='SELECT * FROM events WHERE event_id=?')throw new Error('D1_ERROR: private-lookup-marker');return execute();});
  const response=await worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(alert(listener))}),{...testEnv,DB:db});expect(response.status).toBe(503);expect(response.headers.get('x-diagnostics-elapsed-ms')).toMatch(/^\d+$/);
  const row=await env.DB.prepare('SELECT event_ref,details FROM diagnostics WHERE request_id=?').bind(response.headers.get('x-request-id')).first<{event_ref:string;details:string}>();expect(row?.event_ref).toMatch(/^[0-9a-f]{64}$/);expect(JSON.parse(row!.details).failed_span).toBe('alert_snapshot_ms');expect(JSON.parse(row!.details).spans.alert_prepare_ms).toBeGreaterThanOrEqual(0);
 });
 it('preserves successful DB results when optional metrics are absent',async()=>{
  const {Latency}=await import('../src/latency');const latency=new Latency();const result={success:true,results:[{ok:true}]} as unknown as D1Result<{ok:boolean}>;expect(await latency.db('event_lookup_ms',async()=>result)).toEqual([result]);expect(latency.details.db_sql_ms).toBeUndefined();
 });
});

function reminderContext(parentId:string) {
 const values=new Map<string,unknown>([['parentId',parentId],['interval',5000],['dueAt',Date.now()]]);
 const tasks:Promise<unknown>[]=[];let alarm:number|null=Date.now(),chain=Promise.resolve();
 const ctx={waitUntil:(task:Promise<unknown>)=>{tasks.push(task);},storage:{
  get:async(key:string|string[])=>Array.isArray(key)?new Map(key.map(k=>[k,structuredClone(values.get(k))])):structuredClone(values.get(key)),
  put:async(key:string|Record<string,unknown>,value?:unknown)=>{if(typeof key==='string')values.set(key,structuredClone(value));else for(const [k,v] of Object.entries(key))values.set(k,structuredClone(v));},
  list:async(options:{prefix?:string;limit?:number}={})=>new Map([...values].filter(([k])=>k.startsWith(options.prefix??'')).sort(([a],[b])=>a.localeCompare(b)).slice(0,options.limit??1000).map(([k,v])=>[k,structuredClone(v)])),
  delete:async(key:string|string[])=>{for(const k of Array.isArray(key)?key:[key])values.delete(k);},
  getAlarm:async()=>alarm,setAlarm:async(value:number)=>{alarm=value;},deleteAlarm:async()=>{alarm=null;}
 },blockConcurrencyWhile:<T>(work:()=>Promise<T>)=>{const result=chain.then(work);chain=result.then(()=>{},()=>{});return result;}} as unknown as DurableObjectState;
 (ctx.storage as unknown as {transaction:(work:(storage:DurableObjectStorage)=>Promise<unknown>)=>Promise<unknown>}).transaction=work=>work(ctx.storage);
 return {ctx,values,get alarm(){return alarm;},drain:async()=>{for(let i=0;i<tasks.length;i++)await tasks[i];}};
}

describe('durable accepted reminder outcomes',()=>{
 it('runs the next reminder while an accepted result write is stalled, without sending either event twice',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));
  let now=Date.now()+10000;vi.spyOn(Date,'now').mockImplementation(()=>now);
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{if(sql.startsWith("UPDATE events SET status='sent'")&&method==='run'){entered();await gate;}return execute();});
  const {AlertReminders}=await import('../src/reminders');const state=reminderContext(parent.deviceId),instance=new AlertReminders(state.ctx,{...testEnv,DB:db});
  mockPush();await instance.alarm();await ready;
  try {
   expect(pushRequests).toHaveLength(2);expect([...state.values.keys()].filter(k=>k.startsWith('accepted/'))).toHaveLength(1);
   expect((await env.DB.prepare("SELECT status FROM events ORDER BY created_at DESC LIMIT 1").first<{status:string}>())?.status).toBe('sending');
   now+=5000;mockPush();await instance.alarm();expect(pushRequests).toHaveLength(3);
   expect(new Set(pushRequests.map(r=>JSON.parse(String(r.init?.body)).eventId)).size).toBe(3);
   await env.DB.prepare('UPDATE events SET acknowledged_at=?').bind(new Date(now).toISOString()).run();
  }finally{release();await state.drain();}
  await instance.alarm();await state.drain();
  expect([...state.values.keys()].filter(k=>k.startsWith('accepted/'))).toHaveLength(0);
  expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE status='sent'").first<{n:number}>())?.n).toBe(3);expect(pushRequests).toHaveLength(3);
 });
 it('retains acceptance evidence when a stale snapshot outlives the background result write',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));
  let now=Date.now()+10000;vi.spyOn(Date,'now').mockImplementation(()=>now);
  let release!:()=>void,entered!:()=>void,finishAfterSnapshot=false;
  const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const state=reminderContext(parent.deviceId);
  const db=interceptDB(async(sql,_args,method,execute)=>{
   if(sql.startsWith("UPDATE events SET status='sent'")&&method==='run'){entered();await gate;}
   const result=await execute();
   if(finishAfterSnapshot&&sql.startsWith('SELECT p.listener_id')&&method==='batch'){
    finishAfterSnapshot=false;release();await state.drain();
    expect([...state.values.keys()].filter(k=>k.startsWith('accepted/'))).toHaveLength(0);
   }
   return result;
  });
  const {AlertReminders}=await import('../src/reminders');const instance=new AlertReminders(state.ctx,{...testEnv,DB:db});
  mockPush();await instance.alarm();await ready;
  try {now+=5000;finishAfterSnapshot=true;mockPush();await instance.alarm();expect(pushRequests).toHaveLength(3);}
  finally{release();await state.drain();}
  await env.DB.prepare('UPDATE events SET acknowledged_at=?').bind(new Date(now).toISOString()).run();await instance.alarm();await state.drain();
 });
 it('recovers a durable receipt after restart and a failed D1 write, while respecting Snooze',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();const original=alert(listener);await call('listener/event',listener,original);
  const now=Date.now()+10000;vi.spyOn(Date,'now').mockReturnValue(now);
  const broken=interceptDB(async(sql,_args,method,execute)=>{if(sql.startsWith("UPDATE events SET status='sent'")&&method==='run')throw new Error('D1_ERROR: private-persist-failure');return execute();});
  const {AlertReminders}=await import('../src/reminders');const state=reminderContext(parent.deviceId);
  mockPush();await new AlertReminders(state.ctx,{...testEnv,DB:broken}).alarm();await state.drain();
  const receipt=[...state.values.entries()].find(([k])=>k.startsWith('accepted/'))!;expect(receipt).toBeDefined();
  expect((await call('alert/acknowledge',parent,{eventId:original.eventId})).status).toBe(200);
  await env.DB.prepare("UPDATE events SET status='uncertain',last_error='dispatch_interrupted' WHERE event_id=?").bind(receipt[0].slice('accepted/'.length)).run();
  await new AlertReminders(state.ctx,testEnv).alarm();await state.drain();
  expect([...state.values.keys()].filter(k=>k.startsWith('accepted/'))).toHaveLength(0);expect(pushRequests).toHaveLength(2);
  const saved=await env.DB.prepare('SELECT status,acknowledged_at FROM events WHERE event_id=?').bind(receipt[0].slice('accepted/'.length)).first<{status:string;acknowledged_at:string}>();expect(saved?.status).toBe('sent');expect(saved?.acknowledged_at).not.toBeNull();
  const recovery=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch_outcome' AND outcome='sent'").first<{details:string}>();expect(JSON.parse(recovery!.details)).toMatchObject({durable_outcome:true,outcome_recovery:true});
  expect((await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch' AND outcome='internal_error'").first<{details:string}>())?.details).not.toContain('private-persist-failure');
 });
 it('checkpoints an initial accepted upload through the reminder object before its result write completes',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});const event=alert(listener);
  const {AlertReminders}=await import('../src/reminders');const state=reminderContext(parent.deviceId);
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{if(sql.startsWith("UPDATE events SET status='sent'")&&method==='run'){entered();await gate;}return execute();});
  const instance=new AlertReminders(state.ctx,{...testEnv,DB:db});
  const namespace={getByName:()=>({fetch:(input:string,init:RequestInit)=>instance.fetch(new Request(input,init))})} as unknown as DurableObjectNamespace;
  const tasks:Promise<unknown>[]=[],ctx={waitUntil:(task:Promise<unknown>)=>{tasks.push(task);}} as unknown as ExecutionContext;
  mockPush();const response=await worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(event)}),{...testEnv,ALERT_REMINDERS:namespace},ctx);
  try {
   await ready;expect(response.status).toBe(200);expect(await response.json()).toEqual({status:'sent'});
   expect(state.values.has('accepted/'+event.eventId)).toBe(true);expect(state.alarm).not.toBeNull();expect(pushRequests).toHaveLength(1);
  }finally{release();await state.drain();await Promise.all(tasks);}
  expect(state.values.has('accepted/'+event.eventId)).toBe(false);
 });
 it('does not let a late durable result overwrite a later attempt',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();const event=alert(listener);await call('listener/event',listener,event);
  const {acceptedDelivery,persistAcceptedDelivery}=await import('../src/accepted-delivery');await env.DB.prepare("UPDATE events SET status='sending',attempts=2,sent_at=NULL WHERE event_id=?").bind(event.eventId).run();
  await persistAcceptedDelivery(testEnv,acceptedDelivery(event.eventId,parent.deviceId,1,0,{requestId:crypto.randomUUID(),started:Date.now(),operation:'dispatch',stage:'storage',outcome:'sent'}),true);
  expect(await env.DB.prepare('SELECT status,attempts,sent_at FROM events WHERE event_id=?').bind(event.eventId).first()).toMatchObject({status:'sending',attempts:2,sent_at:null});expect(pushRequests).toHaveLength(1);
 });
 it('never replays a push when local receipt checkpointing fails after Apple acceptance',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);mockPush();
  await expect(runReminder(testEnv,parent.deviceId,undefined,undefined,{accepted:async()=>{throw new Error('private-checkpoint-failure');}})).rejects.toThrow();
  const row=await env.DB.prepare("SELECT http_status,details FROM diagnostics WHERE operation='dispatch' AND outcome='internal_error'").first<{http_status:number;details:string}>();
  expect(row?.http_status).toBe(200);expect(JSON.parse(row!.details)).toMatchObject({push_outcome:'sent',failed_span:'outcome_queue_ms'});expect(row!.details).not.toContain('private-checkpoint-failure');
  await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(2);
 });
 it('never creates an accepted receipt for an ambiguous APNs send',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});mockPush();await call('listener/event',listener,alert(listener));vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);
  const {AlertReminders}=await import('../src/reminders');const state=reminderContext(parent.deviceId);pushResponses.push(new Error('ambiguous'));await new AlertReminders(state.ctx,testEnv).alarm();await state.drain();
  expect([...state.values.keys()].filter(k=>k.startsWith('accepted/'))).toHaveLength(0);expect((await env.DB.prepare('SELECT status FROM events ORDER BY created_at DESC LIMIT 1').first<{status:string}>())?.status).toBe('uncertain');expect(pushRequests).toHaveLength(2);
 });
});

describe('initial upload admission and batching',()=>{
 it('uses four database calls before Apple and retains client attempt correlation',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  let calls=0,beforeApple=0;const external=globalThis.fetch,clientID=crypto.randomUUID();
  const db=interceptDB(async(_sql,_args,_method,execute)=>{calls++;return execute();});
  vi.stubGlobal('fetch',vi.fn(async(input:RequestInfo|URL,init?:RequestInit)=>{beforeApple=calls;return external(input,init);}));mockPush();
  const response=await worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`,'x-client-request-id':clientID},body:JSON.stringify(alert(listener))}),{...testEnv,DB:db});
  expect(await response.json()).toEqual({status:'sent'});expect(beforeApple).toBe(4);
  const row=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='alert' AND request_id=?").bind(response.headers.get('x-request-id')).first<{details:string}>(),details=JSON.parse(row!.details);
  expect(details.client_request_id).toBe(clientID);
  for(const stage of ['alert_admission_ms','alert_snapshot_ms','event_insert_ms'])expect(details.db_stages[stage]).toMatchObject({calls:1,statements:2});
 });
 it('does not let invalid or revoked credentials consume the real alert budget',async()=>{
  const {listener}=await paired(),value=alert(listener),key=await sha256(`${testEnv.PAIRING_PEPPER}|alert|${listener.deviceId}`);
  await env.DB.prepare('INSERT INTO rate_limits(key,window,attempts) VALUES(?,?,600)').bind(key,Math.floor(Date.now()/1000/600)).run();
  expect((await call('listener/event',{...listener,secret:btoa('xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')},value)).status).toBe(401);
  expect((await env.DB.prepare('SELECT attempts FROM rate_limits WHERE key=?').bind(key).first<{attempts:number}>())?.attempts).toBe(600);
  expect((await call('listener/event',listener,value)).status).toBe(429);
  expect((await call('device/delete',listener)).status).toBe(200);expect((await call('listener/event',listener,value)).status).toBe(401);
  expect(pushRequests).toHaveLength(0);expect((await env.DB.prepare('SELECT event_id FROM events').all()).results).toHaveLength(0);
 });
 it('refuses conflicting metadata after a concurrent upload wins the insert',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});const value=alert(listener);
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql==='SELECT * FROM events WHERE event_id=?'){entered();await gate;}return result;});
  const running=worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(value)}),{...testEnv,DB:db});await ready;
  try {mockPush();expect((await call('listener/event',listener,{...value,isTest:true})).status).toBe(200);}finally{release();}
  expect((await running).status).toBe(409);expect(pushRequests).toHaveLength(1);
 });
 it('uses one read fallback while preserving a newer Stop at the final claim',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});const value=alert(listener);
  let release!:()=>void,entered!:()=>void,reads=0;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql==='SELECT * FROM events WHERE event_id=?'&&++reads===1){entered();await gate;}return result;});
  const running=worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(value)}),{...testEnv,DB:db});await ready;
  try {
   expect((await call('monitoring',parent,{id:crypto.randomUUID(),enabled:false})).status).toBe(200);
   expect(await (await running).json()).toEqual({status:'acknowledged'});expect(reads).toBe(2);expect(pushRequests).toHaveLength(0);
  }finally{release();await running;}
 });
 it('never repeats a committed admission write while its reply is delayed',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  let release!:()=>void,entered!:()=>void,calls=0;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql==='SELECT * FROM devices WHERE id=?'){calls++;entered();await gate;}return result;});
  const running=worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(alert(listener))}),{...testEnv,DB:db});await ready;
  try{await new Promise(r=>setTimeout(r,1550));expect(calls).toBe(1);expect(pushRequests).toHaveLength(0);}finally{mockPush();release();await running;}
  expect(pushRequests).toHaveLength(1);
 });
});

describe('slow initial upload checkpoints',()=>{
 it('records one frozen in-flight stage before completion',async()=>{
  const {Latency}=await import('../src/latency'),{startAlertProgress}=await import('../src/alert-progress');
  const latency=new Latency(),clientID=crypto.randomUUID(),requestID=crypto.randomUUID();latency.details.client_request_id=clientID;
  let release!:()=>void;const gate=new Promise<void>(r=>{release=r;}),jobs:Promise<unknown>[]=[];
  const work=latency.db('alert_admission_ms',async()=>{await gate;return {success:true,results:[],meta:{duration:1}} as unknown as D1Result;});
  const stop=startAlertProgress(testEnv,{waitUntil:job=>jobs.push(job)},requestID,Date.now(),latency,()=> 'authentication',5);
  try {
   await Promise.all(jobs);await new Promise(r=>setTimeout(r,15));
   const rows=await env.DB.prepare('SELECT operation,outcome,details FROM diagnostics WHERE request_id=?').bind(requestID).all<{operation:string;outcome:string;details:string}>();
   expect(rows.results).toHaveLength(1);expect(rows.results[0]).toMatchObject({operation:'alert_progress',outcome:'still_running'});
   const details=JSON.parse(rows.results[0].details);expect(details).toMatchObject({client_request_id:clientID,in_flight_span:'alert_admission_ms',db_stages:{alert_admission_ms:{calls:1}}});expect(details.in_flight_ms).toBeGreaterThanOrEqual(0);expect(details.db_stages.alert_admission_ms.completed).toBeUndefined();
  }finally{stop();release();await work;}
 });
 it('cancels fast checkpoints and keeps a started journal alive until it finishes',async()=>{
  const {Latency}=await import('../src/latency'),{startAlertProgress}=await import('../src/alert-progress');const jobs:Promise<unknown>[]=[];
  const requestId=crypto.randomUUID();
  const stop=startAlertProgress(testEnv,{waitUntil:job=>jobs.push(job)},requestId,Date.now(),new Latency(),()=> 'handler',5);stop();await Promise.all(jobs);
  await new Promise(r=>setTimeout(r,15));expect((await env.DB.prepare('SELECT sequence FROM diagnostics WHERE request_id=?').bind(requestId).all()).results).toHaveLength(0);
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,_method,execute)=>{if(sql.startsWith('INSERT INTO diagnostics')){entered();await gate;}return execute();});let finished=false;
  const slow=startAlertProgress({...testEnv,DB:db},{waitUntil:job=>{jobs.push(job);void job.then(()=>{finished=true;});}},crypto.randomUUID(),Date.now(),new Latency(),()=> 'handler',5);await ready;
  try {slow();await new Promise(r=>setTimeout(r,5));expect(finished).toBe(false);}finally{release();await Promise.all(jobs);}
  expect(finished).toBe(true);
 });
 it('drops arbitrary correlation and stage strings at the privacy boundary',async()=>{
  const {safeTimingDetails}=await import('../src/latency');
  expect(safeTimingDetails({client_request_id:'private-marker',in_flight_span:'private-marker',in_flight_ms:-1} as unknown as import('../src/latency').TimingDetails)).toBeNull();
 });
});


describe('retired Listener-originated silent alarm experiment',()=>{
 it('is replaced by configured AlarmKit tests and sends nothing',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  expect((await call('listener/silent-alarm-test',listener)).status).toBe(410);
  expect(pushRequests).toHaveLength(0);
 });
});


describe('optional overnight silent Watch alarms',()=>{
 async function setup(){
  const pair=await paired();
  await call('device/push-token',pair.parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',pair.parent,{token:'cd'.repeat(32)});
  return pair;
 }
 function fanout(watchStatus=200,phoneStatus=200){
  vi.stubGlobal('fetch',vi.fn(async(input:string|URL|Request,init?:RequestInit)=>{
   pushRequests.push({url:String(input),init});
   const isWatch=(init?.headers as Record<string,string>)['apns-topic'].endsWith('.watchkitapp');
   const status=isWatch?watchStatus:phoneStatus;
   return new Response(status===200?'':JSON.stringify({reason:'ServiceUnavailable'}),{status});
  }));
 }
 async function receiptSetup(){
  const pair=await setup();
  expect((await call('device/push-token',pair.parent,{token:'ab'.repeat(32),alarmReceiptsVersion:1})).status).toBe(200);
  await call('silent-watch-alarms',pair.parent,{enabled:true});fanout();
  return pair;
 }
 const phoneBodies=()=>pushRequests.filter(r=>!new Headers(r.init?.headers).get('apns-topic')!.endsWith('.watchkitapp')).map(r=>JSON.parse(String(r.init?.body)));
 it('keeps ordinary reminders and recovers at 30s, 60s, then every two minutes until confirmed',async()=>{
  const {parent,listener}=await receiptSetup(),base=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(base);
  await call('listener/event',listener,alert(listener));
  const markedAt=[0];
  for(const seconds of [5,25,30,35,55,60,65,90,175,180,185,295,300]){
   clock.mockReturnValue(base+seconds*1000);const before=phoneBodies().length;
   await runReminder(testEnv,parent.deviceId);
   expect(phoneBodies()).toHaveLength(before+1);
   if(phoneBodies().at(-1).silentCryAlarm)markedAt.push(seconds);
  }
  expect(markedAt).toEqual([0,30,60,180,300]);expect(pushRequests).toHaveLength(28);
  for(const body of phoneBodies())expect(body.aps.sound).toBe('default');
  expect(new Set(phoneBodies().filter(b=>b.silentCryAlarm).map(b=>b.alarmCycleId)).size).toBe(1);
  expect((await env.DB.prepare('SELECT request_count,confirmed_at FROM silent_alarm_cycles WHERE parent_id=?').bind(parent.deviceId).first())).toEqual({request_count:5,confirmed_at:null});
  const last=phoneBodies().at(-1);
  expect((await call('alarm/scheduled',parent,{eventId:last.eventId,episodeId:last.episodeId,cycleId:last.alarmCycleId})).status).toBe(200);
  clock.mockReturnValue(base+420000);await runReminder(testEnv,parent.deviceId);
  expect(phoneBodies().at(-1).silentCryAlarm).toBeUndefined();
 });
 it('bounds receipt history during prolonged recovery and accepts recent delayed confirmations',async()=>{
  const {parent,listener}=await receiptSetup(),base=Date.now(),initial=alert(listener);
  let lastEvent='';
  for(let i=0;i<36;i++){
   const event={...initial,eventId:crypto.randomUUID()},claim=crypto.randomUUID(),at=base+i*120000;
   await env.DB.prepare("INSERT INTO events(event_id,episode_id,listener_id,parent_id,payload,created_at,status,claim_id,is_repeat) VALUES(?,?,?,?,?,?,'sending',?,1)")
    .bind(event.eventId,event.episodeId,listener.deviceId,parent.deviceId,JSON.stringify(event),at,claim).run();
   await reserveAlarmRequest(testEnv,event.eventId,claim,at).run();
   lastEvent=event.eventId;
  }
  const row=await env.DB.prepare('SELECT request_count,request_event_ids,cycle_id FROM silent_alarm_cycles WHERE parent_id=?').bind(parent.deviceId).first<{request_count:number;request_event_ids:string;cycle_id:string}>();
  expect(row!.request_count).toBe(36);expect(JSON.parse(row!.request_event_ids)).toHaveLength(32);
  expect(JSON.parse(row!.request_event_ids).at(-1)).toBe(lastEvent);
  expect((await call('alarm/scheduled',parent,{eventId:JSON.parse(row!.request_event_ids)[0],episodeId:initial.episodeId,cycleId:row!.cycle_id})).status).toBe(200);
 });
 it('stops wake requests after idempotent scheduling confirmation without stopping either notification destination',async()=>{
  const {parent,listener}=await receiptSetup(),base=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(base);
  const initial=alert(listener);await call('listener/event',listener,initial);const first=phoneBodies()[0];
  const receipt={eventId:initial.eventId,episodeId:initial.episodeId,cycleId:first.alarmCycleId};
  expect((await call('alarm/scheduled',listener,receipt)).status).toBe(403);
  expect((await call('alarm/scheduled',parent,{...receipt,cycleId:'invalid'})).status).toBe(400);
  expect((await call('alarm/scheduled',parent,receipt)).status).toBe(200);
  expect((await call('alarm/scheduled',parent,receipt)).status).toBe(200);
  clock.mockReturnValue(base+30000);await runReminder(testEnv,parent.deviceId);
  expect(pushRequests).toHaveLength(4);expect(phoneBodies()[1].silentCryAlarm).toBeUndefined();
  expect(phoneBodies()[1].aps['content-available']).toBeUndefined();expect(phoneBodies()[1].aps.sound).toBe('default');
 });
 it('does not compress late recovery attempts together and accepts confirmation of the earlier request',async()=>{
  const {parent,listener}=await receiptSetup(),base=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(base);
  const initial=alert(listener);await call('listener/event',listener,initial);const cycle=phoneBodies()[0].alarmCycleId;
  clock.mockReturnValue(base+45000);await runReminder(testEnv,parent.deviceId);expect(phoneBodies().at(-1).silentCryAlarm).toBe(true);
  clock.mockReturnValue(base+60000);await runReminder(testEnv,parent.deviceId);expect(phoneBodies().at(-1).silentCryAlarm).toBeUndefined();
  clock.mockReturnValue(base+75000);await runReminder(testEnv,parent.deviceId);expect(phoneBodies().at(-1).silentCryAlarm).toBe(true);
  expect((await call('alarm/scheduled',parent,{eventId:initial.eventId,episodeId:initial.episodeId,cycleId:cycle})).status).toBe(200);
 });
 it('starts a fresh cycle after a snooze deadline changes and rejects stale or foreign confirmations',async()=>{
  const {parent,listener}=await receiptSetup(),base=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(base);
  const initial=alert(listener);await call('listener/event',listener,initial);const old=phoneBodies()[0].alarmCycleId;
  const other=device('parent');await register(other);
  const receipt={eventId:initial.eventId,episodeId:initial.episodeId,cycleId:old};
  expect((await call('alarm/scheduled',other,receipt)).status).toBe(409);
  expect((await call('alarm/scheduled',parent,receipt)).status).toBe(200);
  expect((await call('alert/acknowledge',parent,{eventId:initial.eventId})).status).toBe(200);
  clock.mockReturnValue(base+61000);
  // A fresh Listener heartbeat confirms that crying persisted through Snooze.
  await env.DB.prepare('INSERT INTO heartbeats(listener_id,received_at,metadata) VALUES(?,?,?)')
   .bind(listener.deviceId,new Date(Date.now()).toISOString(),JSON.stringify({monitoring:true,state:'crying',currentEpisode:{id:initial.episodeId,startedAt:initial.cryStartedAt},episodes:[]})).run();
  await runReminder(testEnv,parent.deviceId);
  const fresh=phoneBodies().at(-1);expect(fresh.silentCryAlarm).toBe(true);expect(fresh.alarmCycleId).not.toBe(old);
  expect((await call('alarm/scheduled',parent,receipt)).status).toBe(409);
  expect((await call('alarm/scheduled',parent,{eventId:fresh.eventId,episodeId:fresh.episodeId,cycleId:fresh.alarmCycleId})).status).toBe(200);
  await call('alert/acknowledge',parent,{eventId:fresh.eventId});
  expect((await call('alarm/scheduled',parent,{eventId:fresh.eventId,episodeId:fresh.episodeId,cycleId:fresh.alarmCycleId})).status).toBe(409);
 });
 it('reserves only one recovery across concurrent event claims and resets on disable/re-enable',async()=>{
  const {parent,listener}=await receiptSetup(),base=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(base);
  const initial=alert(listener);await call('listener/event',listener,initial);
  clock.mockReturnValue(base+30000);
  const repeats=[0,1].map(()=>({...initial,eventId:crypto.randomUUID(),isRepeat:true,createdAt:new Date(Date.now()).toISOString()}));
  for(const e of repeats)await env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at) VALUES(?,?,?,?,?,?,?)')
   .bind(e.eventId,e.episodeId,listener.deviceId,parent.deviceId,1,JSON.stringify(e),Date.now()).run();
  await Promise.all(repeats.map(e=>dispatchEvent(testEnv,e.eventId)));
  expect(pushRequests).toHaveLength(6);expect(phoneBodies().filter(b=>b.silentCryAlarm)).toHaveLength(2);
  await call('silent-watch-alarms',parent,{enabled:false});await call('silent-watch-alarms',parent,{enabled:true});
  clock.mockReturnValue(base+35000);await runReminder(testEnv,parent.deviceId);
  expect(phoneBodies().at(-1).silentCryAlarm).toBe(true);
 });
 it('defaults off and only a paired Parent can enable it with a boolean',async()=>{
  const {parent,listener}=await setup();
  expect((await (await call('listener/status',parent,undefined,'GET')).json() as {silentWatchAlarmsEnabled:boolean}).silentWatchAlarmsEnabled).toBe(false);
  expect((await call('silent-watch-alarms',listener,{enabled:true})).status).toBe(403);
  expect((await call('silent-watch-alarms',parent,{enabled:'true'})).status).toBe(400);
  await env.DB.prepare('UPDATE devices SET push_token=NULL WHERE id=?').bind(parent.deviceId).run();
  expect((await call('silent-watch-alarms',parent,{enabled:true})).status).toBe(409);
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  expect((await call('silent-watch-alarms',parent,{enabled:true})).status).toBe(200);
  expect((await (await call('listener/status',parent,undefined,'GET')).json() as {silentWatchAlarmsEnabled:boolean}).silentWatchAlarmsEnabled).toBe(true);
  fanout();await call('listener/event',listener,alert(listener));
  expect(pushRequests).toHaveLength(2);
  const bodies=pushRequests.map(r=>JSON.parse(String(r.init?.body)));
  expect(bodies.find(b=>b.silentCryAlarm)?.aps['content-available']).toBe(1);
  expect(bodies.find(b=>b.silentCryAlarm)?.aps.sound).toBe('default');
  expect(bodies.find(b=>!b.silentCryAlarm)?.aps.sound).toBe('default');
  expect(bodies[0].eventId).toBe(bodies[1].eventId);
 });
 it('retains Watch acceptance while retrying a rejected phone delivery with the optional alarm enabled',async()=>{
  const {parent,listener}=await setup();await call('silent-watch-alarms',parent,{enabled:true});
  fanout(200,503);const event=alert(listener);
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'pending'});
  const row=await env.DB.prepare('SELECT delivery_state FROM events WHERE event_id=?').bind(event.eventId).first<{delivery_state:string}>();
  expect(JSON.parse(row!.delivery_state)).toEqual({phone:'pending',watch:'sent'});
  fanout();await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();await flushPending(testEnv);
  expect(pushRequests).toHaveLength(3);
  expect(pushRequests.filter(r=>new Headers(r.init?.headers).get('apns-topic')!.endsWith('.watchkitapp'))).toHaveLength(1);
 });
 it('submits and persists Watch acceptance while the phone send is stalled',async()=>{
  const {parent,listener}=await setup();await call('silent-watch-alarms',parent,{enabled:true});
  const event=alert(listener);
  await env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at) VALUES(?,?,?,?,?,?,?)')
   .bind(event.eventId,event.episodeId,listener.deviceId,parent.deviceId,0,JSON.stringify(event),Date.now()).run();
  let release!:()=>void,phoneEntered=false;
  const gate=new Promise<void>(r=>{release=r;});const jobs:Promise<unknown>[]=[];
  vi.stubGlobal('fetch',vi.fn(async(input:string|URL|Request,init?:RequestInit)=>{
   pushRequests.push({url:String(input),init});
   if(!(init?.headers as Record<string,string>)['apns-topic'].endsWith('.watchkitapp')){phoneEntered=true;await gate;}
   return new Response('',{status:200});
  }));
  const running=dispatchEvent(testEnv,event.eventId,undefined,undefined,{background:{waitUntil:job=>{jobs.push(job);}}});
  try{
   let state:Record<string,string>|undefined;
   for(let i=0;i<100;i++){
    const row=await env.DB.prepare('SELECT delivery_state FROM events WHERE event_id=?').bind(event.eventId).first<{delivery_state:string}>();
    state=row?.delivery_state?JSON.parse(row.delivery_state):undefined;
    if(state?.watch==='sent')break;
    await new Promise(r=>setTimeout(r,5));
   }
   expect(phoneEntered).toBe(true);expect(pushRequests).toHaveLength(2);expect(state?.watch).toBe('sent');
  }finally{release();await running;await Promise.all(jobs);}
 });
 it('offers the notification extension on every phone alert and gates the app wake independently',async()=>{
  const {parent,listener}=await receiptSetup(),base=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(base);
  expect((await call('silent-watch-alarms',parent,{enabled:true,appWake:false,extension:true})).status).toBe(200);
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alarmMethods:{appWake:boolean;extension:boolean}};
  expect(status.alarmMethods).toEqual({appWake:false,extension:true});
  await call('listener/event',listener,alert(listener));
  for(const seconds of [5,30,60]){clock.mockReturnValue(base+seconds*1000);await runReminder(testEnv,parent.deviceId);}
  expect(phoneBodies()).toHaveLength(4);
  for(const body of phoneBodies()){
   expect(body.alarmExtension).toBe(true);expect(body.aps['mutable-content']).toBe(1);
   expect(body.silentCryAlarm).toBeUndefined();expect(body.aps['content-available']).toBeUndefined();
   expect(body.aps.sound).toBe('default');
  }
  for(const request of pushRequests.filter(r=>new Headers(r.init?.headers).get('apns-topic')!.endsWith('.watchkitapp'))){
   const body=JSON.parse(String(request.init?.body));
   expect(body.alarmExtension).toBeUndefined();expect(body.aps['mutable-content']).toBeUndefined();
  }
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM silent_alarm_cycles').first<{n:number}>()).toEqual({n:0});
 });
 it('sends both markers when both methods are selected and keeps stored methods for older apps',async()=>{
  const {parent,listener}=await receiptSetup();
  expect((await call('silent-watch-alarms',parent,{enabled:true,appWake:true,extension:true})).status).toBe(200);
  expect((await call('silent-watch-alarms',parent,{enabled:true})).status).toBe(200);
  expect((await call('silent-watch-alarms',parent,{enabled:true,extension:'yes'})).status).toBe(400);
  await call('listener/event',listener,alert(listener));
  const [initial]=phoneBodies();
  expect(initial).toMatchObject({silentCryAlarm:true,alarmExtension:true,aps:{'content-available':1,'mutable-content':1,sound:'default'}});
 });
 it('defaults to the app wake only',async()=>{
  const {parent,listener}=await receiptSetup();
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alarmMethods:{appWake:boolean;extension:boolean}};
  expect(status.alarmMethods).toEqual({appWake:true,extension:false});
  await call('listener/event',listener,alert(listener));
  const [initial]=phoneBodies();
  expect(initial.silentCryAlarm).toBe(true);expect(initial.alarmExtension).toBeUndefined();expect(initial.aps['mutable-content']).toBeUndefined();
 });
 it('adds processing to the existing phone notification without duplicating it when Watch routing is absent',async()=>{
  const {parent,listener}=await setup();await call('device/watch-push-token',parent,{token:null});
  await call('silent-watch-alarms',parent,{enabled:true});fanout();
  await call('listener/event',listener,alert(listener));expect(pushRequests).toHaveLength(1);
  const body=JSON.parse(String(pushRequests[0].init?.body));
  expect(body.silentCryAlarm).toBe(true);expect(body.aps['content-available']).toBe(1);
  expect(body.aps.category).toBe('BABY_CRY_ALERT');expect(body.aps.sound).toBe('default');
 });
 it('preserves phone forwarding, AlarmKit processing and direct Watch delivery for initial alerts and reminders',async()=>{
  const {parent,listener}=await setup();await call('silent-watch-alarms',parent,{enabled:true});
  // Experimental routing must never suppress a real crying notification.
  const configured={...testEnv,WATCH_ONLY_PARENT_ID:parent.deviceId,PHONE_ONLY_TEST_PARENT_ID:parent.deviceId};
  fanout();const initial=alert(listener);
  await worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',
   headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(initial)}),configured);
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);
  await runReminder(configured,parent.deviceId);
  expect(pushRequests).toHaveLength(4);
  const pairs=new Map<string,typeof pushRequests>();
  for(const request of pushRequests){
   const body=JSON.parse(String(request.init?.body));
   pairs.set(body.eventId,[...(pairs.get(body.eventId)??[]),request]);
  }
  expect(pairs.size).toBe(2);
  for(const [id,requests] of pairs){
   expect(requests).toHaveLength(2);
   for(const request of requests){
    const headers=new Headers(request.init?.headers),body=JSON.parse(String(request.init?.body));
    const watch=headers.get('apns-topic')===testEnv.APNS_BUNDLE_ID+'.watchkitapp';
    expect(body).toMatchObject({eventId:id,episodeId:initial.episodeId,
     aps:{sound:'default',category:'BABY_CRY_ALERT','interruption-level':'time-sensitive'}});
    expect(body.silentCryAlarm).toBe(watch?undefined:true);
    expect(body.aps['content-available']).toBe(watch?undefined:1);
    expect(headers.get('apns-collapse-id')).toBe(`${watch?'watch':'phone'}:${id}`);
    expect(body.aps['thread-id']).toBeUndefined();
   }
  }
 });
 it('preserves normal phone alerting on the auxiliary AlarmKit path for a legacy Watch-target claim',async()=>{
  const {parent,listener}=await setup();await call('silent-watch-alarms',parent,{enabled:true});
  const event=alert(listener);
  await env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at,push_target) VALUES(?,?,?,?,?,?,?,?)')
   .bind(event.eventId,event.episodeId,listener.deviceId,parent.deviceId,0,JSON.stringify(event),Date.now(),'watch').run();
  fanout();await dispatchEvent(testEnv,event.eventId);
  expect(pushRequests).toHaveLength(2);
  const phone=pushRequests.find(r=>new Headers(r.init?.headers).get('apns-topic')===testEnv.APNS_BUNDLE_ID)!;
  expect(JSON.parse(String(phone.init?.body))).toMatchObject({eventId:event.eventId,silentCryAlarm:true,
   aps:{sound:'default','content-available':1,'interruption-level':'time-sensitive'}});
 });
 it('does not add alarms when disabled, for tests, or for acknowledged events',async()=>{
  const {parent,listener}=await setup();fanout();
  await call('listener/event',listener,alert(listener));expect(pushRequests).toHaveLength(2);
  await call('silent-watch-alarms',parent,{enabled:true});
  const test={...alert(listener),isTest:true};await call('listener/event',listener,test);
  expect(pushRequests).toHaveLength(4);
  expect(pushRequests.map(r=>JSON.parse(String(r.init?.body))).some(b=>b.silentCryAlarm)).toBe(false);
  const event=alert(listener);await call('listener/event',listener,event);expect(pushRequests).toHaveLength(6);
  await call('alert/acknowledge',parent,{eventId:event.eventId});
  await dispatchEvent(testEnv,event.eventId);expect(pushRequests).toHaveLength(6);
  await call('silent-watch-alarms',parent,{enabled:false});
  expect((await (await call('listener/status',parent,undefined,'GET')).json() as {silentWatchAlarmsEnabled:boolean}).silentWatchAlarmsEnabled).toBe(false);
 });
 it('retains silent alarm fan-out when recovering an owned claim with a delayed reply',async()=>{
  const {parent,listener}=await setup();await call('silent-watch-alarms',parent,{enabled:true});
  const event=alert(listener);
  await env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at) VALUES(?,?,?,?,?,?,?)')
   .bind(event.eventId,event.episodeId,listener.deviceId,parent.deviceId,0,JSON.stringify(event),Date.now()).run();
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql.startsWith('UPDATE events SET resolved_at=')){entered();await gate;}return result;});
  const {Latency}=await import('../src/latency');const latency=new Latency();fanout();
  const running=dispatchEvent({...testEnv,DB:db},event.eventId,undefined,latency);await ready;
  try {
   await Promise.race([running,new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Owned claim fan-out stalled')),1000))]);
   expect(latency.details.claim_result_source).toBe('receipt');expect(pushRequests).toHaveLength(2);
   expect(pushRequests.map(r=>JSON.parse(String(r.init?.body))).filter(b=>b.silentCryAlarm)).toHaveLength(1);
  }finally{release();await running;}
 });
 it('preserves the Watch notification when the Parent has no phone token',async()=>{
  const {parent,listener}=await setup();await call('silent-watch-alarms',parent,{enabled:true});
  await env.DB.prepare('UPDATE devices SET push_token=NULL WHERE id=?').bind(parent.deviceId).run();
  fanout();await call('listener/event',listener,alert(listener));expect(pushRequests).toHaveLength(1);
  expect(JSON.parse(String(pushRequests[0].init?.body)).silentCryAlarm).toBeUndefined();
 });
});

describe('status database pressure and journal isolation',()=>{
 it('reads the complete status in two handler binding calls and retains limiter metadata',async()=>{
  const {parent,listener}=await paired();
  await call('listener/heartbeat',listener,{listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[]});
  const response=await call('listener/status',parent,undefined,'GET'),value=await response.json() as {paired:boolean;monitoring:boolean};
  expect(value).toMatchObject({paired:true,monitoring:true});
  const row=await env.DB.prepare('SELECT details FROM diagnostics WHERE request_id=?').bind(response.headers.get('x-request-id')).first<{details:string}>();
  const timing=JSON.parse(row!.details);expect(timing.db_calls).toBe(5);
  expect(timing.db_stages.status_pair_ms).toMatchObject({calls:1,statements:1});expect(timing.db_stages.status_snapshot_ms).toMatchObject({calls:1,statements:5});
  for(const key of ['ip_rate_limit_ms','device_rate_limit_ms','authentication_lookup_ms'])expect(timing.db_stages[key]).toMatchObject({calls:1,completed:1,statements:1});
 });
 it('does not return a stale nursery snapshot after pairing changes during lookup',async()=>{
  const {parent}=await paired();let changed=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{if(method==='batch'&&sql==='SELECT * FROM heartbeats WHERE listener_id=?'){changed=true;await env.DB.prepare('DELETE FROM pairs WHERE parent_id=?').bind(parent.deviceId).run();}return execute();});
  const response=await worker.fetch(new Request('https://monitor.test/v1/listener/status',{headers:{authorization:`Bearer ${parent.deviceId}.${parent.secret}`}}),{...testEnv,DB:db});
  expect(changed).toBe(true);expect(await response.json()).toMatchObject({paired:false});
 });
 it('returns status even while its diagnostic write is stalled',async()=>{
  const {parent}=await paired();const prior=(await env.DB.prepare('SELECT sequence FROM diagnostics').all()).results.length;vi.spyOn(Date,'now').mockReturnValue(Date.now()+60000);
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;}),jobs:Promise<unknown>[]=[];
  const db=interceptDB(async(sql,_args,_method,execute)=>{if(sql.startsWith('INSERT INTO diagnostics')){entered();await gate;}return execute();});
  const running=worker.fetch(new Request('https://monitor.test/v1/listener/status',{headers:{authorization:`Bearer ${parent.deviceId}.${parent.secret}`}}),{...testEnv,DB:db},{waitUntil:(job:Promise<unknown>)=>{jobs.push(job);}} as unknown as ExecutionContext);
  await ready;
  try {
   const response=await Promise.race([running,new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Status waited on telemetry')),1000))]);
   expect(response.status).toBe(200);expect(response.headers.get('x-diagnostics-status')).toBe('queued');expect(response.headers.get('x-diagnostics-elapsed-ms')).toBe('0');
   expect((await env.DB.prepare('SELECT request_id FROM diagnostics').all()).results).toHaveLength(prior);
  }finally{release();await running;await Promise.all(jobs);}
 });
 it('releases unused Apple response bodies without delaying or changing known acceptance',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  let release!:()=>void;const gate=new Promise<void>(r=>{release=r;}),cancel=vi.fn(()=>gate);
  pushResponses.push(new Response(new ReadableStream({cancel}),{status:200}));
  try {
   const response=await Promise.race([call('listener/event',listener,alert(listener)),new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Acceptance waited on cleanup')),1000))]);
   expect(await response.json()).toEqual({status:'sent'});expect(cancel).toHaveBeenCalledOnce();
  }finally{release();}
 });
});

describe('owned claim receipt suppression',()=>{
 it('honors a Stop recorded while the committed claim reply is delayed',async()=>{
  const {parent,listener}=await paired();await call('listener/event',listener,alert(listener));await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=await env.DB.prepare('SELECT event_id FROM events').first<{event_id:string}>();
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql.startsWith('UPDATE events SET resolved_at=')){entered();await gate;}return result;});
  const {dispatchEvent}=await import('../src/alerts'),{Latency}=await import('../src/latency');const latency=new Latency();
  const running=dispatchEvent({...testEnv,DB:db},event!.event_id,undefined,latency);await ready;
  try {
   expect((await call('monitoring',parent,{id:crypto.randomUUID(),enabled:false})).status).toBe(200);
   await Promise.race([running,new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Stop receipt not observed')),1000))]);
   expect(latency.details).toMatchObject({claim_result_source:'receipt',exit_reason:'acknowledged'});expect(pushRequests).toHaveLength(0);
   const skipped=await env.DB.prepare("SELECT attempt,target FROM diagnostics WHERE operation='dispatch_skip' AND event_ref=? ORDER BY sequence DESC LIMIT 1").bind(await eventReference(testEnv,event!.event_id)).first();expect(skipped).toEqual({attempt:2,target:'phone'});
  }finally{release();await running;}
 });
 it('does not send after a claim lease expires while its original reply is delayed',async()=>{
  const {parent,listener}=await paired();await call('listener/event',listener,alert(listener));await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=await env.DB.prepare('SELECT event_id FROM events').first<{event_id:string}>();
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql.startsWith('UPDATE events SET resolved_at=')){entered();await gate;}return result;});
  const {dispatchEvent}=await import('../src/alerts'),{Latency}=await import('../src/latency');const latency=new Latency();
  const running=dispatchEvent({...testEnv,DB:db},event!.event_id,undefined,latency);await ready;
  try {vi.spyOn(Date,'now').mockReturnValue(Date.now()+31000);await Promise.race([running,new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Expired lease not observed')),1000))]);expect(pushRequests).toHaveLength(0);expect(latency.details.exit_reason).toBe('not_pending');}
  finally{release();await running;}
 });
});

describe('claim ownership across competing requests and token rotation',()=>{
 it('cannot borrow another invocation’s committed claim while its own write is still pending',async()=>{
  const {parent,listener}=await paired();await call('listener/event',listener,alert(listener));await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=await env.DB.prepare('SELECT event_id FROM events').first<{event_id:string}>();
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{if(method==='batch'&&sql.startsWith('UPDATE events SET resolved_at=')){entered();await gate;}return execute();});
  const {dispatchEvent}=await import('../src/alerts'),{Latency}=await import('../src/latency');const latency=new Latency();
  const first=dispatchEvent({...testEnv,DB:db},event!.event_id,undefined,latency);await ready;
  try {
   mockPush();await dispatchEvent(testEnv,event!.event_id);await new Promise(r=>setTimeout(r,300));
   expect(pushRequests).toHaveLength(1);expect(latency.details.claim_receipt_outcome).toBe('missing');
  }finally{release();await first;}
  expect(pushRequests).toHaveLength(1);expect(latency.details.claim_result_source).toBe('reply');expect(latency.details.exit_reason).toBe('already_sent');
 });
 it('uses the current destination token when ownership proves a delayed committed claim',async()=>{
  const {parent,listener}=await paired();await call('listener/event',listener,alert(listener));await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=await env.DB.prepare('SELECT event_id FROM events').first<{event_id:string}>();
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql.startsWith('UPDATE events SET resolved_at=')){entered();await gate;}return result;});
  const {dispatchEvent}=await import('../src/alerts');mockPush();const running=dispatchEvent({...testEnv,DB:db},event!.event_id);await ready;
  try {
   await env.DB.prepare('UPDATE devices SET push_token=? WHERE id=?').bind(await encryptToken(testEnv,'ef'.repeat(32)),parent.deviceId).run();
   await Promise.race([running,new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Owned claim did not progress')),1000))]);
   expect(pushRequests).toHaveLength(1);expect(pushRequests[0].url).toContain('ef'.repeat(32));
  }finally{release();await running;}
 });
});

describe('heartbeat binding wait recovery',()=>{
 const beat=(listener:TestDevice)=>({listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[]});
 const request=(listener:TestDevice)=>new Request('https://monitor.test/v1/listener/heartbeat',{method:'POST',headers:{'content-type':'application/json','CF-Connecting-IP':'127.0.0.1',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(beat(listener))});
 it('uses four binding calls with fully instrumented snapshot and atomic persistence',async()=>{
  const {listener}=await paired();let calls=0;
  const db=interceptDB(async(_sql,_args,_method,execute)=>{calls++;return execute();});
  const response=await worker.fetch(request(listener),{...testEnv,DB:db});expect(await response.json()).toEqual(defaultConfiguration);
  expect(calls).toBe(5); // Four functional calls plus the existing diagnostic write.
  const row=await env.DB.prepare('SELECT details FROM diagnostics WHERE request_id=?').bind(response.headers.get('x-request-id')).first<{details:string}>();
  const d=JSON.parse(row!.details);expect(d.db_calls).toBe(4);
  expect(d.db_stages.heartbeat_admission_ms).toMatchObject({calls:1,statements:3});
  expect(d.db_stages.heartbeat_snapshot_ms).toMatchObject({calls:1,statements:1});
  expect(d.db_stages.heartbeat_storage_ms).toMatchObject({calls:1,statements:6});
 });
 it('recovers a stalled credential reply with one fresh SELECT and charges quotas once',async()=>{
  const {listener}=await paired();let reads=0,release!:()=>void,entered!:()=>void;
  const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(sql==='SELECT * FROM devices WHERE id=?'&&method==='all'&&++reads===1){entered();await gate;}return result;});
  const work=worker.fetch(request(listener),{...testEnv,DB:db});await ready;
  try {
   const response=await work;expect(response.status).toBe(200);expect(reads).toBe(2);
   const row=await env.DB.prepare('SELECT details FROM diagnostics WHERE request_id=?').bind(response.headers.get('x-request-id')).first<{details:string}>();
   expect(JSON.parse(row!.details).db_stages.authentication_lookup_ms).toMatchObject({calls:2,hedges:1,hedge_wins:1,unfinished:1,hedge_after_ms:250});
  }finally{release();await work;}
 });
 it('refuses credentials deleted while their original lookup reply is stalled',async()=>{
  const {listener}=await paired();let reads=0,release!:()=>void,entered!:()=>void;
  const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(sql==='SELECT * FROM devices WHERE id=?'&&method==='all'&&++reads===1){entered();await gate;}return result;});
  const work=worker.fetch(request(listener),{...testEnv,DB:db});await ready;
  try {expect((await call('device/delete',listener)).status).toBe(200);expect((await work).status).toBe(401);expect(reads).toBe(2);}
  finally{release();await work;}
  expect((await env.DB.prepare('SELECT * FROM heartbeats').all()).results).toHaveLength(0);
 });
 it('revalidates credentials inside the quota transaction and does not charge a revoked device',async()=>{
  const {listener}=await paired(),key=await sha256(`${testEnv.PAIRING_PEPPER}|device|${listener.deviceId}`);
  const prior=(await env.DB.prepare('SELECT attempts FROM rate_limits WHERE key=?').bind(key).first<{attempts:number}>())?.attempts;
  const db=interceptDB(async(sql,_args,method,execute)=>{if(method==='batch'&&sql.startsWith('INSERT INTO rate_limits'))await env.DB.prepare('UPDATE devices SET secret_hash=? WHERE id=?').bind(await sha256('revoked'),listener.deviceId).run();return execute();});
  expect((await worker.fetch(request(listener),{...testEnv,DB:db})).status).toBe(401);
  expect((await env.DB.prepare('SELECT attempts FROM rate_limits WHERE key=?').bind(key).first<{attempts:number}>())?.attempts).toBe(prior);
 });
 it('preserves both budgets and does not charge the device after the IP ceiling rejects it',async()=>{
  const {listener}=await paired(),window=Math.floor(Date.now()/1000/600);
  const ip=await sha256(`${testEnv.PAIRING_PEPPER}|api|127.0.0.1`),deviceKey=await sha256(`${testEnv.PAIRING_PEPPER}|device|${listener.deviceId}`);
  await env.DB.prepare('INSERT INTO rate_limits(key,window,attempts) VALUES(?,?,3000) ON CONFLICT(key) DO UPDATE SET window=excluded.window,attempts=3000').bind(ip,window).run();
  const prior=(await env.DB.prepare('SELECT attempts FROM rate_limits WHERE key=?').bind(deviceKey).first<{attempts:number}>())?.attempts;
  expect((await worker.fetch(request(listener),testEnv)).status).toBe(429);
  expect((await env.DB.prepare('SELECT attempts FROM rate_limits WHERE key=?').bind(deviceKey).first<{attempts:number}>())?.attempts).toBe(prior);
  await env.DB.prepare('UPDATE rate_limits SET attempts=0 WHERE key=?').bind(ip).run();
  await env.DB.prepare('INSERT INTO rate_limits(key,window,attempts) VALUES(?,?,600) ON CONFLICT(key) DO UPDATE SET window=excluded.window,attempts=600').bind(deviceKey,window).run();
  expect((await worker.fetch(request(listener),testEnv)).status).toBe(429);
  const bad={...listener,secret:btoa('xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')};expect((await worker.fetch(request(bad),testEnv)).status).toBe(401);
  expect((await env.DB.prepare('SELECT attempts FROM rate_limits WHERE key=?').bind(deviceKey).first<{attempts:number}>())?.attempts).toBe(601);
 });
 it('uses a fresh heartbeat snapshot fallback and refuses a removed pairing',async()=>{
  const {listener}=await paired();let reads=0,release!:()=>void,entered!:()=>void;
  const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(sql.startsWith('SELECT p.parent_id,p.listener_id,p.created_at,h.received_at')&&method==='all'&&++reads===1){entered();await gate;}return result;});
  const work=worker.fetch(request(listener),{...testEnv,DB:db});await ready;
  try {await env.DB.prepare('DELETE FROM pairs WHERE listener_id=?').bind(listener.deviceId).run();expect((await work).status).toBe(409);expect(reads).toBe(2);}
  finally{release();await work;}
  expect((await env.DB.prepare('SELECT * FROM heartbeats').all()).results).toHaveLength(0);
 });
 it('guards all persistence when pairing changes after the snapshot',async()=>{
  const {listener}=await paired();
  const db=interceptDB(async(sql,_args,method,execute)=>{if(method==='batch'&&sql.startsWith('INSERT INTO heartbeats'))await env.DB.prepare('DELETE FROM pairs WHERE listener_id=?').bind(listener.deviceId).run();return execute();});
  expect((await worker.fetch(request(listener),{...testEnv,DB:db})).status).toBe(409);
  for(const table of ['heartbeats','timeline_events','connection_states'])expect((await env.DB.prepare(`SELECT * FROM ${table}`).all()).results).toHaveLength(0);
 });
 it('never repeats committed heartbeat writes while their reply is delayed',async()=>{
  const {listener}=await paired();let writes=0,release!:()=>void,entered!:()=>void;
  const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql.startsWith('INSERT INTO heartbeats')){writes++;entered();await gate;}return result;});
  const work=worker.fetch(request(listener),{...testEnv,DB:db});await ready;
  try {await new Promise(r=>setTimeout(r,350));expect(writes).toBe(1);expect((await env.DB.prepare('SELECT * FROM heartbeats').all()).results).toHaveLength(1);}
  finally{release();expect((await work).status).toBe(200);}
 });
});

describe('heartbeat journal isolation',()=>{
 it('returns persisted heartbeat configuration without waiting for its unsampled diagnostic',async()=>{
  const {listener}=await paired(),jobs:Promise<unknown>[]=[];let release!:()=>void,entered!:()=>void;
  const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,_method,execute)=>{if(sql.startsWith('INSERT INTO diagnostics')){entered();await gate;}return execute();});
  const value={listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[]};
  const request=new Request('https://monitor.test/v1/listener/heartbeat',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(value)});
  const running=worker.fetch(request,{...testEnv,DB:db},{waitUntil:(job:Promise<unknown>)=>jobs.push(job)} as unknown as ExecutionContext);await ready;
  try {
   const response=await Promise.race([running,new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Heartbeat waited for its journal')),1000))]);
   expect(response.status).toBe(200);expect(await response.json()).toEqual(defaultConfiguration);
   expect(response.headers.get('x-diagnostics-status')).toBe('queued');expect(response.headers.get('x-diagnostics-elapsed-ms')).toBe('0');
   expect((await env.DB.prepare('SELECT * FROM heartbeats WHERE listener_id=?').bind(listener.deviceId).all()).results).toHaveLength(1);
  }finally{release();await running;await Promise.all(jobs);}
 });
});

describe('heartbeat committed-save receipt recovery',()=>{
 const beat=(listener:TestDevice)=>({listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,powerConnected:true,state:'quiet',episodes:[]});
 const request=(listener:TestDevice)=>new Request('https://monitor.test/v1/listener/heartbeat',{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(beat(listener))});
 it('proves its own atomic save while the original reply remains pending',async()=>{
  const {listener}=await paired();let writes=0,release!:()=>void,entered!:()=>void;
  const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql.startsWith('INSERT INTO heartbeats')){writes++;entered();await gate;}return result;});
  const work=worker.fetch(request(listener),{...testEnv,DB:db});await ready;
  try {
   const response=await Promise.race([work,new Promise<never>((_,reject)=>setTimeout(()=>reject(new Error('Waited for original committed save reply')),1200))]);
   expect(await response.json()).toEqual(defaultConfiguration);expect(writes).toBe(1);
   const row=await env.DB.prepare('SELECT details FROM diagnostics WHERE request_id=?').bind(response.headers.get('x-request-id')).first<{details:string}>(),timing=JSON.parse(row!.details);
   expect(timing).toMatchObject({heartbeat_result_source:'receipt',heartbeat_receipt_outcome:'matched',db_stages:{heartbeat_storage_ms:{calls:1,unfinished:1},heartbeat_receipt_ms:{calls:1,completed:1,statements:1}}});
   expect(timing.db_stages.heartbeat_storage_ms.sql_ms).toBeUndefined();
   expect(timing).not.toHaveProperty('__heartbeatReceipt');
  }finally{release();await work;}
 });
 it('recovers a committed save even if only its original response fails',async()=>{
  const {listener}=await paired();let writes=0;
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(method==='batch'&&sql.startsWith('INSERT INTO heartbeats')){writes++;throw new Error('lost committed reply');}return result;});
  expect((await worker.fetch(request(listener),{...testEnv,DB:db})).status).toBe(200);expect(writes).toBe(1);
 });
 it('does not borrow another heartbeat receipt when its write fails before commit',async()=>{
  const {listener}=await paired();expect((await call('listener/heartbeat',listener,beat(listener))).status).toBe(200);
  const before=await env.DB.prepare('SELECT metadata FROM heartbeats WHERE listener_id=?').bind(listener.deviceId).first<{metadata:string}>();let writes=0;
  const db=interceptDB(async(sql,_args,method,execute)=>{if(method==='batch'&&sql.startsWith('INSERT INTO heartbeats')){writes++;throw new Error('save did not commit');}return execute();});
  expect((await worker.fetch(request(listener),{...testEnv,DB:db})).status).toBe(503);expect(writes).toBe(1);
  expect(await env.DB.prepare('SELECT metadata FROM heartbeats WHERE listener_id=?').bind(listener.deviceId).first()).toEqual(before);
 });
 it('refuses a removed pairing as proof of a delayed save whose reply later fails',async()=>{
  const {listener}=await paired();let release!:()=>void,entered!:()=>void,proof!:()=>void;
  const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;}),proofDone=new Promise<void>(r=>{proof=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();if(method==='batch'&&sql.startsWith('INSERT INTO heartbeats')){entered();await gate;throw new Error('late lost reply');}
   if(method==='all'&&sql.includes("json_extract(h.metadata,'$.__heartbeatReceipt')"))proof();return result;
  });
  let complete=false;const work=worker.fetch(request(listener),{...testEnv,DB:db}).then(r=>{complete=true;return r;});await ready;
  try {await env.DB.prepare('DELETE FROM pairs WHERE listener_id=?').bind(listener.deviceId).run();await proofDone;expect(complete).toBe(false);}
  finally{release();expect((await work).status).toBe(503);}
 });
});

describe('durable dual destination receipts',()=>{
 async function setup() {
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});mockPush(200,2);const event=alert(listener);await call('listener/event',listener,event);
  return {parent,listener,event};
 }
 it('lets the next two-device reminder run while its predecessor outcome is stalled',async()=>{
  const {parent}=await setup();let now=Date.now()+10000;vi.spyOn(Date,'now').mockImplementation(()=>now);
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});
  const db=interceptDB(async(sql,_args,method,execute)=>{if(sql.startsWith('WITH states AS MATERIALIZED')&&method==='run'){entered();await gate;}return execute();});
  const {AlertReminders}=await import('../src/reminders');const state=reminderContext(parent.deviceId),instance=new AlertReminders(state.ctx,{...testEnv,DB:db});
  mockPush(200,2);await instance.alarm();await ready;
  try{
   expect(pushRequests).toHaveLength(4);expect([...state.values.keys()].filter(k=>k.startsWith('accepted/'))).toHaveLength(1);
   now+=5000;mockPush(200,2);await instance.alarm();expect(pushRequests).toHaveLength(6);
   const ids=pushRequests.map(r=>JSON.parse(String(r.init?.body)).eventId);expect(new Set(ids).size).toBe(3);
   for(const id of new Set(ids))expect(ids.filter(value=>value===id)).toHaveLength(2);
   expect(JSON.stringify([...state.values.values()])).not.toMatch(/abababababababab|cdcdcdcdcdcdcdcd/);
   await env.DB.prepare('UPDATE events SET acknowledged_at=?').bind(new Date(now).toISOString()).run();
  }finally{release();await state.drain();}
  await instance.alarm();await state.drain();expect([...state.values.keys()].filter(k=>k.startsWith('accepted/'))).toHaveLength(0);
  const rows=await env.DB.prepare("SELECT target,http_status,details FROM diagnostics WHERE operation='dispatch' AND target IS NOT NULL AND json_extract(details,'$.durable_outcome')=1").all<{target:string;http_status:number;details:string}>();
  expect(rows.results).toHaveLength(4);expect(rows.results.every(row=>row.http_status===200)).toBe(true);
 });
 it.each(['retry','uncertain'] as const)('recovers accepted phone and %s Watch outcomes atomically after restart',async outcome=>{
  const {parent,event}=await setup();const states=JSON.stringify({phone:'pending',watch:'pending'});
  await env.DB.prepare("UPDATE events SET status='sending',attempts=2,delivery_state=? WHERE event_id=?").bind(states,event.eventId).run();
  const receipts:import('../src/accepted-delivery').AcceptedDelivery[]=[];
  const send=vi.fn(async(target:'phone'|'watch')=>target==='phone'?{status:'sent' as const,httpStatus:200}:{status:outcome,reason:outcome==='retry'?'apns_503' as const:'transport_unknown' as const});
  const result=await deliverToBoth(testEnv,{table:'events',id:event.eventId,parentId:parent.deviceId,attempt:2,state:states,phoneToken:'secret-phone',watchToken:'secret-watch',requestId:crypto.randomUUID(),send,
   accepted:async receipt=>{receipts.push(receipt);},aggregate:{requestId:crypto.randomUUID(),started:Date.now(),operation:'dispatch',stage:'storage',outcome:'sent'}});
  expect(result).toBe(outcome==='retry'?'pending':'uncertain');expect(receipts).toHaveLength(1);expect(JSON.stringify(receipts)).not.toMatch(/secret-phone|secret-watch/);
  await env.DB.prepare("UPDATE events SET status='uncertain',last_error='dispatch_interrupted',acknowledged_at=? WHERE event_id=?").bind(new Date().toISOString(),event.eventId).run();
  const {persistAcceptedDelivery}=await import('../src/accepted-delivery');await persistAcceptedDelivery(testEnv,receipts[0],true);
  const row=await env.DB.prepare('SELECT status,delivery_state,acknowledged_at FROM events WHERE event_id=?').bind(event.eventId).first<{status:string;delivery_state:string;acknowledged_at:string}>();
  expect(row!.status).toBe(result);expect(row!.acknowledged_at).not.toBeNull();expect(JSON.parse(row!.delivery_state)).toEqual({phone:'sent',watch:outcome==='retry'?'pending':'uncertain'});
  await env.DB.prepare("UPDATE events SET status='sending',attempts=3 WHERE event_id=?").bind(event.eventId).run();send.mockClear();send.mockResolvedValue({status:'sent',httpStatus:200});
  await deliverToBoth(testEnv,{table:'events',id:event.eventId,parentId:parent.deviceId,attempt:3,state:row!.delivery_state,phoneToken:'phone',watchToken:'watch',requestId:crypto.randomUUID(),send});
  expect(send).toHaveBeenCalledTimes(outcome==='retry'?1:0);if(outcome==='retry')expect(send.mock.calls[0][0]).toBe('watch');
 });
 it('does not delete a newer receipt when the old attempt finishes after its D1 commit',async()=>{
  const {parent,event}=await setup();const {acceptedDelivery}=await import('../src/accepted-delivery');
  const first=acceptedDelivery(event.eventId,parent.deviceId,1,0,{requestId:crypto.randomUUID(),started:Date.now(),operation:'dispatch',stage:'storage',outcome:'sent'});
  const second=acceptedDelivery(event.eventId,parent.deviceId,2,0,first.diagnostic);
  const state=reminderContext(parent.deviceId);state.values.set('accepted/'+event.eventId,first);
  let release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>{release=r;}),ready=new Promise<void>(r=>{entered=r;});let count=0;
  const db=interceptDB(async(sql,_args,method,execute)=>{const result=await execute();if(sql.startsWith("UPDATE events SET status='sent'")&&method==='run'&&count++===0){entered();await gate;}return result;});
  const {AlertReminders}=await import('../src/reminders');const instance=new AlertReminders(state.ctx,{...testEnv,DB:db});
  const post=(receipt:typeof first)=>instance.fetch(new Request('https://reminders.internal/accepted',{method:'POST',body:JSON.stringify(receipt)}));
  await post(first);await ready;await post(second);await post(first);
  try{expect((state.values.get('accepted/'+event.eventId) as typeof first).checkpointId).toBe(second.checkpointId);}
  finally{release();await state.drain();}
  expect((state.values.get('accepted/'+event.eventId) as typeof first).checkpointId).toBe(second.checkpointId);
  await env.DB.prepare('UPDATE events SET acknowledged_at=?').bind(new Date().toISOString()).run();await instance.alarm();await state.drain();
  expect(state.values.has('accepted/'+event.eventId)).toBe(false);
 });
});

describe('Watch-only notification trial',()=>{
 async function setup(watch=true){
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  if(watch)await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  return {parent,listener,configured:{...testEnv,WATCH_ONLY_PARENT_ID:parent.deviceId}};
 }
 const upload=(listener:TestDevice,event:Alert,configured:Env)=>worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',
  headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(event)}),configured);
 it('sends only a Time Sensitive Watch push, suppresses the auxiliary phone copy and removes head-start waiting',async()=>{
  const {parent,listener,configured}=await setup();await call('silent-watch-alarms',parent,{enabled:true});
  const event={...alert(listener),isTest:true};mockPush();
  expect(await (await upload(listener,event,{...configured,WATCH_PHONE_HEAD_START_PARENT_ID:parent.deviceId,WATCH_PHONE_HEAD_START_MS:'500'})).json()).toEqual({status:'sent'});
  expect(pushRequests).toHaveLength(1);
  const headers=new Headers(pushRequests[0].init?.headers),body=JSON.parse(String(pushRequests[0].init?.body));
  expect(headers.get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');expect(headers.get('apns-collapse-id')).toBe(event.eventId);
  expect(body.aps.sound).toBe('default');expect(body.aps['interruption-level']).toBe('time-sensitive');expect(body.silentCryAlarm).toBeUndefined();
  expect(await env.DB.prepare('SELECT status,delivery_mode,delivery_state,push_target FROM events WHERE event_id=?').bind(event.eventId).first())
   .toEqual({status:'sent',delivery_mode:'watch_only',delivery_state:null,push_target:'watch'});
  const row=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch' AND target='watch' AND outcome='sent'").first<{details:string}>();
  const details=JSON.parse(row!.details);expect(details).toMatchObject({notification_route:'watch_only',phone_suppressed:true,phone_fallback:false});
  expect(details.coordination_mode).toBeUndefined();expect(details.spans.coordination_wait_ms).toBeUndefined();
  await upload(listener,event,configured);expect(pushRequests).toHaveLength(1);
 });
 it('keeps ordinary phone delivery when no Watch is registered',async()=>{
  const {listener,configured}=await setup(false),event={...alert(listener),isTest:true};mockPush();
  expect(await (await upload(listener,event,configured)).json()).toEqual({status:'sent'});
  expect(pushRequests).toHaveLength(1);expect(new Headers(pushRequests[0].init?.headers).get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID);
  expect(await env.DB.prepare('SELECT delivery_mode FROM events WHERE event_id=?').bind(event.eventId).first()).toEqual({delivery_mode:null});
 });
 it('leaves other Parents on dual delivery',async()=>{
  const {listener}=await setup(),event={...alert(listener),isTest:true};mockPush(200,2);
  await upload(listener,event,{...testEnv,WATCH_ONLY_PARENT_ID:crypto.randomUUID()});expect(pushRequests).toHaveLength(2);
 });
 it('pins retryable Watch delivery across trial rollback without adding a phone send',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush(503);
  expect(await (await upload(listener,event,configured)).json()).toEqual({status:'pending'});
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();mockPush();
  await dispatchEvent(testEnv,event.eventId);expect(pushRequests).toHaveLength(2);
  expect(pushRequests.every(r=>new Headers(r.init?.headers).get('apns-topic')!.endsWith('.watchkitapp'))).toBe(true);
  expect(await env.DB.prepare('SELECT status,attempts,delivery_mode FROM events WHERE event_id=?').bind(event.eventId).first()).toEqual({status:'sent',attempts:2,delivery_mode:'watch_only'});
 });
 it('never retries an uncertain Watch send or falls back to the phone for ambiguous transport',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};pushResponses.push(new Error('ambiguous'));
  expect(await (await upload(listener,event,configured)).json()).toEqual({status:'uncertain'});
  await dispatchEvent(configured,event.eventId);expect(pushRequests).toHaveLength(1);
 });
 it('falls back to the phone only after Apple definitively invalidates the Watch token',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};pushResponses.push({body:JSON.stringify({reason:'Unregistered'}),status:410});
  expect(await (await upload(listener,event,configured)).json()).toEqual({status:'pending'});mockPush();
  await dispatchEvent(configured,event.eventId);expect(pushRequests).toHaveLength(2);
  expect(new Headers(pushRequests[1].init?.headers).get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID);
  const row=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch' AND target='phone' AND outcome='sent'").first<{details:string}>();
  expect(JSON.parse(row!.details)).toMatchObject({notification_route:'watch_only',phone_suppressed:false,phone_fallback:true});
 });
 it('keeps real alerts and reminders on both destinations despite a Watch-only test flag',async()=>{
  const {parent,listener,configured}=await setup();mockPush(200,2);await upload(listener,alert(listener),configured);
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);mockPush(200,2);
  const receipts:import('../src/accepted-delivery').AcceptedDelivery[]=[];
  await runReminder(configured,parent.deviceId,undefined,undefined,{accepted:async receipt=>{receipts.push(receipt);}});
  expect(pushRequests).toHaveLength(4);expect(receipts).toHaveLength(1);expect(receipts[0].dual?.states).toEqual({phone:'sent',watch:'sent'});
  const {persistAcceptedDelivery}=await import('../src/accepted-delivery');await persistAcceptedDelivery(configured,receipts[0]);
  await dispatchEvent(testEnv,receipts[0].eventId);expect(pushRequests).toHaveLength(4);
  expect(await env.DB.prepare('SELECT status,delivery_mode FROM events WHERE event_id=?').bind(receipts[0].eventId).first()).toEqual({status:'sent',delivery_mode:null});
 });
 it('preserves existing dual-target state when the trial is enabled during a retry',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush(200,2);await upload(listener,event,testEnv);
  await env.DB.prepare("UPDATE events SET status='pending',next_attempt=0,delivery_state=? WHERE event_id=?").bind(JSON.stringify({phone:'sent',watch:'pending'}),event.eventId).run();mockPush();
  await dispatchEvent(configured,event.eventId);expect(pushRequests).toHaveLength(3);
  expect(new Headers(pushRequests[2].init?.headers).get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');
  expect(await env.DB.prepare('SELECT delivery_mode,delivery_state FROM events WHERE event_id=?').bind(event.eventId).first())
   .toEqual({delivery_mode:null,delivery_state:JSON.stringify({phone:'sent',watch:'sent'})});
 });
});

describe('phone-only marked-test forwarding control',()=>{
 async function setup(phone=true){
  const {parent,listener}=await paired();
  if(phone)await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  return {parent,listener,configured:{...testEnv,PHONE_ONLY_TEST_PARENT_ID:parent.deviceId}};
 }
 const upload=(listener:TestDevice,event:Alert,configured:Env)=>worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',
  headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(event)}),configured);
 it.each([true,false])('isolates marked tests while preserving ordinary dual delivery (test=%s)',async(isTest)=>{
  const {parent,listener,configured}=await setup(),event={...alert(listener),...(isTest?{isTest:true}:{})};mockPush(200,isTest?1:2);
  expect(await (await upload(listener,event,configured)).json()).toEqual({status:'sent'});
  await upload(listener,event,configured);expect(pushRequests).toHaveLength(isTest?1:2);
  if(isTest){
   const request=pushRequests[0],headers=new Headers(request.init?.headers),body=JSON.parse(String(request.init?.body));
   expect(headers.get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID);expect(headers.get('apns-collapse-id')).toBe(event.eventId);
   expect(body).toMatchObject({isTest:true,aps:{sound:'default',category:'BABY_CRY_ALERT','interruption-level':'time-sensitive'}});
   expect(await env.DB.prepare('SELECT push_target,delivery_state FROM events WHERE event_id=?').bind(event.eventId).first()).toEqual({push_target:'phone',delivery_state:null});
   const row=await env.DB.prepare("SELECT details FROM diagnostics WHERE target='phone' AND operation='dispatch'").first<{details:string}>();
   expect(JSON.parse(row!.details)).toMatchObject({notification_route:'phone_only_test',watch_suppressed:true});
  }
 });
 it('does not affect other Parents',async()=>{
  const {listener}=await setup();mockPush(200,2);await upload(listener,{...alert(listener),isTest:true},{...testEnv,PHONE_ONLY_TEST_PARENT_ID:crypto.randomUUID()});expect(pushRequests).toHaveLength(2);
 });
 it('keeps a retry phone-only after the trial is disabled',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush(503);await upload(listener,event,configured);
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();mockPush();await dispatchEvent(testEnv,event.eventId);
  expect(pushRequests).toHaveLength(2);expect(pushRequests.every(r=>new Headers(r.init?.headers).get('apns-topic')===testEnv.APNS_BUNDLE_ID)).toBe(true);
 });
 it('preserves an already selected dual-target retry',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush(200,2);await upload(listener,event,testEnv);
  await env.DB.prepare("UPDATE events SET status='pending',next_attempt=0,delivery_state=? WHERE event_id=?").bind(JSON.stringify({phone:'sent',watch:'pending'}),event.eventId).run();mockPush();await dispatchEvent(configured,event.eventId);
  expect(pushRequests).toHaveLength(3);expect(new Headers(pushRequests[2].init?.headers).get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');
 });
 it('keeps Watch delivery if no phone token is available',async()=>{
  const {listener,configured}=await setup(false);mockPush();await upload(listener,{...alert(listener),isTest:true},configured);
  expect(pushRequests).toHaveLength(1);expect(new Headers(pushRequests[0].init?.headers).get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');
 });
 it('never sends the Watch a fallback after uncertain phone transport',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};pushResponses.push(new Error('network timeout'));
  expect(await (await upload(listener,event,configured)).json()).toEqual({status:'uncertain'});await dispatchEvent(configured,event.eventId);expect(pushRequests).toHaveLength(1);
 });
 it('allows a Watch fallback only after a definitive phone token rejection',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};pushResponses.push({body:JSON.stringify({reason:'Unregistered'}),status:410});
  await upload(listener,event,configured);mockPush();await dispatchEvent(configured,event.eventId);
  expect(pushRequests).toHaveLength(2);expect(new Headers(pushRequests[1].init?.headers).get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');
 });
 it('leaves an explicit Watch-only trial in control if flags conflict',async()=>{
  const {parent,listener,configured}=await setup();mockPush();await upload(listener,{...alert(listener),isTest:true},{...configured,WATCH_ONLY_PARENT_ID:parent.deviceId});
  expect(pushRequests).toHaveLength(1);expect(new Headers(pushRequests[0].init?.headers).get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');
 });
});

describe('distinct APNs request ID marked-test control',()=>{
 async function setup(){
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  return {parent,listener,configured:{...testEnv,DISTINCT_APNS_ID_TEST_PARENT_ID:parent.deviceId}};
 }
 const upload=(listener:TestDevice,event:Alert,configured:Env)=>worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',
  headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(event)}),configured);
 it('uses different transport UUIDs while matching notification IDs, payloads and event correlation',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush(200,2);
  expect(await (await upload(listener,event,configured)).json()).toEqual({status:'sent'});
  const requests=pushRequests.map(r=>({headers:new Headers(r.init?.headers),body:JSON.parse(String(r.init?.body))}));expect(requests).toHaveLength(2);
  const ids=requests.map(r=>r.headers.get('apns-id'));
  expect(new Set(ids).size).toBe(2);expect(ids).not.toContain(event.eventId);
  for(const r of requests){
   expect(r.headers.get('apns-id')).toMatch(/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/);
   expect(r.headers.get('apns-collapse-id')).toBe(event.eventId);
   expect(r.body).toMatchObject({eventId:event.eventId,episodeId:event.episodeId,isTest:true,
    aps:{sound:'default',category:'BABY_CRY_ALERT','interruption-level':'time-sensitive'}});
  }
  expect(requests[0].body).toEqual(requests[1].body);
  const rows=await env.DB.prepare("SELECT target,details FROM diagnostics WHERE operation='dispatch' AND target IS NOT NULL").all<{target:string;details:string}>();
  expect(rows.results).toHaveLength(2);
  for(const row of rows.results){
   const request=requests.find(r=>r.headers.get('apns-topic')===testEnv.APNS_BUNDLE_ID+(row.target==='watch'?'.watchkitapp':''))!;
   expect(JSON.parse(row.details)).toMatchObject({apns_id_mode:'distinct_request',apns_request_id:request.headers.get('apns-id')});
  }
 });
 it.each(['real','other_parent','disabled'] as const)('preserves existing request IDs for %s alerts',async mode=>{
  const {listener,configured}=await setup(),event={...alert(listener),...(mode==='real'?{}:{isTest:true})};mockPush(200,2);
  await upload(listener,event,mode==='disabled'?testEnv:mode==='other_parent'?{...configured,DISTINCT_APNS_ID_TEST_PARENT_ID:crypto.randomUUID()}:configured);
  expect(pushRequests).toHaveLength(2);
  for(const r of pushRequests)expect(new Headers(r.init?.headers).get('apns-id')).toBe(event.eventId);
 });
 it.each(['retry','uncertain'] as const)('does not replay an accepted sibling after a %s outcome',async mode=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush();
  if(mode==='retry')mockPush(503);else pushResponses.push(new Error('ambiguous'));
  await upload(listener,event,configured);
  const firstIDs=pushRequests.map(r=>new Headers(r.init?.headers).get('apns-id'));
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();
  if(mode==='retry')mockPush();await dispatchEvent(configured,event.eventId);
  expect(pushRequests).toHaveLength(mode==='retry'?3:2);
  if(mode==='retry'){
   const retry=new Headers(pushRequests[2].init?.headers);expect(retry.get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');
   expect(retry.get('apns-collapse-id')).toBe(event.eventId);expect(firstIDs).not.toContain(retry.get('apns-id'));
  }
 });
});

describe('separate collapse IDs for crying alerts and scoped marked tests',()=>{
 async function setup(){
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  return {parent,listener,configured:{...testEnv,SEPARATE_COLLAPSE_ID_TEST_PARENT_ID:parent.deviceId}};
 }
 const upload=(listener:TestDevice,event:Alert,configured:Env)=>worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',
  headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(event)}),configured);
 it.each([{isTest:false,isRepeat:false},{isTest:false,isRepeat:true},{isTest:true,isRepeat:false},{isTest:true,isRepeat:true}])('separates notification IDs while retaining one logical event and transport-ID policy (test=$isTest, repeat=$isRepeat)',async({isTest,isRepeat})=>{
  const {listener,configured}=await setup(),event={...alert(listener),...(isTest?{isTest:true}:{}),isRepeat};mockPush(200,2);
  expect(await (await upload(listener,event,isTest?configured:testEnv)).json()).toEqual({status:'sent'});
  const requests=pushRequests.map(r=>({headers:new Headers(r.init?.headers),body:JSON.parse(String(r.init?.body))}));expect(requests).toHaveLength(2);
  const base=event.eventId;
  for(const r of requests){
   const target=r.headers.get('apns-topic')!.endsWith('.watchkitapp')?'watch':'phone';
   expect(r.headers.get('apns-collapse-id')).toBe(`${target}:${base}`);
   expect(new TextEncoder().encode(r.headers.get('apns-collapse-id')!).length).toBeLessThanOrEqual(64);
   expect(r.headers.get('apns-id')).toBe(event.eventId);
   expect(r.body.isTest).toBe(isTest?true:undefined);
   expect(r.body.aps['thread-id']).toBeUndefined();
   expect(r.body).toMatchObject({eventId:event.eventId,episodeId:event.episodeId,
    aps:{sound:'default',category:'BABY_CRY_ALERT','interruption-level':'time-sensitive'}});
  }
  expect(requests[0].body).toEqual(requests[1].body);
  const rows=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch' AND target IS NOT NULL").all<{details:string}>();
  expect(rows.results).toHaveLength(2);
  for(const row of rows.results)expect(JSON.parse(row.details)).toMatchObject({apns_collapse_mode:'target_scoped',apns_collapse_basis:'event'});
 });
 it.each(['other_parent','disabled'] as const)('preserves matching collapse IDs for marked tests (%s)',async mode=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush(200,2);
  await upload(listener,event,mode==='disabled'?testEnv:mode==='other_parent'?{...configured,SEPARATE_COLLAPSE_ID_TEST_PARENT_ID:crypto.randomUUID()}:configured);
  expect(pushRequests).toHaveLength(2);
  for(const r of pushRequests)expect(new Headers(r.init?.headers).get('apns-collapse-id')).toBe(event.eventId);
 });
 it.each([false,true])('retries only a definitively rejected target without replaying its accepted sibling (rollback=%s)',async rollback=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush();mockPush(503);
  await upload(listener,event,configured);
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();mockPush();
  await dispatchEvent(rollback?testEnv:configured,event.eventId);
  expect(pushRequests).toHaveLength(3);
  const headers=new Headers(pushRequests[2].init?.headers);expect(headers.get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');
  expect(headers.get('apns-collapse-id')).toBe(rollback?event.eventId:`watch:${event.eventId}`);
 });
 it('retains a reminder identity on retry without replacing other reminders or replaying its accepted sibling',async()=>{
  const {listener}=await setup(),event={...alert(listener),isRepeat:true};mockPush();mockPush(503);
  await upload(listener,event,testEnv);
  const first=pushRequests.map(r=>new Headers(r.init?.headers));
  expect(first.map(h=>h.get('apns-collapse-id'))).toEqual([`phone:${event.eventId}`,`watch:${event.eventId}`]);
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();mockPush();
  await dispatchEvent(testEnv,event.eventId);expect(pushRequests).toHaveLength(3);
  const retry=new Headers(pushRequests[2].init?.headers);
  expect(retry.get('apns-collapse-id')).toBe(first[1].get('apns-collapse-id'));
  expect(retry.get('apns-id')).toBe(event.eventId);
  expect(retry.get('apns-topic')).toBe(testEnv.APNS_BUNDLE_ID+'.watchkitapp');
 });
 it('never replays an uncertain target or its accepted sibling',async()=>{
  const {listener,configured}=await setup(),event={...alert(listener),isTest:true};mockPush();pushResponses.push(new Error('ambiguous'));
  expect(await (await upload(listener,event,configured)).json()).toEqual({status:'uncertain'});
  await dispatchEvent(configured,event.eventId);await dispatchEvent(testEnv,event.eventId);expect(pushRequests).toHaveLength(2);
 });
 it.each([false,true])('acknowledges both notification copies once and only snoozes real crying alerts (test=%s)',async isTest=>{
  const {parent,listener,configured}=await setup(),event={...alert(listener),...(isTest?{isTest:true}:{})};mockPush(200,2);await upload(listener,event,isTest?configured:testEnv);
  let mutedUntil:number|undefined;
  for(const request of pushRequests){
   const body=JSON.parse(String(request.init?.body));expect((await call('alert/acknowledge',parent,{eventId:body.eventId})).status).toBe(200);
   const mute=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
   if(mutedUntil!==undefined)expect(mute!.alerts_muted_until).toBe(mutedUntil);
   mutedUntil=mute!.alerts_muted_until;
  }
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM timeline_events WHERE kind=?').bind(isTest?'test_acknowledged':'alert_acknowledged').first()).toEqual({n:1});
  if(isTest)expect(mutedUntil).toBe(0);else expect(mutedUntil!-Date.now()).toBeGreaterThan(59000);
  expect((await env.DB.prepare('SELECT acknowledged_at FROM events WHERE event_id=?').bind(event.eventId).first<{acknowledged_at:string}>())!.acknowledged_at).toBeTruthy();
 });
});

describe('standalone Watch probe',()=>{
 const request=(d?:TestDevice,configured:Env=testEnv)=>worker.fetch(new Request('https://monitor.test/v1/watch-latency-probe/push',{
  method:'POST',headers:d?{authorization:`Bearer ${d.deviceId}.${d.secret}`}:{}}),configured);
 it('requires authentication, a Parent and exact experiment opt-in',async()=>{
  expect((await request()).status).toBe(401);
  const parent=device('parent'),listener=device('listener');await register(parent);await register(listener);
  expect((await request(parent)).status).toBe(403);
  expect((await request(listener,{...testEnv,WATCH_LATENCY_PROBE_PARENT_ID:listener.deviceId})).status).toBe(403);
  expect((await request(parent,{...testEnv,WATCH_LATENCY_PROBE_PARENT_ID:crypto.randomUUID()})).status).toBe(403);
  expect(pushRequests).toHaveLength(0);
 });
 it('sends once to the fixed standalone topic, reuses the provider JWT and creates no nursery events',async()=>{
  const parent=device('parent');await register(parent);await call('device/push-token',parent,{token:'ef'.repeat(32)});
  const configured={...testEnv,WATCH_LATENCY_PROBE_PARENT_ID:parent.deviceId};
  const jwt=await apnsToken(configured);mockPush();
  const response=await request(parent,configured),result=await response.json() as {eventId:string;createdAt:string;accepted:boolean};
  expect(response.status).toBe(200);expect(result.accepted).toBe(true);expect(pushRequests).toHaveLength(1);
  const push=pushRequests[0],headers=new Headers(push.init?.headers),body=JSON.parse(String(push.init?.body));
  expect(push.url).toBe('https://api.sandbox.push.apple.com/3/device/'+'ef'.repeat(32));
  expect(headers.get('apns-topic')).toBe('com.jordanerenrich.cribservice.latencyprobe');
  expect(headers.get('authorization')).toBe('bearer '+jwt);
  expect(headers.get('apns-collapse-id')).toBe(result.eventId);expect(headers.get('apns-id')).toBe(result.eventId);
  expect(body).toMatchObject({eventId:result.eventId,createdAt:result.createdAt,isTest:true,aps:{sound:'default','interruption-level':'time-sensitive'}});
  expect(body.aps.category).toBeUndefined();expect(body.aps['thread-id']).toBeUndefined();
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM events').first()).toEqual({n:0});
 });
 it('rejects a real pairing even if its ID was accidentally configured',async()=>{
  const {parent}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  expect((await request(parent,{...testEnv,WATCH_LATENCY_PROBE_PARENT_ID:parent.deviceId})).status).toBe(409);
  expect(pushRequests).toHaveLength(0);
 });
 it('reports an uncertain send without retries or an outbox',async()=>{
  const parent=device('parent');await register(parent);await call('device/push-token',parent,{token:'ef'.repeat(32)});
  pushResponses.push(new Error('transport unknown'));
  const response=await request(parent,{...testEnv,WATCH_LATENCY_PROBE_PARENT_ID:parent.deviceId});
  expect(await response.json()).toMatchObject({status:'uncertain',accepted:false});expect(pushRequests).toHaveLength(1);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM events').first()).toEqual({n:0});
 });
 it('limits the probe to six isolated attempts per ten minutes',async()=>{
  const parent=device('parent');await register(parent);await call('device/push-token',parent,{token:'ef'.repeat(32)});
  const configured={...testEnv,WATCH_LATENCY_PROBE_PARENT_ID:parent.deviceId};mockPush(200,6);
  for(let i=0;i<6;i++)expect((await request(parent,configured)).status).toBe(200);
  expect((await request(parent,configured)).status).toBe(429);expect(pushRequests).toHaveLength(6);
 });
});

describe('phone head-start trial delivery',()=>{
 async function setup(){
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  return {parent,listener};
 }
 const upload=(listener:TestDevice,event:Alert,configured:Env)=>worker.fetch(new Request('https://monitor.test/v1/listener/event',{method:'POST',
  headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(event)}),configured);
 it('separates actual request starts while retaining matching IDs, Time Sensitive and matching default sound',async()=>{
  const {parent,listener}=await setup(),event={...alert(listener),isTest:true},times=new Map<string,number>(),external=globalThis.fetch;
  vi.stubGlobal('fetch',vi.fn((input:string|URL|Request,init?:RequestInit)=>{times.set(new Headers(init?.headers).get('apns-topic')!,performance.now());return external(input,init);}));mockPush(200,2);
  expect(await (await upload(listener,event,{...testEnv,PHONE_HEAD_START_TEST_PARENT_ID:parent.deviceId})).json()).toEqual({status:'sent'});
  const phoneTopic=testEnv.APNS_BUNDLE_ID,watchTopic=phoneTopic+'.watchkitapp';expect(times.get(watchTopic)!-times.get(phoneTopic)!).toBeGreaterThanOrEqual(499);
  expect(pushRequests).toHaveLength(2);
  const [phone,watch]=pushRequests.map(request=>({headers:new Headers(request.init?.headers),body:JSON.parse(String(request.init?.body))}));
  expect(phone.headers.get('apns-collapse-id')).toBe(watch.headers.get('apns-collapse-id'));expect(phone.headers.get('apns-id')).toBe(watch.headers.get('apns-id'));
  expect(phone.body.aps.sound).toBe('default');expect(watch.body.aps.sound).toBe('default');
  expect(phone.body.aps['interruption-level']).toBe('time-sensitive');expect(watch.body.aps['interruption-level']).toBe('time-sensitive');
  const rows=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch' AND target='watch'").all<{details:string}>();
  const details=JSON.parse(rows.results[0].details);expect(details).toMatchObject({coordination_mode:'phone_head_start',phone_head_start_ms:500,phone_head_start_wait_outcome:'head_start_elapsed'});
  expect(details.phone_head_start_observed_ms).toBeGreaterThanOrEqual(499);
 });
 it('sends to the Watch while the phone APNs response remains stalled',async()=>{
  const {parent,listener}=await setup(),event={...alert(listener),isTest:true};let release!:()=>void,seenWatch!:()=>void,phoneReturned=false;
  const gate=new Promise<void>(r=>{release=r;}),watchStarted=new Promise<void>(r=>{seenWatch=r;});
  vi.stubGlobal('fetch',vi.fn(async(input:string|URL|Request,init?:RequestInit)=>{
   pushRequests.push({url:String(input),init});
   if(new Headers(init?.headers).get('apns-topic')!.endsWith('.watchkitapp'))seenWatch();
   else {await gate;phoneReturned=true;}
   return new Response('',{status:200});
  }));
  const running=upload(listener,event,{...testEnv,WATCH_PHONE_HEAD_START_PARENT_ID:parent.deviceId,WATCH_PHONE_HEAD_START_MS:'350'});
  let timer:ReturnType<typeof setTimeout>|undefined;
  try {
   await Promise.race([watchStarted,new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(new Error('Watch held behind phone response')),3000);})]);
   expect(phoneReturned).toBe(false);expect(pushRequests).toHaveLength(2);
  }finally{if(timer!==undefined)clearTimeout(timer);release();await running;}
 });
 it('keeps real crying and reminders on parallel delivery under the corrected test-only flag',async()=>{
  const {parent,listener}=await setup(),configured={...testEnv,PHONE_HEAD_START_TEST_PARENT_ID:parent.deviceId};
  mockPush(200,2);await upload(listener,alert(listener),configured);
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+10000);mockPush(200,2);await runReminder(configured,parent.deviceId);
  expect(pushRequests).toHaveLength(4);
  const rows=await env.DB.prepare("SELECT details FROM diagnostics WHERE operation='dispatch' AND target='watch'").all<{details:string}>();
  expect(rows.results.length).toBeGreaterThanOrEqual(2);
  for(const row of rows.results)expect(JSON.parse(row.details).coordination_mode).toBeUndefined();
 });
 it.each(['phone','watch'] as const)('does not replay an accepted %s target or wait on its retry',async accepted=>{
  const {parent,listener}=await setup(),event={...alert(listener),isTest:true};mockPush(200,2);await call('listener/event',listener,event);
  const states={phone:'pending',watch:'pending'};states[accepted]='sent';
  await env.DB.prepare("UPDATE events SET status='sending',attempts=2,delivery_state=? WHERE event_id=?").bind(JSON.stringify(states),event.eventId).run();
  const send=vi.fn(async()=>({status:'sent' as const,httpStatus:200}));
  await deliverToBoth(testEnv,{table:'events',id:event.eventId,parentId:parent.deviceId,attempt:2,state:JSON.stringify(states),phoneToken:'phone',watchToken:'watch',requestId:crypto.randomUUID(),phoneHeadStartMS:350,send});
  expect(send).toHaveBeenCalledTimes(1);expect(send.mock.calls[0]).toHaveLength(4);
  expect((send.mock.calls as unknown as unknown[][])[0][0]).toBe(accepted==='phone'?'watch':'phone');
  expect((send.mock.calls as unknown as unknown[][])[0][3]).toBeUndefined();
 });
});

describe('configurable delayed alert tests',()=>{
 const options=(overrides:Record<string,unknown>={})=>({alarmKit:false,phone:true,watch:true,repeatInterval:5,count:1,
  sharedCollapseIDs:false,distinctRequestIDs:false,coalesceRepeats:false,groupNotifications:true,phoneHeadStartMS:0,...overrides});
 async function setup(){
  const pair=await paired();
  expect((await call('device/push-token',pair.parent,{token:'a'.repeat(64)})).status).toBe(200);
  expect((await call('device/watch-push-token',pair.parent,{token:'b'.repeat(64)})).status).toBe(200);
  expect((await call('silent-watch-alarms',pair.parent,{enabled:true})).status).toBe(200);
  const record=await env.DB.prepare('SELECT created_at FROM pairs WHERE parent_id=?').bind(pair.parent.deviceId).first<{created_at:number}>();
  const stub=env.ALERT_TESTS.get(env.ALERT_TESTS.idFromName(`${pair.parent.deviceId}|${pair.listener.deviceId}|${record!.created_at}`));
  return {...pair,stub};
 }
 async function fire(stub:DurableObjectStub){
  await runInDurableObject(stub,async(_instance,state)=>{
   const session=await state.storage.get<{nextAt:string}>('session');
   session!.nextAt=new Date(Date.now()-1).toISOString();
   await state.storage.put('session',session);await state.storage.setAlarm(Date.now()+60000);
  });
  await runDurableObjectAlarm(stub);
 }
 const requests=()=>pushRequests.map(({init})=>({headers:new Headers(init!.headers),body:JSON.parse(init!.body as string)}));
 it('schedules once, recovers from either phone, and sends selected routes after the delay',async()=>{
  const {parent,listener,stub}=await setup(),id=crypto.randomUUID();
  const before=Date.now();
  const response=await call('alert-test',parent,{id,configuration:options()});
  expect(response.status).toBe(200);
  const {session}=await response.json() as {session:{startsAt:string;id:string;state:string}};
  expect(Date.parse(session.startsAt)).toBeGreaterThanOrEqual(before+10000);
  expect(pushRequests).toHaveLength(0);
  expect((await call('alert-test',parent,{id,configuration:options()})).status).toBe(200);
  expect((await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options()})).status).toBe(409);
  expect(await (await call('alert-test',listener,undefined,'GET')).json()).toMatchObject({session:{id,state:'scheduled'}});
  mockPush(200,2);await fire(stub);
  const sent=requests();expect(sent).toHaveLength(2);
  expect(sent[0].headers.get('apns-collapse-id')).toMatch(/^phone:/);
  expect(sent[1].headers.get('apns-collapse-id')).toMatch(/^watch:/);
  expect(sent[0].body.eventId).toBe(sent[1].body.eventId);
  expect(sent[0].body.aps['thread-id']).toBe(id);
  expect(sent[0].body.isTest).toBe(true);
  expect(await (await call('alert-test',parent,undefined,'GET')).json()).toMatchObject({session:{state:'completed',completedCount:1}});
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {notificationRelevance:{testEventIDs:string[]}};
  expect(status.notificationRelevance.testEventIDs).toContain(sent[0].body.eventId);
  expect((await call('alert/acknowledge',parent,{eventId:sent[0].body.eventId})).status).toBe(200);
 });
 it.each([
  [{phone:true,watch:false,alarmKit:false},1],
  [{phone:false,watch:true,alarmKit:false},1],
  [{phone:false,watch:false,alarmKit:true},1],
  [{phone:true,watch:true,alarmKit:true},3]
 ] as const)('uses only the selected destinations: %j',async(selection,total)=>{
  const {parent,stub}=await setup();
  expect((await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options(selection)})).status).toBe(200);
  mockPush(200,total);await fire(stub);
  const sent=requests();expect(sent).toHaveLength(total);
  expect(sent.filter(r=>r.headers.get('apns-topic')!.endsWith('.watchkitapp'))).toHaveLength(selection.watch?1:0);
  expect(sent.filter(r=>r.body.silentCryAlarm)).toHaveLength(selection.alarmKit?1:0);
  if(selection.alarmKit){
   // The same AlarmKit marker as a real cry, labelled as a test.
   const wake=sent.find(r=>r.body.silentCryAlarm)!;
   expect(wake.body.isTest).toBe(true);expect(wake.body.silentAlarmTest).toBeUndefined();
   expect(wake.body.aps.sound).toBeUndefined();expect(wake.body.aps['content-available']).toBe(1);
   expect(wake.body.configuredAlertTest).toBe(true);expect(wake.body.alarmCycleId).toBeUndefined();
   expect(wake.headers.get('apns-collapse-id')).toMatch(/^alarm:/);
  }
 });
 it('applies the Parent alarm methods to AlarmKit tests and refuses when none is selected',async()=>{
  const {parent,listener,stub}=await setup();
  expect((await call('silent-watch-alarms',parent,{enabled:true,appWake:false,extension:false})).status).toBe(200);
  expect((await call('alert-test',listener,{id:crypto.randomUUID(),configuration:options({alarmKit:true})})).status).toBe(409);
  expect((await call('silent-watch-alarms',parent,{enabled:true,appWake:false,extension:true})).status).toBe(200);
  expect((await call('alert-test',listener,{id:crypto.randomUUID(),configuration:options({phone:false,watch:false,alarmKit:true})})).status).toBe(200);
  mockPush(200,1);await fire(stub);
  const [wake]=requests();
  expect(wake.body).toMatchObject({alarmExtension:true,isTest:true,aps:{'mutable-content':1}});
  expect(wake.body.silentCryAlarm).toBeUndefined();expect(wake.body.aps['content-available']).toBeUndefined();
 });
 it('refuses an AlarmKit test while the Parent has Silent Watch alarms off',async()=>{
  const {parent,listener}=await setup();
  expect((await call('silent-watch-alarms',parent,{enabled:false})).status).toBe(200);
  const response=await call('alert-test',listener,{id:crypto.randomUUID(),configuration:options({alarmKit:true})});
  expect(response.status).toBe(409);
  expect(((await response.json()) as {error:string}).error).toContain('Silent Watch alarms');
  expect((await call('alert-test',listener,{id:crypto.randomUUID(),configuration:options()})).status).toBe(200);
 });
 it('shares or separates notification IDs independently from transport IDs and thread grouping',async()=>{
  const {parent,stub}=await setup();
  expect((await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options({sharedCollapseIDs:true,distinctRequestIDs:true,groupNotifications:false})})).status).toBe(200);
  mockPush(200,2);await fire(stub);const [phone,watch]=requests();
  expect(phone.headers.get('apns-collapse-id')).toBe(watch.headers.get('apns-collapse-id'));
  expect(phone.headers.get('apns-id')).not.toBe(watch.headers.get('apns-id'));
  expect(phone.body.aps['thread-id']).toBeUndefined();
 });
 it.each([true,false])('coalesces repeat notification IDs only when selected: %s',async(coalesceRepeats)=>{
  const {listener,stub}=await setup(),id=crypto.randomUUID();
  expect((await call('alert-test',listener,{id,configuration:options({watch:false,count:2,coalesceRepeats})})).status).toBe(200);
  mockPush(200);await fire(stub);
  mockPush(200);await fire(stub);
  const [first,second]=requests();expect(first.body.eventId).not.toBe(second.body.eventId);
  expect(first.body.episodeId).toBe(second.body.episodeId);
  if(coalesceRepeats)expect(first.headers.get('apns-collapse-id')).toBe(second.headers.get('apns-collapse-id'));
  else expect(first.headers.get('apns-collapse-id')).not.toBe(second.headers.get('apns-collapse-id'));
  expect(await (await call('alert-test',listener,undefined,'GET')).json()).toMatchObject({session:{state:'completed',completedCount:2}});
 });
 it('allows interactive testing beyond the old sixty-start budget',async()=>{
  const {parent}=await setup(),id=crypto.randomUUID();
  const key=await sha256(`${testEnv.PAIRING_PEPPER}|alert-test|${parent.deviceId}`);
  await env.DB.prepare('INSERT OR REPLACE INTO rate_limits(key,window,attempts) VALUES(?,?,60)')
   .bind(key,Math.floor(Date.now()/1000/600)).run();
  expect((await call('alert-test',parent,{id,configuration:options()})).status).toBe(200);
  expect((await call('alert-test/stop',parent,{id})).status).toBe(200);
  expect(pushRequests).toHaveLength(0);
 });
 it('allows the 600th start without consuming ordinary device or control budgets',async()=>{
  const {parent}=await setup(),id=crypto.randomUUID(),window=Math.floor(Date.now()/1000/600);
  const startKey=await sha256(`${testEnv.PAIRING_PEPPER}|alert-test|${parent.deviceId}`);
  const deviceKey=await sha256(`${testEnv.PAIRING_PEPPER}|device|${parent.deviceId}`);
  await env.DB.batch([
   env.DB.prepare('INSERT OR REPLACE INTO rate_limits(key,window,attempts) VALUES(?,?,599)').bind(startKey,window),
   env.DB.prepare('INSERT OR REPLACE INTO rate_limits(key,window,attempts) VALUES(?,?,600)').bind(deviceKey,window)
  ]);
  expect((await call('alert-test',parent,{id,configuration:options()})).status).toBe(200);
  const limited=await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options()});
  expect(limited.status).toBe(429);
  expect((await limited.json() as {error:string}).error).toContain('600 starts per 10 minutes');
  expect(await (await call('alert-test',parent,undefined,'GET')).json()).toMatchObject({session:{id,state:'scheduled'}});
  expect(await (await call('alert-test/stop',parent,{id})).json()).toMatchObject({session:{state:'stopped'}});
  expect((await env.DB.prepare('SELECT attempts FROM rate_limits WHERE key=?').bind(deviceKey).first<{attempts:number}>())?.attempts).toBe(600);
  expect((await call('listener/status',parent,undefined,'GET')).status).toBe(429); // Normal request protection remains intact.
  expect(pushRequests).toHaveLength(0);
 });
 it('gives a specific cooldown while leaving status and Stop available at the new limit',async()=>{
  const {parent,stub}=await setup(),id=crypto.randomUUID();
  expect((await call('alert-test',parent,{id,configuration:options()})).status).toBe(200);
  const key=await sha256(`${testEnv.PAIRING_PEPPER}|alert-test|${parent.deviceId}`);
  await env.DB.prepare('UPDATE rate_limits SET attempts=600 WHERE key=?').bind(key).run();
  const response=await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options()});
  expect(response.status).toBe(429);
  expect((await response.json() as {error:string}).error).toMatch(/600 starts per 10 minutes.*Try again in \d+ seconds.*No new test was scheduled/);
  expect(await (await call('alert-test',parent,undefined,'GET')).json()).toMatchObject({session:{id,state:'scheduled'}});
  expect(await (await call('alert-test/stop',parent,{id})).json()).toMatchObject({session:{state:'stopped'}});
  await runDurableObjectAlarm(stub);expect(pushRequests).toHaveLength(0);
 });
 it('stops before the first tick from either phone and ignores stale stop IDs',async()=>{
  const {parent,listener,stub}=await setup(),id=crypto.randomUUID();
  await call('alert-test',parent,{id,configuration:options({count:5})});
  expect(await (await call('alert-test/stop',listener,{id:crypto.randomUUID()})).json()).toMatchObject({session:{state:'scheduled'}});
  expect(await (await call('alert-test/stop',listener,{id})).json()).toMatchObject({session:{state:'stopped'}});
  await runDurableObjectAlarm(stub);expect(pushRequests).toHaveLength(0);
 });
 it('stops on uncertain delivery without retrying an accepted sibling or sending later rounds',async()=>{
  const {parent,stub}=await setup();
  await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options({count:5})});
  mockPush(200);pushResponses.push(new Error('Connection lost'));
  await fire(stub);
  expect(await (await call('alert-test',parent,undefined,'GET')).json()).toMatchObject({session:{state:'failed',completedCount:1}});
  await runDurableObjectAlarm(stub);expect(pushRequests).toHaveLength(2);
 });
 it('never replays an interrupted reserved round',async()=>{
  const {parent,stub}=await setup();
  await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options({count:5})});
  await runInDurableObject(stub,async(_instance,state)=>{
   const session=await state.storage.get<Record<string,unknown>>('session');
   await state.storage.put('session',{...session,dispatching:true,completedCount:1});
  });
  await fire(stub);expect(pushRequests).toHaveLength(0);
  expect(await (await call('alert-test',parent,undefined,'GET')).json()).toMatchObject({session:{state:'failed',completedCount:1}});
 });
 it('cancels a session when pairing changes, before sending any push',async()=>{
  const {parent,stub}=await setup();
  await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options()});
  await env.DB.prepare('DELETE FROM pairs WHERE parent_id=?').bind(parent.deviceId).run();
  await fire(stub);expect(pushRequests).toHaveLength(0);
 });
 it.each([
  {phone:false,watch:false,alarmKit:false},{repeatInterval:0},{repeatInterval:0.5},{count:21},{count:0},
  {alarmKit:'yes'},{phoneHeadStartMS:999},{phone:false,phoneHeadStartMS:500},{unexpected:true}
 ])('rejects invalid configuration %j',async invalid=>{
  const {parent}=await setup();
  expect((await call('alert-test',parent,{id:crypto.randomUUID(),configuration:options(invalid)})).status).toBe(400);
 });
});

describe('unexpected Listener monitoring stops',()=>{
 async function ready(){
  const pair=await paired();await call('device/push-token',pair.parent,{token:'ab'.repeat(32)});
  await env.DB.prepare('UPDATE pairs SET created_at=created_at-600000 WHERE parent_id=?').bind(pair.parent.deviceId).run();
  return pair;
 }
 const beat=(listener:TestDevice,monitoring:boolean,timestamp=new Date().toISOString())=>({listenerId:listener.deviceId,timestamp,monitoring,powerConnected:true,state:'quiet',episodes:[]});
 function failure(listener:TestDevice,at=new Date()):Alert {
  return {eventId:crypto.randomUUID(),episodeId:crypto.randomUUID(),listenerId:listener.deviceId,type:'monitoring_failed',cryStartedAt:at.toISOString(),durationSeconds:0,createdAt:at.toISOString(),isRepeat:false};
 }
 it('repeats until the Listener monitors again, including after Snooze',async()=>{
  const {parent,listener}=await ready();
  await call('listener/heartbeat',listener,beat(listener,true));
  const stopped=failure(listener);mockPush();
  expect(await (await call('listener/event',listener,stopped)).json()).toEqual({status:'sent'});
  await call('listener/heartbeat',listener,beat(listener,false));
  const body=JSON.parse(String(pushRequests[0].init?.body));
  expect(body).toMatchObject({type:'monitoring_failed',aps:{alert:{title:'Nursery monitoring stopped'},'interruption-level':'time-sensitive'}});
  const start=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(start+6000);
  mockPush();expect(await runReminder(testEnv,parent.deviceId)).toBe(true);expect(pushRequests).toHaveLength(2);
  expect(JSON.parse(String(pushRequests[1].init?.body))).toMatchObject({type:'monitoring_failed',episodeId:stopped.episodeId});
  const latest=JSON.parse(String(pushRequests[1].init?.body)) as Alert;
  expect((await call('alert/acknowledge',parent,{eventId:latest.eventId})).status).toBe(200);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(true);expect(pushRequests).toHaveLength(2);
  const muted=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  // No Listener execution is needed to resume after Snooze.
  clock.mockReturnValue(muted!.alerts_muted_until+1);mockPush();
  expect(await runReminder(testEnv,parent.deviceId)).toBe(true);expect(pushRequests).toHaveLength(3);
  clock.mockRestore();
  await call('listener/heartbeat',listener,beat(listener,true));
  vi.spyOn(Date,'now').mockReturnValue(muted!.alerts_muted_until+20000);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);expect(pushRequests).toHaveLength(3);
  const open=await env.DB.prepare("SELECT COUNT(*) AS count FROM events WHERE resolved_at IS NULL AND json_extract(payload,'$.type')='monitoring_failed'").first();
  expect(open).toEqual({count:0});
 });
 it('is not retired by a monitoring heartbeat sent before the stop, and stays quiet once monitoring resumed',async()=>{
  const {parent,listener}=await ready();
  const at=new Date();
  await call('listener/heartbeat',listener,beat(listener,true,new Date(at.getTime()-5000).toISOString()));
  mockPush();await call('listener/event',listener,failure(listener,at));
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+6000);
  mockPush();expect(await runReminder(testEnv,parent.deviceId)).toBe(true);expect(pushRequests).toHaveLength(2);
  vi.restoreAllMocks();
  // An upload delayed past the restart heartbeat is retired without a push.
  await call('listener/heartbeat',listener,beat(listener,true,new Date(at.getTime()+60000).toISOString()));
  const late=failure(listener,new Date(at.getTime()+30000));
  expect(await (await call('listener/event',listener,late)).json()).toEqual({status:'resolved'});
  expect(pushRequests).toHaveLength(2);
 });
 it('suppresses the one-shot stopped notice while the persistent alert is open, and ends with a person\'s Stop',async()=>{
  const {parent,listener}=await ready();
  await call('listener/heartbeat',listener,beat(listener,true));await flushConnections(testEnv);
  mockPush();await call('listener/event',listener,failure(listener));
  await call('listener/heartbeat',listener,beat(listener,false));
  await flushConnections(testEnv);expect(pushRequests).toHaveLength(1);
  expect((await call('monitoring',listener,{id:crypto.randomUUID(),enabled:false})).status).toBe(200);
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+6000);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(false);expect(pushRequests).toHaveLength(1);
 });
 it('rejects a test-marked monitoring failure',async()=>{
  const {listener}=await ready();
  expect((await call('listener/event',listener,{...failure(listener),isTest:true})).status).toBe(400);
 });
});

describe('late Snooze delivery',()=>{
 async function crying(){
  const pair=await paired();await call('device/push-token',pair.parent,{token:'ab'.repeat(32)});
  await env.DB.prepare('UPDATE pairs SET created_at=created_at-3600000 WHERE parent_id=?').bind(pair.parent.deviceId).run();
  const event=alert(pair.listener);mockPush();await call('listener/event',pair.listener,event);
  return {...pair,event};
 }
 it('snoozes from the tap time, so an expired Snooze cannot silence a newer episode',async()=>{
  const {parent,listener,event}=await crying();
  const now=Date.now(),clock=vi.spyOn(Date,'now').mockReturnValue(now+20*60000);
  const later=now+20*60000,newer={...alert(listener),cryStartedAt:new Date(later-300000).toISOString(),createdAt:new Date(later).toISOString()};
  mockPush();await call('listener/event',listener,newer);expect(pushRequests).toHaveLength(2);
  expect((await call('alert/acknowledge',parent,{eventId:event.eventId,actedAt:new Date(now+1000).toISOString()})).status).toBe(200);
  const saved=await env.DB.prepare('SELECT event_id,acknowledged_at FROM events').all<{event_id:string;acknowledged_at:string|null}>();
  expect(saved.results.find(e=>e.event_id===event.eventId)?.acknowledged_at).not.toBeNull();
  expect(saved.results.find(e=>e.event_id===newer.eventId)?.acknowledged_at).toBeNull();
  expect(await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first()).toEqual({alerts_muted_until:0});
  clock.mockReturnValue(now+20*60000+6000);mockPush();
  expect(await runReminder(testEnv,parent.deviceId)).toBe(true);expect(pushRequests).toHaveLength(3);
 });
 it('keeps a snooze that is still running from the tap, and never shortens a longer one',async()=>{
  const {parent,event}=await crying();
  const now=Date.now();
  expect((await call('alert/acknowledge',parent,{eventId:event.eventId,actedAt:new Date(now-30000).toISOString()})).status).toBe(200);
  const first=await env.DB.prepare('SELECT alerts_muted_until,alerts_muted_at FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number;alerts_muted_at:number}>();
  expect(first!.alerts_muted_until).toBeGreaterThanOrEqual(now+29000);expect(first!.alerts_muted_until).toBeLessThanOrEqual(now+31000);
  expect((await call('alert/acknowledge',parent,{eventId:event.eventId})).status).toBe(200);
  expect(await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first()).toEqual({alerts_muted_until:first!.alerts_muted_until});
  expect((await call('alert/acknowledge',parent,{eventId:event.eventId,actedAt:'not-a-date'})).status).toBe(200); // already acknowledged: no-op
 });
 it('clamps a future tap time to the server clock',async()=>{
  const {parent,event}=await crying();
  const now=Date.now();
  expect((await call('alert/acknowledge',parent,{eventId:event.eventId,actedAt:new Date(now+3600000).toISOString()})).status).toBe(200);
  const saved=await env.DB.prepare('SELECT alerts_muted_until FROM devices WHERE id=?').bind(parent.deviceId).first<{alerts_muted_until:number}>();
  expect(saved!.alerts_muted_until).toBeLessThanOrEqual(Date.now()+61000);
 });
});

describe('two caregiver families',()=>{
 async function family(){
  const {parent,listener}=await paired(),partner=device('parent');await register(partner);
  const invitation=await(await call('caregivers/invite',parent,{name:'Jordan'})).json() as {code:string};
  expect((await call('caregivers/join',partner,{code:invitation.code,name:'Alex'})).status).toBe(200);
  return {parent,listener,partner,invitation};
 }
 async function status(d:TestDevice){return await(await call('listener/status',d,undefined,'GET')).json() as any;}
 async function tokens(d:TestDevice,letter:string){
  expect((await call('device/push-token',d,{token:letter.repeat(64)})).status).toBe(200);
  expect((await call('device/watch-push-token',d,{token:(letter==='a'?'b':'d').repeat(64)})).status).toBe(200);
 }
 it('joins once, shares nursery configuration, and keeps per-person opt-outs through exclusive role swaps',async()=>{
  const {parent,partner,listener,invitation}=await family();
  const owner=await status(parent),member=await status(partner);
  expect(member.paired).toBe(true);expect(member.listenerId).toBe(listener.deviceId);
  expect(member.caregiverDuty.myId).toBe(partner.deviceId);
  expect(owner.caregiverDuty.primaryId).toBe(parent.deviceId);
  expect((await call('caregivers/join',partner,{code:invitation.code,name:'Alex'})).status).toBe(200);
  let duty=owner.caregiverDuty;
  const update=async(value:object)=>{const r=await call('caregivers/duty',partner,{revision:duty.revision,...value});expect(r.status).toBe(200);duty=await r.json() as any;};
  await update({caregiverId:partner.deviceId,secondaryEnabled:false});
  await update({primaryId:partner.deviceId});await update({primaryId:parent.deviceId});
  expect(duty.caregivers.find((c:any)=>c.id===partner.deviceId).secondaryEnabled).toBe(false);
  expect((await call('caregivers/duty',parent,{revision:owner.caregiverDuty.revision,primaryId:partner.deviceId})).status).toBe(409);
  const outsider=device('parent');await register(outsider);
  expect((await call('caregivers/duty',outsider,{revision:duty.revision,primaryId:outsider.deviceId})).status).toBe(409);
  expect((await call('settings',partner,{...defaultConfiguration,alertDuration:120})).status).toBe(200);
  expect((await status(parent)).configuration.alertDuration).toBe(120);
 });
 it('delivers primary phone and Watch first, then secondary after the delay; either person snoozes the family',async()=>{
  const {parent,partner,listener}=await family();await tokens(parent,'a');await tokens(partner,'c');
  const event=alert(listener);mockPush(200,2);
  expect((await call('listener/event',listener,event)).status).toBe(200);
  expect(pushRequests).toHaveLength(2);
  expect(pushRequests.map(p=>p.url)).toEqual(expect.arrayContaining([expect.stringContaining('a'.repeat(64)),expect.stringContaining('b'.repeat(64))]));
  expect((await status(partner)).alerts).toHaveLength(0);
  const saved=await env.DB.prepare('SELECT caregiver_plan FROM events WHERE event_id=?').bind(event.eventId).first<{caregiver_plan:string}>();
  const plan=JSON.parse(saved!.caregiver_plan);expect(plan.primary).toBe(parent.deviceId);
  const advanced=Date.now()+121000;vi.spyOn(Date,'now').mockReturnValue(advanced);mockPush(200,4);
  expect(await runReminder(testEnv,parent.deviceId)).toBe(true);
  expect(pushRequests).toHaveLength(6);
  expect((await status(partner)).alerts.length).toBeGreaterThan(0);
  const latest=(await status(partner)).alerts[0].eventId;
  expect((await call('alert/acknowledge',partner,{eventId:latest})).status).toBe(200);
  expect(Date.parse((await status(parent)).alertsMutedUntil)).toBeGreaterThan(advanced);
  expect(Date.parse((await status(partner)).alertsMutedUntil)).toBeGreaterThan(advanced);
  expect((await status(parent)).snoozedBy).toBe(partner.deviceId);
  const before=pushRequests.length;expect(await runReminder(testEnv,parent.deviceId)).toBe(true);expect(pushRequests).toHaveLength(before);
 });
 it('honors secondary opt-out immediately, allows a new primary, and revokes only the departing partner',async()=>{
  const {parent,partner,listener}=await family();await tokens(parent,'a');await tokens(partner,'c');
  let duty=(await status(parent)).caregiverDuty;
  expect((await call('caregivers/duty',parent,{revision:duty.revision,primaryId:partner.deviceId,caregiverId:parent.deviceId,secondaryEnabled:false})).status).toBe(200);
  mockPush(200,2);const event=alert(listener);expect((await call('listener/event',listener,event)).status).toBe(200);
  expect(pushRequests.map(p=>p.url)).toEqual(expect.arrayContaining([expect.stringContaining('c'.repeat(64)),expect.stringContaining('d'.repeat(64))]));
  expect((await status(parent)).alerts).toHaveLength(0);
  const secondPartner=device('parent');await register(secondPartner);
  expect((await call('caregivers/invite',parent,{name:'Jordan'})).status).toBe(409);
  expect((await call('pairing/remove',partner)).status).toBe(200);
  expect((await status(partner)).paired).toBe(false);expect((await status(parent)).paired).toBe(true);
  expect((await status(parent)).caregiverDuty.primaryId).toBe(parent.deviceId);
 });
 it('rejects a used invitation for another device and rejects cross-family snooze',async()=>{
  const {parent,partner,listener,invitation}=await family();const outsider=device('parent');await register(outsider);
  expect((await call('caregivers/join',outsider,{code:invitation.code,name:'Third'})).status).toBe(409);
  expect((await call('pairing/create',partner)).status).toBe(409);
  const event=alert(listener);expect((await call('listener/event',listener,event)).status).toBe(200);
  expect((await call('alert/acknowledge',outsider,{eventId:event.eventId})).status).toBe(404);
  expect((await status(parent)).alertsMutedUntil).toBeNull();
 });
 it('commits only the winning preference in concurrent revision-qualified updates',async()=>{
  const {parent,partner}=await family();const revision=(await status(parent)).caregiverDuty.revision;
  const responses=await Promise.all([false,true].map(enabled=>call('caregivers/duty',parent,{revision,caregiverId:partner.deviceId,secondaryEnabled:enabled})));
  expect(responses.map(r=>r.status).sort()).toEqual([200,409]);
  const winner=responses.findIndex(r=>r.status===200),duty=(await status(parent)).caregiverDuty;
  expect(duty.caregivers.find((c:any)=>c.id===partner.deviceId).secondaryEnabled).toBe([false,true][winner]);
 });
 it('does not send another destination after a caregiver snoozes during dispatch',async()=>{
  const {parent,listener}=await family();await tokens(parent,'a');
  const event=alert(listener);let sends=0;
  vi.mocked(fetch).mockImplementationOnce(async()=>{
   sends++;expect((await call('alert/acknowledge',parent,{eventId:event.eventId})).status).toBe(200);
   return new Response(null,{status:200});
  });
  expect((await call('listener/event',listener,event)).status).toBe(200);
  expect(sends).toBe(1);
  expect((await status(parent)).alertsMutedUntil).not.toBeNull();
  const sent=await env.DB.prepare("SELECT COUNT(*) AS count FROM caregiver_deliveries WHERE state='sent'").first<{count:number}>();expect(sent?.count).toBe(1);
 });
 it('suppresses a delayed family alert when the Listener already confirmed quiet',async()=>{
  const {parent,listener}=await family();await tokens(parent,'a');const event=alert(listener);
  const pair=await env.DB.prepare('SELECT created_at FROM pairs WHERE parent_id=?').bind(parent.deviceId).first<{created_at:number}>();
  await env.DB.prepare('INSERT INTO resolved_episodes(parent_id,listener_id,pair_created_at,episode_id,resolved_at) VALUES(?,?,?,?,?)').bind(parent.deviceId,listener.deviceId,pair!.created_at,event.episodeId,new Date().toISOString()).run();
  const response=await call('listener/event',listener,event);expect(response.status).toBe(200);expect((await response.json() as any).status).toBe('resolved');expect(pushRequests).toHaveLength(0);
 });

 it('tests the invited caregiver’s own phone and Watch rather than the original Parent’s devices',async()=>{
  const {parent,partner,listener}=await family();await tokens(partner,'c');
  expect((await call('silent-watch-alarms',partner,{enabled:true})).status).toBe(200);
  mockPush(200);expect((await call('watch-test/push',partner)).status).toBe(200);expect(pushRequests[0].url).toContain('d'.repeat(64));
  const configuration={alarmKit:false,phone:true,watch:true,repeatInterval:5,count:1,sharedCollapseIDs:false,distinctRequestIDs:false,coalesceRepeats:false,groupNotifications:false,phoneHeadStartMS:0};
  expect((await call('alert-test',partner,{id:crypto.randomUUID(),configuration})).status).toBe(200);
  const record=await env.DB.prepare('SELECT created_at FROM pairs WHERE parent_id=?').bind(parent.deviceId).first<{created_at:number}>();
  const stub=env.ALERT_TESTS.get(env.ALERT_TESTS.idFromName(`${parent.deviceId}|${listener.deviceId}|${record!.created_at}|${partner.deviceId}`));
  await runInDurableObject(stub,async(_instance,state)=>{
   const session=await state.storage.get<{nextAt:string}>('session');session!.nextAt=new Date(Date.now()-1).toISOString();
   await state.storage.put('session',session);await state.storage.setAlarm(Date.now()+60000);
  });
  mockPush(200,2);await runDurableObjectAlarm(stub);
  expect(pushRequests.slice(1).map(r=>r.url)).toEqual(expect.arrayContaining([expect.stringContaining('c'.repeat(64)),expect.stringContaining('d'.repeat(64))]));
  expect((await status(parent)).alerts).toHaveLength(0);expect((await status(partner)).alerts).toHaveLength(1);
 });

 it('starts escalation from server dispatch rather than a delayed upload’s client timestamp',async()=>{
  const {parent,partner,listener}=await family();await tokens(parent,'a');await tokens(partner,'c');
  const began=Date.now(),pairedAt=began-3600000;
  await env.DB.batch([env.DB.prepare('UPDATE pairs SET created_at=? WHERE parent_id=?').bind(pairedAt,parent.deviceId),env.DB.prepare('UPDATE caregiver_families SET pair_created_at=? WHERE owner_id=?').bind(pairedAt,parent.deviceId)]);
  const event={...alert(listener),createdAt:new Date(began-180000).toISOString(),cryStartedAt:new Date(began-480000).toISOString()};mockPush(200,2);
  expect((await call('listener/event',listener,event)).status).toBe(200);expect(pushRequests).toHaveLength(2);
  expect((await status(partner)).alerts).toHaveLength(0);
  const row=await env.DB.prepare('SELECT caregiver_plan FROM events WHERE event_id=?').bind(event.eventId).first<{caregiver_plan:string}>();
  expect(JSON.parse(row!.caregiver_plan).started).toBeGreaterThanOrEqual(began);
 });

 it('keeps silent-alarm recovery receipts separate for the invited caregiver',async()=>{
  const {parent,partner,listener}=await family();await tokens(parent,'a');await tokens(partner,'c');
  expect((await call('device/push-token',partner,{token:'c'.repeat(64),alarmReceiptsVersion:1})).status).toBe(200);
  expect((await call('silent-watch-alarms',partner,{enabled:true})).status).toBe(200);
  const duty=(await status(parent)).caregiverDuty;
  expect((await call('caregivers/duty',partner,{revision:duty.revision,primaryId:partner.deviceId})).status).toBe(200);
  const event=alert(listener);mockPush(200,2);expect((await call('listener/event',listener,event)).status).toBe(200);
  const push=JSON.parse(pushRequests.find(p=>p.url.includes('c'.repeat(64)))!.init!.body as string);
  expect(push.silentCryAlarm).toBe(true);expect(push.alarmCycleId).toBeDefined();
  const receipt={episodeId:event.episodeId,eventId:event.eventId,cycleId:push.alarmCycleId};
  expect((await call('alarm/scheduled',partner,receipt)).status).toBe(200);
  expect((await call('alarm/scheduled',parent,receipt)).status).toBe(409);
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+6000);mockPush(200,2);await runReminder(testEnv,parent.deviceId);
  const repeat=JSON.parse(pushRequests.slice(2).find(p=>p.url.includes('c'.repeat(64)))!.init!.body as string);
  expect(repeat.silentCryAlarm).toBeUndefined();
 });

 it.each(['pairing/remove','device/delete'])('clears family membership when the nursery calls %s and allows a fresh invitation',async(route)=>{
  const {parent,partner,listener}=await family();
  expect((await call(route,listener)).status).toBe(200);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM caregiver_families').first('n')).toBe(0);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM caregiver_invites').first('n')).toBe(0);
  expect((await status(partner)).paired).toBe(false);
  const replacement=device('listener');await register(replacement);
  const nursery=await(await call('pairing/create',parent)).json() as {code:string};
  expect((await call('pairing/claim',replacement,{code:nursery.code})).status).toBe(200);
  const invite=await(await call('caregivers/invite',parent,{name:'Jordan'})).json() as {code:string};
  expect((await call('caregivers/join',partner,{code:invite.code,name:'Alex'})).status).toBe(200);
 });
 it('does not send secondary notifications after an opt-out during primary delivery',async()=>{
  const {parent,partner,listener}=await family();await tokens(parent,'a');await tokens(partner,'c');
  const event=alert(listener);mockPush(200,2);await call('listener/event',listener,event);
  vi.spyOn(Date,'now').mockReturnValue(Date.now()+121000);
  const duty=(await status(parent)).caregiverDuty;let changed=false;
  vi.mocked(fetch).mockImplementation(async(input,init)=>{
   pushRequests.push({url:String(input),init});
   if(!changed){changed=true;expect((await call('caregivers/duty',parent,{revision:duty.revision,caregiverId:partner.deviceId,secondaryEnabled:false})).status).toBe(200);}
   return new Response(null,{status:200});
  });
  await runReminder(testEnv,parent.deviceId);
  expect(pushRequests).toHaveLength(4);
  expect(pushRequests.every(p=>!p.url.includes('c'.repeat(64))&&!p.url.includes('d'.repeat(64)))).toBe(true);
 });
 it('does not dispatch family notifications from a claim reply received after its lease',async()=>{
  const {parent,listener}=await family();await tokens(parent,'a');const event=alert(listener);
  // Prepare an unsent event without making an APNs request.
  await env.DB.prepare('UPDATE devices SET push_token=NULL,watch_push_token=NULL WHERE id=?').bind(parent.deviceId).run();
  await call('listener/event',listener,event);await tokens(parent,'a');
  await env.DB.prepare("UPDATE events SET status='pending',next_attempt=0 WHERE event_id=?").bind(event.eventId).run();
  const now=Date.now();vi.spyOn(Date,'now').mockReturnValue(now);
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();
   if(sql.startsWith("UPDATE events SET status='sending',claim_id=")&&method==='first')vi.mocked(Date.now).mockReturnValue(now+31000);
   return result;
  });
  vi.mocked(fetch).mockImplementation(async(input,init)=>{pushRequests.push({url:String(input),init});return new Response(null,{status:200});});
  await dispatchEvent({...testEnv,DB:db},event.eventId);expect(pushRequests).toHaveLength(0);
 });
 it('keeps a successful partner disconnect successful when the chart service is unavailable',async()=>{
  const {parent,partner}=await family();
  vi.spyOn(testEnv.LIVE_SOUND,'get').mockImplementation(()=>{throw new Error('Relay unavailable');});
  expect((await call('pairing/remove',partner)).status).toBe(200);
  expect((await status(partner)).paired).toBe(false);expect((await status(parent)).paired).toBe(true);
 });
 it.each(['settings','monitoring','alert/acknowledge','alert/resume','connection-alerts'])('rejects a revoked partner’s in-flight %s mutation',async(route)=>{
  const {parent,partner,listener}=await family();const event=alert(listener);await call('listener/event',listener,event);
  if(route==='alert/resume')await call('alert/acknowledge',parent,{eventId:event.eventId});
  const original=await env.DB.prepare('SELECT config,alerts_muted_until,connection_alerts FROM devices WHERE id=?').bind(parent.deviceId).first();
  const body=route==='settings'?{...defaultConfiguration,alertDuration:120}:route==='monitoring'?{id:crypto.randomUUID(),enabled:false}:route==='alert/acknowledge'?{eventId:event.eventId}:route==='alert/resume'?{expectedUntil:(original as any).alerts_muted_until}:{enabled:false};
  let revoked=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{
   if(!revoked&&(['run','batch'].includes(method))&&(/^(UPDATE devices SET (config|connection_alerts)|INSERT INTO monitoring_commands|INSERT INTO alert_snoozes|UPDATE timeline_events)/.test(sql))){
    revoked=true;expect((await call('pairing/remove',partner)).status).toBe(200);
   }
   return execute();
  });
  const response=await worker.fetch(new Request('https://monitor.test/v1/'+route,{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${partner.deviceId}.${partner.secret}`},body:JSON.stringify(body)}),{...testEnv,DB:db});
  expect(revoked).toBe(true);expect(response.status).toBe(409);
  expect(await env.DB.prepare('SELECT config,alerts_muted_until,connection_alerts FROM devices WHERE id=?').bind(parent.deviceId).first()).toEqual(original);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM monitoring_commands').first('n')).toBe(0);
 });
 it('repairs stale family records from an earlier nursery pairing when inviting again',async()=>{
  const {parent,partner}=await family();
  await env.DB.prepare('UPDATE caregiver_families SET pair_created_at=pair_created_at-1').run();
  const response=await call('caregivers/invite',parent,{name:'Jordan'});expect(response.status).toBe(200);
  const {code}=await response.json() as {code:string};
  expect((await call('caregivers/join',partner,{code,name:'Alex'})).status).toBe(200);
  expect((await status(parent)).caregiverDuty.caregivers).toHaveLength(2);
 });
 it('acknowledges only the requesting caregiver’s tests',async()=>{
  const {parent,partner,listener}=await family();
  const own={...alert(listener),isTest:true},invited={...alert(listener),isTest:true,targetCaregiverId:partner.deviceId};
  for(const event of [own,invited])await env.DB.prepare('INSERT INTO events(event_id,episode_id,listener_id,parent_id,is_repeat,payload,created_at) VALUES(?,?,?,?,0,?,?)').bind(event.eventId,event.episodeId,listener.deviceId,parent.deviceId,JSON.stringify(event),Date.now()).run();
  expect((await call('alert/acknowledge',partner,{eventId:own.eventId})).status).toBe(403);
  expect((await call('alert/acknowledge',partner,{eventId:invited.eventId})).status).toBe(200);
  expect((await status(parent)).alerts.find((e:any)=>e.eventId===own.eventId).acknowledgedAt).toBeNull();
  expect((await status(partner)).alerts.find((e:any)=>e.eventId===invited.eventId).acknowledgedAt).not.toBeNull();
  expect((await status(parent)).alertsMutedUntil).toBeNull();
 });
 it.each(['listener/status','timeline'])('withholds an in-flight %s response after partner revocation',async(route)=>{
  const {parent,partner}=await family();let revoked=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{
   const result=await execute();
   if(!revoked&&method==='first'&&sql.startsWith('SELECT * FROM devices WHERE id=')){
    revoked=true;expect((await call('pairing/remove',partner)).status).toBe(200);
   }
   return result;
  });
  const response=await worker.fetch(new Request('https://monitor.test/v1/'+route,{headers:{authorization:`Bearer ${partner.deviceId}.${partner.secret}`}}),{...testEnv,DB:db});
  expect(revoked).toBe(true);expect(response.status).toBe(409);expect(await response.text()).not.toContain('caregiverDuty');
  expect((await status(parent)).paired).toBe(true);
 });
 it('lets the paired nursery snooze and resume the household without stopping monitoring',async()=>{
  const {parent,partner,listener}=await family(),event=alert(listener);
  expect((await call('listener/heartbeat',listener,{listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring:true,microphoneActive:true,powerConnected:true,state:'quiet',episodes:[]})).status).toBe(200);
  await call('listener/event',listener,event);
  expect((await call('alert/acknowledge',listener,{eventId:event.eventId})).status).toBe(200);
  const owner=await status(parent),member=await status(partner),nursery=await status(listener);
  expect(Date.parse(owner.alertsMutedUntil)).toBeGreaterThan(Date.now());
  expect(member.alertsMutedUntil).toBe(owner.alertsMutedUntil);expect(nursery.alertsMutedUntil).toBe(owner.alertsMutedUntil);
  expect(owner.snoozedBy).toBe(listener.deviceId);expect(nursery.monitoring).toBe(true);expect(nursery.microphoneActive).toBe(true);
  const expectedUntil=Date.parse(nursery.alertsMutedUntil);
  expect((await call('alert/resume',listener,{expectedUntil})).status).toBe(200);
  expect(Date.parse((await status(parent)).alertsMutedUntil)).toBeLessThanOrEqual(Date.now());
  expect((await status(listener)).monitoring).toBe(true);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM monitoring_commands').first('n')).toBe(0);
 });
 it('rejects an unpaired or different nursery and does not let the Listener acknowledge caregiver tests',async()=>{
  const {parent,listener}=await family(),event=alert(listener);await call('listener/event',listener,event);
  const other=await paired(),unpaired=device('listener');await register(unpaired);
  expect((await call('alert/acknowledge',unpaired,{eventId:event.eventId})).status).toBe(409);
  expect((await call('alert/acknowledge',other.listener,{eventId:event.eventId})).status).toBe(404);
  const test={...alert(listener),isTest:true};await call('listener/event',listener,test);
  expect((await call('alert/acknowledge',listener,{eventId:test.eventId})).status).toBe(403);
  expect((await status(parent)).alertsMutedUntil).toBeNull();
 });
 it.each(['alert/acknowledge','alert/resume'])('does not let an in-flight nursery %s affect a replacement pairing',async(route)=>{
  const {parent,listener}=await family(),event=alert(listener);await call('listener/event',listener,event);
  if(route==='alert/resume')await call('alert/acknowledge',parent,{eventId:event.eventId});
  const until=Date.parse((await status(parent)).alertsMutedUntil);let replaced=false;
  const db=interceptDB(async(sql,_args,method,execute)=>{
   if(!replaced&&method==='batch'&&(sql.startsWith('INSERT INTO alert_snoozes')||sql.startsWith('UPDATE timeline_events'))){
    replaced=true;expect((await call('pairing/remove',listener)).status).toBe(200);
    const replacement=device('listener');await register(replacement);
    const {code}=await(await call('pairing/create',parent)).json() as {code:string};
    await call('pairing/claim',replacement,{code});
   }
   return execute();
  });
  const response=await worker.fetch(new Request('https://monitor.test/v1/'+route,{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${listener.deviceId}.${listener.secret}`},body:JSON.stringify(route==='alert/resume'?{expectedUntil:until}:{eventId:event.eventId})}),{...testEnv,DB:db});
  expect(replaced).toBe(true);expect(response.status).toBe(409);
  expect((await status(parent)).alertsMutedUntil).toBeNull();
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM alert_snoozes').first('n')).toBe(0);
 });
 it('invalidates an unused nursery pairing code when a caregiver joins a family',async()=>{
  const {parent,listener}=await paired(),partner=device('parent');await register(partner);
  const nurseryCode=await(await call('pairing/create',partner)).json() as {code:string};
  const invitation=await(await call('caregivers/invite',parent,{name:'Jordan'})).json() as {code:string};
  expect((await call('caregivers/join',partner,{code:invitation.code,name:'Alex'})).status).toBe(200);
  const otherListener=device('listener');await register(otherListener);
  expect((await call('pairing/claim',otherListener,{code:nurseryCode.code})).status).toBe(400);
  expect((await status(partner)).listenerId).toBe(listener.deviceId);
 });

});
