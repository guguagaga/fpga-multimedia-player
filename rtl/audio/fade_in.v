// 图像层淡入淡出。各 RGB 通道用移位、加减生成离散亮度等级，避免通用乘法器。
// 新帧就绪后先请求淡出；显示域确认全黑后交接缓冲区，再执行淡入。
// 转场只作用于图像层，OSD 与频谱由后级叠加。
module fade_in (
  input wire clk,  // pixel clock
  input wire rst_n,  // 低有效
  input wire vs,  // video_clk 域帧同步（下降沿 = 一帧边界）
  input wire fade_req,  // 1 拍脉冲：开始淡出（顶层同步过的 sd->video 请求）
  output reg fade_done,  // toggle：淡出完成（顶层同步回 sd 域去换 buffer）
  input wire img_switch,  // 1~2 拍脉冲：无握手硬切的超时恢复触发（直接从黑淡入）
  input wire [23:0] din_rgb,  // 图像层（未淡）
  output wire [23:0] dout_rgb,  // 图像层（已淡），纯组合
  output wire busy  // 1 = 转场进行中（顶层同步给 sd 域做背压）
);

  // ---- 电平表范围：0 = 全亮，17 = 全黑，1 级/帧 ----
  localparam [4:0] LVL_MAX = 5'd17;

  // ---- 状态机 ----
  localparam [1:0] S_LIVE = 2'd0,  // 正常显示（lvl=0，coeff=1，精确透传）
  S_OUT = 2'd1,  // 淡出（旧图 -> 黑）
  S_IN = 2'd2;  // 淡入（黑 -> 新图）

  reg [1:0] st;
  reg [4:0] lvl;

  // ---- 帧边界：vs 下降沿（每帧一个脉冲）----
  reg vs_d;
  wire vs_nedge = vs_d & ~vs;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) vs_d <= 1'b0;
    else vs_d <= vs;
  end

  // ---- 电平 -> 控制位 {mode_shift, k[2:0], e} ----
  //   mode_shift=1: out = s + e×t        (移位模式)
  //   mode_shift=0: out = x - (s + e×t)  (子模式)
  //   k=0 -> s=x：移位模式 = 全亮透传，子模式 = 全黑
  function [4:0] lvl2ctl;
    input [4:0] i;
    begin
      case (i)
        5'd0: lvl2ctl = {1'b1, 3'd0, 1'b0};  // 1.000
        5'd1: lvl2ctl = {1'b0, 3'd6, 1'b0};  // 0.984
        5'd2: lvl2ctl = {1'b0, 3'd5, 1'b0};  // 0.969
        5'd3: lvl2ctl = {1'b0, 3'd4, 1'b0};  // 0.938
        5'd4: lvl2ctl = {1'b0, 3'd4, 1'b1};  // 0.906
        5'd5: lvl2ctl = {1'b0, 3'd3, 1'b0};  // 0.875
        5'd6: lvl2ctl = {1'b0, 3'd3, 1'b1};  // 0.813
        5'd7: lvl2ctl = {1'b0, 3'd2, 1'b0};  // 0.750
        5'd8: lvl2ctl = {1'b0, 3'd2, 1'b1};  // 0.625
        5'd9: lvl2ctl = {1'b0, 3'd1, 1'b0};  // 0.500
        5'd10: lvl2ctl = {1'b1, 3'd2, 1'b1};  // 0.375
        5'd11: lvl2ctl = {1'b1, 3'd2, 1'b0};  // 0.250
        5'd12: lvl2ctl = {1'b1, 3'd3, 1'b1};  // 0.188
        5'd13: lvl2ctl = {1'b1, 3'd3, 1'b0};  // 0.125
        5'd14: lvl2ctl = {1'b1, 3'd4, 1'b1};  // 0.094
        5'd15: lvl2ctl = {1'b1, 3'd4, 1'b0};  // 0.063
        5'd16: lvl2ctl = {1'b1, 3'd5, 1'b0};  // 0.031
        5'd17: lvl2ctl = {1'b0, 3'd0, 1'b0};  // 0.000
        default: lvl2ctl = {1'b1, 3'd0, 1'b0};
      endcase
    end
  endfunction

  wire [4:0] ctl = lvl2ctl(lvl);
  wire       mode_shift = ctl[4];
  wire [2:0] k = ctl[3:1];
  wire       e = ctl[0];

  // ---- 三通道独立移位 + 加/减（没有任何乘法器）----
  wire [7:0] r_in = din_rgb[23:16];
  wire [7:0] g_in = din_rgb[15:8];
  wire [7:0] b_in = din_rgb[7:0];

  wire [7:0] r_s = r_in >> k;  // 3 级桶形移位器，零填充
  wire [7:0] g_s = g_in >> k;
  wire [7:0] b_s = b_in >> k;

  wire [7:0] r_t = r_s >> 1;  // 纯布线
  wire [7:0] g_t = g_s >> 1;
  wire [7:0] b_t = b_s >> 1;

  wire [7:0] r_u = r_s + (e ? r_t : 8'd0);
  wire [7:0] g_u = g_s + (e ? g_t : 8'd0);
  wire [7:0] b_u = b_s + (e ? b_t : 8'd0);

  wire [7:0] r_o = mode_shift ? r_u : (r_in - r_u);
  wire [7:0] g_o = mode_shift ? g_u : (g_in - g_u);
  wire [7:0] b_o = mode_shift ? b_u : (b_in - b_u);

  // S_LIVE 时 lvl 恒为 0 -> 移位模式 k=0 -> out = x（精确透传），
  // 因此这里不需要额外的旁路 mux（省 24 个 LUT）。
  assign dout_rgb = {r_o, g_o, b_o};
  assign busy     = (st != S_LIVE);

  // ---- 转场状态机：只由 vs 下降沿推进 ----
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= S_LIVE;
      lvl       <= 5'd0;
      fade_done <= 1'b0;
    end else begin
      case (st)
        S_LIVE: begin
          if (fade_req) begin
            // 开始淡出（旧图 -> 黑）
            st  <= S_OUT;
            lvl <= 5'd1;
          end else if (img_switch) begin
            // 无握手时从黑场开始淡入
            st  <= S_IN;
            lvl <= LVL_MAX;
          end
        end

        S_OUT: begin
          if (vs_nedge) begin
            if (lvl >= LVL_MAX) begin
              // 已经全黑：告诉 sd 域"可以换 buffer 了"，
              // 同一拍开始淡入（黑只停留 1 帧）
              fade_done <= ~fade_done;
              st        <= S_IN;
              lvl       <= LVL_MAX - 5'd1;
            end else begin
              lvl <= lvl + 5'd1;
            end
          end
        end

        S_IN: begin
          if (vs_nedge) begin
            if (lvl == 5'd0) st <= S_LIVE;
            else lvl <= lvl - 5'd1;
          end
        end

        default: st <= S_LIVE;
      endcase
    end
  end

endmodule
