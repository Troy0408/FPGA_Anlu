"""Regress FAT32 discovery and menu restrictions with ModelSim (standard library only).

Run from any directory: python tools/test_media_catalog.py
ModelSim's vlog, vlib and vsim must be on PATH. Evidence stays in build/media_catalog_tests.
"""
from pathlib import Path
import argparse
import json
import re
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/media_catalog_tests'
PART, RES, FATSZ, CL, TOTAL = 2048, 32, 600, 8, 600000
DATA = PART + RES + 2 * FATSZ
NAMES = ['N03CHIP.BMP', 'N01WATCH.BMP', 'N02DRINK.BMP', 'N04RAIN.BMP',
         'N05LANE.BMP', 'N06LEARN.BMP']
TRACKS = ['TRACK06.WAV', 'TRACK02.WAV', 'TRACK03.WAV', 'TRACK05.WAV']


def short_name(name):
    base, ext = name.split('.')
    return (base.ljust(8) + ext.ljust(3)).encode('ascii')


def bmp(w=64, h=36):
    size = 54 + ((w * 3 + 3) & ~3) * abs(h)
    header = b'BM' + struct.pack('<IHHI', size, 0, 0, 54)
    header += struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, size - 54, 0, 0, 0, 0)
    return header, size


def wav():
    header = b'RIFF' + struct.pack('<I', 4132) + b'WAVEfmt ' + struct.pack('<I', 16)
    header += struct.pack('<HHIIHH', 1, 2, 48000, 192000, 4, 16)
    return header + b'data' + struct.pack('<I', 4096), 4140


def manifest():
    titles = ['Heat Waves', 'Future Club', 'Nightcall', 'Unused', 'Resonance']
    body = b'TRK1' + bytes([5, 0, 0, 0])
    body += b''.join(bytes([len(t)]) + t.encode().ljust(31, b' ') for t in titles)
    return body, len(body)


def changed(media, offset, fmt, value):
    data, size = media
    data = bytearray(data)
    struct.pack_into('<' + fmt, data, offset, value)
    return bytes(data), size


