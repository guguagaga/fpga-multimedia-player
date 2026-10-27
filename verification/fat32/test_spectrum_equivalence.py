from pathlib import Path
import os,subprocess,json,hashlib,time
R=Path(__file__).resolve().parent;D=R/'tests/spectrum_equivalence';D.mkdir(parents=True,exist_ok=True)
old=R/'tests/spectrum_reference_source.v'
new=R/'candidate/project/user_source/hdl_source/spectrum_capture.v'
(D/'reference.v').write_text(old.read_text().replace('module spectrum_capture #','module spectrum_reference #'))
tb=r'''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,v=0;reg[15:0]re=0,im=0;reg[5:0]a=0,b=0;
wire[7:0]x,y,u,w;wire beat0,beat1;
spectrum_reference ref0(.clk(clk),.rst_n(rst_n),.fft_valid(v),.fft_re(re),.fft_im(im),.rd_addr(0),.rd_addr2(a),.rd_addr3(b),.rd_addr4(0),.rd_data2(x),.rd_data3(y),.beat_pulse(beat0));
spectrum_capture dut(.clk(clk),.rst_n(rst_n),.fft_valid(v),.fft_re(re),.fft_im(im),.rd_addr(0),.rd_addr2(a),.rd_addr3(b),.rd_addr4(0),.rd_data2(u),.rd_data3(w),.beat_pulse(beat1));
reg prior_write=0;reg[7:0]prior_value;reg[4:0]prior_index;integer commits=0,reads=0,cycles=0,quiet=0,seed=83481;
always@(posedge clk)begin
 if(rst_n)begin
  if(dut.display_write!==prior_write)$fatal(1,"commit valid cycle=%d",cycles);
  if(prior_write)begin
   if(dut.index_d!==prior_index||dut.update_decay!==prior_value)$fatal(1,"bar decay idx=%d got=%d exp=%d cycle=%d",prior_index,dut.update_decay,prior_value,cycles);
   commits=commits+1;
  end
  prior_write=ref0.display_write;prior_value=ref0.update_decay;prior_index=ref0.cnt[4:0];
 end else prior_write=0;
 #1;
 if(rst_n)begin
  if(beat0!==beat1)$fatal(1,"beat changed");
  if(ref0.display_write||dut.display_write)quiet=0;else quiet=quiet+1;
  if(quiet>4)begin
   if(x!==u||y!==w)$fatal(1,"display values changed read=%d %d -> %d %d",x,y,u,w);
   reads=reads+2;
  end
 end else quiet=0;
end
integer i;
initial begin
 repeat(5)@(negedge clk);rst_n=1;
 for(i=0;i<400000;i=i+1)begin
  @(negedge clk);cycles=cycles+1;a=$random(seed)&63;b=$random(seed)&63;
  // Continuous bins, sparse bins, silence, low-energy and full-scale inputs.
  v=(i%14000<8000)||(($random(seed)&7)==0);
  case((i/5000)%5)
   0:begin re=$random(seed);im=$random(seed);end
   1:begin re=$random(seed)&31;im=$random(seed)&15;end
   2:begin re=0;im=0;end
   3:begin re=16'h8000;im=16'h7fff;end
   4:begin re=$random(seed)&1023;im=-re;end
  endcase
  if(i%57000==56900)rst_n=0;
  if(i%57000==56905)rst_n=1;
 end
 if(commits<10000||reads<100000)$fatal(1,"missing coverage");
 $display("PASS spectrum BRAM equivalence commits=%d read_checks=%d cycles=%d",commits,reads,cycles);$finish;
end
endmodule
'''
(D/'tb.v').write_text(tb);files=[D/'tb.v',D/'reference.v',new];t=time.time()
c=subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb','-o',str(D/'sim.vvp'),*[str(f)for f in files]],capture_output=True,text=True);assert c.returncode==0,c.stderr
c=subprocess.run([os.environ.get('VVP','vvp'),str(D/'sim.vvp')],capture_output=True,text=True,timeout=120);out=c.stdout+c.stderr;print(out,flush=True)
ok=c.returncode==0 and 'PASS spectrum BRAM equivalence'in out
(R/'reports/spectrum_equivalence.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,output=out,source_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}),indent=2));assert ok
