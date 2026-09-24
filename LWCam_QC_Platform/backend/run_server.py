r"""Start the QC engine from THIS working tree.

Not a convenience wrapper - a correctness one. The shipped runtime's
`python313._pth` hardcodes the INSTALLED backend
(C:\Program Files\LW Suite\QC\backend) onto sys.path, ignores PYTHONPATH, and
does not add the working directory. So `python -m app.main` run from this
folder silently starts the INSTALLED engine instead, and because that copy has
no __main__ block it exits without printing anything at all - it looks like the
command did nothing rather than like it ran the wrong code.

Putting this directory first is the whole job. Run it from here:
    python.exe run_server.py [port]
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import uvicorn  # noqa: E402  - must follow the sys.path fix above

from app.core.config import settings  # noqa: E402
from app.main import app  # noqa: E402

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else settings.port
    print("QC engine", flush=True)
    print(f"  code   : {Path(__file__).parent}", flush=True)
    print(f"  console: http://{settings.bind_host}:{port}", flush=True)
    uvicorn.run(app, host=settings.bind_host, port=port)
