#!/usr/bin/env python3
"""
Performance, Quality & Statistics Tester for farmer/EggGoToUI_v10.lua
Analyzes AST syntax validity, Luau register limits, line counts, duplicate definitions,
and repetitive code patterns. Saves and compares stats before and after refactoring.
"""

import os
import sys
import json
import re
import time
from typing import Dict, Any

try:
    import luaparser.ast as ast
    import luaparser.astnodes as nodes
    LUAPARSER_AVAILABLE = True
except ImportError:
    LUAPARSER_AVAILABLE = False


TARGET_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "farmer", "EggGoToUI_v10.lua"))
STATS_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "baseline_stats.json"))
LOG_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "test_run.log"))


def log_print(msg: str, log_fp=None):
    print(msg)
    if log_fp:
        log_fp.write(msg + "\n")


def analyze_code(file_path: str) -> Dict[str, Any]:
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"Target file not found: {file_path}")

    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    lines = content.splitlines()
    total_lines = len(lines)
    blank_lines = sum(1 for line in lines if not line.strip())
    comment_lines = sum(1 for line in lines if line.strip().startswith("--"))
    code_lines = total_lines - blank_lines - comment_lines
    file_bytes = len(content.encode("utf-8"))

    # 1. AST Syntax validation
    ast_valid = False
    ast_error = None
    if LUAPARSER_AVAILABLE:
        try:
            tree = ast.parse(content)
            ast_valid = True
        except Exception as e:
            ast_valid = False
            ast_error = str(e)
    else:
        ast_error = "luaparser not installed"

    # 2. Count top-level locals (Luau register limit = 200)
    top_level_locals = 0
    for line in lines:
        if line.startswith("local ") and not line.startswith("local function"):
            top_level_locals += 1

    # 3. Detect duplicate function definitions
    # Regex for function declarations
    func_pattern = re.compile(r'^\s*(?:local\s+function|function)\s+([a-zA-Z0-9_\.:]+)', re.MULTILINE)
    all_funcs = func_pattern.findall(content)
    func_counts = {}
    for fn in all_funcs:
        # leaf name
        leaf = fn.split(".")[-1].split(":")[-1]
        func_counts[leaf] = func_counts.get(leaf, 0) + 1

    duplicate_functions = {k: v for k, v in func_counts.items() if v > 1}

    # 4. Count repetitive patterns
    # (a) getNetRemote definitions
    net_remote_defs = len(re.findall(r'(?:local\s+function|function)\s+(?:X\.)?getNetRemote', content))
    # (b) formatPetWeight definitions
    pet_weight_defs = len(re.findall(r'(?:local\s+function|function)\s+(?:X\.)?formatPetWeight', content))
    # (c) formatCommas definitions
    format_commas_defs = len(re.findall(r'(?:local\s+function|function)\s+(?:X\.)?formatCommas', content))
    # (d) Temporary Vector3 allocations for XZ distance: Vector3.new(..., 0, ...).Magnitude
    xz_vector_allocs = len(re.findall(r'Vector3\.new\([^,]+,\s*0,\s*[^)]+\)\.Magnitude', content))
    # (e) LocalPlayer.Character + HumanoidRootPart retrieval boilerplates
    char_root_lookups = len(re.findall(r'LocalPlayer\.Character.*?FindFirstChild\(\"HumanoidRootPart\"\)', content))
    # (f) Repeated comma insertion while-loops
    comma_while_loops = len(re.findall(r'string\.gsub\(.*?%\^?\(-?\?%d\+\)\(%d%d%d\)', content))

    # 5. Functions exported on X table
    x_funcs = re.findall(r'function\s+X\.([a-zA-Z0-9_]+)', content)

    return {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "file": file_path,
        "ast_valid": ast_valid,
        "ast_error": ast_error,
        "total_lines": total_lines,
        "code_lines": code_lines,
        "blank_lines": blank_lines,
        "comment_lines": comment_lines,
        "file_bytes": file_bytes,
        "top_level_locals": top_level_locals,
        "duplicate_function_names": duplicate_functions,
        "net_remote_definitions": net_remote_defs,
        "pet_weight_definitions": pet_weight_defs,
        "format_commas_definitions": format_commas_defs,
        "xz_vector3_allocations": xz_vector_allocs,
        "char_root_lookups": char_root_lookups,
        "x_exported_functions_count": len(set(x_funcs)),
        "x_exported_functions": sorted(list(set(x_funcs))),
    }


