import {afterEach,beforeEach,describe,expect,it,vi} from 'vitest';
import {PhoneHeadStart,phoneHeadStartFor} from '../src/notification-coordination';
import {Latency,safeTimingDetails,type TimingDetails} from '../src/latency';
import type {Env} from '../src/types';

describe('bounded phone-first coordination',()=>{
 beforeEach(()=>{vi.useFakeTimers({toFake:['setTimeout','clearTimeout','performance']});});
 afterEach(()=>{vi.useRealTimers();});
 it('measures the lead from the phone request, without depending on its HTTP response',async()=>{
  const head=new PhoneHeadStart(350),phone=new Latency(),watch=new Latency();
  const phoneSchedule=head.schedule('phone',phone),watchSchedule=head.schedule('watch',watch);
  phoneSchedule.requestStarted!();let ready=false;
  const wait=watchSchedule.beforeRequest!().then(()=>{ready=true;});
  await vi.advanceTimersByTimeAsync(349);expect(ready).toBe(false);
  await vi.advanceTimersByTimeAsync(1);await wait;watchSchedule.requestStarted!();
  expect(watch.details).toMatchObject({coordination_mode:'phone_head_start',phone_head_start_ms:350,phone_head_start_observed_ms:350,
   phone_head_start_wait_outcome:'head_start_elapsed',spans:{coordination_wait_ms:350}});
  expect(vi.getTimerCount()).toBe(0); // Phone response is still outstanding.
 });
 it('supports the selected 500 ms trial without extending the Watch-ready cap',async()=>{
  const head=new PhoneHeadStart(500),watch=new Latency();head.schedule('phone',new Latency()).requestStarted!();
  const schedule=head.schedule('watch',watch),wait=schedule.beforeRequest!();
  await vi.advanceTimersByTimeAsync(500);await wait;schedule.requestStarted!();
  expect(watch.details).toMatchObject({phone_head_start_ms:500,phone_head_start_cap_ms:500,phone_head_start_wait_outcome:'head_start_elapsed',
   phone_head_start_observed_ms:500,spans:{coordination_wait_ms:500}});expect(vi.getTimerCount()).toBe(0);
 });
 it('still provides a full lead when phone preparation finishes after the Watch is ready',async()=>{
  const head=new PhoneHeadStart(350),watch=new Latency(),schedule=head.schedule('watch',watch);let ready=false;
  const wait=schedule.beforeRequest!().then(()=>{ready=true;});
  await vi.advanceTimersByTimeAsync(100);head.schedule('phone',new Latency()).requestStarted!();
  await vi.advanceTimersByTimeAsync(349);expect(ready).toBe(false);
  await vi.advanceTimersByTimeAsync(1);await wait;
  expect(watch.details).toMatchObject({phone_head_start_wait_outcome:'head_start_elapsed',spans:{coordination_wait_ms:450}});
 });
 it('caps Watch waiting when phone preparation never starts its request',async()=>{
  const head=new PhoneHeadStart(350),watch=new Latency(),schedule=head.schedule('watch',watch);let ready=false;
  const wait=schedule.beforeRequest!().then(()=>{ready=true;});
  await vi.advanceTimersByTimeAsync(499);expect(ready).toBe(false);
  await vi.advanceTimersByTimeAsync(1);await wait;schedule.requestStarted!();
  expect(watch.details).toMatchObject({phone_head_start_wait_outcome:'wait_cap',spans:{coordination_wait_ms:500}});
  expect(watch.details.phone_head_start_observed_ms).toBeUndefined();
  const frozen=JSON.stringify(watch.details);head.schedule('phone',new Latency()).requestStarted!();
  await vi.advanceTimersByTimeAsync(1000);expect(JSON.stringify(watch.details)).toBe(frozen);expect(vi.getTimerCount()).toBe(0);
 });
 it('does not extend the cap when the phone request starts near the deadline',async()=>{
  const head=new PhoneHeadStart(350),watch=new Latency(),schedule=head.schedule('watch',watch);let ready=false;
  const wait=schedule.beforeRequest!().then(()=>{ready=true;});
  await vi.advanceTimersByTimeAsync(450);head.schedule('phone',new Latency()).requestStarted!();
  await vi.advanceTimersByTimeAsync(49);expect(ready).toBe(false);
  await vi.advanceTimersByTimeAsync(1);await wait;schedule.requestStarted!();
  expect(watch.details).toMatchObject({phone_head_start_wait_outcome:'wait_cap',phone_head_start_observed_ms:50,spans:{coordination_wait_ms:500}});
  expect(vi.getTimerCount()).toBe(0);
 });
 it('releases the Watch immediately when phone preparation fails',async()=>{
  const head=new PhoneHeadStart(350),watch=new Latency();const wait=head.schedule('watch',watch).beforeRequest!();
  head.phoneFinished();await wait;
  expect(watch.details).toMatchObject({phone_head_start_wait_outcome:'phone_unavailable',spans:{coordination_wait_ms:0}});expect(vi.getTimerCount()).toBe(0);
 });
 it('does not add another delay when the phone already has its lead',async()=>{
  const head=new PhoneHeadStart(350),watch=new Latency();head.schedule('phone',new Latency()).requestStarted!();
  await vi.advanceTimersByTimeAsync(400);const schedule=head.schedule('watch',watch);await schedule.beforeRequest!();schedule.requestStarted!();
  expect(watch.details).toMatchObject({phone_head_start_observed_ms:400,spans:{coordination_wait_ms:0}});expect(vi.getTimerCount()).toBe(0);
 });
});

