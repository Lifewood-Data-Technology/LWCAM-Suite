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

import copy
import logging
import logging.handlers
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import uvicorn  # noqa: E402  - must follow the sys.path fix above

from app.core.config import settings  # noqa: E402
from app.core.server_settings import migrate_plain_secrets  # noqa: E402
from app.core.tls import ensure_certificates, is_managed, keep_fresh  # noqa: E402
from app.main import app  # noqa: E402

LOG_MAX_BYTES = 10 * 1024 * 1024
LOG_BACKUPS = 5


def log_config() -> dict:
    """uvicorn's own logging config, plus a rotating logs/server.log for
    uvicorn and the app's loggers (10 MB x 5). An installed server is
    <root>/backend/run_server.py with <root>/logs made by the installer;
    anywhere else (a repo checkout) there is no such folder and the log stays
    on the console only - the folder is never created here."""
    config = copy.deepcopy(uvicorn.config.LOGGING_CONFIG)
    logs = Path(__file__).resolve().parent.parent / "logs"
    if not logs.is_dir():
        return config
    try:
        # Open it now: a read-only or locked folder falls back, not crashes.
        handler = logging.handlers.RotatingFileHandler(
            logs / "server.log", maxBytes=LOG_MAX_BYTES, backupCount=LOG_BACKUPS, encoding="utf-8"
        )
        handler.close()
    except OSError:
        return config
    config["formatters"]["file"] = {"format": "%(asctime)s %(levelname)s %(name)s: %(message)s"}
    config["handlers"]["file"] = {
        "class": "logging.handlers.RotatingFileHandler",
        "filename": str(logs / "server.log"),
        "maxBytes": LOG_MAX_BYTES,
        "backupCount": LOG_BACKUPS,
        "encoding": "utf-8",
        "formatter": "file",
    }
    for name in ("uvicorn", "uvicorn.access"):
        config["loggers"][name]["handlers"].append("file")
    # The app's own loggers (and anything else) propagate to root.
    config["root"] = {"level": "INFO", "handlers": ["default", "file"]}
    return config


def tls_kwargs() -> dict:
    """uvicorn's ssl arguments when tlsCertFile/tlsKeyFile are configured, else
    {} (plain http). The certificate is renewed here, at every start, so a new
    IP address or a nearly-expired leaf never needs a reinstall."""
    if not (settings.tls_cert_file and settings.tls_key_file):
        return {}
    try:
        # An operator's own certificate is used as-is, never regenerated.
        if is_managed(settings.tls_cert_file, settings.tls_key_file):
            ensure_certificates(Path(settings.tls_cert_file).parent)
    except Exception as exc:  # noqa: BLE001 - keep serving with the certificate on disk
        print(f"  tls    : could not renew the certificate: {exc}", flush=True)
    return {"ssl_certfile": settings.tls_cert_file, "ssl_keyfile": settings.tls_key_file}


RENEWED_EXIT_CODE = 3


def start_renewal() -> None:
    """uvicorn cannot swap its certificate while running, and the server now
    runs for weeks, so an IP change would leave browsers on a stale leaf.
    Every 6 h the managed certificate is re-checked; when it was re-issued the
    process exits non-zero and START_QC_SERVER.bat's loop restarts it (~30 s)
    on the new one. An operator's own certificate is never touched."""
    if not (settings.tls_cert_file and settings.tls_key_file):
        return
    if not is_managed(settings.tls_cert_file, settings.tls_key_file):
        return

    def renewed(_crt, _key) -> None:
        logging.getLogger("uvicorn.error").warning(
            "TLS certificate re-issued (name or address changed); restarting to serve it"
        )
        os._exit(RENEWED_EXIT_CODE)

    keep_fresh(Path(settings.tls_cert_file).parent, renewed)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else settings.port
    if migrate_plain_secrets():
        print("  config : stored passwords and keys are now protected", flush=True)
    tls = tls_kwargs()
    start_renewal()
    print("QC engine", flush=True)
    print(f"  code   : {Path(__file__).parent}", flush=True)
    print(f"  console: {'https' if tls else 'http'}://{settings.bind_host}:{port}", flush=True)
    uvicorn.run(app, host=settings.bind_host, port=port, log_config=log_config(), **tls)
