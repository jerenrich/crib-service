import {APIError,type Device,type Env} from './types';
import {pairFor} from './devices';
import {uuid} from './security';

type Pair = {parent_id:string;listener_id:string;created_at:number};
type Peer = {pair:Pair;role:Device['role'];deviceId?:string;lastMessage:number;lastPing?:number;lastSample?:number};
export interface SoundFrame {
 type:'levels';sampledAt:number;levels:number[];threshold:number;
 state:'quiet'|'possibleCry'|'crying';episodeStartedAt?:number|null;alertDuration:number;
 requestID?:string;
 requestIDs?:string[];
 notificationTimes?:number[];
}

export function soundFrame(value:unknown):SoundFrame {
 if(!value||typeof value!=='object'||Array.isArray(value))throw new APIError(400,'Invalid sound levels.');
 const v=value as Record<string,unknown>;
 if(Object.keys(v).some(k=>!['type','sampledAt','levels','threshold','state','episodeStartedAt','alertDuration','requestID','requestIDs','notificationTimes'].includes(k))
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
 if(v.requestIDs!==undefined){
  if(!Array.isArray(v.requestIDs)||v.requestIDs.length>16)throw new APIError(400,'Invalid sound challenges.');
  for(const id of v.requestIDs)uuid(id);
 }
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
  'x-live-peer':JSON.stringify({pair,role:device.role,deviceId:device.familyAuthorization?.memberId??device.id})}}));
}
export async function revokeLiveSound(env:Env,pair:Pair):Promise<void> {
 await room(env,pair).fetch(new Request('https://live-sound/revoke',{method:'POST'}));
}

// Only connection identities are attached to sockets. Sound levels are relayed
// directly, never written to D1, Durable Object storage, attachments, or logs.
export class LiveSound {
 private verifiedAt=0;
 constructor(private ctx:DurableObjectState,private env:Env) {}
 private identity(peer:Peer):string {return peer.deviceId??(peer.role==='parent'?peer.pair.parent_id:peer.pair.listener_id);}
 private async members(pair:Pair):Promise<Set<string>|null> {
  const row=await this.env.DB.prepare(`SELECT f.partner_id FROM pairs p LEFT JOIN caregiver_families f
   ON f.owner_id=p.parent_id AND f.pair_created_at=p.created_at
   WHERE p.parent_id=? AND p.listener_id=? AND p.created_at=?`)
   .bind(pair.parent_id,pair.listener_id,pair.created_at).first<{partner_id:string|null}>();
  if(!row)return null;
  return new Set([pair.parent_id,pair.listener_id,...(row.partner_id?[row.partner_id]:[])]);
 }
 private revokeDeparted(members:Set<string>|null) {
  for(const socket of this.ctx.getWebSockets())if(!members?.has(this.identity(socket.deserializeAttachment() as Peer)))socket.close(1008,'Pairing ended.');
 }
 private send(ws:WebSocket,value:unknown) {
  try{ws.send(JSON.stringify(value));}catch{ws.close(1011,'Connection unavailable.');}
 }
 private demand() {
  const active=this.ctx.getWebSockets('parent').some(ws=>ws.readyState===WebSocket.OPEN);
  for(const ws of this.ctx.getWebSockets('listener'))this.send(ws,{type:'viewing',active});
 }
 private closeAll() {for(const ws of this.ctx.getWebSockets())ws.close(1008,'Pairing ended.');}
 async fetch(request:Request):Promise<Response> {
  if(new URL(request.url).pathname==='/revoke'){this.verifiedAt=0;this.closeAll();return new Response(null,{status:204});}
  const peer=JSON.parse(request.headers.get('x-live-peer')!) as Peer;
  const members=await this.members(peer.pair);this.revokeDeparted(members);
  if(!members?.has(this.identity(peer)))return new Response(null,{status:403});
  // One connection per paired device; a reconnect replaces the previous socket.
  for(const old of this.ctx.getWebSockets(peer.role))if(this.identity(old.deserializeAttachment() as Peer)===this.identity(peer))old.close(1000,'Reconnected.');
  const [client,server]=Object.values(new WebSocketPair());
  this.ctx.acceptWebSocket(server,[peer.role]);
  server.serializeAttachment({...peer,lastMessage:0});
  this.verifiedAt=Date.now();
  this.send(server,{type:'ready'});
  if(peer.role==='listener')for(const parent of this.ctx.getWebSockets('parent'))this.send(parent,{type:'sourceChanged'});
  this.demand();
  return new Response(null,{status:101,webSocket:client});
 }
 async webSocketMessage(ws:WebSocket,message:string|ArrayBuffer):Promise<void> {
  try {
   if(typeof message!=='string'||message.length>4096)throw new Error();
   const peer=ws.deserializeAttachment() as Peer;
   if(Date.now()-this.verifiedAt>=15000){
    const members=await this.members(peer.pair);this.revokeDeparted(members);
    if(!members?.has(this.identity(peer)))return;
    this.verifiedAt=Date.now();
   }
   const value=JSON.parse(message) as Record<string,unknown>;
   if(value.type==='ping'&&Object.keys(value).every(k=>['type','requestID'].includes(k))){
    if(peer.lastPing!==undefined&&Date.now()-peer.lastPing<500)throw new Error();
    peer.lastPing=Date.now();
    if(value.requestID!==undefined){
     if(peer.role!=='parent')throw new Error();
     const requestID=uuid(value.requestID);
     for(const listener of this.ctx.getWebSockets('listener'))this.send(listener,{type:'viewing',active:true,requestID});
    }
    ws.serializeAttachment(peer);this.send(ws,{type:'pong'});return;
   }
   if(peer.role!=='listener')throw new Error();
   if(Date.now()-peer.lastMessage<200)throw new Error();
   peer.lastMessage=Date.now();
   const frame=soundFrame(value);
   if(peer.lastSample!==undefined&&frame.sampledAt<=peer.lastSample)throw new Error();
   peer.lastSample=frame.sampledAt;ws.serializeAttachment(peer);
   for(const parent of this.ctx.getWebSockets('parent'))this.send(parent,frame);
  } catch {ws.close(1008,'Invalid live sound message.');}
 }
 webSocketClose(ws:WebSocket,code:number) {ws.close([1005,1006,1015].includes(code)?1001:code);this.demand();}
 webSocketError(ws:WebSocket) {ws.close(1011,'Connection unavailable.');this.demand();}
}
