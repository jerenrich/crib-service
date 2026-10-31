import {APIError} from './types';
import {uuid} from './security';

function record(value:unknown):Record<string,unknown> {
 if(!value||typeof value!=='object'||Array.isArray(value))throw new APIError(400,'Invalid nursery sound control.');
 return value as Record<string,unknown>;
}
function keys(value:Record<string,unknown>,allowed:string[]) {
 if(Object.keys(value).some(key=>!allowed.includes(key)))throw new APIError(400,'Invalid nursery sound control.');
}
function settings(value:unknown) {
 const v=record(value);keys(v,['sound','volume','timerMinutes']);
 if(typeof v.sound!=='string'||!['whiteNoise','twinkleTwinkle'].includes(v.sound)||typeof v.volume!=='number'||!Number.isFinite(v.volume)||v.volume<0||v.volume>1
  ||typeof v.timerMinutes!=='number'||![5,10,20,30,60].includes(v.timerMinutes))throw new APIError(400,'Invalid nursery sound settings.');
 return v;
}
export function nurserySoundCommand(value:unknown) {
 const v=record(value);keys(v,['type','id','controlToken','request']);
 if(v.type!=='nurserySoundCommand')throw new APIError(400,'Invalid nursery sound command.');
 uuid(v.id);uuid(v.controlToken);
 const request=record(v.request);keys(request,['settings','action','restartTimer']);settings(request.settings);
 if(typeof request.action!=='string'||!['play','stop','updateSettings'].includes(request.action)||typeof request.restartTimer!=='boolean')throw new APIError(400,'Invalid nursery sound command.');
 return v;
}
export function nurserySoundState(value:unknown) {
 const v=record(value);keys(v,['type','state','requestID','controlToken','commandID','failure']);
 if(v.type!=='nurserySoundState')throw new APIError(400,'Invalid nursery sound state.');
 uuid(v.controlToken);
 if(v.requestID!=null)uuid(v.requestID);
 if(v.commandID!=null)uuid(v.commandID);
 if(v.failure!=null&&(typeof v.failure!=='string'||!['playbackFailed','expired','unavailable'].includes(v.failure)))throw new APIError(400,'Invalid nursery sound failure.');
 const state=record(v.state);keys(state,['settings','playing','remainingSeconds']);
 const s=settings(state.settings);
 if(typeof state.playing!=='boolean'||typeof state.remainingSeconds!=='number'||!Number.isFinite(state.remainingSeconds)
  ||state.remainingSeconds<0||state.remainingSeconds>Number(s.timerMinutes)*60
  ||(state.playing?state.remainingSeconds<=0:state.remainingSeconds!==0))throw new APIError(400,'Invalid nursery sound state.');
 return v;
}
