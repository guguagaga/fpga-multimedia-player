"""Codec9 encoder wrapper for this candidate's 15/20/25/30 FPS header support."""
from pathlib import Path
import argparse,subprocess,os,hashlib,json,time,struct
from codec_tools import validate

def encode(source,output,fps=15,budget=125000,start=None,duration=None,force=False):
    if output.exists() and not force:raise FileExistsError(output)
    if fps not in (15,20,25,30) or budget<22501:raise ValueError('invalid rate/budget')
    if not source.is_file():raise FileNotFoundError(source)
    output.parent.mkdir(parents=True,exist_ok=True)
    ff=Path(os.environ.get('FFMPEG','ffmpeg'))
    exe=Path(__file__).resolve().parent/'bin/encode_quad.exe'
    args=[str(ff),'-hide_banner','-loglevel','error','-threads','2']
    if start is not None:args+=['-ss',str(start)]
    args+=['-i',str(source)]
    if duration is not None:args+=['-t',str(duration)]
    args+=['-vf',f'scale=800:450:flags=lanczos,pad=800:600:0:75:black,fps={fps}',
           '-pix_fmt','rgb565le','-f','rawvideo','-']
    began=time.time()
    with output.with_suffix('.encode.log').open('w') as log:
        dec=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=log)
        enc=subprocess.Popen([str(exe),str(output),'500','8000',str(budget),'1'],stdin=dec.stdout,stderr=log)
        dec.stdout.close();rc=enc.wait();dr=dec.wait()
        if rc or dr:raise RuntimeError(f'encode failure rc={rc}, decoder={dr}')
    # The frozen C++ encoder serializes exactly the same Codec9 tokens; only
    # this wrapper writes the true sampling rate into the existing FPS field.
    with output.open('r+b') as f:f.seek(10);f.write(struct.pack('<H',fps))
    report=validate(output,budget);report.pop('frame_offsets')
    report.update(source=str(source.resolve()),start_seconds=start,duration_limit=duration,
                  encode_seconds=round(time.time()-began,2),budget=budget,
                  compressed_bytes_per_second=(report['declared_bytes']-512)/report['duration_seconds'],
                  compatibility='Requires the media_speed candidate for FPS > 15. Geometry remains 800x600 with 800x450 content.')
    output.with_suffix('.encoding.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    return report
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('--output',required=True,type=Path)
    p.add_argument('--fps',type=int,choices=[15,20,25,30],default=15);p.add_argument('--budget',type=int,default=125000)
    p.add_argument('--start',type=float);p.add_argument('--duration',type=float);p.add_argument('--force',action='store_true');a=p.parse_args()
    print(json.dumps(encode(a.source,a.output,a.fps,a.budget,a.start,a.duration,a.force),indent=2))
