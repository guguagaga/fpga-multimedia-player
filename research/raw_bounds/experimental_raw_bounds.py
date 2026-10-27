"""Offline-only exact RGB5654x4 channel-bounds block format proposal.

This is not accepted by the current production FPGA decoder. No complete
movie container or bitstream is produced by this module.
"""
import struct
RAW=0x83;BOUNDS=0x86
def _quad_encode(px):
 channels=[[p>>11 for p in px],[(p>>5)&63 for p in px],[p&31 for p in px]]
 lows=[min(c)for c in channels];widths=[(max(c)-min(c)).bit_length()for c in channels]
 base=(lows[0]<<11)|(lows[1]<<5)|lows[2];meta=widths[0]|(widths[1]<<3)|(widths[2]<<6)
 stream=0;shift=0
 for p in px:
  for value,lo,width in zip([p>>11,(p>>5)&63,p&31],lows,widths):
   stream|=(value-lo)<<shift;shift+=width
 packed=struct.pack('<HH',base,meta)+stream.to_bytes((shift+7)//8,'little')
 return (1,packed)if len(packed)<32 else(0,struct.pack('<16H',*px))
def encode(px):
 if len(px)!=64 or any(not 0<=x<=65535 for x in px):raise ValueError('64 RGB565 pixels required')
 flags=0;payload=bytearray()
 for qy in range(2):
  for qx in range(2):
   quad=[px[(qy*4+y)*8+qx*4+x]for y in range(4)for x in range(4)]
   kind,data=_quad_encode(quad);flags|=kind<<(2*(qy*2+qx));payload.extend(data)
 candidate=bytes([BOUNDS,flags])+payload
 return candidate if len(candidate)<129 else bytes([RAW])+struct.pack('<64H',*px)
def decode(packet):
 if not packet:raise ValueError('empty packet')
 if packet[0]==RAW:
  if len(packet)!=129:raise ValueError('RAW length')
  return struct.unpack('<64H',packet[1:])
 if packet[0]!=BOUNDS or len(packet)<2:raise ValueError('unsupported experimental opcode')
 pos=2;out=[0]*64
 for qy in range(2):
  for qx in range(2):
   kind=(packet[1]>>(2*(qy*2+qx)))&3
   if kind==0:
    if pos+32>len(packet):raise ValueError('short raw quadrant')
    quad=struct.unpack_from('<16H',packet,pos);pos+=32
   elif kind==1:
    if pos+4>len(packet):raise ValueError('short bounds header')
    base,meta=struct.unpack_from('<HH',packet,pos);pos+=4
    widths=[meta&7,(meta>>3)&7,(meta>>6)&7]
    if meta>>9 or any(w>lim for w,lim in zip(widths,[5,6,5])):raise ValueError('invalid bit widths')
    lows=[base>>11,(base>>5)&63,base&31];bits=16*sum(widths);n=(bits+7)//8
    if pos+n>len(packet):raise ValueError('short residual data')
    stream=int.from_bytes(packet[pos:pos+n],'little');pos+=n;quad=[]
    for _ in range(16):
     values=[]
     for low,width,limit in zip(lows,widths,[31,63,31]):
      value=low+(stream&((1<<width)-1));stream>>=width
      if value>limit:raise ValueError('channel overflow')
      values.append(value)
     quad.append((values[0]<<11)|(values[1]<<5)|values[2])
   else:raise ValueError('reserved quadrant kind')
   for y in range(4):
    for x in range(4):out[(qy*4+y)*8+qx*4+x]=quad[y*4+x]
 if pos!=len(packet):raise ValueError('trailing packet bytes')
 return tuple(out)
if __name__=='__main__':
 import random,json
 rng=random.Random(20261027);cases=[]
 for _ in range(10000):
  lows=[rng.randrange(32),rng.randrange(64),rng.randrange(32)];span=[rng.randrange(32-lows[0]),rng.randrange(64-lows[1]),rng.randrange(32-lows[2])]
  cases.append(tuple(((lows[0]+rng.randrange(span[0]+1))<<11)|((lows[1]+rng.randrange(span[1]+1))<<5)|(lows[2]+rng.randrange(span[2]+1))for _ in range(64)))
 cases+=[tuple([p]*64)for p in [0,1,31,65535,0x7bef]]
 cases+=[tuple(rng.randrange(65536)for _ in range(64))for _ in range(1000)]
 for px in cases:assert decode(encode(px))==px
 bad_packets=[b'',b'\x86',b'\x86\xff',b'\x83',b'\x82',
  b'\x86\x55'+bytes(16)+b'\x00',
  b'\x86\x01'+struct.pack('<HH',0,6)+bytes(96),
  b'\x86\x01'+struct.pack('<HH',0,7<<3)+bytes(96),
  b'\x86\x01'+struct.pack('<HH',0,6<<6)+bytes(96),
  b'\x86\x01'+struct.pack('<HH',0,512)+bytes(96),
  b'\x86\x01'+struct.pack('<HH',0xf800,1)+b'\xff\xff'+bytes(96),
  b'\x86\x01'+struct.pack('<HH',0,1)+b'\x00']
 for bad in bad_packets:
  try:decode(bad)
  except ValueError:pass
  else:raise AssertionError('malformed packet accepted')
 print(json.dumps(dict(passed=True,blocks=len(cases),pixels=len(cases)*64,rejected_packets=len(bad_packets),scope='Offline experimental packet roundtrip and malformed rejection: unknown/reserved modes, short packets, illegal RGB widths, reserved metadata, channel overflow, trailing bytes. No productionRTL integration.')))
