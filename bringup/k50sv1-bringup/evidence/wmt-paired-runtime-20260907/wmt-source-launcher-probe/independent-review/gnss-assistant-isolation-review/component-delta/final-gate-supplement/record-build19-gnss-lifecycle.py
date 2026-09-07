"""Attribute the temporary GNSS request's lifecycle from retained same-boot evidence."""
from pathlib import Path
import hashlib
import json
import re

trial = Path(__file__).resolve().parent
out = trial / 'runtime/build19-gnss'
result_path = out / 'lifecycle.json'
assert not result_path.exists()
run = json.loads((out / 'result.json').read_text())
early = json.loads((trial / 'runtime/build19-normal-reboot-early/early-complete.json').read_text())
assert run['boot_id'] == early['identity'].splitlines()[0]
isolation = json.loads((trial / 'runtime/build19-gnss-component-isolation/result.json').read_text())
assert isolation['status'] == isolation['cleanup']['status'] == 'PASS'
assert isolation['boot_id'] == run['boot_id'] and isolation['gnss_exit_code'] == 0
assert isolation['gnss_runner_sha256'] == hashlib.sha256((trial / 'run-build19-gnss.py').read_bytes()).hexdigest()
assert len(run['summary']) == 1 and 'started=true stopped=true' in run['summary'][0]
location = (out / 'location-after.txt').read_text()
assert '  Location Listeners:' in location and '  Historical Records by Provider:' in location
active = location.split('  Location Listeners:', 1)[1].split('  Historical Records by Provider:', 1)[0]
assert 'local.k50.gnssprobe' not in active
followup = [line.strip() for line in active.splitlines() if 'UpdateRecord[gps ' in line]
kernel = (out / 'kernel-interval.txt').read_text().splitlines()
records = [line for line in kernel if re.search(r'GPS_(?:open|close):', line)]
close_ok = [line for line in records if 'GPS_close: WMT turn off GPS OK!' in line]
release = [line for line in records if 'GPS_close: gps_hold_wake_lock(0)' in line]
assert close_ok and release, 'No measured driver close/wake-lock release in the probe interval'
hashes = {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
          for name in ('kernel-interval.txt', 'location-after.txt', 'result.json')}
result = dict(status='PASS_PROBE_LIFECYCLE', boot_id=run['boot_id'],
              probe_removed_from_active_gps_receivers=True,
              independent_followup_request=followup, driver_open_close_evidence=records,
              raw_sha256=hashes,
              limitation='Probe request removal and observed driver close/reopen; '
              'independent active requests remain attributed separately. '
              'No global GPS-idle or positioning claim.')
result_path.write_text(json.dumps(result, indent=2) + '\n')
print('PASS: probe request removed; driver close and wake-lock release retained')
