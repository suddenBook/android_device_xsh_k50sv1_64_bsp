from pathlib import Path
import hashlib,json,os,re,shlex,subprocess,time
trial=Path(__file__).resolve().parent
out=trial/'runtime/build19-gnss'; out.mkdir(exist_ok=False)
adb=['/home/desmond/Android/Sdk/platform-tools/adb','-s','0123456789ABCDEF']; env=dict(os.environ,ADB_LIBUSB='1')
steps=[]
def run(name,args):
 r=subprocess.run(adb+args,env=env,capture_output=True,timeout=180 if args[0] == 'install' else 35)
 (out/(name+'.txt')).write_bytes(r.stdout+r.stderr)
 steps.append(dict(step=name,exit_code=r.returncode))
 assert r.returncode==0,name
 return r.stdout.decode('utf-8','replace')
def sh(name,cmd): return run(name,['shell',cmd])
try:
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
 sh('launch','am start -W -n local.k50.gnssprobe/.ProbeActivity')
 time.sleep(8)
 sh('location-active','dumpsys location')
 sh('wakeup-active','cat /sys/kernel/debug/wakeup_sources')
 sh('kernel-active','dmesg')
 for index in range(4):
  time.sleep(29)
  run('progress-'+str(index),['logcat','-d','-v','threadtime','-s','K50GnssProbe:I','AndroidRuntime:E'])
 time.sleep(5)
 log=run('log',['logcat','-d','-v','threadtime','-s','K50GnssProbe:I','AndroidRuntime:E'])
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
 (out/'steps.json').write_text(json.dumps(steps,indent=2)+'\n')
