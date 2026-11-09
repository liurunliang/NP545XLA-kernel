#!/usr/bin/env python3
"""Inspect and compare QCA TLV files offline; never load or modify firmware."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inspect(path):
    data = path.read_bytes()
    if len(data) < 4:
        raise ValueError(f'{path}: truncated TLV header')
    kind = data[0]
    length = int.from_bytes(data[1:4], 'little')
    if length != len(data) - 4:
        raise ValueError(f'{path}: declared payload {length}, actual {len(data) - 4}')
    result = {'file': str(path), 'size': len(data), 'sha256': digest(data),
              'tlv_type': kind, 'payload_length': length}
    if kind == 1:
        fmt = struct.Struct('<IIBBBBHHHHI')
        if length < fmt.size:
            raise ValueError(f'{path}: truncated patch header')
        names = ('total_size', 'data_length', 'format_version', 'signature',
                 'download_mode', 'reserved1', 'product_id', 'rom_build',
                 'patch_version', 'reserved2', 'entry')
        result['patch'] = dict(zip(names, fmt.unpack_from(data, 4)))
        if not (result['patch']['data_length'] <= result['patch']['total_size'] <= length):
            raise ValueError(f'{path}: inconsistent patch sizes')
        result['build_strings'] = [
            {'file_offset': m.start(), 'value': m.group().decode('ascii')}
            for m in re.finditer(rb'[\x20-\x7e]{8,}', data)
            if b'BTFM.' in m.group() or b'BTFW.' in m.group()
        ]
        result['limits'] = ('Header and strings only; no signature verification, '
                            'load-address assumption, ROM dump, or runtime identity claim.')
    elif kind == 2:
        tags = []
        seen = set()
        pos = 4
        while pos < len(data):
            if len(data) - pos < 12:
                raise ValueError(f'{path}: truncated NVM tag at {pos:#x}')
            tag_id, size, reserved1, reserved2 = struct.unpack_from('<HHII', data, pos)
            end = pos + 12 + size
            if end > len(data):
                raise ValueError(f'{path}: tag {tag_id} extends past payload')
            if tag_id in seen:
                raise ValueError(f'{path}: duplicate tag {tag_id}; compare by ID is ambiguous')
            seen.add(tag_id)
            value = data[pos + 12:end]
            tags.append({'id': tag_id, 'file_offset': pos, 'length': size,
                         'reserved1': reserved1, 'reserved2': reserved2,
                         'sha256': digest(value), 'data_hex': value.hex()})
            pos = end
        result['tag_count'] = len(tags)
        result['tags'] = tags
        result['limits'] = ('Tag 17 is HCI transport and tag 27 is deep sleep in '
                            'upstream btqca; other tag semantics are not inferred.')
    else:
        raise ValueError(f'{path}: unsupported TLV type {kind}; expected patch 1 or NVM 2')
    return result


def compare(left, right):
    if left['tlv_type'] != right['tlv_type']:
        raise ValueError('comparison requires the same TLV type')
    if left['tlv_type'] == 1:
        return {'header_changes': {
            key: {'left': value, 'right': right['patch'][key]}
            for key, value in left['patch'].items() if value != right['patch'][key]
        }, 'left_build': left['build_strings'], 'right_build': right['build_strings']}
    a = {tag['id']: tag for tag in left['tags']}
    b = {tag['id']: tag for tag in right['tags']}
    changed = []
    unchanged = []
    for tag_id in sorted(a.keys() & b.keys()):
        x, y = a[tag_id], b[tag_id]
        if all(x[key] == y[key] for key in ('data_hex', 'reserved1', 'reserved2')):
            unchanged.append(tag_id)
            continue
        v1, v2 = bytes.fromhex(x['data_hex']), bytes.fromhex(y['data_hex'])
        offsets = []
        for i in range(max(len(v1), len(v2))):
            old = v1[i] if i < len(v1) else None
            new = v2[i] if i < len(v2) else None
            if old != new:
                offsets.append({'offset': i, 'left': old, 'right': new})
        changed.append({'id': tag_id, 'left_length': len(v1), 'right_length': len(v2),
                        'left_reserved': [x['reserved1'], x['reserved2']],
                        'right_reserved': [y['reserved1'], y['reserved2']],
                        'byte_changes': offsets})
    return {'only_left': sorted(a.keys() - b.keys()),
            'only_right': sorted(b.keys() - a.keys()),
            'unchanged_tags': unchanged, 'changed_tags': changed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('firmware', type=Path)
    parser.add_argument('--compare', type=Path, metavar='OTHER')
    args = parser.parse_args()
    try:
        result = {'left': inspect(args.firmware)}
        if args.compare:
            result['right'] = inspect(args.compare)
            result['comparison'] = compare(result['left'], result['right'])
    except (OSError, ValueError) as error:
        parser.exit(2, f'{error}\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
