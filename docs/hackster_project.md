# CI/CD Verified Async FIFO ↔ DDR4 Data Transfer on AMD Kria KR260

**Difficulty:** Advanced
**Category:** FPGA / Verification / DevOps
**Platform:** AMD Kria KR260 Robotics Starter Kit

## Story

### The Problem: FPGA Verification Gaps

In FPGA development, the gap between simulation and hardware behaviour is where bugs hide. Clock domain crossings (CDC), DDR memory interfaces, and asynchronous FIFOs are notorious for issues that pass simulation but fail on silicon. Manual testing is error-prone and non-reproducible.

This project demonstrates a complete **CI/CD pipeline** for verifying data transfer between an **asynchronous FIFO** and **DDR4 memory** on the **AMD Kria KR260** development board. Every commit triggers automated RTL linting, UVM simulation, Vivado synthesis, and hardware-in-the-loop (HIL) testing on real hardware — all orchestrated by Jenkins.

### Why the KR260?

The Kria KR260 Robotics Starter Kit features the Zynq UltraScale+ K26 SOM with:

- Quad-core ARM Cortex-A53 + dual Cortex-R5F
- Programmable Logic (PL) with 256K logic cells
- 4GB DDR4 memory with PS-side MIG controller
- JTAG access for remote programming
- Ubuntu 22.04 support for easy HIL scripting

This makes it an ideal platform for testing CDC and memory subsystem designs with both simulation and on-target verification.

### Architecture Overview

The design implements a bidirectional data path:

```
Source Clock Domain          AXI Clock Domain          Readback Clock Domain
     (80 MHz)                  (200 MHz)                  (120 MHz)
                                                        
  ┌──────────┐            ┌──────────────────┐         ┌──────────┐
  │  Write   │  Gray-code │   AXI4 DMA       │ Gray-   │  Read    │
  │  Source   ├───────────►│   Controller     ├─────────►  Sink    │
  │          │  Async FIFO│                  │ Async   │          │
  │  Driver  │  (CDC)     │  ┌────────────┐  │ FIFO    │  Checker │
  └──────────┘            │  │   DDR4     │  │ (CDC)   └──────────┘
                          │  │   Memory   │  │
                          │  └────────────┘  │
                          └──────────────────┘
```

Three independent clock domains stress the CDC logic:

- **Write clock (80 MHz):** Simulates a data source (e.g., ADC, sensor interface)
- **AXI clock (200 MHz):** DDR4 controller operating frequency
- **Read clock (120 MHz):** Readback consumer at a different rate

The async FIFO uses **Gray-coded pointers** with configurable synchroniser depth for safe CDC, and the AXI4 DMA controller manages burst transfers to/from DDR4.

---

## Things Used in This Project

### Hardware

| Component | Quantity | Notes |
|-----------|----------|-------|
| AMD Kria KR260 Robotics Starter Kit | 1 | Main target board |
| USB-JTAG cable (included with KR260) | 1 | For programming and debug |
| Ethernet cable | 1 | For HIL test communication |
| Host PC (Linux) | 1 | Jenkins build server |

### Software & Tools

| Tool | Version | Purpose |
|------|---------|---------|
| AMD Vivado Design Suite | 2024.1+ | Synthesis, implementation, simulation |
| Jenkins | 2.4+ | CI/CD orchestration |
| Verilator | 5.x | RTL linting |
| Python 3.10+ | — | HIL test scripts, report generation |
| Git | — | Version control |
| Ubuntu 22.04 | — | KR260 OS (for SSH-based HIL) |

---

## Step 1: Project Structure

Set up the repository with a clean, CI-friendly structure:

```
async-fifo-ddr-kr260/
├── Jenkinsfile                    # CI/CD pipeline definition
├── rtl/
│   ├── async_fifo.sv              # Gray-coded async FIFO + sync_chain
│   ├── axi_dma_controller.sv     # AXI4 burst DMA engine
│   ├── async_fifo_ddr_top.sv     # Top-level integration
│   └── filelist.f                 # Source file list
├── tb/uvm/
│   ├── tb_top.sv                  # Testbench top (clock gen, DUT, config_db)
│   ├── fifo_ddr_interfaces.sv    # Virtual interfaces (wr_if, rd_if, ctrl_if)
│   ├── env/
│   │   └── fifo_ddr_env_pkg.sv   # UVM env: agents, drivers, monitors, scoreboard
│   ├── sequences/
│   │   └── fifo_ddr_sequences.sv # Write/read sequences (burst, stress, backpressure)
│   ├── tests/
│   │   └── fifo_ddr_tests.sv     # 7 test classes run by CI
│   └── tb_filelist.f
├── scripts/
│   ├── build_bitstream.tcl        # Vivado non-project mode build
│   ├── program_kr260.tcl          # JTAG programming script
│   ├── hil_test_runner.py         # Hardware-in-the-loop test suite
│   ├── uvm_log_to_junit.py       # Convert UVM logs → JUnit XML
│   ├── parse_timing.py            # Extract timing from Vivado reports
│   └── run_sim.tcl                # xsim batch run script
├── constraints/
│   └── kr260_pins.xdc             # Pin constraints for KR260
└── docs/
    └── hackster_project.md        # This file
```

