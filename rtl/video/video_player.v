`timescale 1ns / 1ps
// Parse FPGV data and schedule decoded pixels into owned frame-buffer banks.
// Byte-FIFO admission reserves space for one complete in-flight SD sector.
// Audio consumption grants presentation credit; scanout feedback releases banks.
// Geometry and FIFO capacity are selected by the integration parameters.
module video_player #(
  parameter PLAYLIST_SUPPORT = 0,
  // RLE/COPY_UP support is parameterized; the integration selects block modes.
  parameter                LEGACY_CODECS = 1,
  parameter                AV_SYNC       = 0,
  parameter                AUDIO_MASTER  = 0,
  parameter integer        ORPHAN_CYCLES = 60000,
  parameter         [31:0] FRAME_PIXELS  = 32'd307200,  // 640*480, fixed by the write side
  parameter         [15:0] FRAME_H       = 16'd480,
  // Reserve at least one 512-byte sector above the request watermark so
  // accepted data still fits when decoding is stalled.
  parameter integer        BF_AW         = 10,          // 1024 byte FIFO
  // Request the next sector while enough space remains for its full payload.
  // The integration overrides this watermark together with FIFO depth.
  parameter         [15:0] BF_HI         = 16'd480      // request next sector below this
) (
  input wire clk,
  input wire rst,
  input wire sd_init_done,
  input wire sd_error,
  // ---- control ----
  input wire present_enable, timeline_run,
  input wire audio_frame_tick,
  input wire audio_clock_active,
  output reg [12:0] audio_frame_samples,
  input wire play,  // level: 1 = play / loop, 0 = stop
  input wire pause,  // hold decoded video and its timeline
  input wire [31:0] start_sector,  // first sector of the .VID file
  input wire [1:0] img_disp_buf,  // buffer currently on screen (image path)
  // SD sector interface. Presentation timing is handled independently of
  // compressed frame size; pending reads retain their transaction ownership.
  output reg sd_sec_read,
  output reg [31:0] sd_sec_read_addr,
  input wire [7:0] sd_sec_read_data,
  input wire sd_sec_read_data_valid,
  input wire sd_sec_read_end,
  input wire sd_grant,  // real arbiter ownership; never abandon a live grant
  // ---- frame write side (same shape as bmp_read's) ----
  input wire write_almost_full,
  output reg write_req,
  input wire write_req_ack,
  input wire write_finish_toggle,
  output reg pix_en,
  output reg [31:0] pix_data,
  output wire [15:0] img_h_o,
  input wire scanout_event,
  input wire [1:0] scanout_bank,
  input wire vsync_tick,  // 视频域 vsync 的单拍脉冲（已同步到本域）
  output reg [1:0] wr_buf_idx,
  output reg [1:0] dp_buf_idx,
  // ---- status ----
  output wire movie_last_shown,
  output reg active,  // 1 = video owns the write path and the display
  output reg disp_ok,  // 1 = at least one video frame is on screen
  output wire [3:0] dbg_state
);
  // Register AV-start locally to limit control fanout. Start/stop eligibility
  // follows by one input clock; pause and displayed-frame accounting remain direct.
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
    if (rst) begin
      sd_sec_read_data_q <= 0;
      sd_sec_read_data_valid_q <= 0;
      sd_sec_read_end_q <= 0;
      sd_grant_q <= 0;
    end else begin
      sd_sec_read_data_q <= sd_sec_read_data;
      sd_sec_read_data_valid_q <= sd_sec_read_data_valid;
      sd_sec_read_end_q <= sd_sec_read_end;
      sd_grant_q <= sd_grant;
    end
  end
  localparam [3:0] V_IDLE = 4'd0;
  localparam [3:0] V_HDR = 4'd1;  // reading sector 0
  localparam [3:0] V_REQ = 4'd2;  // write_req handshake for a new frame
  localparam [3:0] V_SETTLE = 4'd3;  // let frame_fifo_write leave S_ACK
  localparam [3:0] V_STRM = 4'd4;  // decoding + emitting
  localparam [3:0] V_DRAIN = 4'd5;  // frame full, swallow tokens until END
  // Presentation pacing is independent of compressed frame size.
  // 74.25MHz / (1650*750) = 60Hz scanout; credit per refresh is
  // fps*1000 against a 60000-unit frame; audio-master pacing uses sample credit.
  localparam [19:0] ACC_ONE = 20'd60000;
  localparam [15:0] FPS_INC = 16'd15000;  // legacy/default 15 fps
  reg [15:0] fps_inc;  // header selects 15/20/25/30 fps without changing clocks
  // Each vsync earns FPS_INC; each completed frame spends ACC_ONE.
  // Retain bounded debt across stalls so the decoder can catch up;
  // stop/restart clears stale debt and grants one immediate first frame.
  reg [19:0] deficit;  // 1/4000 frame; unsigned, saturates at about 262 frames
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
  reg        bf_rdreq;
  reg  [7:0] bf_q;
  wire [7:0] bf_mem_q;
  reg        bf_pending;
  reg        bf_qv;  // bf_q holds an unconsumed byte

  reg  [3:0] state;
  reg  [2:0] dstate;
  reg [31:0] base_sec, end_sec, sec_addr, file_bytes;
  reg inflight;
  reg [9:0] bytes_seen;
  reg [15:0] orphan_timer;
  reg read_last;
  wire recovered_end = inflight && (orphan_timer == ORPHAN_CYCLES - 1);
  wire sector_done = sd_sec_read_end_q || recovered_end;
  reg bf_push;
  reg [7:0] bf_push_data;
  wire byte_in_file = !read_last || (file_bytes[8:0] == 0) ||
                        (bytes_seen < {1'b0,file_bytes[8:0]});
  reg [4:0] hdr_idx;
  reg hdr_magic;
  reg codec332;
  reg codec_up;
  reg codec_block;
  wire use_block_codec = !LEGACY_CODECS || codec_block;
  reg c8_end_seen;
  reg codec_approx;
  reg approx_mode;
  reg [6:0] up_left;
  reg up_phase;
  localparam integer FRAME_W = FRAME_PIXELS / FRAME_H;
  localparam integer PIX_COUNT_W = $clog2(FRAME_PIXELS + 1);
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
  reg codec_bad;
  reg play_d;
  reg wrfin_s0, wrfin_s1, wrfin_s2;
  reg wrfin_seen;
  reg [4:0] settle_cnt;

  reg [8:0] op_cnt;  // remaining pixels of the current token
  reg [7:0] bpp_lo;
  reg [7:0] opcode;
  reg [PIX_COUNT_W-1:0] pcnt;  // pixels emitted for the current frame

  reg [7:0] emit_n;  // pixels still to emit for the current token
  reg [7:0] emit_cnt;  // value loaded into emit_n
  reg [15:0] emit_val;
  reg arm;  // 1-cycle: load emit_n from emit_cnt

  // ---------------- derived ----------------
  wire [BF_AW:0] bf_usedw = bf_wp - bf_rp;
  wire bf_empty = (bf_wp == bf_rp);
  wire bf_full = bf_usedw[BF_AW];
  wire wrfin_pulse = wrfin_s2 ^ wrfin_s1;
  // One complete frame may wait for its presentation credit while the
  // third SDRAM bank receives the following frame. Do not recycle the old
  // displayed bank until a scanout boundary has sampled its replacement.
  reg ready_valid, ready_last, retired_valid;
  reg [1:0] ready_bank, retired_bank;
  wire decode_last, decode_exhausted;
  wire frame_enqueue = (state == V_FIN) && !ready_valid &&
                       (wrfin_pulse || wrfin_seen) && !pause && !decode_exhausted;
  wire write_bank_free = wr_buf_idx != dp_buf_idx &&
                         (!ready_valid || wr_buf_idx != ready_bank) &&
                         (!retired_valid || wr_buf_idx != retired_bank);
  // Two decoded frames cover startup transport/decoder burst jitter.
  // A one-frame movie bypasses preroll; no header/PCM samples are skipped.
  wire preroll_ready = disp_ok || ready_last ||
                       (state==V_FIN && (wrfin_seen || wrfin_pulse));
  wire            frame_commit = preroll_ready && ready_valid && !retired_valid && !movie_last_shown &&
                                   (!AV_SYNC || disp_ok || present_enable) &&
                                   (deficit >= ACC_ONE) && !pause && (!AV_SYNC || !disp_ok || timeline_run_q);
  wire use_audio_clock = AUDIO_MASTER && audio_clock_active;
  // Read the declared frame count, not the prefetch/file wrap position.
  // A last frame is held until its PCM budget is consumed in the top level.
  wire playlist_header_valid;
  generate if (PLAYLIST_SUPPORT) begin : g_playlist_end
    reg [31:0] remaining;
    reg one_left, low_zero, finished;
    assign movie_last_shown = finished;
    assign decode_last = one_left;
    assign decode_exhausted = remaining == 0;
    assign playlist_header_valid = remaining != 0;
    always @(posedge clk or posedge rst) begin
      if (rst) begin remaining<=0;one_left<=0;low_zero<=0;finished<=0;end
      else if (!play) begin remaining<=0;one_left<=0;low_zero<=0;finished<=0;end
      else begin
        one_left <= remaining == 1;
        low_zero <= remaining[15:0] == 0;
        if (state==V_HDR && sd_sec_read_data_valid_q) begin
          case(hdr_idx)
            16: remaining[7:0] <= sd_sec_read_data_q;
            17: remaining[15:8] <= sd_sec_read_data_q;
            18: remaining[23:16] <= sd_sec_read_data_q;
            19: remaining[31:24] <= sd_sec_read_data_q;
          endcase
        end else if(frame_enqueue) begin
          remaining[15:0] <= remaining[15:0] - 16'd1;
          if(low_zero) remaining[31:16] <= remaining[31:16] - 16'd1;

        end
        if(frame_commit && ready_last) finished<=1;
      end
    end
  end else begin : g_legacy_loop
    assign movie_last_shown = 1'b0;
    assign decode_last = 1'b0;
    assign decode_exhausted = 1'b0;
    assign playlist_header_valid = 1'b1;
  end endgenerate
  wire pacing_tick = use_audio_clock ? audio_frame_tick : vsync_tick;
  wire [19:0] pacing_credit = use_audio_clock ? ACC_ONE : {4'd0, fps_inc};
  wire frame_full = (pcnt >= FRAME_PIXELS);
  wire emit_done = (emit_n == 8'd0) && !arm && (up_left == 0);
  wire [6:0] tok_cnt = {1'b0, bf_q[5:0]} + 7'd1;

  // Expand RGB565/RGB332 channels by repeating their most significant bits.
  // RGB565: R8={R5,R5[4:2]}, G8={G6,G6[5:4]}, B8={B5,B5[4:2]}.
  // RGB332: R8={R3,R3,R3[2:1]}, G8 uses the same rule, B8 repeats B2.
  wire [7:0] v_r5 = {emit_val[15:11], emit_val[15:13]};
  wire [7:0] v_g6 = {emit_val[10:5], emit_val[10:9]};
  wire [7:0] v_b5 = {emit_val[4:0], emit_val[4:2]};
  wire [7:0] v_r3 = {emit_val[7:5], emit_val[7:5], emit_val[7:6]};
  wire [7:0] v_g3 = {emit_val[4:2], emit_val[4:2], emit_val[4:3]};
  wire [7:0] v_b2 = {emit_val[1:0], emit_val[1:0], emit_val[1:0], emit_val[1:0]};

  // COPY_UP reads the previous scanline from synchronous RAM. The token
  // format selects RGB332 or RGB565 payload interpretation.
  wire normal_fire = LEGACY_CODECS && play && !pause && !arm && (emit_n != 0) && (up_left == 0) &&
                       !frame_full && !write_almost_full;
  wire copy_fire = LEGACY_CODECS && play && !pause && (up_left != 0) && up_phase &&
                     !frame_full && !write_almost_full;
  wire [15:0] up_value = (pcnt >= FRAME_W) ? up_q : 16'd0;
  wire [23:0] up_rgb = codec332 ?
                         {{up_value[7:5],up_value[7:5],up_value[7:6]},
                          {up_value[4:2],up_value[4:2],up_value[4:3]},
                          {up_value[1:0],up_value[1:0],up_value[1:0],up_value[1:0]}} :
                         {{up_value[15:11],up_value[15:13]},
                          {up_value[10:5],up_value[10:9]},
                          {up_value[4:0],up_value[4:2]}};
  reg codec_huffman;
  wire c8_run = play && use_block_codec && ((state == V_STRM) || (state == V_DRAIN));
  reg c8_run_q;
  always @(posedge clk or posedge rst) begin
    if (rst) c8_run_q <= 0;
    else c8_run_q <= c8_run;
  end
  wire c8_ready, c8_pv, c8_done, c8_fault, c8_busy, c8_out_valid;
  wire block_byte_ready, block_fault, entropy_in_ready, entropy_valid, entropy_done, entropy_fault;
  wire [7:0] entropy_byte;
  wire entropy_queue_ready, entropy_queue_valid;
  wire [7:0] entropy_queue_byte;
  wire [7:0] block_byte=codec_huffman?entropy_queue_byte:bf_q;
  wire block_byte_valid=codec_huffman?entropy_queue_valid:bf_qv;
  codec_byte_queue #(.AW(10)) u_entropy_queue(
    .clk(clk),.clear(rst||!c8_run_q||!codec_huffman),
    .in_data(entropy_byte),.in_valid(entropy_valid),.in_ready(entropy_queue_ready),
    .out_data(entropy_queue_byte),.out_valid(entropy_queue_valid),
    .out_ready(codec_huffman&&block_byte_ready));
  assign c8_ready=codec_huffman?entropy_in_ready:block_byte_ready;
  assign c8_fault=block_fault||(codec_huffman&&entropy_fault);
  wire [7:0] entropy_raw_byte;
  wire [2:0] entropy_raw_context;
  wire entropy_raw_valid,entropy_raw_ready;
  codec12_lossless_restore u_entropy_restore(
    .clk(clk),.rst(rst),.start(!c8_run_q||!codec_huffman),
    .in_data(entropy_raw_byte),.in_context(entropy_raw_context),
    .in_valid(entropy_raw_valid),.in_ready(entropy_raw_ready),
    .out_data(entropy_byte),.out_valid(entropy_valid),.out_ready(entropy_queue_ready));
  context_huffman_decoder u_entropy(
    .clk(clk),.rst(rst),.start(!c8_run_q||!codec_huffman),
    .in_data(bf_q),.in_valid(bf_qv&&codec_huffman&&c8_run_q),.in_ready(entropy_in_ready),
    .out_data(entropy_raw_byte),.out_context(entropy_raw_context),.out_valid(entropy_raw_valid),.out_ready(entropy_raw_ready),
    .frame_done(entropy_done),.fault(entropy_fault));
  wire [15:0] c8_rgb, c8_out_rgb, c8_mem_wdata;
  wire c8_mem_we;
  wire [C8_RAM_AW-1:0] c8_mem_waddr, c8_mem_raddr;
  wire c8_pause = pause || write_almost_full || c8_busy || c8_end_seen || c8_done;
  codec12_block_decoder_experimental #(
    .FRAME_PIXELS(FRAME_PIXELS),
    .ENABLE_GRADIENT(0),
    .ENABLE_QUAD(1),
    .ENABLE_SOLID_RUN(1)
  ) u_codec8 (
    .clk       (clk),
    .rst       (rst),
    .enable    (c8_run_q),
    .pause     (c8_pause),
    .byte_valid(block_byte_valid),
    .byte_data (block_byte),
    .byte_ready(block_byte_ready),
    .pix_valid (c8_pv),
    .pixel     (c8_rgb),
    .frame_done(c8_done),
    .fault     (block_fault)
  );
  video_codec8_raster #(
    .FRAME_W(FRAME_W),
    .RAM_AW (C8_RAM_AW)
  ) u_codec8_raster (
    .clk       (clk),
    .rst       (rst),
    .clear     (!c8_run),
    .pause     (pause || write_almost_full),
    .pix_valid (c8_pv),
    .pix_rgb565(c8_rgb),
    .busy      (c8_busy),
    .mem_we    (c8_mem_we),
    .mem_waddr (c8_mem_waddr),
    .mem_wdata (c8_mem_wdata),
    .mem_raddr (c8_mem_raddr),
    .mem_rdata (c8_read_q),
    .out_valid (c8_out_valid),
    .out_rgb565(c8_out_rgb)
  );
  wire shared_we = use_block_codec ? c8_mem_we : (codec_up && (normal_fire || copy_fire));
  wire [C8_SHARED_AW-1:0] shared_wa = use_block_codec ? c8_mem_waddr : up_x;
  wire [C8_SHARED_AW-1:0] shared_ra = use_block_codec ? c8_mem_raddr : up_x;
  wire [15:0] shared_wd = use_block_codec ? c8_mem_wdata :
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
  wire [15:0] bank_q[0:C8_BANKS-1];
  reg [C8_BANKS-1:0] read_bank_onehot;
  genvar cache_bank;
  generate
    for (cache_bank = 0; cache_bank < C8_BANKS; cache_bank = cache_bank + 1) begin : g_cache
      EG_PHY_BRAM32K #(
        .MODE("DP16K"),
        .DATA_WIDTH_A("16"),
        .DATA_WIDTH_B("16"),
        .REGMODE_A("NOREG"),
        .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),
        .WRITEMODE_B("NORMAL")
      ) mem (
        .doa    (),
        .dia    (shared_wd_q),
        .addra  (shared_wa_q[10:0]),
        .bytea  (1'b0),
        .bytewea(1'b0),
        .csa    (1'b1),
        .wea    (shared_we_q && ((shared_wa_q >> 11) == cache_bank)),
        .clka   (clk),
        .rsta   (1'b0),
        .ocea   (1'b1),
        .dob    (bank_q[cache_bank]),
        .dib    (16'd0),
        .addrb  (shared_ra[10:0]),
        .byteb  (1'b0),
        .byteweb(1'b0),
        .csb    (1'b1),
        .web    (1'b0),
        .clkb   (clk),
        .rstb   (1'b0),
        .oceb   (1'b1)
      );
    end
  endgenerate
  // Decode the bank alongside the synchronous RAM read. Balanced
  // masked-OR selection avoids a binary mux/decoder after RAM output.
  integer bank_decode;
  always @(posedge clk) begin
    for (bank_decode = 0; bank_decode < C8_BANKS; bank_decode = bank_decode + 1)
    read_bank_onehot[bank_decode] <= ((shared_ra >> 11) == bank_decode);
  end
  reg [15:0] c8_selected;
  integer bank_merge;
  always @(*) begin
    c8_selected = 16'd0;
    for (bank_merge = 0; bank_merge < C8_BANKS; bank_merge = bank_merge + 1)
    c8_selected = c8_selected | (bank_q[bank_merge] & {16{read_bank_onehot[bank_merge]}});
  end
  assign c8_read_q = c8_selected;
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
    else if (normal_fire || copy_fire) up_x <= (up_x == FRAME_W - 1) ? 0 : up_x + 1'b1;
  end

  // sec_addr is stable throughout a 512-byte transfer. Prepare its
  // successor before completion rather than adding, comparing and
  // selecting a loop address on the sec_addr feedback path.
  reg [31:0] sec_successor_q, payload_start_q;
  reg [31:0] end_previous_q;
  reg end_zero_q;
  // end_sec changes only when a valid header completes. V_REQ/SETTLE
  // provides >20cycles before the first payload request; later sectors
  // use a frame-stable end. The unsigned identity includes both wraps:
  // (sec+1)>=end iff end==0 || (sec!=UINT_MAX && sec>=end-1).
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      end_previous_q <= 32'hffffffff;
      end_zero_q <= 1;
    end else begin
      end_previous_q <= end_sec - 32'd1;
      end_zero_q <= end_sec == 0;
    end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      sec_successor_q <= 0;
      payload_start_q <= 0;
    end else begin
      sec_successor_q <= sec_addr + 32'd1;
      payload_start_q <= base_sec + 32'd1;
    end
  end
  // Count real bytes, not elapsed time while another SD owner is active.
  // A missed completion is recoverable only after all 512 bytes arrived AND
  // the arbiter released ownership. Never fabricate a missing data byte.
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bytes_seen <= 0;
      orphan_timer <= 0;
      read_last <= 0;
    end else begin
      if (!inflight) bytes_seen <= 0;
      else if (sd_sec_read_data_valid_q && bytes_seen < 512) bytes_seen <= bytes_seen + 1'b1;
      if (!inflight || sd_grant_q || sd_sec_read_data_valid_q || sd_sec_read_end_q || bytes_seen != 512)
        orphan_timer <= 0;
      else if (!recovered_end) orphan_timer <= orphan_timer + 1'b1;
      if (!inflight && !sd_sec_read)
        read_last <= (state != V_HDR) && (end_zero_q || (sec_addr!=32'hffffffff && sec_addr>=end_previous_q));
    end
  end

  // Pipeline sector-boundary filtering together with its data. Reserving
  // 32 bytes below FIFO capacity also covers this one-cycle in-flight byte.
  // Stop gates insertion so a canceled session cannot leak a queued byte.
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bf_push <= 0;
      bf_push_data <= 0;
    end else begin
      bf_push <= sd_sec_read_data_valid_q && active && state != V_HDR && byte_in_file && play;
      bf_push_data <= sd_sec_read_data_q;
    end
  end
  // ---------------- BRAM read port (only writes bf_q) ----------------
  video_byte_ram #(
    .AW(BF_AW)
  ) compressed_bytes (
    .clk (clk),
    .we  (bf_push && play && !bf_full && !rst),
    .wa  (bf_wp[BF_AW-1:0]),
    .data(bf_push_data),
    .re  (bf_rdreq),
    .ra  (bf_rp[BF_AW-1:0]),
    .q   (bf_mem_q)
  );
  always @(posedge clk) bf_q <= bf_mem_q;

  // ---------------- single owning always block ----------------
  reg filesystem_failed;
  always @(posedge clk or posedge rst) begin
    if (rst) filesystem_failed <= 0;
    else if (!play) filesystem_failed <= 0;
    else if (sd_error === 1'b1) filesystem_failed <= 1;
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bf_wp               <= {(BF_AW + 1) {1'b0}};
      bf_rp               <= {(BF_AW + 1) {1'b0}};
      bf_rdreq            <= 1'b0;
      bf_pending          <= 0;
      bf_qv               <= 1'b0;
      codec_huffman       <= 0;
      state               <= V_IDLE;
      dstate              <= D_OP;
      fps_inc             <= FPS_INC;
      audio_frame_samples <= 13'd3200;
      deficit             <= ACC_ONE;  // 复位：立刻允许第一帧
      sd_sec_read         <= 1'b0;
      sd_sec_read_addr    <= 32'd0;
      inflight            <= 1'b0;
      base_sec            <= 32'd0;
      end_sec             <= 32'd0;
      sec_addr            <= 32'd0;
      file_bytes          <= 32'd0;
      hdr_idx             <= 5'd0;
      hdr_magic           <= 1'b0;
      codec332            <= 1'b0;
      codec_bad           <= 1'b0;
      codec_block         <= 0;
      codec_up            <= 0;
      codec_approx        <= 0;
      approx_mode         <= 0;
      up_left             <= 0;
      up_phase            <= 0;
      play_d              <= 1'b0;
      wrfin_s0            <= 1'b0;
      wrfin_s1            <= 1'b0;
      wrfin_s2            <= 1'b0;
      wrfin_seen          <= 1'b0;
      settle_cnt          <= 5'd0;
      op_cnt              <= 9'd0;
      bpp_lo              <= 8'd0;
      opcode              <= 8'd0;
      pcnt                <= 0;
      emit_n              <= 8'd0;
      emit_cnt            <= 8'd0;
      emit_val            <= 16'd0;
      arm                 <= 1'b0;
      write_req           <= 1'b0;
      pix_en              <= 1'b0;
      pix_data            <= 32'd0;
      wr_buf_idx          <= 2'd1;
      dp_buf_idx          <= 2'd0;
      active              <= 1'b0;
      disp_ok             <= 1'b0;
      ready_valid <= 0;ready_last <= 0;ready_bank <= 0;
      retired_valid <= 0;retired_bank <= 0;
    end else begin
      // ---- defaults ----
      pix_en <= 1'b0;
      // Release the external level request at the completion handshake
      // edge. Keep inflight until the delayed response is consumed,
      // so no new request can bypass the last pipelined byte.
      if (sd_sec_read_end) sd_sec_read <= 1'b0;
      arm        <= 1'b0;
      bf_rdreq   <= 1'b0;
      bf_pending <= bf_rdreq;
      play_d     <= play;
      wrfin_s0   <= write_finish_toggle;
      wrfin_s1   <= wrfin_s0;
      wrfin_s2   <= wrfin_s1;
      if (wrfin_pulse) wrfin_seen <= 1'b1;

      // ---- byte FIFO push (header sector is parsed inline, never queued) ----
      if (bf_push && play && !bf_full) begin
        bf_wp <= bf_wp + 1'b1;
      end

      // ---- byte fetch: one outstanding request, data valid next cycle ----
      if (bf_rdreq && !bf_empty) bf_rp <= bf_rp + 1'b1;
      if (bf_pending) bf_qv <= 1'b1;

      // One pixel per clock for RUN/LITERAL/BLACK; two for COPY_UP.
      // Accept the bounded two-register codec8 pipeline even when
      // almost_full rises; the existing FIFO reserves 256 words.
      if (use_block_codec && c8_out_valid) begin
        pix_en <= 1;
        pix_data <= {
          {c8_out_rgb[15:11], c8_out_rgb[15:13]},
          {c8_out_rgb[10:5], c8_out_rgb[10:9]},
          {c8_out_rgb[4:0], c8_out_rgb[4:2]},
          8'd0
        };
        pcnt <= pcnt + 1'b1;
      end else if (!LEGACY_CODECS) begin
        // Invalid/short block frames retain the bounded black-padding
        // contract without synthesizing a second token decoder.
        if (state == V_PAD && !pause && !frame_full && !write_almost_full) begin
          pix_en <= 1;
          pix_data <= 0;
          pcnt <= pcnt + 1'b1;
        end
      end else begin
        if (arm) begin
          emit_n <= emit_cnt;
        end else if (up_left != 0) begin
          if (frame_full) begin
            up_left  <= 0;
            up_phase <= 0;
          end else if (!up_phase) up_phase <= 1;
          else if (copy_fire) begin
            pix_en <= 1;
            pix_data <= {up_rgb, 8'd0};
            pcnt <= pcnt + 1'b1;
            up_left <= up_left - 1'b1;
            up_phase <= 0;
          end
        end else if (emit_n != 0) begin
          if (frame_full) emit_n <= 0;
          else if (normal_fire) begin
            pix_en <= 1;
            pix_data <= codec332 ? {v_r3, v_g3, v_b2, 8'd0} : {v_r5, v_g6, v_b5, 8'd0};
            emit_n <= emit_n - 1'b1;
            pcnt <= pcnt + 1'b1;
          end
        end
      end

      // ================= stop / start =================
      if (!play || filesystem_failed || (sd_error === 1'b1)) begin
        // A new playback session starts with one immediate frame credit.
        deficit <= ACC_ONE;
        if (state != V_IDLE) begin
          sd_sec_read <= 1'b0;
          write_req   <= 1'b0;
          inflight    <= 1'b0;
        end
        state   <= V_IDLE;
        dstate  <= D_OP;
        up_left <= 0;
        up_phase <= 0;
        active  <= 1'b0;
        disp_ok <= 1'b0;
        ready_valid <= 0;retired_valid <= 0;
        pcnt    <= 0;
        emit_n  <= 8'd0;
        bf_qv   <= 1'b0;
        bf_pending <= 0;
        bf_wp   <= {(BF_AW+1){1'b0}};
        bf_rp   <= {(BF_AW+1){1'b0}};
      end else begin
        // Retire and accrue presentation credit in one owning process so neither
        // event overwrites the other. Debit first leaves room at saturation.
        if (frame_commit) begin
          deficit <= deficit - (pacing_tick ? (ACC_ONE - pacing_credit) : ACC_ONE);
        end else if (AV_SYNC && !timeline_run_q) begin
          deficit <= disp_ok ? 20'd0 : ACC_ONE;
        end else if (pacing_tick && (!pause || use_audio_clock)) begin
          // 欠帧累加（饱和，避免长时间卡顿后溢出回绕）
          if (deficit > 20'hFFFFF - pacing_credit) deficit <= 20'hFFFFF;
          else deficit <= deficit + pacing_credit;
        end

        if(scanout_event && scanout_bank==dp_buf_idx) retired_valid <= 0;
        if(frame_commit) begin
          dp_buf_idx <= ready_bank;
          disp_ok <= 1'b1;
          ready_valid <= 0;
          retired_bank <= dp_buf_idx;
          retired_valid <= 1;
        end

        // ---- SD sector retire / loop ----
        if (sector_done && inflight) begin
          sd_sec_read <= 1'b0;
          inflight    <= 1'b0;
          if (read_last) sec_addr <= payload_start_q;  // loop: back to payload start
          else sec_addr <= sec_successor_q;
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
                5'd0: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'h46);  // 'F'
                5'd1: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'h50);  // 'P'
                5'd2: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'h47);  // 'G'
                5'd3: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'h56);  // 'V'
                5'd5: begin
                  codec_huffman <= (sd_sec_read_data_q == 8'd14);
                  codec332 <= (sd_sec_read_data_q == 8'd2) || (sd_sec_read_data_q == 8'd5);
                  codec_up <= (sd_sec_read_data_q == 8'd5) ||
                                        (sd_sec_read_data_q == 8'd6) ||
                                        (sd_sec_read_data_q == 8'd7);
                  codec_approx <= (sd_sec_read_data_q == 8'd7);
                  codec_block <= (sd_sec_read_data_q == 8'd8) || (sd_sec_read_data_q == 8'd9) || ((sd_sec_read_data_q == 8'd10) || ((sd_sec_read_data_q == 8'd12) || (sd_sec_read_data_q == 8'd14)));
                  // Codec 3 expands 320x240 in both axes; codec 4 expands 320x480 horizontally.
                  codec_bad <= !((sd_sec_read_data_q == 8'd8) || (sd_sec_read_data_q == 8'd9) ||
                                     ((sd_sec_read_data_q == 8'd10) || ((sd_sec_read_data_q == 8'd12) || (sd_sec_read_data_q == 8'd14))) || (LEGACY_CODECS &&
                                     ((sd_sec_read_data_q == 8'd1) || (sd_sec_read_data_q == 8'd2) ||
                                      (sd_sec_read_data_q == 8'd5) || (sd_sec_read_data_q == 8'd6) ||
                                      (sd_sec_read_data_q == 8'd7))));
                end
                5'd4: hdr_magic <= hdr_magic && (sd_sec_read_data_q == 8'd1);
                5'd6:
                hdr_magic <= hdr_magic && (sd_sec_read_data_q == ((FRAME_PIXELS / FRAME_H) & 255));
                5'd7:
                hdr_magic <= hdr_magic && (sd_sec_read_data_q == ((FRAME_PIXELS / FRAME_H) >> 8));
                5'd8: hdr_magic <= hdr_magic && (sd_sec_read_data_q == (FRAME_H & 255));
                5'd9: hdr_magic <= hdr_magic && (sd_sec_read_data_q == (FRAME_H >> 8));
                // A zero FPS field uses the default rate. Unsupported nonzero rates fail
                // header validation explicitly.
                5'd10: begin
                  case (sd_sec_read_data_q)
                    8'd0, 8'd15: begin
                      fps_inc <= 16'd15000;
                      audio_frame_samples <= 13'd3200;
                    end
                    8'd20: begin
                      fps_inc <= 16'd20000;
                      audio_frame_samples <= 13'd2400;
                    end
                    8'd25: begin
                      fps_inc <= 16'd25000;
                      audio_frame_samples <= 13'd1920;
                    end
                    8'd30: begin
                      fps_inc <= 16'd30000;
                      audio_frame_samples <= 13'd1600;
                    end
                    default: codec_bad <= 1'b1;
                  endcase
                end
                5'd11: if (sd_sec_read_data_q != 0) codec_bad <= 1'b1;
                5'd12: file_bytes[7:0] <= sd_sec_read_data_q;
                5'd13: file_bytes[15:8] <= sd_sec_read_data_q;
                5'd14: file_bytes[23:16] <= sd_sec_read_data_q;
                5'd15: file_bytes[31:24] <= sd_sec_read_data_q;
                // Fixed-table revision guard; legacy headers are unaffected.
                5'd20: if(codec_huffman)hdr_magic<=hdr_magic&&(sd_sec_read_data_q==8'h48);
                5'd21: if(codec_huffman)hdr_magic<=hdr_magic&&(sd_sec_read_data_q==8'h36);
                5'd22: if(codec_huffman)hdr_magic<=hdr_magic&&(sd_sec_read_data_q==8'h44);
                5'd23: if(codec_huffman)hdr_magic<=hdr_magic&&(sd_sec_read_data_q==8'h31);
                default: ;
              endcase
              if (hdr_idx != 5'd31) hdr_idx <= hdr_idx + 5'd1;
            end
            if (sector_done) begin
              if (hdr_magic && !codec_bad && playlist_header_valid && (file_bytes > 32'd512)) begin
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
            // Compressed bytes have their own FIFO. A retired/queued pixel
            // bank may delay decoding, but must not idle read-ahead while
            // that FIFO has sector-sized headroom. Never touch pixel-bank
            // ownership here; stop/EOF/pause and the existing SD handshake
            // remain authoritative. One outstanding sector bounds capacity.
            // Do not issue the first payload from this early state:
            // header-derived end/last-sector registers need their existing
            // SETTLE latency. A ready/displayed frame proves that boundary
            // pipeline is established for subsequent waiting banks.
            if ((disp_ok || ready_valid) && !decode_exhausted && !pause &&
                !inflight && !sd_sec_read && (bf_usedw <= BF_HI)) begin
              sd_sec_read <= 1'b1;
              sd_sec_read_addr <= sec_addr;
              inflight <= 1'b1;
            end
            wrfin_seen <= 1'b0;  // only look at pulses from now on
            // Keep the final displayed buffer intact until its PCM finishes.
            if (decode_exhausted || !write_bank_free) begin
              write_req <= 1'b0;
            end else if (write_req_ack) begin
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
              end else if (LEGACY_CODECS && emit_done) begin
                arm      <= 1'b1;
                emit_cnt <= 8'd1;  // one black pixel
                emit_val <= 16'd0;
              end
            end else if (use_block_codec) begin
              if (bf_qv && c8_ready) bf_qv <= 0;
              else if (!bf_qv && !bf_rdreq && !bf_pending && !bf_empty && c8_ready) bf_rdreq <= 1;
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
                        2'b00: begin
                          opcode <= bf_q;
                          dstate <= D_RUN0;
                        end
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
                        2'b10: begin  // BLACK
                          arm      <= 1'b1;
                          emit_cnt <= tok_cnt;
                          emit_val <= 16'd0;
                          dstate   <= D_RUNW;
                        end
                        default: begin
                          if (bf_q == 8'hFF) state <= frame_full ? V_FIN : V_PAD;
                          else if (codec_approx && bf_q == 8'hFC) begin
                            approx_mode <= 1'b1;
                            dstate <= D_RUN0;
                          end else if (codec_up) begin
                            up_left  <= tok_cnt;
                            up_phase <= 0;
                            dstate   <= D_RUNW;
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
                        dstate <= D_RUN1;
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
                        dstate <= D_LIT1;
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
                      arm         <= 1'b1;
                      emit_val    <= {bf_q, bpp_lo};
                      approx_mode <= 1'b0;
                      dstate      <= D_RUNW;
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

              if (state == V_STRM && pcnt >= FRAME_PIXELS) state <= V_DRAIN;
            end
          end

          // ------------------------------------------------ frame complete
          V_FIN: begin
            // Reuse the existing byte FIFO while this complete frame waits
            // for its display credit. Do not consume/decode the next frame
            // or change audio/presentation timing here. Existing arbiter,
            // exact-LBA mapping and sector-retirement logic still own IO.
            if (!frame_enqueue && !decode_exhausted && !pause &&
                !inflight && !sd_sec_read && (bf_usedw <= BF_HI)) begin
              sd_sec_read <= 1'b1;
              sd_sec_read_addr <= sec_addr;
              inflight <= 1'b1;
            end
            if (frame_enqueue) begin
              wrfin_seen <= 1'b0;
              ready_bank <= wr_buf_idx;
              ready_last <= decode_last;
              ready_valid <= 1'b1;
              wr_buf_idx <= (wr_buf_idx == 2'd2) ? 2'd0 : (wr_buf_idx + 2'd1);
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



