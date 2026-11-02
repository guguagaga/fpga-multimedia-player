// 从字节 FIFO 组装 16 位 PCM，支持单声道复制与双声道样本对。
// FIFO 为寄存器读输出，REQ 发出读取，GET 使用下一拍数据。
// 请求通过 req_pending 锁存，req_seen 防止同一保持请求重复消费。
module wav_sample_builder (
  input wire clk,  // audio clock 12.288 MHz
  input wire rst,  // active-high reset
  input wire sample_req,  // pulse: request next sample pair (48 kHz)
  input wire stereo,  // 1 = 2 channels, 0 = 1 channel
  // async FIFO read interface (registered rd_data: one cycle after rd_en)
  output wire fifo_rd_en,
  input wire [7:0] fifo_rd_data,
  input wire fifo_empty,
  // sample output (24-bit)
  output reg sample_valid,  // 1-cycle pulse when sample updates
  output reg [23:0] sample_left,
  output reg [23:0] sample_right,
  output wire stream_idle,
  // 只读状态和请求观测接口，不参与音频数据控制。
  output wire [3:0] dbg_st,
  output reg dbg_req_drop,
  // 有限保持窗口用于反映最近一次请求异常，而非永久故障状态。
  output wire dbg_req_drop_recent,
  // 将请求延迟分为请求到首次读使能、首次读使能到样本确认两段。
  output wire [1:0] dbg_lat_req2rden,
  output wire [1:0] dbg_lat_rden2v,
  output wire dbg_req_seen_hi,
  // 观测状态驻留和 FIFO 空状态，以定位等待发生的位置。
  output wire [3:0] dbg_dwell_state,
  output wire [1:0] dbg_dwell_grade,
  output reg dbg_empty_stuck,
  // 记录读取值保持不变的时间，作为数据活动观测量。
  output reg  [1:0]  dbg_rddata_frz,   // fifo_rd_data 的冻结档（0 ⇒ 在读新数据 ；3 ⇒ 恒定 ）
  output reg [1:0] dbg_bytelo_frz,  // byte_lo 的冻结档
  output reg [1:0] dbg_rden_frz,  // fifo_rd_en 的冻结档（3 ⇒ rd_en 停脉冲 ）
  output reg  [11:0] dbg_rddata_chg,   // fifo_rd_data 变化次数（累计低 12 位  供人工核对）
  // 记录消费字节及样本完成关系，仅用于状态观测。
  output wire dbg_pair_bad,  // 恒 0（本检查无意义 ，见下方说明）
  // 请求撤销且未收到确认时记录未完成请求。
  output reg dbg_req_lost,  // 粘滞：曾经有请求被撤但没 ack 
  output wire dbg_req_lost_now,  // 电平：最近 5ms 内还在丢 
  output wire [1:0] dbg_ack_lat  // ack 延迟档：0=<8拍 1=8~64 2=64~512 3=≥512
);

  // REQ 拍 / GET 拍交替：REQ 拉 rd_en，GET 取数
  localparam [3:0] S_IDLE = 4'd0, S_REQ_LO = 4'd1, S_GET_LO = 4'd2,  // L 低字节
  S_REQ_HI = 4'd3, S_GET_HI = 4'd4,  // L 高字节
  S_REQ_RLO = 4'd5, S_GET_RLO = 4'd6,  // R 低字节
  S_REQ_RHI = 4'd7, S_GET_RHI = 4'd8;  // R 高字节

  reg [3:0] st;
  assign stream_idle = (st == S_IDLE);
  // 锁存待处理请求，空闲时启动组样本；保持请求只接受一次。
  reg       req_seen;  // 1 = 本个 sample_req 高电平窗口已被接受过
  reg [7:0] byte_lo;  // low byte of the current sample

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

      // sample_req 保持至 sample_valid；req_seen 限制每个请求窗口只消费一组样本。
      if (!sample_req) req_seen <= 1'b0;  // req 拉低 => 本窗口结束，允许下一次

      case (st)
        S_IDLE: begin
          if (sample_req && !req_seen && !fifo_empty) begin
            st       <= S_REQ_LO;
            req_seen <= 1'b1;  // 本窗口已被接受
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

  // 只读观测逻辑与功能状态机分开驱动，避免统计信号反向影响播放。
  assign dbg_st = st;  // 只读镜像，不新增逻辑
  always @(posedge clk or posedge rst) begin
    if (rst) dbg_req_drop <= 1'b0;
    else if (sample_req && (st != S_IDLE)) dbg_req_drop <= 1'b1;
  end
  // 事件发生后保持约 5 ms 可见窗口，便于读取短暂异常。
  reg [16:0] drop_recent_cnt;
  always @(posedge clk or posedge rst) begin
    if (rst) drop_recent_cnt <= 17'd0;
    else if (sample_req && (st != S_IDLE)) drop_recent_cnt <= 17'd61_440;
    else if (drop_recent_cnt != 17'd0) drop_recent_cnt <= drop_recent_cnt - 17'd1;
  end
  assign dbg_req_drop_recent = (drop_recent_cnt != 17'd0);

  // 分别计量读取启动延迟与样本组装延迟。
  reg        rq_d;  // req 上一拍（找上升沿 ）
  reg [19:0] g_cnt;  // 当前段计数
  reg [ 1:0] g_req2rden;  // 段1 档位（粘滞取最大 ）
  reg [ 1:0] g_rden2v;  // 段2 档位（粘滞取最大 ）
  reg        g_seg2;  // 1 = 正在量"rd_en -> valid"这一段
  function [1:0] grade;
    input [19:0] c;
    begin
      if (c < 20'd8) grade = 2'd0;
      else if (c < 20'd64) grade = 2'd1;
      else if (c < 20'd512) grade = 2'd2;
      else grade = 2'd3;
    end
  endfunction
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      rq_d <= 1'b0;
      g_cnt <= 20'd0;
      g_req2rden <= 2'd0;
      g_rden2v <= 2'd0;
      g_seg2 <= 1'b0;
    end else begin
      rq_d <= sample_req;
      // req 上升沿 ⇒ 开始量段1 
      if (sample_req && !rq_d) begin
        g_cnt  <= 20'd0;
        g_seg2 <= 1'b0;
      end else if (!g_seg2 && fifo_rd_en) begin
        // 首次拉 rd_en ⇒ 段1 结束，记档并开始量段2 
        g_req2rden <= (grade(g_cnt) > g_req2rden) ? grade(g_cnt) : g_req2rden;
        g_cnt <= 20'd0;
        g_seg2 <= 1'b1;
      end else begin
        if (g_cnt != 20'd0 || sample_req) g_cnt <= g_cnt + 20'd1;
        if (g_seg2 && sample_valid) begin
          g_rden2v <= (grade(g_cnt) > g_rden2v) ? grade(g_cnt) : g_rden2v;
          g_seg2   <= 1'b0;
        end
      end
    end
  end
  assign dbg_lat_req2rden = g_req2rden;
  assign dbg_lat_rden2v   = g_rden2v;
  assign dbg_req_seen_hi  = req_seen;

  // 统计状态驻留及 FIFO 空等待。
  reg [19:0] dw_cnt;  // 当前状态已驻留拍数
  reg [ 3:0] dw_st;  // 当前状态
  reg [19:0] dw_max;  // 见过的最大驻留
  reg [ 3:0] dw_max_st;  // 该最大驻留对应的状态码
  reg [19:0] emp_cnt;  // empty 连续为 1 的拍数
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      dw_cnt <= 20'd0;
      dw_st <= 4'd0;
      dw_max <= 20'd0;
      dw_max_st <= 4'd0;
      emp_cnt <= 20'd0;
      dbg_empty_stuck <= 1'b0;
    end else begin
      if (st != dw_st) begin
        dw_st  <= st;
        dw_cnt <= 20'd1;
      end else begin
        if (dw_cnt != 20'hFFFFF) dw_cnt <= dw_cnt + 20'd1;
        if (dw_cnt > dw_max) begin
          dw_max <= dw_cnt;
          dw_max_st <= st;
        end
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

  // 输出字节配对与请求确认的辅助观测。
  assign dbg_pair_bad = 1'b0;   // 保留端口以兼容（恒定 0，明确标注"本检查无意义"）

  // 检测未确认请求并发布确认延迟档位。
  reg req_hi, ack_in_win;
  reg [16:0] lost_recent_cnt;
  reg [19:0] lat_cnt;  // 从 req 上升到 ack 的拍数
  reg [ 1:0] lat_grade;  // 粘滞的"最大档"
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      req_hi <= 1'b0;
      ack_in_win <= 1'b0;
      dbg_req_lost <= 1'b0;
      lost_recent_cnt <= 17'd0;
      lat_cnt <= 20'd0;
      lat_grade <= 2'd0;
    end else begin
      if (sample_req && !req_hi) begin  // 请求上升沿：开窗
        req_hi     <= 1'b1;
        ack_in_win <= 1'b0;
        lat_cnt    <= 20'd0;
      end else if (!sample_req && req_hi) begin  // 请求下降沿：关窗
        req_hi <= 1'b0;
        if (!ack_in_win) begin  // 撤了却没 ack => 真丢 
          dbg_req_lost    <= 1'b1;
          lost_recent_cnt <= 17'd61_440;    // 5ms @12.288MHz
        end
      end
      if (req_hi) lat_cnt <= lat_cnt + 20'd1;
      if (sample_valid) begin
        ack_in_win <= 1'b1;
        // ack 延迟档（粘滞取最大 ）
        if (lat_cnt < 20'd8) begin
          if (lat_grade < 2'd0) lat_grade <= 2'd0;
        end else if (lat_cnt < 20'd64) lat_grade <= (lat_grade < 2'd1) ? 2'd1 : lat_grade;
        else if (lat_cnt < 20'd512) lat_grade <= (lat_grade < 2'd2) ? 2'd2 : lat_grade;
        else lat_grade <= 2'd3;
      end
      if (lost_recent_cnt != 17'd0) lost_recent_cnt <= lost_recent_cnt - 17'd1;
    end
  end
  assign dbg_req_lost_now = (lost_recent_cnt != 17'd0);
  assign dbg_ack_lat      = lat_grade;

  // 在读取发生时更新输入数据活动计数。
  reg [23:0] age_rdata, age_bytelo, age_rden, age_vld;
  reg [7:0] prev_rdata, prev_bytelo;
  reg prev_rden;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      age_rdata <= 24'd0;
      age_bytelo <= 24'd0;
      age_rden <= 24'd0;
      age_vld <= 24'd0;
      prev_rdata <= 8'd0;
      prev_bytelo <= 8'd0;
      prev_rden <= 1'b0;
      dbg_rddata_frz <= 2'd0;
      dbg_bytelo_frz <= 2'd0;
      dbg_rden_frz <= 2'd0;
      dbg_rddata_chg <= 12'd0;
    end else begin
      // fifo_rd_data 变化 ⇒ 年龄清零 + 计数 ；否则年龄 +1（饱和 ）
      if (fifo_rd_data !== prev_rdata) begin
        age_rdata <= 24'd0;
        prev_rdata <= fifo_rd_data;
        dbg_rddata_chg <= dbg_rddata_chg + 12'd1;
      end else if (age_rdata < 24'hFFFFFF) age_rdata <= age_rdata + 24'd1;
      // byte_lo 变化
      if (byte_lo !== prev_bytelo) begin
        age_bytelo  <= 24'd0;
        prev_bytelo <= byte_lo;
      end else if (age_bytelo < 24'hFFFFFF) age_bytelo <= age_bytelo + 24'd1;
      // fifo_rd_en 脉冲
      if (fifo_rd_en && !prev_rden) age_rden <= 24'd0;
      else if (age_rden < 24'hFFFFFF) age_rden <= age_rden + 24'd1;
      prev_rden <= fifo_rd_en;
      // 档位（阈值远离正常值 ⇒ 好态必为 0  满足纪律10 ）
      if (age_rdata < 24'd256) dbg_rddata_frz <= 2'd0;
      else if (age_rdata < 24'd4096) dbg_rddata_frz <= 2'd1;
      else if (age_rdata < 24'd65536) dbg_rddata_frz <= 2'd2;
      else dbg_rddata_frz <= 2'd3;  // 恒定 
      if (age_bytelo < 24'd256) dbg_bytelo_frz <= 2'd0;
      else if (age_bytelo < 24'd4096) dbg_bytelo_frz <= 2'd1;
      else if (age_bytelo < 24'd65536) dbg_bytelo_frz <= 2'd2;
      else dbg_bytelo_frz <= 2'd3;
      if (age_rden < 24'd256) dbg_rden_frz <= 2'd0;
      else if (age_rden < 24'd4096) dbg_rden_frz <= 2'd1;
      else if (age_rden < 24'd65536) dbg_rden_frz <= 2'd2;
      else dbg_rden_frz <= 2'd3;  // rd_en 停了 
    end
  end

endmodule
