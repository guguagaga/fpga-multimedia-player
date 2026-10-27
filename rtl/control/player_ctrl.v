//===================================================================
// player_ctrl : keypad -> player control (play/pause, volume, mode, song)
//===================================================================
// Consumes keypad key_code/key_press events and maintains the player
// state. Runs in the sd_card_clk (100 MHz) domain.
//
// Key mapping (4x4 keypad):
//   1 2 3 A     A = play/pause
//   4 5 6 B     B = previous song
//   7 8 9 C     C = next song
//   * 0 # D     * = volume-   # = volume+   D = play mode
//   digits 0-9 = select song by index (stage 2)
//
// This stage implements: play/pause (A), volume +/- (* #).
// Song select / prev / next / mode are wired out but only activated
// once the WAV "seek to sector" path lands (stage 2).
//===================================================================
module player_ctrl (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] key_code,     // 0..15
    input  wire       key_press,    // 1-cycle pulse on press
    // 板载按键送来的"播放/暂停"事件（与矩阵键盘 A 键等价，两个入口都能用）
    input  wire       btn_pause,
    output reg        pause,        // 1 = paused
    output reg [4:0]  volume,       // 0..31, 31 = full
    output reg [1:0]  mode,         // 0=顺序 1=单曲循环 2=随机 (stage 2)
    output reg [5:0]  song_idx      // current song index (stage 2)
);

    // ---- key code constants ----
    localparam KC_A      = 4'd10;   // play/pause
    localparam KC_B      = 4'd11;   // prev
    localparam KC_C      = 4'd12;   // next
    localparam KC_D      = 4'd13;   // mode
    localparam KC_STAR   = 4'd14;   // volume-
    localparam KC_HASH   = 4'd15;   // volume+

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pause    <= 1'b0;
            volume   <= 5'd31;
            mode     <= 2'd0;
            song_idx <= 6'd0;
        end else if (key_press) begin
            // ===== 恢复正常按键逻辑 =====
            // 【重要】这里原来是一段诊断代码（"诊断 v2"）：
            //     volume <= {1'b0, key_code};   // 音量=键码
            //     pause  <= ~pause;             // 任意键翻转暂停
            // 它的作用是"按每个键，在 OSD 的 VOL 处显示该键的键码"，
            // 用来反推键盘接线。注释里写着"确认后恢复音量逻辑"。
            //
            // 后果：**按任意键都会把音量写成键码值（0..15）**，
            // 而 volume_control 是平方刻度，volume=0 就是完全静音。
            // 数字键 0~9 的键码正好是 0~9 -> 一按就几乎没声音。
            //
            // 为什么以前没暴露：键盘只通了 S5/S13 且旧扫描器会卡死，
            // 几乎不会有 key_press 送到这里。扫描器修好后按键事件真的
            // 到达了，音量和暂停就被写坏 —— 表现为"听不见声音"。
            case (key_code)
                KC_A:    pause  <= ~pause;                      // A = 播放/暂停
                KC_STAR: volume <= (volume >= 5'd4) ? (volume - 5'd4) : 5'd0;   // * = 音量-
                KC_HASH: volume <= (volume > 5'd27) ? 5'd31 : (volume + 5'd4);  // # = 音量+
                default: ;                                      // 其余键暂不处理
            endcase
        end else if (btn_pause) begin
            // 板载按键（短按 key1）也能播放/暂停
            pause <= ~pause;
        end
    end

endmodule
