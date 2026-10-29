//===================================================================
// OSD text overlay (osd_core) -- 1-cycle pipelined version
//===================================================================
// Overlays a short text string onto the video stream. The video is a
// per-pixel scan, each pixel has coordinate (x, y). This module decides
// whether the current pixel falls inside the text box:
//     inside text 且  font bit set  -> text color
//     otherwise                     -> original image color
//
// char_rom is synchronous-read (BRAM), so the font row arrives 1 cycle
// after the address. To keep everything aligned, de/vs/rgb are also
// delayed 1 cycle. osd_r/g/b are then COMBINATIONAL (based on those
// 1-cycle-delayed signals), so they stay aligned with de_out/vs_out.
//
// Font: 8x16 dots, 16 bytes per char, bit7 = leftmost column.
//===================================================================
module osd_core #(
  parameter       X0     = 0,      // text top-left x
  parameter       Y0     = 0,      // text top-left y
  parameter [7:0] TEXT_R = 8'hFF,
  parameter [7:0] TEXT_G = 8'hFF,
  parameter [7:0] TEXT_B = 8'hFF
) (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       de,       // video valid
  input  wire       vs,       // vertical sync
  input  wire [9:0] pixel_x,  // current pixel x (0..639)
  input  wire [9:0] pixel_y,  // current pixel y (0..479)
  input  wire [7:0] video_r,  // original image RGB
  input  wire [7:0] video_g,
  input  wire [7:0] video_b,
  output reg        de_out,   // de delayed 1 cycle
  output reg        vs_out,   // vs delayed 1 cycle
  output wire [7:0] osd_r,    // overlaid RGB (combinational, aligned)
  output wire [7:0] osd_g,
  output wire [7:0] osd_b
);

  localparam TEXT_LEN = 4;
  localparam CHAR_W   = 8;   // char width 8 px
  localparam CHAR_H   = 16;  // char height 16 px

  // ---- 1. region check ----
  wire       in_x = (pixel_x >= X0) && (pixel_x < X0 + TEXT_LEN * CHAR_W);
  wire       in_y = (pixel_y >= Y0) && (pixel_y < Y0 + CHAR_H);
  wire       in_osd = in_x && in_y && de;

  // ---- 2. decode: relative coord -> char index / col / row ----
  wire [9:0] rel_x = pixel_x - X0;
  wire [9:0] rel_y = pixel_y - Y0;
  wire [2:0] char_idx = rel_x[4:3];  // char index = (x-X0)/8
  wire [2:0] col = rel_x[2:0];  // column = (x-X0)%8
  wire [3:0] row = rel_y[3:0];  // row = y-Y0 (0..15)

  // ---- 3. char code lookup (text string) ----
  reg  [7:0] char_code;
  always @(*) begin
    case (char_idx)
      3'd0: char_code = "F";  // 8'h46
      3'd1: char_code = "P";  // 8'h50
      3'd2: char_code = "G";  // 8'h47
      3'd3: char_code = "A";  // 8'h41
      default: char_code = " ";
    endcase
  end

  // ---- 4. font ROM lookup (synchronous read) ----
  wire [ 6:0] char_index = char_code[6:0] - 7'd32;  // ASCII 0x20..0x7E -> 0..94
  wire [10:0] rom_addr = {char_index, row};
  wire [ 7:0] rom_data;
  char_rom u_char_rom (
    .clk (clk),
    .addr(rom_addr),
    .dout(rom_data)
  );

  // ---- 5. delay 1 cycle to align with the synchronous font ROM ----
  reg [2:0] col_d;
  reg       in_osd_d;
  reg [7:0] video_r_d, video_g_d, video_b_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      col_d     <= 3'd0;
      in_osd_d  <= 1'b0;
      video_r_d <= 8'd0;
      video_g_d <= 8'd0;
      video_b_d <= 8'd0;
      de_out    <= 1'b0;
      vs_out    <= 1'b0;
    end else begin
      col_d     <= col;
      in_osd_d  <= in_osd;
      video_r_d <= video_r;
      video_g_d <= video_g;
      video_b_d <= video_b;
      de_out    <= de;
      vs_out    <= vs;
    end
  end

  wire pix_on = rom_data[7-col_d];  // bit7 = leftmost column

  // ---- 6. color select (combinational, aligned with de_out/vs_out) ----
  assign osd_r = (in_osd_d && pix_on) ? TEXT_R : video_r_d;
  assign osd_g = (in_osd_d && pix_on) ? TEXT_G : video_g_d;
  assign osd_b = (in_osd_d && pix_on) ? TEXT_B : video_b_d;

endmodule
