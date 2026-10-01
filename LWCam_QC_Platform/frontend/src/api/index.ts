import request from '@/api/client'
import type {
  AdminQcTask,
  AiReviewJob,
  ApiResponse,
  AuthResponse,
  EditableFolderMetadata,
  ExportFailureEntry,
  ExportFolder,
  ExportPreflight,
  ExportRun,
  CropRect,
  MetadataQcTask,
  NetworkLogin,
  PageResult,
  PathSettingsVO,
  PathValidation,
  ProjectOption,
  RejectedImagePayload,
  StatsOverview,
  SystemStatus,
  UpdatePathSettingsRequest,
  UpdateServerSettingsRequest,
  UserInfo,
} from '@/types'

export const authApi = {
  login: (data: { username: string; password: string }) => request.post<ApiResponse<AuthResponse>>('/auth/login', data),
  me: () => request.get<ApiResponse<UserInfo>>('/auth/me'),
  logout: () => request.post<ApiResponse<Record<string, never>>>('/auth/logout'),
  changePassword: (oldPassword: string, newPassword: string) =>
    request.put<ApiResponse<UserInfo>>('/auth/password', { oldPassword, newPassword }),
}

export const adminApi = {
  stats: () => request.get<ApiResponse<StatsOverview>>('/admin/stats/overview'),
  systemStatus: (all = false) =>
    request.get<ApiResponse<SystemStatus>>('/admin/system-status', { params: all ? { all: 1 } : {} }),
  forgetPc: (part: string, host: string) =>
    request.delete<ApiResponse<Record<string, never>>>(
      `/admin/system-status/${encodeURIComponent(part)}/${encodeURIComponent(host)}`,
    ),
  // No user-management bindings here on purpose. Creating, editing, disabling and
  // password-resetting an account is SuperAdmin work and is done in LWCam Admin, against
  // Postgres directly. The engine still exposes those endpoints, but gated to
  // `super_admin`, and this console is never the thing that calls them.
  //
  // projectOptions stays: QcTaskManageView reads it to label a folder's project.
  projectOptions: () => request.get<ApiResponse<ProjectOption[]>>('/admin/projects/options'),
  qcTasks: (params: Record<string, unknown>) =>
    request.get<ApiResponse<PageResult<AdminQcTask>>>('/admin/qc-tasks', { params }),
  releaseQcTask: (folderId: number) =>
    request.post<ApiResponse<void>>(`/admin/qc-tasks/${folderId}/release`),
  exportPreflight: () =>
    request.get<ApiResponse<ExportPreflight>>('/admin/exports/preflight'),
  exportFolders: (
    exportStatus: 'all' | 'exported' | 'unexported',
    page: number,
    size: number,
  ) =>
    request.get<ApiResponse<PageResult<ExportFolder>>>('/admin/exports/folders', {
      params: { exportStatus, page, size },
    }),
  runFolderExport: (folderId: number) =>
    request.post<ApiResponse<ExportRun>>(`/admin/exports/folders/${folderId}`),
  runExport: () =>
    request.post<ApiResponse<ExportRun>>('/admin/exports/run'),
  currentExport: () =>
    request.get<ApiResponse<ExportRun | null>>('/admin/exports/current'),
  // Ledger of exports that failed and have not since succeeded — outlives the
  // run that produced it, so it stays visible until retried or cleared.
  exportFailures: () =>
    request.get<ApiResponse<ExportFailureEntry[]>>('/admin/exports/failures'),
  retryExports: (folderIds?: number[]) =>
    request.post<ApiResponse<ExportRun>>('/admin/exports/retry', { folderIds: folderIds ?? null }),
  pathSettings: () =>
    request.get<ApiResponse<PathSettingsVO>>('/admin/settings/paths'),
  validatePathSettings: (payload: UpdatePathSettingsRequest) =>
    request.post<ApiResponse<PathValidation>>('/admin/settings/paths/validate', payload),
  updateServerSettings: (payload: UpdateServerSettingsRequest) =>
    request.put<ApiResponse<PathSettingsVO>>('/admin/settings', payload),
  networkLogins: () =>
    request.get<ApiResponse<{ logins: NetworkLogin[] }>>('/admin/settings/network-logins'),
  checkNetworkLogins: () =>
    request.post<ApiResponse<{ logins: NetworkLogin[] }>>('/admin/settings/network-logins/check'),
  saveNetworkLogin: (payload: { host: string; username: string; password: string }) =>
    request.post<ApiResponse<{ error: string | null }>>('/admin/settings/network-logins', payload),
  removeNetworkLogin: (host: string) =>
    request.post<ApiResponse<Record<string, never>>>('/admin/settings/network-logins/remove', { host }),
}

