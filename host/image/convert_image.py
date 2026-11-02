"""Convert a still image to the player's uncompressed 24-bit BMP format."""

import argparse
import hashlib
from pathlib import Path
import struct

from PIL import Image, ImageOps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.drive.upper() != 'D:':
        parser.error('Output must be on D:')
    if output.exists():
        parser.error('Output already exists; choose a new filename')
    if not args.source.is_file():
        parser.error('Input image not found')
    with Image.open(args.source) as source:
        image = ImageOps.exif_transpose(source).convert('RGB')
    if max(image.size) > 4096:
        parser.error('Input width and height must be at most 4096 pixels')
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('xb') as destination:
        image.save(destination, format='BMP')
    data = output.read_bytes()
    dib, width, height, planes, bits, compression = struct.unpack_from('<IiiHHI', data, 14)
    if (dib, planes, bits, compression) != (40, 1, 24, 0):
        raise RuntimeError('BMP header validation failed')
    if (width, height) != image.size or height <= 0:
        raise RuntimeError('BMP dimension validation failed')
    if len(data) != 54 + ((width * 3 + 3) // 4 * 4) * height:
        raise RuntimeError('BMP row alignment or file size mismatch')
    with Image.open(output) as result:
        if result.convert('RGB').tobytes() != image.tobytes():
            raise RuntimeError('Decoded pixels differ from prepared input')
    print(f'PASS: {width} x {height}, RGB24 BMP, {len(data)} bytes')
    print('SHA256:', hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    main()
