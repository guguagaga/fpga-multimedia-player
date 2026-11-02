"""Independent exact/numeric checks for quantities used in the submission report."""
from fractions import Fraction
from pathlib import Path
import json
import math


def main():
    checks = {}
    width, height, fps = 1280, 720, 30
    pixels = width * height
    blocks = pixels // 64
    assert (pixels, blocks, pixels * 2 * fps) == (921600, 14400, 55296000)
    assert 3 * blocks + 1 == 43201
    assert 125000 - 43201 == 81799
    assert 32768 + 16384 + 8192 == 57344
    checks['raw_bytes_per_second'] = pixels * 2 * fps
    checks['video_mean_bytes_per_second'] = 601859906 / 271.2
    checks['lossless_reduction_percent'] = (1 - 601859906 / 954604632) * 100
    checks['spi_bytes_per_second'] = 1e9 / (11 * 32)
    checks['max_frame_pure_spi_ms'] = 81745 * 32 * 11 / 1e6
    checks['peak_second_payload_fraction'] = 2446393 / checks['spi_bytes_per_second']
    checks['frame_interval_ms'] = 3030304 * 11 / 1e6
    assert abs(checks['frame_interval_ms'] - 33.333344) < 1e-9
    checks['pcm_reserve_ms'] = {str(n): n / 192000 * 1000 for n in (4096, 8192)}
    checks['fft'] = dict(window_ms=256/48000*1000, bin_hz=48000/256,
                         enbw_hz=1.5*48000/256, butterflies=256//2*8,
                         memory_bits=256*16+2*256*16+128*32,
                         computation_us=5635/74.256)
    assert checks['fft']['butterflies'] == 1024
    assert checks['fft']['memory_bits'] == 16384
    for n in range(1,65):
        samples=[(37*k+13*n)%64 for k in range(n)]
        mean=Fraction(sum(samples),n)
        for color in range(64):
            error=sum((Fraction(x)-color)**2 for x in samples)
            centered=sum((Fraction(x)-mean)**2 for x in samples)
            assert error == centered+n*(mean-color)**2
    # Continuous magnitude bound: (5/4)(1+t²)-(1+t/2)²=(t-1/2)².
    for num in range(1001):
        t=Fraction(num,1000)
        assert Fraction(5,4)*(1+t*t)-(1+t/2)**2 == (t-Fraction(1,2))**2
        assert (1+t/2)**2-(1+t*t) == t*(1-3*t/4)
        assert t*(1-3*t/4) >= 0
    checks['magnitude_max_relative_overestimate'] = math.sqrt(5)/2-1
    checks['resources'] = {
        'LUT': [18365,19600], 'registers': [11872,19600],
        'Slice': [9445,9800], 'BRAM9K': [63,64], 'BRAM32K': [16,16],
        'DSP': [22,29], 'PLL': [3,4],
    }
    checks['utilization_percent']={k:100*a/b for k,(a,b) in checks['resources'].items()}
    checks['passed']=True
    checks['scope']='Arithmetic identities and report values; does not replace RTL or board tests.'
    out=Path(__file__).with_name('submission_calculations.json')
    out.write_text(json.dumps(checks,ensure_ascii=False,indent=2),encoding='utf8')
    print('PASS report arithmetic and exact error identities:',out)


if __name__=='__main__':
    main()
