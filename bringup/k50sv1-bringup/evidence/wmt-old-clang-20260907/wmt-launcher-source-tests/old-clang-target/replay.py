"""Replay the retained Android Q compile with preserved source/generated headers.

The Q source checkout and compiler are external dependencies, checked by hash.
Output must be new. The original compile artifacts are never overwritten.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    arguments = parser.parse_args()
    here = Path(__file__).resolve().parent
    provenance = json.loads((here / 'provenance.json').read_text())
    android = Path(provenance['android_checkout'])
    for row in provenance['external_dependencies']:
        assert sha(Path(row['path'])) == row['sha256'], row['path']
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    rows = []
    for label in ('baseline', 'candidate'):
        destination = output / label
        destination.mkdir()
        original_source = provenance['source_directories'][label]
        for name in ('main', 'firmware', 'protocol', 'patch'):
            command = json.loads((here / label / (name + '.command.json')).read_text())
            command = [value.replace(original_source, str(here / (label + '-source')))
                       .replace(provenance['generated_header_directory'], str(here / 'generated-include'))
                       for value in command]
            for flag, suffix in (('-o', '.o'), ('-MF', '.d')):
                command[command.index(flag) + 1] = str(destination / (name + suffix))
            (destination / (name + '.command.json')).write_text(json.dumps(command, indent=2) + '\n')
            with (destination / (name + '.log')).open('xb') as log:
                process = subprocess.run(command, cwd=android, stdout=log, stderr=subprocess.STDOUT,
                                         timeout=90)
            assert process.returncode == 0, (label, name, process.returncode)
            obj = destination / (name + '.o')
            stripped = destination / (name + '.stripped.o')
            subprocess.run([provenance['objcopy'], '--strip-debug', str(obj), str(stripped)],
                           check=True, timeout=30)
            expected = next(row for row in provenance['original_result']['rows']
                            if row['label'] == label and row['file'] == name + '.c')
            digest = sha(stripped)
            assert digest == expected['stripped_object_sha256'], (label, name, digest)
            rows.append(dict(label=label, file=name + '.c', exit_code=process.returncode,
                             stripped_object_sha256=digest, original_object_matches=True))
    (output / 'result.json').write_text(json.dumps(dict(status='PASS', rows=rows), indent=2) + '\n')
    print('PASS: all 8 preserved-source/header replay objects match the original stripped objects')


if __name__ == '__main__':
    main()
