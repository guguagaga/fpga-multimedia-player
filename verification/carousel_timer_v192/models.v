module bmp_read #(
  // [Design note 健壮性修复 现象1]第一趟扫描（phase A）的扇区预算。
  //
  // 背景（bmp_scan_diag_tb 实测）：
  //   原来 scan_done 只在"凑满 scan_target_count 张 BMP"或"扫到
  //   scan_max_sector"时才置起，而 sd_card_bmp 的首图加载被 scan_done
  //   门控（sd_card_bmp.v:278）。于是凑不满 N 张时首图要等扫完
  //   131071 个扇区（x 实测 164us/扇区 ≈ 21.5 秒）——现场"上电约 20 秒
  //   才出图、按一下重新扫描很快就出图"。
  //   为什么凑不满 3 张：命中一张后用
  //     next_scan_sector_if_match = scan_sector + file_sector_count
  //   跳过整个文件。本卡三张图按簇对齐、间隔 1808 扇区，而 640x480/24bit
  //   合法 BMP 的 file_sector_count = ceil(921654/512) = 1801，
  //   32832+1801 = 34633 < 34640 -> 第 2 张被跳过；34640+1801 = 36441
  //   > 36416 -> 第 3 张也被跳过。实测只认出 2 张，然后一路扫到 131071。
  //
  // 修法（两趟扫描）：
  //   phase A：从 scan_start_sector 起线性扫（不跳文件，绝不漏图），
  //            最多 SCAN_INIT_BUDGET 个扇区就强制 scan_done，让首图尽快显示；
  //   phase B：顶层在首图提交后，用 scan_start2 在后台从"phase A 停下的
  //            位置"继续扫全范围，把剩余的图补齐（供按键切图）。
  parameter [31:0] SCAN_INIT_BUDGET = 32'd6000,
  // [Design note 缩放·写侧补黑]本帧总字数 = 640*480 = 307200。
  //   源图只有 W*H 个像素字时，剩下的要用黑字补满到恰好 307200，
  //   否则帧缓存的写侧永远收不了尾（write_finish 不 fire）⇒ 提交不了。
  parameter [31:0] FRAME_WORDS      = 32'd307200,
  // ================================================================
  // 2026-10-16 SCALER INTEGRATION FIX  (SCALING_EN)
  //
  //   当 scaler 插在本模块与写侧之间时，本模块发出的像素流是
  //   源图，不再是帧。下面几处按 "源 == 帧(640x480)" 定的东西会把
  //   大图源流截断，后果很戏剧性：
  //     帧永远到不了 FRAME_WORDS ⇒ 图片永不提交 ⇒ display_valid 不置起
  //     ⇒ 所有按键被锁死（正是板上"只有第一张图、按键全无反应"）。
  //
  //   (1) wr_total 只有 19 位，且 bmp_data_valid 里有
  //           wr_total < FRAME_WORDS (=307200)
  //       1920x1080 源有 2,073,600 个像素，只在图的 15% 处就被切断；
  //       scaler 随即断粮，只发出 307200/9 ≈ 34133 个输出像素。
  //   (2) 若只放开 (1)，ST_FILL 的退出条件 wr_total >= FRAME_WORDS
  //       就永远不成立，而 ST_FILL 又不涨计数器 ⇒ 整机挂死。
  //
  //   SCALING_EN=0 → 所有表达式与原来逐字相同，640x480 直通路径
  //                  逐位不变，不可能被这次改动影响。
  //   SCALING_EN=1 → 上限放到 4096x4096 能容纳的最大源像素数，
  //                  计数器加宽到 23 位（16,777,216 < 2^24）。
  // ================================================================
  parameter        SCALING_EN       = 1'b0,
  parameter        FAST_ROW_EN      = 1'b1
) (
  input  wire load_abort,
  input  wire sd_error,
  input  wire sd_grant,
  input       clk,
  input       rst,
  output      ready,

  // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
  input             scan_start,
  input             scan_abort,
  input      [31:0] scan_start_sector,
  input      [31:0] scan_max_sector,
  input      [ 2:0] scan_target_count,
  // [Design note 修复 现象1]1 = 受限扫描（phase A）：扫满
  //   SCAN_INIT_BUDGET 个扇区就强制 scan_done，只求尽快出首图。
  //   0 = 全范围扫描（phase B 后台补齐）。
  input             scan_limited,
  // [Design note 修复 现象1]phase B 的起点与发起脉冲。
  //   phase A 用 scan_start_sector（数据区首扇区，全量线性扫）；
  //   phase B 用 scan_start_sector2（= phase A 停下的位置）+ scan_start2。
  //   两个起点分开是因为"在模块内部记住上一趟停在哪儿"会引入额外状态，
  //   而顶层已经能通过 scan_sector_o 拿到当前位置，回接进来最省逻辑。
  input      [31:0] scan_start_sector2,
  input             scan_start2,
  output reg        scan_done,
  output reg        scan_found_valid,
  output reg [31:0] scan_found_sector,
  output reg [ 2:0] scan_found_total,

  // 按指定扇区加载一张图到 SDRAM
  input        load_start,
  input [31:0] load_sector,

  input             sd_init_done,
  output reg [ 3:0] state_code,
  input      [15:0] bmp_width,
  input      [15:0] bmp_height,

  output reg write_req,
  input      write_req_ack,
  input      write_almost_full,

  output reg        sd_sec_read,
  output reg [31:0] sd_sec_read_addr,
  input      [ 7:0] sd_sec_read_data,
  input             sd_sec_read_data_valid,
  input             sd_sec_read_end,

  output wire        bmp_data_wr_en,
  output wire [23:0] bmp_data,

  // [Design note 缩放·写侧补黑]本次校验通过并正在装载的源图高度
  //   （取自 BMP 头）。写侧用它算 VFLIP 起始 (H-1)*640，把图顶到内存行 0..H-1。
  //   整帧期间稳定；H = FRAME_HEIGHT 时写侧行为与改动前逐位相同。
  output wire [15:0] img_h_o,
  output wire        source_top_down,
  output reg         load_error,
  // 2026-10-14 SCALING: 把解析出的源图宽度也引出来，供 img_scaler 判断
  //   是否需要缩小。与 img_h_o 同源（BMP 头），整帧期间稳定。
  output wire [15:0] img_w_o,
  output reg [15:0] aspect_h_o,

  // [Design note]把扫描进度暴露给顶层，用于开机"LOADING + 进度条"等待画面。
  // 扫描是逐扇区裸扫（第一张图在扇区 32832 -> 约 5.4s），这段时间原来整屏全黑。
  output wire [31:0] scan_sector_o
);
reg busy=0,aborting=0;integer pixels=0;
assign ready=!busy;
assign bmp_data_wr_en=busy&&sd_sec_read&&sd_sec_read_data_valid&&!aborting&&!load_abort;
assign bmp_data=24'h112233;assign img_h_o=1;assign img_w_o=8;
assign source_top_down=1;assign scan_sector_o=0;
always @(posedge clk)begin
 if(rst||!sd_init_done)begin busy<=0;aborting<=0;write_req<=0;sd_sec_read<=0;load_error<=0;scan_done<=0;scan_found_valid<=0;scan_found_total<=0;scan_found_sector<=0;state_code<=0;aspect_h_o<=1;end
 else begin
  if(load_start&&!busy)begin busy<=1;write_req<=1;load_error<=0;aborting<=0;sd_sec_read_addr<=load_sector;end
  if(busy&&write_req&&write_req_ack)begin write_req<=0;sd_sec_read<=1;end
  if(busy&&load_abort)begin aborting<=1;if(!sd_sec_read)begin busy<=0;write_req<=0;end end
  if(sd_sec_read&&sd_sec_read_end)begin busy<=0;sd_sec_read<=0;load_error<=sd_error;end
 end
end
endmodule
module image_fit_720p(input clk,rst,frame_start,input[15:0]src_w,src_h,aspect_h,input in_valid,input[23:0]in_pixel,output high,overflow,input out_blocked,output out_valid,output[23:0]out_pixel);
assign high=out_blocked;assign overflow=0;assign out_valid=in_valid&&!frame_start;assign out_pixel=in_pixel;
endmodule
