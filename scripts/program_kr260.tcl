# =============================================================================
# program_kr260.tcl - Program KR260 board via JTAG
# Usage: vivado -mode batch -source program_kr260.tcl -tclargs <bitstream> <target_ip>
# =============================================================================

set bitstream  [lindex $argv 0]
set target_ip  [lindex $argv 1]

puts "============================================"
puts "  Programming KR260"
puts "  Bitstream: ${bitstream}"
puts "  Target:    ${target_ip}"
puts "============================================"

# Connect to hardware server
if {$target_ip eq "localhost" || $target_ip eq "127.0.0.1"} {
    open_hw_manager
    connect_hw_server
} else {
    open_hw_manager
    connect_hw_server -url ${target_ip}:3121
}

# Find KR260 target
set hw_targets [get_hw_targets]
if {[llength $hw_targets] == 0} {
    puts "ERROR: No hardware targets found!"
    close_hw_manager
    exit 1
}

open_hw_target [lindex $hw_targets 0]

# Find the device (Kria K26 = xczu5ev equivalent)
set hw_devices [get_hw_devices]
puts "Found devices: ${hw_devices}"

set target_device ""
foreach dev $hw_devices {
    set dev_name [get_property NAME $dev]
    if {[string match "*xck26*" $dev_name] || [string match "*xczu*" $dev_name]} {
        set target_device $dev
        break
    }
}

if {$target_device eq ""} {
    puts "ERROR: KR260 device not found! Available: ${hw_devices}"
    close_hw_target
    close_hw_manager
    exit 1
}

current_hw_device $target_device

# Program the device
puts "Programming device: [get_property NAME $target_device]"
set_property PROGRAM.FILE ${bitstream} $target_device

# Verify bitstream exists
if {![file exists $bitstream]} {
    puts "ERROR: Bitstream file not found: ${bitstream}"
    close_hw_target
    close_hw_manager
    exit 1
}

program_hw_devices $target_device

# Verify programming
puts "Verifying programming..."
after 2000  ;# Wait for PL to configure

set done_status [get_property REGISTER.IR.BIT5_DONE $target_device]
if {$done_status != 1} {
    puts "WARNING: DONE pin not asserted - programming may have failed"
}

puts "Programming complete!"

# Clean up
close_hw_target
close_hw_manager