export const qcApi = {
  tasks: (params: Record<string, unknown>) =>
    request.get<ApiResponse<PageResult<MetadataQcTask>>>('/qc/metadata-tasks', { params }),
  detail: (id: number) =>
    request.get<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}`),
  claimNext: () =>
    request.post<ApiResponse<MetadataQcTask>>('/qc/metadata-tasks/claim-next'),
  claim: (id: number) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/claim`),
  release: (id: number) =>
    request.post<ApiResponse<void>>(`/qc/metadata-tasks/${id}/release`),
  approve: (id: number, sourceHash: string, comment?: string) =>
    request.post<ApiResponse<void>>(`/qc/metadata-tasks/${id}/approve`, { sourceHash, comment }),
  // Client rework: reopens a PASS folder for a correction under the SAME
  // Group ID and claims it for the caller. Returns the task already in
  // "reviewing" state, same as claim().
  revert: (id: number, sourceHash: string, comment?: string) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/revert`, { sourceHash, comment }),
  reject: (id: number, sourceHash: string, rejectedImages: RejectedImagePayload[], comment?: string) =>
    request.post<ApiResponse<void>>(`/qc/metadata-tasks/${id}/reject`, { sourceHash, rejectedImages, comment }),
  updateMetadata: (id: number, sourceHash: string, metadata: EditableFolderMetadata) =>
    request.put<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/metadata`, { sourceHash, metadata }),
  luminanceImage: (id: number, imageId: number, sourceHash: string) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/${imageId}/luminance`, { sourceHash }),
  luminanceBatch: (id: number, sourceHash: string, imageIds: number[]) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/luminance-batch`, { sourceHash, imageIds }),
  replaceImage: (id: number, imageId: number, sourceHash: string, file: File) => {
    const form = new FormData()
    form.append('sourceHash', sourceHash)
    form.append('file', file)
    return request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/${imageId}/replace`, form)
  },
  insertBeforeImage: (id: number, imageId: number, sourceHash: string, file: File) => {
    const form = new FormData()
    form.append('sourceHash', sourceHash)
    form.append('file', file)
    return request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/${imageId}/insert-before`, form)
  },
  deleteImage: (id: number, imageId: number, sourceHash: string) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/${imageId}/delete`, { sourceHash }),
  deleteImagesBatch: (id: number, sourceHash: string, imageIds: number[]) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/delete-batch`, { sourceHash, imageIds }),
  rotateImage: (id: number, imageId: number, sourceHash: string, degrees: number) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/${imageId}/rotate`, { sourceHash, degrees }),
  rotateBatch: (id: number, sourceHash: string, imageIds: number[], degrees: number) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/rotate-batch`, { sourceHash, imageIds, degrees }),
  deskewImage: (id: number, imageId: number, sourceHash: string, degrees: number) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/${imageId}/deskew`, { sourceHash, degrees }),
  deskewBatch: (id: number, sourceHash: string, imageIds: number[], degrees: number) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/deskew-batch`, { sourceHash, imageIds, degrees }),
  reorderImages: (id: number, sourceHash: string, imageIds: number[]) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/reorder`, { sourceHash, imageIds }),
  restoreOriginal: (id: number, imageId: number, sourceHash: string) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/${imageId}/restore-original`, { sourceHash }),
  undoDraft: (id: number) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/draft/undo`),
  redoDraft: (id: number) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/draft/redo`),
  updateSeparationMarkers: (id: number, sourceHash: string, firstPageImageIds: number[]) =>
    request.put<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/separation-markers`, { sourceHash, firstPageImageIds }),
  saveDraft: (id: number, sourceHash: string) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/draft/save`, { sourceHash }),
  discardDraft: (id: number) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/draft/discard`),
  cropImage: (id: number, imageId: number, sourceHash: string, crop: CropRect) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/images/${imageId}/crop`, {
      sourceHash,
      ...crop,
    }),
  // AI review: three-way split ported from the Flutter reference (start/poll/
  // apply). See src/composables/useAiReview.ts for the lifecycle.
  startAiReview: (id: number, sourceHash: string, force = false) =>
    request.post<ApiResponse<AiReviewJob>>(`/qc/metadata-tasks/${id}/ai-review/jobs`, { sourceHash, force }),
  aiReviewJob: (id: number, jobId: string) =>
    request.get<ApiResponse<AiReviewJob>>(`/qc/metadata-tasks/${id}/ai-review/jobs/${jobId}`),
  latestAiReview: (id: number) =>
    request.get<ApiResponse<AiReviewJob | null>>(`/qc/metadata-tasks/${id}/ai-review/latest`),
  applyAiReview: (id: number, sourceHash: string, inputHash: string, fieldKeys: string[]) =>
    request.post<ApiResponse<MetadataQcTask>>(`/qc/metadata-tasks/${id}/ai-review/apply`, {
      sourceHash,
      inputHash,
      fieldKeys,
    }),
}
