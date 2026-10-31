import {APIError,type Device,type Env} from './types';
import {pairFor} from './devices';
import {uuid} from './security';
import {nurserySoundCommand,nurserySoundState} from './nursery-sound';
import {recordDiagnostic} from './diagnostics';
import type {TimingDetails} from './latency';

type Pair = {parent_id:string;listener_id:string;created_at:number};
type Peer = {pair:Pair;role:Device['role'];lastMessage:number;lastPing?:number;lastSample?:number;controlWindow?:number;controlCount?:number;connectionID?:string;lastConfirmationID?:string};
class LiveSoundProtocolError extends Error {
 constructor(readonly reason:'invalid_message'|'rate_limit'|'wrong_role') {super('Invalid live sound message.');}
}
export interface SoundFrame {
 type:'levels';sampledAt:number;levels:number[];threshold:number;
 state:'quiet'|'possibleCry'|'crying';episodeStartedAt?:number|null;alertDuration:number;
 requestID?:string;
 notificationTimes?:number[];
}

export function soundFrame(value:unknown):SoundFrame {
 if(!value||typeof value!=='object'||Array.isArray(value))throw new APIError(400,'Invalid sound levels.');
 const v=value as Record<string,unknown>;
 if(Object.keys(v).some(k=>!['type','sampledAt','levels','threshold','state','episodeStartedAt','alertDuration','requestID','notificationTimes'].includes(k))
  ||v.type!=='levels'||typeof v.sampledAt!=='number'||!Number.isFinite(v.sampledAt)||v.sampledAt<0||v.sampledAt>32503680000
  ||!Array.isArray(v.levels)||![32,120].includes(v.levels.length)||v.levels.some(n=>typeof n!=='number'||!Number.isFinite(n)||n < -100||n > 0)
  ||typeof v.threshold!=='number'||!Number.isFinite(v.threshold)||v.threshold < -60||v.threshold > -10
  ||!['quiet','possibleCry','crying'].includes(String(v.state))
  ||typeof v.alertDuration!=='number'||!Number.isFinite(v.alertDuration)||v.alertDuration<5||v.alertDuration>3600
  ||(v.episodeStartedAt!=null&&(typeof v.episodeStartedAt!=='number'||!Number.isFinite(v.episodeStartedAt)||v.episodeStartedAt<0||v.episodeStartedAt>v.sampledAt)))
  throw new APIError(400,'Invalid sound levels.');
 if(v.notificationTimes!==undefined&&(!Array.isArray(v.notificationTimes)||v.notificationTimes.length>32
  ||v.notificationTimes.some(n=>typeof n!=='number'||!Number.isFinite(n)||n < (v.sampledAt as number)-30||n > (v.sampledAt as number))))
  throw new APIError(400,'Invalid notification markers.');
 if(v.requestID!==undefined)uuid(v.requestID);
 return v as unknown as SoundFrame;
}

function room(env:Env,pair:Pair) {
 return env.LIVE_SOUND.get(env.LIVE_SOUND.idFromName(`${pair.parent_id}|${pair.listener_id}|${pair.created_at}`));
}
export async function openLiveSound(env:Env,device:Device,request:Request):Promise<Response> {
 if(request.headers.get('upgrade')?.toLowerCase()!=='websocket')throw new APIError(426,'WebSocket required.');
 const pair=await pairFor(env,device);
 if(!pair)throw new APIError(409,'Pair a device first.');
 // Construct fresh internal headers; never trust a caller's role or room headers.
 return room(env,pair).fetch(new Request('https://live-sound/connect',{headers:{upgrade:'websocket',
  'x-live-peer':JSON.stringify({pair,role:device.role})}}));
}
export async function revokeLiveSound(env:Env,pair:Pair):Promise<void> {
 await room(env,pair).fetch(new Request('https://live-sound/revoke',{method:'POST'}));
}

