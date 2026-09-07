from pathlib import Path
import hashlib,json,os,re,shlex,subprocess,time
trial=Path(__file__).resolve().parent
out=trial/'runtime/build19-gnss'; out.mkdir(exist_ok=False)
adb=['/home/desmond/Android/Sdk/platform-tools/adb','-s','0123456789ABCDEF']; env=dict(os.environ,ADB_LIBUSB='1')
steps=[]
search_restore_required=False
search_component=None
log_arguments=['logcat','-d','-b','main','-v','threadtime','-v','monotonic','-v','usec','-s','K50GnssProbe:I','AndroidRuntime:E']
def run(name,args):
 r=subprocess.run(adb+args,env=env,capture_output=True,timeout=180 if args[0] == 'install' else 35)
 (out/(name+'.txt')).write_bytes(r.stdout+r.stderr)
 steps.append(dict(step=name,exit_code=r.returncode))
 assert r.returncode==0,name
 return r.stdout.decode('utf-8','replace')
def sh(name,cmd): return run(name,['shell',cmd])
def gnss_records(text):
 return [line for line in text.splitlines() if re.match(r'^\s*\d+\.\d+\s+\d+\s+\d+\s+I\s+K50GnssProbe\s*:',line)]
try:
 search_package='com.google.android.googlequicksearchbox'
 package_before=sh('search-package-before','dumpsys package '+search_package)
 search_user=re.search(r'^\s*User 0:.*\bstopped=(true|false)\b',package_before,re.M)
 assert search_user, 'Search package stopped state is unavailable'
 assert search_package+'/.SearchActivity filter ' in package_before
 resolved=sh('search-launcher-component','cmd package resolve-activity --brief --user 0 -n '+search_package+'/.SearchActivity').strip().splitlines()
 assert resolved and re.fullmatch(r'[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+',resolved[-1])
 search_component=resolved[-1]
 assert search_component.startswith(search_package+'/')
 search_restore_required=search_user[1]=='false'
 sh('pause-observed-search-request-source','am force-stop '+search_package)
 sh('reset-old-probe-process','am force-stop local.k50.gnssprobe')
 assert not sh('old-probe-process-absent','pidof local.k50.gnssprobe || true').strip()
 idle_observations=[]
 for attempt in range(60):
  idle=sh('gps-idle-observation-'+str(attempt),'dumpsys location')
  active=idle.split('  Location Listeners:',1)[1].split('  Historical Records by Provider:',1)[0]
  idle_now='UpdateRecord[gps ' not in active and re.search(r'^\s*mStarted=false\b',idle,re.M) is not None
  idle_observations.append(dict(attempt=attempt,gps_idle=idle_now))
  if idle_now:break
  time.sleep(1)
 else:raise RuntimeError('GPS did not become idle after pausing the observed request source')
 (out/'idle-preparation.json').write_text(json.dumps(dict(status='PASS',original_search_stopped=search_user[1],observations=idle_observations),indent=2)+'\n')
 identity=sh('identity','cat /proc/sys/kernel/random/boot_id; cat /proc/sys/kernel/tainted; cat /proc/uptime; settings get secure location_mode')
 lines=identity.splitlines(); assert lines[-1]=='3'; start=float(lines[2].split()[0])
 sh('location-before','dumpsys location')
 sh('wakeup-before','cat /sys/kernel/debug/wakeup_sources')
 apk=trial/'gnss-probe/gnss-probe.apk'; digest=hashlib.sha256(apk.read_bytes()).hexdigest()
 installed=sh('installed-path','pm path local.k50.gnssprobe').strip().splitlines()
 assert len(installed)==1 and installed[0].startswith('package:/data/app/'), installed
 assert sh('installed-hash','sha256sum '+shlex.quote(installed[0].removeprefix('package:'))).split()[0]==digest
 sh('permission','pm grant local.k50.gnssprobe android.permission.ACCESS_FINE_LOCATION; pm grant local.k50.gnssprobe android.permission.ACCESS_COARSE_LOCATION')
 sh('appops','appops set --uid local.k50.gnssprobe FINE_LOCATION allow; appops set --uid local.k50.gnssprobe COARSE_LOCATION allow')
 sh('wake','input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'); time.sleep(2)
 prior_log=run('prior-gnss-history',log_arguments)
 prior_records=gnss_records(prior_log)
 sh('launch','am start -W -n local.k50.gnssprobe/.ProbeActivity')
 probe_pids=sh('new-probe-pid','pidof local.k50.gnssprobe').split()
 assert len(probe_pids)==1 and probe_pids[0].isdigit()
 time.sleep(8)
 sh('location-active','dumpsys location')
 sh('wakeup-active','cat /sys/kernel/debug/wakeup_sources')
 sh('kernel-active','dmesg')
 for index in range(4):
  time.sleep(29)
  run('progress-'+str(index),['logcat','-d','-v','threadtime','-s','K50GnssProbe:I','AndroidRuntime:E'])
 time.sleep(5)
 full_log=run('log',log_arguments)
 all_records=gnss_records(full_log)
 assert all_records[:len(prior_records)]==prior_records, 'Retained GNSS history changed or wrapped'
 fresh_records=all_records[len(prior_records):]
 assert fresh_records and all(re.match(r'^\s*\d+\.\d+\s+(\d+)',line)[1]==probe_pids[0] for line in fresh_records)
 log='\n'.join(fresh_records)+'\n'
 (out/'new-run-log.txt').write_text(log)
 (out/'log-history-boundary.json').write_text(json.dumps(dict(status='PASS',old_process_verified_absent=True,new_pid=int(probe_pids[0]),prior_records=len(prior_records),fresh_records=len(fresh_records),prior_log_sha256=hashlib.sha256(prior_log.encode()).hexdigest(),full_log_sha256=hashlib.sha256(full_log.encode()).hexdigest(),new_run_log_sha256=hashlib.sha256(log.encode()).hexdigest(),basis='Exact retained old GNSS record prefix, captured after the old process exited and before the new launch; appended records all match the new probe PID. No log buffer was cleared.'),indent=2)+'\n')
 sh('location-after','dumpsys location')
 sh('wakeup-after','cat /sys/kernel/debug/wakeup_sources')
 final=sh('final-identity','cat /proc/sys/kernel/random/boot_id; cat /proc/sys/kernel/tainted; cat /proc/uptime')
 end=float(final.splitlines()[2].split()[0])
 kernel=[]
 for line in (trial/'runtime/build19-normal-reboot-early/continuous-kmsg.txt').read_text(errors='replace').splitlines():
  m=re.match(r'\d+,\d+,(\d+),[^;]*;(.*)',line)
  if m and start<=int(m[1])/1000000<=end: kernel.append(line)
 (out/'kernel-interval.txt').write_text('\n'.join(kernel)+'\n')
 faults=[line for line in kernel if re.search(r'\bWARNING:|\bBUG:|\bOops:|\bUnable to handle|\bKernel panic',line)]
 summary=[line for line in log.splitlines() if ' summary ' in line]
 result=dict(boot_id=lines[0],apk_sha256=digest,summary=summary,log=log,kernel_interval=[start,end],kernel_records=len(kernel),new_faults=faults,final_identity=final)
 (out/'result.json').write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result),flush=True)
 assert final.splitlines()[:2]==[lines[0],'0'] and kernel and not faults
 assert len(summary)==1 and 'started=true stopped=true' in summary[0]
 assert int(re.search(r'status_callbacks=(\d+)',summary[0])[1])>0
 assert 'gnss_started' in log and 'gnss_stopped' in log
finally:
 fixture=dict(status='PASS',search_restore_required=search_restore_required)
 try:
  if search_restore_required:
   sh('restore-search-availability','am start -W -n '+shlex.quote(search_component))
   restored=sh('search-package-restored','dumpsys package com.google.android.googlequicksearchbox')
   assert re.search(r'^\s*User 0:.*\bstopped=false\b',restored,re.M)
  sh('restore-home-after-gnss','input keyevent KEYCODE_HOME')
 except BaseException as error:
  fixture['status']='FAIL';fixture['error']=repr(error)
  raise
 finally:
  (out/'fixture-restoration.json').write_text(json.dumps(fixture,indent=2)+'\n')
  (out/'steps.json').write_text(json.dumps(steps,indent=2)+'\n')
