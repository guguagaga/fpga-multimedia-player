// Reconstruct original Codec12 bytes after Huffman decoding.
// Colors: modulo-65536 previous-color predictor. Indices: previous block row.
module codec12_lossless_restore (
    input wire clk, rst, start,
    input wire [7:0] in_data,
    input wire [2:0] in_context,
    input wire in_valid,
    output wire in_ready,
    output reg [7:0] out_data,
    output reg out_valid,
    input wire out_ready
);
    localparam ACCEPT=0, PASS=1, COLOR_LOW=2, COLOR_HIGH=3;
    reg [1:0] state;
    reg [7:0] color_low, previous_index0, previous_index1;
    reg [15:0] previous_color, color_word;
    reg index_odd;
    wire [15:0] restored_color={in_data,color_low}+previous_color;
    wire [7:0] restored_index=in_data^((in_context==4&&index_odd)?previous_index1:previous_index0);
    assign in_ready=!rst&&!start&&state==ACCEPT;
    always @(posedge clk)begin
        if(rst||start)begin
            state<=ACCEPT;out_data<=0;out_valid<=0;color_low<=0;
            previous_color<=0;color_word<=0;previous_index0<=0;previous_index1<=0;index_odd<=0;
        end else case(state)
            ACCEPT:if(in_valid)begin
                case(in_context)
                    1:color_low<=in_data;
                    2:begin
                        color_word<=restored_color;previous_color<=restored_color;
                        out_data<=restored_color[7:0];out_valid<=1;state<=COLOR_LOW;
                    end
                    3,4:begin
                        out_data<=restored_index;out_valid<=1;state<=PASS;
                        if(in_context==4&&index_odd)previous_index1<=restored_index;
                        else previous_index0<=restored_index;
                        if(in_context==4)index_odd<=!index_odd;
                    end
                    default:begin
                        out_data<=in_data;out_valid<=1;state<=PASS;
                        if(in_context==0)begin previous_index0<=0;previous_index1<=0;index_odd<=0;end
                    end
                endcase
            end
            PASS:if(out_ready)begin out_valid<=0;state<=ACCEPT;end
            COLOR_LOW:if(out_ready)begin out_data<=color_word[15:8];state<=COLOR_HIGH;end
            COLOR_HIGH:if(out_ready)begin out_valid<=0;state<=ACCEPT;end
        endcase
    end
endmodule
