//===================================================================
// True dual-port RAM (dp_ram) -- SYNCHRONOUS read version (BRAM)
//===================================================================
// Write: synchronous (posedge clk + we)
// Read : synchronous (posedge clk, data valid next cycle)
//
// This synchronous-read form lets the synthesizer map the RAM into a
// block RAM (BRAM), which frees up LUTs. The combinational-read version
// (assign dout = mem[addr]) forces distributed RAM = huge LUT usage,
// which blew past the EG4S20 LUT limit.
//
// The FFT uses it to store 256 complex numbers (one RAM for real, one
// for imag). A butterfly reads addr_a/addr_b, then writes back to the
// same addresses (on a later cycle, so no read/write conflict).
//===================================================================
module dp_ram #(
  parameter DEPTH = 256,
  parameter WIDTH = 16
) (
  input  wire             clk,
  input  wire             wea,
  webb,  // write enable
  input  wire [      7:0] addra,
  addrb,  // address
  input  wire [WIDTH-1:0] dina,
  dinb,  // write data
  output reg  [WIDTH-1:0] douta,
  doutb  // read data (1 cycle after addr)
);

  reg [WIDTH-1:0] mem[0:DEPTH-1];

  always @(posedge clk) begin
    if (wea) mem[addra] <= dina;
    if (webb) mem[addrb] <= dinb;
    douta <= mem[addra];  // synchronous read (read-before-write on same addr)
    doutb <= mem[addrb];
  end

endmodule
