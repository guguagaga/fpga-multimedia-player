// -----------------------------------------------------------------------------
// Module purpose: Image loading, prefetch and slideshow control.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
//===================================================================
// sd_card_bmp : BMP image controller (SD sector-read interface version)
//===================================================================
// Modified from the official lab_ex5_i2s example so that the SD card
// (sd_card_top) is SHARED with the audio reader through an sd_arbiter.
//
// The internal sd_card_top has been removed. This module now exposes a
// plain SD sector-read interface (sd_sec_read / addr / data / valid /
// end) that connects to a shared sd_card_top via an sd_arbiter. The
// physical SPI pins (SD_nCS/DCLK/MOSI/MISO) no longer exist here.
//
// Everything else (BMP scan / load / double-buffer display switching,
// key debounce) is unchanged from the official example.
//===================================================================
module sd_card_bmp #(
  parameter                DIRECTORY_IMAGES  = 1,
  parameter integer        CLK_FREQ_HZ       = 100_000_000,
  parameter         [31:0] SCAN_MAX_SECTOR   = 32'd131071,
  parameter         [ 2:0] SCAN_TARGET_COUNT = 3'd4,
  // [Design note 修复 现象1]phase A（受限扫描）的扇区预算，透传给 bmp_read
  parameter         [31:0] SCAN_INIT_BUDGET  = 32'd6000,
  // [Design note 现象2 超时恢复]首图加载看门狗超时（单位：clk 周期）。
  //   背景：首图加载靠一条 1 拍宽的 load_start_pulse；一旦它被 bmp_read
  //   丢掉（本次定位到的确定性死锁就是这种情况），load_busy 会永远停在 1，
  //   首图永远不加载 = 整场黑屏。这里给一个"毫无进展"的超时：超时后撤销
  //   load_busy，让下面"首图自动加载"的条件重新成立 -> 自动重试。
  //   2 s @100MHz。TB 可以传一个小值来快速验证超时恢复逻辑。
  parameter         [31:0] LOAD_WAIT_MAX     = 32'd200000000,
  // [Design note #2]首图/转场握手 超时超时恢复门槛（单位 = 4096 拍）。
  //   默认 97656 -> 97656 x 4096 / 100MHz ≈ 4.0s（一次正常加载约 0.30s）。
  //   放在参数表里是为了 TB 能传一个很小的值来快速验证超时恢复路径。
  parameter         [16:0] TO_TICKS          = 17'd97656,
  parameter         [31:0] FRAME_WORDS       = 32'd307200
) (
  input             clk,
  input             rst,
  input      [ 2:0] directory_count,
  input      [31:0] directory0, directory1, directory2, directory3,
  input             key_next,
  input             key_auto,         // KEY4 短按 = 轮播 开/关
  // [Design note exp-io]轮播周期改由扩展板 4 位拨码 exp_sw[3:0] 选择。
  //   period_code     : 当前已生效的档位码 0..15（由 carousel_period_cfg 在
  //                     "图片装载完成"的边界上锁存）—— 只用于数码管显示。
  //   auto_period_sec : 当前已生效的周期秒数 2..600（同上锁存）。
  //   计时器仍在本模块内：auto_tick = 1 s 的 tick 数秒 + 10 位饱和计数器，
  //   不会回绕、不会出现 0 秒周期（预设表里没有 0）。
  input      [ 3:0] period_code,
  input      [ 9:0] auto_period_sec,
  // [Design note]键盘 D 单击：立即重开计时并打开轮播。
  //   不再循环档位（档位已由拨码决定），只保留"马上从这一张重新计时"的手感。
  input             period_reseed,
  output     [ 3:0] state_code,
  input      [15:0] bmp_width,
  input      [15:0] bmp_height,
  output reg        display_valid,
  output            img_loading,      // 1 = image load in progress (for SD arbiter priority)

  // [Design note]扫描进度（扇区号），给顶层做开机 LOADING 等待画面
  output [31:0] scan_sector,
  // [Design note 修复 现象1]已经缓存到几张图（0..4），以及扫描是否完成。
  //   顶层用它决定"phase A 结束后要不要发起 phase B 后台补齐扫描"。
  output [ 2:0] found_count_o,
  output        scan_done_o,
  output [ 3:0] auto_mode_o,     // 显示用：0=关，否则 = 完整 4 位档位码 0..F
  // [Design note]周期配置的安全生效边界（连到 carousel_period_cfg.boundary）：
  //   轮播关着 -> 恒 1（连续跟随拨码，所以"关一次轮播再拨码"就是立即生效）；
  //   否则只在 load_finish（一次图片装载结束）那一拍为 1。
  //   ⇒ 换档永远不会打断正在进行的装载/预取，只在"这张图装完、该上屏了"的时候生效。
  output        cfg_boundary_o,
  // [Design note]轮播开关本身（扩展板 595 面板显示 'A' / '-'）
  output        auto_on_o,

  // [Design note]开机扫描起点：由顶层把 fat32_list 算出的数据区起始扇区接进来。
  // 原来是 parameter SCAN_START_SECTOR = 32'd0，从扇区 0 开始白扫 32768 个
  // 保留区/FAT 表扇区（占掉 5.4s 里的绝大部分）。
  input [31:0] scan_start_sector,

  // [Design note 修复 现象1]两趟扫描的接口（透传给 bmp_read）：
  //   scan_start_sector2/scan_start2/scan_limited 由顶层给出，用于
  //   "首图显示之后，在后台从 phase A 停下的位置把剩余图片补齐"。
  input [31:0] scan_start_sector2,
  input        scan_start2,
  input        scan_limited,

  input            write_finish_toggle,
  output reg [1:0] write_buf_idx,
  output reg [1:0] disp_buf_idx,

  // 【转场 FIX 2026-10-07】两段式提交握手 + 转场期间禁止开始新的切图装载。
  //   switch_lock     : video 域 fade_busy（顶层已同步到 sd_card_clk）——1 = 转场中，
  //                     此时不接受新的"切图"装载请求（请求仍会被记在 next_req_pending，
  //                     转场结束后自动执行，不会丢键也不会连跳两张）。
  //   fade_req_toggle : 本模块发给 video 域的 toggle —— "新帧已就绪，请把旧图淡出到黑"。
  //   fade_done_pulse : 顶层把 video 域的 fade_done toggle 同步成的 1 拍脉冲 ——
  //                     "淡出完成，可以换 buffer 了"。
  input            switch_lock,
  // [Design note 视频]1 = 视频正占用写通路。语义与 switch_lock 相同：
  //   不为"切图"发起新的装载（按键请求仍记在 next_req_pending 里，视频退出后执行）。
  //   首图装载不受它影响：开机必须出首图，而顶层只在首图提交后才允许进视频。
  input            vid_lock,
  output reg       fade_req_toggle,
  input            fade_done_pulse,
  // 【首图必出图 超时恢复 2026-10-07】1 = 首图是靠"超时超时恢复"提交的（正常路径恒 0）。
  //   顶层把它引到数码管 DIG3 显示 'F'，上板一眼就能判断有没有走超时恢复。
  output           firstimg_fallback_o,
  // 【根因诊断 2026-10-07 #2】超时恢复触发那一拍锁存下来的 4 个状态位：
  //   {wrfin_seen, source_done_seen, bmp_ready, pixel_wr_seen}
  //   只要走了超时恢复，顶层 DIG3 就显示这个十六进制位，直接判定卡在哪一环。
  output     [3:0] firstimg_diag_o,

  output             write_req,
  input              write_req_ack,
  input              write_almost_full,
  output             write_en,
  output      [31:0] write_data,
  // [Design note 缩放·写侧补黑]本次正在装载的源图高度（取自 BMP 头，1..480）。
  //   顶层把它接到 frame_read_write 的 write_img_h，用来把 VFLIP 写起始
  //   从 479*640 改成 (H-1)*640（图在上、黑在下）。H=480 时与原行为逐位相同。
  output      [15:0] img_h_o,
  output wire        source_top_down,

  // ---- SD sector-read interface (to sd_arbiter) ----
  input         sd_init_done,
  input         sd_error,
  output [31:0] file_base_lba,
  output        sd_sec_read,
  output [31:0] sd_sec_read_addr,
  input  [ 7:0] sd_sec_read_data,
  input         sd_sec_read_data_valid,
  input         sd_grant,
  input         sd_sec_read_end
);

  wire        key_next_press;
  wire        key_auto_press;

  wire        bmp_data_wr_en;
  wire [23:0] bmp_data;
  wire        bmp_ready;
  wire        image_load_error;
  wire        bmp_scan_done;
  wire        scan_done;
  wire        scan_found_valid;
  wire [31:0] scan_found_sector;
  wire [ 2:0] scan_found_total;

  reg         scan_start_pulse;
  reg         load_start_pulse;
  reg  [31:0] load_sector;
  reg         scan_kicked;
  reg         first_image_committed;
  // ============================================================================
  // [Design note exp-io 可设定轮播周期]
  //   原来：auto_mode 6 档循环（KEY4 / 键盘 D 切档），周期 3/5/10/20/30 秒。
  //   现在：周期档由扩展板 4 位拨码 exp_sw[3:0] 选择，共 16 档 2..600 秒
  //         （见 rtl/carousel_period_cfg.v）；本模块只接收已生效的
  //         auto_period_sec / period_code，不再自己切档。
  //   计时方式不变：auto_tick = 1 秒的 tick，sec_cnt 数秒；sec_cnt 从 6 位
  //   加宽到 10 位（600 < 1024），并在 auto_period_sec 处饱和 ⇒ 不会回绕。
  // ============================================================================
  reg         auto_on;  // 轮播开关（KEY4 短按 / period_reseed）
  wire [ 3:0] auto_mode;  // 显示用（组合）：关=0，否则 = 档位码 0..F
  reg  [ 9:0] sec_cnt;  // 已计时秒数，饱和在 auto_period_sec
  reg  [31:0] auto_cnt;
  reg  [ 2:0] img_found_count;
  reg  [ 1:0] img_idx;  // 当前真正显示中的图片编号
  // [Design note 轮播计时起点]load_busy 下降沿 = 一次图片加载结束（新图该上屏了）。
  //   用它做轮播计时起点，覆盖所有切换路径（读卡加载 / 命中缓存 / 首图），
  //   比 fade_done_pulse 可靠：命中缓存时不产生转场，fade_done 不会来 
  reg         load_busy;
  reg         load_busy_q;
  always @(posedge clk or posedge rst) begin
    if (rst) load_busy_q <= 1'b0;
    else load_busy_q <= load_busy;
  end
  wire load_finish = load_busy_q & ~load_busy;

  // ============================================================================
  // [Design note 轮播预取]（PREFETCH_EN=0 时全部逻辑综合后消失，行为与原来逐位相同）
  //
  //   问题：现在"到点才开始读卡" => 间隔 = 周期 + 加载时间（大图多出 13 秒）
  //   预取：显示图 N 期间，后台把图 N+1 读进另一块 buffer；到点直接翻转显示
  //        => 间隔 = max(周期, 加载时间)
  //
  //   规则来自 carousel_model.v 的 8 轮仿真（见 docs/预取设计方案_20261022.md）：
  //     1) next_target 在与翻转同一拍预计算，预取启动时直接用（不能用 disp_idx）
  //     2) 预取用三态子状态机：IDLE 可启动 / BUSY 加载中 / DONE 有图可切
  //     3) 到点时：DONE => 翻转；BUSY => 等它；IDLE => 走老路径
  //     4) 预取装载不能改变 disp_buf_idx / img_idx（那是"后台"）
  // ============================================================================
  localparam PREFETCH_EN = 1'b1;  // 2026-10-23 on: pf_mode removed, state derived from pf_state
  //   The old pf_mode register could stick at 1 after an aborted prefetch, which made every
  //   later commit take the prefetch branch (no display change) => carousel froze on image 2.
  //   Now "is this load a prefetch" == (pf_state == PF_BUSY), so there is no stale flag.
  localparam [1:0] PF_IDLE = 2'd0, PF_BUSY = 2'd1, PF_DONE = 2'd2;

  reg [1:0] pf_state;
  reg [1:0] pf_idx;  // 预取好的图片编号
  reg [1:0] pf_buf;  // 预取好的 buffer 编号
  reg [1:0] next_target;  // 下一张要显示的图片编号（预计算）
  reg pf_flip_pend;  // 1 = 到点了，等 fade_done 再翻转显示
  reg [1:0] load_idx;  // 当前正在写入的图片编号
  reg [1:0] pending_buf_idx;  // 当前正在写入的目标缓冲区
  reg [31:0] img_sector0;
  reg [31:0] img_sector1;
  reg [31:0] img_sector2;
  reg [31:0] img_sector3;
  reg next_req_pending;
  // [Design note 现象2 超时恢复]加载看门狗计数（声明必须在下面所有 always 之前）
  reg [31:0] load_wait_cnt;

  // bmp_ready 先表示"源文件读取/送 FIFO 完成"；真正切显示要等 write_finish_toggle 同步后
  reg source_done_seen;

  // 【转场 FIX 2026-10-07】"已经请求 video 域淡出、正在等 fade_done"标志。
  //   置 1 之后不再重复发 fade_req（write_finish_pulse 只来一次，这里是双保险）；
  //   提交完成 / 看门狗超时 / 开新一轮装载时都清零。
  reg fade_req_sent;

  // ================= 【根因 FIX 2026-10-07】顺序无关的就绪判据 + 超时超时恢复 =================
  // 真机实测时序（这就是上一版"首图不出图"的根因）：
  //   BMP 最后一个扇区里，file_len 之后还有约 458 个"无效但仍在 SPI 上传输"的字节
  //   （≈70~150us）；bmp_read 必须等这个扇区的 sd_sec_read_end 才回 ST_IDLE
  //   （bmp_ready 才变 1）。而 SDRAM 写侧早就把整帧写完了 —— 于是
  //   `write_finish_pulse` 到达时 bmp_ready 还是 0，而且之后不会再有第二个脉冲。
  //   旧代码之所以能出图：它在 load_start 后 1 拍就把 source_done_seen 置起来
  //   （等价于"常备"），所以在那个唯一脉冲上照样提交。收紧成"必须同拍 bmp_ready"
  //   之后就正好错过它 -> 首图永不提交 -> 整场黑屏。
  // 修法：把"整帧已写完"和"源图已读完"分别记住，两者都成立就提交 ——
  //   与到达顺序无关，也不会因为某个事件早来/晚来而丢。
  reg wrfin_seen;  // (1) 本帧 write_finish_pulse 已经见过
  // 【首图必出图 超时恢复】共享的"慢速时基"：4096 分频 + 17 位计数（满量程 ≈5.37s）。
  //   面积吃紧（本设计已在 95%~96% mslices），所以两处超时超时恢复共用一个时基，
  //   省掉两个 32 位计数器 —— 上一版就是被那两个计数器顶到 place 96.28%，
  //   导致 route-eco 出 PHY-8023/RUN-8102 布线违例（被 phy 的 bit 时间戳闸门拦下）。
  reg [11:0] to_presc;  // 4096 分频
  reg [16:0] to_cnt;  // 单位 = 4096 拍
  reg first_load_started;  // 首图装载已经发起过（超时恢复窗口的起点）
  // 【根因诊断位 2026-10-07 #2】真机出现 DIG3='F' 说明"正常提交路径"没在窗口内成立。
  //   这里在超时恢复触发那一拍把 4 个关键状态锁存下来，直接显示到 DIG3 的一个十六进制位上：
  //     bit3 = wrfin_seen（整帧已写完）      bit2 = source_done_seen（源图已读完）
  //     bit1 = bmp_ready（bmp_read 是否已回 IDLE） bit0 = pixel_wr_seen（是否真写过像素）
  //   于是下一次上板只要看 DIG3 就能判定：是"帧没写完"、还是"源没读完"、还是"卡在加载中"。
  reg [3:0] fb_diag;
  reg firstimg_fallback_seen;  // 走过首图超时恢复（引到 DIG3）

  // 4.0s 门槛（97656 x 4096 / 100MHz ≈ 4.000s，见参数表 TO_TICKS）：
  //   远大于一次正常 BMP 加载（1801 扇区 x 25MHz SPI ≈ 164us/扇区 ≈ 0.30s，
  //   SPI_HIGH_SPEED_DIV=0 -> 25MHz，见 SD/sd_card_top.v:25），
  //   也留足"卡住重试"的余量；它只是最后一道保险，正常路径永远不该碰到。
  wire to_tick = (to_presc == 12'd4095);
  reg to_hit;  // Exact terminal predicate, updated with each count/reset.
  reg load_wait_hit;
  // 两处超时恢复的条件互斥（首图阶段 fade_req_sent=0；切图阶段 first_image_committed=1），
  // 所以可以安全共用一个计数窗口。
  //   首图窗口 = "首图装载发起过 且 还没有任何图提交"（跨看门狗重试累计，不看 load_busy 电平）
  wire to_active = (first_load_started && !first_image_committed) ||
      ((load_busy || pf_flip_pend) && fade_req_sent);
  wire firstimg_to = to_active && to_hit && !first_image_committed;  // 首图超时超时恢复
  wire fade_wait_to = to_active && to_hit && fade_req_sent;  // 转场握手超时

  // Publish only after both independently latched completion events arrive.
  // The timeout below is diagnostic; it cannot certify a valid SDRAM frame.
  wire img_frame_ready = wrfin_seen;
  wire img_src_ready = source_done_seen;
  wire firstimg_ready = img_frame_ready && img_src_ready;
  wire commit_now = load_busy &&
      ((firstimg_ready && (!first_image_committed || (PREFETCH_EN && pf_state == PF_BUSY))) ||
       (firstimg_ready && first_image_committed && fade_req_sent &&
        (fade_done_pulse || fade_wait_to)));

  // [Design note 任务1]"本次加载确实见过像素写入"粘滞标志。
  //   为什么需要它：bmp_read 受理 load_start 要晚 1 拍，那一拍它还在 ST_IDLE
  //   （bmp_ready=1），于是旧代码的 `load_busy && bmp_ready` 在 load_start 之后
  //   第一拍就成立 -> source_done_seen 被误置（TB 已实测）。
  //   真机上提交还要等真正的 write_finish_toggle，所以目前无害，但"源图是否读完"
  //   这个判据是失真的（上一版看门狗最初就是被它搞失效的）。
  //   为什么不能直接把 bmp_data_wr_en 加进条件：source_done_seen 应该在
  //   "bmp_read 送完源图、回到 IDLE（bmp_ready 重新为 1）"那一拍置起，而那一拍
  //   bmp_data_wr_en 已经是 0（退出 ST_LOAD_DATA 的那拍 bmp_len_cnt 已 >= file_len
  //   -> bmp_data_valid=0 -> wr_en 拉低）。直接用 bmp_data_wr_en 会让
  //   source_done_seen 永远置不起来 -> 首图永远不提交 -> 整场黑屏。
  //   所以用粘滞标志"本次加载期间见过像素写入"，再与 bmp_ready 相与：
  //   既排除 load_start 之后那一拍，又保留原来的提交时机。
  //   每个"开始一次新加载"的分支里都会把它清 0。
  reg pixel_wr_seen;

  // 同步 mem_clk 域的 write_finish_toggle
  reg [2:0] wrfin_tgl_sync;
  wire write_finish_pulse;

  wire auto_tick;
  wire [1:0] next_from_current;

  // ================================================================
  // 2026-10-14 图片缩放集成
  //   bmp_read 输出的原始像素流（bmp_data_wr_en / bmp_data）先经过
  //   img_scaler，把任意尺寸缩放到恰好 640x480，再交给写侧。
  //
  //   为什么要放在这里而不是改 bmp_read：
  //     · 写侧、SDRAM 布局、VFLIP 寻址、读侧、显示时序全部不用动
  //     · 640x480 及更小的图走 scaler 的 bypass 直通 ⇒ 行为逐位不变
  //     · 只有"大于 640x480"的图才会被真正缩放
  //
  //   scaler 输出的像素数恰好 FRAME_PIXELS(307200)，所以写侧看到的
  //   帧与现在完全同构。img_h_o 也改为上报 480（= scaler 的输出高度），
  //   使 frame_fifo_write 的 VFLIP 起始行与补黑逻辑按满帧处理。
  // ================================================================
  // Fit the original aspect ratio directly into the HDMI raster. The BMP
  // fast-row path still supplies its 480 selected rows; aspect_h preserves
  // the file's original height so that row skipping cannot stretch images.
  wire [15:0] img_src_w, img_h_raw, img_aspect_h;
  wire fit_high, fit_overflow;
  wire [23:0] fit_pixel;
  wire fit_valid;
  reg reader_high_q;
  always @(posedge clk or posedge rst) begin
    if (rst) reader_high_q <= 1;
    else reader_high_q <= fit_high;
  end
  image_fit_720p u_image_fit (
    .clk(clk), .rst(rst), .frame_start(load_start_pulse || vid_lock),
    .src_w(img_src_w), .src_h(img_h_raw), .aspect_h(img_aspect_h),
    .in_valid(bmp_data_wr_en), .in_pixel(bmp_data),
    .high(fit_high), .overflow(fit_overflow),
    .out_blocked(write_almost_full), .out_valid(fit_valid), .out_pixel(fit_pixel)
  );
  // File identity is independent of pixel scaling. Keep the directory-selected
  // first sector connected to the shared FAT mapper for every image request.
  // load_sector stays stable until this load completes or is drained/aborted.
  assign file_base_lba = load_sector;
  assign img_h_o = 16'd720;
  assign write_en = fit_valid;
  assign write_data = {fit_pixel,8'd0};
  assign scan_done  = DIRECTORY_IMAGES ? scan_kicked : bmp_scan_done;
  assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));

  // ---- 【轮播周期】周期秒数由 carousel_period_cfg 给出；auto_step = 到点换图 ----
  wire auto_run = auto_on;
  assign auto_mode = auto_on ? period_code : 4'd0;  // DIG1 显示：0=关，1..F=档位
  // Thresholds change only on second ticks or configuration boundaries.
  // Clear these flags with every timer reset so a completed event cannot
  // retrigger on stale comparison data. Trigger may move one 100MHz clock.
  reg auto_due_q, auto_half_due_q;
  wire auto_step = auto_run && auto_due_q && !load_busy &&
      !switch_lock;  // 到点且当前空闲才换图

  assign next_from_current   = next_index_limited(img_idx, img_found_count);
  assign write_finish_pulse  = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
  assign img_loading         = load_busy || !bmp_ready;
  assign auto_mode_o         = auto_mode;
  // [Design note]周期配置的安全生效边界（见端口注释）
  //   1) 轮播关着 -> 连续跟随拨码（没有正在进行的计时，随便改）
  //   2) 一次图片装载结束 -> 换档
  //   这里故意不把 period_reseed 并进来：并进来只多一个 OR 门，但会整体改掉
  //   综合/布局映射。实测同功能下 WNS 从 +58 ps 变成 -297 ps（34 个违例端点），
  //   而利用率反而更低（94.19% vs 95.74%）—— 这个设计已经贴着布局极限，一个门就能翻盘。
  //   所以宁可保留"已验证通过"的网表形态；要"按 D 立刻生效"时先按一次 KEY4 关轮播即可
  //   （关闭时边界恒 1，拨码立刻跟随）。
  assign cfg_boundary_o      = (!auto_on) || load_finish;
  assign auto_on_o           = auto_on;
  // [Design note]把"已缓存图片数"和"扫描完成"引给顶层，用于决定 phase B 是否发起
  assign found_count_o       = img_found_count;
  assign scan_done_o         = scan_done;
  // 【首图必出图 超时恢复 2026-10-07】触发过超时恢复提交就保持 1（上板 DIG3 显示 'F'）
  assign firstimg_fallback_o = firstimg_fallback_seen;

  key_press_debounce #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .DEBOUNCE_MS(20)
  ) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
  );

  key_press_debounce #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .DEBOUNCE_MS(20)
  ) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
  );

  function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
      case (count)
        3'd0: next_index_limited = 2'd0;
        3'd1: next_index_limited = 2'd0;
        3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
        3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
        default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
      endcase
    end
  endfunction

  function [31:0] sector_lut;
    input [1:0] idx;
    begin
      case (idx)
        2'd0: sector_lut = img_sector0;
        2'd1: sector_lut = img_sector1;
        2'd2: sector_lut = img_sector2;
        2'd3: sector_lut = img_sector3;
        default: sector_lut = img_sector0;
      endcase
    end
  endfunction

  function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input valid_now;
    begin
      if (!valid_now) next_buf_lut = 2'd0;  // 首图固定写 buffer0
      else if (cur_disp_buf == 2'd0) next_buf_lut = 2'd1;
      else next_buf_lut = 2'd0;
    end
  endfunction

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      wrfin_tgl_sync         <= 3'b000;
      scan_start_pulse       <= 1'b0;
      load_start_pulse       <= 1'b0;
      load_sector            <= 32'd0;
      scan_kicked            <= 1'b0;
      first_image_committed  <= 1'b0;
      auto_on                <= 1'b0;
      sec_cnt                <= 10'd0;
      auto_due_q             <= 0;
      auto_half_due_q        <= 0;
      auto_cnt               <= 32'd0;
      // [Design note 预取]新寄存器复位（PREFETCH_EN=0 时会被综合掉，无害）
      pf_state               <= PF_IDLE;
      pf_idx                 <= 2'd0;
      pf_buf                 <= 2'd0;
      next_target            <= 2'd1;  // 首图是 0，下一张从 1 开始
      pf_flip_pend           <= 1'b0;
      img_found_count        <= 3'd0;
      img_idx                <= 2'd0;
      load_idx               <= 2'd0;
      pending_buf_idx        <= 2'd0;
      write_buf_idx          <= 2'd0;
      disp_buf_idx           <= 2'd0;
      img_sector0            <= 32'd0;
      img_sector1            <= 32'd0;
      img_sector2            <= 32'd0;
      img_sector3            <= 32'd0;
      next_req_pending       <= 1'b0;
      load_busy              <= 1'b0;
      pixel_wr_seen          <= 1'b0;
      fade_req_sent          <= 1'b0;
      fade_req_toggle        <= 1'b0;  // 必须复位：video 域靠它的"边沿"识别请求
      wrfin_seen             <= 1'b0;
      to_presc               <= 12'd0;
      to_cnt                 <= 17'd0;
      to_hit                 <= (TO_TICKS == 0);
      first_load_started     <= 1'b0;
      fb_diag                <= 4'd0;
      firstimg_fallback_seen <= 1'b0;
      source_done_seen       <= 1'b0;
      display_valid          <= 1'b0;
      load_wait_cnt          <= 32'd0;
      load_wait_hit          <= (LOAD_WAIT_MAX == 0);
    end else begin
      auto_due_q <= sec_cnt >= auto_period_sec;
      auto_half_due_q <= sec_cnt >= (auto_period_sec >> 1);
      wrfin_tgl_sync <= {wrfin_tgl_sync[1:0], write_finish_toggle};
      scan_start_pulse <= 1'b0;
      load_start_pulse <= 1'b0;

      if (!sd_init_done) begin
        scan_kicked            <= 1'b0;
        first_image_committed  <= 1'b0;
        auto_on                <= 1'b0;
        sec_cnt                <= 10'd0;
        auto_due_q             <= 0;
        auto_half_due_q        <= 0;
        auto_cnt               <= 32'd0;
        img_found_count        <= 3'd0;
        img_idx                <= 2'd0;
        load_idx               <= 2'd0;
        pending_buf_idx        <= 2'd0;
        write_buf_idx          <= 2'd0;
        disp_buf_idx           <= 2'd0;
        img_sector0            <= 32'd0;
        img_sector1            <= 32'd0;
        img_sector2            <= 32'd0;
        img_sector3            <= 32'd0;
        next_req_pending       <= 1'b0;
        load_busy              <= 1'b0;
        pixel_wr_seen          <= 1'b0;
        fade_req_sent          <= 1'b0;
        fade_req_toggle        <= 1'b0;
        wrfin_seen             <= 1'b0;
        to_presc               <= 12'd0;
        to_cnt                 <= 17'd0;
        to_hit                 <= (TO_TICKS == 0);
        first_load_started     <= 1'b0;
        fb_diag                <= 4'd0;
        firstimg_fallback_seen <= 1'b0;
        source_done_seen       <= 1'b0;
        display_valid          <= 1'b0;
        load_wait_cnt          <= 32'd0;
        load_wait_hit          <= (LOAD_WAIT_MAX == 0);
      end else begin
        // [Design note 现象2 超时恢复]首图加载看门狗（必须放在下面
        //   "首图自动加载"的 if 链之前，这样同一拍里如果看门狗清了
        //   load_busy、而加载条件也成立，后面的赋值（load_busy<=1）优先）。
        //   计数条件 = 正在加载，但 bmp_read 一直闲在 IDLE（说明那条 1 拍
        //   load_start 根本没被受理）、且没有任何像素在写 —— 也就是"这次
        //   加载毫无进展"。
        //   ⚠ 这里不能用 source_done_seen 当"源图还没读完"的判据：
        //   bmp_read 受理 load_start 要晚 1 拍，那一拍 bmp_ready 还是 1，
        //   上面第 251 行的 `if (load_busy && bmp_ready) source_done_seen<=1`
        //   会被这一拍误置成 1（bmp 侧既存小瑕疵，真机因为还要等真正的
        //   write_finish_toggle 所以无害）。用 TB 实测：加上 !source_done_seen
        //   这一项，超时恢复就永远不会触发（OLD_TOP 模式下 load_busy 依旧卡死）。
        //   去掉它以后：真机正常流程里这段"bmp_read 空闲 + 无像素"最长就是
        //   "等整帧写进 SDRAM"（几 ms ~ 几十 ms，SDRAM 远快于 25MHz SPI），
        //   离 LOAD_WAIT_MAX=2s 有 40 倍以上余量，所以不会打断正常加载。
        //   一旦超时就撤销 load_busy，下面"首图自动加载"的条件重新成立，
        //   于是自动重发一次 load_start（每 LOAD_WAIT_MAX 重试一次）。
        //   真机正常加载时这个条件不成立（bmp_read 在 ST_LOAD_* 里
        //   bmp_ready=0），所以看门狗绝不会打断一次正常的加载。
        // Retry only a load that never produced a pixel. A completed
        // source awaiting SDRAM must not reuse the buffer or a stale finish.
        if (load_busy && bmp_ready && !bmp_data_wr_en && !pixel_wr_seen) begin
          if (load_wait_hit) begin
            load_busy     <= 1'b0;
            load_wait_cnt <= 32'd0;
            load_wait_hit <= (LOAD_WAIT_MAX == 0);
            // 【转场 FIX 2026-10-07】超时说明这一轮已经废了：把转场握手
            //   标志一起清掉，否则 fade_req_sent 永远为 1，之后每一次切图
            //   都会被"等 fade_done"卡住（活锁）。
            fade_req_sent <= 1'b0;
          end else begin
            load_wait_cnt <= load_wait_cnt + 32'd1;
            load_wait_hit <= load_wait_cnt == (LOAD_WAIT_MAX - 32'd1);
          end
        end else begin
          load_wait_cnt <= 32'd0;
          load_wait_hit <= (LOAD_WAIT_MAX == 0);
        end

        // 扫描阶段缓存前 4 张图的起始 sector
        if (scan_found_valid) begin
          case (img_found_count)
            3'd0: img_sector0 <= scan_found_sector;
            3'd1: img_sector1 <= scan_found_sector;
            3'd2: img_sector2 <= scan_found_sector;
            3'd3: img_sector3 <= scan_found_sector;
            default: ;
          endcase

          if (img_found_count < 3'd4) img_found_count <= img_found_count + 3'd1;
        end

        // Store the source and memory events independently; either
        // arrival order is valid, but both are required before publishing.
        if (load_busy && write_finish_pulse)
          wrfin_seen <= 1'b1;  // (1) 整帧已写进 SDRAM（事件锁存）
        if (bmp_data_wr_en) pixel_wr_seen <= 1'b1;  //   本帧确实在写像素
        if (load_busy && bmp_ready && pixel_wr_seen && !image_load_error)
          source_done_seen <= 1'b1;  // (2) 源图已读完（bmp_read 回 IDLE）

        // ---- 共享超时超时恢复时基（首图超时恢复 / 转场握手超时恢复 共用）----
        //   1024 分频后再计数：每 1024 拍 to_cnt+1，到 TO_TICKS(≈1.0s) 置 to_hit。
        //   计数窗口 = to_active（见上面定义），窗口一关就整体清零。
        if (to_active) begin
          if (to_tick) begin
            to_presc <= 12'd0;
            if (!to_hit) begin
              to_cnt <= to_cnt + 17'd1;
              to_hit <= to_cnt == (TO_TICKS - 17'd1);
            end
          end else begin
            to_presc <= to_presc + 12'd1;
          end
        end else begin
          to_presc <= 12'd0;
          to_cnt   <= 17'd0;
          to_hit   <= (TO_TICKS == 0);
        end

        // 超时恢复标记 + 诊断锁存（正常路径恒 0；上板 DIG3 直接显示 fb_diag 的十六进制位）
        if (load_busy && firstimg_to && !first_image_committed && !firstimg_ready) begin
          firstimg_fallback_seen <= 1'b1;
          fb_diag <= {wrfin_seen, source_done_seen, bmp_ready, pixel_wr_seen};
        end

        // Request fade only after source completion AND SDRAM completion.
        if (load_busy && firstimg_ready && first_image_committed && !fade_req_sent &&
            !(PREFETCH_EN && pf_state == PF_BUSY)) begin
          fade_req_sent   <= 1'b1;
          fade_req_toggle <= ~fade_req_toggle;
        end

        // ===================== [Design note 预取]到点翻转显示 =====================
        //   预取就绪后，到点不装载、只翻转 disp_buf_idx。
        //   这里复用同一条 fade 握手：先发 fade_req_toggle，等 fade_done_pulse 再翻。
        if (PREFETCH_EN) begin
          // ====================================================================
          // [Design note 修复"自动切图卡在第二张"]
          //
          //   上板实测：预取版开轮播，切到第二张后就不动了。
          //
          //   根因：预取装载如果被看门狗/转场/视频打断，load_busy 会自己落下，
          //         但没有经过 commit 点 => pf_mode 停在 1 
          //         之后每一次正常装载的 commit 都会走"预取分支"
          //         （只记 pf_* 不改 disp_buf_idx）=> 显示永远不换 
          //         而且原来的恢复条件写着 `!pf_mode`，自相矛盾，永远不成立 
          //
          //   修法：只要"pf_state 是 BUSY 而 load_busy 已经落下"，
          //         就无条件把两个状态都清干净 —— 这次装载作废，下一拍重来。
          //         装载被打断最多损失一次预取（几十毫秒），不会卡死 
          // ====================================================================
          if ((pf_state == PF_BUSY) && !load_busy) begin
            pf_state <= PF_IDLE;
          end
          // A manual next consumes the prepared next image, even if auto
          // has just been disabled. Never schedule a second load of it.
          if (pf_state == PF_DONE && next_req_pending && !pf_flip_pend && !switch_lock &&
              !vid_lock) begin
            pf_flip_pend <= 1;
            next_req_pending <= 0;
          end
          if (pf_flip_pend && !fade_req_sent) begin
            fade_req_sent   <= 1'b1;
            fade_req_toggle <= ~fade_req_toggle;
          end
          if (pf_flip_pend && (fade_done_pulse || fade_wait_to)) begin
            disp_buf_idx     <= pf_buf;
            img_idx          <= pf_idx;
            next_target      <= next_index_limited(pf_idx, img_found_count);
            pf_state         <= PF_IDLE;
            pf_flip_pend     <= 1'b0;
            next_req_pending <= 0;
            fade_req_sent    <= 1'b0;
            display_valid    <= 1'b1;
          end
        end

        // 提交点（唯一一处改 disp_buf_idx）
        if (commit_now) begin
          load_busy        <= 1'b0;
          source_done_seen <= 1'b0;
          pixel_wr_seen    <= 1'b0;
          wrfin_seen       <= 1'b0;
          fade_req_sent    <= 1'b0;
          to_presc         <= 12'd0;
          to_cnt           <= 17'd0;
          to_hit           <= (TO_TICKS == 0);
          // ---- [Design note 预取]预取装载不提交显示，只记下"已备好" ----
          // [Design note]"这次装载是预取吗" = pf_state==PF_BUSY。
          //   不再用独立的 pf_mode 寄存器（它会残留成"永远停第二张"）。
          if (PREFETCH_EN && (pf_state == PF_BUSY)) begin
            pf_state <= PF_DONE;
            pf_idx   <= load_idx;
            pf_buf   <= pending_buf_idx;
            // disp_buf_idx / img_idx 保持不变 —— 这是"后台"装载
          end else begin
            disp_buf_idx <= pending_buf_idx;
            img_idx      <= load_idx;
            next_target  <= next_index_limited(load_idx, img_found_count);
          end
          display_valid         <= 1'b1;
          first_image_committed <= 1'b1;
        end

        // 上电后自动发起一次"扫描前 4 张 BMP"
        if (!scan_kicked && bmp_ready) begin
          scan_start_pulse      <= !DIRECTORY_IMAGES;
          scan_kicked           <= 1'b1;
          first_image_committed <= 1'b0;
          auto_on               <= 1'b0;
          sec_cnt               <= 10'd0;
          auto_due_q            <= 0;
          auto_half_due_q       <= 0;
          auto_cnt              <= 32'd0;
          img_found_count       <= DIRECTORY_IMAGES ? directory_count : 3'd0;
          if (DIRECTORY_IMAGES) begin
            img_sector0 <= directory0;
            img_sector1 <= directory1;
            img_sector2 <= directory2;
            img_sector3 <= directory3;
          end
          img_idx          <= 2'd0;
          load_idx         <= 2'd0;
          pending_buf_idx  <= 2'd0;
          write_buf_idx    <= 2'd0;
          disp_buf_idx     <= 2'd0;
          next_req_pending <= 1'b0;
          display_valid    <= 1'b0;
          load_busy        <= 1'b0;
          pixel_wr_seen    <= 1'b0;
          wrfin_seen       <= 1'b0;
          to_presc         <= 12'd0;
          to_cnt           <= 17'd0;
          to_hit           <= (TO_TICKS == 0);
          fade_req_sent    <= 1'b0;
          source_done_seen <= 1'b0;
        end else begin
          // 忙的时候也只记 1 次"下一张"请求，不会累积成连跳两张
          if (key_next_press && (img_found_count > 3'd0)) next_req_pending <= 1'b1;
          if (auto_step && !image_load_error && first_image_committed &&
              (img_found_count > 3'd1)) begin
            // [Design note 预取]到点时：已备好 => 只翻转显示；否则走老路径（装载后切换）
            if (PREFETCH_EN && (pf_state == PF_DONE) && !pf_flip_pend) begin
              pf_flip_pend <= 1'b1;
            end else if (!(PREFETCH_EN && ((pf_state != PF_IDLE) || pf_flip_pend))) begin
              next_req_pending <= 1'b1;
            end
            // [Design note 注意]sec_cnt 的清零必须在下面的计数器块里做：
            //   本 always 块后写优先，写在这里会被计数器覆盖 => sec_cnt 卡在饱和值
            //   => auto_step 恒为 1 => 发出一次请求后就一直 pending => "切一张就停" 
          end

          // [Design note]KEY4 短按 = 轮播 开/关（不再兼周期，避免与长按切歌混淆）
          if (key_auto_press && scan_done && (img_found_count > 3'd1)) begin
            auto_on <= ~auto_on;
            sec_cnt <= 10'd0;
            auto_due_q <= 0;
            auto_half_due_q <= 0;
            auto_cnt <= 32'd0;
          end
          // [Design note]键盘 D 单击 = 打开轮播并从这一张重新计时
          //   （周期档位已经交给扩展板拨码 exp_sw[3:0] 选择，这里不再切档）
          if (period_reseed && scan_done && (img_found_count > 3'd1)) begin
            auto_on <= 1'b1;
            sec_cnt <= 10'd0;
            auto_due_q <= 0;
            auto_half_due_q <= 0;
            auto_cnt <= 32'd0;
          end
          // [Design note 修]秒计数不再受 load_busy/switch_lock 门控。
          //   原来加载期间计时器被清零 => 实际间隔 = 周期 + 加载耗时（大图多出 13 秒）。
          //   现在：只要轮播开着就一直走，饱和在 auto_period_sec；到点后等空闲再换图。
          if (auto_run && first_image_committed && (img_found_count > 3'd1)) begin
            if ((load_finish && pf_state != PF_DONE) ||
                (pf_flip_pend && (fade_done_pulse || fade_wait_to))) begin
              // [Design note 计时起点修正]一次加载结束（load_busy 下降沿）= 新图该上屏了，从这里计时。
              //   原来从"发出切换请求"就开始计时，加载期间计时器跑到饱和值，
              //   大图（14MB≈13秒）一加载完就立刻又被切走 => 实际显示 0 秒 
              sec_cnt <= 10'd0;
              auto_due_q <= 0;
              auto_half_due_q <= 0;
              auto_cnt <= 32'd0;
            end else if (auto_step) begin
              // 换图请求已发出 => 清零（否则 auto_step 会一直为 1）
              sec_cnt <= 10'd0;
              auto_due_q <= 0;
              auto_half_due_q <= 0;
              auto_cnt <= 32'd0;
            end else if (auto_tick) begin
              auto_cnt <= 32'd0;
              if ((sec_cnt + 10'd1) >= auto_period_sec)
                sec_cnt <= auto_period_sec;  // 饱和：到点后停在这里等空闲
              else sec_cnt <= sec_cnt + 10'd1;
            end else begin
              auto_cnt <= auto_cnt + 32'd1;
            end
          end else begin
            auto_cnt <= 32'd0;
            sec_cnt <= 10'd0;
            auto_due_q <= 0;
            auto_half_due_q <= 0;
          end

          // 首图自动加载到 buffer0（不受 switch_lock 影响：开机必须能出首图）
          if (!vid_lock && !scan_start2 && scan_done && !first_image_committed && bmp_ready &&
              !load_busy && (img_found_count != 3'd0) &&
              (!image_load_error || next_req_pending)) begin
            load_idx           <= image_load_error ? next_from_current : 2'd0;
            load_sector        <= image_load_error ? sector_lut(next_from_current) : img_sector0;
            pending_buf_idx    <= 2'd0;
            write_buf_idx      <= 2'd0;
            load_start_pulse   <= 1'b1;
            load_busy          <= 1'b1;
            pixel_wr_seen      <= 1'b0;
            wrfin_seen         <= 1'b0;
            to_presc           <= 12'd0;
            to_cnt             <= 17'd0;
            to_hit             <= (TO_TICKS == 0);
            first_load_started <= 1'b1;  // 超时恢复窗口起点（首图）
            fade_req_sent      <= 1'b0;
            source_done_seen   <= 1'b0;
            next_req_pending   <= 1'b0;
            auto_cnt           <= 32'd0;
            pf_state           <= PF_IDLE;  // 正常装载：显式回到 IDLE
          end  // 手动下一张优先：写到"非当前显示"的另一块 buffer
               // 【转场 FIX 2026-10-07】加 !switch_lock：转场（约 538ms）期间不发起新的
               //   切图装载。按键请求已经被上面 next_req_pending 记下（只记 1 次），
               //   转场结束后自动执行 —— 既不丢键，也不会连跳两张/把转场打断。
               // [Design note 视频]再加 !vid_lock：视频播放期间不开新的切图装载
               //   （视频每帧都要用写通路和 SDRAM 带宽，抢会两边都卡）。
          else if (!(PREFETCH_EN && (pf_state != PF_IDLE)) && !scan_start2 && scan_done &&
                   bmp_ready && display_valid && !load_busy && !switch_lock && !vid_lock &&
                   next_req_pending && (img_found_count != 3'd0)) begin
            load_idx           <= next_from_current;
            load_sector        <= sector_lut(next_from_current);
            pending_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
            write_buf_idx      <= next_buf_lut(disp_buf_idx, display_valid);
            load_start_pulse   <= 1'b1;
            load_busy          <= 1'b1;
            pixel_wr_seen      <= 1'b0;
            wrfin_seen         <= 1'b0;
            to_presc           <= 12'd0;
            to_cnt             <= 17'd0;
            to_hit             <= (TO_TICKS == 0);
            first_load_started <= 1'b0;  // 切图不改首图窗口
            pf_state           <= PF_IDLE;  // 正常装载：显式回到 IDLE
                                            //   即使上一次预取被中断，也不会残留"预取中"状态
            fade_req_sent      <= 1'b0;
            source_done_seen   <= 1'b0;
            next_req_pending   <= 1'b0;
            auto_cnt           <= 32'd0;
          end  // ===================== [Design note 预取装载]=====================
               //   轮播开着、当前空闲、还没有预取好的图 => 后台把"下一张"读进另一块 buffer。
               //   与下面两条装载路径的区别：pf_mode=1，提交时不改 disp_buf_idx（后台装载）。
               // [Design note FIX-A 音频饿死]预取只在"周期过半"之后才启动。
               //   原来是一有空就预取 => 图片流几乎连续占用 SD 总线 => 音频饿死
               //   （上板症状：进度条不动、没声音、长按 KEY3 是杂音）。
               //   改成周期前半段完全不碰卡 => 音频有充足的带宽窗口 
          else if (PREFETCH_EN && auto_run && !image_load_error && (pf_state == PF_IDLE) &&
                   !pf_flip_pend && auto_half_due_q && !scan_start2 && scan_done && bmp_ready &&
                   display_valid && !load_busy && !switch_lock && !vid_lock &&
                   (img_found_count > 3'd1)) begin
            load_idx           <= next_target;
            load_sector        <= sector_lut(next_target);
            pending_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
            write_buf_idx      <= next_buf_lut(disp_buf_idx, display_valid);
            load_start_pulse   <= 1'b1;
            load_busy          <= 1'b1;
            pixel_wr_seen      <= 1'b0;
            wrfin_seen         <= 1'b0;
            to_presc           <= 12'd0;
            to_cnt             <= 17'd0;
            to_hit             <= (TO_TICKS == 0);
            first_load_started <= 1'b0;
            fade_req_sent      <= 1'b0;
            source_done_seen   <= 1'b0;
            pf_state           <= PF_BUSY;
          end  // 自动播放下一张：同样写到"非当前显示"的另一块 buffer
               // [Design note FIX-B 同一张显示两次]预取已经备好/正在备好时会由
               //   "到点翻转"负责换图；如果这条老路径同时也在跑，就会把同一张
               //   再装一遍 => 看起来"同一张显示两次"。所以预取非 IDLE 时屏蔽它。
          else if (!(PREFETCH_EN && (pf_state != PF_IDLE)) && !scan_start2 && scan_done &&
                   bmp_ready && display_valid && !load_busy && !switch_lock && !vid_lock &&
                   auto_step && !image_load_error && (img_found_count > 3'd1)) begin
            load_idx           <= next_from_current;
            load_sector        <= sector_lut(next_from_current);
            pending_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
            write_buf_idx      <= next_buf_lut(disp_buf_idx, display_valid);
            load_start_pulse   <= 1'b1;
            load_busy          <= 1'b1;
            pixel_wr_seen      <= 1'b0;
            wrfin_seen         <= 1'b0;
            to_presc           <= 12'd0;
            to_cnt             <= 17'd0;
            to_hit             <= (TO_TICKS == 0);
            first_load_started <= 1'b0;
            fade_req_sent      <= 1'b0;
            source_done_seen   <= 1'b0;
            auto_cnt           <= 32'd0;
          end
        end
        if (load_busy && bmp_ready && image_load_error) begin
          load_busy <= 0;
          pf_state <= PF_IDLE;
          pf_flip_pend <= 0;
          next_req_pending <= 0;
          pixel_wr_seen <= 0;
          source_done_seen <= 0;
          wrfin_seen <= 0;
          fade_req_sent <= 0;
          first_load_started <= 0;
        end
        if (vid_lock) begin
          load_busy <= 0;
          load_start_pulse <= 0;
          pf_state <= PF_IDLE;
          pf_flip_pend <= 0;
          next_req_pending <= 0;
          pixel_wr_seen <= 0;
          source_done_seen <= 0;
          wrfin_seen <= 0;
          fade_req_sent <= 0;
          first_load_started <= 0;
          first_image_committed <= 0;
          display_valid <= 0;
          sec_cnt <= 10'd0;
          auto_due_q <= 0;
          auto_half_due_q <= 0;
          auto_cnt <= 0;
        end
      end
    end
  end

  bmp_read #(
    // [Design note 任务2]把本模块的 SCAN_INIT_BUDGET 真正转发给 bmp_read。
    //   原来这里没传参 -> bmp_read 用的是它自己的默认值 6000，sd_card_bmp 上的
    //   SCAN_INIT_BUDGET 形同虚设（TB 实测：预算传 128，scan_budget_cnt 却一路
    //   数到 633 才按 scan_max 收尾，正是"用的 6000 > 633、预算根本没生效"的证据）。
    //   顶层传下来的也是 6000，与 bmp_read 默认值一致，所以转发后行为完全不变，
    //   只是参数真的生效了（以后顶层要调相位 A 预算只需改这一处）。
    .SCAN_INIT_BUDGET(SCAN_INIT_BUDGET),
    .FRAME_WORDS     (FRAME_WORDS),
    // ================================================================
    // 2026-10-16 SCALING_EN：告诉 bmp_read "我和写侧之间有一个 scaler"
    //
    //   置 1 后它把"本帧字数上限"从 FRAME_WORDS(307200) 放开到
    //   16777216，让源图一直发到图尾。否则 1920x1080 的源
    //   （2,073,600 个像素）会在 307200 处被截断：
    //     scaler 断粮 → 输出不足 307200 → 帧填不满 →
    //     图片永不提交 → display_valid 不置起 → 所有按键被锁死
    //   （这正是板上"只有第一张图、按键全无反应"的根因）
    //
    //   同时它把宽度接受范围从 `width == 640` 放宽到 `640..4096`，
    //   让大图能进来被缩小。置 0 时所有表达式与原来逐字相同，
    //   所以 640x480 直通路径逐位不变、不可能被影响。
    // ================================================================
    .SCALING_EN      (1'b1)
  ) bmp_read_m0 (
    .clk            (clk),
    .rst            (rst),
    .ready          (bmp_ready),
    .load_error     (image_load_error),
    .source_top_down(source_top_down),

    .scan_start(DIRECTORY_IMAGES ? 1'b0 : scan_start_pulse),
    .load_abort(vid_lock),
    .sd_error(sd_error),
    .sd_grant(sd_grant),
    .scan_abort(first_image_committed && (next_req_pending || key_next_press || auto_step)),
    // [Design note 修复 现象1]phase B 用 scan_start_sector2 作为起点，
    //   由 bmp_read 内部根据 scan_start2 选择。这里把两者都接进去。
    .scan_start_sector(scan_start_sector),
    .scan_start_sector2(scan_start_sector2),
    .scan_start2(DIRECTORY_IMAGES ? 1'b0 : scan_start2),
    .scan_max_sector(SCAN_MAX_SECTOR),
    .scan_target_count(scan_start2 ? (SCAN_TARGET_COUNT - img_found_count) : SCAN_TARGET_COUNT),
    .scan_limited(scan_limited),  // 1 = phase A（受限）
    .scan_done(bmp_scan_done),
    .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector),
    .scan_found_total(scan_found_total),

    .load_start (load_start_pulse),
    .load_sector(load_sector),

    .sd_init_done(sd_init_done),
    .state_code(state_code),
    .bmp_width(bmp_width),
    .bmp_height(bmp_height),
    .write_req(write_req),
    .write_req_ack(write_req_ack),
    .write_almost_full(reader_high_q),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),
    .bmp_data_wr_en(bmp_data_wr_en),
    .bmp_data(bmp_data),
    .img_h_o(img_h_raw),  // 2026-10-14: 原始高度（不再直接上报）
    .aspect_h_o(img_aspect_h),
    .img_w_o(img_src_w),  // 2026-10-14 SCALING: 源图宽度
    .scan_sector_o(scan_sector)
  );

endmodule


module key_press_debounce #(
  parameter integer CLK_FREQ_HZ = 100_000_000,
  parameter integer DEBOUNCE_MS = 20
) (
  input  wire clk,
  input  wire rst,
  input  wire button_in,   // 默认：松开=1，按下=0
  output reg  press_pulse
);

  localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

  reg button_sync0;
  reg button_sync1;
  reg button_stable;
  reg [31:0] cnt;
  localparam [31:0] DB_LIMIT = DEBOUNCE_CYCLES - 1;
  reg db_due;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      button_sync0  <= 1'b1;
      button_sync1  <= 1'b1;
      button_stable <= 1'b1;
      cnt           <= 32'd0;
      db_due        <= (DB_LIMIT == 0);
      press_pulse   <= 1'b0;
    end else begin
      button_sync0 <= button_in;
      button_sync1 <= button_sync0;
      press_pulse  <= 1'b0;

      if (button_sync1 == button_stable) begin
        cnt <= 32'd0;
        db_due <= (DB_LIMIT == 0);
      end else begin
        if (db_due) begin
          if (button_stable && !button_sync1) press_pulse <= 1'b1;
          button_stable <= button_sync1;
          cnt           <= 32'd0;
          db_due        <= (DB_LIMIT == 0);
        end else begin
          cnt <= cnt + 32'd1;
          db_due <= cnt == (DB_LIMIT - 1'b1);
        end
      end
    end
  end

endmodule
