from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class FolderMetadataVO(BaseModel):
    folderId: int
    boxId: int
    boxName: str
    projectId: int | None = None
    projectName: str | None = None
    folderName: str
    folderSeq: int
    deviceId: str
    coverTag: str | None = None
    imageTags: str | None = None
    title: str | None = None
    volume: str | None = None
    startDate: str | None = None
    endDate: str | None = None
    archivalRefNo: str | None = None
    recordType: str | None = None
    place: str | None = None
    language: str | None = None
    recordCustodian: str | None = None
    captureOperatorId: str | None = None
    captureOperatorName: str | None = None
    digitizingEntity: str | None = None
    sourceCreatedAt: datetime | None = None
    sourceUpdatedAt: datetime | None = None


class MetadataQcImageVO(BaseModel):
    id: int
    filename: str
    available: bool
    previewUrl: str
    draftState: str | None = None
    separationStart: bool = False


class MetadataTemplateFieldVO(BaseModel):
    key: str
    label: str
    input: str
    mandatory: bool = False
    exported: bool = False
    options: list[str] = Field(default_factory=list)
    value: str | None = None
    # input == "mapped": this field is derived from another field's value.
    # mappedFrom names the source field; valueMap turns the source's value into
    # this one's. Station Setup writes both (mode/mappedFrom/valueMap), and the
    # capture form has resolved fields this way since keying existed.
    mappedFrom: str | None = None
    valueMap: dict[str, str] = Field(default_factory=dict)


class MetadataTemplateVO(BaseModel):
    fields: list[MetadataTemplateFieldVO] = Field(default_factory=list)
    # Legacy shape, still honoured: a single title -> record type map at the top
    # level, from before per-field mapping existed. Templates written by Station
    # Setup leave it null and declare a mapped recordType field instead.
    titleRecordTypeMap: dict[str, str] = Field(default_factory=dict)


class MetadataQcTaskVO(BaseModel):
    id: int
    status: str
    sourceHash: str
    hasDraft: bool = False
    draftImageIds: list[int] = Field(default_factory=list)
    draftMetadataDirty: bool = False
    assignedTo: int | None = None
    claimedAt: datetime | None = None
    submittedAt: datetime
    metadata: FolderMetadataVO
    metadataTemplate: MetadataTemplateVO
    imageCount: int
    imageAvailable: bool
    images: list[MetadataQcImageVO] = Field(default_factory=list)

    # Identity and state for the Completed list.
    #
    # groupId is the identifier the ingest team uses, and it is assigned at
    # EXPORT, not at approval - so it is null for a folder that is approved but
    # not yet swept up (the sweep runs every 30s), and null forever for one sent
    # back for rework. The list falls back to the folder name and shows the
    # state, so an empty Group ID reads as a stage rather than as missing data.
    groupId: str | None = None
    isExported: bool = False
    clientRework: bool = False


class ReviewRequest(BaseModel):
    sourceHash: str = Field(min_length=64, max_length=64)
    comment: str | None = Field(default=None, max_length=2000)


class CropImageRequest(BaseModel):
    sourceHash: str = Field(min_length=64, max_length=64)
    x: int = Field(ge=0)
    y: int = Field(ge=0)
    width: int = Field(gt=0)
    height: int = Field(gt=0)
    previewWidth: int | None = Field(default=None, gt=0)
    previewHeight: int | None = Field(default=None, gt=0)


class LuminanceRequest(ReviewRequest):
    pass


class BatchLuminanceRequest(ReviewRequest):
    imageIds: list[int] = Field(min_length=1)


class RotateImageRequest(ReviewRequest):
    degrees: int


class BatchRotateRequest(ReviewRequest):
    imageIds: list[int] = Field(min_length=1)
    degrees: int


class DeskewImageRequest(ReviewRequest):
    # Float, not int: deskew is the fine correction after LWIP has already
    # straightened the page, so half a degree is the case it exists for. An int
    # would make the reviewer's step size adjustable only upwards from 1.
    degrees: float


