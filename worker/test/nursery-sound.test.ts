import {describe,it,expect} from 'vitest';
import {nurserySoundCommand,nurserySoundState} from '../src/nursery-sound';

const settings=()=>({sound:'whiteNoise',volume:0.3,timerMinutes:20});
const command=()=>({type:'nurserySoundCommand',id:crypto.randomUUID(),controlToken:crypto.randomUUID(),request:{settings:settings(),action:'play',restartTimer:false}});
const state=()=>({type:'nurserySoundState',controlToken:crypto.randomUUID(),requestID:crypto.randomUUID(),state:{settings:settings(),playing:true,remainingSeconds:1000}});
describe('nursery sound controls',()=>{
 it('distinguishes explicit Play and Stop from edits and rejects legacy playing flags',()=>{
  const base=command();
  for(const action of ['play','stop','updateSettings'])expect(nurserySoundCommand({...base,request:{...base.request,action}})).toBeTruthy();
  expect(()=>nurserySoundCommand({...base,request:{settings:settings(),playing:true,restartTimer:false}})).toThrow();
 });
 it('accepts both sounds and exactly the five timers',()=>{
  for(const sound of ['whiteNoise','twinkleTwinkle'])for(const timerMinutes of [5,10,20,30,60]){
   const value=command();value.request.settings={sound,timerMinutes,volume:0.3};
   expect(nurserySoundCommand(value)).toEqual(value);
  }
 });
 it('rejects invalid values, extra fields, recordings, and arbitrary commands',()=>{
  const base=command();
  for(const value of [{...base,id:'bad'}, {...base,controlToken:'bad'}, {...base,audio:'recording'},
   {...base,request:{...base.request,settings:{...settings(),sound:'upload'}}},
   {...base,request:{...base.request,settings:{...settings(),timerMinutes:15}}},
   ...[-1,1.1,NaN,Infinity].map(volume=>({...base,request:{...base.request,settings:{...settings(),volume}}})),
   {...base,request:{...base.request,action:'invalid'}},{...base,request:{...base.request,restartTimer:null}},
   {...base,request:{...base.request,action:['play']}}, {...base,request:{...base.request,settings:{...settings(),sound:['whiteNoise']}}},
   {...base,request:{...base.request,settings:{...settings(),file:'remote-url'}}}])expect(()=>nurserySoundCommand(value)).toThrow();
 });
 it('accepts confirmed states and rejects impossible countdowns and arbitrary error text',()=>{
  const base=state();expect(nurserySoundState(base)).toEqual(base);
  expect(nurserySoundState({...base,state:{...base.state,playing:false,remainingSeconds:0}})).toBeTruthy();
  for(const value of [{...base,state:{...base.state,playing:false}},
   ...[-1,0,1201,Infinity,NaN].map(remainingSeconds=>({...base,state:{...base.state,remainingSeconds}})),
   {...base,failure:'untrusted message'}, {...base,failure:['expired']}, {...base,commandID:'bad'}, {...base,requestID:'bad'}, {...base,state:{...base.state,recording:'audio'}}])
   expect(()=>nurserySoundState(value)).toThrow();
 });
});
