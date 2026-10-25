import {describe,it,expect} from 'vitest';
import {Latency,safeTimingDetails,type TimingDetails} from '../src/latency';

function deferred<T>() {
 let resolve!:(value:T)=>void,reject!:(reason:unknown)=>void;
 const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};
}
const result=(id:number)=>({success:true,results:[{id}],meta:{duration:2,rows_read:3,rows_written:0,total_attempts:2}} as unknown as D1Result<{id:number}>);

describe('bounded read fallback and database metrics',()=>{
 it('keeps fast reads to one call and associates provider metrics with the stage',async()=>{
  const latency=new Latency();let calls=0;
  expect(await latency.readOnly('reminder_snapshot_ms',async()=>{calls++;return result(1);},5)).toEqual([result(1)]);
  await new Promise(r=>setTimeout(r,15));expect(calls).toBe(1);
  expect(latency.details.db_stages?.reminder_snapshot_ms).toEqual({calls:1,completed:1,statements:1,sql_ms:2,rows_read:3,rows_written:0,attempts:2});
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
