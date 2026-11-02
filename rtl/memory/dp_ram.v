// Common-clock dual-port RAM with synchronous writes and one-cycle reads.
// Each port returns the stored value sampled at the clock edge.
// The caller schedules accesses to avoid conflicting writes to the same address.
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
