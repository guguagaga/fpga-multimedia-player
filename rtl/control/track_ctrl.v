`timescale 1ns/1ps
//===================================================================
// track_ctrl : 多曲目顺序播放控制器（切歌）
//===================================================================
// 职责：把"曲目索引"变成"wav_reader 的起播扇区请求"。
//
//   - 它自己不存歌单：扇区由 fat32_list 按 list_idx 给出，
//     所以同一个 song_idx 既用于取扇区，也用于 OSD 显示歌名
//     （顶层把 song_idx 接到 fat32_list 的 list_idx 即可）。
//   - 曲目播完（wav_reader 给 track_end）时：auto_en=1 则自动下一首，
//     否则停在原处等用户按下一首。
//   - 遇到坏文件向后尝试；整张歌单都非法时停止持续重试。
//
// 索引一律按 song_count 取模，所以"下一首"在末尾会回到第一首。
//===================================================================
module track_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 歌单元数据 ----
    input  wire        list_ready,      // 歌单扫描完成
    input  wire [5:0]  song_count,      // 歌单里有多少首
    input  wire [31:0] sel_sector_in,   // 当前 song_idx 对应的 WAV 起始扇区
                                        // （由 fat32_list 组合给出，不需要本模块缓存）
    // ---- 按键事件（1 拍脉冲）----
    input  wire        next_req,
    input  wire        prev_req,
    input  wire        auto_togg,       // 自动续播 开/关
    // ---- wav_reader 反馈 ----
    input  wire        track_end,
    input  wire        track_bad,
    // ---- 输出 ----
    output reg  [5:0]  song_idx,        // 当前曲目号（同时给 OSD 显示歌名）
    output reg         track_sel_valid, // 1 拍脉冲：请 wav_reader 载入下面的扇区
    output wire [31:0] track_sel_sector,
    output reg         auto_en          // 自动续播使能（给 OSD 显示）
);

    // 有歌可播才允许操作
    wire have_any = list_ready && (song_count != 6'd0);

    // 是否已经发起过至少一次选曲。
    // 歌单就绪后**必须主动选一次第 0 首**，否则 wav_reader 会上电自己从头
    // 扫描找第一个 WAV —— 那可能不是歌单里的第 0 首，导致"播放的内容"和
    // OSD 显示的歌名对不上。
    reg select_pending;reg [3:0] select_delay;
    // Narrow playlist metadata takes seven read clocks after index change.
    // Repeated commands restart the delay; the latest index wins.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin track_sel_valid<=0;select_delay<=0;end
        else begin
            track_sel_valid<=0;
            if(select_pending)select_delay<=10;
            else if(select_delay!=0)begin
                select_delay<=select_delay-1'b1;
                if(select_delay==1)track_sel_valid<=1;
            end
        end
    end
    reg sel_done;
    reg [5:0] bad_skips;

    // ---- 索引推进 ----
    // 下一个 / 上一个索引：按 song_count 取模（末尾回卷）
    reg [5:0] nxt;
    always @(*) begin
        if (!have_any)                          nxt = 6'd0;
        else if (song_idx + 6'd1 >= song_count) nxt = 6'd0;
        else                                    nxt = song_idx + 6'd1;
    end

    reg [5:0] prv;
    always @(*) begin
        if (!have_any)             prv = 6'd0;
        else if (song_idx == 6'd0) prv = song_count - 6'd1;
        else                       prv = song_idx - 6'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            song_idx        <= 6'd0;
            select_pending <= 1'b0;
            auto_en         <= 1'b1;    // 默认自动续播（整张专辑连着放）
            sel_done        <= 1'b0;
            bad_skips       <= 6'd0;
        end else begin
            select_pending <= 1'b0;

            if (auto_togg) auto_en <= ~auto_en;

            if (have_any) begin
                if (!sel_done) begin
                    // 歌单刚就绪：主动选第 0 首，保证"播放内容"和
                    // "OSD 显示的歌名"从第一首起就一致
                    song_idx        <= 6'd0;
                    select_pending <= 1'b1;
                    sel_done        <= 1'b1;
                    bad_skips       <= 6'd0;
                end else if (next_req) begin
                    // 用户按"下一首"
                    song_idx        <= nxt;
                    select_pending <= 1'b1;
                    bad_skips       <= 6'd0;
                end else if (prev_req) begin
                    // 用户按"上一首"
                    song_idx        <= prv;
                    select_pending <= 1'b1;
                    bad_skips       <= 6'd0;
                end else if (track_bad) begin
                    // Stop after one complete unsuccessful playlist traversal.
                    if (bad_skips + 6'd1 < song_count) begin
                        song_idx        <= nxt;
                        select_pending <= 1'b1;
                        bad_skips       <= bad_skips + 6'd1;
                    end
                end else if (track_end && auto_en) begin
                    // 一曲放完：自动续播
                    song_idx        <= nxt;
                    select_pending <= 1'b1;
                    bad_skips       <= 6'd0;
                end
                // track_end 且 !auto_en：什么都不做，停在结束状态等用户操作
                if (track_end) bad_skips <= 6'd0;
            end else begin
                sel_done <= 1'b0;
                bad_skips <= 6'd0;
            end
        end
    end

    // 起播扇区直接透传（在 track_sel_valid 那一拍由歌单按 song_idx 组合给出）
    assign track_sel_sector = sel_sector_in;

endmodule
