import {env,applyD1Migrations} from 'cloudflare:test';
import {beforeAll,afterEach,beforeEach,describe,it,expect,vi} from 'vitest';
import worker from '../src/index';
import {defaultConfiguration,type Env,type Alert} from '../src/types';
import {payload,apnsToken} from '../src/apns';
import {encryptToken,decryptToken} from '../src/security';
import {flushPending} from '../src/alerts';
import {eventReference,recordDiagnostic} from '../src/diagnostics';
import {flushConnections} from '../src/connections';

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
 await env.DB.batch(['diagnostics','connection_notices','connection_states','events','heartbeats','pairs','pairing_codes','devices','rate_limits'].map(table=>env.DB.prepare(`DELETE FROM ${table}`)));
 pushResponses=[];pushRequests=[];
 vi.stubGlobal('fetch',vi.fn(async(input:string|URL|Request,init?:RequestInit)=>{
  const url=String(input);expect(url).toMatch(/^https:\/\/api\.sandbox\.push\.apple\.com\/3\/device\//);
  pushRequests.push({url,init});
  const response=pushResponses.shift();if(!response)throw new Error('Unexpected external request');
  if(response instanceof Error)throw response;return response;
 }));
});
afterEach(()=>{expect(pushResponses).toHaveLength(0);vi.unstubAllGlobals();});

describe('connection alerts, readiness and replacement',()=>{
 const beat=(listener:TestDevice,monitoring=true,appliedConfiguration=defaultConfiguration)=>({listenerId:listener.deviceId,timestamp:new Date().toISOString(),monitoring,powerConnected:true,state:'quiet',episodes:[],appliedConfiguration});
 async function stale(){await env.DB.prepare('UPDATE heartbeats SET received_at=?').bind(new Date(Date.now()-240000).toISOString()).run();}
 it('requires parent opt-in and emits one notice per outage plus recovery',async()=>{
  const {parent,listener}=await paired();
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  expect((await call('connection-alerts',listener,{enabled:true})).status).toBe(403);
  expect((await call('connection-alerts',parent,{enabled:'yes'})).status).toBe(400);
  await call('listener/heartbeat',listener,beat(listener));
  await stale();await flushConnections(testEnv);expect(pushRequests).toHaveLength(0);
  await call('listener/heartbeat',listener,beat(listener));await flushConnections(testEnv);
  await call('connection-alerts',parent,{enabled:true});
  await stale();mockPush();await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);
  let content=JSON.parse(String(pushRequests[0].init?.body));expect(content.connectionState).toBe('offline');expect(content.eventId).toBeUndefined();
  await call('listener/heartbeat',listener,beat(listener));mockPush();await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(2);content=JSON.parse(String(pushRequests[1].init?.body));expect(content.connectionState).toBe('online');
 });
 it('reports stopped monitoring but does not warn before first start',async()=>{
  const {parent,listener}=await paired();await call('connection-alerts',parent,{enabled:true});
  await call('device/push-token',parent,{token:'ab'.repeat(32)});
  await call('listener/heartbeat',listener,beat(listener,false));await flushConnections(testEnv);expect(pushRequests).toHaveLength(0);
  await call('listener/heartbeat',listener,beat(listener));
  await call('listener/heartbeat',listener,beat(listener,false));mockPush();await flushConnections(testEnv);await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);expect(JSON.parse(String(pushRequests[0].init?.body)).connectionState).toBe('stopped');
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
  await env.DB.prepare('UPDATE connection_notices SET next_attempt=0').run();mockPush();await flushConnections(testEnv);
  expect(pushRequests).toHaveLength(1);expect(JSON.parse(String(pushRequests[0].init?.body)).connectionState).toBe('online');
  const offline=await env.DB.prepare("SELECT status FROM connection_notices WHERE state='offline'").first<{status:string}>();expect(offline?.status).toBe('cancelled');
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
  const status=await (await call('listener/status',parent,undefined,'GET')).json() as {lastHeartbeat:string;monitoring:boolean};
  expect(Date.parse(status.lastHeartbeat)).toBeGreaterThan(Date.now()-5000);expect(status.monitoring).toBe(true);
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
  expect(notification.aps.alert.title).toBe('Baby is still crying');
  expect(notification).not.toHaveProperty('isTest');
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
  // Acknowledging existing events must not suppress a later enabled reminder.
  mockPush();
  expect(await (await call('listener/event',listener,{...event,eventId:crypto.randomUUID(),isRepeat:true})).json()).toEqual({status:'sent'});
  expect(pushRequests).toHaveLength(1);
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
