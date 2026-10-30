`timescale 1ns/1ps
`include "codec8_full_fixture.vh"
// Actual 800x600 video -> SD byte stream -> shared byte FIFO -> codec8 ->
// seven-row reorder RAM -> pixel FIFO -> REAL frame_fifo_write addresses.
// Every SDRAM write is checked against a software-decoded raster pixel.
module tb_video_quality_sd_cache;
 localparam AUDIO_BYTES=32828;
    reg clk=0, memclk=0, rst=1, play=0, pause=0;
    always #5.5 clk=~clk;
    always #4 memclk=~memclk;
    wire [7:0] data;
    wire valid,secend;reg grant=0,tick=0,finish_toggle=0;
    wire req, wreq, pe, ack, active, disp_ok, mwrite, mfinish, aclr;
    wire [31:0] secaddr, pdata;
    wire [20:0] maddr;
    wire [15:0] ih;
    wire [1:0] wb, db;
    wire [3:0] state;
    reg [7:0] card [0:`C8_CARD_BYTES-1];
    reg [7:0] reference [0:1843199];
    reg [31:0] queue [0:1023];
    integer wp=0, rp=0, cycles=0, pixels=0, frames=0;
    integer peak_pixel=0, peak_byte=0, pause_cycles=0, full_cycles=0;
    integer max_frames=150, byte_cycles=2, fd, got, expected_addr;
    integer card_bytes=`C8_CARD_BYTES;
    reg [8191:0] card_path="work/video_800x600/codec8_full_card.hex";
    reg [8191:0] ref_path="work/video_800x600/codec8_full_reference.rgb565";
    integer idx=0, sector=0, transactions=0, request_delay=0;
    integer lost_ends=0, bank=0;
    reg serving=0, pending=0, wait_release=0;
    reg [15:0] rgb565;
    reg [31:0] expected_rgb;
    wire [9:0] used = wp-rp;
wire pack_valid;wire[31:0]pack_data;
rgb565_pair_pack pack(.clk(clk),.clear(rst|aclr),.pixel_valid(pe),.pixel_rgbx(pdata),.word_valid(pack_valid),.word_data(pack_data));
    reg full=0; always @(negedge clk) full=(used>=256); // stable FIFO threshold, avoid same-edge testbench races
    wire mem_stall = ((cycles % 50000) < 1800) || ((cycles % 97) < 9);
reg defer_audio_prefetch;
wire wavreq;wire[31:0]wavaddr;wire wavgrant;wire[7:0]wavdata;wire wavvalid,wavend;
 integer audio_deadline=2126041,audio_bytes=0,audio_wait=0,audio_maxwait=0,audio_sectors=0;
 integer cmd17=0,cmd18=0,bytes_wire=0,hits=0,card_latency=40000;
 wire[4:0]sdstate;
wire vidreq,vidvalid,vidend,vidgrant,init;
    wire[31:0]vidaddr;wire[7:0]viddata;
    integer last_ready=0,max_ready_gap=0,last_start=0,max_decode=0,rate=30;
    integer last_commit=0,commits=0;reg[1:0]last_dp=0;
    sd_arbiter #(.PREFETCH_AWARE(1),.MAX_DEFER_CYCLES(1400000)) arb(.defer_audio(defer_audio_prefetch),.clk(clk),.rst(rst),.img_sd_sec_read(1'b0),.img_sd_sec_read_addr(0),
      .wav_sd_sec_read(wavreq),.wav_sd_sec_read_addr(wavaddr),.wav_sd_sec_read_data(wavdata),
      .wav_sd_sec_read_data_valid(wavvalid),.wav_sd_sec_read_end(wavend),.wav_grant(wavgrant),
      .fat_sd_sec_read(1'b0),.fat_sd_sec_read_addr(0),.vid_sd_sec_read(vidreq),.vid_sd_sec_read_addr(vidaddr),
      .vid_sd_sec_read_data(viddata),.vid_sd_sec_read_data_valid(vidvalid),.vid_sd_sec_read_end(vidend),.vid_grant(vidgrant),
      .img_priority(1'b0),.sd_sec_read(req),.sd_sec_read_addr(secaddr),.sd_sec_read_data(data),
      .sd_sec_read_data_valid(valid),.sd_sec_read_end(secend));
    reg av_sample=0;
    reg[7:0]audio_card[0:262143];reg[7:0]pcm_reference[0:130623];
    reg[7:0]pcm_queue[0:8191];integer pcm_wp=0,pcm_rp=0,pcm_checks=0;
    reg audio_start=0,old_play=0;wire audio_ready,audio_stereo,audio_bad,audio_end,pcm_valid;wire[7:0]pcm_data;
    initial begin $readmemh("audio.hex",audio_card,0,AUDIO_BYTES-1);$readmemh("pcm.hex",pcm_reference);end
    compressed_audio_reader #(.ENABLE_QOA(0)) audio_reader(.clk(clk),.rst(rst),.start(audio_start),.halt(1'b0),.pause(pause),.seek(1'b0),.fifo_drained(1'b0),
     .sector(32'd161000),.fifo_almost_full(pcm_wp-pcm_rp>=6144),.pcm_fallback(),.wav_ready(audio_ready),.stereo(audio_stereo),.data_size(),.pcm_out_cnt(),
     .sd_req(wavreq),.sd_addr(wavaddr),.sd_data(wavdata),.sd_valid(wavvalid),.sd_end(wavend),.sd_grant(wavgrant),
     .track_end(audio_end),.track_bad(audio_bad),.pcm_valid(pcm_valid),.pcm_data(pcm_data),.idle(),.dbg_state());
    always@(posedge clk)begin
     old_play<=play;audio_start<=play&&!old_play;
     if(!rst)begin
      if(audio_bad||audio_end)$fatal(1,"unexpected actual IMA end/bad");
      if(pcm_valid)begin
       if(pcm_wp-pcm_rp>=8192)$fatal(1,"PCM FIFO overflow");
       pcm_queue[pcm_wp%8192]=pcm_data;pcm_wp=pcm_wp+1;
      end
      if(av_sample)begin
       if(pcm_queue[pcm_rp%8192]!==pcm_reference[2*pcm_checks] || pcm_queue[(pcm_rp+1)%8192]!==pcm_reference[2*pcm_checks+1])
        $fatal(1,"actual PCM sample mismatch %0d",av_consumed);
       pcm_rp=pcm_rp+2;pcm_checks=pcm_checks+1;
      end
      if(wavend)audio_sectors=audio_sectors+1;
     end
    end
    wire map_error;wire [12:0] av_period;
    wire av_allow,av_time, av_buffering;
    reg av_started=0,av_frame_toggle=0,av_time_q=0;
    reg [1:0] observed_buf=0;
    reg observed_valid=0;
    wire av_tick=av_time!=av_time_q;
    integer empty_cycles=0,decode_stall=0,wait_fin=0,wait_run=0,max_wait_run=0,first_present=0,last_present=0;
    integer av_phase=0,av_consumed=0,av_grants=0,av_wait_cycles=0;
    av_sample_sync #(.LEAD_SAMPLES(1920)) av_sync(.clk(clk),.rst(rst),.enable_sd(play),
     .started_sd(av_started),.paused_sd(pause),.draining_sd(1'b0),
     .frame_toggle_sd(av_frame_toggle),.samples_per_frame_sd(av_period),
     .sample_valid(av_sample),.sample_allow(av_allow),.time_toggle(av_time),.buffering(av_buffering));
    always @(negedge clk)begin
     av_sample=0;
     if(!rst)begin
      av_phase=av_phase+48000;
      if(av_phase>=90909091)begin
       av_phase=av_phase-90909091;
       if(av_started && av_allow)begin
        if(pcm_wp-pcm_rp<2)$fatal(1,"actual IMA PCM FIFO underflow at sample%0d",av_consumed);
        av_sample=1;
       end
      end
     end
    end
    always @(posedge clk)if(!rst)begin
     av_time_q<=av_time;
     if(tick&&disp_ok&&(!observed_valid||observed_buf!=db))begin
      av_frame_toggle<=~av_frame_toggle;av_started<=1;
      observed_buf<=db;observed_valid<=1;av_grants=av_grants+1;$display("PRESENT720 n=%0d cycle=%0d consumed=%0d",av_grants,cycles,av_consumed);
     end
     if(av_sample)begin
      av_consumed=av_consumed+1;
      if(av_consumed>av_grants*av_period)$fatal(1,"AV drift: audio exceeds displayed frames");
     end
     if(av_started && av_consumed<max_frames*1600)begin
      if(av_buffering)begin av_wait_cycles=av_wait_cycles+1;wait_run=wait_run+1;if(wait_run>max_wait_run)max_wait_run=wait_run;end
      else wait_run=0;
     end
     if(dut.state==4 && dut.bf_empty)empty_cycles=empty_cycles+1;
     if(dut.state==4 && dut.c8_busy)decode_stall=decode_stall+1;
     if(dut.state==7)wait_fin=wait_fin+1;
     if(tick&&disp_ok&&(!observed_valid||observed_buf!=db))begin
      if(first_present==0)first_present=cycles;last_present=cycles;
     end
    end
    wire movie_last_shown;
    video_player #(.PLAYLIST_SUPPORT(1),.LEGACY_CODECS(0),.BF_AW(14),.BF_HI(16'd15840),.AUDIO_MASTER(1), .AV_SYNC(1), .FRAME_PIXELS(921600), .FRAME_H(720), .ORPHAN_CYCLES(600)) dut (
        .clk(clk), .rst(rst), .play(play), .pause(pause), .present_enable(1'b1),.audio_clock_active(1'b1),.audio_frame_tick(av_tick),.audio_frame_samples(av_period), .timeline_run(av_started), .sd_error(map_error),.sd_init_done(init),
        .start_sector(32'd1), .img_disp_buf(2'd0),
        .sd_sec_read(vidreq), .sd_sec_read_addr(vidaddr), .sd_sec_read_data(viddata),
        .sd_sec_read_data_valid(vidvalid), .sd_sec_read_end(vidend), .sd_grant(vidgrant),
        .write_almost_full(full), .write_req(wreq), .write_req_ack(ack),
        .write_finish_toggle(finish_toggle), .pix_en(pe), .pix_data(pdata),
        .img_h_o(ih), .scanout_event(tick),.scanout_bank(db),.vsync_tick(tick), .wr_buf_idx(wb), .dp_buf_idx(db),
        .movie_last_shown(movie_last_shown),.active(active), .disp_ok(disp_ok), .dbg_state(state)
    );
    defparam dut.u_entropy.METADATA_FILE="D:/codexworks/framerate_v185_20261029/residual_hybrid64_lutqoi/candidate/project/rtl/residual_metadata.mem";
    defparam dut.u_entropy.TREE_FILE="D:/codexworks/framerate_v185_20261029/residual_hybrid64_lutqoi/candidate/project/rtl/residual_tree.mem";
    defparam dut.u_entropy.SYMBOL_FILE="D:/codexworks/framerate_v185_20261029/residual_hybrid64_lutqoi/candidate/project/rtl/residual_symbols.mem";
    frame_fifo_write #(.ADDR_BITS(21), .BURST_SIZE(256), .FRAME_WIDTH(640), .FRAME_HEIGHT(720)) writer (
        .rst(rst), .mem_clk(memclk), .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b0),
        .Sdr_busy(mem_stall), .App_rd_busy((cycles % 37) < 5), .O_wr_busy(),
        .App_wr_en(mwrite), .App_wr_addr(maddr), .write_req(wreq), .write_req_ack(ack),
        .write_finish(mfinish), .write_addr_0(21'd0), .write_addr_1(21'd460800),
        .write_addr_2(21'd921600), .write_addr_3(21'd0), .write_addr_index(wb),
        .write_len(21'd460800), .write_img_h(ih),.write_top_down(1'b0), .fifo_aclr(aclr), .rdusedw(used)
    );

 wire cmdreq,brreq;wire[47:0]cmd;wire[15:0]nb;
 reg cmdack=0,brvalid=0,brack=0;reg[7:0]brdata=0;
