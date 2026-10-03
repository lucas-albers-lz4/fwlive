#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Create a disposable helper with the enable-no-op generation bump removed."""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
source = args.source.read_text()
start = source.index("enable_wan_logging() {")
end = source.index("disable_wan_logging() {", start)
block = source[start:end]
needle = "if ! wan_log_generation_bump >/dev/null; then"
if block.count(needle) != 1:
    parser.error("expected exactly one enable no-op generation bump to mutate")
args.output.write_text(source[:start] + block.replace(needle, "if ! true; then", 1) + source[end:])
