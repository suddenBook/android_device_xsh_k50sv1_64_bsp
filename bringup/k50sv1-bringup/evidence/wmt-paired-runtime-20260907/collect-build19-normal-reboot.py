from pathlib import Path
import json,os,re,subprocess,time
trial=Path(__file__).resolve().parent
out=trial/'runtime/build19-normal-reboot-early';out.mkdir(exist_ok=False)
adb=['/home/desmond/Android/Sdk/platform-tools/adb','-s','0123456789ABCDEF'];env=dict(os.environ,ADB_LIBUSB='1')
stage=trial/'tier1-source-stack-20260907-wmt-command-v2-clang'
expected_incremental=dict(line.split('=',1) for line in (stage/'K50SV1-BUILD-RECEIPT').read_text().splitlines())['build.incremental']
old_boot_id=json.loads((trial/'runtime/build19-first-boot-early/early-complete.json').read_text())['identity'].splitlines()[0].encode()
steps=[]
streams=[]
def run(name,args,check=True,timeout=30):
 r=subprocess.run(adb+args,env=env,capture_output=True,timeout=timeout)
 (out/(name+'.txt')).write_bytes(r.stdout+r.stderr)
 steps.append(dict(step=name,exit_code=r.returncode))
 if check:assert r.returncode==0,name
 return r.stdout.decode('utf-8','replace')
def sh(name,command,**kwargs):return run(name,['shell',command],**kwargs)
try:
 receipt=trial/'source-stack-wmt-command-v2-clang-flash-receipt.txt';deadline=time.monotonic()+600
 while time.monotonic()<deadline:
  if receipt.exists():
   state=receipt.read_text()
   if '\nstatus=PASS\n' in state:break
   if '\nstatus=FAIL\n' in state:raise RuntimeError('Flash receipt reports failure')
  time.sleep(1)
 else:raise RuntimeError('Flash receipt did not complete')
 deadline=time.monotonic()+300
 while time.monotonic()<deadline:
  state=subprocess.run(adb+['shell','cat /proc/sys/kernel/random/boot_id'],env=env,capture_output=True,timeout=5)
  if state.returncode==0 and state.stdout.strip() and state.stdout.strip()!=old_boot_id:break
  time.sleep(1)
 else:raise RuntimeError('Reboot did not produce a new boot ID')
 run('wait-for-device',['wait-for-device'],timeout=60)
 run('root',['root']);time.sleep(1)
 run('root-wait',['wait-for-device'],timeout=35)
 assert sh('root-user','id -u').strip()=='0'
 identity=sh('identity','cat /proc/sys/kernel/random/boot_id; uname -a; getprop ro.build.version.incremental; cat /proc/sys/kernel/tainted; cat /proc/uptime')
 assert expected_incremental in identity,identity
 run('logcat-buffer-size',['logcat','-b','all','-G','64M'])
 for label,args in [('continuous-kmsg',['shell','cat /dev/kmsg']),('continuous-logcat',['logcat','-b','all','-v','threadtime','-v','monotonic','-v','usec'])]:
  handle=(out/(label+'.txt')).open('wb')
  process=subprocess.Popen(adb+args,env=env,stdout=handle,stderr=subprocess.STDOUT)
  streams.append((process,handle))
 sh('dmesg','dmesg')
 run('logcat',['logcat','-d','-b','all','-v','threadtime'])
 sh('pstore-list','ls -l /sys/fs/pstore')
 sh('modules','cat /proc/modules')
 sh('wmt-before-completion','getprop persist.vendor.connsys.chipid; getprop vendor.connsys.driver.ready; getprop init.svc.wmt_loader; getprop init.svc.wmt_launcher; ls -l /proc/driver/wmt_dbg /proc/driver/wmt_aee')
 sh('home-before-completion','cmd package resolve-activity --brief --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME -c android.intent.category.DEFAULT; cat /data/system/users/0/roles.xml',check=False)
 progress=[];deadline=time.monotonic()+600
 while time.monotonic()<deadline:
  r=subprocess.run(adb+['shell','getprop sys.boot_completed; cat /proc/uptime'],env=env,capture_output=True,timeout=12)
  progress.append(dict(host_epoch=time.time(),exit_code=r.returncode,output=r.stdout.decode('utf-8','replace')))
  (out/'boot-progress.json').write_text(json.dumps(progress,indent=2)+'\n')
  if r.returncode==0 and r.stdout.splitlines() and r.stdout.splitlines()[0]==b'1':break
  time.sleep(5)
 else:raise RuntimeError('Boot completion timed out')
 sh('home-after-completion','cmd package resolve-activity --brief --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME -c android.intent.category.DEFAULT; cat /data/system/users/0/roles.xml')
 sh('wmt-after-completion','getprop persist.vendor.connsys.chipid; getprop vendor.connsys.driver.ready; getprop init.svc.wmt_loader; getprop init.svc.wmt_launcher')
 sh('preferences-after-completion','dumpsys package preferred-xml --full')
 sh('roles-after-completion','cat /data/system/users/0/roles.xml')
 sh('state-after-completion','settings get global device_provisioned; settings get secure user_setup_complete; cat /proc/sys/kernel/tainted; dumpsys lock_settings')
 readback=subprocess.run(['python3',str(trial/'collect-installed-readback.py'),'19','normal-reboot'],capture_output=True)
 (out/'independent-readback.txt').write_bytes(readback.stdout+readback.stderr)
 readback.check_returncode()
 (out/'early-complete.json').write_text(json.dumps(dict(status='PASS',identity=identity),indent=2)+'\n')
 print(json.dumps(dict(status='EARLY_COMPLETE',identity=identity)),flush=True)
 deadline=time.monotonic()+3600
 while not (out/'stop-streams').exists() and time.monotonic()<deadline:
  for process,handle in streams:
   if process.poll() is not None: raise RuntimeError('Kernel/logcat stream exited early')
  time.sleep(1)
finally:
 for process,handle in streams:
  if process.poll() is None:
   process.terminate()
   try: process.wait(timeout=8)
   except subprocess.TimeoutExpired: process.kill();process.wait(timeout=5)
  handle.close()
 (out/'steps.json').write_text(json.dumps(steps,indent=2)+'\n')
