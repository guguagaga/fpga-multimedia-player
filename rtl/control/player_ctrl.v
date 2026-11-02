// 键盘事件到播放控制状态的映射，运行于按键控制时钟域。
// 播放、音量、模式和曲目选择仅在对应按键事件发生时更新。
module player_ctrl (
  input  wire       clk,
  input  wire       rst_n,
  input  wire [3:0] key_code,   // 0..15
  input  wire       key_press,  // 1-cycle pulse on press
  // 板载按键送来的"播放/暂停"事件（与矩阵键盘 A 键等价，两个入口都能用）
  input  wire       btn_pause,
  output reg        pause,      // 1 = paused
  output reg  [4:0] volume,     // 0..31, 31 = full
  output reg  [1:0] mode,       // 0=顺序 1=单曲循环 2=随机
  output reg  [5:0] song_idx    // current song index
);

  // ---- key code constants ----
  localparam KC_A    = 4'd10;  // play/pause
  localparam KC_B    = 4'd11;  // prev
  localparam KC_C    = 4'd12;  // next
  localparam KC_D    = 4'd13;  // mode
  localparam KC_STAR = 4'd14;  // volume-
  localparam KC_HASH = 4'd15;  // volume+

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pause    <= 1'b0;
      volume   <= 5'd31;
      mode     <= 2'd0;
      song_idx <= 6'd0;
    end else if (key_press) begin
      // 按键码分别控制对应状态，避免无关按键影响音量或暂停。
      case (key_code)
        KC_A:    pause <= ~pause;  // A = 播放/暂停
        KC_STAR: volume <= (volume >= 5'd4) ? (volume - 5'd4) : 5'd0;  // * = 音量-
        KC_HASH: volume <= (volume > 5'd27) ? 5'd31 : (volume + 5'd4);  // # = 音量+
        default: ;  // 其余键暂不处理
      endcase
    end else if (btn_pause) begin
      // 板载按键（短按 key1）也能播放/暂停
      pause <= ~pause;
    end
  end

endmodule
