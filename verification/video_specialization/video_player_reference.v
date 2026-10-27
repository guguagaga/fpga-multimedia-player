`timescale 1ns/1ps
//===========================================================================
// video_player : FPGV (RLE565 / RLE332) video decoder + frame writer
//---------------------------------------------------------------------------
// WHY IT LOOKS LIKE THIS
//
//   * Bandwidth.  The SD card is read over SPI at 25 MHz = 3.12 MB/s.
//     spi_master toggles DCLK only after clk_div+2 sys clocks of 100 MHz
//     (DCLK_IDLE counts 0..clk_div, then one DCLK_EDGE cycle), so with
//     SPI_HIGH_SPEED_DIV=0 a half period is 2 clocks -> 25 MHz -> 8 bits =
//     4 clocks/bit -> 32 clocks per byte, 512 B per 163.84 us.  That is
//     exactly the 164 us/sector measured on the board.
//     A raw 640x480 RGB565 frame is 614400 B -> 4.9 fps, so the frames are
//     run-length coded by tools/vid_encode.py and this module decodes them.
//
//   * The write side is NOT negotiable.  frame_fifo_write jumps SDRAM rows
//     only when its own wr_x counter hits 639, so every frame handed to it
//     must be exactly 640x480 = 307200 words.  This module therefore pads
//     with black (V_PAD) and swallows anything past 307200 (V_DRAIN): a
//     corrupt file can never wedge the writer and lock the keys.
//
//   * Byte pacing.  Pixel emission is capped at 1 word/clock by the image
//     FIFO port, but a BLACK token describes up to 32 pixels in ONE byte,
//     i.e. more pixels than the 32 clocks that byte takes to arrive.  So
//     incoming bytes land in a 128-entry byte FIFO and the next sector is
//     only requested while the FIFO is at most half full.  Worst case (a
//     fully black frame of 32-pixel BLACK tokens) is a ~48-byte debt per
//     512-byte sector, so 128 entries with a 64-byte threshold has ~2.6x
//     margin.  vid_encode.py caps BLACK runs at 32 for this reason.
//
//   * Triple buffering.  The display re-reads all 307200 words at 60 Hz and
//     only latches read_addr_index at read_req, so the buffer we stopped
//     displaying is still being read for up to one display frame (16.7 ms).
//     Rotating through THREE SDRAM buffers means the buffer we write was
//     retired at least two video frames (50..200 ms) ago.  It costs no LUT:
//     only the read_addr_2/3 and write_addr_2/3 constants in the top change.
//
// FILE FORMAT (authority: tools/vid_encode.py and scripts/encode_rgb565_copyup.py)
//   sector 0 : header   0..3 "FPGV", 4 ver, 5 codec (1=RLE565 2=RLE332,
//                       5=RLE332/COPY_UP, 6=RLE565/COPY_UP,
//                       7=RGB565/COPY_UP/APPROX_RUN),
//                       6..7 width, 8..9 height, 10..11 fps,
//                       12..15 file_bytes, 16..19 frame_count
//   sector 1+: frames, each a token stream ending with 0xFF
//     0x00-0x3F RUN     n=(op&63)+1 pixels, then `bpp` payload bytes
//     0x40-0x7F LITERAL n=(op&63)+1 pixels, then n*bpp payload bytes
//     0x80-0xBF BLACK   n=(op&63)+1 pixels of 0x000000, no payload
//     0xC0-0xFB COPY_UP n=(op&63)+1 pixels from the previous row (codec 5/6/7)
//     0xFC      APPROX_RUN, then count-1 and one RGB565 representative (codec 7)
//     0xFF      END
//   bpp = 2 for codec 1/6/7, 1 for codec 2/5.
//
// REVERT
//   With play=0 nothing outside this file changes: `active` is 0 and the
//   top-level muxes pass the image path through bit for bit.
//===========================================================================
module video_player #(
    parameter AV_SYNC = 0,
    parameter AUDIO_MASTER = 0,
    parameter integer ORPHAN_CYCLES = 60000,
    parameter [31:0]  FRAME_PIXELS = 32'd307200,  // 640*480, fixed by the write side
    parameter [15:0]  FRAME_H      = 16'd480,
    // ---- byte FIFO -------------------------------------------------------
    // 2026-10-17 codec 3 FIX: 原来 128 深 / BF_HI=64，而一个在途扇区有 512 字节
    //   ⇒ 一份扇区到齐之前 FIFO 必然被顶到满，只要解码器在这段时间里**停一下**
    //   就有字节被丢（push 有 `!bf_full` 保护，满了直接不要）。
    //   codec 1 从不停（每个 token 之间只隔 1~2 拍，排空率 ≥ 到达率），所以这个
    //   隐患一直没暴露；codec 3 每行要复放 640 拍、完全不取字节 ⇒ 必炸。
    //   现在深度放到 BF_HI + 512 = 576 以上：**一个在途扇区可以整份吞下**，
    //   解码器短暂停顿不再丢字节。1024 x 8 bit = 8192 bit，落 1 个 BRAM9k。
    parameter integer BF_AW        = 10,          // 1024 byte FIFO
    // 【2026-10-17 带宽修复】门限必须接近 FIFO 深度，不能是"快空了才要"。
    //
    //   原来 BF_HI=64：一个扇区到齐后水位约 576，必须等它掉到 64 才再发请求，
    //   中间约 102 us 里 **卡是空闲的、没有任何读请求在途**。SD 卡每次从空闲
    //   恢复都要付一次访问延迟（常见 200~400 us），于是每扇区实际耗时
    //   164(数据) + 102(空等) + ~290(卡恢复) ≈ 554 us ⇒ 只有 0.92 MB/s，
    //   实测视频以 6 fps 播放、7:02 的内容播了 23:14（用户实测数字）。
    //
    //   改成 480 后：请求在上一笔一结束就发（因为水位还没掉到门限），
    //   卡始终连续读，有效速率回到 25MHz SPI 的上限附近。
    //   留 32 字节余量：480 + 512(一个扇区) = 992 < 1024，不会顶满丢字节。
    parameter [15:0]  BF_HI        = 16'd480      // request next sector below this
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        sd_init_done,
    input  wire        sd_error,
    // ---- control ----
    input wire present_enable, timeline_run,
    input wire audio_frame_tick,
    input wire audio_clock_active,
    output reg [12:0] audio_frame_samples,
    input  wire        play,            // level: 1 = play / loop, 0 = stop
    input  wire        pause,           // hold decoded video and its timeline
    input  wire [31:0] start_sector,    // first sector of the .VID file
    input  wire [1:0]  img_disp_buf,    // buffer currently on screen (image path)
    // 【2026-10-17 视频】帧率上限靠**编码器**做，不在这里做。
    //   实测过两种节流方式：
    //     1) 这里等一个 vsync（需要把 video_clk 的 vsync 同步过来）：能锁 60fps，
    //        但停下来等的时候，上一个扇区的 512 字节还在往 128 深的字节 FIFO
    //        里灌 ⇒ 溢出丢字节 ⇒ 下一帧花掉（仿真已复现）。
    //        要做对得把 FIFO 加到 ~600 深（1 个 BRAM），而本设计 slices 已 96%，
    //        不值得为一个纯显示效果再花面积。
    //     2) 编码器侧用 0xC0 填充字节把每帧字节数补到"目标 fps"对应值：
    //        **零硬件代价**、帧率精确、解码器天然跳过填充（0xC0..0xFE 是保留
    //        码，只消耗 3 个时钟/字节，而同样的字节要 32 个时钟才到）。
    //   ⇒ 采用 (2)，见 tools/vid_encode.py 的 --pace。
    // ---- SD sector read (to sd_arbiter) ----
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end,
    input  wire        sd_grant, // real arbiter ownership; never abandon a live grant
    // ---- frame write side (same shape as bmp_read's) ----
    input  wire        write_almost_full,
    output reg         write_req,
    input  wire        write_req_ack,
    input  wire        write_finish_toggle,
    output reg         pix_en,
    output reg  [31:0] pix_data,
    output wire [15:0] img_h_o,
    input  wire       vsync_tick,     // 视频域 vsync 的单拍脉冲（已同步到本域）
    output reg  [1:0]  wr_buf_idx,
    output reg  [1:0]  dp_buf_idx,
    // ---- status ----
    output reg         active,          // 1 = video owns the write path and the display
    output reg         disp_ok,         // 1 = at least one video frame is on screen
    output wire [3:0]  dbg_state
    // 【2026-10-17 面积回收】原有两个调试计数器 dbg_frames(16FF) / dbg_bytes(32FF)
    //   在顶层是悬空 wire（只连不用）⇒ 纯浪费 48 个 FF + 两个加法器。
    //   删掉它们是为了把 slices 从 96.08% 压回去：加完视频音轨后布局变挤，
    //   WNS 从 −699ps 掉到 −1627ps，而最差路径全落在 wav_reader 的 WAV 头解析上
    //   —— 那正是这次要用的音频通路，不能留着这个风险。
);
    // Local register isolates the top-level AV-start fanout from the credit
    // arithmetic. Start/stop eligibility follows by one 100MHz clock (10ns);
    // pause and displayed-frame sample accounting retain their direct gates.
    reg timeline_run_q;
    always @(posedge clk or posedge rst) begin
        if (rst) timeline_run_q <= 0;
        else timeline_run_q <= timeline_run;
    end
    // ---------------- states ----------------
    // Register SD response as one aligned bundle before all video consumers.
    // Cuts cached SD RAM -> header parser/FIFO-control paths.
    reg [7:0] sd_sec_read_data_q;
    reg sd_sec_read_data_valid_q, sd_sec_read_end_q, sd_grant_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin sd_sec_read_data_q<=0;sd_sec_read_data_valid_q<=0;sd_sec_read_end_q<=0;sd_grant_q<=0;end
        else begin
            sd_sec_read_data_q<=sd_sec_read_data;
            sd_sec_read_data_valid_q<=sd_sec_read_data_valid;
            sd_sec_read_end_q<=sd_sec_read_end;
            sd_grant_q<=sd_grant;
        end
    end
    localparam [3:0] V_IDLE  = 4'd0;
    localparam [3:0] V_HDR   = 4'd1;    // reading sector 0
    localparam [3:0] V_REQ   = 4'd2;    // write_req handshake for a new frame
    localparam [3:0] V_SETTLE= 4'd3;    // let frame_fifo_write leave S_ACK
    localparam [3:0] V_STRM  = 4'd4;    // decoding + emitting
    localparam [3:0] V_DRAIN = 4'd5;    // frame full, swallow tokens until END
    // Presentation pacing is independent of compressed frame size.
    // video_pll is 40 MHz and raster timing is 1056 x 628.
    // Exact refresh = 62500/1036.2 Hz. Credit ratio 15543/62500
    // gives exactly 15 fps at the nominal board clock. Both the declared
    // width and literal width must hold a whole frame (12'd4096 was zero).
    localparam [19:0] ACC_ONE = 20'd60000;
    localparam [15:0] FPS_INC = 16'd30000; // legacy/default 15 fps
    reg [15:0] fps_inc; // header selects 15/20/25/30 fps without changing clocks
    // Each vsync earns FPS_INC; each completed frame spends ACC_ONE.
    // Retain bounded debt across stalls so the decoder can catch up;
    // stop/restart clears stale debt and grants one immediate first frame.
    reg  [19:0] deficit;      // 1/4000 frame; unsigned, saturates at about 262 frames
    // Single driver: credit is updated only in the main state machine.
    localparam [3:0] V_PAD   = 4'd6;    // short frame, pad black to FRAME_PIXELS
    localparam [3:0] V_FIN   = 4'd7;    // wait for the SDRAM write, then swap
    localparam [3:0] V_BAD   = 4'd8;    // header rejected

    localparam [2:0] D_OP    = 3'd0;
    localparam [2:0] D_RUN0  = 3'd1;
    localparam [2:0] D_RUN1  = 3'd2;
    localparam [2:0] D_RUNW  = 3'd3;
    localparam [2:0] D_LIT0  = 3'd4;
    localparam [2:0] D_LIT1  = 3'd5;
    localparam [2:0] D_LITW  = 3'd6;
    // Codec7 reuses RUN0/RUN1 and adds one byte-read state for the
    // representative RGB565 high byte.  Keeping the decoder at 3 bits
    // avoids widening the critical token-state compare network.
    localparam [2:0] D_ARUN2 = 3'd7;

    // ---------------- registers (all declared before any always block) -------
    reg [BF_AW:0] bf_wp, bf_rp;
    reg               bf_rdreq;
    reg  [7:0]        bf_q;
    wire [7:0] bf_mem_q;
    reg bf_pending;
    reg               bf_qv;            // bf_q holds an unconsumed byte

    reg  [3:0]        state;
    reg  [2:0]        dstate;
    reg  [31:0]       base_sec, end_sec, sec_addr, file_bytes;
    reg               inflight;
    reg [9:0]         bytes_seen;
    reg [15:0]        orphan_timer;
    reg               read_last;
    wire recovered_end = inflight && (orphan_timer == ORPHAN_CYCLES-1);
    wire sector_done = sd_sec_read_end_q || recovered_end;
    reg bf_push;
    reg [7:0] bf_push_data;
    wire byte_in_file = !read_last || (file_bytes[8:0] == 0) ||
                        (bytes_seen < {1'b0,file_bytes[8:0]});
    reg  [4:0]        hdr_idx;
    reg               hdr_magic;
    reg               codec332;
    reg               codec_up;
    reg               codec_block;
    reg               c8_end_seen;
    reg               codec_approx;
    reg               approx_mode;
    reg [6:0]         up_left;
    reg               up_phase;
    localparam integer FRAME_W = FRAME_PIXELS / FRAME_H;
    localparam integer PIX_COUNT_W = $clog2(FRAME_PIXELS+1);
    localparam integer X_COUNT_W = $clog2(FRAME_W);
    reg [X_COUNT_W-1:0] up_x;
    // Codec 5 stores an RGB332 row; codec 6 stores RGB565. The wider cache
    // keeps COPY_UP lossless for codec 6 and is inferred as BRAM by TD.
    localparam integer C8_RAM_WORDS = FRAME_W * 7;
    localparam integer C8_RAM_AW = $clog2(C8_RAM_WORDS);
    // Explicit 2048x16 BRAM32K banks free scarce 9K blocks.
    // COPY_UP uses row zero; codec8 shares the same seven-row storage.
    localparam integer C8_BANKS = (C8_RAM_WORDS + 2047) / 2048;
    localparam integer C8_BANK_BITS = (C8_BANKS < 2) ? 1 : $clog2(C8_BANKS);
    localparam integer C8_SHARED_AW = (C8_RAM_AW < 11) ? 11 : C8_RAM_AW;
    wire [15:0] up_q, c8_read_q;
    reg               codec_bad;
    reg               play_d;
    reg               wrfin_s0, wrfin_s1, wrfin_s2;
    reg               wrfin_seen;
    reg  [4:0]        settle_cnt;

    reg  [8:0]        op_cnt;           // remaining pixels of the current token
    reg  [7:0]        bpp_lo;
    reg  [7:0]        opcode;
    reg [PIX_COUNT_W-1:0] pcnt;             // pixels emitted for the current frame

    reg  [7:0]        emit_n;           // pixels still to emit for the current token
    reg  [7:0]        emit_cnt;         // value loaded into emit_n
    reg  [15:0]       emit_val;
    reg               arm;              // 1-cycle: load emit_n from emit_cnt

    // ---------------- derived ----------------
    wire [BF_AW:0]  bf_usedw = bf_wp - bf_rp;
    wire            bf_empty = (bf_wp == bf_rp);
    wire            bf_full  = bf_usedw[BF_AW];
    wire            wrfin_pulse = wrfin_s2 ^ wrfin_s1;
    wire            frame_commit = (state == V_FIN) &&
                                   (wrfin_pulse || wrfin_seen) &&
                                   (!AV_SYNC || disp_ok || present_enable) &&
                                   (deficit >= ACC_ONE) && !pause && (!AV_SYNC || !disp_ok || timeline_run_q);
    wire use_audio_clock = AUDIO_MASTER && audio_clock_active;
    wire pacing_tick = use_audio_clock ? audio_frame_tick : vsync_tick;
    wire [19:0] pacing_credit = use_audio_clock ? ACC_ONE : {4'd0,fps_inc};
    wire            frame_full  = (pcnt >= FRAME_PIXELS);
    wire            emit_done   = (emit_n == 8'd0) && !arm &&
                                  (up_left == 0);
    wire [6:0]      tok_cnt     = {1'b0, bf_q[5:0]} + 7'd1;

    // 565 / 332 -> 24-bit RGB (MSB replication, matching tools/vid_refhash.py)
    //   565: R8={R5,R5[4:2]}  G8={G6,G6[5:4]}  B8={B5,B5[4:2]}
    //   332: R8={R3,R3,R3[2:1]} G8 同理, B8={B2 x4}
    //   ⚠ 332 的复制必须是**高位**（R3[2:1] = emit_val[7:6]），
    //     写成低位（[6:5]）会差 1 个 LSB —— 这个 bug 真的发生过：
    //     TB 的参考哈希对不上，逐像素 diff 抓到 ref=0xffdb55 / rtl=0xffda55。
    wire [7:0] v_r5 = {emit_val[15:11], emit_val[15:13]};
    wire [7:0] v_g6 = {emit_val[10:5],  emit_val[10:9]};
    wire [7:0] v_b5 = {emit_val[4:0],   emit_val[4:2]};
    wire [7:0] v_r3 = {emit_val[7:5], emit_val[7:5], emit_val[7:6]};
    wire [7:0] v_g3 = {emit_val[4:2], emit_val[4:2], emit_val[4:3]};
    wire [7:0] v_b2 = {emit_val[1:0], emit_val[1:0], emit_val[1:0], emit_val[1:0]};

    // Codec 5 adds COPY_UP to RGB332; codec 6 uses the same token format
    // with RGB565 payloads, preserving full colour in repeated rows.
    // The encoder caps these at 12 pixels: at two clocks per pixel this
    // remains faster than 25 MHz SPI, including token decoding overhead.
    // A synchronous row RAM holds the previous row at each column.
    wire normal_fire = play && !pause && !arm && (emit_n != 0) && (up_left == 0) &&
                       !frame_full && !write_almost_full;
    wire copy_fire = play && !pause && (up_left != 0) && up_phase &&
                     !frame_full && !write_almost_full;
    wire [15:0] up_value = (pcnt >= FRAME_W) ? up_q : 16'd0;
    wire [23:0] up_rgb = codec332 ?
                         {{up_value[7:5],up_value[7:5],up_value[7:6]},
                          {up_value[4:2],up_value[4:2],up_value[4:3]},
                          {up_value[1:0],up_value[1:0],up_value[1:0],up_value[1:0]}} :
                         {{up_value[15:11],up_value[15:13]},
                          {up_value[10:5],up_value[10:9]},
                          {up_value[4:0],up_value[4:2]}};
    wire c8_run = play && codec_block && ((state == V_STRM) || (state == V_DRAIN));
    reg c8_run_q;
    always @(posedge clk or posedge rst) begin
        if (rst) c8_run_q <= 0;
        else c8_run_q <= c8_run;
    end
    wire c8_ready, c8_pv, c8_done, c8_fault, c8_busy, c8_out_valid;
    wire [15:0] c8_rgb, c8_out_rgb, c8_mem_wdata;
    wire c8_mem_we;
    wire [C8_RAM_AW-1:0] c8_mem_waddr, c8_mem_raddr;
    wire c8_pause = pause || write_almost_full || c8_busy || c8_end_seen || c8_done;
    video_codec8_block_decoder #(.FRAME_PIXELS(FRAME_PIXELS), .ALLOW_SOLID_RUN(1)) u_codec8 (
        .clk(clk), .rst(rst), .enable(c8_run_q), .pause(c8_pause),
        .byte_valid(bf_qv), .byte_data(bf_q), .byte_ready(c8_ready),
        .pix_valid(c8_pv), .pix_rgb565(c8_rgb), .frame_done(c8_done), .fault(c8_fault)
    );
    video_codec8_raster #(.FRAME_W(FRAME_W), .RAM_AW(C8_RAM_AW)) u_codec8_raster (
        .clk(clk), .rst(rst), .clear(!c8_run), .pause(pause || write_almost_full),
        .pix_valid(c8_pv), .pix_rgb565(c8_rgb), .busy(c8_busy),
        .mem_we(c8_mem_we), .mem_waddr(c8_mem_waddr), .mem_wdata(c8_mem_wdata),
        .mem_raddr(c8_mem_raddr), .mem_rdata(c8_read_q),
        .out_valid(c8_out_valid), .out_rgb565(c8_out_rgb)
    );
    wire shared_we = codec_block ? c8_mem_we : (codec_up && (normal_fire || copy_fire));
    wire [C8_SHARED_AW-1:0] shared_wa = codec_block ? c8_mem_waddr : up_x;
    wire [C8_SHARED_AW-1:0] shared_ra = codec_block ? c8_mem_raddr : up_x;
    wire [15:0] shared_wd = codec_block ? c8_mem_wdata :
        (copy_fire ? up_value : (codec332 ? {8'd0, emit_val[7:0]} : emit_val));
    // Defer writes one cycle to break the RAM read/mux/write feedback path.
    // COPY_UP revisits each column on the following scanline.
    reg shared_we_q;
    reg [C8_SHARED_AW-1:0] shared_wa_q;
    reg [15:0] shared_wd_q;
    always @(posedge clk) begin
        shared_we_q <= shared_we && !rst;
        shared_wa_q <= shared_wa;
        shared_wd_q <= shared_wd;
    end
    wire [15:0] bank_q [0:C8_BANKS-1];
    reg [C8_BANK_BITS-1:0] read_bank;
    genvar cache_bank;
    generate for (cache_bank=0; cache_bank<C8_BANKS; cache_bank=cache_bank+1) begin: g_cache
        EG_PHY_BRAM32K #(.MODE("DP16K"), .DATA_WIDTH_A("16"), .DATA_WIDTH_B("16"),
            .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL")) mem (
            .doa(), .dia(shared_wd_q), .addra(shared_wa_q[10:0]),
            .bytea(1'b0), .bytewea(1'b0), .csa(1'b1),
            .wea(shared_we_q && ((shared_wa_q >> 11) == cache_bank)),
            .clka(clk), .rsta(1'b0), .ocea(1'b1),
            .dob(bank_q[cache_bank]), .dib(16'd0), .addrb(shared_ra[10:0]),
            .byteb(1'b0), .byteweb(1'b0), .csb(1'b1), .web(1'b0),
            .clkb(clk), .rstb(1'b0), .oceb(1'b1)
        );
    end endgenerate
    always @(posedge clk) read_bank <= shared_ra >> 11;
    assign c8_read_q = bank_q[read_bank];
    // Legacy COPY_UP's 10-bit column counter is entirely in bank zero.
    assign up_q = bank_q[0];
    always @(posedge clk or posedge rst) begin
        if (rst) c8_end_seen <= 0;
        else if (!c8_run) c8_end_seen <= 0;
        else if (c8_done) c8_end_seen <= 1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) up_x <= 0;
        else if (!play || (state == V_REQ && write_req_ack)) up_x <= 0;
        else if (normal_fire || copy_fire)
            up_x <= (up_x == FRAME_W-1) ? 0 : up_x + 1'b1;
    end

    // Count real bytes, not elapsed time while another SD owner is active.
    // A missed completion is recoverable only after all 512 bytes arrived AND
    // the arbiter released ownership. Never fabricate a missing data byte.
    always @(posedge clk or posedge rst) begin
        if (rst) begin bytes_seen <= 0; orphan_timer <= 0; read_last <= 0; end
        else begin
            if (!inflight) bytes_seen <= 0;
            else if (sd_sec_read_data_valid_q && bytes_seen < 512)
                bytes_seen <= bytes_seen + 1'b1;
            if (!inflight || sd_grant_q || sd_sec_read_data_valid_q || sd_sec_read_end_q || bytes_seen != 512)
                orphan_timer <= 0;
            else if (!recovered_end) orphan_timer <= orphan_timer + 1'b1;
            if (!inflight && !sd_sec_read)
                read_last <= (state != V_HDR) && (sec_addr + 32'd1 >= end_sec);
        end
    end

    // Pipeline sector-boundary filtering together with its data. Reserving
    // 32 bytes below FIFO capacity also covers this one-cycle in-flight byte.
    // Stop gates insertion so a canceled session cannot leak a queued byte.
    always @(posedge clk or posedge rst) begin
        if(rst)begin bf_push<=0;bf_push_data<=0;end
        else begin
            bf_push<=sd_sec_read_data_valid_q && active &&
                     state!=V_HDR && byte_in_file && play;
            bf_push_data<=sd_sec_read_data_q;
        end
    end
    // ---------------- BRAM read port (only writes bf_q) ----------------
    video_byte_ram #(.AW(BF_AW)) compressed_bytes(
        .clk(clk), .we(bf_push && play && !bf_full && !rst),
        .wa(bf_wp[BF_AW-1:0]), .data(bf_push_data),
        .re(bf_rdreq), .ra(bf_rp[BF_AW-1:0]), .q(bf_mem_q));
    always @(posedge clk) bf_q <= bf_mem_q;

    // ---------------- single owning always block ----------------
    reg filesystem_failed;
    always@(posedge clk or posedge rst)begin
        if(rst)filesystem_failed<=0;
        else if(!play)filesystem_failed<=0;
        else if(sd_error===1'b1)filesystem_failed<=1;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bf_wp <= {(BF_AW+1){1'b0}};
            bf_rp <= {(BF_AW+1){1'b0}};
            bf_rdreq <= 1'b0; bf_pending <= 0; bf_qv <= 1'b0;
            state <= V_IDLE; dstate <= D_OP;
            fps_inc <= FPS_INC;
            audio_frame_samples <= 13'd3200;
            deficit <= ACC_ONE;                 // 复位：立刻允许第一帧
            sd_sec_read <= 1'b0; sd_sec_read_addr <= 32'd0;
            inflight <= 1'b0;
            base_sec <= 32'd0; end_sec <= 32'd0; sec_addr <= 32'd0;
            file_bytes <= 32'd0; hdr_idx <= 5'd0; hdr_magic <= 1'b0;
            codec332 <= 1'b0; codec_bad <= 1'b0;
            codec_block <= 0;
            codec_up <= 0; codec_approx <= 0; approx_mode <= 0; up_left <= 0; up_phase <= 0;
            play_d <= 1'b0;
            wrfin_s0 <= 1'b0; wrfin_s1 <= 1'b0; wrfin_s2 <= 1'b0;
            wrfin_seen <= 1'b0;
            settle_cnt <= 5'd0;
            op_cnt <= 9'd0; bpp_lo <= 8'd0; opcode <= 8'd0;
            pcnt <= 0;
            emit_n <= 8'd0; emit_cnt <= 8'd0; emit_val <= 16'd0; arm <= 1'b0;
            write_req <= 1'b0; pix_en <= 1'b0; pix_data <= 32'd0;
            wr_buf_idx <= 2'd1; dp_buf_idx <= 2'd0;
            active <= 1'b0; disp_ok <= 1'b0;
        end else begin
            // ---- defaults ----
            pix_en   <= 1'b0;
            // Release the external level request at the original handshake
            // edge. Keep inflight until the delayed response is consumed,
            // so no new request can bypass the last pipelined byte.
            if (sd_sec_read_end) sd_sec_read <= 1'b0;
            arm      <= 1'b0;
            bf_rdreq <= 1'b0;
            bf_pending <= bf_rdreq;
            play_d   <= play;
            wrfin_s0 <= write_finish_toggle;
            wrfin_s1 <= wrfin_s0;
            wrfin_s2 <= wrfin_s1;
            if (wrfin_pulse) wrfin_seen <= 1'b1;

            // ---- byte FIFO push (header sector is parsed inline, never queued) ----
            if (bf_push && play && !bf_full) begin
                bf_wp <= bf_wp + 1'b1;
            end

            // ---- byte fetch: one outstanding request, data valid next cycle ----
            if (bf_rdreq && !bf_empty)
                bf_rp <= bf_rp + 1'b1;
            if (bf_pending)
                bf_qv <= 1'b1;

            // One pixel per clock for RUN/LITERAL/BLACK; two for COPY_UP.
            // Accept the bounded two-register codec8 pipeline even when
            // almost_full rises; the existing FIFO reserves 256 words.
            if (codec_block && c8_out_valid) begin
                pix_en <= 1;
                pix_data <= {{c8_out_rgb[15:11],c8_out_rgb[15:13]},
                             {c8_out_rgb[10:5],c8_out_rgb[10:9]},
                             {c8_out_rgb[4:0],c8_out_rgb[4:2]},8'd0};
                pcnt <= pcnt + 1'b1;
            end else if (arm) begin
                emit_n <= emit_cnt;
            end else if (up_left != 0) begin
                if (frame_full) begin up_left <= 0; up_phase <= 0; end
                else if (!up_phase) up_phase <= 1;
                else if (copy_fire) begin
                    pix_en <= 1; pix_data <= {up_rgb,8'd0};
                    pcnt <= pcnt + 1'b1;
                    up_left <= up_left - 1'b1; up_phase <= 0;
                end
            end else if (emit_n != 0) begin
                if (frame_full) emit_n <= 0;
                else if (normal_fire) begin
                    pix_en <= 1;
                    pix_data <= codec332 ? {v_r3,v_g3,v_b2,8'd0} : {v_r5,v_g6,v_b5,8'd0};
                    emit_n <= emit_n - 1'b1; pcnt <= pcnt + 1'b1;
                end
            end

            // ================= stop / start =================
            if (!play || filesystem_failed || (sd_error===1'b1)) begin
                // A new playback session starts with one immediate frame credit.
                deficit <= ACC_ONE;
                if (state != V_IDLE) begin
                    sd_sec_read <= 1'b0;
                    write_req   <= 1'b0;
                    inflight    <= 1'b0;
                end
                state   <= V_IDLE;
                dstate  <= D_OP;
                up_left <= 0; up_phase <= 0;
                active  <= 1'b0;
                disp_ok <= 1'b0;
                pcnt    <= 0;
                emit_n  <= 8'd0;
                bf_qv   <= 1'b0;
                bf_pending <= 0;
                bf_wp   <= {(BF_AW+1){1'b0}};
                bf_rp   <= {(BF_AW+1){1'b0}};
            end else begin
                // ---- 【2026-10-21 换帧节流】vsync 累加（必须留在本 always 块内）----
                //   ⚠ 陷阱：原来的写法 `vs_acc + FPS_INC >= 6'd60` 在 vs_acc=54 时
                //     54+18=72，而 vs_acc 只有 6 位 => 回绕成 8 => 判断为假，
                //     累加器永远不触发（板上实测 4~5 fps，正是这个 bug）。
                //   改成 `vs_acc >= 60-FPS_INC`：比较在 6 位内恒成立，而
                //     `vs_acc + FPS_INC - 60` 因为结果一定 <60，按模运算仍是正确值。
                // Retire and accrue credit together; neither event may overwrite the other.
                // Debit first also leaves room for the tick at saturation.
                if (frame_commit) begin
                    deficit <= deficit - (pacing_tick ? (ACC_ONE - pacing_credit) : ACC_ONE);
                end else if (AV_SYNC && !timeline_run_q) begin
                    deficit <= disp_ok ? 20'd0 : ACC_ONE;
                end else if (pacing_tick && (!pause || use_audio_clock)) begin
                    // 欠帧累加（饱和，避免长时间卡顿后溢出回绕）
                    if (deficit > 20'hFFFFF - pacing_credit)
                        deficit <= 20'hFFFFF;
                    else
                        deficit <= deficit + pacing_credit;
                end

                // ---- SD sector retire / loop ----
                if (sector_done && inflight) begin
                    sd_sec_read <= 1'b0;
                    inflight    <= 1'b0;
                    if (sec_addr + 32'd1 >= end_sec)
                        sec_addr <= base_sec + 32'd1;   // loop: back to payload start
                    else
                        sec_addr <= sec_addr + 32'd1;
                end

                case (state)
                // ------------------------------------------------ IDLE
                V_IDLE: begin
                    if (!play_d && sd_init_done && (start_sector != 32'd0)) begin
                        base_sec   <= start_sector;
                        sec_addr   <= start_sector;
                        hdr_idx    <= 5'd0;
                        hdr_magic  <= 1'b1;
                        codec_bad  <= 1'b0;
                        file_bytes <= 32'd0;
                        pcnt       <= 0;
                        emit_n     <= 8'd0;
                        dstate     <= D_OP;
                        bf_qv      <= 1'b0;
                        wr_buf_idx <= (img_disp_buf == 2'd0) ? 2'd1 : 2'd0;
                        dp_buf_idx <= img_disp_buf;
                        disp_ok    <= 1'b0;
                        state      <= V_HDR;
                    end
                end

                // ------------------------------------------------ header sector
                V_HDR: begin
                    if (!inflight && !sd_sec_read) begin
                        sd_sec_read      <= 1'b1;
                        sd_sec_read_addr <= sec_addr;
                        inflight         <= 1'b1;
                    end
                    if (sd_sec_read_data_valid_q) begin
                        case (hdr_idx)
                        5'd0: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'h46); // 'F'
                        5'd1: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'h50); // 'P'
                        5'd2: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'h47); // 'G'
                        5'd3: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'h56); // 'V'
                        5'd5: begin
                            codec332    <= (sd_sec_read_data_q == 8'd2) || (sd_sec_read_data_q == 8'd5);
                            codec_up <= (sd_sec_read_data_q == 8'd5) ||
                                        (sd_sec_read_data_q == 8'd6) ||
                                        (sd_sec_read_data_q == 8'd7);
                            codec_approx <= (sd_sec_read_data_q == 8'd7);
                            codec_block <= (sd_sec_read_data_q == 8'd8) || (sd_sec_read_data_q == 8'd9) || (sd_sec_read_data_q == 8'd10);
                            // codec 3 = 320x240 -> 2x2 (rows and columns doubled)
                            // codec 4 = 320x480 -> 2x1 (columns only; full vertical
                            //           detail, half horizontal.  Costs ~4 LUT more
                            //           than codec 3 because it simply does NOT set
                            codec_bad <= (sd_sec_read_data_q != 8'd1) &&
                                     (sd_sec_read_data_q != 8'd2) && (sd_sec_read_data_q != 8'd5) &&
                                     (sd_sec_read_data_q != 8'd6) && (sd_sec_read_data_q != 8'd7) &&
                                     (sd_sec_read_data_q != 8'd8) && (sd_sec_read_data_q != 8'd9) && (sd_sec_read_data_q != 8'd10);
                        end
                        5'd4: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'd1);
                        5'd6: hdr_magic <= hdr_magic && (sd_sec_read_data_q == ((FRAME_PIXELS/FRAME_H) & 255));
                        5'd7: hdr_magic <= hdr_magic && (sd_sec_read_data_q == ((FRAME_PIXELS/FRAME_H) >> 8));
                        5'd8: hdr_magic <= hdr_magic && (sd_sec_read_data_q == (FRAME_H & 255));
                        5'd9: hdr_magic <= hdr_magic && (sd_sec_read_data_q == (FRAME_H >> 8));
                        // Zero is accepted for historical files/tests with an unset FPS field.
                        // Other unsupported rates fail header validation explicitly.
                        5'd10: begin
                            case (sd_sec_read_data_q)
                                8'd0,8'd15: begin fps_inc <= 16'd30000; audio_frame_samples <= 13'd3200; end
                                8'd20: begin fps_inc <= 16'd40000; audio_frame_samples <= 13'd2400; end
                                8'd25: begin fps_inc <= 16'd50000; audio_frame_samples <= 13'd1920; end
                                8'd30: begin fps_inc <= 16'd60000; audio_frame_samples <= 13'd1600; end
                                default: codec_bad <= 1'b1;
                            endcase
                        end
                        5'd11: if (sd_sec_read_data_q != 0) codec_bad <= 1'b1;
                        5'd12: file_bytes[7:0]   <= sd_sec_read_data_q;
                        5'd13: file_bytes[15:8]  <= sd_sec_read_data_q;
                        5'd14: file_bytes[23:16] <= sd_sec_read_data_q;
                        5'd15: file_bytes[31:24] <= sd_sec_read_data_q;
                        default: ;
                        endcase
                        if (hdr_idx != 5'd31) hdr_idx <= hdr_idx + 5'd1;
                    end
                    if (sector_done) begin
                        if (hdr_magic && !codec_bad && (file_bytes > 32'd512)) begin
                            end_sec  <= base_sec + ((file_bytes + 32'd511) >> 9);
                            sec_addr <= base_sec + 32'd1;
                            active   <= 1'b1;
                            state    <= V_REQ;
                        end else begin
                            active <= 1'b0;
                            state  <= V_BAD;
                        end
                    end
                end

                // ------------------------------------------------ rejected header
                V_BAD: begin
                    // nothing to do; the top keeps `play` at 1 until the user
                    // presses the key again, so we simply sit here
                end

                // ------------------------------------------------ ask for a frame
                V_REQ: begin
                    wrfin_seen      <= 1'b0;            // only look at pulses from now on
                    if (write_req_ack) begin
                        write_req  <= 1'b0;
                        settle_cnt <= 5'd20;
                        state      <= V_SETTLE;
                    end else if (!write_req) begin
                        write_req <= 1'b1;
                        pcnt      <= 0;
                        emit_n    <= 8'd0;
                        dstate    <= D_OP;
                        // codec 3 row/replay state must start clean per frame
                    end
                end

                // ------------------------------------------------ post-ack gap
                // frame_fifo_write keeps fifo_aclr high for as long as
                // write_req_d2 is set (state S_ACK).  write_req_d2 is three
                // ext_mem_clk cycles behind our write_req, so wait before the
                // first pixel or it would be cleared away.
                V_SETTLE: begin
                    if (settle_cnt == 5'd0) begin
                        dstate <= D_OP;
                        state  <= V_STRM;
                    end else begin
                        settle_cnt <= settle_cnt - 5'd1;
                    end
                end

                // ------------------------------------------------ decode
                V_STRM, V_DRAIN, V_PAD: begin
                    // keep a sector in flight while there is FIFO room
                    // (V_PAD needs no more bytes, so it stops asking)
                    if (!pause && !inflight && !sd_sec_read && (state != V_PAD) &&
                        (bf_usedw <= BF_HI)) begin
                        sd_sec_read      <= 1'b1;
                        sd_sec_read_addr <= sec_addr;
                        inflight         <= 1'b1;
                    end

                    if (state == V_PAD) begin
                        if (frame_full) begin
                            state <= V_FIN;
                        end else if (emit_done) begin
                            arm      <= 1'b1;
                            emit_cnt <= 8'd1;         // one black pixel
                            emit_val <= 16'd0;
                        end
                    end else if (codec_block) begin
                        if (bf_qv && c8_ready) bf_qv <= 0;
                        else if (!bf_qv && !bf_rdreq && !bf_pending && !bf_empty && c8_ready)
                            bf_rdreq <= 1;
                        if (c8_fault) state <= frame_full ? V_FIN : V_PAD;
                        else if (c8_end_seen && !c8_busy && !c8_out_valid && !c8_pv)
                            state <= frame_full ? V_FIN : V_PAD;
                    end else begin
                        // ---- token engine ----
                        if (dstate == D_OP || dstate == D_RUN0 || dstate == D_RUN1 ||
                            dstate == D_LIT0 || dstate == D_LIT1 || dstate == D_ARUN2) begin
                            if (bf_qv) begin
                                bf_qv <= 1'b0;
                                case (dstate)
                                D_OP: begin
                                    case (bf_q[7:6])
                                    2'b00: begin opcode <= bf_q; dstate <= D_RUN0; end
                                    2'b01: begin
                                               opcode <= bf_q;
                                               // n = op+1 pixels; the first one is
                                               // emitted by D_LIT1, so n-1 remain.
                                               // Loaded HERE (not in D_LIT1): a
                                               // reload per pixel would make the
                                               // literal loop for ever.
                                               op_cnt <= {{3{1'b0}}, bf_q[5:0]};
                                               dstate <= D_LIT0;
                                           end
                                    2'b10: begin                       // BLACK
                                               arm      <= 1'b1;
                                               emit_cnt <= tok_cnt;
                                               emit_val <= 16'd0;
                                               dstate   <= D_RUNW;
                                           end
                                    default: begin
                                        if (bf_q == 8'hFF)
                                            state <= frame_full ? V_FIN : V_PAD;
                                        else if (codec_approx && bf_q == 8'hFC) begin
                                            approx_mode <= 1'b1;
                                            dstate <= D_RUN0;
                                        end
                                        else if (codec_up) begin
                                            up_left <= tok_cnt;
                                            up_phase <= 0;
                                            dstate <= D_RUNW;
                                        end
                                        // Other codecs retain reserved-byte skip.
                                    end
                                    endcase
                                end
                                D_RUN0: begin
                                    bpp_lo <= bf_q;
                                    if (codec332) begin
                                        arm      <= 1'b1;
                                        emit_cnt <= {{2{1'b0}}, opcode[5:0]} + 8'd1;
                                        emit_val <= {8'd0, bf_q};
                                        dstate   <= D_RUNW;
                                    end else if (approx_mode) begin
                                        // APPROX_RUN count byte; the next two
                                        // bytes are the representative RGB565.
                                        emit_cnt <= {1'b0, bf_q} + 8'd1;
                                        dstate   <= D_RUN1;
                                    end else begin
                                        dstate   <= D_RUN1;
                                    end
                                end
                                D_RUN1: begin
                                    if (approx_mode) begin
                                        bpp_lo <= bf_q;
                                        dstate <= D_ARUN2;
                                    end else begin
                                        arm      <= 1'b1;
                                        emit_cnt <= {{2{1'b0}}, opcode[5:0]} + 8'd1;
                                        emit_val <= {bf_q, bpp_lo};
                                        dstate   <= D_RUNW;
                                    end
                                end
                                D_LIT0: begin
                                    bpp_lo <= bf_q;
                                    if (codec332) begin
                                        arm      <= 1'b1;
                                        emit_cnt <= 8'd1;
                                        emit_val <= {8'd0, bf_q};
                                        dstate   <= D_LITW;
                                    end else begin
                                        dstate   <= D_LIT1;
                                    end
                                end
                                D_LIT1: begin
                                    arm      <= 1'b1;
                                    emit_cnt <= 8'd1;
                                    emit_val <= {bf_q, bpp_lo};
                                    dstate   <= D_LITW;
                                end
                                D_ARUN2: begin
                                    // High byte of the representative RGB565.
                                    arm      <= 1'b1;
                                    emit_val <= {bf_q, bpp_lo};
                                    approx_mode <= 1'b0;
                                    dstate   <= D_RUNW;
                                end
                                default: dstate <= D_OP;
                                endcase
                            end else if (!bf_rdreq && !bf_pending && !bf_empty) begin
                                bf_rdreq <= 1'b1;
                            end
                        end else begin
                            // D_RUNW / D_LITW : wait for the engine to drain
                            if (emit_done) begin
                                if (dstate == D_RUNW) begin
                                    dstate <= D_OP;
                                end else if (op_cnt == 9'd0) begin
                                    dstate <= D_OP;
                                end else begin
                                    op_cnt <= op_cnt - 9'd1;
                                    dstate <= D_LIT0;
                                end
                            end
                        end

                        if (state == V_STRM && pcnt >= FRAME_PIXELS)
                            state <= V_DRAIN;
                    end
                end

                // ------------------------------------------------ frame complete
                V_FIN: begin
                    if (frame_commit) begin
                        wrfin_seen <= 1'b0;
                        dp_buf_idx <= wr_buf_idx;                       // hard cut
                        wr_buf_idx <= (wr_buf_idx == 2'd2) ? 2'd0
                                                          : (wr_buf_idx + 2'd1);
                        disp_ok    <= 1'b1;
                        pcnt       <= 0;
                        emit_n     <= 8'd0;
                        dstate     <= D_OP;
                        state      <= V_REQ;
                    end
                end

                default: state <= V_IDLE;
                endcase

                
            end
        end
    end

    assign img_h_o   = FRAME_H;
    assign dbg_state = state;

endmodule