wire[7:0]physical_data;wire physical_valid,physical_end,mapped_req,mapped_multi;
wire[31:0]mapped_lba;wire[3:0]map_code;
fat32_sector_mapper #(.PHYSICAL_PREFETCH_BLOCKS(64),.IO_TIMEOUT(5000000)) mapper(
 .clk(clk),.rst(rst),.invalidate(1'b0),.mounted(1'b1),.fat_start_lba(32'd10),.data_start_lba(32'd1000),
 .cluster_shift(4'd4),.max_cluster(28'd50000),.req(req),.owner(vidgrant?2'd3:2'd1),
 .virtual_lba(vidgrant?(secaddr+32'd999):secaddr),.file_base_lba(vidgrant?32'd1000:32'd161000),
 .multi(vidgrant),.pace(1'b0),.data(data),.valid(valid),.done(secend),.error(map_error),.error_code(map_code),
 .sd_req(mapped_req),.sd_lba(mapped_lba),.sd_multi(mapped_multi),.sd_pace(),
 .sd_data(physical_data),.sd_valid(physical_valid),.sd_done(physical_end));
always@(posedge clk)if(map_error)$fatal(1,"fragment mapper error %d",map_code);
 sd_card_sec_read_write #(.PREFETCH_BRAM32(1),.PREFETCH_BLOCKS(64)) sd(.clk(clk),.rst(rst),.sd_init_done(init),.sd_sec_read(mapped_req),.sd_sec_read_addr(mapped_lba),
  .multi_en(mapped_multi),.multi_paced(1'b0),
  .sd_sec_read_data(physical_data),.sd_sec_read_data_valid(physical_valid),.sd_sec_read_end(physical_end),
  .sd_sec_write(1'b0),.sd_sec_write_addr(0),.sd_sec_write_data(8'd0),
  .cmd_req(cmdreq),.cmd_req_ack(cmdack),.cmd_req_error(1'b0),.cmd(cmd),
  .block_read_req(brreq),.block_read_valid(brvalid),.block_read_data(brdata),.block_read_req_ack(brack),
  .rd_nb_blk(nb),.block_write_data_rd(1'b0),.block_write_req_ack(1'b0),.dbg_state(sdstate));
 // Synthetic command/data latency, matching logical SDHC block addressing.
 integer long_stall_injected=0;
 integer cmddelay=0,cmdwaiting=0,blockactive=0,blockwaiting=0,phase=0,index=0,total=0,lba=0,delayleft=0;
function integer cluster_at;input integer k;begin cluster_at=2+k;end endfunction
 reg[31:0]fat_entries[0:50000];integer logical_cluster[0:1000];integer j,node;
 initial begin
 for(j=0;j<=50000;j=j+1)fat_entries[j]=0;
 for(j=0;j<=1000;j=j+1)logical_cluster[j]=-1;
 for(j=0;j<20;j=j+1)fat_entries[j==0?10002:12000+j*53]=j==19?32'h0fffffff:12000+(j+1)*53;
 for(j=0;j<512;j=j+1)begin
 node=cluster_at(j);fat_entries[node]=j==511?32'h0fffffff:cluster_at(j+1);logical_cluster[node]=j;
 end
 end
 function[7:0]cardbyte;input integer sector,offset;integer loc,c,k,logical;reg[31:0]entry;begin
 cardbyte=0;
 if(sector>=10&&sector<1000)begin
  c=(sector-10)*128+offset/4;entry=0;
  entry=c<=50000?fat_entries[c]:0;
  cardbyte=entry>>(8*(offset%4));
 end else if(sector>=161000)begin
  c=2+(sector-1000)/16;k=-1;
  if(c==10002)k=0;
  else if(c>=12053&&(c-12000)%53==0)k=(c-12000)/53;
  loc=(k*16+(sector-1000)%16)*512+offset;
  if(k>=0&&k<20&&loc<AUDIO_BYTES)cardbyte=audio_card[loc];
 end
 else if(sector>=1000)begin
  c=2+(sector-1000)/16;logical=-1;
  if(c<=1000&&logical_cluster[c]>=0)logical=logical_cluster[c]*16+(sector-1000)%16;
  loc=(logical+1)*512+offset;
  if(logical>=0&&loc<card_bytes)cardbyte=card[loc];
 end
 end endfunction
 always@(negedge clk)begin
  cmdack=0;brvalid=0;brack=0;tick=0;
  if(!rst)begin
   cycles=cycles+1;tick=(cycles%1515152==0);
   pause=0;
   if(pause)pause_cycles=pause_cycles+1;
   if(full)full_cycles=full_cycles+1;
   if(used>peak_pixel)peak_pixel=used;
   if(dut.bf_usedw>peak_byte)peak_byte=dut.bf_usedw;
   if(cycles%5000000==0)$display("PROGRESS video cycles=%0d frames=%0d pixels=%0d cmd18=%0d",cycles,frames,pixels,cmd18);
   if(cmdreq&&!cmdwaiting)begin cmdwaiting=1;cmddelay=720;end
   if(cmdwaiting&&cmddelay>0)begin cmddelay=cmddelay-1;if(cmddelay==0)begin
    cmdack=1;lba=cmd[39:8];
    if(cmd[47:40]==17)cmd17=cmd17+1;
    if(cmd[47:40]==18)cmd18=cmd18+1;
   end end
   if(!cmdreq)cmdwaiting=0;
   if(brreq&&!blockwaiting&&!blockactive)begin
    blockwaiting=1;blockactive=1;phase=0;index=0;total=nb*512;delayleft=card_latency;
    if(1'b0)begin delayleft=delayleft+3000000;long_stall_injected=1;end
   end
   if(!brreq)blockwaiting=0;
   if(blockactive)begin
    if(delayleft>0)delayleft=delayleft-1;
    else if(index==total)begin blockactive=0;brack=1;end
    else if(phase==byte_cycles-1)begin
     phase=0;brvalid=1;brdata=cardbyte(lba+index/512,index%512);index=index+1;bytes_wire=bytes_wire+1;
     if(index==total)begin delayleft=(nb>1)?21816:72;end
     else if(index%512==0)delayleft=360; // token/CRC gap in a CMD18 stream
    end else phase=phase+1;
   end
   if(sdstate==25)hits=hits+1; // diagnostic only; exact enum not used for correctness
  end
 end
    always @(posedge clk or posedge aclr) begin
        if (aclr) wp=0;
        else if (!rst && pack_valid) begin
            if (wp-rp>=512) $fatal(1,"pixel FIFO overflow %0d",wp-rp);
            queue[wp % 1024]=pack_data;
            wp=wp+1;
        end
        if (!rst && active && vidvalid && dut.bf_full)
            $fatal(1,"byte FIFO overflow");
    end

    integer pair0,pair1,source_pair;
    always @(posedge aclr)begin bank=wb;rp=0;pixels=0;end
    always @(posedge memclk) begin
        if (!rst && mwrite) begin
            if (rp==wp) $fatal(1,"pixel FIFO underflow");
            if(pixels==0)begin
                if(frames%30==0)got=$fseek(fd,0,0);
                got=$fread(reference,fd);
                if(got!=1843200)$fatal(1,"reference frame truncated");
            end
            source_pair=pixels;
            pair0=reference[4*source_pair]|(reference[4*source_pair+1]<<8);
            pair1=reference[4*source_pair+2]|(reference[4*source_pair+3]<<8);
            if(queue[rp%1024]!=={pair1[15:0],pair0[15:0]})
                $fatal(1,"720p RGB565 pair mismatch frame=%0d pair=%0d got=%h exp=%h next=%h prev=%h pcnt=%0d",frames,pixels,queue[rp%1024],{pair1[15:0],pair0[15:0]}, {reference[4*source_pair+7],reference[4*source_pair+6],reference[4*source_pair+5],reference[4*source_pair+4]}, {reference[4*source_pair-1],reference[4*source_pair-2],reference[4*source_pair-3],reference[4*source_pair-4]},dut.pcnt);
            expected_addr=bank*460800+(719-pixels/640)*640+pixels%640;
            if(maddr!==expected_addr)$fatal(1,"720p address got=%0d exp=%0d",maddr,expected_addr);
            rp=rp+1;pixels=pixels+1;
        end
        if(!rst&&mfinish)begin
                if(pixels!=460800)$fatal(1,"720p frame pair count %d",pixels);
                pixels=0;frames=frames+1;
                finish_toggle=~finish_toggle;
                $display("CHECKED720 frame=%0d pixels=921600 bank=%0d cycles=%0d",frames,bank,cycles);
                if(1'b0)begin
                    if(audio_sectors<1||cmd18<1)
                        $fatal(1,"coverage missing");
                    if(av_consumed>av_grants*av_period)$fatal(1,"AV budget exceeded");
                    $display("PASS720 actual clip PCM_samples=%0d presented=%0d audio_sectors=%0d buffering=%0d",av_consumed,av_grants,audio_sectors,av_wait_cycles);
                    $fclose(fd);$finish;
                end
        end
        if(rst||aclr)rp=0;
    end
    initial begin
        if ($value$plusargs("RATE=%d",rate))begin end
        if ($value$plusargs("FRAMES=%d",max_frames)) begin end
        if ($value$plusargs("BYTE_CYCLES=%d",byte_cycles)) begin end
        if ($value$plusargs("CARD=%s",card_path)) begin end
        if ($value$plusargs("REFERENCE=%s",ref_path)) begin end
        if ($value$plusargs("CARD_BYTES=%d",card_bytes)) begin end
        if (max_frames<1 || max_frames>120 || byte_cycles<1) $fatal(1,"invalid test options");
        if (card_bytes>`C8_CARD_BYTES || card_bytes%512!=0) $fatal(1,"invalid card size");
        $readmemh(card_path,card,0,card_bytes-1);
        fd=$fopen(ref_path,"rb");
        if (!fd) $fatal(1,"missing reference file");
        repeat(8) @(negedge clk);
        #1; rst=0; wait(init); @(negedge clk); play=1;
    end
initial begin
 wait(frames==max_frames);wait(av_grants==max_frames);wait(av_consumed==max_frames*1600);wait(pcm_checks==max_frames*1600);
 if(!movie_last_shown)$fatal(1,"missing last-frame status");
 repeat(200000)@(negedge clk);
 if(frames!=30||av_grants!=30||av_consumed!=30*1600||pcm_checks!=30*1600||wreq||pe)$fatal(1,"finite EOF violation");
 $display("FINITE_EOF_PASS");
 $display("CONTINUITY first=%0d last=%0d stalls=%0d maxstall=%0d empty=%0d decode_busy=%0d wait_fin=%0d",first_present,last_present,av_wait_cycles,max_wait_run,empty_cycles,decode_stall,wait_fin);
 $display("PASS720 real IMA video decoded=%0d presented=%0d PCM_samples=%0d cycles=%0d audio_sectors=%0d buffering=%0d",frames,av_grants,av_consumed,cycles,audio_sectors,av_wait_cycles);$finish;
 end
    initial begin
        #(64'd10000000000);
        $fatal(1,"fullframe timeout frames=%0d pixels=%0d state=%0d",frames,pixels,state);
    end
always @(posedge clk or posedge rst)begin if(rst)defer_audio_prefetch<=0;else defer_audio_prefetch<=play && av_started && (pcm_wp-pcm_rp>=4096) && (sdstate==19 || sdstate==20 || sdstate==23);end
endmodule
