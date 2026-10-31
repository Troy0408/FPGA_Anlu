"""Build the self-contained TD project in a fresh output directory. No programming."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def find_td(value):
    candidates = []
    for entry in (value or '').split(os.pathsep):
        if entry:
            path = Path(entry.strip().strip('"'))
            candidates += [path, path / 'td_commands_prompt.exe', path / 'bin/td_commands_prompt.exe']
    if located := shutil.which('td_commands_prompt.exe'):
        candidates.append(Path(located))
    for path in candidates:
        if path.is_file() and path.name.lower() == 'td_commands_prompt.exe':
            return path.resolve()
    raise ValueError('Set --td-bin or TD_BIN to the TD 6.2.1 bin directory')


def check_project(spec):
    project = ROOT / 'project'
    expected = spec['project_files']
    for name, checksum in expected.items():
        path = (project / name).resolve()
        if not path.is_relative_to(ROOT.resolve()) or not path.is_file():
            raise ValueError('Missing or invalid project input: ' + name)
        if digest(path) != checksum:
            raise ValueError('Frozen input changed: ' + name)
    al = (project / 'probe.al').read_text(encoding='utf-8')
    if re.search(r'<Project\b[^>]*\bPath="([^"]+)"', al).group(1) != '.':
        raise ValueError('Project location must be relative')
    for name in re.findall(r'<File Path="([^"]+)"', al):
        if name not in expected:
            raise ValueError('Project references an unlisted file: ' + name)
    for name in expected:
        if Path(name).suffix not in ('.v', '.vh'):
            continue
        text = (project / name).read_text(encoding='utf-8', errors='replace')
        for include in re.findall(r'`include\s+"([^"]+)"', text):
            if include not in expected:
                raise ValueError('Missing Verilog include: ' + include)
    return len(expected)


def configure_card(work, drive, spec):
    """Read the staged FAT32 card; edit only the disposable build snapshot."""
    from inspect_showcase_card import Fat32
    if not re.fullmatch('[A-Za-z]:', drive):
        raise ValueError('Use one Windows volume letter, for example E:')
    fs = Fat32(drive)
    try:
        folders = [e for e in fs.entries(fs.root)
                   if e['directory'] and e['name'] == spec['media']['directory']]
        if len(folders) != 1:
            raise ValueError('Expected one SHOW640 directory on the card')
        entries = {e['name']: e for e in fs.entries(folders[0]['cluster']) if not e['directory']}
        images = []
        for expected in spec['media']['images']:
            actual = fs.file(entries[expected['card_name']])
            if not actual['contiguous'] or actual['bytes'] != expected['bytes'] or actual['sha256'] != expected['sha256']:
                raise ValueError('Card file differs or is fragmented: ' + expected['card_name'])
            if not 0 <= actual['first_card_lba'] <= actual['last_card_lba'] < 2**32:
                raise ValueError('Card address is outside the 32-bit sector range')
            images.append(actual)
        ordered = sorted(images, key=lambda e: e['first_card_lba'])
        if any(a['last_card_lba'] >= b['first_card_lba'] for a, b in zip(ordered, ordered[1:])):
            raise ValueError('Overlapping image allocations')
    finally:
        fs.f.close()
    top_path = work / 'top.v'
    text = top_path.read_text(encoding='utf-8')
    for index, image in enumerate(images):
        text, count = re.subn(r"(\.IMAGE_SECTOR" + str(index) + r"\(32'd)\d+(\))",
                              lambda match: match[1] + str(image['first_card_lba']) + match[2], text)
        if count != 1:
            raise ValueError('Expected exactly one image address parameter')
    top_path.write_text(text, encoding='utf-8', newline='\n')
    return dict(read_only=True, directory='SHOW640', images=images)


def run_td(executable, script, work, log):
    with log.open('wb') as stream:
        result = subprocess.run([str(executable), script], cwd=work, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=1800)
    text = log.read_bytes().decode('utf-8', errors='replace')
    if result.returncode or re.search(r'\bERROR:|DISPLAY_RESOURCE_FAILED|PLAYER720_CANDIDATE_BIT_FAILED|Oops!', text):
        raise RuntimeError('TD failed; inspect ' + str(log))
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check input hashes and local references only')
    parser.add_argument('--td-bin', default=os.environ.get('TD_BIN') or os.environ.get('PATHTD'))
    parser.add_argument('--run-name', default='player_' + datetime.now().strftime('%Y%m%d_%H%M%S'))
    parser.add_argument('--card-drive', help='Read-only audit of a new card and remap the build snapshot')
    parser.add_argument('--generate-bit', action='store_true', help='Generate a bit after a successful route')
    args = parser.parse_args()
    spec = json.loads((ROOT / 'project/ip/sources.json').read_text(encoding='utf-8'))
    count = check_project(spec)
    print(f'Checked {count} frozen project inputs and all local includes', flush=True)
    if args.check:
        return
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', args.run_name):
        parser.error('Run name must contain only ASCII letters, digits, underscores and hyphens')
    executable = find_td(args.td_bin)
    out = ROOT / 'build' / args.run_name
    out.parent.mkdir(exist_ok=True)
    out.mkdir(exist_ok=False)
    work = out / 'project'
    # build.tcl creates a fresh .al; the reviewable source .al stays in project/.
    shutil.copytree(ROOT / 'project', work, ignore=shutil.ignore_patterns('*.al'))
    # The original vendor preamble includes ../user_source/.../global_def.v.
    shutil.copytree(ROOT / 'user_source', out / 'user_source')
    record = dict(device=spec['device'], original_hardware_bit_sha256=spec['hardware_bit_sha256'],
                  source_inputs=spec['project_files'], strict_signoff=False, board_programmed=False)
    if args.card_drive:
        record['card_readonly_audit'] = configure_card(work, args.card_drive, spec)
        record['remapped_top_sha256'] = digest(work / 'top.v')
    (out / 'inputs.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Running TD synthesis, placement, routing and hold repair...', flush=True)
    text = run_td(executable, 'build.tcl', work, out / 'td.log')
    if 'DISPLAY_RESOURCE_DONE' not in text or not (work / 'probe_route.db').is_file():
        raise RuntimeError('TD did not complete the build script')
    timing = (work / 'probe.timing').read_text(encoding='utf-8', errors='replace')
    setup = re.findall(r'SWNS:\s*([-+\d.]+)ns', timing)
    hold = re.findall(r'HWNS:\s*([-+\d.]+)ns', timing)
    if not setup or not hold:
        raise RuntimeError('Missing numerical timing summary')
    record['setup_wns_ns'], record['hold_wns_ns'] = float(setup[-1]), float(hold[-1])
    record['numeric_timing_passed'] = record['setup_wns_ns'] >= 0 and record['hold_wns_ns'] >= 0
    record['critical_warnings'] = [line.strip() for line in text.splitlines() if 'CRITICAL-WARNING:' in line]
    (out / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if not record['numeric_timing_passed']:
        raise RuntimeError('Timing is negative; inspect the generated reports')
    if args.generate_bit:
        text = run_td(executable, 'generate_bit.tcl', work, out / 'bitgen.log')
        bit = work / 'probe.bit'
        if 'PLAYER720_CANDIDATE_BIT_DONE' not in text or not bit.is_file():
            raise RuntimeError('Bit generation did not complete')
        record['generated_bit_sha256'] = digest(bit)
        (out / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"Route complete: setup {record['setup_wns_ns']:+.3f} ns; hold {record['hold_wns_ns']:+.3f} ns")
    print('Output: ' + str(out))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
