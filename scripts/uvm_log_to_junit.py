#!/usr/bin/env python3
"""Convert UVM test summary to JUnit XML for Jenkins."""
import sys
import os

def main():
    if len(sys.argv) < 3:
        print("Usage: uvm_log_to_junit.py <summary.txt> <output.xml>")
        sys.exit(1)

    summary_file = sys.argv[1]
    output_file = sys.argv[2]

    tests = []
    if os.path.exists(summary_file):
        with open(summary_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith("PASS:"):
                    tests.append((line.split(":", 1)[1].strip(), True))
                elif line.startswith("FAIL:"):
                    tests.append((line.split(":", 1)[1].strip(), False))

    os.makedirs(os.path.dirname(output_file) or '.', exist_ok=True)

    with open(output_file, 'w') as f:
        total = len(tests)
        failures = sum(1 for _, passed in tests if not passed)
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write(f'<testsuite name="UVM" tests="{total}" failures="{failures}">\n')
        for name, passed in tests:
            if passed:
                f.write(f'  <testcase name="{name}" classname="uvm"/>\n')
            else:
                f.write(f'  <testcase name="{name}" classname="uvm">\n')
                f.write(f'    <failure message="UVM test failed"/>\n')
                f.write(f'  </testcase>\n')
        if not tests:
            f.write('  <testcase name="no_tests_run" classname="uvm"/>\n')
        f.write('</testsuite>\n')

    print(f"Generated {output_file}: {total} tests, {failures} failures")

if __name__ == "__main__":
    main()
