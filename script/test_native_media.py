#!/usr/bin/env python3
"""Run isolated native media regressions with the shared compilation cache."""
from app_regression import legacy_cli

if __name__ == "__main__":
    raise SystemExit(legacy_cli("native"))
