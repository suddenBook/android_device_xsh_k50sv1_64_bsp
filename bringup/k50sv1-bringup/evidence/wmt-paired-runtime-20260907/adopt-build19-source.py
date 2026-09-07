"""Fast-forward the three canonical repositories after measured acceptance."""
from pathlib import Path
import hashlib
import json
import subprocess
import traceback

trial = Path(__file__).resolve().parent
project = trial.parents[2]
archive = trial.parents[1] / 'k50sv1-bringup/evidence/wmt-paired-runtime-20260907'
record = archive / 'canonical-adoption.json'
assert not record.exists()
runtime_path = archive / 'runtime.json'
runtime = json.loads(runtime_path.read_text())
assert runtime['status'] == 'PAIRED_SOURCE_BUILD_AND_RUNTIME_PASS'
assert runtime['source_adoption_approved'] and runtime['cleanup_status'] == 'PASS'
assert runtime['checked_readback_phases'] == ['first-boot', 'normal-reboot', 'final']
assert runtime['gnss_component_fixture_restored']
targets = {
    'kernel': ('54bdf406ee9963e3b926d8f19fc2bb4c1a3975eb', '4192fb6ae88e057bb2abb0f464cf6b4cb64697de'),
    'device': ('5df42aaa47d931c1c1bdbb45b7c36bacc59b6adf', 'c270801a1f214b3c56b16efda5742eb0947b0c37'),
    'vendor': ('af72cc5e335cee76e5745744ed743ae229286593', '2fafa3bef7124ae951b816b98cc5698cd5f6bd33'),
}
commands = []
state = dict(status='PREFLIGHT', runtime_sha256=hashlib.sha256(runtime_path.read_bytes()).hexdigest(),
             repositories=[], commands=commands)


def save():
    record.write_text(json.dumps(state, indent=2) + '\n')


def git(repository, *arguments):
    result = subprocess.run(['git', '-C', str(repository), *arguments], capture_output=True, text=True)
    commands.append(dict(repository=str(repository), arguments=arguments, exit_code=result.returncode,
                         stdout=result.stdout, stderr=result.stderr))
    result.check_returncode()
    return result.stdout.strip()


try:
    for name, (previous, target) in targets.items():
        repository = project / 'lineage-17.1' / name / 'xsh/k50sv1_64_bsp'
        assert runtime['revisions'][name] == target
        assert git(repository, 'rev-parse', 'HEAD') == previous
        assert not git(repository, 'status', '--porcelain=v1', '--untracked-files=all')
        git(repository, 'merge-base', '--is-ancestor', previous, target)
        state['repositories'].append(dict(repository=str(repository), before=previous, target=target,
                                          preflight_clean=True, fast_forward_possible=True))
    state['status'] = 'APPLYING_FAST_FORWARDS'
    save()
    for row in state['repositories']:
        repository = Path(row['repository'])
        git(repository, 'merge', '--ff-only', row['target'])
        row['after'] = git(repository, 'rev-parse', 'HEAD')
        row['clean'] = not git(repository, 'status', '--porcelain=v1', '--untracked-files=all')
        assert row['after'] == row['target'] and row['clean']
        save()
    state['status'] = 'PASS'
except BaseException as error:
    state['status'] = 'FAIL'
    state['error'] = repr(error)
    state['traceback'] = traceback.format_exc()
    save()
    raise
save()
print('PASS: canonical kernel, device and vendor fast-forwarded to the measured Build19 sources')
