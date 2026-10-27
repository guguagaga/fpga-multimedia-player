module media_player_shim (
    input  wire        clk,
    input  wire        rst,
    input  wire        scan_start,
    input  wire [31:0] scan_start_sector,
    input  wire [31:0] scan_max_sector,
    input  wire        sd_init_done,
    input  wire        sd_error,
    output wire[31:0] file_base_lba,
    output wire        wav_ready,
    output wire        dbg_pcm_start_odd,
    output wire [31:0] dbg_pcm_sum32,
    output wire [31:0] dbg_pcm_n32,
    output wire [31:0] sample_rate,
    output wire [15:0] channels,
    output wire [15:0] bit_depth,
    output wire [31:0] data_size,
    output wire [31:0] pcm_out_cnt,
    output wire        sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end,
    input  wire        fifo_almost_full,
    input wire fifo_drained, sd_grant,
    input  wire        pause,
    input  wire        seek,
    input  wire [31:0] step_bytes,
    input  wire        track_sel,
    input  wire [31:0] track_sel_sector,
    output wire        track_end,
    output wire        track_bad,
    output wire        pcm_valid,
    output wire [7:0]  pcm_data,
    output wire [2:0]  dbg_state,
    output wire        dbg_gate_open,   // 【2026-10-22】透传内部 gate_open
    output wire [7:0]  dbg_fp,
    output wire        dbg_silent_hit,
    output wire        dbg_posbad_hit,
    output wire        dbg_seek_data_ok,
    output wire        dbg_wp_pcm_seen,
    output wire        dbg_wp_pcm_recent,
    output wire        dbg_wp_gate_stuck,
    output wire        dbg_hdr_phase,
    output wire [1:0]  dbg_fbcnt_frz,
    output wire        dbg_seek_drain,
    output wire        dbg_resync_pulse
);

    // 内部 media_player 的观测输出（只连 dbg_state 的有效 3 位）
    wire [3:0] core_dbg_state;
media_player #(.LOOP_ON_EOF(1'b0)) u_core (
        .clk                   (clk),
        
        .rst                   (rst),
        .scan_start            (scan_start),
        .scan_start_sector     (scan_start_sector),
        .scan_max_sector       (scan_max_sector),
        .sd_init_done          (sd_init_done),
        .sd_error              (sd_error),
        .track_sel             (track_sel),
        .track_sel_sector      (track_sel_sector),
        .wav_ready             (wav_ready),
        .file_base_lba(file_base_lba),
        .sample_rate           (sample_rate),
        .channels              (channels),
        .bit_depth             (bit_depth),
        .data_size             (data_size),
        .pcm_out_cnt           (pcm_out_cnt),
        .sd_sec_read           (sd_sec_read),
        .sd_sec_read_addr      (sd_sec_read_addr),
        .sd_sec_read_data      (sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end       (sd_sec_read_end),
        .fifo_almost_full      (fifo_almost_full),
        .fifo_drained(fifo_drained), .sd_grant(sd_grant),
        .pause                 (pause),
        .seek                  (seek),
        .step_bytes            (step_bytes),
        .track_end             (track_end),
        .track_bad             (track_bad),
        .pcm_valid             (pcm_valid),
        .pcm_data              (pcm_data),
        .dbg_state             (core_dbg_state),
        .dbg_gate_open         (dbg_gate_open)
    );

    // ★真实观测：只保留设计真正提供的那一位★
    assign dbg_state = core_dbg_state[2:0];

    // ★★以下均为【常量桩】—— 不是真实观测（旧 reader 的探针，本设计不再提供）★★
    //   用寄存器驱动，复位后恒定（避免未寄存/悬空 ✓）
    assign dbg_pcm_start_odd = 1'b0;
    assign dbg_pcm_sum32     = 32'd0;
    assign dbg_pcm_n32       = 32'd0;
    assign dbg_fp            = 8'd0;
    assign dbg_silent_hit    = 1'b0;
    assign dbg_posbad_hit    = 1'b0;
    assign dbg_fbcnt_frz     = 2'd0;

    assign dbg_seek_data_ok  = 1'b0;
    assign dbg_wp_pcm_seen   = 1'b0;
    assign dbg_wp_pcm_recent = 1'b0;
    assign dbg_wp_gate_stuck = 1'b0;
    assign dbg_hdr_phase     = 1'b0;
    assign dbg_seek_drain    = 1'b0;
    assign dbg_resync_pulse  = 1'b0;

endmodule
