// Frozen H6D1 binary Huffman tree. Same byte stream and inverse predictors.
// One registered ROM traversal per bit; no canonical subtract/compare cone.
module context_huffman_decoder #(
    parameter SYMBOL_FILE="residual_symbols.mem",
    parameter METADATA_FILE="residual_metadata.mem",
    parameter TREE_FILE="residual_tree.mem"
) (
    input wire clk, rst, start,
    input wire [7:0] in_data,
    input wire in_valid,
    output wire in_ready,
    output wire [7:0] out_data,
    output reg out_valid,
    input wire out_ready,
    output wire [2:0] out_context,
    output reg frame_done, fault
);
    localparam ROOT=0, WALK=1, OUTPUT=2;
    reg [1:0] state;
    reg [7:0] bits;
    reg [3:0] bits_left;
    reg [4:0] code_length;
    reg [2:0] context_id;
    reg [1:0] grammar;
    reg [7:0] color_left;
    reg [4:0] index_left;
    reg [2:0] index_context;
    reg color_high;
    (* ram_style="bram" *) reg [17:0] tree[0:2047];
    reg [17:0] branches_q;
    reg [7:0] symbol_q;
    initial $readmemh(TREE_FILE,tree);
    wire [8:0] branch = bits[7] ? branches_q[17:9] : branches_q[8:0];
    wire walk_bit = state==WALK && bits_left!=0 && !fault && !frame_done;
    wire [10:0] tree_address = {context_id, (state==ROOT ? 8'd0 : branch[7:0])};
    always @(posedge clk)
        if(!rst&&!start && (state==ROOT || (walk_bit&&!branch[8])))
            branches_q <= tree[tree_address];
    assign out_data=symbol_q;
    assign out_context=context_id;
    assign in_ready=!rst&&!start&&!fault&&!frame_done&&state==WALK&&bits_left==0;
    always @(posedge clk) begin
        if(rst||start) begin
            state<=ROOT;bits<=0;bits_left<=0;code_length<=0;
            context_id<=0;grammar<=0;color_left<=0;index_left<=0;
            index_context<=0;color_high<=0;out_valid<=0;
            frame_done<=0;fault<=0;symbol_q<=0;
        end else if(!fault&&!frame_done) begin
            case(state)
                ROOT: state<=WALK;
                WALK: begin
                    if(bits_left==0)begin
                        if(in_valid)begin bits<=in_data;bits_left<=8;end
                    end else if(code_length==18)fault<=1;
                    else begin
                        bits<={bits[6:0],1'b0};bits_left<=bits_left-1'b1;
                        code_length<=code_length+1'b1;
                        if(branch[8])begin
                            symbol_q<=branch[7:0];out_valid<=1;state<=OUTPUT;
                        end
                    end
                end
                OUTPUT: if(out_ready)begin
                    out_valid<=0;code_length<=0;state<=ROOT;
                    case(grammar)
                        0: begin
                            color_high<=0;index_left<=0;
                            case(out_data)
                                8'h80:begin color_left<=2;grammar<=2;context_id<=1;end
                                8'h81:begin color_left<=4;index_left<=8;index_context<=3;grammar<=2;context_id<=1;end
                                8'h83:begin color_left<=128;grammar<=2;context_id<=1;end
                                8'h84,8'h86:begin color_left<=8;grammar<=2;context_id<=1;end
                                8'h85:begin color_left<=2;grammar<=1;context_id<=5;end
                                8'h87:begin color_left<=4;grammar<=1;context_id<=5;end
                                8'h88:begin color_left<=8;index_left<=16;index_context<=4;grammar<=2;context_id<=1;end
                                8'hff:frame_done<=1;
                                default:fault<=1;
                            endcase
                        end
                        1:begin grammar<=2;context_id<=1;end
                        2:begin
                            color_left<=color_left-1'b1;color_high<=!color_high;
                            if(color_left==1)begin
                                if(index_left!=0)begin grammar<=3;context_id<=index_context;end
                                else begin grammar<=0;context_id<=0;end
                            end else context_id<=color_high?1:2;
                        end
                        3:begin
                            index_left<=index_left-1'b1;
                            if(index_left==1)begin grammar<=0;context_id<=0;end
                        end
                    endcase
                end
                default: fault<=1;
            endcase
        end
    end
endmodule
