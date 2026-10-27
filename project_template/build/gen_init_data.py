"""Recreate the ROM initialization files omitted from the supplied release.

Twiddles follow twiddle_rom.v: cos - j*sin, signed Q15, real in bits 31:16.
The replacement font doubles public-domain 8x8 VGA rows to fit char_rom.v's
95-character 8x16 ASCII interface. It does not reconstruct the missing font.
"""
from pathlib import Path
import math
import re

ROOT = Path(__file__).resolve().parent.parent
HDL = ROOT / "user_source" / "hdl_source"


def q15(value):
    return max(-32768, min(32767, round(value * 32768)))


def main():
    twiddles = []
    for k in range(128):
        angle = 2 * math.pi * k / 256
        re_part = q15(math.cos(angle))
        im_part = q15(-math.sin(angle))
        twiddles.append(((re_part & 0xFFFF) << 16) | (im_part & 0xFFFF))
    assert twiddles[0] == 0x7FFF0000
    assert twiddles[64] == 0x00008000
    (HDL / "twiddle_256.mem").write_text(
        "".join(f"{word:08X}\n" for word in twiddles), encoding="ascii"
    )

    source = (ROOT / "build" / "fonts" / "font8x8_basic.h").read_text(encoding="utf-8")
    assert "License: Public Domain" in source
    glyphs = []
    for row in re.findall(r"(?m)^\s*\{([^}]+)\}", source):
        values = [int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]+)", row)]
        assert len(values) == 8
        glyphs.append(values)
    assert len(glyphs) == 128
    font = []
    for code in range(0x20, 0x7F):
        for value in glyphs[code]:
            # Source bit 0 is the left pixel; char_rom expects bit 7 at left.
            pixels = int(f"{value:08b}"[::-1], 2)
            font.extend([pixels, pixels])
    assert len(font) == 1520
    assert font[:16] == [0] * 16
    assert any(font[(ord("A") - 32) * 16:(ord("A") - 31) * 16])
    (HDL / "font_8x16.mem").write_text(
        "".join(f"{row:02X}\n" for row in font), encoding="ascii"
    )
    print("Generated 128 complex Q15 twiddles and 1520 ASCII font rows")


if __name__ == "__main__":
    main()
