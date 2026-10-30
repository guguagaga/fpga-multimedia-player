"""Bounded-memory C12 solid-run packing with per-frame canonical verification."""
from pathlib import Path
import argparse, hashlib, json, mmap, struct

SIZES = {0x80: 3, 0x81: 13, 0x83: 129, 0x84: 9, 0x86: 9, 0x87: 6, 0x88: 25}

def unpack_frame(data, pos, end):
    tokens = []
    while len(tokens) < 14400:
        if pos >= end:
            raise ValueError('Truncated frame')
        op = data[pos]
        if op == 0x85:
            if pos + 4 > end:
                raise ValueError('Truncated solid run')
            tokens.extend([bytes([0x80]) + data[pos+2:pos+4]] * (data[pos+1]+1))
            pos += 4
        else:
            size = SIZES.get(op)
            if size is None or pos + size > end:
                raise ValueError(f'Invalid token at offset {pos}')
            tokens.append(bytes(data[pos:pos+size]))
            pos += size
    if len(tokens) != 14400 or pos >= end or data[pos] != 255:
        raise ValueError('Invalid block count or frame terminator')
    return tokens, pos + 1

def pack_frame(tokens):
    packed = bytearray(); index = 0
    while index < len(tokens):
        token = tokens[index]; count = 1
        if token[0] == 0x80:
            while count < 256 and index + count < len(tokens) and tokens[index+count] == token:
                count += 1
        packed.extend(bytes([0x85, count-1]) + token[1:] if count > 1 else token)
        index += count
    packed.append(255)
    checked, end = unpack_frame(packed, 0, len(packed))
    if checked != tokens or end != len(packed):
        raise ValueError('Canonical verification failed')
    return packed

def repack(source, destination):
    source = Path(source).resolve(); destination = Path(destination).resolve()
    partial = destination.with_name(destination.name + '.partial')
    if source == destination or destination.exists() or partial.exists():
        raise ValueError('Source/destination must differ; destination and .partial must not exist')
    sizes = []; canonical = hashlib.sha256()
    with source.open('rb') as inp, mmap.mmap(inp.fileno(), 0, access=mmap.ACCESS_READ) as data:
        header = bytearray(data[:512])
        if len(header) != 512 or header[:6] != b'FPGV\x01\x0c' or struct.unpack_from('<HH', header, 6) != (1280, 720):
            raise ValueError('Expected 1280x720 C12 file')
        end, count = struct.unpack_from('<II', header, 12)
        if count < 1 or not 512 < end <= len(data) or len(data)-end > 511 or any(data[end:]):
            raise ValueError('Invalid file length, frame count or padding')
        with partial.open('xb+') as out:
            out.write(header); pos = 512
            for frame in range(count):
                tokens, pos = unpack_frame(data, pos, end)
                for token in tokens:
                    canonical.update(token)
                packed = pack_frame(tokens); out.write(packed); sizes.append(len(packed))
            if pos != end:
                raise ValueError('Unconsumed data after declared frames')
            declared = out.tell()
            if declared >= 2**32:
                raise ValueError('32-bit format length exceeded')
            out.write(bytes(-declared % 512))
            struct.pack_into('<I', header, 12, declared)
            out.seek(0); out.write(header)
    # rename() on Windows refuses an existing destination; no existing media is replaced.
    partial.rename(destination)
    with destination.open('rb') as result:
        digest = hashlib.file_digest(result, 'sha256').hexdigest()
    return dict(passed=True, frames=count, canonical_blocks_checked=count*14400,
                declared_bytes=declared, frame_sizes=sizes, sha256=digest,
                canonical_sha256=canonical.hexdigest(),
                scope='Exact per-frame canonical equality. Preserves pixel tokens, orientation and frame rate. No hardware playback certification.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path); parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(json.dumps(repack(args.source, args.destination), indent=2))
