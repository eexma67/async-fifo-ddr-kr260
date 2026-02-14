#!/usr/bin/env python3
"""
hil_test_runner.py - Hardware-in-the-Loop Test Runner for KR260
Tests async FIFO <-> DDR4 data transfer on actual hardware.
Uses SSH + devmem2 for register access.
"""

import argparse
import json
import os
import sys
import time
import subprocess
from dataclasses import dataclass, asdict
from typing import List

# Register Map
BASE_ADDR         = 0xA000_0000
REG_CTRL          = 0x00
REG_STATUS        = 0x04
REG_DDR_BASE      = 0x08
REG_XFER_COUNT    = 0x0C
REG_WORDS_DONE    = 0x10
REG_FIFO_WR_DATA  = 0x20
REG_FIFO_WR_COUNT = 0x24
REG_FIFO_RD_DATA  = 0x30
REG_FIFO_RD_COUNT = 0x34
REG_VERSION       = 0xFC


@dataclass
class TestResult:
    name: str
    passed: bool
    duration_ms: float
    details: str
    data_written: int = 0
    data_read: int = 0
    mismatches: int = 0


class KR260Interface:
    """Interface to KR260 board via SSH + sudo devmem2."""

    def __init__(self, target_ip: str, user: str = "ubuntu"):
        self.target = target_ip
        self.user = user
        self.ssh_prefix = f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 {user}@{target_ip}"

    def _run(self, cmd: str, timeout: int = 30) -> str:
        full_cmd = f'{self.ssh_prefix} "{cmd}"'
        try:
            result = subprocess.run(
                full_cmd, shell=True, capture_output=True, text=True, timeout=timeout
            )
            if result.returncode != 0:
                raise RuntimeError(f"Command failed: {cmd}\nstderr: {result.stderr}")
            return result.stdout.strip()
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Command timed out: {cmd}")

    def write_reg(self, offset: int, value: int):
        addr = BASE_ADDR + offset
        self._run(f"sudo devmem2 0x{addr:08X} w 0x{value:08X}")

    def read_reg(self, offset: int) -> int:
        addr = BASE_ADDR + offset
        output = self._run(f"sudo devmem2 0x{addr:08X} w")
        for line in output.split('\n'):
            if 'Value' in line and ':' in line:
                hex_val = line.split(':')[-1].strip()
                return int(hex_val, 16)
        raise RuntimeError(f"Could not parse devmem2 output: {output}")

    def write_fifo(self, data: List[int]):
        for word in data:
            self.write_reg(REG_FIFO_WR_DATA, word & 0xFFFFFFFF)

    def read_fifo(self, count: int) -> List[int]:
        result = []
        for _ in range(count):
            try:
                rd_count = self.read_reg(REG_FIFO_RD_COUNT)
                if rd_count == 0:
                    break
                result.append(self.read_reg(REG_FIFO_RD_DATA))
            except Exception:
                break
        return result

    def reset(self):
        self.write_reg(REG_CTRL, 0x2)
        time.sleep(0.01)
        self.write_reg(REG_CTRL, 0x0)
        time.sleep(0.01)

    def start_transfer(self, ddr_base: int, count: int):
        self.write_reg(REG_DDR_BASE, ddr_base)
        self.write_reg(REG_XFER_COUNT, count)
        self.write_reg(REG_CTRL, 0x1)

    def wait_transfer(self, timeout_s: float = 5.0) -> bool:
        t0 = time.time()
        while (time.time() - t0) < timeout_s:
            status = self.read_reg(REG_STATUS)
            if status & 0x1:
                return (status & 0x2) == 0
            time.sleep(0.01)
        return False

    def check_connection(self) -> bool:
        try:
            output = self._run("echo connected")
            return "connected" in output
        except Exception as e:
            print(f"  Connection failed: {e}")
            return False


def test_connection(kr260: KR260Interface) -> TestResult:
    t0 = time.time()
    try:
        ok = kr260.check_connection()
        duration = (time.time() - t0) * 1000
        return TestResult(
            name="connection_check",
            passed=ok,
            duration_ms=duration,
            details="Board connection verified" if ok else "Cannot reach KR260"
        )
    except Exception as e:
        return TestResult("connection_check", False, 0, str(e))


def test_register_access(kr260: KR260Interface) -> TestResult:
    t0 = time.time()
    try:
        ver = kr260.read_reg(REG_VERSION)
        duration = (time.time() - t0) * 1000
        return TestResult(
            name="register_access",
            passed=True,
            duration_ms=duration,
            details=f"Version register: 0x{ver:08X}"
        )
    except Exception as e:
        duration = (time.time() - t0) * 1000
        return TestResult("register_access", False, duration, str(e))


