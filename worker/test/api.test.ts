import {env,applyD1Migrations} from 'cloudflare:test';
import {beforeAll,afterEach,beforeEach,describe,it,expect,vi} from 'vitest';
import worker from '../src/index';
import {defaultConfiguration,type Env,type Alert} from '../src/types';
import {payload,apnsToken} from '../src/apns';
import {encryptToken,decryptToken} from '../src/security';
import {flushPending} from '../src/alerts';

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
 await env.DB.batch(['events','heartbeats','pairs','pairing_codes','devices','rate_limits'].map(table=>env.DB.prepare(`DELETE FROM ${table}`)));
 pushResponses=[];pushRequests=[];
 vi.stubGlobal('fetch',vi.fn(async(input:string|URL|Request,init?:RequestInit)=>{
  const url=String(input);expect(url).toMatch(/^https:\/\/api\.sandbox\.push\.apple\.com\/3\/device\//);
  pushRequests.push({url,init});
  const response=pushResponses.shift();if(!response)throw new Error('Unexpected external request');
  if(response instanceof Error)throw response;return response;
 }));
});
afterEach(()=>{expect(pushResponses).toHaveLength(0);vi.unstubAllGlobals();});

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
 it('stores heartbeat with server freshness and shares settings',async()=>{
  const {parent,listener}=await paired();const config={...defaultConfiguration,alertDuration:60,sensitivity:'high'};
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
