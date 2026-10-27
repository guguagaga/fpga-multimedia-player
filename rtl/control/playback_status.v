//===================================================================
// playback_status : song timing / progress (sd_card_clk domain)
//===================================================================
// Converts the WAV reader's PCM byte counter into OSD-friendly values:
//   tot_sec  = data_size / bytes_per_second
//   cur_sec  = pcm_out_cnt / bytes_per_second
//   progress = pcm_out_cnt * 256 / data_size   (Q8, 0..255)
//
// bytes_per_second = sample_rate * channels * (bit_depth/8).
//
// The three divisions run on a shared 32-cycle serial divider each
// (tot once at wav_ready, cur/progress every ~0.1s). All outputs are
// slow (16-bit seconds / 8-bit progress), so the caller can two-flop
// them into the video_clk domain directly.
//===================================================================
module playback_status (
    input  wire        clk,          // sd_card_clk (100 MHz)
    input  wire        rst,          // active-high
    input  wire        wav_ready,    // header parsed, metadata valid
    input  wire [31:0] pcm_out_cnt,  // PCM bytes already played
    input  wire [31:0] data_size,
    input  wire [31:0] sample_rate,
    input  wire [15:0] channels,
    input  wire [15:0] bit_depth,
    output reg  [15:0] tot_sec,      // total length (seconds)
    output reg  [15:0] cur_sec,      // elapsed (seconds)
    output reg  [7:0]  progress      // Q8 progress 0..255
);

    // bytes_per_second = sample_rate * channels * (bit_depth >> 3)
    // (kept generic; the reader currently only accepts 48kHz/16-bit)
    //
    // 这条链子必须拆成两级流水，不能只寄存在末尾：
    //   实测（引入本模块时的综合报告）"wav_reader/channels -> bps_r" 是
    //   12.98ns / 6 级逻辑，因为 sample_rate(32b) x channels(16b) x
    //   (bit_depth>>3) 两个乘法 + 移位 + 加法全挤在同一个时钟周期里，
    //   100MHz(10ns) 下违例 -3.1ns。
    //   拆法：第一拍只算 (sample_rate * channels)，第二拍再乘
    //   bytes_per_sample。两拍各自只有一个乘法器，路径减半。
    //   代价：bps 晚一拍可用（tot_start/cur_start 本来就有 1~2 拍延迟，
    //   而且这些信号是秒级更新的，完全无影响）。
    wire [15:0] bytes_per_sample = {11'd0, bit_depth[15:3]};   // bit_depth/8，只需移位

    reg [31:0] bps_stage;      // 第一级：sample_rate * channels
    reg [31:0] bps_r;          // 第二级：bps_stage * bytes_per_sample
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bps_stage <= 32'd0;
            bps_r     <= 32'd0;
        end else begin
            bps_stage <= sample_rate * channels;
            bps_r     <= bps_stage * bytes_per_sample;
        end
    end
    wire [31:0] bps      = bps_r;
    wire        bps_nz   = (bps_r != 32'd0);   // 比较面对寄存器，只有 1 级逻辑

    // ---- wav_ready rising edge (metadata latched, run tot_sec once) ----
    reg wav_ready_d;
    always @(posedge clk or posedge rst) begin
        if (rst) wav_ready_d <= 1'b0;
        else     wav_ready_d <= wav_ready;
    end
    wire wav_ready_rise = wav_ready && ~wav_ready_d;

    // ---- periodic update tick (~0.1s @ 100MHz) ----
    reg [23:0] timer;
    reg        update_pulse;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            timer <= 24'd0;
            update_pulse <= 1'b0;
        end else begin
            update_pulse <= 1'b0;
            if (timer == 24'd9_999_999) begin
                timer <= 24'd0;
                update_pulse <= 1'b1;
            end else begin
                timer <= timer + 24'd1;
            end
        end
    end

    // ================= 【面积回收 3 · 2026-10-07】三个除法共用一个 div_u32 =================
    // 原来 tot/cur/prog 各挂一个 div_u32（每个 ~106 FF + ~180 LUT）。它们都是**慢调用**
    // （wav_ready 时一次 / update_pulse 周期一次，最快 ~10Hz），完全没必要三个并行：
    // 用一个仲裁器把请求排队、串行复用同一个除法器。
    //   代价：一个 32 位 3:1 输入选择（~80 LUT）+ 3 个 pending 标志；
    //   收益：省掉 2 个 div_u32（~212 FF + ~360 LUT）。
    // 语义保持：每路请求被锁存到 pending，轮到时才启动；被服务那一拍各自给出
    // `*_done` 单拍脉冲，下游锁存逻辑（tot_sec/cur_sec/progress）一行都不用改。
    reg tot_start, cur_start, prog_start;
    always @(posedge clk or posedge rst) begin
        if (rst) begin tot_start <= 1'b0; cur_start <= 1'b0; prog_start <= 1'b0; end
        else begin
            tot_start  <= wav_ready_rise && bps_nz;
            cur_start  <= update_pulse && wav_ready && bps_nz;
            prog_start <= update_pulse && wav_ready && (data_size != 32'd0);
        end
    end

    reg        pend_tot, pend_cur, pend_prog;
    reg        div_busy;
    reg  [1:0] div_sel;                       // 0=tot 1=cur 2=prog
    wire       any_pend = pend_tot | pend_cur | pend_prog;
    // 优先级：tot（只来一次，最重要）> cur > prog
    wire [1:0] sel_nxt  = pend_tot ? 2'd0 : (pend_cur ? 2'd1 : 2'd2);
    wire       start_nxt = !div_busy && any_pend;

    wire [31:0] div_a = (sel_nxt == 2'd0) ? data_size :
                        (sel_nxt == 2'd1) ? pcm_out_cnt :
                                            {pcm_out_cnt[31:8], 8'b0};
    wire [31:0] div_b = (sel_nxt == 2'd2) ? {8'b0, data_size[31:8]} : bps;

    wire        div_done;
    wire [31:0] div_q;
    div_u32 u_div_shared (
        .clk(clk), .rst_n(~rst),
        .start(start_nxt),
        .dividend(div_a), .divisor(div_b),
        .done(div_done), .quotient(div_q), .remainder()
    );

    reg tot_done, cur_done, prog_done;
    reg [31:0] tot_q, cur_q, prog_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pend_tot <= 1'b0; pend_cur <= 1'b0; pend_prog <= 1'b0;
            div_busy <= 1'b0; div_sel <= 2'd0;
            tot_done <= 1'b0; cur_done <= 1'b0; prog_done <= 1'b0;
            tot_q <= 32'd0; cur_q <= 32'd0; prog_q <= 32'd0;
        end else begin
            tot_done <= 1'b0; cur_done <= 1'b0; prog_done <= 1'b0;
            // 1) 收请求 -> pending
            if (tot_start)  pend_tot  <= 1'b1;
            if (cur_start)  pend_cur  <= 1'b1;
            if (prog_start) pend_prog <= 1'b1;
            // 2) 启动：空闲且有请求
            if (start_nxt) begin
                div_busy <= 1'b1;
                div_sel  <= sel_nxt;
                if (sel_nxt == 2'd0)      pend_tot  <= 1'b0;
                else if (sel_nxt == 2'd1) pend_cur  <= 1'b0;
                else                      pend_prog <= 1'b0;
            end
            // 3) 收结果：按启动时锁定的 sel 分发（防止启动后请求变化导致分错）
            if (div_busy && div_done) begin
                div_busy <= 1'b0;
                case (div_sel)
                    2'd0: begin tot_q  <= div_q; tot_done  <= 1'b1; end
                    2'd1: begin cur_q  <= div_q; cur_done  <= 1'b1; end
                    default: begin prog_q <= div_q; prog_done <= 1'b1; end
                endcase
            end
        end
    end

    // ---- 下游锁存（与原实现逐字一致，只把信号来源换成共享除法器的输出）----
    always @(posedge clk or posedge rst) begin
        if (rst) tot_sec <= 16'd0;
        else if (tot_done) tot_sec <= tot_q[15:0];
    end
    always @(posedge clk or posedge rst) begin
        if (rst) cur_sec <= 16'd0;
        else if (cur_done) cur_sec <= cur_q[15:0];
    end

    // ---- divider 3 的输出锁存（除法器已共享，这里只保留锁存）----
    always @(posedge clk or posedge rst) begin
        if (rst) progress <= 8'd0;
        else if (prog_done) progress <= (prog_q > 32'd255) ? 8'd255 : prog_q[7:0];
    end

endmodule
