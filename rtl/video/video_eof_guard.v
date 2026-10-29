// Complete a movie only after its final buffer has reached the display and
// its final PCM grant has crossed to the audio domain and been consumed.
module video_eof_guard (
    input wire clk,
    input wire rst,
    input wire enable,
    input wire paused,
    input wire last_committed,
    input wire frame_presented,
    input wire budget_empty,
    output wire ended
);
    localparam WAIT_LAST = 3'd0;
    localparam SETTLE = 3'd1;
    localparam WAIT_CREDIT = 3'd2;
    localparam DRAIN = 3'd3;
    localparam DONE = 3'd4;
    reg [2:0] state;
    reg [5:0] settle_count;
    assign ended = enable && !paused && state == DONE;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= WAIT_LAST;
            settle_count <= 0;
        end else if (!enable) begin
            state <= WAIT_LAST;
            settle_count <= 0;
        end else begin
            case (state)
                WAIT_LAST: if (last_committed && frame_presented) begin
                    settle_count <= 0;
                    state <= SETTLE;
                end
                // At the fixed production clocks, 64 SD clocks exceed the
                // frame-grant synchronizer plus budget-return synchronizer.
                // A frame contains >=1600 PCM samples, so it cannot drain here.
                SETTLE: if (settle_count == 6'd63) state <= WAIT_CREDIT;
                        else settle_count <= settle_count + 1'b1;
                WAIT_CREDIT: if (!paused && !budget_empty) state <= DRAIN;
                DRAIN: if (!paused && budget_empty) state <= DONE;
                DONE: state <= DONE;
                default: state <= WAIT_LAST;
            endcase
        end
    end
endmodule
