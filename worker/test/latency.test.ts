import {describe,it,expect,vi} from 'vitest';
import {Latency,safeTimingDetails,type TimingDetails} from '../src/latency';

function deferred<T>() {
 let resolve!:(value:T)=>void,reject!:(reason:unknown)=>void;
 const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};
}
const result=(id:number)=>({success:true,results:[{id}],meta:{duration:2,rows_read:3,rows_written:0,total_attempts:2}} as unknown as D1Result<{id:number}>);

describe('bounded read fallback and database metrics',()=>{
 it('keeps local spans stable across a wall-clock adjustment',async()=>{
  const latency=new Latency(),wall=Date.now();
  const clock=vi.spyOn(Date,'now').mockReturnValue(wall);
  try {
   await latency.measure('claim_ms',async()=>{clock.mockReturnValue(wall+3600000);});
   expect(latency.details.spans?.claim_ms).toBeLessThan(1000);
  }finally{clock.mockRestore();}
 });
 it('keeps fast reads to one call and associates provider metrics with the stage',async()=>{
  const latency=new Latency();let calls=0;
  expect(await latency.readOnly('reminder_snapshot_ms',async()=>{calls++;return result(1);},5)).toEqual([result(1)]);
  await new Promise(r=>setTimeout(r,15));expect(calls).toBe(1);
  expect(latency.details.db_stages?.reminder_snapshot_ms).toEqual({calls:1,completed:1,statements:1,sql_ms:2,rows_read:3,rows_written:0,attempts:2,retries:1,statement_meta:[{index:0,sql_ms:2,attempts:2}]});
  expect(latency.details.db_calls).toBe(1);expect(latency.details.db_attempts).toBe(2);
 });
 it('uses one fallback for a stalled read and ignores a late rejected loser',async()=>{
  const latency=new Latency(),first=deferred<D1Result<{id:number}>>();let calls=0;
  expect(await latency.readOnly('reminder_snapshot_ms',()=>++calls===1?first.promise:Promise.resolve(result(2)),5)).toEqual([result(2)]);
  expect(calls).toBe(2);expect(latency.details.db_stages?.reminder_snapshot_ms).toMatchObject({calls:2,completed:1,hedges:1,hedge_wins:1,unfinished:1,attempts:2});
  const frozen=JSON.stringify(latency.details);first.reject(new Error('D1_ERROR: private-late-error'));
  await new Promise(r=>setTimeout(r,15));expect(JSON.stringify(latency.details)).toBe(frozen);
 });
 it('lets the original succeed after the fallback fails, without a third call',async()=>{
  const latency=new Latency(),first=deferred<D1Result<{id:number}>>(),fallback=deferred<void>();let calls=0;
  const read=latency.readOnly('reminder_snapshot_ms',()=>{calls++;if(calls===1)return first.promise;fallback.resolve();return Promise.reject(new Error('D1_ERROR: timeout'));},5);
  await fallback.promise;await new Promise(r=>setTimeout(r,5));first.resolve(result(1));
  expect(await read).toEqual([result(1)]);expect(calls).toBe(2);
  expect(latency.details.db_stages?.reminder_snapshot_ms).toMatchObject({calls:2,completed:1,errors:1,hedges:1});expect(latency.details.failed_span).toBeUndefined();
 });
 it('reports both failed reads once and retains only fixed failure categories',async()=>{
  const latency=new Latency();let calls=0;
  await expect(latency.readOnly('reminder_snapshot_ms',async()=>{calls++;throw new Error('D1_ERROR: timed out private-marker');},5)).rejects.toThrow();
  expect(calls).toBe(2);expect(latency.details.db_stages?.reminder_snapshot_ms).toEqual({calls:2,errors:2,hedges:1});
  expect(latency.details).toMatchObject({failed_span:'reminder_snapshot_ms',error_kind:'d1_timeout'});expect(safeTimingDetails(latency.details)).not.toContain('private-marker');
 });
 it('does not retry a database mutation after failure',async()=>{
  const latency=new Latency();let calls=0;
  await expect(latency.db('claim_ms',async()=>{calls++;throw new Error('D1_ERROR: timeout');})).rejects.toThrow();
  expect(calls).toBe(1);expect(latency.details.db_stages?.claim_ms).toEqual({calls:1,errors:1});
 });
 it('allowlists nested stages and metrics and omits absent provider data',async()=>{
  const latency=new Latency();await latency.db('claim_ms',async()=>({success:true,results:[]} as unknown as D1Result));
  expect(latency.details.db_stages?.claim_ms).toEqual({calls:1,completed:1,statements:1});expect(latency.details.db_sql_ms).toBeUndefined();
  const unsafe={db_stages:{claim_ms:{calls:1,sql_ms:NaN,attempts:-1,private:'secret'},private:{calls:99}}} as unknown as TimingDetails;
  expect(JSON.parse(safeTimingDetails(unsafe)!)).toEqual({db_stages:{claim_ms:{calls:1}}});
 });
});

