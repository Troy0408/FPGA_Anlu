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
            # Git archives store normalized LF; checkout attributes restore CRLF.
            lf_checksum = hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()
            if lf_checksum != spec.get('project_lf_sha256', {}).get(name):
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
    parser.add_argument('--generate-bit', action='store_true', help='Generate a bit after a successful route')
    parser.add_argument('--place-seed', type=int, default=3, help='Placement seed (default: 3); recorded in inputs.json')
    args = parser.parse_args()
    spec = json.loads((ROOT / 'project/ip/sources.json').read_text(encoding='utf-8'))
    count = check_project(spec)
    print(f'Checked {count} frozen project inputs and all local includes', flush=True)
    if args.check:
        return
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', args.run_name):
        parser.error('Run name must contain only ASCII letters, digits, underscores and hyphens')
    if not 0 <= args.place_seed <= 2147483647:
        parser.error('Placement seed must be between 0 and 2147483647')
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
                  source_inputs=spec['project_files'], place_seed=args.place_seed,
                  strict_signoff=False, board_programmed=False)
    (out / 'inputs.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Running TD synthesis, placement, routing and hold repair...', flush=True)
    # Pass options through a separate driver so frozen project files remain
    # byte-for-byte identical to the checked inputs throughout the build.
    driver = work / 'build_driver.tcl'
    driver.write_text(f'set build_place_seed {args.place_seed}\nsource build.tcl\n', encoding='utf-8')
    text = run_td(executable, driver.name, work, out / 'td.log')
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