class BatchDeskewRequest(ReviewRequest):
    imageIds: list[int] = Field(min_length=1)
    degrees: float


class BatchDeleteRequest(ReviewRequest):
    imageIds: list[int] = Field(min_length=1)


class ReorderImagesRequest(ReviewRequest):
    imageIds: list[int] = Field(min_length=1)


class SeparationMarkersRequest(ReviewRequest):
    firstPageImageIds: list[int] = Field(default_factory=list)


class RejectedImageRequest(BaseModel):
    imageId: int
    rejectReason: str = Field(min_length=1, max_length=10000)


class RejectRequest(ReviewRequest):
    rejectReason: str | None = Field(default=None, max_length=10000)
    imageIds: list[int] = Field(default_factory=list)
    rejectedImages: list[RejectedImageRequest] = Field(default_factory=list)


class EditableFolderMetadata(BaseModel):
    folderName: str | None = Field(default=None, max_length=255)
    coverTag: str | None = Field(default=None, max_length=255)
    imageTags: str | None = Field(default=None, max_length=255)
    title: str | None = Field(default=None, max_length=255)
    volume: str | None = Field(default=None, max_length=255)
    startDate: str | None = None
    endDate: str | None = None
    archivalRefNo: str | None = Field(default=None, max_length=255)
    recordType: str | None = Field(default=None, max_length=255)
    place: str | None = Field(default=None, max_length=255)
    language: str | None = Field(default=None, max_length=255)
    recordCustodian: str | None = Field(default=None, max_length=255)
    captureOperatorId: str | None = Field(default=None, max_length=255)
    captureOperatorName: str | None = Field(default=None, max_length=255)
    digitizingEntity: str | None = Field(default=None, max_length=255)


class MetadataUpdateRequest(BaseModel):
    sourceHash: str = Field(min_length=64, max_length=64)
    metadata: EditableFolderMetadata


class AiReviewStartRequest(BaseModel):
    sourceHash: str = Field(min_length=64, max_length=64)
    force: bool = False


class AiReviewEvidenceVO(BaseModel):
    imageId: int
    filename: str
    observation: str


class AiReviewFieldVO(BaseModel):
    key: str
    currentValue: str | None = None
    suggestedValue: str | None = None
    verdict: Literal["match", "mismatch", "uncertain", "not_visible"]
    confidence: float = Field(ge=0, le=1)
    evidence: list[AiReviewEvidenceVO] = Field(default_factory=list)


class AiReviewResultVO(BaseModel):
    overallStatus: Literal["consistent", "needs_review", "insufficient_evidence"]
    fieldReviews: list[AiReviewFieldVO] = Field(default_factory=list)
    acceptedFields: list[str] = Field(default_factory=list)


class AiReviewProgressVO(BaseModel):
    processedImages: int = 0
    totalImages: int = 0


class AiReviewModelsVO(BaseModel):
    extracting: str
    comparing: str


class AiReviewJobVO(BaseModel):
    jobId: str
    folderId: int
    inputHash: str
    status: Literal["queued", "running", "succeeded", "failed", "cancelled"]
    stage: Literal["queued", "extracting", "comparing"] | None = None
    stageStartedAt: datetime | None = None
    trigger: Literal["manual", "preanalysis"] = "manual"
    cancelReason: str | None = None
    model: str
    models: AiReviewModelsVO | None = None
    createdAt: datetime
    updatedAt: datetime
    progress: AiReviewProgressVO
    stale: bool = False
    error: str | None = None
    result: AiReviewResultVO | None = None


class AiReviewApplyRequest(BaseModel):
    sourceHash: str = Field(min_length=64, max_length=64)
    inputHash: str = Field(pattern=r"^[0-9a-f]{64}$")
    fieldKeys: list[str] = Field(min_length=1)
