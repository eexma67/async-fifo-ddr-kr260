## =============================================================================
## kr260_pins.xdc - Pin Constraints for KR260 (Placeholder)
## 
## NOTE: This is a placeholder. Actual pin assignments depend on your
## block design and board connections. The DDR4 pins are handled by the
## MIG IP core automatically.
## =============================================================================

## System Clock (200 MHz from PS)
## The KR260 uses PS-generated clocks routed to PL via EMIO
## No need for explicit clock pin constraints when using PS clocks

## General timing constraints
create_clock -period 5.000 -name axi_clk [get_pins -hierarchical -filter {NAME =~ */clk_out1}]

## False paths for CDC synchronizers
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *sync_reg[0]*}]

## FIFO Gray-code pointer CDC
set_max_delay -datapath_only 5.0 -from [get_cells -hierarchical -filter {NAME =~ *wr_ptr_gray_reg*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *u_wr_ptr_sync/sync_reg[0]*}]
set_max_delay -datapath_only 5.0 -from [get_cells -hierarchical -filter {NAME =~ *rd_ptr_gray_reg*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *u_rd_ptr_sync/sync_reg[0]*}]
