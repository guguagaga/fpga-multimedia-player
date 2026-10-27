from pathlib import Path
import os,subprocess,hashlib,json,struct
R=Path(__file__).resolve().parents[1];D=R/'tests/directory';D.mkdir(exist_ok=True)
tb=r'''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst=1,scan=0;reg[7:0]data=0;reg valid=0,se=0;
wire req,ready,geom,bad;wire[31:0]addr,base,fat,vid,vau,sec;wire[27:0]maxc;wire[3:0]shift;wire[5:0]count;wire[63:0]name;reg[4:0]idx=0;
wire[2:0]images;wire[31:0]im0,im1,im2,im3;
fat32_list dut(.clk(clk),.rst(rst),.scan_start(scan),.sd_init_done(1'b1),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(se),.list_ready(ready),.song_count(count),.list_idx(idx),.list_name(name),.list_sector(sec),.data_start_o(base),.video_sector_o(vid),.vaudio_sector_o(vau),.image_count_o(images),.image0_o(im0),.image1_o(im1),.image2_o(im2),.image3_o(im3),.fat_start_o(fat),.cluster_shift_o(shift),.max_cluster_o(maxc),.geometry_valid_o(geom),.filesystem_error_o(bad));
reg[7:0]disk[0:1999999];integer bytes,spc,part,active,expect_bad,j,lba,transactions=0;reg[31:0]held;
initial begin
 if(!$value$plusargs("BYTES=%d",bytes)||!$value$plusargs("SPC=%d",spc)||!$value$plusargs("PART=%d",part)||!$value$plusargs("ACTIVE=%d",active)||!$value$plusargs("BAD=%d",expect_bad))$fatal(1,"args");
 $readmemh("disk.hex",disk,0,bytes-1);repeat(8)@(negedge clk);rst=0;scan=1;@(negedge clk);scan=0;
 wait(ready);repeat(14)@(negedge clk);
 if(bad!==expect_bad[0])$fatal(1,"filesystem error %d expected %d",bad,expect_bad);
 if(!expect_bad)begin
  if(!geom||base!=part+18||fat!=part+2+active*8||maxc!=((2000-18)/spc)+1)$fatal(1,"geometry base=%d fat=%d max=%d",base,fat,maxc);
  if(count!=2||vid!=base+(30-2)*spc||vau!=base+(40-2)*spc||images!=1||im0!=base+(50-2)*spc)$fatal(1,"fragment root metadata count=%d vid=%d vau=%d images=%d im=%d",count,vid,vau,images,im0);
  idx=0;repeat(12)@(negedge clk);if(name!==64'h534f4e4741202020||sec!=base+8*spc)$fatal(1,"song A");
  idx=1;repeat(12)@(negedge clk);if(name!==64'h534f4e4742202020||sec!=base+18*spc)$fatal(1,"song B");
 end
 $display("PASS fragmented root spc=%d partition=%d active_fat=%d bad=%d transactions=%d",spc,part,active,expect_bad,transactions);$finish;
end
initial begin wait(!rst);forever begin
 @(negedge clk);if(req)begin
  held=addr;transactions=transactions+1;if(held*512+511>=bytes)$fatal(1,"out of disk %d",held);
  repeat(4)@(negedge clk);
  for(j=0;j<512;j=j+1)begin data=disk[held*512+j];valid=1;@(negedge clk);valid=0;if(j%5==0)repeat(2)@(negedge clk);end
  se=1;@(negedge clk);se=0;repeat(5)@(negedge clk);
 end
end end
initial begin #20000000;$fatal(1,"root scan timeout");end
endmodule
'''
(D/'tb.v').write_text(tb);rtl=R/'candidate/project/rtl/fat32_list.v'
c=subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb','-o',str(D/'sim.vvp'),str(D/'tb.v'),str(rtl)],capture_output=True,text=True);assert c.returncode==0,c.stderr
def entry(name,ext,cluster,attr=32):
 b=bytearray(32);b[:8]=name.ljust(8,b' ');b[8:11]=ext;b[11]=attr;struct.pack_into('<H',b,20,cluster>>16);struct.pack_into('<H',b,26,cluster&65535);return b
results=[]
for spc,part,active,bad in [(x,0,0,0)for x in [1,2,4,8,16,32,64,128]]+[(16,7,1,0),(1,0,0,1),(1,7,1,2)]:
 ds=part+18;size=(ds+12*spc)*512;d=bytearray(size);boot=bytearray(512);boot[0]=235;struct.pack_into('<H',boot,11,512);boot[13]=spc;struct.pack_into('<H',boot,14,2);boot[16]=2;struct.pack_into('<I',boot,32,2000);struct.pack_into('<I',boot,36,8);struct.pack_into('<H',boot,40,0x80|active);struct.pack_into('<I',boot,44,2)
 if part:struct.pack_into('<I',d,454,part)
 d[part*512:(part+1)*512]=boot
 # Root cluster2 is full with deleted entries; next is nonadjacent cluster9.
 for off in range(ds*512,(ds+spc)*512,32):d[off]=229
 d[ds*512:ds*512+32]=entry(b'SONGA',b'WAV',10)
 second=(ds+7*spc)*512
 for k,e in enumerate([entry(b'SONGB',b'qoa',20),entry(b'VIDEO',b'VID',30),entry(b'AUDIO',b'VAU',40),entry(b'PICTURE',b'QOI',50)]):d[second+32*k:second+32*(k+1)]=e
 start=(part+2+active*8)*512
 struct.pack_into('<I',d,start+2*4,0xf0000009 if not bad else (2 if bad==1 else 0x0ffffff7));struct.pack_into('<I',d,start+9*4,0x0fffffff)
 (D/'disk.hex').write_text(''.join(f'{x:02x}\n'for x in d))
 c=subprocess.run([os.environ.get('VVP','vvp'),str(D/'sim.vvp'),f'+BYTES={len(d)}',f'+SPC={spc}',f'+PART={part}',f'+ACTIVE={active}',f'+BAD={int(bool(bad))}'],cwd=D,capture_output=True,text=True,timeout=60)
 out=c.stdout+c.stderr;print(out,flush=True);assert c.returncode==0 and 'PASS fragmented root'in out,out
 results.append(dict(spc=spc,partition=part,active_fat=active,bad=bad,passed=True,output=out))
(R/'reports/directory.json').write_text(json.dumps(dict(passed=True,results=results,source_sha256={str(rtl):hashlib.sha256(rtl.read_bytes()).hexdigest()}),indent=2))
