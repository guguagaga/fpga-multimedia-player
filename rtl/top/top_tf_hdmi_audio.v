// -----------------------------------------------------------------------------
// Module purpose: Board integration: clocks, controls, shared SD access, audio/video and HDMI output.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
// Board-level integration for the v167 multimedia player.
// SD/control:90.909091MHz; SDRAM:125MHz; HDMI:720P60.
// Clock exceptions and external-I/O validation limits:docs/ARCHITECTURE.md.
// Current control mapping is described at each event source below.
module top (
  input clk,
  input rst_n,  // 板上 A2（手册 KEY1）：复位，保持不动
  input key1,   // 板上 B2（手册 KEY2）：音乐 播放/暂停 + 长按快进
  input key2,   // 板上 C1（KEY4）：短按轮播，长按切歌
  // KEY3 uses a dedicated input; its tap/hold classification is wired below.
  input key3,   // 板上 B1（手册 KEY3）：手动下一张图（独立）

  // [Design note bc-osd]4 位拨码开关（HX4S20：SW[0..3]=C8/C7/C6/C5，
  //   上拉、拨到低有效；厂商 DEMO `8_key_sw` 与原理图证实，本工程此前未用）。
  //   SW[1:0] = 亮度档 {-48,-16,+16,+48}；SW[3:2] = 对比度档 {96,128,160,192}。
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

  // [Design note 缩放·写侧补黑]sd_card_bmp 解析出的源图高度（1..480），
  //   接到 frame_read_write 用来算 VFLIP 写起始 (H-1)*640。
  //   只在图片装载期间有效；H=480 时写侧与原行为逐位相同。
  // [Design note 视频]改名 img_h_img：它现在只是"图片路径"的高度，
  //   img_h_used 变成它和视频(恒 480)之间的选择结果。
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

  // ===================== [Design note 视频]顶层接线 =====================
  // 视频接入方式（详见 rtl/video_player.v 文件头）：
  //   video_player 输出的像素流与 bmp_read 的 write_en/write_data 同语义，
  //   在顶层做 3 路选择（图片 / 视频）：
  //     · vid_active = 1 时，写通路、buffer 索引、帧高全部交给视频
  //     · vid_active = 0 时，所有信号与改动前逐位相同（图片路径不受影响）
  //   不把 mux 塞进 sd_card_bmp 里，是因为那个模块已经承载了首图超时恢复/转场握手
  //   等一堆历史修复，动它风险远大于在这里加一级选择。
  wire img_pad_en, img_pad_high;
  wire [31:0] img_pad_data;
  wire        image_source_high = image_fifo_almost_full | img_pad_high;
  wire        img_write_req;  // sd_card_bmp 的写请求（原 sd_card_write_req）
  wire        img_write_en;
  wire [31:0] img_write_data;
  wire [ 1:0] img_write_buf_idx;
  wire [ 1:0] img_disp_buf_idx;

  wire        vid_active;
  reg         av_started;
  reg  [27:0] av_wait;
  reg         av_audio_failed;
  wire        video_audio_ready;
  wire [ 2:0] directory_image_count;
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
  // [Design note BUGFIX-2]退出视频时打一拍。注意：它没有接到 key_next——
  //   试过并上 key_next 让画面重装，但那条锥直通图片状态机，实测 WNS 从 -346 崩到
  //   -1584（15 个违例端点），所以撤销了。现在它只是留作观测/后续接别处用。
  reg         vid_exit_reload;
  // [Design note 视频 FIX]"长按已被识别，等待安全时机再切换"的挂起位。
  //   为什么需要（这是上板"长按没反应"的真正原因）：
  //     长按的前 ~20ms 和普通短按无法区分，sd_card_bmp 内部消抖会在 20ms 时
  //     认定"按下了"并开始装载下一张图；而 img_loading 会在
  //     "装载(最长 4.7s) + 转场(567ms)" 期间一直是 1。
  //     旧写法要求 video_can_start 里带 !img_loading ⇒ 1.2s 后那个长按脉冲
  //     正好落在装载窗口里 ⇒ 被静默丢弃，所以怎么按都没反应。
  //   现在：KEY3 的手势先由 key_long 分类（长按根本不发 tap ⇒ 不会触发切图），
  //     万一还是碰上装载中，就把意图挂起，等 img_loading 落下立刻执行。
  reg         vid_toggle_pending;
  wire        video_seq_present = |video_available;

  // 视频只要求"首图已提交"（否则屏幕是黑的、交给视频也没意义）与卡上有 .VID。
  // 不再要求 !img_loading：那个条件正是把长按吃掉的原因。
  wire        video_can_start;
  // 视频期间 / 正等待进视频期间，都不允许开始新的切图装载
  wire        vid_lock = video_play | vid_toggle_pending;

  // ---- 写通路 2 选 1 ----
  assign sd_card_write_req  = vid_active ? vid_write_req : img_write_req;
  assign sd_card_write_en   = vid_active ? vid_write_en : img_pad_en;
  assign sd_card_write_data = vid_active ? vid_write_data : img_pad_data;
  assign write_buf_idx      = vid_active ? vid_write_buf_idx : img_write_buf_idx;
  assign disp_buf_idx       = vid_active ? vid_disp_buf_idx : img_disp_buf_idx;
  // 视频帧恒为满帧 640x480 ⇒ VFLIP 起始 (480-1)*640
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

  // ===================== 像素坐标重建 + OSD 字幕 + FFT 频谱 =====================
  // [Design note]rst_all 的声明+赋值提前到所有使用之前
  //   否则 TD 报 HDL-5373"先用后声明"（隐式 1 位 wire ）—— 会让探针同步块的复位失效
  //   （此前它被我的 HDL-5373 白名单"rst_all"掩盖了  —— 白名单过宽 = 闸门盲点  已一并修 ）
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

  // ===================== 转场（淡入淡出）信号 =====================
  // 【转场 FIX 2026-10-07】fader 内联到 OSD 之前（assign vout_data 那一句），
  //   所以这里只需要"图像层淡完的结果"，不再有 fade_de/fade_vs/fade_rgb。
  //   所有跨时钟域信号都在这里先声明（本文件吃过"先用后声明被当隐式 1 位 wire"的亏）。
  wire [23:0] fade_img;  // 图像层淡入淡出后的结果（送给 osd_player_ui 之前）
  wire        fade_busy;  // video_clk 域：转场进行中（淡出或淡入）
  wire        fade_req_toggle;  // sd_card_clk 域：请求淡出（由 sd_card_bmp 驱动）
  wire        fade_done_tgl;  // video_clk 域：淡出完成（fade_in 输出，toggle）
  reg  [ 2:0] fade_req_sync;  // sd -> video 的 3 级同步
  reg  [ 2:0] fade_done_sync;  // video -> sd 的 3 级同步
  reg  [ 1:0] fade_busy_sync;  // video -> sd 的 busy 电平 2 级同步
  wire        fade_req_pulse;  // video_clk 域的 1 拍"开始淡出"脉冲
  wire        fade_done_pulse;  // sd_card_clk 域的 1 拍"淡出完成"脉冲
  wire        fade_switch_lock;  // sd_card_clk 域：转场中 -> 禁止发起新的切图装载
  // 【首图必出图 超时恢复 2026-10-07】sd_card_bmp 的"走了超时超时恢复提交"标志 -> DIG3
  wire        firstimg_fb_seen;
  // 【根因诊断 2026-10-07 #2】超时恢复触发那一拍锁存的 4 位状态：
  //   {wrfin_seen, source_done_seen, bmp_ready, pixel_wr_seen} —— 超时恢复时 DIG3 显示它的十六进制位
  wire [ 3:0] firstimg_diag;

  wire fft_start, fft_done;
  wire [15:0] fft_din_re, fft_din_im;
  wire [15:0] fft_dout_re, fft_dout_im;
  wire       fft_dout_valid;
  wire [7:0] bar_data;
  wire [5:0] bar_addr;  // 48 柱数组（竖线数由 display 的 LINE_PITCH 决定）
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
  wire [3:0]  img_auto_mode;    // [Design note]完整 4 位档位码（显示用：0=关，1..F=档位）
  wire img_auto_on;  // [Design note exp-io]轮播开关本身（扩展板 595 面板用）
  wire [31:0] list_sector;

  // [Design note]fat32_list 解析出的数据区起始扇区（= reserved + num_fats*fat_sz，
  // 本卡实测 32768）。接给 sd_card_bmp 做图片扫描起点，避免从扇区 0 白扫
  // 保留区+FAT 表（原来开机等图 ~5.4s，改后 ~10ms）。
  // 注意：该值在 list_ready 之前无效，所以图片扫描用 sd_init_done & list_ready 使能。
  // [FIX 2026-10-02] These 6 signals were USED in the sd_card_bmp instantiation
  //   below but DECLARED after it, so Verilog implicitly created 1-bit wires:
  //   img_scan_sector (32b -> 1b), img_found_count (3b -> only bit0), and the
  //   phase-B start point img_scan_sector_lat became 0/1  => phase B rescanned
  //   the whole card from sector 0.  TD reported this as 6x HDL-1007
  //   "undeclared symbol" + 6x HDL-7225 "already implicitly declared".
  //   Fix: declare them here, BEFORE any instantiation that uses them.
  wire [31:0] img_scan_sector;
  wire [2:0] img_found_count;
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


  // [Design note 字节级探针]fat32_list 扇区0 的 byte0（本卡是超级软盘，
  // 即 DBR 的 byte0）。只读观测，仅用于 DIG4 译码；声明必须在使用之前。
  wire [7:0] fat_mbr_b0;

  // ===================== 多曲目播放反馈 =====================
  wire wav_track_end;  // wav_reader: 一曲播完（1 拍）
  wire wav_track_bad;  // wav_reader: 指定扇区的头不合法（1 拍）

  // ================================================================
  // 2026-10-12 IMG-PRIO limited pulse -- declarations (MODULE LEVEL)
  //   Auto-carousel loads images back-to-back.  Constant image priority
  //   starves audio off the SD bus: progress bar freezes, sound stops.
  //   Grant the image a bounded window instead: IMG_PRIO_WIN of every
  //   IMG_PRIO_PERIOD cycles.  Audio needs only ~4% of bus bandwidth, so
  //   it still refills its FIFO; each frame still finishes in bounded time.
  //   Must stay module level and above every use site (TD HDL-8007 rejects
  //   declarations inside an unnamed block).
  // ================================================================

  // ===================== SD 卡复用（共享 sd_card_top） =====================
  wire sd_init_done;
  wire vid_sd_grant;
  wire img_sd_grant;
  // [Design note 保险1]只有"已经在播视频 且 已经出过一张图"才允许走 CMD18。
  //   开机扫目录 / 读图片 / 放音频全程 multi_en = 0，永远走原来的单块 CMD17，
  //   所以多块读里的任何 bug 都不可能影响开机、出图、音频 —— 最坏只影响视频。
  // Reuse the existing 8KB CMD18 cache for sequential image loading.
  // Directory/audio keep CMD17; cache hits for images are paced separately.
  wire sd_multi_en = (vid_sd_grant & video_play) | (img_sd_grant & img_loading);
  // 仲裁器：这笔交易属于视频（=> CMD18 多块读）
  reg [7:0] img_data_q;
  reg img_valid_q, img_end_q, img_grant_q;
  wire img_sd_sec_read, wav_sd_sec_read, sd_sec_read;
  assign video_can_start = list_ready && video_seq_present && !img_loading && !img_sd_sec_read;
  wire fat_sd_sec_read;
  wire [31:0] img_sd_sec_read_addr, wav_sd_sec_read_addr, sd_sec_read_addr;
  wire [31:0] fat_sd_sec_read_addr;
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
  // ============================================================================
  // [Design note 结构性时序修复]只给音频客户端的 SD 响应加一级流水。
  //
  //   这个设计反复出现同一个"最差路径族"：
  //       sd_card_sec_read_write 的 FSM 状态（组合译码出 data_valid）
  //       → 各客户端的写使能（wav 的 riff_length.ce 等）
  //   Z1 构建里最后剩下的那 1 条违例（-0.096 ns / 7 级）就是它：
  //       sd_card_sec_read_write/state[1] -> u_wav_reader/u_core/riff_length[7].ce
  //
  //   为什么不在顶层统一延迟：仲裁器的 SERV 靠 sd_sec_read_end 退出，
  //   把 end 延后一拍会让 sd_sec_read 多举一拍，SD 核可能重复触发同一扇区，
  //   多出来那次 read_end 又会污染下一个客户端。
  //   所以只在音频这一路做：data / data_valid / read_end 三者同拍延迟，
  //   仲裁器与 SD 核的握手保持原样。对 wav_player 来说，字节流只是整体晚一拍的
  //   同一组 (data, valid, end)，语义完全不变。
  // ============================================================================
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

  // ============ [Design note fix3]读取器观测位（纯只读，仅数码管调试面板用）====
  //   wav_dbg_state   : wav_reader FSM 状态码
  //   wav_dbg_resync  : 粘滞，resync_pulse 曾经发过（音频停滞超时恢复触发过）
  //   wav_dbg_rdwd    : 粘滞，read_end 握手看门狗曾经超时（read_end 卡过）
  //   这三个 wire 的唯一用途是驱动 seg_scan 的调试面板分支；
  //   不进入任何功能路径，接线错了也只影响显示，不影响音频/视频/SD 行为。
  wire [2:0] wav_dbg_state;
  wire       wav_dbg_resync;
  wire       wav_dbg_rdwd;
  wire [7:0] wav_dbg_fp;  // 【修复7】8 位事件指纹（详见 wav_reader 端口注释）
  wire       wav_dbg_silent;  // 【修复8】静音检测器曾触发   -> DIG0 小数点
  wire       wav_dbg_gate_open;  // [Design note 探针]播放器是否在接受 SD 数据
  reg        gate_open_r;  //   打一拍再送数码管（避免长组合路径拖时序）
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) gate_open_r <= 1'b1;
    else gate_open_r <= wav_dbg_gate_open;
  end
  wire wav_dbg_posbad;  // 【修复8】位置偏差检测器曾触发 -> DIG1 小数点
  wire wav_dbg_dataok;  // [Design note]seek 后数据通路是否已恢复（电平）
  // [Design note]写侧探针（FIFO 饿死那条链）
  wire wav_dbg_wp_seen, wav_dbg_wp_recent, wav_dbg_wp_gate;
  wire wav_dbg_drop_recent;  // [Design note]不粘滞：最近 5ms 内仍在丢请求
  wire        wav_dbg_req_held, wav_dbg_ack_seen;   // [Design note]req_held 电平 + ack 曾来（i2s 侧 ）
  wire wav_dbg_req_stall;  // [Design note]请求曾长期举着没 ack（真停摆 ）
  wire wav_dbg_pcm_odd;  // [Design note](a) seek 后首字节偏移奇数 （(b'') 已删 ）
  // [Design note]端到端累加器（只读 ；口径见 SD 报告附录 A ）
  wire [31:0] wav_dbg_pcm_sum32, wav_dbg_pcm_n32;
  wire [1:0] wav_dbg_lat_req2rden, wav_dbg_lat_rden2v;  // [Design note]把 ack 延迟拆两段
  wire        wav_dbg_req_seen_hi;
  // [Design note]状态驻留 + empty 卡住（只读 ）
  wire [ 3:0] wav_dbg_dwell_state;
  wire [ 1:0] wav_dbg_dwell_grade;
  wire        wav_dbg_empty_stuck;
  // [Design note]活计数版"输出是否冻住"（只读 ）
  wire [ 1:0] wav_dbg_chg_grade;
  wire [11:0] wav_dbg_chg_cnt;
  wire        wav_dbg_chg_last;
  // [Design note] 组14：builder 侧冻结档 + 写入侧冻结探测器（只读）
  wire [1:0] wav_dbg_rddata_frz, wav_dbg_bytelo_frz, wav_dbg_rden_frz;
  wire [11:0] wav_dbg_rddata_chg;
  reg  [1:0]  wav_dbg_wdata_frz;      // 写入侧 wav_pcm_data 的冻结档（3 ⇒ 读取器不再写新字节 ）
  // [Design note] 组15：写入使能冻结档 + 闩锁条件电平位（全部在顶层  0 个新 reader 口 ）
  //   复用：wav_pcm_data 冻结档（= 上面这个  组14 已有 ）
  //   新增：① wav_pcm_valid 的冻结档（形态①写完全停 vs 形态②写恒定字节 的分界）
  //         ③ wav_pcm_byte_cnt >= wav_data_size 的【电平位】（=1 即闩锁条件当场确认）
  reg [1:0] wav_dbg_vldfrz_grade;  // 0=<256 拍 1=<4096 2=<65536 3=≥65536 没写过
  // [Design note] 组16：头部区电平位 + file_byte_cnt 冻结档 + SD 侧冻结档（只读）
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
      else wav_dbg_sdvalid_frz <= 2'd3;  // SD 不再来数据
    end
  end
  // [Design note] 组17：回到【每窗口活计数】风格（唯一被 TB 自证过的模式  组11/组12 ）
  //   为什么换掉"冻结年龄"：组16 证明它在【好态也读到 3】（未自证 ⇒ 读数不可信 ）
  // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。   窗口 ≈ 21ms（2,100,000 拍 @旧控制频率  对齐 1024 帧 @48kHz  ⇒ 与 D 可对比 ）
  //   A = wav_pcm_valid 脉冲数（好≈1024 / 坏≈0 本版核心）
  //   B = wav_pcm_data 变化次数 ｜ C = sd_sec_read_data_valid 脉冲数
  //   D = 复用 i2s 已有的窗口计数 wav_dbg_vld_cnt（组12  已自证 1024  0 新逻辑 ）
  wire [1:0] wav_dbg_vld_grade, wav_dbg_req_grade, wav_dbg_held_grade;
  wire [11:0] wav_dbg_vld_cnt, wav_dbg_req_cnt;
  // [Design note] 组18：G4 直测（只读）
  wire wav_dbg_seek_drain, wav_dbg_resync_pulse;
  reg [11:0] w18_resync_cnt;
  reg w18_pcnt_chg, w18_pcnt_chg_win;
  reg  [31:0] w18_pcnt_prev;
  // [Design note] 组19：SD 侧只读镜像 + 读取器请求电平（本版不需要计数器）
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
        w18_resync_cnt <= w18_resync_cnt + 12'd1;  // [Design note] resync 计数
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
        else w17_a_grade <= 2'd0;  // 读取器不再产 PCM
        if (w17_b_cnt >= 12'd768) w17_b_grade <= 2'd3;
        else if (w17_b_cnt >= 12'd256) w17_b_grade <= 2'd2;
        else if (w17_b_cnt >= 12'd16) w17_b_grade <= 2'd1;
        else w17_b_grade <= 2'd0;
        if (w17_c_cnt >= 12'd768) w17_c_grade <= 2'd3;
        else if (w17_c_cnt >= 12'd256) w17_c_grade <= 2'd2;
        else if (w17_c_cnt >= 12'd16) w17_c_grade <= 2'd1;
        else w17_c_grade <= 2'd0;  // SD 侧不再给数据
        // D：复用 i2s 的窗口计数（1024 帧窗口 ）
        if (wav_dbg_vld_cnt >= 12'd768) w17_d_grade <= 2'd3;
        else if (wav_dbg_vld_cnt >= 12'd256) w17_d_grade <= 2'd2;
        else if (wav_dbg_vld_cnt >= 12'd16) w17_d_grade <= 2'd1;
        else w17_d_grade <= 2'd0;
        w18_pcnt_chg_win <= w18_pcnt_chg;  // [Design note] 窗口内是否推进过
        w18_pcnt_chg <= 1'b0;
        w17_a_cnt <= 12'd0;
        w17_b_cnt <= 12'd0;
        w17_c_cnt <= 12'd0;
      end else w17_t <= w17_t + 22'd1;
    end
  end
  wire        wav_dbg_latch_cond = (wav_pcm_byte_cnt >= wav_data_size) && (wav_data_size != 32'd0);   // [Design note] 闩锁条件电平位（组15 用；组16 插入时曾被误吞  已补回 ）
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
  // [Design note] 组12：供数率活计数（只读）
  // [Design note] 下面两行声明【已前移】到组17 块之前
  //   （原在 386-387 行 ⇒ 组17 块在 351 行先用后声明 ⇒ HDL-5373 隐式 1 位线 ⇒
  //     `wav_dbg_vld_cnt >= 12'd768` 会【恒假】⇒ D 档恒 0  ⇒ 已修 ）
  // [Design note] 组13：输入端活动 + 锁存脉冲（只读）
  wire [1:0] wav_dbg_in_chg_grade, wav_dbg_lat_grade;
  wire [11:0] wav_dbg_in_chg_cnt, wav_dbg_lat_cnt;
  // [Design note]反复播同一帧（只读 ）
  wire [1:0] wav_dbg_rep_grade;
  wire wav_dbg_rep_long;
  wire [3:0] wav_dbg_same_frames;

  reg [1:0] ps_scr;  // 轮显屏号 0..3
  reg  [25:0] ps_scr_cnt;                          // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 ~0.5s @旧控制频率 换屏；26 位 因为 50,000,000 > 2^20-1 （位宽必须装得下常量 ）
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
  // [Design note]音量通路探针（父 agent 指出的"一剑封喉"嫌疑 ）
  //   只读调查结论：player_ctrl.v:42 复位时 volume<=31（满量程 ）；
  //     没有任何 seek/切歌路径会清它 ；只有键盘 `*` 会 -4（下限 0 ）
  //     => volume=0 => gain=volume²=0 => 上游全好、输出纯静音
  //   这两位就是"当前增益是否为 0"（电平）与"增益曾经为 0"（粘滞 ）
  reg         vol_chg_hit;       // [Design note]音量曾经发生过变化（= 有人在按 * / # 或键抖动 ）
  reg [19:0]  vol_chg_cnt;       // 最近一次音量变化后的充电计数（~100ms @12.288MHz = 1228800 拍 => 21 位）
  reg vol_chg_recent_a;  // audio 域活指示
  reg vol_chg_s0, vol_chg_s1;  // 同步到 clk 域（慢电平  2FF ）
  reg [4:0] vol_prev;
  reg       vol_zero_hit;  // 粘滞：音量曾经为 0（= 完全静音 ）
  reg       vol_zero_now;  // 电平：现在音量为 0
  // [Design note]它们产生在 audio_mclk 域，而显示在 clk 域 ⇒ 必须 2 级同步
  //   （慢电平/粘滞位  不是多比特总线 ⇒ 不会撕裂 ）
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

  // key1 / key2 / key3 同步（板载按键，低有效）
  // [Design note 修复]key3 是新增的"图片"按键，同样只加两级同步器，
  //   不做任何消抖时序改动（消抖仍在 sd_card_bmp 内部的 key_press_debounce 里，
  //   沿用它原本的 20ms 参数，未改一行）。
  // [Design note 面积/时序]kp_debug_on 原来是寄存器（复位时装 kp_debug_dflt）。
  //   只要它是寄存器，综合器就无法把 `kp_debug_on ? 调试分支 : 工作状态分支`
  //   这个三目折掉 ⇒ 整条调试显示锥（dbg_d0..d5、20 个 PROBE_GRP 分支、
  //   以及它们背后的 vau_sector / fat32 cur_cluster 深锥）全部留在网表里，
  //   并且成了当时 4 个违例里 3 个的来源（vaudio_sector_r -> seg_data[4]/[2]，
  //   9 级 / -0.454 ns）。这里改成常量，调试分支整块被优化掉。
  //   要恢复调试数码管：把下面这行改回寄存器版本（原来在复位分支里 <= kp_debug_dflt）。
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

  // ============================================================================
  // [Design note exp-io]EDA 扩展板 V3.0：13 路输入（74HC595输出未启用）
  //---------------------------------------------------------------------------
  // 13 路输入（KEY0..KEY4 / SW0..SW7）全部低有效，来自 J1 的杜邦线，属于异步输入：
  //   1) exp_input_sync 里做两级同步 + 8 ms 消抖（8 个 1 ms 采样点全一致才认）
  //   2) 按键输出单拍 press 脉冲，按住不会重复触发
  //   3) 拨码输出逻辑电平（1 = 拨到 ON）
  //
  // 按键功能分配（与交接文档第 5 节一致；全部接在已有的功能入口上，
  // 不新增任何手势逻辑，因此不会和板载按键的手势互相干扰）：
  //   KEY0 -> 视频 暂停/恢复      （等价板载 KEY2(B2) 短按在视频模式下的作用）
  //   KEY1 -> 下一首              （并入 track_ctrl.next_req）
  //   KEY2 -> 下一张图            （50ms 虚拟按键并入 sd_card_bmp.key_next）
  //   KEY3 -> 进入/退出视频        （并入 video_key_hold 长按事件）
  //   KEY4 -> 自动轮播 开/关       （并入 auto_vk 的触发源）
  //   SW0..SW3 -> 轮播周期档 0..15（低有效，全 OFF = 档 0 = 2 秒，见 carousel_period_cfg）
  //   SW4..SW7 -> 保留（同步消抖后引到 exp_sw_level，暂无消费者）
  //
  // 面积：13 路同步/消抖约 170 LE，595 驱动约 100 LE，周期查表约 30 LE。
  // 资源余量以配套最终物理报告为准；输入采样逻辑复用共享tick。
  // 周期选择使用查表，避免运行时除法。
  // ============================================================================
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

  // [Design note]档位码 = 4 个拨码的二进制值，ON 记为 1：
  //   exp_sw_level 已经是“拨到 ON = 1”（exp_input_sync 里把低有效翻回来了），
  //   所以这里不能再取反。原来写成 ~exp_sw_level，结果 4 个拨码全 OFF 时
  //   得到码 15 => 周期 600 秒 => 按 KEY4 打开轮播后 10 分钟不换图，
  //   表现就是“自动切图起不来”。
  //   现在：全 OFF = 码 0 = 2 秒；SW0 ON = 1；SW3 ON = 8；全 ON = 15 = 600 秒。
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

  // KEY2（下一张图）/ KEY4（轮播开关）：下游 sd_card_bmp 的 key_next / key_auto
  //   是【低电平 + 内部 20 ms 消抖】输入，1 拍脉冲会被那条消抖整条滤掉。
  //   这里直接用本模块已经消抖好的电平取反（= 低有效按键），效果等同真按键，
  //   比"脉冲展宽 50 ms"省掉一个 26 位计数器（面积：约 26 个 FF）。
  // In video mode KEY2 selects the previous movie, without queuing an image.
  wire exp_nextimg_key_n = video_play || ~exp_key_down[2];
  wire exp_auto_key_n = ~exp_key_down[4];  // KEY4 按下 = 0

  // ===================== 【面积开关】新功能开关 =====================
  // EG4S20 的 mslice 上限是 4900。加上 button_ctrl + track_ctrl（约 450 LUT）
  // 后实测 mslice = 4990，超出 90，TD 会拒绝布局、无法生成 bit 文件。
  //
  // 【已改为安全默认】用 ifndef DISABLE_PLAYER_CTRL 包住：什么都不定义时默认开启功能。
  // 回到"按键直接切图 / 自动轮播"的原始行为，面积降下来即可烧录；
  // 代价是切歌、快进、播放器按键控制同时失效。
  //
  // 想恢复全部功能：把 0 改回 1。工程里两个 .v 文件保持存在不影响。
  `define USE_PLAYER_CTRL 1

`ifndef DISABLE_PLAYER_CTRL
  // ===================== 板载按键 -> 播放器控制 =====================
  // 这块板只有 2 个用户按键，用"短按/长按"扩展出 5 个功能：
  //   key1 短按 = 播放/暂停（同时继续承担"手动切图"）
  //   key1 长按 = 快进（首次触发后每 100ms 再跳一次，松手停止）
  //   key2 短按 = 下一首
  //   key2 长按 = 上一首
  // [Design note key4-split]上面的按键分工按【用户需求】更新（原 517-520 行作废）：
  //   · wire 名澄清：key1_s2 = 板上 B2（用户称 KEY2）；key2_s2 = 板上 C1（用户称 KEY4）；
  //     key3_s2 = 板上 B1（用户称 KEY3）。旧注释里的 "key2" 指的都是 key2_s2 = KEY4(C1)，
  //     "短按=下一首/长按=上一首"说的就是 KEY4 —— 历史注释名混乱，以此 [Design note] 块为准。
  //   · KEY2(B2)：不变 —— 短按 播放/暂停；长按 快进；双击 自动续播开关
  //   · KEY3(B1)：不变 —— 手动下一张图
  //   · KEY4(C1)：改为 —— 短按 = 图片轮播 开/暂停；长按 = 切歌(下一首)
  //       （原：短按=下一首、长按=上一首；且 key_auto 直连 key2_s2 ⇒ 长按也 toggle 轮播 ）
  //   实现：短按 -> 虚拟按键 auto_vk（展宽 50ms 过 20ms 消抖）-> sd_card_bmp.key_auto；
  //         长按 -> button_ctrl.long_b_tick（严格 1 拍脉冲）-> track_ctrl.next_req；
  //         "上一首"入口撤销（prev_req 绑 0）。
  wire btn_tap_a, btn_tap_b, btn_dbl_a, btn_long_a, btn_long_b, btn_ff_tick;
  wire btn_long_b_tick;  // [Design note] B 键长按触发脉冲（见 button_ctrl）
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
    .long_b_tick(btn_long_b_tick)  // [Design note] KEY4 长按 = 切歌用
  );
  assign btn_pause_evt = btn_tap_a;
`else
  // ---- 关闭新功能：把相关信号绑成"无动作"，逻辑被完全裁掉 ----
  wire btn_tap_a = 1'b0, btn_tap_b = 1'b0, btn_dbl_a = 1'b0;
  wire btn_long_a = 1'b0, btn_long_b = 1'b0, btn_ff_tick = 1'b0;
  wire btn_long_b_tick = 1'b0;  // [Design note]
  wire btn_pause_evt = 1'b0;
`endif

  // ===================== [Design note key4-split]KEY4 短按 -> 轮播开关(虚拟按键) =====================
  // 用户需求：KEY4 短按 = 图片自动轮播 开/暂停，长按 = 切歌。
  //   为什么需要"虚拟按键"：sd_card_bmp 的 key_auto 内部走 key_press_debounce(20ms 消抖)，
  //   它只认【低电平稳定 >=20ms】的完整按压，并在稳定点产生 1 个 press_pulse（toggle 一次）。
  //     · 不能像旧版那样把 key2_s2 直接接 key_auto —— 按下沿即 toggle，【长按也会 toggle】；
  //     · 也不能直接接 btn_tap_b（1 拍脉冲）—— 20ms 消抖会把整个脉冲滤掉 。
  //   做法：btn_tap_b（短按脉冲）到来时，把 auto_vk 拉低 50ms 再回高 —— 恰好被识别为
  //   一次完整短按（20ms 稳定点出 1 个脉冲）；长按路径完全不经过这里 。
  reg [25:0] auto_vk_cnt;   // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 50ms @旧控制频率 = 5,000,000 拍（26 位够：< 67,108,864）
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

  // 快进步进：固定跳 10 秒。
  // 本工程只接受 48kHz/16bit/1~2ch 的 WAV（见 wav_reader 的头校验），
  // 所以最坏情况每声道 2 字节：48000 x 2 x 2 = 192000 B/s -> 10s = 1,920,000 字节。
  // 用常量避免再引入一个乘法器（器件已 92% 满）。
  // 想改快进幅度就改这个数：5s = 960000，30s = 5,760,000。
  // [Design note]快进步长按【解析出的声道数】选常数（不再固定按立体声）
  //   板级事实（用户 SD 卡实测）：01star.wav / 02gods.wav 都是 48kHz/16bit/mono
  //     => 真实码率 48000 x 1 x 2 = 96000 B/s => 10 秒 = 960,000 字节
  //   原来固定写 1_920_000（按立体声算）=> 对单声道文件其实跳了 20 秒
  //     （与用户"按一下跳约 1 分钟"一致：长按连发 ~3 跳 x 20 秒 ）
  //   注意：进度/时间显示本来就是对的  —— playback_status.v:46-47 用
  //     bps = sample_rate x channels x (bit_depth>>3) 从【解析出的头】算
  //     => 单声道自动得 96000 （所以"显示差 2 倍"不成立 ，已核实）
  //   本处修正只影响【一次快进跳多远】
  //   实现：读取器已强制 48kHz/16bit（见 wav_reader 头部校验）=> 只有声道数可变
  //     => 用 2 选 1 常数（不是运行时乘法）=> 0 DSP 新增
  wire [31:0] ff_step_bytes = (wav_channels == 16'd2) ? 32'd1_920_000  // 立体声: 192000 B/s x10s
  : 32'd960_000;  // 单声道:  96000 B/s x10s
  localparam [31:0] FF_STEP_BYTES = 32'd1_920_000;   // 仅作"立体声档"参考值（不再直接用）

`ifndef DISABLE_PLAYER_CTRL
  // ===================== 多曲目控制（切歌） =====================
  // track_ctrl 持有当前曲目号，并按 song_count 取模推进；
  // 同一个 song_idx 既用于"取扇区"，也接到 OSD 显示歌名（见下方 fat32_list.list_idx）。
  wire        track_sel_valid;
  wire [31:0] track_sel_sector;
  wire [ 5:0] play_song_idx;
  wire        auto_en;

  // [Design note 声明顺序]vau_tgt 在这里先声明（真正的驱动逻辑在下面 VAU 切换 FSM 里），
  //   因为本行之后不远处就要用它门控 track_ctrl 的 track_end。
  reg         vau_tgt;  // 目标源：1 = .VAU, 0 = 歌单

  track_ctrl u_track_ctrl (
    .clk(sd_card_clk),
    .rst_n(rst_n),
    .list_ready(list_ready),
    .song_count(song_count),
    // 歌单按 song_idx 组合给出的本曲起始扇区（给 wav_reader 起播）
    .sel_sector_in(list_sector),
    // 板载按键事件
    // [Design note] 用户新分工：KEY4 长按 = 切歌(下一首)；短按让位给图片轮播。
    //   · next_req 用【严格 1 拍脉冲】btn_long_b_tick（button_ctrl 新增）——
    //     本模块是电平式消费、无一次性门控；若接 long_b 电平，按住期间会每拍推一次索引 。
    //   · prev_req 原接 btn_long_b（电平，同隐患）——"上一首"入口按用户需求撤销，绑 0。
    // [Design note exp-io]扩展板 KEY1 也接进"下一首"（单拍脉冲，与键盘 C 或起来）
    .next_req((kp_next_song || exp_next_song_evt) && !video_play),
    .prev_req(1'b0),  // [Design note] 撤销（原 btn_long_b = 长按上一首）
    .auto_togg(btn_dbl_a && !video_play),  // key1 双击   = 自动续播 开/关
                            //（key2 已被图片轮播占用，key1 单击已用于
                            //  播放/暂停、长按已用于快进，所以用双击）
    // wav_reader 反馈
    // [Design note BUGFIX]视频音轨（vau_tgt=1）期间不要把 track_end 送给 track_ctrl：
    //   原来直接连，而 auto_en 默认是 1（默认自动续播），于是视频音轨一播完
    //   （或被 track_bad 打断）就把歌单索引推进一首 —— 实测表现就是
    //   "退出视频后放的变成了另一首歌"。视频期间歌单索引应当冻结，
    //   视频音轨不会自动从头重选；用户重新进入视频时才会重选。
    .track_end(wav_track_end && !vau_tgt && !video_play),
    .track_bad(wav_track_bad && !video_play),
    // 输出
    .song_idx(play_song_idx),
    .track_sel_valid(track_sel_valid),
    .track_sel_sector(track_sel_sector),
    .auto_en(auto_en)
  );
`else
  // ---- 关闭切歌：wav_reader 不收到选曲脉冲，保持原来"扫描到第一个 WAV 就播"的行为 ----
  // （wav_reader 的 scan_start 由顶层给出，见下方其实例化）
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

  //=== [Design note] ========================================
  // 改动：新增【音频下游只读探针组】——audio_mclk 域 4 个 reset-only 粘滞位，
  //       2 级同步到 clk 域，由 DOWN_PROBE 选择是否在数码管上显示
  // 原因：读取器侧已有 8 位指纹，但【音频下游（FIFO/样本构造器/I2S）从来没有探针】。
  //       用户症状"要么没声音、要么全杂音"里"全杂音"是典型的【字节配对/相位】特征，
  //       所以必须能一眼看出：下游有没有在产出样本、有没有长时间欠载、I2S 在不在跑。
  // 证据：（静态调查）wav_sample_builder.v 是 4 状态字节配对机（每帧 8 拍）；
  //       i2s_transmitter.v 在【帧边界直接锁存】sample_left/right；
  //        wav_sample_valid 在顶层【没有任何消费者】=> 配对完全取决于
  //         builder 的完成节奏与 FIFO 是否有数据 => 欠载/停摆必须可观测
  // 影响：只写显示寄存器、只驱动数码管 ⇒ 不进任何功能表达式 ；
  //       DOWN_PROBE=0（默认）时显示与 fix7-diag 完全一致
  // 相关：见 CHANGELOG_源码改动登记.md 的同编号条目
  //============================================================================
  //   判读（audio 域粘滞位，只由 rst_all 清）：
  //     au_sv_hit    : 样本构造器曾产出过样本     -> 正常 1（常 0 = 从没出声 ）
  //     au_empty_hit : FIFO 曾连续欠载 > ~1.6ms   -> 正常 0（常 1 = 音频断流 ）
  //     au_lrck_hit  : I2S 的 LRCK 曾翻转（在跑） -> 正常 1（0 = I2S 死了 ）
  //     au_stall_hit : 既欠载又从未产出样本       -> 正常 0（1 = 下游彻底断流 ）
  localparam [15:0] AU_EMPTY_LIMIT = 16'd20_000;  // @12.288MHz 约 1.6ms
  //=== [Design note] ==========================================
  // 改动：音频域探针加两位（au_valid_hit / au_starve_after_ok），同步向量 4->6 位；
  //       探针组选择从 1 位 DOWN_PROBE 改为 2 位 PROBE_GRP（0=读取器 1=数据流 2=下一层）
  // 原因：① 板级 DIG1=3 分不清"seek 瞬间的正常空档"还是"持续断流"
  //          => 加 au_starve_after_ok = "已经出过样本之后仍长时间欠载" = 真问题判别位
  //       ② 数据流全正常但仍无声时，需要继续往下钉 => 探 I2S_receiver 的 O_audio_valid
  // 证据：板级 fix9_dataflow = 3 3 2 3 0 3
  //       · DIG0=3 => seek 后数据已恢复   · DIG5=3 且 bit7=0 => 无错位锁存
  //       · DIG2=2 => 文件是 mono（进度存档_20261002.md:137：两首均 48k/16bit/mono，
  //         23685198B ÷ 96000B/s = 246.7s = 4:07 与用户"总长 4:06"吻合 ）=> stereo=0 正常
  // 影响：只写显示寄存器；PROBE_GRP 是常量 ⇒ 只影响 debug 分支显示
  // 相关：见 CHANGELOG_源码改动登记.md 的同编号条目
  //============================================================================
  // [Design note]探针组选择（2 位常量；只改它=换一组显示，功能逻辑完全不动 ）
  //   0 = 读取器组（地址/状态/8 位指纹）
  //   1 = 数据流组（seek 后数据是否恢复 / FIFO 欠载 / stereo）
  //   2 = 下一层组（I2S_receiver 的 audio_valid / 看门狗 / resync）
  // [Design note]FIFO 水位档（写侧视角；async_fifo 提供 wr_usedw  DEPTH=4096）
  //   0 = < 512（很空）｜1 = 512~2047（低）｜2 = 2048~3071（中）｜3 = >= 3072（到 almost_full 阈值）
  // [Design note]随 FIFO 8192 按原比例重标：512/2048/3072 -> 1024/4096/6144
  wire [1:0] fifo_lvl = (fifo_usedw <  14'd1024) ? 2'd0 :
                          (fifo_usedw <  14'd4096) ? 2'd1 :
                          (fifo_usedw <  14'd6144) ? 2'd2 : 2'd3;



  // [Design note 切图音频中断修复]img_seen：一旦出过图就永久为 1。
  //   原来 img_priority 里的 ~display_valid 在【切图期间】也会为 1（新图还没提交），
  //   于是后面 img_loading & fifo_lvl[1] 的水位门控被完全短路 —— 整张图（最大 14.75MB
  //   ≈ 12 秒）音频一个扇区都拿不到，32ms 的 FIFO 立刻见底，播放器看门狗超时。
  //   改成"只有从未出过图（开机）才让图片绝对优先"，切图期间交由水位门控。
  reg img_seen;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) img_seen <= 1'b0;
    else if (display_valid) img_seen <= 1'b1;
  end
  // [Design note]消费端观测（板级读数：FIFO 满  + 门控正常  => 消费端没在取 ）
  //   ① 写侧"最近 5ms 内有写"（替换之前无意义的 20µs 窗口 —— 读取器是整扇区突发写 ）
  //   ② 构造器状态机状态码（CDC 2FF；状态码是多比特，理论上可能撕裂 —— 只用于"卡在哪个状态"的粗判 ）
  //   ③ 构造器的 sample_req 是否被丢过（1 位粘滞  CDC 安全 ）
  //   ④ i2s 的 LRCK 是否在翻转（1 位粘滞  CDC 安全 ）
  reg  [19:0] wp5_cnt;                       // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 写之后计数（500000 拍 = 5ms @旧控制频率）
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
  // [Design note]把 audio_rst 的声明+赋值提前到使用之前
  //   （原来声明在第 713 行，而我的采样在第 538 行 => HDL-5373"先用后声明"⇒ 会被当隐式 1 位 wire
  //     且闸门会拦下 ）—— 语义完全不变，只是位置前移
  wire audio_rst;
  assign audio_rst = ~rst_n | ~audio_pll_lock;

  reg lrck_hit;
  // [Design note]活的 LRCK 指示（5ms 充电窗 ）—— 粘滞位无法回答"现在还在动吗"
  //   + audio_rst 电平采样（用 DIG2 的小数点显示 ⇒ 直接看"音频域是不是在复位"）
  reg [19:0] lrck_recent_cnt;                // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 5ms @旧控制频率 = 500000 拍（20 位够 ）
  reg audio_rst_s;
  // [Design note]三位只读探针（放在 lrck_hit / lrck_recent_cnt / audio_rst_s 声明【之后】
  //   否则就是 HDL-5373"先用后声明"⇒ 隐式 1 位线 ⇒ `lrck_recent_cnt == 20'd0` 恒假 ⇒
  //   lrck_stopped 永远报不出来 —— 闸门已当场拦下并修好 ）
  //=== [Design note] ======================================
  // 为什么改：粘滞/档位型仪器【连续三次】都没能分辨故障 （组7/组9/组8）
  //   ⇒ 根因：粘滞位天然测不了"事件【停止】" —— 例如 `lrck_stopped` 要求
  //     `lrck_hit`（曾动过 ）⇒ 若 LRCK 从未动过就【永远报不出来】
  //   ⇒ 改为【活计数型】：每 5ms 窗口数 LRCK 边沿
  //     预期 ≈ 48kHz × 5ms ≈ 240 个/窗口 （好态稳定 ；坏态直接掉到 ≈0 ⇒ 一眼可见）
  //   另修正 pll_lock_lost：先见 1 再变 0 才算"失锁"（屏蔽上电锁定过程
  //     —— 板级读数证明原粘滞位被上电窗口污染 ：正常态也读到 1 ）
  reg pll_lock_seen;  // audio_pll_lock 曾经为 1（先见锁定 ）
  reg [21:0] pll_lock_stbl;    // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 [Design note] lock 稳定拍数（40ms@旧控制频率）⇒ 屏蔽上电窗口
  reg pll_lock_lost;  // 先见 1 之后再变 0 ⇒ 真失锁
  reg [19:0] lrck_win;  // 本窗口 LRCK 边沿计数（500000 拍里数  19 位够 ）
  reg [18:0] lrck_win_t;       // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 窗口计时（5ms @旧控制频率 = 500000  < 2^19 ）
  reg [15:0] lrck_edges_win;  // 上一窗口的边沿数（供显示 ）
  reg [1:0] lrck_grade;  // 档位：3=≈预期 2=偏少 1=很少 0=≈0（时钟死 ）
  reg lrck_lvl_now;  // 当前 LRCK 电平（非粘滞，静止时也能读 ）
  // [Design note 诊断]wav_track_bad 是单拍脉冲，200 Hz 扫描的数码管几乎抓不到，
  //   所以之前读到的 "track_bad=0" 并不能证明没发生过。这里做成一位粘滞标志：
  //   一旦发生过就永久点亮，直到复位。声明放在这里（先声明后使用 ）。
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
          pll_lock_stbl <= pll_lock_stbl + 22'd1;  // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 40ms@旧控制频率
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
  // 【已删除】旧的 #fix25 残留块  —— 它还在驱动 `pll_lock_lost` ⇒ 与 #fix26 的块构成
  //   【多驱动】 ⇒ 被 SYN 闸门当场拦下 （本轮构建【没有】写出 bit ）
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
      // [Design note]活的 LRCK：一旦翻转就把 5ms 窗充满
      if (lrck_s1 != lrck_d) lrck_recent_cnt <= 20'd500_000;
      else if (lrck_recent_cnt != 20'd0) lrck_recent_cnt <= lrck_recent_cnt - 20'd1;
      audio_rst_s <= audio_rst;
    end
  end
  localparam [4:0]  PROBE_GRP      = 5'd4;   // 0=读取器 1=数据流 2=下一层 3=写侧组 4=消费端组
  reg au_sv_hit, au_empty_hit, au_lrck_hit, au_stall_hit;
  // [Design note]两个新位（都是父 agent 点名要的）：
  //   au_valid_hit       : 下一层【I2S_receiver 的 O_audio_valid】曾出现
  //                        => 证明 I2S -> receiver -> HDMI 音频包 这一层收到过有效样本
  //   au_starve_after_ok : 在【已经出过样本之后】FIFO 仍长时间欠载
  //                        => 这一位才是"真问题"；为 0 说明 au_empty_hit 只是启动/seek 瞬间的正常空档
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
      // [Design note]关键判别位：已经出过样本之后还长时间欠载 = 真问题
      if (fifo_empty && au_sv_hit && (au_empty_cnt >= AU_EMPTY_LIMIT)) au_starve_after_ok <= 1'b1;
      // [Design note]下一层：I2S_receiver 报出有效样本
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
  // ---- [Design note]stereo / channels 可观测（C1/C5 最高嫌疑，之前完全没有探针 ）----
  //   为什么最关键：wav_sample_builder 按 stereo 决定【每帧读 4 字节还是 2 字节】
  //     => stereo 与实际文件不符 => 每次取错字节数 => 字节配对全错 => 全杂音
  //   两位都只驱动显示 ：DIG2 小数点 = stereo 当前值；DIG3 小数点 = 曾解析出非 2 声道
  reg ch_not2_hit;  // [sd 域] wav_ready 时曾经解析出 wav_channels != 2
  always @(posedge clk or posedge rst_all) begin
    if (rst_all) ch_not2_hit <= 1'b0;
    else if (wav_ready && (wav_channels != 16'd2)) ch_not2_hit <= 1'b1;
  end
  reg stereo_o0, stereo_o1;  // [audio 域 stereo] 2FF 同步到 clk 域（单比特，安全 ）
  //   注：stereo_o0/o1 的驱动块放在下面 stereo 声明之后（声明必须先于使用 ）
  // 键盘调试信号跨到 clk 域（慢变信号，两级同步即可）
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

      //=== [Design note] ==============================================
      // 改动：调试面板分支（kp_debug_on=1）重新分配数码管：DIG0/1/2=读取器地址低12位，
      //       DIG3=FSM状态码，DIG4/DIG5=wav_reader 的 8 位事件指纹；DIG5 小数点=sd_sec_read
      //       电平，DIG0/DIG1 小数点=两个自愈检测器的粘滞位
      // 原因：前四轮"推理找根因"每轮 TB 都过、上板都不改善 => 必须靠板级可观测性定位；
      //       实测证明有效：用户念一次读数（DIG4=0 / DIG5=b）就当场钉死了根因
      // 证据：板级读数 DIG4=0（bit3 从未进放空）+ DIG5=b（bit6=0 rd_cnt 未清 / bit7=1 锁存时
      //       rd_cnt≠0）=> 直接指向 fix7 那条根因
      // 影响：只在 kp_debug_on=1 时生效（diag 版 bit）；正常版 kp_debug_dflt=0，
      //       正常显示分支一位未动 ；两版 bit 的显示互不影响
      // 相关：见 CHANGELOG_源码改动登记.md 的同编号条目
      //============================================================================        // ============ [Design note diag-v2]探针位重分配 ==================
      //   背景：用户报"按快进后无声"，而进度条一直在走 ⇒ 原来 DIG5 显示
      //   pcm_out_cnt[19:16] 的信息量已经很低 ⇒ 换成最能定位握手互锁的三样：
      //     ① 读取器请求电平 wav_sd_sec_read  → 用 DIG5 的小数点看
      //     ② 读取器地址 wav_sd_sec_read_addr → DIG0/DIG1/DIG2/DIG5 四个十六进制位
      //     ③ FSM 状态码 + 粘滞位                  → DIG3 / DIG4（沿用 fix3）
      //   关键判据：故障时若【小数点常亮】(请求一直举着) 且【地址数字冻住不动】
      //     ⇒ 就是"举着请求等 read_end"的握手互锁
      //   注1：DIG0~DIG2 在 debug 分支里原本显示键盘矩阵，此处按父 agent 批准借用；
      //        正常分支（kp_debug_dflt=0）一位都没动
      //   注2：地址只显示 bit[15:0]（本卡扇区号 ≤ 36441 < 65536 ⇒ 足够）
      if (PROBE_GRP == 5'd1) begin
        // ==== [Design note]一次读完"数据到底有没有送到音频侧" ====
        //   板级证据：读取器状态机健康（DIG3=3、指纹显示进放空/清 rd_cnt/干净上升沿 ）
        //   但下游 FIFO 一直欠载（1111）=> 唯一缺口在【读取器的数据输出侧】
        //   DIG0 = {样本构造器曾产出, seek 后数据是否已恢复}  -> 正常 11 = 3
        //   DIG1 = {下游彻底断流, FIFO 曾长时间欠载}         -> 正常 00 = 0
        //   DIG2 = {曾解析出非2声道, 当前 stereo}            -> 正常 01 = 1（立体声）
        //   DIG3 = 读取器 FSM 状态码                          -> 正常 3
        //   DIG4/DIG5 = 读取器 8 位指纹（bit7 语义已修正 ）
        dbg_d0 <= hex7({2'b00, au_s1[0], wav_dbg_dataok});
        dbg_d1 <= hex7(
            {2'b00, au_s1[5], au_s1[1]}
        );  // {出过样本后仍欠载(真问题), FIFO曾长时间欠载}
        dbg_d2 <= hex7({2'b00, ch_not2_hit, stereo_o1});
        dbg_d3 <= hex7(
            {1'b0, wav_dbg_state}
        );  // [Design note]读取器状态码（正常 3 ；音量变化位随键盘拆除失效 ⇒ 已去掉 ）
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd20) begin
        // ==== [Design note] 组20：最小探针版（纯显示，无新 always）====
        //   用户新事实："歌能播完；只要快进就没声音，不管落点原来有没有声音"
        //     => 快进后【输出整体停止且再不自愈】，只有复位能恢复
        //   主问题：快进后 seek_drain 是否卡在 1
        //     （它是 PCM 输出块的门 G4；且 drain 分支会 hold pcm_out_cnt；
        //       它的出口只有 sd_sec_read_end 与 track_sel => 没人清就永久静音）
        //   DIG0 = {3'b000, seek_drain}  1 = 卡住 => PCM 全被门控 => 永久静音
        //   DIG1..DIG4 = 请求扇区 sd_sec_read_addr 的 [15:12]/[11:8]/[7:4]/[3:0]
        //                （4 位十六进制，作对照：快进时落点是否 +约1875）
        //   DIG5 = {2'b00, seek_drain, sd_sec_read_addr[0]}
        //          bit0 = 请求扇区奇偶（预期恒 0）；bit1 = seek_drain 电平（同 DIG0）
        //   判读：快进后 DIG0=1 => seek_drain 卡住（首发嫌疑成立，与"只有复位能恢复"吻合）
        //         快进后 DIG0=0 且声音仍无 => 那道门不是唯一原因 => 回数据/相位侧
        dbg_d0 <= hex7({3'b000, wav_dbg_seek_drain});
        dbg_d1 <= hex7(wav_sd_sec_read_addr[15:12]);
        dbg_d2 <= hex7(wav_sd_sec_read_addr[11:8]);
        dbg_d3 <= hex7(wav_sd_sec_read_addr[7:4]);
        dbg_d4 <= hex7(wav_sd_sec_read_addr[3:0]);
        dbg_d5 <= hex7({2'b00, wav_dbg_seek_drain, wav_sd_sec_read_addr[0]});
      end else if (PROBE_GRP == 5'd19) begin
        // ==== [Design note] 组19：SD 侧可观测性（只观测）====
        //   组18 已裁决：坏态 DIG2=0 => SD 侧停止供数。本版分清三种原因：
        //   H-a 读取器不再发请求 / H-b SD 命令出错回 IDLE 且无重试 / H-c 卡不响应
        //   DIG0 = cmd_req_error 曾置1（粘滞，只由 rst 清）
        //   DIG1/DIG2 = SD 读写 FSM 状态码：state = DIG1*8 + DIG2
        //        0=S_IDLE 1=CMD0 2=CMD8 3=CMD55 4=CMD41 5=CMD17 6=S_READ
        //        7=CMD24 8=WRITE 14=S_ERR 15=WRITE_END 16=READ_END 17=WAIT 18=CMD16
        //   DIG3 = {3'b000, wav_sd_sec_read} 读取器请求电平（1 = 仍在请求/等待 end）
        //   DIG4/DIG5 = 读取器 8 位指纹（沿用其它组语义）
        //   判读：DIG3=1 且 DIG0=1 => H-b（命令出错且无重试）；DIG3=0 => H-a（不再请求）；
        //        DIG3=1 且 DIG0=0 且 state≈IDLE => H-c（卡不响应）
        dbg_d0 <= hex7({3'b000, wav_dbg_sd_cmd_err});
        dbg_d1 <= (video_play ? vau_fault_seg : hex7({2'b00, wav_dbg_sd_state[4:3]}));
        dbg_d2 <= hex7({1'b0, wav_dbg_sd_state[2:0]});
        dbg_d3 <= hex7({3'b000, wav_sd_sec_read});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd18) begin
        // ==== [Design note] 组18：直测 PCM 输出的门 G4（只观测）====
        //   只读审查（pcm_gate_audit ）锁定头号嫌疑：G4 = `!seek_drain`
        //   DIG0 = `seek_drain` 电平位
        //        1 ⇒ 放空窗口卡住 ⇒ PCM 全被门控 ⇒ 且 :739-746 会 hold pcm_out_cnt
        //          ⇒ 计数冻结 ⇒ 100ms resync 反复触发却清不掉它 ⇒ 永久静音
        //   DIG1 = resync_pulse 的窗口计数档 若在反复触发而仍静音 ⇒ 坐实"修不好"
        //   DIG2 = SD 侧 sd_sec_read_data_valid 窗口档（= 组17 的 C  已被自证的模式 ）
        //   DIG3 = {3'b000, 本窗口内 pcm_out_cnt 是否推进过}
        //        0 ⇒ 永久没推进（与 seek_drain=1 互为旁证 ）
        //   DIG4/DIG5 = resync 计数的低 8 位（持续非 0 ⇒ resync 在响）
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
        // ==== [Design note] 组17：每窗口活计数（组11/12 风格  已被 TB 自证 ）====
        // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。   窗口 ≈21ms（2.1M 拍 @旧控制频率  ≈ 1024 帧 @48kHz ）
        //   DIG0 = A 档（wav_pcm_valid 每窗口脉冲数）
        //         3 ⇒ ≈1024（读取器在产 PCM  正常） ｜ 0 ⇒ ≈0（读取器不再产 PCM核心）
        //   DIG1 = B 档（wav_pcm_data 变化次数） 3 ⇒ 数据在变 ；0 ⇒ 数据恒定
        //   DIG2 = C 档（SD 侧 sd_sec_read_data_valid 脉冲数） 3 ⇒ SD 仍在给 ；0 ⇒ SD 停了
        //   DIG3 = D 档（builder 侧 sample_valid；复用 i2s 窗口计数 ） 正常 3
        //   DIG4/DIG5 = A 计数的 bit[11:8] 与 bit[7:4]  正常 ≈ 4 / 0（1024 = 0x400）
        //   判读（先写死 ）：
        //      DIG0=0 且 DIG3=3 ⇒ 读取器不再产 PCM，而 builder 侧仍活 ⇒ 卡在读取器
        //        （再看 DIG2：=3 ⇒ SD 仍在给数据 ⇒ 读取器有数据却不输出）
        //      DIG0=0 且 DIG2=0 ⇒ SD 侧也停了 ⇒ 查 SD
        //      DIG0=3 ⇒ 读取器在产 PCM ⇒ 与组11"输出冻住"矛盾 ⇒ 间歇 ⇒ 故障瞬间再读
        dbg_d0 <= hex7({2'b00, w17_a_grade});
        dbg_d1 <= hex7({2'b00, w17_b_grade});
        dbg_d2 <= hex7({2'b00, w17_c_grade});
        dbg_d3 <= hex7({2'b00, w17_d_grade});
        dbg_d4 <= hex7(w17_a_cnt[11:8]);
        dbg_d5 <= hex7(w17_a_cnt[7:4]);
      end else if (PROBE_GRP == 5'd16) begin
        // ==== [Design note] 组16：PCM 输出条件的另一半（只观测）====
        //   组15 已证 DIG2=0 ⇒ "到顶闩锁"未触发 ⇒ 真凶必是另一项：
        //     file_byte_cnt >= data_offset  ⇒ 读取器卡在【WAV 头区之前】
        //   DIG0 = {2'b00, file_byte_cnt < data_offset 电平位}
        //          =1 ⇒ 仍在头部区（写到不了 PCM 数据区） —— 本版核心判据
        //   DIG1 = {2'b00, file_byte_cnt 冻结档}  3 ⇒ 字节计数卡住
        //   DIG2 = {2'b00, SD 侧 sd_sec_read_data_valid 冻结档}
        //          档 0/1/2 ⇒ SD 数据仍在来（但读不到 data_offset）
        //          档 3 ⇒ SD 不再来数据 ⇒ 查 SD 侧
        //   DIG3 = {1'b0, 读取器状态码} ｜ DIG4/DIG5 = wav_pcm_byte_cnt 低 8 位
        //   判读（先写死 ）：
        //      DIG0=1 且 DIG2 档 0/1/2 ⇒ 数据在来、但一直停在头部区
        //        ⇒ 查头解析/对齐（data_offset 解析、rd_cnt/扇区对齐、read_end ）
        //      DIG0=1 且 DIG2=3 ⇒ SD 数据不再来 ⇒ 查 SD 侧
        //      DIG0=0 ⇒ 已过头部区 ⇒ 与组15 结论矛盾 ⇒ 需重审
        dbg_d0 <= hex7({2'b00, wav_dbg_hdr_phase});
        dbg_d1 <= hex7({2'b00, wav_dbg_fbcnt_frz});
        dbg_d2 <= hex7({2'b00, wav_dbg_sdvalid_frz});
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_pcm_byte_cnt[7:4]);
        dbg_d5 <= hex7(wav_pcm_byte_cnt[3:0]);
      end else if (PROBE_GRP == 5'd15) begin
        // ==== [Design note] 组15：区分"写完全停"与"写恒定字节"，只观测 ====
        //   判读核心：DIG1（写入使能冻结档）+ DIG2（闩锁条件电平位）
        //   DIG0 = {2'b00, wav_pcm_data 冻结档}   （= 组14 的 DIG1  保留 ）
        //   DIG1 = {2'b00, wav_pcm_valid 冻结档}  3 ⇒ 写入【完全停】（形态①）
        //                                             档 0/1/2 ⇒ 仍在写 ⇒ 形态②（写恒定字节）
        //   DIG2 = {3'b000, 闩锁条件电平位}     =1 ⇒ wav_pcm_byte_cnt >= wav_data_size
        //                                              ⇒ 闩锁条件当场确认
        //   DIG3 = {2'b00, 写入使能年龄档的补充}（暂同 DIG1，留位 ）
        //   DIG4/DIG5 = wav_pcm_byte_cnt 的低 8 位（看它是否卡住 ）
        //   判读（先写死 ）：
        //      DIG2=1 且 DIG1=3 ⇒ 闩锁确认：pcm_out_cnt 到顶 ⇒ 写入永久停
        //      DIG2=0 且 DIG1=3 ⇒ 另有原因（SD 数据不再来 ⇒ 查 SD 侧 ）
        //      DIG1 档 0/1/2 而 DIG0=3 ⇒ 形态②：在写恒定字节 ⇒ 查读地址/越界
        dbg_d0 <= hex7({2'b00, wav_dbg_wdata_frz});
        dbg_d1 <= hex7({2'b00, wav_dbg_vldfrz_grade});
        dbg_d2 <= hex7({3'b000, wav_dbg_latch_cond});
        dbg_d3 <= hex7({2'b00, wav_dbg_vldfrz_grade});
        dbg_d4 <= hex7(wav_pcm_byte_cnt[7:4]);
        dbg_d5 <= hex7(wav_pcm_byte_cnt[3:0]);
      end else if (PROBE_GRP == 5'd14) begin
        // ==== [Design note] 组14：冻结探测器（活电平型），只观测 ====
        //   为什么不用窗口计数：冻结"年龄"是电平型 ⇒ 任何时刻都能读  非粘滞
        // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。   口径：0=<256 拍 ｜ 1=<4096 ｜ 2=<65536 ｜ 3=≥65536 拍（≈0.65ms@旧控制频率）没变过
        //   好态必须全为 0（阈值远离正常值  满足纪律10 ）
        //   DIG0 = fifo_rd_data 冻结档  3 ⇒ FIFO 读数据恒定（组13 已指向这一格 ）
        //   DIG1 = 写入侧 wav_pcm_data 冻结档  3 ⇒ 读取器不再写新字节 ⇒ 读取器侧
        //   DIG2 = fifo_rd_en 冻结档  3 ⇒ rd_en 停脉冲（与"valid 必先耗 2/4 个 rd_en"矛盾 ⇒ 不会出现 ）
        //   DIG3 = byte_lo 冻结档 ｜ DIG4/DIG5 = fifo_rd_data 累计变化次数的低 8 位
        //   判读：DIG1=3 ⇒ 读取器侧（A 类）
        //         DIG1=0 而 DIG0=3 ⇒ 写入在变但 FIFO 读出恒定 ⇒ 极端情况，需重新审视 B 类
        //         DIG0=0 且 DIG1=0 ⇒ 数据在流 ⇒ 请在故障瞬间再读一次
        dbg_d0 <= hex7({2'b00, wav_dbg_rddata_frz});
        dbg_d1 <= hex7({2'b00, wav_dbg_wdata_frz});
        dbg_d2 <= hex7({2'b00, wav_dbg_rden_frz});
        dbg_d3 <= hex7({2'b00, wav_dbg_bytelo_frz});
        dbg_d4 <= hex7(wav_dbg_rddata_chg[7:4]);
        dbg_d5 <= hex7(wav_dbg_rddata_chg[3:0]);
      end else if (PROBE_GRP == 5'd13) begin
        // ==== [Design note] 组13：把最后两种可能分开，只观测 ====
        //   背景：组11 = 坏态"输出冻住"；组12 = 两态 `330400` ⇒ 供给链健康 ⇒ 落在【取用/锁存侧】
        //   DIG0 = {2'b00, 输入端活动档}  正常 3（每帧变 1 次 ≈1024）
        //          0 ⇒ 输入端本身就冻 ⇒ 问题在【builder 的样本寄存器 / FIFO 读数据】
        //   DIG1 = {2'b00, 锁存脉冲档}    正常 3（锁存条件每帧都成立） 0 ⇒ 锁存没发生
        //   DIG2 = {3'b000, 锁存拍采到的值是否与上次相同} 正常在 0/1 间跳 恒 0 ⇒ 冻住
        //   DIG3/DIG4/DIG5 = 上一窗口"输入端变化次数"的 12 位 正常 ≈ 4/0/0 = 1024
        //   判读：DIG0=0 ⇒ 输入端冻 ⇒ 查 builder/FIFO 读数据
        //         DIG0=3 而输出仍冻 ⇒ 问题在【I2S 锁存/取用本身】（锁存使能/采样时刻）
        //   口径注意：DIG1 数的是"锁存条件成立的【拍数】"（bclk 高期间成立多拍 ⇒ 会饱和 ）
        //            ⇒ 只看档位，别把饱和值当帧数
        dbg_d0 <= hex7({2'b00, wav_dbg_in_chg_grade});
        dbg_d1 <= hex7({2'b00, wav_dbg_lat_grade});
        dbg_d2 <= hex7({3'b000, wav_dbg_chg_last});
        dbg_d3 <= hex7(wav_dbg_in_chg_cnt[11:8]);
        dbg_d4 <= hex7(wav_dbg_in_chg_cnt[7:4]);
        dbg_d5 <= hex7(wav_dbg_in_chg_cnt[3:0]);
      end else if (PROBE_GRP == 5'd12) begin
        // ==== [Design note] 组12：供数率活计数（组11 的镜像），只观测 ====
        //   组11 已证实坏态【输出冻住】（每 1024 帧变化数 = 0）。本组回答"供不上 vs 没取走"：
        //   DIG0 = sample_valid 档  正常 3（≈1024） 0 ⇒ 供数停了（构造器/FIFO/握手侧 ）
        //   DIG1 = sample_req 档    正常 3 0 ⇒ I2S 自己没在请求
        //   DIG2 = req_held 最长连续为高档 正常 0 3 = 曾连续 ≥512 拍举着没被确认
        //   DIG3/DIG4/DIG5 = 上一窗口 sample_valid 计数的 12 位  正常 ≈ 4/0/0 = 1024
        //   DIG4 的小数点 = 活 LRCK
        //   判读：DIG0=0 且 DIG1=3 ⇒ 供数停了但 I2S 在要 ⇒ 卡在构造器/FIFO/握手
        //         DIG0=0 且 DIG1=0 ⇒ I2S 自己没在请求 ⇒ 查它自己的请求产生
        //         DIG0=3 而输出仍冻住 ⇒ 供数正常但没被锁存 ⇒ 取用侧问题
        dbg_d0 <= hex7({2'b00, wav_dbg_vld_grade});
        dbg_d1 <= hex7({2'b00, wav_dbg_req_grade});
        dbg_d2 <= hex7({2'b00, wav_dbg_held_grade});
        dbg_d3 <= hex7(wav_dbg_vld_cnt[11:8]);
        dbg_d4 <= hex7(wav_dbg_vld_cnt[7:4]);
        dbg_d5 <= hex7(wav_dbg_vld_cnt[3:0]);
      end else if (PROBE_GRP == 5'd11) begin
        // ==== [Design note]版】只观测  ====
        //   为什么：粘滞位测不了"事件停止"（组7/8/9 都栽在这 ）
        //   口径：每 1024 帧一个窗口，数"这一窗口里有多少帧发生了变化"
        //       好态：几乎每帧都变 ⇒ 计数 ≈ 1024 ⇒ 档 3
        //       坏态（反复播同一帧/输出冻住 ）：计数 ≈ 0 ⇒ 档 0
        //   DIG0 = {2'b00, chg_grade}   正常 = 3 ｜ 2=多数变 ｜ 1=少数变 ｜ 0=几乎不变(冻住 )
        //   DIG1 = {3'b000, chg_last}   最近一帧是否变化（非粘滞 ）正常时应在 0/1 间跳
        //   DIG2/DIG3/DIG4 = 上一窗口"变化帧数"的 12 位（分 3 个十六进制位 ）
        //        正常应 ≈ 0x400 = 1024 ⇒ 读作 DIG2=4 / DIG3=0 / DIG4=0
        //   DIG4 小数点 = 活 LRCK ｜ DIG5 = 指纹高
        dbg_d0 <= hex7({2'b00, wav_dbg_chg_grade});
        dbg_d1 <= hex7({3'b000, wav_dbg_chg_last});
        dbg_d2 <= hex7(wav_dbg_chg_cnt[11:8]);
        dbg_d3 <= hex7(wav_dbg_chg_cnt[7:4]);
        dbg_d4 <= hex7({2'b00, wav_dbg_chg_cnt[3:0]});
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd10) begin
        // ==== [Design note]只观测  ====
        //   为什么换：组7/组8/组9【连续三次】粘滞/档位型都没分辨出故障
        //     ⇒ 粘滞位天然测不了"事件停止"（例：lrck_stopped 要求"曾动过"）
        //   DIG0 = LRCK 活计数档（每 5ms 窗口数 LRCK 边沿 ）
        //       3 = ≈预期（≈240 个/窗口 = 48kHz×5ms ）正常
        //       2 = 偏少（60~179）｜ 1 = 很少（8~59）｜ 0 = ≈0（<8）⇒ 时钟死了
        //       —— 这是本版核心：故障时 DIG0 应【直接掉到 0】，一眼可见
        //   DIG1 = {pll_lock_lost (先见1再变0才算 ), LRCK 当前电平 , audio_rst_now , 1'b0} 正常 0
        //   DIG2 = 上一窗口 LRCK 边沿数的低 4 位（人工核对用  正常应≈F（240 的低 4 位））
        //   DIG3 = 读取器状态码 ｜ DIG4 = 指纹低 + 小数点=活 LRCK ｜ DIG5 = 指纹高
        //   请给【好/坏两组】读数 （新规矩 ）
        dbg_d0 <= hex7({2'b00, lrck_grade});
        dbg_d1 <= hex7({1'b0, pll_lock_lost, lrck_lvl_now, audio_rst_s});
        dbg_d2 <= hex7(lrck_edges_win[3:0]);
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd9) begin
        // ==== [Design note]只观测  ====
        //   背景：DIG4 小数点【不亮】⇒ LRCK 没跑 ；按 KEY1 复位后完全恢复
        //        静态核查：seek 路径【不碰】audio_rst / rst_n / PLL.reset(恒 1'b0)
        //        推论：故障时 audio_pll_lock 仍=1、audio_rst 仍=0 ⇒ 时钟自身停了
        //   DIG0 = {1'b0, audio_rst_now , pll_lock_lost , lrck_stopped }  正常 = 0
        //       bit0=1 ⇒ LRCK 曾停 （与小数点灭互为旁证 ）
        //       bit1=2 ⇒ PLL 曾报失锁 （若=1 且 KEY1 能救 ⇒ 需重新审视 lock 毛刺 ）
        //       bit2=4 ⇒ audio_rst 当前仍为 1 （音频域被复位按住）
        //   判读预置（先写死 ）：DIG0=1 ⇒ 时钟停而域未复位 ⇒ 最强指向 PLL 输出
        //                          DIG0=5/7 ⇒ 域被按住 ⇒ 查 lock 侧是否被锁存
        //   DIG1 = 读取器状态码 ｜ DIG2 = {写侧水位档}（旁证：坏时水位可能高 ）
        //   DIG3 = 构造器状态码 ｜ DIG4 = 指纹低 + 小数点=活 LRCK ｜ DIG5 = 指纹高
        dbg_d0 <= hex7(
            {1'b0, audio_rst_s, pll_lock_lost, (lrck_grade == 2'd0)}
        );  // 第4位改用【活计数=0】⇒ 时钟死
        dbg_d1 <= hex7({1'b0, wav_dbg_state});
        dbg_d2 <= hex7({2'b00, fifo_lvl});
        dbg_d3 <= hex7({1'b0, sb_st_s1[2:0]});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd8) begin
        // ==== [Design note]只观测  ====
        //   背景：组7 的"对照读数"证明 empty/驻留/水位 在【好与坏】状态下完全相同
        //        => 那些"可疑值"其实是【正常现象】⇒ 故障在组7 看不到的地方
        //   本组直接测：I2S 是否在【反复锁存同一个样本对】（= "反复播同一帧" ）
        //   DIG0 = {1'b0, rep_long , rep_grade[1:0]}   正常 = 0
        //          = 8..B（rep_long=1）⇒ 反复播同一帧 ⇒ 症状直接命中
        //          = 1/2/4/5 ⇒ 有连续重复但未达 16 帧（注意静音段也会如此 ）
        //   DIG1 = 当前连续相同帧数（低 4 位，饱和）  正常 = 0
        //   DIG2 = {2'b00, 写侧FIFO水位档}（旁证：坏时水位可能仍高 ）
        //   DIG3 = 读取器状态码 ｜ DIG4/5 = 指纹 + 活 LRCK 小数点
        //   ⚠️ 判读要求：必须在【有声音/较响】的段落读，并与"好状态"对照
        dbg_d0 <= hex7({1'b0, wav_dbg_rep_long, wav_dbg_rep_grade});
        dbg_d1 <= hex7(wav_dbg_same_frames);
        dbg_d2 <= hex7({2'b00, fifo_lvl});
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd7) begin
        // ==== [Design note]只观测  ====
        //   背景：组6 读数 = 段1档3（req→首次 rd_en ≥512 ）+ 段2档0
        //   代码：`fifo_rd_en = (REQ 状态) && !fifo_empty`
        //   => 若【读侧 empty 恒为高】⇒ rd_en 永不拉高 ⇒ 卡在 S_REQ_LO ⇒ 与读数完全吻合
        //   DIG0 = {2'b00, empty曾经连续>512拍为1 , empty 当前电平}  正常 = 0
        //          1 = 此刻空（正常启动期 ）｜ 2 = 曾长期判空 ⇒ 读侧 flag 卡住
        //   DIG1 = 停留最久的状态码（0=IDLE｜1/3=REQ(等 empty )｜2/4=GET｜5~8=R ）
        //          若 = 1 或 3 ⇒ 卡在"等 empty"
        //   DIG2 = {写侧水位档[1:0], 驻留档[1:0]}  矛盾证据：水位高(2/3) 而 DIG0=2
        //   DIG3 = 读取器状态码 ｜ DIG4/5 = 指纹 + 活 LRCK 小数点
        dbg_d0 <= hex7({2'b00, wav_dbg_empty_stuck, fifo_empty});
        dbg_d1 <= hex7(wav_dbg_dwell_state);
        dbg_d2 <= hex7({fifo_lvl, wav_dbg_dwell_grade});
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd6) begin
        // ==== [Design note]只观测  ====
        //   DIG0 = {2'b00, lat_req_to_rden}  段1：req→首次 rd_en 的拍数档（0<8｜1=8~64｜2=64~512｜3≥512）
        //   DIG1 = {2'b00, lat_rden_to_valid} 段2：rd_en→sample_valid 的拍数档（同上）
        //   DIG2 = {2'b00, req_seen_hi, ack延迟档[0..1]}  req_seen 电平 + 总档
        //   DIG3 = 读取器状态码 ｜ DIG4/5 = 指纹 + 活 LRCK 小数点
        //   正常值：DIG0 = 0（TB 实测 req→rd_en 仅 1~2 拍 ）
        //              DIG1 = 0（rd_en→valid 仅 3~4 拍 ）
        //              DIG2 低位 = 0（总延迟 ~5 拍  = 档 0）；req_seen_hi 应几乎恒 0
        dbg_d0 <= hex7({2'b00, wav_dbg_lat_req2rden});
        dbg_d1 <= hex7({2'b00, wav_dbg_lat_rden2v});
        dbg_d2 <= hex7({1'b0, wav_dbg_req_seen_hi, 1'b0, wav_dbg_ack_lat[0]});
        dbg_d3 <= hex7({1'b0, wav_dbg_state});
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd5) begin
        // ==== [Design note]端到端累加器轮显（PC 侧对账用 ）====
        //   DIG0/DIG1 = 当前屏号（0..3  便于知道在看哪一屏）
        //   DIG2..DIG5 = 该屏 16 位值的 4 位十六进制（DIG2 最高位 ）
        //   屏序（每 ~0.5s 换一屏 ）：0=sum32[15:0] 最常用 ｜1=sum32[31:16] ｜2=n[15:0] ｜3=保留
        dbg_d0 <= hex7({2'b00, ps_scr});
        dbg_d1 <= hex7({2'b00, ps_scr});
        dbg_d2 <= hex7(ps_show[15:12]);
        dbg_d3 <= hex7(ps_show[11:8]);
        dbg_d4 <= hex7(ps_show[7:4]);
        dbg_d5 <= hex7(ps_show[3:0]);
      end else if (PROBE_GRP == 5'd4) begin
        // ==== [Design note]FIFO 满 + 消费端没在取 ====
        //   DIG0 = {写侧曾写(5ms 窗), 最近 5ms 内有写}      -> 正常 3
        //   DIG1 = 构造器状态机状态码（0=IDLE 正常；长时间非 0 => 卡住 ）
        //   DIG2 = {sample_req 曾被丢 , FIFO 读使能当前电平} -> 正常 0 或 1
        //   DIG3 = 读取器 FSM 状态码                          -> 正常 3
        //   DIG4 = 指纹低 4 位；DIG4 小数点 = LRCK 在翻转（正常亮 ）
        //   DIG5 = 指纹高 4 位
        // ==== [Design note]====
        //   上一版 DIG2 的"丢请求"是【假警报】：握手之后"req 高且非 IDLE"属于正常
        //     （请求方会一直举着直到 ack ）=> 现在改成真正的"撤了却没 ack"
        //   DIG0 = {2'b00, req_stall(真停摆), ack_seen()}   正常 = 1
        //   DIG1 = {构造器状态码[2:0], 最近5ms内有写}          => 在变 = 构造器在动
        //   DIG2 = {仍在丢(真), 曾丢过(真), ack延迟档[1:0]}  正常 = 0
        //   DIG3 = 读取器状态码 ｜ DIG4/5 = 指纹 + 活 LRCK 小数点
        // ==== [Design note]====
        //   DIG0 = {2'b00, pcm_start_odd(seek后首字节奇数偏移 ), pcm_gap(PCM流不连续 )}  正常 = 0
        //   DIG1 = {构造器状态码[2:0], 最近5ms有写}                    在变 = 构造器在动
        //   DIG2 = {ack延迟档[1:0], 真丢请求 , ack曾来 }              正常 = 1
        //   DIG3 = {1'b0, 读取器状态码}                                正常 = 3
        //   DIG4/5 = 指纹 + DIG4 小数点 = 活 LRCK
        dbg_d0 <= hex7(
            {3'b000, wav_dbg_pcm_odd}
        );  // 本版核心位：(a) seek 后首字节奇数偏移
        dbg_d1 <= hex7({sb_st_s1[2:0], wp5_recent});
        dbg_d2 <= hex7(
            {wav_dbg_req_lost_now, wav_dbg_req_lost, wav_dbg_ack_lat}
        );  // [Design note]{真仍在丢, 真曾丢, ack延迟档}
        // 【已删除】原 fix14 的 dbg_d2（{仍在丢,曾丢过,读使能}）
        //   属于【正常握手行为】⇒ 正常播放就恒为 1 ⇒ 是误报显示 （本会话已证 ）
        dbg_d3 <= hex7(
            {1'b0, wav_dbg_state}
        );  // [Design note]读取器状态码（正常 3 ；音量变化位随键盘拆除失效 ⇒ 已去掉 ）
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd3) begin
        // ==== [Design note]FIFO 饿死那条链 ====
        //   DIG0 = {pcm_valid 曾出现, 最近 20µs 内有 pcm_valid}  -> 正常 3
        //   DIG1 = FIFO 水位档 0..3（写侧 wr_usedw）              -> 健康 1~2
        //   DIG2 = {门控残留(非 seek 期间 seek_drain/窗口仍为高), sd_sec_read 电平} -> 正常 0 或 1
        //   DIG3 = 读取器 FSM 状态码                              -> 正常 3
        //   DIG4/DIG5 = 读取器 8 位指纹（DIG4 含 2 = read_end 看门狗超时过）
        dbg_d0 <= hex7({2'b00, wav_dbg_wp_seen, wav_dbg_wp_recent});
        dbg_d1 <= hex7({2'b00, fifo_lvl});
        dbg_d2 <= hex7({2'b00, wav_dbg_wp_gate, wav_sd_sec_read});
        dbg_d3 <= hex7(
            {1'b0, wav_dbg_state}
        );  // [Design note]读取器状态码（正常 3 ；音量变化位随键盘拆除失效 ⇒ 已去掉 ）
        dbg_d4 <= hex7(wav_dbg_fp[3:0]);
        dbg_d5 <= hex7(wav_dbg_fp[7:4]);
      end else if (PROBE_GRP == 5'd2) begin
        // ==== [Design note]I2S_receiver -> HDMI 音频包 这一层 ====
        //   DIG0 = {audio_valid 曾出现, LRCK 在跑}       -> 正常 11 = 3
        //   DIG1 = {下游彻底断流, FIFO 曾长时间欠载}     -> 正常 00 = 0
        //   DIG2 = {出过样本后仍欠载(真问题), 曾欠载}     -> 正常 00 = 0
        //   DIG3 = 读取器 FSM 状态码                      -> 正常 3
        //   DIG4/DIG5 = 读取器 8 位指纹
        dbg_d0 <= hex7({2'b00, au_s1[4], au_s1[2]});
        dbg_d1 <= hex7({2'b00, au_s1[3], au_s1[1]});
        dbg_d2 <= hex7({2'b00, au_s1[5], au_s1[1]});
        dbg_d3 <= hex7(
            {1'b0, wav_dbg_state}
        );  // [Design note]读取器状态码（正常 3 ；音量变化位随键盘拆除失效 ⇒ 已去掉 ）
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

      // ---- 播放器状态指示（键盘调试面板关闭时用这 6 位数码管）----
      // 这块板给了 6 位数码管，原来只在键盘自检时用；面板默认关闭，
      // 等于 6 位数码管一直黑着。用它显示播放器状态，是"零新增硬件成本"
      // 的可见反馈，也方便现场演示和排查。
      //   DIG0 = 当前曲目号（0..9，十进制显示）
      //   DIG1 = 歌单总数
      //   DIG2 = 自动续播 开(A) / 关(灭)
      //   DIG3 = 已暂停(P) / 播放中(灭)
      //   DIG4 = 【字节级探针】DBR byte0：正常 'H'，异常显示低 4 位十六进制
      //   DIG5 = 灭（留作备用）
      // 全部用已存在的信号，纯组合译码 + 1 级寄存，不引入新逻辑路径。
      psg_d0 <= hex7(play_song_idx[3:0]);
      psg_d1 <= hex7(song_count[3:0]);
      psg_d2 <= auto_en ? 7'b0001000 : 7'b1111111;  // 'A'
      psg_d3 <= pause ? 7'b0011000 : 7'b1111111;  // 'P'
      psg_d4 <= btn_long_a ? 7'b0001110 : 7'b1111111;  // 'F'
    end
  end

  // 全局复位：只依赖外部按键复位。不再绑定音频 PLL 锁定，
  // 避免音频 PLL 上电偶发不锁/锁定慢导致整个系统（视频+SD卡）卡死。


  // 音频域复位：音频 PLL 未锁定时只复位音频链路（时钟稳定后才播放）


  // 保持你原来的 TF / SDRAM / video 时钟
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

  // 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
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

  // ===================== 音频：SD 卡 WAV 播放（替换测试音） =====================
  // wav_reader 的 scan_start 脉冲：sd_init_done 拉高后延迟约 10us 发一次
  reg [23:0] wav_scan_cnt;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
      wav_scan_cnt   <= 24'd0;
      wav_scan_start <= 1'b0;
    end else begin
      wav_scan_start <= 1'b0;
      if (display_valid && wav_scan_cnt < 24'h800000) begin
        wav_scan_cnt <= wav_scan_cnt + 24'd1;
        // [Design note] 盲扫只作【歌单不可用】的超时恢复：
        //   有歌单（list_ready 且 song_count>0）时不再发 boot 扫描脉冲。
        //   病（板测）：该脉冲在 display_valid+10µs 无条件发出，与歌单首曲的
        //   track_sel 竞争；抢赢时先播一段盲扫扫到的孤儿/被删文件数据
        //   （板测 40s 噪声，探针证实内容=被删 02gods 的残留字节），
        //   之后歌单曲目才干净播出。⇒ 有歌单时跳过 boot 盲扫。
        if ((wav_scan_cnt == 24'd1000) && !(list_ready && (song_count != 6'd0)))  // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 ~10us @旧控制频率
          wav_scan_start <= 1'b1;
      end
    end
  end

  // [Design note]"先图后音"：track_sel_valid 是单拍脉冲，图片还没出来时
  // 不能直接丢掉（否则音频永远不启动），先挂起，等 display_valid 拉高再放行。
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

  // 2026-10-10 音频重写：实例换为接口垫片 `wav_player_shim`
  //   垫片的【端口签名与旧 wav_reader 逐字相同】⇒ 本实例化的所有端口连接一行都不用改
  //   垫片内部实例化新的 `wav_player`，并把新设计不再提供的旧探针驱动为常量
  //   （旧 `wav_reader.v` 已移入隔离目录 `_snapshots_retired_20261010\`  可回退 ）
  wire wav_sd_grant;
  // ============================================================================
  // [Design note 死锁修复]"排空"判据必须能容忍"FIFO 空了但构造器还在等数据"。
  //
  //   板上实测（AA1，卡在 GIF）
  //       DIG0 = 3  → wav_player 状态 = ST_SEEK
  //       DIG2 = 0  → wav_ready = 0
  //   wav_player 退出 ST_SEEK 的条件是：
  //       state==ST_SEEK && !inflight && !partial_frame && fifo_drained && ...
  //   而原来的 fifo_drained = fifo_empty && sample_builder_idle。
  //
  //   视频抢 SD ⇒ 音频 FIFO 被抽干 ⇒ 采样构造器停在"等数据"的请求态（不是 IDLE）
  //   ⇒ sample_builder_idle = 0 ⇒ fifo_drained 恒 0 ⇒ 切轨永远做不完 ⇒
  //   wav_ready 掉到 0、进度条冻结、退出视频也回不来（没人再重发选轨）。
  //   这是一个真正的死锁，不是时序问题。
  //
  //   修法：FIFO 空且持续 EMPTY_HOLD 拍，就认为"排空"成立（此时构造器确实没数据可做，
  //   它卡在请求态只是因为它不知道不会再有数据了）。
  //   为什么 256 拍足够：audio_mclk = 12.288 MHz ⇒ 21 µs，远大于构造器一次取样的
  //   几个时钟；而正常播放时 FIFO 深度 4096 字节（21 ms）不会出现"连续 21 µs 全空"，
  //   所以不会误判成已排空。
  // ============================================================================
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
  // Optional 30fps resource experiment: WAV PCM/IMA only; QOA rejected.
  media_player_shim #(.ENABLE_QOA(0)) u_wav_reader (
    .file_base_lba(fs_audio_base),
    .sd_error(fs_error && fs_error_owner == 1),
    .clk(sd_card_clk),
    .rst(rst_all),
    .scan_start(wav_scan_start),
    // ============================================================
    // 2026-10-12 FIX: do NOT blind-scan the whole card.
    //   Previously: .scan_start_sector(32'd0), .scan_max_sector(32'h000FFFFF)
    //     => the player blind-scanned up to 1,048,575 sectors starting at 0.
    //     At a real 0.5-1 ms per sector that is ~500-1000 s (8-17 MINUTES)
    //     on real hardware => the macro behaviour is "never plays, progress
    //     bar stuck", and for that whole time the audio monopolises the SD
    //     bus so the image loader cannot (re)load => white bars + noise.
    //   The project ALREADY knows where the files are: fat32_list outputs
    //     fat_data_start, and the BMP reader uses exactly that
    //     (.scan_start_sector(fat_data_start) at the sd_card_bmp instance).
    //     The audio player was the only client bypassing it.
    //   Fix: same as the image path - start at the FAT32 data area, and keep
    //     the scan only as a small FALLBACK bound.
    //     => 256 was tried first and was TOO SMALL: the song can sit far
    //        past the FAT32 data start (the images occupy the front), so a
    //        256-sector window could never reach it.
    //     => 8192 sectors is a generous FALLBACK bound (~4-8 s worst case),
    //        while the primary path is still "start at fat_data_start".
    // ============================================================
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
    .step_bytes(ff_step_bytes),   // [Design note]按解析出的声道数选步长（单声道 960000 = 10s ）
    // 切歌：track_ctrl 指定曲目起始扇区，wav_reader 回报播完/坏文件
    // [Design note 视频配音轨]进入/退出视频时由 vau_take 抢占，见上面那段注释
    .track_sel(fade_select),
    .track_sel_sector(fade_sector),
    .track_end(wav_track_end),
    .track_bad(wav_track_bad),
    .pcm_valid(wav_pcm_valid),
    .pcm_data(wav_pcm_data),
    // [Design note fix3]观测位：只接数码管调试面板，wav_reader 内部无任何逻辑依赖它们
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

  // ============================================================================
  // [Design note exp-io]矩阵键盘（4x4）已下线
  //---------------------------------------------------------------------------
  // 用户确认矩阵键盘不再接线，所以：
  //   1) 顶层删掉 keypad_col/keypad_row 两个端口 ⇒ 那 8 个 J1 脚位
  //      （J1-2 G11 / J1-4 F13 / J1-5 H13 / J1-19 F14 / J1-22 G14 /
  //        J1-25 H15 / J1-33 N16 / J1-34 N14）全部释放给扩展板；
  //   2) keypad_scan 模块不再例化 ⇒ 省掉它的全部逻辑（约 200 gates / 90 FF）；
  //   3) 原来由键盘产生的所有信号改成常量：没有键盘事件、键位图为 0。
  //      受影响的只有"键盘快捷键"：C=下一首、D=重开轮播计时、A=播放暂停。
  //      这三件事现在分别由扩展板 KEY1 / 扩展板 KEY4+拨码 / 板载 KEY2 承担，
  //      功能没有丢失（见第 4 节的按键分配表）。
  //
  // 回退：把下面 KP_ON 改回 1，同时恢复两个端口和 pin.adc 里的 8 条键盘约束。
  // ============================================================================
  localparam KP_ON = 1'b0;

  generate
    if (KP_ON) begin : g_kp
      keypad_scan u_keypad_scan (
        .clk        (sd_card_clk),
        .rst_n      (rst_n),
        .col        (),
        .row        (),              // 端口已删除，回退时接回 keypad_col/row
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

  // 跨时钟域 FIFO：sd_card_clk(100M) -> audio_mclk(12.288M)
  // 【音频卡顿修复 2026-10-02】原来吃 async_fifo 的默认参数
  //   (ADDR_WIDTH=11, DEPTH=2048, ALMOST_FULL_THRESH=1024)，
  //   稳态只存 1022~1535 B = 10.66 ms @48k/16bit 单声道；
  //   SD 卡任何一次读停顿 > 10.7 ms 就欠载 -> I2S 重复播上一采样 = "卡顿一下"。
  //   现在加深到 4096、水位提到 3072 -> 余量 31.99 ms（仿真已证 30 ms 停顿不卡）。
  //   代价：+2 个 9K BRAM（2048x8 -> 4096x8），slices 基本不变。
  async_fifo #(
    .DATA_WIDTH        (8),
    // [Design note 切图断音]4096(42ms) -> 8192(85ms)：
    //   切图期间卡要在大文件顺序流里插入音频的随机读，每次寻道数毫秒，
    //   音频瞬时吞吐会掉到 50~200 kB/s（需求 96 kB/s 的边界附近）。
    //   加深缓冲让音频扛住更长的抖动。ALMOST_FULL 同步按比例提到 6144，
    //   保持"预留下游 2 个整块"的原有比例。
    //   代价：+4 个 9K BRAM（4096x8 -> 8192x8），slices 基本不变。
    .ADDR_WIDTH        (13),    // DEPTH = 2^13 = 8192
    .DEPTH             (8192),
    .ALMOST_FULL_THRESH(6144)   // 预留 2048 B(=4 个扇区) 给 in-flight 扇区
  ) u_async_fifo (
    .wr_clk(sd_card_clk),
    .wr_rst(rst_all),
    .wr_en(wav_pcm_valid),
    .wr_data(wav_pcm_data),  // [Design note] 真实播放器写入（诊断注入已撤除）
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
  // ---- [Design note]把实际用于字节配对的 stereo 值同步到 clk 域（只供显示 ）----
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
    .sample_valid(wav_sample_valid),          // 构造器的【输出】（只接一次 ；上一版误插了两次 ）
    .sample_left(wav_sample_left),
    .sample_right(wav_sample_right),
    // [Design note]消费端观测口（必须用端口连接；层次引用 u_xxx.sig 会被 TD 判为
    //   HDL-8007 "external reference remains unresolved" 并让 top 变黑盒  —— 本轮踩过 ）
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
  // [Design note]音量探针驱动（volume_s1 已在上方声明  => 满足"先声明后使用" ）
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
      // [Design note]音量变化监测（看是不是有人在按 * / #，或键在抖动 ）
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
  i2s_transmitter #(.MAX_BUDGET_HOLD(2)) u_i2s_transmitter (
    .hold_budget_gap(av_buffering && !av_drain_old_stream),
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



  // ===================== TF 多图扫描与缓存（双缓冲，扇区接口版） =====================
  // [Design note 修复 现象3]key_next 从 key1_s2 改成 key3_s2：
  //   key1_s2 同时还接着 u_button_ctrl.key_a（播放/暂停 + 长按快进），
  //   一个物理键同时驱动图片和音乐两个状态机，索引必然发散、
  //   "歌名和正在播放的歌对不上"。现在图片控制独占 key3(B1)。
  //   key_auto 保持 key2_s2（这一个键只做"自动轮播开关"，没有冲突）。
  // [Design note key4-split]上句"key_auto 保持 key2_s2"已作废：key_auto 改接
  //   auto_vk（仅 KEY4 短按触发，见其处 [Design note] 注释）——直连 key2_s2 时"长按也会
  //   toggle 轮播"；且该键现按用户需求改为"短按=轮播开关、长按=切歌"
  //   （切歌走 button_ctrl.long_b_tick -> track_ctrl，不再走图片线）。
  // ===================== [Design note 修复 现象1]两趟扫描 =====================
  // 背景（bmp_scan_diag_tb 实测）：
  //   sd_card_bmp 的首图加载被 bmp_read 的 scan_done 门控，而 scan_done 原来
  //   只在"凑满 SCAN_TARGET_COUNT 张"或"扫到 SCAN_MAX_SECTOR"时才置起。
  //   本卡三张图按簇对齐（间隔 1808 扇区），而 bmp_read 命中一张后按
  //   file_sector_count(=1801) 跳过整个文件，跳过头 -> 只认出 2 张 ->
  //   scan_done 一直不来 -> 首图要等扫完 131071 个扇区（x 164us ≈ 21.5s）。
  //   这就是"上电约 20 秒才出图；按一下重新扫描很快就出图"。
  //
  // 现在的做法：
  //   phase A（受限扫描，scan_limited=1）：从数据区首扇区线性扫，最多
  //       SCAN_INIT_BUDGET(6000) 个扇区就强制 scan_done -> 首图立刻加载显示。
  //       实测本卡 3 张图都在这个窗口内（约 5814 个扇区 = 0.95s < 2s）。
  //   phase B（后台全范围，scan_limited=0）：首图提交后再从 phase A 停下的
  //       位置继续扫全范围，把第一趟没扫到的图补齐（供按键切图）。
  //       如果 phase A 已经把图找全了，这一趟就只剩"扫完剩余范围"，
  //       不占额外功能代价。
  //
  // 用 scan_sector_o（bmp_read 的扫描位置）回接成 phase B 的起点。
  // Admit earlier background image preparation only with >=6144 PCM bytes
  // already buffered (~32ms at 48kHz stereo16). Admission never changes the
  // arbiter's transaction ownership, urgent-audio rule or video prefetch.
  reg image_prefetch_audio_ready;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) image_prefetch_audio_ready <= 1'b0;
    else image_prefetch_audio_ready <= (fifo_usedw >= 14'd6144);
  end
  sd_card_bmp #(
    .EARLY_PREFETCH_EN(1),
    .CLK_FREQ_HZ      (SD_CORE_HZ),
    .SCAN_MAX_SECTOR  (32'd131071),
    // 2026-10-12【图片修复 2/2】3'd3 -> 3'd4：让第 4 张图能被识别
    //   【现象（用户）】"顺序可能会错乱，比如从最后一张跳到开头那一张"。
    //   【机理】本设计容量本来就是 4 张：`img_sector0..3` 四个寄存器、
    //     `sector_lut` 四个入口（含 default 超时恢复）、`img_idx` 2 位(0..3)、
    //     `img_found_count` 上限 4（`if (img_found_count < 3'd4)` 才自增）。
    //     但本参数传 3 ⇒ 后台补齐（phase B，scan_limited=0）在凑满 3 张时
    //     就走 `bmp_read.v:377` 的提前收工 ⇒ 第 4 张的扇区从未被记录，
    //     `img_sector3` 停在复位值 0。
    //   【为什么对音频零影响】本参数只作用于图片扫描，且其提前收工带
    //     `!scan_limited` 门槛 ⇒ 受限阶段(phase A) 根本不看它。
    //     phase B 又在首图已上屏、音频早已在播之后才启动
    //     ⇒ 与音频的启动/盲扫没有任何时序交集 （上一版翻车的是音频扫描起点，
    //        不是本参数；本参数另有自建台实证，见下）
    //   【实测证据】自建台 `bmp_scan_count_tb`（仪器先自检 4/4 头满足 header_match）：
    //     同一张 4 图卡 —— target=3 ⇒ 认出 3 张；target=4 ⇒ 认出 4 张
    //     且 phase A 在 target=4 与 target=3 下结果完全相同 ⇒ 首图时序不变
    //   【为什么 phase A 不受影响】它只看 `SCAN_INIT_BUDGET`(6000 扇区) 与范围。
    //   【对准赛题】原文："至少支持对 4 幅 640x480、24-bit 的图片进行
    //     自动扫描、识别与装载" ⇒ 必须能认出 4 张。
    //   【安全超时恢复】`if (img_found_count < 3'd4)` 保证索引不会溢出；
    //     `sector_lut` 四入口齐全 + default 超时恢复；四个寄存器复位都清 0
    .SCAN_TARGET_COUNT(3'd4),
    // ================================================================
    // 2026-10-16 扫描预算：6000 -> 65536 -> 24576
    //
    //   为什么要放大（6000 太小）：phase A 是线性扫（不跳文件），
    //   只扫 SCAN_INIT_BUDGET 个扇区就强制 scan_done。而大图非常占扇区：
    //       640x480   1,801 扇区      800x600   2,813
    //       1280x720  5,401           1920x1080 12,151
    //   四张依次排布时，第 4 张起点已在 rel ~10,096 扇区
    //   —— 6000 连第 3 张都扫不到，实测只认出 2 张。
    //   而本该补齐的 phase B 是刻意禁用的（见 `if (1'b0 && !bg_kicked ...)`），
    //   所以"扫不到 = 永远看不到"。
    //
    //   为什么定 24576（而不是 65536）：
    //     实测最大 rel = 10,096，24576 有 2.4 倍余量；
    //     开机扫描时间与预算成正比：
    //        6000  -> 0.98 s
    //        24576 -> 4.0 s      <== 本版
    //        65536 -> 10.7 s
    //     4 s 已能覆盖 12 MB（约 2 张 1920x1080 或 13 张 640x480），
    //     且首图仍在约 1 s 出现（扫到第一张就加载），
    //     所以 4 s 只是"后几张登记完"的时间。
    //     若以后卡上图片更多/更大，再往上调即可（上限 SCAN_MAX_SECTOR=131071）。
    //   回退：改回 32'd6000（旧行为）或 32'd65536。
    // ================================================================
    // 2026-10-17 扫描预算 24576 -> 60000
    //   卡上现在放 4 张 GOSICK 图的 4 个分辨率（640/1280/1920/2560 宽）：
    //     1801 + 7201 + 16200 + 28800 = 54002 扇区
    //   24576 只够前 2 张，会"只看到 2 张图"（这个坑已经踩过两次）。
    //   60000 有 11% 余量；扫描时间 60000 x 163.8us ≈ 9.8 s（后台），
    //   首图仍在约 0.2 s 出现（扫到第一张就加载）。
    //   上限 SCAN_MAX_SECTOR = 131071，60000 在其内。
    //   回退：改回 32'd24576。
    .SCAN_INIT_BUDGET (32'd60000)
  ) sd_card_bmp_m0 (
    .directory_count(directory_image_count),
    .directory0     (directory_image0),
    .directory1     (directory_image1),
    .directory2     (directory_image2),
    .directory3     (directory_image3),
    .clk            (sd_card_clk),
    .rst            (rst_all),
    // [Design note exp-io]扩展板 KEY2 也接成"下一张"：key3_tap_n 是
    //   key_long 产生的 40 ms 低有效 tap，exp_nextimg_key_n 是扩展板 KEY2
    //   的低有效电平，两者相与 = 任意一个按下（都是低有效）
    .key_next       (key3_tap_n & exp_nextimg_key_n),  // B1(KEY3)短按 / 扩展板 KEY2
    // [Design note] 原直连 key2_s2（板上 C1/KEY4 原始电平）——按下沿即
    //   toggle、长按也会误触发；现改接【短按虚拟按键】auto_vk（仅 KEY4 短按走这条路径）。
    // [Design note exp-io]扩展板 KEY4 是独立的消抖电平，直接相与即可（低有效）
    .key_auto       (auto_vk & exp_auto_key_n),
    // [Design note exp-io]轮播周期改由扩展板拨码选择（见 carousel_period_cfg）；
    //   键盘 D 退化成"打开轮播 + 立即重开计时"（period_reseed）。
    .period_code    (exp_period_code),
    .auto_period_sec(exp_period_sec),
    .period_reseed  (kp_period_step),
    .prefetch_audio_ready(image_prefetch_audio_ready),
    .cfg_boundary_o (exp_cfg_boundary),
    .state_code     (state_code),
    .bmp_width      (16'd640),
    .bmp_height     (16'd480),
    .img_h_o        (img_h_img),
    .source_top_down(img_top_down),
    .display_valid  (display_valid),
    .img_loading    (img_loading),

    // [Design note]图片扫描起点 = FAT32 数据区首扇区（本卡 32832 -> 簇6 的 BMP）
    .file_base_lba     (fs_image_base),
    .sd_error          (fs_error && fs_error_owner == 0),
    .scan_start_sector (fat_data_start),
    // [Design note]phase B 的起点 = phase A 停下的位置（锁存值）
    .scan_start_sector2(img_scan_sector_lat),
    .scan_start2       (1'b0),
    .scan_limited      (bg_scan_limited),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx      (img_write_buf_idx),
    .disp_buf_idx       (img_disp_buf_idx),

    // 【转场 FIX 2026-10-07】两段式提交握手 + 转场背压（详见 SD\sd_card_bmp.v 端口注释）
    //   fade_switch_lock 是 fade_busy 同步到 sd_card_clk 后的电平（转场 ≈538ms，
    //   电平够宽，2 级同步足够）。
    .switch_lock        (fade_switch_lock),
    // [Design note 视频]视频播放期间禁止开新的切图装载
    .vid_lock           (vid_lock),
    .fade_req_toggle    (fade_req_toggle),
    .fade_done_pulse    (fade_done_pulse),
    // 【首图必出图 超时恢复 2026-10-07】1 = 首图靠超时超时恢复才提交（正常恒 0）-> DIG3
    .firstimg_fallback_o(firstimg_fb_seen),
    // 【根因诊断 2026-10-07 #2】超时恢复那一拍的 4 位状态（同上）-> DIG3 十六进制位
    .firstimg_diag_o    (firstimg_diag),

    .write_req        (img_write_req),
    .write_req_ack    (sd_card_write_req_ack),
    .write_almost_full(image_source_high),
    .write_en         (img_write_en),
    .write_data       (img_write_data),

    // [Design note]加 & list_ready：bmp_read 在扫描起点一拍内就发起读，
    // 必须等 fat32_list 扫完根目录、fat_data_start 已经有效之后再放行图片扫描。
    // （原来 sd_init_done 一拉高图片就抢跑，会用到还算不出来的 data_start）
    .sd_init_done          (sd_init_done & list_ready),
    .sd_sec_read           (img_sd_sec_read),
    .sd_sec_read_addr      (img_sd_sec_read_addr),
    .sd_sec_read_data      (img_data_q),
    .sd_sec_read_data_valid(img_valid_q),
    .sd_sec_read_end       (img_end_q),
    .sd_grant              (img_grant_q),
    // [Design note]把扫描位置 + 已缓存图片数 + 扫描完成 引给顶层，
    //   用于决定 phase B（后台全范围补齐扫描）的起点和发起时机。
    //   注意端口名是 scan_sector（sd_card_bmp 侧），底层 bmp_read 侧才叫
    //   scan_sector_o —— TD 报 HDL-8007 就是因为这里写错了名字。
    .scan_sector           (img_scan_sector),
    .found_count_o         (img_found_count),
    .scan_done_o           (img_scan_done_fb),
    .auto_mode_o           (img_auto_mode),              // 轮播档位（显示用，0=关）
    // [Design note exp-io]把轮播开关本身引给扩展板 595 面板（显示 'A'/'-'）
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
  // [Design note 现象2：图片侧确定性死锁]原发起条件是
  //     (img_scan_done_fb && img_found_count!=0 && !img_loading)
  // 而 sd_card_bmp 的首图加载用的是同一个 scan_done、同一拍、同一个
  // !img_loading（此刻 load_busy 还没置起来），于是两个 1 拍脉冲同拍到达
  // bmp_read；而 bmp_read 的 ST_IDLE 先判 scan_start2（bmp_read.v:281-292），
  // load_start 被整条丢掉，load_busy 又只有 write_finish_toggle 才会清
  // （sd_card_bmp.v:254-263）-> 首图永远不加载：黑屏、DIG5 一直 2。
  // 修法（顶层侧）：phase B 只是"后台补齐剩余图片"，没有任何理由抢在首图
  //   之前发起，所以正常路径改成等首图真的显示出来（display_valid=1）
  //   且当前不忙；再加两条退化路径，保证它绝不会永不发起：
  //     (a) phase A 一张图都没找到 -> 没有首图可加载、不存在竞争 -> 立刻发起；
  //     (b) 有图但首图超时仍未提交（加载失败/脉冲被丢）-> BG_FIRSTIMG_WAIT
  //         之后、且当前确实不在加载中 -> 仍然发起。
  //   display_valid 就是 sd_card_bmp 内部 first_image_committed 的对外可见
  //   等价信号：两者在 sd_card_bmp.v 的同一个 always 里同一拍置起
  //   （sd_card_bmp.v:251-252），所以这里不需要新增端口/新信号。
  //   sd_card_bmp 里另有一条 load_busy 看门狗超时恢复（LOAD_WAIT_MAX），
  //   保证"一个 1 拍脉冲丢了"不会把 load_busy 永久钉在 1。
  localparam [31:0] BG_FIRSTIMG_WAIT = 32'd272727273;  // 3s，按SD_CORE_HZ换算

  // 2026-10-12 image-priority window phase counter (one driver).
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
      // ============================================================
      // 2026-10-12 [EXP1] background catch-up scan disabled
      //   EXP1 (md5 8B2A583F...0015) is the best-quality bit measured on
      //   the board: white bars were reduced to very few.  It combined
      //   (a) continuous image priority while img_loading, and
      //   (b) NO background scan => no second SD-card reader running
      //   concurrently with an image load.
      //   Reverting to exactly that behaviour.
      //   Cost: images that only the background pass would have found
      //   are not discovered (phase A images still switch normally).
      //   Revert: delete the leading 1'b0 &&  .
      // ============================================================
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
    else image_priority_q <= ~display_valid | (img_loading & fifo_usedw[13]);
  end
  // wr_usedw and SD state are both in sd_card_clk. Reserve4096 PCM
  // bytes covers21.3ms even for48k stereo; an ordinary48-sector burst is
  // about9.5ms. Startup/low reserve retains immediate audio eligibility.
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
    // ================================================================
    // 2026-10-12【白条根治·关键一行】图片优先权必须覆盖"正在装图"
    //   【板上现象（用户）】开机正常；一按切图键 → 第一次就"没音乐＋白条"；
    //     重置后恢复；按多了反复出现。⇒ 状态可恢复 ⇒ 是"资源被抢"而非逻辑死锁。
    //   【根因】本信号原为 `~display_valid`，而 sd_arbiter 的语义是
    //       img_priority=1 : fat > img > wav   （首图显示之前）
    //       img_priority=0 : wav > img > fat   （首图之后 = 音频绝对优先）
    //     但 `display_valid` 在首图一提交就恒为 1 ⇒ 此信号永久为 0
    //     ⇒ 此后音频每一轮仲裁都赢（它在播放时几乎每拍都举着请求）。
    //     而手动切一张图要读 1801 个扇区（640x480x24bit = 921600 B）
    //     ⇒ 图像客户端抢不到扇区 ⇒ 帧缓冲写不满就被切到显示缓冲 ⇒ 白条；
    //       同时音频链路被这次异常拖乱 ⇒ 没音乐。
    //   【为什么"重置就好、按多了反复"】这是纯仲裁饥饿：没有死锁，
    //     复位把两边都清干净就恢复；再切一次图又进同一个饥饿窗口。
    //   【修法·一行】把"正在装图"也算进图片优先：
    //       ~display_valid | img_loading
    //     · 首图之前：~display_valid=1 ⇒ 行为与原来完全一致（不引入回归）
    //     · 装图期间：img_loading=1 ⇒ 图像优先 ⇒ 1801 个扇区能连续读完
    //       ⇒ 帧写满再提交 ⇒ 白条消失
    //     · 不装图时：两项皆 0 ⇒ 音频绝对优先 ⇒ 正常播放的音质不受影响
    //   【代价·如实】装图那段时间（约 1801 扇区）音频会让出总线，
    //     FIFO 可能欠载 ⇒ 切图瞬间可能有极短音频中断；但这远好于现状
    //     （现状是"没音乐 + 白条"）。若听感不可接受，可改为"图像优先但
    //     周期性给音频让一窗口"（类似 wav_player 里已用的让出机制）。
    //   【安全】只改这一个输入表达式；arbiter 内部的优先级与握手一行未动；
    //     所有其他连接保持原样
    // ================================================================
    // ================================================================
    // 2026-10-16 补回丢失的修复：`| img_loading`
    //
    //   定版树（D:\fpga_build_release_20261012，md5 D1414147...）里这一行是
    //       .img_priority(~img_seen | (img_loading & fifo_lvl[1])),
    //   而移植到 _toolbuild / _toolbuild_scalerWIP 时只带过来了上面那段
    //   根因注释，代码这一行没跟上 —— 于是白条问题一直没被真正修掉。
    //
    //   根因（上面 1860-1878 行注释已写全）：本信号原为 `~display_valid`，
    //   而 sd_arbiter 的语义是
    //       img_priority=1 : fat > img > wav   （首图显示之前）
    //       img_priority=0 : wav > img > fat   （首图之后 = 音频绝对优先）
    //   但 display_valid 在首图一提交就恒为 1 ⇒ 此信号永久为 0
    //   ⇒ 此后音频每一轮仲裁都赢（播放时它几乎每拍都举着请求）。
    //   而手动切一张图要读 1801 个扇区（640x480x24bit = 921600 B）
    //   ⇒ 图像客户端抢不到扇区 ⇒ 帧缓冲写不满就被切到显示缓冲 ⇒ 白条；
    //     同时音频链路被这次异常拖乱 ⇒ 没音乐。
    //
    //   修法一行：把"正在装图"也算进图片优先。
    //     · 首图之前：~display_valid=1 ⇒ 行为与原来完全一致（不引入回归）
    //     · 装图期间：img_loading=1 ⇒ 图像优先 ⇒ 扇区能连续读完 ⇒ 帧写满再提交
    //     · 不装图时：两项皆 0 ⇒ 音频绝对优先 ⇒ 正常播放音质不受影响
    //
    //   ⚠️ 这一行同时影响图片和音频，是本轮音频回归的前提。
    //      改完必须用仿真台验证仲裁（见 tb_arbiter 计划），再上板。
    // ================================================================
    .img_priority              (image_priority_q),
    // [Design note]fifo_usedw[13] 就是 "FIFO 已用 >= 4096 B"（FIFO 深 8192，14 位计数）；
    //   与 fifo_lvl[1] 完全等效，但省掉 14 位比较器 => 不必再加寄存器打拍。
    // [Design note 切图断音]关键：display_valid 是锁存的 first_image_committed，
    //   上电后恒为 1 => 原来这里等价于 img_loading，切图期间 img_priority 恒为 1
    //   => 仲裁走 fat>图片>音频 分支 => 图片一直在请求就永远轮不到音频
    //   加 & fifo_lvl[1]（=FIFO>=4096，即半满以上）后：
    //     水位充足 -> 图片优先（快速装图）；水位一低 -> 优先级归 0，走 15:1 配额
    //   => 音频必定被服务。配合今早修的冷却相位锁死 bug，两者才真正成立。
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
    // [Design note 视频]第 4 个客户端，优先级最低（见 sd_arbiter.v 文件头）
    .vid_sd_sec_read           (vid_sd_sec_read),
    .vid_sd_sec_read_addr      (vid_sd_sec_read_addr),
    .vid_sd_sec_read_data      (vid_sd_sec_read_data),
    .vid_sd_sec_read_data_valid(vid_sd_sec_read_data_valid),
    .vid_sd_sec_read_end       (vid_sd_sec_read_end),
    .sd_sec_read               (sd_sec_read),
    .sd_sec_read_addr          (sd_sec_read_addr),
    // [Design note]这里必须用流水后的三兄弟（三者同拍延迟，语义一致）；
    //   用 raw 会让 data 与 read_end 差一拍 ⇒ 仲裁器提前退 SERV ⇒ 数据错乱。
    .sd_sec_read_data          (fs_logical_data),
    .sd_sec_read_data_valid    (fs_logical_valid),
    .sd_sec_read_end           (fs_logical_done)
  );

  // ===================== [Design note 视频]播放器 + 按键 =====================
  // 帧率上限在编码器里做（0xC0 填充字节），不在 RTL 里做：
  //   试过"等一个 vsync 再开下一帧"，能锁 60fps，但停下来等的时候上一个扇区的
  //   512 字节还在往 128 深的字节 FIFO 里灌 ⇒ 溢出丢字节 ⇒ 下一帧花掉（仿真复现）。
  //   要做对得把 FIFO 加到 ~600 深（1 个 BRAM），而本设计 slices 已 96%，不值。
  //   填充方案零硬件代价、帧率精确，解码器天然跳过（0xC0..0xFE 保留码）。
  // 触发方式：KEY3（板上 B1）长按 1.2 s 切换视频播放/停止。
  //   为什么用长按：KEY2/KEY4 已经被"播放暂停/快进/轮播/切歌"占满（见
  //   button_ctrl 那一大段历史注释），KEY3 目前只做"手动下一张图"且没有长按功能，
  //   所以长按是唯一不碰既有手势的位置。
  //
  // [Design note 视频 FIX]KEY3 → key_next 改接"分类后的 tap"，不再直连 key3_s2。
  //   旧接法：长按的前 20ms 被 sd_card_bmp 当成短按 ⇒ 开始装载下一张图
  //   （装载 0.3~4.7s + 转场 0.567s 期间 img_loading=1）⇒ 1.2s 的长按脉冲
  //   撞在装载窗口里被丢弃 ⇒ 板上表现为"长按完全没反应"。现在由 key_long
  //   先判断 tap/hold：长按根本不发 tap，就不会触发切图，img_loading 保持 0。
  wire video_key_hold;
  wire key3_tap_n;
  key_long #(
    .CLK_FREQ_HZ(SD_CORE_HZ),
    // 0.8 s：正常短按只有 50~300 ms，800 ms 已经明显区分开；
    // 原来定 1.2 s，而人估"长按"常常只按到 1 s 左右，容易差一点点不触发。
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
      // [Design note exp-io]扩展板 KEY0 只做"视频暂停/恢复"，
      //   不并进 btn_pause_evt —— 那条还会在非视频模式下暂停音乐，
      //   而 KEY0 的需求就是纯视频控制。
      if (!video_play || video_switching) video_paused <= 1'b0;
      else if (btn_pause_evt || exp_video_pause_evt) video_paused <= ~video_paused;
      // [Design note exp-io]扩展板 KEY3 一次按下 = 进入/退出视频
      //   （板载 B1 仍然要长按 0.8 s；两者都产生单拍事件，共用同一条边沿）
      if (video_key_hold || exp_video_toggle_evt) begin
        // [Design note BUGFIX-2]退出改成无条件。
        //   上一版把 `!img_loading` 删掉后板测仍然出不去（长按后 DIG2 还是
        //   video_play=1），说明挡路的不是 img_loading。视频侧一拿不到 SD 数据，
        //   播放器就会在两个状态之间来回抖（实测 DIG5 在 4/5 跳、DIG0/1 = 0fps），
        //   任何"先看条件再退"的写法都可能被这种抖动重新挂起。
        //   所以：只要当前在视频模式，长按就立刻退出，不判任何条件；
        //   进视频仍走原来的挂起机制（那边确实要等 video_can_start，
        //   否则没有视频文件时会把屏幕切成黑屏）。
        if (video_play) begin
          video_play         <= 1'b0;
          video_paused       <= 1'b0;
          vid_toggle_pending <= 1'b0;
          vid_exit_reload    <= 1'b1;  // 让图片路径重装一张，避免停在最后一帧
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

  // =========================================================================
  // [Design note 参赛版]VIDEO_ON = 0 => 整个视频子系统被 generate 剪掉。
  //   为什么：面积上"频谱 + 视频"放不下（频谱要 ~23.5%，视频占 ~8%，当前已 77%）。
  //   参赛版本要的是「图片 + 音频 + 频谱 + 拨码亮度对比度 + OSD 滚动字幕」，
  //   视频这条线的带宽问题（SD 卡每块 1,540 字节填充 ⇒ 0.91 MB/s）还没解决，
  //   所以先整块摘掉，把面积让给频谱。
  //   把 VIDEO_ON 改回 1'b1 就能恢复视频（视频的 RTL 全部保留，没有删任何东西）。
  // =========================================================================
  localparam VIDEO_ON = 1'b1;  // 动图演示版：视频打开（频谱为此关掉）

  generate
    if (VIDEO_ON) begin : g_video
      // ============================================================================
      // [Design note 换帧节流]把 video_clk 的 vsync 变成 sd_card_clk 域的单拍脉冲。
      //   做法：video_clk 侧每见一次 vs 边沿翻转一位 -> 3 级同步 -> 边沿检测。
      //   这样不管两个时钟差多少，每个显示帧正好送一个 tick，不会多也不会漏。
      // ============================================================================
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

  // ===================== FAT32 目录扫描（读 .WAV 歌名，启动时一次性） =====================
  // scan_start 在 sd_init_done 拉高后延迟约 5us 发一次（仲裁器 img_priority
  // 阶段 fat 优先，几十个扇区即可扫完根目录）。
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
        if (fat_scan_cnt == 20'd500)   // 历史100MHz换算；v167以SD_CORE_HZ及实际计数阈值为准。 ~5us @旧控制频率
          fat_scan_start <= 1'b1;
      end
    end
  end

  fat32_list u_fat32_list (
    .fat_start_o           (fs_fat_start),
    .cluster_shift_o       (fs_cluster_shift),
    .max_cluster_o         (fs_max_cluster),
    .geometry_valid_o      (fs_geometry_valid),
    .filesystem_error_o    (fs_mount_error),
    .clk                   (sd_card_clk),
    .rst                   (rst_all | !sd_init_done),
    .scan_start            (fat_scan_start),
    .sd_init_done          (sd_init_done),
    .sd_sec_read           (fat_sd_sec_read),
    .sd_sec_read_addr      (fat_sd_sec_read_addr),
    .sd_sec_read_data      (fat_sd_sec_read_data),
    .sd_sec_read_data_valid(fat_sd_sec_read_data_valid),
    .sd_sec_read_end       (fat_sd_sec_read_end),
    .list_ready            (list_ready),
    .song_count            (song_count),
    // 当前曲目号由 track_ctrl 给出：既用来取扇区，也用来显示歌名
    // （song_idx 已按 song_count 取模，永远 < 32，不会越界访问歌单表）
    .list_idx              (play_song_idx[4:0]),
    .list_name             (list_name),
    .list_sector           (list_sector),
    // [Design note]把数据区首扇区引出来给图片扫描做起点（list_ready 后有效）
    .data_start_o          (fat_data_start),
    // [Design note 视频]根目录里第一个 .VID 文件的起始扇区（0 = 卡上没有视频）
    .video_sector_o        (legacy_video_sector),
    // [Design note 视频配音轨]根目录里第一个 .VAU 文件（0 = 没配专属音轨）
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
    // [Design note 字节级探针]扇区0 的 byte0（只读观测，不参与任何内部判断）
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
    // [Design note CMD18 多块读]WIP：驱动侧已实现（sd_card_cmd.v 多块计数、
    //   sd_card_sec_read_write.v 的 S_CMD18/S_HIT/pbuf），SPI 级仿真实测
    //   1.48x（0.91 -> 1.35 MB/s），但数据对齐还有一个 bug（批量第一个
    //   字节是 0xFF、地址也不对），所以这里先接 0，让所有客户端走原来的
    //   单块 CMD17 路径 —— 行为与改动前完全一致，随时可以综合。
    //   等对齐 bug 修掉、仿真里数据全对，再改成 .sd_read_multi(vid_grant)。
    //   （sd_arbiter 已经导出 vid_grant，接线只差这一行。）
    .sd_read_multi(fs_card_multi),
    .sd_read_paced(fs_card_pace),   // [Design note]重新启用 CMD18：收尾已修（见 sd_card_cmd.v S_STOP_CMD/S_STOP_DRAIN）
    // [Design note 停用]CMD18 多块读在真卡上两次都失败
    //   (FPGVB 数据错乱 / FPGVC 开机就挂)，已回退为单块
    //   CMD17。RTL 里的 S_CMD18/S_READ_NEXT/pbuf 保留但
    //   不可达，等有示波器/逻辑分析仪能抓真卡 SPI 波形
    //   再重启 —— 纯仿真已无法覆盖真卡的字节时序。
    // [Design note] 组19：SD 侧只读镜像（唯一 sd_card_top 实例）
    .dbg_sd_state(wav_dbg_sd_state),
    .dbg_sd_cmd_err(wav_dbg_sd_cmd_err)
  );

  // [Design note 诊断]把 bmp_read 的 state_code 译码后接到 DIG5（原来译码结果无人使用被优化掉）
  // [Design note 现象2]bmp_read 里 ST_LOAD_HDR 原来也是 4'd2，与 ST_SCAN(4'd2)
  //   撞码，DIG5 读 2 时无法区分"在扫描"还是"在读 BMP 头"，本轮定位被误导过一轮。
  //   现在 ST_LOAD_HDR = 4'd5，DIG5 的完整含义（小数点 = display_valid）：
  //     0 = bmp_read 复位/未初始化        （正常只在 sd_init_done 之前出现）
  //     1 = ST_IDLE  空闲                 （正常：出图后停在 1，且小数点亮）
  //     2 = ST_SCAN  正在逐扇区扫 BMP 头   （正常：上电后先出现，phase B 后台补扫时也会出现）
  //     3 = ST_LOAD_WAIT 等帧缓存授权      （正常：一闪而过）
  //     4 = ST_LOAD_DATA 正在把整张图灌进帧缓存（正常：约 0.3~0.6s）
  //     5 = ST_LOAD_HDR  正在读/校验 BMP 头（新增码，正常：一闪而过）
  //   小数点（DIG5 的 dp）= display_valid：亮 = 已有一张图提交到屏上。
  wire [7:0] img_state_seg;
  seg_decoder seg_decoder_m0 (
    .bin_data(state_code),
    .seg_data(img_state_seg)
  );

  // ============ [Design note 字节级探针]DBR 首字节判读（只挂 DIG4）============
  // 回答的问题："从 DBR 扇区读回来的第 0 个字节是不是 0xEB？"
  //   fat_mbr_b0 = fat32_list 内部 mbr_b0 = 扇区0 的 byte0。
  //   本卡是超级软盘（无 MBR，DBR 直接放在扇区0），所以扇区0 的 byte0
  //   就是 DBR 的 byte0；正常值 = 0xEB（或 0xE9），即 x86 near/short jump。
  // 显示：
  //   0xEB / 0xE9 -> 'H'  （H 不是十六进制字形，一眼区分"签名正确"）
  //   其它        -> fat_mbr_b0 低 4 位的十六进制，直接读出实际收到的值
  //                  （0xFE 数据令牌 -> E；0x58/0x3C DBR byte1 -> 8/C；0x00 -> 0）
  // 纯组合观测，DIG0..DIG3 与 DIG5 全部保持原义不变。
  // 注意：此处调用 hex7，故本段必须位于 hex7 的函数声明之后。
  wire [6:0] dbr_probe_seg = (fat_mbr_b0 == 8'hEB || fat_mbr_b0 == 8'hE9)
                           ? 7'b0001001                  // 'H' = DBR 签名正确
  : hex7(
      fat_mbr_b0[3:0]
  );  // 否则显示低 4 位

  // ================================================================
  // 2026-10-13 STICKY PROBES for the HEADER-PARSE PHASE.
  //   On-board reading #1: state=0 (IDLE) and wav_ready=0 (dp LIT, active
  //   low) => the FSM never reached ST_STREAM. So it either never started,
  //   or it started and fell back.
  //
  //   The parse can ONLY advance on data_beat:
  //       data_beat = sd_sec_read_data_valid && req_done        (L342)
  //       parse block runs on  (state == ST_HDR && data_beat)   (L553)
  //       end_pos is set only once the 4-byte length field has been fully
  //       received (L588), and hdr_valid_w requires
  //       (dlen_arm == 0) && (end_pos != 0) && ...              (L627)
  //   => if NO BYTE EVER ARRIVES, the parse never moves, end_pos stays 0,
  //      hdr_valid_w stays false, and the FSM can never enter ST_STREAM.
  //      That is the most likely head-phase failure on real hardware.
  //
  //   ZERO CORE CHANGE: sd_sec_read_data_valid is already a TOP-level net
  //   (wav_sd_sec_read_data_valid, fanned out by sd_arbiter). Watching it
  //   here tells us whether bytes ever reached the player at all.
  //
  //   dp (active LOW) = sticky "a data byte ever arrived":
  //       dp OFF (=1) => BYTES DID ARRIVE  => parse should have progressed
  //       dp LIT (=0) => NOT A SINGLE BYTE => the failure is upstream
  //                      (bus / arbitration / sd_card_top), not the parser
  //   seen_hdr separately records "ever left IDLE" so that a final state of
  //   IDLE can be told apart from "never started".
  //   Declared BEFORE seg_scan_m0 on purpose: TD reports HDL-5373 for
  //   use-before-declaration. Each register is driven ONLY here => no
  //   multi-driver risk (the hw0[7] lesson).
  // ================================================================
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

  // ================================================================
  // [DIAG 2026-10-11 ffprobe-v3] 快进档案：按键脉冲总数 + 【每次按键】的跳幅(20ms 窗口)
  //   DIG0..1 = btn_ff_tick 累计计数低8位（按前后各读一次相减 = 本次按键的脉冲数）
  //   DIG2..4 = (跳幅字节 >> 12) 三位十六进制：10s => 0EA ｜ 乘性缺陷(旧片) => AFC
  //   v3 相对 v2 的两处修正：
  //     ① 位选修正——v2 写的 [19:16]/[15:12]/[11:8] 实为「>>8」口径（与注释的
  //        「>>12」不符，示值 = (跳幅/256) 的 12 位），已改为真正的 >>12 位选：
  //        [23:20]/[19:16]/[15:12] ⇒ 示值单位 = 4096B ≈ 42.7ms；
  //     ② 每次按键重采样——v2 的 ff_st 捕获一次后停在 2'd2，跳幅永远冻结在
  //        【上电后第一次按键】；v3 在捕获完成后等下一次 btn_ff_tick 重新开始，
  //        ⇒ 任意第 N 次按键后都能读到【本次按键首 tick】的 20ms 窗口跳幅。
  //   判读：正常 = 每次按键 ≈ 0EA（单 tick 一格 10s；一次物理按压常触发 ≥2 个
  //         tick ⇒ 连按的每格都应是 0EA，不应出现 AFC）。乘性缺陷（seekdone-fix
  //         已修，可用旧片 FIXED9 回归）= 第 2 次起每次 ≈ AFC（≈2 分钟）。
  // ================================================================
  // [Design note 面积/时序]快进诊断（ff_c0/ff_c1/ff_wait/ff_st/ff_ticks/ff_diff）整块删除。
  //   唯一用途是把"每次 ±10s 按键的跳幅"显示到数码管上（纯诊断，无功能消费者），
  //   却占 103 个 FF + 一个 21 位减法器 + 一个 32 位减法器；而且 EDID 停用之后
  //   ff_c1 -> seg_data[0] 成了唯一的违例路径（-0.336 / 8 级）。
  //   删除后数码管显示"工作状态"（SD 状态码 / WAV 状态码 / 帧率），见 seg_data_* 处。
  //   恢复办法：rtl_state\final\ 快照里有这一版。
  wire [15:0] ff_ticks = 16'd0;  // 名字保留给下面的显示分支（已不使用）
  wire [31:0] ff_diff = 32'd0;

  // [NOTE 2026-10-11] 诊断探针已全部撤除（ffprobe/rateprobe 等），交付版为原始显示。

  // ================================================================
  // Frame-rate diagnostic window:88778*1024 SD/control cycles, approximately1s.
  // This counter only drives diagnostics; A/V timing uses actual PCM consumption.
  reg  [16:0] dg_seconds_div;
  reg [8:0] dg_vfr, dg_vfr_prev;
  reg  [7:0] dg_fps;
  reg  [9:0] dg_div;
  reg  [1:0] dg_vbi_d;
  wire       dg_tick = (dg_div == 10'd0);

  // [Design note 面积]占空比诊断（dg_sdcnt / dg_wfcnt / dg_tot / dg_sdhi / dg_wfhi /
  //   dg_sd_en / dg_wf_en）整块删除：它们只用来在数码管上显示"SD 请求占空比 / 写背压
  //   是否 >50%"，没有任何功能消费者，却占 51 个 FF + 3 个 17 位加法器 + 4 条比较锥
  //   （上一轮实测 5~8 个违例端点，最差 -0.337）。
  //   现在数码管改成显示真正有用的"工作状态"：
  //     DIG0/1 = 视频时帧率（dg_fps，保留）/ 音频时 WAV FSM 状态码
  //     DIG2   = {WAV ready, 正在放视频}
  //     DIG3   = SD 读写 FSM 状态码（wav_dbg_sd_state[3:0]）
  //     DIG4   = SD 状态码高位 + 小数点 = "SD 命令曾出错"
  //     DIG5   = WAV FSM 状态 + 小数点 = wav_ready（原有的板上探针）
  //   恢复办法：rtl_state\final\ 快照。
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
    // 【修复8】debug 分支里 DIG0/DIG1 的小数点改显示两个自愈检测器的粘滞位：
    //   DIG0.dp = 静音检测器曾触发 ; DIG1.dp = 位置偏差检测器曾触发
    //   正常分支（kp_debug_on=0）仍是原来的 1'b1 —— 一位都没动
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
    // [Design note]debug 分支里 DIG2/DIG3 的小数点改显示 stereo / channels 告警：
    //   DIG2.dp = stereo 当前值（正常 1）; DIG3.dp = 曾解析出非 2 声道（正常 0）
    // [Design note]debug 分支里 DIG2 的小数点：消费端组显示 = 当前音量是否为 0 （其它组仍是 stereo ）
    // [Design note 诊断结论]把"音频域健康字"塞进数码管虽然信息量大，但数码管是
    //   pin-bound 路径（6:1 扫描 + 输出管脚）。两次构建它都变成 -0.94 ns 的最差锥，
    //   整体 WNS 从 +101 崩到 -942、还带出 hold -1476。
    //   所以这里还原成精简版：DIG2/DIG3 回到原来的内容，
    //   只保留 DIG5 的粘滞 track_bad（一位 FF，代价极小）。
    .seg_data_2        (kp_debug_on ? ((PROBE_GRP == 5'd4) ? {wav_dbg_ack_seen, dbg_d2} : {stereo_o1, dbg_d2})
                        : {1'b1, hex7(
        {2'b00, wav_ready, video_play}
    )}),
    .seg_data_3(kp_debug_on ? {ch_not2_hit, dbg_d3} : {1'b1, hex7(wav_dbg_sd_state[3:0])}),

    // DIG4 = 字节级探针（原来这里是"快进中"的 'F'，属纯装饰：真正的快进由
    //        btn_ff_tick 驱动 playback_status.seek，与此显示无关，功能零影响）
    // [Design note]debug 分支里 DIG4 的小数点 = 活的 LRCK 指示（5ms 内有翻转 = 亮 ）
    //   ⚠️ 上一版这里被写成"字面 \n"（不是换行）⇒ 整条 .seg_data_4 连接【被注释掉】
    //      （TD 对缺失的端口连接只告警、不报错 ⇒ 静默存活了几版 ）——本次修掉
    // [Design note 诊断]DIG4 改成「切图断音」的四个 sd 域探针：
    //   bit3 = img_priority（仲裁器实际看到的优先级）
    //   bit2 = img_loading （图片正在装载）
    //   bit3 = img_seen  ... 见下
    // 读法：8=优先级被拉高  4=正在装图  2=出过图  1=音频正在请求
    .seg_data_4        (kp_debug_on ? {(lrck_recent_cnt != 20'd0), dbg_d4}
                                    : {wav_dbg_sd_cmd_err,
                                       (video_play ? vau_fault_seg : hex7(
        {2'b00, wav_dbg_sd_state[4:3]}
    ))}),
    // [Design note diag-v2]DIG5 的小数点在 debug 分支里改成显示
    //   读取器请求电平 wav_sd_sec_read（1 = 请求举着 / 正在等 read_end）。
    //   正常分支仍是 display_valid（图片是否已提交）—— 一位都没动
    //   判读：故障时小数点常亮且 DIG0/1/2/5 的地址数字冻住 => 握手互锁
    // ============================================================
    // 2026-10-13 ONBOARD PROBE: put the PLAYER FSM STATE on the last
    //   (physically RIGHTMOST) digit, with the decimal point = wav_ready.
    //   Reason: the new player never plays on real hardware and every
    //   simulation-based hypothesis has been falsified. This makes the
    //   board report WHERE it is stuck, using only signals that already
    //   exist (wav_dbg_state is wired at L1387, wav_ready at L1365) -
    //   no new logic, no new register.
    //   PHYSICAL POSITION (verified from seg_scan.v + pin.adc + user
    //   observation): seg_data_0 = LEFTMOST ... seg_data_5 = RIGHTMOST.
    //     left->right: song_idx | song_count | 'A' | 'P' | probe | THIS
    //   READOUT (dbg_state = wav_player FSM):
    //     0 + dp OFF = never became ready (stuck IDLE)
    //     0 + dp ON  = was ready once, fell back to IDLE
    //     1          = STUCK IN HEADER PARSE   <- most informative
    //     2          = entered STREAM => look downstream (I2S/FIFO)
    //     3          = stuck in seek / track change
    //   The previous DIG5 content (img_state_seg) was the least useful
    //   for an audio-not-playing diagnosis, so it is the one sacrificed.
    //
    //   ---- 2026-10-13 (2) DECIMAL POINT = STICKY "ever left IDLE" ----
    //   On-board reading #1 gave state=0 and the dp LIT. dp polarity is
    //   ACTIVE LOW (seg_scan.v: reset/default drive 8'hff = all off), so
    //   dp LIT meant wav_ready = 0, NOT 1. Corrected reading:
    //       state = 0 (IDLE) and wav_ready = 0  => never reached ST_STREAM.
    //   That is consistent, but it cannot distinguish "never started" from
    //   "started, failed, fell back". So the dp is re-purposed to a STICKY
    //   flag: ONCE the FSM has been seen outside IDLE, seen_hdr stays 1.
    //       dp OFF (=1, active low) => it DID leave IDLE at least once
    //       dp LIT (=0)             => it NEVER left IDLE
    //   wav_ready remains readable from the state digit itself (the dp is
    //   redundant with it: wav_ready=1 only while state!=0).
    //   Cost: ONE new register, driven ONLY here in the top => no
    //   multi-driver risk (the hw0[7] lesson).
    // ============================================================
    // [Design note 视频]最右一位数码管改成状态探针，判读表见
    //   烧录指引_视频_20261017.md。
    //   video_play=0 且无挂起时显示内容与改动前逐位相同（还是 wav_dbg_state）。
    //   放视频期间（vau_tgt=1）改为显示音轨切换的结果：
    //     E = 卡上没找到 .VAU（vaudio_sector==0）⇒ 走不通，去查卡
    //     8 = 音频 FSM IDLE / 9 = 读头部 / A = STREAM（正常出声）/ B = SEEK
    //   （高位置 1 是为了和图片模式的 0~3 区分开）
    //   不含视频时：9 = 长按已识别等待中，8 = V_BAD，其余 0~7 是视频 FSM 状态
    // ============================================================
    .seg_data_5(kp_debug_on ? {wav_sd_sec_read, dbg_d5} : {~seen_byte,
    // [Design note 时序]原来这里直接写 `vau_sector == 32'd0`，
    //   而 vau_sector 来自 fat32_list 的 vaudio_sector_r（32 位）。
    //   一个 32 输入 NOR + 后面的 vau_tgt/vid_toggle_pending/
    //   video_play 三级三目 + hex7 译码 + 顶层的显示三目
    //   + seg_scan 的 6:1 扫描，串成 9 级组合直冲输出管脚
    //   （实测两根 -0.454/-0.452，是当时 4 个违例里的大头）。
    //   改成预先寄存一位标志，把最前面那 3 级从路径里拿掉。
    // [Design note 诊断版]"音轨不靠谱"要看的恰恰是音频播放器，
    //   而视频模式原来显示的是 vid_dbg_state（视频状态）。这里改成
    //   { wav_track_bad , wav_state[2:0] }：
    //     数字：0=IDLE 1=HDR 2=STREAM 3=SEEK
    //     视频模式下这一位就是 WAV 播放器状态（不再显示视频状态）
    //   看到 2 且有噪声 ⇒ 播放器认为在正常播 ⇒ 数据源/输出问题
    //   看到 0/1/3 反复跳 ⇒ 在反复失败重启（看门狗循环）
    hex7(
        vau_tgt ? {wav_tbad_sticky, wav_dbg_state}
                                        : (vid_toggle_pending ? 4'h9
                                         : (video_play ? {wav_tbad_sticky, wav_dbg_state}
                                                       : {1'b0, wav_dbg_state}))
    )})
  );

  // ============================================================================
  // [Design note 简化交付]扩展板 74HC595 数码管：本版不驱动
  //---------------------------------------------------------------------------
  // 原因：杜邦线拉 1 MHz 的 SCLK 不稳定，8 位显示看不清，反而干扰判断；
  // 而"看周期档位"用开发板自带的 6 位数码管就够了 —— DIG1 现在显示完整 4 位档位码
  // （hex 0..F，见下面 seg_scan 的 .seg_data_1）。
  //
  // 本版因此：
  //   · 删掉 exp_seg_rclk / exp_seg_dio / exp_seg_sclk 三个输出端口，J1-31/32/35 空出来；
  //   · J1 上只剩 13 根输入 + 2 根地 = 15 根线，全是"插上就不动"的线；
  //   · rtl/seg595_display.v 与 tb_expansion_io.v 保留（已仿真验证过，随时可用）。
  //
  // 以后线材条件好了（建议 4 芯排线，SCLK 与 GND 就近回流）恢复只需三步：
  //   1) 顶层加回三个 output 端口；
  //   2) pin.adc 加回 J1-31/32/35 三条约束（LVCMOS33, DRIVESTRENGTH 8）；
  //   3) 取消下面这段注释，并把 seg595_display.v 加回 .al 文件列表。
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

  // ===================== 原图像时序与帧缓存 =====================
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

  // 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
  // 【转场 FIX 2026-10-07】图像层先过 fader 再进 OSD：
  //   fade_img 在 fade_in 内部恒等（转场结束/未转场时 lvl=0，精确透传 din），
  //   转场期间只有图片变暗 —— OSD 字幕/进度条/按键格子、FFT 频谱柱都不跟着淡。
  //   这里 display_valid 的优先级和原来完全一致（它是最外层的门）。
  // [Design note 视频]改接 display_valid_any：视频模式下由"第一帧已写满"决定，
  //   否则保持原来的 display_valid（图片路径），行为逐位不变。
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
    // [Design note 视频]第三块帧缓冲（三缓冲轮转，见 rtl/video_player.v）
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
    // [Design note 视频]第三块帧缓冲（三缓冲轮转，见 rtl/video_player.v）
    .write_addr_2     (BUF2_ADDR),
    .write_addr_3     (24'd0),
    .write_addr_index (write_buf_idx),
    .write_len        (FRAME_PIXELS),
    // [Design note 缩放·写侧补黑]源图高度 -> VFLIP 写起始 (H-1)*640
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

  // ===================== 音频接收（不变） =====================
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

  // ============================================================================
  // [Design note 视频音轨标题]视频模式下不显示歌单名，改显示视频音轨标识。
  //   OSD 的 song_name 是 8 字节大端 ASCII（char_rom 覆盖 0x20..0x7E，含 '/'）。
  //   video_play 在 sd_card_clk 域，这里 2FF 同步进 video_clk（慢信号，单比特安全）。
  //   video_clk 只有 25.175 MHz，这条 mux 的时序余量极大，不参与 sd_card_clk 关键路径。
  // ============================================================================
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

  // ===================== [Design note bc-osd]拨码开关：同步 + 档位映射 =====================
  //   sw 为慢速静态电平（拨码），3 级同步进 video_clk；SW[1:0]/SW[3:2] 查表映射为
  //   亮度偏移与对比度 Q7 档位。映射表与 osd_player_ui 内的显示查表【必须一致】！
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
    .sw_deg     (sw_deg),            // [Design note bc-osd]参数拨码档位（B/C 显示）
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

  // ===================== FFT 音频频谱（video_clk 域，无跨时钟域） =====================
  // [Design note 面积]SPECTRUM_ON = 0 时整个频谱子系统（audio_frame + fft_256 +
  //   spectrum_capture + spectrum_display）被 generate 剪掉，综合器不再实现它们：
  //   实测这三个实例合计 1,594 gates + 1,586 FF，而设计已经到 97.87% 布线失败
  //   （PHY-8023 拥塞，u_fat32_list/mux98）。关掉它可以腾出约 1,400~1,900 slices，
  //   用来放真正需要的功能（视频取数诊断、音频 FIFO 加深等）。
  //
  //   像素通路的相位必须保持：spectrum_display 在 en=0 时是"打 1 拍再输出"，
  //   所以旁路分支也必须打 1 拍，否则整幅画面会横向移 1 像素。
  //   电视/HDMI 输出只是少了频谱柱状图，图像、视频、OSD、音频全部不受影响。
  // [Design note 实测取舍]三个功能全开 = 4958 mslices > 4900 上限，放不下。
  //   三种可行组合（都实测过）：
  //     频谱 + 视频        = 4881 mslices / WNS -2420   （无专属音轨）
  //     视频 + 音轨        = 3768 mslices / WNS -1110   ← 当前（最健康）
  //     频谱 + 音轨(无视频) ≈ 3900 mslices               （未构建，理论上最宽裕）
  //   想三个全要：只能砍频谱的柱数（48→24 可省一半的多路选择器），见交接文档。
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

      // 频谱柱状图叠加到视频（内部重建坐标，输出延迟 1 拍对齐）
      // [Design note 视频]放视频时关掉频谱：en=0 时 spectrum_display 变成纯直通
      //   （输出 rgb_q，与 de_q 同拍延迟 ⇒ 像素级无差别，不会横移）。
      //   vid_active 在 sd_card_clk 域，这里两级同步到 video_clk；晚一帧生效无所谓。
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
      // ---- 频谱关闭：纯旁路，但必须保持 1 拍延迟（与原 en=0 通路一致）----
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

  // ===================== 切图淡入淡出转场 =====================
  // 检测 disp_buf_idx 切换（sd_card_clk 域），同步到 video_clk 域生成 switch 脉冲
  // 【转场 FIX 2026-10-07】这个脉冲现在只当超时恢复用：正常切图走
  //   fade_req/fade_done 两段式握手（见 sd_card_bmp.v），换 buffer 时一定处于
  //   淡入阶段（busy=1），所以这个脉冲会被 fader 忽略。只有"没有握手的硬切"
  //   （异常情况）才会用它，行为退回旧版"从黑淡入"。
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
  // [Design note 视频]视频换帧时 disp_buf_idx 每帧都会变，而这个脉冲会让
  //   fade_in 走"从黑淡入"的超时恢复路径 ⇒ 每帧都黑一下。视频必须硬切，所以屏蔽它。
  //   图片路径（vid_active=0）完全不受影响。
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

  // ---- 图像层淡入淡出（无乘法器；纯组合数据通路）----
  //   接在 vout_data 那一级（OSD 之前）—— OSD/频谱不跟着淡。
  //   vs 用 disp_vs（video_clk 域帧同步，旧版就是这个信号，极性已验证）。
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

  // ===================== [Design note bc-osd]亮度/对比度（拨码实时调节，免乘法） =====================
  //   插在频谱/OSD 叠加之后、送 HDMI 之前 ⇒ 作用于最终画面像素（含 OSD 文字，属预期）；
  //   1 拍流水线输出与 disp 组同拍对齐后进 rgb_to_axis（vs/de/rgb 三者一起过流水）。
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

  // ===================== RGB/DE 转 AXIS 视频 =====================
  // 【转场 FIX 2026-10-07】fader 已经不在这一级了（它现在在 OSD 之前），
  //   所以这里直接用 spectrum_display 对齐输出的 disp_de/disp_vs/disp_rgb。
  // [Design note bc-osd]改接 brightness_contrast 的 1 拍对齐输出。
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

  // ===================== [Design note 面积]EDID/DDC 读取器停用 =====================
  //   原来的 u_startup_pulse 在上电 +100k 拍（25 MHz 下约 4 ms）打一拍
  //   edid_trig，让 HDMI 核里的 I2C master 去读显示器的 EDID。
  //   实测：读回来的 edid_valid/edid_data 全设计没有任何消费者
  //   （只有两个 wire 声明），而它占 211 LUT + 155 FF + 2 BRAM（≈90 mslices）。
  //   HDMI 核是加密 IP（hdmi_1_4b_transmitter_core_wrapper.enc.v），删不掉里面的实例，
  //   但把触发端接常量 0 后 I2C master 永远停在 IDLE，综合器可以把它大半剪掉。
  //   零功能风险：EDID 数据本来就不影响任何行为；DDC 两根线保持不被主机驱动
  //   （显示器侧有上拉，HDMI 规范允许不读 EDID）。
  //   回退：把 .I_edid_read_trig(1'b0) 改回 edid_trig，并恢复下面的 startup_pulse。
  // ===================== 带音频的 HDMI 1.4b 发射 =====================
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
    .I_edid_read_trig (1'b0),        // [Design note 面积]EDID 读取器停用，见上方注释
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

