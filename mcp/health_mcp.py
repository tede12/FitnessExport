#!/usr/bin/env python3
"""Run the source checkout without installing the package."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from fitness_health.server import main

if __name__ == "__main__":
    main()
