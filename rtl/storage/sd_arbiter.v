`timescale 1ns / 1ps
// Arbitrate complete sector transactions; hold owner and address until completion.
// New grants require IDLE and an expired cooldown. Eligible urgent audio has
// priority; otherwise img_priority selects the directory/image preference.
// With normal priority, a waiting image is considered after 15 audio grants.
// Video uses remaining grants and may consume already-filled physical cache data.
module sd_arbiter #(
  parameter integer PREFETCH_AWARE = 0,
  parameter integer MAX_DEFER_CYCLES = 1_000_000
) (
  input wire defer_audio,
  input  wire        clk,
  input  wire        rst,
  // ---- image client (sd_card_bmp) ----
  input  wire        img_sd_sec_read,
  input  wire [31:0] img_sd_sec_read_addr,
  output wire [ 7:0] img_sd_sec_read_data,
  output wire        img_sd_sec_read_data_valid,
  output wire        img_sd_sec_read_end,
  // ---- audio client (wav_reader) ----
  input  wire        wav_sd_sec_read,
  input  wire [31:0] wav_sd_sec_read_addr,
  output wire [ 7:0] wav_sd_sec_read_data,
  output wire        wav_sd_sec_read_data_valid,
  output wire        wav_sd_sec_read_end,
  // ---- playlist client (fat32_list) ----
  input  wire        fat_sd_sec_read,
  input  wire [31:0] fat_sd_sec_read_addr,
  output wire [ 7:0] fat_sd_sec_read_data,
  output wire        fat_sd_sec_read_data_valid,
  output wire        fat_sd_sec_read_end,
  // ---- video client (video_player) ----
  input  wire        vid_sd_sec_read,
  input  wire [31:0] vid_sd_sec_read_addr,
  output wire [ 7:0] vid_sd_sec_read_data,
  output wire        vid_sd_sec_read_data_valid,
  output wire        vid_sd_sec_read_end,
  // Directory/image preference supplied by startup and PCM-water-level logic.
  input  wire        img_priority,                // Directory/image preference from the integration.
  output wire        wav_grant,
  output wire        img_grant,
  // vid_grant identifies the owner for the top-level sequential-read policy.
  output wire        vid_grant,
  // ---- shared SD card (sd_card_top) ----
  output wire        sd_sec_read,
  output wire [31:0] sd_sec_read_addr,
  input  wire [ 7:0] sd_sec_read_data,
  input  wire        sd_sec_read_data_valid,
  input  wire        sd_sec_read_end
);

  localparam IDLE = 1'b0, SERV = 1'b1;
  localparam [1:0] SEL_IMG = 2'd0, SEL_WAV = 2'd1, SEL_FAT = 2'd2, SEL_VID = 2'd3;

  reg        state;
  reg [ 1:0] sel;
  reg [31:0] address_latched;
  reg [ 3:0] wav_run;  // Consecutive normal-priority audio grants.
  // Leave COOLDOWN idle clocks after a sector completes so the shared transport
  // can retire its response before a new owner is granted.
  localparam [4:0] COOLDOWN = 5'd15;
  reg [4:0] cool;

  // A saturated wait counter raises audio priority at the next eligible grant.
  // It does not interrupt a live transaction or bypass cooldown/audio eligibility.
  localparam integer WAV_WAIT_MAX = 20_000;
  reg  [15:0] wav_wait_cnt;
  wire        wav_urgent = (wav_wait_cnt >= WAV_WAIT_MAX[15:0]);

  // 计数：不请求时清零；被授权（进入 SERV 且 sel 是 WAV）时清零；否则累加
  always @(posedge clk or posedge rst) begin
    if (rst) wav_wait_cnt <= 16'd0;
    else if (!wav_sd_sec_read) wav_wait_cnt <= 16'd0;
    else if ((state == SERV) && (sel == SEL_WAV)) wav_wait_cnt <= 16'd0;
    else if (wav_wait_cnt != WAV_WAIT_MAX[15:0]) wav_wait_cnt <= wav_wait_cnt + 16'd1;
  end

  // A new audio miss cannot use the card during a physical video burst.
  // With sufficient PCM reserve, leave ownership free for cache-hit video
  // requests until that burst ends. Never revoke an accepted transaction.
  // Saturating timeout preserves eventual admission even if busy sticks.
  localparam integer DEFER_W = $clog2(MAX_DEFER_CYCLES+1);
  reg [DEFER_W-1:0] defer_count;
  wire defer_expired = defer_count == MAX_DEFER_CYCLES;
  wire audio_eligible = wav_sd_sec_read &&
      (!PREFETCH_AWARE || !defer_audio || defer_expired);
  always @(posedge clk or posedge rst) begin
    if (rst) defer_count <= 0;
    else if (!PREFETCH_AWARE || !wav_sd_sec_read || ((state == SERV) && (sel == SEL_WAV)))
      defer_count <= 0;
    else if (defer_audio && !defer_expired)
      defer_count <= defer_count + 1'b1;
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= IDLE;
      sel <= SEL_IMG;
      address_latched <= 32'd0;
      wav_run <= 4'd0;
      cool <= 5'd0;
    end else begin
      // 事务中预装 COOLDOWN，事务结束后倒数到 0 才允许再授权
      if (state == SERV) cool <= COOLDOWN;
      else if (cool != 5'd0) cool <= cool - 5'd1;
      case (state)
        IDLE: begin
          // Evaluate requests only after cooldown; quota counters advance on grants.
          if (cool == 5'd0) begin
            // Service urgent audio when the request is eligible at this idle boundary.
            if (wav_urgent && audio_eligible) begin
              sel <= SEL_WAV;
              state <= SERV;
              address_latched <= wav_sd_sec_read_addr;
              wav_run <= 0;
            end else if (img_priority) begin
              // Directory/image preference; urgent eligible audio is handled above.
              if (fat_sd_sec_read) begin
                sel <= SEL_FAT;
                state <= SERV;
                address_latched <= fat_sd_sec_read_addr;
                wav_run <= 0;
              end else if (img_sd_sec_read) begin
                sel <= SEL_IMG;
                state <= SERV;
                address_latched <= img_sd_sec_read_addr;
                wav_run <= 0;
              end else if (audio_eligible) begin
                sel <= SEL_WAV;
                state <= SERV;
                address_latched <= wav_sd_sec_read_addr;
                wav_run <= 0;
              end else if (vid_sd_sec_read) begin
                sel <= SEL_VID;
                state <= SERV;
                address_latched <= vid_sd_sec_read_addr;
                wav_run <= 0;
              end
            end else begin
              // Normal preference with an image opportunity after 15 audio grants.
              if (img_sd_sec_read && wav_run == 4'd15) begin
                sel <= SEL_IMG;
                state <= SERV;
                address_latched <= img_sd_sec_read_addr;
                wav_run <= 0;
              end else if (audio_eligible) begin
                sel <= SEL_WAV;
                state <= SERV;
                address_latched <= wav_sd_sec_read_addr;
                if (wav_run != 4'd15) wav_run <= wav_run + 1'b1;
              end else if (img_sd_sec_read) begin
                sel <= SEL_IMG;
                state <= SERV;
                address_latched <= img_sd_sec_read_addr;
                wav_run <= 0;
              end else if (fat_sd_sec_read) begin
                sel <= SEL_FAT;
                state <= SERV;
                address_latched <= fat_sd_sec_read_addr;
                wav_run <= 0;
              end else if (vid_sd_sec_read) begin
                sel <= SEL_VID;
                state <= SERV;
                address_latched <= vid_sd_sec_read_addr;
                wav_run <= 0;
              end
            end
          end  // cool==0 守卫
        end
        SERV: begin
          if (sd_sec_read_end) state <= IDLE;
        end
        default: state <= IDLE;
      endcase

    end
  end

  wire serving_img = (state == SERV) && (sel == SEL_IMG);
  wire serving_wav = (state == SERV) && (sel == SEL_WAV);
  wire serving_fat = (state == SERV) && (sel == SEL_FAT);
  wire serving_vid = (state == SERV) && (sel == SEL_VID);

  // ---- forward the selected client's request to the SD card ----
  // Ownership includes the complete transaction even if a client cancels.
  assign sd_sec_read                = (state == SERV);
  assign sd_sec_read_addr           = address_latched;
  assign wav_grant                  = serving_wav;
  assign img_grant                  = serving_img;
  assign vid_grant                  = serving_vid;

  // ---- fan the SD card response back to the selected client ----
  assign wav_sd_sec_read_data       = serving_wav ? sd_sec_read_data : 8'd0;
  assign wav_sd_sec_read_data_valid = serving_wav & sd_sec_read_data_valid;
  assign wav_sd_sec_read_end        = serving_wav & sd_sec_read_end;

  assign img_sd_sec_read_data       = serving_img ? sd_sec_read_data : 8'd0;
  assign img_sd_sec_read_data_valid = serving_img & sd_sec_read_data_valid;
  assign img_sd_sec_read_end        = serving_img & sd_sec_read_end;

  assign fat_sd_sec_read_data       = serving_fat ? sd_sec_read_data : 8'd0;
  assign fat_sd_sec_read_data_valid = serving_fat & sd_sec_read_data_valid;
  assign fat_sd_sec_read_end        = serving_fat & sd_sec_read_end;

  assign vid_sd_sec_read_data       = serving_vid ? sd_sec_read_data : 8'd0;
  assign vid_sd_sec_read_data_valid = serving_vid & sd_sec_read_data_valid;
  assign vid_sd_sec_read_end        = serving_vid & sd_sec_read_end;

endmodule
