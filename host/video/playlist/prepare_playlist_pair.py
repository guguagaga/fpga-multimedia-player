"""Validate an encoded 720P15 Codec12/PCM pair and stage it in an empty numbered slot."""
from pathlib import Path
import argparse,hashlib,json,re,shutil,struct,wave

def sha(path):
    with path.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--video',type=Path,required=True);p.add_argument('--audio',type=Path,required=True)
    p.add_argument('--slot',type=int,choices=range(1,5),required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();video=a.video.resolve();audio=a.audio.resolve();out=a.output.resolve()
    with video.open('rb')as f:h=f.read(512)
    if len(h)!=512 or h[:6]!=b'FPGV\x01\x0c' or struct.unpack_from('<HHH',h,6)!=(1280,720,15):
        raise ValueError('Expected the v182 1280x720/15fps Codec12 profile')
    declared,count=struct.unpack_from('<II',h,12)
    if count<1 or not 512<declared<=video.stat().st_size or video.stat().st_size-declared>511:
        raise ValueError('Invalid video header length/frame count')
    with wave.open(str(audio),'rb')as w:
        if w.getparams()[:3]!=(1,2,48000) or w.getcomptype()!='NONE':
            raise ValueError('Expected RIFF/WAVE PCM 48kHz, mono, 16-bit (VAU extension is allowed)')
        samples=w.getnframes()
    expected=count*3200
    if samples!=expected:
        raise ValueError(f'Companion PCM must contain exactly {expected} samples, found {samples}. Trim/pad audio before staging.')
    out.mkdir(parents=True,exist_ok=True)
    for entry in out.iterdir():
        if re.match(fr'(?i)^[MV]{a.slot}.*\.(VID|VAU)$',entry.name):
            raise FileExistsError(f'Numbered slot already occupied: {entry}; resolve duplicates explicitly')
    destinations=[out/f'M{a.slot}_VIDEO.VID',out/f'V{a.slot}_AUDIO.VAU']
    manifest=out/f'PAIR{a.slot}.json'
    if manifest.exists():raise FileExistsError(manifest)
    records=[]
    for source,target in zip((video,audio),destinations):
        expected_hash=sha(source)
        with source.open('rb')as src,target.open('xb')as dst:shutil.copyfileobj(src,dst,1024*1024)
        actual=sha(target)
        if actual!=expected_hash:raise IOError(f'Copy verification failed; files preserved: {target}')
        records.append(dict(source=str(source),file=target.name,sha256=actual,bytes=target.stat().st_size))
    report=dict(slot=a.slot,frames=count,seconds=count/15,pcm_samples=samples,files=records,
                scope='Header/profile/duration and copied-file hashes verified. Use the production encoder canonical validation for payload correctness; this tool does not certify hardware playback.')
    manifest.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
