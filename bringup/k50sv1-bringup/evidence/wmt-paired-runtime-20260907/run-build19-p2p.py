from pathlib import Path
import hashlib,json,os,re,shlex,subprocess,time
trial=Path(__file__).resolve().parent
main=trial.parents[1]/'k50sv1-bringup'
out=trial/'runtime/build19-p2p'; out.mkdir(exist_ok=False)
adb=['/home/desmond/Android/Sdk/platform-tools/adb','-s','0123456789ABCDEF']; env=dict(os.environ,ADB_LIBUSB='1')
steps=[]
def run(name,args):
    r=subprocess.run(adb+args,env=env,capture_output=True,timeout=180 if args[0] == 'install' else 40)
    (out/(name+'.txt')).write_bytes(r.stdout+r.stderr)
    steps.append(dict(step=name,exit_code=r.returncode))
    assert r.returncode==0,name
    return r.stdout.decode('utf-8','replace')
def sh(name,cmd): return run(name,['shell',cmd])
def interfaces(text):
    result=[]
    for line in text.splitlines():
        m=re.match(r'\d+: (\S+)\s+inet\s+\S+/(\d+)',line)
        if m: result.append(dict(interface=m[1],ipv4_prefix=m[2]))
    return result
try:
    identity=sh('identity','cat /proc/sys/kernel/random/boot_id; cat /proc/sys/kernel/tainted; cat /proc/uptime; settings get secure location_mode; settings get global wifi_on')
    lines=identity.splitlines(); assert lines[-2:] == ['3','1'], lines[-2:]
    start=float(lines[2].split()[0])
    sh('before-kernel','dmesg')
    sh('before-p2p','dumpsys wifip2p')
    apk=main/'tools/runtime-probes/p2p/out/k50-p2p-probe.apk'
    digest=hashlib.sha256(apk.read_bytes()).hexdigest()
    assert digest=='0dbe0a93f149c12518d05823da564af57297d5bab0c3869bb969eaab201aebe5'
    installed=sh('installed-path','pm path local.k50.p2pprobe').strip().splitlines()
    assert len(installed)==1 and installed[0].startswith('package:/data/app/'), installed
    assert sh('installed-hash','sha256sum '+shlex.quote(installed[0].removeprefix('package:'))).split()[0]==digest
    sh('permission','pm grant local.k50.p2pprobe android.permission.ACCESS_FINE_LOCATION')
    sh('appop-fine','appops set --uid local.k50.p2pprobe FINE_LOCATION allow')
    sh('appop-coarse','appops set --uid local.k50.p2pprobe COARSE_LOCATION allow')
    sh('wake','input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'); time.sleep(2)
    sh('launch','am start -W -n local.k50.p2pprobe/.P2pProbeActivity')
    active=[]
    for index in range(3):
        active.append(interfaces(sh('interfaces-'+str(index),'ip -o -4 addr show')))
        time.sleep(1)
    time.sleep(9)
    log=run('probe-log',['logcat','-d','-v','threadtime','-s','K50P2pProbe:I','AndroidRuntime:E'])
    after=interfaces(sh('after-interfaces','ip -o -4 addr show'))
    sh('after-p2p','dumpsys wifip2p')
    final=sh('after-identity','cat /proc/sys/kernel/random/boot_id; cat /proc/sys/kernel/tainted; cat /proc/uptime')
    end=float(final.splitlines()[2].split()[0])
    kernel=[]
    for line in (trial/'runtime/build19-normal-reboot-early/continuous-kmsg.txt').read_text(errors='replace').splitlines():
        m=re.match(r'\d+,\d+,(\d+),[^;]*;(.*)',line)
        if m and start <= int(m[1])/1000000 <= end: kernel.append(line)
    (out/'kernel-interval.txt').write_text('\n'.join(kernel)+'\n')
    faults=[line for line in kernel if re.search(r'\bWARNING:|\bBUG:|\bOops:|\bUnable to handle|\bKernel panic',line)]
    result=dict(boot_id=lines[0],apk_sha256=digest,probe_pass='RESULT PASS reason=group_removed formed=true cleanup_pending=false' in log and 'RESULT FAIL' not in log,ipv4_during=active,ipv4_after=after,p2p_ipv4_added=any(v['interface']=='p2p0' for sample in active for v in sample),p2p_ipv4_removed=all(v['interface']!='p2p0' for v in after),kernel_interval=[start,end],kernel_records=len(kernel),new_faults=faults,final_identity=final,log=log)
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(result),flush=True)
    assert final.splitlines()[:2]==[lines[0],'0'] and kernel and not faults
    assert all(result[key] for key in ['probe_pass','p2p_ipv4_added','p2p_ipv4_removed'])
finally:
    (out/'steps.json').write_text(json.dumps(steps,indent=2)+'\n')
