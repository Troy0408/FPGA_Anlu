`default_nettype none
// Contest example 4/5 reuse. Original ownership and comments are retained.
// Source boundaries and modifications: project/ip/sources.json.


// ===== Official source: top_tf_hdmi_audio.v =====

module top(
    input wire clk,
    input wire rst_n,
    input wire key1,           // Physical KEY2: menu enter/back
    input wire key3,           // Physical KEY3: next/increase
    input wire key2,           // Physical KEY4: previous/decrease
    input wire [2:0]                sw,             // SW1 auto; SW2 menu; SW3 scene

    output wire [5:0]                seg_sel,
    output wire [7:0]                seg_data,

    // HDMI TMDS
    output wire HDMI_CLK_P,
    output wire HDMI_D2_P,
    output wire HDMI_D1_P,
    output wire HDMI_D0_P,

    // HDMI DDC
    output wire HDMI_DDC_SCL,
    inout wire HDMI_DDC_SDA,

    // TF card SPI
    output wire sd_ncs,
    output wire sd_dclk,
    output wire sd_mosi,
    input wire sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd230400;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire managed_refresh_req,managed_refresh_fault;
// 720p integration candidate: source25MHz, output74.25/371.25MHz.
wire output_clk,output_raw,ref_raw,reference27,ref_lock,out_lock;
wire unused_ref_feedback,unused_out_feedback;
wire [1:0] row_free;
wire output_frame_toggle,visible_frame_toggle,render_late,scan_underrun,pixel_overflow;
wire tx_locked;
wire title_ready,title_we;wire [7:0] title_address;wire [6:0] title_data;
wire output_audio_valid,audio_overflow;
wire storage_empty,storage_valid,storage_fault;
wire [23:0] output_left,output_right;
reg [2:0] output_reset_sync,serial_reset_sync;
wire output_reset=output_reset_sync[2],serial_reset=serial_reset_sync[2];

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire ext_mem_clk_sft_raw;
EG_LOGIC_BUFG sdram_shift_bufg (.i(ext_mem_clk_sft_raw), .o(ext_mem_clk_sft));
wire video_clk;
wire hdmi_5x_clk;
wire rst_all;

wire hs;
wire vs;
wire de;

wire [24:0] vout_bundle;
wire [23:0] vout_data_raw = vout_bundle[24:1];
wire sd_card_write_ready;
wire [23:0] vout_data;
wire [23:0] scene_data;
wire scene_hs,scene_vs,scene_de,scene_picture;
wire [23:0] adjusted_data;
wire adjusted_hs, adjusted_vs, adjusted_de;
wire [23:0] rhythm_data;
wire rhythm_hs,rhythm_vs,rhythm_de;
wire music_valid,music_ready,music_urgent;
wire [31:0] music_sample,music_underruns;
wire [3:0] music_status;
wire music_flush,music_flush_ack;
wire tracks_ready_sd,tracks_ready_pixel,track_select_toggle,track_select_ack;
wire [4:0] track_mask_sd,track_mask_pixel;
wire [1239:0] track_titles;
wire [2:0] active_track_sd,active_track_pixel,track_select_index;
wire [3:0] track_status_pixel;
wire [247:0] selected_title;
wire [2:0] track_index_menu;
wire track_title_valid;wire [7:0] track_title_address;wire [6:0] track_title_data;
wire tracks_ready_menu;wire [4:0] track_mask_menu;wire [3:0] track_status_menu;
wire auto_enable;
wire menu_open,menu_edit,subtitle_enable,visual_enable,scene_enable,scene_active;
wire scene_step,scene_previous,scene_mode_active,scene_full_frame;
wire [1:0] scene_index;
wire [7:0] subtitle_glyph;
wire [3:0] subtitle_row;
wire [15:0] subtitle_font_q,subtitle_font_hi_q;
wire scene_hold,static_loader_allowed;
wire [31:0] scene_source_tag,output_scene_start_tag;
wire output_scene_start_toggle,scene_render_start,scene_present_start;
wire static_mode=!scene_hold && !scene_mode_active && !scene_active;
wire [2:0] menu_item;
wire [3:0] brightness_level,volume_level,contrast_level;
wire [1:0] period_select;
wire nav_toggle,nav_previous,nav_ack_toggle,nav_idle;
wire menu_picture_toggle,menu_picture_ack,picture_select_toggle,picture_select_ack;
wire [2:0] menu_picture_index,picture_select_index,picture_candidate;
wire [2:0] current_picture_sd,picture_count_sd;
wire catalog_showcase_sd,catalog_ready_sd,catalog_tracks_sd;
reg [2:0] current_picture_pixel,picture_count_pixel;
reg catalog_showcase_pixel,catalog_ready_pixel,catalog_tracks_pixel;
wire picture_state_toggle,picture_idle;
reg picture_state_valid,picture_capture_pending,picture_state_seen;
(* async_reg="true" *) reg [2:0] picture_state_sync;
always @(posedge video_clk or posedge rst_all)begin
    if(rst_all)begin
        picture_state_sync<=0;picture_state_seen<=0;picture_capture_pending<=0;
        current_picture_pixel<=0;picture_count_pixel<=0;picture_state_valid<=0;
        catalog_showcase_pixel<=0;catalog_ready_pixel<=0;catalog_tracks_pixel<=0;
    end else begin
        picture_state_sync<={picture_state_sync[1:0],picture_state_toggle};
        if(picture_state_sync[2]!=picture_state_seen)begin
            picture_state_seen<=picture_state_sync[2];picture_capture_pending<=1;
        end else if(picture_capture_pending)begin
            current_picture_pixel<=current_picture_sd;picture_count_pixel<=picture_count_sd;
            catalog_showcase_pixel<=catalog_showcase_sd;catalog_ready_pixel<=catalog_ready_sd;catalog_tracks_pixel<=catalog_tracks_sd;
            picture_capture_pending<=0;picture_state_valid<=1;
        end
    end
end
wire menu_open_frame,menu_edit_frame,subtitle_frame,visual_frame;
wire [2:0] menu_item_frame;
wire [3:0] brightness_frame,volume_frame,contrast_frame;
wire [1:0] period_frame;

wire menu_hs,menu_vs,menu_de;
wire [23:0] menu_rgb;
wire text_done, text_we;
wire [3:0] text_status;
wire [7:0] text_addr, text_data;
wire [8:0] text_length;
wire        display_valid;
wire frame_ready_toggle,frame_presented_toggle;
wire [2:0] video_read_bank;
wire [5:0] image_gain;
wire [52:0] frame_metadata;
wire loader_busy,auto_toggle,auto_ack_toggle,full_frame_done;
wire [15:0] auto_sequence,source_width,source_height;
wire status_hs,status_vs,status_de;
wire [23:0] status_rgb;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [2:0]  write_buf_idx;
wire [2:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        source_audio_valid;
wire [23:0] source_audio_left,source_audio_right;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路
assign rst_all = ~rst_n | ~audio_pll_lock;

EG_LOGIC_BUFG output_buf(.i(output_raw),.o(output_clk));
EG_LOGIC_BUFG ref_buf(.i(ref_raw),.o(reference27));
hd720_ref27 reference_pll(.refclk(clk),.reset(1'b0),.extlock(ref_lock),
 .clk0_out(unused_ref_feedback),.clk1_out(ref_raw));
hd720_video_pll output_pll(.refclk(reference27),.reset(!ref_lock),.extlock(out_lock),
 .clk0_out(unused_out_feedback),.clk1_out(output_raw),.clk2_out(hdmi_5x_clk));
always @(posedge output_clk or posedge rst_all)
 if(rst_all)output_reset_sync<=7;else output_reset_sync<={output_reset_sync[1:0],1'b0};
always @(posedge hdmi_5x_clk or posedge rst_all)
 if(rst_all)serial_reset_sync<=7;else serial_reset_sync<={serial_reset_sync[1:0],1'b0};
assign audio_pll_lock=ref_lock && out_lock;
hd720_title_bridge u_title_bridge(.write_clk(sd_card_clk),.clk(video_clk),.rst(rst_all),
 .valid(track_title_valid),.address(track_title_address),.data(track_title_data),.ready(title_ready),
 .title_we(title_we),.title_address(title_address),.title_data(title_data));
hd720_source_integrity u_source_integrity(.clk(video_clk),.rst(rst_all),.vs(vs_0),
 .read_enable(video_read_en),.read_empty(storage_empty),.read_valid(storage_valid),
 .storage_required(!scene_active),.frame_fault(storage_fault));

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft_raw),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (),
    .reset      (1'b0)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
// The output PLL lock now supplies the common startup condition.

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (50_000_000),
    .CANVAS_WIDTH(640),.CANVAS_HEIGHT(360),.TITLE_STREAM(1),
    // Pictures and soundtrack come from the TF card root catalog (root_catalog.vh).
    .ENABLE_IMAGE_CACHE(1),
    .ENABLE_TEXT       (0),.SHOWCASE_TRACK_ORDER(1),
    .ENABLE_MUSIC      (1),
    .ENABLE_TRACKS     (1),
    .ENABLE_TRANSITION (1),
    .EXTERNAL_COMMANDS (1),
    .ENABLE_PICTURE_SELECT (1),
    .EXTERNAL_AUTOPLAY (1),
    .EXTERNAL_MODE_CONTROL (1),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd6)
) sd_card_bmp_m0(
    .background_hold(1'b0),.background_reload_req(1'b0),.background_idle(),.background_reload_ack(),
    .external_req(1'b0),.external_hold(1'b0),.external_ready(1'b0),.external_restart_toggle(1'b0),.external_name(88'd0),
    .external_grant(),.external_valid(),.external_last(),.external_done(),.external_data(),.external_size(),.external_error(),
    .external_idle(),.external_released(),.external_restart_ack(),
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (1'b1),
    .nav_toggle(nav_toggle),.nav_previous(nav_previous),.nav_ack_toggle(nav_ack_toggle),
    .picture_select_toggle(picture_select_toggle),.picture_select_index(picture_select_index),
    .picture_select_ack(picture_select_ack),.current_picture_index(current_picture_sd),
    .picture_count(picture_count_sd),.catalog_showcase(catalog_showcase_sd),.catalog_ready(catalog_ready_sd),.catalog_tracks(catalog_tracks_sd),
    .picture_state_toggle(picture_state_toggle),.picture_idle(picture_idle),
    .static_enable(static_loader_allowed),.auto_enable(auto_enable && static_mode),
    .auto_toggle(auto_toggle),.auto_sequence(auto_sequence),.auto_ack_toggle(auto_ack_toggle),
    .frame_metadata(frame_metadata),.loader_busy(loader_busy),
    .text_done(text_done), .text_status(text_status), .text_we(text_we),
    .text_addr(text_addr), .text_data(text_data), .text_length(text_length),
    .music_ready(music_ready),.music_urgent(music_urgent),.music_valid(music_valid),
    .music_sample(music_sample),.music_status(music_status),
    .music_flush(music_flush),.music_flush_ack(music_flush_ack),
    .track_select_toggle(track_select_toggle),.track_select_index(track_select_index),.track_select_ack(track_select_ack),
    .tracks_ready(tracks_ready_sd),.track_mask(track_mask_sd),.track_titles(track_titles),.active_track(active_track_sd),
    .track_title_valid(track_title_valid),.track_title_address(track_title_address),.track_title_data(track_title_data),.track_title_ready(title_ready),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd360),
    .display_valid     (),
    .frame_ready_toggle(frame_ready_toggle),
    .frame_presented_toggle(frame_presented_toggle),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_ready       (sd_card_write_ready),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
hd720_render_timing video_timing_data_m0(
 .clk(video_clk),.global_reset(rst_all),.enable(Sdr_init_done && tx_locked),.frame_toggle(output_frame_toggle),.row_free(row_free),
 .read_req(video_read_req),.read_req_ack(video_read_req_ack),.hs(hs_0),.vs(vs_0),.de(de_0),.late_frame(render_late));

video_delay #(.DATA_WIDTH(25)) video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         ({video_read_data[31:8],video_read_data[0]}),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_bundle)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid ? vout_data_raw : 24'd0;
// R06: two eleven-update fades; 336ms combined first-to-last intervals at
// 25MHz / 800x525. Loading and black/read handshake are separate intervals.
image_fade_transition #(.FADE_STEP(3),.BANK_INDEX_BITS(3)) u_transition(
    .clk(video_clk),.rst(rst_all),.in_vs(vs_0),.in_de(de_0),
    .ready_toggle(frame_ready_toggle),.ready_bank(disp_buf_idx),
    .read_req(video_read_req),.read_req_ack(video_read_req_ack),
    .presented_toggle(frame_presented_toggle),.read_bank(video_read_bank),
    .image_valid(display_valid),.gain(image_gain));

// Team E04: three matched RGB/HS/VS/DE pipeline stages; no frame buffer.
player_menu_control #(.ENABLE_TRACKS(1),.ENABLE_SCENE(1),.ENABLE_PICTURES(1),.SHOWCASE_TRACK_ORDER(1),.DEFAULT_SUBTITLE_ENABLE(0),.DEFAULT_VISUAL_ENABLE(0)) u_menu_control(.lock_media(1'b0),.force_scene_off(1'b0),
    .clk(video_clk),.rst(rst_all),.key_enter_n(key1),.key_next_n(key3),.key_prev_n(key2),
    .sw_auto(sw[0]),.sw_menu(sw[1]),.sw_scene(sw[2]),.nav_ack_toggle(nav_ack_toggle),.nav_hold(scene_hold),
    .current_picture_index(current_picture_pixel),.picture_count(picture_count_pixel),
    .catalog_showcase(catalog_showcase_pixel),.catalog_ready(catalog_ready_pixel),.catalog_tracks(catalog_tracks_pixel),
    .picture_select_toggle(menu_picture_toggle),.picture_select_index(menu_picture_index),
    .picture_select_ack(menu_picture_ack),.picture_candidate(picture_candidate),
    .tracks_ready(tracks_ready_pixel),.track_mask(track_mask_pixel),.active_track(active_track_pixel),
    .track_select_ack(track_select_ack),.track_select_toggle(track_select_toggle),.track_select_index(track_select_index),
    .auto_enable(auto_enable),.menu_open(menu_open),.menu_edit(menu_edit),.menu_item(menu_item),
    .brightness_level(brightness_level),.volume_level(volume_level),.contrast_level(contrast_level),
    .subtitle_enable(subtitle_enable),.visual_enable(visual_enable),.period_select(period_select),
    .nav_toggle(nav_toggle),.nav_previous(nav_previous),.nav_idle(nav_idle),.scene_enable(scene_enable),
    .scene_step(scene_step),.scene_previous(scene_previous));
player_scene_restore u_scene_restore(
    .clk(video_clk),.rst(rst_all),.scene_requested(scene_enable),
    .current_picture(current_picture_pixel),.picture_state_valid(picture_state_valid),.quiescent(picture_idle),.nav_idle(nav_idle),
    .menu_toggle(menu_picture_toggle),.menu_index(menu_picture_index),.menu_ack(menu_picture_ack),
    .loader_toggle(picture_select_toggle),.loader_index(picture_select_index),.loader_ack(picture_select_ack),
    .scene_hold(scene_hold),.static_allowed(static_loader_allowed));
player_menu_frame_state #(.DEFAULT_SUBTITLE_ENABLE(0),.DEFAULT_VISUAL_ENABLE(0)) u_menu_frame_state(
    .clk(video_clk),.rst(rst_all),.in_vs(vs_0),.in_de(de_0),
    .pending_settings({menu_open,menu_edit,menu_item,brightness_level,volume_level,contrast_level,subtitle_enable,visual_enable,period_select}),
    .frame_settings({menu_open_frame,menu_edit_frame,menu_item_frame,brightness_frame,volume_frame,contrast_frame,subtitle_frame,visual_frame,period_frame}));
// R10: four-season Night City replaces the frame-buffer picture before image
// adjustment, so brightness/contrast, subtitle, 64 bars, prompts and menu all
// composite above it. Fixed 3 clocks; the static loader keeps its own banks.
player_scene_control #(.PRESENT_DELAY(29),.ACTIVE_HEIGHT(360),.EXTERNAL_COMPLETION(1)) u_scene_control(.visible_frame_toggle(visible_frame_toggle),
    .clk(video_clk),.rst(rst_all),.enable(scene_hold),.auto_enable(auto_enable),.period_select(period_select),
    .manual_step(scene_step),.manual_previous(scene_previous),.in_vs(vs_0),.in_de(de_0),
    .scene_index(scene_index),.scene_active(scene_mode_active),.full_frame_done(scene_full_frame));
night_city_scene_cn #(.ENABLE_SEASONS(1),.SCENE_TOP(0)) u_scene(
    .clk(video_clk),.rst(rst_all),.enable(scene_mode_active),.scene_select(scene_index),
    .in_hs(hs),.in_vs(vs),.in_de(de),.in_picture(vout_bundle[0] && display_valid),.in_rgb(vout_data),
    // R12 street screen: same final PCM as the 64 bars (after volume/mute).
    .audio_valid(audio_valid),.audio_left(audio_left_data),.audio_right(audio_right_data),
    .subtitle_glyph(subtitle_glyph),.subtitle_row(subtitle_row),
    .subtitle_font_q(subtitle_font_q),.subtitle_font_hi_q(subtitle_font_hi_q),
    .out_hs(scene_hs),.out_vs(scene_vs),.out_de(scene_de),.out_picture(scene_picture),.out_rgb(scene_data),
    .scene_active(scene_active));
video_adjust_osd_cn #(.EXTERNAL_UI(1),.SUBTITLE_TOP(320),.SHOWCASE_CN(1)) u_adjust (
    .clk(video_clk), .rst(rst_all), .key_dec_n(1'b1), .key_inc_n(1'b1),
    .ui_brightness(brightness_frame),.ui_contrast(contrast_frame),
    .switch_in(2'b00), .auto_enable(), .subtitle_switch(subtitle_frame),
    .text_clk(sd_card_clk), .text_we(text_we), .text_addr(text_addr), .text_data(text_data),
    .text_done(text_done), .text_status(text_status), .text_length(text_length),
    .subtitle_picture_bank(video_read_bank),.subtitle_scene(scene_active),
    .subtitle_catalog_ok(catalog_showcase_pixel && catalog_ready_pixel),
    .subtitle_glyph(subtitle_glyph),.subtitle_row(subtitle_row),
    .subtitle_font_q(subtitle_font_q),.subtitle_font_hi_q(subtitle_font_hi_q),
    .in_hs(scene_hs), .in_vs(scene_vs), .in_de(scene_de), .in_rgb(scene_data),.in_picture(scene_picture),
    .image_gain(scene_active ? 6'd32 : image_gain), // static fades never dim the scene
    .out_hs(adjusted_hs), .out_vs(adjusted_vs), .out_de(adjusted_de),
    .out_rgb(adjusted_data)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),.WAIT_SDR_IDLE(1),.BANK_INDEX_BITS(3),.EXTRA_BANK4_ADDR(21'd921600),.EXTRA_BANK5_ADDR(21'd1152000),
    .ENABLE_MANAGED_REFRESH(1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (360)
) frame_read_write_m0(
    .managed_refresh_req(managed_refresh_req),.managed_refresh_fault(managed_refresh_fault),.write_issue_observe(),.read_issue_observe(),.write_empty_observe(),.pause_observe(),
    .quiesce_req(1'b0),.quiesce_epoch(32'd0),.run_enable(1'b1),
    .write_fence_ack(),.read_fence_ack(),.write_fence_epoch(),.read_fence_epoch(),.fence_error(),
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd460800),
    .read_addr_3       (24'd691200),
    .read_addr_index   (video_read_bank),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),.read_empty(storage_empty),.read_valid(storage_valid),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd460800),
    .write_addr_3      (24'd691200),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_ready       (sd_card_write_ready),
    .write_data        (sd_card_write_data)
);

sdram #(.EXTERNAL_REFRESH(1)) U3(
    .App_ref_req(managed_refresh_req),
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// MUSIC.WAV stereo PCM -> proven vendor FIFO -> HDMI public PCM interface.
// Pixel-domain fractional tick removes the legacy I2S round trip. The original
// audio PLL remains solely for the already-used common startup lock condition.
music_pcm_output #(.ENABLE_FLUSH(1)) u_music_output(
    .flush_ack_read(),.flush_active_read(),.write_clk(sd_card_clk),.clk(video_clk),.rst(rst_all),
    .flush_req(music_flush),.flush_ack(music_flush_ack),
    .sample_valid(music_valid),.sample_ready(music_ready),.sample_data(music_sample),.urgent(music_urgent),
    .play_enable(1'b1),.buffer_ready(),.media_valid(),
    .audio_valid(source_audio_valid),.audio_left(source_audio_left),.audio_right(source_audio_right),.underruns(music_underruns));
player_track_status_bridge u_track_status(
    .write_clk(sd_card_clk),.clk(video_clk),.rst(rst_all),
    .tracks_ready(tracks_ready_sd),.available_mask(track_mask_sd),.active_index(active_track_sd),.status(music_status),
    .ready_pixel(tracks_ready_pixel),.mask_pixel(track_mask_pixel),.index_pixel(active_track_pixel),.status_pixel(track_status_pixel));
// Titles are immutable before ready and for the remainder of this reset epoch.
player_track_title_snapshot #(.CACHE_TITLE(0)) u_track_title(
    .clk(video_clk),.rst(rst_all),.tracks_ready(tracks_ready_pixel),.available_mask(track_mask_pixel),
    .active_index(active_track_pixel),.status(track_status_pixel),.titles(track_titles),
    .ready_out(tracks_ready_menu),.mask_out(track_mask_menu),.status_out(track_status_menu),.title_out(selected_title),.index_out(track_index_menu));
wire [23:0] volume_left,volume_right;
// Mute the complete volume pipeline while clearing the old source. Flush ACK
// is delayed at least64 pixel clocks, beyond the48-clock arithmetic latency.
player_track_pcm_mute u_track_mute(
    .clk(video_clk),.rst(rst_all),.flush_req(music_flush),.in_left(volume_left),.in_right(volume_right),
    .out_left(audio_left_data),.out_right(audio_right_data));
// One final PCM bundle for all media: shared gain, HDMI/ACR and real bars.
// Same video_clk domain; pending volume applies at the next sample boundary.
pcm_volume_slew u_pcm_volume(
    .clk(video_clk),.rst(rst_all),.volume_level(volume_level),
    .in_valid(source_audio_valid),.in_left(source_audio_left),.in_right(source_audio_right),
    .out_valid(audio_valid),.out_left(volume_left),.out_right(volume_right));
music_rhythm_overlay #(.PANEL_TOP(240),.BAR_BASE(304)) u_music_rhythm(
    .clk(video_clk),.rst(rst_all),.audio_valid(audio_valid),.enable(visual_frame),.audio_left(audio_left_data),.audio_right(audio_right_data),
    .in_hs(adjusted_hs),.in_vs(adjusted_vs),.in_de(adjusted_de),.in_rgb(adjusted_data),
    .out_hs(rhythm_hs),.out_vs(rhythm_vs),.out_de(rhythm_de),.out_rgb(rhythm_data));
// Completion is certified at the rhythm output: 21+3+3+2 matched raster clocks.
// Scene mode suspends static autoplay exactly like SW1 off (fresh dwell later).
player_presentation_control #(.CONTROL_DELAY(29),.MODE_AWARE(1),.ACTIVE_HEIGHT(360),.EXTERNAL_COMPLETION(1)) u_presentation(.visible_frame_toggle(visible_frame_toggle),
    .clk(video_clk),.rst(rst_all),.in_vs(rhythm_vs),.in_de(rhythm_de),
    .image_valid(display_valid),.image_gain(image_gain),.presented_toggle(frame_presented_toggle),
    .frame_ready_toggle(frame_ready_toggle),.frame_metadata(frame_metadata),.load_busy(loader_busy),
    .nav_toggle(nav_toggle),.static_mode(static_mode),.auto_enable(auto_enable && static_mode),.period_select(period_select),
    .auto_ack_toggle(auto_ack_toggle),.auto_toggle(auto_toggle),.auto_sequence(auto_sequence),
    .full_frame_done(full_frame_done),.source_width(source_width),.source_height(source_height));
player_scene_present_tag u_scene_present_tag(
    .clk(video_clk),.rst(rst_all),.source_vs(status_vs),.scene_active(scene_active),.scene_index(scene_index),
    .output_start_toggle(output_scene_start_toggle),.output_start_tag(output_scene_start_tag),
    .source_tag(scene_source_tag),.render_start(scene_render_start),.present_start(scene_present_start));
player_status_overlay u_status(
    .clk(video_clk),.rst(rst_all),.auto_enable(auto_enable),.size_event(full_frame_done && !scene_active),
    .scene_render_start(scene_render_start),.scene_present_start(scene_present_start),.scene_active(scene_active),.scene_index(scene_index),
    .source_width(source_width),.source_height(source_height),
    .in_hs(rhythm_hs),.in_vs(rhythm_vs),.in_de(rhythm_de),.in_rgb(rhythm_data),
    .out_hs(status_hs),.out_vs(status_vs),.out_de(status_de),.out_rgb(status_rgb),
    .auto_visible(),.size_visible());
player_menu_overlay #(.ENABLE_TRACKS(1),.ENABLE_SCENE(1),.ENABLE_PICTURES(1),.USE_FONT_ROM(1),.USE_RAM_TITLES(1),.COMPACT(1)) u_menu_overlay(.media_locked(1'b0),
    .clk(video_clk),.rst(rst_all),.scene_enable(scene_enable || scene_hold),.picture_index(picture_candidate),.menu_open(menu_open_frame),.menu_edit(menu_edit_frame),.menu_item(menu_item_frame),
    .brightness_level(brightness_frame),.volume_level(volume_frame),.contrast_level(contrast_frame),
    .subtitle_enable(subtitle_frame),.visual_enable(visual_frame),.period_select(period_frame),
    .tracks_ready(tracks_ready_menu),.track_mask(track_mask_menu),.track_status(track_status_menu),.track_title(selected_title),
    .catalog_showcase(catalog_showcase_pixel),.catalog_ready(catalog_ready_pixel),.catalog_tracks(catalog_tracks_pixel),
    .raw_titles(1240'd0),.raw_track_index(track_index_menu),
    .title_we(title_we),.title_address(title_address),.title_data(title_data),
    .in_hs(status_hs),.in_vs(status_vs),.in_de(status_de),.in_rgb(status_rgb),
    .out_hs(menu_hs),.out_vs(menu_vs),.out_de(menu_de),.out_rgb(menu_rgb));

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (output_clk),
    .I_rst         (output_reset),
    .I_audio_valid (output_audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
hd720_composite_scanout #(.FRAME_TAGGED(1)) u_composite(
 .source_clk(video_clk),.pixel_clk(output_clk),.rst(rst_all),.stream_enable(Sdr_init_done && tx_locked),
 .source_vs(menu_vs),.source_de(menu_de),.source_rgb(menu_rgb),.source_fault(storage_fault),.row_free(row_free),
 .source_frame_tag(scene_source_tag),.frame_done_tag(),
 .frame_start_toggle(output_scene_start_toggle),.frame_start_tag(output_scene_start_tag),
 .frame_toggle(output_frame_toggle),.axis_valid(axis_s_valid),.axis_user(axis_s_user),
 .axis_last(axis_s_last),.axis_data(axis_s_data),.axis_ready(axis_s_ready),
 .frame_done_toggle(visible_frame_toggle),.underrun(scan_underrun),.overflow(pixel_overflow));
hd720_pcm_bridge u_pcm_bridge(.source_clk(video_clk),.pixel_clk(output_clk),.rst(rst_all),
 .source_valid(audio_valid),.source_left(audio_left_data),.source_right(audio_right_data),
 .source_media_valid(1'b0),.source_epoch_start(1'b0),.source_epoch(32'd0),
 .media_valid(),.epoch_start(),.media_epoch(),
 .audio_valid(output_audio_valid),.audio_left(output_left),.audio_right(output_right),.overflow(audio_overflow));

// 上电后自动打一拍，触发一次 EDID 读取
reg [22:0] edid_count;
always @(posedge output_clk or posedge output_reset)
 if(output_reset)edid_count<=0;else if(edid_count<7425000)edid_count<=edid_count+1'b1;
assign edid_trig=edid_count==7424999;

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 1650        ),
    .HSA                    ( 40         ),
    .HFP                    ( 110         ),
    .HBP                    ( 220         ),
    .HACTIVE                ( 1280        ),
    .VTOTAL                 ( 750        ),
    .VSA                    ( 5          ),
    .VFP                    ( 5         ),
    .VBP                    ( 20         ),
    .VACTIVE                ( 720        ),
    .VIDEO_VIC              ( 4          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 743        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (output_clk),
    .I_rst              (output_reset),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (output_audio_valid),
    .I_audio_left_data  (output_left),
    .I_audio_right_data (output_right),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (tx_locked),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hd720_phy #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (output_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_pixel_rst        (output_reset),
    .I_rst              (serial_reset),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

`default_nettype wire
