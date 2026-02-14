#!/usr/bin/env python3
"""Generate HTML build report from results."""
import argparse
import os
import json
from datetime import datetime

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results-dir', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)

    # Collect results
    test_summary = []
    summary_file = os.path.join(args.results_dir, 'test_summary.txt')
    if os.path.exists(summary_file):
        with open(summary_file) as f:
            for line in f:
                line = line.strip()
                if line:
                    test_summary.append(line)

    timing = {}
    timing_file = os.path.join(args.results_dir, 'timing_results.json')
    if os.path.exists(timing_file):
        with open(timing_file) as f:
            timing = json.load(f)

    hil_results = []
    hil_file = os.path.join(args.results_dir, 'hil', 'results.json')
    if os.path.exists(hil_file):
        with open(hil_file) as f:
            hil_results = json.load(f)

    # Generate HTML
    html = f"""<!DOCTYPE html>
<html>
<head>
    <title>Build Report - {datetime.now().strftime('%Y-%m-%d %H:%M')}</title>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }}
        h1 {{ color: #333; }}
        h2 {{ color: #555; border-bottom: 2px solid #ddd; padding-bottom: 5px; }}
        .pass {{ color: #2e7d32; font-weight: bold; }}
        .fail {{ color: #c62828; font-weight: bold; }}
        table {{ border-collapse: collapse; width: 100%; margin: 10px 0; }}
        th, td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        th {{ background: #4a90d9; color: white; }}
        tr:nth-child(even) {{ background: #f2f2f2; }}
        .card {{ background: white; padding: 20px; margin: 10px 0; border-radius: 5px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
    </style>
</head>
<body>
    <h1>Async FIFO + DDR CI/CD Build Report</h1>
    <p>Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>

    <div class="card">
        <h2>UVM Simulation Results</h2>
        <table>
            <tr><th>Test</th><th>Result</th></tr>
"""
    for line in test_summary:
        status = "PASS" if line.startswith("PASS") else "FAIL"
        css_class = "pass" if status == "PASS" else "fail"
        test_name = line.split(":", 1)[1].strip() if ":" in line else line
        html += f'            <tr><td>{test_name}</td><td class="{css_class}">{status}</td></tr>\n'

    if not test_summary:
        html += '            <tr><td colspan="2">No test results available</td></tr>\n'

    html += """        </table>
    </div>

    <div class="card">
        <h2>Timing Summary</h2>
        <table>
            <tr><th>Metric</th><th>Value</th></tr>
"""
    html += f'            <tr><td>WNS (ns)</td><td>{timing.get("wns", "N/A")}</td></tr>\n'
    html += f'            <tr><td>TNS (ns)</td><td>{timing.get("tns", "N/A")}</td></tr>\n'
    met = timing.get("timing_met", "N/A")
    css = "pass" if met else "fail"
    html += f'            <tr><td>Timing Met</td><td class="{css}">{met}</td></tr>\n'

    html += """        </table>
    </div>

    <div class="card">
        <h2>Hardware-in-the-Loop Results</h2>
        <table>
            <tr><th>Test</th><th>Result</th><th>Duration (ms)</th><th>Details</th></tr>
"""
    for r in hil_results:
        status = "PASS" if r.get("passed") else "FAIL"
        css_class = "pass" if r.get("passed") else "fail"
        html += f'            <tr><td>{r.get("name","")}</td><td class="{css_class}">{status}</td>'
        html += f'<td>{r.get("duration_ms",0):.1f}</td><td>{r.get("details","")}</td></tr>\n'

    if not hil_results:
        html += '            <tr><td colspan="4">No HIL results available</td></tr>\n'

    html += """        </table>
    </div>
</body>
</html>"""

    with open(args.output, 'w') as f:
        f.write(html)

    print(f"Report generated: {args.output}")

if __name__ == "__main__":
    main()
