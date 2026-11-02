"""Convert an ordinary video file into the player's paired VID/VAU files."""
from pathlib import Path
from decimal import Decimal, ROUND_FLOOR
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Video input: MP4, MKV, MOV, AVI, etc. supported by FFmpeg')
    parser.add_argument('--audio', type=Path, help='Separate synchronized audio input; defaults to video input')
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--ffprobe', type=Path, help='Defaults to ffprobe.exe beside ffmpeg.exe')
    parser.add_argument('--output', type=Path, required=True, help='New output directory on D:')
    parser.add_argument('--fps', type=int, choices=[20, 30], default=30)
    parser.add_argument('--start', type=Decimal, default=Decimal(0))
    parser.add_argument('--seconds', type=Decimal, help='Omit to encode the whole remaining video')
    parser.add_argument('--slot', type=int, choices=[1, 2, 3, 4], default=2)
    args = parser.parse_args()
    ff = args.ffmpeg.resolve()
    probe = (args.ffprobe or ff.with_name('ffprobe.exe')).resolve()
    source = args.input.resolve()
    audio = (args.audio or source).resolve()
    out = args.output.resolve()
    for p in [ff, probe, source, audio]:
        if not p.is_file():parser.error('File not found: '+str(p))
    if out.drive.upper() != 'D:':parser.error('Work and output directory must be on D:')
    if out.exists():parser.error('Output directory already exists; select a new directory')
    if args.start < 0:parser.error('--start must be nonnegative')
    def inspect(path):
        return json.loads(subprocess.check_output([str(probe), '-v', 'error', '-show_streams',
                         '-show_format', '-of', 'json', str(path)], encoding='utf-8'))
    metadata = inspect(source)
    video_stream = next((s for s in metadata['streams'] if s['codec_type']=='video'), None)
    if video_stream is None:parser.error('Input contains no video stream')
    audio_meta = metadata if audio == source else inspect(audio)
    if not any(s['codec_type']=='audio' for s in audio_meta['streams']):
        parser.error('No audio stream found; provide a synchronized audio file with --audio')
    duration_value = video_stream.get('duration') or metadata.get('format', {}).get('duration')
    if args.seconds is None and duration_value is None:
        parser.error('Duration unavailable; specify --seconds')
    requested = args.seconds if args.seconds is not None else Decimal(duration_value)-args.start
    if requested <= 0:parser.error('Requested duration must be positive')
    if duration_value and args.start+requested > Decimal(duration_value)+Decimal('0.001'):
        parser.error('Requested interval exceeds the input duration')
    frame_value = requested*args.fps
    # Container durations are commonly rounded to microseconds (e.g. 7/30).
    # Restore a near-integer endpoint only for probed full-file durations.
    nearest = frame_value.to_integral_value()
    if args.seconds is None and abs(frame_value-nearest) <= Decimal('0.001'):
        frame_value = nearest
    frames = int(frame_value.to_integral_value(rounding=ROUND_FLOOR))
    if frames < 1:parser.error('Requested duration is shorter than one frame')
    duration = Decimal(frames)/args.fps
    # Pass an integer frame count so full-length inputs need no decimal duration rounding.
    backend = Path(__file__).resolve().parent/'codec14'
    for name in ['encode_blocks_experimental.exe', 'adpcm-xq.exe', 'index_residual.json']:
        if not (backend/name).is_file():parser.error('Missing bundled tool: '+str(backend/name))
    out.mkdir(parents=True)
    temp = out/'tmp';temp.mkdir()
    env = dict(os.environ, TEMP=str(temp), TMP=str(temp), PYTHONDONTWRITEBYTECODE='1', PYTHONUTF8='1')
    cmd = [sys.executable, '-X', 'utf8', str(backend/'encode_h6d1_video.py'),
           '--ffmpeg', str(ff), '--fps', str(args.fps), '--frames', str(frames),
           '--start', str(args.start), '--video', str(source), '--audio', str(audio),
           '--output', str(out/'work')]
    with (out/'encoding.log').open('w', encoding='utf-8') as log:
        subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        video = out/'work'/f'EXPERIMENTAL_720P{args.fps}.VID'
        ima = out/'work/AUDIO_IMA.VAU'
        subprocess.run([sys.executable, '-X', 'utf8', str(backend/'encode_ima_audio.py'),
                        '--video', str(video), '--pcm', str(out/'work/EXPERIMENTAL_AUDIO.VAU'),
                        '--output', str(ima)], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    vr = json.loads(video.with_suffix('.json').read_text())
    ar = json.loads(ima.with_suffix('.json').read_text())
    assert vr['passed'] and ar['passed'] and vr['frames']==ar['frames']==frames
    ready = out/'sdcard';ready.mkdir()
    names = (f'M{args.slot}_VIDEO.VID', f'V{args.slot}_AUDIO.VAU')
    for src,name in zip([video,ima], names):shutil.copy2(src,ready/name)
    def sha(path):
        with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
    manifest = dict(passed=True,input=str(source),audio=str(audio),source_start=str(args.start),
                    source_metadata=metadata,frames=frames,fps=args.fps,duration_seconds=float(duration),
                    end_trim_seconds=float(requested-duration),width=1280,height=720,
                    audio_samples=frames*48000//args.fps,spatial_budget=125000,
                    verification='Per-frame lossless-stage round trip and disk reread; IMA decoded sample count',
                    files={n:dict(bytes=(ready/n).stat().st_size,sha256=sha(ready/n))for n in names},
                    mean_video_bytes_s=vr['mean_bytes_per_frame']*args.fps,
                    max_frame_bytes=vr['max_frame_bytes'])
    (out/'conversion.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    print('PASS: '+str(ready))
    print(f'{frames} frames, {args.fps} fps, {float(duration):.6f} seconds; output verified')


if __name__ == '__main__':
    main()
