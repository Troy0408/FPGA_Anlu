`timescale 1ns/1ps
module tb_subtitle_catalog;
reg clk=0,rst=1,vs=0,allowed=0,scene=0,enabled=1;
always #5 clk=~clk;
video_adjust_osd_cn #(.EXTERNAL_UI(1),.SHOWCASE_CN(1)) dut(
 .clk(clk),.rst(rst),.ui_brightness(4'd5),.ui_contrast(4'd5),.key_dec_n(1'b1),.key_inc_n(1'b1),
 .switch_in(2'd0),.subtitle_switch(enabled),.subtitle_catalog_ok(allowed),.text_clk(clk),
 .text_we(1'b0),.text_addr(8'd0),.text_data(8'd0),.text_done(1'b1),.text_status(4'd0),
 .text_length(9'd0),.subtitle_picture_bank(3'd2),.subtitle_scene(scene),
 .subtitle_font_q(16'd0),.subtitle_font_hi_q(16'd0),.in_hs(1'b0),.in_vs(vs),.in_de(1'b0),
 .in_rgb(24'd0),.in_picture(1'b1),.image_gain(6'd32));
task frame;
 begin vs=0;repeat(4)@(negedge clk);vs=1;repeat(4)@(negedge clk);vs=0;repeat(4)@(negedge clk);end
endtask
initial begin
 repeat(5)@(negedge clk);rst=0;repeat(6)@(negedge clk);
 frame;if(dut.subtitle_frame)$fatal(1,"custom picture subtitle visible");
 scene=1;frame;
 if(!dut.subtitle_frame || dut.subtitle_selection_frame!=6)$fatal(1,"scene subtitle missing");
 scene=0;allowed=1;frame;
 if(!dut.subtitle_frame || dut.subtitle_selection_frame!=2)$fatal(1,"named picture subtitle missing");
 enabled=0;frame;if(dut.subtitle_frame)$fatal(1,"subtitle switch ignored");
 $display("PASS tb_subtitle_catalog");$finish;
end
endmodule
