// -----------------------------------------------------------------------------
// Module purpose: SDRAM frame write addresses and FIFO-drain scheduling.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
module frame_fifo_write #(
  parameter MEM_DATA_BITS = 32,
  parameter ADDR_BITS     = 21,
  parameter BURST_BITS    = 9,
  parameter BURST_SIZE    = 128,
  parameter WRITE_V_FLIP  = 1,    // 1: write image rows upside-down to cancel BMP bottom-up storage
  parameter FRAME_WIDTH   = 640,
  parameter FRAME_HEIGHT  = 480
) (
  input  rst,
  input  mem_clk,           // external memory controller user interface clock
  input  Sdr_init_done,
  input  Sdr_init_ref_vld,
  input  Sdr_busy,
  input  App_rd_busy,
  output O_wr_busy,

  output App_wr_en,
  output [ADDR_BITS - 1:0] App_wr_addr,
  /*
    output reg                       wr_burst_req,               // to external memory controller,send out a burst write request  
    output reg[BURST_BITS - 1:0]     wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes 
    output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // to external memory controller,base address of the burst write request 
    input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock 
    input                            wr_burst_finish,            // from external memory controller,burst write finish
    */
  input write_req,  // data write module write request,keep '1' until read_req_ack = '1'
  output reg write_req_ack,  // data write module write request response
  output write_finish,  // data write module write request finish
  input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
  input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
  input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
  input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
  input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
  input [ADDR_BITS - 1:0] write_len,  // data write module write request data length
  // [Design note 缩放·写侧补黑]本次要写的源图高度（1..FRAME_HEIGHT）。
  //   为什么需要端口：写起始偏移必须从"写死 479*640"变成"(H-1)*640"，
  //   才能把 H 行真实像素顶到内存行 0..H-1（图在上）。
  //   H = FRAME_HEIGHT 时它与原常量完全相同 ⇒ 逐位不变。
  input [15:0] write_img_h,
  input write_top_down,
  output reg fifo_aclr,  // to fifo asynchronous clear
  input [9:0] rdusedw  // from fifo read used words
);
  localparam ONE = 256'd1;  //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
  localparam ZERO = 256'd0;  //256 bit '0'

  // Vertical flip address mapping for 640x480 frame buffer.
  // Input stream order remains unchanged; only SDRAM write addresses are remapped:
  // stream row 0 -> memory row FRAME_HEIGHT-1, stream row 1 -> memory row FRAME_HEIGHT-2, ...
  localparam [ADDR_BITS - 1:0] VFLIP_LINE_JUMP = (FRAME_WIDTH * 2) - 1;
  localparam [15:0] VFLIP_LINE_LAST_X = FRAME_WIDTH - 1;
  // [Design note 缩放·写侧补黑]本帧总字数 = 640*480 = 307200（补黑要"恰好"补到它）
  localparam [ADDR_BITS - 1:0] FRAME_WORDS = FRAME_WIDTH * FRAME_HEIGHT;
  localparam [15:0] FH16 = FRAME_HEIGHT;

  // ---- 运行时可配的 VFLIP 起始偏移 ----------------------------------------
  //   原来是写死的 localparam (FRAME_HEIGHT-1)*FRAME_WIDTH = 479*640 = 306560。
  //   现在要按本帧源图高度 H 算 (H-1)*640：
  //     写流第 0 行（BMP 最底行）落到内存行 H-1，最后一行落到内存行 0
  //     => H 行真实像素占内存行 0..H-1（图在上）
  //   640 = 2^9 + 2^7，所以用移位相加实现，不产生乘法器/DSP 
  //   跨时钟：write_img_h 来自 sd_card_clk 域，但它在整帧期间稳定（头部解析后
  //   到本帧写请求之间有数百微秒），这里按 write_addr_index 同样的惯例做两级同步，
  //   只在 S_ACK 那一拍取样 ⇒ 功能安全。
  reg [15:0] img_h_d0, img_h_d1;
  reg [1:0] top_down_sync;
  reg flip_frame;

  always @(posedge mem_clk or posedge rst) begin
    if (rst == 1'b1) begin
      img_h_d0 <= FH16;
      img_h_d1 <= FH16;
    end else begin
      img_h_d0 <= write_img_h;
      img_h_d1 <= img_h_d0;
    end
  end

  wire [15:0] vflip_img_h = (img_h_d1 == 16'd0) ? FH16 : (img_h_d1 > FH16) ? FH16 : img_h_d1;
  // 19 位足够：(FRAME_HEIGHT-1)*FRAME_WIDTH = 479*640 = 306560 < 2^19 = 524288 
  // 与 21 位的 write_addr_N 相加时零扩展，结果仍是 21 位 ⇒ 语义不变、加法器更窄。
  // ================================================================
  // 2026-10-13 TIMING FIX (merged from the other build)
  //   Board/STA fact: this offset was COMBINATIONAL and was the worst
  //   path of the whole design in the tool build:
  //     ext_mem_clk  requirement 8 ns, actual 21.40 ns -> SWNS -6.699 ns
  //   Chain: (H-1)<<9 + (H-1)<<7  ->  + write_addr_N  ->  App_wr_addr_r
  //   It is a per-frame CONSTANT: only img_h_d1 feeds it, and that is a
  //   two-stage synchroniser of write_img_h, stable for hundreds of us
  //   before the frame write starts.  It is used ONLY in S_ACK (once per
  //   frame), so registering it costs nothing functionally.
  //   Revert: delete this always block and restore the wire expression.
  // ================================================================
  reg  [18:0] vflip_first_addr_offset_r;
  reg  [15:0] vflip_h_minus_one;
  always @(posedge mem_clk or posedge rst) begin
    if (rst) vflip_h_minus_one <= 0;
    else vflip_h_minus_one <= vflip_img_h - 16'd1;
  end
  always @(posedge mem_clk or posedge rst) begin
    if (rst == 1'b1) vflip_first_addr_offset_r <= 19'd0;
    else vflip_first_addr_offset_r <= vflip_h_minus_one * FRAME_WIDTH;
  end  // (H-1)*640

  //write state machine code
  localparam S_IDLE = 0;  //idle state,waiting for write
  localparam S_ACK = 1;  //written request response
  localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst write
  localparam S_WRITE_BURST = 3;  //begin a burst write
  localparam S_WRITE_BURST_END = 4;  //a burst write complete
  localparam S_END = 5;  //a frame of data is written to complete


  reg write_req_d0;  //asynchronous write request, synchronize to 'mem_clk' clock domain,first beat
  reg write_req_d1;  //the second
  reg write_req_d2;  //third,Why do you need 3 ? Here's the design habit
  reg[ADDR_BITS - 1:0]                write_len_d0;                //asynchronous write_len(write data length), synchronize to 'mem_clk' clock domain first
  reg [ADDR_BITS - 1:0] write_len_d1;  //second
  reg [ADDR_BITS - 1:0] write_len_latch;  //lock write data length
  reg [ADDR_BITS - 1:0] write_cnt;  //write data counter
  reg [1:0] write_addr_index_d0;
  reg [1:0] write_addr_index_d1;
  reg [3:0] state;  //state machine
  always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
      top_down_sync <= 0;
      flip_frame <= WRITE_V_FLIP;
    end else begin
      top_down_sync <= {top_down_sync[0], write_top_down};
      if (state == S_IDLE) flip_frame <= WRITE_V_FLIP && !top_down_sync[1];
    end
  end
  reg  [ ADDR_BITS - 1:0] App_wr_addr_r;
  reg  [            15:0] wr_x;  // current x position in one input row
  // Keep vertical wrapping relative to the selected buffer, including buffer1.
  reg  [ ADDR_BITS - 1:0] write_base;

  reg  [BURST_BITS - 1:0] burst_cnt;
  wire                    wr_burst_finish;

  reg                     App_wr_en_r;
  reg                     App_wr_en_d0;

  wire                    into_burst;
  // Remaining length is constant throughout a burst. S_WRITE_BURST_END
  // provides one full cycle after write_cnt advances before S_CHECK_FIFO.
  // Register the subtraction so write arbitration has only one comparator.
  reg  [   ADDR_BITS-1:0] remaining_words;
  always @(posedge mem_clk or posedge rst) begin
    if (rst) remaining_words <= 0;
    else remaining_words <= write_len_latch - write_cnt;
  end
  assign into_burst = (((rdusedw >= remaining_words) || rdusedw >= BURST_SIZE) && ~App_rd_busy);

  assign App_wr_addr = {App_wr_addr_r[ADDR_BITS-1:0]};
  //assign O_wr_busy = (state != S_IDLE || (S_IDLE && write_req_d2));
  assign O_wr_busy = (state == S_WRITE_BURST || (state == S_CHECK_FIFO && into_burst));//在突发，或者将要突发，则显示busy
  assign wr_burst_finish = (burst_cnt >= BURST_SIZE);
  assign write_finish = (state == S_END) ? 1'b1 : 1'b0;  //write finish at state 'S_END'
  assign App_wr_en = App_wr_en_d0;


  always @(posedge mem_clk or posedge rst) begin
    if (rst == 1'b1) begin
      write_req_d0        <= 1'b0;
      write_req_d1        <= 1'b0;
      write_req_d2        <= 1'b0;
      write_len_d0        <= ZERO[ADDR_BITS-1:0];  //equivalent to write_len_d0 <= 0;
      write_len_d1        <= ZERO[ADDR_BITS-1:0];  //equivalent to write_len_d1 <= 0;
      write_addr_index_d0 <= 2'b00;
      write_addr_index_d1 <= 2'b00;
    end else begin
      write_req_d0    <=  write_req;
      write_req_d1    <=  write_req_d0;
      write_req_d2    <=  write_req_d1;
      write_len_d0    <=  write_len;
      write_len_d1    <=  write_len_d0;
      write_addr_index_d0 <= write_addr_index;
      write_addr_index_d1 <= write_addr_index_d0;
    end
  end
  always @(posedge mem_clk or posedge rst) begin
    if (rst == 1'b1) begin
      burst_cnt <= ZERO[BURST_BITS-1:0];
      App_wr_addr_r <= ZERO[ADDR_BITS-1:0];
      App_wr_en_d0 <= 1'b0;
      wr_x <= 16'd0;
      write_base <= {ADDR_BITS{1'b0}};
    end else begin

      if (state == S_CHECK_FIFO) burst_cnt <= ZERO[BURST_BITS-1:0];
      else if (App_wr_en) burst_cnt <= burst_cnt + 1'b1;
      else burst_cnt <= burst_cnt;
      //
      if (state == S_ACK) begin
        wr_x <= 16'd0;
        case (write_addr_index_d1)
          2'd0: write_base <= write_addr_0;
          2'd1: write_base <= write_addr_1;
          2'd2: write_base <= write_addr_2;
          2'd3: write_base <= write_addr_3;
        endcase
        if (write_addr_index_d1 == 2'd0)
          App_wr_addr_r <= flip_frame ? (write_addr_0 + vflip_first_addr_offset_r) : write_addr_0;
        else if (write_addr_index_d1 == 2'd1)
          App_wr_addr_r <= flip_frame ? (write_addr_1 + vflip_first_addr_offset_r) : write_addr_1;
        else if (write_addr_index_d1 == 2'd2)
          App_wr_addr_r <= flip_frame ? (write_addr_2 + vflip_first_addr_offset_r) : write_addr_2;
        else if (write_addr_index_d1 == 2'd3)
          App_wr_addr_r <= flip_frame ? (write_addr_3 + vflip_first_addr_offset_r) : write_addr_3;
      end else if (App_wr_en) begin
        if (flip_frame) begin
          if (wr_x == VFLIP_LINE_LAST_X) begin
            wr_x <= 16'd0;
            // [Design note 缩放·写侧补黑]行末步进加模 307200 回绕。
            //   原实现是裸的 addr -= 1279：从内存行 0 再往上就下溢。
            //   A1 口径要补黑到内存行 H..479，即"写完行 0 之后绕到行 479，
            //   再一行一行往上填"，所以必须取模回绕。
            //   行末 addr = 行首+639；减 1279 = 行首-640。
            //   行首 < 640 时会变负 ⇒ 改成 +（FRAME_WORDS-1279）= +305921，
            //   等价于 (行首-640) mod 307200 
            //   H=480 时这一拍之后不再有写（整帧正好 307200 字），
            //   该寄存器的死值不影响任何 SDRAM 写 ⇒ 逐位不变 
            if (App_wr_addr_r >= write_base + VFLIP_LINE_JUMP)
              App_wr_addr_r <= App_wr_addr_r - VFLIP_LINE_JUMP;
            else App_wr_addr_r <= App_wr_addr_r + (FRAME_WORDS - VFLIP_LINE_JUMP);
          end else begin
            wr_x <= wr_x + 1'b1;
            App_wr_addr_r <= App_wr_addr_r + 1'b1;
          end
        end else App_wr_addr_r <= App_wr_addr_r + 1'b1;
      end else App_wr_addr_r <= App_wr_addr_r;
      //
      if(App_wr_en_r && burst_cnt + App_wr_en < BURST_SIZE && (burst_cnt + write_cnt + App_wr_en < write_len_latch))begin
        App_wr_en_d0 <= 1'b1;
      end else App_wr_en_d0 <= 1'b0;

    end
  end
  always @(posedge mem_clk or posedge rst) begin
    if (rst == 1'b1) begin
      state <= S_IDLE;
      write_len_latch <= ZERO[ADDR_BITS-1:0];

      //wr_burst_addr <= ZERO[ADDR_BITS - 1:0];
      //wr_burst_req <= 1'b0;
      App_wr_en_r <= 1'b0;

      write_cnt <= ZERO[ADDR_BITS-1:0];
      fifo_aclr <= 1'b0;
      write_req_ack <= 1'b0;
      //wr_burst_len <= ZERO[BURST_BITS - 1:0];


    end else
      case (state)
        //idle state,waiting for write write_req_d2 == '1' goto the 'S_ACK'
        S_IDLE: begin
          if (write_req_d2 == 1'b1 && Sdr_init_done) begin
            state <= S_ACK;
          end
          write_req_ack <= 1'b0;
        end
        //'S_ACK' state completes the write request response, the FIFO reset, the address latch, and the data length latch
        S_ACK: begin
          //after write request revocation(write_req_d2 == '0'),goto 'S_CHECK_FIFO',write_req_ack goto '0'
          if (write_req_d2 == 1'b0) begin
            state <= S_CHECK_FIFO;
            fifo_aclr <= 1'b0;
            write_req_ack <= 1'b0;
          end else begin
            //write request response
            write_req_ack <= 1'b1;
            //FIFO reset
            fifo_aclr <= 1'b1;
            //select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
            /*
                    if(write_addr_index_d1 == 2'd0)
                        wr_burst_addr <= write_addr_0;
                    else if(write_addr_index_d1 == 2'd1)
                        wr_burst_addr <= write_addr_1;
                    else if(write_addr_index_d1 == 2'd2)
                        wr_burst_addr <= write_addr_2;
                    else if(write_addr_index_d1 == 2'd3)
                        wr_burst_addr <= write_addr_3;
                    */
            //latch data length
            write_len_latch <= write_len_d1;
          end
          //write data counter reset, write_cnt <= 0;
          write_cnt <= ZERO[ADDR_BITS-1:0];
        end
        S_CHECK_FIFO: begin
          //if there is a write request at this time, enter the 'S_ACK' state
          if (write_req_d2 == 1'b1) begin
            state <= S_ACK;
          end  //if the FIFO space is a burst write request, goto burst write state
          else if (into_burst) begin
            state <= S_WRITE_BURST;
            //wr_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
            //wr_burst_req <= 1'b1;
            App_wr_en_r <= 1'b1;
          end
        end

        S_WRITE_BURST: begin
          //burst finish
          if (wr_burst_finish == 1'b1) begin
            App_wr_en_r <= 1'b0;
            state <= S_WRITE_BURST_END;
            //write counter + burst length
            write_cnt <= write_cnt + BURST_SIZE[ADDR_BITS-1:0];
            //the next burst write address is generated
            //wr_burst_addr <= wr_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
          end
        end
        S_WRITE_BURST_END: begin
          //if there is a write request at this time, enter the 'S_ACK' state
          if (write_req_d2 == 1'b1) begin
            state <= S_ACK;
          end  //if the write counter value is less than the frame length, continue writing,
               //otherwise the writing is complete
          else if (write_cnt < write_len_latch) begin
            state <= S_CHECK_FIFO;
          end else begin
            state <= S_END;
          end
        end
        S_END: begin
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
  end
endmodule
