`timescale 1ns/1ps
module tb;
reg sd_card_clk=0,audio_mclk=0;always #5.5 sd_card_clk=~sd_card_clk;always #40.69 audio_mclk=~audio_mclk;
reg rst_all=1;wire audio_rst=rst_all;
reg video_play=0,vau_tgt,video_paused=0,av_started=0;
wire[31:0]vau_sector;reg[31:0]song5_sector=20000,track_sel_sector=100;
reg[5:0]song_count=6;reg track_sel_valid=0,display_valid=1,pause=0;
wire wav_ready,wav_track_bad;reg[27:0]av_wait;reg av_audio_failed;
wire video_audio_ready;wire fs_error=0;wire[1:0]fs_error_owner=0;wire[3:0]fs_error_code=0;
function[6:0]hex7;input[3:0]d;begin hex7={3'd0,d};end endfunction
wire btn_ff_tick=0;
wire audio_transition_busy;
reg next_req=0,prev_req=0,movie_ended=0;
wire video_engine_play,video_audio_select,switching,auto_enabled,selection_failed;
wire[1:0]video_index;assign vau_sector=10000+video_index*10000;
video_playlist_ctrl playlist(.clk(sd_card_clk),.rst(rst_all),.mode_video(video_play),.list_ready(1'b1),
 .next_req(next_req),.prev_req(prev_req),.auto_toggle(1'b0),.ended(movie_ended),.io_idle(1'b1),
 .audio_ready(wav_ready),.audio_busy(audio_transition_busy),.available(4'b1011),.index(video_index),
 .engine_play(video_engine_play),.audio_select(video_audio_select),.switching(switching),
 .auto_enabled(auto_enabled),.selection_failed(selection_failed));
always@(negedge sd_card_clk)if(switching)video_paused=0;

wire fifo_empty,fifo_full,fifo_almost_full,fifo_rd_en;
wire[7:0]fifo_rd_data;wire[13:0]fifo_used;
wire wav_sample_req,wav_sample_valid;wire[23:0]wav_sample_left,wav_sample_right;
wire av_audio_allow,av_audio_time_toggle,av_buffering;
reg av_display_toggle=0;wire[12:0]av_frame_samples=3200;
wire[4:0]volume_s1=31;wire[23:0]vol_sample_left,vol_sample_right;
wire audio_i2s_bclk,audio_i2s_lrck,audio_i2s_dout;
wire[15:0]channels;reg[1:0]stereo_sync=0;wire stereo=stereo_sync[1];
always@(posedge audio_mclk)stereo_sync<={stereo_sync[0],channels==2};

  reg         sel_pending;
  reg  [27:0] sel_wait_cnt;
  wire        sel_timeout = sel_wait_cnt[27];  // 2^27 SD/control cycles:about1.48s at90.909091MHz
  // Video entry selects the companion VAU; exit selects the current playlist track.
  // Selection retries until wav_ready acknowledges the change.
  // A/V synchronization uses consumed PCM samples and presented-frame credit in
  // av_sample_sync. A shared reference oscillator alone does not guarantee sync.
  // vau_tgt is declared before track_ctrl because it also gates track-end events.
  reg         vau_sent;  // 已经发过至少一次选择脉冲
  reg         vau_ack;  // 播放器已接受（看到过 wav_ready 掉低）
  reg  [19:0] vau_gap;  // 重试间隔计数
  reg         vau_fire;  // 1 拍选择脉冲
  localparam VAU_ON = 1'b1;  // Enable companion audio selection for video playback.
  // Acknowledged video soundtrack faults must not silently restart at byte 0.
  // Only an explicit video mode change reselects a track.
  reg [3:0] vau_fault_code;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) vau_fault_code <= 0;
    else if (!video_play) vau_fault_code <= 0;
    else if (fs_error && fs_error_owner == 1) vau_fault_code <= fs_error_code;
    else if (wav_track_bad && vau_fault_code == 0) vau_fault_code <= 4'hf;
  end
  reg [6:0] vau_fault_seg;
  always @(posedge sd_card_clk) vau_fault_seg <= hex7(vau_fault_code);
  // The current card's V1_AMIYA.VAU contains the DEFT video audio (the file
  // payload matches deft_vau_18fps.wav).  It must win whenever the directory
  // scanner found it; V9_AMIYA.WAV is only a compatibility fallback for cards
  // that have no .VAU entry at all.
  reg vau_sector_nz;
  // Prefer the dedicated video soundtrack; WAV is a fallback.
  wire [31:0] vau_sel_sector = (vau_sector != 32'd0) ? vau_sector : song5_sector;
  // [Design note 时序]vau_src_ok 原来是【组合】的：
  //     vau_tgt ? (vau_sel_sector != 0) : (song_count != 0)
  //   而 vau_sel_sector 本身又是一个 32 位 mux（vau_sector / song5_sector）。
  //   这条锥直接串进 vau_gap 计数器的使能，实测是 sd_card_clk 域的第 3 名
  //   最差路径（slack 0.151ns，起于 fat32_list/song_sector_reg）。
  //   但 vau_src_ok 只由「进出视频」驱动，是慢变信号 ⇒ 打一拍完全无害，
  //   而它每帧只用一次。
  reg vau_src_ok_r;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) vau_src_ok_r <= 1'b0;
    else
      vau_src_ok_r <= vau_tgt ? ((song5_sector != 32'd0) || (vau_sector != 32'd0)) : (song_count != 6'd0);
  end
  wire vau_src_ok = vau_src_ok_r;
  //   [Design note]当前卡的 .VAU 扫描结果为 1355072，内容是 DEFT 配音；
  //   只有 vau_sector==0 时才退回歌单备用扇区，避免把 AMIYA 歌曲误当成视频音轨。
  // [Design note 时序]把 "vau_sector != 0" 提前寄存成一位标志：
  //   深锥源头是 32 位比较，而它的消费者只是数码管上的一位状态码。
  //   打一拍不影响任何功能（数字管刷新 200Hz，晚一个 sd_card_clk 完全无感）。
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) vau_sector_nz <= 1'b0;
    else vau_sector_nz <= (vau_sector != 32'd0);
  end

  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      vau_tgt  <= 1'b0;
      vau_sent <= 1'b0;
      vau_ack  <= 1'b1;  // 上电时歌单自己会起，不需要我们动
      vau_gap  <= 20'd0;
      vau_fire <= 1'b0;
    end else begin
      vau_fire <= 1'b0;
      if (VAU_ON && ((!video_play && vau_tgt != video_play) || video_audio_select)) begin
        // 模式刚变 -> 立刻请求，等确认
        vau_tgt  <= video_play;
        vau_sent <= 1'b0;
        vau_ack  <= 1'b0;
        vau_gap  <= 20'd0;
      end else if (!vau_ack) begin
        if (!vau_src_ok) begin
          // 没有目标文件（例如卡上没 .VAU）：放弃请求，保持原样
          vau_ack <= 1'b1;
        end else if (vau_gap == 20'd0) begin
          vau_fire <= 1'b1;
          vau_sent <= 1'b1;
          vau_gap  <= 20'd818182;  // 约9ms，按SD_CORE_HZ换算
        end else begin
          vau_gap <= vau_gap - 20'd1;
        end
        // 只认"发出去之后"的 wav_ready 掉低，避免上电时 wav_ready=0 的假确认
        if (vau_sent && !vau_fire && !wav_ready) vau_ack <= 1'b1;
      end
    end
  end

  // 视频播放期间封锁歌单自己的切歌脉冲（track_sel_valid）。
  //   不加这个闸门的话：自动续播在 track_end 时、或用户长按 KEY4 时，
  //   歌单会把音频抢回自己的下一首 —— 视频还在放，声音却换成别的歌，
  //   看着就像"配音轨功能坏了"。视频期间只允许 vau_fire 动音轨。
  wire       wav_track_sel = vau_fire ? 1'b1
                         : (video_play ? 1'b0
                                       : (display_valid ? (track_sel_valid | sel_pending)
                                                        : (sel_timeout & sel_pending)));
  // ============================================================================
  // [Design note 二分实验 EE1]切轨目标强制用歌单当前曲，暂时不切 .VAU。
  //
  //   目的：把"视频期间切轨"和"这个 .VAU 文件"两件事分开。
  //   · 进视频仍然会触发一次完整的切轨事件（同样的 wav_track_sel、同样的排空/重新解析），
  //     唯一不同的是目标扇区：用歌单当前曲（已知能正常播）而不是 vau_sector。
  //   · 若这样声音正常 ⇒ 切换机制与视频并发都没问题 ⇒ 问题锁定在 vau_sector / .VAU；
  //   · 若仍是噪声      ⇒ 任何"视频期间切轨"都会坏 ⇒ 问题在切轨/并发通路。
  //   验证完把下面 VAS_SECTOR_TEST 改回 1'b0 就恢复原行为（切 .VAU）。
  // ============================================================================
  localparam       VAS_SECTOR_TEST = 1'b0;   // 【已复原】0 = 正常切 VAU；1 = 二分实验用（切当前歌）
  // ============================================================================
  // [Design note 致命一拍错位修复]扇区必须锁存，不能跟着 1 拍脉冲一起消失。
  //
  //   bug 原来是组合式：
  //       wire wav_track_sector = vau_fire ? vau_sel_sector : track_sel_sector;
  //   而 wav_player 是这么取扇区的（wav_player.v:399）：
  //       track_sel_q <= track_sel;                       // 打一拍
  //       if (track_sel_q) pending_sector <= track_sel_sector;
  //   于是：
  //       T   : vau_fire=1 -> 扇区 = VAU 的
  //       T+1 : vau_fire=0 -> 扇区 = 歌单的 （而播放器正好在这一拍采样！）
  //   => 每次进/出视频都选到"当前那首歌" => 音轨永远不切、歌一直放、音画不同步。
  //      （这就是为什么二分实验 EE1 两端都指歌单时"看起来正常"。）
  //
  //   修法：脉冲只置起一个锁存，扇区在锁存里保持到下一次选择。
  // ============================================================================
  reg [31:0] wav_track_sector_l;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) wav_track_sector_l <= 32'd0;
    // vau_fire is used on BOTH mode edges. Choose the destination mode;
    // exiting video must select the current playlist song, not VAU again.
    else if (vau_fire) wav_track_sector_l <= vau_tgt ? vau_sel_sector : track_sel_sector;
    else if (wav_track_sel) wav_track_sector_l <= track_sel_sector;  // 歌单切歌
  end
  wire [31:0] wav_track_sector = wav_track_sector_l;
  // 视频播放期间强制解除暂停：否则用户之前暂停过歌单，会连视频音轨一起没声
  wire        wav_pause_eff = video_play ? (!av_started || video_paused) : pause;
  assign video_audio_ready = !VAU_ON || av_audio_failed || (vau_tgt && vau_ack && wav_ready && !audio_transition_busy && !wav_track_sel);
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      av_wait <= 0;
      av_audio_failed <= 0;
    end else if (!video_engine_play) begin
      av_wait <= 0;
      av_audio_failed <= 0;
    end else if (!av_started && !video_audio_ready) begin
      if (av_wait >= 28'd181818181) av_audio_failed <= 1;
      else av_wait <= av_wait + 1'b1;
    end else av_wait <= 0;
  end

  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      sel_pending  <= 1'b0;
      sel_wait_cnt <= 28'd0;
    end else begin
      if (wav_track_sel) sel_pending <= 1'b0;
      else if (track_sel_valid) sel_pending <= 1'b1;
      if (sel_pending) sel_wait_cnt <= sel_wait_cnt + 28'd1;
      else sel_wait_cnt <= 28'd0;
    end
  end

  wire sample_builder_idle;
  localparam [7:0] EMPTY_HOLD = 8'd255;
  reg [7:0] empty_cnt;
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) empty_cnt <= 8'd0;
    else if (!fifo_empty) empty_cnt <= 8'd0;
    else if (empty_cnt != EMPTY_HOLD) empty_cnt <= empty_cnt + 8'd1;
  end
  reg audio_drained;
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) audio_drained <= 1'b0;
    else audio_drained <= fifo_empty && (sample_builder_idle || (empty_cnt == EMPTY_HOLD));
  end
  reg [1:0] audio_drained_sync;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) audio_drained_sync <= 2'b00;
    else audio_drained_sync <= {audio_drained_sync[0], audio_drained};
  end
  // 2026-10-26: defer destructive stream commands until audible fade is done.
  wire fade_select, fade_seek, fade_pause, fade_mute_req, fade_timeout;
  wire [31:0] fade_sector;
  reg [1:0] fade_ack_sync;
  wire fade_audio_ack;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) fade_ack_sync <= 0;
    else fade_ack_sync <= {fade_ack_sync[0], fade_audio_ack};
  end
  audio_transition u_audio_transition (
    .clk          (sd_card_clk),
    .rst          (rst_all),
    .select_req   (wav_track_sel),
    .select_sector(wav_track_sector),
    .seek_req     (btn_ff_tick && !video_play),
    .pause_req    (wav_pause_eff),
    .reader_ready (wav_ready),
    .reader_bad   (wav_track_bad),
    .mute_ack     (fade_ack_sync[1]),
    .mute_req     (fade_mute_req),
    .reader_pause (fade_pause),
    .select_out   (fade_select),
    .seek_out     (fade_seek),
    .sector_out   (fade_sector),
    .busy         (audio_transition_busy),
    .timeout_seen (fade_timeout)
  );
  reg wav_ready_d;
  reg wav_stream_tog;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      wav_ready_d <= 1'b0;
      wav_stream_tog <= 1'b0;
    end else begin
      wav_ready_d <= wav_ready;
      if (wav_ready && !wav_ready_d) wav_stream_tog <= ~wav_stream_tog;
    end
  end
  reg [2:0] sb_tog_sync;
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) sb_tog_sync <= 3'b000;
    else sb_tog_sync <= {sb_tog_sync[1:0], wav_stream_tog};
  end
  wire sb_rst_pulse = sb_tog_sync[2] ^ sb_tog_sync[1];
  wire audio_sb_rst = audio_rst | sb_rst_pulse;

  wav_sample_builder u_wav_sample_builder (
    .clk(audio_mclk),
    .rst(audio_sb_rst),
    .sample_req(wav_sample_req && av_audio_allow),
    .stereo(stereo),
    .stream_idle(sample_builder_idle),
    .fifo_rd_en(fifo_rd_en),
    .fifo_rd_data(fifo_rd_data),
    .fifo_empty(fifo_empty),
    .sample_valid(wav_sample_valid),          // 构造器的【输出】（只接一次 ；上一版误插了两次 ）
    .sample_left(wav_sample_left),
    .sample_right(wav_sample_right),
    // [Design note]消费端观测口（必须用端口连接；层次引用 u_xxx.sig 会被 TD 判为
    //   HDL-8007 "external reference remains unresolved" 并让 top 变黑盒  —— 本轮踩过 ）
    .dbg_st(),
    .dbg_req_drop(),
    .dbg_req_drop_recent(),
    .dbg_lat_req2rden(),
    .dbg_lat_rden2v(),
    .dbg_req_seen_hi(),
    .dbg_dwell_state(),
    .dbg_dwell_grade(),
    .dbg_empty_stuck(),
    .dbg_pair_bad(),
    .dbg_rddata_frz(),
    .dbg_bytelo_frz(),
    .dbg_rden_frz(),
    .dbg_rddata_chg(),
    .dbg_req_lost(),
    .dbg_req_lost_now(),
    .dbg_ack_lat()
  );

  // Fade still advances at physical audio frame rate if SD starves. Repeat
  // the last complete sample pair through the gain ramp; never invent PCM bytes.
  reg [1:0] fade_mute_sync;
  reg fade_lrck_d;
  reg [1:0] fade_zero_frames;
  wire [9:0] fade_gain;
  wire fade_frame_tick = audio_i2s_lrck && !fade_lrck_d;
  wire fade_stall_tick = fade_mute_sync[1] && (fifo_empty || !av_audio_allow) && fade_frame_tick;
  assign fade_audio_ack = (fade_zero_frames == 2'd3);
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) begin
      fade_mute_sync <= 0;
      fade_lrck_d <= 0;
      fade_zero_frames <= 0;
    end else begin
      fade_mute_sync <= {fade_mute_sync[0], fade_mute_req};
      fade_lrck_d <= audio_i2s_lrck;
      if (!fade_mute_sync[1] || fade_gain != 0) fade_zero_frames <= 0;
      else if (fade_frame_tick && fade_zero_frames != 3)
        fade_zero_frames <= fade_zero_frames + 1'b1;
    end
  end
  volume_control u_volume_control (
    .clk         (audio_mclk),
    .rst         (audio_rst),
    .sample_tick (wav_sample_valid || fade_stall_tick),
    .gain        (fade_gain),
    .volume      (fade_mute_sync[1] ? 5'd0 : volume_s1),
    .sample_in_l (wav_sample_left),
    .sample_in_r (wav_sample_right),
    .sample_out_l(vol_sample_left),
    .sample_out_r(vol_sample_right)
  );

  // PCM -> I2S（audio_mclk 域，生成 I2S 三线，替换官方测试音 DDS）
  // PCM consumption follows actual displayed frame grants. Keep the audio
  // clock running during buffering, and drain old streams during selection.
  // A reader dropping ready at normal EOF does not invalidate buffered PCM.
  // Only startup/selection may bypass grants to drain a previous stream.
  wire av_drain_old_stream = (!av_started && !wav_ready) || (audio_transition_busy && !video_paused);
  av_sample_sync #(
    .LEAD_SAMPLES(1920)
  ) u_av_sample_sync (
    .clk                 (audio_mclk),
    .rst                 (audio_rst),
    .enable_sd           (VAU_ON && video_engine_play && !av_audio_failed),
    .started_sd          (av_started),
    .paused_sd           (video_paused),
    .draining_sd         (av_drain_old_stream),
    .frame_toggle_sd     (av_display_toggle),
    .samples_per_frame_sd(av_frame_samples),
    .sample_valid        (wav_sample_valid),
    .sample_allow        (av_audio_allow),
    .time_toggle         (av_audio_time_toggle),
    .buffering           (av_buffering)
  );
  reg [1:0] av_mute_sync;
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) av_mute_sync <= 0;
    // av_audio_failed only releases the video barrier after its bounded
    // timeout.  It must not become a permanent I2S mute: once the first
    // video frame is presented, the recovered/playlist fallback stream is
    // allowed to reach HDMI audio.
    else
      av_mute_sync <= {av_mute_sync[0], fade_audio_ack};
  end
  i2s_transmitter u_i2s_transmitter (
    .clk             (audio_mclk),
    .rst             (audio_rst),
    .mute            (av_mute_sync[1]),
    .flush           (sb_rst_pulse),
    .sample_left     (av_mute_sync[1] ? 24'd0 : vol_sample_left),
    .sample_right    (av_mute_sync[1] ? 24'd0 : vol_sample_right),
    .sample_req      (wav_sample_req),
    // [Design note]请求-接受握手：把构造器的产出脉冲接回来，i2s 才能"保持请求到被接受"
    //   （此前 wav_sample_valid 在顶层【没有任何消费者】 —— 正是 C2 的另一半成因 ）
    .sample_valid    (wav_sample_valid || fade_stall_tick),
    .dbg_req_held    (),
    .dbg_ack_seen    (),
    .dbg_req_stall   (),
    .dbg_rep_grade   (),
    .dbg_rep_long    (),
    .dbg_same_frames (),
    .dbg_chg_grade   (),
    .dbg_chg_cnt     (),
    .dbg_chg_last    (),
    .dbg_vld_grade   (),
    .dbg_req_grade   (),
    .dbg_held_grade  (),
    .dbg_vld_cnt     (),
    .dbg_req_cnt     (),
    .dbg_in_chg_grade(),
    .dbg_lat_grade   (),
    .dbg_in_chg_cnt  (),
    .dbg_lat_cnt     (),
    .i2s_bclk        (audio_i2s_bclk),
    .i2s_lrck        (audio_i2s_lrck),
    .i2s_dout        (audio_i2s_dout)
  );




wire req,pvalid,ended;wire[31:0]addr;wire[7:0]pcm;
reg[7:0]data=0;reg valid=0,done=0,grant=0;
media_player #(.LOOP_ON_EOF(0)) player(.clk(sd_card_clk),.rst(rst_all),
 .scan_start(1'b0),.scan_start_sector(32'd0),.scan_max_sector(32'd0),.sd_init_done(1'b1),.sd_error(1'b0),
 .track_sel(fade_select),.track_sel_sector(fade_sector),.wav_ready(wav_ready),.channels(channels),
 .sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done),
 .fifo_almost_full(fifo_almost_full),.fifo_drained(audio_drained_sync[1]),.sd_grant(grant),
 .pause(fade_pause),.seek(1'b0),.step_bytes(32'd0),.track_bad(wav_track_bad),.track_end(ended),.pcm_valid(pvalid),.pcm_data(pcm));
async_fifo #(.ADDR_WIDTH(13),.DEPTH(8192),.ALMOST_FULL_THRESH(6144)) fifo(
 .wr_clk(sd_card_clk),.wr_rst(rst_all),.wr_en(pvalid),.wr_data(pcm),.full(fifo_full),.almost_full(fifo_almost_full),.wr_usedw(fifo_used),
 .rd_clk(audio_mclk),.rd_rst(rst_all),.rd_en(fifo_rd_en),.rd_data(fifo_rd_data),.empty(fifo_empty));
reg[7:0]header[0:43];integer i,b,base,kind;
task put32(input integer o,input[31:0]v);begin
 header[o]=v[7:0];header[o+1]=v[15:8];header[o+2]=v[23:16];header[o+3]=v[31:24];end endtask
initial begin
 for(i=0;i<44;i=i+1)header[i]=0;
 header[0]="R";header[1]="I";header[2]="F";header[3]="F";put32(4,1000036);
 header[8]="W";header[9]="A";header[10]="V";header[11]="E";
 header[12]="f";header[13]="m";header[14]="t";header[15]=" ";put32(16,16);
 header[20]=1;header[22]=1;put32(24,48000);put32(28,96000);header[32]=2;header[34]=16;
 header[36]="d";header[37]="a";header[38]="t";header[39]="a";put32(40,1000000);
 wait(!rst_all);
 forever begin
  @(negedge sd_card_clk);
  if(req)begin
   grant=1;
   if(addr>=10000)begin base=(addr%10000)*512;kind=(addr/10000)*'h22;end
   else begin base=(addr-100)*512;kind='h11;end
   repeat(20)@(negedge sd_card_clk);
   for(b=0;b<512;b=b+1)begin
    data=(base+b<44)?header[base+b]:kind;valid=1;
    @(negedge sd_card_clk);valid=0;repeat(15)@(negedge sd_card_clk);
   end
   done=1;@(negedge sd_card_clk);done=0;grant=0;repeat(20)@(negedge sd_card_clk);
  end
 end
end
initial begin repeat(20)begin #1000000; $display("STATE t=%t ctl=%d gain=%d ack=%b empty=%b allow=%b ready=%b",$time,u_audio_transition.state,fade_gain,fade_audio_ack,fifo_empty,av_audio_allow,wav_ready);$fflush();end end
integer pairs=0,restarts=0,checks=0;reg tick_d=0;
always@(posedge audio_mclk)if(!rst_all&&wav_sample_valid)pairs=pairs+1;
always@(negedge sd_card_clk)if(!rst_all)begin
 if(fade_select)begin restarts=restarts+1;$display("SELECT time=%t sector=%d gain=%d used=%d",$time,fade_sector,fade_gain,fifo_used);end
 if(pvalid&&fifo_full)$fatal(1,"overflow");
 if(selection_failed)$fatal(1,"playlist selection timeout");
 if(wav_track_bad)$fatal(1,"reader rejected valid media");
 if(!video_engine_play)begin av_started=0;tick_d=av_audio_time_toggle;end
 else if(!av_started&&video_audio_ready)begin av_started=1;av_display_toggle=~av_display_toggle;end
 else if(av_started&&!video_paused&&tick_d!=av_audio_time_toggle)begin tick_d=av_audio_time_toggle;av_display_toggle=~av_display_toggle;end
end
task expect_source(input[31:0]sector,input[23:0]sample);
 integer n,before_pairs;begin
 n=0;repeat(100)@(negedge audio_mclk);
 while(!(wav_ready&&player.pending_sector==sector&&!audio_transition_busy&&fade_gain==961&&wav_sample_valid&&wav_sample_left==sample)&&n<30000*256)begin
  @(negedge audio_mclk);n=n+1;
 end
 if(n>=30000*256)$fatal(1,"STUCK video=%b sector=%d ready=%b transition=%d gain=%d fifo=%d sb=%d ack=%b allow=%b",video_play,player.pending_sector,wav_ready,u_audio_transition.state,fade_gain,fifo_used,u_wav_sample_builder.st,vau_ack,av_audio_allow);
 checks=checks+1;$display("SOURCE_OK %d pairs=%d restarts=%d",checks,pairs,restarts);
 end endtask
task press(input integer previous);begin
 @(negedge sd_card_clk);if(previous)prev_req=1;else next_req=1;
 @(negedge sd_card_clk);prev_req=0;next_req=0;
end endtask
initial begin
 repeat(8)@(negedge sd_card_clk);rst_all=0;
 repeat(8)@(negedge sd_card_clk);track_sel_valid=1;
 @(negedge sd_card_clk);track_sel_valid=0;
 expect_source(100,24'h111100);
 video_play=1;expect_source(10000,24'h222200);
 press(0);expect_source(20000,24'h444400);
 video_paused=1;repeat(1000)@(negedge audio_mclk);
 press(0);expect_source(40000,24'h888800);
 press(0);expect_source(10000,24'h222200);
 press(1);expect_source(40000,24'h888800);
 @(negedge sd_card_clk);movie_ended=1;
 @(negedge sd_card_clk);movie_ended=0;
 expect_source(10000,24'h222200);
 video_play=0;expect_source(100,24'h111100);
 if(checks!=8||restarts!=8)$fatal(1,"unexpected switches checks=%0d restarts=%0d",checks,restarts);
 $display("PASS real audio playlist checks=%d restarts=%d",checks,restarts);$finish;
end
initial begin #2000000000;$fatal(1,"overall timeout");end
endmodule
