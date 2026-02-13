# Async FIFO ↔ DDR4 CI/CD Verification — AMD Kria KR260

[![Jenkins Build](https://img.shields.io/badge/CI%2FCD-Jenkins-blue)](https://jenkins.io)
[![Platform](https://img.shields.io/badge/Platform-KR260-green)](https://www.amd.com/en/products/system-on-modules/kria/k26/kr260-robotics-starter-kit.html)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

> **Published on [Hackster.io](https://www.hackster.io)** — Full project tutorial with step-by-step guide.

A complete CI/CD pipeline for verifying asynchronous FIFO ↔ DDR4 data transfers on the AMD Kria KR260. Features UVM simulation, Vivado synthesis, and hardware-in-the-loop testing — all automated via Jenkins.

## Quick Start

```bash
# Clone
git clone https://github.com/<your-username>/async-fifo-ddr-kr260.git
cd async-fifo-ddr-kr260

# Run UVM simulation locally (requires Vivado)
source /tools/Xilinx/Vivado/2024.1/settings64.sh
cd sim
xvlog -sv +define+FIFO_DEPTH=1024 +define+DATA_WIDTH=64 +define+DDR_BURST_LEN=256 \
    -L uvm -f ../rtl/filelist.f -f ../tb/uvm/tb_filelist.f
xelab tb_top -relax -s sim_snapshot -L uvm -timescale 1ns/1ps
xsim sim_snapshot -testplusarg "UVM_TESTNAME=fifo_ddr_basic_write_read_test" \
    -testplusarg "UVM_VERBOSITY=UVM_MEDIUM"
```

## Architecture

```
WR_CLK (80MHz) ──► Async FIFO (Gray CDC) ──► AXI4 DMA ──► DDR4 (4GB)
                                                  │
DDR4 ──► AXI4 DMA ──► Async FIFO (Gray CDC) ──► RD_CLK (120MHz)
```

Three independent clock domains maximally stress CDC logic. The AXI DMA controller manages burst transfers with configurable depth, width, and burst length.

## CI/CD Pipeline (Jenkins)

| Stage | Tool | Output |
|-------|------|--------|
| RTL Lint | Verilator | lint_report.log |
| UVM Simulation | xsim (7 tests) | JUnit XML + coverage HTML |
| Synthesis + Impl | Vivado 2024.1 | Bitstream + timing report |
| Program KR260 | Vivado JTAG | program.log |
| HIL Tests | Python + SSH | JUnit XML + results JSON |

### Jenkins Parameters

```
FIFO_DEPTH    = 1024        # Power of 2
DATA_WIDTH    = 64          # 32, 64, or 128
DDR_BURST_LEN = 256         # Max 256 (AXI4)
BUILD_TYPE    = full         # full | sim_only | hw_only
RUN_HIL       = true         # Hardware-in-the-loop
KR260_TARGET  = 192.168.1.100
```

## UVM Test Suite

| Test | Description |
|------|-------------|
| `fifo_ddr_basic_write_read_test` | Incrementing data integrity |
| `fifo_ddr_burst_transfer_test` | Full burst-length transfer |
| `fifo_ddr_clock_domain_stress_test` | 512 txns, random timing |
| `fifo_ddr_backpressure_test` | Slow reader (5–50 cycle delays) |
| `fifo_ddr_overflow_underflow_test` | 2× FIFO depth (full flag test) |
| `fifo_ddr_random_traffic_test` | 5 × 200 random transactions |
| `fifo_ddr_reset_recovery_test` | Mid-transfer reset + resume |

## Project Structure

```
├── Jenkinsfile                    # CI/CD pipeline
├── rtl/                           # Synthesisable RTL
│   ├── async_fifo.sv              # Gray-coded async FIFO
│   ├── axi_dma_controller.sv     # AXI4 burst DMA
│   └── async_fifo_ddr_top.sv     # Top-level
├── tb/uvm/                        # UVM verification
│   ├── tb_top.sv                  # TB top + clock gen
│   ├── env/                       # Agents, scoreboard
│   ├── sequences/                 # Test sequences
│   └── tests/                     # Test classes
├── scripts/                       # Build & test automation
│   ├── build_bitstream.tcl        # Vivado batch build
│   ├── program_kr260.tcl          # JTAG programming
│   └── hil_test_runner.py         # HIL test suite
├── constraints/                   # KR260 pin constraints
└── docs/                          # Hackster write-up
```

## Prerequisites

- AMD Vivado 2024.1+
- Jenkins 2.4+ with Pipeline plugin
- Verilator 5.x
- Python 3.10+ (paramiko for SSH)
- KR260 with Ubuntu 22.04 and network access

## License

MIT — see [LICENSE](LICENSE) for details.
