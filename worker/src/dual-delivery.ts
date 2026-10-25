import type {Env} from './types';
import type {PushResult} from './apns';
import {Latency} from './latency';
import {PushPreparationError,recordDiagnostic} from './diagnostics';

type Target='phone'|'watch';
type State='pending'|'sent'|'blocked'|'uncertain'|'failed';

// The caller owns the existing event/notice lease and suppression checks. Each
// destination's result is committed separately before the aggregate is released.
// An unknown send is never replayed, even if the other destination needs a retry.
export async function deliverToBoth(env:Env,options:{
 table:'events'|'connection_notices';id:string;parentId:string;attempt:number;state:string;
 phoneToken:string|null;watchToken:string|null;requestId:string;eventRef?:string;
 source?:Latency['details']['dispatch_source'];
 send:(target:Target,token:string,timing:Latency)=>Promise<PushResult>;
}):Promise<State> {
 const {table,id,parentId,attempt}=options,key=table==='events'?'event_id':'id';
 const states=JSON.parse(options.state) as Record<Target,State>;
 const deliveries=await Promise.allSettled((['phone','watch'] as const).map(async target=>{
  if(['sent','uncertain','failed'].includes(states[target]))return;
  const token=target==='phone'?options.phoneToken:options.watchToken;
  const started=Date.now(),timing=new Latency();timing.eventRef=options.eventRef;
  timing.deliveryAttempt=attempt;timing.details.dispatch_source=options.source;
  let result:PushResult={status:'blocked',reason:'no_push_token'};
  if(token){
   try{result=await options.send(target,token,timing);}
   catch(error){timing.failure(error);result={status:'retry',reason:error instanceof PushPreparationError?error.code:'apns_configuration'};}
  }
  timing.details.push_outcome=result.status;
  const state:State=result.status==='retry'?'pending':result.status;
  const column=target==='phone'?'push_token':'watch_push_token';
  const statements:D1PreparedStatement[]=[];
  if(result.reason==='invalid_device_token'&&token){
   statements.push(env.DB.prepare(`UPDATE devices SET ${column}=NULL WHERE id=? AND ${column}=?`).bind(parentId,token));
   // Preserve a replacement uploaded while this rejected token was in flight.
   statements.push(env.DB.prepare(`UPDATE ${table} SET delivery_state=json_set(delivery_state,?,
    CASE WHEN EXISTS(SELECT 1 FROM devices WHERE id=? AND ${column} IS NOT NULL) THEN 'pending' ELSE 'blocked' END)
    WHERE ${key}=? AND status='sending' AND attempts=?`).bind(`$.${target}`,parentId,id,attempt));
  }else{
   statements.push(env.DB.prepare(`UPDATE ${table} SET delivery_state=json_set(delivery_state,?,?)
    WHERE ${key}=? AND status='sending' AND attempts=?`).bind(`$.${target}`,state,id,attempt));
  }
  await timing.db('outcome_storage_ms',()=>env.DB.batch(statements));
  await recordDiagnostic(env,{requestId:options.requestId,started,operation:'dispatch',stage:'push',
   outcome:result.reason??result.status,eventRef:options.eventRef,target,attempt,httpStatus:result.httpStatus,details:timing.details});
 }));
 const failure=deliveries.find((result):result is PromiseRejectedResult=>result.status==='rejected');
 if(failure)throw failure.reason;
 // Re-read committed results: concurrent JSON updates and replacement-token
 // decisions must be authoritative, rather than either sender's stale snapshot.
 const saved=await env.DB.prepare(`SELECT delivery_state FROM ${table} WHERE ${key}=? AND attempts=?`)
  .bind(id,attempt).first<{delivery_state:string}>();
 if(!saved)throw new Error('Delivery claim disappeared');
 const values=Object.values(JSON.parse(saved.delivery_state) as Record<Target,State>);
 const status:State=values.every(value=>value==='sent')?'sent':values.includes('pending')?'pending':
  values.includes('blocked')?'blocked':values.includes('uncertain')?'uncertain':'failed';
 await env.DB.prepare(`UPDATE ${table} SET status=?,next_attempt=?,lease_until=NULL,
  sent_at=CASE WHEN ?='sent' THEN ? ELSE sent_at END${table==='events'?",last_error=CASE WHEN ?='sent' THEN NULL ELSE ? END":''}
  WHERE ${key}=? AND status='sending' AND attempts=?`)
  .bind(status,Date.now()+Math.min(300000,2000*2**Math.min(attempt,8)),status,new Date().toISOString(),
   ...(table==='events'?[status,status==='uncertain'?'transport_unknown':'partial_delivery']:[]),id,attempt).run();
 return status;
}
