"""`python -m color_cal_tool --image ... --out ... --result ...`

Always writes ONE JSON object to `--result`. stdout is best-effort only: the
Dart side launches this with `pythonw.exe` (D12), which has no console to
write to, so nothing may depend on stdout landing anywhere. Logging goes to
stderr instead.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from .calibrate import calibrate
from .profile import write_profile

logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
LOGGER = logging.getLogger("color_cal_tool")

# Exit codes: 0 ok; 2 for a detection/fit outcome manual corners or --force
# may fix; 3 for a caller/environment problem neither can fix.
_EXIT_CODE_BY_ERROR_CODE = {
    "no_chart_found": 2,
    "low_confidence": 2,
    "clipped_patches": 2,
    "chart_mismatch": 2,
    "fit_failed": 2,
    "bad_arguments": 3,
    "io_error": 3,
}


def _parse_corners(value: str) -> list[tuple[float, float]]:
    parts = [p.strip() for p in value.split(",")]
    if len(parts) != 8:
        raise ValueError("--corners must be 8 comma-separated numbers: x1,y1,x2,y2,x3,y3,x4,y4")
    try:
        numbers = [float(p) for p in parts]
    except ValueError as exc:
        raise ValueError(f"--corners must be numeric: {exc}") from exc
    return [(numbers[i], numbers[i + 1]) for i in range(0, 8, 2)]


def _parse_inset(value: str) -> dict:
    parts = [p.strip() for p in value.split(",")]
    if len(parts) != 4:
        raise ValueError("--inset must be 4 comma-separated numbers: left,top,right,bottom")
    try:
        left, top, right, bottom = (float(p) for p in parts)
    except ValueError as exc:
        raise ValueError(f"--inset must be numeric: {exc}") from exc
    return {"left": left, "top": top, "right": right, "bottom": bottom}


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="color_cal_tool")
    parser.add_argument("--image", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--device-id", dest="device_id", default=None)
    parser.add_argument("--operator", default=None)
    parser.add_argument("--corners", default=None)
    parser.add_argument("--inset", default=None)
    parser.add_argument("--debug-dir", dest="debug_dir", default=None)
    parser.add_argument("--force", action="store_true")
    return parser


def _write_result(result_path: str, payload: dict) -> None:
    Path(result_path).parent.mkdir(parents=True, exist_ok=True)
    with open(result_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)


def _print_best_effort(payload: dict) -> None:
    try:
        print(json.dumps(payload))
    except Exception:
        pass  # pythonw.exe has no stdout; this is a courtesy for a console run


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)  # missing/unknown flags: argparse's own usage + exit(2)

    try:
        corners = _parse_corners(args.corners) if args.corners else None
        inset = _parse_inset(args.inset) if args.inset else None
    except ValueError as exc:
        result = {"ok": False, "error": {"code": "bad_arguments", "message": str(exc)}}
        _write_result(args.result, result)
        _print_best_effort(result)
        return _EXIT_CODE_BY_ERROR_CODE["bad_arguments"]

    try:
        result = calibrate(
            args.image,
            corners=corners,
            inset=inset,
            device_id=args.device_id,
            operator=args.operator,
            debug_dir=args.debug_dir,
            force=args.force,
        )
        if result.get("ok"):
            write_profile(args.out, result["profile"])
            result["profile_path"] = str(args.out)
            exit_code = 0
        else:
            exit_code = _EXIT_CODE_BY_ERROR_CODE.get(result.get("error", {}).get("code"), 2)
    except Exception as exc:  # noqa: BLE001 - the CLI's own catch-all, per contract
        LOGGER.exception("color_cal_tool failed")
        result = {"ok": False, "error": {"code": "io_error", "message": str(exc)}}
        exit_code = _EXIT_CODE_BY_ERROR_CODE["io_error"]

    _write_result(args.result, result)
    _print_best_effort(result)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
