// Diagnostic 2x scanout: one 640x360 SDRAM read per 1280x720 HDMI frame.
// Pixel clock domain throughout. FIFO pop is qualified by empty, response by
// valid; at most one read is outstanding. Missing rows turn magenta and latch
// underrun; the raster never waits for storage. No native 720p detail claim.
module hd720_frame_scanout #(
    parameter integer SOURCE_WIDTH=640, SOURCE_HEIGHT=360,
    parameter integer H_TOTAL=1650, H_START=260,
    parameter integer V_TOTAL=750, V_START=25,
    parameter integer USE_BRAM32K=0
)(
    input wire clk, rst,
    input wire ready_toggle,
    input wire [1:0] ready_bank,
    output reg presented_toggle,
    output reg [1:0] read_bank,
    output reg read_req,
    input wire read_req_ack,
    input wire read_empty, read_valid,
    input wire [31:0] read_data,
    output wire read_en,
    output reg axis_valid, axis_user, axis_last,
    output reg [23:0] axis_data,
    output reg axis_picture,
    output reg underrun,
    output reg [15:0] underrun_frames,
    output wire frame_start
);
    localparam integer OUT_WIDTH=SOURCE_WIDTH*2, OUT_HEIGHT=SOURCE_HEIGHT*2;
    reg [11:0] h, v;
    (* async_reg="true" *) reg [2:0] ready_sync, ack_sync;
    reg [1:0] bank_sync0, bank_sync1;
    reg applied_toggle, image_valid;
    reg [1:0] request_state;
    reg [3:0] settle;
    reg stream_ready, pending;
    reg [10:0] fill_row, fill_x;
    reg [1:0] line_ready;
    reg frame_failed;
    wire [23:0] line0_q,line1_q;
    wire row0_picture,row1_picture;
    reg active_q,sof_q,last_q,bank_q,row_ready_q,image_valid_q;
    reg presented_internal;
    wire active = h>=H_START && h<H_START+OUT_WIDTH &&
                  v>=V_START && v<V_START+OUT_HEIGHT;
    wire [11:0] visible_x=h-H_START, visible_y=v-V_START;
    wire [10:0] source_x=visible_x[11:1];
    wire source_bank=visible_y[1];
    assign frame_start=(h==0 && v==0);
    assign read_en=stream_ready && fill_row<SOURCE_HEIGHT &&
        !line_ready[fill_row[0]] && !pending && !read_empty;
    always @(posedge clk or posedge rst) begin
        if(rst)begin
            ready_sync<=0;ack_sync<=0;bank_sync0<=0;bank_sync1<=0;
        end else begin
            ready_sync<={ready_sync[1:0],ready_toggle};
            ack_sync<={ack_sync[1:0],read_req_ack};
            // Held bundle: bank is stable from ready publication through ACK.
            bank_sync0<=ready_bank;bank_sync1<=bank_sync0;
        end
    end
    always @(posedge clk or posedge rst) begin
        if(rst)begin h<=0;v<=0;end
        else if(h==H_TOTAL-1)begin h<=0;if(v==V_TOTAL-1)v<=0;else v<=v+1'b1;end
        else h<=h+1'b1;
    end
    // Reuse the selected official FIFO's proven simple dual-port RAM wrapper.
    // Fixed power-of-two depth maps to BRAM rather than a 640-way LUT mux.
    wire line_we=!rst && stream_ready && pending && read_valid;
    generate if(USE_BRAM32K)begin: wide_rows
        hd720_row32k row0(.clk(clk),.write_enable(line_we && !fill_row[0]),
            .write_x(fill_x[9:0]),.write_data({read_data[31:8],read_data[0]}),
            .read_x(source_x[9:0]),.read_data({line0_q,row0_picture}));
        hd720_row32k row1(.clk(clk),.write_enable(line_we && fill_row[0]),
            .write_x(fill_x[9:0]),.write_data({read_data[31:8],read_data[0]}),
            .read_x(source_x[9:0]),.read_data({line1_q,row1_picture}));
    end else begin: original_rows
    // Legacy diagnostic stores RGB only; the production marker needs 32K mode.
    assign row0_picture=1'b1;
    assign row1_picture=1'b1;
    ram_infer_rfifo_32_32_512 #(.DATAWIDTH_A(24),.DATAWIDTH_B(24),
        .ADDRWIDTH_A(10),.ADDRWIDTH_B(10),.MODE("SDP"),
        .RESETMODE_A("SYNC"),.RESETMODE_B("SYNC")) row0(
        .clka(clk),.rsta(1'b0),.cea(1'b1),.ocea(1'b0),.wea(line_we && !fill_row[0]),
        .dia(read_data[31:8]),.addra(fill_x[9:0]),.doa(),
        .clkb(clk),.rstb(1'b0),.ceb(1'b1),.oceb(1'b1),.web(1'b0),
        .dib(24'd0),.addrb(source_x[9:0]),.dob(line0_q));
    ram_infer_rfifo_32_32_512 #(.DATAWIDTH_A(24),.DATAWIDTH_B(24),
        .ADDRWIDTH_A(10),.ADDRWIDTH_B(10),.MODE("SDP"),
        .RESETMODE_A("SYNC"),.RESETMODE_B("SYNC")) row1(
        .clka(clk),.rsta(1'b0),.cea(1'b1),.ocea(1'b0),.wea(line_we && fill_row[0]),
        .dia(read_data[31:8]),.addra(fill_x[9:0]),.doa(),
        .clkb(clk),.rstb(1'b0),.ceb(1'b1),.oceb(1'b1),.web(1'b0),
        .dib(24'd0),.addrb(source_x[9:0]),.dob(line1_q));
    end endgenerate
    // RAM read stage and one output select stage; tags follow both stages.
    always @(posedge clk or posedge rst) begin
        if(rst)begin
            axis_valid<=0;axis_user<=0;axis_last<=0;axis_data<=0;axis_picture<=0;
            active_q<=0;sof_q<=0;last_q<=0;bank_q<=0;row_ready_q<=0;image_valid_q<=0;
            presented_toggle<=0;
        end
        else begin
            active_q<=active;sof_q<=active && visible_x==0 && visible_y==0;
            last_q<=active && visible_x==OUT_WIDTH-1;
            bank_q<=source_bank;row_ready_q<=line_ready[source_bank];image_valid_q<=image_valid;
            axis_valid<=active_q;axis_user<=sof_q;axis_last<=last_q;
            presented_toggle<=presented_internal;
            axis_picture<=active_q && image_valid_q && row_ready_q &&
                (bank_q ? row1_picture : row0_picture);
            if(active_q && image_valid_q)begin
                if(!row_ready_q)axis_data<=24'hb04070;
                else if(bank_q)axis_data<=line1_q;
                else axis_data<=line0_q;
            end else axis_data<=0;
        end
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            presented_internal<=0;read_bank<=0;read_req<=0;applied_toggle<=0;
            image_valid<=0;request_state<=0;settle<=0;stream_ready<=0;
            pending<=0;fill_row<=0;fill_x<=0;line_ready<=0;
            underrun<=0;underrun_frames<=0;frame_failed<=0;
        end else if(frame_start)begin
            stream_ready<=0;pending<=0;fill_row<=0;fill_x<=0;
            line_ready<=0;frame_failed<=0;settle<=0;
            if(ready_sync[2]!=applied_toggle)begin
                applied_toggle<=ready_sync[2];read_bank<=bank_sync1;image_valid<=1;
            end
            if(image_valid || ready_sync[2]!=applied_toggle)begin
                read_req<=1;request_state<=1;
            end
        end else begin
            // Complete the four-phase request/clear handshake before FIFO reads.
            if(request_state==1 && ack_sync[2])begin read_req<=0;request_state<=2;end
            if(request_state==2 && !ack_sync[2])begin request_state<=3;settle<=0;end
            if(request_state==3)begin
                if(settle==7)begin stream_ready<=1;request_state<=0;end
                else settle<=settle+1'b1;
            end
            if(read_en)pending<=1;
            if(stream_ready && pending && read_valid)begin
                pending<=0;
                if(fill_x==SOURCE_WIDTH-1)begin
                    line_ready[fill_row[0]]<=1;fill_row<=fill_row+1'b1;fill_x<=0;
                end else fill_x<=fill_x+1'b1;
            end
            if(active && image_valid && !line_ready[source_bank])begin
                underrun<=1;frame_failed<=1;
            end
            // Release a line only after its second displayed copy is complete.
            if(active && visible_x==OUT_WIDTH-1 && visible_y[0])begin
                line_ready[source_bank]<=0;
                if(visible_y==OUT_HEIGHT-1)begin
                    if(!frame_failed && line_ready[source_bank])presented_internal<=applied_toggle;
                    else if(underrun_frames!=16'hffff)underrun_frames<=underrun_frames+1'b1;
                end
            end
        end
    end
endmodule

// One physical 32K block per 640-pixel row, including the content/black-border
// marker. Both 16-bit ports address separate 1024-word halves in parallel.
// Ownership is external: writing and reading a row may not overlap. The
// scanout only writes a released bank, then publishes it after the last write.
// This replaces three 9K blocks, rather than adding to production's full pool.
module hd720_row32k(
    input wire clk,write_enable,
    input wire [9:0] write_x,read_x,
    input wire [24:0] write_data,
    output wire [24:0] read_data
);
    wire [15:0] lo,hi;
    wire [9:0] address=write_enable ? write_x : read_x;
    assign read_data={hi[8:0],lo};
    EG_PHY_BRAM32K #(
        .MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.SRMODE("SYNC")
    ) storage(
        .doa(lo),.dia(write_data[15:0]),.addra({1'b0,address}),
        .bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(write_enable),
        .clka(clk),.rsta(1'b0),.ocea(1'b1),
        .dob(hi),.dib({7'd0,write_data[24:16]}),.addrb({1'b1,address}),
        .byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(write_enable),
        .clkb(clk),.rstb(1'b0),.oceb(1'b1));
endmodule
