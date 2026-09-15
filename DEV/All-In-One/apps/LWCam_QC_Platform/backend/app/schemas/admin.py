from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field


class CreateUserRequest(BaseModel):
    userId: str = Field(min_length=3, max_length=255, pattern=r"^[a-zA-Z0-9_.@-]+$")
    password: str = Field(min_length=6, max_length=64)
    role: str
    projectIds: list[int] = Field(default_factory=list)


class UpdateUserRequest(BaseModel):
    role: str
    status: str
    projectIds: list[int] = Field(default_factory=list)


class ResetPasswordRequest(BaseModel):
    newPassword: str = Field(min_length=6, max_length=64)


class UserAdminVO(BaseModel):
    id: int
    userId: str
    role: str
    status: str
    projectIds: list[int]
    projectNames: list[str]
    createdAt: datetime
    lastLoginAt: datetime | None = None
    mustChangePassword: bool


class ProjectOptionVO(BaseModel):
    id: int
    projectId: str
    projectName: str


class AdminQcTaskVO(BaseModel):
    folderId: int
    folderName: str
    folderSeq: int
    boxId: int
    boxName: str
    projectId: int | None = None
    projectCode: str | None = None
    projectName: str | None = None
    reviewerId: int | None = None
    reviewerUserId: str
    imageCount: int
    claimedAt: datetime | None = None
    updatedAt: datetime


class StatsOverviewVO(BaseModel):
    todayNewTasks: int
    todayCompletedTasks: int
    todayQcPassRate: float
    totalUsers: int
    totalTasks: int
    pendingClaimTasks: int
    taskTrend: list[dict[str, Any]]
    taskStatusDistribution: list[dict[str, Any]]
    reviewerWorkload: list[dict[str, Any]]


class PathSettingVO(BaseModel):
    """One path in force, and where it came from. Display only."""

    value: str
    source: str


class AiReviewSettingVO(BaseModel):
    """Stage 1: whether this station may send images to OpenRouter at all."""

    enabled: bool
    # False when no OpenRouter API key is configured. Both are set in LWCam Admin.
    keyConfigured: bool


class AiScannerSettingVO(BaseModel):
    """Stage 2: whether the check runs automatically instead of on demand."""

    enabled: bool
    # False when stage 1 is off or no key is configured, in which case this switch
    # cannot take effect whatever it is set to.
    available: bool
    # Whether the scanner thread is actually running right now.
    running: bool
    scanIntervalSeconds: int


class PathSettingsVO(BaseModel):
    captureImageStoredPrefix: PathSettingVO
    captureImageLocalRoot: PathSettingVO
    exportTempDir: PathSettingVO
    exportOutputDir: PathSettingVO
    aiReview: AiReviewSettingVO
    aiScanner: AiScannerSettingVO
    # Named so the console can say WHERE to go to change any of this.
    configuredBy: str


class UpdatePathSettingsRequest(BaseModel):
    """Candidate paths to probe. Nothing here is saved - Station Setup owns them."""

    captureImageStoredPrefix: str = Field(default="", max_length=10800)
    captureImageLocalRoot: str = Field(default="", max_length=10800)
    exportTempDir: str = Field(default="", max_length=10800)
    exportOutputDir: str = Field(default="", max_length=10800)


class PathCheckVO(BaseModel):
    key: str
    path: str
    exists: bool
    writable: bool
    message: str | None = None


class PathValidationVO(BaseModel):
    ok: bool
    checks: list[PathCheckVO]
    # How many capture_folders rows the candidate image mapping actually resolves
    # to a directory on disk. This is the check that proves a remap is correct.
    resolvedFolders: int
    totalFolders: int
