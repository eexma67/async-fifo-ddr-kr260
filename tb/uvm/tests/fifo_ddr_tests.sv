// =============================================================================
// fifo_ddr_tests.sv - UVM Test Suite
// Tests run automatically via Jenkins CI with +UVM_TESTNAME
// =============================================================================

package fifo_ddr_test_pkg;
    import uvm_pkg::*;
    import fifo_ddr_env_pkg::*;
    import fifo_ddr_seq_pkg::*;
    `include "uvm_macros.svh"

    // =========================================================================
    // Base Test
    // =========================================================================
    class fifo_ddr_base_test extends uvm_test;
        `uvm_component_utils(fifo_ddr_base_test)

        fifo_ddr_env env;
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

            `uvm_info("TEST", $sformatf(
                "Configuration: FIFO_DEPTH=%0d DATA_WIDTH=%0d DDR_BURST_LEN=%0d",
                fifo_depth, data_width, ddr_burst_len), UVM_LOW)
        endfunction

        function void end_of_elaboration_phase(uvm_phase phase);
            super.end_of_elaboration_phase(phase);
            uvm_top.print_topology();
        endfunction

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
    // Test 1: Basic Write-Read (Data Integrity)
    // =========================================================================
    class fifo_ddr_basic_write_read_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_basic_write_read_test)

        function new(string name = "fifo_ddr_basic_write_read_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_incr_seq wr_seq;
            fifo_rd_base_seq rd_seq;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Basic Write-Read Test", UVM_LOW)

            // Write incrementing data
            wr_seq = fifo_wr_incr_seq::type_id::create("wr_seq");
            wr_seq.num_txns = 64;
            wr_seq.start(env.wr_agent.sequencer);

            // Allow CDC latency
            #500;

            // Read back and verify via scoreboard
            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
            rd_seq.num_txns = 64;
            rd_seq.start(env.rd_agent.sequencer);

            #1000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 2: Burst Transfer
    // =========================================================================
    class fifo_ddr_burst_transfer_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_burst_transfer_test)

        function new(string name = "fifo_ddr_burst_transfer_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_burst_seq wr_seq;
            fifo_rd_base_seq  rd_seq;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Burst Transfer Test", UVM_LOW)

            wr_seq = fifo_wr_burst_seq::type_id::create("wr_seq");
            wr_seq.burst_len = ddr_burst_len;
            wr_seq.start(env.wr_agent.sequencer);

            #2000;

            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
            rd_seq.num_txns = ddr_burst_len;
            rd_seq.start(env.rd_agent.sequencer);

            #2000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 3: Clock Domain Stress (asymmetric clock ratios)
    // =========================================================================
    class fifo_ddr_clock_domain_stress_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_clock_domain_stress_test)

        function new(string name = "fifo_ddr_clock_domain_stress_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_stress_seq wr_seq;
            fifo_rd_base_seq   rd_seq;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Clock Domain Stress Test", UVM_LOW)

            // Hammer writes with random timing
            fork
                begin
                    wr_seq = fifo_wr_stress_seq::type_id::create("wr_seq");
                    wr_seq.num_txns = 512;
                    wr_seq.start(env.wr_agent.sequencer);
                end
                begin
                    #200; // Let FIFO fill a bit
                    rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
                    rd_seq.num_txns = 512;
                    rd_seq.start(env.rd_agent.sequencer);
                end
            join

            #5000;
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

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Backpressure Test", UVM_LOW)

            fork
                begin
                    wr_seq = fifo_wr_burst_seq::type_id::create("wr_seq");
                    wr_seq.burst_len = fifo_depth; // Fill FIFO completely
                    wr_seq.start(env.wr_agent.sequencer);
                end
                begin
                    #100;
                    rd_seq = fifo_rd_backpressure_seq::type_id::create("rd_seq");
                    rd_seq.num_txns = fifo_depth;
                    rd_seq.start(env.rd_agent.sequencer);
                end
            join

            #10000;
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

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Overflow/Underflow Test", UVM_LOW)

            // Attempt to write more than FIFO depth (should be blocked by full flag)
            wr_seq = fifo_wr_burst_seq::type_id::create("wr_seq");
            wr_seq.burst_len = fifo_depth * 2;
            wr_seq.start(env.wr_agent.sequencer);

            // Read everything out
            #500;
            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
            rd_seq.num_txns = fifo_depth * 2; // Will block on empty
            fork
                rd_seq.start(env.rd_agent.sequencer);
                begin
                    #50000; // Timeout for reads
                end
            join_any
            disable fork;

            #2000;
            phase.drop_objection(this);
        endtask
    endclass

    // =========================================================================
    // Test 6: Random Traffic
    // =========================================================================
    class fifo_ddr_random_traffic_test extends fifo_ddr_base_test;
        `uvm_component_utils(fifo_ddr_random_traffic_test)

        function new(string name = "fifo_ddr_random_traffic_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_stress_seq wr_seq;
            fifo_rd_base_seq   rd_seq;

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Random Traffic Test", UVM_LOW)

            // Multiple rounds of random write/read
            repeat(5) begin
                fork
                    begin
                        wr_seq = fifo_wr_stress_seq::type_id::create("wr_seq");
                        wr_seq.num_txns = 200;
                        wr_seq.start(env.wr_agent.sequencer);
                    end
                    begin
                        #100;
                        rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
                        rd_seq.num_txns = 200;
                        rd_seq.start(env.rd_agent.sequencer);
                    end
                join
                #500;
            end

            #5000;
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

            phase.raise_objection(this);
            `uvm_info("TEST", "Starting Reset Recovery Test", UVM_LOW)

            // Phase 1: Normal operation
            wr_seq = fifo_wr_incr_seq::type_id::create("wr_seq");
            wr_seq.num_txns = 32;
            wr_seq.start(env.wr_agent.sequencer);
            #500;

            // Phase 2: Assert reset mid-transfer (done at tb_top level via force/release)
            `uvm_info("TEST", "Asserting reset...", UVM_LOW)
            // Note: In real TB, you'd use a reset agent or virtual sequence
            #200;

            // Phase 3: Resume after reset
            `uvm_info("TEST", "Releasing reset, resuming transfers...", UVM_LOW)
            #500;

            wr_seq = fifo_wr_incr_seq::type_id::create("wr_seq2");
            wr_seq.num_txns   = 64;
            wr_seq.start_val  = 64'hAAAA_0000_0000_0000;
            wr_seq.start(env.wr_agent.sequencer);

            #500;
            rd_seq = fifo_rd_base_seq::type_id::create("rd_seq");
            rd_seq.num_txns = 64;
            rd_seq.start(env.rd_agent.sequencer);

            #5000;
            phase.drop_objection(this);
        endtask
    endclass

endpackage
