from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, ForeignKey, String, text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base


# Written verbatim into the shared `users.roles` column. Lowercase to match the
# Dart UserRole enum names LWCAM/LWCamAdmin parse — their `fromJson` is an exact
# lowercase match, so 'Admin' would silently revoke that account's admin role in
# the capture apps. Reads stay case-insensitive (see `normalize_role`), so rows
# written by earlier builds keep working.
ROLE_SUPER_ADMIN = "SuperAdmin"
ROLE_ADMIN = "admin"
ROLE_QC = "qc"


def normalize_role(value: str) -> str:
    normalized = value.strip().lower().replace("-", "_")
    if normalized in {"superadmin", "super_admin"}:
        return "super_admin"
    if normalized == "admin":
        return "admin"
    if normalized == "qc":
        return "qc"
    return normalized


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(
        BigInteger, primary_key=True, server_default=text("nextval('users_id_seq'::regclass)")
    )
    user_id: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    password: Mapped[str] = mapped_column(String(255), nullable=False)
    roles: Mapped[str] = mapped_column(String(255), nullable=False, default="")
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    must_change_password: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("clock_timestamp()")
    )
    created_by: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL", onupdate="CASCADE"))
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("clock_timestamp()")
    )
    updated_by: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL", onupdate="CASCADE"))
    is_deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    projects = relationship(
        "Project", secondary="user_projects", back_populates="users", lazy="selectin", viewonly=True
    )

    @property
    def role_set(self) -> set[str]:
        """Every role this account holds, normalized.

        `users.roles` is a comma-joined list shared with LWCAM/LWCamAdmin, where
        holding several ('admin,capture', 'qc,admin') is normal. Authorization
        must use this, never [role] — that one collapses the list to a single
        value and would deny a role the account genuinely has.
        """
        raw_roles = self.roles or ""
        for marker in ("{", "}", "[", "]", '"', "'"):
            raw_roles = raw_roles.replace(marker, "")
        return {
            normalize_role(role)
            for role in raw_roles.replace(";", ",").replace("|", ",").split(",")
            if role.strip()
        }

    @property
    def role(self) -> str:
        """The single highest-precedence role, for DISPLAY and default landing page.

        Not an authorization answer — see [role_set].
        """
        normalized = self.role_set
        for candidate in ("super_admin", "admin", "qc"):
            if candidate in normalized:
                return candidate
        return next(iter(sorted(normalized)), "")

    @property
    def status(self) -> str:
        return "active" if self.active and not self.is_deleted else "disabled"
