"""Create four numbered, original diagnostic movies and exactly matched PCM tracks."""
from pathlib import Path
import argparse,hashlib,json,math,struct,wave

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    args=parser.parse_args();out=args.output.resolve()
    out.mkdir(parents=True,exist_ok=False)
    count=30;fps=15;sample_rate=48000
    colors=[(0xf800,'red',440),(0x07e0,'green',660),(0x001f,'blue',880),(0xffe0,'yellow',1100)]
    records=[]
    for slot,(color,name,hz) in enumerate(colors,1):
        # Codec12 solid-run syntax: <=256 consecutive identical 8x8 blocks.
        tokens=bytearray();left=14400
        while left:
            run=min(256,left);tokens+=bytes([0x85,run-1])+struct.pack('<H',color);left-=run
        tokens.append(255)
        payload=tokens*count;header=bytearray(512);header[:6]=b'FPGV\x01\x0c'
        struct.pack_into('<HHHII',header,6,1280,720,fps,512+len(payload),count)
        video=out/f'M{slot}_TEST.VID';video.write_bytes(header+payload+bytes(-(512+len(payload))%512))
        audio=out/f'V{slot}_TEST.VAU'
        samples=sample_rate*count//fps;pcm=bytearray()
        for n in range(samples):
            # A short fade at both ends prevents test-tone discontinuities.
            gain=min(1.0,n/480,(samples-1-n)/480)
            pcm+=struct.pack('<h',round(3000*gain*math.sin(2*math.pi*hz*n/sample_rate)))
        with wave.open(str(audio),'wb')as wav:
            wav.setparams((1,2,sample_rate,0,'NONE','not compressed'));wav.writeframes(pcm)
        records.append(dict(slot=slot,color=name,tone_hz=hz,seconds=count/fps,files={p.name:dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())for p in (video,audio)}))
    (out/'MANIFEST.json').write_text(json.dumps(dict(profile='720P15 Codec12 solid-color diagnostic, PCM48k mono16',scope='Switch/EOF identity test only; very small payload does not test realistic SD throughput or video quality.',clips=records),indent=2),encoding='utf-8')
    print(out)

if __name__=='__main__':main()
