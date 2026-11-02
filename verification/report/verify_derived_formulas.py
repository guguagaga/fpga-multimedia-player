from pathlib import Path
import json, math
import numpy as np
R=Path(__file__).resolve().parent
e=json.loads((R/'spectrum_math_verification.json').read_text(encoding='utf8'))
# Polynomial identities establish the continuous bound without sampling.
# (5/4)(1+t^2) - (1+t/2)^2 = (t-1/2)^2.
assert np.allclose(np.array([1.25,0,1.25])-np.array([1,1,.25]),[.25,-1,1])
# (1+t/2)^2 - (1+t^2) = t(1-3t/4) >= 0 for 0<=t<=1.
assert np.allclose(np.array([1,1,.25])-np.array([1,0,1]),[0,1,-.75])
for m in range(32769):
 assert 0 <= m/2-(m//2) <= .5
for starting in range(249):
 h=starting;c=0
 while h:h=max(0,h-2);c+=1
 assert c==math.ceil(starting/2)
lut=e['contrast_lut']
assert min(1<<i for i,h in enumerate(lut)if h>=5)==32
for b in range(256):
 assert b-(b>>2)==math.ceil(3*b/4)
 for fg in range(256):
  bg=b-(b>>2);c=(12*fg+4*bg)>>4
  assert 0<=c<=255 and c==math.floor(.75*fg+.25*bg)
assert 32*18==608-32 and 32*3==96
assert 256*16+2*256*16+128*32==16384
assert all(v==5635 for v in e['start_to_done_cycles'])
checks=dict(passed=True,continuous_bound_proof='Polynomial identities, t in [0,1]',
 integer_floor_bound_cases=32769,maximum_half_truncation_error=.5,
 decay_initial_states=249,alpha_blend_combinations=65536,
 min_tilted_magnitude=32,fft_clock_mhz=74.256,
 compute_time_us=5635/74.256,
 compute_to_window_percent=(5635/74.256)/(256/48000*1e6)*100,
 source='verify_derived_formulas.py',scope='Report identities and integer bounds; does not replace full hardware verification')
(R/'derived_formula_verification.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps(checks,ensure_ascii=False,indent=2))
