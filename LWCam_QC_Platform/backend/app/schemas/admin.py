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


class AiScannerSettingVO(BaseModel):
    """Stage 2: whether the check runs automatically instead of on demand."""

    enabled: bool
    # False when stage 1 is off or no key is configured, in which case this switch
    # cannot take effect whatever it is set to.
    available: bool
    # Whether the scanner thread is actually running right now.
    running: bool
    scanIntervalSeconds: int


class AiSettingVO(BaseModel):
    """AI review and pre-analysis configuration (editable)."""

    enabled: bool
    preanalysisEnabled: bool
    keyConfigured: bool
    extractModel: str
    compareModel: str


class PathSettingsVO(BaseModel):
    captureImageStoredPrefix: PathSettingVO
    captureImageLocalRoot: PathSettingVO
    qcImagesRoot: PathSettingVO
    exportTempDir: PathSettingVO
    exportOutputDir: PathSettingVO
    # Not path-sourced like the four above, so no PathSettingVO wrapper - these
    # are plain flags the console can now read AND write via PUT /settings.
    #
    # exportZipOutput was write-only at first: server_settings.py persisted it
    # and UpdateServerSettingsRequest accepted it, but nothing reported it back,
    # so the console could save the switch and then had no way to load its own
    # saved state. A setting you can set but not read is worse than one you
    # cannot set at all - it invites an admin to "fix" a value that was already
    # correct.
    luminanceEnabled: bool
    exportTiffOutput: bool
    exportZipOutput: bool
    exportAutoEnabled: bool
    ai: AiSettingVO
    aiScanner: AiScannerSettingVO
    # Named so the console can say WHERE to go to change any of this.
    configuredBy: str


class UpdatePathSettingsRequest(BaseModel):
    """Candidate paths to probe. This request does not save them."""

    # Blank on a single-PC station, where the stored path already resolves.
    qcImagesRoot: str = Field(default="", max_length=10800)
    captureImageStoredPrefix: str = Field(default="", max_length=10800)
    captureImageLocalRoot: str = Field(default="", max_length=10800)
    exportTempDir: str = Field(default="", max_length=10800)
    exportOutputDir: str = Field(default="", max_length=10800)


class UpdateServerSettingsRequest(BaseModel):
    """The settings the QC engine now owns outright - saved AND applied live.

    Unlike UpdatePathSettingsRequest above, this is not a probe: PUT /settings
    persists these to `config.txt` (app/core/server_settings.py)
    and mutates the running `settings` singleton in the same call, no restart.

    Secret fields (openrouterApiKey) are write-only: omitted in responses and
    blank in requests means "keep the current value". Other optional strings
    keep their value when omitted and clear it when blank.
    """

    qcImagesRoot: str = Field(default="", max_length=10800)
    exportTempDir: str = Field(default="", max_length=10800)
    exportOutputDir: str = Field(default="", max_length=10800)
    exportZipOutput: bool = True
    exportTiffOutput: bool = True
    luminanceEnabled: bool = False
    # Defaults True to match Settings.export_auto_enabled: a client that omits
    # the field must not silently stop a station exporting.
    exportAutoEnabled: bool = True
    # AI settings (optional)
    aiReviewEnabled: bool | None = None
    aiPreanalysisEnabled: bool | None = None
    openrouterApiKey: str | None = None
    openrouterExtractModel: str | None = None
    openrouterCompareModel: str | None = None


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
