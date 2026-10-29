// -----------------------------------------------------------------------------
// Module purpose: Audio transition envelope and command handoff.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
// SD-domain command sequencer. Fade acknowledgement is synchronized from
// the audio domain only after gain zero and two physical I2S frame edges.
// Latest selection wins while fading. Sector is captured a cycle after the
// input pulse, matching the top's existing registered destination contract.
module audio_transition #(
  parameter [27:0] WATCHDOG = 28'd250000000
) (
  input wire clk, rst, select_req,
  input wire [31:0] select_sector,
  input wire seek_req, pause_req, reader_ready, reader_bad, mute_ack,
  output wire mute_req, reader_pause,
  output reg select_out, seek_out,
  output reg [31:0] sector_out,
  output wire busy,
  output reg timeout_seen
);
  localparam RUN = 0, FADE = 1, WAIT_LOW = 2, WAIT_READY = 3;
  reg [1:0] state;
  reg sel_q, seek_q, pending_select, pending_seek;
  reg [31:0] pending_sector;
  reg [27:0] wd;
  assign mute_req = (state != RUN) || pause_req || sel_q || seek_q;
  assign reader_pause = (state == RUN) && pause_req && mute_ack;
  assign busy = (state != RUN) || sel_q || seek_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= RUN;
      sel_q <= 0;
      seek_q <= 0;
      pending_select <= 0;
      pending_seek <= 0;
      pending_sector <= 0;
      sector_out <= 0;
      select_out <= 0;
      seek_out <= 0;
      wd <= 0;
      timeout_seen <= 0;
    end else begin
      sel_q <= select_req;
      seek_q <= seek_req;
      select_out <= 0;
      seek_out <= 0;
      if (state == RUN || state == FADE) wd <= 0;
      else if (wd < WATCHDOG) wd <= wd + 1'b1;
      case (state)
        RUN: if (sel_q || seek_q || (pause_req && !mute_ack)) state <= FADE;
        FADE:
        if (mute_ack && !sel_q && !seek_q) begin
          if (pending_select) begin
            select_out <= 1;
            sector_out <= pending_sector;
            pending_select <= 0;
            pending_seek <= 0;
            state <= WAIT_LOW;
          end else if (pending_seek && reader_ready) begin
            seek_out <= 1;
            pending_seek <= 0;
            state <= WAIT_LOW;
          end else begin
            pending_seek <= 0;
            state <= RUN;
          end
        end
        WAIT_LOW:
        if (!reader_ready) begin
          wd <= 0;
          state <= WAIT_READY;
        end
        WAIT_READY:
        if (reader_ready || reader_bad) begin
          state <= (pending_select || pending_seek) ? FADE : RUN;
          wd <= 0;
        end
      endcase
      // Recover control availability after a missing media response. The reader
      // itself still owns and safely completes any physical SD transaction.
      if ((state == WAIT_LOW || state == WAIT_READY) && wd >= WATCHDOG) begin
        timeout_seen <= 1;
        state <= (pending_select || pending_seek) ? FADE : RUN;
        wd <= 0;
      end
      if (sel_q) begin
        pending_select <= 1;
        pending_sector <= select_sector;
        pending_seek   <= 0;
        if (state == RUN) state <= FADE;
      end else if (seek_q && !pending_select) begin
        pending_seek <= 1;
        if (state == RUN) state <= FADE;
      end
    end
  end
endmodule
