// =============================================================================
// fifo_ddr_sequences.sv - UVM Sequences for Async FIFO <-> DDR Tests
// =============================================================================

package fifo_ddr_seq_pkg;
    import uvm_pkg::*;
    import fifo_ddr_env_pkg::*;
    `include "uvm_macros.svh"

    // =========================================================================
    // Base Write Sequence
    // =========================================================================
    class fifo_wr_base_seq extends uvm_sequence #(fifo_wr_txn);
        `uvm_object_utils(fifo_wr_base_seq)

        int unsigned num_txns = 64;

        function new(string name = "fifo_wr_base_seq");
            super.new(name);
        endfunction

        task body();
            fifo_wr_txn txn;
            for (int i = 0; i < num_txns; i++) begin
                txn = fifo_wr_txn::type_id::create($sformatf("wr_txn_%0d", i));
                start_item(txn);
                if (!txn.randomize()) `uvm_error("SEQ", "Randomization failed")
                finish_item(txn);
            end
        endtask
    endclass

    // =========================================================================
    // Incrementing Data Write Sequence (for data integrity)
    // =========================================================================
    class fifo_wr_incr_seq extends uvm_sequence #(fifo_wr_txn);
        `uvm_object_utils(fifo_wr_incr_seq)

        int unsigned num_txns = 256;
        logic [63:0] start_val = 64'hDEAD_BEEF_0000_0000;

        function new(string name = "fifo_wr_incr_seq");
            super.new(name);
        endfunction

        task body();
            fifo_wr_txn txn;
            for (int i = 0; i < num_txns; i++) begin
                txn = fifo_wr_txn::type_id::create($sformatf("wr_txn_%0d", i));
                start_item(txn);
                txn.data  = start_val + i;
                txn.delay = 0;
                finish_item(txn);
            end
        endtask
    endclass

    // =========================================================================
    // Burst Write Sequence (back-to-back, no delay)
    // =========================================================================
    class fifo_wr_burst_seq extends uvm_sequence #(fifo_wr_txn);
        `uvm_object_utils(fifo_wr_burst_seq)

        int unsigned burst_len = 256;

        function new(string name = "fifo_wr_burst_seq");
            super.new(name);
        endfunction

        task body();
            fifo_wr_txn txn;
            for (int i = 0; i < burst_len; i++) begin
                txn = fifo_wr_txn::type_id::create($sformatf("burst_%0d", i));
                start_item(txn);
                txn.data  = 64'hCAFE_0000_0000_0000 | i;
                txn.delay = 0;  // No gaps
                finish_item(txn);
            end
        endtask
    endclass

    // =========================================================================
    // Stress Sequence (random delays, random data)
    // =========================================================================
    class fifo_wr_stress_seq extends uvm_sequence #(fifo_wr_txn);
        `uvm_object_utils(fifo_wr_stress_seq)

        int unsigned num_txns = 1024;

        function new(string name = "fifo_wr_stress_seq");
            super.new(name);
        endfunction

        task body();
            fifo_wr_txn txn;
            for (int i = 0; i < num_txns; i++) begin
                txn = fifo_wr_txn::type_id::create($sformatf("stress_%0d", i));
                start_item(txn);
                if (!txn.randomize() with {
                    delay inside {[0:20]};
                }) `uvm_error("SEQ", "Randomization failed")
                finish_item(txn);
            end
        endtask
    endclass

    // =========================================================================
    // Base Read Sequence
    // =========================================================================
    class fifo_rd_base_seq extends uvm_sequence #(fifo_rd_txn);
        `uvm_object_utils(fifo_rd_base_seq)

        int unsigned num_txns = 64;

        function new(string name = "fifo_rd_base_seq");
            super.new(name);
        endfunction

        task body();
            fifo_rd_txn txn;
            for (int i = 0; i < num_txns; i++) begin
                txn = fifo_rd_txn::type_id::create($sformatf("rd_txn_%0d", i));
                start_item(txn);
                if (!txn.randomize()) `uvm_error("SEQ", "Randomization failed")
                finish_item(txn);
            end
        endtask
    endclass

    // =========================================================================
    // Backpressure Read Sequence (slow reader)
    // =========================================================================
    class fifo_rd_backpressure_seq extends uvm_sequence #(fifo_rd_txn);
        `uvm_object_utils(fifo_rd_backpressure_seq)

        int unsigned num_txns = 256;

        function new(string name = "fifo_rd_backpressure_seq");
            super.new(name);
        endfunction

        task body();
            fifo_rd_txn txn;
            for (int i = 0; i < num_txns; i++) begin
                txn = fifo_rd_txn::type_id::create($sformatf("bp_rd_%0d", i));
                start_item(txn);
                txn.delay = $urandom_range(5, 50); // Slow reads
                finish_item(txn);
            end
        endtask
    endclass

endpackage
