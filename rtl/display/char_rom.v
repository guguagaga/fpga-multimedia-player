// Synchronous 8x16 ASCII font ROM loaded from font_8x16.mem.
// addr = (ASCII - 0x20) * 16 + row; bit 7 is the leftmost pixel.
// Contains 95 printable characters; dout follows addr by one clock.
module char_rom (
  input  wire        clk,
  input  wire [10:0] addr,  // char_index*16 + row
  output reg  [ 7:0] dout   // one font row, 8 bits = 8 columns
);

  reg [7:0] rom[0:1519];  // 1520 bytes font

  initial $readmemh("font_8x16.mem", rom);

  always @(posedge clk) dout <= rom[addr];

endmodule
