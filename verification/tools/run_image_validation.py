from pathlib import Path
import subprocess,concurrent.futures,json,time,hashlib,sys,argparse,os
parser=argparse.ArgumentParser(description='Verify BMP row skipping, reference pixels, writer addresses and carousel behavior.')
parser.add_argument('--modelsim-dir',type=Path,default=os.environ.get('MODELSIM_BIN'))
parser.add_argument('--tests',nargs='+',choices=['rows','fast','baseline','handshake','period'],default=['rows','fast','baseline','handshake','period'])
parser.add_argument('--workers',type=int,default=2)
options=parser.parse_args()
if not options.modelsim_dir: parser.error('Supply --modelsim-dir (directory containing vsim.exe, vlog.exe and vlib.exe)')
p=Path(__file__).resolve().parent.parent
ms=options.modelsim_dir
snapshot={str(f.relative_to(p)):hashlib.sha256(f.read_bytes()).hexdigest() for f in (p/'candidate/project').rglob('*') if f.is_file() and '_Runs' not in str(f) and f.suffix.lower() in ['.v','.mem','.sdc','.adc','.al']}
sim=p/'fpga/sim'
r=p/'fpga/reports/image_fast'
r.mkdir(parents=True,exist_ok=True)
rtl=p/'candidate/project/rtl'
sd=p/'candidate/project/user_source/hdl_source/SD'
P_QOI=p/'candidate/project/user_source/hdl_source/qoi_stream.v'
common=[rtl/'fat32_list.v',sd/'sd_card_bmp.v',sd/'bmp_read.v',P_QOI,rtl/'img_scaler.v',rtl/'pixel_fifo_24x8.v',sd/'frame_fifo_write.v',rtl/'carousel_period_cfg.v']
cases=[
 ('rows','tb_image_rows',[sim/'tb_image_rows.v',sd/'bmp_read.v',P_QOI],[],'PASS all row-selection and fallback tests'),
 ('fast','tb_image_fast',[sim/'tb_image_fast.v',*common],[],'PASS prefetch two transitions'),
 ('baseline','tb_image_fast',[sim/'tb_image_fast.v',*common],['-gENABLE_FAST=0'],'PASS baseline performance run'),
 ('handshake','tb_bmp_handshake',[sim/'work/video_800x600/tb_bmp_handshake.v',sd/'bmp_read.v',P_QOI],[],'PASS writer-ack wait can be cancelled'),
 ('period','tb_carousel_period_cfg',[sim/'work/video_800x600/tb_carousel_period_cfg.v',*common],[],'PASS'),
]
def run(case):
 name,top,sources,args,marker=case
 start=time.time()
 lib=p/'fpga/sim_runs'/('image_'+name)
 print('RUN',name,flush=True)
 outputs=[]
 for cmd in [
  [ms/'vlib.exe',lib],
  [ms/'vlog.exe','-sv','-work',lib,*sources],
  [ms/'vsim.exe','-c','-lib',lib,'-l',r/(name+'.log'),*args,top,'-do','onerror {quit -code 1}; run -all; quit -f -code 0'],
 ]:
  z=subprocess.run(list(map(str,cmd)),cwd=sim,capture_output=True,text=True,errors='replace')
  outputs.append(z.stdout+z.stderr)
  if z.returncode:break
 text='\n'.join(outputs)
 (r/(name+'_console.txt')).write_text(text,encoding='utf-8')
 ok=z.returncode==0 and marker in text and '** Error' not in text and '** Fatal' not in text and 'FATAL' not in text
 result={'test':name,'passed':ok,'seconds':round(time.time()-start,2),'returncode':z.returncode}
 print(json.dumps(result),flush=True)
 if not ok:print(text[-5000:],flush=True)
 return result
cases=[c for c in cases if c[0] in options.tests]
with concurrent.futures.ThreadPoolExecutor(max_workers=options.workers) as pool:
 results=list(pool.map(run,cases))
unchanged=all(hashlib.sha256((p/name).read_bytes()).hexdigest()==h for name,h in snapshot.items())
report={'passed':all(x['passed'] for x in results) and unchanged,'source_unchanged':unchanged,'source_sha256':snapshot,'results':results,
 'bmp_sha256':hashlib.sha256((sd/'bmp_read.v').read_bytes()).hexdigest()}
(r/('validation_'+'_'.join(c[0] for c in cases)+'.json')).write_text(json.dumps(report,indent=2),encoding='utf-8')
raise SystemExit(not report['passed'])