describe('pair-scoped coordination settings and diagnostics',()=>{
 it('limits the corrected trial to marked tests and rejects overlapping experiments',()=>{
  const configured={PHONE_HEAD_START_TEST_PARENT_ID:'parent'} as Env;
  expect(phoneHeadStartFor(configured,'parent',true)).toBe(500);
  expect(phoneHeadStartFor(configured,'parent')).toBe(0);
  expect(phoneHeadStartFor(configured,'other',true)).toBe(0);
  for(const key of ['WATCH_ONLY_PARENT_ID','PHONE_ONLY_TEST_PARENT_ID','DISTINCT_APNS_ID_TEST_PARENT_ID','SEPARATE_COLLAPSE_ID_TEST_PARENT_ID']){
   expect(phoneHeadStartFor({...configured,[key]:'parent'},'parent',true)).toBe(0);
  }
 });
 it('requires an exact Parent opt-in and a small valid delay',()=>{
  const base={WATCH_PHONE_HEAD_START_PARENT_ID:'parent',WATCH_PHONE_HEAD_START_MS:'350'} as Env;
  expect(phoneHeadStartFor(base,'parent')).toBe(350);expect(phoneHeadStartFor(base,'other')).toBe(0);
  for(const value of ['','0','501','10000','-1','NaN','350.5','350private'])expect(phoneHeadStartFor({...base,WATCH_PHONE_HEAD_START_MS:value},'parent')).toBe(0);
  expect(phoneHeadStartFor({} as Env,'parent')).toBe(0);
 });
 it('does not retain arbitrary coordination modes, identifiers or outcomes',()=>{
  const unsafe={coordination_mode:'private-parent-id',phone_head_start_wait_outcome:'private-payload',phone_head_start_ms:Infinity,
   phone_head_start_observed_ms:-1,notification_route:'private-route',phone_suppressed:'private-value',phone_fallback:1,spans:{coordination_wait_ms:NaN}} as unknown as TimingDetails;
  expect(safeTimingDetails(unsafe)).toBeNull();
  expect(JSON.parse(safeTimingDetails({coordination_mode:'phone_head_start',phone_head_start_wait_outcome:'wait_cap',phone_head_start_ms:350,phone_head_start_cap_ms:500})!))
   .toMatchObject({coordination_mode:'phone_head_start',phone_head_start_wait_outcome:'wait_cap',phone_head_start_ms:350,phone_head_start_cap_ms:500});
  expect(JSON.parse(safeTimingDetails({notification_route:'watch_only',phone_suppressed:true,phone_fallback:false})!))
   .toEqual({notification_route:'watch_only',phone_suppressed:true,phone_fallback:false});
 });
});