def test_basic_transfer(kr260: KR260Interface, fifo_depth: int) -> TestResult:
    t0 = time.time()
    count = min(16, fifo_depth)
    mismatches = 0

    try:
        kr260.reset()
        wr_data = [0xDEAD0000 + i for i in range(count)]
        kr260.write_fifo(wr_data)
        kr260.start_transfer(ddr_base=0x1000_0000, count=count)

        if not kr260.wait_transfer(timeout_s=5.0):
            return TestResult("basic_transfer", False, (time.time()-t0)*1000,
                            "Transfer timeout or error", count, 0, count)

        time.sleep(0.1)
        rd_data = kr260.read_fifo(count)

        for i in range(min(len(wr_data), len(rd_data))):
            if wr_data[i] != rd_data[i]:
                mismatches += 1

        if len(rd_data) < count:
            mismatches += count - len(rd_data)

        duration = (time.time() - t0) * 1000
        passed = mismatches == 0
        return TestResult(
            name="basic_transfer",
            passed=passed,
            duration_ms=duration,
            details=f"Wrote {count}, read {len(rd_data)}, mismatches {mismatches}",
            data_written=count,
            data_read=len(rd_data),
            mismatches=mismatches
        )
    except Exception as e:
        duration = (time.time() - t0) * 1000
        return TestResult("basic_transfer", False, duration, str(e))


def test_burst_transfer(kr260: KR260Interface, burst_len: int) -> TestResult:
    t0 = time.time()
    count = min(burst_len, 64)

    try:
        kr260.reset()
        wr_data = [0xCAFE0000 + i for i in range(count)]
        kr260.write_fifo(wr_data)
        kr260.start_transfer(ddr_base=0x2000_0000, count=count)

        if not kr260.wait_transfer(timeout_s=10.0):
            return TestResult("burst_transfer", False, (time.time()-t0)*1000,
                            "Transfer timeout", count, 0, count)

        time.sleep(0.2)
        rd_data = kr260.read_fifo(count)
        mismatches = sum(1 for i in range(min(len(wr_data), len(rd_data)))
                        if wr_data[i] != rd_data[i])

        duration = (time.time() - t0) * 1000
        return TestResult(
            name="burst_transfer",
            passed=mismatches == 0 and len(rd_data) == count,
            duration_ms=duration,
            details=f"Burst {count} words, mismatches {mismatches}",
            data_written=count,
            data_read=len(rd_data),
            mismatches=mismatches
        )
    except Exception as e:
        return TestResult("burst_transfer", False, (time.time()-t0)*1000, str(e))


def main():
    parser = argparse.ArgumentParser(description='KR260 HIL Test Runner')
    parser.add_argument('--target', required=True, help='KR260 IP address')
    parser.add_argument('--user', default='ubuntu', help='SSH username')
    parser.add_argument('--fifo-depth', type=int, default=1024)
    parser.add_argument('--data-width', type=int, default=64)
    parser.add_argument('--burst-len', type=int, default=256)
    parser.add_argument('--output-dir', default='results/hil')
    parser.add_argument('--tests', default='all', help='Test to run: all, connection, basic, burst')
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    print("=" * 60)
    print("  KR260 Hardware-in-the-Loop Test Runner")
    print(f"  Target:     {args.user}@{args.target}")
    print(f"  FIFO Depth: {args.fifo_depth}")
    print(f"  Data Width: {args.data_width}")
    print(f"  Burst Len:  {args.burst_len}")
    print("=" * 60)

    kr260 = KR260Interface(args.target, args.user)
    results = []

    test_map = {
        'connection': lambda: test_connection(kr260),
        'register': lambda: test_register_access(kr260),
        'basic': lambda: test_basic_transfer(kr260, args.fifo_depth),
        'burst': lambda: test_burst_transfer(kr260, args.burst_len),
    }

    if args.tests == 'all':
        tests_to_run = list(test_map.keys())
    else:
        tests_to_run = [args.tests]

    for test_name in tests_to_run:
        if test_name in test_map:
            print(f"\n--- Running: {test_name} ---")
            result = test_map[test_name]()
            results.append(result)
            status = "PASS" if result.passed else "FAIL"
            print(f"  [{status}] {result.name}: {result.details} ({result.duration_ms:.1f}ms)")

            # Stop on connection failure
            if test_name == 'connection' and not result.passed:
                print("Connection failed, skipping remaining tests")
                break

    # Save results
    results_file = os.path.join(args.output_dir, 'results.json')
    with open(results_file, 'w') as f:
        json.dump([asdict(r) for r in results], f, indent=2)

    # Generate JUnit XML
    junit_file = os.path.join(args.output_dir, 'hil_results.xml')
    total = len(results)
    failures = sum(1 for r in results if not r.passed)
    with open(junit_file, 'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write(f'<testsuite name="HIL" tests="{total}" failures="{failures}">\n')
        for r in results:
            if r.passed:
                f.write(f'  <testcase name="{r.name}" classname="hil" time="{r.duration_ms/1000:.3f}"/>\n')
            else:
                f.write(f'  <testcase name="{r.name}" classname="hil" time="{r.duration_ms/1000:.3f}">\n')
                f.write(f'    <failure message="{r.details}"/>\n')
                f.write(f'  </testcase>\n')
        f.write('</testsuite>\n')

    # Summary
    print("\n" + "=" * 60)
    print(f"  RESULTS: {total - failures}/{total} passed")
    print("=" * 60)

    sys.exit(1 if failures > 0 else 0)


if __name__ == "__main__":
    main()
