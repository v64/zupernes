#!/usr/bin/env python3
"""Convert a BizHawk .bk2 movie to the shared .zmov format.

A .bk2 is a zip archive; the controller data lives in "Input Log.txt",
one line per emulated frame:

    |..|UDLRsSYBXAlr|............|

The first pipe-group is console buttons (reset/power - we reject movies
that use them mid-run, zupernes has no reset line yet), the second is
controller 1. Column meaning is declared by the "LogKey:" header line,
e.g.  LogKey:#Reset|Power|#P1 Up|P1 Down|... - we parse it rather than
assume an order. Comments (Subtitles/rerecords/etc.) live in Header.txt;
we carry the interesting ones over as # metadata.

Usage: bk2_to_zmov.py <movie.bk2> <out.zmov>
"""

import sys
import zipfile

# BizHawk button name -> zmov character (zmov: B Y s S U D L R A X l r)
NAME_TO_CHAR = {
    'Up': 'U', 'Down': 'D', 'Left': 'L', 'Right': 'R',
    'Select': 's', 'Start': 'S',
    'B': 'B', 'A': 'A', 'X': 'X', 'Y': 'Y',
    'L': 'l', 'R': 'r',
}


def main():
    bk2_path, out_path = sys.argv[1], sys.argv[2]
    zf = zipfile.ZipFile(bk2_path)
    log = zf.read('Input Log.txt').decode('utf-8').splitlines()
    try:
        header = zf.read('Header.txt').decode('utf-8').splitlines()
    except KeyError:
        header = []

    meta = {}
    for line in header:
        if ' ' in line:
            k, v = line.split(' ', 1)
            meta[k] = v

    # Parse the LogKey to learn column layout. Format:
    #   LogKey:#Reset|Power|#P1 Up|P1 Down|...
    # '#' starts a new pipe-group; entries within a group are one column
    # (one character) each in the input lines.
    logkey = next((l for l in log if l.startswith('LogKey:')), None)
    if logkey is None:
        sys.exit("no LogKey in Input Log.txt")
    groups = [g.split('|') for g in logkey[len('LogKey:'):].strip('#').split('|#')]
    groups = [[e for e in g if e] for g in groups]

    # Find the P1 group and build column -> zmov char
    p1_group = None
    p1_map = {}
    for gi, g in enumerate(groups):
        if any(e.startswith('P1 ') for e in g):
            p1_group = gi
            for ci, name in enumerate(g):
                short = name[len('P1 '):]
                if short in NAME_TO_CHAR:
                    p1_map[ci] = NAME_TO_CHAR[short]
            break
    if p1_group is None:
        sys.exit("no P1 columns in LogKey")

    out = []
    out.append(f"# converted from {bk2_path}")
    for k in ('GameName', 'SHA1', 'rerecordCount', 'Author'):
        if k in meta:
            out.append(f"# {k}: {meta[k]}")

    frames = 0
    for line in log:
        if not line.startswith('|'):
            continue
        parts = line.strip('|').split('|')
        console = parts[0] if len(parts) > 1 else ''
        if any(c not in '. ' for c in console):
            sys.exit(f"frame {frames}: console buttons used ({console!r}) - "
                     "mid-movie reset/power is not supported")
        cols = parts[p1_group]
        chars = ''.join(ch for ci, ch in sorted(p1_map.items())
                        if ci < len(cols) and cols[ci] not in '. ')
        out.append(chars)
        frames += 1

    with open(out_path, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print(f"wrote {out_path}: {frames} frames")


if __name__ == '__main__':
    main()
