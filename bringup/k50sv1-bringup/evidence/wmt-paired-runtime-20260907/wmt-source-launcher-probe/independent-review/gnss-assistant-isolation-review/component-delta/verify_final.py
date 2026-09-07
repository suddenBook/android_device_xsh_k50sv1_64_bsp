#!/usr/bin/env python3
"""Replay frozen wrapper and acceptance gates with retained/mock I/O only."""
import ast,contextlib,copy,hashlib,io,json,re,shlex,subprocess,sys,traceback,types
from pathlib import Path
import xml.etree.ElementTree as ET
D=Path(__file__).resolve().parent;S=D/'final-snapshot';O=D/sys.argv[1]
O.mkdir(exist_ok=False)
def deny(event,args):
 if event.startswith('subprocess.') or event in ('os.system','os.exec','os.posix_spawn'):raise RuntimeError('No process launch')
sys.addaudithook(deny)
rows=json.loads((D/'final-input-sha256.json').read_text())['rows']
for r in rows:
 data=(S/r['snapshot']).read_bytes();assert len(data)==r['bytes'] and hashlib.sha256(data).hexdigest()==r['sha256']
W=S/'runtime/build19-gnss-component-isolation';actual=json.loads((W/'result.json').read_text())
responses={p.stem:p.read_text() for p in W.glob('*.txt')}
tree=ast.parse((S/'run-build19-gnss-with-component-isolation.py').read_text())
body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name!='shell']+[next(n for n in tree.body if isinstance(n,ast.Try))]
code=compile(ast.Module(body=body,type_ignores=[]),'frozen-component-wrapper','exec')
cases=[]
def check(name,fn):
 try: detail=fn();cases.append(dict(name=name,status='PASS',detail=detail))
 except BaseException as e:cases.append(dict(name=name,status='FAIL',error=repr(e)))
def wrapper(name,failed=(),changes=None,child_rc=0,timeout=False):
 out=O/name;out.mkdir();calls=[];values=dict(responses);values.update(changes or {})
 def shell(label,command):
  calls.append(label)
  if label in failed:raise RuntimeError('Injected '+label)
  key=label
  if key not in values and key.startswith('binding-isolated-'):key='binding-isolated-0'
  if key not in values and key.startswith('service-isolated-'):key='service-isolated-0'
  return values[key]
 def child(args,**kwargs):
  calls.append('child')
  assert args==['python3',str(S/'run-build19-gnss.py')]
  if timeout:raise subprocess.TimeoutExpired(args,360)
  return subprocess.CompletedProcess(args,child_rc)
 ns=dict(trial=S,out=out,package='com.google.android.googlequicksearchbox',service_class='com.google.android.voiceinteraction.GsaVoiceInteractionService',component=actual['component'],state=dict(status='PREPARING',mutations_started=False),steps=[],env={},json=json,hashlib=hashlib,re=re,shlex=shlex,ET=ET,traceback=traceback,time=types.SimpleNamespace(sleep=lambda x:None),subprocess=types.SimpleNamespace(run=child,STDOUT=subprocess.STDOUT),shell=shell)
 exec(code,ns)
 state=ns['state'];(out/'calls.json').write_text(json.dumps(calls,indent=2)+'\n')
 return state,calls
def exact():
 state,calls=wrapper('actual-wrapper');assert state==actual
 return dict(exact=True,cleanup=state['cleanup']['status'])
check('actual_wrapper_exact_replay',exact)
for name,kwargs in [('child_failure',dict(child_rc=1)),('child_timeout',dict(timeout=True)),('disable_failure',dict(failed=('pause-observed-component',))),('component_restore_failure',dict(failed=('restore-component-default',))),('setting_restore_failure',dict(failed=('restore-voice_recognition_service',))),('search_restore_failure',dict(failed=('restore-search-availability',))),('role_readback_failure',dict(failed=('roles-restored',))),('home_failure',dict(failed=('restore-home',))),('dump_remove_failure',dict(failed=('remove-selector-dump',)))]:
 def negative(name=name,kwargs=kwargs):
  state,calls=wrapper(name,**kwargs);assert state['status']=='FAIL'
  for step in ['restore-component-default','restore-assistant','restore-voice_recognition_service','restore-voice_interaction_service','restore-search-availability','roles-restored','restore-home']:assert step in calls
  return dict(status=state['status'],cleanup=state['cleanup']['status'],later_cleanup_attempted=True)
 check(name,negative)
