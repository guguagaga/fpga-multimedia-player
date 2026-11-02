// Map the decoded switch selector to one of 16 carousel periods (2..600 s).
// preset_sec follows the selector; period_sec and preset_code latch at boundary.
// The caller supplies boundary so the active interval changes at a safe point.
module carousel_period_cfg (
  input            clk,
  input            rst,          // active HIGH
  input      [3:0] preset_sel,   // synchronized + debounced switch code
  input            boundary,     // 1 = a new preset may be taken now
  output reg [3:0] preset_code,  // preset that is in effect
  output reg [9:0] period_sec,   // period that is in effect (2 .. 600 s)
  output     [9:0] preset_sec    // decode of preset_sel (not latched)
);

  // ---------------------------------------------------------------
  // Preset table. Written as a function so the same decode is used
  // for the latched value and for the read only probe.
  // ---------------------------------------------------------------
  function [9:0] period_lut;
    input [3:0] code;
    begin
      case (code)
        4'd0: period_lut = 10'd2;
        4'd1: period_lut = 10'd3;
        4'd2: period_lut = 10'd5;
        4'd3: period_lut = 10'd8;
        4'd4: period_lut = 10'd10;
        4'd5: period_lut = 10'd15;
        4'd6: period_lut = 10'd20;
        4'd7: period_lut = 10'd30;
        4'd8: period_lut = 10'd45;
        4'd9: period_lut = 10'd60;
        4'd10: period_lut = 10'd90;
        4'd11: period_lut = 10'd120;
        4'd12: period_lut = 10'd180;
        4'd13: period_lut = 10'd240;
        4'd14: period_lut = 10'd300;
        default: period_lut = 10'd600;  // 4'd15, and any X/Z code
      endcase
    end
  endfunction

  assign preset_sec = period_lut(preset_sel);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      // power up default = code 0 = 2 s. The carousel itself powers
      // up OFF, so this value is not visible until the user turns
      // the carousel on.
      preset_code <= 4'd0;
      period_sec  <= 10'd2;
    end else if (boundary) begin
      preset_code <= preset_sel;
      period_sec  <= period_lut(preset_sel);
    end
  end

endmodule

// Coherent, latest-value status mailbox. Both domains share active-high rst.
// The source bundle stays unchanged until the destination acknowledges it.
// Changes while busy are coalesced; the final effective value is delivered.
module carousel_status_cdc (
  input            src_clk,
  input            dst_clk,
  input            rst,
  input      [4:0]  src_status,
  output reg [4:0]  dst_status
);
  reg [4:0] bundle;
  reg request_toggle, ack_toggle;
  (* ASYNC_REG = "TRUE" *) reg [1:0] ack_sync;
  (* ASYNC_REG = "TRUE" *) reg [2:0] request_sync;

  always @(posedge src_clk or posedge rst) begin
    if (rst) begin
      bundle <= 5'd0;
      request_toggle <= 1'b0;
      ack_sync <= 2'b00;
    end else begin
      ack_sync <= {ack_sync[0], ack_toggle};
      if ((ack_sync[1] == request_toggle) && (src_status != bundle)) begin
        bundle <= src_status;
        request_toggle <= ~request_toggle;
      end
    end
  end

  always @(posedge dst_clk or posedge rst) begin
    if (rst) begin
      request_sync <= 3'b000;
      ack_toggle <= 1'b0;
      dst_status <= 5'd0;
    end else begin
      request_sync <= {request_sync[1:0], request_toggle};
      if (request_sync[2] != ack_toggle) begin
        dst_status <= bundle;
        ack_toggle <= request_sync[2];
      end
    end
  end
endmodule
