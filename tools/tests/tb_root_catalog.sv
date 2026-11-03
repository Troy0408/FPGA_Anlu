`timescale 1ns/1ps
module tb_root_catalog;
reg clk=0, rst=1;
always #5 clk=~clk;
wire req,done,pictures,tracks;
wire [31:0] lba,l0,l1,l2,l3,l4,l5;
wire [17:0] order;
wire [87:0] first_wav;
wire [2:0] nb,nw;
wire [3:0] status;
reg valid=0,ending=0;
reg [7:0] data=0;
root_media_catalog #(.TIMEOUT_CYCLES(1000000)) dut(
 .clk(clk),.rst(rst),.sd_ready(1'b1),.start(1'b1),.read_req(req),.read_lba(lba),
 .byte_valid(valid),.byte_data(data),.read_end(ending),.done(done),
 .pictures_named(pictures),.tracks_named(tracks),.bmp_count(nb),.wav_count(nw),
 .bmp_lba0(l0),.bmp_lba1(l1),.bmp_lba2(l2),.bmp_lba3(l3),.bmp_lba4(l4),.bmp_lba5(l5),
 .named_order(order),.first_wav_name(first_wav),.status(status));
reg [4095:0] card[int unsigned];
reg [4095:0] block_data;
reg [31:0] address;
string filename;
integer fd,n,i,reads=0;
initial begin
 if(!$value$plusargs("card=%s",filename)) $fatal(1,"missing card");
 fd=$fopen(filename,"r");
 if(!fd) $fatal(1,"cannot open card");
 while(!$feof(fd)) begin
  n=$fscanf(fd,"%h %h\n",address,block_data);
  if(n==2) card[address]=block_data;
 end
 $fclose(fd);
 repeat(5) @(negedge clk);rst=0;
end
initial forever begin
 @(negedge clk);
 if(!rst && req) begin
  address=lba;reads=reads+1;
  // All named files have been admitted before the final directory re-read.
  // Losing that response must not enable features requiring an exact set.
  if($test$plusargs("stall") && reads==34) wait(done);
  block_data=card.exists(address) ? card[address] : '0;
  repeat(3) @(negedge clk);
  for(i=0;i<512;i=i+1) begin
   valid=1;data=block_data[4095-8*i -:8];@(negedge clk);valid=0;
   // Exercise gaps as well as consecutive bytes.
   if(i%3==0) @(negedge clk);
  end
  ending=1;@(negedge clk);ending=0;
  repeat(3) @(negedge clk);
 end
end
initial begin
 wait(done);@(negedge clk);
 $display("CATALOG %0d %0d %0d %0d %0d %022h %0d %0d %0d %0d %0d %0d %0d %0d",
  status,nb,nw,pictures,tracks,first_wav,l0,l1,l2,l3,l4,l5,order,reads);
 $finish;
end
initial begin #20000000;$fatal(1,"catalog timeout");end
endmodule
