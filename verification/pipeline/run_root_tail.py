"""Force root FAT entry at bytes508..511, including no idle byte cycles."""
from pathlib import Path
import ast,subprocess,struct,json,hashlib,sys,os
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent/'generated/root_tail';D.mkdir(parents=True,exist_ok=True)

tree=ast.parse((R/'verification/fat32/test_directory.py').read_text());tb=next(ast.literal_eval(n.value)for n in tree.body if isinstance(n,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='tb'for t in n.targets))
a=tb.index(' if(!expect_bad)begin');b=tb.index(' $display("PASS fragmented root',a)
tb=tb[:a]+' if(!expect_bad && !geom)$fatal(1,"valid geometry lost");\n'+tb[b:]
tb=tb.replace('if(j%5==0)repeat(2)@(negedge clk);','')
(D/'tb.v').write_text(tb);rtl=R/'rtl/storage/fat32_list.v'
c=subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb','-o',str(D/'sim.vvp'),str(D/'tb.v'),str(rtl)],capture_output=True,text=True);assert c.returncode==0,c.stderr
results=[]
for nxt,bad in [(0x0fffffff,0),(0x01000009,1),(0x0ffffff7,1),(127,1),(0,1),(1,1),(9,0)]:
 disk=bytearray(40000*512);disk[0]=235;struct.pack_into('<H',disk,11,512);disk[13]=1;struct.pack_into('<H',disk,14,2);disk[16]=2;struct.pack_into('<I',disk,32,2000);struct.pack_into('<I',disk,36,8);struct.pack_into('<I',disk,44,127)
 for off in range((18+125)*512,(18+126)*512,32):disk[off]=229
 struct.pack_into('<I',disk,2*512+127*4,nxt)
 # all valid next root sectors contain an immediate directory-end marker.
 (D/'disk.hex').write_text(''.join(f'{x:02x}\n'for x in disk[:160000]))
 c=subprocess.run([os.environ.get('VVP','vvp'),str(D/'sim.vvp'),'+BYTES=160000','+SPC=1','+PART=0','+ACTIVE=0',f'+BAD={bad}'],cwd=D,capture_output=True,text=True,timeout=60)
 out=c.stdout+c.stderr;ok=c.returncode==0 and'PASS fragmented root'in out;print(hex(nxt),out,flush=True);results.append(dict(next=nxt,expected_error=bad,passed=ok,output=out))
(D/'root_tail.json').write_text(json.dumps(dict(passed=all(r['passed']for r in results),scope='Root cluster127 FAT entry at last four sector bytes; continuous byte events and immediate end; EOC/bad/out-of-range/self/free/valid next cluster. No payload reads.',results=results,source_sha256={str(rtl):hashlib.sha256(rtl.read_bytes()).hexdigest()}),indent=2));assert all(r['passed']for r in results)
