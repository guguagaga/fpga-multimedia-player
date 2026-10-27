// Gain ramp advances on acknowledged PCM sample pairs,
// not a level-held request or a free-running fabric clock.
// STEP=2 reaches gain 961 in 481 samples (~10.02 ms at 48 kHz).
module volume_control # (parameter integer STEP=2) (
    input wire clk,rst,sample_tick,
    input wire [4:0] volume,
    input wire [23:0] sample_in_l,sample_in_r,
    output wire [23:0] sample_out_l,sample_out_r,
    output reg [9:0] gain
);
wire [9:0] target=volume*volume;
wire [9:0] distance=(gain<target)?target-gain:gain-target;
always @(posedge clk or posedge rst) begin
    if(rst)gain<=0;
    else if(sample_tick) begin
        if(distance<=STEP)gain<=target;
        else if(gain<target)gain<=gain+STEP;
        else gain<=gain-STEP;
    end
end
wire signed [23:0] sl=$signed(sample_in_l),sr=$signed(sample_in_r);
wire signed [10:0] g={1'b0,gain};
wire signed [34:0] ml=sl*g,mr=sr*g;
assign sample_out_l=ml[33:10],sample_out_r=mr[33:10];
endmodule
