import {sha256} from './security';
import type {Env} from './types';
import type {Latency} from './latency';

// Apple allows reuse across topics and servers. Rotate at 50 minutes, inside
// its 20–60 minute window, using one persistent authority per signing key.
const reuseSeconds=3000;
// A response may cross the refresh deadline in transit. Apple accepts tokens
// for an hour; reserve one minute for the actual send, without extending caching.
const usableSeconds=3540;
interface TokenRecord {identity:string;token:string;issuedAt:number;reference:string}
interface TokenReply {record:TokenRecord;reused:boolean}
function privateKey(env:Env):string {return env.APNS_PRIVATE_KEY.replace(/\\n/g,'\n').replace(/-----[^-]+-----/g,'').replace(/\s/g,'');}
function configuration(env:Env):string {
 if(!env.APNS_KEY_ID||!env.APNS_TEAM_ID||!env.APNS_PRIVATE_KEY||!env.APNS_BUNDLE_ID)throw new Error('APNs configuration missing');
 return JSON.stringify([env.APNS_KEY_ID,env.APNS_TEAM_ID,privateKey(env)]);
}
function valid(record:TokenRecord|undefined,identity:string,now:number,maxAge=reuseSeconds):record is TokenRecord {
 return !!record&&record.identity===identity&&Number.isSafeInteger(record.issuedAt)&&record.issuedAt<=now&&now-record.issuedAt<maxAge&&
  typeof record.token==='string'&&record.token.length<4096&&record.token.split('.').length===3&&/^[0-9a-f]{64}$/.test(record.reference);
}
function base64url(value:Uint8Array):string {return btoa(String.fromCharCode(...value)).replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');}
function encodedJSON(value:unknown):string {return base64url(new TextEncoder().encode(JSON.stringify(value)));}

// This object is reachable only through the internal namespace binding. It
// never sends pushes, and persists the token before releasing it to callers.
export class ProviderTokens implements DurableObject {
 private pending?:Promise<TokenReply>;
 constructor(private state:DurableObjectState,private env:Env){}
 async fetch(request:Request):Promise<Response> {
  if(request.method!=='POST'||new URL(request.url).pathname!=='/token')return new Response(null,{status:404});
  const identity=await sha256(configuration(this.env));
  if(request.headers.get('x-credential-identity')!==identity)return new Response(null,{status:409});
  // Crypto yields as well as storage: coalesce misses throughout signing and
  // the durable write, so concurrent destinations cannot mint different JWTs.
  if(!this.pending){
   const pending=this.load(identity);
   this.pending=pending;
   void pending.finally(()=>{if(this.pending===pending)this.pending=undefined;}).catch(()=>{});
  }
  return Response.json(await this.pending,{headers:{'cache-control':'no-store'}});
 }
 private async load(identity:string):Promise<TokenReply> {
  const stored=await this.state.storage.get<TokenRecord>('token');
  const now=Math.floor(Date.now()/1000);
  // A clock regression must not turn into an early token rotation.
  if(stored?.identity===identity&&stored.issuedAt>now)throw new Error('APNs token clock moved backwards');
  if(valid(stored,identity,now))return {record:stored,reused:true};
  const key=await crypto.subtle.importKey('pkcs8',Uint8Array.from(atob(privateKey(this.env)),c=>c.charCodeAt(0)),{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
  const input=`${encodedJSON({alg:'ES256',kid:this.env.APNS_KEY_ID})}.${encodedJSON({iss:this.env.APNS_TEAM_ID,iat:now})}`;
  const signature=await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,new TextEncoder().encode(input));
  const token=`${input}.${base64url(new Uint8Array(signature))}`;
  const record={identity,token,issuedAt:now,reference:await sha256(token)};
  await this.state.storage.put('token',record);
  return {record,reused:false};
 }
}

export class ProviderTokenCache {
 private cached?:{configuration:string;record:TokenRecord};
 private pending?:{configuration:string;promise:Promise<TokenReply>};
 async get(env:Env,latency?:Latency,checkAuthority=false):Promise<string> {
  const config=configuration(env),now=Math.floor(Date.now()/1000);
  let record:TokenRecord,source:NonNullable<Latency['details']['provider_token_source']>;
  if(!checkAuthority&&this.cached?.configuration===config&&valid(this.cached.record,this.cached.record.identity,now)){
   record=this.cached.record;source='memory';
  }else{
   const shared=this.pending?.configuration===config;
   if(!shared){
    const promise=this.load(env,config);
    this.pending={configuration:config,promise};
    void promise.finally(()=>{if(this.pending?.promise===promise)this.pending=undefined;}).catch(()=>{});
   }
   const reply=await this.pending!.promise;
   record=reply.record;source=shared?'in_flight':reply.reused?'coordinator_reused':'coordinator_created';
   this.cached={configuration:config,record};
  }
  if(latency){
   latency.details.provider_token_cached=source==='memory'||source==='in_flight'||source==='coordinator_reused';
   latency.details.provider_token_source=source;
   latency.details.provider_token_age_s=Math.max(0,Math.floor(Date.now()/1000)-record.issuedAt);
   latency.details.provider_token_ref=record.reference;
  }
  return record.token;
 }
 private async load(env:Env,config:string):Promise<TokenReply> {
  const identity=await sha256(config);
  const response=await env.APNS_PROVIDER_TOKENS.getByName(identity).fetch('https://provider.internal/token',{
   method:'POST',headers:{'x-credential-identity':identity},signal:AbortSignal.timeout(5000)
  });
  if(!response.ok)throw new Error('APNs token authority unavailable');
  const reply=await response.json() as TokenReply;
  if(!valid(reply.record,identity,Math.floor(Date.now()/1000),usableSeconds)||typeof reply.reused!=='boolean')throw new Error('APNs token authority response invalid');
  // No local signing fallback: a coordinator outage must not create token churn.
  return reply;
 }
}
export const providerTokens=new ProviderTokenCache();
