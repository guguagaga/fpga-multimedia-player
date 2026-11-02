// FAT32 mount, media discovery, and runtime image-directory cursor.
// Accept either a partitioned volume or a DBR at sector zero, then parse
// 512-byte sector geometry and follow the root-directory cluster chain.
// Ignore deleted, long-name, directory, and volume-label entries. The
// short-name extension identifies supported media. Music/video metadata
// is collected at mount; image lookup resumes from the stored directory slot.
module fat32_list #(
  // Bound startup music metadata by MAX_SONGS. Runtime image lookup uses
  // a directory cursor and is independent of this table capacity.
  parameter [5:0] MAX_SONGS = 6'd8,
  // IDX_W is the address width required by MAX_SONGS.
  parameter [2:0] IDX_W     = 3'd3,
  parameter STREAM_IMAGES = 0
) (
  input wire clk,
  input wire rst,
  // Runtime cursor shares the mount parser. Music/video metadata is frozen.
  input wire image_pause, image_consume, sd_read_error,
  output reg image_valid, image_empty, image_error,
  output reg [31:0] image_lba,
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
        list_idx,  // Address range 0..MAX_SONGS-1.
  output reg [63:0] list_name,  // 8-byte ASCII short name
  output reg [31:0] list_sector,  // file start sector (from cluster)

  // Expose mounted data-region geometry to the media readers.
  output wire [31:0] data_start_o,  // first sector of the data region

  // Expose sector-zero byte zero for read-only mount diagnostics.
  output wire [7:0] mbr_b0_o,  // Byte zero of sector zero.

  // First discovered VID start sector; zero indicates that none was found.
  output wire [31:0] video_sector_o,
  output reg media_entry_valid,
  output reg media_entry_audio,
  output reg [15:0] media_entry_prefix,
  output wire [31:0] media_entry_sector,

  // First discovered VAU start sector. VAU files are kept outside the music list.
  output wire [31:0] vaudio_sector_o,
  // Expose the configured fallback music sector only when no dedicated VAU exists.
  output reg [3:0] image_count_o,
  output reg [31:0] image0_o, image1_o, image2_o, image3_o,
  output reg [31:0] image4_o, image5_o, image6_o, image7_o,
  output wire [27:0] root_cluster_o,
  output wire [31:0] fat_start_o,
  output wire [3:0] cluster_shift_o,
  output wire [27:0] max_cluster_o,
  output wire geometry_valid_o,
  output reg filesystem_error_o,
  output wire [31:0] song5_sector_o
);

  localparam ST_IDLE = 20'h00001;
  localparam ST_READ_MBR = 20'h00002;
  localparam ST_READ_DBR = 20'h00004;
  localparam ST_READ_ROOT = 20'h00008;
  localparam ST_DONE = 20'h00010;
  localparam ST_CALC_ROOT = 20'h00020;  // 第 2 级流水：算根目录首扇区
  localparam ST_CALC_ROOT2 = 20'h00040;  // Separate cluster offset preparation from address addition.

  // One-hot reachable-state decode reduces shared binary decode fanout.
  reg [19:0] state;
  localparam ST_IMAGE_ISSUE = 20'h04000, ST_IMAGE_END = 20'h08000, ST_IMAGE_HOLD = 20'h10000,
             ST_IMAGE_ADVANCE = 20'h20000, ST_IMAGE_WRAP = 20'h40000, ST_IMAGE_STOP = 20'h80000;
  reg runtime_images, image_found, image_pending, image_wrapped, image_read_bad;
  reg [4:0] image_start_entry, image_resume_entry;
  reg image_size_nonzero, image_cluster_ok;
  wire parse_entry;
  localparam ST_ROOT_FAT = 20'h00080, ST_ROOT_GAP = 20'h00100, ST_ROOT_CHECK = 20'h00200, ST_VOLUME_SHIFT = 20'h00400,
      ST_ROOT_SHIFT = 20'h00800, ST_ROOT_ADD = 20'h01000, ST_ROOT_EVAL = 20'h02000;
  reg [3:0] geometry_shift;
  reg [31:0] total_sectors, fat_base_r, volume_clusters;
  reg [15:0] ext_flags;
  reg [27:0] root_current;
  reg [31:0] root_next;
  reg [27:0] root_hops;  // Bounded by the mounted volume, not a file-count cap.
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
  assign geometry_valid_o = (list_ready || state[3] || state[4] || state[7] ||
                             state[8] || state[9] || state[11] || state[12] || state[13]) &&
      !filesystem_error_o;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      total_sectors <= 0;
      ext_flags <= 0;
    end else if (state[2] && sd_sec_read_data_valid_q) begin
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
    end else if (!state[7]) begin
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

  // Drive geometry outputs from the declared full-width registers.
  assign data_start_o = data_start;
  assign root_cluster_o = root_cluster[27:0];

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
  // Resolve video locations from directory clusters instead of scanning media data.
  reg        is_vid;  // current entry's extension == "VID"/"vid"
  reg        is_vau;  // current entry's extension == "VAU"/"vau"
  // Track slot validity independently of extension and attributes. Deleted
  // entries and the directory-end marker never become media candidates.
  reg        entry_valid;
  reg        dir_end_seen;

  // Store each music entry in six 16-bit RAM words. Directory commits and
  // playlist reads share the narrow memory to limit register and mux cost.
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
  // The cluster field completes at byte27 before the byte31 commit. Register
  // the unsigned cluster>=2 predicate before it drives media write enables.
  always @(posedge clk or posedge rst) begin
    if (rst) cluster_valid_q <= 0;
    else cluster_valid_q <= (cur_cluster >= 32'd2);
  end
  reg [31:0] entry_sector_q;
  assign media_entry_sector = entry_sector_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      media_entry_valid <= 0;
      media_entry_audio <= 0;
      media_entry_prefix <= 0;
      entry_commit_q  <= 0;
      entry_sector_q  <= 0;
      image_commit_q  <= 0;
      song_commit_q   <= 0;
      video_commit_q  <= 0;
      vaudio_commit_q <= 0;
    end else begin
      media_entry_valid <= !runtime_images && state[3] && sd_sec_read_data_valid_q && entry_off == 31 &&
                           collecting && cluster_valid_q && (is_vid || is_vau);
      if (state[3] && sd_sec_read_data_valid_q && entry_off == 31) begin
          media_entry_audio <= is_vau;
          media_entry_prefix <= cur_name[63:48];
      end
      entry_commit_q <= state[3] && sd_sec_read_data_valid_q && entry_off == 31;
      image_commit_q <= !runtime_images && state[3] && sd_sec_read_data_valid_q && entry_off == 31 &&
          collecting && (is_bmp || is_qoi) && cluster_valid_q && image_count_o < 8;
      song_commit_q <= !runtime_images && state[3] && sd_sec_read_data_valid_q && entry_off == 31 &&
          collecting && (is_wav || is_qoa) && count < MAX_SONGS;
      video_commit_q <= !runtime_images && state[3] && sd_sec_read_data_valid_q && entry_off == 31 &&
          collecting && is_vid && video_empty_q;
      vaudio_commit_q <= !runtime_images && state[3] && sd_sec_read_data_valid_q && entry_off == 31 &&
          collecting && is_vau && vaudio_empty_q;
      if (state[3] && sd_sec_read_data_valid_q && entry_off == 31)
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
  // First VID start sector, owned by the directory commit process.
  reg [31:0] video_sector_r;
  assign video_sector_o = video_sector_r;
  reg [31:0] vaudio_sector_r;
  assign vaudio_sector_o = vaudio_sector_r;
  // A dedicated VAU suppresses the optional music-list fallback.
  assign song5_sector_o  = (vaudio_sector_r == 32'd0) ? song5_sector_r : 32'd0;

  // ---- MBR byte-0 looks like a DBR (x86 short/near jump)? ----
  reg [7:0] mbr_b0;

  wire is_dbr = (mbr_b0 == 8'hEB) || (mbr_b0 == 8'hE9);

  // Read-only sector-zero byte mirror for mount diagnosis.
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
      // Clear the directory-end flag when starting a new scan.
      if (state[0] || state[14]) dir_end_seen <= 1'b0;
      if (state[3] && sd_sec_read_data_valid_q && parse_entry) begin
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
          // Reject deleted slots and stop at the directory-end marker, even if
          // remaining bytes still contain an old filename or media extension.
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
        // Compare short-name extensions case-insensitively.
        if (entry_off == 5'd8)
          is_wav <= (sd_sec_read_data_q == 8'h57) || (sd_sec_read_data_q == 8'h77);  // 'W'/'w'
        if (entry_off == 5'd9)
          is_wav <= is_wav &&
              ((sd_sec_read_data_q == 8'h41) || (sd_sec_read_data_q == 8'h61));  // 'A'/'a'
        if (entry_off == 5'd10)
          is_wav <= is_wav &&
              ((sd_sec_read_data_q == 8'h56) || (sd_sec_read_data_q == 8'h76));  // 'V'/'v'
        // Video extension VID.
        if (entry_off == 5'd8)
          is_vid <= (sd_sec_read_data_q == 8'h56) || (sd_sec_read_data_q == 8'h76);  // 'V'/'v'
        if (entry_off == 5'd9)
          is_vid <= is_vid &&
              ((sd_sec_read_data_q == 8'h49) || (sd_sec_read_data_q == 8'h69));  // 'I'/'i'
        if (entry_off == 5'd10)
          is_vid <= is_vid &&
              ((sd_sec_read_data_q == 8'h44) || (sd_sec_read_data_q == 8'h64));  // 'D'/'d'
        // Dedicated video-audio extension VAU is not part of the WAV music list.
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
        // Assemble the cluster from little-endian DIR_FstClusHI at bytes20..21
        // and DIR_FstClusLO at bytes26..27.
        if (entry_off == 5'd20) cur_cluster[23:16] <= sd_sec_read_data_q;
        if (entry_off == 5'd21) cur_cluster[31:24] <= sd_sec_read_data_q;
        if (entry_off == 5'd26) cur_cluster[7:0] <= sd_sec_read_data_q;
        if (entry_off == 5'd27) cur_cluster[15:8] <= sd_sec_read_data_q;
        // Reject long-name, directory and volume-label attributes; allow regular
        // files with other attribute bits such as read-only or archive.
        if (entry_off == 5'd11) begin
          if (entry_valid && (sd_sec_read_data_q != 8'h0F) &&
              ((sd_sec_read_data_q & 8'h18) == 8'h00))
            collecting <= 1'b1;  // a plain file entry
        end
      end
    end
  end

  // Hold parser contents after the first candidate, drain the full sector,
  // and expose the result only at the transaction boundary. Byte counters
  // continue through skipped entries; no partial SD transaction is abandoned.
  // Sector counters settle before the read completes (or before a held
  // image is consumed). Register the cluster-boundary decision separately
  // so increment/compare logic is not chained into the state selector.
  reg root_last_sector_q;
  always @(posedge clk or posedge rst) begin
    if(rst) root_last_sector_q <= 1'b0;
    else root_last_sector_q <= ({1'b0,root_sector_done}+33'd1) >= {25'd0,root_sectors_total};
  end
  assign parse_entry = !runtime_images ||
      (!image_found && !dir_end_seen && rd_cnt < 512 &&
       {1'b0,rd_cnt[8:5]} >= image_start_entry);
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      image_found<=0; image_pending<=0; image_lba<=0;
      image_size_nonzero<=0; image_cluster_ok<=0; image_resume_entry<=0;
      image_read_bad<=0;
    end else begin
      image_cluster_ok <= cur_cluster >= 2 && cur_cluster <= {4'd0,max_cluster_o};
      image_pending <= 0;
      if(state[14]) begin image_found<=0; image_read_bad<=0; end
      else if(runtime_images && sd_read_error) image_read_bad<=1;
      if(state[3] && sd_sec_read_data_valid_q && parse_entry) begin
        if(entry_off==0) image_size_nonzero<=0;
        if(entry_off>=28) image_size_nonzero<=image_size_nonzero || sd_sec_read_data_q!=0;
        if(runtime_images && entry_off==31 && collecting &&
           (is_bmp || is_qoi) && image_cluster_ok &&
           (image_size_nonzero || sd_sec_read_data_q!=0)) begin
          image_found<=1; image_pending<=1;
          image_resume_entry<={1'b0,rd_cnt[8:5]}+1'b1;
        end
      end
      if(image_pending) image_lba<=entry_sector_q;
    end
  end

  // ---- commit a collected .WAV entry at the end of its 32 bytes ----
  integer ci;
  // Pipeline cluster subtraction, sector-offset multiplication and base
  // addition. The cluster field is complete before the directory entry
  // commit, so each stage uses stable metadata without extending the byte parser.
  reg [31:0] song_m2_r;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      song_m2_r  <= 32'd0;
      song_off_r <= 32'd0;
    end else begin
      song_m2_r <= (cur_cluster >= 32'd2) ? (cur_cluster - 32'd2) : 32'd0;
      if (state[3] && sd_sec_read_data_valid_q && entry_off == 5'd30)
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
      image4_o <= 0;
      image5_o <= 0;
      image6_o <= 0;
      image7_o <= 0;

      vaudio_sector_r <= 32'd0;
      // Initialize only entries within the parameterized music-table bounds.
      song5_sector_r <= 0;
    end else begin
      if (image_commit_q) begin
        case (image_count_o)
          0: image0_o <= entry_sector_q;
          1: image1_o <= entry_sector_q;
          2: image2_o <= entry_sector_q;
          3: image3_o <= entry_sector_q;
          4: image4_o <= entry_sector_q;
          5: image5_o <= entry_sector_q;
          6: image6_o <= entry_sector_q;
          7: image7_o <= entry_sector_q;

        endcase
        image_count_o <= image_count_o + 1'b1;
      end
      if (song_commit_q) begin
        // The count guard proves the RAM index is in range; use the exact
        // address width so elaboration preserves that bound.

        // cluster -> sector: data_start + song_off_r
        //   乘法已在上面预寄存，这里只做一次 32 位加法。
        if (count == 5) song5_sector_r <= entry_sector_q;
        count <= count + 6'd1;
      end
      // Commit the first VID sector using the prepared cluster offset.
      if (video_commit_q) video_sector_r <= entry_sector_q;
      // Commit the first VAU sector for the default video-audio selection.
      if (vaudio_commit_q) vaudio_sector_r <= entry_sector_q;
    end
  end

  // Advance byte and directory-slot offsets only for accepted bytes. Hold
  // positions across gaps in the SD valid signal.
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      rd_cnt <= 10'd0;
      entry_off <= 5'd0;
    end else if (state[3]) begin
      // 只有真正收到字节才前进；空洞拍保持不动
      if (sd_sec_read_data_valid_q) begin
        rd_cnt    <= rd_cnt + 10'd1;
        entry_off <= entry_off + 5'd1;
      end
    end else if (state[1] || state[2]) begin
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
    end else if (state[1] && sd_sec_read_data_valid_q) begin
      case (rd_cnt)
        10'd0:   mbr_b0 <= sd_sec_read_data_q;
        // Read the partition LBA only for an MBR. When sector zero is a DBR,
        // these bytes are boot content and must not affect mounted geometry.
        10'd454: partition_start[7:0] <= is_dbr ? 8'd0 : sd_sec_read_data_q;
        10'd455: partition_start[15:8] <= is_dbr ? 8'd0 : sd_sec_read_data_q;
        10'd456: partition_start[23:16] <= is_dbr ? 8'd0 : sd_sec_read_data_q;
        10'd457: partition_start[31:24] <= is_dbr ? 8'd0 : sd_sec_read_data_q;
        default: ;
      endcase
    end else if (state[2] && sd_sec_read_data_valid_q) begin
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
  // Prepare root-directory location in stages: subtract cluster bias,
  // scale by sectors per cluster, then add the registered data-region base.
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
    else if (state[5]) root_cluster_off_r <= root_off_mul_r;
  end

  wire [31:0] root_dir_w2 = data_start_r + root_cluster_off_r;

  // BPB fields complete before the sector ends. Register their validity
  // reduction before it drives mount state and ready enables.
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
      root_next[27:0] == root_current || root_next[27:0] == root_cluster[27:0] || root_hops >= max_cluster_local_q - 2;
  // Classify the FAT entry after the completed-sector edge, then consume
  // the result. A final entry at bytes508..511 must include its last byte.
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
      runtime_images<=0; image_valid<=0; image_empty<=0; image_error<=0;
      image_start_entry<=0; image_wrapped<=0;
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
      runtime_images<=0; image_valid<=0; image_empty<=0; image_error<=0;
      image_start_entry<=0; image_wrapped<=0;
      state       <= ST_IDLE;
      sd_sec_read <= 1'b0;
      list_ready  <= 1'b0;
    end else begin
      case (1'b1)
        state[0]: begin
          list_ready  <= 1'b0;
          sd_sec_read <= 1'b0;
          if (scan_start) begin
            filesystem_error_o <= 0;
            root_hops <= 0;
            sd_sec_read_addr <= 32'd0;  // sector 0 (MBR or DBR)
            state <= ST_READ_MBR;
          end
        end

        state[1]: begin
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

        state[2]: begin
          sd_sec_read <= 1'b1;
          if (sd_sec_read_end_q) begin
            sd_sec_read        <= 1'b0;
            // Latch the prepared data-region base before calculating the root address.
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

        // Prepare the root cluster offset before adding the data-region base.
        state[5]: begin
          // Register the root cluster offset for the following address stage.
          data_start      <= data_start_r;
          fat_base_r      <= reserved_base_q + active_span_q;
          // Geometry calculations are rare. Reuse the result registers as a
          // one-bit-per-clock shifter instead of two wide barrel networks.
          volume_clusters <= total_sectors - overhead_q;
          geometry_shift  <= spc_shift;
          root_current    <= root_cluster[27:0];
          state           <= ST_VOLUME_SHIFT;
        end

        state[10]: begin
          if (geometry_shift != 0) begin
            volume_clusters <= volume_clusters >> 1;
            geometry_shift  <= geometry_shift - 1'b1;
          end else state <= ST_CALC_ROOT2;
        end

        state[6]: begin
          // Add the stable root offset to the data-region base.
          root_dir_sector  <= root_dir_w2;
          cur_sector       <= root_dir_w2;
          sd_sec_read_addr <= root_dir_w2;
          state            <= ST_READ_ROOT;
        end

        state[3]: begin
          sd_sec_read <= 1'b1;
          if (sd_sec_read_end_q) begin
            sd_sec_read <= 1'b0;
            if(!runtime_images) root_sector_done <= root_sector_done + 8'd1;
            // Stop at the FAT directory-end marker. Later slots may retain stale
            // bytes and must not be interpreted as live files.
            if(runtime_images) state<=ST_IMAGE_END;
            else if (dir_end_seen) begin
              // end-of-directory seen, or whole root cluster read
              list_ready <= 1'b1;
              song_count <= count;
              state <= ST_DONE;
            end else if (root_last_sector_q) begin
              sd_sec_read_addr <= fat_base_r + {11'd0, root_current[27:7]};
              state <= ST_ROOT_GAP;
            end else begin
              cur_sector <= cur_sector + 32'd1;
              sd_sec_read_addr <= cur_sector + 32'd1;
            end
          end
        end

        state[8]: begin
          sd_sec_read <= 0;
          if(!runtime_images || !image_pause) state <= ST_ROOT_FAT;
        end
        state[7]: begin
          sd_sec_read <= 1;
          if (sd_sec_read_end_q) begin
            sd_sec_read <= 0;
            state <= ST_ROOT_EVAL;
          end
        end
        state[13]: begin
          sd_sec_read <= 0;
          root_current <= root_next[27:0];
          root_hops <= root_hops + 1'b1;
          if(runtime_images) begin
            if(root_count_bad_q || image_read_bad) begin image_error<=1; state<=ST_IMAGE_STOP; end
            else if(root_eoc_q) state<=ST_IMAGE_WRAP;
            else if(root_bad_q) begin image_error<=1; state<=ST_IMAGE_STOP; end
            else state<=ST_ROOT_CHECK;
          end else if (root_count_bad_q) begin
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

        state[9]: begin
          cur_sector <= root_current - 2;
          geometry_shift <= spc_shift;
          state <= ST_ROOT_SHIFT;
        end
        state[11]: begin
          if (geometry_shift != 0) begin
            cur_sector <= cur_sector << 1;
            geometry_shift <= geometry_shift - 1'b1;
          end else state <= ST_ROOT_ADD;
        end
        state[12]: begin
          cur_sector <= data_start + cur_sector;
          sd_sec_read_addr <= data_start + cur_sector;
          root_sector_done <= 0;
          state <= runtime_images ? ST_IMAGE_ISSUE : ST_READ_ROOT;
        end
        state[4]: begin
          sd_sec_read <= 1'b0;
          list_ready  <= 1'b1;
          if(STREAM_IMAGES && !runtime_images && !filesystem_error_o) begin
            runtime_images<=1; root_current<=root_cluster[27:0]; root_hops<=0;
            cur_sector<=root_dir_sector; sd_sec_read_addr<=root_dir_sector;
            root_sector_done<=0; image_start_entry<=0; image_wrapped<=0;
            state<=ST_IMAGE_ISSUE;
          end
        end
        state[14]: begin
          sd_sec_read<=0;
          if(!image_pause) state<=ST_READ_ROOT;
        end
        state[15]: begin
          sd_sec_read<=0;
          if(rd_cnt!=512 || image_read_bad) begin image_error<=1; state<=ST_IMAGE_STOP; end
          else if(image_found) begin image_valid<=1; state<=ST_IMAGE_HOLD; end
          else if(dir_end_seen) state<=ST_IMAGE_WRAP;
          else begin image_start_entry<=16; state<=ST_IMAGE_ADVANCE; end
        end
        state[16]: if(image_consume) begin
          image_valid<=0; image_wrapped<=0;
          image_start_entry<=image_resume_entry; state<=ST_IMAGE_ADVANCE;
        end
        state[17]: begin
          if(image_start_entry<16) state<=ST_IMAGE_ISSUE;
          else if(!root_last_sector_q) begin
            root_sector_done<=root_sector_done+1'b1;
            cur_sector<=cur_sector+1'b1; sd_sec_read_addr<=cur_sector+1'b1;
            image_start_entry<=0; state<=ST_IMAGE_ISSUE;
          end else begin
            image_start_entry<=0;
            sd_sec_read_addr<=fat_base_r+{11'd0,root_current[27:7]}; state<=ST_ROOT_GAP;
          end
        end
        state[18]: begin
          if(image_wrapped) begin image_empty<=1; state<=ST_IMAGE_STOP; end
          else begin
            image_wrapped<=1; root_current<=root_cluster[27:0]; root_hops<=0;
            cur_sector<=root_dir_sector; sd_sec_read_addr<=root_dir_sector;
            root_sector_done<=0; image_start_entry<=0; state<=ST_IMAGE_ISSUE;
          end
        end
        state[19]: begin sd_sec_read<=0; image_valid<=0; end

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

