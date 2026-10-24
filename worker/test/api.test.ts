import {runReminder} from '../src/reminders';
import {env,applyD1Migrations,runInDurableObject,runDurableObjectAlarm} from 'cloudflare:test';
import {beforeAll,afterEach,beforeEach,describe,it,expect,vi} from 'vitest';
import worker from '../src/index';
import {defaultConfiguration,type Env,type Alert} from '../src/types';
import {payload,apnsToken} from '../src/apns';
import {encryptToken,decryptToken,sha256} from '../src/security';
import {flushPending} from '../src/alerts';
import {eventReference,recordDiagnostic} from '../src/diagnostics';
import {flushConnections} from '../src/connections';
import {soundFrame} from '../src/live-sound';

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
let pushResponses: (Response | Error)[] = [];
let pushRequests: {url:string;init?:RequestInit}[] = [];
function mockPush(status=200,times=1){
 for(let i=0;i<times;i++)pushResponses.push(new Response(status===200?'':JSON.stringify({reason:'ServiceUnavailable'}),{status}));
}

beforeAll(async()=>{
 await applyD1Migrations(env.DB,env.TEST_MIGRATIONS);
 const key=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']) as CryptoKeyPair;
 const pem=btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.exportKey('pkcs8',key.privateKey) as ArrayBuffer)));
 testEnv={...env,APNS_KEY_ID:'TESTKEY',APNS_TEAM_ID:'TESTTEAM',APNS_PRIVATE_KEY:`-----BEGIN PRIVATE KEY-----\n${pem}\n-----END PRIVATE KEY-----`,APNS_BUNDLE_ID:'com.example.BabyCryMonitor',APNS_ENVIRONMENT:'development'};
});
beforeEach(async()=>{
 await env.DB.batch(['monitoring_commands','alert_snoozes','timeline_events','diagnostics','connection_notices','connection_states','events','heartbeats','pairs','pairing_codes','devices','rate_limits'].map(table=>env.DB.prepare(`DELETE FROM ${table}`)));
 pushResponses=[];pushRequests=[];
 vi.stubGlobal('fetch',vi.fn(async(input:string|URL|Request,init?:RequestInit)=>{
  const url=String(input);expect(url).toMatch(/^https:\/\/api\.sandbox\.push\.apple\.com\/3\/device\//);
  pushRequests.push({url,init});
  const response=pushResponses.shift();if(!response)throw new Error('Unexpected external request');
  if(response instanceof Error)throw response;return response;
 }));
});
afterEach(()=>{try{expect(pushResponses).toHaveLength(0);}finally{vi.unstubAllGlobals();vi.restoreAllMocks();}});

describe('connection alerts, readiness and replacement',()=>{
 const beat=(listener:TestDevice,monitoring=true,appliedConfiguration=defaultConfiguration)=>({listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring,powerConnected:true,state:'quiet',episodes:[],appliedConfiguration});
 async function stale(){await env.DB.prepare('UPDATE heartbeats SET received_at=?').bind(new Date(Date.now()-240000).toISOString()).run();}
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
  const content=JSON.parse(String(pushRequests[0].init?.body));expect(content.connectionState).toBe('offline');expect(content.eventId).toBeUndefined();
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
 it('uses scheduled checks to warn the Watch after three minutes without a heartbeat, even during snooze',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));
  await env.DB.prepare('UPDATE devices SET alerts_muted_until=? WHERE id=?').bind(Date.now()+60000,parent.deviceId).run();
  const check=()=>worker.scheduled({} as ScheduledController,testEnv);
  await env.DB.prepare('UPDATE heartbeats SET received_at=?').bind(new Date(Date.now()-179000).toISOString()).run();
  await check();expect(pushRequests).toHaveLength(0);
  await env.DB.prepare('UPDATE heartbeats SET received_at=?').bind(new Date(Date.now()-181000).toISOString()).run();
  mockPush();await check();await check();
  expect(pushRequests).toHaveLength(1);expect(pushRequests[0].url).toContain('cd'.repeat(32));
  const content=JSON.parse(String(pushRequests[0].init?.body));
  expect(content.connectionState).toBe('offline');
  expect(content.aps.alert.title).toBe('Listener connection lost');
  expect(content.aps.sound).toBe('default');
  expect(content.aps['interruption-level']).toBe('time-sensitive');
  expect((await env.DB.prepare('SELECT status FROM connection_notices').first<{status:string}>())?.status).toBe('sent');
 });
 it('does not replay ambiguous health delivery and cancels obsolete outages',async()=>{
  const {parent,listener}=await paired();await call('connection-alerts',parent,{enabled:true});
  await call('device/push-token',parent,{token:'ab'.repeat(32)});await call('listener/heartbeat',listener,beat(listener));await stale();
  pushResponses.push(new Error('transport unknown'));await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);
  const notice=await env.DB.prepare('SELECT status FROM connection_notices').first<{status:string}>();expect(notice?.status).toBe('uncertain');
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
  mockPush();await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);expect(pushRequests[0].url).toContain('cd'.repeat(32));
  expect(JSON.parse(String(pushRequests[0].init?.body)).connectionState).toBe(state);
  await call('listener/heartbeat',listener,beat(listener));
  for(const status of ['pending','blocked']){
   await env.DB.prepare("INSERT INTO connection_notices(id,listener_id,parent_id,state,observed_at,created_at,status,next_attempt) VALUES(?,?,?,'online',?,?,?,?)")
    .bind(crypto.randomUUID(),listener.deviceId,parent.deviceId,`${new Date().toISOString()}-${status}`,Date.now(),status,Date.now()+3600000).run();
  }
  await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);
  const notices=await env.DB.prepare("SELECT status FROM connection_notices WHERE state='online'").all<{status:string}>();
  expect(notices.results.map(n=>n.status)).toEqual(['cancelled','cancelled']);
  expect((await env.DB.prepare('SELECT state FROM connection_states WHERE listener_id=?').bind(listener.deviceId).first<{state:string}>())?.state).toBe('online');
 });
 it('retries explicit rejection once without duplicating concurrent dispatch',async()=>{
  const {parent,listener}=await paired();await call('connection-alerts',parent,{enabled:true});await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();mockPush(503);
  await flushConnections(testEnv);await env.DB.prepare('UPDATE connection_notices SET next_attempt=0').run();mockPush();
  await Promise.all([flushConnections(testEnv),flushConnections(testEnv)]);expect(pushRequests).toHaveLength(2);
  expect(pushRequests[0].init?.headers).toEqual(pushRequests[1].init?.headers);
 });
 it('falls back after an explicitly invalid Watch token without replaying uncertain sends',async()=>{
  const {parent,listener}=await paired();await call('connection-alerts',parent,{enabled:true});
  await call('device/push-token',parent,{token:'ab'.repeat(32)});await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener));await stale();
  pushResponses.push(new Response(JSON.stringify({reason:'BadDeviceToken'}),{status:400}));await flushConnections(testEnv);
  await env.DB.prepare('UPDATE connection_notices SET next_attempt=0').run();mockPush();await flushConnections(testEnv);
  expect(pushRequests[0].url).toContain('cd'.repeat(32));expect(pushRequests[1].url).toContain('ab'.repeat(32));
  expect(JSON.parse(String(pushRequests[1].init?.body)).aps.sound).toBeUndefined();
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
 it('sends one haptic-capable Watch notification under the Watch topic',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const event={...alert(listener),isTest:true};mockPush();
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'sent'});
  await call('listener/event',listener,event);await flushPending(testEnv);
  expect(pushRequests).toHaveLength(1);
  expect(pushRequests[0].url).toContain('cd'.repeat(32));
  expect(new Headers(pushRequests[0].init?.headers).get('apns-topic')).toBe('com.example.BabyCryMonitor.watchkitapp');
  expect(JSON.parse(String(pushRequests[0].init?.body))).toMatchObject({aps:{sound:'default',category:'BABY_CRY_ALERT','interruption-level':'time-sensitive'},eventId:event.eventId,createdAt:event.createdAt,isTest:true});
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {alerts:{deliveryTarget:string}[]};
  expect(status.alerts[0].deliveryTarget).toBe('watch');
 });
 it('keeps an accepted phone alert on the phone when a Watch registers later',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  const event=alert(listener);mockPush();await call('listener/event',listener,event);
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  await call('listener/event',listener,event);await flushPending(testEnv);
  expect(pushRequests).toHaveLength(1);expect(pushRequests[0].url).toContain('ab'.repeat(32));
 });
 it('preserves the Watch destination after explicit rejection, without duplicating to iPhone',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const event=alert(listener);mockPush(503);await call('listener/event',listener,event);
  await env.DB.prepare('UPDATE events SET next_attempt=0 WHERE event_id=?').bind(event.eventId).run();mockPush();
  await flushPending(testEnv);
  expect(pushRequests).toHaveLength(2);expect(pushRequests.every(r=>r.url.includes('cd'.repeat(32)))).toBe(true);
 });
 it('falls back to the phone only after the Watch token is explicitly rejected as invalid',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const event=alert(listener);pushResponses.push(new Response(JSON.stringify({reason:'Unregistered'}),{status:410}));
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'pending'});
  mockPush();await flushPending(testEnv);
  expect(pushRequests).toHaveLength(2);expect(pushRequests[1].url).toContain('ab'.repeat(32));
  expect(JSON.parse(String(pushRequests[1].init?.body)).aps).not.toHaveProperty('sound');
 });
 it('does not replay an uncertain Watch delivery on the phone',async()=>{
  const {parent,listener}=await paired();await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});
  const event=alert(listener);pushResponses.push(new Error('connection lost'));
  expect(await (await call('listener/event',listener,event)).json()).toEqual({status:'uncertain'});
  await call('device/watch-push-token',parent,{token:null});await flushPending(testEnv);
  expect(pushRequests).toHaveLength(1);
 });
 it('does not reawaken an acknowledged episode when the Watch registers',async()=>{
  const {parent,listener}=await paired();const event=alert(listener);
  await call('listener/event',listener,event);await call('alert/acknowledge',parent,{eventId:event.eventId});
  await call('device/watch-push-token',parent,{token:'cd'.repeat(32)});await flushPending(testEnv);
  expect(pushRequests).toHaveLength(0);
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
  expect(notification.aps).not.toHaveProperty('sound');
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
 it('omits audible sound and signs an ES256 provider JWT',async()=>{
  const notification=payload(alert(device('listener')));expect(notification.aps).not.toHaveProperty('sound');
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
  const retries=await env.DB.prepare('SELECT outcome,attempt FROM diagnostics WHERE event_ref=? ORDER BY sequence').bind(ref).all();
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

describe('5-second reminders and acknowledgement mute',()=>{
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
  expect(reminder.aps.alert.title).toContain('Reminder');expect(reminder.aps.alert.body).toContain('Settings');
  const headers=pushRequests[1].init?.headers as Record<string,string>;
  expect(Number(headers['apns-expiration'])).toBe(Math.floor(Date.now()/1000)+5);
  expect(headers['apns-collapse-id']).toBe(event.episodeId);
  advance(5);mockPush();await runReminder(testEnv,parent.deviceId);expect(pushRequests).toHaveLength(3);
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
 it('relays the exact nursery chart only to its paired Parent and signals viewing demand',async()=>{
  const a=await paired(),b=await paired();
  const listener=await open(a.listener);
  expect(await listener.next()).toEqual({type:'viewing',active:false});
  const parent=await open(a.parent),other=await open(b.parent);
  expect(await listener.next()).toEqual({type:'viewing',active:true});
  const value=frame();listener.socket.send(JSON.stringify(value));
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
  for(const value of [{...frame(),audio:'recording'},{...frame(),levels:[0]},
   {...frame(),levels:Array(32).fill(-101)},{...frame(),levels:Array(32).fill(NaN)},
   {...frame(),threshold:-90},{...frame(),episodeStartedAt:Date.now()/1000+100}])expect(()=>soundFrame(value)).toThrow();
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
