`timescale 1ns / 1ps
// Audio-domain elastic timeline. Each displayed video frame authorizes one
// frame of PCM. Video presentation credit follows consumed samples, with a
// small lead for the next display blanking boundary. Stalls cannot accumulate
// audio lead. I2S clocks continue during buffering; no PCM is discarded.
module av_sample_sync #(
  parameter integer LEAD_SAMPLES = 960
) (
  input wire clk, rst,
  input wire enable_sd, started_sd, paused_sd, draining_sd,
  input wire frame_toggle_sd,
  input wire [12:0] samples_per_frame_sd,
  input wire sample_valid,
  output wire sample_allow,
  output reg time_toggle,
  output wire buffering
);
  reg [1:0] enable_q, started_q, paused_q, draining_q;
  reg [2:0] frame_q;
  reg [12:0] period_q0, period_q1;
  reg frame_seen, was_enabled;
  reg [14:0] budget;
  reg [12:0] phase;
  wire frame_event = frame_q[2] != frame_seen;
  wire [12:0] period = (period_q1 >= 13'd1600 && period_q1 <= 13'd3200) ? period_q1 : 13'd3200;
  // High-rate startup credit must fall BETWEEN display refreshes. At30fps,
  // half a frame is exactly one60Hz refresh: tiny clock/CDC phase differences
  // could move a ready frame to that earlier refresh. Three quarters of a
  // frame gives1200samples (25ms), centered between16.67ms and33.33ms.
  // Lower rates use LEAD_SAMPLES. Samples are neither skipped nor
  // duplicated; this changes only when the next presentation is authorized.
  wire [12:0] first_phase = (period > LEAD_SAMPLES) ? period - LEAD_SAMPLES : period - (period >> 2);
  wire consuming = enable_q[1] && started_q[1] && sample_valid && !draining_q[1];
  assign
      sample_allow = !enable_q[1] || draining_q[1] || (started_q[1] && !paused_q[1] && budget != 0);
  assign buffering = enable_q[1] && started_q[1] && !paused_q[1] && budget == 0;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      enable_q <= 0;
      started_q <= 0;
      paused_q <= 0;
      draining_q <= 0;
      frame_q <= 0;
      period_q0 <= 3200;
      period_q1 <= 3200;
      frame_seen <= 0;
      was_enabled <= 0;
      budget <= 0;
      phase <= 2240;
      time_toggle <= 0;
    end else begin
      enable_q <= {enable_q[0], enable_sd};
      started_q <= {started_q[0], started_sd};
      paused_q <= {paused_q[0], paused_sd};
      draining_q <= {draining_q[0], draining_sd};
      frame_q <= {frame_q[1:0], frame_toggle_sd};
      period_q0 <= samples_per_frame_sd;
      period_q1 <= period_q0;
      was_enabled <= enable_q[1];
      frame_seen <= frame_q[2];
      if (!enable_q[1] || !was_enabled) begin
        budget <= 0;
        phase  <= first_phase;
      end else begin
        if (!started_q[1]) phase <= first_phase;
        case ({
          frame_event, consuming
        })
          2'b10: budget <= budget + period;
          2'b01: if (budget != 0) budget <= budget - 1'b1;
          2'b11: budget <= budget + period - 1'b1;
        endcase
        if (consuming && budget != 0) begin
          if (phase == 1) begin
            phase <= period;
            time_toggle <= ~time_toggle;
          end else phase <= phase - 1'b1;
        end
      end
    end
  end
endmodule
