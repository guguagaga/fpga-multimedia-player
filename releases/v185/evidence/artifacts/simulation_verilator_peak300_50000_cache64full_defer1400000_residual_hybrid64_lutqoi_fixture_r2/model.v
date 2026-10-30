// Simulation-only model for this project's same-clock DP16K usage.
module EG_PHY_BRAM32K #(parameter MODE="DP16K",DATA_WIDTH_A="16",DATA_WIDTH_B="16",REGMODE_A="NOREG",REGMODE_B="NOREG",WRITEMODE_A="NORMAL",WRITEMODE_B="NORMAL")(
 output reg[15:0]doa,dob,input wire[15:0]dia,dib,input wire[10:0]addra,addrb,
 input wire bytea,byteb,bytewea,byteweb,csa,csb,wea,web,clka,clkb,rsta,rstb,ocea,oceb);
reg[15:0]mem[0:2047];reg[15:0]newword;
always@(posedge clka)begin
 newword=mem[addra];
 if(csa&&wea)begin
  if(bytewea)begin
   if(bytea)newword[15:8]=dia[15:8];else newword[7:0]=dia[7:0];
  end else newword=dia;
  mem[addra]<=newword;
 end
 if(csb)dob<=(csa&&wea&&addra==addrb)?newword:mem[addrb];
 if(web||rsta||rstb||!ocea||!oceb)$fatal(1,"unsupported fast model mode");
end
endmodule
