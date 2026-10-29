// -----------------------------------------------------------------------------
// Module purpose: FAT32 directory enumeration and media playlist metadata.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
//===================================================================
// fat32_list : FAT32 root-directory scanner -> WAV playlist
//===================================================================
// Scans an SD card's FAT32 root directory and collects every *.WAV
// file's 8.3 short name + start sector into a playlist RAM. This is
// the "song list" that the on-screen menu shows, letting the user pick
// a song with the buttons (instead of typing).
//
// Filesystem walk:
//   1) read sector 0
//        - if byte 0 is 0xEB/0xE9 -> it IS the DBR (super-floppy, no MBR)
//        - else it is an MBR -> read the partition LBA at offset 454..457
//   2) read the DBR, parse the FAT32 BPB:
//        BytesPerSector @11, SectorsPerCluster @13, ReservedSectors @14,
//        NumFATs @16, FATSz32 @36, RootCluster @44
//   3) root_dir_sector = partition + Reserved + NumFATs*FATSz
//                        + (RootCluster-2) * SectorsPerCluster
//   4) read the root directory cluster (SectorsPerCluster sectors),
//      walk 32-byte directory entries, and collect every "*.WAV" /
//      "*.wav" short-name entry.
//      Entry identity is checked FIRST:
//        - 0xE5 (deleted)        -> skip
//        - 0x00 (end of directory)-> stop after this sector
//        - attr 0x0F (LFN)       -> skip
//        - attr bit4 0x10 (dir)  -> skip
//        - attr bit3 0x08 (label)-> skip
//      then the extension (bytes 8..10) is compared case-insensitively
//      against "WAV" and the entry is committed at its last byte.
//      [Design note]Before this fix there was NO identity check: the
//      code only tested attr==0x20 && ext=="WAV" while scanning the whole
//      root cluster, so deleted / stale 32-byte slots whose remaining
//      bytes still read "WAV"+0x20 were counted as songs. That is what
//      made song_count=6 on a card holding only 2 WAVs, and the bogus
//      (stale) cluster numbers in those slots are what made wav_reader
//      fail its RIFF check and auto-skip every track.
//
// Playlist: up to MAX_SONGS entries, each = 8-byte ASCII name + 32-bit
// start sector. list_ready goes high when the scan completes.
//===================================================================
module fat32_list #(
  // ================= 【面积回收 A 2026-10-07】歌单深度 32 -> 8 =================
  // 为什么：song_name[32]x64bit + song_sector[32]x32bit = 3072 个寄存器，
  //   是全设计最大的非 IP 寄存器块（占全部 11074 FF 的 ~21%；非 IP 部分 ~32%），
  //   而且 list_name/list_sector 的 32:1 读复用器本身也是 LUT 大户
  //   （gate.area: fat32_list seq=3503，全设计第一）。
  // 为什么安全：写入受 `count < MAX_SONGS` 限制、输出 `song_count <= count`，
  //   顶层 play_song_idx 是按 song_count 取模推进的 ⇒ 索引恒 < song_count <= MAX_SONGS
  //   ⇒ 缩小深度不会越界，本卡只有 2 首，行为完全不变。
  // 以后怎么改回：把 MAX_SONGS 改回 6'd32、IDX_W 改回 3'd5 即可（一行），
  //   数组维度与读索引都跟着参数走，顶层端口宽度不用动。
  parameter [5:0] MAX_SONGS = 6'd8,
  // IDX_W = ceil(log2(MAX_SONGS))：MAX_SONGS=8 -> 3；改回 32 -> 5
  parameter [2:0] IDX_W     = 3'd3
) (
  input wire clk,
  input wire rst,
  input wire scan_start,  // pulse: begin directory scan
  input wire sd_init_done,
  // ---- SD sector-read interface (same handshake as sd_card_top) ----
  output reg sd_sec_read,
  output reg [31:0] sd_sec_read_addr,
  input wire [7:0] sd_sec_read_data,
  input wire sd_sec_read_data_valid,
  input wire sd_sec_read_end,
  // ---- playlist output ----
  output reg list_ready,  // scan done, playlist valid
  output reg [5:0] song_count,  // number of .WAV files found
  input wire [4:0]
        list_idx,  // 0..MAX_SONGS-1 (read back；端口宽度保持 5bit，顶层不用改)
  output reg [63:0] list_name,  // 8-byte ASCII short name
  output reg [31:0] list_sector,  // file start sector (from cluster)

  // [Design note]把内部已经算好的数据区起始扇区暴露给顶层：
  //   顶层接给 sd_card_bmp 的 scan_start_sector，图片扫描直接从数据区起扫，
  //   不再白扫前面 32768 个保留区/FAT 扇区（开机等图 5.4s -> ~10ms）。
  output wire [31:0] data_start_o,  // first sector of the data region

  // [Design note 字节级探针]只读引出扇区0 的 byte0。
  //   本卡是超级软盘（DBR 直接放在扇区0，无 MBR），所以扇区0 的 byte0
  //   就同时是 DBR 的 byte0。纯观测：不参与任何内部判断，mbr_b0 本来就是 reg。
  output wire [7:0] mbr_b0_o,  // byte 0 of sector 0 (= DBR byte0 on this card)

  // [Design note 视频]第一个 .VID 文件的起始扇区（0 = 卡上没有视频文件）。
  //   顶层接给 video_player 的 start_sector；为 0 时顶层直接把视频功能关掉。
  output wire [31:0] video_sector_o,
  // [Design note 视频音轨]第一个 .VAU 文件的起始扇区（0 = 没配专属音轨）。
  //   只在"进入视频模式"时被顶层的一个 1 拍脉冲打进 wav_player 的 track_sel，
  //   平时完全不参与歌单（扩展名不是 WAV，所以不计入 song_count）。
  output wire [31:0] vaudio_sector_o,
  // [Design note 超时恢复]无 .VAU 时才向顶层提供歌单第 5 首备用扇区
  //   .VAU 扫描在真卡上返回 0，这里给顶层一个已知可用的等价音轨。
  output reg [2:0] image_count_o,
  output reg [31:0] image0_o, image1_o, image2_o, image3_o,
  output wire [31:0] fat_start_o,
  output wire [3:0] cluster_shift_o,
  output wire [27:0] max_cluster_o,
  output wire geometry_valid_o,
  output reg filesystem_error_o,
  output wire [31:0] song5_sector_o
);

  localparam ST_IDLE       = 3'd0;
  localparam ST_READ_MBR   = 3'd1;
  localparam ST_READ_DBR   = 3'd2;
  localparam ST_READ_ROOT  = 3'd3;
  localparam ST_DONE       = 3'd4;
  localparam ST_CALC_ROOT  = 3'd5;  // 第 2 级流水：算根目录首扇区
  localparam ST_CALC_ROOT2 = 3'd6;  // 2026-10-13 timing fix: split mul and add

  reg [3:0] state;
  localparam ST_ROOT_FAT = 7, ST_ROOT_GAP = 8, ST_ROOT_CHECK = 9, ST_VOLUME_SHIFT = 10,
      ST_ROOT_SHIFT = 11, ST_ROOT_ADD = 12, ST_ROOT_EVAL = 13;
  reg [3:0] geometry_shift;
  reg [31:0] total_sectors, fat_base_r, volume_clusters;
  reg [15:0] ext_flags;
  reg [27:0] root_current;
  reg [31:0] root_next;
  reg [12:0] root_hops;  // Includes terminal 4096-hop limit.
  reg [ 9:0] root_fat_count;
  reg [ 3:0] spc_shift;
  reg [ 7:0] sec_per_cluster;
  reg [ 9:0] rd_cnt;
  reg [ 7:0] sd_sec_read_data_q;
  reg sd_sec_read_data_valid_q, sd_sec_read_end_q;
  always @(*) begin
    case (sec_per_cluster)
      1: spc_shift = 0;
      2: spc_shift = 1;
      4: spc_shift = 2;
      8: spc_shift = 3;
      16: spc_shift = 4;
      32: spc_shift = 5;
      64: spc_shift = 6;
      128: spc_shift = 7;
      default: spc_shift = 15;
    endcase
  end
  assign fat_start_o = fat_base_r;
  assign cluster_shift_o = spc_shift;
  assign max_cluster_o = volume_clusters[27:0] + 1'b1;
  assign geometry_valid_o = (state == ST_READ_ROOT || state == ST_DONE || state == ST_ROOT_FAT ||
                             state == ST_ROOT_GAP || state == ST_ROOT_CHECK || state ==
                             ST_ROOT_SHIFT || state == ST_ROOT_ADD || state == ST_ROOT_EVAL) &&
      !filesystem_error_o;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      total_sectors <= 0;
      ext_flags <= 0;
    end else if (state == ST_READ_DBR && sd_sec_read_data_valid_q) begin
      case (rd_cnt)
        32: total_sectors[7:0] <= sd_sec_read_data_q;
        33: total_sectors[15:8] <= sd_sec_read_data_q;
        34: total_sectors[23:16] <= sd_sec_read_data_q;
        35: total_sectors[31:24] <= sd_sec_read_data_q;
        40: ext_flags[7:0] <= sd_sec_read_data_q;
        41: ext_flags[15:8] <= sd_sec_read_data_q;
      endcase
    end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      root_fat_count <= 0;
      root_next <= 0;
    end else if (state != ST_ROOT_FAT) begin
      root_fat_count <= 0;
      root_next <= 0;
    end else if (sd_sec_read_data_valid_q) begin
      root_fat_count <= root_fat_count + 1'b1;
      if (root_fat_count[8:2] == root_current[6:0]) begin
        case (root_fat_count[1:0])
          0: root_next[7:0] <= sd_sec_read_data_q;
          1: root_next[15:8] <= sd_sec_read_data_q;
          2: root_next[23:16] <= sd_sec_read_data_q;
          3: root_next[31:24] <= sd_sec_read_data_q;
        endcase
      end
    end
  end

  // ---- parsed filesystem geometry ----
  reg [31:0] partition_start;  // LBA of the partition (0 if super-floppy)
  reg [31:0] bytes_per_sec;  // usually 512
  reg [15:0] reserved_secs;
  reg [ 7:0] num_fats;
  reg [31:0] fat_sz;
  reg [31:0] root_cluster;
  reg [31:0] root_dir_sector;  // computed first sector of root directory
  reg [31:0] data_start;  // first sector of the data region
  reg [31:0] data_start_r;  // 第 1 级流水结果（供第 2 级算 root_dir）

  // [Design note]注意：本 assign 必须放在上面 data_start 的 reg 声明之后，
  // 否则 data_start 会被当成本处隐式声明出来的 1 位 wire，赋出去只有 bit0。
  assign data_start_o = data_start;

  // One local input stage cuts the SD arbiter/byte-counter fanout.
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      sd_sec_read_data_q <= 0;
      sd_sec_read_data_valid_q <= 0;
      sd_sec_read_end_q <= 0;
    end else begin
      sd_sec_read_data_q <= sd_sec_read_data;
      sd_sec_read_data_valid_q <= sd_sec_read_data_valid;
      sd_sec_read_end_q <= sd_sec_read_end;
    end
  end
  // ---- directory-walk state ----
  reg [31:0] cur_sector;  // sector being read
  reg [ 7:0] root_sectors_total;  // sectors in the root cluster
  reg [ 7:0] root_sector_done;  // count of root sectors already read
  reg [ 4:0] entry_off;  // byte offset within a 32-byte entry (0..31)
  reg [63:0] cur_name;  // 8-byte name being assembled
  reg [31:0] cur_cluster;  // cluster of the current entry
  reg        collecting;  // currently collecting a .WAV entry
  reg        is_bmp;
  reg        is_qoi;
  reg        is_qoa;
  reg        is_wav;  // current entry's extension == "WAV"/"wav"
  // [Design note 视频]同时认 .VID 扩展名，记下第一个 .VID 文件的
  //   起始扇区给 video_player 用。为什么不用扫描找：bmp_read 的线性扫描是
  //   每扇区一次事务（164us），视频文件排在音频之后（LBA > 60000），
  //   扫到它要 10 s 以上。FAT 目录里本来就有簇号，一次目录扇区就够了。
  //   代价：一个 32 位比较器 + 一个 32 位寄存器（约 40 LUT）。
  //   没有 .VID 文件时 video_sector_r 保持 0，顶层据此禁用视频。
  reg        is_vid;  // current entry's extension == "VID"/"vid"
  reg        is_vau;  // current entry's extension == "VAU"/"vau"
  // [Design note]目录项"身份"过滤所需的两个状态位。
  //   entry_valid : 当前 32 字节槽是一个有效(未删除)的目录项。
  //                 0xE5 = 已删除槽（内容还在！扩展名仍是 WAV、属性仍是 0x20），
  //                 0x00 = 目录结束标记。两者都必须排除。
  //   dir_end_seen: 已经看到 0x00 结束标记 -> 本扇区读完后立刻收尾，
  //                 不再继续扫根目录簇剩下的 (sec_per_cluster-1) 个扇区。
  //   ⚠ 这两个 reg 的声明必须在下面所有 always 块之前（本会话三次
  //     隐式 1 位 wire 的教训：HDLs 报 undeclared/implicitly declared，
  //     甚至让 optimize_rtl 确定性 coredump）。
  reg        entry_valid;
  reg        dir_end_seen;

  // ---- playlist storage ----
  // 【面积回收 A 2026-10-07】深度由 MAX_SONGS 参数决定（当前 8）：
  //   song_name 省 24x64 = 1536 FF，song_sector 省 24x32 = 768 FF，合计 2304 FF。
  // Six 16-bit words per entry share one narrow RAM. Directory commits
  // are at least 32 byte clocks apart; six write clocks always fit.
  (* ram_style="bram" *)reg [15:0] song_meta                                                [0:(1<<(IDX_W+3))-1];
  reg [95:0] write_shift, read_shift;
  wire [95:0] song_meta_q = read_shift;
  reg [2:0] write_word, read_word;
  reg [IDX_W-1:0] write_idx, read_idx;
  reg read_valid_q;
  reg [15:0] meta_word_q;
  reg [31:0] song5_sector_r;
  reg [5:0] count;
  reg [31:0] song_off_r;
  // Commit one cycle after byte31. With consecutive byte events the
  // following byte is byte0: its name/type resets take effect AFTER
  // the commit edge, so the completed entry remains available here.
  reg video_empty_q, vaudio_empty_q;
  reg entry_commit_q;
  reg image_commit_q, song_commit_q, video_commit_q, vaudio_commit_q;
  reg cluster_valid_q;
  // The cluster completes at byte27, at least four clocks before byte31.
  // Preserve the original unsigned >=2 test while removing this wide
  // comparator from all media register enables and downstream selectors.
  always @(posedge clk or posedge rst) begin
    if (rst) cluster_valid_q <= 0;
    else cluster_valid_q <= (cur_cluster >= 32'd2);
  end
  reg [31:0] entry_sector_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      entry_commit_q  <= 0;
      entry_sector_q  <= 0;
      image_commit_q  <= 0;
      song_commit_q   <= 0;
      video_commit_q  <= 0;
      vaudio_commit_q <= 0;
    end else begin
      entry_commit_q <= state == ST_READ_ROOT && sd_sec_read_data_valid_q && entry_off == 31;
      image_commit_q <= state == ST_READ_ROOT && sd_sec_read_data_valid_q && entry_off == 31 &&
          collecting && (is_bmp || is_qoi) && cluster_valid_q && image_count_o < 4;
      song_commit_q <= state == ST_READ_ROOT && sd_sec_read_data_valid_q && entry_off == 31 &&
          collecting && (is_wav || is_qoa) && count < MAX_SONGS;
      video_commit_q <= state == ST_READ_ROOT && sd_sec_read_data_valid_q && entry_off == 31 &&
          collecting && is_vid && video_empty_q;
      vaudio_commit_q <= state == ST_READ_ROOT && sd_sec_read_data_valid_q && entry_off == 31 &&
          collecting && is_vau && vaudio_empty_q;
      if (state == ST_READ_ROOT && sd_sec_read_data_valid_q && entry_off == 31)
        entry_sector_q <= data_start + song_off_r;
    end
  end
  wire song_commit = song_commit_q;
  always @(posedge clk) begin
    if (write_word < 6) song_meta[{write_idx, write_word}] <= write_shift[15:0];
    meta_word_q <= song_meta[{read_idx, read_word}];
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      write_shift <= 0;
      write_word <= 6;
      write_idx <= 0;
      read_shift <= 0;
      read_word <= 0;
      read_idx <= 0;
      read_valid_q <= 0;
    end else begin
      if (song_commit) begin
        write_shift <= {cur_name, entry_sector_q};
        write_word  <= 0;
        write_idx   <= count[IDX_W-1:0];
      end else if (write_word < 6) begin
        write_shift <= write_shift >> 16;
        write_word  <= write_word + 1'b1;
      end
      if (!list_ready || list_idx >= song_count) begin
        read_valid_q <= 0;
        read_word <= 0;
      end else if (read_idx != list_idx[IDX_W-1:0]) begin
        read_idx <= list_idx[IDX_W-1:0];
        read_word <= 0;
        read_valid_q <= 0;
      end else if (!read_valid_q) begin
        if (read_word != 0) read_shift <= {meta_word_q, read_shift[95:16]};
        if (read_word == 6) read_valid_q <= 1;
        else read_word <= read_word + 1'b1;
      end
    end
  end
  // [Design note 视频]第一个 .VID 文件的起始扇区（单驱动：只在下面的
  //   commit always 块里写，rst 时清 0）
  reg [31:0] video_sector_r;
  assign video_sector_o = video_sector_r;
  reg [31:0] vaudio_sector_r;
  assign vaudio_sector_o = vaudio_sector_r;
  // When a dedicated VAU exists, hide the AMIYA playlist fallback from the
  // video selector.  The top-level mux topology stays unchanged for timing,
  // while video still selects the real DEFT VAU sector on the current card.
  assign song5_sector_o  = (vaudio_sector_r == 32'd0) ? song5_sector_r : 32'd0;

  // ---- MBR byte-0 looks like a DBR (x86 short/near jump)? ----
  reg [7:0] mbr_b0;

  wire is_dbr = (mbr_b0 == 8'hEB) || (mbr_b0 == 8'hE9);

  // [Design note 字节级探针]只读引出 mbr_b0 给顶层数码管观测。
  // ⚠ 本 assign 必须放在上面 `reg [7:0] mbr_b0;` 的声明之后。
  //   上一次"加探针"就是把这个 assign 放进了前面的声明区，于是 mbr_b0
  //   被当成隐式 1 位 wire（8 位驱动 1 位），让 optimize_rtl 变成
  //   确定性 coredump（已确认，证据见同目录
  //   fat32_list.v.bak_prevstripprobe_20261002 里的 [FIX 2026-10-02] 注释）。
  assign mbr_b0_o = mbr_b0;
  // ---- assemble the current entry name (bytes 0..7 of a 32-byte entry) ----
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      cur_name     <= 64'd0;
      cur_cluster  <= 32'd0;
      collecting   <= 1'b0;
      is_wav       <= 1'b0;
      is_bmp       <= 1'b0;
      is_qoi       <= 0;
      is_qoa       <= 0;
      is_vid       <= 1'b0;
      is_vau       <= 1'b0;
      entry_valid  <= 1'b0;
      dir_end_seen <= 1'b0;
    end else begin
      // [Design note]每次扫描开始前清"目录结束"标记（单驱动：只在本块写）
      if (state == ST_IDLE) dir_end_seen <= 1'b0;
      if (state == ST_READ_ROOT && sd_sec_read_data_valid_q) begin
        // byte-level parse of a directory entry
        if (entry_off == 5'd0) begin
          // entry start: first byte tells us the slot's identity
          collecting  <= 1'b0;
          is_wav      <= 1'b0;
          is_bmp      <= 1'b0;
          is_qoi      <= 0;
          is_qoa      <= 0;
          is_vid      <= 1'b0;
          is_vau      <= 1'b0;
          cur_name    <= 64'd0;
          // [Design note 根因]0xE5 = 已删除槽，0x00 = 目录结束标记。
          //   这两类槽的其余 31 字节仍然原样保留（扩展名照样是 WAV、
          //   属性照样是 0x20），老代码只按 attr==0x20 判身份，于是把
          //   目录里的"尸体槽"也当成歌 -> song_count 大于卡上真实歌数，
          //   且这些槽的簇号是旧的/垃圾 -> wav_reader 读不到 RIFF ->
          //   track_bad 自动跳曲（DIG0 一路往上跑）却始终没有声音。
          entry_valid <= (sd_sec_read_data_q != 8'hE5) && (sd_sec_read_data_q != 8'h00);
          if (sd_sec_read_data_q == 8'h00) dir_end_seen <= 1'b1;
        end
        // name bytes 0..7
        case (entry_off)
          5'd0: cur_name[63:56] <= sd_sec_read_data_q;
          5'd1: cur_name[55:48] <= sd_sec_read_data_q;
          5'd2: cur_name[47:40] <= sd_sec_read_data_q;
          5'd3: cur_name[39:32] <= sd_sec_read_data_q;
          5'd4: cur_name[31:24] <= sd_sec_read_data_q;
          5'd5: cur_name[23:16] <= sd_sec_read_data_q;
          5'd6: cur_name[15:8] <= sd_sec_read_data_q;
          5'd7: cur_name[7:0] <= sd_sec_read_data_q;
        endcase
        // extension bytes 8..10 -> check "WAV" / "wav"
        // [Design note]原来只认大写 0x57/0x41/0x56。卡上 8.3 短名一般
        //   由 Windows 强制写成大写、真实大小写记录在偏移 12 的 NT 标志位里
        //   （本卡 `01star.wav` 的短名其实就是 `01STAR  WAV`，所以老代码在这张
        //   卡上"碰巧"能过），但只要短名字节真是小写（某些工具 / 别的 OS /
        //   直接 dd 写入的卡）就会被整体漏掉 -> song_count 偏小、歌单为空。
        //   这里补上小写 'w'/'a'/'v'，实现真正的大小写不敏感。
        if (entry_off == 5'd8)
          is_wav <= (sd_sec_read_data_q == 8'h57) || (sd_sec_read_data_q == 8'h77);  // 'W'/'w'
        if (entry_off == 5'd9)
          is_wav <= is_wav &&
              ((sd_sec_read_data_q == 8'h41) || (sd_sec_read_data_q == 8'h61));  // 'A'/'a'
        if (entry_off == 5'd10)
          is_wav <= is_wav &&
              ((sd_sec_read_data_q == 8'h56) || (sd_sec_read_data_q == 8'h76));  // 'V'/'v'
        // [Design note 视频]extension "VID" / "vid"
        if (entry_off == 5'd8)
          is_vid <= (sd_sec_read_data_q == 8'h56) || (sd_sec_read_data_q == 8'h76);  // 'V'/'v'
        if (entry_off == 5'd9)
          is_vid <= is_vid &&
              ((sd_sec_read_data_q == 8'h49) || (sd_sec_read_data_q == 8'h69));  // 'I'/'i'
        if (entry_off == 5'd10)
          is_vid <= is_vid &&
              ((sd_sec_read_data_q == 8'h44) || (sd_sec_read_data_q == 8'h64));  // 'D'/'d'
        // [Design note 视频音轨]extension "VAU" / "vau"
        //   专门给"视频配的那条音轨"用一个独立扩展名，而不是 .WAV：
        //   .WAV 会被 song_count 收进歌单，正常听歌时也会被轮到，
        //   语义就乱了（那条音轨只在放视频时该响）。
        //   用 .VAU 之后它不进歌单、不占总曲目号，顶层的 PACE
        //   预算仍然按单声道 96 kB/s 预留，与 .VAU 的码率一一对应。
        if (entry_off == 5'd8)
          is_vau <= (sd_sec_read_data_q == 8'h56) || (sd_sec_read_data_q == 8'h76);  // 'V'/'v'
        if (entry_off == 5'd9)
          is_vau <= is_vau &&
              ((sd_sec_read_data_q == 8'h41) || (sd_sec_read_data_q == 8'h61));  // 'A'/'a'
        if (entry_off == 5'd10)
          is_vau <= is_vau &&
              ((sd_sec_read_data_q == 8'h55) || (sd_sec_read_data_q == 8'h75));  // 'U'/'u'
        // Real directory entries only; never discover deleted file contents.
        if (entry_off == 8) is_qoa <= ((sd_sec_read_data_q | 8'h20) == 8'h71);
        if (entry_off == 9) is_qoa <= is_qoa && ((sd_sec_read_data_q | 8'h20) == 8'h6f);
        if (entry_off == 10) is_qoa <= is_qoa && ((sd_sec_read_data_q | 8'h20) == 8'h61);
        if (entry_off == 8) is_qoi <= ((sd_sec_read_data_q | 8'h20) == 8'h71);
        if (entry_off == 9) is_qoi <= is_qoi && ((sd_sec_read_data_q | 8'h20) == 8'h6f);
        if (entry_off == 10) is_qoi <= is_qoi && ((sd_sec_read_data_q | 8'h20) == 8'h69);
        if (entry_off == 8) is_bmp <= ((sd_sec_read_data_q | 8'h20) == 8'h62);
        if (entry_off == 9) is_bmp <= is_bmp && ((sd_sec_read_data_q | 8'h20) == 8'h6d);
        if (entry_off == 10) is_bmp <= is_bmp && ((sd_sec_read_data_q | 8'h20) == 8'h70);
        // cluster: DIR_FstClusHI(offset 20..21) 和 DIR_FstClusLO(offset 26..27)
        // [Design note]这两个字段都是小端 16 位：
        //   offset 20 = HI 的低字节, offset 21 = HI 的高字节
        //   offset 26 = LO 的低字节, offset 27 = LO 的高字节
        // 原来写成了 [31:24]<=20 / [23:16]<=21 / [15:8]<=26 / [7:0]<=27，
        // 等于把两个 16 位半字都当大端读 —— 低半字整体字节交换。
        // 后果：目录项 `77 00`（簇 119）被算成 0x7700 = 30464，
        //       扇区从 34640 变成 520160，读到的完全不是 WAV ->
        //       wav_reader 头校验失败 -> track_bad 死循环 -> 没声音、DIG0 乱跳。
        // 实测对照（新卡 16GB FAT32）：目录项 06/00 -> 簇 6（fsutil LCN 4 +2 ）
        //                              77/00 -> 簇 119（fsutil LCN 117 +2 ）
        //                              C3/0B -> 簇 3011（fsutil LCN 3009 +2 ）
        if (entry_off == 5'd20) cur_cluster[23:16] <= sd_sec_read_data_q;
        if (entry_off == 5'd21) cur_cluster[31:24] <= sd_sec_read_data_q;
        if (entry_off == 5'd26) cur_cluster[7:0] <= sd_sec_read_data_q;
        if (entry_off == 5'd27) cur_cluster[15:8] <= sd_sec_read_data_q;
        // attribute byte 11 -> 0x0F LFN, 0x10 dir, 0x08 volume label
        // [Design note]原来要求属性字节精确等于 0x20，两头都不对：
        //   - 只读的 WAV（attr 0x21 = 只读+归档）会被漏掉；
        //   - 更重要的是"这个槽是不是一个文件"完全靠 0x20 这一条，
        //     没有先排除 LFN(0x0F)/目录(0x10)/卷标(0x08)。
        // 现在：先要求 entry_valid（非 0xE5 非 0x00），再按位排除
        //   LFN / 目录 / 卷标，其余才算普通文件项。
        if (entry_off == 5'd11) begin
          if (entry_valid && (sd_sec_read_data_q != 8'h0F) &&
              ((sd_sec_read_data_q & 8'h18) == 8'h00))
            collecting <= 1'b1;  // a plain file entry
        end
      end
    end
  end

  // ---- commit a collected .WAV entry at the end of its 32 bytes ----
  integer ci;
  // ==================================================================
  // 2026-10-17 TIMING FIX（重做，之前被我误删）
  //
  //   布线后全设计最差路径（−2.400 ns，且最差 8 条里 7 条都是它）：
  //       u_fat32_list/cur_cluster_reg[1]  ->  u_fat32_list/song_sector_reg[*]
  //   原因：这一拍把减、乘、加三件事串成一条链写进 32 位寄存器：
  //       song_sector[c] <= data_start + ((cur_cluster - 2) * sec_per_cluster)
  //   其中乘法（cluster-2)*sec_per_cluster 是主要开销。
  //
  //   修法与 2026-10-13 修 ST_CALC_ROOT 时完全同型：把乘法提前一拍、
  //   用寄存器承载，写入那一拍只做一次 32 位加法。
  //   entry_off 在 ST_READ_ROOT 里随 sd_sec_read_data_valid_q 走 0..31，
  //   所以 entry_off==30 正好是 entry_off==31 提交的前一拍；
  //   而 cur_cluster（在 offset 27 装完）/ sec_per_cluster / data_start
  //   在整个目录扇区读期间都是稳的，提前采样取到的是同一个值。
  //
  //   这是纯流水线改动，不改语义：
  //     · 同样的 entry_off==31 才写入 song_sector
  //     · 只是乘法的结果早一拍算好
  //   ⚠️ 为什么必须修：歌单工作在 100 MHz 域，这条路径只有 ~7.6 ns 余量，
  //      出错会导致歌曲扇区取错 → 选曲失败 → 没声音。
  //      而音频的正常选曲路径完全依赖歌单（list_sector ->
  //      track_sel_sector -> wav_player，不扫描），所以歌单错 = 音频废。
  //   回退：把 song_off_r 那一段删掉，并把下面的加法改回行内表达式。
  // ==================================================================
  // [Design note 时序]原来这一拍做「减 2 + 相乘」，实测是 sd_card_clk 域的
  //   第 1 名违规路径（-0.050ns，lvl=4：cur_cluster -> song_off_r.mi）。
  //   照 root_cluster 的既有做法拆成两级流水：
  //     第 1 级：cur_m2_r  <= cur_cluster - 2      （每拍都算，起于寄存器）
  //     第 2 级：song_off_r <= cur_m2_r * sec_per_cluster
  //   等价性：cur_cluster 在目录项的第 26/27 字节装好，到 entry_off==30 已经
  //   稳定 3 拍，所以第 2 级用"上一拍的 cur_m2_r"取到的就是同一个值 
  reg [31:0] song_m2_r;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      song_m2_r  <= 32'd0;
      song_off_r <= 32'd0;
    end else begin
      song_m2_r <= (cur_cluster >= 32'd2) ? (cur_cluster - 32'd2) : 32'd0;
      if (state == ST_READ_ROOT && sd_sec_read_data_valid_q && entry_off == 5'd30)
        song_off_r <= cluster_offset(song_m2_r, sec_per_cluster);
    end
  end

  // Entries are at least 32 byte events apart, so the local empty flags
  // settle long before another VID/VAU commit can occur.

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      video_empty_q  <= 1;
      vaudio_empty_q <= 1;
    end else begin
      video_empty_q  <= (video_sector_r == 0);
      vaudio_empty_q <= (vaudio_sector_r == 0);
    end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      count <= 6'd0;
      video_sector_r <= 32'd0;
      image_count_o <= 0;
      image0_o <= 0;
      image1_o <= 0;
      image2_o <= 0;
      image3_o <= 0;
      vaudio_sector_r <= 32'd0;
      // 【面积回收 A】循环上界必须跟着 MAX_SONGS（原来硬编码 32）：
      //   TD 对数组下标做静态范围检查，越界会报 HDL-8007 并把整个模块
      //   变成 black box（网表里逻辑直接消失），所以要显式写在范围内。
      song5_sector_r <= 0;
    end else begin
      if (image_commit_q) begin
        case (image_count_o)
          0: image0_o <= entry_sector_q;
          1: image1_o <= entry_sector_q;
          2: image2_o <= entry_sector_q;
          3: image3_o <= entry_sector_q;
        endcase
        image_count_o <= image_count_o + 1'b1;
      end
      if (song_commit_q) begin
        // 【面积回收 A】用 count 的低 IDX_W 位做下标：count<MAX_SONGS 已保证
        //   不越界，但这里显式截断是为了让 TD 的静态范围检查通过
        //   （否则 HDL-8007 -> black box，且黑盒网表照样能生成"新"bit，
        //     时间戳闸门抓不到 —— 已实测踩过）。

        // cluster -> sector: data_start + song_off_r
        //   乘法已在上面预寄存，这里只做一次 32 位加法。
        if (count == 5) song5_sector_r <= entry_sector_q;
        count <= count + 6'd1;
      end
      // [Design note 视频]第一个 .VID 文件的起始扇区（同样只做一次加法）
      if (video_commit_q) video_sector_r <= entry_sector_q;
      // [Design note 视频音轨]第一个 .VAU 文件的起始扇区。
      //   和 .VID 一样"只认第一个"，多放了也只会取第一个，避免选择逻辑。
      if (vaudio_commit_q) vaudio_sector_r <= entry_sector_q;
    end
  end

  // ---- byte offset within sector + directory entry offset ----
  // [Design note]原来第一支写的是
  //     else if (state == ST_READ_ROOT && sd_sec_read_data_valid_q)
  //   于是"在 ST_READ_ROOT 但这一拍没有数据"会掉进最后一个 else，把
  //   rd_cnt / entry_off 清零。真机 SPI 是 25MHz（SPI_HIGH_SPEED_DIV=0
  //   -> 100/4），sd_sec_read_data_valid_q 是每 4 拍才 1 拍高，所以
  //   entry_off 被反复清零、永远到不了 8/9/10/11/31：
  //     - byte8..10 的 "WAV" 判断失效
  //     - byte11 的 collecting 置不起来
  //     - entry_off==31 的提交永不触发
  //   -> song_count 恒为 0。
  //   而 MBR/DBR 那一支是只看 state 的 else if，空洞拍不清零（只在
  //   sd_sec_read_end_q 清），所以分区/BPB 几何一直解析正确 —— 这正好解释
  //   了"根目录扇区地址算得对、34 个扇区全读完、却一首歌都没收集到"。
  //   历史测试台的 SD 模型都是"每拍一个字节"，所以这个 bug 一直没暴露；
  //   现在用带空洞的模型可复现（见 tb/fat32_gap_tb.v，GAP>=2 即 count=0）。
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      rd_cnt <= 10'd0;
      entry_off <= 5'd0;
    end else if (state == ST_READ_ROOT) begin
      // 只有真正收到字节才前进；空洞拍保持不动
      if (sd_sec_read_data_valid_q) begin
        rd_cnt    <= rd_cnt + 10'd1;
        entry_off <= entry_off + 5'd1;
      end
    end else if (state == ST_READ_MBR || state == ST_READ_DBR) begin
      if (sd_sec_read_data_valid_q) rd_cnt <= rd_cnt + 10'd1;
      else if (sd_sec_read_end_q) rd_cnt <= 10'd0;
    end else begin
      rd_cnt <= 10'd0;
      entry_off <= 5'd0;
    end
  end

  // ---- geometry capture (MBR + DBR) ----
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      mbr_b0          <= 8'd0;
      partition_start <= 32'd0;
      bytes_per_sec   <= 32'd0;
      sec_per_cluster <= 8'd0;
      reserved_secs   <= 16'd0;
      num_fats        <= 8'd0;
      fat_sz          <= 32'd0;
      root_cluster    <= 32'd0;
    end else if (state == ST_READ_MBR && sd_sec_read_data_valid_q) begin
      case (rd_cnt)
        10'd0:   mbr_b0 <= sd_sec_read_data_q;
        // [Design note]只有"真的是 MBR"时，字节 454..457 才是
        // 分区起始 LBA。超级软盘（DBR 直接放在 0 号扇区，is_dbr=1）
        // 时那 4 字节是 DBR 里的启动提示文字（例如 "ss any key..."），
        // 取进来会把 data_start 污染成天文数字 -> root_dir_sector 全错
        // -> 根目录读不到东西 -> song_count = 0。
        // 实测（16GB FAT32 超级软盘）：这 4 字节 = 73 73 20 61 = 0x61207373，
        // 加上 reserved/fat 后 root_dir 变成 19 亿。
        10'd454: partition_start[7:0] <= is_dbr ? 8'd0 : sd_sec_read_data_q;
        10'd455: partition_start[15:8] <= is_dbr ? 8'd0 : sd_sec_read_data_q;
        10'd456: partition_start[23:16] <= is_dbr ? 8'd0 : sd_sec_read_data_q;
        10'd457: partition_start[31:24] <= is_dbr ? 8'd0 : sd_sec_read_data_q;
        default: ;
      endcase
    end else if (state == ST_READ_DBR && sd_sec_read_data_valid_q) begin
      case (rd_cnt)
        10'd11:  bytes_per_sec[7:0] <= sd_sec_read_data_q;
        10'd12:  bytes_per_sec[15:8] <= sd_sec_read_data_q;
        10'd13:  sec_per_cluster <= sd_sec_read_data_q;
        10'd14:  reserved_secs[7:0] <= sd_sec_read_data_q;
        10'd15:  reserved_secs[15:8] <= sd_sec_read_data_q;
        10'd16:  num_fats <= sd_sec_read_data_q;
        10'd36:  fat_sz[7:0] <= sd_sec_read_data_q;
        10'd37:  fat_sz[15:8] <= sd_sec_read_data_q;
        10'd38:  fat_sz[23:16] <= sd_sec_read_data_q;
        10'd39:  fat_sz[31:24] <= sd_sec_read_data_q;
        10'd44:  root_cluster[7:0] <= sd_sec_read_data_q;
        10'd45:  root_cluster[15:8] <= sd_sec_read_data_q;
        10'd46:  root_cluster[23:16] <= sd_sec_read_data_q;
        10'd47:  root_cluster[31:24] <= sd_sec_read_data_q;
        default: ;
      endcase
    end
  end

  // Device has spare DSPs. Registered products use fewer LUTs than a
  // wide case mux for all eight legal sectors-per-cluster values.
  function [31:0] cluster_offset;
    input [31:0] c;
    input [7:0] spc;
    begin
      cluster_offset = c * spc;
    end
  endfunction
  // ---- computed geometry（分两级流水，见下）----
  // 第 1 级：data_start = partition + reserved + num_fats*fat_sz
  // BPB bytes16/39/41 settle long before DBR byte511. These rare
  // mount calculations have independent pipeline registers; no chained
  // multiply/add/subtract must complete at the state transition.
  reg [31:0] fat_span_q, overhead_q, reserved_base_q, active_span_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      fat_span_q <= 0;
      overhead_q <= 0;
      reserved_base_q <= 0;
      active_span_q <= 0;
    end else begin
      fat_span_q <= num_fats * fat_sz;
      overhead_q <= {16'd0, reserved_secs} + fat_span_q;
      reserved_base_q <= partition_start + {16'd0, reserved_secs};
      active_span_q <= ext_flags[7] ? ext_flags[3:0] * fat_sz : 32'd0;
    end
  end
  wire [31:0] data_start_w = partition_start + overhead_q;
  // 第 2 级：用已寄存的 data_start_r 再算根目录扇区
  //   root_dir = data_start + (root_cluster-2)*sec_per_cluster
  // 2026-10-13 TIMING FIX (merged): worst sd_card_clk path was
  //   u_fat32_list/root_cluster_reg[*] -> sd_sec_read_addr_reg[*] / cur_sector_reg[*]
  //   delay 11.71ns, level 8, requirement 10ns.  One cycle chained
  //   subtract + multiply + add.  Split it: this stage computes only the
  //   cluster offset, the next stage does a single 32-bit add.
  // [Design note TIMING]再来一级：把「减 2」和「乘 sec_per_cluster」拆到两个时钟。
  //   原式 (root_cluster-2)*sec_per_cluster 一拍算完，实测
  //       root_cluster_reg[*] -> root_cluster_off_r_reg[*]  5 级，ADDER×4 + MULT18×1，-0.331 ns
  //   并且同一个源头还带出另外两条违例（-> sd_card_cmd/state, -0.191 / -0.167）。
  //   root_cluster 与 sec_per_cluster 在 DBR 解析后就一直稳定（远早于 ST_CALC_ROOT），
  //   所以这两级自由流水多花 2 拍没有任何时序/功能影响，只是把一条长锥切成三段。
  reg  [31:0] root_m2_r;  // 第 1 级：root_cluster - 2
  reg  [31:0] root_off_mul_r;  // 第 2 级：× sec_per_cluster
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      root_m2_r      <= 32'd0;
      root_off_mul_r <= 32'd0;
    end else begin
      root_m2_r      <= root_cluster - 32'd2;
      root_off_mul_r <= cluster_offset(root_m2_r, sec_per_cluster);
    end
  end
  reg [31:0] root_cluster_off_r;
  always @(posedge clk or posedge rst) begin
    if (rst) root_cluster_off_r <= 32'd0;
    else if (state == ST_CALC_ROOT) root_cluster_off_r <= root_off_mul_r;
  end

  wire [31:0] root_dir_w2 = data_start_r + root_cluster_off_r;

  // BPB fields finish by byte47 and are consumed at end-of-sector.
  // Register the validity reduction instead of routing it through the
  // state/list_ready enables in the same cycle (measured WNS -4.619ns).
  reg geometry_bad_q;
  always @(posedge clk or posedge rst) begin
    if (rst) geometry_bad_q <= 1;
    else
      geometry_bad_q <= spc_shift > 7 || bytes_per_sec != 512 || fat_sz == 0 ||
          total_sectors == 0 || (ext_flags[7] && ext_flags[3:0] >= num_fats);
  end
  reg [27:0] max_cluster_local_q;
  // Geometry settles long before the root FAT sector. Only this stable
  // bound is pipelined: root_next can finish at the last sector byte,
  // so its compare must see the current parsed value at end-of-sector.
  always @(posedge clk or posedge rst) begin
    if (rst) max_cluster_local_q <= 0;
    else max_cluster_local_q <= max_cluster_o;
  end
  wire root_next_bad = root_next[27:0] < 2 || root_next[27:0] > max_cluster_local_q ||
      root_next[27:0] == root_current || root_next[27:0] == root_cluster[27:0] || root_hops >= 4096;
  // Classify at the same completed-sector edge as the old consumer,
  // then consume on the following cycle. This deliberately adds a wait
  // stage: root_next at bytes508..511 must never be compared one byte early.
  reg root_count_bad_q, root_eoc_q, root_bad_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      root_count_bad_q <= 1;
      root_eoc_q <= 0;
      root_bad_q <= 1;
    end else begin
      root_count_bad_q <= root_fat_count != 512;
      root_eoc_q <= root_next[27:0] >= 28'hffffff8;
      root_bad_q <= root_next_bad;
    end
  end
  // ---- main state machine ----
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state              <= ST_IDLE;
      sd_sec_read        <= 1'b0;
      sd_sec_read_addr   <= 32'd0;
      list_ready         <= 1'b0;
      song_count         <= 6'd0;
      cur_sector         <= 32'd0;
      root_sectors_total <= 32'd0;
      root_sector_done   <= 32'd0;
      data_start_r       <= 32'd0;
      data_start         <= 32'd0;
      root_dir_sector    <= 32'd0;
      filesystem_error_o <= 0;
      fat_base_r         <= 0;
      volume_clusters    <= 0;
      geometry_shift     <= 0;
      root_current       <= 0;
      root_hops          <= 0;
    end else if (!sd_init_done) begin
      state       <= ST_IDLE;
      sd_sec_read <= 1'b0;
      list_ready  <= 1'b0;
    end else begin
      case (state)
        ST_IDLE: begin
          list_ready  <= 1'b0;
          sd_sec_read <= 1'b0;
          if (scan_start) begin
            filesystem_error_o <= 0;
            root_hops <= 0;
            sd_sec_read_addr <= 32'd0;  // sector 0 (MBR or DBR)
            state <= ST_READ_MBR;
          end
        end

        ST_READ_MBR: begin
          sd_sec_read <= 1'b1;
          if (sd_sec_read_end_q) begin
            sd_sec_read <= 1'b0;
            if (is_dbr) begin
              // super-floppy: DBR is at sector 0
              sd_sec_read_addr <= 32'd0;
            end else begin
              // MBR: read the DBR at the partition LBA
              sd_sec_read_addr <= partition_start;
            end
            state <= ST_READ_DBR;
          end
        end

        ST_READ_DBR: begin
          sd_sec_read <= 1'b1;
          if (sd_sec_read_end_q) begin
            sd_sec_read        <= 1'b0;
            // 第 1 级流水：只把 data_start 寄存下来。
            // 原来这里同一拍还要用 root_dir_w（依赖 data_start_w）
            // 去写 sd_sec_read_addr，等于把两个"乘法+加法"串在
            // 一个 100MHz 周期里：实测 12.35ns / 6~8 级逻辑，
            // Fmax 只有 79.2MHz（时序报告里 u_fat32_list 的
            // root_cluster -> sd_sec_read_addr 共 243 个违例端点）。
            data_start_r       <= data_start_w;
            root_sectors_total <= sec_per_cluster;
            root_sector_done   <= 32'd0;
            if (geometry_bad_q) begin
              filesystem_error_o <= 1;
              list_ready <= 1;
              state <= ST_DONE;
            end else state <= ST_CALC_ROOT;
          end
        end

        // 第 2 级流水：这时 data_start_r 已经稳定，独占一个周期算
        // root_dir，再进 ST_READ_ROOT 发起读。多花 1 个周期，
        // 但每次扫描只走一次，对功能无影响。
        ST_CALC_ROOT: begin
          // 2026-10-13 timing fix: only compute+register the cluster offset here.
          data_start      <= data_start_r;
          fat_base_r      <= reserved_base_q + active_span_q;
          // Geometry calculations are rare. Reuse the result registers as a
          // one-bit-per-clock shifter instead of two wide barrel networks.
          volume_clusters <= total_sectors - overhead_q;
          geometry_shift  <= spc_shift;
          root_current    <= root_cluster[27:0];
          state           <= ST_VOLUME_SHIFT;
        end

        ST_VOLUME_SHIFT: begin
          if (geometry_shift != 0) begin
            volume_clusters <= volume_clusters >> 1;
            geometry_shift  <= geometry_shift - 1'b1;
          end else state <= ST_CALC_ROOT2;
        end

        ST_CALC_ROOT2: begin
          // 2026-10-13 timing fix: offset is stable now, single 32-bit add.
          root_dir_sector  <= root_dir_w2;
          cur_sector       <= root_dir_w2;
          sd_sec_read_addr <= root_dir_w2;
          state            <= ST_READ_ROOT;
        end

        ST_READ_ROOT: begin
          sd_sec_read <= 1'b1;
          if (sd_sec_read_end_q) begin
            sd_sec_read <= 1'b0;
            root_sector_done <= root_sector_done + 8'd1;
            // [Design note]看到 0x00 目录结束标记就收尾。
            //    FAT 规定 0x00 之后不再有有效目录项，而根目录按
            //    "簇"分配（本卡 sec_per_cluster=16 = 8192 字节），
            //    512 字节之后的 15 个扇区里可能残留旧目录内容。
            //    老代码无条件把整簇 16 个扇区全扫完，把那些残留槽
            //    也当歌收进歌单 -> song_count 比卡上真实歌数大，
            //    且它们的簇号是旧的 -> 全部 track_bad。
            //    顺带把根目录扫描从 16 个扇区降到 1 个（启动更快）。
            if (dir_end_seen) begin
              // end-of-directory seen, or whole root cluster read
              list_ready <= 1'b1;
              song_count <= count;
              state <= ST_DONE;
            end else if (({1'b0, root_sector_done} + 9'd1) >= {1'b0, root_sectors_total}) begin
              sd_sec_read_addr <= fat_base_r + {11'd0, root_current[27:7]};
              state <= ST_ROOT_GAP;
            end else begin
              cur_sector <= cur_sector + 32'd1;
              sd_sec_read_addr <= cur_sector + 32'd1;
            end
          end
        end

        ST_ROOT_GAP: begin
          sd_sec_read <= 0;
          state <= ST_ROOT_FAT;
        end
        ST_ROOT_FAT: begin
          sd_sec_read <= 1;
          if (sd_sec_read_end_q) begin
            sd_sec_read <= 0;
            state <= ST_ROOT_EVAL;
          end
        end
        ST_ROOT_EVAL: begin
          sd_sec_read <= 0;
          root_current <= root_next[27:0];
          root_hops <= root_hops + 1'b1;
          if (root_count_bad_q) begin
            filesystem_error_o <= 1;
            state <= ST_DONE;
            list_ready <= 1;
            song_count <= count;
          end else if (root_eoc_q) begin
            state <= ST_DONE;
            list_ready <= 1;
            song_count <= count;
          end else if (root_bad_q) begin
            filesystem_error_o <= 1;
            state <= ST_DONE;
            list_ready <= 1;
            song_count <= count;
          end else state <= ST_ROOT_CHECK;
        end

        ST_ROOT_CHECK: begin
          cur_sector <= root_current - 2;
          geometry_shift <= spc_shift;
          state <= ST_ROOT_SHIFT;
        end
        ST_ROOT_SHIFT: begin
          if (geometry_shift != 0) begin
            cur_sector <= cur_sector << 1;
            geometry_shift <= geometry_shift - 1'b1;
          end else state <= ST_ROOT_ADD;
        end
        ST_ROOT_ADD: begin
          cur_sector <= data_start + cur_sector;
          sd_sec_read_addr <= data_start + cur_sector;
          root_sector_done <= 0;
          state <= ST_READ_ROOT;
        end
        ST_DONE: begin
          sd_sec_read <= 1'b0;
          list_ready  <= 1'b1;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // Synchronous RAM read. track_ctrl delays its selection pulse by one cycle.
  always @(*) begin
    list_name   = read_valid_q ? song_meta_q[95:32] : 64'd0;
    list_sector = read_valid_q ? song_meta_q[31:0] : 32'd0;
  end
endmodule
