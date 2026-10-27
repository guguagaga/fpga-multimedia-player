"""Exercise actual packed frame controllers with simultaneous scanout/write."""
from pathlib import Path
import os,subprocess,time,json,hashlib
R=Path(__file__).resolve().parents[1];P=R/'candidate/project';H=P/'user_source/hdl_source'
D=R/'tests'/('concurrent_'+str(int(time.time())));D.mkdir()
s=(R/'tests/tb_packed_frame.v').read_text()
s=s.replace('tb_packed_frame','tb_concurrent_frame').replace('reg[1:0] bank=0;','reg[1:0] bank=0,rbank=0;')
s=s.replace('.read_addr_index(bank)', '.read_addr_index(rbank)')
s=s.replace('color(2*wr+1),color(2*wr)', 'color(2*wr+1+bank*921600),color(2*wr+bank*921600)')
s=s.replace('expected=rgbx(color(i));', 'expected=rgbx(color(i+rbank*921600));')
begin=s.index(' integer p,x,y,b;');end=s.index(' initial begin #500000000',begin)
s=s[:begin]+''' integer p,x,y,b,j,initial_bank;
 initial begin
  // Distinct initialized banks let scanout check its own bank while a new
  // frame is written to another bank through the real asynchronous FIFO.
  for(initial_bank=0;initial_bank<3;initial_bank=initial_bank+1)
   for(j=0;j<460800;j=j+1)
    memory[initial_bank*460800+(719-j/640)*640+j%640]=
     {color(2*j+1+initial_bank*921600),color(2*j+initial_bank*921600)};
  repeat(20)@(negedge clk);rst=0;
  for(b=0;b<3;b=b+1)begin
   bank=(b+1)%3;rbank=b;wr=0;reads=0;checked=0;
   fork
    begin
     @(negedge clk);wreq=1;wait(wack);@(negedge clk);wreq=0;
     repeat(30)@(negedge clk);
     for(p=0;p<921600;p=p+1)begin
      while(high)begin we=0;@(negedge clk);end
      we=1;wd=rgbx(color(p+bank*921600));@(negedge clk);
      if(p%131==0)begin we=0;repeat(3)@(negedge clk);end
     end
     we=0;wait(wfinish);
     if(wr!=460800)$fatal(1,"concurrent write count");
    end
    begin
     @(negedge readclk);rreq=1;wait(rack);@(negedge readclk);rreq=0;
     repeat(800)@(negedge readclk);
     for(y=0;y<720;y=y+1)begin
      for(x=0;x<1280;x=x+1)begin re=1;@(negedge readclk);end
      re=0;repeat(370)@(negedge readclk);
     end
     repeat(30)@(negedge readclk);
     if(checked!=921600||reads!=460800)$fatal(1,"concurrent read count");
    end
   join
   $display("CHECKED concurrent720 read_bank=%d write_bank=%d pixels=%d",rbank,bank,checked);
  end
  $display("PASS concurrent720 three complete frames, packed FIFO, read/write priority and stalls");$finish;
 end
'''+s[end:]
(D/'tb.v').write_text(s)
files=[D/'tb.v',P/'rtl/rgb565_pair_pack.v']+[H/n for n in ['SD/frame_read_write.v','SD/frame_fifo_write.v','SD/frame_fifo_read.v','ip/afifo_16_32_256.v','ip/afifo_32_16_256.v']]
snapshot={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}
script='onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+f.resolve().as_posix()+'}'for f in files)+'\nvsim work.tb_concurrent_frame\nrun -all\nquit -code 0\n'
(D/'run.do').write_text(script);t=time.time()
with(D/'console.log').open('w')as log:p=subprocess.run([str(Path(os.environ['MODELSIM_BIN'])/'vsim.exe'),'-c','-do','run.do'],cwd=D,stdout=log,stderr=subprocess.STDOUT)
out=(D/'console.log').read_text(errors='replace');ok=p.returncode==0 and 'PASS concurrent720'in out and not any(x in out for x in ['** Error','** Fatal','FATAL:'])
assert snapshot=={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}
(R/'reports/concurrent_memory.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,source_sha256=snapshot,scope='Actual vendor asynchronous FIFOs/frame read/write controllers. Concurrent 37.125MHz raster scanout and 100MHz backpressured pixel producer, three banks with distinct patterns, memory backend latency/stalls. Behavioral backend, not physical SDRAM model.',summary=out[-6000:]),indent=2))
print(out[-6000:]);assert ok
