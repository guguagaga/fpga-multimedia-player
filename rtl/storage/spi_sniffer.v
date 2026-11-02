// Read-only SPI receive-byte capture with a 2 KiB synchronous RAM.
// Freeze after the selected command/token window, then walk stored bytes
// through diagnostic outputs. Capture does not drive media requests.

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
