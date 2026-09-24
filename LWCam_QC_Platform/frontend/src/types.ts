export interface ApiResponse<T> {
  code: number
  message: string
  data: T
}

export interface PageResult<T> {
  records: T[]
  total: number
  page: number
  size: number
}

export interface UserInfo {
  id: number
  userId: string
  /** Highest-precedence role — display and default landing page only. */
  role: string
  /** Every role held. Route guards must use this for multi-role accounts. */
  roles?: string[]
  status: string
  homePath: string
  mustChangePassword: boolean
}

export interface AuthResponse {
  token: string
  user: UserInfo
}

export interface ProjectOption {
  id: number
  projectId: string
  projectName: string
}

export interface ExportConfig {
  tempDir: string
  outputDir: string
  csvEncoding: string
  csvLineEnding: string
}

export interface ExportRunItem {
  folderId: number
  status: string
  groupId?: string
  zipPath?: string
  error?: string
  errorKey?: string
  errorParams?: Record<string, unknown>
}

export interface ExportRun {
  runId: string
  status: string
  createdBy: string
  createdAt: string
  startedAt?: string
  completedAt?: string
  total: number
  succeeded: number
  failed: number
  /** Missing from run records persisted before multi-station support. */
  skipped?: number
  currentFolderId?: number
  items: ExportRunItem[]
}

export interface ExportableFolder {
  folderId: number
  folderName: string
  folderSeq: number
  boxName: string
  projectId: string
  projectName: string
  imageCount: number
}

export interface ExportFolder extends ExportableFolder {
  qcStatus: string
  isExported: boolean
  exportedTime?: string
  groupId?: string
  exportable: boolean
}

export interface ExportPreflight {
  ready: boolean
  errors: ExportIssue[]
  eligibleCount: number
  exportedCount: number
  invalidProjects: Array<{ id: number; projectId: string; projectName: string }>
  config?: ExportConfig
  activeRun?: ExportRun
}

export interface ExportIssue {
  errorKey: string
  errorParams?: Record<string, unknown>
}

export interface AdminQcTask {
  folderId: number
  folderName: string
  folderSeq: number
  boxId: number
  boxName: string
  projectId?: number
  projectCode?: string
  projectName?: string
  reviewerId?: number
  reviewerUserId: string
  imageCount: number
  claimedAt?: string
  updatedAt: string
}

export interface StatsOverview {
  todayNewTasks: number
  todayCompletedTasks: number
  todayQcPassRate: number
  totalUsers: number
  totalTasks: number
  pendingClaimTasks: number
  taskTrend: Array<Record<string, unknown>>
  taskStatusDistribution: Array<{ status: string; label: string; count: number }>
  reviewerWorkload: Array<{
    reviewerId: number
    reviewerName: string
    total: number
    approved: number
    rejected: number
  }>
}

export interface MetadataRecord {
  folderId: number
  boxId: number
  boxName: string
  projectId?: number
  projectName?: string
  folderName: string
  folderSeq: number
  deviceId: string
  coverTag?: string
  imageTags?: string
  title?: string
  volume?: string
  startDate?: string
  endDate?: string
  archivalRefNo?: string
  recordType?: string
  place?: string
  language?: string
  recordCustodian?: string
  captureOperatorId?: string
  captureOperatorName?: string
  digitizingEntity?: string
  sourceCreatedAt?: string
  sourceUpdatedAt?: string
}

export interface EditableFolderMetadata {
  folderName?: string | null
  coverTag?: string | null
  imageTags?: string | null
  title?: string | null
  volume?: string | null
  startDate?: string | null
  endDate?: string | null
  archivalRefNo?: string | null
  recordType?: string | null
  place?: string | null
  language?: string | null
  recordCustodian?: string | null
  captureOperatorId?: string | null
  captureOperatorName?: string | null
  digitizingEntity?: string | null
}

export interface MetadataQcImage {
  id: number
  filename: string
  available: boolean
  previewUrl: string
  draftState?: string | null
  separationStart?: boolean
}

export interface MetadataTemplateField {
  key: keyof EditableFolderMetadata
  label: string
  /**
   * `input` mirrors the LWCam project template one for one, as Station Setup
   * wrote it and `qc.py`'s `metadata_template` normalises it:
   *   text   - free text
   *   select - dropdown over `options`
   *   fixed  - not keyed at all; the template's own `value`
   *   mapped - derived from `mappedFrom` through `valueMap`
   * A kind missing here renders as free text, which is how `mapped` fields
   * were editable while the mapping overwrote whatever was typed.
   */
  input: 'text' | 'select' | 'fixed' | 'mapped'
  mandatory: boolean
  exported: boolean
  options: string[]
  value?: string | null
  mappedFrom?: string | null
  valueMap?: Record<string, string>
}

export interface MetadataTemplate {
  fields: MetadataTemplateField[]
  titleRecordTypeMap: Record<string, string>
}

export interface MetadataQcTask {
  id: number
  status: string
  sourceHash: string
  hasDraft: boolean
  draftImageIds: number[]
  draftMetadataDirty: boolean
  assignedTo?: number
  claimedAt?: string
  submittedAt: string
  metadata: MetadataRecord
  metadataTemplate: MetadataTemplate
  imageCount: number
  imageAvailable: boolean
  images: MetadataQcImage[]

