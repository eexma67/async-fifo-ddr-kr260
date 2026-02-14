// =============================================================================
// axi4_mem_slave.sv - AXI4 Slave Memory Model (DDR Behavioral)
// 
// Simple behavioral model of a DDR memory with AXI4 slave interface.
// Supports INCR bursts for both write and read channels.
// Used in UVM testbench as a DDR stand-in.
// =============================================================================

module axi4_mem_slave #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 32,
    parameter MEM_SIZE   = 65536,   // Number of words
    parameter ID_WIDTH   = 4
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // AXI4 Write Address Channel
    input  logic [ID_WIDTH-1:0]     s_axi_awid,
    input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  logic [7:0]              s_axi_awlen,
    input  logic [2:0]              s_axi_awsize,
    input  logic [1:0]              s_axi_awburst,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,

    // AXI4 Write Data Channel
    input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  logic                    s_axi_wlast,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,

    // AXI4 Write Response Channel
    output logic [ID_WIDTH-1:0]     s_axi_bid,
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    // AXI4 Read Address Channel
    input  logic [ID_WIDTH-1:0]     s_axi_arid,
    input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  logic [7:0]              s_axi_arlen,
    input  logic [2:0]              s_axi_arsize,
    input  logic [1:0]              s_axi_arburst,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,

    // AXI4 Read Data Channel
    output logic [ID_WIDTH-1:0]     s_axi_rid,
    output logic [DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rlast,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready
);

    // =========================================================================
    // Memory Array
    // =========================================================================
    localparam BYTES_PER_WORD = DATA_WIDTH / 8;
    localparam ADDR_LSB       = $clog2(BYTES_PER_WORD);

    logic [DATA_WIDTH-1:0] mem [0:MEM_SIZE-1];

    // =========================================================================
    // Write Channel FSM
    // =========================================================================
    typedef enum logic [1:0] {
        WR_IDLE,
        WR_DATA,
        WR_RESP
    } wr_state_t;

    wr_state_t wr_state;
    logic [ADDR_WIDTH-1:0] wr_addr;
    logic [7:0]            wr_len;
    logic [7:0]            wr_beat_cnt;
    logic [ID_WIDTH-1:0]   wr_id;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state      <= WR_IDLE;
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bid     <= '0;
            s_axi_bresp   <= 2'b00;
            wr_addr       <= '0;
            wr_len        <= '0;
            wr_beat_cnt   <= '0;
            wr_id         <= '0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    s_axi_bvalid <= 1'b0;
                    if (s_axi_awvalid && s_axi_awready) begin
                        wr_addr       <= s_axi_awaddr;
                        wr_len        <= s_axi_awlen;
                        wr_id         <= s_axi_awid;
                        wr_beat_cnt   <= '0;
                        s_axi_awready <= 1'b0;
                        s_axi_wready  <= 1'b1;
                        wr_state      <= WR_DATA;
                    end
                end

                WR_DATA: begin
                    if (s_axi_wvalid && s_axi_wready) begin
                        // Write data to memory with strobe
                        automatic int word_addr = (wr_addr >> ADDR_LSB) % MEM_SIZE;
                        for (int b = 0; b < BYTES_PER_WORD; b++) begin
                            if (s_axi_wstrb[b])
                                mem[word_addr][b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
                        end

                        wr_addr     <= wr_addr + BYTES_PER_WORD;
                        wr_beat_cnt <= wr_beat_cnt + 1;

                        if (s_axi_wlast || wr_beat_cnt == wr_len) begin
                            s_axi_wready <= 1'b0;
                            s_axi_bvalid <= 1'b1;
                            s_axi_bid    <= wr_id;
                            s_axi_bresp  <= 2'b00; // OKAY
                            wr_state     <= WR_RESP;
                        end
                    end
                end

                WR_RESP: begin
                    if (s_axi_bvalid && s_axi_bready) begin
                        s_axi_bvalid  <= 1'b0;
                        s_axi_awready <= 1'b1;
                        wr_state      <= WR_IDLE;
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Read Channel FSM
    // =========================================================================
    typedef enum logic [1:0] {
        RD_IDLE,
        RD_DATA
    } rd_state_t;

    rd_state_t rd_state;
    logic [ADDR_WIDTH-1:0] rd_addr;
    logic [7:0]            rd_len;
    logic [7:0]            rd_beat_cnt;
    logic [ID_WIDTH-1:0]   rd_id;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state      <= RD_IDLE;
            s_axi_arready <= 1'b1;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= '0;
            s_axi_rresp   <= 2'b00;
            s_axi_rlast   <= 1'b0;
            s_axi_rid     <= '0;
            rd_addr       <= '0;
            rd_len        <= '0;
            rd_beat_cnt   <= '0;
            rd_id         <= '0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    if (s_axi_arvalid && s_axi_arready) begin
                        rd_addr       <= s_axi_araddr;
                        rd_len        <= s_axi_arlen;
                        rd_id         <= s_axi_arid;
                        rd_beat_cnt   <= '0;
                        s_axi_arready <= 1'b0;
                        s_axi_rvalid  <= 1'b1;
                        s_axi_rid     <= s_axi_arid;
                        s_axi_rdata   <= mem[(s_axi_araddr >> ADDR_LSB) % MEM_SIZE];
                        s_axi_rresp   <= 2'b00;
                        s_axi_rlast   <= (s_axi_arlen == 0);
                        rd_state      <= RD_DATA;
                    end
                end

                RD_DATA: begin
                    if (s_axi_rvalid && s_axi_rready) begin
                        rd_beat_cnt <= rd_beat_cnt + 1;

                        if (rd_beat_cnt == rd_len) begin
                            // Last beat accepted
                            s_axi_rvalid  <= 1'b0;
                            s_axi_rlast   <= 1'b0;
                            s_axi_arready <= 1'b1;
                            rd_state      <= RD_IDLE;
                        end else begin
                            // Next beat
                            rd_addr     <= rd_addr + BYTES_PER_WORD;
                            s_axi_rdata <= mem[((rd_addr + BYTES_PER_WORD) >> ADDR_LSB) % MEM_SIZE];
                            s_axi_rlast <= (rd_beat_cnt + 1 == rd_len);
                        end
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule
