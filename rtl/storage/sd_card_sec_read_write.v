
module sd_card_sec_read_write #(
  parameter PREFETCH_BRAM32 = 0,
  parameter integer PREFETCH_BLOCKS = 16,
  parameter SPI_LOW_SPEED_DIV = 248,  // spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
  parameter SPI_HIGH_SPEED_DIV = 0  // spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
) (
  input             clk,
  input             rst,
  output reg        sd_init_done,
  input             sd_sec_read,
  input      [31:0] sd_sec_read_addr,
  // multi_en selects CMD18 read-ahead. Unpaced requests use PREFETCH_BLOCKS;
  // paced image requests use at most 16 sectors. Other requests use CMD17.
  input             multi_en,
  input             multi_paced,             // latched per request; does not slow SPI
  output     [ 7:0] sd_sec_read_data,
  output            sd_sec_read_data_valid,
  output            sd_sec_read_end,
  input             sd_sec_write,
  input      [31:0] sd_sec_write_addr,
  input      [ 7:0] sd_sec_write_data,
  output            sd_sec_write_data_req,
  output            sd_sec_write_end,

  output reg [15:0] spi_clk_div,
  output reg        cmd_req,
  input             cmd_req_ack,
  input             cmd_req_error,
  output reg [47:0] cmd,
  output reg [ 7:0] cmd_r1,
  output reg [15:0] cmd_data_len,
  output reg        block_read_req,
  input             block_read_valid,
  input      [ 7:0] block_read_data,
  input             block_read_req_ack,
  output reg [15:0] rd_nb_blk,            // CMD18 本批要读几块（给字节级模块）
  output reg        block_write_req,
  output     [ 7:0] block_write_data,
  input             block_write_data_rd,
  input             block_write_req_ack,
  // Read-only state and sticky command-error outputs for transport diagnosis.
  output     [ 4:0] dbg_state,            // FSM 状态码只读镜像（卡在哪一步）
  output            dbg_cmd_err           // cmd_req_error 曾置1（粘滞，只由 rst 清）
);
  reg [ 7:0] read_data;
  reg [31:0] timer;

  localparam S_IDLE = 0;
  localparam S_CMD0 = 1;
  localparam S_CMD8 = 2;
  localparam S_CMD55 = 3;
  localparam S_CMD41 = 4;
  localparam S_CMD17 = 5;
  localparam S_READ = 6;
  localparam S_CMD24 = 7;
  localparam S_WRITE = 8;
  localparam S_ERR = 14;
  localparam S_WRITE_END = 15;
  localparam S_READ_END = 16;
  localparam S_WAIT_READ_WRITE = 17;
  localparam S_CMD16 = 18;
  // CMD18 read-ahead and cache replay states.
  localparam S_CMD18 = 19;
  localparam S_READM = 20;
  localparam S_CMD12 = 21;
  localparam S_CMD12W = 22;
  localparam S_MEND = 23;
  localparam S_HIT = 24;
  localparam S_HIT_END = 25;
  localparam S_CACHE_CHECK = 26;

  // CMD18 amortizes command overhead across a sequential batch. The first
  // sector is delivered directly; following complete sectors are cached.
  // Cache slot i represents pbuf_lba+i. Exact-LBA hits reuse cached data;
  // misses wait for the physical transaction to stop before starting another.
  localparam integer NB_BLK = PREFETCH_BLOCKS;
  localparam integer COUNT_W = $clog2(NB_BLK);
  localparam integer PBUF_AW = $clog2(NB_BLK*512);
  localparam [PBUF_AW-1:0] PBUF_SKIP=512;  // Skip the first directly delivered sector in the cache write offset.
  // Enable sequential multi-block reads and their cache-replay path.
  localparam MULTI_ON = 1'b1;  // Sequential multi-block reads enabled.

  reg  [ 4:0] state;
  // Image read-ahead is latency-sensitive because PCM shares the card.
  // Keep the video batch capacity, but bound paced image bursts to 16 sectors.
  localparam integer IMAGE_BURST_BLOCKS = (NB_BLK > 16) ? 16 : NB_BLK;
  reg [COUNT_W:0] burst_blocks;
  reg  [31:0] sec_addr;

  // ---- 预取缓冲 ----

  reg  [31:0] pbuf_lba;
  reg  [COUNT_W-1:0] pbuf_n;  // 有效块数 0..NB_BLK-1
  reg  [31:0] rd_cnt;  // 本批已收数据字节（不含令牌/CRC）
  reg  [ 9:0] hit_cnt;
  reg  [PBUF_AW-1:0] hit_idx;  // 命中块在 pbuf 里的起始偏移
  wire [ 7:0] hit_q;
  reg         hit_slow;
  reg  [ 1:0] hit_phase;
  wire        hit_advance = !hit_slow || (hit_phase == 0);
  always @(posedge clk or posedge rst) begin
    if (rst) hit_phase <= 0;
    else if (state != S_HIT) hit_phase <= 0;
    else hit_phase <= hit_phase + 1'b1;
  end
  reg hit_qv;
  reg [5:0] c12w_cnt;

  // Capture cache lookup arithmetic when accepting the request. The next
  // state consumes only registered offset/underflow and latched read mode.
  // This adds one cycle per sector, not per byte. Keep the explicit unsigned
  // underflow guard: subtraction alone would alias wrapped LBAs near 2^32.
  reg [31:0] blk_off_q;
  reg cache_ge_q, request_multi_q;
  always @(posedge clk) if (state == S_WAIT_READ_WRITE && !sd_sec_write && sd_sec_read) begin
    blk_off_q <= sd_sec_read_addr - pbuf_lba;
    cache_ge_q <= sd_sec_read_addr >= pbuf_lba;
    request_multi_q <= multi_en;
  end
  wire pbuf_hit = cache_ge_q && !(|blk_off_q[31:COUNT_W]) && (blk_off_q[COUNT_W-1:0] < pbuf_n);
  // For an unsigned count, rd_cnt < 512 is equivalent to zero high bits.
  // This reduction avoids a wide carry chain on payload-valid fanout.
  wire rd_client = ~(|rd_cnt[31:9]);

  // Physical CMD18 ownership and logical512-byte client ownership are
  // separate. After the first sector, serve only FULLY WRITTEN cache sectors
  // while SPI continues. A miss (including audio) waits for physical stop.
  localparam SF_IDLE=0,SF_CHECK=1,SF_READ=2,SF_END=3;
  reg [1:0] sf_state;
  reg sf_wait_low,sf_ge,sf_slow,sf_valid,first_end,first_returned;
  reg [31:0] sf_offset;
  reg [PBUF_AW-1:0] sf_base;
  reg [9:0] sf_count;
  reg [1:0] sf_phase;
  wire sf_advance=!sf_slow || sf_phase==0;
  wire sf_end=sf_state==SF_END;
  wire [PBUF_AW-1:0] sf_ra=sf_base+sf_count[8:0];
  wire sf_range=sf_ge && !(|sf_offset[31:COUNT_W]) && {1'b0,sf_offset[COUNT_W-1:0]} < (burst_blocks-1'b1);
  wire [COUNT_W:0] sf_sector_end={1'b0,sf_offset[COUNT_W-1:0]}+2;
  wire sf_complete=rd_cnt[COUNT_W+9:9]>=sf_sector_end;
  wire sf_idle=sf_state==SF_IDLE && !sf_valid;
  always @(posedge clk or posedge rst)begin
    if(rst)begin
      sf_state<=SF_IDLE;sf_wait_low<=1;sf_ge<=0;sf_slow<=0;
      sf_valid<=0;first_end<=0;first_returned<=0;
      sf_offset<=0;sf_base<=0;sf_count<=0;sf_phase<=0;
    end else begin
      first_end<=0;
      sf_valid<=sf_state==SF_READ && sf_count<512 && sf_advance;
      if(sf_state==SF_READ)sf_phase<=sf_phase+1'b1;else sf_phase<=0;
      if(!sd_sec_read)sf_wait_low<=0;
      if(state==S_CMD18 && cmd_req_ack && !cmd_req_error)begin
        sf_wait_low<=1;first_returned<=0;
      end
      if(state==S_READM && block_read_valid && rd_cnt==511)begin
        first_end<=1;first_returned<=1;sf_wait_low<=1;
      end
      case(sf_state)
        SF_IDLE:if(state==S_READM && first_returned && !sf_wait_low && sd_sec_read)begin
          sf_offset<=sd_sec_read_addr-pbuf_lba;
          sf_ge<=sd_sec_read_addr>=pbuf_lba;sf_slow<=multi_paced;
          sf_state<=SF_CHECK;
        end
        SF_CHECK:begin
          if(sf_range && sf_complete)begin
            sf_base<={sf_offset[PBUF_AW-10:0],9'd0};sf_count<=0;sf_state<=SF_READ;
          end else sf_state<=SF_IDLE;
        end
        SF_READ:if(sf_count==513)sf_state<=SF_END;
                else if(sf_advance)sf_count<=sf_count+1'b1;
        SF_END:begin sf_state<=SF_IDLE;sf_wait_low<=1;end
      endcase
    end
  end

  // Publish the latched batch size during CMD18; single-block reads use one.
  always @(posedge clk or posedge rst) begin
    if (rst == 1'b1) rd_nb_blk <= 16'd1;
    else if (MULTI_ON && (state == S_CMD18 || state == S_READM)) rd_nb_blk <= burst_blocks;
    else rd_nb_blk <= 16'd1;
  end

  // Select direct payload, complete-cache replay, or concurrent cache service.
  // MULTI_ON guards the paths that depend on multi-block ownership.
  assign sd_sec_read_data_valid = ((state == S_READ) && block_read_valid)  // Direct single-sector payload.
      || (MULTI_ON && (state == S_READM) && block_read_valid && rd_client) ||
          (MULTI_ON && hit_qv) || sf_valid;  // 预取命中
  assign sd_sec_read_data = ((MULTI_ON && hit_qv) || sf_valid) ? hit_q : block_read_data;
  assign sd_sec_read_end = (state == S_READ_END) || ((state == S_MEND) && !first_returned) || first_end || sf_end ||
      (MULTI_ON && (state == S_HIT_END));
  assign sd_sec_write_data_req = (state == S_WRITE) && block_write_data_rd;
  assign block_write_data = sd_sec_write_data;
  assign sd_sec_write_end = (state == S_WRITE_END);

  // Write sectors after the first into the shared cache. Cache replay only
  // uses complete sectors, keeping in-flight SPI writes isolated from clients.
  wire pbuf_we = MULTI_ON && state == S_READM && block_read_valid && !rd_client;
  wire [PBUF_AW-1:0] pbuf_wa = rd_cnt[PBUF_AW-1:0] - PBUF_SKIP;
  wire [PBUF_AW-1:0] pbuf_ra = (sf_state==SF_READ) ? sf_ra : hit_idx + {{(PBUF_AW-9){1'b0}}, hit_cnt[8:0]};
  generate
    if (PREFETCH_BRAM32) begin : g_prefetch32
      // Byte-lane RAM mapping preserves synchronous read latency while distributing
      // the cache over available block-RAM types.
      video_byte_ram #(
        .AW(PBUF_AW), .DEPTH_BYTES(NB_BLK*512), .HYBRID_TAIL_9K(NB_BLK==64)
      ) cache (
        .clk (clk),
        .we  (pbuf_we),
        .re  (1'b1),
        .wa  (pbuf_wa),
        .ra  (pbuf_ra),
        .data(block_read_data),
        .q   (hit_q)
      );
    end else begin : g_prefetch_infer
      reg [7:0] pbuf[0:NB_BLK*512-1];
      reg [7:0] q;
      always @(posedge clk) begin
        if (pbuf_we) pbuf[pbuf_wa] <= block_read_data;
        q <= pbuf[pbuf_ra];
      end
      assign hit_q = q;
    end
  endgenerate

  always @(posedge clk) begin
    if (rst == 1'b1) hit_qv <= 1'b0;
    else hit_qv <= (state == S_HIT) && (hit_cnt < 10'd512) && hit_advance;
  end

  // 命中读侧：BRAM 读要打一拍，所以有效位也打一拍（真正的实现在上面）

  // Read-only state mirror and sticky command-error latch.
  assign dbg_state = state;  // FSM 状态码直通
  reg dbg_cmd_err_r;
  always @(posedge clk or posedge rst) begin
    if (rst == 1'b1) dbg_cmd_err_r <= 1'b0;
    else if (cmd_req_error) dbg_cmd_err_r <= 1'b1;  // 粘滞：曾出错（只由 rst 清）
  end
  assign dbg_cmd_err = dbg_cmd_err_r;

  always @(posedge clk or posedge rst) begin
    if (rst == 1'b1) begin
      state <= S_IDLE;
      cmd_req <= 1'b0;
      cmd_data_len <= 16'd0;
      cmd_r1 <= 8'd0;
      cmd <= 48'd0;
      spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
      block_write_req <= 1'b0;
      block_read_req <= 1'b0;
      sec_addr <= 32'd0;
      burst_blocks <= NB_BLK;
      sd_init_done <= 1'b0;
      // ---- 多块读状态（必须复位，否则 X 会污染数据通路）----
      pbuf_lba <= 32'd0;
      pbuf_n <= 5'd0;
      rd_cnt <= 32'd0;
      hit_cnt <= 10'd0;
      hit_idx <= 13'd0;
      hit_slow <= 1'b0;
      c12w_cnt <= 6'd0;
    end else
      case (state)
        S_IDLE: begin
          state <= S_CMD0;
          sd_init_done <= 1'b0;
          spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
        end
        S_CMD0: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state   <= S_CMD8;
            cmd_req <= 1'b0;
          end else if (cmd_req_ack) begin
            //CMD0 failed (e.g. SD card stuck in data mode after a hot
            //re-download): restart the whole init sequence. The
            //S_CMD_PRE now sends 80 clocks first, which lets the card
            //leave data mode before we re-send CMD0.
            state   <= S_IDLE;
            cmd_req <= 1'b0;
          end else begin
            cmd_req <= 1'b1;
            cmd_data_len <= 16'd0;
            cmd_r1 <= 8'h01;
            cmd <= {8'd0, 8'h00, 8'h00, 8'h00, 8'h00, 8'h95};
          end
        end
        S_CMD8: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state   <= S_CMD55;
            cmd_req <= 1'b0;
          end else if (cmd_req_ack) begin
            state   <= S_IDLE;
            cmd_req <= 1'b0;
          end else begin
            cmd_req <= 1'b1;
            cmd_data_len <= 16'd4;
            cmd_r1 <= 8'h01;
            cmd <= {8'd8, 8'h00, 8'h00, 8'h01, 8'haa, 8'h87};
          end
        end
        S_CMD55: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state   <= S_CMD41;
            cmd_req <= 1'b0;
          end else if (cmd_req_ack) begin
            state   <= S_IDLE;
            cmd_req <= 1'b0;
          end else begin
            cmd_req <= 1'b1;
            cmd_data_len <= 16'd0;
            cmd_r1 <= 8'h01;
            cmd <= {8'd55, 8'h00, 8'h00, 8'h00, 8'h00, 8'hff};
          end
        end
        S_CMD41: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state <= S_CMD16;
            cmd_req <= 1'b0;
            sd_init_done <= 1'b1;
            spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
          end else if (cmd_req_ack) begin
            state <= S_CMD55;
          end else begin
            cmd_req <= 1'b1;
            cmd_data_len <= 16'd0;
            cmd_r1 <= 8'h00;
            cmd <= {8'd41, 8'h40, 8'h00, 8'h00, 8'h00, 8'hff};
          end
        end
        S_CMD16: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state <= S_WAIT_READ_WRITE;
            cmd_req <= 1'b0;
            sd_init_done <= 1'b1;
            spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
          end else if (cmd_req_ack) begin
            // Restart initialization after CMD16 failure; do not re-enter an ACMD41 loop.
            state   <= S_IDLE;
            cmd_req <= 1'b0;
          end else begin
            cmd_req <= 1'b1;
            cmd_data_len <= 16'd0;
            cmd_r1 <= 8'h00;
            cmd <= {8'd16, 32'd512, 8'hff};
          end
        end
        S_WAIT_READ_WRITE: begin
          if (sd_sec_write == 1'b1) begin
            state <= S_CMD24;
            sec_addr <= sd_sec_write_addr;
          end else if (sd_sec_read == 1'b1) begin
            sec_addr <= sd_sec_read_addr;
            hit_slow <= multi_paced;
            burst_blocks <= multi_paced ? IMAGE_BURST_BLOCKS : NB_BLK;
            state <= S_CACHE_CHECK;
          end

          spi_clk_div <= 16'd0;
        end
        S_CACHE_CHECK: begin
          // A cached physical sector is valid even when new read-ahead is
          // disabled at a fragmented-file or volume boundary.
          if (MULTI_ON && pbuf_hit) begin
            hit_idx <= {blk_off_q[PBUF_AW-10:0], 9'd0};
            hit_cnt <= 10'd0;
            state <= S_HIT;
          end else if (MULTI_ON && request_multi_q) state <= S_CMD18;
          else state <= S_CMD17;
        end
        // CMD18 sequential batch read.
        S_CMD18: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state   <= S_READM;
            cmd_req <= 1'b0;
            rd_cnt  <= 32'd0;
            pbuf_lba <= sec_addr+1;
            pbuf_n <= 0;
          end else if (cmd_req_ack) begin
            // On command failure, release this state instead of waiting for success.
            state   <= S_READ_END;
            cmd_req <= 1'b0;
          end else begin
            cmd_req      <= 1'b1;
            // cmd_data_len 必须保持 0：字节级模块用它区分读/写命令，
            // 非 0 会被当成写命令进 S_CMD_DATA。块数走 rd_nb_blk。
            cmd_data_len <= 16'd0;
            cmd_r1       <= 8'h00;
            cmd          <= {8'd18, sec_addr, 8'hff};
          end
        end
        S_READM: begin
          if (block_read_valid) rd_cnt <= rd_cnt + 32'd1;
          if (block_read_req_ack) begin
            block_read_req <= 1'b0;
            // The byte controller sends CMD12 and drains the stream. Retire the batch
            // here without issuing a duplicate stop command.
            state          <= S_MEND;
            // The first sector was delivered; cache retains the following batch sectors.
            pbuf_lba       <= sec_addr + 32'd1;
            pbuf_n         <= burst_blocks - 1'b1;
          end else block_read_req <= 1'b1;
        end
        S_CMD12: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state <= S_CMD12W;
            cmd_req <= 1'b0;
            c12w_cnt <= 6'd0;
          end else if (cmd_req_ack) begin
            // On command failure, release this state instead of waiting for success.
            state   <= S_READ_END;
            cmd_req <= 1'b0;
          end else begin
            cmd_req      <= 1'b1;
            cmd_data_len <= 16'd0;
            cmd_r1       <= 8'h00;
            cmd          <= {8'd12, 32'd0, 8'hff};
          end
        end
        S_CMD12W: begin
          // CMD12 之后卡可能还举着 busy，等 ~1us 再放总线，
          // 免得下一个客户端一上来就踩到忙状态。
          cmd_req <= 1'b0;
          if (c12w_cnt == 6'd63) state <= S_MEND;
          else c12w_cnt <= c12w_cnt + 6'd1;
        end
        S_MEND: begin
          // Physical stop is complete. Never end an unrelated pending
          // request, nor replace the cache port during a logical hit.
          if(!first_returned || (sf_idle && !(sf_wait_low && sd_sec_read)))
            state <= S_WAIT_READ_WRITE;
        end
        S_HIT: begin
          if (hit_cnt == 10'd513) begin
            hit_cnt <= 10'd0;
            state   <= S_HIT_END;
          end else if (hit_advance) hit_cnt <= hit_cnt + 10'd1;
        end
        S_HIT_END: begin
          state <= S_WAIT_READ_WRITE;
        end
        S_CMD24: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state   <= S_WRITE;
            cmd_req <= 1'b0;
          end else if (cmd_req_ack) begin
            // On command failure, release this state instead of waiting for success.
            state   <= S_READ_END;
            cmd_req <= 1'b0;
          end else begin
            cmd_req <= 1'b1;
            cmd_data_len <= 16'd0;
            cmd_r1 <= 8'h00;
            cmd <= {8'd24, sec_addr, 8'hff};

          end
        end
        S_WRITE: begin
          if (block_write_req_ack == 1'b1) begin
            block_write_req <= 1'b0;
            state <= S_WRITE_END;
          end else block_write_req <= 1'b1;
        end
        S_CMD17: begin
          if (cmd_req_ack & ~cmd_req_error) begin
            state   <= S_READ;
            cmd_req <= 1'b0;
          end else if (cmd_req_ack) begin
            // On command failure, release this state instead of waiting for success.
            state   <= S_READ_END;
            cmd_req <= 1'b0;
          end else begin
            cmd_req <= 1'b1;
            cmd_data_len <= 16'd0;
            cmd_r1 <= 8'h00;
            cmd <= {8'd17, sec_addr, 8'hff};
          end
        end
        S_READ: begin
          if (block_read_req_ack) begin
            state <= S_READ_END;
            block_read_req <= 1'b0;
          end else begin
            block_read_req <= 1'b1;
          end
        end
        S_WRITE_END: begin
          state <= S_WAIT_READ_WRITE;
        end
        S_READ_END: begin
          state <= S_WAIT_READ_WRITE;
        end
        default: state <= S_IDLE;
      endcase
  end
endmodule
