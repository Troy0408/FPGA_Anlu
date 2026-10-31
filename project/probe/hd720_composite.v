// Team 720p candidate: preserve the 25MHz composition domain, then double the
// completed 640x360 RGB stream. Not selected by player.f until full validation.
// The source never pauses a clock. It waits for row credit in horizontal blank.
module hd720_render_timing(
    input wire clk,global_reset,frame_toggle,enable,
    input wire [1:0] row_free,
    input wire read_req_ack,
    output reg read_req,
    output wire hs,
    output reg vs,de,
    output reg late_frame
);
    reg [2:0] reset_sync;
    always @(posedge clk or posedge global_reset)
        if(global_reset)reset_sync<=7;else reset_sync<={reset_sync[1:0],1'b0};
    wire rst=reset_sync[2];
    (* async_reg="true" *) reg [2:0] frame_sync,ack_sync;
    (* async_reg="true" *) reg [1:0] free_meta,free_sync;
    (* async_reg="true" *) reg [1:0] enable_sync;
    reg frame_seen;
    reg [9:0] x;
    reg [8:0] y;
    reg [5:0] blank;
    reg [2:0] state;
    localparam IDLE=0,VSYNC=1,REQ=2,ACK_LOW=3,ROW_WAIT=4,ACTIVE=5,GAP=6,FAULT=7;
    assign hs=1'b0;
    always @(posedge clk or posedge rst)begin
        if(rst)begin frame_sync<=0;ack_sync<=0;free_meta<=0;free_sync<=0;enable_sync<=0;end
        else begin
            frame_sync<={frame_sync[1:0],frame_toggle};
            ack_sync<={ack_sync[1:0],read_req_ack};
            free_meta<=row_free;free_sync<=free_meta;
            enable_sync<={enable_sync[0],enable};
        end
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin frame_seen<=0;x<=0;y<=0;blank<=0;state<=IDLE;vs<=0;de<=0;read_req<=0;late_frame<=0;end
        else if(!enable_sync[1])begin frame_seen<=frame_sync[2];state<=IDLE;de<=0;vs<=0;read_req<=0;end
        else if(frame_sync[2]!=frame_seen)begin
            frame_seen<=frame_sync[2];
            if(state!=IDLE)begin late_frame<=1;de<=0;vs<=0;state<=FAULT;end
            else begin x<=0;y<=0;blank<=0;state<=VSYNC;vs<=1;de<=0;end
        end else case(state)
            IDLE:begin de<=0;vs<=0;end
            VSYNC:if(blank==3)begin vs<=0;read_req<=1;state<=REQ;end else blank<=blank+1'b1;
            REQ:if(ack_sync[2])begin read_req<=0;state<=ACK_LOW;end
            ACK_LOW:if(!ack_sync[2])begin blank<=0;state<=GAP;end
            ROW_WAIT:if(free_sync[y[0]])begin x<=0;de<=1;state<=ACTIVE;end
            ACTIVE:if(x==639)begin de<=0;x<=0;y<=y+1'b1;blank<=0;state<=GAP;end else x<=x+1'b1;
            GAP:if(blank==39)begin
                // Initial gap also gives the original FIFO clear time to retire.
                if(y==360)state<=IDLE;
                else state<=ROW_WAIT;
            end else blank<=blank+1'b1;
            FAULT:begin de<=0;vs<=0;if(ack_sync[2])read_req<=0;end
            default:state<=IDLE;
        endcase
    end
endmodule

// Four-word default register FIFO; no RAM inference. Registered Gray pointers cross
// through two stages; each slot is held until the remote read pointer returns.
// Source input is one word per active 25MHz cycle. Destination drains at74.25.
// Common reset only; reset of one side while the other runs is unsupported.
module hd720_pixel_fifo #(parameter integer WIDTH=25,parameter integer ADDR_BITS=2)(
    input wire write_clk,read_clk,rst,
    input wire write_valid,
    input wire [WIDTH-1:0] write_data,
    output wire write_ready,
    input wire read_take,
    output wire read_valid,
    output wire [WIDTH-1:0] read_data,
    output reg overflow
);
    reg [2:0] write_release,read_release;
    always @(posedge write_clk or posedge rst)
        if(rst)write_release<=7;else write_release<={write_release[1:0],1'b0};
    always @(posedge read_clk or posedge rst)
        if(rst)read_release<=7;else read_release<={read_release[1:0],1'b0};
    wire write_reset=write_release[2],read_reset=read_release[2];
    reg [WIDTH-1:0] words[0:(1<<ADDR_BITS)-1];
    reg [ADDR_BITS:0] wp,rp,wg,rg; /* fehdl keep="true" */
    (* async_reg="true" *) reg [ADDR_BITS:0] rg_meta,rg_sync,wg_meta,wg_sync; /* fehdl keep="true" */
    wire [ADDR_BITS:0] wn=wp+1'b1;
    wire [ADDR_BITS:0] wn_gray=(wn>>1)^wn;
    // FULL describes the current pointer, not the speculative next write.
    // Comparing wn_gray here would waste one slot and caused the earlier
    // four-word probe to reject valid traffic with three outstanding words.
    assign write_ready=!write_reset && wg!={~rg_sync[ADDR_BITS:ADDR_BITS-1],rg_sync[ADDR_BITS-2:0]};
    assign read_valid=!read_reset && rg!=wg_sync;
    assign read_data=words[rp[ADDR_BITS-1:0]];
    // Reset every slot so TD cannot substitute distributed RAM with missing
    // write-clock->asynchronous-read timing arcs. No slot is exposed until its
    // Gray ownership pointer crosses; reset data is not a valid payload.
    integer slot;
    always @(posedge write_clk or posedge write_reset)
        if(write_reset)begin
            for(slot=0;slot<(1<<ADDR_BITS);slot=slot+1)words[slot]<=0;
        end else if(write_valid && write_ready)words[wp[ADDR_BITS-1:0]]<=write_data;
    always @(posedge write_clk or posedge write_reset)begin
        if(write_reset)begin wp<=0;wg<=0;rg_meta<=0;rg_sync<=0;overflow<=0;end
        else begin
            rg_meta<=rg;rg_sync<=rg_meta;
            if(write_valid && !write_ready)overflow<=1;
            if(write_valid && write_ready)begin wp<=wn;wg<=wn_gray;end
        end
    end
    always @(posedge read_clk or posedge read_reset)begin
        if(read_reset)begin rp<=0;rg<=0;wg_meta<=0;wg_sync<=0;end
        else begin
            wg_meta<=wg;wg_sync<=wg_meta;
            if(read_take && read_valid)begin rp<=rp+1'b1;rg<=((rp+1'b1)>>1)^(rp+1'b1);end
        end
    end
endmodule

// The SAME final PCM bundle drives the source-domain real bars and, in order,
// this output-domain HDMI/ACR bridge. No second audio timer is introduced.
module hd720_pcm_bridge #(parameter integer TAGGED=0)(
    input wire source_clk,pixel_clk,rst,
    input wire source_valid,
    input wire [23:0] source_left,source_right,
    input wire source_media_valid,source_epoch_start,
    input wire [31:0] source_epoch,
    output reg audio_valid,
    output reg [23:0] audio_left,audio_right,
    output reg media_valid,epoch_start,
    output reg [31:0] media_epoch,
    output reg overflow
);
    reg [2:0] source_release,pixel_release;
    always @(posedge source_clk or posedge rst)
        if(rst)source_release<=7;else source_release<={source_release[1:0],1'b0};
    always @(posedge pixel_clk or posedge rst)
        if(rst)pixel_release<=7;else pixel_release<={pixel_release[1:0],1'b0};
    wire source_reset=source_release[2],pixel_reset=pixel_release[2];
    localparam integer PAYLOAD_BITS=TAGGED ? 82 : 48;
    reg [PAYLOAD_BITS-1:0] held_sample; /* fehdl keep="true" */
    wire [81:0] received_payload=held_sample;
    reg request,acknowledge;
    (* async_reg="true" *) reg [2:0] request_sync; /* fehdl keep="true" */
    (* async_reg="true" *) reg [1:0] acknowledge_sync; /* fehdl keep="true" */
    // A48k sample is520/521 source clocks apart. A complete held-bundle
    // request/ACK takes far less; no queue or wide asynchronous mux is needed.
    always @(posedge source_clk or posedge source_reset)begin
        if(source_reset)begin held_sample<=0;request<=0;acknowledge_sync<=0;overflow<=0;end
        else begin
            acknowledge_sync<={acknowledge_sync[0],acknowledge};
            if(source_valid)begin
                if(request!=acknowledge_sync[1])overflow<=1;
                else begin
                    // Metadata and stereo samples share exactly one owned
                    // request/ACK bundle. No bare epoch bits cross separately.
                    held_sample<=TAGGED ? {source_media_valid,source_epoch_start,source_epoch,source_left,source_right} :
                        {34'd0,source_left,source_right};
                    request<=~request;
                end
            end
        end
    end
    always @(posedge pixel_clk or posedge pixel_reset)begin
        if(pixel_reset)begin audio_valid<=0;audio_left<=0;audio_right<=0;request_sync<=0;acknowledge<=0;
            media_valid<=0;epoch_start<=0;media_epoch<=0;end
        else begin
            request_sync<={request_sync[1:0],request};audio_valid<=0;media_valid<=0;epoch_start<=0;
            if(request_sync[2]!=acknowledge)begin
                audio_left<=held_sample[47:24];audio_right<=held_sample[23:0];
                media_valid<=TAGGED && received_payload[81];epoch_start<=TAGGED && received_payload[80];
                media_epoch<=TAGGED ? received_payload[79:48] : 32'd0;
                audio_valid<=1;acknowledge<=request_sync[2];
            end
        end
    end
endmodule

// Startup-only title byte mailbox, SD50MHz -> compositor25MHz. The FAT byte
// service can backpressure. ACK follows the actual destination RAM write edge.
module hd720_title_bridge(
    input wire write_clk,clk,rst,
    input wire valid,
    input wire [7:0] address,
    input wire [6:0] data,
    output wire ready,
    output reg title_we,
    output reg [7:0] title_address,
    output reg [6:0] title_data
);
    reg [2:0] wr_release,rd_release;
    always @(posedge write_clk or posedge rst)
        if(rst)wr_release<=7;else wr_release<={wr_release[1:0],1'b0};
    always @(posedge clk or posedge rst)
        if(rst)rd_release<=7;else rd_release<={rd_release[1:0],1'b0};
    wire wr_reset=wr_release[2],rd_reset=rd_release[2];
    reg [14:0] held;
    reg request,acknowledge,writing;
    (* async_reg="true" *) reg [2:0] req_sync,ack_sync;
    assign ready=!wr_reset && request==ack_sync[2];
    always @(posedge write_clk or posedge wr_reset)begin
        if(wr_reset)begin held<=0;request<=0;ack_sync<=0;end
        else begin
            ack_sync<={ack_sync[1:0],acknowledge};
            if(valid && ready)begin held<={address,data};request<=~request;end
        end
    end
    always @(posedge clk or posedge rd_reset)begin
        if(rd_reset)begin req_sync<=0;acknowledge<=0;writing<=0;title_we<=0;title_address<=0;title_data<=0;end
        else begin
            req_sync<={req_sync[1:0],request};
            if(writing)begin
                // title_we was high through this clock; the RAM consumed it.
                title_we<=0;acknowledge<=req_sync[2];writing<=0;
            end else if(req_sync[2]!=acknowledge)begin
                title_address<=held[14:7];title_data<=held[6:0];title_we<=1;writing<=1;
            end
        end
    end
endmodule

// Both RAM ports stay on pixel_clk; clocks are never muxed at a RAM port.
// A small CDC FIFO brings completed source-domain pixels to the row writer.
// The last source pixel publishes a row; it is released only after BOTH copies.
module hd720_composite_scanout #(
    parameter integer FRAME_TAGGED=0
)(
    input wire source_clk,pixel_clk,rst,
    input wire stream_enable,
    input wire source_vs,source_de,source_fault,
    input wire [23:0] source_rgb,
    // Source-domain held frame bundle. Only the actual SOF word captures it;
    // changing the next frame's epoch cannot relabel an old TX certificate.
    input wire [31:0] source_frame_tag,
    output wire [1:0] row_free,
    output reg frame_toggle,
    output reg axis_valid,axis_user,axis_last,
    output reg [23:0] axis_data,
    input wire axis_ready,
    output reg frame_done_toggle,
    output reg [31:0] frame_done_tag,
    output reg frame_start_toggle,
    output reg [31:0] frame_start_tag,
    output reg underrun,
    output wire overflow
);
    reg [2:0] source_release,pixel_release;
    always @(posedge source_clk or posedge rst)
        if(rst)source_release<=7;else source_release<={source_release[1:0],1'b0};
    always @(posedge pixel_clk or posedge rst)
        if(rst)pixel_release<=7;else pixel_release<={pixel_release[1:0],1'b0};
    wire source_reset=source_release[2],pixel_reset=pixel_release[2];
    (* async_reg="true" *) reg [2:0] overflow_sync;
    always @(posedge pixel_clk or posedge pixel_reset)
        if(pixel_reset)overflow_sync<=0;else overflow_sync<={overflow_sync[1:0],overflow};
    reg [11:0] h,v;
    (* async_reg="true" *) reg [1:0] enable_sync;
    reg stream_active;
    reg [1:0] ready;
    reg [9:0] fill_x;
    reg [8:0] fill_y;
    reg source_vs_last;
    reg source_sof;
    reg [9:0] source_x;
    localparam integer PIXEL_BITS=26+(FRAME_TAGGED ? 32 : 0);
    wire [PIXEL_BITS-1:0] word_data;
    wire source_word_sof=source_sof && source_x==0;
    wire [PIXEL_BITS-1:0] fifo_word;
    wire [31:0] received_frame_tag;
    generate if(FRAME_TAGGED)begin: tagged_frames
        // Four register slots transport the SOF+tag as one held CDC bundle.
        // Tag bits are not stored in the 25-bit row RAMs.
        assign fifo_word={source_word_sof ? source_frame_tag : 32'd0,source_fault,source_word_sof,source_rgb};
        assign received_frame_tag=word_data[57:26];
    end else begin: untagged_frames
        assign fifo_word={source_fault,source_word_sof,source_rgb};
        assign received_frame_tag=32'd0;
    end endgenerate
    reg [31:0] active_frame_tag;
    wire available,write_ready;
    wire pop=available && !ready[fill_y[0]] && fill_y<360;
    assign row_free=~ready;
    wire active=h>=260 && h<1540 && v>=25 && v<745;
    wire [11:0] ox=h-260,oy=v-25;
    wire [9:0] rx=ox[10:1];
    wire rb=oy[1];
    wire [24:0] q0,q1;
    reg active_q,sof_q,last_q,rb_q,ready_q,eof_q,axis_eof,frame_bad;
    always @(posedge source_clk or posedge source_reset)begin
        if(source_reset)begin source_vs_last<=0;source_sof<=1;source_x<=0;end
        else begin
            source_vs_last<=source_vs;
            if(source_vs && !source_vs_last)begin source_sof<=1;source_x<=0;end
            if(source_de)begin
                if(source_x==639)begin source_x<=0;source_sof<=0;end
                else source_x<=source_x+1'b1;
            end
        end
    end
    hd720_pixel_fifo #(.WIDTH(PIXEL_BITS)) pixels(.write_clk(source_clk),.read_clk(pixel_clk),.rst(rst),
        .write_valid(source_de),.write_data(fifo_word),
        .write_ready(write_ready),.read_take(pop),.read_valid(available),.read_data(word_data),.overflow(overflow));
    hd720_row32k row0(.clk(pixel_clk),.write_enable(pop && !fill_y[0]),
        .write_x(fill_x),.write_data({word_data[23:0],1'b1}),.read_x(rx),.read_data(q0));
    hd720_row32k row1(.clk(pixel_clk),.write_enable(pop && fill_y[0]),
        .write_x(fill_x),.write_data({word_data[23:0],1'b1}),.read_x(rx),.read_data(q1));
    always @(posedge pixel_clk or posedge pixel_reset)begin
        if(pixel_reset)begin
            h<=0;v<=0;ready<=0;fill_x<=0;fill_y<=0;frame_toggle<=0;
            active_q<=0;sof_q<=0;last_q<=0;rb_q<=0;ready_q<=0;
            axis_valid<=0;axis_user<=0;axis_last<=0;axis_data<=0;underrun<=0;
            eof_q<=0;axis_eof<=0;frame_bad<=0;frame_done_toggle<=0;
            active_frame_tag<=0;frame_done_tag<=0;frame_start_toggle<=0;frame_start_tag<=0;
            enable_sync<=0;stream_active<=0;
        end else begin
            enable_sync<={enable_sync[0],stream_enable};
            if(h==1649)begin h<=0;if(v==749)v<=0;else v<=v+1'b1;end else h<=h+1'b1;
            if(h==0 && v==0)begin
                frame_toggle<=~frame_toggle;fill_x<=0;fill_y<=0;ready<=0;frame_bad<=0;stream_active<=enable_sync[1];
                active_frame_tag<=0;
            end
            if(pop)begin
                if(word_data[25])frame_bad<=1;
                if(word_data[24]!=(fill_y==0 && fill_x==0))begin underrun<=1;frame_bad<=1;end
                if(word_data[24])active_frame_tag<=received_frame_tag;
                if(fill_x==639)begin ready[fill_y[0]]<=1;fill_x<=0;fill_y<=fill_y+1'b1;end
                else fill_x<=fill_x+1'b1;
            end
            if(active && stream_active && !ready[rb])begin underrun<=1;frame_bad<=1;end
            if(axis_valid && !axis_ready && stream_active)begin underrun<=1;frame_bad<=1;end
            // Identity of the first accepted AXIS pixel, distinct from complete
            // frame certification. Tag was captured from the real source SOF.
            if(FRAME_TAGGED && axis_user && axis_valid && axis_ready && stream_active &&
                !frame_bad && !overflow_sync[2])begin
                frame_start_toggle<=~frame_start_toggle;frame_start_tag<=active_frame_tag;
            end
            // Certify only after the last AXIS word was actually accepted.
            // A starved/blocked frame never advances the visible-frame token.
            if(axis_eof && axis_valid && axis_ready && stream_active && !frame_bad && !overflow_sync[2])begin
                frame_done_toggle<=~frame_done_toggle;
                frame_done_tag<=FRAME_TAGGED ? active_frame_tag : 32'd0;
            end
            if(active && ox==1279 && oy[0])ready[rb]<=0;
            active_q<=active;sof_q<=active && ox==0 && oy==0;last_q<=active && ox==1279;
            eof_q<=active && ox==1279 && oy==719;axis_eof<=eof_q;
            rb_q<=rb;ready_q<=ready[rb];
            axis_valid<=active_q;axis_user<=sof_q;axis_last<=last_q;
            axis_data<=active_q && stream_active ? (ready_q ? (rb_q ? q1[24:1] : q0[24:1]) : 24'hb04070) : 24'd0;
        end
    end
endmodule

// Storage proof follows the same source frame as the25MHz compositor.
// The original FIFO returns valid one source clock after a read request.
// Raw VS clears the old frame before the21+14-stage active pipeline starts;
// the renderer's40-cycle inter-line gap drains that pipeline before next VS.
module hd720_source_integrity(
    input wire clk,rst,vs,read_enable,read_empty,read_valid,storage_required,
    output reg frame_fault
);
    reg vs_last,read_pending;
    wire bad=storage_required && ((read_enable && read_empty) || (read_pending && !read_valid));
    always @(posedge clk or posedge rst)begin
        if(rst)begin vs_last<=0;read_pending<=0;frame_fault<=0;end
        else begin
            vs_last<=vs;read_pending<=read_enable;
            if(vs && !vs_last)frame_fault<=0;
            if(bad)frame_fault<=1;
        end
    end
endmodule
