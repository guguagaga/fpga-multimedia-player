"""Pure reversible H6D1 transforms; no benchmark or filesystem side effects.

The source is packed Codec12 tokens. No color quantization or pixel filtering
occurs here. Predictors reset per frame; index predictors reset per block.
"""
COLORS = {128: 1, 129: 2, 131: 64, 132: 4, 133: 1, 134: 4, 135: 2, 136: 4}


def transform(data, inverse=False):
    out = bytearray(data)
    pos = 0
    previous_color = 0
    while pos < len(data):
        op = data[pos]
        pos += 1
        if op == 255:
            if pos != len(data):
                raise ValueError('Trailing bytes after frame terminator')
            return bytes(out)
        if op not in COLORS:
            raise ValueError(f'Invalid opcode {op:#x}')
        pos += int(op in (133, 135))
        count = COLORS[op]
        indices = {129: 8, 136: 16}.get(op, 0)
        if pos + count * 2 + indices > len(data):
            raise ValueError('Truncated block')
        for _ in range(count):
            value = data[pos] | (data[pos + 1] << 8)
            restored = (value + previous_color if inverse else value - previous_color) & 65535
            out[pos] = restored & 255
            out[pos + 1] = restored >> 8
            previous_color = restored if inverse else value
            pos += 2
        previous_row = [0, 0]
        for i in range(indices):
            slot = i % 2 if op == 136 else 0
            value = data[pos] ^ previous_row[slot]
            previous_row[slot] = value if inverse else data[pos]
            out[pos] = value
            pos += 1
    raise ValueError('Missing frame terminator')