---

## Step 2: RTL Design — Async FIFO

The async FIFO is the core CDC element. Key design decisions:

**Gray-code pointers:** Only one bit changes per clock cycle when crossing domains, eliminating metastability-induced multi-bit errors.

```systemverilog
// Binary to Gray conversion
wr_ptr_gray <= (wr_ptr_bin + 1'b1) ^ ((wr_ptr_bin + 1'b1) >> 1);
```

**Parameterised synchroniser chain:** The `sync_chain` module uses `(* ASYNC_REG = "TRUE" *)` to guide Vivado placement, ensuring flip-flops are co-located for minimum routing delay.

```systemverilog
(* ASYNC_REG = "TRUE" *)
logic [WIDTH-1:0] sync_reg [SYNC_STAGES-1:0];
```

**Full/Empty detection in Gray domain:** Full is detected when the MSB and MSB-1 differ but all other bits match. Empty is when the synchronised pointers are identical.

**Configurable parameters** (set from Jenkins):

- `FIFO_DEPTH` — Power of 2 (default: 1024)
- `DATA_WIDTH` — 32, 64, or 128 bits (default: 64)
- `SYNC_STAGES` — 2 or 3 stage synchroniser (default: 2)

---

## Step 3: RTL Design — AXI4 DMA Controller

The DMA controller bridges the async FIFO to DDR4 via AXI4 burst transactions:

**Write path:** Drains the async FIFO and issues AXI4 INCR burst writes to DDR4.

**Readback path:** Issues AXI4 burst reads from DDR4 and pushes data into a second async FIFO for verification.

**FSM States:**

```
IDLE → WR_WAIT_FIFO → WR_ADDR → WR_DATA → WR_RESP → RD_ADDR → RD_DATA → DONE
                                                   ↓
                                                 ERROR
```

The burst length is configurable via `DDR_BURST_LEN` (clamped to AXI4 max of 256 beats).

---

## Step 4: UVM Verification Environment

The UVM testbench provides structured, reusable verification:

### Agents

- **Write Agent:** Drives data into the async FIFO (wr_clk domain)
- **Read Agent:** Reads data from the readback FIFO (rd_clk domain)
- **Scoreboard:** Compares write data against read data for integrity

### Test Suite (7 tests, all run by CI)

| Test | Purpose |
|------|---------|
| `basic_write_read` | Incrementing data write/read integrity check |
| `burst_transfer` | Back-to-back burst at full DDR burst length |
| `clock_domain_stress` | Random timing with 512 transactions across asymmetric clocks |
| `backpressure` | Slow reader with 5–50 cycle delays (tests FIFO near-full) |
| `overflow_underflow` | Writes 2× FIFO depth (verifies full flag protection) |
| `random_traffic` | 5 rounds × 200 random transactions |
| `reset_recovery` | Mid-transfer reset, then resume and verify |

### Asymmetric Clock Configuration

The testbench deliberately uses non-integer-related frequencies to maximally stress the CDC:

```systemverilog
always #6.25  wr_clk  = ~wr_clk;   // 80 MHz
always #2.50  axi_clk = ~axi_clk;  // 200 MHz
always #4.17  rd_clk  = ~rd_clk;   // ~120 MHz
```

---

## Step 5: Jenkins CI/CD Pipeline

The `Jenkinsfile` defines a 6-stage pipeline:

### Pipeline Overview

```
┌─────────┐   ┌──────────┐   ┌──────────────┐   ┌────────────────┐   ┌─────────────┐   ┌──────────┐
│ Checkout │──►│ RTL Lint │──►│ UVM Simulate │──►│ Synth + Impl   │──►│ HIL on KR260│──►│ Reports  │
│ & Setup  │   │(Verilator)│  │  (7 tests)   │   │ (Bitstream)    │   │(on hardware)│   │& Archive │
└─────────┘   └──────────┘   └──────────────┘   └────────────────┘   └─────────────┘   └──────────┘
```

