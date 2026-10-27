//===================================================================
// 256-point Radix-2 DIT FFT (single-butterfly time-multiplexed)
//   -- synchronous-RAM (BRAM) version, 5-cycle butterfly
//===================================================================
// Architecture: 1 butterfly unit + 2 true dual-port RAMs (real/imag)
//               + 1 twiddle factor ROM, time-multiplexed by a state
//               machine to run 8 stages x 128 = 1024 butterflies.
//
// Flow:
//   1) S_LOAD : load 256 time-domain samples (write at bit-reversed addr)
//   2) S_BFLY : 8 butterfly stages, 128 per stage, 5 cycles each
//               (read addr -> data valid + butterfly -> butterfly out
//                -> write back)
//   3) S_OUT  : read out 256 frequency bins in natural order
//
// RAM is synchronous-read (BRAM), so a butterfly now takes 5 cycles:
//   sub_cnt 0: present read addr (RAM latches data)
//   sub_cnt 1: data valid -> butterfly samples (din_valid)
//   sub_cnt 2: second pair of real products
//   sub_cnt 3: scaled butterfly outputs; sub_cnt 4: write back
//
// Key: butterfly internally scales by 1/2 before narrowing per stage,
//      8 stages = total scale 256, to prevent overflow.
//===================================================================
module fft_256 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,          // start pulse (high 1 cycle)
    input  wire [15:0] din_re,         // time-domain sample real
    input  wire [15:0] din_im,         // time-domain sample imag (0 for real signal)
    output reg         busy,           // computing
    output reg         done,           // done (high 1 cycle)
    output reg  [15:0] dout_re,        // frequency bin real
    output reg  [15:0] dout_im,        // frequency bin imag
    output reg         dout_valid      // output valid (continuous 256 cycles)
);

    // ---------- state ----------
    localparam S_IDLE = 3'd0, S_LOAD = 3'd1, S_BFLY = 3'd2,
               S_OUT  = 3'd3, S_DONE = 3'd4;
    reg [2:0] state;

    // ---------- counters ----------
    reg [7:0] load_cnt;    // load counter 0..255
    reg [2:0] stage;       // butterfly stage 0..7
    reg [6:0] bfly_cnt;    // butterfly index within stage 0..127
    reg [2:0] sub_cnt;     // butterfly sub-cycle 0..4
    reg [8:0] out_cnt;     // output counter 0..256

    // ---------- address generation (combinational, core algorithm) ----------
    wire [7:0] d    = 8'd1 << stage;                    // stride = 2^stage
    wire [7:0] d_m1 = d - 8'd1;
    wire [6:0] k    = bfly_cnt & d_m1[6:0];             // index within group
    wire [6:0] g    = bfly_cnt >> stage;                // group number
    wire [7:0] g2   = {1'b0, g} << (stage + 3'd1);      // g * 2d
    wire [7:0] addr_a = g2 | {1'b0, k};                 // butterfly input A address
    wire [7:0] addr_b = addr_a | d;                     // butterfly input B address = A + d
    wire [6:0] twiddle_idx = k << (3'd7 - stage);       // twiddle factor index

    // ---------- bit-reverse function ----------
    function [7:0] bit_reverse;
        input [7:0] a;
        integer i;
        begin
            bit_reverse = 8'd0;
            for (i = 0; i < 8; i = i + 1)
                bit_reverse[i] = a[7-i];
        end
    endfunction

    // ---------- RAM control (combinational) ----------
    reg [7:0] ram_a_addr, ram_b_addr;
    reg       ram_a_we, ram_b_we;

    always @(*) begin
        ram_a_addr = addr_a;       // default: butterfly read A
        ram_b_addr = addr_b;       // default: butterfly read B
        ram_a_we   = 1'b0;
        ram_b_we   = 1'b0;
        if (state == S_LOAD) begin                 // load: write bit-reversed addr
            ram_a_addr = bit_reverse(load_cnt);
            ram_a_we   = 1'b1;
            ram_b_addr = 8'd0;
        end
        else if (state == S_BFLY && sub_cnt == 3'd4) begin  // butterfly write-back
            ram_a_addr = addr_a;
            ram_b_addr = addr_b;
            ram_a_we   = 1'b1;
            ram_b_we   = 1'b1;
        end
        else if (state == S_OUT) begin             // output: read natural order
            ram_a_addr = out_cnt[7:0];
            ram_b_addr = 8'd0;
        end
    end

    // ---------- butterfly unit ----------
    // data valid on sub_cnt==1 (synchronous RAM read latency = 1)
    wire bf_din_valid = (state == S_BFLY) && (sub_cnt == 2'd1);
    wire signed [15:0] bf_y0_re, bf_y0_im, bf_y1_re, bf_y1_im;

    // ==================================================================
    // ★★2026-10-10 修复（真功能缺陷：先用后声明 ⇒ 隐式 1 位 ⇒ 宽输入被截断）★★
    //   【TD 原文】HDL-7225 CRITICAL-WARNING: 'tw_re' is already implicitly
    //     declared on line 108 in fft_256.v(115)
    //   【根因】下面 `butterfly u_bf` 在【第 106~108 行】就引用了
    //     `ram_a_dout_re/im`、`ram_b_dout_re/im`、`tw_re`、`tw_im`，
    //     而它们的 `wire [15:0]` 真声明原本在【第 115 行 / 第 138 行】✗
    //     ⇒ Verilog 对"尚未声明的名字"建【隐式 1 位线网】
    //     ⇒ ★连接只取 bit 0、其余 15 位被补 0 丢弃★ ✗
    //   【后果】`butterfly.v` 的 `x0_re/x0_im/x1_re/x1_im/w_re/w_im` 都是 16 位，
    //     却只连到 bit 0 ⇒ ★蝶形运算输入实际只有最低位 ⇒ FFT 结果不可能正确★ ✗
    //   【修法】★把这两个声明【上移到 u_bf 实例之前】★（不动任何逻辑 ✓）
    //     ⇒ 6 条 HDL-7225 应全部消失 ⇒ 蝶形输入恢复 16 位连通 ✓
    //   ★注★：`dp_ram` 的两个实例在【声明之后】，那两处连接本来就是好的 ✓；
    //          被截断的只有【引到 u_bf 的这 6 个 tap】✓
    // ==================================================================
    wire [15:0] tw_re, tw_im;
    wire [15:0] ram_a_dout_re, ram_a_dout_im, ram_b_dout_re, ram_b_dout_im;
    // ★2026-10-10 修复（纯声明缺失）：`bf_dout_valid` 是 butterfly 的输出连接，
    //   原文只在此处出现一次、此后再未被读 ⇒ 隐式 1 位网。
    //   两个独立工具都报：
    //     · ModelSim: Warning vlog-2623 (Undefined variable) 于 fft_256.v(128)
    //     · TD      : HDL-1007 "undeclared symbol 'bf_dout_valid', assumed default net type 'wire'" (128)
    //   ⇒ 零功能影响（该网从未被读到），但补上声明即为"声明卫生" ✓
    //   ★注★：这是本文件同类问题的【第 7 处】—— 前 6 处（`tw_re/tw_im`、
    //          `ram_a_dout_*`、`ram_b_dout_*`）此前已修，这一处当时漏了 ✓（如实登记）
    wire bf_dout_valid;

    butterfly u_bf (
        .clk        (clk),
        .rst_n      (rst_n),
        .din_valid  (bf_din_valid),
        .x0_re      (ram_a_dout_re), .x0_im (ram_a_dout_im),
        .x1_re      (ram_b_dout_re), .x1_im (ram_b_dout_im),
        .w_re       (tw_re),         .w_im  (tw_im),
        .dout_valid (bf_dout_valid),
        .y0_re      (bf_y0_re), .y0_im (bf_y0_im),
        .y1_re      (bf_y1_re), .y1_im (bf_y1_im)
    );

    // ---------- twiddle factor ROM (synchronous read) ----------
    // (wire [15:0] tw_re, tw_im; -- ★moved above u_bf★ 2026-10-10)
    twiddle_rom u_tw (.clk(clk), .addr(twiddle_idx), .re(tw_re), .im(tw_im));

    // butterfly scales guarded sums before narrowing. No second divide here.
    wire [15:0] ram_a_din_re = (state == S_LOAD) ? din_re : bf_y0_re;
    wire [15:0] ram_a_din_im = (state == S_LOAD) ? din_im : bf_y0_im;
    wire [15:0] ram_b_din_re = bf_y1_re;
    wire [15:0] ram_b_din_im = bf_y1_im;

    // ---------- dual-port RAM (one for real, one for imag) ----------
    // (wire [15:0] ram_a_dout_re/im, ram_b_dout_re/im; -- ★moved above u_bf★ 2026-10-10)

    dp_ram u_re_ram (
        .clk(clk), .wea(ram_a_we), .webb(ram_b_we),
        .addra(ram_a_addr), .addrb(ram_b_addr),
        .dina(ram_a_din_re), .dinb(ram_b_din_re),
        .douta(ram_a_dout_re), .doutb(ram_b_dout_re)
    );
    dp_ram u_im_ram (
        .clk(clk), .wea(ram_a_we), .webb(ram_b_we),
        .addra(ram_a_addr), .addrb(ram_b_addr),
        .dina(ram_a_din_im), .dinb(ram_b_din_im),
        .douta(ram_a_dout_im), .doutb(ram_b_dout_im)
    );

    // ---------- main state machine ----------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            load_cnt  <= 8'd0;
            stage     <= 3'd0;
            bfly_cnt  <= 7'd0;
            sub_cnt   <= 2'd0;
            out_cnt   <= 9'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            dout_valid<= 1'b0;
            dout_re   <= 16'd0;
            dout_im   <= 16'd0;
        end else begin
            done <= 1'b0;
            case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    state    <= S_LOAD;
                    load_cnt <= 8'd0;
                    busy     <= 1'b1;
                end
            end
            S_LOAD: begin
                load_cnt <= load_cnt + 8'd1;
                if (load_cnt == 8'd255) begin
                    state    <= S_BFLY;
                    stage    <= 3'd0;
                    bfly_cnt <= 7'd0;
                    sub_cnt  <= 2'd0;
                end
            end
            S_BFLY: begin
                case (sub_cnt)
                2'd0: sub_cnt <= 2'd1;   // present read addr (RAM latches data)
                2'd1: sub_cnt <= 2'd2;   // data valid -> butterfly samples
                3'd2: sub_cnt <= 3'd3;
                3'd3: sub_cnt <= 3'd4;   // butterfly outputs Y0/Y1
                3'd4: begin              // write back + next butterfly
                    sub_cnt <= 2'd0;
                    if (bfly_cnt == 7'd127) begin
                        if (stage == 3'd7) begin
                            state   <= S_OUT;
                            out_cnt <= 9'd0;
                        end else begin
                            stage    <= stage + 3'd1;
                            bfly_cnt <= 7'd0;
                        end
                    end else begin
                        bfly_cnt <= bfly_cnt + 7'd1;
                    end
                end
                endcase
            end
            S_OUT: begin
                // synchronous RAM read: addr=out_cnt, data valid next cycle.
                // First cycle (out_cnt=0) is the read latency; data streams
                // out from cycle 1 onward, so dout_valid gates cycle 0 off.
                dout_re    <= ram_a_dout_re;
                dout_im    <= ram_a_dout_im;
                dout_valid <= (out_cnt >= 9'd1) && (out_cnt <= 9'd256);
                if (out_cnt == 9'd256)
                    state <= S_DONE;
                else
                    out_cnt <= out_cnt + 9'd1;
            end
            S_DONE: begin
                done       <= 1'b1;
                dout_valid <= 1'b0;
                busy       <= 1'b0;
                state      <= S_IDLE;
            end
            endcase
        end
    end

endmodule