def compare_stats(baseline: Dict[str, Any], current: Dict[str, Any], log_fp=None) -> bool:
    all_passed = True

    log_print("\n" + "=" * 80, log_fp)
    log_print("  AUDIT COMPARISON REPORT: BASELINE vs CURRENT UPDATE", log_fp)
    log_print("=" * 80, log_fp)

    # 1. AST Validation
    ast_status = "PASS" if current["ast_valid"] else "FAIL"
    if not current["ast_valid"]:
        all_passed = False
    log_print(f"[*] AST Syntax Validity:        {current['ast_valid']} ({ast_status})", log_fp)
    if current["ast_error"]:
        log_print(f"    Error: {current['ast_error']}", log_fp)

    # 2. Luau Local Limit (Max 200)
    loc_b = baseline["top_level_locals"]
    loc_c = current["top_level_locals"]
    loc_status = "PASS (<= 200)" if loc_c <= 200 else "FAIL (> 200 EXCEEDED!)"
    if loc_c > 200:
        all_passed = False
    log_print(f"[*] Top-level Locals (Luau Limit): Baseline={loc_b} | Current={loc_c} ({loc_status})", log_fp)

    # Table of optimization metrics
    metrics = [
        ("Total Lines", baseline["total_lines"], current["total_lines"], "lower_or_equal"),
        ("Non-comment Code Lines", baseline["code_lines"], current["code_lines"], "lower_or_equal"),
        ("File Bytes", baseline["file_bytes"], current["file_bytes"], "lower_or_equal"),
        ("NetRemote Definitions", baseline["net_remote_definitions"], current["net_remote_definitions"], "lower"),
        ("FormatPetWeight Definitions", baseline["pet_weight_definitions"], current["pet_weight_definitions"], "lower"),
        ("XZ Vector3 Allocations", baseline["xz_vector3_allocations"], current["xz_vector3_allocations"], "lower_or_equal"),
        ("Char/RootPart Lookups", baseline["char_root_lookups"], current["char_root_lookups"], "lower_or_equal"),
        ("Exported Functions on X", baseline["x_exported_functions_count"], current["x_exported_functions_count"], "higher_or_equal"),
    ]

    log_print("\n{:<32} {:>10} {:>10} {:>10} {:>12}".format("Metric", "Baseline", "Current", "Delta", "Status"), log_fp)
    log_print("-" * 80, log_fp)

    for name, b_val, c_val, goal in metrics:
        delta = c_val - b_val
        delta_str = f"{delta:+d}" if delta != 0 else "0"
        status = "OK"

        if goal == "lower":
            if c_val < b_val:
                status = "OPTIMIZED"
            elif c_val == b_val:
                status = "EQUAL"
            else:
                status = "REGRESSED"
                all_passed = False
        elif goal == "lower_or_equal":
            if c_val <= b_val:
                status = "OPTIMIZED" if c_val < b_val else "EQUAL"
            else:
                status = "EXPANDED"
        elif goal == "higher_or_equal":
            if c_val >= b_val:
                status = "OPTIMIZED" if c_val > b_val else "EQUAL"
            else:
                status = "REDUCED"
                all_passed = False

        log_print("{:<32} {:>10} {:>10} {:>10} {:>12}".format(name, b_val, c_val, delta_str, status), log_fp)

    log_print("-" * 80, log_fp)
    log_print(f"Overall Optimization Verdict: {'ALL CHECKS PASSED (OPTIMIZED OR EQUAL)' if all_passed else 'REGRESSION DETECTED'}\n", log_fp)
    return all_passed


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Audit and test farmer/EggGoToUI_v10.lua stats")
    parser.add_argument("--save-baseline", action="store_true", help="Save current stats as baseline")
    parser.add_argument("--compare", action="store_true", help="Compare current stats against saved baseline")
    args = parser.parse_args()

    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    with open(LOG_FILE, "a", encoding="utf-8") as log_fp:
        log_print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Running Code Analysis on {TARGET_FILE}", log_fp)
        stats = analyze_code(TARGET_FILE)

        # Print current stats
        log_print("\n" + "=" * 80, log_fp)
        log_print("  CURRENT CODE STATISTICS", log_fp)
        log_print("=" * 80, log_fp)
        log_print(f"File:                      {stats['file']}", log_fp)
        log_print(f"AST Valid:                 {stats['ast_valid']} (Error: {stats['ast_error']})", log_fp)
        log_print(f"Total Lines:               {stats['total_lines']}", log_fp)
        log_print(f"Code Lines:                {stats['code_lines']}", log_fp)
        log_print(f"Comment Lines:             {stats['comment_lines']}", log_fp)
        log_print(f"File Size (bytes):         {stats['file_bytes']}", log_fp)
        log_print(f"Top-level Locals:          {stats['top_level_locals']} / 200 (limit)", log_fp)
        log_print(f"Duplicate Function Names:  {json.dumps(stats['duplicate_function_names'])}", log_fp)
        log_print(f"getNetRemote Definitions:  {stats['net_remote_definitions']}", log_fp)
        log_print(f"formatPetWeight Defs:      {stats['pet_weight_definitions']}", log_fp)
        log_print(f"formatCommas Defs:         {stats['format_commas_definitions']}", log_fp)
        log_print(f"Vector3 XZ Allocations:    {stats['xz_vector3_allocations']}", log_fp)
        log_print(f"Char/RootPart Lookups:     {stats['char_root_lookups']}", log_fp)
        log_print(f"Exported X Functions:      {stats['x_exported_functions_count']}", log_fp)

        if args.save_baseline or not os.path.exists(STATS_FILE):
            with open(STATS_FILE, "w", encoding="utf-8") as f:
                json.dump(stats, f, indent=2)
            log_print(f"\n[+] Saved baseline stats to {STATS_FILE}", log_fp)

        if args.compare or (os.path.exists(STATS_FILE) and not args.save_baseline):
            with open(STATS_FILE, "r", encoding="utf-8") as f:
                baseline = json.load(f)
            passed = compare_stats(baseline, stats, log_fp)
            if not passed:
                sys.exit(1)

        # Run runtime benchmark simulation report
        try:
            from benchmark_optimizations import run_benchmark
            run_benchmark()
        except ImportError:
            pass


if __name__ == "__main__":
    main()
