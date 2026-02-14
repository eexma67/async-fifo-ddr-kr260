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

# ---- Synthesis ----
puts ">>> Running Synthesis..."
set synth_start [clock seconds]

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

# ---- Implementation ----
puts ">>> Running Implementation..."
set impl_start [clock seconds]

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set impl_end [clock seconds]
puts "Implementation completed in [expr {$impl_end - $impl_start}] seconds"

# Check implementation status
if {[get_property STATUS [get_runs impl_1]] != "write_bitstream Complete!"} {
    puts "ERROR: Implementation failed!"
    exit 1
}

# ---- Post-Implementation Reports ----
open_run impl_1

report_utilization -file ${project_name}_impl_util.rpt
report_timing_summary -max_paths 20 -file ${project_name}_impl_timing.rpt
report_power -file ${project_name}_power.rpt
report_drc -file ${project_name}_drc.rpt
report_methodology -file ${project_name}_methodology.rpt

# ---- Check Timing ----
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]

puts "============================================"
puts "  TIMING SUMMARY"
puts "  WNS: ${wns} ns"
puts "  TNS: ${tns} ns"
puts "============================================"

if {$wns < 0} {
    puts "WARNING: Timing not met! WNS = ${wns} ns"
    # Don't fail - let Jenkins decide based on threshold
}

puts "Build complete. Bitstream: ./${project_name}/${project_name}.runs/impl_1/${project_name}_top.bit"
close_project
