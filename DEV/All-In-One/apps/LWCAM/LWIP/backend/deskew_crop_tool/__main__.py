from __future__ import annotations

import argparse
from pathlib import Path

from .config import DEFAULT_CONFIG_PATH, load_config
from .orchestrator import FolderOrchestrator, configure_logging


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Watch incoming folders and run deskew followed by crop."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG_PATH,
        help="JSON configuration file",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Process currently ready folders, then exit",
    )
    parser.add_argument(
        "--wait",
        action="store_true",
        help="With --once, wait for current folders to become stable",
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.wait and not args.once:
        parser.error("--wait can only be used with --once")

    config = load_config(args.config)
    configure_logging(config, verbose=args.verbose)
    orchestrator = FolderOrchestrator(config)
    if args.once:
        processed = orchestrator.run_once(wait_for_stability=args.wait)
        print(f"Processed {processed} folder(s).")
        return 0
    orchestrator.run_forever(reload_config=lambda: load_config(args.config))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
