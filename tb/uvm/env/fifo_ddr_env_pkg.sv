// =============================================================================
// fifo_ddr_env_pkg.sv - UVM Environment Package
// =============================================================================

package fifo_ddr_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // =========================================================================
    // Transaction: FIFO Write
    // =========================================================================
    class fifo_wr_txn extends uvm_sequence_item;
        `uvm_object_utils(fifo_wr_txn)

        rand logic [63:0] data;
        rand int unsigned delay;    // Inter-transaction delay (cycles)

        constraint c_delay { delay inside {[0:10]}; }

        function new(string name = "fifo_wr_txn");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf("WR data=0x%016h delay=%0d", data, delay);
        endfunction
    endclass

    // =========================================================================
    // Transaction: FIFO Read
    // =========================================================================
    class fifo_rd_txn extends uvm_sequence_item;
        `uvm_object_utils(fifo_rd_txn)

        logic [63:0] data;
        rand int unsigned delay;

        constraint c_delay { delay inside {[0:5]}; }

        function new(string name = "fifo_rd_txn");
            super.new(name);
        endfunction

        function string convert2string();
            return $sformatf("RD data=0x%016h delay=%0d", data, delay);
        endfunction
    endclass

    // =========================================================================
    // Transaction: DMA Control
    // =========================================================================
    class dma_ctrl_txn extends uvm_sequence_item;
        `uvm_object_utils(dma_ctrl_txn)

        rand logic [31:0] base_addr;
        rand logic [31:0] count;

        constraint c_aligned { base_addr[2:0] == 0; }  // 8-byte aligned
        constraint c_count   { count inside {[1:4096]}; }

        function new(string name = "dma_ctrl_txn");
            super.new(name);
        endfunction
    endclass

    // =========================================================================
    // FIFO Write Driver
    // =========================================================================
    class fifo_wr_driver extends uvm_driver #(fifo_wr_txn);
        `uvm_component_utils(fifo_wr_driver)

        virtual fifo_wr_if wr_vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual fifo_wr_if)::get(this, "", "wr_vif", wr_vif))
                `uvm_fatal("WR_DRV", "Failed to get wr_vif from config_db")
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_txn txn;
            forever begin
                seq_item_port.get_next_item(txn);

                // Wait for inter-transaction delay
                repeat(txn.delay) @(posedge wr_vif.clk);

                // Wait until not full
                while (wr_vif.wr_full) @(posedge wr_vif.clk);

                @(posedge wr_vif.clk);
                wr_vif.wr_cb.wr_en   <= 1'b1;
                wr_vif.wr_cb.wr_data <= txn.data;

                @(posedge wr_vif.clk);
                wr_vif.wr_cb.wr_en <= 1'b0;

                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // FIFO Write Monitor
    // =========================================================================
    class fifo_wr_monitor extends uvm_monitor;
        `uvm_component_utils(fifo_wr_monitor)

        virtual fifo_wr_if wr_vif;
        uvm_analysis_port #(fifo_wr_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db#(virtual fifo_wr_if)::get(this, "", "wr_vif", wr_vif))
                `uvm_fatal("WR_MON", "Failed to get wr_vif")
        endfunction

        task run_phase(uvm_phase phase);
            fifo_wr_txn txn;
            forever begin
                @(posedge wr_vif.clk);
                if (wr_vif.mon_cb.wr_en && !wr_vif.mon_cb.wr_full) begin
                    txn = fifo_wr_txn::type_id::create("wr_txn");
                    txn.data = wr_vif.mon_cb.wr_data;
                    ap.write(txn);
                    `uvm_info("WR_MON", txn.convert2string(), UVM_HIGH)
                end
            end
        endtask
    endclass

    // =========================================================================
    // FIFO Read Driver
    // =========================================================================
    class fifo_rd_driver extends uvm_driver #(fifo_rd_txn);
        `uvm_component_utils(fifo_rd_driver)

        virtual fifo_rd_if rd_vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual fifo_rd_if)::get(this, "", "rd_vif", rd_vif))
                `uvm_fatal("RD_DRV", "Failed to get rd_vif")
        endfunction

        task run_phase(uvm_phase phase);
            fifo_rd_txn txn;
            forever begin
                seq_item_port.get_next_item(txn);
                repeat(txn.delay) @(posedge rd_vif.clk);

                while (rd_vif.rd_empty) @(posedge rd_vif.clk);

                @(posedge rd_vif.clk);
                rd_vif.rd_cb.rd_en <= 1'b1;

                @(posedge rd_vif.clk);
                rd_vif.rd_cb.rd_en <= 1'b0;
                txn.data = rd_vif.rd_cb.rd_data;

                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    // FIFO Read Monitor
    // =========================================================================
    class fifo_rd_monitor extends uvm_monitor;
        `uvm_component_utils(fifo_rd_monitor)

        virtual fifo_rd_if rd_vif;
        uvm_analysis_port #(fifo_rd_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db#(virtual fifo_rd_if)::get(this, "", "rd_vif", rd_vif))
                `uvm_fatal("RD_MON", "Failed to get rd_vif")
        endfunction

        task run_phase(uvm_phase phase);
            fifo_rd_txn txn;
            forever begin
                @(posedge rd_vif.clk);
                if (rd_vif.mon_cb.rd_en && !rd_vif.mon_cb.rd_empty) begin
                    txn = fifo_rd_txn::type_id::create("rd_txn");
                    txn.data = rd_vif.mon_cb.rd_data;
                    ap.write(txn);
                    `uvm_info("RD_MON", txn.convert2string(), UVM_HIGH)
                end
            end
        endtask
    endclass

    // =========================================================================
    // Write Agent
    // =========================================================================
    class fifo_wr_agent extends uvm_agent;
        `uvm_component_utils(fifo_wr_agent)

        fifo_wr_driver  driver;
        fifo_wr_monitor monitor;
        uvm_sequencer #(fifo_wr_txn) sequencer;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = fifo_wr_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                driver    = fifo_wr_driver::type_id::create("driver", this);
                sequencer = uvm_sequencer#(fifo_wr_txn)::type_id::create("sequencer", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Read Agent
    // =========================================================================
    class fifo_rd_agent extends uvm_agent;
        `uvm_component_utils(fifo_rd_agent)

        fifo_rd_driver  driver;
        fifo_rd_monitor monitor;
        uvm_sequencer #(fifo_rd_txn) sequencer;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            monitor = fifo_rd_monitor::type_id::create("monitor", this);
            if (get_is_active() == UVM_ACTIVE) begin
                driver    = fifo_rd_driver::type_id::create("driver", this);
                sequencer = uvm_sequencer#(fifo_rd_txn)::type_id::create("sequencer", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (get_is_active() == UVM_ACTIVE)
                driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    // Analysis imp declarations (workaround for xsim UVM 1.2 multi-imp bug)
    // =========================================================================
    `uvm_analysis_imp_decl(_wr)
    `uvm_analysis_imp_decl(_rd)

    // =========================================================================
    // Scoreboard: Data Integrity Checker
    // =========================================================================
    class fifo_ddr_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(fifo_ddr_scoreboard)

        uvm_analysis_imp_wr #(fifo_wr_txn, fifo_ddr_scoreboard) wr_imp;
        uvm_analysis_imp_rd #(fifo_rd_txn, fifo_ddr_scoreboard) rd_imp;

        // Reference queue: expected data
        logic [63:0] expected_q[$];
        int unsigned match_count;
        int unsigned mismatch_count;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            wr_imp = new("wr_imp", this);
            rd_imp = new("rd_imp", this);
            match_count    = 0;
            mismatch_count = 0;
        endfunction

        // Capture writes as expected data
        function void write_wr(fifo_wr_txn txn);
            expected_q.push_back(txn.data);
            `uvm_info("SCB", $sformatf("WR captured: 0x%016h (queue size: %0d)",
                       txn.data, expected_q.size()), UVM_HIGH)
        endfunction

        // Check reads against expected
        function void write_rd(fifo_rd_txn txn);
            logic [63:0] exp;

            if (expected_q.size() == 0) begin
                `uvm_error("SCB", $sformatf("RD data 0x%016h received but expected queue empty!", txn.data))
                mismatch_count++;
                return;
            end

            exp = expected_q.pop_front();
            if (txn.data !== exp) begin
                `uvm_error("SCB", $sformatf("MISMATCH! Expected: 0x%016h Got: 0x%016h", exp, txn.data))
                mismatch_count++;
            end else begin
                match_count++;
                `uvm_info("SCB", $sformatf("MATCH #%0d: 0x%016h", match_count, txn.data), UVM_HIGH)
            end
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("SCB", $sformatf("SCOREBOARD SUMMARY: Matches=%0d Mismatches=%0d Remaining=%0d",
                match_count, mismatch_count, expected_q.size()), UVM_LOW)

            if (mismatch_count > 0 || expected_q.size() > 0)
                `uvm_error("SCB", "DATA INTEGRITY CHECK FAILED")
            else
                `uvm_info("SCB", "DATA INTEGRITY CHECK PASSED", UVM_LOW)
        endfunction
    endclass

    // =========================================================================
    // Environment
    // =========================================================================
    class fifo_ddr_env extends uvm_env;
        `uvm_component_utils(fifo_ddr_env)

        fifo_wr_agent       wr_agent;
        fifo_rd_agent       rd_agent;
        fifo_ddr_scoreboard scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            wr_agent   = fifo_wr_agent::type_id::create("wr_agent", this);
            rd_agent   = fifo_rd_agent::type_id::create("rd_agent", this);
            scoreboard = fifo_ddr_scoreboard::type_id::create("scoreboard", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            wr_agent.monitor.ap.connect(scoreboard.wr_imp);
            rd_agent.monitor.ap.connect(scoreboard.rd_imp);
        endfunction
    endclass

endpackage
