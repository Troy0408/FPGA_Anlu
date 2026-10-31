// R10 pixel-domain mode owner. No storage/PCM state is reset on mode changes.
// Top feeds the pre-video_delay raster; renderer sees the held mode/index
// 21 clocks later. Certification is delayed to the actual rhythm output.
module player_scene_control #(
    parameter integer CLK_FREQ_HZ=25_000_000,
    parameter integer ACTIVE_WIDTH=640,ACTIVE_HEIGHT=480,
    parameter integer PRESENT_DELAY=0,
    parameter integer EXTERNAL_COMPLETION=0
)(
    input wire clk,rst,enable,auto_enable,manual_step,manual_previous,in_vs,in_de,
    input wire [1:0] period_select,
    input wire visible_frame_toggle,
    output reg [1:0] scene_index,
    output reg scene_active,full_frame_done
);
(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst)
    if(rst)reset_sync<=7;else reset_sync<={reset_sync[1:0],1'b0};
wire reset=reset_sync[2];
reg vs_last,de_last,scan_good,certified,auto_last;
reg [10:0] column,row;
reg pending,pending_manual,pending_previous,dwell_valid;
localparam integer DWELL_MAX=CLK_FREQ_HZ*15;
localparam integer DWELL_BITS=$clog2(DWELL_MAX+1);
reg [DWELL_BITS-1:0] dwell_count;
reg [PRESENT_DELAY:0] complete_pipe;
wire frame_start=!in_de && in_vs && !vs_last;
wire change_scene=frame_start && enable && scene_active &&
    (manual_step || (pending && (pending_manual || auto_enable)));
wire completed=enable && scene_active && !certified && scan_good &&
    !in_de && de_last && column==ACTIVE_WIDTH && row==ACTIVE_HEIGHT-1;
wire source_complete=PRESENT_DELAY==0 ? completed : complete_pipe[PRESENT_DELAY-1];
(* async_reg="true" *) reg [2:0] visible_sync;
reg visible_seen,completion_pending;
wire visible_complete=EXTERNAL_COMPLETION ? completion_pending && visible_sync[2]!=visible_seen : source_complete;
always @(posedge clk or posedge reset)begin
    if(reset)begin visible_sync<=0;visible_seen<=0;completion_pending<=0;end
    else begin
        visible_sync<={visible_sync[1:0],visible_frame_toggle};visible_seen<=visible_sync[2];
        if(source_complete)completion_pending<=1;
        if(visible_complete || !enable || !scene_active || manual_step || change_scene ||
           (auto_enable && !auto_last))completion_pending<=0;
    end
end
wire [DWELL_BITS-1:0] dwell_limit=period_select==0 ? CLK_FREQ_HZ*3 :
    period_select==2 ? CLK_FREQ_HZ*15 : CLK_FREQ_HZ*5;
integer k;
always @(posedge clk or posedge reset)begin
    if(reset)begin
        scene_index<=0;scene_active<=0;full_frame_done<=0;
        vs_last<=0;de_last<=0;scan_good<=0;certified<=0;auto_last<=0;
        column<=0;row<=0;pending<=0;pending_manual<=0;pending_previous<=0;
        dwell_valid<=0;dwell_count<=0;complete_pipe<=0;
    end else begin
        vs_last<=in_vs;de_last<=in_de;auto_last<=auto_enable;
        full_frame_done<=0;
        complete_pipe[0]<=completed;
        for(k=1;k<=PRESENT_DELAY;k=k+1)complete_pipe[k]<=complete_pipe[k-1];
        if(completed)certified<=1;
        if(frame_start)begin
            scene_active<=enable;column<=0;row<=0;scan_good<=enable;
            if(!scene_active || !enable || change_scene)certified<=0;
            if(change_scene)begin
                scene_index<=(manual_step ? manual_previous : pending_previous) ?
                    scene_index-2'd1 : scene_index+2'd1;
                pending<=0;dwell_valid<=0;dwell_count<=0;complete_pipe<=0;
            end
        end else if(in_de)begin
            if(!scene_active || column>=ACTIVE_WIDTH || row>=ACTIVE_HEIGHT)scan_good<=0;
            if(column<2047)column<=column+1'b1;
        end else if(de_last)begin
            if(column!=ACTIVE_WIDTH)scan_good<=0;
            column<=0;if(row<2047)row<=row+1'b1;
        end
        // Enable/auto changes cancel old deadlines. An accepted storage
        // transaction is independent and continues in the original player.
        if(!enable || !scene_active)begin
            pending<=0;dwell_valid<=0;dwell_count<=0;certified<=0;complete_pipe<=0;
        end else if(manual_step)begin
            pending<=!frame_start;pending_manual<=1;pending_previous<=manual_previous;
            dwell_valid<=0;dwell_count<=0;complete_pipe<=0;
        end else if(!auto_enable)begin
            if(!pending_manual)pending<=0;
            dwell_valid<=0;dwell_count<=0;
        end else if(!auto_last)begin
            certified<=0;scan_good<=frame_start;dwell_valid<=0;dwell_count<=0;complete_pipe<=0;
            if(!pending_manual)pending<=0;
        end else if(visible_complete && !pending && !change_scene)begin
            full_frame_done<=1;dwell_valid<=1;dwell_count<=0;
        end else if(dwell_valid && !change_scene)begin
            if(dwell_count>=dwell_limit-1'b1)begin
                pending<=1;pending_manual<=0;pending_previous<=0;
                dwell_valid<=0;dwell_count<=0;
            end else dwell_count<=dwell_count+1'b1;
        end
        // The completion event is also useful with SW1 off. Only the dwell
        // depends on SW1, so each visible identity is still traceable.
        if(visible_complete && enable && scene_active && !manual_step && !change_scene)
            full_frame_done<=1;
    end
end
endmodule

// SW3 display handover plus serialized absolute-picture requests. The scene
// remains visible while accepted static transactions drain and the saved picture
// is re-presented. `quiescent` must include queued, loading and presenting work.
module player_scene_restore(
    input wire clk,rst,scene_requested,
    input wire [2:0] current_picture,
    input wire picture_state_valid,quiescent,nav_idle,
    input wire menu_toggle,input wire [2:0] menu_index,
    output reg menu_ack,
    input wire loader_ack,
    output reg loader_toggle,output reg [2:0] loader_index,
    output reg scene_hold,output wire static_allowed
);
localparam STATIC=2'd0,SCENE=2'd1,DRAIN=2'd2,RESTORE=2'd3;
reg [1:0] state;
reg [2:0] saved_picture;
reg restore_sent,owner_menu;
(* async_reg="true" *) reg [2:0] ack_sync;
(* async_reg="true" *) reg [4:0] quiet_sync;
assign static_allowed=(state==STATIC || state==DRAIN || state==RESTORE) && !scene_requested;
always @(posedge clk or posedge rst)begin
    if(rst)begin
        state<=STATIC;scene_hold<=0;saved_picture<=0;restore_sent<=0;owner_menu<=0;
        menu_ack<=0;loader_toggle<=0;loader_index<=0;ack_sync<=0;quiet_sync<=0;
    end else begin
        ack_sync<={ack_sync[1:0],loader_ack};quiet_sync<={quiet_sync[3:0],quiescent};
        if(ack_sync[2]==loader_toggle && owner_menu)begin menu_ack<=menu_toggle;owner_menu<=0;end
        case(state)
          STATIC:if(scene_requested && picture_state_valid)begin
              saved_picture<=current_picture;scene_hold<=1;state<=SCENE;
          end
          SCENE:if(!scene_requested)begin state<=DRAIN;restore_sent<=0;quiet_sync<=0;end
          DRAIN:if(scene_requested)state<=SCENE;
            else if(quiet_sync[4] && nav_idle && ack_sync[2]==loader_toggle && !owner_menu && menu_ack==menu_toggle)begin
                if(current_picture==saved_picture)begin scene_hold<=0;state<=STATIC;end
                else begin state<=RESTORE;restore_sent<=0;end
            end
          RESTORE:if(scene_requested)state<=SCENE;
            else if(!restore_sent && ack_sync[2]==loader_toggle && !owner_menu)begin
                loader_index<=saved_picture;loader_toggle<=!loader_toggle;restore_sent<=1;
            end else if(restore_sent && ack_sync[2]==loader_toggle && quiet_sync[4] && nav_idle && current_picture==saved_picture)begin
                scene_hold<=0;state<=STATIC;restore_sent<=0;
            end
        endcase
        // Already accepted menu requests finish before restoration. During scene
        // no new menu request is generated by the input owner.
        if(menu_ack!=menu_toggle && ack_sync[2]==loader_toggle && !owner_menu && state!=RESTORE)begin
            loader_index<=menu_index;loader_toggle<=!loader_toggle;owner_menu<=1;
        end
    end
end
endmodule

// The source VS is ahead of its first active pixel. Attach an epoch to every
// scene transition, so even a rapid round trip to the same index cannot accept
// an old output SOF as the current presentation.
module player_scene_present_tag(
    input wire clk,rst,source_vs,scene_active,
    input wire [1:0] scene_index,
    input wire output_start_toggle,input wire [31:0] output_start_tag,
    output reg [31:0] source_tag,
    output reg render_start,present_start
);
reg vs_last,active_last;
reg [1:0] index_last;
reg [28:0] epoch;
(* async_reg="true" *) reg [2:0] start_sync;
reg start_seen,capture_pending,compare_pending,waiting;
reg [31:0] captured_start_tag;
always @(posedge clk or posedge rst)begin
    if(rst)begin
        vs_last<=0;active_last<=0;index_last<=0;epoch<=0;source_tag<=0;
        render_start<=0;present_start<=0;start_sync<=0;start_seen<=0;capture_pending<=0;compare_pending<=0;captured_start_tag<=0;waiting<=0;
    end else begin
        vs_last<=source_vs;render_start<=0;present_start<=0;
        start_sync<={start_sync[1:0],output_start_toggle};
        if(start_sync[2]!=start_seen)begin start_seen<=start_sync[2];capture_pending<=1;end
        else if(capture_pending)begin
            capture_pending<=0;captured_start_tag<=output_start_tag;compare_pending<=1;
        end
        if(compare_pending)begin
            compare_pending<=0;
            if(waiting && captured_start_tag==source_tag && source_tag[2] &&
               !(source_vs && !vs_last && (!scene_active || !active_last || index_last!=scene_index)))begin
                present_start<=1;waiting<=0;
            end
        end
        if(source_vs && !vs_last)begin
            if(scene_active && (!active_last || index_last!=scene_index))begin
                epoch<=epoch+1'b1;source_tag<={epoch+1'b1,1'b1,scene_index};
                render_start<=1;waiting<=1;
            end else if(!scene_active && active_last)begin
                epoch<=epoch+1'b1;source_tag<={epoch+1'b1,1'b0,scene_index};waiting<=0;
            end
            active_last<=scene_active;index_last<=scene_index;
        end
    end
end
endmodule
