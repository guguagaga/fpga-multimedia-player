
module sd_card_cmd (
  input             sys_clk,
  output wire       read_stream,
  input             rst,
  input      [15:0] spi_clk_div,          //SPI module clock division parameter
  input             cmd_req,              //SD card command request
  output            cmd_req_ack,          //SD card command request response
  output reg        cmd_req_error,        //SD card command request error
  input      [47:0] cmd,                  //SD card command
  input      [ 7:0] cmd_r1,               //SD card expect response
  input      [15:0] cmd_data_len,         //SD card command read data length
  input             block_read_req,       //SD card sector data read request
  output reg        block_read_valid,     //SD card sector data read data valid
  output reg [ 7:0] block_read_data,      //SD card sector data read data
  output            block_read_req_ack,   //SD card sector data read response
  input             block_write_req,      //SD card sector data write request
  input      [ 7:0] block_write_data,     //SD card sector data write data next clock is valid
  output            block_write_data_rd,  //SD card sector data write data
  output            block_write_req_ack,  //SD card sector data write response
  output            nCS_ctrl,             //SPI module chip select control
  output reg [15:0] clk_div,
  output reg        spi_wr_req,           //SPI module data sending request
  input             spi_wr_ack,           //SPI module data request response
  output     [ 7:0] spi_data_in,          //SPI module send data
  input      [ 7:0] spi_data_out,         //SPI module data returned
  input      [15:0] nb_blk_in             //CMD18: blocks in this read
);
  parameter S_IDLE         = 0;
  parameter S_WAIT         = 1;
  parameter S_INIT         = 2;
  parameter S_CMD_PRE      = 3;
  parameter S_CMD          = 4;
  parameter S_CMD_DATA     = 5;
  parameter S_READ_WAIT    = 6;
  parameter S_READ         = 7;
  parameter S_READ_ACK     = 8;
  parameter S_WRITE_TOKEN  = 9;
  parameter S_WRITE_DATA_0 = 10;
  parameter S_WRITE_DATA_1 = 11;
  parameter S_WRITE_CRC    = 12;
  parameter S_WRITE_SUC    = 13;
  parameter S_WRITE_BUSY   = 14;
  parameter S_WRITE_ACK    = 15;
  parameter S_ERR          = 16;
  parameter S_END          = 17;
  parameter S_READ_NEXT    = 18;  // CMD18: 在块与块之间找下一个 0xFE 令牌
  parameter S_STOP_CMD     = 19;  // CMD18 收尾：把 CMD12 当数据字节发出去
  parameter S_STOP_DRAIN   = 20;  // 读掉卡还在吐的整块（否则它污染下一笔事务）
  reg  [15:0] stop_cnt;

  reg  [ 4:0] state;
  reg         CS_reg;
  reg  [15:0] byte_cnt;
  reg  [ 7:0] send_data;
  wire [ 7:0] data_recv;
  reg  [ 9:0] wr_data_cnt;

  // ---- CMD18 multi-block read (2026-10-17) ----
  //   nb_blk 是独立端口，不能复用 cmd_data_len：
  //     cmd_data_len != 0 在 S_CMD 里表示"这是写命令，进 S_CMD_DATA"（CMD24 用），
  //     拿它传块数会把读命令带进写数据状态机（踩过）。
  //   nb_blk == 0 按 1 块处理，保证老路径 cmd_data_len=0 时行为不变。
  reg  [15:0] blk_done;
  // Capture command type: CMD18 needs CMD12 even when only one block is read.
  reg         read_is_multi;
  wire [15:0] nb_blk = (nb_blk_in == 16'd0) ? 16'd1 : nb_blk_in;

  // The first 512 payload bytes are irrevocable once the token was accepted.
  // Keep command, token, CRC and stop handling on the existing handshake.
  assign read_stream = (state == S_READ) && (byte_cnt < 16'd511);
  assign cmd_req_ack = (state == S_END);
  assign block_read_req_ack = (state == S_READ_ACK);
  assign block_write_req_ack = (state == S_WRITE_ACK);
  assign block_write_data_rd = (state == S_WRITE_DATA_0);
  assign spi_data_in = send_data;
  assign data_recv = spi_data_out;
  assign nCS_ctrl = CS_reg;
  always @(posedge sys_clk or posedge rst) begin
    if (rst == 1'b1) begin
      CS_reg <= 1'b1;
      spi_wr_req <= 1'b0;
      byte_cnt <= 16'd0;
      clk_div <= 16'd0;
      send_data <= 8'hff;
      state <= S_IDLE;
      cmd_req_error <= 1'b0;
      wr_data_cnt <= 10'd0;
      read_is_multi <= 1'b0;
    end else
      case (state)
        S_IDLE: begin
          state   <= S_INIT;
          clk_div <= spi_clk_div;
          CS_reg  <= 1'b1;
        end
        S_INIT: begin
          //send 2500 bytes (~100ms @200kHz) on power to let the SD card
          //finish its internal power-up init, so ACMD41 passes quickly
          if (spi_wr_ack == 1'b1) begin
            if (byte_cnt >= 16'd2499) begin
              byte_cnt <= 16'd0;
              spi_wr_req <= 1'b0;
              state <= S_WAIT;
            end else begin
              byte_cnt <= byte_cnt + 16'd1;
            end
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hff;
          end
        end
        S_WAIT: begin
          cmd_req_error <= 1'b0;
          wr_data_cnt   <= 10'd0;
          //wait for  instruction
          if (cmd_req == 1'b1) begin
            state <= S_CMD_PRE;
            read_is_multi <= (cmd[45:40] == 6'd18);
          end else if (block_read_req == 1'b1) state <= S_READ_WAIT;
          else if (block_write_req == 1'b1) state <= S_WRITE_TOKEN;
          clk_div <= spi_clk_div;
        end
        S_CMD_PRE: begin
          //send 10 bytes of 0xFF (~80 clocks, CS high) before each command.
          //This recovers an SD card stuck in data mode after a hot re-download:
          //CS high + >=74 clocks lets the card leave data mode, then the
          //following command (CS low) re-enters SPI mode cleanly.
          if (spi_wr_ack == 1'b1) begin
            if (byte_cnt >= 16'd9) begin
              state <= S_CMD;
              spi_wr_req <= 1'b0;
              byte_cnt <= 16'd0;
            end else begin
              byte_cnt <= byte_cnt + 16'd1;
            end
          end else begin
            spi_wr_req <= 1'b1;
            CS_reg <= 1'b1;
            send_data <= 8'hff;
          end
        end
        S_CMD: begin
          if (spi_wr_ack == 1'b1) begin
            if ((byte_cnt == 16'h9ff) || (data_recv != cmd_r1 && data_recv[7] == 1'b0)) begin
              state <= S_ERR;
              spi_wr_req <= 1'b0;
              byte_cnt <= 16'd0;
            end else if (data_recv == cmd_r1) begin
              spi_wr_req <= 1'b0;
              if (cmd_data_len != 16'd0) begin
                state <= S_CMD_DATA;
                byte_cnt <= 16'd0;
              end else begin
                state <= S_END;
                byte_cnt <= 16'd0;
              end
            end else byte_cnt <= byte_cnt + 16'd1;
          end else begin
            spi_wr_req <= 1'b1;
            CS_reg <= 1'b0;
            if (byte_cnt == 16'd0) send_data <= (cmd[47:40] | 8'h40);
            else if (byte_cnt == 16'd1) send_data <= cmd[39:32];
            else if (byte_cnt == 16'd2) send_data <= cmd[31:24];
            else if (byte_cnt == 16'd3) send_data <= cmd[23:16];
            else if (byte_cnt == 16'd4) send_data <= cmd[15:8];
            else if (byte_cnt == 16'd5) send_data <= cmd[7:0];
            else send_data <= 8'hff;
          end
        end
        S_CMD_DATA: begin
          if (spi_wr_ack == 1'b1) begin
            if (byte_cnt == cmd_data_len - 16'd1) begin
              state <= S_END;
              spi_wr_req <= 1'b0;
              byte_cnt <= 16'd0;
            end else begin
              byte_cnt <= byte_cnt + 16'd1;
            end
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hff;
          end
        end
        S_READ_WAIT: begin
          if (spi_wr_ack == 1'b1 && data_recv == 8'hfe) begin
            spi_wr_req <= 1'b0;
            state <= S_READ;
            // 令牌已在这里吃掉，进来后第一个字节就是数据 byte 0
            byte_cnt <= 16'd0;
            blk_done <= 16'd0;
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hff;
          end
        end
        S_READ: begin
          // ================================================================
          // [Design note 回退]这里恢复成改动前逐字节一致的时序：
          //   进入本状态时第一个字节就是数据 byte 0（令牌已在 S_READ_WAIT
          //   吃掉），byte_cnt 0..511 是数据，512/513 是 CRC，513 处结束。
          //
          //   上一版我把语义改成"byte_cnt==0 找令牌 / 1..512 数据 /
          //   513~514 CRC"，虽然在我的理想化模型里过了，但真卡上
          //   整条 SD 读通路全废（板上现象：图片黑屏、音频卡 seek、
          //   视频 0 帧）—— 说明真卡的令牌/填充字节时序比模型脏，
          //   对每块第一个字节的偏移极其敏感。
          //
          //   CMD18 多块读因此暂停：sd_card_top 的 sd_read_multi 接 0，
          //   所有客户端走单块 CMD17（与 FPGVA 行为一致）。
          //   要重启多块，必须先在模型里加"劣化卡"（令牌前塞垃圾字节、
          //   CRC 后不干净），保证老路径时序一字不改也能对。
          // ================================================================
          if (spi_wr_ack == 1'b1) begin
            if (byte_cnt == 16'd513) begin
              byte_cnt <= 16'd0;
              // 【CMD18 多块】第一块的字节时序完全没有动：
              //   0..511 数据、512/513 CRC、513 处结束，与改动前一致。
              //   只有在"后面还有块"时，才跳到 S_READ_NEXT 去找下一个
              //   0xFE 令牌；令牌与数据之间的字节一律不产生 valid。
              if (blk_done + 16'd1 >= nb_blk) begin
                // 2026-10-26 speed fix: CMD17 ends after data + two CRC bytes.
                // The old unconditional branch added CMD12 + 600 dummy bytes
                // to EVERY single-sector read. Keep CMD18 cleanup unchanged.
                state <= read_is_multi ? S_STOP_CMD : S_READ_ACK;
                spi_wr_req <= 1'b0;
                blk_done <= 16'd0;
                byte_cnt <= 16'd0;
              end else begin
                state    <= S_READ_NEXT;
                blk_done <= blk_done + 16'd1;
              end
            end else begin
              byte_cnt <= byte_cnt + 16'd1;
            end
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hff;
          end
        end
        S_READ_NEXT: begin
          // CMD18 块与块之间：真实卡会先吐若干填充/杂字节，然后才给
          // 本块的 0xFE 令牌。这里只做"找令牌"，一个数据字节都不吐
          // （state != S_READ，所以 block_read_valid 恒 0），找到后
          // 回到 S_READ 且 byte_cnt=0 —— 与第一块进入时完全同样的
          // 字节语义，所以第一块和后续块的解包路径是同一条。
          if (spi_wr_ack == 1'b1 && data_recv == 8'hfe) begin
            spi_wr_req <= 1'b0;
            state      <= S_READ;
            byte_cnt   <= 16'd0;
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hff;
          end
        end
        S_WRITE_TOKEN:
        if (spi_wr_ack == 1'b1) begin
          state <= S_WRITE_DATA_0;
          spi_wr_req <= 1'b0;
          byte_cnt <= 16'd0;
        end else begin
          spi_wr_req <= 1'b1;
          send_data  <= 8'hfe;
        end
        S_WRITE_DATA_0: begin
          state <= S_WRITE_DATA_1;
          wr_data_cnt <= wr_data_cnt + 10'd1;
        end
        S_WRITE_DATA_1: begin
          if (spi_wr_ack == 1'b1 && wr_data_cnt == 10'd512) begin
            state <= S_WRITE_CRC;
            spi_wr_req <= 1'b0;
          end else if (spi_wr_ack == 1'b1) begin
            state <= S_WRITE_DATA_0;
            spi_wr_req <= 1'b0;
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= block_write_data;
          end
        end
        S_WRITE_CRC: begin
          if (spi_wr_ack == 1'b1) begin
            if (byte_cnt == 16'd1) begin
              state <= S_WRITE_SUC;
              spi_wr_req <= 1'b0;
              byte_cnt <= 16'd0;
            end else begin
              byte_cnt <= byte_cnt + 16'd1;
            end
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hff;
          end
        end
        S_WRITE_SUC: begin
          if (spi_wr_ack == 1'b1) begin
            if (data_recv[4:0] == 5'b00101) begin
              state <= S_WRITE_BUSY;
              spi_wr_req <= 1'b0;
            end
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hff;
          end
        end
        S_WRITE_BUSY: begin
          if (spi_wr_ack == 1'b1) begin
            if (data_recv == 8'hff) begin
              state <= S_WRITE_ACK;
              spi_wr_req <= 1'b0;
            end
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hff;
          end
        end
        // ================= [Design note 修复]CMD18 收尾 =================
        // 真卡在收到 CMD18 后会持续预取并流块，直到看见 CMD12 才停。
        // 旧实现读完最后一块就停机、再走"命令通道"发 CMD12 —— 那时卡仍在
        // 吐第 N+1 块的数据，命令通道读到的第一个字节是数据/令牌而不是 R1
        // ⇒ cmd_req_error ⇒ S_CMD12 无限重试 ⇒ 总线死锁（板上"只有视频黑屏"）。
        // 修法：CMD12 用数据字节通路发出去（和卡的流处于同一串时钟里），
        // 然后把卡剩下的"半块数据 + stuff + R1"全部读掉丢弃，总线才干净。
        S_STOP_CMD: begin
          if (spi_wr_ack == 1'b1) begin
            if (byte_cnt == 16'd5) begin
              byte_cnt   <= 16'd0;
              stop_cnt   <= 16'd0;
              spi_wr_req <= 1'b0;
              state      <= S_STOP_DRAIN;
            end else byte_cnt <= byte_cnt + 16'd1;
          end else begin
            spi_wr_req <= 1'b1;
            case (byte_cnt)
              16'd0:   send_data <= 8'h4C;  // 0x40 | CMD12
              16'd1:   send_data <= 8'h00;
              16'd2:   send_data <= 8'h00;
              16'd3:   send_data <= 8'h00;
              16'd4:   send_data <= 8'h00;
              default: send_data <= 8'hFF;  // CRC 不校验
            endcase
          end
        end
        S_STOP_DRAIN: begin
          // 600 字节 = 512 数据 + 2 CRC + 令牌 + stuff + R1 + 余量
          if (spi_wr_ack == 1'b1) begin
            if (stop_cnt == 16'd599) begin
              stop_cnt   <= 16'd0;
              spi_wr_req <= 1'b0;
              state      <= S_READ_ACK;  // 到这里总线已经干净了
            end else stop_cnt <= stop_cnt + 16'd1;
          end else begin
            spi_wr_req <= 1'b1;
            send_data  <= 8'hFF;
          end
        end
        S_ERR: begin
          state <= S_END;
          cmd_req_error <= 1'b1;
        end
        S_READ_ACK, S_WRITE_ACK, S_END: begin
          state <= S_WAIT;
        end
        default: state <= S_IDLE;
      endcase
  end
  always @(posedge sys_clk or posedge rst) begin
    if (rst == 1'b1) block_read_valid <= 1'b0;
    // 恢复改动前的窗口：byte_cnt 0..511 = 一块的 512 个数据字节
    else if (state == S_READ && byte_cnt < 16'd512) block_read_valid <= spi_wr_ack;
    else block_read_valid <= 1'b0;
  end

  always @(posedge sys_clk or posedge rst) begin
    if (rst == 1'b1) block_read_data <= 8'd0;
    else if (state == S_READ && spi_wr_ack == 1'b1) block_read_data <= data_recv;
  end

endmodule
