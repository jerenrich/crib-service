import {env,runInDurableObject} from 'cloudflare:test';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {ProviderTokenCache,ProviderTokens} from '../src/provider-token';
import {sha256} from '../src/security';
import {Latency,safeTimingDetails} from '../src/latency';
import type {Env} from '../src/types';

afterEach(()=>vi.restoreAllMocks());
function authority(){
 const values=new Map<string,unknown>();
 const get=vi.fn(async(key:string)=>values.get(key));
 const put=vi.fn(async(key:string,value:unknown)=>{values.set(key,structuredClone(value));});
 const state={storage:{get,put}} as unknown as DurableObjectState;
 let instance=new ProviderTokens(state,env);
 const fetch=vi.fn((input:string,init:RequestInit)=>instance.fetch(new Request(input,init)));
 const testEnv={...env,APNS_PROVIDER_TOKENS:{getByName:()=>({fetch})}} as unknown as Env;
 return {values,get,put,fetch,testEnv,restart:()=>{instance=new ProviderTokens(state,env);}};
}

describe('persistent APNs provider tokens',()=>{
 it('shares one signed JWT across concurrent cold callers and different topics/environments',async()=>{
  const a=authority(),clients=Array.from({length:12},()=>new ProviderTokenCache());
  const tokens=await Promise.all(clients.map((client,i)=>client.get({...a.testEnv,APNS_BUNDLE_ID:i%2?'com.example.other':'com.example.watch',APNS_ENVIRONMENT:i%2?'production':'development'})));
  expect(new Set(tokens).size).toBe(1);expect(a.put).toHaveBeenCalledTimes(1);
  const [header,body,signature]=tokens[0].split('.');
  const decode=(value:string)=>Uint8Array.from(atob(value.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
  expect(JSON.parse(new TextDecoder().decode(decode(header)))).toEqual({alg:'ES256',kid:'TESTKEY'});
  expect(JSON.parse(new TextDecoder().decode(decode(body)))).toMatchObject({iss:'TESTTEAM',iat:expect.any(Number)});
  const pem=env.APNS_PRIVATE_KEY.replace(/-----[^-]+-----/g,'').replace(/\s/g,'');
  const key=await crypto.subtle.importKey('pkcs8',decode(pem),{name:'ECDSA',namedCurve:'P-256'},true,['sign']);
  const jwk=await crypto.subtle.exportKey('jwk',key) as JsonWebKey;delete jwk.d;jwk.key_ops=['verify'];
  const publicKey=await crypto.subtle.importKey('jwk',jwk,{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
  expect(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},publicKey,decode(signature),new TextEncoder().encode(`${header}.${body}`))).toBe(true);
 });
 it('coalesces an isolate cold miss and uses local memory for warm sends',async()=>{
  const a=authority(),client=new ProviderTokenCache(),first=new Latency(),second=new Latency(),third=new Latency();
  const tokens=await Promise.all([client.get(a.testEnv,first),client.get(a.testEnv,second)]);
  expect(await client.get(a.testEnv,third)).toBe(tokens[0]);expect(tokens[1]).toBe(tokens[0]);expect(a.fetch).toHaveBeenCalledTimes(1);
  expect(first.details.provider_token_source).toBe('coordinator_created');expect(second.details.provider_token_source).toBe('in_flight');expect(third.details.provider_token_source).toBe('memory');
  expect(first.details.provider_token_ref).toBe(await sha256(tokens[0]));
 });
 it('reuses persisted tokens after both object and caller restarts, then rotates once at 50 minutes',async()=>{
  const a=authority(),start=Math.floor(Date.now()/1000)*1000;
  vi.spyOn(Date,'now').mockReturnValue(start);
  const first=await new ProviderTokenCache().get(a.testEnv);a.restart();
  vi.mocked(Date.now).mockReturnValue(start+2999_000);
  const trace=new Latency();expect(await new ProviderTokenCache().get(a.testEnv,trace)).toBe(first);
  expect(trace.details).toMatchObject({provider_token_source:'coordinator_reused',provider_token_age_s:2999});
  vi.mocked(Date.now).mockReturnValue(start+3000_000);a.restart();
  const refreshed=await Promise.all(Array.from({length:8},()=>new ProviderTokenCache().get(a.testEnv)));
  expect(new Set(refreshed).size).toBe(1);expect(refreshed[0]).not.toBe(first);expect(a.put).toHaveBeenCalledTimes(2);
 });
 it('does not release a JWT until its durable write commits',async()=>{
  const a=authority();let release!:()=>void;
  const gate=new Promise<void>(resolve=>{release=resolve;});
  const original=a.put.getMockImplementation()!;
  let writing!:()=>void;const started=new Promise<void>(resolve=>{writing=resolve;});
  a.put.mockImplementation(async(key,value)=>{writing();await gate;await original(key,value);});
  let finished=false;const pending=new ProviderTokenCache().get(a.testEnv).then(token=>{finished=true;return token;});
  await started;expect(finished).toBe(false);release();await pending;expect(a.put).toHaveBeenCalledTimes(1);
 });
 it('does not rotate early if a clock moves backwards',async()=>{
  const a=authority(),start=Date.now();vi.spyOn(Date,'now').mockReturnValue(start);
  await new ProviderTokenCache().get(a.testEnv);a.restart();
  vi.mocked(Date.now).mockReturnValue(start-5000);
  await expect(new ProviderTokenCache().get(a.testEnv)).rejects.toThrow('clock moved backwards');
  expect(a.put).toHaveBeenCalledTimes(1);
 });
 it('fails closed on storage failure and recovers without a local signing fallback',async()=>{
  const a=authority(),client=new ProviderTokenCache();
  a.put.mockRejectedValueOnce(new Error('storage unavailable'));
  await expect(client.get(a.testEnv)).rejects.toThrow('storage unavailable');
  expect(a.values.size).toBe(0);
  const token=await client.get(a.testEnv);a.restart();
  expect(await new ProviderTokenCache().get(a.testEnv)).toBe(token);expect(a.put).toHaveBeenCalledTimes(2);
 });
 it('rejects a mismatched signing configuration instead of returning an old credential token',async()=>{
  const a=authority();
  await expect(new ProviderTokenCache().get({...a.testEnv,APNS_KEY_ID:'ROTATEDKEY'})).rejects.toThrow('authority unavailable');
  expect(a.put).not.toHaveBeenCalled();
 });
 it('uses the deployed namespace binding and preserves reuse across a reconstructed instance',async()=>{
  const trace=new Latency(),first=await new ProviderTokenCache().get(env,trace);
  const pem=env.APNS_PRIVATE_KEY.replace(/-----[^-]+-----/g,'').replace(/\s/g,'');
  const identity=await sha256(JSON.stringify([env.APNS_KEY_ID,env.APNS_TEAM_ID,pem]));
  const stub=env.APNS_PROVIDER_TOKENS.getByName(identity);
  const reply=await runInDurableObject(stub,async(_instance,state)=>{
   const reconstructed=new ProviderTokens(state,env);
   return (await reconstructed.fetch(new Request('https://provider.internal/token',{method:'POST',headers:{'x-credential-identity':identity}}))).json() as Promise<{record:{token:string};reused:boolean}>;
  });
  expect(reply.record.token).toBe(first);expect(reply.reused).toBe(true);
 });
 it('does not persist arbitrary strings or bearer credentials in diagnostic fields',()=>{
  expect(safeTimingDetails({provider_token_ref:'bearer-private-token',provider_token_source:'private-value'} as never)).toBeNull();
  expect(JSON.parse(safeTimingDetails({provider_token_ref:'a'.repeat(64),provider_token_source:'coordinator_reused',provider_token_age_s:100})!)).toEqual({provider_token_ref:'a'.repeat(64),provider_token_source:'coordinator_reused',provider_token_age_s:100});
 });
});
