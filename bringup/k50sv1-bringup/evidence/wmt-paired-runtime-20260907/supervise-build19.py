from pathlib import Path
import json
import os
import subprocess
import time

trial = Path(__file__).resolve().parent
project = trial / 'build-project'
log = trial / 'full-build-19-clean.log'
receipt = trial / 'build19-process-result.json'
assert not log.exists() and not receipt.exists()
started = time.time()
environment = dict(os.environ, K50SV1_BUILD_TIER='1', K50_BUILD_JOBS='32',
                   K50SV1_CLEAN_BUILD='1', PYTHONDONTWRITEBYTECODE='1')
with log.open('xb') as output:
    result = subprocess.run(['./work/k50sv1-bringup/tools/run-lineage-build.sh'],
                            cwd=project, env=environment, stdout=output,
                            stderr=subprocess.STDOUT)
receipt.write_text(json.dumps(dict(started_epoch=started, finished_epoch=time.time(),
                                  exit_code=result.returncode, log=str(log)), indent=2) + '\n')
raise SystemExit(result.returncode)
