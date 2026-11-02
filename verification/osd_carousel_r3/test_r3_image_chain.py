"""Exercise actual image-reader/fit/write handshake with vendor RAM models."""
from pathlib import Path
import hashlib,json,os,re,shutil,struct,subprocess,time
R=Path('D:/codexworks/framerate_v185_20261029')
C=Path('D:/codexworks/osd_carousel_v187/rebuild_r3')
S=R/'residual_hybrid64_lutqoi/tests/image_integration'
T=C/'tests/integration_ase';T.mkdir(parents=True,exist_ok=False)
env=dict(os.environ,TEMP=str(R/'tmp'),TMP=str(R/'tmp'))
results=[]
files={}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for kind,w,h in [(1,320,240),(0,1280,960)]:
    O=T/f'kind{kind}_{w}x{h}';O.mkdir()
    shutil.copy2(S/'tb.v',O/'tb.v')
    hdr=bytearray(512)
    if kind:
        hdr[:14]=b'qoif'+struct.pack('>II',w,h)+bytes([3,0])
    else:
        stride=(w*3+3)//4*4
        hdr[:2]=b'BM'
        struct.pack_into('<I',hdr,2,54+stride*h)
        struct.pack_into('<I',hdr,10,54)
        struct.pack_into('<IiiHHIIiiII',hdr,14,40,w,h,1,24,0,stride*h,0,0,0,0)
    (O/'header.hex').write_text('\n'.join(f'{x:02x}'for x in hdr)+'\n')
    script=(S/'run.do').read_text().replace((R/'residual_hybrid64_lutqoi/candidate/project').as_posix(),(C/'candidate/project').as_posix()).replace(S.as_posix(),O.as_posix())
    script=script.replace('+W=320 +H=240 +KIND=1',f'+W={w} +H={h} +KIND={kind}')
    (O/'run.do').write_text(script)
    for name in re.findall(r'\{([^{}]+\.v)\}',script):
        p=Path(name);files[str(p)]=sha(p)
    files[str(O/'header.hex')]=sha(O/'header.hex')
    start=time.time()
    with (O/'console.log').open('w')as log:
        proc=subprocess.run(['E:/modelsim/modelsim_ase/win32aloem/vsim.exe','-c','-do','run.do'],cwd=O,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=900)
    log=(O/'console.log').read_text(errors='replace')
    passed=proc.returncode==0 and 'PASS IMAGE CHAIN' in log and '** Error' not in log and '** Fatal' not in log
    result=dict(kind=kind,w=w,h=h,passed=passed,returncode=proc.returncode,seconds=time.time()-start,log=str(O/'console.log'))
    results.append(result);print(json.dumps(result),flush=True)
    if not passed:break
report=dict(passed=len(results)==2 and all(x['passed']for x in results),cases=results,source_sha256=files,
    scope='Actual SD sector stream -> BMP/QOI reader -> image_fit -> output write/ack/commit, vendor QOI RAM models. Two full 921600-pixel frames, exact color/borders with backpressure; BMP fast row skip and QOI low-resolution adaptation.')
(T/'result.json').write_text(json.dumps(report,indent=2))
assert report['passed']
