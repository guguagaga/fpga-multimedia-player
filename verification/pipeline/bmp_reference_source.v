module bmp_read
#(
    // 【2026-10-02 健壮性修复 现象1】第一趟扫描（phase A）的扇区预算。
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
    //   phase A：从 scan_start_sector 起**线性**扫（不跳文件，绝不漏图），
    //            最多 SCAN_INIT_BUDGET 个扇区就强制 scan_done，让首图尽快显示；
    //   phase B：顶层在首图提交后，用 scan_start2 在后台从"phase A 停下的
    //            位置"继续扫全范围，把剩余的图补齐（供按键切图）。
    parameter [31:0] SCAN_INIT_BUDGET = 32'd6000,
    // 【2026-10-08 缩放·写侧补黑】本帧总字数 = 640*480 = 307200。
    //   源图只有 W*H 个像素字时，剩下的要用**黑字补满到恰好 307200**，
    //   否则帧缓存的写侧永远收不了尾（write_finish 不 fire）⇒ 提交不了。
    parameter [31:0] FRAME_WORDS = 32'd307200,
    // ================================================================
    // 2026-10-16 SCALER INTEGRATION FIX  (SCALING_EN)
    //
    //   当 scaler 插在本模块与写侧之间时，本模块发出的像素流是
    //   **源图**，不再是帧。下面几处按 "源 == 帧(640x480)" 定的东西会把
    //   大图源流**截断**，后果很戏剧性：
    //     帧永远到不了 FRAME_WORDS ⇒ 图片永不提交 ⇒ display_valid 不置起
    //     ⇒ **所有按键被锁死**（正是板上"只有第一张图、按键全无反应"）。
    //
    //   (1) wr_total 只有 19 位，且 bmp_data_valid 里有
    //           wr_total < FRAME_WORDS (=307200)
    //       1920x1080 源有 2,073,600 个像素，只在**图的 15% 处**就被切断；
    //       scaler 随即断粮，只发出 307200/9 ≈ 34133 个输出像素。
    //   (2) 若只放开 (1)，ST_FILL 的退出条件 wr_total >= FRAME_WORDS
    //       就永远不成立，而 ST_FILL 又不涨计数器 ⇒ **整机挂死**。
    //
    //   SCALING_EN=0 → 所有表达式**与原来逐字相同**，640x480 直通路径
    //                  **逐位不变**，不可能被这次改动影响。
    //   SCALING_EN=1 → 上限放到 4096x4096 能容纳的最大源像素数，
    //                  计数器加宽到 23 位（16,777,216 < 2^24）。
    // ================================================================
    parameter        SCALING_EN = 1'b0,
    parameter        FAST_ROW_EN = 1'b1
)(
    input wire load_abort,
    input wire sd_error,
    input wire sd_grant,
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input                       scan_abort,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    // 【2026-10-02 修复 现象1】1 = 受限扫描（phase A）：扫满
    //   SCAN_INIT_BUDGET 个扇区就强制 scan_done，只求尽快出首图。
    //   0 = 全范围扫描（phase B 后台补齐）。
    input                       scan_limited,
    // 【2026-10-02 修复 现象1】phase B 的起点与发起脉冲。
    //   phase A 用 scan_start_sector（数据区首扇区，全量线性扫）；
    //   phase B 用 scan_start_sector2（= phase A 停下的位置）+ scan_start2。
    //   两个起点分开是因为"在模块内部记住上一趟停在哪儿"会引入额外状态，
    //   而顶层已经能通过 scan_sector_o 拿到当前位置，回接进来最省逻辑。
    input  [31:0]               scan_start_sector2,
    input                       scan_start2,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,
    input                       write_almost_full,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output wire                 bmp_data_wr_en,
    output wire [23:0]          bmp_data,

    // 【2026-10-08 缩放·写侧补黑】本次校验通过并正在装载的**源图高度**
    //   （取自 BMP 头）。写侧用它算 VFLIP 起始 (H-1)*640，把图顶到内存行 0..H-1。
    //   整帧期间稳定；H = FRAME_HEIGHT 时写侧行为与改动前逐位相同。
    output wire [15:0]          img_h_o,
    output wire source_top_down,
    output reg load_error,
    // 2026-10-14 SCALING: 把解析出的源图宽度也引出来，供 img_scaler 判断
    //   是否需要缩小。与 img_h_o 同源（BMP 头），整帧期间稳定。
    output wire [15:0]          img_w_o,

    // 【2026-10-01】把扫描进度暴露给顶层，用于开机"LOADING + 进度条"等待画面。
    // 扫描是逐扇区裸扫（第一张图在扇区 32832 -> 约 5.4s），这段时间原来整屏全黑。
    output wire [31:0]          scan_sector_o
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
// Recover a lost client end pulse only AFTER all 512 bytes were received
// and the arbiter released ownership. Never time out an active SD transfer.
reg [9:0] sector_bytes;
reg [15:0] end_wait;
wire recovered_end = sd_sec_read && (end_wait == 16'd59999);
wire sector_end = sd_sec_read_end || recovered_end;
always @(posedge clk or posedge rst) begin
    if (rst) begin sector_bytes <= 0; end_wait <= 0; end
    else begin
        if (!sd_sec_read) sector_bytes <= 0;
        else if (sd_sec_read_data_valid && sector_bytes < 512)
            sector_bytes <= sector_bytes + 1'b1;
        if (!sd_sec_read || sd_grant !== 1'b0 || sd_sec_read_data_valid ||
            sd_sec_read_end || sector_bytes != 512) end_wait <= 0;
        else if (!recovered_end) end_wait <= end_wait + 1'b1;
    end
end
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
// 【2026-10-08 缩放·写侧补黑】补黑阶段：像素流发完后，用本地节拍器继续发 32'd0，
//   直到本帧总字数**恰好** FRAME_WORDS(=307200)。H=480 时补黑 0 字、该状态永不进入
//   ⇒ 与改动前逐位相同。
localparam ST_FILL      = 3'd5;

reg [2:0]  state;
reg [9:0]  rd_cnt;
reg [31:0] image_pixels;
reg [31:0] width;
reg [31:0] height;
// QOI integration: one full sector is buffered before decoding. A RUN can
// expand one byte to 62 pixels; SD transactions cannot be backpressured.
reg [31:0] q_magic,q_width,q_height;
reg [7:0] q_channels,q_colorspace;
reg is_qoi;
always @(posedge clk or posedge rst)begin
 if(rst)is_qoi<=0;else is_qoi<=(q_magic==32'h716f6966);
end
reg fast_rows;
reg[15:0]meta_h,meta_w;
always @(posedge clk or posedge rst)begin
 if(rst)begin meta_h<=0;meta_w<=0;end
 else begin meta_h<=is_qoi?q_height[15:0]:(fast_rows?16'd480:height[15:0]);meta_w<=is_qoi?q_width[15:0]:width[15:0];end
end
assign source_top_down=is_qoi;
wire q_header_match=is_qoi && q_width>=bmp_width && q_width<=4096 &&
 q_height>=1 && q_height<=4096 && (SCALING_EN || q_height<=bmp_height) &&
 (q_channels==3 || q_channels==4) && q_colorspace<=1;
reg bmp_pixel_wr_en;reg[23:0]bmp_pixel_data;
wire q_done,q_error,q_byte_ready,q_pixel_valid;
wire [23:0]q_pixel;
wire q_pixel_ready=(state==ST_LOAD_DATA)&&is_qoi&&!write_almost_full;
assign bmp_data_wr_en=is_qoi ? (q_pixel_valid&&q_pixel_ready) : bmp_pixel_wr_en;
assign bmp_data=is_qoi ? q_pixel : bmp_pixel_data;
reg [7:0] q_buf[0:511];reg[7:0]q_mem_q,q_byte;
reg q_have,q_pending,q_valid;
reg[9:0]q_pos;
wire q_start=(state==ST_LOAD_WAIT)&&write_req_ack&&is_qoi;
reg [31:0]q_byte_limit;
always @(posedge clk)begin
 q_mem_q<=q_buf[q_pos[8:0]];
 if(state==ST_LOAD_DATA&&is_qoi&&sd_sec_read_data_valid)
  q_buf[sector_bytes[8:0]]<=sd_sec_read_data;
 q_byte_limit<=(image_pixels<<2)+image_pixels+32'd22;
end
always @(posedge clk or posedge rst)begin
 if(rst)begin q_magic<=0;q_width<=0;q_height<=0;q_channels<=0;q_colorspace<=0;end
 else if((state==ST_LOAD_HDR||state==ST_SCAN)&&sd_sec_read_data_valid)begin
  case(rd_cnt)
   0:q_magic<={24'd0,sd_sec_read_data};
   1,2,3:q_magic<={q_magic[23:0],sd_sec_read_data};
   4:q_width<={24'd0,sd_sec_read_data};
   5,6,7:q_width<={q_width[23:0],sd_sec_read_data};
   8:q_height<={24'd0,sd_sec_read_data};
   9,10,11:q_height<={q_height[23:0],sd_sec_read_data};
   12:q_channels<=sd_sec_read_data;
   13:q_colorspace<=sd_sec_read_data;
  endcase
 end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin q_have<=0;q_pending<=0;q_valid<=0;q_pos<=0;q_byte<=0;end
 else if(load_start||load_abort||!sd_init_done)begin q_have<=0;q_pending<=0;q_valid<=0;q_pos<=0;end
 else begin
  if(state==ST_LOAD_DATA&&is_qoi&&sector_end)begin q_have<=1;q_pos<=0;end
  if(q_have&&!q_pending&&!q_valid&&q_pos<512)begin q_pending<=1;q_pos<=q_pos+1'b1;end
  if(q_pending)begin q_byte<=q_mem_q;q_valid<=1;q_pending<=0;end
  if(q_valid&&q_byte_ready)q_valid<=0;
  if(q_have&&q_pos==512&&!q_pending&&!q_valid)q_have<=0;
 end
end
qoi_stream #(.EXTERNAL_PIXELS(1'b1),.BRAM32_INDEX(1)) u_qoi(.clk(clk),.rst(rst||load_abort||!sd_init_done),.start(q_start),
 .din(q_byte),.din_valid(q_valid),.din_ready(q_byte_ready),.pixel(q_pixel),
 .expected_pixels(image_pixels[24:0]),.pixel_valid(q_pixel_valid),.pixel_ready(q_pixel_ready),.done(q_done),.error(q_error),.width(),.height());




reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;


reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
// 【2026-10-02】phase A 的扇区预算计数
reg [31:0] scan_budget_cnt;
reg [31:0] load_sector_latched;
reg [2:0] scan_target_latched;

// 【2026-10-08 缩放·写侧补黑】本帧已发出的字数（像素字 + 补黑字）。
//   ⚠️ 必须在**任何使用之前**声明：状态机里的 ST_FILL 判断比下面那个
//      always 块更早用到它；Verilog 里"先用后声明"会隐式变成 1 位 wire
//      （TD 会给 HDL-5373 警告），那样 `wr_total >= FRAME_WORDS` 就永远为假。
//   ⚠️ 位宽 19 位：FRAME_WORDS = 307200 < 2^19 = 524288 ⇒ 可证明装得下 ✓
//   ⚠️ 位宽：SCALING_EN=0 时 FRAME_WORDS = 307200 < 2^19，19 位就够；
//      但 SCALING_EN=1 时本模块发的是**源图**，像素数可达 16,777,216
//      （4096x4096），所以统一取 23 位。
//      23 位对 SCALING_EN=0 是**纯加宽**：上限仍是 FRAME_WORDS，
//      高位永远为 0 ⇒ 不缩放路径的行为逐位不变。
// 【2026-10-16 SCALING_EN】"要发的字数"上限。
//   ⚠️ 这只用于**防计数器溢出**，不是"控制帧长"。
//      帧长**始终**由写侧数到 FRAME_WORDS 决定，与源图多大无关。
//   SCALING_EN=0：等于 FRAME_WORDS（与改动前逐字相同）。
//   SCALING_EN=1：源像素可达 16,777,216，上限必须够大，
//      否则计数器会回绕，ST_FILL 的递增门控也会失效。
localparam [31:0] WR_TOTAL_LIMIT = SCALING_EN ? 32'd16777216 : FRAME_WORDS;
reg [22:0] wr_total;

// 【2026-10-01】扫描进度输出（给顶层做 LOADING 等待画面）
assign scan_sector_o = scan_sector;
// 【2026-10-08 缩放·写侧补黑】把头部解析出的高度给写侧用
assign img_h_o       = meta_h;
// 2026-10-14 SCALING: 源图宽度，与 img_h_o 同源同时机
assign img_w_o       = meta_w;
// 2026-10-26: exact vertical decimation before SD transfer.
// For 2x/3x/4x integer vertical reduction, the existing scaler selects
// rows 0,N,2N,...,479N. Read only sectors intersecting these rows, emit
// their complete RGB streams, and report H=480 to the unchanged scaler.
// Width must be four-byte aligned (no BMP row padding). Other dimensions
// retain the original full-stream path. No in-flight sector is cancelled.
reg [13:0] fast_row_bytes;
reg [15:0] fast_step_bytes;
// Fast offsets fit 25 bits: pixel_offset < 64 KiB and the largest
// accepted source is 4096*1920*3 bytes (< 24 MiB). Unusual headers
// with larger pixel offsets retain the original full-stream fallback.
reg [24:0] fast_start, fast_end, fast_next;
reg [31:0] fast_lba;
// Header fields settle before header-end; row lookahead settles during
// the current row. Keep the address adder outside the request/state mux.
always @(posedge clk or posedge rst) begin
    if (rst) fast_lba <= 0;
    else fast_lba <= load_sector_latched + ((state == ST_LOAD_HDR) ?
                     {9'd0,pixel_offset[31:9]} : {16'd0,fast_next[24:9]});
end
reg [8:0] fast_row;
reg [31:0] bmp_len_cnt;
wire fast_row_done = fast_rows && (bmp_len_cnt >= fast_end);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        fast_rows <= 0;
        fast_row_bytes <= 0;
        fast_step_bytes <= 0;
    end else begin
        fast_rows <= FAST_ROW_EN && SCALING_EN && !is_qoi &&
                     (pixel_offset[31:16] == 0) &&
                     (width[1:0] == 0) && (width >= 640) && (width <= 4096) &&
                     ((height == 960) || (height == 1440) || (height == 1920));
        fast_row_bytes <= {1'b0,width[12:0]} + {width[12:0],1'b0};
        case (height)
            960: fast_step_bytes <= {1'b0,fast_row_bytes,1'b0};
            1440: fast_step_bytes <= {2'b0,fast_row_bytes} + {1'b0,fast_row_bytes,1'b0};
            default: fast_step_bytes <= {fast_row_bytes,2'b0};
        endcase
    end
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        fast_start <= 0; fast_end <= 0; fast_next <= 0; fast_row <= 0;
    end else begin
        // Pipelined lookahead settles during the header/ack and each row.
        fast_end <= fast_start + {11'd0,fast_row_bytes};
        fast_next <= fast_start + {9'd0,fast_step_bytes};
        if (state != ST_LOAD_DATA) begin
            fast_start <= pixel_offset[24:0];
            fast_row <= 0;
        end else if (sector_end && fast_row_done && (fast_row != 479)) begin
            fast_start <= fast_next;
            fast_row <= fast_row + 1'b1;
        end
    end
end
reg [1:0]  bmp_byte_idx;

wire header_match;
wire bmp_data_valid;
wire [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;
// Header fields are complete by byte 33; header decisions occur only after
// the 512-byte sector ends. Compute the image bounds in advance, rather
// than putting multiply/add/compare in every pixel's 100 MHz enable path.
// Three pipeline stages settle long before ST_LOAD_DATA can be entered.

// Header geometry settles hundreds of byte clocks before any pixel load.
// Select the source dimensions BEFORE the product, allowing one shared
// DSP instead of parallel BMP/QOI products plus a32-bit result mux.
reg[15:0]source_width_q,source_height_q;
always @(posedge clk or posedge rst)begin
 if(rst)begin source_width_q<=0;source_height_q<=0;end
 else begin source_width_q<=is_qoi?q_width[15:0]:width[15:0];
            source_height_q<=is_qoi?q_height[15:0]:height[15:0];end
end
reg [31:0] image_bytes;
reg [31:0] image_end;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        image_pixels <= 32'd0;
        image_bytes <= 32'd0;
        image_end <= 32'd0;
    end else begin
        // ================================================================
        // 2026-10-16 ★真 BUG 修正★：这里原来用的是 `bmp_width`（模块参数），
        //   而顶层把它**硬编码成 16'd640**：
        //       top_tf_hdmi_audio.v:1688  .bmp_width  (16'd640),
        //       top_tf_hdmi_audio.v:1689  .bmp_height (16'd480),
        //   它的语义是"**显示**宽度"（接受条件的上界），**不是图像宽度**。
        //
        //   于是对一张 800x600 的图：
        //       image_pixels = bmp_width * height = 640 * 600 = 384,000   ✗
        //       image_bytes  = 1,152,000
        //       image_end    = 1,152,054
        //   而 `bmp_data_valid` 的门控里有 `bmp_len_cnt < image_end`
        //   ⇒ **源流在 1,152,000 字节处被砍断**，只发出 384,000 个像素
        //     （800x600 真实有 480,000 个像素）。
        //   ⇒ scaler 只收到 80% 的源 → 只输出 245,760 个字（需要 307,200）
        //   ⇒ 帧永远填不满 → 图片永不提交 → **按键全锁**。
        //
        //   实测佐证（tb_fulllink，探针）：
        //       h=600 w=800 px=384000 byt=1152000 end=1152054
        //   而 file_len = 1,440,054。`px` 正好等于 640*600。
        //
        //   为什么以前没暴露：SCALING_EN=0 时 `bmp_data_valid` 里还有
        //       (wr_total < FRAME_WORDS)
        //   那一项**先**把源流停在 307,200，正好掩盖了这个错误。
        //   640x480 的直通工况下 width==640 且 height==480，
        //   所以这一行改与不改**结果相同**（见 tb_bmpread 的 307200 验证）。
        //
        //   改法：用**解析出来的图像宽度** `width`，而不是参数 `bmp_width`。
        //   `bmp_width`/`bmp_height` 仍保留作接受条件的上界。
        // ================================================================
        image_pixels <= source_width_q*source_height_q;
        image_bytes <= image_pixels * 32'd3;
        image_end <= pixel_offset + image_bytes;
    end
end

assign ready = (state == ST_IDLE);
// ====================================================================
// 【2026-10-20 时序】header_match 打一拍，供状态机在两个"扇区结束"点使用。
//   原因：header_match 是一条 32 位比较/减法链
//        (width>=640)&&(width<=4096)&&(height>=1)&&(height<=4096)&&
//        (pixel_offset>=54)&&(file_len>=pixel_offset)&&
//        (file_len-pixel_offset>=image_bytes)&&...
//   它组合直接驱动 state/scan_sector/scan_found_sector/sd_sec_read_addr 的
//   写使能 ⇒ 实测 **57 个违例端点全部**由此发出（最差 -0.990，7 级）。
//   header_match 的输入（header_0/1, width, height, file_len, pixel_offset,
//   bit_count, compression, image_bytes）全部来自 BMP 头 **第 33 字节为止**的
//   字段，而它的两个使用点都在 `sector_end`（第 512 字节之后，早了几百
//   拍且不再变化），所以这里打一拍**逐位等价**：判决时读到的就是
//   header_match 在判决前一拍的取值，而那些输入在判决前几百拍就已经稳定。
//   复位时 header_ok_r=0，与原组合值（全 0 寄存器 ⇒ header_match=0）一致。
// ====================================================================
// All header fields settle hundreds of clocks before sector_end.
// Separate unsigned length subtraction from the remaining validation tree.
reg[31:0]header_payload_bytes;reg header_length_ok;
always @(posedge clk or posedge rst)begin
 if(rst)begin header_payload_bytes<=0;header_length_ok<=0;end
 else begin header_payload_bytes<=file_len-pixel_offset;header_length_ok<=file_len>=pixel_offset;end
end
reg header_ok_r;
always @(posedge clk or posedge rst) begin
    if (rst) header_ok_r <= 1'b0;
    else     header_ok_r <= header_match;
end
wire bmp_header_match;
assign header_match = q_header_match || bmp_header_match;
assign bmp_header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      // ============================================================
                      // 2026-10-16：宽度条件按 SCALING_EN 分两种
                      //
                      //   写侧 frame_fifo_write 的地址**只在 wr_x == 639 时跳行**：
                      //       if (wr_x == VFLIP_LINE_LAST_X)   // = 639
                      //           App_wr_addr_r -= VFLIP_LINE_JUMP;
                      //       else
                      //           App_wr_addr_r += 1'b1;
                      //   所以：
                      //     · width == 640  → 行边界与访存边界对齐 ⇒ 正确
                      //     · width  < 640  → 像素被连续打包进 640 宽的访存行
                      //       （101 宽时一行装 6.3 整行图），整幅图里行跳转只发生
                      //       **一次** ⇒ 图像变成横带，**乱码**
                      //     · width  > 640  → 必须先由 scaler 缩小成恰好 640
                      //
                      //   SCALING_EN=0（无 scaler，源 == 帧）：必须 width == 640。
                      //   SCALING_EN=1（有 scaler）：接受 640..4096。
                      //       scaler 恒输出 640x480 ⇒ 宽度 >640 被缩到恰好 640，
                      //       行边界自然对齐；宽度 ==640 走 bypass 直通。
                      //       ⚠️ 仍然**不能**接受 <640：scaler 只缩不放，
                      //          而且写侧的 640 字行边界对不齐。
                      // ============================================================
                      (width >= {16'd0, bmp_width}) &&
                      (width <= 32'd4096) &&
                      // 【2026-10-08 缩放·口径 A1】高度校验**放宽**：原来要求
                      //   height == bmp_height(=480)，现在接受 1..480 的任意高度。
                      //   判定依据来自 **BMP 头本身**；height > 480 仍然跳过
                      //   （本阶段只支持 <=480，图顶部对齐，不做居中）。
                      //   写侧会按这个高度把图放到内存行 0..H-1，并把余下部分补黑。
                      (height >= 32'd1) &&
                      // 2026-10-16：高度上限也按 SCALING_EN 分两种
                      //   （高度不影响写侧打包，只决定 VFLIP 起始行 (H-1)*640；
                      //     >480 时由 scaler 缩到 480）
                      (SCALING_EN ? (height <= 32'd4096)
                                  : (height <= {16'd0, bmp_height})) &&
                      (pixel_offset >= 32'd54) &&
                      header_length_ok &&
                      (header_payload_bytes >= image_bytes) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0);
assign bmp_data_valid = !is_qoi && (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt < image_end) &&
                        (!fast_rows || ((bmp_len_cnt >= fast_start) && (bmp_len_cnt < fast_end))) &&
                        // 【2026-10-16 SCALING_EN】决定"源流什么时候停"。
                        //   不缩放：wr_total 数到 FRAME_WORDS 就停 —— 与原来逐字
                        //     相同（源就是帧）。
                        //   有 scaler：**不能**再按 FRAME_WORDS 停！源图有
                        //     2,073,600 个像素（1920x1080），只发 307,200 个会把
                        //     scaler 饿死 → 输出不足 307200 → 帧填不满 → 挂死。
                        //     源流应**一直发到图尾**，由 `bmp_len_cnt < image_end`
                        //     自然收尾，所以这里放开成恒定 1。
                        (SCALING_EN ? 1'b1 : (wr_total < FRAME_WORDS));
assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
// 【2026-10-02】线性扫描：命中后也只前进一个扇区。
//   原因见文件头：`scan_sector + file_sector_count` 会因为"文件实际占用
//   比 file_len 大"而跳过下一张图（本卡实测 34633 < 34640，36441 > 36416）。
//   线性扫绝不漏图；时间由 SCAN_INIT_BUDGET（phase A）封顶。
assign next_scan_sector_if_match = scan_sector + 32'd1;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

// 预算计数器：每读完一个扇区 +1，只在受限扫描（phase A）时使用
wire scan_budget_hit = scan_limited && (scan_budget_cnt + 32'd1 >= SCAN_INIT_BUDGET) &&
                       (sector_end == 1'b1);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sector_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_WAIT && fast_rows) begin
        bmp_len_cnt <= {pixel_offset[31:9],9'd0};
    end else if (state == ST_LOAD_DATA) begin
        if (sector_end && fast_row_done && (fast_row != 479))
            bmp_len_cnt <= {7'd0,fast_next[24:9],9'd0};
        else if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_pixel_wr_en <= 1'b0;
        bmp_pixel_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_pixel_wr_en <= 1'b0;
                    bmp_pixel_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_pixel_wr_en <= 1'b0;
                    bmp_pixel_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_pixel_wr_en  <= 1'b1;
                    bmp_pixel_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_pixel_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_pixel_wr_en <= 1'b0;
        end
    end else if (state == ST_FILL) begin
        // 【2026-10-08 缩放·写侧补黑】本地节拍器：每拍发一个**黑字**（32'd0），
        //   直到本帧总字数恰好 FRAME_WORDS。冒烟条件在 wr_total 里，
        //   这里只要在 ST_FILL 就一直发（退出由状态机负责）。
        //   ⚠️ bmp_pixel_wr_en 是**寄存器**：如果在"决定退出"那一拍仍然拉高，
        //      它会在下一拍（已经回 ST_IDLE）多产生 1 个写脉冲 ⇒ 多写 1 字。
        //      所以这里必须用 wr_total 把关，退出拍不发。
        // 【2026-10-16 SCALING_EN】退出条件必须**始终**是 FRAME_WORDS：
        //   ST_FILL 的职责就是"把帧补满到 307200"，与源图多大无关。
        //   若跟着 WR_TOTAL_LIMIT 走，缩放模式下 wr_total 永远到不了
        //   FRAME_WORDS，而 ST_FILL 又不涨计数器 ⇒ 永远出不去，整机挂死。
        if (wr_total >= FRAME_WORDS || write_almost_full) begin
            bmp_pixel_wr_en <= 1'b0;
        end else begin
            bmp_pixel_wr_en <= 1'b1;
            bmp_pixel_data       <= 24'd0;
        end
    end else begin
        bmp_pixel_wr_en <= 1'b0;
    end
end

// 【2026-10-08 缩放·写侧补黑】wr_total 的**声明**已上移到模块顶部
//   （必须在 ST_FILL 判断之前，否则会隐式变成 1 位 wire —— 见那里的注释）。
//   这里只留计数器本体：
//   用"计数到 FRAME_WORDS"而不是"用 file_len 算像素数" —— 后者要除法器/乘法器，
//   这里只要一个加法器 + 一个比较器（面积/DSP 友好）✓
//   计数条件与 bmp_pixel_wr_en 的产生条件**严格一一对应**（同一拍同条件），
//   所以 wr_total 永远等于已经发给写侧的字节数。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        wr_total <= 23'd0;
    end else if (!sd_init_done || ((state == ST_IDLE) && load_start)) begin
        wr_total <= 23'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid && (bmp_byte_idx == 2'd2))
            wr_total <= wr_total + 23'd1;
    end else if ((state == ST_FILL) && (wr_total < WR_TOTAL_LIMIT) && !write_almost_full) begin
        wr_total <= wr_total + 23'd1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        load_error <= 0;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        scan_budget_cnt   <= 32'd0;
        load_sector_latched <= 32'd0;
        scan_target_latched <= 3'd0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        load_error <= 0;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        scan_budget_cnt   <= 32'd0;
        load_sector_latched <= 32'd0;
        scan_target_latched <= 3'd0;
    end else begin
        scan_found_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start || scan_start2) begin
                    scan_target_latched <= scan_target_count;
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    // 【2026-10-02】选起点：phase A 用 scan_start_sector，
                    //   phase B（scan_start2，由顶层接上 scan_sector_o）用
                    //   scan_start_sector2，这样后台扫描从 phase A 停下的
                    //   位置继续，而不是从头再扫一遍。
                    scan_sector      <= scan_start2 ? scan_start_sector2
                                                    : scan_start_sector;
                    scan_budget_cnt  <= 32'd0;      // 预算重新起算
                    sd_sec_read_addr <= scan_start2 ? scan_start_sector2
                                                    : scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    load_error <= 0;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sector_end) begin
                    sd_sec_read <= 1'b0;
                    // 预算计数（只有 phase A 受限扫描才用）
                    if (scan_limited && !scan_budget_hit)
                        scan_budget_cnt <= scan_budget_cnt + 32'd1;

                    if (header_ok_r) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;
                        // 只有"非受限"（phase B 后台）才允许因凑满 target 提前结束。
                        // phase A 必须只由预算/范围决定何时结束，否则若顶层把
                        // scan_target_count 传小，phase A 会提前收工、后面的图丢失。
                        if (scan_found_total + 3'd1 >= scan_target_latched) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else if ((next_scan_sector_if_match > scan_max_sector) ||
                                     scan_budget_hit) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        if ((scan_sector >= scan_max_sector) ||
                            (next_scan_sector_if_miss > scan_max_sector) ||
                            scan_budget_hit) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                    // Pause a background scan only at a sector boundary. Keep
                    // the next sector so the top can resume after an image load.
                    if (scan_abort) begin
                        scan_done <= 1'b1;
                        state <= ST_IDLE;
                        scan_sector <= scan_sector + 32'd1;
                        sd_sec_read_addr <= scan_sector + 32'd1;
                    end
                end
            end

            ST_LOAD_HDR: begin
                // 【FIX 2026-10-02 现象2】这里原来是 4'd2，与 ST_SCAN(4'd2) 撞码：
                //   DIG5 读 2 时无法区分"正在扫描"和"正在读 BMP 头/校验头"，
                //   本次定位图片问题就被这个歧义误导过一轮。
                //   现在改成 4'd5 —— DIG5=5 专指 ST_LOAD_HDR。
                state_code  <= 4'd5;
                sd_sec_read <= 1'b1;

                if (sector_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_ok_r) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= fast_rows ? fast_lba : load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                if(is_qoi)begin
                    if(!sd_sec_read && !q_have && !q_pending && !q_valid && !q_done && !q_error)begin
                        if(bmp_len_cnt>=q_byte_limit)begin load_error<=1;state<=ST_IDLE;end
                        else sd_sec_read<=1;
                    end
                    if(sector_end)begin sd_sec_read<=0;sd_sec_read_addr<=sd_sec_read_addr+1'b1;end
                    if((q_done||q_error)&&!sd_sec_read)begin load_error<=q_error;state<=ST_IDLE;end
                end else begin
                // Leave >=256 words free for an indivisible 512-byte sector
                // (at most 171 pixels). Never interrupt an existing request.
                if (!write_almost_full || sd_sec_read) sd_sec_read <= 1'b1;
                else sd_sec_read <= 1'b0;

                if (sector_end) begin
                    sd_sec_read <= 1'b0;
                    if (fast_rows && fast_row_done) begin
                        if (fast_row == 479) state <= ST_IDLE;
                        else sd_sec_read_addr <= fast_lba;
                    end else if (bmp_len_cnt >= file_len) begin
                        // 【2026-10-08 缩放·写侧补黑】像素流发完了，但本帧
                        //   还没写满 FRAME_WORDS ⇒ 进 ST_FILL 补黑；
                        //   H=480 时 wr_total 已经等于 FRAME_WORDS ⇒ 直接收尾，
                        //   与改动前**逐拍相同** ✓
                        if (wr_total >= FRAME_WORDS)
                            state <= ST_IDLE;
                        else
                            state <= ST_FILL;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
                end
            end

            // ---- 【2026-10-08 缩放·写侧补黑】补黑阶段 ----
            //   不再请求 SD 扇区（数据已经拿全了），只用本地节拍器把黑字发到写侧，
            //   直到本帧恰好 FRAME_WORDS 个字。
            //   退出即回 ST_IDLE，总字数**恰好** FRAME_WORDS（不是"至少"）。
            ST_FILL: begin
                state_code  <= 4'd6;          // 新增观测码（DIG5 可读）
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
                if (wr_total >= FRAME_WORDS)
                    state <= ST_IDLE;
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
        if (load_abort === 1'b1) begin
            if (state == ST_LOAD_WAIT || state == ST_FILL ||
                ((state == ST_LOAD_HDR || state == ST_LOAD_DATA) &&
                 (!sd_sec_read || sector_end))) begin
                state <= ST_IDLE; sd_sec_read <= 0; write_req <= 0;
            end
        end
        // The mapper owns the failed sector and has already retired it.
        // Discard this incomplete frame; never publish fabricated pixels.
        if(sd_error===1'b1)begin
            state<=ST_IDLE;sd_sec_read<=0;write_req<=0;load_error<=1;
        end

    end
end

endmodule
