#!/usr/bin/env python3
"""Convert an lsnes .lsmv movie's input log to the shared .zmov format.

An .lsmv is a zip; its "input" member has one line per frame:
    F. 0 0|BYsSudlrAXLR[|port2...]
Columns in the port-1 field are lsnes SNES gamepad order: B Y Select
Start Up Down Left Right A X L R (dot = released). Lines whose flag
field lacks 'F' are subframe polls (rare; skipped with a warning).

Usage: lsmv_to_zmov.py <movie.lsmv|input-file> <out.zmov>
"""
import sys, zipfile, io

LSNES_TO_ZMOV = ['B', 'Y', 's', 'S', 'U', 'D', 'L', 'R', 'A', 'X', 'l', 'r']

def main():
    src, out_path = sys.argv[1], sys.argv[2]
    try:
        zf = zipfile.ZipFile(src)
        text = zf.read('input').decode()
    except zipfile.BadZipFile:
        text = open(src).read()
    frames = []
    skipped = 0
    for line in text.splitlines():
        if not line:
            continue
        flags, _, rest = line.partition('|')
        if 'F' not in flags.split(' ')[0]:
            skipped += 1
            continue
        port1 = rest.split('|')[0]
        chars = ''.join(LSNES_TO_ZMOV[i] for i, c in enumerate(port1[:12]) if c != '.')
        frames.append(chars)
    with open(out_path, 'w') as f:
        f.write('# zmov 1\n# converted from ' + src + '\n')
        f.write('\n'.join(frames) + '\n')
    print(f'wrote {out_path}: {len(frames)} frames ({skipped} subframe lines skipped)')

if __name__ == '__main__':
    main()
