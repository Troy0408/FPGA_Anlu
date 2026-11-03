localparam integer FILTER_CYCLES = (CLK_FREQ_HZ / 1000 * DEBOUNCE_MS > 0) ?
                                   CLK_FREQ_HZ / 1000 * DEBOUNCE_MS : 1;
localparam integer FILTER_BITS = (FILTER_CYCLES < 2) ? 1 : $clog2(FILTER_CYCLES);
(* async_reg = "true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst) begin
    if (rst) reset_sync <= 3'b111;
    else reset_sync <= {reset_sync[1:0], 1'b0};
end
wire reset = reset_sync[2];
// Independently filter the two switches and two active-low keys. SW1=1 auto,
// SW2=1 contrast; defaults are manual/brightness, released keys.
(* async_reg = "true" *) reg [4:0] input_meta, input_sync;
reg [4:0] input_stable;
reg [FILTER_BITS-1:0] filter_count [0:4];
reg dec_press, inc_press;
integer k;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        input_meta <= 5'b01100; input_sync <= 5'b01100; input_stable <= 5'b01100;
        dec_press <= 0; inc_press <= 0;
        for (k=0; k<5; k=k+1) filter_count[k] <= 0;
    end else begin
        input_meta <= {subtitle_switch, key_inc_n, key_dec_n, switch_in};
        input_sync <= input_meta;
        dec_press <= 0; inc_press <= 0;
        for (k=0; k<5; k=k+1) begin
            if (input_sync[k] == input_stable[k]) filter_count[k] <= 0;
            else if (filter_count[k] == FILTER_CYCLES-1) begin
                input_stable[k] <= input_sync[k]; filter_count[k] <= 0;
                if (k==2 && input_stable[2] && !input_sync[2]) dec_press <= 1;
                if (k==3 && input_stable[3] && !input_sync[3]) inc_press <= 1;
            end else filter_count[k] <= filter_count[k] + 1'b1;
        end
    end
end
assign auto_enable = input_stable[0];
reg vs_last, de_last;
reg [9:0] x;
reg [8:0] y;

// E01 horizontal offsets and full-message off-screen wrap are informed by
// Project F render_sinescroll.sv, Will Green & Ben Blundell (2022), MIT,
// pinned dd212c2e5e0e0d8bdcf93ba077630dbfd49ae708. Team implementation uses
// direct 640x480 scanning, a TF-writable ASCII cache, and no sine/framebuffer.
// Startup-only dual-clock character RAM. Writer never changes RAM or its
// descriptor after done until COMMON reset. Synchronize the publish bit first,
// then capture the stable length/status bundle; no bitwise descriptor CDC.
wire [7:0] text_character1;
wire [7:0] text_read_addr;
generate if (!SHOWCASE_CN) begin: legacy_text_cache
    reg [7:0] text_memory [0:255];
    reg [7:0] character_read;
    always @(posedge text_clk) if(text_we) text_memory[text_addr]<=text_data;
    always @(posedge clk) character_read<=text_memory[text_read_addr];
    assign text_character1=character_read;
end else begin: no_legacy_text_cache
    assign text_character1=8'd0;
end endgenerate
(* async_reg = "true" *) reg [2:0] text_publish_sync;
reg text_captured;
reg [8:0] text_length_pending, text_length_frame;
reg [3:0] text_status_pending, text_status_frame;
reg subtitle_frame;
reg signed [13:0] scroll_offset;
wire [13:0] text_width = {1'b0,text_length_frame,4'b0};
wire signed [13:0] text_pixel = scroll_offset + $signed({4'b0,x});
assign text_read_addr = text_pixel[11:4];
reg [2:0] subtitle_selection_frame;
wire [2:0] subtitle_selection = subtitle_scene ? 3'd6 :
                                (subtitle_picture_bank < 3'd6 ? subtitle_picture_bank : 3'd0);
wire [8:0] subtitle_glyph_y=y-(SUBTITLE_TOP+8);
`include "scene/showcase_subtitle_logic.vh"
wire [7:0] showcase_glyph=showcase_message_glyph(subtitle_selection_frame,text_pixel[9:4]);
wire [3:0] showcase_row=subtitle_glyph_y[3:0];
assign subtitle_glyph=SHOWCASE_CN ? showcase_glyph : 8'd0;
assign subtitle_row=SHOWCASE_CN ? showcase_row : 4'd0;
wire showcase_ink;
generate if (SHOWCASE_CN) begin: cn_glyphs
    reg [7:0] glyph1;
    reg [3:0] column1;
    always @(posedge clk) begin
        glyph1<=showcase_glyph; column1<=text_pixel[3:0];
    end
    wire [15:0] glyph_row=glyph1[7] ? subtitle_font_hi_q : subtitle_font_q;
    assign showcase_ink=glyph_row[4'd15-column1];
end else begin: no_cn_glyphs
    assign showcase_ink=1'b0;
end endgenerate
always @(posedge clk or posedge reset) begin
    if(reset) begin
        text_publish_sync<=0; text_captured<=0; text_length_pending<=0; text_status_pending<=0;
        text_length_frame<=0; text_status_frame<=0; subtitle_frame<=0; scroll_offset<=-14'sd640;
        subtitle_selection_frame<=0;
    end else begin
        text_publish_sync<={text_publish_sync[1:0],text_done};
        if(text_publish_sync[2] && !text_captured) begin
            text_captured<=1; text_length_pending<=text_length; text_status_pending<=text_status;
        end
        // Exactly ONE update per frame (the leading VS edge in blanking).
        if(!in_de && in_vs && !vs_last) begin
            text_length_frame<=SHOWCASE_CN ? showcase_message_length(subtitle_selection) : text_length_pending;
            text_status_frame<=text_status_pending;
            if(SHOWCASE_CN) subtitle_selection_frame<=subtitle_selection;
            subtitle_frame<=(EXTERNAL_UI ? subtitle_switch : input_stable[4]) && (subtitle_scene || subtitle_catalog_ok);
            if(!(EXTERNAL_UI ? subtitle_switch : input_stable[4]) || !(subtitle_scene || subtitle_catalog_ok) || !subtitle_frame ||
               (SHOWCASE_CN ? subtitle_selection_frame!=subtitle_selection : text_length_frame!=text_length_pending) || text_length_frame==0)
                scroll_offset<=-14'sd640;
            else if(scroll_offset+SCROLL_STEP >= $signed(text_width)) scroll_offset<=-14'sd640;
            else scroll_offset<=scroll_offset+SCROLL_STEP;
        end
    end
end

reg signed [4:0] brightness_pending, brightness_frame; // -8..8, units of 16
reg [2:0] contrast_pending, contrast_frame;            // 0..4: .50/.75/1/1.25/1.50
reg [3:0] ui_brightness_frame,ui_contrast_frame;
reg select_frame, auto_frame;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        brightness_pending <= 0; brightness_frame <= 0;
        contrast_pending <= 2; contrast_frame <= 2;
        ui_brightness_frame<=5;ui_contrast_frame<=5;
        select_frame <= 0; auto_frame <= 0;
        vs_last <= 0; de_last <= 0; x <= 0; y <= 0;
    end else begin
        vs_last <= in_vs; de_last <= in_de;
        if (!EXTERNAL_UI && (dec_press ^ inc_press)) begin
            if (input_stable[1]) begin
                if (inc_press && contrast_pending < 4) contrast_pending <= contrast_pending + 1'b1;
                if (dec_press && contrast_pending > 0) contrast_pending <= contrast_pending - 1'b1;
            end else begin
                if (inc_press && brightness_pending < 5'sd8) brightness_pending <= brightness_pending + 1'b1;
                if (dec_press && brightness_pending > -5'sd8) brightness_pending <= brightness_pending - 1'b1;
            end
        end
        // Both VS edges lie in vertical blank, matching the reference bridge.
        // One frame uses one complete parameter/OSD snapshot, never torn digits.
        if (!in_de && in_vs != vs_last) begin
            brightness_frame <= brightness_pending; contrast_frame <= contrast_pending;
            ui_brightness_frame<=ui_brightness;ui_contrast_frame<=ui_contrast;
            select_frame <= input_stable[1]; auto_frame <= input_stable[0];
            x <= 0; y <= 0;
        end else if (in_de) x <= x + 1'b1;
        else begin
            x <= 0;
            if (de_last) y <= y + 1'b1;
        end
    end
end

function signed [11:0] contrast_product;
    input [7:0] pixel;
    input [2:0] level;
    reg signed [11:0] centered;
    begin
        centered = $signed({1'b0,pixel}) - 12'sd128;
        case (level)
            0: contrast_product = centered <<< 1;
            1: contrast_product = (centered <<< 1) + centered;
            2: contrast_product = centered <<< 2;
            3: contrast_product = (centered <<< 2) + centered;
            default: contrast_product = (centered <<< 2) + (centered <<< 1);
        endcase
    end
endfunction

// R03 live menu wiring, R04 image subpart: signed products stay in stage 1,
// constant division/clipping in stage 2. Round contrast towards zero.
function signed [11:0] ui_product;
    input [7:0] pixel;
    input [3:0] level;
    reg signed [8:0] centered;
    reg signed [5:0] factor;
    begin
        centered=$signed({1'b0,pixel})-9'sd128;
        factor=$signed({2'b0,level})+6'sd5;
        ui_product=centered*factor;
    end
endfunction
function signed [8:0] ui_offset;
    input [3:0] level;
    begin
        case(level)
            0:ui_offset=-128;1:ui_offset=-102;2:ui_offset=-77;
            3:ui_offset=-51;4:ui_offset=-26;5:ui_offset=0;
            6:ui_offset=26;7:ui_offset=51;8:ui_offset=77;
            9:ui_offset=102;default:ui_offset=128;
        endcase
    end
endfunction
function [7:0] ui_clip;
    input signed [11:0] product;
    input signed [8:0] offset;
    reg signed [12:0] value;
    begin
        value=product/12'sd10+offset+13'sd128;
        ui_clip=value<0 ? 8'd0 : value>255 ? 8'd255 : value[7:0];
    end
endfunction
function [7:0] clip_channel;
    input signed [11:0] product;
    input signed [4:0] brightness;
    reg signed [12:0] value;
    begin
        value = (product >>> 2) + $signed({brightness,4'b0}) + 13'sd128;
        if (value < 0) clip_channel = 0;
        else if (value > 255) clip_channel = 255;
        else clip_channel = value[7:0];
    end
endfunction

function [7:0] osd_char;
    input [2:0] row;
    input [4:0] column;
    input signed [4:0] brightness;
    input [2:0] contrast;
    input selected, auto_on;
    reg [191:0] line;
    reg [3:0] magnitude;
    reg [11:0] digits;
    begin
        case (row)
            0: line = "IMAGE SETTINGS          ";
            1: line = " BRIGHT: +000           ";
            2: line = " CONTRAST: 1.00X        ";
            3: line = "AUTO: OFF  PERIOD: 5S   ";
            4: line = "KEY2 NEXT  KEY3- KEY4+  ";
            5: line = "SW1 AUTO   SW2 SELECT   ";
            default: line = 192'd0;
        endcase
        osd_char = line[191 - column*8 -: 8];
        magnitude = (brightness < 0) ? -brightness : brightness;
        case (magnitude)
            0: digits=12'h000; 1: digits=12'h016; 2: digits=12'h032;
            3: digits=12'h048; 4: digits=12'h064; 5: digits=12'h080;
            6: digits=12'h096; 7: digits=12'h112; default: digits=12'h128;
        endcase
        if (row==1) begin
            case (column)
                0: osd_char = selected ? " " : ">";
                9: osd_char = (brightness < 0) ? "-" : "+";
                10: osd_char = 8'd48 + {4'd0,digits[11:8]};
                11: osd_char = 8'd48 + {4'd0,digits[7:4]};
                12: osd_char = 8'd48 + {4'd0,digits[3:0]};
                default: ;
            endcase
        end
        if (row==2) begin
            if (column==0) osd_char = selected ? ">" : " ";
            if (column==11) osd_char = (contrast<2) ? "0" : "1";
            if (column==13) begin
                case (contrast) 0,4: osd_char="5"; 1: osd_char="7";
                    3: osd_char="2"; default: osd_char="0"; endcase
            end
            if (column==14) osd_char = (contrast==1 || contrast==3) ? "5" : "0";
        end
        if (row==3 && auto_on) begin
            if (column==7) osd_char="N";
            if (column==8) osd_char=" ";
        end
    end
endfunction

`include "fonts/ascii_8x8.vh"

function [7:0] text_notice;
    input [5:0] column;
    input [3:0] result;
    reg [191:0] line;
    begin
        case(result)
            0:line="TEXT LOADING            ";
            3:line="NO TEXT.TXT             ";
            7:line="TEXT.TXT EMPTY          ";
            default:line="TEXT READ ERROR         ";
        endcase
        text_notice = column<24 ? line[191-column*8 -:8] : 8'h20;
        if(column==16 && result!=0 && result!=3 && result!=7)
            text_notice=8'd48+{4'd0,result};
    end
endfunction

wire [9:0] panel_x = x - 10'd8;
wire [8:0] panel_y = y - 9'd8;
wire in_panel = !EXTERNAL_UI && in_de && x>=8 && x<392 && y>=8 && y<104;
reg signed [11:0] r1, g1, b1;
reg signed [4:0] brightness1;
reg signed [8:0] ui_offset1;
reg [7:0] character1;
reg [5:0] glyph_index1;
reg panel1, border1, selected1;
reg hs1, vs1, de1, hs2, vs2, de2;
reg [23:0] rgb2;
reg picture1;
reg [5:0] gain1,gain2;
// Xosera video_blend_4bit.sv (Xark, MIT), pinned 51967d8c17409c151ba546f93be97f16375868f2,
// informs fixed-point gain and the exact opaque endpoint only. Team RGB888
// single-image fade; no upstream HDL, SB_MAC16 or second playfield is copied.
function [7:0] fade_channel;
    input [7:0] pixel;
    input [5:0] alpha;
    reg [12:0] product;
    begin
        product=pixel*alpha[4:0];
        fade_channel=alpha[5] ? pixel : product[12:5];
    end
endfunction
wire [23:0] faded_rgb2={fade_channel(rgb2[23:16],gain2),fade_channel(rgb2[15:8],gain2),fade_channel(rgb2[7:0],gain2)};
reg ink2, panel2, border2, selected2;
wire in_subtitle = in_de && subtitle_frame && y>=SUBTITLE_TOP && y<SUBTITLE_TOP+32;
wire subtitle_pixel_valid = text_pixel>=0 && text_pixel<$signed(text_width);
reg subtitle1, subtitle2, subtitle_ink1, subtitle_has_text1;
reg [7:0] notice1;
wire [63:0] glyph = font_8x8(subtitle1 ? (subtitle_has_text1 ? text_character1 : notice1) : character1);
always @(posedge clk or posedge reset) begin
    if (reset) begin
        r1<=0; g1<=0; b1<=0; brightness1<=0;ui_offset1<=0;picture1<=0;
        character1<=0; glyph_index1<=0; panel1<=0; border1<=0; selected1<=0;
        hs1<=0; vs1<=0; de1<=0; hs2<=0; vs2<=0; de2<=0;
        rgb2<=0; ink2<=0; panel2<=0; border2<=0; selected2<=0;
        gain1<=0; gain2<=0;
        subtitle1<=0; subtitle2<=0; subtitle_ink1<=0; subtitle_has_text1<=0; notice1<=0;
        out_hs<=0; out_vs<=0; out_de<=0; out_rgb<=0;
    end else begin
        // Stage 1: gain and character selection, carrying original raster timing.
        r1 <= EXTERNAL_UI ? ui_product(in_rgb[23:16],ui_contrast_frame) : contrast_product(in_rgb[23:16],contrast_frame);
        g1 <= EXTERNAL_UI ? ui_product(in_rgb[15:8],ui_contrast_frame) : contrast_product(in_rgb[15:8],contrast_frame);
        b1 <= EXTERNAL_UI ? ui_product(in_rgb[7:0],ui_contrast_frame) : contrast_product(in_rgb[7:0],contrast_frame);
        ui_offset1<=ui_offset(ui_brightness_frame);
        brightness1 <= brightness_frame;
        picture1 <= in_picture;
        gain1<=image_gain; gain2<=gain1;
        character1 <= osd_char(panel_y[6:4],panel_x[8:4],brightness_frame,
                              contrast_frame,select_frame,auto_frame);
        glyph_index1 <= in_subtitle ? {subtitle_glyph_y[3:1],(text_length_frame!=0 ? text_pixel[3:1] : x[3:1])} : {panel_y[3:1],panel_x[3:1]};
        subtitle1<=in_subtitle; subtitle_has_text1<=text_length_frame!=0;
        subtitle_ink1<=y>=SUBTITLE_TOP+8 && y<SUBTITLE_TOP+24 && (text_length_frame!=0 ? subtitle_pixel_valid : x<384);
        notice1<=text_notice(x[9:4],text_status_frame);
        panel1<=in_panel;
        border1<=(in_panel && (x==8 || x==391 || y==8 || y==103)) || (in_subtitle && y==SUBTITLE_TOP);
        selected1 <= (panel_y[6:4]==1 && !select_frame) ||
                     (panel_y[6:4]==2 && select_frame);
        hs1<=in_hs; vs1<=in_vs; de1<=in_de;
        // Stage 2: offset/clamp and glyph lookup; three independent RGB channels.
        rgb2 <= !picture1 ? 24'd0 : EXTERNAL_UI ? {ui_clip(r1,ui_offset1),ui_clip(g1,ui_offset1),ui_clip(b1,ui_offset1)} :
            {clip_channel(r1,brightness1),clip_channel(g1,brightness1),clip_channel(b1,brightness1)};
        ink2<=(SHOWCASE_CN && subtitle1 ? showcase_ink : glyph[6'd63-glyph_index1]) && (!subtitle1 || subtitle_ink1);
        subtitle2<=subtitle1;
        panel2<=panel1; border2<=border1; selected2<=selected1;
        hs2<=hs1; vs2<=vs1; de2<=de1;
        // Stage 3: text remains readable at all image brightness/contrast levels.
        out_hs<=hs2; out_vs<=vs2; out_de<=de2;
        if (!de2) out_rgb<=0;
        else if (border2 || ((panel2 || subtitle2) && ink2)) out_rgb<=
            border2 ? 24'h40ffff : subtitle2 ? 24'hfff080 : selected2 ? 24'h40ffff : 24'hffffff;
        else if (panel2 || subtitle2) out_rgb<={1'b0,faded_rgb2[23:17],1'b0,faded_rgb2[15:9],1'b0,faded_rgb2[7:1]};
        else out_rgb<=faded_rgb2;
    end
end
