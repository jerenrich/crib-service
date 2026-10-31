import {describe,it,expect} from 'vitest';
import {LiveSound} from '../src/live-sound';
import {safeTimingDetails,type TimingDetails} from '../src/latency';
import type {Env} from '../src/types';

describe('live sound diagnostics',()=>{
 function fixture(databaseFails=false){
  const tasks:Promise<unknown>[]=[],rows:unknown[][]=[],closed:{code:number;reason?:string}[]=[];
  const peer={pair:{parent_id:'private-parent',listener_id:'private-listener',created_at:1},role:'parent',lastMessage:0,connectionID:crypto.randomUUID()};
  const socket={deserializeAttachment:()=>peer,serializeAttachment:()=>{},close:(code:number,reason?:string)=>closed.push({code,reason}),send:()=>{}} as unknown as WebSocket;
  const env={DB:{prepare:(sql:string)=>{
   if(databaseFails)throw new Error('private database exception with SQL and secret');
   return {bind:(...args:unknown[])=>({first:async()=>({ok:1}),run:async()=>{if(sql.startsWith('INSERT INTO diagnostics'))rows.push(args);return {success:true};}})};
  }}} as unknown as Env;
  const ctx={waitUntil:(task:Promise<unknown>)=>tasks.push(task),getWebSockets:()=>[]} as unknown as DurableObjectState;
  return {room:new LiveSound(ctx,env),socket,closed,tasks,rows,peer};
 }
 it('uses 1011 for a pairing-store outage instead of blaming the client',async()=>{
  const f=fixture(true);await f.room.webSocketMessage(f.socket,JSON.stringify({type:'ping'}));await Promise.all(f.tasks);
  expect(f.closed).toEqual([{code:1011,reason:'Connection unavailable.'}]);
 });
 it('uses 1008 for malformed messages and keeps only fixed, sampled diagnostic fields',async()=>{
  const f=fixture();
  for(let i=0;i<5;i++)await f.room.webSocketMessage(f.socket,'private malformed message containing a token');
  await Promise.all(f.tasks);
  expect(f.closed.every(close=>close.code===1008)).toBe(true);
  expect(f.rows).toHaveLength(1);
  const text=JSON.stringify(f.rows);
  expect(text).toContain('invalid_message');expect(text).toContain('rejected');
  expect(text).not.toContain('private');expect(text).not.toContain('token');
 });
 it('correlates relay acceptance with a command UUID and does not retain its settings or token',async()=>{
  const f=fixture(),id=crypto.randomUUID(),token=crypto.randomUUID();
  await f.room.webSocketMessage(f.socket,JSON.stringify({type:'nurserySoundCommand',id,controlToken:token,
   request:{settings:{sound:'twinkleTwinkle',volume:0.7,timerMinutes:60},action:'play',restartTimer:false}}));
  await Promise.all(f.tasks);
  const text=JSON.stringify(f.rows);
  expect(text).toContain(id);expect(text).toContain('command_relayed');expect(text).toContain('recipients');
  for(const value of [token,'twinkleTwinkle','timerMinutes','private-parent','private-listener','controlToken'])expect(text).not.toContain(value);
 });
 it('records one confirmation for repeated uppercase Swift UUIDs rather than every state tick',async()=>{
  const f=fixture();f.peer.role='listener';
  const commandID=crypto.randomUUID().toUpperCase();
  for(let i=0;i<5;i++)await f.room.webSocketMessage(f.socket,JSON.stringify({type:'nurserySoundState',commandID,controlToken:crypto.randomUUID(),
   state:{settings:{sound:'whiteNoise',volume:0.3,timerMinutes:20},playing:false,remainingSeconds:0}}));
  await Promise.all(f.tasks);
  expect(f.rows).toHaveLength(1);
  expect(JSON.stringify(f.rows)).toContain(commandID.toLowerCase());expect(JSON.stringify(f.rows)).toContain('confirmation_relayed');
 });
 it('bounds and redacts new diagnostic details before database insertion',()=>{
  const dirty={live_sound:{phase:'failed',role:'parent',reason:'pairing_store',close_code:1011,recipients:1,connection_id:crypto.randomUUID(),
   controlToken:'private-token',audio:'private-recording',exception:'private-error'}} as unknown as TimingDetails;
  const text=safeTimingDetails(dirty)!;
  expect(text).toContain('pairing_store');expect(text).toContain('1011');expect(text).not.toContain('private');
  expect(safeTimingDetails({live_sound:{phase:'private-phase'}} as unknown as TimingDetails)).toBeNull();
  const invalid={live_sound:{phase:'failed',role:'private-role',reason:'private-reason',close_code:99999,recipients:Infinity,connection_id:'private-identity'}} as unknown as TimingDetails;
  expect(safeTimingDetails(invalid)).toBe('{"live_sound":{"phase":"failed"}}');
 });
});
