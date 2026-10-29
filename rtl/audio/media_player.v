module media_player #(
  parameter [31:0] BLIND_SCAN_LIMIT = 32'd4096,
  parameter [23:0] SEEK_DRAIN_WD = 24'd10_000_000,
  parameter [23:0] HDR_WD = 24'd10_000_000,
  parameter [3:0] BUS_SETTLE = 4'd2,
  parameter LOOP_ON_EOF = 1'b1
) (
  input wire clk, rst,
  input wire scan_start,
  input wire [31:0] scan_start_sector, scan_max_sector,
  input wire sd_init_done, track_sel,
  input wire sd_error,
  input wire [31:0] track_sel_sector,
  output wire [31:0] file_base_lba,
  output reg wav_ready,
  output reg [31:0] sample_rate,
  output reg [15:0] channels, bit_depth,
  output reg [31:0] data_size, pcm_out_cnt,
  output wire sd_sec_read,
  output wire [31:0] sd_sec_read_addr,
  input wire [7:0] sd_sec_read_data,
  input wire sd_sec_read_data_valid, sd_sec_read_end,
  input wire fifo_almost_full, pause, seek,
  input wire [31:0] step_bytes,
  // Synchronized from the audio domain; both FIFO and sample builder idle.
  input wire fifo_drained,
  // Sector ownership, so time spent waiting for another client is excluded.
  input wire sd_grant,
  output reg track_end, track_bad, pcm_valid,
  output reg [7:0] pcm_data,
  output wire [3:0] dbg_state,
  output wire dbg_gate_open
);
  localparam IDLE = 0, DRAIN = 1, PROBE = 2, COMPRESSED = 4;
  reg [2:0] mode;
  reg select_q, scan_q, start_reader;
  reg [31:0] pending_sector;
  // The reader's committed sector stays stable until its old request drains.
  // Reuse that existing register instead of duplicating the file identity.
  wire comp_ready, comp_stereo, comp_end, comp_bad, comp_valid, comp_idle;
  wire [31:0] comp_size, comp_count;
  wire [7:0] comp_data;
  wire [3:0] comp_state;
  wire [3:0] old_state = 0;  // reference-only probe, never part of control
  wire comp_halt = (mode != PROBE && mode != COMPRESSED);
  always @(*) begin
    wav_ready = (mode == COMPRESSED) && comp_ready;
    sample_rate = 48000;
    channels = comp_stereo ? 16'd2 : 16'd1;
    bit_depth = 16;
    data_size = comp_size;
    pcm_out_cnt = comp_count;
    track_end = (mode == COMPRESSED) && comp_end;
    track_bad = (mode == PROBE || mode == COMPRESSED) && (comp_bad || (sd_error === 1'b1));
    pcm_valid = comp_valid;
    pcm_data = comp_data;
  end
  assign dbg_state = comp_state;
  assign dbg_gate_open = comp_valid;
  compressed_audio_reader compressed (
    .clk             (clk),
    .rst             (rst || !sd_init_done),
    .start           (start_reader),
    .halt            (comp_halt),
    .pause           (pause),
    .seek            (seek && mode == COMPRESSED),
    .fifo_drained    (fifo_drained),
    .sector          (pending_sector),
    .file_base_lba   (file_base_lba),
    .fifo_almost_full(fifo_almost_full),
    .pcm_fallback    (),
    .wav_ready       (comp_ready),
    .stereo          (comp_stereo),
    .data_size       (comp_size),
    .pcm_out_cnt     (comp_count),
    .sd_req          (sd_sec_read),
    .sd_addr         (sd_sec_read_addr),
    .sd_data         (sd_sec_read_data),
    .sd_valid        (sd_sec_read_data_valid),
    .sd_end          (sd_sec_read_end),
    .sd_grant        (sd_grant),
    .track_end       (comp_end),
    .track_bad       (comp_bad),
    .pcm_valid       (comp_valid),
    .pcm_data        (comp_data),
    .idle            (comp_idle),
    .dbg_state       (comp_state)
  );
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      mode <= IDLE;
      select_q <= 0;
      scan_q <= 0;
      pending_sector <= 0;
      start_reader <= 0;
    end else if (!sd_init_done) begin
      mode <= IDLE;
      select_q <= 0;
      scan_q <= 0;
      start_reader <= 0;
    end else begin
      select_q <= track_sel;
      scan_q <= scan_start;
      start_reader <= 0;
      case (mode)
        DRAIN:
        if (comp_idle && fifo_drained) begin
          start_reader <= 1;
          mode <= PROBE;
        end
        PROBE: if (!start_reader && comp_ready) mode <= COMPRESSED;
        COMPRESSED: if (comp_end && LOOP_ON_EOF) mode <= DRAIN;
      endcase
      if (select_q || scan_q) begin
        mode <= DRAIN;
        pending_sector <= select_q ? track_sel_sector : scan_start_sector;
      end
      if (sd_error === 1'b1) begin
        mode <= IDLE;
        start_reader <= 0;
      end
    end
  end
endmodule
