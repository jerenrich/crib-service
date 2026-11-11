// Imports nothing, so any module (timeline included) can use it without a cycle.
// Connection-loss timing. A Listener counts as offline after 3 minutes without an
// update, or after the Parent's alert delay when that is shorter. The alert waits
// for the Parent's chosen delay (`outageAlertCutoffSQL`, ISO text comparable with
// received_at, `?` bound to now in ms, `device` the Parent row). Once recorded, an
// outage stays current until the heartbeat changes: later checks match only the
// heartbeat, so changing the delay mid-outage can postpone an alert but never retire one.
export const offlineDetectionMs=180000;
export const connectionAlertDelays=Array.from({length:20},(_,i)=>(i+1)*60);
export const outageAlertCutoffSQL=(device='d')=>`strftime('%Y-%m-%dT%H:%M:%fZ',(?-${device}.connection_alert_delay*1000)/1000.0,'unixepoch')`;
/** Milliseconds of silence before a Listener counts as offline for this Parent. */
export const offlineAfterMs=(delaySeconds:number)=>Math.min(offlineDetectionMs,delaySeconds*1000);
