from __future__ import annotations

import argparse
from pathlib import Path

from .console import run


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Sweep published export packages to S3 and serve the upload console."
    )
    parser.add_argument("--config", type=Path, required=True, help="JSON configuration file")
    args = parser.parse_args()
    return run(args.config)


if __name__ == "__main__":
    raise SystemExit(main())