  // Identity and state for the Completed list. groupId is assigned at EXPORT,
  // not approval, so it is null until the export sweep runs and null forever
  // for a folder sent back for rework — see backend MetadataQcTaskVO.
  groupId?: string | null
  isExported: boolean
  clientRework: boolean

  // True for a child Separation split off another folder - see the comment
  // on the backend's MetadataQcTaskVO. The Rework button is disabled for
  // one of these rather than left to fail after the click.
  separatedFromFolder: boolean

  // A server setting, not task data, carried on the task payload so the review
  // toolbar can hide the luminance tool rather than offer one that answers 503.
  // See the comment on MetadataQcTaskVO for why it rides along here.
  luminanceEnabled: boolean
}

export interface CropRect {
  x: number
  y: number
  width: number
  height: number
  previewWidth?: number
  previewHeight?: number
}

export interface RejectedImagePayload {
  imageId: number
  rejectReason: string
}

// Ledger entry from the durable export failure file (services/export.py
// `_failures`). Loosely typed on the backend (`dict[str, Any]`) because it is
// a JSON ledger, not a DB row — these are the keys it actually writes.
export interface ExportFailureEntry {
  folderId: number
  folderName?: string | null
  error?: string | null
  errorKey?: string | null
  errorParams?: Record<string, unknown> | null
  failedAt?: string | null
  attempts?: number
  lastRunId?: string | null
  groupId?: string | null
  zipPath?: string | null
}

export interface PathSettingVO {
  value: string
  source: string
}

export interface AiScannerStatus {
  enabled: boolean
  available: boolean
  running: boolean
  scanIntervalSeconds: number
}

export interface UploadSettings {
  enabled: boolean
  s3Path: string
  region: string
  accessKey: string
  secretKeyConfigured: boolean
  doneRoot: string
  summaryRoot: string
}

export interface AiSettings {
  enabled: boolean
  preanalysisEnabled: boolean
  keyConfigured: boolean
  extractModel: string
  compareModel: string
}

export interface PathSettingsVO {
  captureImageStoredPrefix: PathSettingVO
  captureImageLocalRoot: PathSettingVO
  qcImagesRoot: PathSettingVO
  exportTempDir: PathSettingVO
  exportOutputDir: PathSettingVO
  luminanceEnabled: boolean
  exportTiffOutput: boolean
  exportZipOutput: boolean
  exportAutoEnabled: boolean
  upload: UploadSettings
  ai: AiSettings
  aiScanner: AiScannerStatus
  configuredBy: string
}

export interface UpdatePathSettingsRequest {
  qcImagesRoot: string
  captureImageStoredPrefix?: string
  captureImageLocalRoot?: string
  exportTempDir?: string
  exportOutputDir?: string
}

export interface UpdateServerSettingsRequest {
  qcImagesRoot: string
  exportTempDir: string
  exportOutputDir: string
  exportZipOutput: boolean
  exportTiffOutput: boolean
  luminanceEnabled: boolean
  exportAutoEnabled: boolean
  uploadEnabled: boolean
  uploadS3Path: string
  uploadS3Region: string
  uploadS3AccessKey: string
  uploadS3SecretKey: string
  uploadDoneRoot: string
  uploadSummaryRoot: string
  aiReviewEnabled: boolean
  aiPreanalysisEnabled: boolean
  openrouterApiKey: string
  openrouterExtractModel: string
  openrouterCompareModel: string
}

export interface PathCheckVO {
  key: string
  path: string
  exists: boolean
  writable: boolean
  message?: string | null
}

export interface PathValidation {
  ok: boolean
  checks: PathCheckVO[]
  resolvedFolders: number
  totalFolders: number
}

// --- AI review ---------------------------------------------------------
// Ported from the Flutter reference (models/qc_ai_review.dart), not
// reinvented, so field names and shapes match the engine exactly.

export interface AiReviewEvidence {
  imageId: number
  filename: string
  observation: string
}

export interface AiReviewField {
  key: string
  currentValue?: string | null
  suggestedValue?: string | null
  verdict: 'match' | 'mismatch' | 'uncertain' | 'not_visible'
  confidence: number
  evidence: AiReviewEvidence[]
}

export interface AiReviewResult {
  overallStatus: 'consistent' | 'needs_review' | 'insufficient_evidence'
  fieldReviews: AiReviewField[]
  acceptedFields: string[]
}

export interface AiReviewProgress {
  processedImages: number
  totalImages: number
}

export interface AiReviewModels {
  extracting: string
  comparing: string
}

export interface AiReviewJob {
  jobId: string
  folderId: number
  inputHash: string
  status: 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled'
  stage?: 'queued' | 'extracting' | 'comparing' | null
  stageStartedAt?: string | null
  trigger: 'manual' | 'preanalysis'
  cancelReason?: string | null
  model: string
  models?: AiReviewModels | null
  createdAt: string
  updatedAt: string
  progress: AiReviewProgress
  stale: boolean
  error?: string | null
  result?: AiReviewResult | null
}
