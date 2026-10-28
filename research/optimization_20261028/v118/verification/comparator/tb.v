module tb;
function lt_u32;
 input [31:0] a,b;
 reg [3:0] less,equal;
 begin
  less[3]=a[31:24]<b[31:24]; equal[3]=a[31:24]==b[31:24];
  less[2]=a[23:16]<b[23:16]; equal[2]=a[23:16]==b[23:16];
  less[1]=a[15:8]<b[15:8]; equal[1]=a[15:8]==b[15:8];
  less[0]=a[7:0]<b[7:0]; equal[0]=a[7:0]==b[7:0];
  lt_u32=less[3] | (equal[3]&less[2]) |
         ((&equal[3:2])&less[1]) | ((&equal[3:1])&less[0]);
 end
endfunction
reg[31:0]a,b;integer i,j,k,seed=42342,checks=0;
task check;begin
 if(lt_u32(a,b)!==(a<b))$fatal(1,"unsigned comparison a=%h b=%h",a,b);
 checks=checks+1;
end endtask
initial begin
 for(i=0;i<4;i=i+1)for(j=0;j<256;j=j+1)for(k=0;k<256;k=k+1)begin
 a=32'h5a69c387;b=a;a[i*8+:8]=j;b[i*8+:8]=k;check;
 end
 for(i=0;i<250000;i=i+1)begin
 a=$random(seed);b=$random(seed);check;b=a;check;b=a+1;check;b=a-1;check;
 end
 a=0;b=32'hffffffff;check;a=32'hffffffff;b=0;check;
 $display("PASS COMPARATOR checks=%0d",checks);$finish;
end
endmodule
