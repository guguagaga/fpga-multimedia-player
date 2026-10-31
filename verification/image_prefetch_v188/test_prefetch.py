from pathlib import Path
import subprocess,os,json,hashlib,concurrent.futures,re,time
R=Path(__file__).resolve().parent;P=R/'candidate/project'
S=Path('D:/codexworks/osd_carousel_v187/rebuild_r3/tests/integration_ase/kind1_320x240')
T=R/'tests';T.mkdir(exist_ok=True)
base=(S/'tb.v').read_text()
base=base.replace('module tb;','module tb;\nparameter EARLY=0;\ninteger n=0,txns=0;').replace(',txns=0,n=0,',',')
base=base.replace('reg ack=0;','reg reseed=0;wire audio_ready; reg ack=0;')
base=base.replace('sd_card_bmp #(.CLK_FREQ_HZ(90909091))','sd_card_bmp #(.CLK_FREQ_HZ(2000000),.EARLY_PREFETCH_EN(EARLY))')
base=base.replace(".directory_count(3'd1),.directory0(32'd100),.directory1(32'd0),.directory2(32'd0)",".directory_count(3'd3),.directory0(32'd100),.directory1(32'd10000),.directory2(32'd20000)")
base=base.replace(".auto_period_sec(10'd600),.period_reseed(1'b0)",".auto_period_sec(10'd2),.period_reseed(reseed),.prefetch_audio_ready(audio_ready)")
base=base.replace('.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),\n .sd_sec_read_end(ended),.sd_grant(grant)', '.sd_sec_read_data(image_data),.sd_sec_read_data_valid(image_valid),\n .sd_sec_read_end(image_end),.sd_grant(image_grant)')
pos=base.index('sd_card_bmp #')
extra='''
wire[7:0]image_data,audio_data;wire image_valid,image_end,image_grant;
wire audio_valid,audio_end,audio_grant,card_req;wire[31:0]card_addr;
reg audio_req=0;integer fifo=6144,min_fifo=8192,audio_tick=0,audio_sectors=0,audio_wait=0,max_audio_wait=0;
reg audio_go=0;reg permission=0;assign audio_ready=permission;
reg img_priority=1;
always @(posedge clk)begin
 if(rst)begin permission<=0;img_priority<=1;end
 else begin permission<=fifo>=6144;img_priority<=!shown || (loading && fifo>=8192);end
end
sd_arbiter #(.PREFETCH_AWARE(1),.MAX_DEFER_CYCLES(1400000)) arb(
 .clk(clk),.rst(rst),.defer_audio(1'b0),.img_priority(img_priority),
 .img_sd_sec_read(req),.img_sd_sec_read_addr(addr),.img_sd_sec_read_data(image_data),.img_sd_sec_read_data_valid(image_valid),.img_sd_sec_read_end(image_end),.img_grant(image_grant),
 .wav_sd_sec_read(audio_req),.wav_sd_sec_read_addr(32'd999999),.wav_sd_sec_read_data(audio_data),.wav_sd_sec_read_data_valid(audio_valid),.wav_sd_sec_read_end(audio_end),.wav_grant(audio_grant),
 .fat_sd_sec_read(1'b0),.fat_sd_sec_read_addr(32'd0),.vid_sd_sec_read(1'b0),.vid_sd_sec_read_addr(32'd0),
 .sd_sec_read(card_req),.sd_sec_read_addr(card_addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended));
always @(posedge clk)if(!rst)begin
 if(audio_valid)fifo=fifo+1;
 if(audio_go)begin
  audio_tick=audio_tick+1;
  if(audio_tick==470)begin
   audio_tick=0;if(fifo<=0)$fatal(1,"audio underflow");fifo=fifo-1;
  end
  if(fifo<min_fifo)min_fifo=fifo;
 end
 if(fifo>8192)$fatal(1,"audio overflow");
 if(audio_end)begin audio_req=0;audio_sectors=audio_sectors+1;end
 else if(audio_go && fifo<6144)audio_req=1;
 if(audio_req&&!audio_grant)begin audio_wait=audio_wait+1;if(audio_wait>max_audio_wait)max_audio_wait=audio_wait;end
 else audio_wait=0;
end
wire fade_req;reg fadeprev=0,fade_done=0,transition=0;
integer fade_ticks=0;
always @(negedge clk)if(!rst)begin
 fade_done=0;
 if(fade_req!=fadeprev)begin fadeprev=fade_req;fade_ticks=100;transition=1;end
 if(fade_ticks>0)begin fade_ticks=fade_ticks-1;if(fade_ticks==50)fade_done=1;if(fade_ticks==0)transition=0;end
end
integer frames=0,shown_count=0,last_idx=-1,boot_cycle=0,auto_start=0,load_start_cycle=0,first_data_cycle=0;
integer load_count=0,flip1=0,flip2=0,old_pf=0;
reg[1:0]old_load_idx=0;reg previous_wreq=0;
initial begin
 wait(shown&&!loading);@(negedge clk);auto_go_setup;
end
task auto_go_setup;begin audio_go=1;reseed=1;auto_start=cycle;@(negedge clk);reseed=0;end endtask
always @(negedge clk)if(!rst)begin
 if(wreq&&!previous_wreq)begin
  if(n!=0 && n!=921600)$fatal(1,"partial frame replaced n=%d",n);
  n=0;load_start_cycle=cycle;first_data_cycle=0;load_count=load_count+1;
  $display("EVENT LOAD id=%0d cycle=%0d pf=%0d",dut.load_idx,cycle,dut.pf_state);
 end
 previous_wreq=wreq;
 if(image_valid&&first_data_cycle==0)first_data_cycle=cycle;
 if(dut.pf_state==2 && old_pf!=2)$display("EVENT READY id=%0d cycle=%0d",dut.pf_idx,cycle);
 old_pf=dut.pf_state;
 if(shown&&dut.img_idx!=last_idx)begin
  if(frames<shown_count+1)$fatal(1,"display before complete write");
  last_idx=dut.img_idx;shown_count=shown_count+1;
  $display("EVENT DISPLAY id=%0d cycle=%0d since_auto=%0d",last_idx,cycle,cycle-auto_start);
  if(shown_count==1)boot_cycle=cycle;
  if(shown_count==2)flip1=cycle-auto_start;
  if(shown_count==3)begin
   flip2=cycle-auto_start;
   if(load_count!=3 || frames!=3)$fatal(1,"duplicate or incomplete loads");
   $display("PASS EARLY=%0d flip1=%0d flip2=%0d min_fifo=%0d max_audio_wait=%0d frames=%0d sectors=%0d",EARLY,flip1,flip2,min_fifo,max_audio_wait,frames,txns);$finish;
  end
 end
end
'''
base=base[:pos]+extra+base[pos:]
base=base.replace(".switch_lock(1'b0)",'.switch_lock(transition)').replace(".fade_done_pulse(1'b0)",'.fade_done_pulse(fade_done),.fade_req_toggle(fade_req)')
base=base.replace('if(req)begin','if(card_req)begin').replace('off=(addr-100)*512;','off=(card_addr-(card_addr>=20000?20000:card_addr>=10000?10000:100))*512;')
base=base.replace('repeat(10)@(negedge clk);','repeat((txns%23==0)?20000:500)@(negedge clk);')
base=base.replace('data=value(off+b);','data=audio_grant ? 8\'h55 : value(off+b);')
base=base.replace('repeat(20)@(negedge clk);','wait(!card_req);repeat(20)@(negedge clk);')
base=base.replace('if(n==921600)delay_finish=30;','if(n==921600)begin delay_finish=30;frames=frames+1;$display("EVENT WRITTEN id=%0d cycle=%0d load_cycles=%0d",dut.load_idx,cycle,cycle-load_start_cycle);end')
a=base.index(' if(shown)begin\n');b=base.index(' if(cycle>45000000)',a)
base=base[:a]+base[b:];base=base.replace('cycle>45000000','cycle>60000000')
def run(early):
 O=T/f'full_chain_v3_early{early}';O.mkdir(exist_ok=True)
 observed=base.replace(' if(cycle>60000000)', ''' if(cycle%1000000==0)$display("PROGRESS cycle=%0d n=%0d state=%0d req=%b card_req=%b arb=%0d audio_req=%b fifo=%0d qoi=%0d fit=%0d ack=%b wreq=%b",cycle,n,st,req,card_req,arb.sel,audio_req,fifo,dut.bmp_read_m0.u_qoi.state,dut.u_image_fit.state,ack,wreq);
 if(loading&&cycle-load_start_cycle>6000000)$fatal(1,"load watchdog n=%0d state=%0d qoi=%0d fit=%0d qpos=%0d qhave=%b qpending=%b qvalid=%b sectors=%0d addr=%0d",n,st,dut.bmp_read_m0.u_qoi.state,dut.u_image_fit.state,dut.bmp_read_m0.q_pos,dut.bmp_read_m0.q_have,dut.bmp_read_m0.q_pending,dut.bmp_read_m0.q_valid,txns,addr);
 if(cycle>60000000)''')
 (O/'tb.v').write_text(observed);(O/'header.hex').write_bytes((S/'header.hex').read_bytes())
 script=(S/'run.do').read_text().replace('D:/codexworks/osd_carousel_v187/rebuild_r3/candidate/project',P.as_posix()).replace(S.as_posix(),O.as_posix())
 script=script.replace('vsim work.tb work.glbl','vlog {'+(P/'user_source/hdl_source/sd_arbiter.v').as_posix()+'}\nvsim -gEARLY='+str(early)+' work.tb work.glbl')
 (O/'run.do').write_text(script)
 start=time.time()
 with(O/'console.log').open('w')as log:p=subprocess.run(['E:/modelsim/modelsim_ase/win32aloem/vsim.exe','-c','-do','run.do'],cwd=O,env=dict(os.environ,TEMP=str(R/'tmp'),TMP=str(R/'tmp')),stdout=log,stderr=subprocess.STDOUT,timeout=1800)
 log=(O/'console.log').read_text(errors='replace');ok=p.returncode==0 and 'PASS EARLY='in log and '** Error'not in log and '** Fatal'not in log
 result={'early':early,'passed':ok,'seconds':time.time()-start,'events':[x for x in log.splitlines()if 'EVENT 'in x or 'PASS EARLY'in x]}
 (O/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
 if not ok:print(log[-2500:],flush=True)
 return result
with concurrent.futures.ThreadPoolExecutor(max_workers=2)as pool:results=list(pool.map(run,[0,1]))
(T/'comparison.json').write_text(json.dumps({'passed':all(x['passed']for x in results),'cases':results,'scope':'Actual image loader/QOI/scaler and real sd_arbiter, full720P pixels, modeled audio byte sink and variable logical-sector service. Accelerated2M clocks/second carousel timer; not hardware SD/SPI throughput or full audio decoder proof.'},indent=2))
assert all(x['passed']for x in results)
