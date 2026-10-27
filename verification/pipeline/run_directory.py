"""Compare all directory outputs every cycle against the previous snapshot."""
from pathlib import Path
import ast,re,struct,subprocess,json,hashlib,time,sys,os
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent/'generated/directory';D.mkdir(parents=True,exist_ok=True)
old=D.parents[1]/'directory_reference_source.v';new=R/'rtl/storage/fat32_list.v'
tree=ast.parse((R/'verification/fat32/test_directory.py').read_text())
tb=next(ast.literal_eval(n.value)for n in tree.body if isinstance(n,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='tb'for t in n.targets))

ports=re.search(r'fat32_list dut\((.*?)\);',tb,re.S).group(1)
outputs={'req':1,'ready':1,'geom':1,'bad':1,'addr':32,'base':32,'fat':32,'vid':32,'vau':32,'sec':32,'maxc':28,'shift':4,'count':6,'name':64,'images':3,'im0':32,'im1':32,'im2':32,'im3':32}
decl='\n'.join(f'wire [{n-1}:0] r_{k};'for k,n in outputs.items())
refports=re.sub(r'\((\w+)\)',lambda m:'(r_'+m[1]+')'if m[1]in outputs else m[0],ports)
check='always @(posedge clk) begin #1; if(!rst && {'+','.join(outputs)+'} !== {'+','.join('r_'+k for k in outputs)+'}) $fatal(1,"directory output cycle mismatch");end\n'
tb=tb.replace('reg[7:0]disk',decl+'\nfat_reference refdut('+refports+');\n'+check+'reg[7:0]disk')
a=tb.index(' if(!expect_bad)begin');b=tb.index(' $display("PASS fragmented root',a)
tb=tb[:a]+' idx=0;repeat(12)@(negedge clk);idx=1;repeat(12)@(negedge clk);idx=7;repeat(12)@(negedge clk);\n'+tb[b:]
(D/'reference.v').write_text(old.read_text(encoding='utf-8').replace('module fat32_list','module fat_reference'),encoding='utf-8')
def entry(name,ext,cluster,attr=32):
 b=bytearray(32);b[:8]=name.ljust(8,b' ')[:8];b[8:11]=ext;b[11]=attr;struct.pack_into('<H',b,20,cluster>>16);struct.pack_into('<H',b,26,cluster&65535);return b
results=[];start=time.time()
for fast in [False,True]:
 source=tb.replace('if(j%5==0)repeat(2)@(negedge clk);',''if fast else'if(j%5==0)repeat(2)@(negedge clk);')
 (D/'tb.v').write_text(source)
 c=subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb','-o',str(D/'sim.vvp'),str(D/'tb.v'),str(D/'reference.v'),str(new)],capture_output=True,text=True);assert c.returncode==0,c.stderr
 for spc in [1,2,4,8,16,32,64,128]:
  ds=18;size=(ds+12*spc)*512;disk=bytearray(size);disk[0]=235;struct.pack_into('<H',disk,11,512);disk[13]=spc;struct.pack_into('<H',disk,14,2);disk[16]=2;struct.pack_into('<I',disk,32,2000);struct.pack_into('<I',disk,36,8);struct.pack_into('<I',disk,44,2)
  # Full root cluster: alternating types, caps, duplicates, high/malformed
  # clusters. These are parser fixtures; payload clusters are never read.
  clusters=[0,1,2,0x80000000,0xffffffff,0xffffff7,0xffff,0x10000]
  types=[b'BMP',b'QOI',b'WAV',b'qoa',b'VID',b'VAU']
  for j,off in enumerate(range(ds*512,(ds+spc)*512,32)):
   name=(f'E{j:07d}').encode();attr=32
   if j%19==3:name=b'\xe5ELENTRY'
   if j%19==7:attr=15
   if j%19==11:attr=16
   disk[off:off+32]=entry(name,types[j%6],clusters[(j//6)%8],attr)
  second=(ds+7*spc)*512
  for j,ext in enumerate(types):disk[second+j*32:second+(j+1)*32]=entry(b'LASTFILE',ext,50+j)
  struct.pack_into('<I',disk,2*512+2*4,9);struct.pack_into('<I',disk,2*512+9*4,0xfffffff)
  (D/'disk.hex').write_text(''.join(f'{x:02x}\n'for x in disk))
  c=subprocess.run([os.environ.get('VVP','vvp'),str(D/'sim.vvp'),f'+BYTES={len(disk)}',f'+SPC={spc}','+PART=0','+ACTIVE=0','+BAD=0'],cwd=D,capture_output=True,text=True,timeout=90)
  output=c.stdout+c.stderr;print(f'fast={fast} '+output,flush=True);assert c.returncode==0 and'PASS fragmented root'in output,output
  results.append(dict(spc=spc,consecutive_bytes=fast,passed=True,output=output))
(D/'directory_commit.json').write_text(json.dumps(dict(passed=True,seconds=time.time()-start,scope='16 full directory scans: all eight SPC values, gapped and consecutive valid bytes, fragmented root, all media types, caps/duplicates, deleted/LFN/directory entries and UINT32 malformed cluster extremes; all outputs compared every cycle against v47. Not file payload validation.',results=results,source_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in [new,old,D/'tb.v',D/'reference.v']}),indent=2))
