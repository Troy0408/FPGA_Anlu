# Diagnostic replacement for official lab_ex5_i2s timing.sdc.
# Preserve timing checks between related PLL clocks, including HDMI pixel/5x
# and SDRAM controller/shifted clocks. This is not a released player constraint.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name sd_card_clk -source [get_ports {clk}] -master_clock clk [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name ext_mem_clk -source [get_ports {clk}] -master_clock clk [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name sdram_clk -source [get_ports {clk}] -master_clock clk [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
rename_clock -name video_clk -source [get_ports {clk}] -master_clock clk [get_pins {video_pll_m0/pll_inst.clkc[0]}]
# MUSIC.WAV now feeds PCM in video_clk; the unused audio clock output and
# I2S sampling boundary no longer exist. Keep all remaining related PLL clock
# checks, including SD/FIFO/video. No false paths or multicycle exceptions.
# R03 scoped CDC intent (interface section 49; reviewed by independent Codex):
# read_req is HELD until ACK and traverses d0/d1/d2; bank[0] is held before
# that subsequent request and through S_ACK/presentation. Only the FIRST
# capture inputs may resolve on a later mem clock. Keep a finite 20ns data
# bound (<25ns mem period) and d0->d1/d2 setup/hold checks. TD's datapath_only
# also creates HOLD false paths ONLY at these two first inputs; these are
# metastability-allowed sampling entries, not destination resolution stages.
# The native ignored/exception reports must prove that exact scope.
# Do not replace these exact endpoints with clock groups or wildcards: TD
# wildcard name correlation also returns source aliases. The build audits
# canonical names, exception endpoints and downstream resolution paths.
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {frame_read_write_m0/frame_fifo_read_m0/read_req_d0 frame_read_write_m0/frame_fifo_read_m0/read_addr_index_d0[0]}] -datapath_only 20.0
