`timescale 1ns/1ps
// Exercise the real SD-domain publication logic while scene mode holds images.
module tb_catalog_publish;
reg clk=0,rst=1;
reg scene_requested=1;
always #5 clk=~clk;
wire token,ready,pictures,tracks;
wire [2:0] count;
wire idle,scene_hold;
player_scene_restore restore(.clk(clk),.rst(rst),.scene_requested(scene_requested),
 .current_picture(3'd0),.picture_state_valid(ready),.quiescent(idle),.nav_idle(1'b1),
 .menu_toggle(1'b0),.menu_index(3'd0),.loader_ack(1'b0),.scene_hold(scene_hold));
sd_card_bmp #(.ENABLE_TEXT(0),.ENABLE_VIDEO_STREAM(1),.ENABLE_IMAGE_CACHE(1)) dut(
 .clk(clk),.rst(rst),.background_hold(1'b1),.background_reload_req(1'b0),
 .static_enable(1'b0),.auto_enable(1'b0),.auto_toggle(1'b0),.auto_sequence(16'd0),
 .key_next(1'b1),.nav_toggle(1'b0),.nav_previous(1'b0),
 .picture_select_toggle(1'b0),.picture_select_index(3'd0),
 .write_finish_toggle(1'b0),.frame_presented_toggle(1'b0),
 .picture_count(count),.picture_state_toggle(token),.catalog_ready(ready),.picture_idle(idle),
 .catalog_showcase(pictures),.catalog_tracks(tracks));
task reset_case;
 begin rst=1;repeat(5)@(negedge clk);rst=0;repeat(8)@(negedge clk);end
endtask
initial begin
 force dut.catalog_done=0;force dut.catalog_bmp_count=0;
 force dut.sd_init_done=1;
 force dut.catalog_pictures_named=0;force dut.catalog_tracks_named=0;
 reset_case;
 if(token!==0) $fatal(1,"premature publication");
 force dut.catalog_done=1;repeat(10)@(negedge clk);
 if(token!==1 || !ready || count!==0) $fatal(1,"empty catalog was never published");
 repeat(10)@(negedge clk);
 if(token!==1) $fatal(1,"empty catalog published twice");
 if(dut.loader_busy || !idle || !scene_hold)$fatal(1,"empty cache did not quiesce in scene mode");
 scene_requested=0;repeat(20)@(negedge clk);
 if(scene_hold)$fatal(1,"scene mode could not exit with an empty catalog");
 force dut.catalog_done=0;reset_case;
 force dut.catalog_bmp_count=3;repeat(5)@(negedge clk);
 if(token!==0) $fatal(1,"intermediate count leaked");
 force dut.catalog_bmp_count=6;force dut.catalog_pictures_named=1;
 force dut.catalog_tracks_named=1;force dut.catalog_done=1;
 repeat(20)@(negedge clk);
 if(token!==1 || count!==6 || !pictures || !tracks)
  $fatal(1,"catalog held by scene mode was not published atomically");
 $display("PASS tb_catalog_publish");$finish;
end
initial begin #100000;$fatal(1,"publish timeout");end
endmodule
