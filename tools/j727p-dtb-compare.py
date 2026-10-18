#!/usr/bin/env python3
"""Read-only structural comparison of Qualcomm concatenated kernel DTBs.

Usage: python j727p-dtb-compare.py old/kernel_dtb current/kernel_dtb
No external Python packages required. Never modifies either input.
"""
import hashlib
import struct
import sys
from pathlib import Path

MAGIC = b'\xd0\x0d\xfe\xed'
BEGIN, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9

def digest(x):
    return hashlib.sha256(x).hexdigest()[:16]

def blobs(raw):
    out, pos = [], 0
    while True:
        off = raw.find(MAGIC, pos)
        if off == -1:
            break
        if off + 40 > len(raw):
            break
        hdr = struct.unpack_from('>10I', raw, off)
        _, total, structs, strings, reserves, version, last, cpuid, lenstr, lenstruct = hdr
        if (40 <= total <= len(raw) - off and
                40 <= structs < total and 40 <= strings < total and
                strings + lenstr <= total and
                structs + lenstruct <= total and
                version >= last >= 1):
            out.append((off, raw[off:off + total]))
            pos = off + total
        else:
            pos = off + 4
    return out

def properties(blob):
    h = struct.unpack_from('>10I', blob, 0)
    struct_off, strings_off, lenstr, lenstruct = h[2], h[3], h[8], h[9]
    strings = blob[strings_off:strings_off + lenstr]
    props = {}
    stack = []
    pos, limit = struct_off, struct_off + lenstruct
    while pos + 4 <= limit:
        tag = struct.unpack_from('>I', blob, pos)[0]
        pos += 4
        if tag == BEGIN:
            end = blob.find(b'\x00', pos, limit)
            if end < 0:
                raise ValueError('unterminated node')
            stack.append(blob[pos:end].decode('utf-8', 'replace'))
            pos = (end + 4) & ~3
        elif tag == END_NODE:
            if not stack:
                raise ValueError('unbalanced nodes')
            stack.pop()
        elif tag == PROP:
            if pos + 8 > limit:
                raise ValueError('truncated property')
            length, nameoff = struct.unpack_from('>II', blob, pos)
            pos += 8
            if nameoff >= len(strings) or pos + length > limit:
                raise ValueError('invalid property offset/length')
            end = strings.find(b'\x00', nameoff)
            if end < 0:
                raise ValueError('unterminated property name')
            name = strings[nameoff:end].decode('utf-8', 'replace')
            path = '/' + '/'.join(p for p in stack if p)
            props[path + ':' + name] = blob[pos:pos + length]
            pos = (pos + length + 3) & ~3
        elif tag == NOP:
            continue
        elif tag == END:
            break
        else:
            raise ValueError('invalid DTB token 0x%x' % tag)
    return props

def short(value):
    if value is None:
        return '(missing)'
    label = '%dB' % len(value)
    if len(value) <= 16:
        return label + ' ' + value.hex()
    return '%s sha256=%s first16=%s' % (label, digest(value), value[:16].hex())

def main(a, b):
    aa, bb = Path(a).read_bytes(), Path(b).read_bytes()
    la, lb = blobs(aa), blobs(bb)
    print('OLD: %d bytes; found %d FDT blobs; SHA256 %s' % (len(aa), len(la), digest(aa)))
    print('CURRENT: %d bytes; found %d FDT blobs; SHA256 %s' % (len(bb), len(lb), digest(bb)))
    if not la or not lb:
        print('No parseable FDT blobs found in one or both inputs. Do not repack kernel.')
        return 1
    print('Note: only FDT node/property changes are compared; metadata, padding and reservations can differ.')
    for idx in range(max(len(la), len(lb))):
        if idx >= len(la) or idx >= len(lb):
            print('FDT #%d present only in %s' % (idx, 'current' if idx >= len(la) else 'old'))
            continue
        offa, xa = la[idx]
        offb, xb = lb[idx]
        print('\nFDT #%d old offset=%d size=%d hash=%s; current offset=%d size=%d hash=%s' %
              (idx, offa, len(xa), digest(xa), offb, len(xb), digest(xb)))
        if xa == xb:
            print('  IDENTICAL')
            continue
        try:
            pa, pb = properties(xa), properties(xb)
        except ValueError as exc:
            print('  Cannot compare structured properties:', exc)
            continue
        changes = [(k, pa.get(k), pb.get(k)) for k in sorted(set(pa) | set(pb)) if pa.get(k) != pb.get(k)]
        print('  CHANGED FDT PROPERTIES:', len(changes))
        keyterms = ('camera', 'flash', 'torch', 'eeprom', 'sensor', 'regulator', 'gpio', 'pinctrl', 'clk', 'clock', 'csi', 'csiphy')
        important = [x for x in changes if any(t in x[0].lower() for t in keyterms)]
        for k, av, bv in (important + [x for x in changes if x not in important])[:35]:
            print('  ' + k)
            print('    OLD:     ' + short(av))
            print('    CURRENT: ' + short(bv))
        if len(changes) > 35:
            print('  ... %d additional changed properties omitted' % (len(changes) - 35))
        if not changes:
            print('  No node/property value differences detected (check header, reservations or padding).')
    return 0

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print('Usage: python j727p-dtb-compare.py old_kernel_dtb current_kernel_dtb', file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    except (OSError, struct.error) as error:
        print('ERROR:', error, file=sys.stderr)
        sys.exit(1)
