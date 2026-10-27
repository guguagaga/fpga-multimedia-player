# Replacement ASCII font

`font8x8_basic.h` is the public-domain font table from Daniel Hepper's font8x8
project: https://github.com/dhepper/font8x8/blob/master/font8x8_basic.h

The source header preserves its author and public-domain notices. It is based
on Marcel Sondaar's public-domain VGA fonts. `build/gen_init_data.py` reverses
the row bit order and duplicates every row to produce the 8x16, 95-printable-
ASCII layout expected by this project's `char_rom.v`.

The original release omitted `font_8x16.mem` and its generator. This is a
replacement font; its glyph shapes may differ from the original board image.
