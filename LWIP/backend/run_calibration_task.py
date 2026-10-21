"""Private LWIP worker. All paths are local and selected by the coordinator."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from color_cal_tool.calibrate import calibrate
from color_cal_tool.task_protocol import atomic_json


def main():
    work = Path(sys.argv[1])
    request = json.loads((work / "request.json").read_text(encoding="utf-8"))
    options = request.get("analysis", {})
    result = calibrate(
        work / "chart.jpg", device_id=request["device_id"], operator=request["operator"],
        corners=options.get("corners"), force=options.get("force", False),
        debug_dir=work / "debug",
    )
    atomic_json(work / "analysis.json", result)


if __name__ == "__main__":
    main()