describe('D1 serving and per-statement retry evidence',()=>{
 it('distinguishes four statements from retries and retains only bounded serving metadata',async()=>{
  const latency=new Latency();
  await latency.db('claim_ms',async()=>Array.from({length:4},(_,index)=>({success:true,results:[],meta:{duration:0.2,total_attempts:index===3?2:1,served_by_colo:'AMS',served_by_region:'WEUR',served_by_primary:true,private:'secret'}} as unknown as D1Result)));
  const stage=JSON.parse(safeTimingDetails(latency.details)!).db_stages.claim_ms;
  expect(stage).toMatchObject({statements:4,attempts:5,retries:1});
  expect(stage.statement_meta).toEqual(Array.from({length:4},(_,index)=>({index,sql_ms:0.2,attempts:index===3?2:1,colo:'AMS',region:'WEUR',primary:true})));
  expect(JSON.stringify(stage)).not.toContain('secret');
 });
 it('rejects untrusted location values, extra keys and oversized metadata arrays',()=>{
  const details={db_stages:{claim_ms:{statement_meta:Array.from({length:100},(_,index)=>({index,colo:'private-marker',region:'private-marker',primary:'private-marker',attempts:-1,sql_ms:Infinity,private:'secret'}))}},durable_outcome:true,outcome_recovery:false,outcome_queue_age_ms:30} as unknown as TimingDetails;
  const safe=JSON.parse(safeTimingDetails(details)!);
  expect(safe.db_stages.claim_ms.statement_meta).toHaveLength(16);expect(safe.db_stages.claim_ms.statement_meta[0]).toEqual({index:0});
  expect(safe).toMatchObject({durable_outcome:true,outcome_recovery:false,outcome_queue_age_ms:30});expect(JSON.stringify(safe)).not.toMatch(/private|secret|Infinity/);
 });
});

describe('one-write ownership receipt recovery',()=>{
 it('keeps fast claims to one mutation and no receipt read',async()=>{
  const latency=new Latency(),write=vi.fn(async()=>[result(1)]),proof=vi.fn(async()=>result(2));
  expect(await latency.confirmedClaim(write,proof,5)).toEqual({source:'reply',results:[result(1)]});
  await new Promise(r=>setTimeout(r,10));expect(write).toHaveBeenCalledOnce();expect(proof).not.toHaveBeenCalled();
 });
 it('accepts committed ownership while a reply is delayed and freezes the trace before a late rejection',async()=>{
  const latency=new Latency(),write=deferred<D1Result<{id:number}>[]>();let writes=0,reads=0;
  expect(await latency.confirmedClaim(()=>{writes++;return write.promise;},async()=>{reads++;return result(2);},5)).toEqual({source:'receipt',receipt:{id:2}});
  const frozen=JSON.stringify(latency.details);write.reject(new Error('D1_ERROR: private-late-marker'));await new Promise(r=>setTimeout(r,10));
  expect(writes).toBe(1);expect(reads).toBe(1);expect(JSON.stringify(latency.details)).toBe(frozen);
 });
 it('never treats an absent ownership receipt as permission to send',async()=>{
  const latency=new Latency(),write=deferred<D1Result<{id:number}>[]>(),read=deferred<void>();let done=false;
  const running=latency.confirmedClaim(()=>write.promise,async()=>{read.resolve();return {...result(2),results:[]};},5).then(value=>{done=true;return value;});
  await read.promise;await new Promise(r=>setTimeout(r,5));expect(done).toBe(false);
  write.resolve([result(1)]);expect(await running).toEqual({source:'reply',results:[result(1)]});
  expect(latency.details.claim_receipt_outcome).toBe('missing');
 });
 it('recovers a lost reply only with an owned committed row, and otherwise preserves the write failure',async()=>{
  const latency=new Latency();expect(await latency.confirmedClaim(async()=>{throw new Error('D1_ERROR: timeout');},async()=>result(2),5)).toEqual({source:'receipt',receipt:{id:2}});
  expect(latency.details.error_kind).toBeUndefined();expect(latency.details.db_stages?.claim_ms?.errors).toBe(1);
  const failed=new Latency();let writes=0,reads=0;
  await expect(failed.confirmedClaim(async()=>{writes++;throw new Error('D1_ERROR: private-write-marker');},async()=>{reads++;return {...result(2),results:[]};},5)).rejects.toThrow('private-write-marker');
  expect(writes).toBe(1);expect(reads).toBe(1);expect(failed.details.failed_span).toBe('claim_ms');expect(safeTimingDetails(failed.details)).not.toContain('private-write-marker');
 });
 it('ignores a late failing receipt when the original write reply wins',async()=>{
  const latency=new Latency(),write=deferred<D1Result<{id:number}>[]>(),proof=deferred<D1Result<{id:number}>>(),started=deferred<void>();
  const running=latency.confirmedClaim(()=>write.promise,()=>{started.resolve();return proof.promise;},5);await started.promise;
  write.resolve([result(1)]);expect(await running).toEqual({source:'reply',results:[result(1)]});
  const frozen=JSON.stringify(latency.details);proof.reject(new Error('private-receipt-error'));await new Promise(r=>setTimeout(r,10));expect(JSON.stringify(latency.details)).toBe(frozen);
 });
 it('fails closed when both the write and receipt fail',async()=>{
  const latency=new Latency();let writes=0,reads=0;
  await expect(latency.confirmedClaim(async()=>{writes++;throw new Error('D1_ERROR: original');},async()=>{reads++;throw new Error('private-receipt-error');},5)).rejects.toThrow('original');
  expect(writes).toBe(1);expect(reads).toBe(1);expect(latency.details.claim_receipt_outcome).toBe('error');
 });
});
