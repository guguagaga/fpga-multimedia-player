// Synchronous ROM for W_256^k = cos(2*pi*k/256) - j*sin(2*pi*k/256).
// twiddle_256.mem holds 128 complex entries, with signed Q15 real/imaginary halves.
// Outputs follow addr by one clock.
module twiddle_rom (
  input  wire        clk,
  input  wire [ 6:0] addr,  // twiddle index 0..127
  output reg  [15:0] re,    // real part cos (Q15)
  output reg  [15:0] im     // imag part -sin (Q15)
);

  reg [31:0] mem[0:127];

  initial $readmemh("twiddle_256.mem", mem);

  always @(posedge clk) begin
    re <= mem[addr][31:16];  // high 16 bits = real
    im <= mem[addr][15:0];  // low 16 bits = imag
  end

endmodule