def package_mismatch():
 value=responses['search-package-restored'].replace('granted=true','granted=false',1)
 # Mutate an actual runtime permission line, not an unrelated install permission.
 m=re.search(r'^        android\.permission\.[\w.]+: granted=(true|false),.*$',responses['search-package-restored'],re.M);assert m
 old=m[0];value=responses['search-package-restored'].replace(old,old.replace('granted='+m[1],'granted='+('false' if m[1]=='true' else 'true')),1)
 state,_=wrapper('runtime-permission-mismatch',changes={'search-package-restored':value});assert state['cleanup']['status']=='FAIL'
check('runtime_permission_mismatch_rejected',package_mismatch)
# Exercise the unchanged finish and lifecycle isolation gates without their live side effects.
def assigned(n,name):return isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id==name for t in n.targets)
for filename,endname in [('finish-build19-runtime.py','p2p'),('record-build19-gnss-lifecycle.py',None)]:
 nodes=ast.parse((S/filename).read_text()).body;first=next(i for i,n in enumerate(nodes) if assigned(n,'isolation'))
 if endname:last=next(i for i,n in enumerate(nodes) if assigned(n,endname))
 else:last=first+1
 if not endname:
  while last<len(nodes) and isinstance(nodes[last],ast.Assert) and 'isolation' in ast.unparse(nodes[last]):last+=1
 gate=compile(ast.Module(body=nodes[first+1:last],type_ignores=[]),filename,'exec')
 for field in ['valid','status','cleanup','boot_id','gnss_exit_code','gnss_runner_sha256']:
  def gate_case(field=field,gate=gate):
   state=copy.deepcopy(actual)
   if field=='status':state[field]='FAIL'
   elif field=='cleanup':state[field]['status']='FAIL'
   elif field=='boot_id':state[field]='different'
   elif field=='gnss_exit_code':state[field]=1
   elif field=='gnss_runner_sha256':state[field]='0'*64
   rejected=False
   try:exec(gate,dict(isolation=state,trial=S,hashlib=hashlib,boot_id=actual['boot_id'],run=dict(boot_id=actual['boot_id'])))
   except AssertionError:rejected=True
   assert rejected==(field!='valid')
  check(filename+'_'+field,gate_case)
# Verify current child delta is exactly the reviewed empty-binding admission.
old=(D.parent/'snapshot/child-before-empty-binding.py').read_text();new=(S/'run-build19-gnss.py').read_text()
assert new==old.replace("assert voice_settings['voice_interaction_service'].startswith(search_package+'/')","assert voice_settings['voice_interaction_service']=='' or voice_settings['voice_interaction_service'].startswith(search_package+'/')",1)
# Replay retained child attribution and accepted lifecycle without any phone access.
g=S/'runtime/build19-gnss';r=json.loads((g/'result.json').read_text());b=json.loads((g/'log-history-boundary.json').read_text())
parse=lambda text:[x for x in text.splitlines() if re.match(r'^\s*\d+\.\d+\s+\d+\s+\d+\s+I\s+K50GnssProbe\s*:',x)]
prior=parse((g/'prior-gnss-history.txt').read_text());allr=parse((g/'log.txt').read_text());assert allr[:len(prior)]==prior
fresh=allr[len(prior):];assert all(re.match(r'^\s*\d+\.\d+\s+(\d+)',x)[1]==str(b['new_pid']) for x in fresh)
assert '\n'.join(fresh)+'\n'==r['log']==(g/'new-run-log.txt').read_text()
for name,key in [('prior-gnss-history.txt','prior_log_sha256'),('log.txt','full_log_sha256'),('new-run-log.txt','new_run_log_sha256')]:assert hashlib.sha256((g/name).read_bytes()).hexdigest()==b[key]
report=dict(status='PASS' if all(x['status']=='PASS' for x in cases) else 'FAIL',passed=sum(x['status']=='PASS' for x in cases),total=len(cases),cases=cases,input_files=len(rows),child_delta_exact=True,actual_child_attribution=dict(pid=b['new_pid'],prior_records=len(prior),fresh_records=len(fresh),summary=r['summary']),process_launches=0,adb_calls=0)
(O/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k] for k in ['status','passed','total','input_files','actual_child_attribution']}))
for c in cases:
 if c['status']=='FAIL':print(c)
raise SystemExit(report['status']!='PASS')
