`timescale 1ns/1ps
// Probe actual glyph pixels in the compact menu, including its colour pipeline.
module tb_catalog_menu_pixels;
reg clk=0,rst=1,vs=0,de=0,ready=0,pictures=0,tracks=0,scene=0;
always #5 clk=~clk;
wire out_de;
wire [23:0] rgb;
integer x_probe=28,y_probe=14,gray,white,x,y;
player_menu_overlay #(.COMPACT(1),.ENABLE_TRACKS(1),.ENABLE_SCENE(1),.ENABLE_PICTURES(1)) dut(
 .clk(clk),.rst(rst),.menu_open(1'b1),.menu_edit(1'b0),.scene_enable(scene),.media_locked(1'b0),
 .menu_item(3'd0),.picture_index(3'd0),.brightness_level(4'd5),.volume_level(4'd5),
 .contrast_level(4'd5),.subtitle_enable(1'b0),.visual_enable(1'b0),.period_select(2'd1),
 .tracks_ready(1'b1),.track_mask(5'b11111),.catalog_showcase(pictures),.catalog_ready(ready),
 .catalog_tracks(tracks),.track_status(4'd1),.track_title(248'd0),.raw_titles(1240'd0),
 .raw_track_index(3'd0),.title_we(1'b0),.title_address(8'd0),.title_data(7'd0),
 .in_hs(1'b0),.in_vs(vs),.in_de(de),.in_rgb(24'h202020),.out_de(out_de),.out_rgb(rgb));
task check_row(input integer row,input integer disabled);
 begin
  rst=1;de=0;vs=0;repeat(5)@(negedge clk);rst=0;repeat(5)@(negedge clk);
  vs=1;repeat(4)@(negedge clk);vs=0;
  force dut.x=x_probe;force dut.y=y_probe;
  gray=0;white=0;de=1;
  for(y=0;y<16;y=y+1)begin
   y_probe=14+row*18+y;
   for(x=28;x<124;x=x+1)begin
    x_probe=x;@(negedge clk);
    if(out_de && rgb===24'h909090)gray=gray+1;
    if(out_de && rgb===24'hffffff)white=white+1;
   end
  end
  repeat(4)begin
   @(negedge clk);
   if(out_de && rgb===24'h909090)gray=gray+1;
   if(out_de && rgb===24'hffffff)white=white+1;
  end
  de=0;release dut.x;release dut.y;
  if(disabled ? (gray==0 || white!=0) : (white==0 || gray!=0))
   $fatal(1,"row=%0d expected disabled=%0d gray=%0d white=%0d",row,disabled,gray,white);
 end
endtask
initial begin
 ready=1;check_row(3,1);check_row(6,1);check_row(7,1);
 scene=1;check_row(3,0);check_row(6,1);check_row(7,1);
 scene=0;pictures=1;tracks=1;check_row(3,0);check_row(6,0);check_row(7,0);
 pictures=0;tracks=0;ready=0;check_row(3,0);check_row(6,0);check_row(7,0);
 $display("PASS tb_catalog_menu_pixels");$finish;
end
initial begin #1000000;$fatal(1,"menu pixel timeout");end
endmodule
