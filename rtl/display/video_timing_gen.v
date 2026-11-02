// Generate HS, VS and DE with horizontal and vertical timing state machines.
// Each axis cycles through sync, back porch, active area and front porch.
// Parameters set interval lengths and sync polarities in pixel clocks or lines.
module video_timing_gen #(
  parameter H_ACTIVE = 12'd1280,
  parameter H_FP     = 12'd110,
  parameter H_SYNC   = 12'd40,
  parameter H_BP     = 12'd220,
  parameter V_ACTIVE = 12'd720,
  parameter V_FP     = 12'd5,
  parameter V_SYNC   = 12'd5,
  parameter V_BP     = 12'd20,
  parameter HS_POL   = 1'b1,
  parameter VS_POL   = 1'b1
) (
  input  wire clk,  // pixel clock
  input  wire rst,  // active-high reset
  output reg  hs,   // horizontal sync
  output reg  vs,   // vertical sync
  output reg  de    // data enable (pixel valid)
);

  // ---------------- horizontal FSM ----------------
  localparam H_SYNC_ST = 2'd0, H_BP_ST = 2'd1, H_ACTIVE_ST = 2'd2, H_FP_ST = 2'd3;

  reg [ 1:0] h_state;
  reg [11:0] h_cnt;  // clock count inside current h state
  reg        h_end;  // 1-cycle pulse at the end of a line

  // ---------------- vertical FSM ----------------
  localparam V_SYNC_ST = 2'd0, V_BP_ST = 2'd1, V_ACTIVE_ST = 2'd2, V_FP_ST = 2'd3;

  reg [ 1:0] v_state;
  reg [11:0] v_cnt;  // line count inside current v state

  // ---------------- horizontal state machine ----------------
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      h_state <= H_SYNC_ST;
      h_cnt   <= 12'd0;
      h_end   <= 1'b0;
    end else begin
      h_end <= 1'b0;  // default low
      case (h_state)
        H_SYNC_ST:
        if (h_cnt == H_SYNC - 12'd1) begin
          h_state <= H_BP_ST;
          h_cnt   <= 12'd0;
        end else h_cnt <= h_cnt + 12'd1;
        H_BP_ST:
        if (h_cnt == H_BP - 12'd1) begin
          h_state <= H_ACTIVE_ST;
          h_cnt   <= 12'd0;
        end else h_cnt <= h_cnt + 12'd1;
        H_ACTIVE_ST:
        if (h_cnt == H_ACTIVE - 12'd1) begin
          h_state <= H_FP_ST;
          h_cnt   <= 12'd0;
        end else h_cnt <= h_cnt + 12'd1;
        H_FP_ST:
        if (h_cnt == H_FP - 12'd1) begin
          h_state <= H_SYNC_ST;
          h_cnt   <= 12'd0;
          h_end   <= 1'b1;  // line done
        end else h_cnt <= h_cnt + 12'd1;
        default: h_state <= H_SYNC_ST;
      endcase
    end
  end

  // ---------------- vertical state machine ----------------
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      v_state <= V_SYNC_ST;
      v_cnt   <= 12'd0;
    end else if (h_end) begin  // advance once per line
      case (v_state)
        V_SYNC_ST:
        if (v_cnt == V_SYNC - 12'd1) begin
          v_state <= V_BP_ST;
          v_cnt   <= 12'd0;
        end else v_cnt <= v_cnt + 12'd1;
        V_BP_ST:
        if (v_cnt == V_BP - 12'd1) begin
          v_state <= V_ACTIVE_ST;
          v_cnt   <= 12'd0;
        end else v_cnt <= v_cnt + 12'd1;
        V_ACTIVE_ST:
        if (v_cnt == V_ACTIVE - 12'd1) begin
          v_state <= V_FP_ST;
          v_cnt   <= 12'd0;
        end else v_cnt <= v_cnt + 12'd1;
        V_FP_ST:
        if (v_cnt == V_FP - 12'd1) begin
          v_state <= V_SYNC_ST;
          v_cnt   <= 12'd0;
        end else v_cnt <= v_cnt + 12'd1;
        default: v_state <= V_SYNC_ST;
      endcase
    end
  end

  // ---------------- outputs (all registered, aligned) ----------------
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      hs <= 1'b1;
      vs <= 1'b1;
      de <= 1'b0;
    end else begin
      hs <= (h_state == H_SYNC_ST) ? HS_POL : ~HS_POL;
      vs <= (v_state == V_SYNC_ST) ? VS_POL : ~VS_POL;
      de <= (h_state == H_ACTIVE_ST) && (v_state == V_ACTIVE_ST);
    end
  end

endmodule
