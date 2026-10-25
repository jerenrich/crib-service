import {describe,it,expect} from 'vitest';
import {StatusDiagnosticSampler} from '../src/status-diagnostics';

describe('bounded status success sampling',()=>{
 it('keeps first/periodic and every slow success while counting omitted ordinary rows',()=>{
  const sampler=new StatusDiagnosticSampler();expect(sampler.take(50,1000)).toEqual({record:true,sampled:0});
  for(let i=0;i<20;i++)expect(sampler.take(50,1001+i)).toEqual({record:false,sampled:0});
  expect(sampler.take(2000,2000)).toEqual({record:true,sampled:20});
  expect(sampler.take(2001,2001)).toEqual({record:true,sampled:0});
  expect(sampler.take(20,2002)).toEqual({record:false,sampled:0});
  expect(sampler.take(20,32001)).toEqual({record:true,sampled:1});
 });
 it('records again after a clock reversal instead of indefinitely suppressing rows',()=>{
  const sampler=new StatusDiagnosticSampler();sampler.take(1,50000);sampler.take(1,50001);
  expect(sampler.take(1,1000)).toEqual({record:true,sampled:1});
 });
});
