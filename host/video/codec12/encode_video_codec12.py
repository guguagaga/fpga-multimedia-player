"""Encode a video to the tested 720P15 Codec12 profile without shell binary pipes."""
from pathlib import Path
import argparse, hashlib, json, shutil, struct, subprocess
from repack_codec12_stream import repack

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg'))
    parser.add_argument('--frames', type=int, help='Optional short trial; omit to encode the whole input')
    args = parser.parse_args()
    source = args.input.resolve(); output = args.output.resolve()
    encoder = Path(__file__).resolve().parent / 'encode_blocks_experimental.exe'
    if not source.is_file() or source == output or not args.ffmpeg:
        raise ValueError('Input must exist, output must differ, and FFmpeg must be supplied or on PATH')
    if args.frames is not None and args.frames < 1:
        raise ValueError('--frames must be positive')
    if sha(encoder) != '452b0d25c6728ebd861b86b9c24895f1396e713e2123d3d889409dac0cb22123':
        raise ValueError('Bundled encoder hash differs from the tested profile')
    intermediate = output.with_name(output.name + '.unpacked.C12')
    ff_log = output.with_name(output.name + '.ffmpeg.log')
    enc_log = output.with_name(output.name + '.encoder.log')
    report_path = output.with_name(output.name + '.json')
    for path in (output, intermediate, ff_log, enc_log, report_path, output.with_name(output.name+'.partial')):
        if path.exists():
            raise FileExistsError(f'Refuse to overwrite {path}')
    output.parent.mkdir(parents=True, exist_ok=True)
    # Keep the exact production filter graph: inserting pad can change FFmpeg's
    # negotiated intermediate pixel format even for an already 16:9 source.
    # This profile targets 16:9 input; other aspect ratios are stretched.
    filters = 'scale=1280:720:flags=lanczos,fps=15'
    command = [str(args.ffmpeg), '-nostdin', '-hide_banner', '-loglevel', 'error', '-threads', '2', '-i', str(source), '-vf', filters]
    if args.frames is not None:
        command += ['-frames:v', str(args.frames)]
    command += ['-pix_fmt', 'rgb565le', '-f', 'rawvideo', 'pipe:1']
    ff = enc = None
    print('Encoding 1280x720 / 15fps / Codec12 / 125000-byte frame budget', flush=True)
    with ff_log.open('xb') as ff_errors, enc_log.open('xb') as enc_errors:
        try:
            ff = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=ff_errors)
            enc = subprocess.Popen([str(encoder), str(intermediate), '500', '8000', '125000', '15'], stdin=ff.stdout, stderr=enc_errors)
            ff.stdout.close()
            enc_code = enc.wait(); ff_code = ff.wait()
            if enc_code or ff_code:
                raise RuntimeError(f'Encoding failed: encoder={enc_code}, ffmpeg={ff_code}; logs/intermediate preserved')
        finally:
            for process in (enc, ff):
                if process is not None and process.poll() is None:
                    process.terminate(); process.wait()
    with intermediate.open('rb') as stream:
        header = stream.read(512)
    if header[:6] != b'FPGV\x01\x0c' or struct.unpack_from('<HHH', header, 6) != (1280, 720, 15):
        raise ValueError('Unexpected encoded profile; intermediate preserved')
    count = struct.unpack_from('<I', header, 16)[0]
    if count < 1 or (args.frames is not None and count != args.frames):
        raise ValueError('Unexpected frame count; intermediate preserved')
    print(f'Encoded {count} frames; verifying lossless packing', flush=True)
    result = repack(intermediate, output)
    result.update(input=str(source), input_sha256=sha(source), encoder_sha256=sha(encoder),
                  width=1280, height=720, fps=15, duration_seconds=count/15,
                  budget_before_packing=125000, feature_mask=15, ffmpeg_command=command,
                  audio_note='This tool encodes video only. Keep or prepare a correctly matched 48kHz PCM companion audio file.')
    report_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    # Remove only the intermediate this invocation created, after verified output and report exist.
    intermediate.unlink()
    print(f'PASS: {output}\nSHA256: {result["sha256"]}', flush=True)

if __name__ == '__main__':
    main()
