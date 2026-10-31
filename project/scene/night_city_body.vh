(* async_reg="true" *) reg [2:0] reset_sync;
always @(posedge clk or posedge rst)
 if(rst) reset_sync<=7; else reset_sync<={reset_sync[1:0],1'b0};
wire reset=reset_sync[2];
reg vs_last,de_last,enable_frame;
reg [1:0] season_frame;
reg [9:0] scan_x;
reg [8:0] scan_y;
reg [15:0] t;
wire frame_start=!in_de && in_vs && !vs_last;
always @(posedge clk or posedge reset) begin
 if(reset) begin vs_last<=0;de_last<=0;enable_frame<=0;scan_x<=0;scan_y<=0;season_frame<=0;t<=FRAME_START;end
 else begin
  vs_last<=in_vs;de_last<=in_de;
  if(frame_start) begin enable_frame<=enable;season_frame<=ENABLE_SEASONS ? scene_select : 2'd0;t<=t+1'b1;end
  if(!in_de && in_vs!=vs_last)begin scan_x<=0;scan_y<=0;end
  else if(in_de)scan_x<=scan_x+1'b1;
  else begin scan_x<=0;if(de_last)scan_y<=scan_y+1'b1;end
 end
end
// R12 live loudness: per-frame peak of the 5-bit PCM16 level (|x|>>10, the
// negative side via one's complement) -> 12-frame scrolling history, 0..28.
wire [4:0] aud_l=audio_left[23] ? ~audio_left[22:18] : audio_left[22:18];
wire [4:0] aud_r=audio_right[23] ? ~audio_right[22:18] : audio_right[22:18];
wire [4:0] aud_m=aud_l>aud_r ? aud_l : aud_r;
reg [4:0] aud_peak;
reg [4:0] hist0,hist1,hist2,hist3,hist4,hist5,hist6,hist7,hist8,hist9,hist10,hist11;
wire [4:0] peak_level=aud_peak>5'd28 ? 5'd28 : aud_peak;
always @(posedge clk or posedge reset) begin
 if(reset) begin aud_peak<=0;{hist0,hist1,hist2,hist3,hist4,hist5,hist6,hist7,hist8,hist9,hist10,hist11}<=60'd0;end
 else begin
  if(frame_start) begin
   aud_peak<=0;
   {hist11,hist10,hist9,hist8,hist7,hist6,hist5,hist4,hist3,hist2,hist1,hist0}<=
    {hist10,hist9,hist8,hist7,hist6,hist5,hist4,hist3,hist2,hist1,hist0,peak_level};
  end else if(audio_valid && aud_m>aud_peak) aud_peak<=aud_m;
 end
end
function [7:0] hash8;
 input [15:0] a;reg [15:0] v;
 begin v=a^(a<<5);v=v^(v>>3);v=v^(v<<7);v=v^((v>>4)&(v>>9));hash8=v[7:0]^(v>>8);end
endfunction
function [2:0] tri4;
 input [3:0] v;
 begin tri4=v[3] ? ~v[2:0] : v[2:0];end
endfunction
// ---- BRAM prefetch chain (addresses only; data meet stage1 at pixel P) ----
wire [15:0] tilemap_q0,tilemap_q1,cloud_q,char_q,palette_q,season_lo,season_hi;
wire [15:0] tileset_q[0:5];
wire [10:0] season_addr;
wire [8:0] logical_y=scan_y-SCENE_TOP;
wire [9:0] map_x=in_de ? scan_x+10'd2 : 10'd0;     // pixel P, sampled at P-2
wire [9:0] tile_x=in_de ? scan_x+10'd1 : 10'd0;    // pixel P, sampled at P-1
wire [12:0] tilemap_index={logical_y[8:3],6'd0}+{2'b0,logical_y[8:3],4'd0}+{6'd0,map_x[9:3]};
wire [11:0] tilemap_addr=tilemap_index[11:0];
reg tilemap_sel;
wire [15:0] tilemap_word=tilemap_sel ? tilemap_q1 : tilemap_q0;
wire [10:0] subtitle_font_addr={subtitle_glyph[6:0],subtitle_row};
wire [9:0] tile_id=tilemap_word[9:0];
wire tile_mono=tile_id<10'd143;
wire tile_compressed=tile_id<10'd512;
wire [13:0] tile_address=tile_mono ?
    {2'b00,tile_id,2'b00}+{12'd0,logical_y[2:1]} : tile_compressed ?
    {1'b0,tile_id,3'b000}-14'd572+{11'd0,logical_y[2:0]} :
    {tile_id,4'b0000}-14'd4668+{10'd0,logical_y[2:0],tile_x[2]};
wire [10:0] tileset_addr=tile_address[10:0];
wire [10:0] tile_decode_addr=11'd1284+{1'b0,tile_id};
wire [15:0] tile_decode_q;
reg [2:0] tileset_block,pixel_sel;reg [1:0] nibble_sel;reg [5:0] palette_sel;
reg tile_compressed1,tile_mono1,row_parity1;
wire [15:0] tileset_word=tileset_q[tileset_block];
wire [1:0] compact_pix=tile_mono1 ? {1'b0,tileset_word[{row_parity1,pixel_sel}]} :
                                      tileset_word[{pixel_sel,1'b0}+:2];
wire [3:0] tile_pix=tile_compressed1 ? tile_decode_q[{compact_pix,2'b00}+:4] :
                                        tileset_word[{nibble_sel,2'b00}+:4];
wire [10:0] palette_addr={2'b11,palette_sel,tile_pix[3:1]};
reg palette_byte;
wire [7:0] static_code=palette_byte ? palette_q[15:8] : palette_q[7:0];
// character sprite (60x98 at x479,y217) with live breathing row offset
wire [9:0] sprite_lx=scan_x-10'd479;
wire [8:0] sprite_ly=logical_y-9'd217;
wire breath_now=t[8:7]==2'd1;
wire [8:0] sprite_row=(breath_now && sprite_ly<9'd36) ? sprite_ly+9'd1 : sprite_ly;
wire [10:0] char_addr={sprite_row[6:0],4'd0}-{4'd0,sprite_row[6:0]}+{5'd0,sprite_lx[7:2]};
reg [1:0] char_nibble;reg sprite_box;
wire [3:0] char_pix=sprite_box ? char_q[{char_nibble,2'b00}+:4] : 4'd0;
wire [9:0] cloud_u=scan_x+t[12:3];
wire [10:0] cloud_addr={3'b111,cloud_u[8:1]};
`include "scene/night_tiles_rom.vh"
always @(posedge clk or posedge reset)
 if(reset)begin tilemap_sel<=0;tileset_block<=0;nibble_sel<=0;pixel_sel<=0;tile_compressed1<=0;tile_mono1<=0;row_parity1<=0;palette_sel<=0;palette_byte<=0;char_nibble<=0;sprite_box<=0;end
 else begin
  tilemap_sel<=tilemap_addr[11];
  tileset_block<=tile_address[13:11];nibble_sel<=tile_x[1:0];pixel_sel<=tile_x[2:0];tile_compressed1<=tile_compressed;tile_mono1<=tile_mono;row_parity1<=logical_y[0];palette_sel<=tilemap_word[15:10];
  palette_byte<=tile_pix[0];
  char_nibble<=sprite_lx[1:0];sprite_box<=sprite_lx<10'd60 && sprite_ly<9'd98;
 end
// ---- R12 street detail: outline strips, cable bulbs, two screens, shops ----
// Pure logic over the pixel coordinates (no tiles). It is evaluated one clock
// early from scan_x/logical_y (pixel P) and registered beside x/y, so stage 1
// only selects. Codes 208..228 live in the season ROM; its flags give strips,
// bulbs and signs the existing breathe/chase/flicker pulse.
// Bit-exact model: detail() in tools/night_city_model.py.
wire [9:0] px=scan_x;
wire [8:0] py=logical_y;
wire det_lane=px<10'd476;
reg det_seam;reg [7:0] seam_code;
always @* begin
 det_seam=1;seam_code=8'd220;
 case(px)
  10'd60,10'd192,10'd332,10'd456:seam_code=8'd220;
  10'd116,10'd260,10'd400:seam_code=8'd221;
  default:det_seam=0;
 endcase
end
wire vstrip=det_seam && py>=9'd226 && det_lane;
wire hstrip=py==9'd303 && det_lane && px>=10'd2;
// cables: one shared squarer, the two spans are disjoint in x
wire cab1=px<10'd236;
wire cab_in=cab1 || (px>=10'd260 && px<10'd476);
wire [9:0] cab_c=cab1 ? 10'd118 : 10'd368;
wire [9:0] cab_dx=px>=cab_c ? px-cab_c : cab_c-px;     // <=118
// sag=floor(dx*dx/1024) by thresholds (no multiplier): dx>=ceil(32*sqrt(k))
wire [6:0] cd=cab_dx[6:0];
wire [3:0] cab_sag=(cd>=7'd32)+(cd>=7'd46)+(cd>=7'd56)+(cd>=7'd64)+(cd>=7'd72)+(cd>=7'd79)+
                   (cd>=7'd85)+(cd>=7'd91)+(cd>=7'd96)+(cd>=7'd102)+(cd>=7'd107)+(cd>=7'd111)+(cd>=7'd116);
wire [8:0] cab_y=(cab1 ? 9'd235 : 9'd233)-{5'd0,cab_sag};
wire cab_wire=cab_in && py==cab_y;
wire [8:0] cab_dy=py-cab_y;
wire cab_bulb=cab_in && (px[2:0]==3'd3 || px[2:0]==3'd4) && cab_dy>=9'd1 && cab_dy<=9'd2;
wire [7:0] bulb_code=px[4:3]==2'd1 ? 8'd218 : px[4:3]==2'd2 ? 8'd219 : 8'd217;
// screens: shared scanline background with a slow bright sweep
wire [4:0] sweep_u=py[4:0]-t[5:1];
wire [7:0] scr_bg=sweep_u==5'd0 ? 8'd212 : py[0] ? 8'd210 : 8'd209;
wire scr_a=px>=10'd10 && px<10'd104 && py>=9'd238 && py<9'd264;
wire scr_a_in=px>=10'd12 && px<10'd102 && py>=9'd240 && py<9'd262;
wire scr_b=px>=10'd338 && px<10'd394 && py>=9'd240 && py<9'd276;
wire scr_b_in=px>=10'd340 && px<10'd392 && py>=9'd242 && py<9'd274;
// screen B bars: 12 columns of 3px at x342+4b, newest at the right
wire [9:0] bar_u=px-10'd342;
reg [4:0] bar_h;
always @* case(bar_u[5:2])
 4'd0:bar_h=hist11; 4'd1:bar_h=hist10; 4'd2:bar_h=hist9; 4'd3:bar_h=hist8;
 4'd4:bar_h=hist7; 4'd5:bar_h=hist6; 4'd6:bar_h=hist5; 4'd7:bar_h=hist4;
 4'd8:bar_h=hist3; 4'd9:bar_h=hist2; 4'd10:bar_h=hist1; 4'd11:bar_h=hist0;
 default:bar_h=5'd0;
endcase
wire [8:0] bar_rise=9'd272-py;
wire bar_pix=scr_b_in && px>=10'd342 && bar_u<10'd48 && bar_u[1:0]!=2'd3 && py<9'd272 && bar_rise<={4'd0,bar_h};
wire [7:0] bar_code=bar_rise<9'd8 ? 8'd213 : bar_rise<9'd16 ? 8'd214 : 8'd215;
// street shop signs (same row, disjoint in x)
wire shop_row=py>=9'd330 && py<9'd346;
wire shop0=shop_row && px>=10'd126 && px<10'd172;
wire shop1=shop_row && px>=10'd266 && px<10'd318;
wire shop2=shop_row && px>=10'd404 && px<10'd456;
wire shop_any=shop0 || shop1 || shop2;
wire shop_edge=py==9'd330 || py==9'd345 || px==10'd126 || px==10'd171 || px==10'd266 || px==10'd317 || px==10'd404 || px==10'd455;
wire [7:0] shop_frame=shop0 ? 8'd223 : shop1 ? 8'd228 : 8'd227;
wire [7:0] shop_text=shop0 ? 8'd224 : shop1 ? 8'd225 : 8'd226;
// one shared 3x5 scale-2 text unit; origin chosen by the region it serves
reg [79:0] txt_str;reg [9:0] txt_x;reg [8:0] txt_y;
always @* begin
 if(py<9'd300)begin txt_str="NIGHT CITY";txt_x=10'd18;txt_y=9'd246;end
 else if(px<10'd220)begin txt_str="DOLLS     ";txt_x=10'd130;txt_y=9'd333;end
 else if(px<10'd360)begin txt_str="NOODLE    ";txt_x=10'd269;txt_y=9'd333;end
 else begin txt_str="CLINIC    ";txt_x=10'd407;txt_y=9'd333;end
end
wire [9:0] txt_u=px-txt_x;
wire [8:0] txt_v=py-txt_y;
wire [3:0] txt_idx=txt_u[6:3];
wire [1:0] txt_col=txt_u[2:1];
wire [3:0] txt_row=txt_v[4:1];
reg [7:0] txt_ch;
always @* case(txt_idx)
 4'd0:txt_ch=txt_str[79:72]; 4'd1:txt_ch=txt_str[71:64]; 4'd2:txt_ch=txt_str[63:56]; 4'd3:txt_ch=txt_str[55:48];
 4'd4:txt_ch=txt_str[47:40]; 4'd5:txt_ch=txt_str[39:32]; 4'd6:txt_ch=txt_str[31:24]; 4'd7:txt_ch=txt_str[23:16];
 4'd8:txt_ch=txt_str[15:8];  4'd9:txt_ch=txt_str[7:0];   default:txt_ch=8'h20;
endcase
reg [14:0] glyph;
always @* case(txt_ch)
 8'h4e:glyph=15'b101_111_111_111_101; 8'h49:glyph=15'b111_010_010_010_111;   // N I
 8'h47:glyph=15'b011_100_101_101_011; 8'h48:glyph=15'b101_101_111_101_101;   // G H
 8'h54:glyph=15'b111_010_010_010_010; 8'h43:glyph=15'b011_100_100_100_011;   // T C
 8'h59:glyph=15'b101_101_010_010_010; 8'h44:glyph=15'b110_101_101_101_110;   // Y D
 8'h4f:glyph=15'b010_101_101_101_010; 8'h4c:glyph=15'b100_100_100_100_111;   // O L
 8'h53:glyph=15'b011_100_010_001_110; 8'h45:glyph=15'b111_100_110_100_111;   // S E
 default:glyph=15'd0;
endcase
reg [2:0] glyph_row;
always @* case(txt_row)
 4'd0:glyph_row=glyph[14:12]; 4'd1:glyph_row=glyph[11:9]; 4'd2:glyph_row=glyph[8:6];
 4'd3:glyph_row=glyph[5:3];   4'd4:glyph_row=glyph[2:0]; default:glyph_row=3'd0;
endcase
reg glyph_bit;
always @* case(txt_col) 2'd0:glyph_bit=glyph_row[2]; 2'd1:glyph_bit=glyph_row[1]; 2'd2:glyph_bit=glyph_row[0]; default:glyph_bit=1'b0; endcase
wire txt_pix=px>=txt_x && py>=txt_y && txt_u<10'd128 && txt_v<9'd10 && glyph_bit;
// final early code; strips still need the stage-1 front-building mask
wire det_hi=cab_wire || cab_bulb || scr_a || scr_b || shop_any;
wire [7:0] det_hi_code=shop_any ? (shop_edge ? shop_frame : txt_pix ? shop_text : 8'd222) :
                       scr_b ? (!scr_b_in ? 8'd208 : bar_pix ? bar_code : scr_bg) :
                       scr_a ? (!scr_a_in ? 8'd208 : txt_pix ? 8'd211 : scr_bg) :
                       cab_bulb ? bulb_code : 8'd216;
wire [7:0] det_strip_code=vstrip ? seam_code : {7'b1101110,px[5]};   // 220/221
reg det_hi1,det_strip1;reg [7:0] det_hi_code1,det_strip_code1;
always @(posedge clk or posedge reset)
 if(reset)begin det_hi1<=0;det_strip1<=0;det_hi_code1<=0;det_strip_code1<=0;end
 else begin det_hi1<=in_de && det_hi;det_strip1<=in_de && (vstrip||hstrip);det_hi_code1<=det_hi_code;det_strip_code1<=det_strip_code;end
// ---- Stage 1: original video bundle and pixel P coordinates ----
reg hs1,vs1,de1,pic1,en1,body1;
reg [1:0] season1;
reg [23:0] rgb1;
reg [9:0] x;reg [8:0] y;
always @(posedge clk or posedge reset)
 if(reset)begin hs1<=0;vs1<=0;de1<=0;pic1<=0;en1<=0;body1<=0;rgb1<=0;x<=0;y<=0;season1<=0;end
 else begin hs1<=in_hs;vs1<=in_vs;de1<=in_de;pic1<=in_picture;en1<=enable_frame;
  rgb1<=in_rgb;x<=scan_x;y<=logical_y;body1<=scan_y>=SCENE_TOP && scan_y<SCENE_TOP+360;season1<=season_frame;end
wire spring=season1==2'd0,summer=season1==2'd1,autumn=season1==2'd2,winter=season1==2'd3;
wire [1:0] bxy=x[1:0]^y[1:0];
wire [3:0] dith={bxy[0],y[0],bxy[1],y[1]};          // 4x4 ordered dither
// sky gradient: 16 dithered bands
wire [11:0] band_sum={1'b0,y,2'b00}+{3'b0,y}+{6'd0,dith,2'b00};
wire [3:0] band=band_sum[11:6]>6'd15 ? 4'd15 : band_sum[9:6];
// One hash unit: stars (spring/autumn) or the lightning slot (summer only).
wire [7:0] star_h=hash8(season1==2'd1 ? {6'd0,t[15:6]} : {y[8:1],x[8:1]}^16'h5a00);
wire star=!season1[0] && star_h==8'h3c && !x[0] && !y[0] && y<9'd150;
wire [9:0] far_u=x+t[15:6];
wire far_band=(y>=9'd30 && y<9'd33)||(y>=9'd58 && y<9'd60)||(y>=9'd84 && y<9'd87);
wire [7:0] far_h=hash8({6'd0,far_u[9:4],4'd0}^{10'd0,y[8:3]}^16'h2700);
wire streak=far_band && far_h[1:0]==2'd0;
// sun / moon: octagonal distance, dithered halo
reg [9:0] body_x;reg [8:0] body_y;reg [4:0] body_r,halo_r;
always @* case(season1)
 2'd0:{body_x,body_y,body_r,halo_r}={10'd84,9'd50,5'd12,5'd6};
 2'd1:{body_x,body_y,body_r,halo_r}={10'd376,9'd124,5'd18,5'd14};
 2'd2:{body_x,body_y,body_r,halo_r}={10'd548,9'd46,5'd10,5'd10};
 default:{body_x,body_y,body_r,halo_r}={10'd64,9'd36,5'd12,5'd12};
endcase
wire [9:0] sdx=x>=body_x ? x-body_x : body_x-x;
wire [8:0] sdy=y>=body_y ? y-body_y : body_y-y;
wire [10:0] sdist=(sdx>{1'b0,sdy} ? {1'b0,sdx}+{3'd0,sdy[8:1]} : {2'b0,sdy}+{2'd0,sdx[9:1]});
wire [5:0] reach={1'b0,body_r}+{1'b0,halo_r};
wire [10:0] halo_gap={5'd0,reach}-sdist;
wire halo=sdist<{5'd0,reach} && {4'd0,dith}<{halo_gap[5:0],2'b00};
wire disc=sdist<{6'd0,body_r};
wire [10:0] diag_sum={1'b0,x}+{2'b0,y};
wire shaded=diag_sum>{1'b0,body_x}+{2'b0,body_y}+{7'd0,body_r[4:1]};
// craters as small |dx|,|dy| windows on the side given by the abs-compare sign
wire west=x<body_x,north=y<body_y;
wire crater=!season1[0] && ((west && sdx>=10'd2 && sdx<=10'd5 && north && sdy>=9'd3 && sdy<=9'd5) ||
                            (!west && sdx>=10'd2 && sdx<=10'd4 && !north && sdy>=9'd1 && sdy<=9'd3));
// near cloud: height field ROM (prefetched by scan_x), per-season scale
reg [8:0] cloud_base;
always @* case(season1) 2'd0:cloud_base=9'd76; 2'd1:cloud_base=9'd96; 2'd2:cloud_base=9'd74; default:cloud_base=9'd100; endcase
wire [3:0] rise=cloud_q[3:0];
wire [5:0] cloud_rise=summer ? {rise,2'b00} : {1'b0,rise,1'b0};
wire [8:0] cloud_top=cloud_base-{3'd0,cloud_rise};
wire [6:0] cloud_h={1'b0,cloud_rise}+7'd6+{4'd0,cloud_q[5:4],1'b0};   // bot-top <= 72
// y<top wraps cloud_depth to >=416 (top<=96), so one compare replaces two.
wire [8:0] cloud_depth=y-cloud_top;
wire cloud=rise>=4'd5 && cloud_depth<{2'b0,cloud_h};
wire cloud_under=cloud_depth>={2'b0,cloud_h}-9'd2;
wire [3:0] cloud_shade=cloud_depth>9'd15 ? 4'd15 : cloud_depth[3:0];
// lightning (summer): per-frame slot hash; bolt zig-zag from two triangle waves
wire [7:0] slot=star_h;
wire strike=summer && slot[2:0]==3'd5 && t[5:0]<6'd12 && !(t[5:0]>=6'd4 && t[5:0]<6'd6);
wire distant_flash=summer && slot[2:0]==3'd2 && t[5:0]<6'd6;
wire [9:0] bolt_pos=10'd120+{2'b0,slot[7:4],4'd0}+{5'd0,slot[2:0],2'b00}+{7'd0,tri4(y[5:2])}+{7'd0,tri4(y[7:4]^4'd5)};
wire [9:0] bolt_d=bolt_pos-x;                     // bolt column = bolt_pos-7
wire bolt=strike && y>=9'd70 && y<9'd200 && bolt_d>=10'd6 && bolt_d<=10'd8;
// windows: tile slot 1/2 lit, hue and slow blink from a hash of the 4x8 cell
wire near_win=static_code==8'd2;
wire [7:0] win_h=hash8({near_win,1'b0,y[8:3],8'd0}^{8'd0,x[9:2]}^16'h1300);
wire win_blink=win_h[4:0]==5'd7 && (t[7]^win_h[0]);
wire win_drift=win_h[5:0]==6'd11 && (t[10]^win_h[6]);
reg [7:0] lit_level;
always @* case(season1) 2'd0:lit_level=LIT_SPRING; 2'd1:lit_level=LIT_SUMMER; 2'd2:lit_level=LIT_AUTUMN; default:lit_level=LIT_WINTER; endcase
wire win_lit=(win_h<lit_level)^win_blink^win_drift;
wire [7:0] window_code={4'h8,near_win,win_lit,win_h[2:1]};
// character: live breathing (row offset above), jacket corner and hood tuft
wire breath=t[8:7]==2'd1;
wire [1:0] sway=tri4(t[8:5])>>1;
wire [9:0] cloth_dx=x-10'd530;
wire [8:0] cloth_dy=y-9'd263;
wire cloth=cloth_dy<9'd9 && cloth_dx<10'd3+{8'd0,sway}+{8'd0,cloth_dy[3:2]} && char_pix==4'd0;
wire [8:0] tuft_dy=y-9'd225+{8'd0,breath};
wire tuft=x==10'd531 && (tuft_dy==9'd0 || tuft_dy==9'd1+{8'd0,t[5]}) && char_pix==4'd0;
wire person=char_pix!=4'd0 || cloth || tuft;
// traffic: five sky-lane cars + elevated train; positions = frame counter
wire [9:0] car_pos0=t[10:1]+t[12:3];
wire [9:0] car_pos1=10'd470-(t[9:0]+t[11:2]);
wire [9:0] car_pos2=10'd160-(t[10:1]+t[11:2]);
wire [9:0] car_pos3=10'd590+t[9:0];
wire [9:0] car_pos4=10'd300+t[10:1];
// Lanes are disjoint (rows 103/115/128/141/150 + bob), so one sprite unit
// selected by y draws all five cars without a priority chain.
reg [9:0] lane_pos;reg [4:0] lane_len;reg [2:0] lane_y;reg lane_right,lane_bob,lane_hit;reg [7:0] lane_lamp;
always @* begin
 lane_hit=1;lane_pos=car_pos0;lane_len=5'd16;lane_y=3'd7;lane_right=1;lane_bob=t[6];lane_lamp=8'd180;
 if(y>=9'd103 && y<9'd108)begin end
 else if(y>=9'd115 && y<9'd120)begin lane_pos=car_pos4;lane_len=5'd10;lane_y=3'd3;lane_right=1;lane_bob=t[6];lane_lamp=8'd181;end
 else if(y>=9'd128 && y<9'd133)begin lane_pos=car_pos1;lane_len=5'd12;lane_y=3'd0;lane_right=0;lane_bob=!t[6];lane_lamp=8'd182;end
 else if(y>=9'd141 && y<9'd146)begin lane_pos=car_pos2;lane_len=5'd20;lane_y=3'd5;lane_right=0;lane_bob=t[6];lane_lamp=8'd181;end
 else if(y>=9'd150 && y<9'd155)begin lane_pos=car_pos3;lane_len=5'd14;lane_y=3'd6;lane_right=1;lane_bob=!t[6];lane_lamp=8'd180;end
 else lane_hit=0;
end
// lane_y holds lane[2:0]; in-band rows differ by 0..4 so 3 bits suffice.
// Car extent u=(x-pos) mod 1024 < len (len<=20) replaces the +64 window.
wire [9:0] cu=x-lane_pos;
wire [2:0] cr=y[2:0]-lane_y-{2'd0,lane_bob};
wire cin=lane_hit && cu<{5'd0,lane_len};
wire cfront=lane_right ? cu[4:0]>=lane_len-5'd2 : cu[4:0]<5'd2;
wire crear=lane_right ? cu[4:0]<5'd2 : cu[4:0]>=lane_len-5'd2;
wire croof=cin && cr==3'd0 && cu[4:0]>=5'd3 && cu[4:0]<lane_len-5'd3;
wire cbody=cin && (cr==3'd1 || cr==3'd2);
wire cglow=cin && cr==3'd3 && dith<4'd6;
wire traffic=croof||cbody||cglow;
wire [7:0] traffic_code=croof ? 8'd178 : (cbody && cfront) ? 8'd179 : (cbody && !crear) ? 8'd177 : lane_lamp;
wire [9:0] train_pos=t[9:0]+t[11:2];
wire [9:0] train_u=x-train_pos;
wire train_row=y>=9'd161 && y<9'd167;
wire [2:0] train_r=y[2:0]-3'd1;                    // 161..166 -> 0..5
wire train_in=train_row && train_u<10'd72;
wire train_roof=train_in && train_r==3'd0 && train_u[6:0]>=7'd3 && train_u[6:0]<7'd69;
wire train_body=train_in && train_r!=3'd0;
wire train_window=train_body && (train_r==3'd2||train_r==3'd3) && train_u[2:0]>=3'd2 && train_u[2:0]<3'd7;
wire [7:0] train_code=train_roof ? 8'd184 : train_window ? 8'd185 : (train_body && train_u[6:0]>=7'd69) ? 8'd179 :
                      (train_body && train_u[6:0]<7'd2) ? 8'd182 : 8'd183;
wire traffic_any=traffic||train_roof||train_body;
wire traffic_shown=traffic_any && static_code<FRONT_SPLIT && !person;
wire det_front=static_code>=FRONT_SPLIT || static_code==8'd2;   // R12 strips: front facades only
// weather. Far layers hide behind the slanted roof and the character.
wire [12:0] roof_diag={3'd0,x}+{1'b0,y,3'b0};
wire roof=x>=10'd485 && y>=9'd258 && roof_diag>=13'd2693;
// particle lanes (winter snow / autumn leaves)
wire [9:0] pa_x=winter ? x+t[11:2]+{7'd0,tri4(y[7:4]+t[8:5])} : x+t[11:2];
wire [9:0] pb_x=x+t[10:1]+(winter ? {6'd0,tri4(y[7:4]+t[7:4]),1'b0} : {6'd0,tri4(y[7:4]+t[8:5]),1'b0});
// spring rain: two diagonal rolling textures (additive light in stage 2)
wire [9:0] fu=x+{3'd0,y[8:3]};
// Shared lane hashes: spring rain vs winter snow / autumn leaves.
wire [7:0] lane_ha=hash8(spring ? {8'd0,fu[9:2]} : {6'd2,pa_x[9:2]});
wire [7:0] fh=lane_ha;
wire [6:0] fp=y[6:0]-t[6:0]+fh[6:0];
wire far_rain=spring && fu[1:0]==2'd1 && fh[1:0]==2'd0 && fp<7'd4 && !roof && !person;
wire [9:0] nu=x+{2'd0,y[8:2]};
wire [7:0] lane_hb=hash8(spring ? {8'd1,nu[9:2]} : {8'd3,1'b0,pb_x[9:3]});
wire [7:0] nh=lane_hb;
wire [7:0] np=y[7:0]-(t[7:0]+{t[6:0],1'b0})+nh;
wire near_rain=spring && nu[2:0]==3'd3 && nh[2:0]==3'd1 && np<8'd8;
// winter snow / autumn leaves share two particle-lane hash units
wire [7:0] pa_h=lane_ha;
wire [6:0] pa_p=winter ? y[6:0]-t[7:1]+pa_h[6:0] : y[6:0]-t[8:2]+pa_h[6:0];
wire pa=winter ? (pa_x[1:0]==2'd1 && pa_h[2:0]==3'd2 && pa_p<7'd2) :
        autumn ? (pa_x[1:0]==2'd1 && pa_h[2:0]==3'd4 && pa_p==7'd0) : 1'b0;
wire [7:0] pb_h=lane_hb;
wire [7:0] pb_p=winter ? y[7:0]-t[7:0]+pb_h : y[7:0]-t[8:1]+pb_h;
wire [1:0] spin=t[4:3]+pb_h[1:0];
wire [2:0] leaf_x=pb_x[2:0];
wire leaf_shape=spin==2'd0 ? (pb_p==8'd0 && leaf_x<3'd3) : spin==2'd1 ? (leaf_x=={1'b0,pb_p[1:0]} && pb_p<8'd3) :
                spin==2'd2 ? (leaf_x==3'd1 && pb_p<8'd3) : (pb_p<8'd2 && leaf_x<3'd2);
wire pb=winter ? (pb_x[2:0]<3'd2 && pb_h[2:0]==3'd5 && pb_p<8'd2) : autumn ? (pb_h[1:0]==2'd1 && leaf_shape) : 1'b0;
wire [7:0] pa_code=winter ? 8'd187 : 8'd188;
wire [7:0] pb_code=winter ? 8'd186 : pb_h[3] ? 8'd189 : 8'd188;
// winter breath vapour, rising and fading during the exhale phase
wire [4:0] vt=t[6:2];
wire vapor_on=winter && t[8:7]==2'd3;
wire [9:0] vapor_x=10'd500-{7'd0,vt[4:2]};
wire [8:0] vapor_y=9'd233-{7'd0,vt[4:3]};
wire [2:0] vapor_r=3'd1+{1'b0,vt[4:3]};
// |d|<=r  <=>  (d+r) unsigned < 2r+1: same square, no absolute-value muxes.
wire [9:0] vdx=x-vapor_x+{7'd0,vapor_r};
wire [8:0] vdy=y-vapor_y+{6'd0,vapor_r};
wire vapor=vapor_on && vdx<{6'd0,vapor_r,1'b1} && vdy<{5'd0,vapor_r,1'b1} && dith<4'd12-{1'b0,vt[4:2]} && !person;
// spring rooftop splash / wet glints (shared hash)
wire [7:0] glint_h=hash8({y[8:1],7'd0}^{6'd0,x[9:1]}^{t[8:4],11'd0}^16'h6100);
wire splash=spring && roof && !person && glint_h[4:0]==5'd9 && !(x[0]^y[0]);
// autumn fog density (dithered), winter sun beams (dithered)
// 31-|y-184|/2 over 122..247 as one subtract: y>=184 uses y, else 368-y.
wire [8:0] fog_fold=y>=9'd184 ? y : 9'd368-y;
wire [8:0] fog_ady=fog_fold-9'd184;
wire [5:0] fog_dens=(y>=9'd122 && y<9'd248) ? 6'd31-{1'b0,fog_ady[5:1]} : 6'd0;
wire [9:0] fog_u=x+{6'd0,t[15:4]};
wire [9:0] fog_v={1'b0,x[9:1]}-{5'd0,t[15:5]}+{1'b0,y};
wire [3:0] fog_noise={1'b0,tri4(fog_u[8:5])}+{1'b0,tri4(fog_v[7:4])};
wire [6:0] fog_sum={1'b0,fog_dens}+{2'b0,fog_noise,1'b0};
wire fog=fog_sum[6:1]>{2'b0,dith}+6'd6;
wire [6:0] beam_u=x[6:0]+y[7:1]+t[11:5];
wire [5:0] beam_dn=6'd47-beam_u[5:0];
wire [4:0] beam_tri=beam_u<7'd24 ? beam_u[4:0] : beam_u<7'd48 ? beam_dn[4:0] : 5'd0;
wire beam=y<9'd300 && beam_tri>{1'b0,dith}+5'd4+{2'b0,y[8:6]};
reg fx_bit;
always @* case(season1) 2'd0:fx_bit=glint_h[4:0]==5'd3; 2'd1:fx_bit=strike; 2'd2:fx_bit=fog; default:fx_bit=beam; endcase
// neon pulse candidates; the material's ROM flags choose one in stage 2
wire breathe=dith<{tri4(t[9:6]),1'b0};
wire [7:0] flicker_h=hash8({t[14:7],8'd0}^{3'd0,y[8:4],4'd0}^{6'd0,x[9:4]}^16'h3300);
wire flick=flicker_h[2:0]==3'd0 && t[1];
wire flick_off=flicker_h[3:0]==4'd8 && t[3:2]==2'd0;
wire [3:0] chase_u=x[3:0]+y[3:0]+t[5:2];
wire chase=chase_u>=4'd10;
wire [5:0] holo_u=y[5:0]-t[6:1];
wire holo=holo_u>=6'd6 && y[0];
// ---- Stage 1 composition: material code, back to front ----
reg [7:0] code;
always @* begin
 code={4'h9,band};                                            // 144+band
 if(star)code=(star_h[1]^t[4]^x[0]) ? 8'd161 : 8'd162;
 if(streak)code=far_h[2] ? 8'd167 : 8'd166;
 if(halo)code=8'd165;
 if(disc)code=(crater || (shaded && !summer)) ? 8'd164 : 8'd163;
 if(cloud)code=distant_flash ? 8'd174 : cloud_depth<9'd2 ? 8'd170 : cloud_under ? 8'd171 :
               dith<cloud_shade ? 8'd169 : 8'd168;
 if(bolt)code=bolt_d==10'd7 ? 8'd172 : 8'd173;
 if(static_code>=8'd3)code=static_code;
 if(static_code==8'd1 || static_code==8'd2)code=window_code;
 if(traffic_shown)code=train_roof||train_body ? train_code : traffic_code;
 if(det_strip1 && det_front)code=det_strip_code1;
 if(det_hi1)code=det_hi_code1;
 if(pa && !roof && !person)code=pa_code;
 if(person)code=char_pix!=4'd0 ? {4'hc,char_pix} : cloth ? 8'd197 : 8'd194;
 if(vapor)code=8'd190;
 if(pb)code=pb_code;
 if(splash)code=8'd191;
 if(!body1)code=8'd192;
end
// ---- Stage 2: seasonal material record + pulse/rain arithmetic ----
assign season_addr={season1,fx_bit && body1,code};
reg hs2,vs2,de2,pic2,en2,fr2,nr2,breathe2,flick2,off2,chase2,holo2;
reg [23:0] rgb2;
always @(posedge clk or posedge reset)
 if(reset)begin hs2<=0;vs2<=0;de2<=0;pic2<=0;en2<=0;fr2<=0;nr2<=0;breathe2<=0;flick2<=0;off2<=0;chase2<=0;holo2<=0;rgb2<=0;end
 else begin hs2<=hs1;vs2<=vs1;de2<=de1;pic2<=pic1;en2<=en1;rgb2<=rgb1;
  fr2<=far_rain && body1;nr2<=near_rain && body1;
  breathe2<=breathe;flick2<=flick;off2<=flick_off;chase2<=chase;holo2<=holo;end
wire [7:0] flags=season_hi[15:8];
wire [23:0] base={season_hi[7:0],season_lo};
wire dim=(flags[1:0]==2'd1 && breathe2) || (flags[1:0]==2'd2 && flick2) || (flags[1:0]==2'd3 && chase2) || (flags[2] && holo2);
wire dark=flags[1:0]==2'd2 && off2;
function [7:0] light_channel;
 input [7:0] c;input f,n,d,k;
 reg [8:0] v;
 begin v=k ? {3'd0,c[7:2]} : d ? {1'b0,c[7:1]}+{2'b0,c[7:2]} : {1'b0,c};
  if(f)v={1'b0,v[8:1]}+{2'b0,v[8:2]}+9'd28;
  if(n)v={1'b0,v[8:1]}+9'd72;
  light_channel=v[7:0];end   // max 255 / 218 / 199: never wraps
endfunction
always @(posedge clk or posedge reset)begin
 if(reset)begin out_hs<=0;out_vs<=0;out_de<=0;out_picture<=0;out_rgb<=0;scene_active<=0;end
 else begin out_hs<=hs2;out_vs<=vs2;out_de<=de2;scene_active<=en2;
 out_picture<=en2 ? de2 : pic2;
 out_rgb<=!de2 ? 24'd0 : !en2 ? rgb2 :
  {light_channel(base[23:16],fr2,nr2,dim,dark),light_channel(base[15:8],fr2,nr2,dim,dark),light_channel(base[7:0],fr2,nr2,dim,dark)};
 end
end
