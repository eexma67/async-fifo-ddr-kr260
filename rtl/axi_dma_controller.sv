// =============================================================================
// axi_dma_controller.sv
// AXI4 DMA Controller: Transfers data between Async FIFO and DDR4
// Supports burst writes (FIFO->DDR) and burst reads (DDR->FIFO)
//
// FIX (Build 10): The async FIFO has a 1-cycle registered read output
// (BRAM-style). Added S_WR_PREFETCH state to prime the read data pipeline
// so fifo_rd_data is valid when m_axi_wvalid first asserts in S_WR_DATA.
// Also registered ddr_base_addr for stable readback addressing.
// =============================================================================

module axi_dma_controller #(
    parameter int DATA_WIDTH    = 64,
    parameter int AXI_ADDR_W    = 32,
    parameter int AXI_ID_W      = 4,
    parameter int AXI_LEN_W     = 8,
    parameter int DDR_BURST_LEN = 256  // Max 256 for AXI4
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // ---- FIFO Write-path Read Interface ----
    output logic                        fifo_rd_en,
    input  logic [DATA_WIDTH-1:0]       fifo_rd_data,
    input  logic                        fifo_rd_empty,
    input  logic [$clog2(DDR_BURST_LEN):0] fifo_rd_count,

    // ---- FIFO Readback Write Interface ----
    output logic                        fifo_rb_wr_en,
    output logic [DATA_WIDTH-1:0]       fifo_rb_wr_data,
    input  logic                        fifo_rb_wr_full,

    // ---- AXI4 Master Write Address ----
    output logic [AXI_ID_W-1:0]        m_axi_awid,
    output logic [AXI_ADDR_W-1:0]      m_axi_awaddr,
    output logic [AXI_LEN_W-1:0]       m_axi_awlen,
    output logic [2:0]                  m_axi_awsize,
    output logic [1:0]                  m_axi_awburst,
    output logic                        m_axi_awvalid,
    input  logic                        m_axi_awready,

    // ---- AXI4 Master Write Data ----
    output logic [DATA_WIDTH-1:0]       m_axi_wdata,
    output logic [DATA_WIDTH/8-1:0]     m_axi_wstrb,
    output logic                        m_axi_wlast,
    output logic                        m_axi_wvalid,
    input  logic                        m_axi_wready,

    // ---- AXI4 Master Write Response ----
    input  logic [AXI_ID_W-1:0]        m_axi_bid,
    input  logic [1:0]                  m_axi_bresp,
    input  logic                        m_axi_bvalid,
    output logic                        m_axi_bready,

    // ---- AXI4 Master Read Address ----
    output logic [AXI_ID_W-1:0]        m_axi_arid,
    output logic [AXI_ADDR_W-1:0]      m_axi_araddr,
    output logic [AXI_LEN_W-1:0]       m_axi_arlen,
    output logic [2:0]                  m_axi_arsize,
    output logic [1:0]                  m_axi_arburst,
    output logic                        m_axi_arvalid,
    input  logic                        m_axi_arready,

    // ---- AXI4 Master Read Data ----
    input  logic [AXI_ID_W-1:0]        m_axi_rid,
    input  logic [DATA_WIDTH-1:0]       m_axi_rdata,
    input  logic [1:0]                  m_axi_rresp,
    input  logic                        m_axi_rlast,
    input  logic                        m_axi_rvalid,
    output logic                        m_axi_rready,

    // ---- Control & Status ----
    input  logic                        transfer_start,
    input  logic [AXI_ADDR_W-1:0]      ddr_base_addr,
    input  logic [31:0]                transfer_count,
    output logic                        transfer_done,
    output logic                        transfer_error,
    output logic [31:0]                words_transferred
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int BYTES_PER_WORD = DATA_WIDTH / 8;
    localparam int AXI_SIZE       = $clog2(BYTES_PER_WORD);
    localparam int BURST_LEN      = (DDR_BURST_LEN > 256) ? 256 : DDR_BURST_LEN;

    // =========================================================================
    // FSM States
    // =========================================================================
    typedef enum logic [3:0] {
        S_IDLE,
        S_WR_WAIT_FIFO,    // Wait for FIFO to have data
        S_WR_ADDR,         // Issue AXI write address
        S_WR_PREFETCH,     // Pre-read first word (FIFO has 1-cycle read latency)
        S_WR_DATA,         // Stream write data from FIFO to AXI
        S_WR_RESP,         // Wait for write response
        S_RD_ADDR,         // Issue AXI read address
        S_RD_DATA,         // Receive read data, push to readback FIFO
        S_DONE,
        S_ERROR
    } state_t;

    state_t state, next_state;

    // =========================================================================
    // Internal registers
    // =========================================================================
    logic [AXI_ADDR_W-1:0]  current_addr;
    logic [AXI_ADDR_W-1:0]  rd_base_addr;     // Registered copy for readback
    logic [31:0]            remaining_words;
    logic [31:0]            wr_word_count;
    logic [AXI_LEN_W-1:0]   burst_beat_cnt;
    logic [AXI_LEN_W-1:0]   current_burst_len; // Actual burst length - 1
    logic                    prefetch_valid;    // fifo_rd_data has valid prefetch

    // =========================================================================
    // Static AXI assignments
    // =========================================================================
    assign m_axi_awid    = '0;
    assign m_axi_awsize  = AXI_SIZE[2:0];
    assign m_axi_awburst = 2'b01;  // INCR
    assign m_axi_wstrb   = {(DATA_WIDTH/8){1'b1}};

    assign m_axi_arid    = '0;
    assign m_axi_arsize  = AXI_SIZE[2:0];
    assign m_axi_arburst = 2'b01;  // INCR

    assign m_axi_bready  = (state == S_WR_RESP);

    // =========================================================================
    // Burst length calculation
    // =========================================================================
    logic [AXI_LEN_W-1:0] calc_burst_len;
    always_comb begin
        if (remaining_words >= BURST_LEN)
            calc_burst_len = BURST_LEN - 1;
        else
            calc_burst_len = remaining_words[AXI_LEN_W-1:0] - 1;
    end

    // =========================================================================
    // FSM: Sequential
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            current_addr      <= '0;
            rd_base_addr      <= '0;
            remaining_words   <= '0;
            wr_word_count     <= '0;
            burst_beat_cnt    <= '0;
            current_burst_len <= '0;
            prefetch_valid    <= 1'b0;
            transfer_done     <= 1'b0;
            transfer_error    <= 1'b0;
            words_transferred <= '0;
        end else begin
            state <= next_state;

            case (state)
                S_IDLE: begin
                    transfer_done  <= 1'b0;
                    transfer_error <= 1'b0;
                    prefetch_valid <= 1'b0;
                    if (transfer_start) begin
                        current_addr      <= ddr_base_addr;
                        rd_base_addr      <= ddr_base_addr;
                        remaining_words   <= transfer_count;
                        wr_word_count     <= '0;
                        words_transferred <= '0;
                    end
                end

                S_WR_WAIT_FIFO: begin
                    current_burst_len <= calc_burst_len;
                    prefetch_valid    <= 1'b0;
                end

                S_WR_ADDR: begin
                    if (m_axi_awvalid && m_axi_awready)
                        burst_beat_cnt <= '0;
                end

                S_WR_PREFETCH: begin
                    // fifo_rd_en was asserted in this state (see output logic).
                    // On the NEXT cycle (entering S_WR_DATA), fifo_rd_data is valid.
                    prefetch_valid <= 1'b1;
                end

                S_WR_DATA: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        burst_beat_cnt    <= burst_beat_cnt + 1'b1;
                        wr_word_count     <= wr_word_count + 1'b1;
                        words_transferred <= words_transferred + 1'b1;
                    end
                end

                S_WR_RESP: begin
                    if (m_axi_bvalid) begin
                        if (m_axi_bresp != 2'b00) begin
                            transfer_error <= 1'b1;
                        end else begin
                            current_addr    <= current_addr + ((current_burst_len + 1) * BYTES_PER_WORD);
                            remaining_words <= remaining_words - (current_burst_len + 1);
                        end
                    end
                end

                S_RD_ADDR: begin
                    if (m_axi_arvalid && m_axi_arready)
                        burst_beat_cnt <= '0;
                end

                S_RD_DATA: begin
                    if (m_axi_rvalid && m_axi_rready)
                        burst_beat_cnt <= burst_beat_cnt + 1'b1;
                end

                S_DONE: begin
                    transfer_done <= 1'b1;
                end

                S_ERROR: begin
                    transfer_error <= 1'b1;
                    transfer_done  <= 1'b1;
                end

                default: ;
            endcase
        end
    end

    // =========================================================================
    // FSM: Combinational next-state
    // =========================================================================
    always_comb begin
        next_state = state;

        case (state)
            S_IDLE:
                if (transfer_start && transfer_count > 0)
                    next_state = S_WR_WAIT_FIFO;

            S_WR_WAIT_FIFO:
                if (!fifo_rd_empty)
                    next_state = S_WR_ADDR;

            S_WR_ADDR:
                if (m_axi_awvalid && m_axi_awready)
                    next_state = S_WR_PREFETCH;  // NEW: prefetch before data phase

            S_WR_PREFETCH:
                next_state = S_WR_DATA;          // Always 1 cycle

            S_WR_DATA:
                if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                    next_state = S_WR_RESP;

            S_WR_RESP: begin
                if (m_axi_bvalid) begin
                    if (m_axi_bresp != 2'b00)
                        next_state = S_ERROR;
                    else if (remaining_words <= (current_burst_len + 1))
                        next_state = S_RD_ADDR;
                    else
                        next_state = S_WR_WAIT_FIFO;
                end
            end

            S_RD_ADDR:
                if (m_axi_arvalid && m_axi_arready)
                    next_state = S_RD_DATA;

            S_RD_DATA:
                if (m_axi_rvalid && m_axi_rready && m_axi_rlast)
                    next_state = S_DONE;

            S_DONE:
                next_state = S_IDLE;

            S_ERROR:
                next_state = S_IDLE;

            default:
                next_state = S_IDLE;
        endcase
    end

    // =========================================================================
    // Output logic
    // =========================================================================

    // FIFO read enable:
    //   S_WR_PREFETCH: read first word to prime the pipeline
    //   S_WR_DATA:     read next word when current beat accepted (not on last beat)
    assign fifo_rd_en = (state == S_WR_PREFETCH && !fifo_rd_empty) ||
                        (state == S_WR_DATA && m_axi_wvalid && m_axi_wready
                         && !m_axi_wlast && !fifo_rd_empty);

    // AXI Write address
    assign m_axi_awaddr  = current_addr;
    assign m_axi_awlen   = current_burst_len;
    assign m_axi_awvalid = (state == S_WR_ADDR);

    // AXI Write data — fifo_rd_data is valid because:
    //   First beat:      prefetched in S_WR_PREFETCH (data appears 1 cycle later)
    //   Subsequent beats: pre-read on previous beat acceptance
    assign m_axi_wdata  = fifo_rd_data;
    assign m_axi_wvalid = (state == S_WR_DATA) && prefetch_valid;
    assign m_axi_wlast  = (state == S_WR_DATA) && (burst_beat_cnt == current_burst_len);

    // AXI Read address — use registered base address
    assign m_axi_araddr  = rd_base_addr;
    assign m_axi_arlen   = current_burst_len;
    assign m_axi_arvalid = (state == S_RD_ADDR);

    // AXI Read data -> Readback FIFO
    assign m_axi_rready    = (state == S_RD_DATA) && !fifo_rb_wr_full;
    assign fifo_rb_wr_en   = (state == S_RD_DATA) && m_axi_rvalid && !fifo_rb_wr_full;
    assign fifo_rb_wr_data = m_axi_rdata;

endmodule
