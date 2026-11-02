"""Verify the bundled spectrum RTL against an independent integer model.

Run from the unpacked project root with --vsim and a new --output directory.
Generated simulation files and results stay in that output directory.
"""

from pathlib import Path
import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import numpy as np

R = Path(__file__).resolve().parent
S = R.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--vsim', required=True, type=Path, help='Path to ModelSim vsim.exe')
parser.add_argument('--output', required=True, type=Path, help='New verification output directory on D:')
args = parser.parse_args()
vsim = args.vsim.resolve()
T = args.output.resolve()
if not vsim.is_file():
    parser.error('ModelSim executable not found')
if T.drive.upper() != 'D:':
    parser.error('Verification output must be on D:')
if T.exists():
    parser.error('Output already exists; choose a new directory')
T.mkdir(parents=True)
(T / 'tmp').mkdir()
os.environ['TEMP'] = str(T / 'tmp')
os.environ['TMP'] = str(T / 'tmp')
if not __debug__:
    parser.error('Run Python without -O; assertions are part of the checks')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
code=lambda n:(S/'rtl/spectrum'/n).read_text(encoding='utf8')
hann=[int(v) for _,v in re.findall(r"8'd(\d+): hann = 16'd(\d+)",code('audio_frame.v'))]
assert len(hann)==256
mapping={int(k):int(v) for k,v in re.findall(r'(\d+): log_map = (\d+);',code('spectrum_capture.v'))}
lut=[int(v) for _,v in re.findall(r"4'd(\d+): contrast_lut = 8'd(\d+)",code('spectrum_capture.v'))]
assert len(mapping)==128 and len(lut)==16
twpath=S/'rtl/control/twiddle_256.mem'
tw=[int(x,16) for x in twpath.read_text().split()]
signed=lambda x:x-65536 if x>=32768 else x
tw=[(signed(x>>16),signed(x&65535)) for x in tw]
sat=lambda x:max(-32768,min(32767,x))
def fixed_fft(samples):
 a=[(0,0)]*256
 for i,v in enumerate(samples):a[int(f'{i:08b}'[::-1],2)]=(int(v),0)
 for stage in range(8):
  d=1<<stage
  for group in range(0,256,2*d):
   for k in range(d):
    ar,ai=a[group+k];br,bi=a[group+k+d];wr,wi=tw[k<<(7-stage)]
    tr=(br*wr-bi*wi+16384)>>15;ti=(bi*wr+br*wi+16384)>>15
    a[group+k]=(sat((ar+tr)>>1),sat((ai+ti)>>1))
    a[group+k+d]=(sat((ar-tr)>>1),sat((ai-ti)>>1))
 return a
def heights(a):
 bars=[]
 for k,(re_,im_) in enumerate(a):
  mx,mn=max(abs(re_),abs(im_)),min(abs(re_),abs(im_))
  m=min(65535,2*(mx+(mn>>1)))
  q=m>>2
  mt=m if k<20 else m+q if k<40 else 2*m-q if k<57 else 4*m+q
  n=min(15,max(0,mt.bit_length()-1))
  bars.append(lut[n])
 return bars
n=np.arange(256)
signals=[('silence',np.zeros(256,dtype=int)),('impulse',np.eye(1,256,128,dtype=int)[0]*30000),('dc',np.full(256,10000))]
for k in [1,5,20,57,67,126]:signals.append((f'bin{k}',np.rint(12000*np.sin(2*np.pi*k*n/256)).astype(int)))
signals += [('offbin5_4',np.rint(12000*np.sin(2*np.pi*5.4*n/256)).astype(int)),('random',np.random.default_rng(20261102).integers(-32768,32768,256))]
windows=[[(int(x)*w+16384)>>15 for x,w in zip(sig,hann)]for _,sig in signals]
ffts=[fixed_fft(x)for x in windows]
state=[0]*32;expected_bars=[]
for a in ffts:
 for k,b in enumerate(heights(a)):
  if 1<=k<127 and b>=5:state[mapping[k]]=max(state[mapping[k]],b)
 state=[max(0,x-2) for x in state];expected_bars.append(state[:])
