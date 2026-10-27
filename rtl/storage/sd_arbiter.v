`timescale 1ns/1ps
// Sector arbiter: fat > image > audio before the first display frame.
// After boot, audio is preferred; a waiting image gets a turn after at
// most three consecutive audio sectors. The address and request are held
// for the complete transaction, even when the originating client cancels.
//
// 【2026-10-17 视频】第 4 个客户端 = video_player，优先级**最低**。
//   为什么最低就够用：SPI 是 25 MHz，一个扇区 164 us，而音频每 5.3 ms 才要
//   一个扇区（96 kB/s），SD 总线约 97% 的时间是空的。视频拿这些空闲时间就能
//   跑到约 3.0 MB/s。反过来若把视频放到高优先级，音频会欠载（async_fifo 只有
//   32 ms 余量）。
//   把视频放在最后还意味着：**不插视频时，三个老客户端的仲裁顺序一位都不变**，
//   所以图片/音频/歌单的行为与改之前逐拍相同。
// 【2026-10-17 视频】4th client = video_player, LOWEST priority.
//   Rationale: at 25 MHz SPI a sector takes 164 us but the audio client only
//   needs one every 5.3 ms (96 kB/s), so ~97% of the bus is idle and that is
//   already enough for ~3.0 MB/s of video.  Putting video last also keeps the
//   three existing clients bit-for-bit identical when no video is playing.
module sd_arbiter (
    input  wire        clk,
    input  wire        rst,
    // ---- image client (sd_card_bmp) ----
    input  wire        img_sd_sec_read,
    input  wire [31:0] img_sd_sec_read_addr,
    output wire [7:0]  img_sd_sec_read_data,
    output wire        img_sd_sec_read_data_valid,
    output wire        img_sd_sec_read_end,
    // ---- audio client (wav_reader) ----
    input  wire        wav_sd_sec_read,
    input  wire [31:0] wav_sd_sec_read_addr,
    output wire [7:0]  wav_sd_sec_read_data,
    output wire        wav_sd_sec_read_data_valid,
    output wire        wav_sd_sec_read_end,
    // ---- playlist client (fat32_list) ----
    input  wire        fat_sd_sec_read,
    input  wire [31:0] fat_sd_sec_read_addr,
    output wire [7:0]  fat_sd_sec_read_data,
    output wire        fat_sd_sec_read_data_valid,
    output wire        fat_sd_sec_read_end,
    // ---- video client (video_player) ----
    input  wire        vid_sd_sec_read,
    input  wire [31:0] vid_sd_sec_read_addr,
    output wire [7:0]  vid_sd_sec_read_data,
    output wire        vid_sd_sec_read_data_valid,
    output wire        vid_sd_sec_read_end,
    // ---- image priority (first image not yet shown) ----
    input  wire        img_priority,   // 1 = before first image shown
    output wire        wav_grant,
    output wire        img_grant,
    // 【2026-10-17 多块读】1 = 当前这一笔交易属于视频客户端。
    //   只有视频是"纯顺序 + 高带宽"的流，值得用 CMD18 一次读 16 块；
    //   音频/目录/图片都是随机或低频访问，走原来的单块 CMD17 路径
    //   （否则预取会把别的客户端的缓冲挤掉，反而更慢）。
    output wire        vid_grant,
    // ---- shared SD card (sd_card_top) ----
    output wire        sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);

    localparam IDLE = 1'b0, SERV = 1'b1;
    localparam [1:0] SEL_IMG = 2'd0, SEL_WAV = 2'd1, SEL_FAT = 2'd2,
                     SEL_VID = 2'd3;

    reg        state;
    reg  [1:0] sel;
    reg [31:0] address_latched;
    reg [3:0] wav_run;   // 【2026-10-22 寻道摊薄】2 位->4 位，配额 3->15
    // ========================================================================
    // 【2026-10-20 稳定性】事务之间强制插入 COOLDOWN 拍空隙。
    //
    //   原来 SERV 在 sd_sec_read_end 的同一拍就回 IDLE，下一拍立刻可以授给下一个
    //   客户端 ⇒ 背靠背事务之间**只有 1 个时钟**。只跑音频时事务间隔 5ms，毫无问题；
    //   但视频一起来抢卡，事务就变成背靠背：
    //       SERV(视频) → IDLE(1拍) → SERV(音频) → IDLE(1拍) → SERV(视频) ...
    //   SD 核收到 read_end 之后还需要几拍才能完全回位（CS 撤销 / 内部状态机回收），
    //   1 拍空隙下它可能被下一次请求直接打断 ⇒ 返回的扇区数据错乱。
    //   这与现场现象完全吻合：**只有"视频 + 音频同时读卡"时才出现，而且不稳定**。
    //
    //   代价：每扇区多 16 拍 = 0.16 µs。视频每秒约 1000 扇区 ⇒ 多花 0.016% 带宽，
    //   可以忽略。只改"何时允许开始下一笔"，不动授给谁/地址锁存/数据回送。
    // ========================================================================
    localparam [4:0] COOLDOWN = 5'd15;
    reg  [4:0] cool;

    // ============================================================================
    // 【2026-10-23 音频最久等待上限】★让轮播预取可以安全打开的关键★
    //
    //   问题：原优先级只看【水位】(img_loading & fifo_usedw[13]) 和【配额】(wav_run==15)。
    //         一旦图片流变成"几乎一直在请求"（例如轮播预取），水位门控经常放行图片，
    //         音频分到的带宽可能掉到 96 kB/s 以下 => 8 KB FIFO 慢慢见底 =>
    //         上板实测：自动切图约 6 分钟后"没音乐的死锁" ✗
    //
    //   修法：给音频加一个【最久等待】硬上限。wav 的请求挂着超过 WAV_WAIT_MAX 拍，
    //         就【无条件】授权音频一次（唯一的例外是冷却期 cool，那是总线协议要求）。
    //         => 音频吞吐下限 = 1 扇区 / WAV_WAIT_MAX 拍，与谁在抢无关 ✓
    //
    //   取值：20000 拍 @100MHz = 200 us => 1 扇区/200us = 2.56 MB/s，
    //         远高于音频需要的 96 kB/s；同时又不会把视频/图片饿死
    //         （最多插一个扇区就轮到别人）。
    // ============================================================================
    localparam integer WAV_WAIT_MAX = 20_000;
    reg  [15:0] wav_wait_cnt;
    wire        wav_urgent = (wav_wait_cnt >= WAV_WAIT_MAX[15:0]);

    // 计数：不请求时清零；被授权（进入 SERV 且 sel 是 WAV）时清零；否则累加
    always @(posedge clk or posedge rst) begin
        if (rst)
            wav_wait_cnt <= 16'd0;
        else if (!wav_sd_sec_read)
            wav_wait_cnt <= 16'd0;
        else if ((state == SERV) && (sel == SEL_WAV))
            wav_wait_cnt <= 16'd0;
        else if (wav_wait_cnt != WAV_WAIT_MAX[15:0])
            wav_wait_cnt <= wav_wait_cnt + 16'd1;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            sel   <= SEL_IMG;
            address_latched <= 32'd0;
            wav_run <= 4'd0;
            cool  <= 5'd0;
        end else begin
            // 事务中预装 COOLDOWN，事务结束后倒数到 0 才允许再授权
            if (state == SERV)          cool <= COOLDOWN;
            else if (cool != 5'd0)      cool <= cool - 5'd1;
            case (state)
                IDLE: begin
                    // 【2026-10-22 饿死修复】冷却期间**不评估仲裁**。
                    //   原来冷却只靠后面的"无条件覆盖"抑制授权，但 case 里的
                    //   `wav_run <= wav_run + 1` 仍然执行 ⇒ 配额被空转消耗；
                    //   COOLDOWN=16 正好是 wav_run 4 相循环的整数倍 ⇒ 每次冷却
                    //   结束都停在同一相位 ⇒ 一旦该相位对应图片，音频就永久饿死。
                    if (cool == 5'd0) begin
                    // 【2026-10-23】音频最久等待上限：无条件抢先于所有客户端
                    //   （img_priority 期间本来是图片/目录优先，这里也让音频插队：
                    //     首图窗口很短，插一扇区不影响开机；但能彻底避免饿死）
                    if (wav_urgent && wav_sd_sec_read) begin
                        sel <= SEL_WAV; state <= SERV;
                        address_latched <= wav_sd_sec_read_addr; wav_run <= 0;
                    end else if (img_priority) begin
                        // boot: fat scan first, then image, then audio
                        if (fat_sd_sec_read) begin
                            sel <= SEL_FAT; state <= SERV;
                            address_latched <= fat_sd_sec_read_addr; wav_run <= 0;
                        end else if (img_sd_sec_read) begin
                            sel <= SEL_IMG; state <= SERV;
                            address_latched <= img_sd_sec_read_addr; wav_run <= 0;
                        end else if (wav_sd_sec_read) begin
                            sel <= SEL_WAV; state <= SERV;
                            address_latched <= wav_sd_sec_read_addr; wav_run <= 0;
                        end else if (vid_sd_sec_read) begin
                            sel <= SEL_VID; state <= SERV;
                            address_latched <= vid_sd_sec_read_addr; wav_run <= 0;
                        end
                    end else begin
                        // after boot: bounded audio priority
                        if (img_sd_sec_read && wav_run == 4'd15) begin
                            sel <= SEL_IMG; state <= SERV;
                            address_latched <= img_sd_sec_read_addr; wav_run <= 0;
                        end else if (wav_sd_sec_read) begin
                            sel <= SEL_WAV; state <= SERV;
                            address_latched <= wav_sd_sec_read_addr;
                            if (wav_run != 4'd15) wav_run <= wav_run + 1'b1;
                        end else if (img_sd_sec_read) begin
                            sel <= SEL_IMG; state <= SERV;
                            address_latched <= img_sd_sec_read_addr; wav_run <= 0;
                        end else if (fat_sd_sec_read) begin
                            sel <= SEL_FAT; state <= SERV;
                            address_latched <= fat_sd_sec_read_addr; wav_run <= 0;
                        end else if (vid_sd_sec_read) begin
                            sel <= SEL_VID; state <= SERV;
                            address_latched <= vid_sd_sec_read_addr; wav_run <= 0;
                        end
                    end
                    end   // cool==0 守卫
                end
                SERV: begin
                    if (sd_sec_read_end)
                        state <= IDLE;
                end
                default: state <= IDLE;
            endcase

            // 【2026-10-20 稳定性】冷却期内**取消任何刚发出的授权**。
            //   Verilog 里同一 always 块内后写的赋值优先，所以这里可以无条件覆盖
            //   上面 case 里刚设置的 state/sel/address_latched：保持 IDLE、
            //   地址与选择都维持原值，等 cool 归零后再按当拍的请求重新仲裁。
            // （原"无条件覆盖"已删除：改由 IDLE 分支的 cool==0 守卫实现）
        end
    end

    wire serving_img = (state == SERV) && (sel == SEL_IMG);
    wire serving_wav = (state == SERV) && (sel == SEL_WAV);
    wire serving_fat = (state == SERV) && (sel == SEL_FAT);
    wire serving_vid = (state == SERV) && (sel == SEL_VID);

    // ---- forward the selected client's request to the SD card ----
    // Ownership includes the complete transaction even if a client cancels.
    assign sd_sec_read = (state == SERV);
    assign sd_sec_read_addr = address_latched;
    assign wav_grant = serving_wav;
    assign img_grant = serving_img;
    assign vid_grant = serving_vid;

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
