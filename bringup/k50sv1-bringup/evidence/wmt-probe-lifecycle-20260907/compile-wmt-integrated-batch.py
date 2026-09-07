"""Compile the integrated batch's changed production objects with frozen ARM64 flags."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kernel', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
trial = Path(__file__).resolve().parent
android = trial / 'build-project/lineage-17.1'
original_obj = android / 'out/target/product/k50sv1_64_bsp/obj/KERNEL_OBJ'
original_source = android / 'kernel/xsh/k50sv1_64_bsp'
snapshot = trial / 'kernel-obj-build14-snapshot'
source = args.kernel.resolve()
output = args.output.resolve()
assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=source).strip()
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
base = '54bdf406ee9963e3b926d8f19fc2bb4c1a3975eb'
changed = subprocess.check_output(['git', 'diff', '--name-only', base, revision], cwd=source, text=True).splitlines()
objects = [path for path in changed if path.endswith('.c') and '/test/' not in path]
assert objects and all(path.startswith('drivers/misc/mediatek/connectivity/') for path in objects)
output.mkdir(parents=True, exist_ok=False)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_one(name):
    relative = Path(name)
    saved = snapshot / relative.parent / ('.' + relative.stem + '.o.cmd')
    command = saved.read_text().splitlines()[0].split(' := ', 1)[1]
    argv = shlex.split(command.replace('\\#', '#'))
    target = output / relative.with_suffix('.o')
    target.parent.mkdir(parents=True, exist_ok=True)
    for index, arg in enumerate(argv):
        arg = arg.replace(str(original_obj), str(snapshot)).replace(str(original_source), str(source))
        if arg.startswith('-I') and not arg[2:].startswith('/'):
            arg = '-I' + str(snapshot / arg[2:])
        if arg.startswith('-Wp,-MD,'):
            arg = '-Wp,-MD,' + str(target.with_suffix('.d'))
        argv[index] = arg
    argv[argv.index('-o') + 1] = str(target)
    argv.append('-Werror')
    command_file = target.with_suffix('.command.json')
    command_file.write_text(json.dumps(argv, indent=2) + '\n')
    compiled = subprocess.run(argv, cwd=output, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = target.with_suffix('.compile.log')
    log.write_bytes(compiled.stdout)
    return dict(source=name, source_sha256=digest(source / name), exit_code=compiled.returncode,
                saved_command_sha256=digest(saved), command_file=str(command_file),
                command_sha256=digest(command_file), object=str(target),
                object_sha256=digest(target) if compiled.returncode == 0 else None,
                log=str(log), log_sha256=digest(log))


with ThreadPoolExecutor(max_workers=3) as pool:
    rows = list(pool.map(compile_one, objects))
assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=source).strip()
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip() == revision
result = dict(status='PASS' if all(row['exit_code'] == 0 for row in rows) else 'FAIL',
              kernel_revision=revision, base_revision=base, generated_headers=str(snapshot),
              config_sha256=digest(snapshot / '.config'), rows=rows,
              limitations='Production GCC 4.9 command flags and generated headers from build14; the later full clean build verifies complete final linkage.')
(output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(dict(status=result['status'], kernel_revision=revision, objects=len(rows))))
raise SystemExit(result['status'] != 'PASS')
