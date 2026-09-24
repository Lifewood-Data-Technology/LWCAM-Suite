from datetime import datetime

from sqlalchemy import BigInteger, DateTime, ForeignKey, String, text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class ReworkLog(Base):
    __tablename__ = "rework_logs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    image_id: Mapped[int | None] = mapped_column(ForeignKey("capture_images.id", ondelete="SET NULL", onupdate="CASCADE"))
    assigned_uid: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT", onupdate="CASCADE"), nullable=False
    )
    folder_id: Mapped[int] = mapped_column(
        ForeignKey("capture_folders.id", ondelete="RESTRICT", onupdate="CASCADE"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("clock_timestamp()")
    )
    rework_comments: Mapped[str] = mapped_column(String(10800), nullable=False)
    rework_status: Mapped[str] = mapped_column(String(20), nullable=False, default="OPEN")
    rework_type: Mapped[str] = mapped_column(String(255), nullable=False)
