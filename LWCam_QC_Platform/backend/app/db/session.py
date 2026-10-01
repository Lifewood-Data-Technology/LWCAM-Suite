from collections.abc import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import settings

# A remote DB PC (LAN / Tailscale) that is off or slow must not hang a request or
# a sweep forever: connecting gives up after 5 s, a single statement after 2 min.
# sslmode stays in the URL query (config.database_url).
engine = create_engine(
    settings.database_url,
    pool_pre_ping=True,
    connect_args={
        "connect_timeout": 5,
        "options": "-c statement_timeout=120000",
        # TCP keepalives: if the DB PC vanishes, a half-open connection is dropped
        # in ~60 s and the server releases the advisory lock the dead
        # connection held (export folder locks), instead of leaving it a ghost.
        "keepalives": 1,
        "keepalives_idle": 30,
        "keepalives_interval": 10,
        "keepalives_count": 3,
    },
)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, expire_on_commit=False)


def get_db() -> Generator[Session, None, None]:
    from app.services.schema_check import ensure_current  # late: it imports the engine above

    ensure_current()
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

