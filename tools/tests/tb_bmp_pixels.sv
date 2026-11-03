`timescale 1ns/1ps
module tb_bmp_pixels;
reg clk=0,rst=1,load=0,ack=0,valid=0,ending=0;
always #5 clk=~clk;
reg [7:0] data=0;
wire req,wreq,we,content,ready;
wire [31:0] lba;
wire [23:0] pixel;
wire [15:0] width,height;
wire [3:0] status;
bmp_read #(.CANVAS_WIDTH(640),.CANVAS_HEIGHT(360)) dut(
 .clk(clk),.rst(rst),.ready(ready),.pause_scan(1'b0),.scan_start(1'b0),
 .scan_start_sector(32'd0),.scan_max_sector(32'd0),.scan_target_count(3'd0),
 .load_start(load),.load_sector(32'd64),.sd_init_done(1'b1),.state_code(status),
 .bmp_width(16'd640),.bmp_height(16'd360),.write_req(wreq),.write_req_ack(ack),
 .write_ready(1'b1),.sd_sec_read(req),.sd_sec_read_addr(lba),.sd_sec_read_data(data),
 .sd_sec_read_data_valid(valid),.sd_sec_read_end(ending),.bmp_data_wr_en(we),
 .bmp_data(pixel),.bmp_content(content),.loaded_width(width),.loaded_height(height));
integer w=1280,h=720,size=2764854,pixels=0,reads=0,cycle=0,last_write=-100;
integer fit_w,fit_h,left_pad,bottom_pad;
reg active=0,expected_content;
function automatic [7:0] media(input integer p);
 begin
  media=0;
  if(p==0)media="B";else if(p==1)media="M";
  else if(p>=2 && p<6)media=size>>(8*(p-2));
  else if(p==10)media=54;else if(p==14)media=40;
  else if(p>=18 && p<22)media=w>>(8*(p-18));
  else if(p>=22 && p<26)media=h>>(8*(p-22));
  else if(p==26)media=1;else if(p==28)media=24;
  else if(p>=54 && p<size)case((p-54)%3)
   0:media=8'h25;1:media=8'h72;2:media=8'hc9;
  endcase
 end
endfunction
initial forever begin
 @(negedge clk);
 if(!rst && req)begin : sector
  integer address,i;address=lba;reads=reads+1;
  repeat(3)@(negedge clk);
  for(i=0;i<512;i=i+1)begin valid=1;data=media((address-64)*512+i);@(negedge clk);end
  valid=0;ending=1;@(negedge clk);ending=0;
 end
end
always @(negedge clk) ack<=wreq;
always @(posedge clk)begin
 cycle=cycle+1;
 if(active)begin
  if(status==15)$fatal(1,"pixel loader failed");
  if(we)begin
   expected_content=(pixels%640>=left_pad && pixels%640<left_pad+fit_w &&
                     pixels/640>=bottom_pad && pixels/640<bottom_pad+fit_h);
   if(content!==expected_content || pixel!==(expected_content ? 24'hc97225 : 24'd0))
    $fatal(1,"pixel %0d RGB=%h content=%b expected content=%b",pixels,pixel,content,expected_content);
   if(cycle-last_write<16)$fatal(1,"write FIFO pacing changed");
   last_write=cycle;pixels=pixels+1;
  end
  if(ready && !load)begin
   if(pixels!=230400 || width!=w || height!=(h<0 ? -h : h))$fatal(1,"pixel count or metadata mismatch");
   $display("PASS tb_bmp_pixels size=%0dx%0d pixels=%0d reads=%0d cycles=%0d",w,h,pixels,reads,cycle);
   $finish;
  end
 end
end
initial begin
 if($test$plusargs("topdown"))begin w=640;h=-360;size=691254;end
 fit_w=640;fit_h=360;left_pad=0;bottom_pad=0;
 repeat(5)@(negedge clk);rst=0;repeat(5)@(negedge clk);
 load=1;@(negedge clk);load=0;active=1;
end
initial begin #2000000000;$fatal(1,"pixel timeout");end
endmodule
