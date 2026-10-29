// spi_sniffer.v - on-chip SD card SPI byte-stream capture (2 KB, real ERAM).
//
// WHAT IT GIVES US
//   The complete real-card byte stream around one sector read:
//       ... 51 <4B addr> <fill ~1540 bytes> FE <512 data> ...
//   On-board fill-counter measurements (2 samples): 1,536 and 1,544 bytes
//   between the CMD17 byte and the 0xFE token - the card dribbles ~1,540
//   bytes of 0xFF before the data token, which is why a 512 B sector costs
//   554 us instead of 164 us (0.91 MB/s instead of 3.12).
//
//   Three CMD18 multi-block attempts failed on the real card while the
//   SPI simulation was byte-perfect, so we need the real stream, not a model.
//
// LEARNED THE HARD WAY (do not repeat)
//   1. Never name a signal `buf` - it is a reserved Verilog keyword (the gate
//      primitive).  iverilog says "invalid module item", TD says HDL-8007.
//   2. A wide vector (reg [16383:0] cap) is NOT a RAM to the synthesiser: TD
//      maps it to LUTs (20716 > 9800 slice limit).  A RAM needs an ARRAY.
//   3. An array only becomes ERAM if the read is SYNCHRONOUS, and the official
//      way to force it is the attribute (* ram_style = "bram" *).
//
// READOUT
//   dbg_byte walks the capture at ~2 Hz (0.5 s per byte), wrapping at 2048.
//   On freeze the walk starts 64 bytes before the token, i.e. right at the
//   fill -> token -> data transition.  Two 7-seg hex digits + dp for `frozen`.
//
// COST  2 ERAM blocks (2 KB) + ~40 LUT, in no functional path.

module spi_sniffer (
  input            clk,
  input            rst,
  input            byte_valid,
  input      [7:0] byte_data,
  output reg       frozen,
  output reg [7:0] dbg_byte,
  output reg [7:0] dbg_idx
);

  // ---- 2 KB capture, forced into ERAM ----
  (* ram_style = "bram" *)reg [ 7:0] mem      [0:2047];

  reg [10:0] wp;
  reg [10:0] rp;
  reg [25:0] step_cnt;
  reg [ 5:0] post_cnt;
  reg        seen_cmd;
  reg        seen_tok;
  reg        hold;

  // capture write port (single write port, gated)
  always @(posedge clk) begin
    if (byte_valid && !hold) mem[wp] <= byte_data;
  end

  // display read port - MUST be an unconditional synchronous read so the
  // tool infers ERAM instead of LUTs
  always @(posedge clk) begin
    dbg_byte <= mem[rp];
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      wp       <= 11'd0;
      rp       <= 11'd0;
      step_cnt <= 26'd0;
      post_cnt <= 6'd0;
      seen_cmd <= 1'b0;
      seen_tok <= 1'b0;
      hold     <= 1'b0;
      frozen   <= 1'b0;
      dbg_idx  <= 8'd0;
    end else begin
      if (byte_valid && !hold) begin
        wp <= wp + 11'd1;
        // CMD17 = 0x51, CMD18 = 0x52
        if (byte_data == 8'h51 || byte_data == 8'h52) begin
          seen_cmd <= 1'b1;
          seen_tok <= 1'b0;
        end
        if (seen_cmd && byte_data == 8'hfe) seen_tok <= 1'b1;
        // keep 32 bytes after the token, then freeze and put the walk
        // right at the fill -> token -> data transition
        if (seen_tok) begin
          if (post_cnt == 6'd31) begin
            hold     <= 1'b1;
            frozen   <= 1'b1;
            seen_cmd <= 1'b0;
            seen_tok <= 1'b0;
            rp       <= wp - 11'd63;
          end else post_cnt <= post_cnt + 6'd1;
        end
      end
      // walk: 0.5 s per byte at 100 MHz
      if (step_cnt == 26'd49999999) begin
        step_cnt <= 26'd0;
        rp       <= rp + 11'd1;
        dbg_idx  <= rp[7:0];
      end else step_cnt <= step_cnt + 26'd1;
    end
  end

endmodule
