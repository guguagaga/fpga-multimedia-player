// Board integration: clocks, controls, shared SD access, media pipelines and HDMI.
// SD/control clock: 90.909091 MHz; SDRAM clock: 125 MHz; HDMI: 1280x720 at 60 Hz.
module top (
  input clk,
  input rst_n,  // 板上 A2（手册 KEY1）：复位，保持不动
  input key1,   // 板上 B2（手册 KEY2）：音乐 播放/暂停 + 长按快进
  input key2,   // 板上 C1（KEY4）：短按轮播，长按切歌
  // KEY3 uses a dedicated input; its tap/hold classification is wired below.
  input key3,   // 板上 B1（手册 KEY3）：手动下一张图（独立）

  // 主板 SW[1:0] 选择亮度 {-48,-16,+16,+48}；SW[3:2] 选择对比度 Q7 {96,128,160,192}。
  // 主板丝印与 RTL 位序的映射以 pin.adc 为准。
  input [3:0] sw,

  // Expansion inputs are active-low and synchronized/debounced internally.
  // External74HC595 display and matrix keyboard are disabled in this build.
  // Pin assignments remain authoritative in pin.adc.
  input [4:0] exp_key,
  input [7:0] exp_sw,

  // On-board six-digit display.
  output [5:0] seg_sel,
  output [7:0] seg_data,

  // HDMI TMDS
  output HDMI_CLK_P,
  output HDMI_D2_P,
  output HDMI_D1_P,
  output HDMI_D0_P,

  // HDMI DDC
  output HDMI_DDC_SCL,
  inout  HDMI_DDC_SDA,

  // TF card SPI
  output sd_ncs,
  output sd_dclk,
  output sd_mosi,
  input  sd_miso
);

  parameter MEM_DATA_BITS = 32;
  parameter ADDR_BITS     = 21;
  parameter BUSRT_BITS    = 10;
  parameter FRAME_PIXELS  = 24'd460800;    // 1280*720 RGB565 pixels, packed two per32-bit word
  parameter BUF0_ADDR     = 24'd0;
  parameter BUF1_ADDR     = FRAME_PIXELS;
  // Three video buffers prevent immediate reuse of a retired display buffer.
  // 720P RGB565 uses460800 packed32-bit words per frame.
  parameter BUF2_ADDR     = 24'd921600;    // FRAME_PIXELS * 2

  wire Sdr_init_done;
  wire Sdr_init_ref_vld;
  wire Sdr_busy;

  localparam integer SD_CORE_HZ=90_909_091; // 1GHz PLL VCO divided by11; actual control-clock frequency.
  wire        sd_card_clk;
  wire        ext_mem_clk;
  wire        ext_mem_clk_sft;
  wire        video_clk;
  wire        hdmi_5x_clk;

  wire        hs;
  wire        vs;
  wire        de;

  wire [23:0] vout_data_raw;
  wire [23:0] vout_data;
  wire        display_valid;
  wire        img_loading;

  wire [ 3:0] state_code;
  wire [ 6:0] seg_data_0;

  // 图片源高度由图片链路提供；帧缓存写入按完整 1280x720 输出栅格组织。
  wire [15:0] img_h_img;
  wire        img_top_down;
  wire [15:0] img_h_used;

  wire [1:0] scanout_bank_mem;
  wire scanout_toggle_mem;
  reg [1:0] scanout_bank_s0,scanout_bank_s1,scanout_bank_sd;
  reg [2:0] scanout_toggle_sync;
  wire scanout_event_sd=scanout_toggle_sync[2]^scanout_toggle_sync[1];
  // Bundled bank data settles through two registers before the delayed
  // event is consumed. Source bank remains stable for a complete refresh.
  always @(posedge sd_card_clk or posedge rst_all)begin
    if(rst_all)begin
      scanout_bank_s0<=0;scanout_bank_s1<=0;scanout_bank_sd<=0;
      scanout_toggle_sync<=0;
    end else begin
      scanout_bank_s0<=scanout_bank_mem;scanout_bank_s1<=scanout_bank_s0;
      scanout_toggle_sync<={scanout_toggle_sync[1:0],scanout_toggle_mem};
      if(scanout_event_sd)scanout_bank_sd<=scanout_bank_s1;
    end
  end
  wire        video_read_req;
  wire        video_read_req_ack;
  wire        video_read_en;
  wire [31:0] video_read_data;

  wire        sd_card_write_en;
  wire [31:0] sd_card_write_data;
  wire        sd_card_write_req;
  wire        sd_card_write_req_ack;
  wire        frame_write_finish;
  wire        image_fifo_almost_full;
  reg         frame_write_toggle_mem;

  wire [ 1:0] write_buf_idx;
  wire [ 1:0] disp_buf_idx;

  // 图片与视频共享 SDRAM 写接口。模式选择同时切换像素、写使能和缓冲区归属，
  // 使一个客户端的数据不会写入另一个客户端持有的帧缓冲。
  wire img_pad_en, img_pad_high;
  wire [31:0] img_pad_data;
  wire        image_source_high = image_fifo_almost_full | img_pad_high;
  wire        img_write_req;  // 图片加载器的帧写请求。
  wire        img_write_en;
  wire [31:0] img_write_data;
  wire [ 1:0] img_write_buf_idx;
  wire [ 1:0] img_disp_buf_idx;

  wire        vid_active;
  reg         av_started;
  reg  [27:0] av_wait;
  reg         av_audio_failed;
  wire        video_audio_ready;
  wire [31:0] directory_image4, directory_image5, directory_image6, directory_image7;
  wire [ 3:0] directory_image_count;
  wire [31:0] directory_image0, directory_image1, directory_image2, directory_image3;
  wire        vid_disp_ok;
  wire        vid_write_req;
  wire        vid_write_en;
  wire [31:0] vid_write_data;
  wire [ 1:0] vid_write_buf_idx;
  wire [ 1:0] vid_disp_buf_idx;
  wire [15:0] vid_img_h;
  wire        vid_sd_sec_read;
  wire [31:0] vid_sd_sec_read_addr;
  wire [ 7:0] vid_sd_sec_read_data;
  wire        vid_sd_sec_read_data_valid;
  wire        vid_sd_sec_read_end;
  wire [ 3:0] vid_dbg_state;
  wire [31:0] legacy_video_sector, legacy_vau_sector;
  wire media_entry_valid, media_entry_audio;
  wire [15:0] media_entry_prefix;
  wire [31:0] media_entry_sector;
  wire [3:0] video_available;
  wire [1:0] video_index;
  wire video_engine_play, video_switching, video_audio_select;
  wire video_playlist_ended;
  wire video_auto_enabled, video_selection_failed, video_duplicate_seen;
  wire video_last_shown;
  reg [1:0] video_budget_empty_sync;
  wire [31:0] fat_video_sector;  // fat32_list 找到的 .VID 起始扇区（0 = 卡上没有）
  wire [31:0] vau_sector;  // fat32_list 找到的 .VAU 起始扇区（0 = 没配视频音轨）
  wire [31:0] song5_sector;  // 【超时恢复】无 .VAU 时使用歌单第 5 首
  reg         video_play;  // 用户开关：KEY3 长按切换
  reg         video_paused;  // KEY1 短按：视频暂停/继续
  // 退出视频的单周期事件。
  reg         vid_exit_reload;
  // 保留视频切换意图，等当前图片读事务完成后再转交共享接口。
  // 短按和长按先分类，避免一次手势同时触发切图与视频切换。
  reg         vid_toggle_pending;
  wire        video_seq_present = |video_available;

  // 视频入口要求目录就绪、有效视频存在，且图片加载和图片读请求均已结束。
  wire        video_can_start;
  // 视频期间 / 正等待进视频期间，都不允许开始新的切图装载
  wire        vid_lock = video_play | vid_toggle_pending;

  // ---- 写通路 2 选 1 ----
  assign sd_card_write_req  = vid_active ? vid_write_req : img_write_req;
  assign sd_card_write_en   = vid_active ? vid_write_en : img_pad_en;
  assign sd_card_write_data = vid_active ? vid_write_data : img_pad_data;
  assign write_buf_idx      = vid_active ? vid_write_buf_idx : img_write_buf_idx;
  assign disp_buf_idx       = vid_active ? vid_disp_buf_idx : img_disp_buf_idx;
  // 图片和视频共用完整 720 行输出帧。
  assign img_h_used         = 16'd720;
  // 首图提交前黑屏；视频接入后视频自己有"第一帧写满才显示"的门（vid_disp_ok）
  wire                     display_valid_any = vid_active ? vid_disp_ok : display_valid;

  wire                     App_rd_en;
  wire [    ADDR_BITS-1:0] App_rd_addr;
  wire                     Sdr_rd_en;
  wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
  wire                     App_wr_en;
  wire [    ADDR_BITS-1:0] App_wr_addr;
  wire [MEM_DATA_BITS-1:0] App_wr_din;
  wire [              3:0] App_wr_dm;

  wire                     hs_0;
  wire                     vs_0;
  wire                     de_0;

  // HDMI 1.4b 音频发射相关
  wire                     audio_video_ref75;
  wire                     audio_pll_lock;
  wire                     audio_mclk;
  wire                     audio_i2s_bclk;
  wire                     audio_i2s_lrck;
  wire                     audio_i2s_dout;
  wire                     audio_valid;
  wire [             23:0] audio_left_data;
  wire [             23:0] audio_right_data;
  wire                     acr_valid;
  wire [             19:0] acr_cts;
  wire [             19:0] acr_n;

  wire                     axis_s_user;
  wire                     axis_s_valid;
  wire                     axis_s_last;
  wire [             23:0] axis_s_data;
  wire                     axis_s_ready;

  wire                     edid_trig;
  wire                     edid_valid;
  wire [              7:0] edid_data;

  wire [              9:0] tmds_ch0_data;
  wire [              9:0] tmds_ch1_data;
  wire [              9:0] tmds_ch2_data;
  wire [              9:0] tmds_clk_data;

  // 像素坐标、OSD 和频谱所用信号在实例化前统一声明，防止隐式窄线网。
  wire                     rst_all;
  assign rst_all = ~rst_n;
  wire rst_all_n;
  assign rst_all_n = ~rst_all;

  wire [10:0] active_x;
  wire [ 9:0] active_y;
  wire [7:0] osd_r, osd_g, osd_b;
  wire [23:0] osd_rgb;
  wire osd_de, osd_vs;
  wire disp_de, disp_vs;
  wire [23:0] disp_rgb;

  // 图像层淡入淡出及跨时钟域握手信号。转场在 OSD 叠加前处理。
  wire [23:0] fade_img;  
  wire        fade_busy;  // video_clk 域：转场进行中（淡出或淡入）
  wire        fade_req_toggle;  // sd_card_clk 域：请求淡出（由 sd_card_bmp 驱动）
  wire        fade_done_tgl;  // video_clk 域：淡出完成（fade_in 输出，toggle）
  reg  [ 2:0] fade_req_sync;  // sd -> video 的 3 级同步
  reg  [ 2:0] fade_done_sync;  // video -> sd 的 3 级同步
  reg  [ 1:0] fade_busy_sync;  // video -> sd 的 busy 电平 2 级同步
  wire        fade_req_pulse;  // video_clk 域的 1 拍"开始淡出"脉冲
  wire        fade_done_pulse;  // sd_card_clk 域的 1 拍"淡出完成"脉冲
  wire        fade_switch_lock;  // sd_card_clk 域：转场中 -> 禁止发起新的切图装载
  // 首图超时提交状态，供状态显示使用。
  wire        firstimg_fb_seen;
  // 超时快照记录写完成、源完成、解码就绪和像素写入状态。
  wire [ 3:0] firstimg_diag;

  wire fft_start, fft_done;
  wire [15:0] fft_din_re, fft_din_im;
  wire [15:0] fft_dout_re, fft_dout_im;
  wire       fft_dout_valid;
  wire [7:0] bar_data;
  wire [5:0] bar_addr;  // 32 个显示频带的读地址。
  wire [7:0] bar_data2;
  wire [5:0] bar_addr2;
  wire [7:0] bar_data3;
  wire [5:0] bar_addr3;
  wire [7:0] bar_data4;
  wire [5:0] bar_addr4;
  wire       beat_pulse;

  // ===================== 播放状态（进度条/时间，sd_card_clk 域） =====================
  wire       wav_ready;
  wire [31:0] wav_sample_rate, wav_data_size, wav_pcm_byte_cnt;
  wire [15:0] wav_channels, wav_bit_depth;
  wire [15:0] tot_sec, cur_sec;
  wire [7:0] progress;

  // ===================== 歌名（FAT32 播放列表，sd_card_clk 域） =====================
  reg fat_scan_start;
  wire list_ready;
  wire [5:0] song_count;
  wire [63:0] list_name;
  wire [3:0]  img_auto_mode;    
  wire img_auto_on;  
  wire [31:0] list_sector;

  // FAT32 数据区地址仅在 list_ready 后有效，图片访问须等待挂载完成。
  wire [31:0] img_scan_sector;
  wire [3:0] img_found_count;
  wire img_scan_done_fb;
  reg bg_scan_start2;
  reg bg_scan_limited;
  reg [31:0] img_scan_sector_lat;
  wire [31:0] fat_data_start;
  wire [31:0] fs_fat_start, fs_audio_base, fs_image_base;
  wire [ 3:0] fs_cluster_shift;
  wire [27:0] fs_max_cluster;
  wire fs_geometry_valid, fs_mount_error, fs_error;
  wire [3:0] fs_error_code;
  wire [1:0] fs_error_owner;
  wire fs_card_req, fs_card_multi, fs_card_pace;
  wire [31:0] fs_card_lba;
  wire [ 7:0] fs_logical_data;
  wire fs_logical_valid, fs_logical_done;
  wire [1:0] fs_owner = vid_sd_grant ? 2'd3 : (img_sd_grant ? 2'd0 : (wav_sd_grant ? 2'd1 : 2'd2));
  wire[31:0]fs_file_base=vid_sd_grant?fat_video_sector:(img_sd_grant?fs_image_base:fs_audio_base);


  // 挂载扇区首字节的只读状态观测。
  wire [7:0] fat_mbr_b0;

  // ===================== 多曲目播放反馈 =====================
  wire wav_track_end;  // wav_reader: 一曲播完（1 拍）
  wire wav_track_bad;  // wav_reader: 指定扇区的头不合法（1 拍）

  // 图片与音频共享读卡带宽；图片优先权由音频 FIFO 储备决定。

  // ===================== SD 卡复用（共享 sd_card_top） =====================
  wire sd_init_done;
  wire vid_sd_grant;
  wire img_sd_grant;
  // 视频和图片顺序读取均可启用 CMD18；目录与音频请求采用单扇区路径。
  // 多块读是否放行由当前事务归属及 FAT 映射结果共同决定。
  wire sd_multi_en = (vid_sd_grant & video_play) | (img_sd_grant & img_loading);
  // 图片响应寄存器保持 data、valid、end 在同一流水级。
  reg [7:0] img_data_q;
  reg img_valid_q, img_end_q, img_grant_q;
  wire img_sd_sec_read, wav_sd_sec_read, sd_sec_read;
  assign video_can_start = list_ready && video_seq_present && !img_loading && !img_sd_sec_read;
  wire fat_sd_sec_read;
  wire mount_sd_req, iter_sd_req, iter_valid, iter_empty, iter_error, iter_consume, iter_failed;
  wire [31:0] mount_sd_addr, iter_sd_addr, iter_lba;
  wire [27:0] fs_root_cluster;
  // Mount and runtime image queries share one parser and one SD client.
  // list_ready remains asserted; pause never revokes an active read.
  assign fat_sd_sec_read = mount_sd_req;


  wire [31:0] img_sd_sec_read_addr, wav_sd_sec_read_addr, sd_sec_read_addr;
  wire [31:0] fat_sd_sec_read_addr;
  assign fat_sd_sec_read_addr = mount_sd_addr;
  wire [7:0] img_sd_sec_read_data, wav_sd_sec_read_data, sd_sec_read_data;
  wire [7:0] fat_sd_sec_read_data;
  wire img_sd_sec_read_data_valid, wav_sd_sec_read_data_valid, sd_sec_read_data_valid;
  wire fat_sd_sec_read_data_valid;
  wire img_sd_sec_read_end, wav_sd_sec_read_end, sd_sec_read_end;
  wire fat_sd_sec_read_end;

  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      img_data_q  <= 0;
      img_valid_q <= 0;
      img_end_q   <= 0;
      img_grant_q <= 0;
    end else begin
      img_data_q  <= img_sd_sec_read_data;
      img_valid_q <= img_sd_sec_read_data_valid;
      img_end_q   <= img_sd_sec_read_end;
      img_grant_q <= img_sd_grant;
    end
  end
  // 音频客户端响应统一延迟一拍，缩短 SD 状态译码到音频写使能的组合路径。
  // data、valid、end 必须同拍延迟；仲裁器与物理控制器使用自身事务完成握手。
  reg [7:0] wav_d_q;
  reg wav_dv_q, wav_e_q;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      wav_d_q  <= 8'd0;
      wav_dv_q <= 1'b0;
      wav_e_q  <= 1'b0;
    end else begin
      wav_d_q  <= wav_sd_sec_read_data;
      wav_dv_q <= wav_sd_sec_read_data_valid;
      wav_e_q  <= wav_sd_sec_read_end;
    end
  end

  // ===================== 音频数据通路 =====================
  reg        wav_scan_start;
  wire       wav_pcm_valid;
  wire [7:0] wav_pcm_data;
  wire fifo_full, fifo_almost_full, fifo_empty;
  wire [13:0] fifo_usedw;  // wr_usedw = [ADDR_WIDTH:0]，ADDR_WIDTH=13 -> 14 bit
  wire [ 7:0] fifo_rd_data;
  wire        fifo_rd_en;
  wire        wav_sample_valid;
  wire [23:0] wav_sample_left, wav_sample_right;
  wire wav_sample_req;
  wire av_audio_allow, av_buffering;
  wire [12:0] av_frame_samples;
  wire av_audio_time_toggle;
  wire av_audio_frame_tick;
  reg av_display_toggle;
  reg [2:0] av_time_sync;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) av_time_sync <= 0;
    else av_time_sync <= {av_time_sync[1:0], av_audio_time_toggle};
  end
  assign av_audio_frame_tick = av_time_sync[2] ^ av_time_sync[1];

  // 读取器状态与故障粘滞位只用于状态显示，不参与媒体控制决策。
  wire [2:0] wav_dbg_state;
  wire       wav_dbg_resync;
  wire       wav_dbg_rdwd;
  wire [7:0] wav_dbg_fp;  
  wire       wav_dbg_silent;  
  wire       wav_dbg_gate_open;  
  reg        gate_open_r;  //   打一拍再送数码管（避免长组合路径拖时序）
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) gate_open_r <= 1'b1;
    else gate_open_r <= wav_dbg_gate_open;
  end
  wire wav_dbg_posbad;  
  wire wav_dbg_dataok;  
  wire wav_dbg_wp_seen, wav_dbg_wp_recent, wav_dbg_wp_gate;
  wire wav_dbg_drop_recent;  
  wire        wav_dbg_req_held, wav_dbg_ack_seen;   
  wire wav_dbg_req_stall;  
  wire wav_dbg_pcm_odd;  
  wire [31:0] wav_dbg_pcm_sum32, wav_dbg_pcm_n32;
  wire [1:0] wav_dbg_lat_req2rden, wav_dbg_lat_rden2v;  
  wire        wav_dbg_req_seen_hi;
  wire [ 3:0] wav_dbg_dwell_state;
  wire [ 1:0] wav_dbg_dwell_grade;
  wire        wav_dbg_empty_stuck;
  wire [ 1:0] wav_dbg_chg_grade;
  wire [11:0] wav_dbg_chg_cnt;
  wire        wav_dbg_chg_last;
  wire [1:0] wav_dbg_rddata_frz, wav_dbg_bytelo_frz, wav_dbg_rden_frz;
  wire [11:0] wav_dbg_rddata_chg;
  reg  [1:0]  wav_dbg_wdata_frz;      
  // 音频写数据、写使能及结束条件的只读活动观测。
  reg [1:0] wav_dbg_vldfrz_grade;  // 0=<256 拍 1=<4096 2=<65536 3=≥65536 没写过
  wire wav_dbg_hdr_phase;  // 1 = file_byte_cnt < data_offset ⇒ 卡在头部区
  wire [1:0] wav_dbg_fbcnt_frz;  // file_byte_cnt 冻结档
  reg [1:0] wav_dbg_sdvalid_frz;  // SD 侧 sd_sec_read_data_valid 冻结档
  reg [23:0] sdv_age;
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      sdv_age <= 24'd0;
      wav_dbg_sdvalid_frz <= 2'd0;
    end else begin
      if (wav_sd_sec_read_data_valid) sdv_age <= 24'd0;
      else if (sdv_age < 24'hFFFFFF) sdv_age <= sdv_age + 24'd1;
      if (sdv_age < 24'd256) wav_dbg_sdvalid_frz <= 2'd0;
      else if (sdv_age < 24'd4096) wav_dbg_sdvalid_frz <= 2'd1;
      else if (sdv_age < 24'd65536) wav_dbg_sdvalid_frz <= 2'd2;
      else wav_dbg_sdvalid_frz <= 2'd3;  
    end
  end
  // 每窗口统计 PCM 写入、数据变化及 SD 字节有效事件，供状态显示。
  // 窗口时间由计数阈值与 SD_CORE_HZ 换算。
  wire [1:0] wav_dbg_vld_grade, wav_dbg_req_grade, wav_dbg_held_grade;
  wire [11:0] wav_dbg_vld_cnt, wav_dbg_req_cnt;
  wire wav_dbg_seek_drain, wav_dbg_resync_pulse;
  reg [11:0] w18_resync_cnt;
  reg w18_pcnt_chg, w18_pcnt_chg_win;
  reg  [31:0] w18_pcnt_prev;
  wire [ 4:0] wav_dbg_sd_state;
  wire        wav_dbg_sd_cmd_err;
  localparam integer W17 = 2_100_000;
  reg [21:0] w17_t;
  reg [11:0] w17_a_cnt, w17_b_cnt, w17_c_cnt;
  reg [1:0] w17_a_grade, w17_b_grade, w17_c_grade, w17_d_grade;
  reg [7:0] w17_pdata_prev;
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      w17_t <= 22'd0;
      w17_a_cnt <= 12'd0;
      w17_b_cnt <= 12'd0;
      w17_c_cnt <= 12'd0;
      w17_a_grade <= 2'd0;
      w17_b_grade <= 2'd0;
      w17_c_grade <= 2'd0;
      w17_d_grade <= 2'd0;
      w17_pdata_prev <= 8'd0;
      w18_resync_cnt <= 12'd0;
      w18_pcnt_chg <= 1'b0;
      w18_pcnt_chg_win <= 1'b0;
      w18_pcnt_prev <= 32'd0;
    end else begin
      if (wav_pcm_valid) w17_a_cnt <= w17_a_cnt + 12'd1;
      if (wav_pcm_data !== w17_pdata_prev) begin
        w17_b_cnt <= w17_b_cnt + 12'd1;
        w17_pdata_prev <= wav_pcm_data;
      end
      if (wav_sd_sec_read_data_valid) w17_c_cnt <= w17_c_cnt + 12'd1;
      if (wav_dbg_resync_pulse)
        w18_resync_cnt <= w18_resync_cnt + 12'd1;  
      if (wav_pcm_byte_cnt !== w18_pcnt_prev) begin
        w18_pcnt_chg  <= 1'b1;
        w18_pcnt_prev <= wav_pcm_byte_cnt;
      end  // pcm_out_cnt 是否推进
      if (w17_t >= (W17 - 1)) begin
        w17_t <= 22'd0;
        // 档位：≥768 记 3（≈1024 的一半以上 ）；≥16 记 1；否则 0
        if (w17_a_cnt >= 12'd768) w17_a_grade <= 2'd3;
        else if (w17_a_cnt >= 12'd256) w17_a_grade <= 2'd2;
        else if (w17_a_cnt >= 12'd16) w17_a_grade <= 2'd1;
        else w17_a_grade <= 2'd0;  
        if (w17_b_cnt >= 12'd768) w17_b_grade <= 2'd3;
        else if (w17_b_cnt >= 12'd256) w17_b_grade <= 2'd2;
        else if (w17_b_cnt >= 12'd16) w17_b_grade <= 2'd1;
        else w17_b_grade <= 2'd0;
        if (w17_c_cnt >= 12'd768) w17_c_grade <= 2'd3;
        else if (w17_c_cnt >= 12'd256) w17_c_grade <= 2'd2;
        else if (w17_c_cnt >= 12'd16) w17_c_grade <= 2'd1;
        else w17_c_grade <= 2'd0;  
        // D：复用 i2s 的窗口计数（1024 帧窗口 ）
        if (wav_dbg_vld_cnt >= 12'd768) w17_d_grade <= 2'd3;
        else if (wav_dbg_vld_cnt >= 12'd256) w17_d_grade <= 2'd2;
        else if (wav_dbg_vld_cnt >= 12'd16) w17_d_grade <= 2'd1;
        else w17_d_grade <= 2'd0;
        w18_pcnt_chg_win <= w18_pcnt_chg;  
        w18_pcnt_chg <= 1'b0;
        w17_a_cnt <= 12'd0;
        w17_b_cnt <= 12'd0;
        w17_c_cnt <= 12'd0;
      end else w17_t <= w17_t + 22'd1;
    end
  end
  wire        wav_dbg_latch_cond = (wav_pcm_byte_cnt >= wav_data_size) && (wav_data_size != 32'd0);   
  reg [23:0] vld_age;
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      vld_age <= 24'd0;
      wav_dbg_vldfrz_grade <= 2'd0;
    end else begin
      if (wav_pcm_valid) vld_age <= 24'd0;
      else if (vld_age < 24'hFFFFFF) vld_age <= vld_age + 24'd1;
      if (vld_age < 24'd256) wav_dbg_vldfrz_grade <= 2'd0;
      else if (vld_age < 24'd4096) wav_dbg_vldfrz_grade <= 2'd1;
      else if (vld_age < 24'd65536) wav_dbg_vldfrz_grade <= 2'd2;
      else wav_dbg_vldfrz_grade <= 2'd3;  // 写完全停
    end
  end
  reg [23:0] wdata_age;
  reg [ 7:0] wdata_prev;
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      wdata_age <= 24'd0;
      wdata_prev <= 8'd0;
      wav_dbg_wdata_frz <= 2'd0;
    end else begin
      if (wav_pcm_data !== wdata_prev) begin
        wdata_age  <= 24'd0;
        wdata_prev <= wav_pcm_data;
      end else if (wdata_age < 24'hFFFFFF) wdata_age <= wdata_age + 24'd1;
      if (wdata_age < 24'd256) wav_dbg_wdata_frz <= 2'd0;
      else if (wdata_age < 24'd4096) wav_dbg_wdata_frz <= 2'd1;
      else if (wdata_age < 24'd65536) wav_dbg_wdata_frz <= 2'd2;
      else wav_dbg_wdata_frz <= 2'd3;
    end
  end
  // 音频供数、输入活动及锁存脉冲的只读观测。
  wire [1:0] wav_dbg_in_chg_grade, wav_dbg_lat_grade;
  wire [11:0] wav_dbg_in_chg_cnt, wav_dbg_lat_cnt;
  wire [1:0] wav_dbg_rep_grade;
  wire wav_dbg_rep_long;
  wire [3:0] wav_dbg_same_frames;

  reg [1:0] ps_scr;  // 轮显屏号 0..3
  reg  [25:0] ps_scr_cnt;                          
  reg [15:0] ps_show;  // 当前屏显示的 16 位
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      ps_scr <= 2'd0;
      ps_scr_cnt <= 26'd0;
      ps_show <= 16'd0;
    end else begin
      if (ps_scr_cnt >= 26'd50_000_000) begin
        ps_scr_cnt <= 26'd0;
        ps_scr <= ps_scr + 2'd1;
      end else ps_scr_cnt <= ps_scr_cnt + 26'd1;
      case (ps_scr)
        2'd0:    ps_show <= wav_dbg_pcm_sum32[15:0];  // 屏0 = 低16位（最常用 ）
        2'd1:    ps_show <= wav_dbg_pcm_sum32[31:16];  // 屏1 = 高16位
        2'd2:    ps_show <= wav_dbg_pcm_n32[15:0];  // 屏2 = 已累加样本数 n 的低 16 位
        default: ps_show <= 16'd0;  // 屏3 = 保留
      endcase
    end
  end
  wire wav_dbg_req_lost, wav_dbg_req_lost_now;
  wire [1:0] wav_dbg_ack_lat;
  // 音量活动和零增益状态观测；粘滞位保留复位后的事件。
  reg         vol_chg_hit;       
  reg [19:0]  vol_chg_cnt;       // 音量变化活动窗口计数，装载 1000000 个音频主时钟周期。
  reg vol_chg_recent_a;  // audio 域活指示
  reg vol_chg_s0, vol_chg_s1;  // 同步到 clk 域（慢电平  2FF ）
  reg [4:0] vol_prev;
  reg       vol_zero_hit;  // 粘滞：音量曾经为 0（= 完全静音 ）
  reg       vol_zero_now;  // 电平：现在音量为 0
  // 音频域的慢电平与粘滞位通过两级寄存器同步到状态显示域。
  reg volz_hit_s0, volz_hit_s1, volz_now_s0, volz_now_s1;

  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      volz_hit_s0 <= 1'b0;
      volz_hit_s1 <= 1'b0;

      volz_now_s0 <= 1'b0;
      volz_now_s1 <= 1'b0;
    end else begin
      volz_hit_s0 <= vol_zero_hit;
      volz_hit_s1 <= volz_hit_s0;
      volz_now_s0 <= vol_zero_now;
      volz_now_s1 <= volz_now_s0;
      vol_chg_s0  <= vol_chg_recent_a;
      vol_chg_s1  <= vol_chg_s0;
    end
  end

  // ===================== 矩阵键盘 + 播放器控制 =====================
  wire [ 3:0] key_code;


  wire        key_press;

  // ============================================================================
  // Retained matrix-keyboard event wiring. KP_ON is disabled in this build;
  // expansion and board-button events are connected separately.
  wire        kp_next_song = key_press && (key_code == 4'd12);  // C
  wire        kp_period_step = key_press && (key_code == 4'd13);  // D
  wire        pause;
  wire [ 4:0] volume;
  wire [ 1:0] mode;
  wire [ 5:0] song_idx;

  // 键盘自检输出（sd_card_clk 域）：用于数码管显示真实扫描结果
  wire [15:0] kp_raw_image;  // 4x4 键位图，1 = 该键被读到闭合
  wire [ 1:0] kp_row_now;  // 当前正在扫描的行
  wire [ 3:0] kp_col_now;  // 当前采样的原始列读数
  wire [15:0] kp_frame_cnt;  // 帧计数（持续增长 = 扫描器没停摆）
  wire [ 1:0] hit_row_lat;  // 最近一次按下的行（锁存，OSD 可读）
  wire [ 3:0] hit_col_lat;  // 最近一次按下的列（锁存，OSD 可读）
  wire [ 3:0] hit_key_lat;  // 最近一次按下的键码（锁存，OSD 可读）

  // 板载按键为低有效，先同步至 SD/control 域，再由手势模块分类。
  localparam kp_debug_dflt = 1'b0;  // 1 = 上电默认显示键盘自检面板
  wire kp_debug_on = kp_debug_dflt;
  reg key1_s1, key1_s2;
  reg key2_s1, key2_s2;
  reg key3_s1, key3_s2;

  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      key1_s1 <= 1'b1;
      key1_s2 <= 1'b1;
      key2_s1 <= 1'b1;
      key2_s2 <= 1'b1;
      key3_s1 <= 1'b1;
      key3_s2 <= 1'b1;
    end else begin
      key1_s1 <= key1;
      key1_s2 <= key1_s1;
      key2_s1 <= key2;
      key2_s2 <= key2_s1;
      key3_s1 <= key3;
      key3_s2 <= key3_s1;
    end
  end

  // 扩展板按键及拨码经同步、消抖后生成稳定电平和按键脉冲。
  // 机械输入不直接驱动读卡或帧缓冲控制。
  wire [4:0] exp_key_down;  // 1 = 按下（消抖后）
  wire [4:0] exp_key_press;  // 单拍脉冲
  wire [7:0] exp_sw_level;  // 1 = 拨到 ON（消抖后）

  exp_input_sync #(
    .CLK_FREQ_HZ(SD_CORE_HZ),
    .DEBOUNCE_MS(8)
  ) u_exp_input_sync (
    .clk      (sd_card_clk),
    .rst      (rst_all),
    .key_n    (exp_key),
    .sw_n     (exp_sw),
    .key_down (exp_key_down),
    .sw_level (exp_sw_level),
    .key_press(exp_key_press)
  );

  // exp_sw_level 已转换为 ON=1；低四位直接作为轮播周期档位码。
  wire [3:0] exp_preset_sel = exp_sw_level[3:0];

  wire [3:0] exp_period_code;  // 当前已生效的档位码
  wire [9:0] exp_period_sec;  // 当前已生效的周期（秒）
  wire       exp_cfg_boundary;  // 允许换档的安全边界（来自 sd_card_bmp）

  carousel_period_cfg u_period_cfg (
    .clk        (sd_card_clk),
    .rst        (rst_all),
    .preset_sel (exp_preset_sel),
    .boundary   (exp_cfg_boundary),
    .preset_code(exp_period_code),
    .period_sec (exp_period_sec),
    .preset_sec ()
  );

  wire [4:0] auto_status_video;
  carousel_status_cdc u_carousel_status (
    .src_clk(sd_card_clk), .dst_clk(video_clk), .rst(rst_all),
    .src_status({img_auto_on, exp_period_code}),
    .dst_status(auto_status_video)
  );

  // ---- 单拍事件 ----
  wire exp_video_pause_evt = exp_key_press[0];  // KEY0 视频暂停/恢复
  wire exp_next_song_evt = exp_key_press[1];  // KEY1 下一首
  wire exp_video_toggle_evt = exp_key_press[3];  // KEY3 进入/退出视频

  // 图片控制接口使用低有效按键电平及内部消抖。
  // 扩展板电平取反后接入，防止单周期事件被下游消抖过滤。
  wire exp_nextimg_key_n = video_play || ~exp_key_down[2];
  wire exp_auto_key_n = ~exp_key_down[4];  // KEY4 按下 = 0

  // 编译期功能选择用于裁剪未接入的控制接口。
  `define USE_PLAYER_CTRL 1

`ifndef DISABLE_PLAYER_CTRL
  // 板载 KEY2 控制音乐暂停与长按快进，KEY4 短按轮播、长按切歌。
  // 短按事件在手势分类结束后发送，长按不再产生短按事件。
  wire btn_tap_a, btn_tap_b, btn_dbl_a, btn_long_a, btn_long_b, btn_ff_tick;
  wire btn_long_b_tick;  
  wire btn_level_a, btn_level_b;
  wire btn_pause_evt;
  // KEY1 在视频模式只控制视频暂停，避免退出视频后把歌曲误留在暂停态。
  wire btn_music_pause_evt = btn_pause_evt && !video_play;

  button_ctrl #(
    .DEBOUNCE(21'd1818182),
    .LONG_PRESS(26'd36363636),
    .LONG_PRESS_B(26'd36363636),
    .REPEAT_PERIOD(24'd9090909),
    .DBL_WINDOW(26'd27272727)
  ) u_button_ctrl (
    .clk        (sd_card_clk),
    .rst_n      (rst_n),
    .key_a      (key1_s2),
    .key_b      (key2_s2),
    .level_a    (btn_level_a),
    .level_b    (btn_level_b),
    .tap_a      (btn_tap_a),
    .tap_b      (btn_tap_b),
    .dbl_a      (btn_dbl_a),
    .long_a     (btn_long_a),
    .long_b     (btn_long_b),
    .ff_tick    (btn_ff_tick),
    .long_b_tick(btn_long_b_tick)  
  );
  assign btn_pause_evt = btn_tap_a;
`else
  // ---- 关闭新功能：把相关信号绑成"无动作"，逻辑被完全裁掉 ----
  wire btn_tap_a = 1'b0, btn_tap_b = 1'b0, btn_dbl_a = 1'b0;
  wire btn_long_a = 1'b0, btn_long_b = 1'b0, btn_ff_tick = 1'b0;
  wire btn_long_b_tick = 1'b0;  
  wire btn_pause_evt = 1'b0;
`endif

  // 把 KEY4 短按转换为满足图片控制接口消抖宽度的低有效虚拟按键。
  reg [25:0] auto_vk_cnt;   
  reg auto_vk;  // 低有效虚拟按键：平时 1（松开）
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      auto_vk     <= 1'b1;
      auto_vk_cnt <= 26'd0;
    end else if (btn_tap_b) begin
      auto_vk     <= 1'b0;
      auto_vk_cnt <= 26'd4545455;
    end else if (auto_vk_cnt != 26'd0) begin
      auto_vk_cnt <= auto_vk_cnt - 26'd1;
      if (auto_vk_cnt == 26'd1) auto_vk <= 1'b1;
    end
  end

  // 按音频采样率、位宽与声道数计算 10 秒快进步长。
  // 48 kHz、16 位双声道对应 192000 字节/秒；位置限制由读取器处理。
  wire [31:0] ff_step_bytes = (wav_channels == 16'd2) ? 32'd1_920_000  // 立体声: 192000 B/s x10s
  : 32'd960_000;  // 单声道:  96000 B/s x10s
  localparam [31:0] FF_STEP_BYTES = 32'd1_920_000;   

`ifndef DISABLE_PLAYER_CTRL
  // ===================== 多曲目控制（切歌） =====================
  // track_ctrl 持有当前曲目号，并按 song_count 取模推进；
  // 同一个 song_idx 既用于"取扇区"，也接到 OSD 显示歌名（见下方 fat32_list.list_idx）。
  wire        track_sel_valid;
  wire [31:0] track_sel_sector;
  wire [ 5:0] play_song_idx;
  wire        auto_en;

  // 视频音源选择状态供歌单事件门控使用。
  reg         vau_tgt;  // 目标源：1 = .VAU, 0 = 歌单

  track_ctrl u_track_ctrl (
    .clk(sd_card_clk),
    .rst_n(rst_n),
    .list_ready(list_ready),
    .song_count(song_count),
    // 歌单按 song_idx 组合给出的本曲起始扇区（给 wav_reader 起播）
    .sel_sector_in(list_sector),
    // 板载 KEY4 长按和扩展下一曲事件送入曲目控制器。
    .next_req((kp_next_song || exp_next_song_evt) && !video_play),
    .prev_req(1'b0),  
    .auto_togg(btn_dbl_a && !video_play),  // key1 双击   = 自动续播 开/关
                            // 播放器结束与坏文件事件反馈给歌单控制，曲目索引统一取模。
    .track_end(wav_track_end && !vau_tgt && !video_play),
    .track_bad(wav_track_bad && !video_play),
    // 输出
    .song_idx(play_song_idx),
    .track_sel_valid(track_sel_valid),
    .track_sel_sector(track_sel_sector),
    .auto_en(auto_en)
  );
`else
  // 切歌功能关闭时，读取器使用自身扫描入口。
  wire        track_sel_valid = 1'b0;
  wire [31:0] track_sel_sector = 32'd0;
  wire [ 5:0] play_song_idx = 6'd0;
  wire        auto_en = 1'b0;
`endif

  // 4 位十六进制 -> 7 段码（共阳：0 点亮）
  function [6:0] hex7;
    input [3:0] v;
    begin
      case (v)
        4'h0: hex7 = 7'b1000000;
        4'h1: hex7 = 7'b1111001;
        4'h2: hex7 = 7'b0100100;
        4'h3: hex7 = 7'b0110000;
        4'h4: hex7 = 7'b0011001;
        4'h5: hex7 = 7'b0010010;
        4'h6: hex7 = 7'b0000010;
        4'h7: hex7 = 7'b1111000;
        4'h8: hex7 = 7'b0000000;
        4'h9: hex7 = 7'b0010000;
        4'hA: hex7 = 7'b0001000;
        4'hB: hex7 = 7'b0000011;
        4'hC: hex7 = 7'b1000110;
        4'hD: hex7 = 7'b0100001;
        4'hE: hex7 = 7'b0000110;
        default: hex7 = 7'b0001110;  // F
      endcase
    end
  endfunction

  reg [6:0] dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d4, dbg_d5;
  // 同一批数码管的第二用途：播放器状态（键盘自检面板关闭时显示）
  reg [6:0] psg_d0, psg_d1, psg_d2, psg_d3, psg_d4, psg_d5;

  reg [15:0] kp_img_s1, kp_img_s2;
  reg [1:0] kp_row_s1, kp_row_s2;
  reg [3:0] kp_col_s1, kp_col_s2;

  // 音频域只读观测通过同步寄存器送入状态显示域。
  localparam [15:0] AU_EMPTY_LIMIT = 16'd20_000;  // @12.288MHz 约 1.6ms
  // 探针组选择决定数码管观测的音频数据阶段。
  wire [1:0] fifo_lvl = (fifo_usedw <  14'd1024) ? 2'd0 :
                          (fifo_usedw <  14'd4096) ? 2'd1 :
                          (fifo_usedw <  14'd6144) ? 2'd2 : 2'd3;



  // img_seen 记录首图已提交事件。
  reg img_seen;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) img_seen <= 1'b0;
    else if (display_valid) img_seen <= 1'b1;
  end
  // 音频数据活动、FIFO 水位和构造器状态用于定位供数与消费阶段。
  // 多位状态同步仅用于观测，不参与功能握手。
  reg  [19:0] wp5_cnt;                       
  wire wp5_recent = (wp5_cnt != 20'd0);
  reg wp5_ever;
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      wp5_cnt  <= 20'd0;
      wp5_ever <= 1'b0;
    end else begin
      if (wav_pcm_valid) begin
        wp5_cnt  <= 20'd500_000;
        wp5_ever <= 1'b1;
      end else if (wp5_cnt != 20'd0) wp5_cnt <= wp5_cnt - 20'd1;
    end
  end
  wire [3:0]  sb_st_audio;                   // 构造器状态码（audio 域，来自实例端口  不用层次引用 ）
  wire sb_drop_audio;  // 请求被丢（audio 域）
  reg [3:0] sb_st_s0, sb_st_s1;  // 构造器状态码 CDC
  reg sb_drop_s0, sb_drop_s1;  // 请求被丢 CDC
  reg lrck_s0, lrck_s1, lrck_d;  // LRCK 活动 CDC
  // 音频域复位在所有音频观测和实例之前定义。
  wire audio_rst;
  assign audio_rst = ~rst_n | ~audio_pll_lock;

  reg lrck_hit;
  // LRCK 活动窗口与音频复位电平的只读观测。
  reg [19:0] lrck_recent_cnt;                
  reg audio_rst_s;
  // 时钟活动、PLL 锁定和复位状态观测。
  reg pll_lock_seen;  // audio_pll_lock 曾经为 1（先见锁定 ）
  reg [21:0] pll_lock_stbl;    
  reg pll_lock_lost;  // 先见 1 之后再变 0 ⇒ 真失锁
  reg [19:0] lrck_win;  // 本窗口 LRCK 边沿计数（500000 拍里数  19 位够 ）
  reg [18:0] lrck_win_t;       
  reg [15:0] lrck_edges_win;  // 上一窗口的边沿数（供显示 ）
  reg [1:0] lrck_grade;  // 档位：3=≈预期 2=偏少 1=很少 0=≈0（时钟死 ）
  reg lrck_lvl_now;  // 当前 LRCK 电平（非粘滞，静止时也能读 ）
  // 将单周期坏文件事件锁存，保证低速数码管扫描能够观察到。
  reg wav_tbad_sticky;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) wav_tbad_sticky <= 1'b0;
    else if (wav_track_bad) wav_tbad_sticky <= 1'b1;
  end
  wire lrck_edge_now = (lrck_s1 != lrck_d);
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      pll_lock_seen <= 1'b0;
      pll_lock_lost <= 1'b0;
      pll_lock_stbl <= 22'd0;
      lrck_win <= 20'd0;
      lrck_win_t <= 19'd0;
      lrck_edges_win <= 16'd0;
      lrck_grade <= 2'd0;
      lrck_lvl_now <= 1'b0;
    end else begin
      // ---- PLL 失锁：先见 1 再变 0（屏蔽上电窗口 ）----
      if (audio_pll_lock) begin
        pll_lock_seen <= 1'b1;
        if (pll_lock_stbl < 22'd4_000_000)
          pll_lock_stbl <= pll_lock_stbl + 22'd1;  
      end else if (pll_lock_seen && (pll_lock_stbl >= 22'd4_000_000)) pll_lock_lost <= 1'b1;
      // ---- LRCK 活计数（5ms 窗口 ）----
      lrck_lvl_now <= lrck_s1;
      if (lrck_edge_now) lrck_win <= lrck_win + 20'd1;
      if (lrck_win_t >= 19'd500_000) begin
        lrck_win_t     <= 19'd0;
        lrck_edges_win <= lrck_win[15:0];
        // 预期 ≈240/窗口（48kHz×5ms ）：240×3/4≈180 记 3；≥1/4 记 2；≥8 记 1；否则 0
        if (lrck_win >= 20'd180) lrck_grade <= 2'd3;
        else if (lrck_win >= 20'd60) lrck_grade <= 2'd2;
        else if (lrck_win >= 20'd8) lrck_grade <= 2'd1;
        else lrck_grade <= 2'd0;  // 时钟死了
        lrck_win <= 20'd0;
      end else lrck_win_t <= lrck_win_t + 19'd1;
    end
  end
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      sb_st_s0 <= 4'd0;
      sb_st_s1 <= 4'd0;
      sb_drop_s0 <= 1'b0;
      sb_drop_s1 <= 1'b0;
      lrck_s0 <= 1'b0;
      lrck_s1 <= 1'b0;
      lrck_d <= 1'b0;
      lrck_hit <= 1'b0;
    end else begin
      sb_st_s0   <= sb_st_audio;
      sb_st_s1   <= sb_st_s0;
      sb_drop_s0 <= sb_drop_audio;
      sb_drop_s1 <= sb_drop_s0;
      lrck_s0    <= audio_i2s_lrck;
      lrck_s1    <= lrck_s0;
      lrck_d     <= lrck_s1;
      if (lrck_s1 != lrck_d) lrck_hit <= 1'b1;  // LRCK 在动（粘滞，保留对比 ）
      if (lrck_s1 != lrck_d) lrck_recent_cnt <= 20'd500_000;
      else if (lrck_recent_cnt != 20'd0) lrck_recent_cnt <= lrck_recent_cnt - 20'd1;
      audio_rst_s <= audio_rst;
    end
  end
  localparam [4:0]  PROBE_GRP      = 5'd4;   // 0=读取器 1=数据流 2=下一层 3=写侧组 4=消费端组
  reg au_sv_hit, au_empty_hit, au_lrck_hit, au_stall_hit;
  // 记录 I2S 接收端曾输出有效样本及有效后欠载状态。
  reg au_valid_hit, au_starve_after_ok;
  reg [15:0] au_empty_cnt;
  reg        au_lrck_d;
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) begin
      au_sv_hit <= 1'b0;
      au_empty_hit <= 1'b0;
      au_lrck_hit <= 1'b0;
      au_stall_hit <= 1'b0;
      au_empty_cnt <= 16'd0;
      au_lrck_d <= 1'b0;
      au_valid_hit <= 1'b0;
      au_starve_after_ok <= 1'b0;
    end else begin
      if (wav_sample_valid) au_sv_hit <= 1'b1;
      if (fifo_empty) begin
        if (au_empty_cnt >= AU_EMPTY_LIMIT) au_empty_hit <= 1'b1;
        else au_empty_cnt <= au_empty_cnt + 16'd1;
      end else begin
        au_empty_cnt <= 16'd0;
      end
      au_lrck_d <= audio_i2s_lrck;
      if (audio_i2s_lrck != au_lrck_d) au_lrck_hit <= 1'b1;
      if (au_empty_hit && !au_sv_hit) au_stall_hit <= 1'b1;
      if (fifo_empty && au_sv_hit && (au_empty_cnt >= AU_EMPTY_LIMIT)) au_starve_after_ok <= 1'b1;
      if (audio_valid) au_valid_hit <= 1'b1;
    end
  end
  // 粘滞位是稳定电平 => 2 级同步足够安全（不是多比特总线，不会撕裂 ）
  reg [5:0] au_s0, au_s1;
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      au_s0 <= 6'd0;
      au_s1 <= 6'd0;
    end else begin
      au_s0 <= {
        au_starve_after_ok, au_valid_hit, au_sv_hit, au_empty_hit, au_lrck_hit, au_stall_hit
      };
      au_s1 <= au_s0;
    end
  end
  // 声道格式决定样本字节配对；状态镜像仅用于观测格式与数据流。
  reg ch_not2_hit;  // [sd 域] wav_ready 时曾经解析出 wav_channels != 2
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) ch_not2_hit <= 1'b0;
    else if (wav_ready && (wav_channels != 16'd2)) ch_not2_hit <= 1'b1;
  end
  reg stereo_o0, stereo_o1;  // [audio 域 stereo] 2FF 同步到 clk 域（单比特，安全 ）
  // 键盘与音频格式的慢状态通过同步寄存器送入显示域。
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      kp_img_s1 <= 16'd0;
      kp_img_s2 <= 16'd0;
      kp_row_s1 <= 2'd0;
      kp_row_s2 <= 2'd0;
      kp_col_s1 <= 4'hF;
      kp_col_s2 <= 4'hF;
      dbg_d0 <= 7'b1111111;
      dbg_d1 <= 7'b1111111;
      dbg_d2 <= 7'b1111111;
      dbg_d3 <= 7'b1111111;
      dbg_d4 <= 7'b1111111;
      dbg_d5 <= 7'b1111111;
      psg_d0 <= 7'b1111111;
      psg_d1 <= 7'b1111111;
      psg_d2 <= 7'b1111111;
      psg_d3 <= 7'b1111111;
      psg_d4 <= 7'b1111111;
      psg_d5 <= 7'b1111111;
    end else begin
      kp_img_s1 <= kp_raw_image;
      kp_img_s2 <= kp_img_s1;
      kp_row_s1 <= kp_row_now;
      kp_row_s2 <= kp_row_s1;
      kp_col_s1 <= kp_col_now;
      kp_col_s2 <= kp_col_s1;

      // 数码管调试视图：读取地址、读取器状态和事件标志。
      if (PROBE_GRP == 5'd1) begin
        // 音频写侧数据流观测。
        dbg_d0 <= hex7({2'b00, au_s1[0], wav_dbg_dataok});
        dbg_d1 <= hex7(
            {2'b00, au_s1[5], au_s1[1]}
        );  // {出过样本后仍欠载(真问题), FIFO曾长时间欠载}
        dbg_d2 <= hex7({2'b00, ch_not2_hit, stereo_o1});
        dbg_d3 <= hex7(
            {1'b0, wav_dbg_state}
        );  
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd20) begin
        // 音频请求与读取器状态观测。
        dbg_d0 <= hex7({3'b000, wav_dbg_seek_drain});
        dbg_d1 <= hex7(wav_sd_sec_read_addr[15:12]);
        dbg_d2 <= hex7(wav_sd_sec_read_addr[11:8]);
        dbg_d3 <= hex7(wav_sd_sec_read_addr[7:4]);
        dbg_d4 <= hex7(wav_sd_sec_read_addr[3:0]);
        dbg_d5 <= hex7({2'b00, wav_dbg_seek_drain, wav_sd_sec_read_addr[0]});
      end else if (PROBE_GRP == 5'd19) begin
        // SD 请求、命令错误及供数状态观测。
        dbg_d0 <= hex7({3'b000, wav_dbg_sd_cmd_err});
        dbg_d1 <= (video_play ? vau_fault_seg : hex7({2'b00, wav_dbg_sd_state[4:3]}));
        dbg_d2 <= hex7({1'b0, wav_dbg_sd_state[2:0]});
        dbg_d3 <= hex7({3'b000, wav_sd_sec_read});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd18) begin
        // PCM 输出准入条件观测。
        dbg_d0 <= hex7({3'b000, wav_dbg_seek_drain});
        dbg_d1 <= (w18_resync_cnt >= 12'd1) ? hex7(
            4'd3
        ) : hex7(
            4'd0
        );  // 本窗口是否发生过 resync
        dbg_d2 <= hex7({2'b00, w17_c_grade});
        dbg_d3 <= hex7({3'b000, w18_pcnt_chg_win});
        dbg_d4 <= hex7(w18_resync_cnt[7:4]);
        dbg_d5 <= hex7(w18_resync_cnt[3:0]);
      end else if (PROBE_GRP == 5'd17) begin
        // 按窗口统计 PCM 与 SD 事件，避免将突发传输间隙误读为永久停流。
        dbg_d0 <= hex7({2'b00, w17_a_grade});
        dbg_d1 <= hex7({2'b00, w17_b_grade});
        dbg_d2 <= hex7({2'b00, w17_c_grade});
        dbg_d3 <= hex7({2'b00, w17_d_grade});
        dbg_d4 <= hex7(w17_a_cnt[11:8]);
        dbg_d5 <= hex7(w17_a_cnt[7:4]);
      end else if (PROBE_GRP == 5'd16) begin
        // 文件位置与头部解析阶段观测。
        dbg_d0 <= hex7({2'b00, wav_dbg_hdr_phase});
        dbg_d1 <= hex7({2'b00, wav_dbg_fbcnt_frz});
        dbg_d2 <= hex7({2'b00, wav_dbg_sdvalid_frz});
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_pcm_byte_cnt[7:4]);
        dbg_d5 <= hex7(wav_pcm_byte_cnt[3:0]);
      end else if (PROBE_GRP == 5'd15) begin
        // 分别观测数据变化和写使能活动，区分恒定样本与停止写入。
        dbg_d0 <= hex7({2'b00, wav_dbg_wdata_frz});
        dbg_d1 <= hex7({2'b00, wav_dbg_vldfrz_grade});
        dbg_d2 <= hex7({3'b000, wav_dbg_latch_cond});
        dbg_d3 <= hex7({2'b00, wav_dbg_vldfrz_grade});
        dbg_d4 <= hex7(wav_pcm_byte_cnt[7:4]);
        dbg_d5 <= hex7(wav_pcm_byte_cnt[3:0]);
      end else if (PROBE_GRP == 5'd14) begin
        // 活动年龄按计数阈值分档，供数码管状态显示。
        dbg_d0 <= hex7({2'b00, wav_dbg_rddata_frz});
        dbg_d1 <= hex7({2'b00, wav_dbg_wdata_frz});
        dbg_d2 <= hex7({2'b00, wav_dbg_rden_frz});
        dbg_d3 <= hex7({2'b00, wav_dbg_bytelo_frz});
        dbg_d4 <= hex7(wav_dbg_rddata_chg[7:4]);
        dbg_d5 <= hex7(wav_dbg_rddata_chg[3:0]);
      end else if (PROBE_GRP == 5'd13) begin
        // 输入样本活动与锁存事件观测。
        dbg_d0 <= hex7({2'b00, wav_dbg_in_chg_grade});
        dbg_d1 <= hex7({2'b00, wav_dbg_lat_grade});
        dbg_d2 <= hex7({3'b000, wav_dbg_chg_last});
        dbg_d3 <= hex7(wav_dbg_in_chg_cnt[11:8]);
        dbg_d4 <= hex7(wav_dbg_in_chg_cnt[7:4]);
        dbg_d5 <= hex7(wav_dbg_in_chg_cnt[3:0]);
      end else if (PROBE_GRP == 5'd12) begin
        // 供数脉冲及消费活动观测。
        dbg_d0 <= hex7({2'b00, wav_dbg_vld_grade});
        dbg_d1 <= hex7({2'b00, wav_dbg_req_grade});
        dbg_d2 <= hex7({2'b00, wav_dbg_held_grade});
        dbg_d3 <= hex7(wav_dbg_vld_cnt[11:8]);
        dbg_d4 <= hex7(wav_dbg_vld_cnt[7:4]);
        dbg_d5 <= hex7(wav_dbg_vld_cnt[3:0]);
      end else if (PROBE_GRP == 5'd11) begin
        // 每 1024 音频帧统计数据变化次数。
        dbg_d0 <= hex7({2'b00, wav_dbg_chg_grade});
        dbg_d1 <= hex7({3'b000, wav_dbg_chg_last});
        dbg_d2 <= hex7(wav_dbg_chg_cnt[11:8]);
        dbg_d3 <= hex7(wav_dbg_chg_cnt[7:4]);
        dbg_d4 <= hex7({2'b00, wav_dbg_chg_cnt[3:0]});
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd10) begin
        // 音频时钟与数据活动的只读观测。
        dbg_d0 <= hex7({2'b00, lrck_grade});
        dbg_d1 <= hex7({1'b0, pll_lock_lost, lrck_lvl_now, audio_rst_s});
        dbg_d2 <= hex7(lrck_edges_win[3:0]);
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd9) begin
        // LRCK、PLL 和复位的只读观测。
        dbg_d0 <= hex7(
            {1'b0, audio_rst_s, pll_lock_lost, (lrck_grade == 2'd0)}
        );  // 第4位改用【活计数=0】⇒ 时钟死
        dbg_d1 <= hex7({1'b0, wav_dbg_state});
        dbg_d2 <= hex7({2'b00, fifo_lvl});
        dbg_d3 <= hex7({1'b0, sb_st_s1[2:0]});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd8) begin
        // FIFO 及音频消费侧的状态观测。
        dbg_d0 <= hex7({1'b0, wav_dbg_rep_long, wav_dbg_rep_grade});
        dbg_d1 <= hex7(wav_dbg_same_frames);
        dbg_d2 <= hex7({2'b00, fifo_lvl});
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd7) begin
        // 观察样本请求到 FIFO 读、FIFO 读到有效样本的延迟阶段。
        dbg_d0 <= hex7({2'b00, wav_dbg_empty_stuck, fifo_empty});
        dbg_d1 <= hex7(wav_dbg_dwell_state);
        dbg_d2 <= hex7({fifo_lvl, wav_dbg_dwell_grade});
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd6) begin
        dbg_d0 <= hex7({2'b00, wav_dbg_lat_req2rden});
        dbg_d1 <= hex7({2'b00, wav_dbg_lat_rden2v});
        dbg_d2 <= hex7({1'b0, wav_dbg_req_seen_hi, 1'b0, wav_dbg_ack_lat[0]});
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd5) begin
        dbg_d0 <= hex7({2'b00, ps_scr});
        dbg_d1 <= hex7({2'b00, ps_scr});
        dbg_d2 <= hex7(ps_show[15:12]);
        dbg_d3 <= hex7(ps_show[11:8]);
        dbg_d4 <= hex7(ps_show[7:4]);
        dbg_d5 <= hex7(ps_show[3:0]);
      end else if (PROBE_GRP == 5'd4) begin
        // 音频 FIFO 写入与样本构造器状态观测。
        dbg_d0 <= hex7(
            {3'b000, wav_dbg_pcm_odd}
        );  
        dbg_d1 <= hex7({sb_st_s1[2:0], wp5_recent});
        dbg_d2 <= hex7(
            {wav_dbg_req_lost_now, wav_dbg_req_lost, wav_dbg_ack_lat}
        );  
        dbg_d3 <= hex7(
            {1'b0, wav_dbg_state}
        );  
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd3) begin
        // 音频写入事件和 FIFO 水位观测。
        dbg_d0 <= hex7({2'b00, wav_dbg_wp_seen, wav_dbg_wp_recent});
        dbg_d1 <= hex7({2'b00, fifo_lvl});
        dbg_d2 <= hex7({2'b00, wav_dbg_wp_gate, wav_sd_sec_read});
        dbg_d3 <= hex7(
            {1'b0, wav_dbg_state}
        );  
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd2) begin
        // I2S 接收端与 HDMI 音频输入的活动观测。
        dbg_d0 <= hex7({2'b00, au_s1[4], au_s1[2]});
        dbg_d1 <= hex7({2'b00, au_s1[3], au_s1[1]});
        dbg_d2 <= hex7({2'b00, au_s1[5], au_s1[1]});
        dbg_d3 <= hex7(
            {1'b0, wav_dbg_state}
        );  
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else begin
        dbg_d0 <= hex7(wav_sd_sec_read_addr[11:8]);  // 地址 [11:8]
        dbg_d1 <= hex7(wav_sd_sec_read_addr[7:4]);  // 地址 [7:4]
        dbg_d2 <= hex7(wav_sd_sec_read_addr[3:0]);  // 地址 [3:0]
        dbg_d3 <= hex7({1'b0, wav_dbg_state});  // 读取器 FSM 状态码（正常 3）
        dbg_d4 <= hex7(
            wav_dbg_fp[3:0]
        );  // 指纹低 4 位：bit0 resync|bit1 rd_wd超时|bit2 放空超时|bit3 进过放空
        dbg_d5 <= hex7(
            wav_dbg_fp[7:4]
        );  // 指纹高 4 位：bit4 下降沿|bit5 seek后上升沿|bit6 seek后rd_cnt清|bit7 锁存时rd_cnt!=0
      end

      // 板载六位数码管显示播放状态；调试视图由编译参数选择。
      psg_d0 <= hex7(play_song_idx[3:0]);
      psg_d1 <= hex7(song_count[3:0]);
      psg_d2 <= auto_en ? 7'b0001000 : 7'b1111111;  // 'A'
      psg_d3 <= pause ? 7'b0011000 : 7'b1111111;  // 'P'
      psg_d4 <= btn_long_a ? 7'b0001110 : 7'b1111111;  // 'F'
    end
  end

  // 全局复位由板载复位输入控制；音频 PLL 未锁定只复位音频域。


  // 音频域复位：音频 PLL 未锁定时只复位音频链路（时钟稳定后才播放）


  // SD、SDRAM 与视频时钟生成。
  sys_pll sys_pll_m0 (
    .refclk  (clk),
    .clk0_out(sd_card_clk),
    .clk1_out(ext_mem_clk),
    .clk2_out(ext_mem_clk_sft),
    .reset   (1'b0)
  );

  video_pll video_pll_m0 (
    .refclk  (audio_video_ref75),
    .clk0_out(video_clk),
    .clk1_out(hdmi_5x_clk),
    .reset   (1'b0)
  );

  // 音频 PLL 提供 12.288 MHz 主时钟。
  PLL_HDMI_AUDIO u_audio_pll (
    .refclk  (clk),
    .reset   (1'b0),
    .extlock (audio_pll_lock),
    .clk0_out(audio_video_ref75),
    .clk1_out(),
    .clk2_out(audio_mclk)
  );

  // mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
  always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all) frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish) frame_write_toggle_mem <= ~frame_write_toggle_mem;
  end

  // WAV 扫描启动控制。
  reg [23:0] wav_scan_cnt;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      wav_scan_cnt   <= 24'd0;
      wav_scan_start <= 1'b0;
    end else begin
      wav_scan_start <= 1'b0;
      if (display_valid && wav_scan_cnt < 24'h800000) begin
        wav_scan_cnt <= wav_scan_cnt + 24'd1;
        // 有有效歌单时使用目录选曲；仅在歌单不可用时允许读取器扫描。
        if ((wav_scan_cnt == 24'd1000) && !(list_ready && (song_count != 6'd0)))  
          wav_scan_start <= 1'b1;
      end
    end
  end

  // 首图提交前锁存选曲事件，显示有效后再启动音频，避免丢失单周期请求。
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
  // 视频优先选择专用 VAU 伴音；缺少专用文件时使用兼容音源。
  reg vau_sector_nz;
  // Prefer the dedicated video soundtrack; WAV is a fallback.
  wire [31:0] vau_sel_sector = (vau_sector != 32'd0) ? vau_sector : song5_sector;
  // 音源有效标志预先寄存，缩短扇区选择到切换状态机的组合路径。
  reg vau_src_ok_r;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) vau_src_ok_r <= 1'b0;
    else
      vau_src_ok_r <= vau_tgt ? ((song5_sector != 32'd0) || (vau_sector != 32'd0)) : (song_count != 6'd0);
  end
  wire vau_src_ok = vau_src_ok_r;
  // 预先寄存专用伴音是否存在，供选择和状态显示使用。
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

  // 视频期间屏蔽歌单自动切歌，保证视频与伴音的配对关系。
  wire       wav_track_sel = vau_fire ? 1'b1
                         : (video_play ? 1'b0
                                       : (display_valid ? (track_sel_valid | sel_pending)
                                                        : (sel_timeout & sel_pending)));
  localparam       VAS_SECTOR_TEST = 1'b0;   // 【已复原】0 = 正常切 VAU；1 = 二分实验用（切当前歌）
  // 音源选择时锁存目标扇区；读取器采样完成之前地址保持稳定。
  reg [31:0] wav_track_sector_l;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) wav_track_sector_l <= 32'd0;
    // vau_fire is used on BOTH mode edges. Choose the destination mode;
    // exiting video must select the current playlist song, not VAU again.
    else if (vau_fire) wav_track_sector_l <= vau_tgt ? vau_sel_sector : track_sel_sector;
    else if (wav_track_sel) wav_track_sector_l <= track_sel_sector;  // 歌单切歌
  end
  wire [31:0] wav_track_sector = wav_track_sector_l;
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

  // 媒体读取适配层统一音源选择、解码和 PCM 输出接口。
  wire wav_sd_grant;
  // 切轨排空以实际样本消费和 FIFO 状态为依据，
  // 允许 FIFO 已空而样本构造器仍等待数据时结束排空，避免相互等待。
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
  // 淡出完成后再提交切轨或定位命令，避免截断正在输出的样本。
  wire fade_select, fade_seek, fade_pause, fade_mute_req, audio_transition_busy, fade_timeout;
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
  // 当前音频通路启用 PCM 与 IMA，QOA 解码在此配置中关闭。
  media_player_shim #(.ENABLE_QOA(0)) u_wav_reader (
    .file_base_lba(fs_audio_base),
    .sd_error(fs_error && fs_error_owner == 1),
    .clk(sd_card_clk),
    .rst(rst_all),
    .scan_start(wav_scan_start),
    // 读取器扫描限于 FAT32 数据区域，并受扫描预算约束。
    .scan_start_sector(fat_data_start),
    .scan_max_sector(32'd8192),
    .sd_init_done(sd_init_done),
    .wav_ready(wav_ready),
    .dbg_pcm_start_odd(wav_dbg_pcm_odd),
    .dbg_pcm_sum32(wav_dbg_pcm_sum32),
    .dbg_pcm_n32(wav_dbg_pcm_n32),
    .dbg_hdr_phase(wav_dbg_hdr_phase),
    .dbg_fbcnt_frz(wav_dbg_fbcnt_frz),
    .sample_rate(wav_sample_rate),
    .channels(wav_channels),
    .bit_depth(wav_bit_depth),
    .data_size(wav_data_size),
    .pcm_out_cnt(wav_pcm_byte_cnt),
    .sd_sec_read(wav_sd_sec_read),
    .sd_sec_read_addr(wav_sd_sec_read_addr),
    .sd_sec_read_data(wav_d_q),
    .sd_sec_read_data_valid(wav_dv_q),
    .sd_sec_read_end(wav_e_q),
    .fifo_almost_full(fifo_almost_full),
    .fifo_drained(audio_drained_sync[1]),
    .sd_grant(wav_sd_grant),
    .pause(fade_pause),
    // 长按 key1 -> 快进 10 秒（button_ctrl 产生周期性脉冲）
    .seek(fade_seek),
    .step_bytes(ff_step_bytes),   
    // 歌单与视频模式共用音源切换入口，模式选择决定目标扇区。
    .track_sel(fade_select),
    .track_sel_sector(fade_sector),
    .track_end(wav_track_end),
    .track_bad(wav_track_bad),
    .pcm_valid(wav_pcm_valid),
    .pcm_data(wav_pcm_data),
    // 读取器观测端口只连接状态显示。
    .dbg_state(wav_dbg_state),
    .dbg_gate_open(wav_dbg_gate_open),
    .dbg_fp(wav_dbg_fp),
    .dbg_silent_hit(wav_dbg_silent),
    .dbg_posbad_hit(wav_dbg_posbad),
    .dbg_seek_data_ok(wav_dbg_dataok),
    .dbg_wp_pcm_seen(wav_dbg_wp_seen),
    .dbg_wp_pcm_recent(wav_dbg_wp_recent),
    .dbg_wp_gate_stuck(wav_dbg_wp_gate),
    .dbg_seek_drain(wav_dbg_seek_drain),
    .dbg_resync_pulse(wav_dbg_resync_pulse)
  );

  // 矩阵键盘接口在当前配置中关闭；板载与扩展按键独立接入。
  localparam KP_ON = 1'b0;

  generate
    if (KP_ON) begin : g_kp
      keypad_scan u_keypad_scan (
        .clk        (sd_card_clk),
        .rst_n      (rst_n),
        .col        (),
        .row        (),              
        .key_code   (key_code),
        .key_press  (key_press),
        .raw_image  (kp_raw_image),
        .row_now    (kp_row_now),
        .col_now    (kp_col_now),
        .frame_cnt  (kp_frame_cnt),
        .hit_row_lat(hit_row_lat),
        .hit_col_lat(hit_col_lat),
        .hit_key_lat(hit_key_lat)
      );
    end else begin : g_nokp
      // 没有键盘：所有键盘事件为 0，键位图/调试量为 0
      assign key_code     = 4'd0;
      assign key_press    = 1'b0;
      assign kp_raw_image = 16'd0;
      assign kp_row_now   = 2'd0;
      assign kp_col_now   = 4'd0;
      assign kp_frame_cnt = 16'd0;
      assign hit_row_lat  = 2'd0;
      assign hit_col_lat  = 4'd0;
      assign hit_key_lat  = 4'd0;
    end
  endgenerate

  // 播放器控制（播放/暂停 + 音量 + 模式，sd_card_clk 域）
  player_ctrl u_player_ctrl (
    .clk      (sd_card_clk),
    .rst_n    (rst_n),
    .key_code (key_code),
    .key_press(key_press),
    .pause    (pause),
    .volume   (volume),
    .mode     (mode),
    .song_idx (song_idx),
    .btn_pause(btn_music_pause_evt)
  );

  // 板载按键的播放/暂停事件接进 player_ctrl（与矩阵键盘 A 键等效）
  // 见上方 u_button_ctrl 的实例化：btn_pause_evt = key1 短按

  // 播放状态：PCM 字节数 -> 总时长/当前时间/进度（sd_card_clk 域）
  playback_status u_playback_status (
    .clk        (sd_card_clk),
    .rst        (rst_all),
    .wav_ready  (wav_ready),
    .pcm_out_cnt(wav_pcm_byte_cnt),
    .data_size  (wav_data_size),
    .sample_rate(wav_sample_rate),
    .channels   (wav_channels),
    .bit_depth  (wav_bit_depth),
    .tot_sec    (tot_sec),
    .cur_sec    (cur_sec),
    .progress   (progress)
  );

  // PCM 字节经双时钟 FIFO 从 sd_card_clk 域交接到 audio_mclk 域。
  async_fifo #(
    .DATA_WIDTH        (8),
    // FIFO 容量 8192 字节；48 kHz、16 位双声道满储备约 42.67 ms。
    // 水位参与共享读卡仲裁，吸收图片突发读取造成的供数间隙。
    .ADDR_WIDTH        (13),    // DEPTH = 2^13 = 8192
    .DEPTH             (8192),
    .ALMOST_FULL_THRESH(6144)   // 预留 2048 B(=4 个扇区) 给 in-flight 扇区
  ) u_async_fifo (
    .wr_clk(sd_card_clk),
    .wr_rst(rst_all),
    .wr_en(wav_pcm_valid),
    .wr_data(wav_pcm_data),  
    .full(fifo_full),
    .almost_full(fifo_almost_full),
    .wr_usedw(fifo_usedw),
    .rd_clk(audio_mclk),
    .rd_rst(rst_all),
    .rd_en(fifo_rd_en),
    .rd_data(fifo_rd_data),
    .empty(fifo_empty)
  );

  // 字节流 -> 24 位样本（audio_mclk 域）
  // stereo 标志跨域同步：wav_channels(sd_card_clk) -> audio_mclk
  wire stereo_sd = (wav_channels == 16'd2);
  reg stereo_s0, stereo_s1;
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) begin
      stereo_s0 <= 1'b0;
      stereo_s1 <= 1'b0;
    end else begin
      stereo_s0 <= stereo_sd;
      stereo_s1 <= stereo_s0;
    end
  end
  wire stereo = stereo_s1;
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
      stereo_o0 <= 1'b0;
      stereo_o1 <= 1'b0;
    end else begin
      stereo_o0 <= stereo;
      stereo_o1 <= stereo_o0;
    end
  end

  // Reset byte pairing only when the reader has drained the old stream and
  // committed the new format/position. Resetting at track_sel discards a low
  // byte already removed from the FIFO, leaving the remaining stream odd.
  // format_settle in wav_player holds new PCM for 64 SD clocks, allowing this
  // toggle and the channel count to cross into the audio clock domain first.
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
    .sample_valid(wav_sample_valid),          
    .sample_left(wav_sample_left),
    .sample_right(wav_sample_right),
    // 音频消费状态通过显式端口连接到观测逻辑。
    .dbg_st(sb_st_audio),
    .dbg_req_drop(sb_drop_audio),
    .dbg_req_drop_recent(wav_dbg_drop_recent),
    .dbg_lat_req2rden(wav_dbg_lat_req2rden),
    .dbg_lat_rden2v(wav_dbg_lat_rden2v),
    .dbg_req_seen_hi(wav_dbg_req_seen_hi),
    .dbg_dwell_state(wav_dbg_dwell_state),
    .dbg_dwell_grade(wav_dbg_dwell_grade),
    .dbg_empty_stuck(wav_dbg_empty_stuck),
    .dbg_pair_bad(),
    .dbg_rddata_frz(wav_dbg_rddata_frz),
    .dbg_bytelo_frz(wav_dbg_bytelo_frz),
    .dbg_rden_frz(wav_dbg_rden_frz),
    .dbg_rddata_chg(wav_dbg_rddata_chg),
    .dbg_req_lost(wav_dbg_req_lost),
    .dbg_req_lost_now(wav_dbg_req_lost_now),
    .dbg_ack_lat(wav_dbg_ack_lat)
  );

  // 音量跨时钟域同步（sd_card_clk -> audio_mclk，慢信号两级同步）
  reg [4:0] volume_s0, volume_s1;
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) begin
      volume_s0 <= 5'd31;
      volume_s1 <= 5'd31;
    end else begin
      volume_s0 <= volume;
      volume_s1 <= volume_s0;
    end
  end

  // 音量缩放（纯组合：24bit 有符号 × 5bit 音量）
  wire [23:0] vol_sample_left, vol_sample_right;
  // 音量状态观测使用同步后的音量值。
  always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) begin
      vol_zero_hit <= 1'b0;
      vol_zero_now <= 1'b0;
      vol_chg_hit <= 1'b0;
      vol_chg_cnt <= 20'd0;
      vol_chg_recent_a <= 1'b0;
      vol_prev <= 5'd31;
    end else begin
      vol_zero_now <= (volume_s1 == 5'd0);
      if (volume_s1 == 5'd0) vol_zero_hit <= 1'b1;
      // 记录音量变化事件。
      vol_prev <= volume_s1;
      if (volume_s1 != vol_prev) begin
        vol_chg_hit      <= 1'b1;
        vol_chg_cnt      <= 20'd1_000_000;  // ~81ms @12.288MHz
        vol_chg_recent_a <= 1'b1;
      end else begin
        if (vol_chg_cnt != 20'd0) vol_chg_cnt <= vol_chg_cnt - 20'd1;
        if (vol_chg_cnt == 20'd1) vol_chg_recent_a <= 1'b0;
      end
    end
  end

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

  // PCM 转 I2S；样本消费受实际显示帧额度控制。
  // 缓冲等待期间保持音频时钟运行，音源切换时排空旧数据。
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
  i2s_transmitter #(.MAX_BUDGET_HOLD(2)) u_i2s_transmitter (
    .hold_budget_gap(av_buffering && !av_drain_old_stream),
    .clk             (audio_mclk),
    .rst             (audio_rst),
    .mute            (av_mute_sync[1]),
    .flush           (sb_rst_pulse),
    .sample_left     (av_mute_sync[1] ? 24'd0 : vol_sample_left),
    .sample_right    (av_mute_sync[1] ? 24'd0 : vol_sample_right),
    .sample_req      (wav_sample_req),
    // 样本构造器返回接受脉冲，发送端保持请求直到样本被接受。
    .sample_valid    (wav_sample_valid || fade_stall_tick),
    .dbg_req_held    (wav_dbg_req_held),
    .dbg_ack_seen    (wav_dbg_ack_seen),
    .dbg_req_stall   (wav_dbg_req_stall),
    .dbg_rep_grade   (wav_dbg_rep_grade),
    .dbg_rep_long    (wav_dbg_rep_long),
    .dbg_same_frames (wav_dbg_same_frames),
    .dbg_chg_grade   (wav_dbg_chg_grade),
    .dbg_chg_cnt     (wav_dbg_chg_cnt),
    .dbg_chg_last    (wav_dbg_chg_last),
    .dbg_vld_grade   (wav_dbg_vld_grade),
    .dbg_req_grade   (wav_dbg_req_grade),
    .dbg_held_grade  (wav_dbg_held_grade),
    .dbg_vld_cnt     (wav_dbg_vld_cnt),
    .dbg_req_cnt     (wav_dbg_req_cnt),
    .dbg_in_chg_grade(wav_dbg_in_chg_grade),
    .dbg_lat_grade   (wav_dbg_lat_grade),
    .dbg_in_chg_cnt  (wav_dbg_in_chg_cnt),
    .dbg_lat_cnt     (wav_dbg_lat_cnt),
    .i2s_bclk        (audio_i2s_bclk),
    .i2s_lrck        (audio_i2s_lrck),
    .i2s_dout        (audio_i2s_dout)
  );



  // 图片控制负责加载、预读、缓冲区提交与轮播计时。
  // 按键经分类后分别接入音乐和图片控制，避免一次手势触发两条通路。
  sd_card_bmp #(
    .STREAM_IMAGES(1),
    .ENABLE_ZOOM      (1),
    .CLK_FREQ_HZ      (SD_CORE_HZ),
    .SCAN_MAX_SECTOR  (32'd131071),
    // 挂载目录提供启动图片信息；运行期图片列表由动态目录游标按需遍历。
    .SCAN_TARGET_COUNT(3'd4),
    // 图片读取等待 FAT32 挂载就绪，目录游标按簇链定位有效图片。
    .SCAN_INIT_BUDGET (32'd60000)
  ) sd_card_bmp_m0 (
    .zoom_small     (exp_sw_level[4]),
    .stream_valid(iter_valid),.stream_lba(iter_lba),
    .stream_consume(iter_consume),.stream_failed(iter_failed),
    .directory_count(directory_image_count),
    .directory0     (directory_image0),
    .directory1     (directory_image1),
    .directory2     (directory_image2),
    .directory3     (directory_image3),
    .directory4     (directory_image4),
    .directory5     (directory_image5),
    .directory6     (directory_image6),
    .directory7     (directory_image7),

    .clk            (sd_card_clk),
    .rst            (rst_all),
    // 板载图片短按与扩展 KEY2 均接入低有效下一张请求。
    .key_next       (key3_tap_n & exp_nextimg_key_n),  // B1(KEY3)短按 / 扩展板 KEY2
    // 板载 KEY4 使用短按虚拟事件；扩展 KEY4 使用消抖后的轮播开关电平。
    .key_auto       (auto_vk & exp_auto_key_n),
    // 轮播周期由扩展拨码选择；重置事件重新建立计时基准。
    .period_code    (exp_period_code),
    .auto_period_sec(exp_period_sec),
    .period_reseed  (kp_period_step),
    .cfg_boundary_o (exp_cfg_boundary),
    .state_code     (state_code),
    .bmp_width      (16'd640),
    .bmp_height     (16'd480),
    .img_h_o        (img_h_img),
    .source_top_down(img_top_down),
    .display_valid  (display_valid),
    .img_loading    (img_loading),

    // 图片扫描数据区地址在挂载完成后有效。
    .file_base_lba     (fs_image_base),
    .sd_error          (fs_error && fs_error_owner == 0),
    .scan_start_sector (fat_data_start),
    .scan_start_sector2(img_scan_sector_lat),
    .scan_start2       (1'b0),
    .scan_limited      (bg_scan_limited),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx      (img_write_buf_idx),
    .disp_buf_idx       (img_disp_buf_idx),

    // 淡出请求与完成通过两段式握手交接；转场忙状态阻止重复装载。
    .switch_lock        (fade_switch_lock),
    .vid_lock           (vid_lock),
    .fade_req_toggle    (fade_req_toggle),
    .fade_done_pulse    (fade_done_pulse),
    // 首图超时提交状态。
    .firstimg_fallback_o(firstimg_fb_seen),
    // 首图提交条件的超时快照。
    .firstimg_diag_o    (firstimg_diag),

    .write_req        (img_write_req),
    .write_req_ack    (sd_card_write_req_ack),
    .write_almost_full(image_source_high),
    .write_en         (img_write_en),
    .write_data       (img_write_data),

    // FAT32 挂载就绪后才允许读图，防止使用尚未有效的数据区地址。
    .sd_init_done          (sd_init_done & list_ready),
    .sd_sec_read           (img_sd_sec_read),
    .sd_sec_read_addr      (img_sd_sec_read_addr),
    .sd_sec_read_data      (img_data_q),
    .sd_sec_read_data_valid(img_valid_q),
    .sd_sec_read_end       (img_end_q),
    .sd_grant              (img_grant_q),
    // 图片扫描进度反馈用于后台扫描控制。
    .scan_sector           (img_scan_sector),
    .found_count_o         (img_found_count),
    .scan_done_o           (img_scan_done_fb),
    .auto_mode_o           (img_auto_mode),              // 轮播档位（显示用，0=关）
    // 图片轮播开关状态反馈。
    .auto_on_o             (img_auto_on)

  );

  // bmp_read 的扫描位置（phase B 的起点要用）
  // sd_card_bmp 上引出的扫描反馈

  // ---- phase B（后台全范围扫描）控制 ----
  //   bg_scan_limited : 1 = phase A（受限，预算封顶）；0 = phase B（全范围）
  //   bg_scan_start2  : phase B 的 1 拍发起脉冲
  //   bg_kicked       : 只发起一次
  //   bg_wait_cnt     : 首图迟迟不提交时的退化计时（见下）
  reg        bg_kicked;
  reg [31:0] bg_wait_cnt;
  // 后台扫描等首图提交及图片通路空闲后启动，避免与首图加载竞争。
  localparam [31:0] BG_FIRSTIMG_WAIT = 32'd272727273;  // 3s，按SD_CORE_HZ换算

  // 图片优先级窗口计数。
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
    end else begin
    end
  end

  // phase A 结束时把扫描位置快照下来：进 ST_IDLE 后 scan_sector_o 会保持，
  //   但为了不依赖它的保持行为，这里显式锁存一次。
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      img_scan_sector_lat <= 32'd0;
    end else if (img_scan_done_fb) begin
      img_scan_sector_lat <= img_scan_sector;
    end
  end

  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      bg_scan_start2  <= 1'b0;
      bg_scan_limited <= 1'b1;  // 上电默认先跑 phase A（受限）
      bg_kicked       <= 1'b0;
      bg_wait_cnt     <= 32'd0;
    end else begin
      bg_scan_start2 <= 1'b0;
      // Resume an interrupted background scan after the requested image.
      if (bg_kicked && img_loading && (img_found_count < 3'd4)) bg_kicked <= 1'b0;
      // 后台扫描由启用参数和首图状态共同控制。
      if (!bg_kicked && img_scan_done_fb && (img_found_count < 3'd4)) begin
        if (!img_loading && display_valid) begin
          // 正常路径：首图已经在屏上 -> 后台补齐剩余图片
          bg_scan_start2  <= 1'b1;
          bg_scan_limited <= 1'b0;  // 切到全范围
          bg_kicked       <= 1'b1;
        end else if (img_found_count == 3'd0) begin
          // 退化 (a)：phase A 一张都没找到 -> 没有首图可加载，立刻继续全范围扫
          bg_scan_start2  <= 1'b1;
          bg_scan_limited <= 1'b0;
          bg_kicked       <= 1'b1;
        end else if (!img_loading && (bg_wait_cnt >= BG_FIRSTIMG_WAIT)) begin
          // 退化 (b)：有图但首图超时仍未提交 -> 仍然发起，绝不永不补扫
          bg_scan_start2  <= 1'b1;
          bg_scan_limited <= 1'b0;
          bg_kicked       <= 1'b1;
        end else begin
          bg_wait_cnt <= bg_wait_cnt + 32'd1;
        end
      end
    end
  end

  // ===================== SD 卡扇区读仲裁器（音频优先） =====================
  // Water-level preference may lag one SD clock; sector ownership never changes
  // mid-transfer. Registering it breaks the Gray decode -> arbitration path.
  reg image_priority_q;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) image_priority_q <= 1'b1;
    else image_priority_q <= ~display_valid | (img_loading & (fifo_usedw >= 14'd4096));
  end
  // FIFO 水位与 SD 状态同属 sd_card_clk 域。4096 字节 PCM 储备
  // 对应 48 kHz、16 位双声道约 21.33 ms；低水位时立即恢复音频请求准入。
  reg defer_audio_prefetch;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) defer_audio_prefetch <= 0;
    else defer_audio_prefetch <= video_engine_play && av_started &&
        (fifo_usedw >= 14'd4096) &&
        (wav_dbg_sd_state == 19 || wav_dbg_sd_state == 20 || wav_dbg_sd_state == 23);
  end
  sd_arbiter #(.PREFETCH_AWARE(1), .MAX_DEFER_CYCLES(1400000)) u_sd_arbiter (
    .defer_audio(defer_audio_prefetch),
    .clk                       (sd_card_clk),
    .rst                       (rst_all),
    // 图片优先权由寄存后的加载状态与音频 FIFO 水位共同决定。
    .img_priority              (image_priority_q),
    // 已受理事务保持到完成；水位偏好只影响下一笔事务的准入。
    .wav_grant                 (wav_sd_grant),
    .img_grant                 (img_sd_grant),
    .vid_grant                 (vid_sd_grant),
    .img_sd_sec_read           (img_sd_sec_read),
    .img_sd_sec_read_addr      (img_sd_sec_read_addr),
    .img_sd_sec_read_data      (img_sd_sec_read_data),
    .img_sd_sec_read_data_valid(img_sd_sec_read_data_valid),
    .img_sd_sec_read_end       (img_sd_sec_read_end),
    .wav_sd_sec_read           (wav_sd_sec_read),
    .wav_sd_sec_read_addr      (wav_sd_sec_read_addr),
    .wav_sd_sec_read_data      (wav_sd_sec_read_data),
    .wav_sd_sec_read_data_valid(wav_sd_sec_read_data_valid),
    .wav_sd_sec_read_end       (wav_sd_sec_read_end),
    .fat_sd_sec_read           (fat_sd_sec_read),
    .fat_sd_sec_read_addr      (fat_sd_sec_read_addr),
    .fat_sd_sec_read_data      (fat_sd_sec_read_data),
    .fat_sd_sec_read_data_valid(fat_sd_sec_read_data_valid),
    .fat_sd_sec_read_end       (fat_sd_sec_read_end),
    .vid_sd_sec_read           (vid_sd_sec_read),
    .vid_sd_sec_read_addr      (vid_sd_sec_read_addr),
    .vid_sd_sec_read_data      (vid_sd_sec_read_data),
    .vid_sd_sec_read_data_valid(vid_sd_sec_read_data_valid),
    .vid_sd_sec_read_end       (vid_sd_sec_read_end),
    .sd_sec_read               (sd_sec_read),
    .sd_sec_read_addr          (sd_sec_read_addr),
    // 音频 data、valid 和 end 必须使用同一级流水响应。
    .sd_sec_read_data          (fs_logical_data),
    .sd_sec_read_data_valid    (fs_logical_valid),
    .sd_sec_read_end           (fs_logical_done)
  );

  // 视频模式控制与手势分类。播放节拍由实际呈现帧及音频消费反馈控制。
  wire video_key_hold;
  wire key3_tap_n;
  key_long #(
    .CLK_FREQ_HZ(SD_CORE_HZ),
    // 长按阈值为 0.8 秒，用于区分图片短按与视频模式切换。
    .HOLD_MS    (800),
    .TAP_MS     (40),
    .MIN_MS     (15)
  ) u_video_key (
    .clk       (sd_card_clk),
    .rst       (rst_all),
    .key_n     (key3_s2),
    .hold_pulse(video_key_hold),
    .tap_n     (key3_tap_n)
  );

  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      video_play         <= 1'b0;
      video_paused       <= 1'b0;
      vid_toggle_pending <= 1'b0;
      vid_exit_reload    <= 1'b0;
    end else begin
      vid_exit_reload <= 1'b0;
      // 扩展 KEY0 仅控制视频暂停，避免改变背景音乐的暂停状态。
      if (!video_play || video_switching) video_paused <= 1'b0;
      else if (btn_pause_evt || exp_video_pause_evt) video_paused <= ~video_paused;
      // 扩展 KEY3 和板载长按共用单周期视频模式切换事件。
      if (video_key_hold || exp_video_toggle_evt) begin
        // 退出视频不等待媒体数据继续到达，保证停止供数时仍可退出。
        if (video_play) begin
          video_play         <= 1'b0;
          video_paused       <= 1'b0;
          vid_toggle_pending <= 1'b0;
          vid_exit_reload    <= 1'b1;  // 视频退出事件。
        end else begin
          vid_toggle_pending <= ~vid_toggle_pending;  // 每次长按翻转一次意图
        end
      end else if (vid_toggle_pending && list_ready && !video_seq_present) begin
        vid_toggle_pending <= 0;
      end else if (vid_toggle_pending && video_can_start) begin
        video_play         <= 1'b1;
        vid_toggle_pending <= 1'b0;
      end
    end
  end

  // 编译期视频使能控制视频通路的生成。
  localparam VIDEO_ON = 1'b1;  // 启用视频通路。

  generate
    if (VIDEO_ON) begin : g_video
      // 视频域场同步事件转换为 toggle，经三级同步后在 SD 域恢复为单周期事件。
      reg vs_d_v, vs_tog_v;
      always @(posedge video_clk or negedge rst_all_n) begin
        if (!rst_all_n) begin
          vs_d_v   <= 1'b0;
          vs_tog_v <= 1'b0;
        end else begin
          vs_d_v <= vs;
          if (vs_d_v & ~vs) vs_tog_v <= ~vs_tog_v;
        end
      end
      reg [2:0] vt_sync;
      always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) vt_sync <= 3'b000;
        else vt_sync <= {vt_sync[1:0], vs_tog_v};
      end
      wire vid_vsync_tick = vt_sync[2] ^ vt_sync[1];
      // Publish one audio grant per NEW video buffer observed at a raster boundary.
      reg [1:0] av_last_buf;
      reg av_have_buf;
      always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) begin
          av_display_toggle <= 0;
          av_last_buf <= 0;
          av_have_buf <= 0;
        end else if (!video_engine_play) av_have_buf <= 0;
        else if(vid_disp_ok && scanout_event_sd && scanout_bank_s1==vid_disp_buf_idx &&
         (!av_have_buf || av_last_buf!=scanout_bank_s1))begin
          av_display_toggle <= ~av_display_toggle;
          av_last_buf <= scanout_bank_s1;
          av_have_buf <= 1;
        end
      end
      video_eof_guard u_video_eof_guard (
        .clk(sd_card_clk), .rst(rst_all), .enable(video_engine_play),
        .paused(video_paused), .last_committed(video_last_shown),
        .frame_presented(vid_disp_ok && scanout_event_sd && scanout_bank_s1==vid_disp_buf_idx &&
                         (!av_have_buf || av_last_buf != scanout_bank_s1)),
        .budget_empty(video_budget_empty_sync[1]), .ended(video_playlist_ended));

      // Audio starts only after the first committed video buffer reaches a display boundary.
      always @(posedge sd_card_clk or posedge rst_all) begin
        if (rst_all) av_started <= 0;
        else if (!video_engine_play) av_started <= 0;
        else if (vid_disp_ok && scanout_event_sd && scanout_bank_s1==vid_disp_buf_idx) av_started <= 1;
      end


      video_player #(
        .PLAYLIST_SUPPORT(1),
        .LEGACY_CODECS(0),
        .BF_AW        (14),
        .BF_HI        (16'd15840),
        .AUDIO_MASTER (1),
        .AV_SYNC      (1),
        .FRAME_PIXELS (32'd921600),
        .FRAME_H      (16'd720)
      ) u_video_player (
        .clk                   (sd_card_clk),
        .rst                   (rst_all),
        .vsync_tick            (vid_vsync_tick),
        .scanout_event         (scanout_event_sd),
        .scanout_bank          (scanout_bank_s1),
        .present_enable        (video_audio_ready),
        .timeline_run          (av_started),
        .audio_frame_tick      (av_audio_frame_tick),
        .audio_clock_active    (VAU_ON && !av_audio_failed),
        .audio_frame_samples   (av_frame_samples),
        .sd_error              (fs_error && fs_error_owner == 3),
        // 视频必须等 FAT 目录扫完（fat_video_sector 才有效），和 bmp_read 一样
        //  用 sd_init_done & list_ready 做门控
        .sd_init_done          (sd_init_done & list_ready),
        .play                  (video_engine_play),
        .pause                 (video_paused),
        .start_sector          (fat_video_sector),
        .movie_last_shown      (video_last_shown),
        .img_disp_buf          (img_disp_buf_idx),
        .sd_sec_read           (vid_sd_sec_read),
        .sd_sec_read_addr      (vid_sd_sec_read_addr),
        .sd_sec_read_data      (vid_sd_sec_read_data),
        .sd_sec_read_data_valid(vid_sd_sec_read_data_valid),
        .sd_sec_read_end       (vid_sd_sec_read_end),
        .sd_grant              (vid_sd_grant),
        .write_almost_full     (image_fifo_almost_full),
        .write_req             (vid_write_req),
        .write_req_ack         (sd_card_write_req_ack),
        .write_finish_toggle   (frame_write_toggle_mem),
        .pix_en                (vid_write_en),
        .pix_data              (vid_write_data),
        .img_h_o               (vid_img_h),
        .wr_buf_idx            (vid_write_buf_idx),
        .dp_buf_idx            (vid_disp_buf_idx),
        .active                (vid_active),
        .disp_ok               (vid_disp_ok),
        .dbg_state             (vid_dbg_state)
      );

    end else begin : g_no_video
      // 视频摘除时的固定输出：显示永远走图片通路，SD 不给视频分配任何请求。
      assign av_frame_samples = 13'd3200;
      always @* av_display_toggle = 1'b0;
      assign vid_active        = 1'b0;
      assign vid_disp_ok       = 1'b0;
      assign vid_write_req     = 1'b0;
      assign vid_write_en      = 1'b0;
      assign vid_write_data    = 32'd0;
      assign vid_write_buf_idx = 2'd0;
      assign vid_disp_buf_idx  = 2'd0;
      assign vid_img_h         = 16'd0;
      assign vid_sd_sec_read   = 1'b0;
      assign vid_dbg_state     = 4'd0;
    end
  endgenerate

  // FAT32 挂载建立音视频目录及卷几何；运行期图片查询复用目录解析器。
  reg [19:0] fat_scan_cnt;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      fat_scan_cnt   <= 20'd0;
      fat_scan_start <= 1'b0;
    end else begin
      fat_scan_start <= 1'b0;
      if (!sd_init_done) fat_scan_cnt <= 0;
      else if (fat_scan_cnt < 20'h80000) begin
        fat_scan_cnt <= fat_scan_cnt + 20'd1;
        if (fat_scan_cnt == 20'd500)   
          fat_scan_start <= 1'b1;
      end
    end
  end

  fat32_list #(.STREAM_IMAGES(1)) u_fat32_list (
    .image_pause(video_play || (fifo_usedw < 14'd4096 && wav_sd_sec_read)),
    .image_consume(iter_consume),.image_valid(iter_valid),.image_empty(iter_empty),
    .image_error(iter_error),.image_lba(iter_lba),
    .sd_read_error(fs_error && fs_error_owner==2),
    .root_cluster_o(fs_root_cluster),
    .fat_start_o           (fs_fat_start),
    .cluster_shift_o       (fs_cluster_shift),
    .max_cluster_o         (fs_max_cluster),
    .geometry_valid_o      (fs_geometry_valid),
    .filesystem_error_o    (fs_mount_error),
    .clk                   (sd_card_clk),
    .rst                   (rst_all | !sd_init_done),
    .scan_start            (fat_scan_start),
    .sd_init_done          (sd_init_done),
    .sd_sec_read           (mount_sd_req),
    .sd_sec_read_addr      (mount_sd_addr),
    .sd_sec_read_data      (fat_sd_sec_read_data),
    .sd_sec_read_data_valid(fat_sd_sec_read_data_valid),
    .sd_sec_read_end       (fat_sd_sec_read_end),
    .list_ready            (list_ready),
    .song_count            (song_count),
    // 曲目号同时选择文件地址与 OSD 标题，索引范围由歌单控制器约束。
    .list_idx              (play_song_idx[4:0]),
    .list_name             (list_name),
    .list_sector           (list_sector),
    .data_start_o          (fat_data_start),
    .video_sector_o        (legacy_video_sector),
    .vaudio_sector_o       (legacy_vau_sector),
    .media_entry_valid     (media_entry_valid),
    .media_entry_audio     (media_entry_audio),
    .media_entry_prefix    (media_entry_prefix),
    .media_entry_sector    (media_entry_sector),
    .song5_sector_o        (song5_sector),
    .image_count_o         (directory_image_count),
    .image0_o              (directory_image0),
    .image1_o              (directory_image1),
    .image2_o              (directory_image2),
    .image3_o              (directory_image3),
    .image4_o              (directory_image4),
    .image5_o              (directory_image5),
    .image6_o              (directory_image6),
    .image7_o              (directory_image7),

    .mbr_b0_o              (fat_mbr_b0)
  );


  // Multi-video control remains in the SD/control clock domain.
  always @(posedge sd_card_clk or posedge rst_all) begin
    if(rst_all) video_budget_empty_sync<=0;
    else video_budget_empty_sync<={video_budget_empty_sync[0],av_buffering};
  end
  video_catalog u_video_catalog (
    .clk(sd_card_clk),.rst(rst_all),.clear(!sd_init_done),
    .entry_valid(media_entry_valid),.entry_audio(media_entry_audio),
    .entry_prefix(media_entry_prefix),.entry_sector(media_entry_sector),
    .index(video_index),.legacy_video(legacy_video_sector),.legacy_audio(legacy_vau_sector),
    .available(video_available),.selected_video(fat_video_sector),.selected_audio(vau_sector),
    .duplicate_seen(video_duplicate_seen));
  video_playlist_ctrl u_video_playlist (
    .clk(sd_card_clk),.rst(rst_all),.mode_video(video_play),.list_ready(list_ready),
    .next_req(kp_next_song || exp_next_song_evt),.prev_req(exp_key_press[2]),
    .auto_toggle(btn_dbl_a),
    .ended(video_playlist_ended),
    .io_idle(!vid_sd_sec_read && !vid_sd_grant),.audio_ready(wav_ready),.audio_busy(audio_transition_busy),
    .available(video_available),.index(video_index),.engine_play(video_engine_play),
    .audio_select(video_audio_select),.switching(video_switching),
    .auto_enabled(video_auto_enabled),.selection_failed(video_selection_failed));

  // ===================== 共享 sd_card_top（接物理 SPI 引脚） =====================
  fat32_sector_mapper #(.PHYSICAL_PREFETCH_BLOCKS(64)) u_fat_mapper (
    .clk           (sd_card_clk),
    .rst           (rst_all),
    .invalidate    (!sd_init_done),
    .mounted       (fs_geometry_valid),
    .fat_start_lba (fs_fat_start),
    .data_start_lba(fat_data_start),
    .cluster_shift (fs_cluster_shift),
    .max_cluster   (fs_max_cluster),
    .req           (sd_sec_read),
    .owner         (fs_owner),
    .virtual_lba   (sd_sec_read_addr),
    .file_base_lba (fs_file_base),
    .multi         (sd_multi_en),
    .pace          (img_sd_grant),
    .data          (fs_logical_data),
    .valid         (fs_logical_valid),
    .done          (fs_logical_done),
    .error         (fs_error),
    .error_code    (fs_error_code),
    .error_owner   (fs_error_owner),
    .sd_req        (fs_card_req),
    .sd_lba        (fs_card_lba),
    .sd_multi      (fs_card_multi),
    .sd_pace       (fs_card_pace),
    .sd_data       (sd_sec_read_data),
    .sd_valid      (sd_sec_read_data_valid),
    .sd_done       (sd_sec_read_end)
  );
  // A transport timeout must also drain/reinitialize the physical controller;
  // returning an end pulse alone could leave an old SPI response in flight.
  reg fs_transport_reset;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) fs_transport_reset <= 0;
    else fs_transport_reset <= fs_error && (fs_error_code == 5);
  end

  sd_card_top #(
    .PREFETCH_BRAM32(1),.PREFETCH_BLOCKS(64)
  ) sd_card_top_m0 (
    .clk(sd_card_clk),
    .rst(rst_all | fs_transport_reset),
    .SD_nCS(sd_ncs),
    .SD_DCLK(sd_dclk),
    .SD_MOSI(sd_mosi),
    .SD_MISO(sd_miso),
    .sd_init_done(sd_init_done),
    .sd_sec_read(fs_card_req),
    .sd_sec_read_addr(fs_card_lba),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),
    .sd_sec_write(1'b0),
    .sd_sec_write_addr(32'd0),
    .sd_sec_write_data(8'd0),
    .sd_sec_write_data_req(),
    .sd_sec_write_end(),
    // FAT 映射器输出物理多块读与节拍控制，连接到共享 SD 控制器。
    .sd_read_multi(fs_card_multi),
    .sd_read_paced(fs_card_pace),   
    // SD 控制器状态和命令错误作为只读观测输出。
    .dbg_sd_state(wav_dbg_sd_state),
    .dbg_sd_cmd_err(wav_dbg_sd_cmd_err)
  );

  // 图片状态译码供板载状态显示。
  wire [7:0] img_state_seg;
  seg_decoder seg_decoder_m0 (
    .bin_data(state_code),
    .seg_data(img_state_seg)
  );

  // 挂载扇区首字节观测的显示译码。
  wire [6:0] dbr_probe_seg = (fat_mbr_b0 == 8'hEB || fat_mbr_b0 == 8'hE9)
                           ? 7'b0001001                  // 'H' = DBR 签名正确
  : hex7(
      fat_mbr_b0[3:0]
  );  // 否则显示低 4 位

  // 锁存头部解析和文件错误事件，供低速状态显示读取。
  reg seen_hdr;  // ever outside IDLE
  reg seen_byte;  // ever saw sd_sec_read_data_valid high
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      seen_hdr  <= 1'b0;
      seen_byte <= 1'b0;
    end else begin
      if (wav_dbg_state != 3'd0) seen_hdr <= 1'b1;
      if (wav_sd_sec_read_data_valid) seen_byte <= 1'b1;
    end
  end

  // 状态显示所需的保留信号。
  wire [15:0] ff_ticks = 16'd0;  // 名字保留给下面的显示分支（已不使用）
  wire [31:0] ff_diff = 32'd0;


  // ================================================================
  // Frame-rate diagnostic window:88778*1024 SD/control cycles, approximately1s.
  // This counter only drives diagnostics; A/V timing uses actual PCM consumption.
  reg  [16:0] dg_seconds_div;
  reg [8:0] dg_vfr, dg_vfr_prev;
  reg  [7:0] dg_fps;
  reg  [9:0] dg_div;
  reg  [1:0] dg_vbi_d;
  wire       dg_tick = (dg_div == 10'd0);

  // 视频模式显示帧率，图片与音乐模式显示读取器及轮播状态。
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      dg_seconds_div <= 17'd0;
      dg_vfr <= 9'd0;
      dg_vfr_prev <= 9'd0;
      dg_fps <= 8'd0;
      dg_div <= 10'd0;
      dg_vbi_d <= 2'd0;
    end else begin
      dg_div   <= dg_div + 10'd1;
      dg_vbi_d <= vid_disp_buf_idx;
      if (vid_disp_buf_idx != dg_vbi_d) dg_vfr <= dg_vfr + 9'd1;
      if (dg_tick) begin
        if (dg_seconds_div == 17'd88777) begin
          dg_seconds_div <= 17'd0;
          dg_fps         <= dg_vfr - dg_vfr_prev;
          dg_vfr_prev    <= dg_vfr;
        end else dg_seconds_div <= dg_seconds_div + 1'b1;
      end
    end
  end


  seg_scan #(
    .SAME_CLOCK(1),
    .CLK_FREQ  (SD_CORE_HZ)
  ) seg_scan_m0 (
    .status_clk(sd_card_clk),
    .clk(sd_card_clk),
    .rst_n(rst_n),
    .seg_sel(seg_sel),
    .seg_data(seg_data),
    // 小数点用于所选状态视图的故障标志。
    .seg_data_0(kp_debug_on ? {wav_dbg_silent, dbg_d0} : (video_play ? {1'b1, hex7(
        dg_fps[7:4]
    )} : {1'b1, hex7(
        {1'b0, wav_dbg_state}
    )})),  // 视频=帧率高位 / 音频=WAV状态码
    .seg_data_1(kp_debug_on ? {wav_dbg_posbad, dbg_d1} : (video_play ? {1'b1, hex7(
        dg_fps[3:0]
    )} : {1'b1, hex7(
        img_auto_mode
    )})),  // 视频=帧率低位 / 音频=轮播档位码 0..F
    // 状态显示仅选择已寄存的观测量，限制输出译码路径深度。
    .seg_data_2        (kp_debug_on ? ((PROBE_GRP == 5'd4) ? {wav_dbg_ack_seen, dbg_d2} : {stereo_o1, dbg_d2})
                        : {1'b1, hex7(
        {2'b00, wav_ready, video_play}
    )}),
    .seg_data_3(kp_debug_on ? {ch_not2_hit, dbg_d3} : {1'b1, hex7(wav_dbg_sd_state[3:0])}),

    // 图片加载、图像有效及音频请求的状态显示。
    .seg_data_4        (kp_debug_on ? {(lrck_recent_cnt != 20'd0), dbg_d4}
                                    : {wav_dbg_sd_cmd_err,
                                       (video_play ? vau_fault_seg : hex7(
        {2'b00, wav_dbg_sd_state[4:3]}
    ))}),
    // 右侧状态位显示读取器状态与锁存错误。
    .seg_data_5(kp_debug_on ? {wav_sd_sec_read, dbg_d5} : {~seen_byte,
    // 音源有效标志预寄存，避免宽比较串联数码管译码路径。
    hex7(
        vau_tgt ? {wav_tbad_sticky, wav_dbg_state}
                                        : (vid_toggle_pending ? 4'h9
                                         : (video_play ? {wav_tbad_sticky, wav_dbg_state}
                                                       : {1'b0, wav_dbg_state}))
    )})
  );

  // 扩展板 74HC595 显示接口未启用。
  /*
reg [4:0] exp_ui_s0, exp_ui_s1;
always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        exp_ui_s0 <= 5'd0;
        exp_ui_s1 <= 5'd0;
    end else begin
        exp_ui_s0 <= {img_auto_on, exp_period_code};
        exp_ui_s1 <= exp_ui_s0;
    end
end

seg595_display #(
    .CLK_FREQ_HZ    (50_000_000),
    .SEG_BYTE_FIRST (0),
    .DIG_SEL0_LEFT  (1),
    .SEG_ACT_LOW    (1),
    .DIG_ACT_LOW    (0)
) u_exp_seg595 (
    .clk         (clk),
    .rst         (rst_all),
    .carousel_on (exp_ui_s1[4]),
    .preset_code (exp_ui_s1[3:0]),
    .seg_rclk    (exp_seg_rclk),
    .seg_dio     (exp_seg_dio),
    .seg_sclk    (exp_seg_sclk)
);
*/


  // The image loader now emits a complete aspect-fitted 1280x720 raster.
  assign img_pad_high = image_fifo_almost_full;
  assign img_pad_en = img_write_en && !vid_active;
  assign img_pad_data = img_write_data;

  // 图像时序与帧缓存。
  video_timing_data video_timing_data_m0 (
    .video_clk   (video_clk),
    .rst         (rst_all),
    .read_req    (video_read_req),
    .read_req_ack(video_read_req_ack),
    .hs          (hs_0),
    .vs          (vs_0),
    .de          (de_0)
  );

  video_delay video_delay_m0 (
    .video_clk(video_clk),
    .rst      (rst_all),
    .read_en  (video_read_en),
    .read_data(video_read_data[31:8]),
    .hs       (hs_0),
    .vs       (vs_0),
    .de       (de_0),
    .hs_r     (hs),
    .vs_r     (vs),
    .de_r     (de),
    .vout_data(vout_data_raw)
  );

  // 首帧提交后开放显示；图像层先淡入淡出，再叠加 OSD 和频谱。
  // 视频有效门由首帧完整写入及呈现状态控制。
  assign vout_data = display_valid_any ? fade_img : 24'd0;

  frame_read_write #(
    .WRITE_V_FLIP(1),
    .PACKED565   (1),
    .FRAME_WIDTH (1280),
    .FRAME_HEIGHT(720)
  ) frame_read_write_m0 (
    .mem_clk         (ext_mem_clk),
    .rst             (rst_all),
    .Sdr_init_done   (Sdr_init_done),
    .Sdr_init_ref_vld(Sdr_init_ref_vld),
    .Sdr_busy        (Sdr_busy),

    .App_rd_en  (App_rd_en),
    .App_rd_addr(App_rd_addr),
    .Sdr_rd_en  (Sdr_rd_en),
    .Sdr_rd_dout(Sdr_rd_dout),

    .read_clk       (video_clk),
    .read_req       (video_read_req),
    .read_req_ack   (video_read_req_ack),
    .read_finish    (),
    .read_addr_0    (BUF0_ADDR),
    .read_addr_1    (BUF1_ADDR),
    .read_addr_2    (BUF2_ADDR),
    .read_addr_3    (24'd0),
    .scanout_bank(scanout_bank_mem),
    .scanout_toggle(scanout_toggle_mem),
    .read_addr_index(disp_buf_idx),
    .read_len       (FRAME_PIXELS),
    .read_en        (video_read_en),
    .read_data      (video_read_data),

    .App_wr_en  (App_wr_en),
    .App_wr_addr(App_wr_addr),
    .App_wr_din (App_wr_din),
    .App_wr_dm  (App_wr_dm),

    .write_clk        (sd_card_clk),
    .write_req        (sd_card_write_req),
    .write_req_ack    (sd_card_write_req_ack),
    .write_finish     (frame_write_finish),
    .write_almost_full(image_fifo_almost_full),
    .write_addr_0     (BUF0_ADDR),
    .write_addr_1     (BUF1_ADDR),
    .write_addr_2     (BUF2_ADDR),
    .write_addr_3     (24'd0),
    .write_addr_index (write_buf_idx),
    .write_len        (FRAME_PIXELS),
    // 帧缓存按完整输出栅格高度进行写地址计算。
    .write_img_h      (img_h_used),
    .write_top_down   (vid_active ? 1'b0 : img_top_down),
    .write_en         (sd_card_write_en),
    .write_data       (sd_card_write_data)
  );

  sdram U3 (
    .Clk             (ext_mem_clk),
    .Clk_sft         (ext_mem_clk_sft),
    .Rst             (rst_all),
    .Sdr_init_done   (Sdr_init_done),
    .Sdr_init_ref_vld(Sdr_init_ref_vld),
    .Sdr_busy        (Sdr_busy),
    .App_wr_en       (App_wr_en),
    .App_wr_addr     (App_wr_addr),
    .App_wr_dm       (App_wr_dm),
    .App_wr_din      (App_wr_din),
    .App_rd_en       (App_rd_en),
    .App_rd_addr     (App_rd_addr),
    .Sdr_rd_en       (Sdr_rd_en),
    .Sdr_rd_dout     (Sdr_rd_dout)
  );

  // 音频接收。
  I2S_receiver u_I2S_receiver (
    .I_clk             (video_clk),
    .I_rst             (rst_all),
    .I_i2s_BCLK        (audio_i2s_bclk),
    .I_i2s_LRCK        (audio_i2s_lrck),
    .I_i2s_DOUT        (audio_i2s_dout),
    .O_audio_valid     (audio_valid),
    .O_audio_left_data (audio_left_data),
    .O_audio_right_data(audio_right_data)
  );

  audio_arc_calculate #(
    .ACR_N(6144)
  ) u_audio_arc_calculate (
    .I_clk        (video_clk),
    .I_rst        (rst_all),
    .I_audio_valid(audio_valid),
    .O_acr_valid  (acr_valid),
    .O_acr_cts    (acr_cts),
    .O_acr_n      (acr_n)
  );

  // ===================== 像素坐标重建（de/vs -> x/y） =====================
  video_coord u_video_coord (
    .clk     (video_clk),
    .rst_n   (rst_all_n),
    .de      (de),
    .vs      (vs),
    .active_x(active_x),
    .active_y(active_y)
  );

  // ===================== 播放状态跨时钟域同步（sd_card_clk -> video_clk） =====================
  // tot_sec/cur_sec/progress 是慢信号（秒级/进度），两级同步即可。
  reg [15:0] tot_sec_s0, tot_sec_s1;
  reg [15:0] cur_sec_s0, cur_sec_s1;
  reg [7:0] progress_s0, progress_s1;
  always @(posedge video_clk or negedge rst_all_n) begin
    if (!rst_all_n) begin
      tot_sec_s0  <= 16'd0;
      tot_sec_s1  <= 16'd0;
      cur_sec_s0  <= 16'd0;
      cur_sec_s1  <= 16'd0;
      progress_s0 <= 8'd0;
      progress_s1 <= 8'd0;
    end else begin
      tot_sec_s0  <= tot_sec;
      tot_sec_s1  <= tot_sec_s0;
      cur_sec_s0  <= cur_sec;
      cur_sec_s1  <= cur_sec_s0;
      progress_s0 <= progress;
      progress_s1 <= progress_s0;
    end
  end

  // 歌名同步（list_name 在 list_ready 后稳定，两级同步即可）
  reg [63:0] list_name_s0, list_name_s1;
  always @(posedge video_clk or negedge rst_all_n) begin
    if (!rst_all_n) begin
      list_name_s0 <= 64'd0;
      list_name_s1 <= 64'd0;
    end else begin
      list_name_s0 <= list_name;
      list_name_s1 <= list_name_s0;
    end
  end

  function [9:0] auto_period_decode;
    input [3:0] code;
    begin
      case (code)
        4'd0: auto_period_decode=10'd2;   4'd1: auto_period_decode=10'd3;
        4'd2: auto_period_decode=10'd5;   4'd3: auto_period_decode=10'd8;
        4'd4: auto_period_decode=10'd10;  4'd5: auto_period_decode=10'd15;
        4'd6: auto_period_decode=10'd20;  4'd7: auto_period_decode=10'd30;
        4'd8: auto_period_decode=10'd45;  4'd9: auto_period_decode=10'd60;
        4'd10:auto_period_decode=10'd90;  4'd11:auto_period_decode=10'd120;
        4'd12:auto_period_decode=10'd180; 4'd13:auto_period_decode=10'd240;
        4'd14:auto_period_decode=10'd300; default:auto_period_decode=10'd600;
      endcase
    end
  endfunction
  wire carousel_on_v = auto_status_video[4];
  wire [9:0] carousel_period_sec_v = auto_period_decode(auto_status_video[3:0]);

  // 视频模式显示伴音标题；图片模式显示歌曲标题。
  // 模式电平同步到 video_clk 后选择稳定的标题数据。
  reg vp_v0, vp_v1;
  always @(posedge video_clk or negedge rst_all_n) begin
    if (!rst_all_n) begin
      vp_v0 <= 1'b0;
      vp_v1 <= 1'b0;
    end else begin
      vp_v0 <= video_play;
      vp_v1 <= vp_v0;
    end
  end
  // "DEFT A/V"
  wire [63:0] osd_title = vp_v1 ? 64'h4445465420412F56 : list_name_s1;

  // 音量/播放状态同步（sd_card_clk -> video_clk，两级）
  reg [4:0] volume_v0, volume_v1;
  reg pause_v0, pause_v1;
  always @(posedge video_clk or negedge rst_all_n) begin
    if (!rst_all_n) begin
      volume_v0 <= 5'd31;
      volume_v1 <= 5'd31;
      pause_v0  <= 1'b0;
      pause_v1  <= 1'b0;
    end else begin
      volume_v0 <= volume;
      volume_v1 <= volume_v0;
      pause_v0  <= pause;
      pause_v1  <= pause_v0;
    end
  end

  // 音频格式元数据同步（sd_card_clk -> video_clk，两级，慢信号）
  reg [31:0] sr_v0, sr_v1;
  reg [15:0] ch_v0, ch_v1;
  reg [15:0] bd_v0, bd_v1;
  always @(posedge video_clk or negedge rst_all_n) begin
    if (!rst_all_n) begin
      sr_v0 <= 32'd0;
      sr_v1 <= 32'd0;
      ch_v0 <= 16'd0;
      ch_v1 <= 16'd0;
      bd_v0 <= 16'd0;
      bd_v1 <= 16'd0;
    end else begin
      sr_v0 <= wav_sample_rate;
      sr_v1 <= sr_v0;
      ch_v0 <= wav_channels;
      ch_v1 <= ch_v0;
      bd_v0 <= wav_bit_depth;
      bd_v1 <= bd_v0;
    end
  end

  // 键盘自检信号同步（sd_card_clk -> video_clk，两级；供 OSD 面板显示）
  reg [15:0] kp_img_v0, kp_img_v1;
  reg [1:0] kp_row_v0, kp_row_v1;
  reg [3:0] kp_col_v0, kp_col_v1;
  reg [3:0] key_code_v0, key_code_v1;
  reg [3:0] hit_row_v0, hit_row_v1;
  reg [3:0] hit_col_v0, hit_col_v1;
  reg [3:0] hit_key_v0, hit_key_v1;
  reg kp_dbg_v0, kp_dbg_v1;
  always @(posedge video_clk or negedge rst_all_n) begin
    if (!rst_all_n) begin
      kp_img_v0   <= 16'd0;
      kp_img_v1   <= 16'd0;
      kp_row_v0   <= 2'd0;
      kp_row_v1   <= 2'd0;
      kp_col_v0   <= 4'hF;
      kp_col_v1   <= 4'hF;
      key_code_v0 <= 4'd0;
      key_code_v1 <= 4'd0;
      hit_row_v0  <= 2'd0;
      hit_row_v1  <= 2'd0;
      hit_col_v0  <= 4'd0;
      hit_col_v1  <= 4'd0;
      hit_key_v0  <= 4'd0;
      hit_key_v1  <= 4'd0;
      kp_dbg_v0   <= 1'b0;
      kp_dbg_v1   <= 1'b0;
    end else begin
      kp_img_v0   <= kp_raw_image;
      kp_img_v1   <= kp_img_v0;
      kp_row_v0   <= kp_row_now;
      kp_row_v1   <= kp_row_v0;
      kp_col_v0   <= kp_col_now;
      kp_col_v1   <= kp_col_v0;
      key_code_v0 <= key_code;
      key_code_v1 <= key_code_v0;
      hit_row_v0  <= hit_row_lat;
      hit_row_v1  <= hit_row_v0;
      hit_col_v0  <= hit_col_lat;
      hit_col_v1  <= hit_col_v0;
      hit_key_v0  <= hit_key_lat;
      hit_key_v1  <= hit_key_v0;
      kp_dbg_v0   <= kp_debug_on;
      kp_dbg_v1   <= kp_dbg_v0;
    end
  end

  reg [3:0] sw_s0, sw_s1, sw_s2;
  always @(posedge video_clk or negedge rst_all_n) begin
    if (!rst_all_n) begin
      sw_s0 <= 4'd0;
      sw_s1 <= 4'd0;
      sw_s2 <= 4'd0;
    end else begin
      sw_s0 <= sw;
      sw_s1 <= sw_s0;
      sw_s2 <= sw_s1;
    end
  end
  wire [3:0] sw_deg = sw_s2;
  wire signed [8:0] bc_bright = (sw_deg[1:0] == 2'd0) ? (-9'sd48) :  // 档0: -48
  (sw_deg[1:0] == 2'd1) ? (-9'sd16) :  // 档1: -16
  (sw_deg[1:0] == 2'd2) ? 9'sd16 :  // 档2: +16
  9'sd48;  // 档3: +48
  wire [8:0] bc_contrast = (sw_deg[3:2] == 2'd0) ? 9'd96 :  // 档0: 0.75x
  (sw_deg[3:2] == 2'd1) ? 9'd128 :  // 档1: 1.00x
  (sw_deg[3:2] == 2'd2) ? 9'd160 :  // 档2: 1.25x
  9'd192;  // 档3: 1.50x

  // ===================== OSD 播放器 UI（底部进度条 + 时间 + 歌名） =====================
  osd_player_ui u_osd_player_ui (
    .clk        (video_clk),
    .rst_n      (rst_all_n),
    .de         (de),
    .vs         (vs),
    .screen_x   (active_x),
    .screen_y   (active_y),
    .video_r    (vout_data[23:16]),
    .video_g    (vout_data[15:8]),
    .video_b    (vout_data[7:0]),
    .tot_sec    (tot_sec_s1),
    .cur_sec    (cur_sec_s1),
    .progress   (progress_s1),
    .song_name  (osd_title),
    .sample_rate(sr_v1),
    .channels   (ch_v1),
    .bit_depth  (bd_v1),
    .volume     (volume_v1),
    .pause      (pause_v1),
    .carousel_on(carousel_on_v),
    .carousel_period_sec(carousel_period_sec_v),
    .video_mode (vp_v1),
    .kp_debug   (kp_dbg_v1),
    .sw_deg     (sw_deg),            
    // 4x4 格子用实时位图（每帧刷新），这样"某个键到底有没有被读到"
    // 立刻能看出来；R/C/K 那一行则是"最近一次被受理的按键"（锁存）。
    // 排查硬件这两种信息都需要：前者看"读没读到"，后者看"解出什么键码"。
    .kp_image   (kp_img_v1),
    .kp_row     (hit_row_v1),
    .kp_col     (hit_col_v1),
    .kp_key     (hit_key_v1),
    .de_out     (osd_de),
    .vs_out     (osd_vs),
    .osd_r      (osd_r),
    .osd_g      (osd_g),
    .osd_b      (osd_b)
  );
  assign osd_rgb = {osd_r, osd_g, osd_b};

  // 频谱分析与绘制位于 video_clk 域。SPECTRUM_ON 控制编译期生成。
  // 启用与旁路分支均保持一拍像素及同步延迟，避免显示相位变化。
  localparam SPECTRUM_ON = 1'b1;

  generate
    if (SPECTRUM_ON) begin : g_spec

      audio_frame u_audio_frame (
        .clk        (video_clk),
        .rst_n      (rst_all_n),
        .audio_valid(audio_valid),
        .audio_left (audio_left_data),
        .fft_done   (fft_done),
        .fft_start  (fft_start),
        .fft_din_re (fft_din_re),
        .fft_din_im (fft_din_im)
      );

      fft_256 u_fft_256 (
        .clk       (video_clk),
        .rst_n     (rst_all_n),
        .start     (fft_start),
        .din_re    (fft_din_re),
        .din_im    (fft_din_im),
        .busy      (),
        .done      (fft_done),
        .dout_re   (fft_dout_re),
        .dout_im   (fft_dout_im),
        .dout_valid(fft_dout_valid)
      );

      spectrum_capture u_spectrum_capture (
        .clk       (video_clk),
        .rst_n     (rst_all_n),
        .fft_valid (fft_dout_valid),
        .fft_re    (fft_dout_re),
        .fft_im    (fft_dout_im),
        .rd_addr   (bar_addr),
        .rd_data   (bar_data),
        .rd_addr2  (bar_addr2),
        .rd_data2  (bar_data2),
        .rd_addr3  (bar_addr3),
        .rd_data3  (bar_data3),
        .rd_addr4  (bar_addr4),
        .rd_data4  (bar_data4),
        .beat_pulse(beat_pulse)
      );

      // 视频模式关闭频谱叠加，但保持像素与有效信号同拍延迟。
      reg vid_active_v0, vid_active_v1;
      always @(posedge video_clk or posedge rst_all) begin
        if (rst_all) begin
          vid_active_v0 <= 1'b0;
          vid_active_v1 <= 1'b0;
        end else begin
          vid_active_v0 <= vid_active;
          vid_active_v1 <= vid_active_v0;
        end
      end

      spectrum_display #(
        .GLOW_EN(1'b0),
        .BAND_EN(1'b0)
      ) u_spectrum_display (
        .clk       (video_clk),
        .rst_n     (rst_all_n),
        .de        (osd_de),
        .vs        (osd_vs),
        .din_rgb   (osd_rgb),
        .en        (~vid_active_v1),
        .bar_data  (bar_data),
        .bar_addr  (bar_addr),
        .bar_data2 (bar_data2),
        .bar_addr2 (bar_addr2),
        .bar_data3 (bar_data3),
        .bar_addr3 (bar_addr3),
        .bar_data4 (bar_data4),
        .bar_addr4 (bar_addr4),
        .beat_pulse(beat_pulse),
        .de_out    (disp_de),
        .vs_out    (disp_vs),
        .dout_rgb  (disp_rgb)
      );

    end else begin : g_nospec
      // 频谱旁路保持一拍延迟。
      reg [23:0] byp_rgb_q;
      reg byp_de_q, byp_vs_q;
      always @(posedge video_clk or posedge rst_all) begin
        if (rst_all) begin
          byp_rgb_q <= 24'd0;
          byp_de_q  <= 1'b0;
          byp_vs_q  <= 1'b0;
        end else begin
          byp_rgb_q <= osd_rgb;
          byp_de_q  <= osd_de;
          byp_vs_q  <= osd_vs;
        end
      end
      assign disp_rgb = byp_rgb_q;
      assign disp_de  = byp_de_q;
      assign disp_vs  = byp_vs_q;
    end
  endgenerate

  // 图片转场使用淡出/提交/淡入握手。缓冲切换事件提供无握手切换的恢复入口。
  reg [1:0] disp_buf_idx_s0, disp_buf_idx_s1;
  always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
      disp_buf_idx_s0 <= 2'd0;
      disp_buf_idx_s1 <= 2'd0;
    end else begin
      disp_buf_idx_s0 <= disp_buf_idx;
      disp_buf_idx_s1 <= disp_buf_idx_s0;
    end
  end
  // 视频帧切换屏蔽图像淡入触发，避免每帧产生亮度变化。
  wire img_switch_raw = (disp_buf_idx_s0 != disp_buf_idx_s1);
  wire img_switch = img_switch_raw && !vid_active;

  // ---- 跨时钟域 1/3：sd_card_clk -> video_clk（开始淡出的请求，toggle 同步）----
  always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) fade_req_sync <= 3'b000;
    else fade_req_sync <= {fade_req_sync[1:0], fade_req_toggle};
  end
  assign fade_req_pulse = fade_req_sync[2] ^ fade_req_sync[1];

  // ---- 跨时钟域 2/3：video_clk -> sd_card_clk（淡出完成，toggle 同步）----
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) fade_done_sync <= 3'b000;
    else fade_done_sync <= {fade_done_sync[1:0], fade_done_tgl};
  end
  assign fade_done_pulse = fade_done_sync[2] ^ fade_done_sync[1];

  // ---- 跨时钟域 3/3：video_clk -> sd_card_clk（转场中 = busy 电平，2 级同步）----
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) fade_busy_sync <= 2'b00;
    else fade_busy_sync <= {fade_busy_sync[0], fade_busy};
  end
  assign fade_switch_lock = fade_busy_sync[1];

  // 图像层在 OSD 之前淡入淡出，字幕与频谱不参与图像转场。
  // 帧同步取自对齐后的显示通路。
  fade_in u_fade_in (
    .clk       (video_clk),
    .rst_n     (rst_all_n),
    .vs        (disp_vs),
    .fade_req  (fade_req_pulse),
    .fade_done (fade_done_tgl),
    .img_switch(img_switch),
    .din_rgb   (vout_data_raw),
    .dout_rgb  (fade_img),
    .busy      (fade_busy)
  );

  wire bc_de, bc_vs;
  wire [23:0] bc_rgb;
  brightness_contrast u_brightness_contrast (
    .clk       (video_clk),
    .rst_n     (rst_all_n),
    .de        (disp_de),
    .vs        (disp_vs),
    .din_rgb   (disp_rgb),
    .brightness(bc_bright),
    .contrast  (bc_contrast),
    .de_out    (bc_de),
    .vs_out    (bc_vs),
    .dout_rgb  (bc_rgb)
  );

  // 亮度和对比度处理后的 RGB、DE 与 VS 同级输入 AXIS 转换器。
  video_rgb_to_axis_640x480 #(
    .WIDTH(1280)
  ) u_video_rgb_to_axis_640x480 (
    .I_clk        (video_clk),
    .I_rst        (rst_all),
    .I_vs         (bc_vs),
    .I_de         (bc_de),
    .I_rgb        (bc_rgb),
    .O_video_user (axis_s_user),
    .O_video_valid(axis_s_valid),
    .O_video_last (axis_s_last),
    .O_video_data (axis_s_data)
  );

  // HDMI 使用固定输出格式，EDID 读取触发固定为低。
  // HDMI 发送器连接对齐后的视频流与音频样本。
  hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE           ("EG"),
    .HTOTAL           (1650),
    .HSA              (40),
    .HFP              (110),
    .HBP              (220),
    .HACTIVE          (1280),
    .VTOTAL           (750),
    .VSA              (5),
    .VFP              (5),
    .VBP              (20),
    .VACTIVE          (720),
    .VIDEO_VIC        (4),
    .VIDEO_TPG        ("Disable"),
    .VIDEO_FORMAT     ("RGB"),
    .AUDIO_SAMPLE_RATE("48K"),
    .IIC_SCL_DIV      (250)
  ) u_hdmi_1_4b_transmitter_core_wrapper (
    .I_pixel_clk      (video_clk),
    .I_rst            (rst_all),
    .I_edid_read_trig (1'b0),        
    .O_edid_read_valid(edid_valid),
    .O_edid_read_data (edid_data),

    .I_axis_s_user (axis_s_user),
    .I_axis_s_valid(axis_s_valid),
    .I_axis_s_last (axis_s_last),
    .I_axis_s_data (axis_s_data),
    .O_axis_s_ready(axis_s_ready),

    .I_audio_valid     (audio_valid),
    .I_audio_left_data (audio_left_data),
    .I_audio_right_data(audio_right_data),
    .I_acr_valid       (acr_valid),
    .I_acr_cts         (acr_cts),
    .I_acr_n           (acr_n),

    .O_video_locked(),
    .O_ddc_scl     (HDMI_DDC_SCL),
    .IO_ddc_sda    (HDMI_DDC_SDA),

    .O_ch0_tmds_data(tmds_ch0_data),
    .O_ch1_tmds_data(tmds_ch1_data),
    .O_ch2_tmds_data(tmds_ch2_data),
    .O_clk_tmds_data(tmds_clk_data)
  );

  hdmi_phy_wrapper #(
    .DEVICE("EG")
  ) u_hdmi2phy_wrapper (
    .I_pixel_clk       (video_clk),
    .I_serial_clk      (hdmi_5x_clk),
    .I_rst             (rst_all),
    .I_tmds_channel_0  (tmds_ch0_data),
    .I_tmds_channel_1  (tmds_ch1_data),
    .I_tmds_channel_2  (tmds_ch2_data),
    .I_tmds_channel_clk(tmds_clk_data),
    .O_tmds_ch0_p      (HDMI_D0_P),
    .O_tmds_ch1_p      (HDMI_D1_P),
    .O_tmds_ch2_p      (HDMI_D2_P),
    .O_tmds_clk_p      (HDMI_CLK_P)
  );

endmodule

