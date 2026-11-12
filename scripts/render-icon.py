#!/usr/bin/env python3
"""Keep the packaging entry point; render the standard T+ mark with native AppKit."""
from pathlib import Path
import subprocess
import sys


def main() -> int:
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("dist/Typemore-icon.png")
    output.parent.mkdir(parents=True, exist_ok=True)
    renderer = Path(__file__).with_suffix(".swift")
    subprocess.run(["swift", str(renderer), str(output.resolve())], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
