//===================================================================
// wav_sample_builder : FIFO bytes -> 24-bit samples (audio clock domain)
//===================================================================
// Runs in the audio clock domain (12.288 MHz). On every sample_req pulse
// (48 kHz, driven by i2s_transmitter) it reads one sample pair from the
// async FIFO and produces 24-bit left/right samples (16-bit << 8).
//
//   stereo = 0 (mono)  : reads 2 bytes (1 sample), same value on L and R
//   stereo = 1 (stereo): reads 4 bytes (L then R), L/R from their own
//                        little-endian 16-bit samples
//
// `stereo` is a run-time input (the WAV channel count is only known after
// the header is parsed), so it is driven from the CDC-synced channels value.
//
// 【与 async_fifo 的**寄存器读**配套】
//   async_fifo 的 rd_data 现在是寄存器输出：REQ 拍拉高 rd_en，**下一拍**
//   才拿到该字节。所以每个字节拆成两拍：
//       S_REQ_x : fifo_rd_en = !fifo_empty（空则按住不拉，等有数据）
//       S_GET_x : 取 fifo_rd_data（此时已是请求的那个字节）
//   一次立体声样本对 = 4 字节 = 8 拍；而一帧有 256 拍，余量充足。
//
//   为什么要 !fifo_empty 才拉 rd_en：启动阶段 WAV 头部还没解析完、FIFO 是
//   空的；此时读 mem[] 会锁到未写过的垃圾，放出一串噪声。
//
//   （旧版是组合读，rd_en 与 rd_data 同拍。改寄存器读后必须这样配套；
//     早前 3 次失败的写法与根因分析见 async_fifo.v 顶部注释。）
//===================================================================
module wav_sample_builder (
    input  wire        clk,           // audio clock 12.288 MHz
    input  wire        rst,           // active-high reset
    input  wire        sample_req,    // pulse: request next sample pair (48 kHz)
    input  wire        stereo,        // 1 = 2 channels, 0 = 1 channel
    // async FIFO read interface (registered rd_data: one cycle after rd_en)
    output wire        fifo_rd_en,
    input  wire [7:0]  fifo_rd_data,
    input  wire        fifo_empty,
    // sample output (24-bit)
    output reg         sample_valid,  // 1-cycle pulse when sample updates
    output reg  [23:0] sample_left,
    output reg  [23:0] sample_right,
    output wire        stream_idle,
    // ==== 【2026-10-09 #fix12-probe】消费端只读探针（只驱动显示 ✓ 不进功能表达式 ✓）====
    //   dbg_st       : 当前 4 状态机状态码（看它卡在哪个状态）
    //   dbg_req_drop : ★sample_req 在【非 IDLE】时到达 => 该请求被丢弃★（粘滞位）
    //     （这是 C2：`S_IDLE: if (sample_req)` —— 停在 REQ/GET 时到来的请求会被丢掉 ✗）
    output wire [3:0]  dbg_st,
    output reg         dbg_req_drop,
    // 【#fix14-probe】★不粘滞★版：最近 ~5ms 内是否【仍在丢请求】（电平/充电窗 ✓）
    //   粘滞位只能说明"曾经丢过"✗；这一位才能回答"现在还在丢吗"✓
    output wire        dbg_req_drop_recent,
    //=== [CHG 2026-10-09 #fix21-latgrades] ==================================
    // ★把板级"ack 延迟 ≥512 拍"拆开★（只读 ✓）
    //   lat_req_to_rden  : 从 req 上升到本模块首次拉 rd_en 的拍数档（0<8｜1=8~64｜2=64~512｜3≥512）
    //   lat_rden_to_valid: 从该 rd_en 到 sample_valid 的拍数档（同上分档 ✓）
    //   req_seen_hi      : req_seen 当前电平（1 = 本窗口已收过一次 ⇒ 若长期为 1 ✗ 即"卡住"）
    //   用途：判定 ≥512 拍是【等 FIFO】还是【req_seen 卡住】✗（父 agent 的①②③ ✓）
    //   影响：只读 ✓ 不进功能表达式 ✓
    //========================================================================
    output wire [1:0]  dbg_lat_req2rden,
    output wire [1:0]  dbg_lat_rden2v,
    output wire        dbg_req_seen_hi,
    //=== [CHG 2026-10-09 #fix23-dwell] ======================================
    // ★决定性探针★：板级组6 读数 = 段1档3（req→首次 rd_en ≥512 ✗）+ 段2档0
    //   代码结构：`fifo_rd_en = (REQ 状态) && !fifo_empty` ✗
    //   => 若【读侧 empty 恒为高】⇒ rd_en 永不拉高 ⇒ 卡在 S_REQ_LO ⇒ 段1 无上限 ✗
    //   这正是"写侧近满（wr_usedw 大 ✓）而读侧认为空（empty=1 ✗）"的经典矛盾 ✓✓
    // 本组探针：
    //   dwell_state : 当前停留最久的【状态码】（驻留拍数最大者 ✓）
    //   dwell_grade : 该状态的驻留拍数档（0<8｜1=8~64｜2=64~512｜3≥512 ✓）
    //   empty_stuck : empty 曾连续 >512 拍为 1（= 读侧"一直认为空" ✗✓）
    output wire [3:0]  dbg_dwell_state,
    output wire [1:0]  dbg_dwell_grade,
    output reg         dbg_empty_stuck,
    //=== [CHG 2026-10-09 #fix31-g14] ========================================
    // ★组14：用【冻结探测器】把"读数据恒定"定位到最细（活电平型 ✓ 非粘滞 ✓）
    //   为什么用"冻结年龄"而不是"窗口计数"：年龄是【电平型】✓ ⇒ 任何时刻都能读 ✓
    //      好态：刚变过 ⇒ 年龄很小 ⇒ 档 0 ✓；★坏态：长时间不变 ⇒ 年龄饱和 ⇒ 档 3✗✓✓★
    //   口径：档 0=<256 拍 ｜ 1=<4096 ｜ 2=<65536 ｜ ★3=≥65536（≈0.65ms@100MHz 没变过）✗★
    //   影响：只读 ✓ 不进功能表达式 ✓
    //========================================================================
    output reg  [1:0]  dbg_rddata_frz,   // ★fifo_rd_data 的冻结档（0 ⇒ 在读新数据 ✓；3 ⇒ 恒定 ✗✓）★
    output reg  [1:0]  dbg_bytelo_frz,   // byte_lo 的冻结档
    output reg  [1:0]  dbg_rden_frz,     // ★fifo_rd_en 的冻结档（3 ⇒ rd_en 停脉冲 ✗✓）★
    output reg  [11:0] dbg_rddata_chg,   // fifo_rd_data 变化次数（累计低 12 位 ✓ 供人工核对）✓
    //=== [CHG 2026-10-09 #fix19-probe] =======================================
    // 改动：新增只读探针 dbg_pair_bad（粘滞）
    // 原因：(b) 端到端数据指纹的【非平凡版本】：本模块每消费 1 字节就 +1，
    //       而每个 sample_valid 必须出现在【偶数】个消费字节之后 ✓
    //       ⇒ 若 FIFO/CDC 丢了 1 字节、或多/少读 1 字节 ⇒ 奇偶错 ⇒ 高低字节互换 ⇒ 全杂音 ✗✓
    //       （纯粹的"滚动指纹两端比对"对 FIFO 是【同义反复】✗ —— 比的是自己延迟后的副本 ✗；
    //         真正的数据完整性已由 async_fifo_tb 用计数图案证明 503/0 ✓；
    //         这里做的是能真正报错的"配对奇偶"检查 ✓）
    // 证据：TB wav_fp_tb：正常 = 0 ✓；注入丢 1 字节 / 错位 ⇒ 必须置 1 ✓
    // 影响：只驱动显示 ✓ 不进功能表达式 ✓
    //========================================================================
    output wire        dbg_pair_bad,   // 恒 0（本检查无意义 ✗，见下方说明）
    // 【#fix15-probe】★修正语义★：上面"sample_req 高且非 IDLE"在握手之后属于【正常】✗
    //   （请求方会一直举着直到 ack ✓）=> 它会把正常握手报成"丢请求" ✗（板级已误报 DIG2=6 ✗）
    //   真正的"丢"= ★请求被撤下但没有 ack★ ⇒ 下面这一位才是真的 ✗
    output reg         dbg_req_lost,       // 粘滞：曾经有请求被撤但没 ack ✗
    output wire        dbg_req_lost_now,   // 电平：最近 5ms 内还在丢 ✗
    output wire [1:0]  dbg_ack_lat         // ack 延迟档：0=<8拍 1=8~64 2=64~512 3=≥512
);

    // REQ 拍 / GET 拍交替：REQ 拉 rd_en，GET 取数
    localparam [3:0] S_IDLE    = 4'd0,
                     S_REQ_LO  = 4'd1, S_GET_LO  = 4'd2,   // L 低字节
                     S_REQ_HI  = 4'd3, S_GET_HI  = 4'd4,   // L 高字节
                     S_REQ_RLO = 4'd5, S_GET_RLO = 4'd6,   // R 低字节
                     S_REQ_RHI = 4'd7, S_GET_RHI = 4'd8;   // R 高字节

    reg [3:0] st;
    assign stream_idle = (st == S_IDLE);
    //=== [CHG 2026-10-09 #fix13-handshake] =====================================
    // 改动：把"请求只在 IDLE 被接受"改成"请求被【锁存】"——
    //       sample_req 在任何状态到来都置 req_pending，回到 IDLE 立即处理并清掉 ✓
    // 原因：板级读数（消费端组）DIG2 = 2 ⇒ bit1=1 ⇒ ★sample_req 在非 IDLE 时到达被丢弃★ ✗
    //       ⇒ 构造器少取/不取 ⇒ FIFO 无人搬走 ⇒ FIFO 近满（DIG1=3 ✗）
    //       ⇒ 而 i2s 在帧边界【盲锁存】上一帧 ⇒ 反复播同一帧 = 全杂音 / 极端时无声 ✓
    // 为什么选"构造器锁存"(B) 而不是"请求方保持"(A)：
    //   A 要保证 exactly-once 就必须有 ack；最自然的 ack 是 sample_valid，
    //   但构造器在发 sample_valid 的同一拍就回到 IDLE ⇒ 下一拍若 req 仍为高会【再次触发】
    //   ⇒ 一帧取两个样本 = 2 倍速 ✗（有竞争 ✗）。B 无此竞争，且同样满足"不丢请求" ✓
    // 证据：TB wav_sb_req_tb（新增）—— 构造器忙的时候到达的请求
    //       修复前：请求被丢 => 处理数 < 请求数 => FAIL ✗
    //       修复后：每个请求都被处理一次 => PASS ✓
    // 影响：只改"何时启动一次取样"；取数时序、字节配对、stereo 分支一字未动 ✓
    //============================================================================
    reg        req_seen;      // 1 = 本个 sample_req 高电平窗口已被接受过
    reg [7:0] byte_lo;    // low byte of the current sample

    // 只在 REQ 拍拉 rd_en；FIFO 空则不拉（既不前进 rd_ptr，也不换 rd_data）。
    // fifo_empty 是 async_fifo 用当前 rd_ptr 组合译码出来的，同拍判断是安全的。
    assign fifo_rd_en = ((st == S_REQ_LO ) || (st == S_REQ_HI ) ||
                         (st == S_REQ_RLO) || (st == S_REQ_RHI)) && !fifo_empty;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st           <= S_IDLE;
            req_seen     <= 1'b0;
            byte_lo      <= 8'd0;
            sample_valid <= 1'b0;
            sample_left  <= 24'd0;
            sample_right <= 24'd0;
        end else begin
            sample_valid <= 1'b0;

            // 【#fix13 完整握手】请求方（i2s）会把 sample_req 【保持到本模块给出 sample_valid】✓
            //   本模块对"一次 req 高电平窗口"只接受【一次】（req_seen 记着 ✓）
            //   => 既不丢请求（请求方保持 ✓），也不会一帧取两次（req_seen 挡住 ✓）
            if (!sample_req) req_seen <= 1'b0;      // req 拉低 => 本窗口结束，允许下一次

            case (st)
                S_IDLE: begin
                    if (sample_req && !req_seen && !fifo_empty) begin
                        st       <= S_REQ_LO;
                        req_seen <= 1'b1;           // 本窗口已被接受
                    end
                end

                // 请求 L 低字节；空则原地等
                S_REQ_LO: if (!fifo_empty) st <= S_GET_LO;
                // 取 L 低字节
                S_GET_LO: begin
                    byte_lo <= fifo_rd_data;
                    st      <= S_REQ_HI;
                end

                // 请求 L 高字节
                S_REQ_HI: if (!fifo_empty) st <= S_GET_HI;
                // 取 L 高字节：立体声则继续取 R，单声道则左右同值收工
                S_GET_HI: begin
                    if (stereo) begin
                        sample_left <= {fifo_rd_data, byte_lo, 8'd0};
                        st          <= S_REQ_RLO;
                    end else begin
                        sample_left  <= {fifo_rd_data, byte_lo, 8'd0};
                        sample_right <= {fifo_rd_data, byte_lo, 8'd0};
                        sample_valid <= 1'b1;
                        st           <= S_IDLE;
                    end
                end

                // 请求 R 低字节
                S_REQ_RLO: if (!fifo_empty) st <= S_GET_RLO;
                S_GET_RLO: begin
                    byte_lo <= fifo_rd_data;
                    st      <= S_REQ_RHI;
                end

                // 请求 R 高字节
                S_REQ_RHI: if (!fifo_empty) st <= S_GET_RHI;
                // 取 R 高字节：收工
                S_GET_RHI: begin
                    sample_right <= {fifo_rd_data, byte_lo, 8'd0};
                    sample_valid <= 1'b1;
                    st           <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    //=== [CHG 2026-10-09 #fix12-probe] =========================================
    // 改动：新增两个只读观测口 dbg_st（4 状态机状态码）/ dbg_req_drop（sample_req 被丢粘滞位）
    // 原因：板级读数 fix11 写侧组 = 2 3 0 3 3 1 => **FIFO 接近满** ✗ + 门控正常 ✓ + 状态正常 ✓
    //       => 生产端一直在正常送数据，是【消费端没取走】✗ => 必须看构造器卡在哪
    // 证据：板级（上式）；TB 侧构造器一直是 IDLE 主导、无请求被丢 ⇒ 模型复现不出 ✗
    // 影响：只驱动显示（assign + 一个粘滞位）✓ 不进 pcm/rd_en 等功能表达式 ✓
    // 相关：见 CHANGELOG_源码改动登记.md 的同编号条目
    //============================================================================
    // ---- 【#fix12-probe】消费端观测（只读；本块只写 dbg_req_drop ✓ 单块驱动 ✓）----
    assign dbg_st = st;                       // 只读镜像，不新增逻辑
    always @(posedge clk or posedge rst) begin
        if (rst) dbg_req_drop <= 1'b0;
        else if (sample_req && (st != S_IDLE)) dbg_req_drop <= 1'b1;
    end
    // 【#fix14-probe】不粘滞版：丢过一次就把计数充到 5ms（12.288MHz => 61440 拍 ✓ 17 位够 ✓）
    reg [16:0] drop_recent_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst) drop_recent_cnt <= 17'd0;
        else if (sample_req && (st != S_IDLE)) drop_recent_cnt <= 17'd61_440;
        else if (drop_recent_cnt != 17'd0)     drop_recent_cnt <= drop_recent_cnt - 17'd1;
    end
    assign dbg_req_drop_recent = (drop_recent_cnt != 17'd0);

    // ---- 【#fix21-latgrades】把"ack 延迟"拆成两段（只读 ✓）----
    reg        rq_d;                 // req 上一拍（找上升沿 ✓）
    reg [19:0] g_cnt;                // 当前段计数
    reg [1:0]  g_req2rden;           // 段1 档位（粘滞取最大 ✓）
    reg [1:0]  g_rden2v;             // 段2 档位（粘滞取最大 ✓）
    reg        g_seg2;               // 1 = 正在量"rd_en -> valid"这一段
    function [1:0] grade;
        input [19:0] c;
        begin
            if      (c <  20'd8)   grade = 2'd0;
            else if (c <  20'd64)  grade = 2'd1;
            else if (c <  20'd512) grade = 2'd2;
            else                   grade = 2'd3;
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rq_d <= 1'b0; g_cnt <= 20'd0; g_req2rden <= 2'd0; g_rden2v <= 2'd0; g_seg2 <= 1'b0;
        end else begin
            rq_d <= sample_req;
            // req 上升沿 ⇒ 开始量段1 ✓
            if (sample_req && !rq_d) begin g_cnt <= 20'd0; g_seg2 <= 1'b0; end
            else if (!g_seg2 && fifo_rd_en) begin
                // 首次拉 rd_en ⇒ 段1 结束，记档并开始量段2 ✓
                g_req2rden <= (grade(g_cnt) > g_req2rden) ? grade(g_cnt) : g_req2rden;
                g_cnt <= 20'd0; g_seg2 <= 1'b1;
            end else begin
                if (g_cnt != 20'd0 || sample_req) g_cnt <= g_cnt + 20'd1;
                if (g_seg2 && sample_valid) begin
                    g_rden2v <= (grade(g_cnt) > g_rden2v) ? grade(g_cnt) : g_rden2v;
                    g_seg2 <= 1'b0;
                end
            end
        end
    end
    assign dbg_lat_req2rden = g_req2rden;
    assign dbg_lat_rden2v   = g_rden2v;
    assign dbg_req_seen_hi  = req_seen;

    // ---- 【#fix23-dwell】状态驻留 + empty 卡住（只读 ✓）----
    reg [19:0] dw_cnt;            // 当前状态已驻留拍数
    reg [3:0]  dw_st;             // 当前状态
    reg [19:0] dw_max;            // 见过的最大驻留
    reg [3:0]  dw_max_st;         // 该最大驻留对应的状态码
    reg [19:0] emp_cnt;           // empty 连续为 1 的拍数
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dw_cnt <= 20'd0; dw_st <= 4'd0; dw_max <= 20'd0; dw_max_st <= 4'd0;
            emp_cnt <= 20'd0; dbg_empty_stuck <= 1'b0;
        end else begin
            if (st != dw_st) begin dw_st <= st; dw_cnt <= 20'd1; end
            else begin
                if (dw_cnt != 20'hFFFFF) dw_cnt <= dw_cnt + 20'd1;
                if (dw_cnt > dw_max) begin dw_max <= dw_cnt; dw_max_st <= st; end
            end
            if (fifo_empty) begin
                if (emp_cnt != 20'hFFFFF) emp_cnt <= emp_cnt + 20'd1;
                if (emp_cnt >= 20'd512) dbg_empty_stuck <= 1'b1;
            end else emp_cnt <= 20'd0;
        end
    end
    assign dbg_dwell_state = dw_max_st;
    assign dbg_dwell_grade = (dw_max <  20'd8)   ? 2'd0 :
                             (dw_max <  20'd64)  ? 2'd1 :
                             (dw_max <  20'd512) ? 2'd2 : 2'd3;

    // ---- 【#fix19-probe】★这里原本想放"消费字节计数奇偶"检查 —— 实测发现它是【同义反复】✗★
    //   本模块每个样本固定取 2（mono）/4（stereo）字节 ⇒ cons_bytes[0] 在 sample_valid 时
    //   ★结构上恒为 0★ ⇒ 这条检查【永远报不出错】= 第 4 次"假 PASS"陷阱 ✗✗
    //   => 已删除 ✗；真正的非平凡检查放在【读取器】(b')：PCM 流是否【连续】
    //      （pos_diff != 0 即字节流有跳跃/丢失/错位 ✗）见 wav_reader.v 的 dbg_pcm_gap ✓
    assign dbg_pair_bad = 1'b0;   // 保留端口以兼容（恒定 0，明确标注"本检查无意义"✗）

    // ---- 【#fix15-probe】真正的丢请求判定 + ack 延迟档（只读 ✓）----
    reg        req_hi, ack_in_win;
    reg [16:0] lost_recent_cnt;
    reg [19:0] lat_cnt;          // 从 req 上升到 ack 的拍数
    reg [1:0]  lat_grade;        // 粘滞的"最大档"
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            req_hi <= 1'b0; ack_in_win <= 1'b0; dbg_req_lost <= 1'b0;
            lost_recent_cnt <= 17'd0; lat_cnt <= 20'd0; lat_grade <= 2'd0;
        end else begin
            if (sample_req && !req_hi) begin          // 请求上升沿：开窗
                req_hi     <= 1'b1;
                ack_in_win <= 1'b0;
                lat_cnt    <= 20'd0;
            end else if (!sample_req && req_hi) begin // 请求下降沿：关窗
                req_hi <= 1'b0;
                if (!ack_in_win) begin                // ★撤了却没 ack => 真丢 ✗
                    dbg_req_lost    <= 1'b1;
                    lost_recent_cnt <= 17'd61_440;    // 5ms @12.288MHz
                end
            end
            if (req_hi) lat_cnt <= lat_cnt + 20'd1;
            if (sample_valid) begin
                ack_in_win <= 1'b1;
                // ack 延迟档（粘滞取最大 ✓）
                if      (lat_cnt < 20'd8)   begin if (lat_grade < 2'd0) lat_grade <= 2'd0; end
                else if (lat_cnt < 20'd64)  lat_grade <= (lat_grade < 2'd1) ? 2'd1 : lat_grade;
                else if (lat_cnt < 20'd512) lat_grade <= (lat_grade < 2'd2) ? 2'd2 : lat_grade;
                else                        lat_grade <= 2'd3;
            end
            if (lost_recent_cnt != 17'd0) lost_recent_cnt <= lost_recent_cnt - 17'd1;
        end
    end
    assign dbg_req_lost_now = (lost_recent_cnt != 17'd0);
    assign dbg_ack_lat      = lat_grade;

    //==== 【#fix31-g14】冻结探测器（只读 ✓；口径见头注 ✓）====
    //   ★放在模块末尾 ⇒ 保证 fifo_rd_en / fifo_rd_data / byte_lo 都已声明 ✓（避免"先用后声明"✗）
    reg [23:0] age_rdata, age_bytelo, age_rden, age_vld;
    reg [7:0]  prev_rdata, prev_bytelo;
    reg        prev_rden;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            age_rdata <= 24'd0; age_bytelo <= 24'd0; age_rden <= 24'd0; age_vld <= 24'd0;
            prev_rdata <= 8'd0; prev_bytelo <= 8'd0; prev_rden <= 1'b0;
            dbg_rddata_frz <= 2'd0; dbg_bytelo_frz <= 2'd0; dbg_rden_frz <= 2'd0; dbg_rddata_chg <= 12'd0;
        end else begin
            // fifo_rd_data 变化 ⇒ 年龄清零 + 计数 ✓；否则年龄 +1（饱和 ✓）
            if (fifo_rd_data !== prev_rdata) begin
                age_rdata <= 24'd0; prev_rdata <= fifo_rd_data;
                dbg_rddata_chg <= dbg_rddata_chg + 12'd1;
            end else if (age_rdata < 24'hFFFFFF) age_rdata <= age_rdata + 24'd1;
            // byte_lo 变化
            if (byte_lo !== prev_bytelo) begin age_bytelo <= 24'd0; prev_bytelo <= byte_lo; end
            else if (age_bytelo < 24'hFFFFFF) age_bytelo <= age_bytelo + 24'd1;
            // fifo_rd_en 脉冲
            if (fifo_rd_en && !prev_rden) age_rden <= 24'd0;
            else if (age_rden < 24'hFFFFFF) age_rden <= age_rden + 24'd1;
            prev_rden <= fifo_rd_en;
            // 档位（阈值远离正常值 ⇒ 好态必为 0 ✓ 满足纪律10 ✓）
            if      (age_rdata  < 24'd256)   dbg_rddata_frz <= 2'd0;
            else if (age_rdata  < 24'd4096)  dbg_rddata_frz <= 2'd1;
            else if (age_rdata  < 24'd65536) dbg_rddata_frz <= 2'd2;
            else                             dbg_rddata_frz <= 2'd3;   // ★恒定 ✗✓★
            if      (age_bytelo < 24'd256)   dbg_bytelo_frz <= 2'd0;
            else if (age_bytelo < 24'd4096)  dbg_bytelo_frz <= 2'd1;
            else if (age_bytelo < 24'd65536) dbg_bytelo_frz <= 2'd2;
            else                             dbg_bytelo_frz <= 2'd3;
            if      (age_rden   < 24'd256)   dbg_rden_frz <= 2'd0;
            else if (age_rden   < 24'd4096)  dbg_rden_frz <= 2'd1;
            else if (age_rden   < 24'd65536) dbg_rden_frz <= 2'd2;
            else                             dbg_rden_frz <= 2'd3;     // ★rd_en 停了 ✗✓★
        end
    end

endmodule
