// =============================================================================
// async_fifo.sv
// Asynchronous FIFO with Gray-code pointer synchronisation
// Dual-clock domain: wr_clk (write) / rd_clk (read)
// =============================================================================

module async_fifo #(
    parameter int DATA_WIDTH = 64,
    parameter int FIFO_DEPTH = 1024,
    parameter int ADDR_WIDTH = $clog2(FIFO_DEPTH),
    parameter int SYNC_STAGES = 2    // CDC synchroniser depth
)(
    // Write domain
    input  logic                    wr_clk,
    input  logic                    wr_rst_n,
    input  logic                    wr_en,
    input  logic [DATA_WIDTH-1:0]   wr_data,
    output logic                    wr_full,
    output logic [ADDR_WIDTH:0]     wr_count,

    // Read domain
    input  logic                    rd_clk,
    input  logic                    rd_rst_n,
    input  logic                    rd_en,
    output logic [DATA_WIDTH-1:0]   rd_data,
    output logic                    rd_empty,
    output logic [ADDR_WIDTH:0]     rd_count
);

    // =========================================================================
    // Pointer declarations (extra bit for full/empty detection)
    // =========================================================================
    logic [ADDR_WIDTH:0] wr_ptr_bin, wr_ptr_gray;
    logic [ADDR_WIDTH:0] rd_ptr_bin, rd_ptr_gray;

    // Synchronised pointers (Gray-coded)
    logic [ADDR_WIDTH:0] wr_ptr_gray_sync;  // wr_ptr synchronised to rd_clk
    logic [ADDR_WIDTH:0] rd_ptr_gray_sync;  // rd_ptr synchronised to wr_clk

    // Memory addresses
    logic [ADDR_WIDTH-1:0] wr_addr, rd_addr;

    // =========================================================================
    // Dual-port RAM
    // =========================================================================
    logic [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

    assign wr_addr = wr_ptr_bin[ADDR_WIDTH-1:0];
    assign rd_addr = rd_ptr_bin[ADDR_WIDTH-1:0];

    // Write port
    always_ff @(posedge wr_clk) begin
        if (wr_en && !wr_full)
            mem[wr_addr] <= wr_data;
    end

    // Read port
    always_ff @(posedge rd_clk) begin
        if (rd_en && !rd_empty)
            rd_data <= mem[rd_addr];
    end

    // =========================================================================
    // Write pointer logic (wr_clk domain)
    // =========================================================================
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= '0;
            wr_ptr_gray <= '0;
        end else if (wr_en && !wr_full) begin
            wr_ptr_bin  <= wr_ptr_bin + 1'b1;
            wr_ptr_gray <= (wr_ptr_bin + 1'b1) ^ ((wr_ptr_bin + 1'b1) >> 1);
        end
    end

    // =========================================================================
    // Read pointer logic (rd_clk domain)
    // =========================================================================
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= '0;
            rd_ptr_gray <= '0;
        end else if (rd_en && !rd_empty) begin
            rd_ptr_bin  <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= (rd_ptr_bin + 1'b1) ^ ((rd_ptr_bin + 1'b1) >> 1);
        end
    end

    // =========================================================================
    // Gray-code CDC synchronisers
    // =========================================================================
    // Synchronise wr_ptr_gray -> rd_clk domain
    sync_chain #(
        .WIDTH       (ADDR_WIDTH + 1),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_wr_ptr_sync (
        .clk     (rd_clk),
        .rst_n   (rd_rst_n),
        .d_in    (wr_ptr_gray),
        .q_out   (wr_ptr_gray_sync)
    );

    // Synchronise rd_ptr_gray -> wr_clk domain
    sync_chain #(
        .WIDTH       (ADDR_WIDTH + 1),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_rd_ptr_sync (
        .clk     (wr_clk),
        .rst_n   (wr_rst_n),
        .d_in    (rd_ptr_gray),
        .q_out   (rd_ptr_gray_sync)
    );

    // =========================================================================
    // Full and Empty logic
    // =========================================================================
    // Full: MSB and MSB-1 differ, rest match (Gray-code comparison)
    assign wr_full = (wr_ptr_gray == {~rd_ptr_gray_sync[ADDR_WIDTH:ADDR_WIDTH-1],
                                       rd_ptr_gray_sync[ADDR_WIDTH-2:0]});

    // Empty: pointers are identical
    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync);

    // =========================================================================
    // Approximate count (for monitoring / threshold logic)
    // =========================================================================
    // Convert synchronised Gray pointers back to binary for count
    logic [ADDR_WIDTH:0] wr_ptr_bin_in_rd, rd_ptr_bin_in_wr;

    // Gray-to-binary conversion
    always_comb begin
        wr_ptr_bin_in_rd[ADDR_WIDTH] = wr_ptr_gray_sync[ADDR_WIDTH];
        for (int i = ADDR_WIDTH - 1; i >= 0; i--)
            wr_ptr_bin_in_rd[i] = wr_ptr_bin_in_rd[i+1] ^ wr_ptr_gray_sync[i];
    end

    always_comb begin
        rd_ptr_bin_in_wr[ADDR_WIDTH] = rd_ptr_gray_sync[ADDR_WIDTH];
        for (int i = ADDR_WIDTH - 1; i >= 0; i--)
            rd_ptr_bin_in_wr[i] = rd_ptr_bin_in_wr[i+1] ^ rd_ptr_gray_sync[i];
    end

    assign wr_count = wr_ptr_bin - rd_ptr_bin_in_wr; // Write-domain count
    assign rd_count = wr_ptr_bin_in_rd - rd_ptr_bin;  // Read-domain count

endmodule


// =============================================================================
// sync_chain.sv (inline) - Parameterised multi-stage synchroniser
// =============================================================================
module sync_chain #(
    parameter int WIDTH       = 1,
    parameter int SYNC_STAGES = 2
)(
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] d_in,
    output logic [WIDTH-1:0] q_out
);

    (* ASYNC_REG = "TRUE" *)
    logic [WIDTH-1:0] sync_reg [SYNC_STAGES-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SYNC_STAGES; i++)
                sync_reg[i] <= '0;
        end else begin
            sync_reg[0] <= d_in;
            for (int i = 1; i < SYNC_STAGES; i++)
                sync_reg[i] <= sync_reg[i-1];
        end
    end

    assign q_out = sync_reg[SYNC_STAGES-1];

endmodule
