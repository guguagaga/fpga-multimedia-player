// Unsigned 32-bit restoring divider; start is accepted while idle.
// PIPELINE_STEP separates comparison and subtraction into successive cycles.
// done marks valid quotient and remainder; wait for done before requesting again.
module div_u32 #(
  parameter PIPELINE_STEP = 1
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        start,     // pulse to begin a division
  input  wire [31:0] dividend,
  input  wire [31:0] divisor,
  output reg         done,      // pulse when result is ready
  output reg  [31:0] quotient,
  output reg  [31:0] remainder
);

  reg         busy;
  reg         phase;  // PIPELINE_STEP 时：0=比较 1=相减
  reg  [ 6:0] cnt;
  reg  [63:0] acc;  // {remainder, quotient}
  reg  [31:0] d;

  // combinational next-state for the shift-subtract step
  wire [63:0] acc_shift = acc << 1;
  wire [31:0] rem_cur = acc_shift[63:32];
  wire        ge = (rem_cur >= d);

  // 比较结果先寄存（PIPELINE_STEP=1 时），下一拍再去做减法
  reg         ge_r;
  reg  [31:0] rem_cur_r;
  reg  [63:0] acc_shift_r;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy        <= 1'b0;
      phase       <= 1'b0;
      cnt         <= 7'd0;
      done        <= 1'b0;
      acc         <= 64'd0;
      d           <= 32'd0;
      quotient    <= 32'd0;
      remainder   <= 32'd0;
      ge_r        <= 1'b0;
      rem_cur_r   <= 32'd0;
      acc_shift_r <= 64'd0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        busy  <= 1'b1;
        phase <= 1'b0;
        cnt   <= 7'd0;
        acc   <= {32'd0, dividend};
        d     <= divisor;
      end else if (busy) begin
        if (PIPELINE_STEP != 0) begin
          // ---- 第一拍：只做移位+比较，把结论寄存下来 ----
          if (phase == 1'b0) begin
            ge_r        <= ge;
            rem_cur_r   <= rem_cur;
            acc_shift_r <= acc_shift;
            phase       <= 1'b1;
          end else begin
            // ---- 第二拍：只做减法（不再有比较器在环路上）----
            acc   <= {rem_cur_r - (ge_r ? d : 32'd0), acc_shift_r[31:0]} | (ge_r ? 64'd1 : 64'd0);
            phase <= 1'b0;
            if (cnt == 7'd32) begin
              busy      <= 1'b0;
              done      <= 1'b1;
              quotient  <= acc[31:0];
              remainder <= acc[63:32];
            end else begin
              cnt <= cnt + 7'd1;
            end
          end
        end else begin
          // ---- 单拍迭代路径（PIPELINE_STEP=0）----
          if (cnt == 7'd32) begin
            busy      <= 1'b0;
            done      <= 1'b1;
            quotient  <= acc[31:0];
            remainder <= acc[63:32];
          end else begin
            acc <= {ge ? (rem_cur - d) : rem_cur, acc_shift[31:0]} | (ge ? 64'd1 : 64'd0);
            cnt <= cnt + 7'd1;
          end
        end
      end
    end
  end

endmodule
