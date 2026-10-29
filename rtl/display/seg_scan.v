
module seg_scan (
  input            clk,
  input            status_clk,
  input            rst_n,
  output reg [5:0] seg_sel,     //digital led chip select
  output reg [7:0] seg_data,    //eight segment digital tube output,MSB is the decimal point
  input      [7:0] seg_data_0,
  input      [7:0] seg_data_1,
  input      [7:0] seg_data_2,
  input      [7:0] seg_data_3,
  input      [7:0] seg_data_4,
  input      [7:0] seg_data_5
);
  parameter SAME_CLOCK = 0;
  parameter SCAN_FREQ = 200;     //scan frequency
  parameter CLK_FREQ = 50000000; //clock frequency

  parameter SCAN_COUNT = CLK_FREQ /(SCAN_FREQ * 6) - 1;

  // Status originates in the 100MHz domain. Half-cycle staging keeps
  // it away from coincident 50MHz scan edges. No false path is added.
  reg [7:0] glyph_0, glyph_1, glyph_2, glyph_3, glyph_4, glyph_5;
  // SAME_CLOCK=1 is used by the 100MHz production top: status and scan
  // are synchronous, with a full cycle for the glyph mux instead of a 5ns
  // half-cycle path into the 50MHz domain. Default retains legacy wiring.
  generate
    if (SAME_CLOCK) begin : g_same_clock
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          glyph_0 <= 8'hff;
          glyph_1 <= 8'hff;
          glyph_2 <= 8'hff;
          glyph_3 <= 8'hff;
          glyph_4 <= 8'hff;
          glyph_5 <= 8'hff;
        end else begin
          glyph_0 <= seg_data_0;
          glyph_1 <= seg_data_1;
          glyph_2 <= seg_data_2;
          glyph_3 <= seg_data_3;
          glyph_4 <= seg_data_4;
          glyph_5 <= seg_data_5;
        end
      end
    end else begin : g_legacy_clock
      always @(negedge status_clk or negedge rst_n) begin
        if (!rst_n) begin
          glyph_0 <= 8'hff;
          glyph_1 <= 8'hff;
          glyph_2 <= 8'hff;
          glyph_3 <= 8'hff;
          glyph_4 <= 8'hff;
          glyph_5 <= 8'hff;
        end else begin
          glyph_0 <= seg_data_0;
          glyph_1 <= seg_data_1;
          glyph_2 <= seg_data_2;
          glyph_3 <= seg_data_3;
          glyph_4 <= seg_data_4;
          glyph_5 <= seg_data_5;
        end
      end
    end
  endgenerate
  localparam TIMER_W = (SCAN_COUNT < 2) ? 1 : $clog2(SCAN_COUNT + 1);
  reg[TIMER_W-1:0] scan_timer;  //scan time counter
  reg[2:0] scan_sel;     //Scan select counter
  always @(posedge clk or negedge rst_n) begin
    if (rst_n == 1'b0) begin
      scan_timer <= 32'd0;
      scan_sel   <= 4'd0;
    end else if (scan_timer >= SCAN_COUNT) begin
      scan_timer <= 32'd0;
      if (scan_sel == 4'd5) scan_sel <= 4'd0;
      else scan_sel <= scan_sel + 4'd1;
    end else begin
      scan_timer <= scan_timer + 32'd1;
    end
  end
  always @(posedge clk or negedge rst_n) begin
    if (rst_n == 1'b0) begin
      seg_sel  <= 6'b111111;
      seg_data <= 8'hff;
    end else begin
      case (scan_sel)
        //first digital led
        4'd0: begin
          seg_sel  <= 6'b11_1110;
          seg_data <= glyph_0;
        end
        //second digital led
        4'd1: begin
          seg_sel  <= 6'b11_1101;
          seg_data <= glyph_1;
        end
        //...
        4'd2: begin
          seg_sel  <= 6'b11_1011;
          seg_data <= glyph_2;
        end
        4'd3: begin
          seg_sel  <= 6'b11_0111;
          seg_data <= glyph_3;
        end
        4'd4: begin
          seg_sel  <= 6'b10_1111;
          seg_data <= glyph_4;
        end
        4'd5: begin
          seg_sel  <= 6'b01_1111;
          seg_data <= glyph_5;
        end
        default: begin
          seg_sel  <= 6'b11_1111;
          seg_data <= 8'hff;
        end
      endcase
    end
  end

endmodule
