`timescale 1ns/1ps
module tb;
reg sd_card_clk=0;always #5 sd_card_clk=~sd_card_clk;
reg rst_all=1,video_play=0,video_paused=0,wav_ready=1,vau_src_ok=1;
localparam VAU_ON=1;reg vau_tgt,vau_sent,vau_ack,vau_fire;reg[19:0]vau_gap;reg[23:0]vau_wd;
integer fires=0,at_fault;
always@(posedge sd_card_clk)if(vau_fire)fires=fires+1;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        vau_tgt  <= 1'b0;
        vau_sent <= 1'b0;
        vau_ack  <= 1'b1;               // 上电时歌单自己会起，不需要我们动
        vau_gap  <= 20'd0;
        vau_fire <= 1'b0;
    end else begin
        vau_fire <= 1'b0;
        if (VAU_ON && (vau_tgt != video_play)) begin
            // 模式刚变 -> 立刻请求，等确认
            vau_tgt  <= video_play;
            vau_sent <= 1'b0;
            vau_ack  <= 1'b0;
            vau_gap  <= 20'd0;
            end else if (!vau_ack) begin
            if (!vau_src_ok) begin
                // 没有目标文件（例如卡上没 .VAU）：放弃请求，保持原样
                vau_ack <= 1'b1;
            end else if (vau_gap == 20'd0) begin
                vau_fire <= 1'b1;
                vau_sent <= 1'b1;
                vau_gap  <= 20'd900_000;   // 约 9 ms @100MHz 后重试
            end else begin
                vau_gap <= vau_gap - 20'd1;
            end
            // 只认"发出去之后"的 wav_ready 掉低，避免上电时 wav_ready=0 的假确认
            if (vau_sent && !vau_fire && !wav_ready) vau_ack <= 1'b1;
        end
    end
end
initial begin
 repeat(3)@(negedge sd_card_clk);rst_all=0;video_play=1;
 wait(vau_fire);@(negedge sd_card_clk);wav_ready=0;wait(vau_ack);
 repeat(10)@(negedge sd_card_clk);wav_ready=1;
 repeat(20)@(negedge sd_card_clk);at_fault=fires;wav_ready=0;
 repeat(10000030)@(negedge sd_card_clk);
 if(fires-at_fault!=0)$fatal(1,"restart count %0d expected 0",fires-at_fault);
 $display("FAULT_RESELECT_COUNT %0d",fires-at_fault);
 at_fault=fires;video_play=0;wait(vau_fire);repeat(10)@(negedge sd_card_clk);video_play=1;
 repeat(20)@(negedge sd_card_clk);
 if(fires<at_fault+2)$fatal(1,"explicit mode switch did not select");
 $display("PASS RESTART POLICY");$finish;
end
endmodule
