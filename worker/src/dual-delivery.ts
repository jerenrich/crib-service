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
  try{
   await timing.db('outcome_storage_ms',()=>env.DB.batch(statements));
  }catch(error){
   // Keep the known Apple result even if functional persistence fails. This
   // evidence never authorizes replay of a delivery with ambiguous transport.
   timing.failure(error);
   await recordDiagnostic(env,{requestId:options.requestId,started,operation:'dispatch',stage:'storage',
    outcome:'internal_error',eventRef:options.eventRef,target,attempt,httpStatus:result.httpStatus,details:timing.details});
   throw error;
  }
  await recordDiagnostic(env,{requestId:options.requestId,started,operation:'dispatch',stage:'push',
   outcome:result.reason??result.status,eventRef:options.eventRef,target,attempt,httpStatus:result.httpStatus,details:timing.details});
 }));
 const failure=deliveries.find((result):result is PromiseRejectedResult=>result.status==='rejected');
 if(failure)throw failure.reason;
 // Decide current token eligibility and release the claim in one statement.
 // Registration before this write sees 'sending'; registration afterward sees
 // 'blocked'. Both orderings must wake the target, without replaying acceptance.
 const saved=await env.DB.prepare(`WITH states AS MATERIALIZED (
  SELECT
   CASE WHEN json_extract(delivery_state,'$.phone')='blocked' AND EXISTS(SELECT 1 FROM devices d WHERE d.id=${table}.parent_id AND d.push_token IS NOT NULL)
    THEN 'pending' ELSE json_extract(delivery_state,'$.phone') END AS phone,
   CASE WHEN json_extract(delivery_state,'$.watch')='blocked' AND EXISTS(SELECT 1 FROM devices d WHERE d.id=${table}.parent_id AND d.watch_push_token IS NOT NULL)
    THEN 'pending' ELSE json_extract(delivery_state,'$.watch') END AS watch
  FROM ${table} WHERE ${key}=? AND status='sending' AND attempts=?
 ), outcome AS (
  SELECT phone,watch,CASE WHEN phone='sent' AND watch='sent' THEN 'sent'
   WHEN phone='pending' OR watch='pending' THEN 'pending'
   WHEN phone='blocked' OR watch='blocked' THEN 'blocked'
   WHEN phone='uncertain' OR watch='uncertain' THEN 'uncertain' ELSE 'failed' END AS status FROM states
 ) UPDATE ${table} SET delivery_state=(SELECT json_object('phone',phone,'watch',watch) FROM outcome),
  status=(SELECT status FROM outcome),next_attempt=?,lease_until=NULL,
  sent_at=CASE WHEN (SELECT status FROM outcome)='sent' THEN ? ELSE sent_at END
  ${table==='events'?",last_error=CASE (SELECT status FROM outcome) WHEN 'sent' THEN NULL WHEN 'uncertain' THEN 'transport_unknown' ELSE 'partial_delivery' END":''}
  WHERE ${key}=? AND status='sending' AND attempts=? RETURNING status`)
  .bind(id,attempt,Date.now()+Math.min(300000,2000*2**Math.min(attempt,8)),new Date().toISOString(),id,attempt).first<{status:State}>();
 if(!saved){
  // Cron can recover an expired lease while target journals are still awaiting
  // D1. Observe that decision without overwriting it or reporting false failure.
  const recovered=await env.DB.prepare(`SELECT status FROM ${table} WHERE ${key}=? AND attempts=?`)
   .bind(id,attempt).first<{status:State}>();
  if(recovered&&['sent','uncertain'].includes(recovered.status))return recovered.status;
  throw new Error('Delivery claim disappeared');
 }
 return saved.status;
}
