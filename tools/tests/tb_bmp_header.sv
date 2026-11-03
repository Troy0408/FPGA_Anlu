`timescale 1ns/1ps
// Feed real sector bytes and check the public write request/geometry, without
// depending on the scaler's pixel pipeline or on SD SPI initialization.
module tb_bmp_header;
reg clk=0,rst=1,load=0,valid=0,ending=0;
always #5 clk=~clk;
reg [7:0] data=0;
wire req,wreq,ready;
wire [31:0] lba;
wire [3:0] status;
wire [15:0] width,height;
bmp_read #(.CANVAS_WIDTH(640),.CANVAS_HEIGHT(360)) dut(
 .clk(clk),.rst(rst),.ready(ready),.pause_scan(1'b0),.scan_start(1'b0),
 .scan_start_sector(32'd0),.scan_max_sector(32'd0),.scan_target_count(3'd0),
 .load_start(load),.load_sector(32'd1234),.sd_init_done(1'b1),.state_code(status),
 .bmp_width(16'd640),.bmp_height(16'd360),.write_req(wreq),.write_req_ack(1'b0),
 .write_ready(1'b0),.sd_sec_read(req),.sd_sec_read_addr(lba),.sd_sec_read_data(data),
 .sd_sec_read_data_valid(valid),.sd_sec_read_end(ending),.loaded_width(width),.loaded_height(height));
reg [7:0] header[0:511];
integer i,j,w,h;
task word_at(input integer offset,input [31:0] value);
 begin for(j=0;j<4;j=j+1)header[offset+j]=value>>(j*8);end
endtask
task check(input integer x,input integer y,input integer bad);
 begin
  rst=1;load=0;valid=0;ending=0;repeat(5)@(negedge clk);rst=0;
  for(i=0;i<512;i=i+1)header[i]=0;
  header[0]="B";header[1]="M";header[26]=1;header[28]=24;
  word_at(2,54+((x*3+3)&32'hfffffffc)*(y<0 ? -y : y));
  word_at(10,54);word_at(14,40);word_at(18,x);word_at(22,y);
  if(bad)word_at(30,1);
  repeat(5)@(negedge clk);load=1;@(negedge clk);load=0;
  wait(req);@(negedge clk);
  if(lba!==1234)$fatal(1,"wrong sector");
  for(i=0;i<512;i=i+1)begin valid=1;data=header[i];@(negedge clk);end
  valid=0;ending=1;@(negedge clk);ending=0;
  repeat(150)@(negedge clk);
  if(bad)begin if(status!==15 || wreq)$fatal(1,"bad BMP was accepted");end
  else if(!wreq || width!==x || height!==(y<0 ? -y : y))
   $fatal(1,"BMP geometry %0dx%0d width=%0d height=%0d request=%0b",x,y,width,height,wreq);
 end
endtask
initial begin
 check(1280,720,0);check(853,-479,0);check(1920,1080,0);check(1,1,0);check(640,360,1);
 $display("PASS tb_bmp_header");$finish;
end
initial begin #1000000;$fatal(1,"BMP header timeout");end
endmodule