(T/'samples.mem').write_text('\n'.join(f'{int(x)&65535:04x}'for _,sig in signals for x in sig))
shutil.copy2(twpath,T/'twiddle_256.mem')
tb = (R / 'tb_spectrum.v.in').read_text(encoding='utf8')
tb = tb.replace('NUMS', str(len(signals) * 256)).replace('NFR', str(len(signals)))
(T/'tb.v').write_text(tb)
files=[T/'tb.v']+[S/'rtl/spectrum'/x for x in ['audio_frame.v','fft_256.v','butterfly.v','twiddle_rom.v','spectrum_capture.v']]+[S/'rtl/memory/dp_ram.v']
(T/'run.do').write_text('onerror {quit -code 1}\nvlib work\nvlog -work work '+' '.join('{'+p.as_posix()+'}'for p in files)+'\nvsim -c -voptargs=+acc work.tb\nrun -all\nquit -code 0\n')
with (T/'simulation.log').open('wb') as log:
 run=subprocess.run([str(vsim),'-c','-do','run.do'],cwd=T,stdout=log,stderr=subprocess.STDOUT,timeout=300)
# ModelSim may use the Windows code page for filenames; the marker is ASCII.
assert run.returncode==0 and b'SPECTRUM_REPORT_PASS' in (T/'simulation.log').read_bytes(), (T/'simulation.log')
counts={'F':0,'W':0,'B':0};cycles=[]
for line in (T/'rtl_values.txt').read_text().splitlines():
 fields=line.split();typ=fields[0];vals=list(map(int,fields[1:]));f=vals[0]
 if typ=='C':cycles.append(vals[1]);continue
 k=vals[1];got=vals[2:];want=list(ffts[f][k]) if typ=='F'else [windows[f][k]]if typ=='W'else [expected_bars[f][k]]
 assert got==want,(typ,f,k,got,want)
 counts[typ]+=1
assert counts=={'F':2816,'W':2816,'B':352},counts
hw=np.array(hann)/32768
ideal=.5*(1-np.cos(2*np.pi*n/256))
rows=[]
for b in range(32):
 bins=[k for k in range(1,127)if mapping[k]==b]
 assert bins and bins==list(range(min(bins),max(bins)+1))
 rows.append(dict(band=b,first_bin=min(bins),last_bin=max(bins),count=len(bins),low_hz=min(bins)*187.5,high_hz=max(bins)*187.5))
assert sum(row['count']for row in rows)==126
assert all(mapping[k]<=mapping[k+1]for k in range(127))
fft_error=max(max(abs(complex(*q)-r)for q,r in zip(a,np.fft.fft(w)/256))for a,w in zip(ffts,windows))
result=dict(passed=True,scope='Bundled RTL versus independent integer model; nominal 48 kHz calculations; simulation evidence',
 source_sha256={p.relative_to(S).as_posix():sha(p)for p in files[1:]+[S/'rtl/spectrum/spectrum_display.v',S/'rtl/top/top_tf_hdmi_audio.v',twpath]},
 rtl_checks=counts,signal_names=[s[0]for s in signals],start_to_done_cycles=cycles,
 nominal_fs=48000,N=256,bin_spacing_hz=187.5,window_duration_ms=256/48000*1000,
 hann_sum=int(sum(hann)),coherent_gain=float(hw.mean()),double_gain=float(2*hw.mean()),
 hann_max_abs_error=float(max(abs(hw-ideal))),enbw_bins=float(256*np.dot(hw,hw)/sum(hw)**2),
 theoretical_enbw_hz=1.5*187.5,max_complex_error_vs_float_fft=fft_error,
 real_magnitude_upper_relative_error=math.sqrt(1.25)-1,
 contrast_lut=lut,contrast_formula_discrepancies=[(i,lut[i],round(248*(i-3)**2/144))for i in range(4,16)if lut[i]!=round(248*(i-3)**2/144)],
 bands=rows,full_decay_updates=124,minimum_full_decay_ms=124*256/48000*1000,
 butterflies=8*128,fft_core_cycles=256+8*128*5+257+1,
 butterflies_per_dft_term_ratio=(8*128)/(256*256))
(T/'spectrum_math_verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({k:v for k,v in result.items()if k not in ['source_sha256','bands']},ensure_ascii=False,indent=2))
