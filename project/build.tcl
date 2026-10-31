if {[catch {
import_device eagle_s20.db -package EG4S20BG256
create_project probe ./ -family EG4 -device EG4S20BG256
open_project probe.al
add_files global_def.v
add_files top.v
add_files sd.v
add_files video.v
add_files ip.v
add_files reference/stream_scaler.v
add_files probe/hd720_frame_scanout.v
add_files probe/hd720_composite.v
add_files probe/hd720_pll.v
add_files hd720_reference.v
add_files sdr_as_ram.enc.v
add_files sdr_init_ref.enc.v
add_files sdr_wrrd.enc.v
add_files hdmi_1_4b_transmitter_core_wrapper.enc.v
add_files probe.sdc
add_files probe.adc
top_module top
close_project
open_project -single_run probe.al
elaborate -top top
read_adc probe.adc
optimize_rtl
read_sdc probe.sdc
read_sdc player720_candidate.sdc
read_sdc -ip rfifo_32_32_512 afifo_32_16_256.tcl
read_sdc -ip wfifo_32_32_512 afifo_16_32_256.tcl
set scoped_0 [get_regs {u_composite/pixels/wg_meta[0] u_composite/pixels/wg_meta[1] u_composite/pixels/wg_meta[2] u_pcm_bridge/request_sync[0] u_composite/overflow_sync[0]}]
if {[llength $scoped_0] != 5} {error "720p exact CDC group0 count changed"}
puts "PLAYER720_SCOPE_0 $scoped_0"
set scoped_1 [get_regs {u_composite/pixels/rg_meta[0] u_composite/pixels/rg_meta[1] u_composite/pixels/rg_meta[2] u_pcm_bridge/acknowledge_sync[0] video_timing_data_m0/frame_sync[0] video_timing_data_m0/free_meta[0] video_timing_data_m0/free_meta[1] u_presentation/visible_sync[0] u_scene_control/visible_sync[0]}]
if {[llength $scoped_1] != 9} {error "720p exact CDC group1 count changed"}
puts "PLAYER720_SCOPE_1 $scoped_1"
set scoped_2 [get_regs {video_timing_data_m0/enable_sync[0] u_composite/enable_sync[0]}]
if {[llength $scoped_2] != 2} {error "720p exact CDC group2 count changed"}
puts "PLAYER720_SCOPE_2 $scoped_2"
set scoped_3 [get_regs {video_timing_data_m0/enable_sync[0]}]
if {[llength $scoped_3] != 1} {error "720p exact CDC group3 count changed"}
puts "PLAYER720_SCOPE_3 $scoped_3"
set scoped_4 [get_regs {u_pcm_bridge/audio_left[0] u_pcm_bridge/audio_right[0] u_pcm_bridge/audio_left[1] u_pcm_bridge/audio_right[1] u_pcm_bridge/audio_left[2] u_pcm_bridge/audio_right[2] u_pcm_bridge/audio_left[3] u_pcm_bridge/audio_right[3] u_pcm_bridge/audio_left[4] u_pcm_bridge/audio_right[4] u_pcm_bridge/audio_left[5] u_pcm_bridge/audio_right[5] u_pcm_bridge/audio_left[6] u_pcm_bridge/audio_right[6] u_pcm_bridge/audio_left[7] u_pcm_bridge/audio_right[7] u_pcm_bridge/audio_left[8] u_pcm_bridge/audio_right[8] u_pcm_bridge/audio_left[9] u_pcm_bridge/audio_right[9] u_pcm_bridge/audio_left[10] u_pcm_bridge/audio_right[10] u_pcm_bridge/audio_left[11] u_pcm_bridge/audio_right[11] u_pcm_bridge/audio_left[12] u_pcm_bridge/audio_right[12] u_pcm_bridge/audio_left[13] u_pcm_bridge/audio_right[13] u_pcm_bridge/audio_left[14] u_pcm_bridge/audio_right[14] u_pcm_bridge/audio_left[15] u_pcm_bridge/audio_right[15] u_pcm_bridge/audio_left[16] u_pcm_bridge/audio_right[16] u_pcm_bridge/audio_left[17] u_pcm_bridge/audio_right[17] u_pcm_bridge/audio_left[18] u_pcm_bridge/audio_right[18] u_pcm_bridge/audio_left[19] u_pcm_bridge/audio_right[19] u_pcm_bridge/audio_left[20] u_pcm_bridge/audio_right[20] u_pcm_bridge/audio_left[21] u_pcm_bridge/audio_right[21] u_pcm_bridge/audio_left[22] u_pcm_bridge/audio_right[22] u_pcm_bridge/audio_left[23] u_pcm_bridge/audio_right[23]}]
if {[llength $scoped_4] != 48} {error "720p exact CDC group4 count changed"}
puts "PLAYER720_SCOPE_4 $scoped_4"
set scoped_5 [get_pins {u_composite/row0/storage.dia[0] u_composite/row0/storage.dia[1] u_composite/row0/storage.dia[2] u_composite/row0/storage.dia[3] u_composite/row0/storage.dia[4] u_composite/row0/storage.dia[5] u_composite/row0/storage.dia[6] u_composite/row0/storage.dia[7] u_composite/row0/storage.dia[8] u_composite/row0/storage.dia[9] u_composite/row0/storage.dia[10] u_composite/row0/storage.dia[11] u_composite/row0/storage.dia[12] u_composite/row0/storage.dia[13] u_composite/row0/storage.dia[14] u_composite/row0/storage.dia[15] u_composite/row0/storage.dib[0] u_composite/row0/storage.dib[1] u_composite/row0/storage.dib[2] u_composite/row0/storage.dib[3] u_composite/row0/storage.dib[4] u_composite/row0/storage.dib[5] u_composite/row0/storage.dib[6] u_composite/row0/storage.dib[7] u_composite/row0/storage.dib[8] u_composite/row1/storage.dia[0] u_composite/row1/storage.dia[1] u_composite/row1/storage.dia[2] u_composite/row1/storage.dia[3] u_composite/row1/storage.dia[4] u_composite/row1/storage.dia[5] u_composite/row1/storage.dia[6] u_composite/row1/storage.dia[7] u_composite/row1/storage.dia[8] u_composite/row1/storage.dia[9] u_composite/row1/storage.dia[10] u_composite/row1/storage.dia[11] u_composite/row1/storage.dia[12] u_composite/row1/storage.dia[13] u_composite/row1/storage.dia[14] u_composite/row1/storage.dia[15] u_composite/row1/storage.dib[0] u_composite/row1/storage.dib[1] u_composite/row1/storage.dib[2] u_composite/row1/storage.dib[3] u_composite/row1/storage.dib[4] u_composite/row1/storage.dib[5] u_composite/row1/storage.dib[6] u_composite/row1/storage.dib[7] u_composite/row1/storage.dib[8]}]
if {[llength $scoped_5] != 50} {error "720p exact CDC group5 count changed"}
puts "PLAYER720_SCOPE_5 $scoped_5"
set scoped_6 [get_regs {u_title_bridge/req_sync[0]}]
if {[llength $scoped_6] != 1} {error "720p exact CDC group6 count changed"}
puts "PLAYER720_SCOPE_6 $scoped_6"
set scoped_7 [get_regs {u_title_bridge/ack_sync[0]}]
if {[llength $scoped_7] != 1} {error "720p exact CDC group7 count changed"}
puts "PLAYER720_SCOPE_7 $scoped_7"
set scoped_8 [get_regs {u_title_bridge/title_address[0] u_title_bridge/title_address[1] u_title_bridge/title_address[2] u_title_bridge/title_address[3] u_title_bridge/title_address[4] u_title_bridge/title_address[5] u_title_bridge/title_address[6] u_title_bridge/title_address[7] u_title_bridge/title_data[0] u_title_bridge/title_data[1] u_title_bridge/title_data[2] u_title_bridge/title_data[3] u_title_bridge/title_data[4] u_title_bridge/title_data[5] u_title_bridge/title_data[6]}]
if {[llength $scoped_8] != 15} {error "720p exact CDC group8 count changed"}
puts "PLAYER720_SCOPE_8 $scoped_8"
set scoped_9 [get_regs {u_composite/frame_bad}]
if {[llength $scoped_9] != 1} {error "720p exact CDC group9 count changed"}
puts "PLAYER720_SCOPE_9 $scoped_9"
set scoped_10 [get_regs {u_composite/active_frame_tag[0] u_composite/active_frame_tag[1] u_composite/active_frame_tag[2] u_composite/active_frame_tag[3] u_composite/active_frame_tag[4] u_composite/active_frame_tag[5] u_composite/active_frame_tag[6] u_composite/active_frame_tag[7] u_composite/active_frame_tag[8] u_composite/active_frame_tag[9] u_composite/active_frame_tag[10] u_composite/active_frame_tag[11] u_composite/active_frame_tag[12] u_composite/active_frame_tag[13] u_composite/active_frame_tag[14] u_composite/active_frame_tag[15] u_composite/active_frame_tag[16] u_composite/active_frame_tag[17] u_composite/active_frame_tag[18] u_composite/active_frame_tag[19] u_composite/active_frame_tag[20] u_composite/active_frame_tag[21] u_composite/active_frame_tag[22] u_composite/active_frame_tag[23] u_composite/active_frame_tag[24] u_composite/active_frame_tag[25] u_composite/active_frame_tag[26] u_composite/active_frame_tag[27] u_composite/active_frame_tag[28] u_composite/active_frame_tag[29] u_composite/active_frame_tag[30] u_composite/active_frame_tag[31]}]
if {[llength $scoped_10] != 32} {error "720p exact CDC group10 count changed"}
puts "PLAYER720_SCOPE_10 $scoped_10"
set scoped_11 [get_regs {u_scene_present_tag/start_sync[0]}]
if {[llength $scoped_11] != 1} {error "720p exact CDC group11 count changed"}
puts "PLAYER720_SCOPE_11 $scoped_11"
set scoped_12 [get_regs {u_scene_present_tag/captured_start_tag[0] u_scene_present_tag/captured_start_tag[1] u_scene_present_tag/captured_start_tag[2] u_scene_present_tag/captured_start_tag[3] u_scene_present_tag/captured_start_tag[4] u_scene_present_tag/captured_start_tag[5] u_scene_present_tag/captured_start_tag[6] u_scene_present_tag/captured_start_tag[7] u_scene_present_tag/captured_start_tag[8] u_scene_present_tag/captured_start_tag[9] u_scene_present_tag/captured_start_tag[10] u_scene_present_tag/captured_start_tag[11] u_scene_present_tag/captured_start_tag[12] u_scene_present_tag/captured_start_tag[13] u_scene_present_tag/captured_start_tag[14] u_scene_present_tag/captured_start_tag[15] u_scene_present_tag/captured_start_tag[16] u_scene_present_tag/captured_start_tag[17] u_scene_present_tag/captured_start_tag[18] u_scene_present_tag/captured_start_tag[19] u_scene_present_tag/captured_start_tag[20] u_scene_present_tag/captured_start_tag[21] u_scene_present_tag/captured_start_tag[22] u_scene_present_tag/captured_start_tag[23] u_scene_present_tag/captured_start_tag[24] u_scene_present_tag/captured_start_tag[25] u_scene_present_tag/captured_start_tag[26] u_scene_present_tag/captured_start_tag[27] u_scene_present_tag/captured_start_tag[28] u_scene_present_tag/captured_start_tag[29] u_scene_present_tag/captured_start_tag[30] u_scene_present_tag/captured_start_tag[31]}]
if {[llength $scoped_12] != 32} {error "720p exact CDC group12 count changed"}
puts "PLAYER720_SCOPE_12 $scoped_12"
set scoped_13 [get_regs {frame_read_write_m0/frame_fifo_read_m0/read_addr_index_d0[1] frame_read_write_m0/frame_fifo_read_m0/read_addr_index_d0[2]}]
if {[llength $scoped_13] != 2} {error "720p exact CDC group13 count changed"}
puts "PLAYER720_SCOPE_13 $scoped_13"
set_param gate opt_area high
set_param gate pack_effort high
optimize_gate
write_verilog probe_gate.v
report_area -io_info -file probe_gate.area
set_param place effort high
set_param place seed 3
set_param route effort routability
legalize_phy_inst
place
route
fix_hold
puts PHYSICAL_HOLD_REPAIR_DONE
update_timing -mode final
report_area -io_info -file probe.area
report_timing_status -file probe.ts
report_timing_summary -file probe.timing
report_route_status -drc
report_timing_exception -file probe.exceptions
report_timing_ignored -file probe.ignored
write_verilog probe_route.v
export_db probe_route.db
close_project
puts DISPLAY_RESOURCE_DONE
} reason]} {puts stderr "DISPLAY_RESOURCE_FAILED: $reason";exit 1}
exit 0
