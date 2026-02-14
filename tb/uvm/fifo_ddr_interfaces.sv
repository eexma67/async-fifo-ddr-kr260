// =============================================================================
// fifo_ddr_interfaces.sv - Virtual Interfaces for UVM Testbench
// =============================================================================

// ---- FIFO Write Interface ----
interface fifo_wr_if #(
    parameter int DATA_WIDTH = 64,
    parameter int ADDR_WIDTH = 10
)(
    input logic clk,
    input logic rst_n
);
    logic                    wr_en;
    logic [DATA_WIDTH-1:0]   wr_data;
    logic                    wr_full;
    logic [ADDR_WIDTH:0]     wr_count;

    clocking wr_cb @(posedge clk);
        default input #1 output #1;
        output  wr_en;
        output  wr_data;
        input   wr_full;
        input   wr_count;
    endclocking

    // Monitor clocking block - all signals are inputs for sampling
    clocking mon_cb @(posedge clk);
        default input #1;
        input wr_en;
        input wr_data;
        input wr_full;
        input wr_count;
    endclocking

    modport driver  (clocking wr_cb, input rst_n);
    modport monitor (clocking mon_cb, input rst_n, input wr_full);
endinterface


// ---- FIFO Read Interface ----
interface fifo_rd_if #(
    parameter int DATA_WIDTH = 64,
    parameter int ADDR_WIDTH = 10
)(
    input logic clk,
    input logic rst_n
);
    logic                    rd_en;
    logic [DATA_WIDTH-1:0]   rd_data;
    logic                    rd_empty;
    logic [ADDR_WIDTH:0]     rd_count;

    clocking rd_cb @(posedge clk);
        default input #1 output #1;
        output  rd_en;
        input   rd_data;
        input   rd_empty;
        input   rd_count;
    endclocking

    // Monitor clocking block - all signals are inputs for sampling
    clocking mon_cb @(posedge clk);
        default input #1;
        input rd_en;
        input rd_data;
        input rd_empty;
        input rd_count;
    endclocking

    modport driver  (clocking rd_cb, input rst_n);
    modport monitor (clocking mon_cb, input rst_n, input rd_empty);
endinterface


// ---- DMA Control Interface ----
interface ctrl_if (
    input logic clk,
    input logic rst_n
);
    logic        transfer_start;
    logic [31:0] ddr_base_addr;
    logic [31:0] transfer_count;
    logic        transfer_done;
    logic        transfer_error;
    logic [31:0] words_transferred;

    clocking ctrl_cb @(posedge clk);
        default input #1 output #1;
        output  transfer_start;
        output  ddr_base_addr;
        output  transfer_count;
        input   transfer_done;
        input   transfer_error;
        input   words_transferred;
    endclocking

    modport driver  (clocking ctrl_cb, input rst_n);
    modport monitor (clocking ctrl_cb, input rst_n);
endinterface
