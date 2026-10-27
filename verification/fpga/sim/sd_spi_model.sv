`timescale 1ns/1ps
// Pin-level SPI card stimulus. No byte-level shortcut around spi_master.
module sd_spi_model(input rst, input ncs, input sck, input mosi, output reg miso,
                    input integer token_delay, input integer stop_tail,
                    input fail_read);
reg [7:0] q[0:32767];
reg [7:0] packet[0:5];
reg [7:0] rx=8'h00, tx=8'hff;
integer bits=0, pn=0, qr=0, qw=0;
integer cmd17_count=0, cmd18_count=0, cmd12_count=0, command_count=0;
integer selected_bytes=0, stream=0;
function automatic [7:0] payload(input integer lba, input integer off);
    payload=(lba*13+off*7+(off>>3)) & 255;
endfunction
task automatic push(input [7:0] b);
begin
    if(qw>=32768) $fatal(1,"card response queue overflow");
    q[qw]=b; qw=qw+1;
end endtask
task automatic execute_command;
integer id,lba,j,k;
begin
    id=packet[0]&63; lba={packet[1],packet[2],packet[3],packet[4]};
    qr=0;qw=0;command_count=command_count+1;
    case(id)
      0: begin push(8'hff);push(8'h01);stream=0;end
      8: begin push(8'hff);push(8'h01);push(0);push(0);push(1);push(8'haa);end
      55: begin push(8'hff);push(8'h01);end
      41,16: begin push(8'hff);push(0);end
      17,18: begin
        if(id==17)cmd17_count=cmd17_count+1;
        else cmd18_count=cmd18_count+1;
        push(8'hff);push(8'hff);
        if(fail_read)begin push(8'h04);stream=0;end
        else begin
          push(0);stream=(id==18);
          for(j=0;j<(id==18?20:1);j=j+1)begin
            for(k=0;k<(j==0?token_delay:(2+j%7));k=k+1)push(8'hff);
            push(8'hfe);
            for(k=0;k<512;k=k+1)push(payload(lba+j,k));
            push(8'h12);push(8'h34);
          end
        end
      end
      12: begin
        cmd12_count=cmd12_count+1;
        // Exercise the existing multi-block drain with a dirty remaining tail.
        if(stream)begin
          for(k=0;k<stop_tail;k=k+1)push((k*19)&255);
          push(8'hff);push(0);push(0);push(8'hff);
        end else begin push(8'hff);push(8'h04);end
        stream=0;
      end
      default: $fatal(1,"unexpected MOSI command %0d",id);
    endcase
end endtask
always @(negedge sck or posedge ncs or posedge rst) begin
    if(rst||ncs)miso=1;
    else miso=tx[7-bits];
end
always @(posedge sck or posedge ncs or posedge rst)begin
    if(rst||ncs)begin bits=0;pn=0;qr=0;qw=0;rx=0;tx=8'hff;end
    else begin
      rx={rx[6:0],mosi};
      if(bits==7)begin
        selected_bytes=selected_bytes+1;
        if(pn==0)begin
          if(rx[7:6]==2'b01)begin packet[0]=rx;pn=1;end
        end else begin
          packet[pn]=rx;pn=pn+1;
          if(pn==6)begin execute_command();pn=0;end
        end
        if(qr<qw)begin tx=q[qr];qr=qr+1;end else tx=8'hff;
        bits=0;
      end else bits=bits+1;
    end
end
endmodule
