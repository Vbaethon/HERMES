#!/usr/bin/env python3
"""Run all three app regressions with a single cached compilation."""
import argparse
from app_regression import SUITES, cli

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suites", nargs="*", choices=tuple(SUITES), help="default: all three suites")
    parser.add_argument("--build-only", action="store_true", help="prepare or check the compilation cache without running tests")
    args = parser.parse_args()
    raise SystemExit(cli(args.suites or tuple(SUITES), build_only=args.build_only))
