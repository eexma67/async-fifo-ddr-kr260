// =============================================================================
// async_fifo_ddr_top.sv
// Top-level: Async FIFO <-> DDR4 Data Transfer Controller (KR260)
// 
// Architecture:
//   WR_CLK domain -> Async FIFO -> RD_CLK/AXI_CLK domain -> AXI4 Master -> DDR4
//   DDR4 -> AXI4 Master -> Async FIFO -> WR_CLK domain (readback path)
//
// Parameters configurable via CI/CD:
//   FIFO_DEPTH, DATA_WIDTH, DDR_BURST_LEN
// =============================================================================

`ifndef FIFO_DEPTH
  `define FIFO_DEPTH 1024
`endif
`ifndef DATA_WIDTH
  `define DATA_WIDTH 64
`endif
`ifndef DDR_BURST_LEN
  `define DDR_BURST_LEN 256
`endif

module async_fifo_ddr_top #(
    parameter int FIFO_DEPTH    = `FIFO_DEPTH,
    parameter int DATA_WIDTH    = `DATA_WIDTH,
    parameter int ADDR_WIDTH    = $clog2(FIFO_DEPTH),
    parameter int DDR_BURST_LEN = `DDR_BURST_LEN,
    parameter int AXI_ADDR_W    = 32,
    parameter int AXI_ID_W      = 4,
    parameter int AXI_LEN_W     = 8
)(
    // ---- Write-side clock domain (source) ----
    input  logic                    wr_clk,
    input  logic                    wr_rst_n,
    input  logic                    wr_en,
    input  logic [DATA_WIDTH-1:0]   wr_data,
    output logic                    wr_full,
    output logic [ADDR_WIDTH:0]     wr_fifo_count,

    // ---- Read-side / AXI clock domain ----
    input  logic                    axi_clk,       // DDR controller clock (typically 200-300 MHz)
    input  logic                    axi_rst_n,

    // ---- Readback path (DDR -> FIFO -> rd_clk domain) ----
    input  logic                    rd_clk,
    input  logic                    rd_rst_n,
    input  logic                    rd_en,
    output logic [DATA_WIDTH-1:0]   rd_data,
    output logic                    rd_empty,
    output logic [ADDR_WIDTH:0]     rd_fifo_count,

    // ---- AXI4 Master Interface (to DDR4 MIG) ----
    // Write Address Channel
    output logic [AXI_ID_W-1:0]    m_axi_awid,
    output logic [AXI_ADDR_W-1:0]  m_axi_awaddr,
    output logic [AXI_LEN_W-1:0]   m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,

    // Write Data Channel
    output logic [DATA_WIDTH-1:0]   m_axi_wdata,
    output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    // Write Response Channel
    input  logic [AXI_ID_W-1:0]    m_axi_bid,
    input  logic [1:0]             m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,

    // Read Address Channel
    output logic [AXI_ID_W-1:0]    m_axi_arid,
    output logic [AXI_ADDR_W-1:0]  m_axi_araddr,
    output logic [AXI_LEN_W-1:0]   m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,

    // Read Data Channel
    input  logic [AXI_ID_W-1:0]    m_axi_rid,
    input  logic [DATA_WIDTH-1:0]   m_axi_rdata,
    input  logic [1:0]             m_axi_rresp,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready,

    // ---- Control & Status ----
    input  logic                    transfer_start,
    input  logic [AXI_ADDR_W-1:0]  ddr_base_addr,
    input  logic [31:0]            transfer_count, // Total words to transfer
    output logic                    transfer_done,
    output logic                    transfer_error,
    output logic [31:0]            words_transferred
);

    // =========================================================================
    // Internal signals
    // =========================================================================
    logic                   fifo_wr_rd_en;       // FIFO read in AXI domain (write path)
    logic [DATA_WIDTH-1:0]  fifo_wr_rd_data;
    logic                   fifo_wr_rd_empty;
    logic [ADDR_WIDTH:0]    fifo_wr_rd_count;

    logic                   fifo_rb_wr_en;       // FIFO write in AXI domain (readback path)
    logic [DATA_WIDTH-1:0]  fifo_rb_wr_data;
    logic                   fifo_rb_wr_full;

    // =========================================================================
    // Write-path Async FIFO: wr_clk -> axi_clk
    // =========================================================================
    async_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) u_wr_fifo (
        // Write side
        .wr_clk     (wr_clk),
        .wr_rst_n   (wr_rst_n),
        .wr_en      (wr_en),
        .wr_data    (wr_data),
        .wr_full    (wr_full),
        .wr_count   (wr_fifo_count),
        // Read side (AXI clock domain)
        .rd_clk     (axi_clk),
        .rd_rst_n   (axi_rst_n),
        .rd_en      (fifo_wr_rd_en),
        .rd_data    (fifo_wr_rd_data),
        .rd_empty   (fifo_wr_rd_empty),
        .rd_count   (fifo_wr_rd_count)
    );

    // =========================================================================
    // Readback-path Async FIFO: axi_clk -> rd_clk
    // =========================================================================
    async_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) u_rb_fifo (
        // Write side (AXI clock domain)
        .wr_clk     (axi_clk),
        .wr_rst_n   (axi_rst_n),
        .wr_en      (fifo_rb_wr_en),
        .wr_data    (fifo_rb_wr_data),
        .wr_full    (fifo_rb_wr_full),
        .wr_count   (),
        // Read side
        .rd_clk     (rd_clk),
        .rd_rst_n   (rd_rst_n),
        .rd_en      (rd_en),
        .rd_data    (rd_data),
        .rd_empty   (rd_empty),
        .rd_count   (rd_fifo_count)
    );

    // =========================================================================
    // AXI4 DMA Transfer Controller
    // =========================================================================
    axi_dma_controller #(
        .DATA_WIDTH    (DATA_WIDTH),
        .AXI_ADDR_W    (AXI_ADDR_W),
        .AXI_ID_W      (AXI_ID_W),
        .AXI_LEN_W     (AXI_LEN_W),
        .DDR_BURST_LEN (DDR_BURST_LEN)
    ) u_dma_ctrl (
        .clk                (axi_clk),
        .rst_n              (axi_rst_n),
        // FIFO write-path read interface
        .fifo_rd_en         (fifo_wr_rd_en),
        .fifo_rd_data       (fifo_wr_rd_data),
        .fifo_rd_empty      (fifo_wr_rd_empty),
        .fifo_rd_count      (fifo_wr_rd_count),
        // FIFO readback write interface
        .fifo_rb_wr_en      (fifo_rb_wr_en),
        .fifo_rb_wr_data    (fifo_rb_wr_data),
        .fifo_rb_wr_full    (fifo_rb_wr_full),
        // AXI4 Master
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
        // Control
        .transfer_start     (transfer_start),
        .ddr_base_addr      (ddr_base_addr),
        .transfer_count     (transfer_count),
        .transfer_done      (transfer_done),
        .transfer_error     (transfer_error),
        .words_transferred  (words_transferred)
    );

    // =========================================================================
    // Assertions (for simulation only)
    // =========================================================================
    // synthesis translate_off

    // FIFO should never be written when full
    assert property (@(posedge wr_clk) disable iff (!wr_rst_n)
        wr_en |-> !wr_full
    ) else $error("ASSERT FAIL: Write to full FIFO!");

    // FIFO should never be read when empty
    assert property (@(posedge rd_clk) disable iff (!rd_rst_n)
        rd_en |-> !rd_empty
    ) else $error("ASSERT FAIL: Read from empty FIFO!");

    // AXI write response should always be OKAY
    assert property (@(posedge axi_clk) disable iff (!axi_rst_n)
        m_axi_bvalid |-> (m_axi_bresp == 2'b00)
    ) else $error("ASSERT FAIL: AXI write error response!");

    // AXI read response should always be OKAY
    assert property (@(posedge axi_clk) disable iff (!axi_rst_n)
        m_axi_rvalid |-> (m_axi_rresp == 2'b00)
    ) else $error("ASSERT FAIL: AXI read error response!");

    // synthesis translate_on

endmodule
