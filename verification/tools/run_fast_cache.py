from pathlib import Path
import subprocess,hashlib,json,time,os
R=Path(__file__).resolve().parents[1];P=R/'candidate/project';H=P/'user_source/hdl_source';D=R/'tests/fast_cache';D.mkdir(exist_ok=True)
(R/'reports').mkdir(exist_ok=True)
s=(D/'tb.v').read_text()
s=s.replace('width=800;height=600;', 'width=1280;height=960;')
s=s.replace('expected=pixels;', 'expected=y*(height/480)*width+x*(width/640);')
s=s.replace('PASS image_sd_cache', 'PASS fast image SD cache')
(D/'tb.v').write_text(s)
files=[D/'tb.v',H/'SD/sd_card_bmp.v',H/'SD/bmp_read.v',H/'qoi_stream.v',P/'rtl/img_scaler.v',P/'rtl/pixel_fifo_24x8.v',H/'SD/frame_fifo_write.v',P/'rtl/carousel_period_cfg.v',H/'sd_arbiter.v',H/'SD/sd_card_sec_read_write.v',P/'rtl/fat32_list.v']
snap={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}
script='onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+f.as_posix()+'}'for f in files)+'\nvsim work.tb_image_native_cache +BYTE_CYCLES=32\nrun -all\nquit -code 0\n'
(D/'run.do').write_text(script);start=time.time()
with(D/'console.log').open('w')as log:p=subprocess.run([str(Path(os.environ['MODELSIM_BIN'])/'vsim.exe'),'-c','-l','transcript.log','-do','run.do'],cwd=D,stdout=log,stderr=subprocess.STDOUT)
out=(D/'console.log').read_text(errors='replace');ok=p.returncode==0 and 'PASS fast image SD cache'in out and not any(t in out for t in ['** Error','** Fatal','FATAL:'])
assert snap=={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}
(R/'reports/fast_cache.json').write_text(json.dumps({'passed':ok,'seconds':time.time()-start,'source_sha256':snap,'scope':'1280x960 BMP, real production arbiter/CMD18 cache/scaler/writer; command-interface card model, audio contention; all 480000 pixels and SDRAM addresses','summary':out[-3500:]},indent=2))
print(out[-3500:]);assert ok
