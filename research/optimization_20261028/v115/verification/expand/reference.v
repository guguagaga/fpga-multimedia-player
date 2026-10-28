module image_expand_reference (
 input wire clk, input wire rst, input wire frame_start,
 input wire in_valid, input wire [23:0] in_pixel,
 output reg high, output reg overflow,
 input wire out_blocked,
 output reg out_valid, output reg [23:0] out_pixel
);
 reg [23:0] fifo [0:255];
 reg [7:0] wp, rp;
 reg [8:0] count;
 reg [23:0] q;
 reg qvalid;
 reg [2:0] state;
 localparam LIVE=0, DUP=1, FETCH=2, REPLAY=3, REPDUP=4, DONE=5;
 reg [9:0] x, y, rx;
 reg [23:0] held;
 reg [23:0] linebuf [0:639];
 reg [23:0] lineq;
 wire take = (state == LIVE) && qvalid && !out_blocked;
 wire fetch_fifo = (!qvalid || take) && (count != 0);
 wire push = in_valid && (count != 256);
 // A sector already in flight can add at most 171 RGB pixels. Register
 // the 64-entry threshold to break count -> QOI ready -> push -> count.
 // One extra accepted pixel leaves >=191 free slots, still above 171.
 always @(posedge clk) begin
   if (rst || frame_start) high <= 0;
   else high <= (count >= 64);
 end

 // Synchronous memory reads infer block RAM. No RAM content reset needed.
 always @(posedge clk) begin
   if (push) fifo[wp] <= in_pixel;
   if (fetch_fifo) q <= fifo[rp];
   if (take) linebuf[x] <= q;
   if (state == FETCH) lineq <= linebuf[rx];
 end
 always @(posedge clk) begin
   if (rst || frame_start) begin
     wp<=0; rp<=0; count<=0; qvalid<=0; overflow<=0;
   end else begin
     if (in_valid && !push) overflow<=1;
     if (push) wp<=wp+1'b1;
     if (fetch_fifo) rp<=rp+1'b1;
     case ({push,fetch_fifo})
       2'b10: count<=count+1'b1;
       2'b01: count<=count-1'b1;
       default: ;
     endcase
     if (fetch_fifo) qvalid<=1;
     else if (take) qvalid<=0;
   end
 end
 always @(posedge clk) begin
   if (rst || frame_start) begin
     state<=LIVE; x<=0; y<=0; rx<=0; held<=0;
     out_valid<=0; out_pixel<=0;
   end else begin
     out_valid<=0;
     case (state)
       LIVE: if (take) begin
         out_valid<=1; out_pixel<=q; held<=q;
         if (x == 639) begin
           x<=0;
           if (y[1:0] == 0) begin rx<=0; state<=FETCH; end
           else if (y == 479) state<=DONE;
           else y<=y+1'b1;
         end else begin
           x<=x+1'b1;
           if (x[1:0] == 0) state<=DUP;
         end
       end
       DUP: if (!out_blocked) begin
         out_valid<=1; out_pixel<=held; state<=LIVE;
       end
       FETCH: state<=REPLAY;
       REPLAY: if (!out_blocked) begin
         out_valid<=1; out_pixel<=lineq;
         if (rx[1:0] == 0) state<=REPDUP;
         else if (rx == 639) begin y<=y+1'b1; state<=LIVE; end
         else begin rx<=rx+1'b1; state<=FETCH; end
       end
       REPDUP: if (!out_blocked) begin
         out_valid<=1; out_pixel<=lineq;
         rx<=rx+1'b1; state<=FETCH;
       end
       DONE: ;
       default: state<=DONE;
     endcase
   end
 end
endmodule
