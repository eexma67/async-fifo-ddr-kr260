// =============================================================================
// tb_top.sv - UVM Testbench Top Module
// Async FIFO <-> DDR Data Transfer Verification
// =============================================================================

`timescale 1ns/1ps

`include "uvm_macros.svh"
import uvm_pkg::*;

module tb_top;

    // =========================================================================
    // Parameters (override via +define+ from CI/CD)
    // =========================================================================
    parameter int FIFO_DEPTH    = `FIFO_DEPTH;
    parameter int DATA_WIDTH    = `DATA_WIDTH;
    parameter int DDR_BURST_LEN = `DDR_BURST_LEN;
    parameter int ADDR_WIDTH    = $clog2(FIFO_DEPTH);

    // =========================================================================
    // Clock and Reset Generation
    // =========================================================================
    logic wr_clk   = 0;
    logic axi_clk  = 0;
    logic rd_clk   = 0;
    logic wr_rst_n = 0;
    logic axi_rst_n= 0;
    logic rd_rst_n = 0;

    // Asymmetric clocks to stress CDC
    always #6.25  wr_clk  = ~wr_clk;   // 80 MHz  (write source)
    always #2.50  axi_clk = ~axi_clk;  // 200 MHz (DDR/AXI)
    always #4.17  rd_clk  = ~rd_clk;   // ~120 MHz (readback)

    // Reset sequence
    initial begin
        wr_rst_n  = 0;
        axi_rst_n = 0;
        rd_rst_n  = 0;
        #100;
        @(posedge wr_clk)  wr_rst_n  = 1;
        @(posedge axi_clk) axi_rst_n = 1;
        @(posedge rd_clk)  rd_rst_n  = 1;
    end

    // =========================================================================
    // DUT Signals
    // =========================================================================
    logic                    wr_en;
    logic [DATA_WIDTH-1:0]   wr_data;
    logic                    wr_full;
    logic [ADDR_WIDTH:0]     wr_fifo_count;

    logic                    rd_en;
    logic [DATA_WIDTH-1:0]   rd_data;
    logic                    rd_empty;
    logic [ADDR_WIDTH:0]     rd_fifo_count;

    logic                    transfer_start;
    logic [31:0]            ddr_base_addr;
    logic [31:0]            transfer_count;
    logic                    transfer_done;
    logic                    transfer_error;
    logic [31:0]            words_transferred;

    // AXI4 signals
    logic [3:0]             m_axi_awid, m_axi_bid, m_axi_arid, m_axi_rid;
    logic [31:0]            m_axi_awaddr, m_axi_araddr;
    logic [7:0]             m_axi_awlen, m_axi_arlen;
    logic [2:0]             m_axi_awsize, m_axi_arsize;
    logic [1:0]             m_axi_awburst, m_axi_arburst;
    logic                    m_axi_awvalid, m_axi_awready;
    logic [DATA_WIDTH-1:0]   m_axi_wdata, m_axi_rdata;
    logic [DATA_WIDTH/8-1:0] m_axi_wstrb;
    logic                    m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic [1:0]             m_axi_bresp, m_axi_rresp;
    logic                    m_axi_bvalid, m_axi_bready;
    logic                    m_axi_arvalid, m_axi_arready;
    logic                    m_axi_rlast, m_axi_rvalid, m_axi_rready;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    async_fifo_ddr_top #(
        .FIFO_DEPTH    (FIFO_DEPTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .DDR_BURST_LEN (DDR_BURST_LEN)
    ) dut (
        .wr_clk             (wr_clk),
        .wr_rst_n           (wr_rst_n),
        .wr_en              (wr_en),
        .wr_data            (wr_data),
        .wr_full            (wr_full),
        .wr_fifo_count      (wr_fifo_count),
        .axi_clk            (axi_clk),
        .axi_rst_n          (axi_rst_n),
        .rd_clk             (rd_clk),
        .rd_rst_n           (rd_rst_n),
        .rd_en              (rd_en),
        .rd_data            (rd_data),
        .rd_empty           (rd_empty),
        .rd_fifo_count      (rd_fifo_count),
        .m_axi_awid         (m_axi_awid),
        .m_axi_awaddr       (m_axi_awaddr),
        .m_axi_awlen        (m_axi_awlen),
        .m_axi_awsize       (m_axi_awsize),
        .m_axi_awburst      (m_axi_awburst),
        .m_axi_awvalid      (m_axi_awvalid),
        .m_axi_awready      (m_axi_awready),
        .m_axi_wdata        (m_axi_wdata),
        .m_axi_wstrb        (m_axi_wstrb),
        .m_axi_wlast        (m_axi_wlast),
        .m_axi_wvalid       (m_axi_wvalid),
        .m_axi_wready       (m_axi_wready),
        .m_axi_bid          (m_axi_bid),
        .m_axi_bresp        (m_axi_bresp),
        .m_axi_bvalid       (m_axi_bvalid),
        .m_axi_bready       (m_axi_bready),
        .m_axi_arid         (m_axi_arid),
        .m_axi_araddr       (m_axi_araddr),
        .m_axi_arlen        (m_axi_arlen),
        .m_axi_arsize       (m_axi_arsize),
        .m_axi_arburst      (m_axi_arburst),
        .m_axi_arvalid      (m_axi_arvalid),
        .m_axi_arready      (m_axi_arready),
        .m_axi_rid          (m_axi_rid),
        .m_axi_rdata        (m_axi_rdata),
        .m_axi_rresp        (m_axi_rresp),
        .m_axi_rlast        (m_axi_rlast),
        .m_axi_rvalid       (m_axi_rvalid),
        .m_axi_rready       (m_axi_rready),
        .transfer_start     (transfer_start),
        .ddr_base_addr      (ddr_base_addr),
        .transfer_count     (transfer_count),
        .transfer_done      (transfer_done),
        .transfer_error     (transfer_error),
        .words_transferred  (words_transferred)
    );

    // =========================================================================
    // AXI4 Slave Memory Model (DDR Behavioral Model)
    // =========================================================================
    axi4_mem_slave #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (32),
        .MEM_SIZE   (65536)  // 64K words
    ) u_ddr_model (
        .clk            (axi_clk),
        .rst_n          (axi_rst_n),
        .s_axi_awid     (m_axi_awid),
        .s_axi_awaddr   (m_axi_awaddr),
        .s_axi_awlen    (m_axi_awlen),
        .s_axi_awsize   (m_axi_awsize),
        .s_axi_awburst  (m_axi_awburst),
        .s_axi_awvalid  (m_axi_awvalid),
        .s_axi_awready  (m_axi_awready),
        .s_axi_wdata    (m_axi_wdata),
        .s_axi_wstrb    (m_axi_wstrb),
        .s_axi_wlast    (m_axi_wlast),
        .s_axi_wvalid   (m_axi_wvalid),
        .s_axi_wready   (m_axi_wready),
        .s_axi_bid      (m_axi_bid),
        .s_axi_bresp    (m_axi_bresp),
        .s_axi_bvalid   (m_axi_bvalid),
        .s_axi_bready   (m_axi_bready),
        .s_axi_arid     (m_axi_arid),
        .s_axi_araddr   (m_axi_araddr),
        .s_axi_arlen    (m_axi_arlen),
        .s_axi_arsize   (m_axi_arsize),
        .s_axi_arburst  (m_axi_arburst),
        .s_axi_arvalid  (m_axi_arvalid),
        .s_axi_arready  (m_axi_arready),
        .s_axi_rid      (m_axi_rid),
        .s_axi_rdata    (m_axi_rdata),
        .s_axi_rresp    (m_axi_rresp),
        .s_axi_rlast    (m_axi_rlast),
        .s_axi_rvalid   (m_axi_rvalid),
        .s_axi_rready   (m_axi_rready)
    );

    // =========================================================================
    // Virtual Interface Assignments (connect to UVM env via config_db)
    // =========================================================================
    fifo_wr_if  #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) wr_vif(wr_clk, wr_rst_n);
    fifo_rd_if  #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) rd_vif(rd_clk, rd_rst_n);
    ctrl_if     ctrl_vif(axi_clk, axi_rst_n);

    // Connect virtual interfaces to DUT signals
    assign wr_en          = wr_vif.wr_en;
    assign wr_data        = wr_vif.wr_data;
    assign wr_vif.wr_full = wr_full;
    assign wr_vif.wr_count= wr_fifo_count;

    assign rd_en          = rd_vif.rd_en;
    assign rd_vif.rd_data = rd_data;
    assign rd_vif.rd_empty= rd_empty;
    assign rd_vif.rd_count= rd_fifo_count;

    assign transfer_start      = ctrl_vif.transfer_start;
    assign ddr_base_addr       = ctrl_vif.ddr_base_addr;
    assign transfer_count      = ctrl_vif.transfer_count;
    assign ctrl_vif.transfer_done  = transfer_done;
    assign ctrl_vif.transfer_error = transfer_error;
    assign ctrl_vif.words_transferred = words_transferred;

    // =========================================================================
    // UVM Config DB & Run
    // =========================================================================
    initial begin
        uvm_config_db#(virtual fifo_wr_if)::set(null, "*", "wr_vif", wr_vif);
        uvm_config_db#(virtual fifo_rd_if)::set(null, "*", "rd_vif", rd_vif);
        uvm_config_db#(virtual ctrl_if)::set(null, "*", "ctrl_vif", ctrl_vif);

        // Set parameters in config DB for test access
        uvm_config_db#(int)::set(null, "*", "FIFO_DEPTH", FIFO_DEPTH);
        uvm_config_db#(int)::set(null, "*", "DATA_WIDTH", DATA_WIDTH);
        uvm_config_db#(int)::set(null, "*", "DDR_BURST_LEN", DDR_BURST_LEN);

        run_test();
    end

    // =========================================================================
    // Timeout watchdog
    // =========================================================================
    initial begin
        #10_000_000; // 10ms
        `uvm_fatal("TB_TOP", "Simulation timeout!")
    end

    // =========================================================================
    // Waveform dump (for debug)
    // =========================================================================
    initial begin
        if ($test$plusargs("DUMP_WAVES")) begin
            $dumpfile("waves.vcd");
            $dumpvars(0, tb_top);
        end
    end

endmodule
