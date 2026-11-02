"""Convert an audio input to 48 kHz stereo PCM WAV with a 44-byte header."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--ffmpeg', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    raw = output.with_suffix('.pcm')
    if output.drive.upper() != 'D:':
        parser.error('Output must be on D:')
    if output.exists() or raw.exists():
        parser.error('Output or intermediate PCM already exists')
    if not args.source.is_file() or not args.ffmpeg.is_file():
        parser.error('Input or FFmpeg executable not found')
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        str(args.ffmpeg), '-nostdin', '-hide_banner', '-v', 'error', '-n',
        '-i', str(args.source), '-vn', '-ar', '48000', '-ac', '2',
        '-c:a', 'pcm_s16le', '-f', 's16le', str(raw),
    ], check=True)
    pcm = raw.read_bytes()
    if not pcm or len(pcm) % 4:
        raise RuntimeError('Audio contains no complete stereo sample frames')
    with output.open('xb') as destination:
        with wave.open(destination, 'wb') as writer:
            writer.setparams((2, 2, 48000, 0, 'NONE', 'not compressed'))
            writer.writeframes(pcm)
    with wave.open(str(output), 'rb') as reader:
        if reader.getparams()[:4] != (2, 2, 48000, len(pcm) // 4):
            raise RuntimeError('WAV parameter verification failed')
        if reader.readframes(reader.getnframes()) != pcm:
            raise RuntimeError('WAV PCM round-trip verification failed')
    if output.stat().st_size != 44 + len(pcm):
        raise RuntimeError('Unexpected WAV header or file size')
    print(f'PASS: 48000 Hz, 16-bit stereo, {len(pcm) // 4} samples/channel')
    print(f'Duration: {len(pcm) / 192000:.6f} seconds')
    print('SHA256:', hashlib.sha256(output.read_bytes()).hexdigest())


if __name__ == '__main__':
    main()
