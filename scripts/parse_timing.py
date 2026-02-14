#!/usr/bin/env python3
"""Parse Vivado timing report and extract WNS/TNS."""
import sys
import os
import json
import re

def main():
    if len(sys.argv) < 3:
        print("Usage: parse_timing.py <timing_report.rpt> <output.json>")
        sys.exit(1)

    rpt_file = sys.argv[1]
    output_file = sys.argv[2]

    results = {"wns": None, "tns": None, "timing_met": False}

    if not os.path.exists(rpt_file):
        print(f"Warning: Timing report not found: {rpt_file}")
        with open(output_file, 'w') as f:
            json.dump(results, f, indent=2)
        return

    with open(rpt_file) as f:
        content = f.read()

    wns_match = re.search(r'WNS\(ns\)\s*:\s*([-\d.]+)', content)
    tns_match = re.search(r'TNS\(ns\)\s*:\s*([-\d.]+)', content)

    if wns_match:
        results["wns"] = float(wns_match.group(1))
    if tns_match:
        results["tns"] = float(tns_match.group(1))

    if results["wns"] is not None:
        results["timing_met"] = results["wns"] >= 0

    os.makedirs(os.path.dirname(output_file) or '.', exist_ok=True)
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)

    print(f"WNS: {results['wns']} ns")
    print(f"TNS: {results['tns']} ns")
    print(f"Timing met: {results['timing_met']}")

if __name__ == "__main__":
    main()