// Socket attachments hold connection metadata and a last confirmation UUID for
// diagnostic deduplication. Sound levels and control contents are never persisted.
export class LiveSound {
 private verifiedAt=0;
 private diagnosticTimes=new Map<string,number>();
 constructor(private ctx:DurableObjectState,private env:Env) {}
 private diagnostic(details:NonNullable<TimingDetails['live_sound']>,commandID?:string,started=Date.now()) {
  // No frame, heartbeat, raw message, credential, device identity, or control token.
  // Journal writes are best effort and never awaited on the relay path.
  if(!commandID){
   const key=`${details.phase}|${details.role}|${details.reason}|${details.close_code}`;
   const now=Date.now(),last=this.diagnosticTimes.get(key);
   if(last!==undefined&&now-last<60000)return;
   this.diagnosticTimes.set(key,now);
  }
  try{this.ctx.waitUntil(recordDiagnostic(this.env,{requestId:commandID??crypto.randomUUID(),operation:'live_sound',
   stage:details.reason==='pairing_store'?'storage':details.phase==='rejected'?'validation':'handler',
   outcome:details.phase==='failed'?'internal_error':details.phase==='rejected'||details.reason==='playbackFailed'||details.reason==='expired'||details.reason==='unavailable'?'rejected':'ok',
   started,details:{live_sound:details}}));}catch{/* Diagnostics cannot affect relay behavior. */}
 }
 private async valid(pair:Pair):Promise<boolean> {
  return !!await this.env.DB.prepare('SELECT 1 FROM pairs WHERE parent_id=? AND listener_id=? AND created_at=?')
   .bind(pair.parent_id,pair.listener_id,pair.created_at).first();
 }
 private send(ws:WebSocket,value:unknown):boolean {
  try{ws.send(JSON.stringify(value));return true;}catch{
   this.diagnostic({phase:'failed',reason:'transport',close_code:1011});ws.close(1011,'Connection unavailable.');return false;
  }
 }
 private demand() {
  const active=this.ctx.getWebSockets('parent').some(ws=>ws.readyState===WebSocket.OPEN);
  for(const ws of this.ctx.getWebSockets('listener'))this.send(ws,{type:'viewing',active});
 }
 private closeAll() {
  this.diagnostic({phase:'closed',reason:'pairing_ended',close_code:1008});
  for(const ws of this.ctx.getWebSockets())ws.close(1008,'Pairing ended.');
 }
 async fetch(request:Request):Promise<Response> {
  if(new URL(request.url).pathname==='/revoke'){this.verifiedAt=0;this.closeAll();return new Response(null,{status:204});}
  const peer=JSON.parse(request.headers.get('x-live-peer')!) as Peer;
  if(!await this.valid(peer.pair))return new Response(null,{status:403});
  // One connection per paired device; a reconnect replaces the previous socket.
  for(const old of this.ctx.getWebSockets(peer.role))old.close(1000,'Reconnected.');
  const [client,server]=Object.values(new WebSocketPair());
  this.ctx.acceptWebSocket(server,[peer.role]);
  const connectionID=crypto.randomUUID();
  server.serializeAttachment({...peer,lastMessage:0,connectionID});
  this.verifiedAt=Date.now();
  this.send(server,{type:'ready'});
  if(peer.role==='listener')for(const parent of this.ctx.getWebSockets('parent'))this.send(parent,{type:'sourceChanged'});
  this.demand();
  this.diagnostic({phase:'connected',role:peer.role,connection_id:connectionID});
  return new Response(null,{status:101,webSocket:client});
 }
 async webSocketMessage(ws:WebSocket,message:string|ArrayBuffer):Promise<void> {
  const started=Date.now();
  let peer:Peer|undefined,checkingPair=false;
  try {
   if(typeof message!=='string'||message.length>4096)throw new LiveSoundProtocolError('invalid_message');
   peer=ws.deserializeAttachment() as Peer;
   if(Date.now()-this.verifiedAt>=15000){
    checkingPair=true;
    if(!await this.valid(peer.pair)){this.closeAll();return;}
    this.verifiedAt=Date.now();checkingPair=false;
   }
   let value:Record<string,unknown>;
   try{
    const parsed:unknown=JSON.parse(message);
    if(!parsed||typeof parsed!=='object'||Array.isArray(parsed))throw new Error();
    value=parsed as Record<string,unknown>;
   }catch{throw new LiveSoundProtocolError('invalid_message');}
   if(value.type==='ping'&&Object.keys(value).every(k=>['type','requestID'].includes(k))){
    if(peer.lastPing!==undefined&&Date.now()-peer.lastPing<500)throw new LiveSoundProtocolError('rate_limit');
    peer.lastPing=Date.now();
    if(value.requestID!==undefined){
     if(peer.role!=='parent')throw new LiveSoundProtocolError('wrong_role');
     const requestID=uuid(value.requestID);
     for(const listener of this.ctx.getWebSockets('listener'))this.send(listener,{type:'viewing',active:true,requestID});
    }
    ws.serializeAttachment(peer);this.send(ws,{type:'pong'});return;
   }
   if(value.type==='nurserySoundCommand'||value.type==='nurserySoundState'){
    const now=Date.now();
    if(peer.controlWindow===undefined||now-peer.controlWindow>=1000){peer.controlWindow=now;peer.controlCount=0;}
    peer.controlCount=(peer.controlCount??0)+1;if(peer.controlCount>16)throw new LiveSoundProtocolError('rate_limit');
    if(value.type==='nurserySoundCommand'){
     if(peer.role!=='parent')throw new LiveSoundProtocolError('wrong_role');
     const command=nurserySoundCommand(value);
     let recipients=0;
     for(const listener of this.ctx.getWebSockets('listener'))if(this.send(listener,command))recipients++;
     this.diagnostic({phase:'command_relayed',role:peer.role,connection_id:peer.connectionID,recipients},uuid(command.id),started);
    }else{
     if(peer.role!=='listener')throw new LiveSoundProtocolError('wrong_role');
     const state=nurserySoundState(value);
     let recipients=0;
     for(const parent of this.ctx.getWebSockets('parent'))if(this.send(parent,state))recipients++;
     const commandID=state.commandID==null?undefined:uuid(state.commandID);
     if(commandID!==undefined&&commandID!==peer.lastConfirmationID){
      peer.lastConfirmationID=commandID;
      this.diagnostic({phase:'confirmation_relayed',role:peer.role,connection_id:peer.connectionID,recipients,
       ...(state.failure==null?{}:{reason:state.failure as 'playbackFailed'|'expired'|'unavailable'})},peer.lastConfirmationID,started);
     }
    }
    ws.serializeAttachment(peer);return;
   }
   if(peer.role!=='listener')throw new LiveSoundProtocolError('wrong_role');
   if(Date.now()-peer.lastMessage<200)throw new LiveSoundProtocolError('rate_limit');
   peer.lastMessage=Date.now();
   const frame=soundFrame(value);
   if(peer.lastSample!==undefined&&frame.sampledAt<=peer.lastSample)throw new LiveSoundProtocolError('invalid_message');
   peer.lastSample=frame.sampledAt;ws.serializeAttachment(peer);
   for(const parent of this.ctx.getWebSockets('parent'))this.send(parent,frame);
  } catch(error) {
   const invalid=!checkingPair&&(error instanceof LiveSoundProtocolError||(error instanceof APIError&&error.status<500));
   const code=invalid?1008:1011;
   this.diagnostic({phase:invalid?'rejected':'failed',role:peer?.role,connection_id:peer?.connectionID,close_code:code,
    reason:checkingPair?'pairing_store':error instanceof LiveSoundProtocolError?error.reason:invalid?'invalid_message':'internal_error'},undefined,started);
   ws.close(code,invalid?'Invalid live sound message.':'Connection unavailable.');
  }
 }
 webSocketClose(ws:WebSocket,code:number) {
  this.diagnostic({phase:'closed',reason:'peer_closed',close_code:code});
  ws.close([1005,1006,1015].includes(code)?1001:code);this.demand();
 }
 webSocketError(ws:WebSocket) {
  this.diagnostic({phase:'failed',reason:'transport',close_code:1011});
  ws.close(1011,'Connection unavailable.');this.demand();
 }
}
