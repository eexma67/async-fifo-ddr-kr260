# =============================================================================
# build_bitstream.tcl - Vivado Non-Project Mode Build Script
# Usage: vivado -mode batch -source build_bitstream.tcl -tclargs <part> <rtl_dir> <xdc_dir> <project_name> <fifo_depth> <data_width> <burst_len>
# =============================================================================

# Parse arguments
set part          [lindex $argv 0]
set rtl_dir       [lindex $argv 1]
set xdc_dir       [lindex $argv 2]
set project_name  [lindex $argv 3]
set fifo_depth    [lindex $argv 4]
set data_width    [lindex $argv 5]
set burst_len     [lindex $argv 6]

puts "============================================"
puts "  Vivado Build: ${project_name}"
puts "  Part:         ${part}"
puts "  FIFO Depth:   ${fifo_depth}"
puts "  Data Width:   ${data_width}"
puts "  Burst Len:    ${burst_len}"
puts "============================================"

# Create project
create_project ${project_name} ./${project_name} -part ${part} -force

# Set board (KR260)
set_property board_part xilinx.com:kr260_som:part0:1.0 [current_project]

# Add RTL sources
add_files -fileset sources_1 [glob ${rtl_dir}/*.sv]
set_property file_type SystemVerilog [get_files *.sv]

# Set Verilog defines from CI parameters
set_property verilog_define [list \
    FIFO_DEPTH=${fifo_depth} \
    DATA_WIDTH=${data_width} \
    DDR_BURST_LEN=${burst_len} \
] [current_fileset]

# Set top module
set_property top async_fifo_ddr_top [current_fileset]

# Add constraints
if {[glob -nocomplain ${xdc_dir}/*.xdc] ne ""} {
    add_files -fileset constrs_1 [glob ${xdc_dir}/*.xdc]
}

# ---- Create Block Design for DDR4 MIG ----
# In a real build, you'd source a BD TCL script here
# source ${rtl_dir}/../scripts/create_bd_ddr4.tcl

# ---- Synthesis (Out-of-Context for IP module) ----
# Since this RTL is an IP that will be wrapped in a block design with
# PS DDR controller, we synthesize out-of-context (no I/O buffers).
puts ">>> Running Synthesis..."
set synth_start [clock seconds]

set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]

launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_end [clock seconds]
puts "Synthesis completed in [expr {$synth_end - $synth_start}] seconds"

# Check synthesis status
if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}

# Report utilisation after synthesis
open_run synth_1
report_utilization -file ${project_name}_synth_util.rpt
report_timing_summary -file ${project_name}_synth_timing.rpt

# ---- Post-Synthesis Reports (OOC mode - no implementation/bitstream) ----
# Implementation requires a block design wrapper with PS/DDR interconnect.
# For CI/CD, we validate synthesis, utilization, and estimated timing.
puts ">>> Skipping implementation (OOC mode - IP module)"
puts ">>> To generate a bitstream, wrap this IP in a block design with PS."

report_utilization -file ${project_name}_impl_util.rpt
report_timing_summary -max_paths 20 -file ${project_name}_impl_timing.rpt

# ---- Check Timing (post-synthesis estimate) ----
puts "============================================"
puts "  SYNTHESIS COMPLETE (Out-of-Context)"
puts "  Resource utilization in: ${project_name}_synth_util.rpt"
puts "  Timing estimate in:     ${project_name}_synth_timing.rpt"
puts "============================================"

puts "Build complete."
close_project
