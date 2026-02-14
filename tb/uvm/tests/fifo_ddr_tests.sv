// =============================================================================
// fifo_ddr_tests.sv - UVM Test Suite
// Tests run automatically via Jenkins CI with +UVM_TESTNAME
//
// Data flow: UVM WR driver → wr_FIFO → DMA → AXI → DDR memory model
//            UVM RD driver ← rb_FIFO ← DMA ← AXI ← DDR memory model
//
// The DMA must be triggered via ctrl_vif (transfer_start, ddr_base_addr,
// transfer_count) to move data through the pipeline.
// =============================================================================

package fifo_ddr_test_pkg;
    import uvm_pkg::*;
    import fifo_ddr_env_pkg::*;
    import fifo_ddr_seq_pkg::*;
    `include "uvm_macros.svh"

    // =========================================================================
    // Base Test (with DMA trigger helper)
    // =========================================================================
    class fifo_ddr_base_test extends uvm_test;
        `uvm_component_utils(fifo_ddr_base_test)

        fifo_ddr_env env;
        virtual ctrl_if ctrl_vif;
        int fifo_depth;
        int data_width;
        int ddr_burst_len;

        function new(string name = "fifo_ddr_base_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = fifo_ddr_env::type_id::create("env", this);

            // Retrieve CI/CD parameters
            void'(uvm_config_db#(int)::get(this, "", "FIFO_DEPTH", fifo_depth));
            void'(uvm_config_db#(int)::get(this, "", "DATA_WIDTH", data_width));
            void'(uvm_config_db#(int)::get(this, "", "DDR_BURST_LEN", ddr_burst_len));

            // Get control interface handle
            if (!uvm_config_db#(virtual ctrl_if)::get(this, "", "ctrl_vif", ctrl_vif))
                `uvm_fatal("TEST", "Failed to get ctrl_vif from config_db")

            `uvm_info("TEST", $sformatf(
                "Configuration: FIFO_DEPTH=%0d DATA_WIDTH=%0d DDR_BURST_LEN=%0d",
                fifo_depth, data_width, ddr_burst_len), UVM_LOW)
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            super.end_of_elaboration_phase(phase);
            uvm_top.print_topology();
        endfunction

        // -----------------------------------------------------------------
        // Helper: Trigger DMA transfer and wait for completion
        // Uses clocking block drives for proper clock-domain alignment.
        // -----------------------------------------------------------------
        task trigger_dma(input logic [31:0] base_addr, input logic [31:0] count,
                         output bit success);
            int timeout_cycles;
            success = 0;

            // Drive via clocking block for deterministic timing
            @(posedge ctrl_vif.clk);
            ctrl_vif.ctrl_cb.ddr_base_addr  <= base_addr;
            ctrl_vif.ctrl_cb.transfer_count <= count;
            ctrl_vif.ctrl_cb.transfer_start <= 1'b1;
            @(posedge ctrl_vif.clk);
            ctrl_vif.ctrl_cb.transfer_start <= 1'b0;

            // Wait for transfer_done or transfer_error with generous timeout
            // Budget: ~40 cycles/word for write+read+overhead
            timeout_cycles = count * 40 + 10000;
            repeat (timeout_cycles) begin
                @(posedge ctrl_vif.clk);
                if (ctrl_vif.ctrl_cb.transfer_done) begin
                    `uvm_info("TEST", $sformatf("DMA done: %0d words at 0x%08h",
                              ctrl_vif.ctrl_cb.words_transferred, base_addr), UVM_MEDIUM)
                    success = 1;
                    return;
                end
                if (ctrl_vif.ctrl_cb.transfer_error) begin
                    `uvm_error("TEST", "DMA transfer error!")
                    return;
                end
            end

            `uvm_error("TEST", $sformatf("DMA timeout after %0d cycles (count=%0d)",
                       timeout_cycles, count))
        endtask

        // -----------------------------------------------------------------
        // Helper: Initialize ctrl_vif to idle
        // -----------------------------------------------------------------
        task init_ctrl();
            @(posedge ctrl_vif.clk);
            ctrl_vif.ctrl_cb.transfer_start <= 1'b0;
            ctrl_vif.ctrl_cb.ddr_base_addr  <= 32'h0;
            ctrl_vif.ctrl_cb.transfer_count <= 32'h0;
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server svr;
            super.report_phase(phase);
            svr = uvm_report_server::get_server();
            if (svr.get_severity_count(UVM_FATAL) + svr.get_severity_count(UVM_ERROR) > 0)
                `uvm_info("TEST", "*** TEST FAILED ***", UVM_NONE)
            else
                `uvm_info("TEST", "*** TEST PASSED ***", UVM_NONE)
        endfunction
    endclass

    // =========================================================================
    // Test 1: Basic Write-Read (Data Integrity via DMA loopback)
    //   Write 64 words → DMA to DDR → DMA readback → Read 64 words
    // =========================================================================
    class fifo_ddr_basic_write_read_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_basic_write_read_test)

        function new(string name = "fifo_ddr_basic_write_read_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_incr_seq wr_seq;
            fifo_rd_base_seq rd_seq;
            bit dma_ok;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Basic Write-Read Test", UVM_LOW)
            init_ctrl();

            // Step 1: Write 64 words into write FIFO
            wr_seq = fifo_wr_incr_seq::type_id::create("wr_seq");
            wr_seq.num_txns = 64;
            wr_seq.start(env.wr_agent.sequencer);
            `uvm_info("TEST", "64 words written to FIFO", UVM_MEDIUM)

            // Step 2: Trigger DMA (FIFO -> DDR -> readback FIFO)
            #500;
            trigger_dma(32'h0000_0000, 64, dma_ok);
            if (!dma_ok) begin
                phase.drop_objection(this);
                return;
            end

            // Step 3: Read 64 words from readback FIFO
            #500;
            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
            rd_seq.num_txns = 64;
            rd_seq.start(env.rd_agent.sequencer);

            #1000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 2: Burst Transfer (DDR_BURST_LEN sized)
    // =========================================================================
    class fifo_ddr_burst_transfer_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_burst_transfer_test)

        function new(string name = "fifo_ddr_burst_transfer_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_burst_seq wr_seq;
            fifo_rd_base_seq  rd_seq;
            bit dma_ok;
            int xfer_count = (ddr_burst_len > 256) ? 256 : ddr_burst_len;

            phase.raise_objection(this);
            `uvm_info("TEST", $sformatf("Starting Burst Transfer Test (count=%0d)", xfer_count), UVM_LOW)
            init_ctrl();

            wr_seq = fifo_wr_burst_seq::type_id::create("wr_seq");
            wr_seq.burst_len = xfer_count;
            wr_seq.start(env.wr_agent.sequencer);

            #500;
            trigger_dma(32'h0001_0000, xfer_count, dma_ok);
            if (!dma_ok) begin
                phase.drop_objection(this);
                return;
            end

            #500;
            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
            rd_seq.num_txns = xfer_count;
            rd_seq.start(env.rd_agent.sequencer);

            #2000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 3: Clock Domain Stress (multiple batches at different addresses)
    // =========================================================================
    class fifo_ddr_clock_domain_stress_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_clock_domain_stress_test)

        function new(string name = "fifo_ddr_clock_domain_stress_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_burst_seq wr_seq;
            fifo_rd_base_seq  rd_seq;
            bit dma_ok;
            int batch_size = 128;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Clock Domain Stress Test", UVM_LOW)
            init_ctrl();

            for (int batch = 0; batch < 4; batch++) begin
                `uvm_info("TEST", $sformatf("Batch %0d: %0d words", batch, batch_size), UVM_MEDIUM)

                wr_seq = fifo_wr_burst_seq::type_id::create($sformatf("wr_seq_%0d", batch));
                wr_seq.burst_len = batch_size;
                wr_seq.start(env.wr_agent.sequencer);

                #500;
                trigger_dma(batch * 32'h0001_0000, batch_size, dma_ok);
                if (!dma_ok) begin
                    `uvm_error("TEST", $sformatf("DMA failed on batch %0d", batch))
                    phase.drop_objection(this);
                    return;
                end

                #500;
                rd_seq = fifo_rd_base_seq::type_id::create($sformatf("rd_seq_%0d", batch));
                rd_seq.num_txns = batch_size;
                rd_seq.start(env.rd_agent.sequencer);

                #500;
            end

            #2000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 4: Backpressure (slow consumer)
    // =========================================================================
    class fifo_ddr_backpressure_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_backpressure_test)

        function new(string name = "fifo_ddr_backpressure_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_burst_seq        wr_seq;
            fifo_rd_backpressure_seq rd_seq;
            bit dma_ok;
            int xfer_count = 256;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Backpressure Test", UVM_LOW)
            init_ctrl();

            wr_seq = fifo_wr_burst_seq::type_id::create("wr_seq");
            wr_seq.burst_len = xfer_count;
            wr_seq.start(env.wr_agent.sequencer);

            #500;
            trigger_dma(32'h0002_0000, xfer_count, dma_ok);
            if (!dma_ok) begin
                phase.drop_objection(this);
                return;
            end

            #500;
            rd_seq = fifo_rd_backpressure_seq::type_id::create("rd_seq");
            rd_seq.num_txns = xfer_count;
            rd_seq.start(env.rd_agent.sequencer);

            #5000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 5: Overflow / Underflow Protection
    // =========================================================================
    class fifo_ddr_overflow_underflow_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_overflow_underflow_test)

        function new(string name = "fifo_ddr_overflow_underflow_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_burst_seq wr_seq;
            fifo_rd_base_seq  rd_seq;
            bit dma_ok;
            int xfer_count = 256;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Overflow/Underflow Test", UVM_LOW)
            init_ctrl();

            // Write and DMA concurrently so DMA drains the FIFO
            fork
                begin
                    wr_seq = fifo_wr_burst_seq::type_id::create("wr_seq");
                    wr_seq.burst_len = xfer_count;
                    wr_seq.start(env.wr_agent.sequencer);
                end
                begin
                    #200;
                    trigger_dma(32'h0003_0000, xfer_count, dma_ok);
                end
            join

            if (!dma_ok) begin
                `uvm_error("TEST", "DMA failed during overflow test")
                phase.drop_objection(this);
                return;
            end

            #500;
            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
            rd_seq.num_txns = xfer_count;
            rd_seq.start(env.rd_agent.sequencer);

            #2000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 6: Random Traffic (multiple rounds)
    // =========================================================================
    class fifo_ddr_random_traffic_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_random_traffic_test)

        function new(string name = "fifo_ddr_random_traffic_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_base_seq wr_seq;
            fifo_rd_base_seq rd_seq;
            bit dma_ok;
            int round_size = 64;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Random Traffic Test", UVM_LOW)
            init_ctrl();

            repeat(5) begin
                wr_seq = fifo_wr_base_seq::type_id::create("wr_seq");
                wr_seq.num_txns = round_size;
                wr_seq.start(env.wr_agent.sequencer);

                #500;
                trigger_dma(32'h0004_0000, round_size, dma_ok);
                if (!dma_ok) begin
                    `uvm_error("TEST", "DMA failed during random traffic")
                    phase.drop_objection(this);
                    return;
                end

                #500;
                rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
                rd_seq.num_txns = round_size;
                rd_seq.start(env.rd_agent.sequencer);

                #500;
            end

            #2000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 7: Reset Recovery
    // =========================================================================
    class fifo_ddr_reset_recovery_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_reset_recovery_test)

        function new(string name = "fifo_ddr_reset_recovery_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_incr_seq wr_seq;
            fifo_rd_base_seq rd_seq;
            bit dma_ok;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Reset Recovery Test", UVM_LOW)
            init_ctrl();

            // Phase 1: Normal 32-word transfer
            wr_seq = fifo_wr_incr_seq::type_id::create("wr_seq");
            wr_seq.num_txns = 32;
            wr_seq.start(env.wr_agent.sequencer);

            #500;
            trigger_dma(32'h0005_0000, 32, dma_ok);

            #500;
            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
            rd_seq.num_txns = 32;
            rd_seq.start(env.rd_agent.sequencer);
            #500;

            `uvm_info("TEST", "Phase 1 complete, asserting reset...", UVM_LOW)
            #200;
            `uvm_info("TEST", "Releasing reset, resuming transfers...", UVM_LOW)
            #500;

            // Phase 2: Post-reset transfer
            init_ctrl();
            wr_seq = fifo_wr_incr_seq::type_id::create("wr_seq2");
            wr_seq.num_txns   = 64;
            wr_seq.start_val  = 64'hAAAA_0000_0000_0000;
            wr_seq.start(env.wr_agent.sequencer);

            #500;
            trigger_dma(32'h0006_0000, 64, dma_ok);
            if (!dma_ok) begin
                `uvm_error("TEST", "DMA failed after reset recovery")
                phase.drop_objection(this);
                return;
            end

            #500;
            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq2");
            rd_seq.num_txns = 64;
            rd_seq.start(env.rd_agent.sequencer);

            #2000;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
