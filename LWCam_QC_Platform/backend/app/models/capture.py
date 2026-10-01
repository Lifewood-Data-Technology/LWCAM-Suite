from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


class CaptureBox(Base):
    __tablename__ = "capture_boxes"

    box_id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    box_name: Mapped[str] = mapped_column(String(255), nullable=False)
    device_id: Mapped[int] = mapped_column(ForeignKey("devices.id", ondelete="RESTRICT", onupdate="CASCADE"), nullable=False)
    status: Mapped[str] = mapped_column(String(255), nullable=False, default="OPEN")
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT", onupdate="CASCADE"), nullable=False)
    project_id: Mapped[int] = mapped_column(ForeignKey("projects.id", ondelete="RESTRICT", onupdate="CASCADE"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=text("clock_timestamp()"))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=text("clock_timestamp()"))
    transfer_start_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    transfer_end_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    transferred_to: Mapped[str | None] = mapped_column(String(255))
    is_deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    device = relationship("Device", lazy="joined")
    project = relationship("Project", lazy="joined")
    folders: Mapped[list["CaptureFolder"]] = relationship(back_populates="box")


class CaptureFolder(Base):
    __tablename__ = "capture_folders"
    __table_args__ = (
        UniqueConstraint("box_id", "folder_seq", name="uq_capture_folders_box_sequence"),
        # The live schema constrains group_id to be unique (multiple NULLs are
        # still fine). Declared here because it is not obvious from the column
        # definition, and Separation has to suffix each child's value to respect
        # it — see qc.child_group_id.
        UniqueConstraint("group_id", name="capture_folders_group_id_key"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    group_id: Mapped[str | None] = mapped_column(String(255))
    folder_name: Mapped[str] = mapped_column(String(255), nullable=False)
    box_id: Mapped[int] = mapped_column(ForeignKey("capture_boxes.box_id", ondelete="RESTRICT", onupdate="CASCADE"), nullable=False)
    device_id: Mapped[int] = mapped_column(ForeignKey("devices.id", ondelete="RESTRICT", onupdate="CASCADE"), nullable=False)
    folder_seq: Mapped[int] = mapped_column(Integer, nullable=False)
    cover_tag: Mapped[str | None] = mapped_column(String(255))
    image_tags: Mapped[str | None] = mapped_column(String(255))
    title: Mapped[str | None] = mapped_column(String(255))
    volume: Mapped[str | None] = mapped_column(String(255))
    # Archive coverage as the project's records carry it - "1914", "1914-06",
    # "1877-Mar-05" - and as FamilySearch receives it. Verbatim text, never parsed.
    start_date: Mapped[str | None] = mapped_column(Text)
    end_date: Mapped[str | None] = mapped_column(Text)
    archival_ref_no: Mapped[str | None] = mapped_column(String(255))
    record_type: Mapped[str | None] = mapped_column(String(255))
    place: Mapped[str | None] = mapped_column(String(255))
    language: Mapped[str | None] = mapped_column(String(255))
    record_custodian: Mapped[str | None] = mapped_column(String(255))
    capture_operator_id: Mapped[str | None] = mapped_column(String(255))
    capture_operator_name: Mapped[str | None] = mapped_column(String(255))
    digitizing_entity: Mapped[str | None] = mapped_column(String(255))
    source_created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    source_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=text("clock_timestamp()"))
    is_deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    client_qc_status: Mapped[str | None] = mapped_column(String(20))
    client_rework: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_deskewed: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_cropped: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_created_thumbnail: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    folder_path: Mapped[str | None] = mapped_column(String(10800))
    thumbnail_path: Mapped[str | None] = mapped_column(String(10800))
    qc_status: Mapped[str] = mapped_column(String(20), nullable=False, default="PENDING")
    qc_locked_by: Mapped[str | None] = mapped_column(String(255))
    qc_locked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Who moved this folder to PASS or REWORK - qc_locked_by cannot serve this:
    # it is the CURRENT claimant, and both approve and reject null it out on
    # the same commit that sets qc_status, so by the time a folder is decided
    # the actor is already gone. This is a real FK (users.id), unlike
    # qc_locked_by's username string, because it is a permanent attribution
    # rather than a lock to be released. NULL forever on anything reviewed
    # before this column existed - see migration 004 for why that is not
    # backfilled.
    qc_reviewed_by: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT", onupdate="CASCADE"))
    # Which folder this one was split OUT OF by Separation - set on every
    # child a separation creates (see apply_separation_commit), NULL on every
    # other folder. Stop-gap for the rework loop: LWCAM computes a recapture
    # target from this folder's OUTPUT path alone, which does not exist for a
    # separated child (see migration 005), so reject_task refuses rejection
    # outright when this is set. Also the column a future fix will use to
    # resolve rework through the ORIGINATING folder instead - built as that
    # permanent link, not a throwaway flag. NULL forever on anything
    # separated before this column existed - not backfilled, same convention
    # as qc_reviewed_by above.
    separated_from_folder_id: Mapped[int | None] = mapped_column(
        ForeignKey("capture_folders.id", ondelete="RESTRICT", onupdate="CASCADE")
    )
    is_tif_converted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_exported: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    exported_time: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    is_ingested: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    ingested_time: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    upload_error: Mapped[str | None] = mapped_column(Text)

    box: Mapped[CaptureBox] = relationship(back_populates="folders", lazy="joined")
    device = relationship("Device", lazy="joined")
    images: Mapped[list["CaptureImage"]] = relationship(back_populates="folder", cascade="all, delete-orphan", lazy="selectin")


class CaptureImage(Base):
    __tablename__ = "capture_images"
    __table_args__ = (UniqueConstraint("folder_id", "image_name", name="uq_capture_images_folder_image"),)

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    image_name: Mapped[str] = mapped_column(String(255), nullable=False)
    device_id: Mapped[int] = mapped_column(ForeignKey("devices.id", ondelete="RESTRICT", onupdate="CASCADE"), nullable=False)
    folder_id: Mapped[int] = mapped_column(
        ForeignKey("capture_folders.id", ondelete="CASCADE", onupdate="CASCADE")
    )
    file_format: Mapped[str] = mapped_column(String(10), nullable=False)
    image_created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=text("clock_timestamp()"))
    image_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    folder: Mapped[CaptureFolder | None] = relationship(back_populates="images")
