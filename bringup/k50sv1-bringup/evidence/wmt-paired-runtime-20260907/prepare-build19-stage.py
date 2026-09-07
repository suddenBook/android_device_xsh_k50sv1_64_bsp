from pathlib import Path
import json,os,subprocess,time
trial=Path(__file__).resolve().parent
result=trial/'build19-process-result.json'
out=trial/'build19-stage-result.json'
steps=[]
stage=trial/'tier1-source-stack-20260907-wmt-command-v2-clang'
def run(label,args,timeout):
 with (trial/(label+'.log')).open('wb') as log:
  process=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=timeout,
                         env=dict(os.environ,K50SV1_BUILD_TIER='1',PYTHONDONTWRITEBYTECODE='1'))
 steps.append(dict(step=label,exit_code=process.returncode))
 if process.returncode: raise RuntimeError(label+' failed with '+str(process.returncode))
try:
 deadline=time.monotonic()+3600
 while time.monotonic()<deadline:
  if result.exists():
   try: data=json.loads(result.read_text())
   except json.JSONDecodeError: data=None
   if data is not None:
    if data['exit_code']!=0: raise RuntimeError('build19 failed')
    break
  status=subprocess.check_output(['systemctl','--user','show','k50sv1-build19.service','--property=ActiveState','--value'],text=True).strip()
  if status not in ('active','activating'): raise RuntimeError('build19 stopped without result')
  time.sleep(5)
 else: raise RuntimeError('build19 observation window elapsed; check same build unit before further action')
 run('build19-native-providers', ['python3',str(trial/'collect-build19-providers.py')],300)
 run('build19-stage', [str(trial/'build-project/work/k50sv1-bringup/tools/stage-tier-images.sh'),str(stage)],900)
 run('build19-stage-verification', [str(trial/'build-project/work/k50sv1-bringup/tools/verify-stage-contract.sh'),str(stage)],300)
 out.write_text(json.dumps(dict(status='PASS',stage=str(stage),steps=steps),indent=2)+'\n')
 print('PASS: build19 producers, launcher product policy and frozen stage contract',flush=True)
except Exception as error:
 out.write_text(json.dumps(dict(status='FAIL',error=str(error),steps=steps),indent=2)+'\n')
 raise

