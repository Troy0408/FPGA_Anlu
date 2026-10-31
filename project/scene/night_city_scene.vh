// R11 Night City: same rooftop city, four seasons, live weather/light/traffic.
// Static city = 8x8 tiles of 4-bit slots -> 8-bit material codes (BRAM, built
// offline by tools/night_art.py from team art in the composition of the user's
// ChatGPT HTML). Seasonal colours = one ROM record per {season,fx,code}.
// Sky, clouds, sun/moon, stars, windows, traffic, rain/snow/leaves/fog/beams,
// lightning, neon pulses and character breathing/cloth are computed per pixel
// from the frame counter. No frame buffer, no stored animation frames.
// 3 clocks, one pixel/clock; tilemap/tileset/palette reads are prefetched two
// and one pixel ahead so the 4-BRAM chain keeps the original latency.
// Bit-exact development model: tools/night_city_model.py.
module night_city_scene #(parameter [15:0] FRAME_START=16'd0,
 parameter integer ENABLE_SEASONS=0,parameter integer SCENE_TOP=60)(
 input wire clk,rst,enable,in_hs,in_vs,in_de,in_picture,
 // R12: final PCM (same clk) for the street screen's live loudness bars.
 input wire audio_valid,
 input wire [23:0] audio_left,audio_right,
 input wire [1:0] scene_select,
 input wire [23:0] in_rgb,
 output reg out_hs,out_vs,out_de,out_picture,
 output reg [23:0] out_rgb, output reg scene_active
);
wire [7:0] subtitle_glyph=0;
wire [3:0] subtitle_row=0;
wire [15:0] subtitle_font_q,subtitle_font_hi_q;
`include "scene/night_city_body.vh"
endmodule

module night_city_scene_cn #(parameter [15:0] FRAME_START=16'd0,
 parameter integer ENABLE_SEASONS=0,parameter integer SCENE_TOP=60)(
 input wire clk,rst,enable,in_hs,in_vs,in_de,in_picture,
 // R12: final PCM (same clk) for the street screen's live loudness bars.
 input wire audio_valid,
 input wire [23:0] audio_left,audio_right,
 input wire [1:0] scene_select,
 input wire [23:0] in_rgb,
 // Two font ROMs reuse blocks freed by lossless scene tile packing. The
 // font address and output are synchronous to the scene's video clock.
 input wire [7:0] subtitle_glyph,
 input wire [3:0] subtitle_row,
 output wire [15:0] subtitle_font_q, subtitle_font_hi_q,
 output reg out_hs,out_vs,out_de,out_picture,
 output reg [23:0] out_rgb, output reg scene_active
);
`include "scene/night_city_body.vh"
endmodule
