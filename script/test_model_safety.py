#!/usr/bin/env python3
"""Run offline model regressions with the shared app compilation cache."""
from app_regression import legacy_cli

if __name__ == "__main__":
    raise SystemExit(legacy_cli("model"))