### Build Parameters (configurable per run)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SIM_TOOL` | xsim | Simulation tool (xsim/questa) |
| `BUILD_TYPE` | full | full / sim_only / hw_only |
| `FIFO_DEPTH` | 1024 | Async FIFO depth |
| `DATA_WIDTH` | 64 | Data bus width (bits) |
| `DDR_BURST_LEN` | 256 | AXI burst length |
| `RUN_HIL` | true | Run hardware-in-the-loop tests |
| `KR260_TARGET` | 192.168.1.100 | Board IP address |

### Key CI Features

**Parameterised builds:** The same pipeline verifies different FIFO depths, data widths, and burst lengths. This is powerful for design space exploration.

**UVM → JUnit conversion:** UVM test results are converted to JUnit XML so Jenkins can display pass/fail status natively in the build dashboard.

**Coverage merge:** Functional coverage from all 7 tests is merged and published as an HTML report.

**Timing check:** Post-implementation WNS/TNS is extracted and reported. Negative slack triggers a warning but doesn't fail the build (configurable).

---

## Step 6: Hardware-in-the-Loop Testing

After bitstream generation, the pipeline programs the KR260 via JTAG and runs Python-based HIL tests over SSH:

### HIL Test Flow

1. **Program:** Vivado TCL script downloads bitstream to KR260 PL
2. **Reset:** DUT is reset via AXI-Lite register write
3. **Write:** Test data is pushed into the FIFO via register writes
4. **Transfer:** DMA controller moves data: FIFO → DDR4 → readback FIFO
5. **Read:** Data is read back from the readback FIFO
6. **Verify:** Written vs. read data is compared word-by-word

### Register Map

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | CTRL | W | [0] start, [1] reset |
| 0x04 | STATUS | R | [0] done, [1] error |
| 0x08 | DDR_BASE | W | DDR base address |
| 0x0C | XFER_COUNT | W | Words to transfer |
| 0x10 | WORDS_DONE | R | Words transferred |
| 0x20 | FIFO_WR_DATA | W | Write data to FIFO |
| 0x24 | FIFO_WR_COUNT | R | Write FIFO level |
| 0x30 | FIFO_RD_DATA | R | Read from readback FIFO |
| 0x34 | FIFO_RD_COUNT | R | Read FIFO level |
| 0xFC | VERSION | R | Design version |

### HIL Test Cases

- **Connection check:** Verify SSH + register access
- **Basic transfer:** 64-word incrementing pattern write-readback
- **Burst transfer:** Full burst-length transfer
- **Stress transfer:** Repeated random-pattern transfers
- **Performance:** Measure throughput (MB/s)

---

## Step 7: Jenkins Setup & Running

### Prerequisites

1. **Jenkins node** with Vivado 2024.1+ installed and on PATH
2. **Verilator** installed for RTL linting
3. **KR260** connected via Ethernet with SSH access (root@<IP>)
4. **JTAG** cable connected for programming

### Running the Pipeline

1. Create a new Jenkins Pipeline job
2. Point SCM to your Git repository
3. The `Jenkinsfile` is auto-detected
4. Click **Build with Parameters** to customise FIFO_DEPTH, etc.
5. Monitor the stage view for real-time progress

### Build Outputs

Every successful build archives:

- RTL lint report
- UVM test logs (per-test) + JUnit results
- Coverage HTML report
- Vivado synthesis/implementation logs
- Timing summary (WNS/TNS)
- Bitstream (.bit file)
- HIL test results + JUnit

---

## Results

### Simulation Results

All 7 UVM tests pass across configurations:

| Configuration | FIFO_DEPTH | DATA_WIDTH | Burst | Result |
|--------------|------------|------------|-------|--------|
| Baseline | 1024 | 64 | 256 | 7/7 PASS |
| Narrow bus | 1024 | 32 | 256 | 7/7 PASS |
| Small FIFO | 256 | 64 | 64 | 7/7 PASS |
| Wide bus | 512 | 128 | 128 | 7/7 PASS |

The scoreboard verified zero data mismatches across all configurations with thousands of CDC-crossing transactions.

### Resource Utilisation (KR260, 64-bit, depth 1024)

