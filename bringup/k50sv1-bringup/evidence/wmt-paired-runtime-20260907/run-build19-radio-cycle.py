from pathlib import Path
import json, os, re, subprocess, time
trial=Path(__file__).resolve().parent
out=trial/'runtime/build19-radio-cycle'; out.mkdir(exist_ok=False)
adb=['/home/desmond/Android/Sdk/platform-tools/adb','-s','0123456789ABCDEF']; env=dict(os.environ,ADB_LIBUSB='1')
steps=[]
def run(name,args,save=True):
    r=subprocess.run(adb+args,env=env,capture_output=True,timeout=25)
    if save: (out/(name+'.txt')).write_bytes(r.stdout+r.stderr)
    steps.append(dict(step=name,exit_code=r.returncode))
    assert r.returncode==0,name
    return r.stdout.decode('utf-8','replace')
def sh(name,cmd,**kwargs): return run(name,['shell',cmd],**kwargs)
def poll(name,command,predicate,seconds=40):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=sh(name,command,save=False)
        if predicate(value):
            (out/(name+'.txt')).write_text(value)
            return value
        time.sleep(1)
    (out/(name+'-timeout.txt')).write_text(value)
    raise RuntimeError(name+' timed out')
def state(s):
    m=re.search(r'^\s+state: (\S+)',s,re.M)
    return m[1] if m else None
original={}
completed=False
try:
    identity=sh('identity','cat /proc/sys/kernel/random/boot_id; cat /proc/sys/kernel/tainted; cat /proc/uptime')
    boot=identity.splitlines()[0]; start=float(identity.splitlines()[2].split()[0])
    for key in ['wifi_scan_always_enabled','ble_scan_always_enabled','wifi_on','bluetooth_on']:
        original[key]=sh('original-'+key,'settings get global '+key).strip()
    assert original['wifi_on']=='1' and original['bluetooth_on']=='1'
    beforebt=sh('bluetooth-before','dumpsys bluetooth_manager')
    sh('wifi-before','dumpsys wifi')
    sh('scanning-off','settings put global wifi_scan_always_enabled 0; settings put global ble_scan_always_enabled 0')
    sh('bluetooth-disable','svc bluetooth disable')
    sh('wifi-disable','svc wifi disable')
    poll('bluetooth-off','dumpsys bluetooth_manager',lambda s:state(s)=='OFF')
    poll('wifi-off','dumpsys wifi',lambda s:'Wi-Fi is disabled' in s)
    sh('interfaces-off','ip -o -4 addr show')
    time.sleep(3)
    sh('wifi-enable','svc wifi enable')
    poll('wifi-reconnected','dumpsys wifi',lambda s:'COMPLETED' in s and 'mNetworkInfo [type: WIFI[], state: CONNECTED/CONNECTED' in s,seconds=55)
    sh('traffic-before','cat /sys/class/net/wlan0/statistics/rx_packets; cat /sys/class/net/wlan0/statistics/tx_packets')
    ping=sh('wifi-traffic','ping -I wlan0 -c 12 -i 0.2 -W 3 1.1.1.1')
    sh('traffic-after','cat /sys/class/net/wlan0/statistics/rx_packets; cat /sys/class/net/wlan0/statistics/tx_packets')
    sh('bluetooth-enable','svc bluetooth enable')
    poll('bluetooth-on','dumpsys bluetooth_manager',lambda s:state(s)=='ON')
    sh('wake','input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'); time.sleep(2)
    sh('discovery-launch','am start -W -a android.bluetooth.devicepicker.action.LAUNCH')
    time.sleep(3)
    active=sh('bluetooth-discovery-active','dumpsys bluetooth_manager')
    time.sleep(10)
    sh('discovery-ui-dump','uiautomator dump /data/local/tmp/k50-bt-picker.xml')
    run('discovery-ui',['exec-out','cat','/data/local/tmp/k50-bt-picker.xml'])
    sh('discovery-ui-cleanup','rm /data/local/tmp/k50-bt-picker.xml')
    sh('discovery-stop','input keyevent KEYCODE_HOME')
    time.sleep(3)
    afterbt=sh('bluetooth-after','dumpsys bluetooth_manager')
    sh('optional-config-paths','for p in /vendor/firmware/wifi.cfg /vendor/firmware/wifi_fw.cfg; do if [ -e "$p" ]; then ls -lZ "$p"; else printf "ABSENT %s\n" "$p"; fi; done')
    assert '12 packets transmitted, 12 received, 0% packet loss' in ping
    assert 'Discovering: true' in active and 'Discovering: false' in afterbt
    completed=True
finally:
    restored=True
    for key in ['wifi_scan_always_enabled','ble_scan_always_enabled']:
        if key in original:
            command=('settings delete global '+key) if original[key]=='null' else ('settings put global '+key+' '+original[key])
            try: sh('restore-'+key,command)
            except Exception: restored=False
    for key,radio in [('wifi_on','wifi'),('bluetooth_on','bluetooth')]:
        if key in original:
            try: sh('restore-'+radio,'svc '+radio+(' enable' if original[key]=='1' else ' disable'))
            except Exception: restored=False
    final=sh('final-identity','cat /proc/sys/kernel/random/boot_id; cat /proc/sys/kernel/tainted; cat /proc/uptime')
    end=float(final.splitlines()[2].split()[0])
    kernel=[]
    for line in (trial/'runtime/build19-normal-reboot-early/continuous-kmsg.txt').read_text(errors='replace').splitlines():
        m=re.match(r'\d+,\d+,(\d+),[^;]*;(.*)',line)
        if m and start<=int(m[1])/1000000<=end: kernel.append(line)
    (out/'kernel-interval.txt').write_text('\n'.join(kernel)+'\n')
    faults=[line for line in kernel if re.search(r'\bWARNING:|\bBUG:|\bOops:|\bUnable to handle|\bKernel panic',line)]
    kernel_avcs=[line for line in kernel if 'avc:' in line and 'scontext=u:r:kernel:s0' in line]
    result=dict(completed=completed,settings_restored=restored,boot_id=boot,final_identity=final,kernel_interval=[start,end],kernel_records=len(kernel),kernel_context_avcs=kernel_avcs,new_faults=faults)
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    (out/'steps.json').write_text(json.dumps(steps,indent=2)+'\n')
    print(json.dumps(result),flush=True)

assert completed and restored and kernel and not faults and not kernel_avcs
assert final.splitlines()[:2]==[boot,'0']