def image(files, fragmented=(), spc=CL):
    """Sparse card: only headers, directory sectors, and occupied FAT sectors."""
    sectors, locations = {}, {}
    fat = {0: 0xffffff8, 1: 0xfffffff, 2: 0xfffffff}
    entries, next_cluster = [], 3
    for name, (header, size) in files:
        count = max(1, (size + spc * 512 - 1) // (spc * 512))
        # A pathological size need not allocate a million test FAT records:
        # its first FAT link alone proves it is not a contiguous file.
        first = next_cluster
        if count > 10000:
            fat[first] = 0xfffffff
            next_cluster += 1
        else:
            chain = list(range(first, first + count))
            if name in fragmented and count > 1:
                chain = [first] + list(range(first + 2, first + count + 1))
            for a, b in zip(chain, chain[1:]):
                fat[a] = b
            fat[chain[-1]] = 0xfffffff
            next_cluster = chain[-1] + 1
        lba = DATA + (first - 2) * spc
        sectors[lba] = header.ljust(512, b'\0')[:512]
        locations[name] = lba
        entries.append(short_name(name) + bytes([0x20]) + bytes(8) +
                       struct.pack('<H', first >> 16) + bytes(4) +
                       struct.pack('<HI', first & 0xffff, size))
    directory = b''.join(entries) + bytes(32)
    root_clusters = (len(directory) + spc * 512 - 1) // (spc * 512)
    root_chain = [2] + list(range(60000, 60000 + root_clusters - 1))
    for a, b in zip(root_chain, root_chain[1:]):
        fat[a] = b
    fat[root_chain[-1]] = 0xfffffff
    directory = directory.ljust(root_clusters * spc * 512, b'\0')
    for index, cluster in enumerate(root_chain):
        for s in range(spc):
            offset = (index * spc + s) * 512
            sectors[DATA + (cluster - 2) * spc + s] = directory[offset:offset + 512]
    fat_sectors = {}
    for cluster, value in fat.items():
        block = fat_sectors.setdefault(cluster // 128, bytearray(512))
        struct.pack_into('<I', block, (cluster % 128) * 4, value)
    sectors.update({PART + RES + s: bytes(b) for s, b in fat_sectors.items()})
    mbr = bytearray(512)
    mbr[450] = 0x0c
    volume_total = RES + 2 * FATSZ + 70000 * spc
    struct.pack_into('<II', mbr, 454, PART, volume_total)
    mbr[510:512] = b'\x55\xaa'
    sectors[0] = bytes(mbr)
    boot = bytearray(512)
    boot[0] = 0xeb
    struct.pack_into('<HBHB', boot, 11, 512, spc, RES, 2)
    struct.pack_into('<I', boot, 32, volume_total)
    struct.pack_into('<I', boot, 36, FATSZ)
    struct.pack_into('<I', boot, 44, 2)
    boot[510:512] = b'\x55\xaa'
    sectors[PART] = bytes(boot)
    return sectors, locations


def cases():
    named = [(n, bmp()) for n in NAMES] + [('TRACKS.BIN', manifest())]
    named += [(n, wav()) for n in TRACKS]
    yield 'named', named, NAMES, TRACKS, 1, 1, ()
    yield 'mixed', [('PHOTO.BMP', bmp()), ('SONG.WAV', wav())], ['PHOTO.BMP'], ['SONG.WAV'], 0, 0, ()
    yield 'fragmented', [('A.BMP', bmp(200, 100)), ('B.BMP', bmp(200, 100))], ['B.BMP'], [], 0, 0, ('A.BMP',)
    many = [(f'P{i}.BMP', bmp(8, 8)) for i in range(9)] + [(f'S{i}.WAV', wav()) for i in range(8)]
    yield 'limits', many, [f'P{i}.BMP' for i in range(6)], [f'S{i}.WAV' for i in range(5)], 0, 0, ()
    yield 'empty', [], [], [], 0, 0, ()
    yield 'audio_only', [('SONG.WAV', wav())], [], ['SONG.WAV'], 0, 0, ()
    yield 'truncated_wav_then_good', [('BAD.WAV', (wav()[0], 35)), ('GOOD.WAV', wav())], [], ['GOOD.WAV'], 0, 0, ()
    for size in (35, 4140, 0xffffffff):
        yield f'bad_riff_size_{size}', [('BAD.WAV', changed(wav(), 4, 'I', size))], [], [], 0, 0, ()
    yield 'top_down', [('TOP.BMP', bmp(853, -479))], ['TOP.BMP'], [], 0, 0, ()
    yield 'max_size', [('MAX.BMP', bmp(1920, 1080))], ['MAX.BMP'], [], 0, 0, ()
    yield 'min_size', [('MIN.BMP', bmp(1, 1))], ['MIN.BMP'], [], 0, 0, ()
    yield 'huge_entry', [('HUGE.BMP', (bmp()[0], 0xffffffff))], [], [], 0, 0, ()
    for spc in (1, 2, 4, 16, 32, 64, 128):
        yield f'cluster_{spc}', [('TEST.BMP', bmp()), ('TEST.WAV', wav())], ['TEST.BMP'], ['TEST.WAV'], 0, 0, ()
    yield 'root_chain', [(f'T{i}.TXT', (b'x', 1)) for i in range(129)] + [('LAST.BMP', bmp())], ['LAST.BMP'], [], 0, 0, ()
    yield 'audio_root_chain', [(f'T{i}.TXT', (b'x', 1)) for i in range(129)] + [('LAST.WAV', wav())], [], ['LAST.WAV'], 0, 0, ()
    yield 'root_limit', named + [(f'T{i}.TXT', (b'x', 1)) for i in range(4096)], NAMES, TRACKS, 0, 0, ()
    yield 'wrong_manifest_size', [(n, (b, 169) if n == 'TRACKS.BIN' else (b, s))
          for n, (b, s) in named], NAMES, TRACKS, 1, 0, ()
    yield 'extra_named_picture', named + [('EXTRA.BMP', bmp())], NAMES, TRACKS, 0, 1, ()
    yield 'extra_named_audio', named + [('EXTRA.WAV', wav())], NAMES, TRACKS + ['EXTRA.WAV'], 1, 0, ()
    bad_bmp = [(0, 'H', 0), (2, 'I', 10), (2, 'I', 8388609), (10, 'I', 53),
               (10, 'I', 1048577), (14, 'I', 39), (14, 'I', 125), (18, 'I', 0),
               (18, 'I', 1921), (18, 'I', 0x1000040), (22, 'I', 0),
               (22, 'i', -1081), (22, 'I', 1081), (26, 'H', 2), (28, 'H', 32), (30, 'I', 1)]
    for offset, fmt, value in bad_bmp:
        media = changed(bmp(), offset, fmt, value)
        yield f'bmp_bad_{offset}_{value}', [('BAD.BMP', media)], [], [], 0, 0, ()
    for offset in (0, 8, 12, 20, 22, 24, 28, 32, 34):
        header, size = wav()
        header = bytearray(header)
        header[offset] ^= 1
        yield f'wav_bad_{offset}', [('BAD.WAV', (bytes(header), size))], [], [], 0, 0, ()


def run(command, timeout=90):
    result = subprocess.run(command, cwd=OUT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):', result.stdout):
        raise RuntimeError(result.stdout)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pixels', action='store_true', help='Also run two slow complete-frame scaler simulations')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for command in ('vlib', 'vlog', 'vsim'):
        if not shutil.which(command):
            raise RuntimeError(f'{command} is not on PATH')
    if not (OUT / 'work').exists():
        run(['vlib', 'work'])
    project = ROOT / 'project'
    run(['vlog', '+incdir+' + str(project), str(project / 'global_def.v'),
         str(project / 'sd.v'), str(project / 'video.v'),
         str(project / 'reference/stream_scaler.v'),
         *map(str, sorted((ROOT / 'tools/tests').glob('tb_*.sv')))])
    evidence = []
    for name, files, pictures, tracks, pn, tn, fragmented in cases():
        spc = int(name.split('_')[1]) if name.startswith('cluster_') else CL
        sectors, locations = image(files, fragmented, spc)
        card_path = OUT / (name + '.txt')
        card_path.write_text(''.join(f'{lba:08x} {block.hex()}\n' for lba, block in sorted(sectors.items())))
        log = run(['vsim', '-c', 'tb_root_catalog', '+card=' + str(card_path), '-do', 'run -all; quit -f'])
        (OUT / (name + '.log')).write_text(log)
        match = re.search(r'CATALOG (\d+) (\d+) (\d+) (\d+) (\d+) ([\da-f]+) ((?:\d+ ){7}\d+)', log)
        if not match:
            raise RuntimeError(log)
        actual = [int(x) for x in match.group(1, 2, 3, 4, 5)]
        assert actual == [5 if name == 'root_limit' else 1, len(pictures), len(tracks), pn, tn], (name, actual)
        expected_first = int.from_bytes(short_name(tracks[0]), 'big') if tracks else 0
        assert int(match[6], 16) == expected_first, (name, 'first WAV')
        rest = list(map(int, match[7].split()))
        expected_lbas = [locations[p] for p in pictures] + [0] * (6 - len(pictures))
        assert rest[:6] == expected_lbas, (name, rest, expected_lbas)
        if pn:
            expected_order = sum(NAMES.index(n) << (3 * i) for i, n in enumerate(sorted(NAMES)))
            assert rest[6] == expected_order, (name, 'named order')
        evidence.append(dict(case=name, result=actual, lbas=rest[:6], reads=rest[7]))
        print('PASS', name, flush=True)
    log = run(['vsim', '-c', 'tb_root_catalog', '+card=' + str(OUT / 'named.txt'),
               '+stall', '-do', 'run -all; quit -f'])
    (OUT / 'incomplete_catalog.log').write_text(log)
    assert re.search(r'CATALOG 6 6 4 0 0 ', log), log
    evidence.append(dict(case='incomplete_catalog', passed=True))
    print('PASS incomplete_catalog', flush=True)
    for top in ('tb_menu_catalog', 'tb_catalog_publish', 'tb_bmp_header', 'tb_subtitle_catalog', 'tb_catalog_menu_pixels'):
        log = run(['vsim', '-c', top, '-do', 'run -all; quit -f'])
        (OUT / (top + '.log')).write_text(log)
        assert 'PASS ' + top in log, log
        evidence.append(dict(case=top, passed=True))
        print('PASS', top, flush=True)
    for name in ('audio_only', 'named', 'cluster_1', 'cluster_128', 'audio_root_chain', 'truncated_wav_then_good'):
        extra = ['+named'] if name == 'named' else []
        log = run(['vsim', '-c', 'tb_music_catalog', '+card=' + str(OUT / (name + '.txt')),
                   *extra, '-do', 'run -all; quit -f'])
        (OUT / ('music_' + name + '.log')).write_text(log)
        assert 'PASS tb_music_catalog' in log, log
        evidence.append(dict(case='music_' + name, passed=True))
        print('PASS music_' + name, flush=True)
    for name in ('cluster_1', 'audio_root_chain'):
        log = run(['vsim', '-c', '-gMOUNT=0', 'tb_music_catalog',
                   '+card=' + str(OUT / (name + '.txt')), '-do', 'run -all; quit -f'])
        (OUT / ('legacy_music_' + name + '.log')).write_text(log)
        assert 'PASS tb_music_catalog' in log, log
        evidence.append(dict(case='legacy_music_' + name, passed=True))
        print('PASS legacy_music_' + name, flush=True)
    if args.pixels:
        for name, extra in (('bottomup', []), ('topdown', ['+topdown'])):
            log = run(['vsim', '-c', 'tb_bmp_pixels', *extra, '-do', 'run -all; quit -f'], timeout=600)
            (OUT / ('pixels_' + name + '.log')).write_text(log)
            assert 'PASS tb_bmp_pixels' in log, log
            evidence.append(dict(case='pixels_' + name, passed=True))
            print('PASS pixels_' + name, flush=True)
    (OUT / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'Passed {len(evidence)} media regressions; evidence: {OUT}')


if __name__ == '__main__':
    main()
