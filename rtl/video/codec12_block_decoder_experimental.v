`timescale 1ns / 1ps
// Research only: full block byte parser for experimental format 12.
// PAL2/PAL4 indices stream one byte at a time; no 64/128-bit index shift bank.
// Pixel output is registered. Pause stops new work; an already-issued pixel
// remains observable for its valid cycle. Downstream must respect that latency.
module codec12_block_decoder_experimental #(
  parameter FRAME_PIXELS = 921600,
  parameter ENABLE_GRADIENT = 1,
  parameter ENABLE_QUAD = 1,
  parameter ENABLE_SOLID_RUN = 0
) (
  input wire clk, rst, enable, pause,
  input wire byte_valid,
  input wire [7:0] byte_data,
  output wire byte_ready,
  output wire pix_valid,
  output wire [15:0] pixel,
  output reg frame_done, fault
);
  localparam OP = 0, EDGE = 1, LO = 2, HI = 3, INDEX = 4, OUT = 5, RAW_LO = 6, RAW_HI = 7,
      RAW_OUT = 8, GSTART = 9, GWAIT = 10, RUN = 11, GAP = 12;
  reg [3:0] state;
  reg [7:0] mode, low_byte, indices;
  reg [7:0] repeat_blocks;
  reg [2:0] colors, ci, index_left;
  reg [5:0] pix_idx;
  reg [15:0] p0, p1, p2, p3, raw_pixel;
  reg signed [6:0] edge_row, edge_acc;
  reg signed [2:0] edge_dx, edge_dy;
  localparam EW = $clog2(FRAME_PIXELS + 1);
  reg [EW-1:0] emitted;
  reg normal_valid;
  reg [15:0] normal_pixel;
  wire grad_valid, grad_done, grad_busy;
  wire [15:0] grad_pixel;
  wire grad_start = enable && !pause && !fault && state == GSTART;
  generate
    if (ENABLE_GRADIENT) begin : gradient_mode
      gradient_block_experimental gradient (
        .clk      (clk),
        .rst      (rst | !enable),
        .start    (grad_start),
        .pause    (pause),
        .c00      (p0),
        .c10      (p1),
        .c01      (p2),
        .c11      (p3),
        .busy     (grad_busy),
        .pix_valid(grad_valid),
        .done     (grad_done),
        .pixel    (grad_pixel)
      );
    end else begin : no_gradient
      assign grad_valid = 0;
      assign grad_done  = 0;
      assign grad_busy  = 0;
      assign grad_pixel = 0;
    end
  endgenerate
  assign pix_valid = enable && !rst && !fault && (normal_valid || grad_valid);
  assign pixel = grad_valid ? grad_pixel : normal_pixel;
  assign byte_ready = enable && !pause && !fault &&
      (state == OP || state == EDGE || state == LO || state == HI || state == INDEX ||
       state == RAW_LO || state == RAW_HI || state == RUN);
  wire [1:0] palette_index = mode == 8'h88 ? indices[1:0] : {1'b0, indices[0]};
  wire [15:0] palette_pixel = palette_index == 0 ? p0 :
      palette_index == 1 ? p1 : palette_index == 2 ? p2 : p3;
  wire [15:0] quad_pixel = pix_idx[5] ? (pix_idx[2] ? p3 : p2) : (pix_idx[2] ? p1 : p0);
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= OP;
      mode <= 0;
      low_byte <= 0;
      indices <= 0;
      colors <= 0;
      ci <= 0;
      index_left <= 0;
      pix_idx <= 0;
      p0 <= 0;
      p1 <= 0;
      p2 <= 0;
      p3 <= 0;
      raw_pixel <= 0;
      edge_row <= 0;
      edge_acc <= 0;
      edge_dx <= 0;
      edge_dy <= 0;
      emitted <= 0;
      normal_valid <= 0;
      normal_pixel <= 0;
      frame_done <= 0;
      fault <= 0;
      repeat_blocks <= 0;
    end else begin
      normal_valid <= 0;
      frame_done   <= 0;
      if (!enable) begin
        state <= OP;
        emitted <= 0;
        fault <= 0;
        pix_idx <= 0;
        repeat_blocks <= 0;
      end else if (!fault) begin
        if (grad_valid) begin
          if (emitted >= FRAME_PIXELS) fault <= 1;
          else emitted <= emitted + 1'b1;
        end
        // Consume completion even if pause rises after the last gradient pixel.
        if (state == GWAIT && grad_done) state <= OP;
        if (!pause)
          case (state)
            OP:
            if (byte_valid) begin
              mode <= byte_data;
              pix_idx <= 0;
              ci <= 0;
              repeat_blocks <= 0;
              case (byte_data)
                8'h80: begin
                  colors <= 1;
                  state  <= LO;
                end
                8'h85:
                if (ENABLE_SOLID_RUN) begin
                  colors <= 1;
                  mode   <= 8'h80;
                  state  <= RUN;
                end else fault <= 1;
                8'h81: begin
                  colors <= 2;
                  state  <= LO;
                end
                8'h84:
                if (ENABLE_QUAD) begin
                  colors <= 4;
                  state  <= LO;
                end else fault <= 1;
                8'h86:
                if (ENABLE_GRADIENT) begin
                  colors <= 4;
                  state  <= LO;
                end else fault <= 1;
                8'h88: begin
                  colors <= 4;
                  state  <= LO;
                end
                8'h87: begin
                  colors <= 2;
                  state  <= EDGE;
                end
                8'h83:   state <= RAW_LO;
                8'hff: begin
                  if (emitted != FRAME_PIXELS) fault <= 1;
                  else frame_done <= 1;
                  emitted <= 0;
                end
                default: fault <= 1;
              endcase
            end
            RUN:
            if (byte_valid) begin
              repeat_blocks <= byte_data;
              state <= LO;
            end
            GAP: state <= OUT;
            EDGE:
            if (byte_valid) begin
              case (byte_data[7:5])
                0: begin
                  edge_dx <= 1;
                  edge_dy <= 0;
                end
                1: begin
                  edge_dx <= 0;
                  edge_dy <= 1;
                end
                2: begin
                  edge_dx <= 1;
                  edge_dy <= 1;
                end
                3: begin
                  edge_dx <= 1;
                  edge_dy <= -1;
                end
                4: begin
                  edge_dx <= 2;
                  edge_dy <= 1;
                end
                5: begin
                  edge_dx <= 2;
                  edge_dy <= -1;
                end
                6: begin
                  edge_dx <= 1;
                  edge_dy <= 2;
                end
                7: begin
                  edge_dx <= 1;
                  edge_dy <= -2;
                end
              endcase
              if (byte_data[7:5] == 3 || byte_data[7:5] == 5) begin
                edge_row <= 7 - $signed({2'b0, byte_data[4:0]});
                edge_acc <= 7 - $signed({2'b0, byte_data[4:0]});
              end else if (byte_data[7:5] == 7) begin
                edge_row <= 14 - $signed({2'b0, byte_data[4:0]});
                edge_acc <= 14 - $signed({2'b0, byte_data[4:0]});
              end else begin
                edge_row <= -$signed({2'b0, byte_data[4:0]});
                edge_acc <= -$signed({2'b0, byte_data[4:0]});
              end
              state <= LO;
            end
            LO:
            if (byte_valid) begin
              low_byte <= byte_data;
              state <= HI;
            end
            HI:
            if (byte_valid) begin
              case (ci)
                0: p0 <= {byte_data, low_byte};
                1: p1 <= {byte_data, low_byte};
                2: p2 <= {byte_data, low_byte};
                3: p3 <= {byte_data, low_byte};
              endcase
              if (ci + 1 == colors) begin
                if (mode == 8'h86) state <= GSTART;
                else if (mode == 8'h81 || mode == 8'h88) state <= INDEX;
                else state <= OUT;
              end else begin
                ci <= ci + 1'b1;
                state <= LO;
              end
            end
            INDEX:
            if (byte_valid) begin
              indices <= byte_data;
              index_left <= mode == 8'h88 ? 3 : 7;
              state <= OUT;
            end
            OUT: begin
              if (emitted >= FRAME_PIXELS) fault <= 1;
              else begin
                normal_valid <= 1;
                emitted <= emitted + 1'b1;
                case (mode)
                  8'h80:   normal_pixel <= p0;
                  8'h84:   normal_pixel <= ENABLE_QUAD ? quad_pixel : 16'd0;
                  8'h87:   normal_pixel <= edge_acc[6] ? p0 : p1;
                  default: normal_pixel <= palette_pixel;
                endcase
              end
              if (mode == 8'h87) begin
                if (pix_idx[2:0] == 7) begin
                  edge_row <= edge_row + edge_dy;
                  edge_acc <= edge_row + edge_dy;
                end else edge_acc <= edge_acc + edge_dx;
              end
              if (mode == 8'h81 || mode == 8'h88) begin
                indices <= mode == 8'h88 ? {2'b0, indices[7:2]} : {1'b0, indices[7:1]};
                index_left <= index_left - 1'b1;
                if (index_left == 0) state <= INDEX;
              end
              if (pix_idx == 63) begin
                pix_idx <= 0;
                if (ENABLE_SOLID_RUN && repeat_blocks != 0) begin
                  repeat_blocks <= repeat_blocks - 1'b1;
                  state <= GAP;
                end else state <= OP;
              end else pix_idx <= pix_idx + 1'b1;
            end
            RAW_LO:
            if (byte_valid) begin
              low_byte <= byte_data;
              state <= RAW_HI;
            end
            RAW_HI:
            if (byte_valid) begin
              raw_pixel <= {byte_data, low_byte};
              state <= RAW_OUT;
            end
            RAW_OUT: begin
              if (emitted >= FRAME_PIXELS) fault <= 1;
              else begin
                normal_valid <= 1;
                normal_pixel <= raw_pixel;
                emitted <= emitted + 1'b1;
              end
              if (pix_idx == 63) begin
                state   <= OP;
                pix_idx <= 0;
              end else begin
                pix_idx <= pix_idx + 1'b1;
                state   <= RAW_LO;
              end
            end
            GSTART: state <= GWAIT;
            GWAIT: begin
            end
            default: fault <= 1;
          endcase
      end
    end
  end
endmodule