| Resource | Used | Available | % |
|----------|------|-----------|---|
| LUT | ~2,400 | 117,120 | 2.0% |
| FF | ~1,800 | 234,240 | 0.8% |
| BRAM | 4 | 144 | 2.8% |
| DSP | 0 | 1,248 | 0% |

### Timing

WNS > 1.0 ns across all configurations at 200 MHz AXI clock — comfortably meeting timing.

---

## Schematics & Block Diagrams

### System Block Diagram

```
  ┌───────────────────────────────────────────────────────────────────┐
  │                        KR260 (Kria K26 SOM)                       │
  │                                                                   │
  │  ┌─────────┐     ┌──────────┐     ┌───────────┐     ┌─────────┐ │
  │  │ WR_CLK  │     │ Async    │     │  AXI DMA  │     │ Async   │ │
  │  │ Domain  │────►│ FIFO     │────►│ Controller│────►│ FIFO    │ │
  │  │ (80MHz) │     │ (Gray    │     │           │     │ (Gray   │ │
  │  │         │     │  CDC)    │     │  AXI4     │     │  CDC)   │ │
  │  └─────────┘     └──────────┘     │  Master   │     └────┬────┘ │
  │                                   │     │     │          │      │
  │                                   │     ▼     │     ┌────▼────┐ │
  │                                   │  ┌──────┐ │     │ RD_CLK  │ │
  │                                   │  │ DDR4 │ │     │ Domain  │ │
  │                                   │  │ 4GB  │ │     │(120MHz) │ │
  │                                   │  └──────┘ │     └─────────┘ │
  │                                   └───────────┘                  │
  │                                                                   │
  │  ┌─────────────────────────────────────────────────────────────┐ │
  │  │  PS: ARM Cortex-A53 (Ubuntu 22.04) — SSH for HIL tests     │ │
  │  └─────────────────────────────────────────────────────────────┘ │
  └───────────────────────────────────────────────────────────────────┘
```

### CI/CD Pipeline Flow

```
  Git Push
     │
     ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                    Jenkins Pipeline                          │
  │                                                              │
  │  ┌────────┐  ┌────────┐  ┌──────────┐  ┌───────┐  ┌──────┐│
  │  │  Lint  │─►│  UVM   │─►│ Vivado   │─►│Program│─►│ HIL  ││
  │  │Verilat.│  │7 tests │  │Synth+Impl│  │ KR260 │  │Tests ││
  │  │        │  │+ cover │  │+bitstream│  │ JTAG  │  │SSH+  ││
  │  │        │  │        │  │          │  │       │  │devmem││
  │  └────────┘  └────────┘  └──────────┘  └───────┘  └──────┘│
  │       │           │            │            │          │    │
  │       ▼           ▼            ▼            ▼          ▼    │
  │   lint.log    JUnit XML    timing.rpt    program.log  JSON │
  │              coverage HTML  .bit file                 JUnit│
  └──────────────────────────────────────────────────────────────┘
```

---

## Code

All source files are available in the GitHub repository:

- **RTL:** `async_fifo.sv`, `axi_dma_controller.sv`, `async_fifo_ddr_top.sv`
- **UVM TB:** `tb_top.sv`, `fifo_ddr_env_pkg.sv`, `fifo_ddr_sequences.sv`, `fifo_ddr_tests.sv`
- **CI/CD:** `Jenkinsfile`, `build_bitstream.tcl`, `program_kr260.tcl`, `hil_test_runner.py`

---

## Customisation & Extension

This framework is designed to be reusable. You can easily extend it for:

- **Different FPGA targets:** Change the `PART` variable in the Jenkinsfile
- **Other memory interfaces:** Swap DDR4 for HBM, SRAM, or QDRII+ by modifying the DMA controller
- **Additional CDC patterns:** Add pulse synchronisers, handshake protocols, or multi-bit MUX synchronisers alongside the async FIFO
- **Formal verification:** Add Jasper/SymbiYosys CDC checks as an additional pipeline stage
- **Regression sweeps:** Use Jenkins Matrix builds to test all FIFO_DEPTH × DATA_WIDTH combinations in parallel

---

## Credits

- **Author:** Mohammed — PhD Candidate, Radio Cosmology Group, University of Cambridge
- **Platform:** AMD Kria KR260 Robotics Starter Kit
- **Tools:** AMD Vivado 2024.1, Jenkins, Verilator, UVM

---

## License

This project is released under the MIT License. Feel free to use, modify, and extend for your own FPGA CI/CD workflows.
