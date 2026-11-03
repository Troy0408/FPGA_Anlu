`timescale 1ns/1ps
module tb_menu_catalog;
reg clk=0,rst=1,enter_n=1,next_n=1,prev_n=1,sw_menu=0,sw_scene=0;
always #5 clk=~clk;
reg catalog_ready=0,pictures=0,tracks=0;
wire editing,opened,subtitle,scene,pt,tt;
wire [2:0] item,pi,ti;
player_menu_control #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(1),
 .ENABLE_TRACKS(1),.ENABLE_SCENE(1),.ENABLE_PICTURES(1),.DEFAULT_SUBTITLE_ENABLE(0)) dut(
 .clk(clk),.rst(rst),.key_enter_n(enter_n),.key_next_n(next_n),.key_prev_n(prev_n),
 .sw_auto(1'b0),.sw_menu(sw_menu),.sw_scene(sw_scene),.lock_media(1'b0),.force_scene_off(1'b0),
 .catalog_ready(catalog_ready),.catalog_showcase(pictures),.catalog_tracks(tracks),
 .current_picture_index(3'd0),.picture_count(3'd6),.picture_select_ack(pt),
 .picture_select_toggle(pt),.picture_select_index(pi),.nav_ack_toggle(1'b0),.nav_hold(1'b0),
 .tracks_ready(1'b1),.track_select_ack(tt),.track_mask(5'b11111),.active_track(3'd0),
 .track_select_toggle(tt),.track_select_index(ti),.menu_open(opened),.menu_edit(editing),
 .menu_item(item),.subtitle_enable(subtitle),.scene_enable(scene));
task tick;begin repeat(10) @(negedge clk);end endtask
task press_enter;begin enter_n=0;tick;enter_n=1;tick;end endtask
task press_next;begin next_n=0;tick;next_n=1;tick;end endtask
task select_item(input [2:0] target);
 begin
  if(editing) press_enter;
  while(item!=target) press_next;
 end
endtask
initial begin
 tick;rst=0;tick;sw_menu=1;tick;
 if(!opened) $fatal(1,"menu did not open");
 select_item(3);press_enter;
 if(!editing) $fatal(1,"catalog must not lock subtitles before scan completes");
 catalog_ready=1;tick;
 if(editing) $fatal(1,"subtitle edit did not close after scan");
 press_enter;
 if(editing) $fatal(1,"custom-card subtitles entered edit");
 press_next;
 if(subtitle) $fatal(1,"disabled subtitle changed");
 select_item(6);press_enter;
 if(editing || pt) $fatal(1,"custom-card picture selection enabled");
 select_item(7);press_enter;
 if(editing || tt) $fatal(1,"custom-card track selection enabled");
 sw_scene=1;tick;
 if(!scene) $fatal(1,"scene switch failed");
 select_item(3);press_enter;
 if(!editing) $fatal(1,"scene subtitle must remain editable");
 press_next;
 if(!subtitle) $fatal(1,"scene subtitle did not turn on");
 press_enter;sw_scene=0;tick;
 pictures=1;tracks=1;tick;
 select_item(6);press_enter;press_next;press_enter;
 if(!pt || pi!=1) $fatal(1,"named-card picture command failed");
 select_item(7);press_enter;press_next;
 if(!tt || ti!=1) $fatal(1,"named-card track command failed");
 tracks=0;tick;
 if(editing) $fatal(1,"track edit did not close after catalog change");
 $display("PASS tb_menu_catalog");$finish;
end
initial begin #1000000;$fatal(1,"menu timeout");end
endmodule
