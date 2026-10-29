// Stop -> release old SD ownership -> select pair -> restart companion audio
// -> observe ready falling/rising -> start video. Never change file identity
// while the old physical request is owned. New presses while busy are ignored.
module video_playlist_ctrl #(
    parameter integer SELECT_TIMEOUT = 181818181
) (
    input wire clk, rst, mode_video, list_ready,
    input wire next_req, prev_req, auto_toggle, ended,
    input wire io_idle, audio_ready, audio_busy,
    input wire [3:0] available,
    output reg [1:0] index,
    output wire engine_play,
    output reg audio_select,
    output wire switching,
    output reg auto_enabled,
    output reg selection_failed
);
    localparam IDLE=0, PLAY=1, STOP=2, SEARCH=3, SETTLE=4,
               SELECT=5, WAIT_LOW=6, WAIT_HIGH=7, FAILED=8;
    reg [3:0] state;
    reg backwards, initial_entry;
    reg [2:0] attempts;
    reg [1:0] settle;
    reg [$clog2(SELECT_TIMEOUT+1)-1:0] watchdog;
    assign engine_play = mode_video && state == PLAY;
    assign switching = mode_video && state != PLAY;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=IDLE;index<=0;audio_select<=0;auto_enabled<=1;
            selection_failed<=0;backwards<=0;initial_entry<=1;
            attempts<=0;settle<=0;watchdog<=0;
        end else begin
            audio_select<=0;
            if (mode_video && auto_toggle) auto_enabled<=~auto_enabled;
            if (!mode_video || !list_ready) begin
                state<=IDLE;selection_failed<=0;watchdog<=0;
            end else begin
                if (state==WAIT_LOW || state==WAIT_HIGH || state==STOP) begin
                    if (watchdog<SELECT_TIMEOUT) watchdog<=watchdog+1'b1;
                end else watchdog<=0;
                case(state)
                    IDLE: begin initial_entry<=1;backwards<=0;state<=STOP;end
                    PLAY: if(next_req || prev_req || (auto_enabled && ended)) begin
                        backwards<=prev_req && !next_req;
                        initial_entry<=0;state<=STOP;
                    end
                    STOP: if(io_idle) begin
                        if(!initial_entry) index<=backwards?index-2'd1:index+2'd1;
                        attempts<=0;state<=SEARCH;
                    end else if(watchdog==SELECT_TIMEOUT) begin state<=FAILED;selection_failed<=1;end
                    SEARCH: if(available[index]) begin settle<=0;state<=SETTLE;end
                    else if(attempts==3) begin state<=FAILED;selection_failed<=1;end
                    else begin index<=backwards?index-2'd1:index+2'd1;attempts<=attempts+1'b1;end
                    SETTLE: if(settle==3) state<=SELECT;else settle<=settle+1'b1;
                    SELECT: begin audio_select<=1;state<=WAIT_LOW;end
                    WAIT_LOW: if(!audio_ready) state<=WAIT_HIGH;
                    else if(watchdog==SELECT_TIMEOUT) begin state<=FAILED;selection_failed<=1;end
                    WAIT_HIGH: if(audio_ready && !audio_busy) begin state<=PLAY;selection_failed<=0;end
                    else if(watchdog==SELECT_TIMEOUT) begin state<=FAILED;selection_failed<=1;end
                    FAILED: if(next_req || prev_req) begin
                        backwards<=prev_req && !next_req;initial_entry<=0;state<=STOP;watchdog<=0;
                    end
                    default: state<=IDLE;
                endcase
            end
        end
    end
endmodule
