<!-- QC review screen: the main page of the QC Platform web console (pipeline: capture -> LWIP -> QC -> export -> upload). -->
<!-- One component serves three routes: the Available queue (pending), the review desk (qc-my-tasks / qc-review) and the Completed history. -->
<!-- `active` (pending | mine | completed) is derived from the route and picks which of the three template blocks renders. -->
<!-- Image edits (rotate, crop, deskew, delete, ...) are not applied at once: the server keeps them as a draft on the task, -->
<!-- and every call sends task.sourceHash so a stale copy is refused with a version conflict (see handleVersionOrActionError). -->
<!-- Metadata is edited in a local form (metadataForm) and saved separately; approve saves it first, reject needs a remark per page. -->
<!-- Layout: this <script> comes first, then the <template> (page header, queue, desk, completed history, dialogs), then scoped CSS. -->
<script setup lang="ts">
// --- Imports and state --------------------------------------------------------
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { ElMessage, ElMessageBox } from 'element-plus'
import AppShell from '@/components/AppShell.vue'
import ImagePreviewViewer from '@/components/ImagePreviewViewer.vue'
import ThumbnailImage from '@/components/ThumbnailImage.vue'
import QcAiReviewPanel from '@/components/qc/QcAiReviewPanel.vue'
import { qcApi } from '@/api'
import type { ApiError } from '@/api/client'
import { usePreviewImage } from '@/composables/usePreviewImage'
import { useAiReview } from '@/composables/useAiReview'
import { translateValue } from '@/i18n'
import { formatTimestamp } from '@/utils/date'
import type { CropRect, EditableFolderMetadata, MetadataQcImage, MetadataQcTask, MetadataTemplateField } from '@/types'

const { t } = useI18n()
type QcScope = 'pending' | 'mine' | 'completed'

const route = useRoute()
const router = useRouter()
const active = ref<QcScope>('pending')
const loading = ref(false)
const detailLoading = ref(false)
const actionLoading = ref(false)
const metadataSaving = ref(false)
const luminanceLoading = ref(false)
const draftSaving = ref(false)
const draftDiscarding = ref(false)
const tasks = ref<MetadataQcTask[]>([])
const scopeTotals = reactive<Record<'pending' | 'mine' | 'completed', number | null>>({
  pending: null,
  mine: null,
  completed: null,
})
const current = ref<MetadataQcTask | null>(null)
const claimedTask = ref<MetadataQcTask | null>(null)
const image = ref<MetadataQcImage | null>(null)
const viewerVisible = ref(false)
const rejectDialogVisible = ref(false)
const cropLoading = ref(false)
const cropImageEl = ref<HTMLImageElement | null>(null)
const replaceInputEl = ref<HTMLInputElement | null>(null)
const insertInputEl = ref<HTMLInputElement | null>(null)
// In-place crop mode on the main preview. The overlay is an absolutely
// positioned box glued to the measured img rect (the img itself is left
// untouched — re-parenting it would break its max-height:100% sizing against
// the flex canvas). Overlay-local coords == displayed-image coords, which is
// what clampCropPoint / cropRectInNaturalPixels already assume.
const cropMode = ref(false)
const previewCanvasEl = ref<HTMLDivElement | null>(null)
const cropOverlayBox = reactive({ left: 0, top: 0, width: 0, height: 0 })
const cropSelection = reactive({ x: 0, y: 0, width: 0, height: 0 })
type CropHandle = 'nw' | 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w'
const CROP_HANDLES: CropHandle[] = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w']
const CROP_MIN = 8
const cropDrag = ref<null | {
  kind: 'draw' | 'move' | 'resize'
  handle?: CropHandle
  start: { x: number; y: number }
  orig: { x: number; y: number; width: number; height: number }
}>(null)
let cropResizeObserver: ResizeObserver | null = null
// Degrees the straighten (deskew) buttons apply per click. Session-only, like
// the Flutter toolbar's own deskewStep: it belongs to the batch being worked
// through, not to the operator, so it is never carried across folders.
const DESKEW_STEP_MIN = 0.1
const DESKEW_STEP_MAX = 10
const deskewStep = ref(1)
function formatDeskewStep(value: number) {
  return Number.isInteger(value) ? String(value) : value.toFixed(1)
}
const deskewStepText = ref(formatDeskewStep(deskewStep.value))
function setDeskewStep(value: number) {
  if (Number.isNaN(value)) return
  deskewStep.value = Math.min(DESKEW_STEP_MAX, Math.max(DESKEW_STEP_MIN, value))
  deskewStepText.value = formatDeskewStep(deskewStep.value)
}
function commitDeskewStepInput() {
  const parsed = Number.parseFloat(deskewStepText.value)
  if (!Number.isNaN(parsed)) setDeskewStep(parsed)
  else deskewStepText.value = formatDeskewStep(deskewStep.value)
}
// Steps by 0.1 below one degree and by 1 above it — a flat 0.1 would take
// ninety clicks to get from 1 to 10; a flat 1 could never reach the
// half-degree corrections this field exists for. Mirrors the Flutter toolbar's
// _Nudge exactly, rounded to one decimal so repeated 0.1 steps don't drift.
function nudgeDeskewStep(direction: 1 | -1) {
  const current = deskewStep.value
  const increment = (direction > 0 ? current : current - 0.01) < 1 ? 0.1 : 1
  setDeskewStep(Math.round((current + increment * direction) * 10) / 10)
}
const deskewStepLabel = computed(() => formatDeskewStep(deskewStep.value))

// --- Reject remarks, page selection and split state ---------------------------
const rejectedImageIds = ref<number[]>([])
const rejectReasons = reactive<Record<number, string>>({})

const selectedImageIds = ref<number[]>([])
const separationMode = ref(false)
// Unapplied clicks while the mode is open: the EXTRA start pages only (page 1 is implicit).
const separationSelection = ref<Set<number>>(new Set())
const separationApplying = ref(false)
const metadataForm = reactive<EditableFolderMetadata>({})
const { previewSrc, previewLoading, previewError } = usePreviewImage(image)

// AI review owns only the job; applying a suggestion writes the metadata
// draft and comes back as a whole task, merged the same way every other
// draft mutation is (applyTaskUpdate), then the metadata form is resynced —
// the folder id does not change on an apply, so the id-keyed watch that
// normally refreshes the form after a claim never fires for it on its own.
const aiReview = useAiReview(
  () => current.value,
  () => current.value?.status === 'reviewing',
  (task) => {
    applyTaskUpdate(task)
    fillMetadataFormFromCurrent()
  },
)

// --- Route flags and display data ---------------------------------------------
const isReviewRoute = computed(() => route.name === 'qc-review')
const isWorkbenchRoute = computed(() => route.name === 'qc-my-tasks' || route.name === 'qc-review')
const isStandaloneQcRoute = computed(() => isWorkbenchRoute.value || route.name === 'qc-completed')
const showListChrome = computed(() => !isStandaloneQcRoute.value)

const currentImageIndex = computed(() => {
  if (!current.value || !image.value) return 0
  return current.value.images.findIndex((item) => item.id === image.value?.id) + 1
})

const currentRejectReason = computed({
  get() {
    if (!image.value) return ''
    return rejectReasons[image.value.id] || ''
  },
  set(value: string) {
    if (!image.value) return
    const imageId = image.value.id
    if (value.trim() && !rejectedImageIds.value.includes(imageId)) {
      rejectedImageIds.value = [...rejectedImageIds.value, imageId]
    } else if (!value.trim()) {
      rejectedImageIds.value = rejectedImageIds.value.filter((id) => id !== imageId)
    }
    rejectReasons[imageId] = value
  },
})
// Collapsed until asked for, then sticky for the rest of the folder - the
// operator who opens it is mid-rejection and will be moving between pages.
const rejectReasonCollapsed = ref(true)
const rejectReasonOpen = computed(
  () => !rejectReasonCollapsed.value || !!currentRejectReason.value.trim(),
)
function toggleRejectReason() {
  rejectReasonCollapsed.value = !rejectReasonCollapsed.value
}

const metadataGroups = computed(() => {
  const metadata = current.value?.metadata
  if (!metadata) return []
  // One list, not three sections. The old grouping took each section's heading
  // from its own FIRST FIELD - "Folder name", "Title", "Device ID" - so the
  // headings were field labels wearing a hat, and each one then repeated
  // immediately underneath itself as a row. There is no real grouping in this
  // data: it is one folder's metadata, read top to bottom.
  return [
    {
      title: '',
      fields: [
        [t('qc.fields.projectName'), metadata.projectName],
        [t('qc.fields.boxDetails'), metadata.boxName],
        [t('qc.fields.folderName'), metadata.folderName],
        [t('qc.fields.folderSeq'), metadata.folderSeq],
        [t('qc.fields.title'), metadata.title],
        [t('qc.fields.volume'), metadata.volume],
        [t('qc.fields.archivalRefNo'), metadata.archivalRefNo],
        [t('qc.fields.coverTag'), metadata.coverTag],
        [t('qc.fields.imageTags'), metadata.imageTags],
        [t('qc.fields.startDate'), canonicalDateValue(metadata.startDate)],
        [t('qc.fields.endDate'), canonicalDateValue(metadata.endDate)],
        [t('qc.fields.deviceId'), metadata.deviceId],
        [t('qc.fields.scanningOpr'), metadata.captureOperatorName || metadata.captureOperatorId],
        [t('qc.fields.recordType'), metadata.recordType],
        [t('qc.fields.place'), metadata.place],
        [t('qc.fields.language'), metadata.language],
        [t('qc.fields.recordCustodian'), metadata.recordCustodian],
        [t('qc.fields.digitizingEntity'), metadata.digitizingEntity],
      ],
    },
  ]
})

// The page is named after the project being audited. A QC account can be scoped
// to several projects and the client has no way to ask which (UserInfo carries
// no project fields, /admin/projects/options is admin-only), so the name is
// derived from the queue itself and only shown when every loaded task agrees.
// A mixed queue, an empty queue and the first paint before load() resolves all
// fall back to the generic title rather than naming a project wrongly.
const pageTitle = computed(() => {
  const names = new Set(
    tasks.value
      .map((task) => task.metadata.projectName?.trim())
      .filter((name): name is string => Boolean(name)),
  )
  // ponytail: only the loaded page is scanned; a queue deeper than one page
  // could hide a second project. Widen if that queue depth turns out to be real.
  return names.size === 1 ? [...names][0] : t('qc.title')
})

const summaryItems = computed(() => [
  { label: t('qc.pending'), value: scopeTotals.pending ?? (active.value === 'pending' ? tasks.value.length : '-') },
  { label: t('qc.mine'), value: scopeTotals.mine ?? (active.value === 'mine' ? tasks.value.length : '-') },
  { label: t('qc.completed'), value: scopeTotals.completed ?? (active.value === 'completed' ? tasks.value.length : '-') },
])

// --- Crop box, batch selection and tool enablement ----------------------------
const cropSelectionStyle = computed(() => ({
  left: `${Math.min(cropSelection.x, cropSelection.x + cropSelection.width)}px`,
  top: `${Math.min(cropSelection.y, cropSelection.y + cropSelection.height)}px`,
  width: `${Math.abs(cropSelection.width)}px`,
  height: `${Math.abs(cropSelection.height)}px`,
}))

const hasCropSelection = computed(() => Math.abs(cropSelection.width) >= 8 && Math.abs(cropSelection.height) >= 8)

const batchableImageIds = computed(() => current.value?.images.filter((item) => item.available).map((item) => item.id) || [])
const selectedBatchIds = computed(() => selectedImageIds.value.filter((id) => batchableImageIds.value.includes(id)))
const batchSelectionLabel = computed(() => `${selectedBatchIds.value.length} / ${batchableImageIds.value.length}`)
// Tri-state "All pages" checkbox (matches the Flutter rail header): unchecked
// selects every batchable page, checked or indeterminate clears the selection.
const allBatchSelected = computed(
  () => batchableImageIds.value.length > 0 && selectedBatchIds.value.length === batchableImageIds.value.length,
)
const batchSelectionIndeterminate = computed(() => selectedBatchIds.value.length > 0 && !allBatchSelected.value)

// The pages the toolbar's shared rotate/deskew/luminance/delete buttons act
// on — same rule as the Flutter toolbar's `targetIds`: a non-empty tick list
// wins, in PAGE order (so a batch call and its audit entry read the way the
// rail looks); with nothing ticked it falls back to the page on screen, which
// is what keeps every single-page click working unticked.
const luminanceAvailable = computed(() => current.value?.luminanceEnabled === true)

const targetImageIds = computed(() => {
  if (selectedBatchIds.value.length) {
    const order = current.value?.images.map((item) => item.id) ?? []
    return order.filter((id) => selectedBatchIds.value.includes(id))
  }
  return image.value ? [image.value.id] : []
})

// An image operation is in flight — separate from metadataSaving/draftSaving
// so the metadata panel doesn't grey out while a page is being rotated.
const toolbarBusy = computed(() => actionLoading.value || luminanceLoading.value || cropLoading.value || separationApplying.value)
// Unapplied marks must not be saved/approved/rejected without the reviewer noticing.
const separationBlocking = computed(() => separationMode.value || separationApplying.value)
const toolsEnabled = computed(() => current.value?.status === 'reviewing' && !toolbarBusy.value)
const isTaskSettled = computed(() => current.value?.status === 'passed' || current.value?.status === 'rework')
const canMoveImageUp = computed(() => toolsEnabled.value && currentImageIndex.value > 1)
const canMoveImageDown = computed(() => toolsEnabled.value && !!current.value && currentImageIndex.value < current.value.imageCount)

// Says the count in the tooltip so a click's reach is visible without
// counting ticks — matches the Flutter toolbar's `batched()`.
function batched(label: string) {
  const count = targetImageIds.value.length
  return count > 1 ? `${label} (${count} pages)` : label
}
// --- Folder separation (splitting one folder into several) ---------------------
const separationMarkerIds = computed(() => current.value?.images.filter((item) => item.separationStart).map((item) => item.id) || [])
// The server sends page 1 as a start too once any extra marker exists; the
// extras are what the PUT carries and what the preview toggles.
const appliedExtraStartIds = computed(() => {
  const firstId = current.value?.images[0]?.id
  return separationMarkerIds.value.filter((id) => id !== firstId)
})
const separationGroupsShown = computed(
  () => current.value?.status === 'reviewing' && (separationMode.value || appliedExtraStartIds.value.length > 0),
)
// Per image id: which folder it would land in and how big that folder is.
const separationGroupById = computed(() => {
  const map = new Map<number, { folder: number; pages: number; first: boolean }>()
  const images = current.value?.images || []
  if (!separationGroupsShown.value || !images.length) return map
  const starts = separationMode.value ? separationSelection.value : new Set(appliedExtraStartIds.value)
  const groups: number[][] = []
  images.forEach((item, index) => {
    if (index === 0 || starts.has(item.id)) groups.push([])
    groups[groups.length - 1].push(item.id)
  })
  groups.forEach((ids, groupIndex) =>
    ids.forEach((id, i) => map.set(id, { folder: groupIndex + 1, pages: ids.length, first: i === 0 })),
  )
  return map
})
// "1–2, 3–4, 5" for the confirm dialog, from the CURRENT order and applied markers.
function splitRanges(): string[] {
  const images = current.value?.images || []
  const starts = new Set(appliedExtraStartIds.value)
  const ranges: string[] = []
  let from = 0
  images.forEach((item, index) => {
    if (index > 0 && starts.has(item.id)) {
      ranges.push(from + 1 === index ? `${index}` : `${from + 1}–${index}`)
      from = index
    }
  })
  ranges.push(from + 1 === images.length ? `${images.length}` : `${from + 1}–${images.length}`)
  return ranges
}

// --- Metadata form: fields, template, dirty check, validation ------------------
// The fields shown in the metadata panel/dialog. Whether each one is REQUIRED
// comes from the template (the backend ships archivalRefNo as optional), not
// from membership in this list.
const editableMetadataKeys: Array<keyof EditableFolderMetadata> = [
  'coverTag',
  'title',
  'volume',
  'startDate',
  'endDate',
  'archivalRefNo',
]

// Mirrors the backend DEFAULT_METADATA_TEMPLATE for folders without one.
const fallbackMandatoryByKey: Partial<Record<keyof EditableFolderMetadata, boolean>> = {
  coverTag: true,
  title: true,
  volume: true,
  startDate: true,
  endDate: true,
  archivalRefNo: false,
}

function fallbackEditableField(key: keyof EditableFolderMetadata): MetadataTemplateField {
  return {
    key,
    label: t(`qc.fields.${key}`),
    input: 'text',
    mandatory: fallbackMandatoryByKey[key] ?? true,
    exported: true,
    options: [],
  }
}

// A project that DISABLES a field (`enabled: false`) has no entry for it: the
// backend drops it from the template, and `validate_metadata_for_approval`
// iterates that same list, so it never asks for it. Falling back per key
// therefore REINVENTED a disabled field as a mandatory free-text box and
// blocked an approval the engine would have accepted - "This field is
// required: Cover tag", with nothing the reviewer could legitimately type.
// The fallback is for a folder whose project carries no template at all.
const editableTemplateFields = computed<MetadataTemplateField[]>(() => {
  const templateFields = current.value?.metadataTemplate.fields ?? []
  if (!templateFields.length) return editableMetadataKeys.map(fallbackEditableField)
  return editableMetadataKeys
    .map((key) => templateFields.find((field) => field.key === key))
    .filter((field): field is MetadataTemplateField => Boolean(field))
    .map((field) => ({ ...field }))
})

const metadataPayloadKeys: Array<keyof EditableFolderMetadata> = [
  'coverTag',
  'imageTags',
  'title',
  'volume',
  'startDate',
  'endDate',
  'archivalRefNo',
  'recordType',
  'place',
  'language',
  'recordCustodian',
  'captureOperatorId',
  'captureOperatorName',
  'digitizingEntity',
]

const metadataDirty = computed(() => {
  const metadata = current.value?.metadata
  if (!metadata) return false
  return metadataPayloadKeys.some((key) => {
    // Compare dates in canonical form: the form holds '<year>-01-01T00:00:00Z'
    // while the API returns PostgreSQL's offset (e.g. '+07:20'), so a raw string
    // compare would report every folder as permanently unsaved.
    if (isDateFieldKey(key)) {
      return normalizeMetadataValue(canonicalDateValue(metadataForm[key])) !==
        normalizeMetadataValue(canonicalDateValue(metadata[key]))
    }
    return normalizeMetadataValue(metadataForm[key]) !== normalizeMetadataValue(metadata[key])
  })
})

const hasUnsavedChanges = computed(() => Boolean(current.value?.hasDraft) || metadataDirty.value)
const savingChanges = computed(() => draftSaving.value || metadataSaving.value)

// Merge a task returned by any draft-changing call into the screen: keeps the
// selected page (or its position), hides draft-deleted pages, prunes stale ticks.
function applyTaskUpdate(task: MetadataQcTask, selectedImageId?: number | null) {
  const visibleImages = task.images.filter((item) => item.draftState !== 'deleted')
  const visibleTask = { ...task, images: visibleImages, imageCount: visibleImages.length }
  const previousIndex = current.value?.images.findIndex((item) => item.id === image.value?.id) ?? -1
  current.value = visibleTask
  claimedTask.value = visibleTask.status === 'reviewing' ? visibleTask : claimedTask.value
  const nextImageId = selectedImageId ?? image.value?.id
  // id match first; a draft page (negative id) gets a real id on Save, so then keep the same position
  image.value =
    visibleTask.images.find((item) => item.id === nextImageId) ||
    (previousIndex >= 0 ? visibleTask.images[Math.min(previousIndex, visibleTask.images.length - 1)] : undefined) ||
    visibleTask.images[0] ||
    null
  syncRejectReasons(rejectedImageIds.value.filter((id) => visibleTask.images.some((item) => item.id === id)), false)
  rejectedImageIds.value = rejectedImageIds.value.filter((id) => visibleTask.images.some((item) => item.id === id))
  selectedImageIds.value = selectedImageIds.value.filter((id) => visibleTask.images.some((item) => item.id === id))
  const listIndex = tasks.value.findIndex((item) => item.id === visibleTask.id)
  if (listIndex >= 0) tasks.value[listIndex] = visibleTask
}

function isDateFieldKey(key: string) {
  return key === 'startDate' || key === 'endDate'
}

/**
 * The value a date field holds in the form: a bare year, e.g. '1939'.
 *
 * Dates are keyed as years — the template offers years as options, and when the
 * folder's template omits the field it falls back to a plain text input. The API
 * returns what PostgreSQL stores, offset and all ('1939-01-01T00:00:00+07:20',
 * since Asia/Singapore ran on +07:20 that year), which rendered as an unmatched
 * select option (blank) or as that raw string in a text box.
 *
 * The year comes from the leading digits and NOT from a UTC conversion:
 * 1939-01-01T00:00:00+07:20 in UTC is 1938-12-31, which would show 1938. The two
 * fields don't even share an offset — 1945 is stored at +09 — so nothing
 * offset-based is consistent. The backend coerces a 4-digit year back to a
 * datetime (metadata_date), so a year is a valid value to send.
 */
function canonicalDateValue(value: unknown): string | null {
  if (typeof value !== 'string' || !value.trim()) return null
  return /^(\d{4})/.exec(value.trim())?.[1] ?? value
}

function displayOption(option: string) {
  return option
}

function normalizeMetadataValue(value: unknown) {
  return value === null || value === undefined ? '' : String(value)
}

function titleRecordType(title: string | null | undefined) {
  if (!title || !current.value) return null
  return current.value.metadataTemplate.titleRecordTypeMap[title] || null
}

function syncDerivedMetadataFields() {
  if (!current.value) return
  const fields = current.value.metadataTemplate.fields
  const form = metadataForm as Record<string, string | null | undefined>
  for (const field of fields) {
    if (field.input === 'fixed') {
      form[field.key] = field.value ?? null
    }
  }
  // Mapped fields are derived here so the reviewer SEES the value the engine
  // will store, instead of a blank box that fills in only after saving.
  // Resolved ONE level deep against an editable source, exactly as the engine's
  // apply_template_mappings does - a mapped-from-mapped or mapped-from-fixed
  // chain derives null rather than recursing, so evaluation order cannot
  // matter. A source value the map does not cover derives null too: that can
  // block approval on a mandatory field, which is honest, because the reviewer
  // cannot type it and the template has a hole.
  const fieldByKey = new Map(fields.map((field) => [field.key as string, field]))
  for (const field of fields) {
    if (field.input !== 'mapped') continue
    const sourceKey = field.mappedFrom
    const source = sourceKey ? fieldByKey.get(sourceKey) : undefined
    const sourceIsEditable = source?.input === 'text' || source?.input === 'select'
    if (!sourceKey || sourceKey === field.key || !sourceIsEditable) {
      form[field.key] = null
      continue
    }
    const sourceValue = form[sourceKey]
    form[field.key] = sourceValue ? (field.valueMap?.[sourceValue] ?? null) : null
  }
  metadataForm.recordType = titleRecordType(metadataForm.title) ?? null
}

function hasMetadataValue(value: unknown) {
  return value !== null && value !== undefined && String(value).trim() !== ''
}

function requiredMissingFromMetadata(metadata: Record<string, unknown>) {
  // Only mandatory fields block save/approve — archivalRefNo is shown here but
  // the template marks it optional.
  return editableTemplateFields.value.filter(
    (field) => field.mandatory && !hasMetadataValue(metadata[field.key]),
  )
}

function requiredMissingFromForm() {
  return requiredMissingFromMetadata(metadataForm as unknown as Record<string, unknown>)
}

function validateCurrentBeforeApprove() {
  const task = current.value
  if (!task) return false
  const missing = requiredMissingFromMetadata(task.metadata as unknown as Record<string, unknown>)
  if (missing.length) {
    ElMessage.warning(`${t('qc.requiredMissing')}: ${missing.map((field) => field.label).join(', ')}`)
    return false
  }
  return true
}

// --- Loading, claiming and routing --------------------------------------------
// Fills the Pending / Mine / Completed counters (page size 1: only the total is used).
async function loadScopeTotals() {
  const scopes: QcScope[] = ['pending', 'mine', 'completed']
  const results = await Promise.allSettled(
    scopes.map((scope) => qcApi.tasks({ scope, page: 1, size: 1 })),
  )
  results.forEach((result, index) => {
    if (result.status === 'fulfilled') {
      scopeTotals[scopes[index]] = result.value.data.data.total
    }
  })
}

function scopeFromRouteName(): QcScope {
  if (route.name === 'qc-my-tasks' || route.name === 'qc-review') return 'mine'
  if (route.name === 'qc-completed') return 'completed'
  return 'pending'
}

function reviewTaskId() {
  const id = Number(route.params.id)
  return Number.isFinite(id) ? id : null
}

function syncActiveFromRoute() {
  active.value = scopeFromRouteName()
}

function clearCurrentTask() {
  current.value = null
  claimedTask.value = null
  image.value = null
  selectedImageIds.value = []
  exitSeparationMode()
}

async function releaseCurrent() {
  const task = claimedTask.value
  if (task?.status !== 'reviewing') return
  try {
    await qcApi.release(task.id)
  } catch {
    // The task may already be completed or released.
  }
  claimedTask.value = null
}

async function load() {
  loading.value = true
  try {
    if (isReviewRoute.value) {
      const taskId = reviewTaskId()
      if (!taskId) {
        clearCurrentTask()
        return
      }
      const { data } = await qcApi.detail(taskId)
      current.value = data.data
      claimedTask.value = data.data.status === 'reviewing' ? data.data : null
      image.value = data.data.images[0] || null
      selectedImageIds.value = []
      return
    }
    const { data } = await qcApi.tasks({ scope: active.value, page: 1, size: 100 })
    tasks.value = data.data.records
    scopeTotals[active.value] = data.data.total
    if (active.value === 'mine') {
      const mine = data.data.records[0]
      if (mine) {
        const detail = await qcApi.detail(mine.id)
        current.value = detail.data.data
        claimedTask.value = detail.data.data
        image.value = detail.data.data.images[0] || null
        selectedImageIds.value = []
      } else {
        current.value = null
        claimedTask.value = null
        image.value = null
        selectedImageIds.value = []
      }
    } else {
      clearCurrentTask()
    }
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

async function refreshPage() {
  await Promise.all([load(), loadScopeTotals()])
}

async function open(task: MetadataQcTask) {
  if (task.status === 'pending' && claimedTask.value && claimedTask.value.id !== task.id) {
    ElMessage.warning(t('qc.finishCurrentFirst'))
    return
  }
  detailLoading.value = true
  try {
    const response = task.status === 'pending' ? await qcApi.claim(task.id) : await qcApi.detail(task.id)
    current.value = response.data.data
    if (response.data.data.status === 'reviewing') claimedTask.value = response.data.data
    image.value = response.data.data.images[0] || null
    selectedImageIds.value = []
    if (task.status === 'pending') await router.push({ name: 'qc-review', params: { id: response.data.data.id } })
  } catch (error) {
    ElMessage.error((error as Error).message)
    await load()
  } finally {
    detailLoading.value = false
  }
}

async function claimNext() {
  detailLoading.value = true
  try {
    const { data } = await qcApi.claimNext()
    current.value = data.data
    claimedTask.value = data.data
    image.value = data.data.images[0] || null
    selectedImageIds.value = []
    active.value = 'mine'
    await router.push({ name: 'qc-review', params: { id: data.data.id } })
    return true
  } catch (error) {
    // An empty queue is the normal end of a review session — after approving
    // the last folder there is nothing left to claim. Not an error.
    if ((error as ApiError).status === 404) {
      ElMessage.info(t('qc.noMoreTasks'))
    } else {
      ElMessage.error((error as Error).message)
    }
    return false
  } finally {
    detailLoading.value = false
  }
}

async function loadMineKeepingCurrent(task: MetadataQcTask) {
  const { data } = await qcApi.tasks({ scope: 'mine', page: 1, size: 100 })
  tasks.value = data.data.records
  scopeTotals.mine = data.data.total
  current.value = task
  claimedTask.value = task
  image.value = task.images[0] || null
  selectedImageIds.value = []
}

// Is there anything to offer at all? Ported from the Flutter desk
// (qc_home_page.dart `openQcReview` / qc_controller.dart
// `nextUpAfterCompletion`), which asks this BEFORE prompting.
async function somethingIsWaiting(): Promise<boolean> {
  try {
    const mine = await qcApi.tasks({ scope: 'mine', page: 1, size: 100 })
    if (mine.data.data.records.some((task: MetadataQcTask) => task.imageAvailable)) return true
    // Deliberately a COUNT and not claimNext(): the reviewer has not agreed to
    // take anything yet, and claiming in order to discover whether a claim was
    // possible would leave a folder locked to somebody who then said no.
    const pending = await qcApi.tasks({ scope: 'pending', page: 1, size: 1 })
    return pending.data.data.total > 0
  } catch {
    // A failed probe must not strand the reviewer on the folder they just
    // finished. Fall back to asking, which is what happened before this existed.
    return true
  }
}

async function promptNextTaskOrClose() {
  if (!(await somethingIsWaiting())) {
    // Nothing held and nothing waiting, so there is nothing to ask about.
    clearCurrentTask()
    await router.push('/qc/tasks')
    return
  }
  try {
    await ElMessageBox.confirm(t('qc.nextTaskPrompt'), t('qc.title'), {
      type: 'success',
      confirmButtonText: t('qc.claimNext'),
      cancelButtonText: t('common.close'),
      distinguishCancelAndClose: false,
    })
    const claimed = await claimNext()
    if (!claimed) {
      // Somebody else took it between the probe and the claim. The desk renders
      // whenever `current` is set — leaving the approved folder in it made the
      // UI look like the approval hadn't happened.
      clearCurrentTask()
      await router.push('/qc/tasks')
    }
  } catch {
    // Declined. Available, not My tasks: the reviewer holds nothing now.
    clearCurrentTask()
    await router.push('/qc/tasks')
  }
}

// --- Approve, revert and reject -----------------------------------------------
async function approve() {
  if (current.value?.status !== 'reviewing') return
  if (!validateCurrentBeforeApprove()) return
  const hasUnsaved = current.value.hasDraft || metadataDirty.value
  if (appliedExtraStartIds.value.length) {
    // The split confirmation replaces the plain one - it says more.
    if (!(await confirmSplit('qc.splitApproveConfirm', 'qc.splitFolder'))) return
  } else {
    await ElMessageBox.confirm(
      t(hasUnsaved ? 'qc.approveWithDraftConfirm' : 'qc.approveConfirm', { pages: current.value.images.length }),
      t('qc.title'),
      { type: 'info' },
    )
  }
  actionLoading.value = true
  try {
    // Typed-but-unsaved metadata is committed here rather than lost. Image
    // edits already survive - the engine's approve_task commits the draft
    // itself - but the metadata FORM is a separate save, so forgetting the
    // button silently discarded the reviewer's keying. The confirmation above
    // has always promised this happens; now it does.
    //
    // Silent, because the approve toast follows immediately, and awaited
    // before reading sourceHash again: a successful save issues a NEW hash,
    // and approving with the stale one is a 409 the reviewer cannot act on.
    if (metadataDirty.value && !(await saveMetadata({ silent: true }))) return
    if (current.value?.status !== 'reviewing') return
    await qcApi.approve(current.value.id, current.value.sourceHash)
    ElMessage.success(t('qc.passed'))
    claimedTask.value = null
    await promptNextTaskOrClose()
  } catch (error) {
    await handleVersionOrActionError(error)
  } finally {
    actionLoading.value = false
  }
}

function jumpToImageFromAiEvidence(imageId: number) {
  const item = current.value?.images.find((candidate) => candidate.id === imageId)
  if (item) image.value = item
}

async function revertCurrentTask() {
  if (!current.value || current.value.status !== 'passed') return
  try {
    await ElMessageBox.confirm(t('qc.revertConfirm'), t('qc.title'), { type: 'warning' })
  } catch {
    return
  }
  detailLoading.value = true
  try {
    const { data } = await qcApi.revert(current.value.id, current.value.sourceHash)
    current.value = data.data
    claimedTask.value = data.data
    image.value = data.data.images[0] || null
    selectedImageIds.value = []
    active.value = 'mine'
    ElMessage.success(t('qc.revertDone'))
    await router.push({ name: 'qc-review', params: { id: data.data.id } })
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    detailLoading.value = false
  }
}

async function openRejectDialog() {
  if (current.value?.hasDraft) {
    try {
      await ElMessageBox.confirm(t('qc.discardDraftConfirm'), t('qc.title'), { type: 'warning' })
    } catch {
      return
    }
  }
  // ticked (else previewed) pages plus every existing page with a typed remark, in page order
  const order = current.value?.images.map((item) => item.id) ?? []
  const wanted = new Set([...targetImageIds.value, ...order.filter((id) => (rejectReasons[id] || '').trim())])
  const imageIds = order.filter((id) => wanted.has(id))
  rejectedImageIds.value = imageIds
  syncRejectReasons(imageIds)
  rejectDialogVisible.value = true
}

async function submitReject() {
  if (current.value?.status !== 'reviewing') return
  if (!rejectedImageIds.value.length) {
    ElMessage.warning(t('qc.rejectImagesRequired'))
    return
  }
  const rejectedImages = rejectedImageIds.value.map((imageId) => ({
    imageId,
    rejectReason: (rejectReasons[imageId] || '').trim(),
  }))
  const missingReason = rejectedImages.find((item) => !item.rejectReason)
  if (missingReason) {
    ElMessage.warning(t('qc.rejectReasonRequired'))
    return
  }
  actionLoading.value = true
  try {
    await qcApi.reject(
      current.value.id,
      current.value.sourceHash,
      rejectedImages,
    )
    rejectDialogVisible.value = false
    resetRejectState()
    ElMessage.success(t('qc.rejected'))
    claimedTask.value = null
    await promptNextTaskOrClose()
  } catch (error) {
    const status = (error as ApiError).status
    if (status === 400 || status === 422) {
      // e.g. a page added in QC can't be recaptured: stay, dialog stays open to adjust
      ElMessage.error((error as Error).message)
    } else {
      rejectDialogVisible.value = false
      await handleVersionOrActionError(error)
    }
  } finally {
    actionLoading.value = false
  }
}

// --- Metadata save and error handling -----------------------------------------
function fillMetadataFormFromCurrent() {
  if (!current.value) return
  const metadata = current.value.metadata
  Object.assign(metadataForm, {
    coverTag: metadata.coverTag ?? null,
    imageTags: metadata.imageTags ?? null,
    title: metadata.title ?? null,
    volume: metadata.volume ?? null,
    // Canonicalized so the year matches an option and renders — see
    // canonicalDateValue.
    startDate: canonicalDateValue(metadata.startDate),
    endDate: canonicalDateValue(metadata.endDate),
    archivalRefNo: metadata.archivalRefNo ?? null,
    recordType: metadata.recordType ?? null,
    place: metadata.place ?? null,
    language: metadata.language ?? null,
    recordCustodian: metadata.recordCustodian ?? null,
    captureOperatorId: metadata.captureOperatorId ?? null,
    captureOperatorName: metadata.captureOperatorName ?? null,
    digitizingEntity: metadata.digitizingEntity ?? null,
  })
  syncDerivedMetadataFields()
}

/**
 * Returns whether the save succeeded. Approve needs to know: on failure
 * `handleVersionOrActionError` clears the current task, so carrying on would
 * approve nothing at best and dereference null at worst.
 */
async function saveMetadata(options: { silent?: boolean } = {}): Promise<boolean> {
  // Not "saved" - nothing was. Approve treats this as a failure and stops,
  // which is right: a folder that is no longer being reviewed must not be
  // approved on the strength of a form the reviewer can no longer commit.
  if (current.value?.status !== 'reviewing') return false
  syncDerivedMetadataFields()
  const missing = requiredMissingFromForm()
  if (missing.length) {
    ElMessage.warning(`${t('qc.requiredMissing')}: ${missing.map((field) => field.label).join(', ')}`)
  }
  metadataSaving.value = true
  try {
    const selectedImageId = image.value?.id
    const metadataPayload: EditableFolderMetadata = {
      coverTag: metadataForm.coverTag ?? null,
      imageTags: metadataForm.imageTags ?? null,
      title: metadataForm.title ?? null,
      volume: metadataForm.volume ?? null,
      startDate: metadataForm.startDate ?? null,
      endDate: metadataForm.endDate ?? null,
      archivalRefNo: metadataForm.archivalRefNo ?? null,
      recordType: metadataForm.recordType ?? null,
      place: metadataForm.place ?? null,
      language: metadataForm.language ?? null,
      recordCustodian: metadataForm.recordCustodian ?? null,
      captureOperatorId: metadataForm.captureOperatorId ?? null,
      captureOperatorName: metadataForm.captureOperatorName ?? null,
      digitizingEntity: metadataForm.digitizingEntity ?? null,
    }
    const { data } = await qcApi.updateMetadata(
      current.value.id,
      current.value.sourceHash,
      metadataPayload,
    )
    current.value = data.data
    claimedTask.value = data.data
    const listIndex = tasks.value.findIndex((task) => task.id === data.data.id)
    if (listIndex >= 0) tasks.value[listIndex] = data.data
    image.value = data.data.images.find((item) => item.id === selectedImageId) || data.data.images[0] || null
    if (!options.silent) ElMessage.success(t('qc.metadataSaved'))
    return true
  } catch (error) {
    await handleVersionOrActionError(error)
    return false
  } finally {
    metadataSaving.value = false
  }
}

// Separation refusals are the reviewer's to fix (400): show the message and
// stay in the task. Only a version conflict (409) or anything unexpected kicks out.
async function handleStayOrKickOut(error: unknown) {
  const status = (error as ApiError).status
  if (status === 400 || status === 422) ElMessage.error((error as Error).message)
  else await handleVersionOrActionError(error)
}

async function handleVersionOrActionError(error: unknown) {
  ElMessage.error((error as Error).message)
  clearCurrentTask()
  if (isReviewRoute.value) await router.push('/qc/my-tasks')
  else await load()
}

// --- Preview viewer, crop mode and page keyboard navigation -------------------
function openViewer() {
  if (cropMode.value) return // the overlay blocks clicks anyway — insurance
  if (previewSrc.value) viewerVisible.value = true
}

function resetCropSelection() {
  cropSelection.x = 0
  cropSelection.y = 0
  cropSelection.width = 0
  cropSelection.height = 0
}

const canCrop = computed(
  () => current.value?.status === 'reviewing' && !!image.value?.available && !!previewSrc.value,
)

function toggleCropMode() {
  if (cropMode.value) exitCropMode()
  else enterCropMode()
}

function enterCropMode() {
  // naturalWidth === 0 means the img hasn't decoded yet — the natural-px
  // conversion would produce garbage, so refuse until @load re-enables us.
  if (!canCrop.value || !cropImageEl.value || cropImageEl.value.naturalWidth === 0) return
  if (separationMode.value) exitSeparationMode()
  resetCropSelection()
  syncCropOverlayBox()
  cropMode.value = true
  cropResizeObserver = new ResizeObserver(syncCropOverlayBox)
  if (previewCanvasEl.value) cropResizeObserver.observe(previewCanvasEl.value)
  window.addEventListener('keydown', onCropKeydown)
}

function exitCropMode() {
  cropMode.value = false
  stopCropDrag()
  resetCropSelection()
  cropResizeObserver?.disconnect()
  cropResizeObserver = null
  window.removeEventListener('keydown', onCropKeydown)
}

function onCropKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape') exitCropMode()
}

// Left/Right page the viewer. Scoped to the rail-and-viewer subtree (attached
// directly on those two elements below, not window/document) so it never
// competes with caret movement in the metadata text fields — the same
// regression the Flutter reference guards against in qc_review_page_test.dart.
function focusPagingRoot(event: MouseEvent) {
  ;(event.currentTarget as HTMLElement | null)?.focus()
}

function onPageNavKeydown(event: KeyboardEvent) {
  if (cropMode.value) return
  if (event.ctrlKey || event.shiftKey || event.altKey || event.metaKey) return
  if (!current.value) return
  if (event.key === 'ArrowLeft') {
    if (currentImageIndex.value > 1) {
      event.preventDefault()
      image.value = current.value.images[currentImageIndex.value - 2]
    }
  } else if (event.key === 'ArrowRight') {
    if (currentImageIndex.value < current.value.imageCount) {
      event.preventDefault()
      image.value = current.value.images[currentImageIndex.value]
    }
  }
}

/** Glue the overlay to the rendered img box (letterboxed by object-fit within
 *  the flex canvas), and keep an existing selection proportionally in place
 *  when the box resizes (window resize, sidebar collapse, responsive reflow). */
function syncCropOverlayBox() {
  const img = cropImageEl.value
  const canvas = previewCanvasEl.value
  if (!img || !canvas) return
  const imgRect = img.getBoundingClientRect()
  const canvasRect = canvas.getBoundingClientRect()
  const prevWidth = cropOverlayBox.width
  const prevHeight = cropOverlayBox.height
  cropOverlayBox.left = imgRect.left - canvasRect.left
  cropOverlayBox.top = imgRect.top - canvasRect.top
  cropOverlayBox.width = imgRect.width
  cropOverlayBox.height = imgRect.height
  if (hasCropSelection.value && prevWidth > 0 && prevHeight > 0 && (prevWidth !== imgRect.width || prevHeight !== imgRect.height)) {
    const fx = imgRect.width / prevWidth
    const fy = imgRect.height / prevHeight
    cropSelection.x *= fx
    cropSelection.width *= fx
    cropSelection.y *= fy
    cropSelection.height *= fy
  }
}

function clampCropPoint(event: PointerEvent) {
  const element = cropImageEl.value
  if (!element) return { x: 0, y: 0 }
  const rect = element.getBoundingClientRect()
  return {
    x: Math.min(rect.width, Math.max(0, event.clientX - rect.left)),
    y: Math.min(rect.height, Math.max(0, event.clientY - rect.top)),
  }
}

function normalizedSelection() {
  return {
    x: Math.min(cropSelection.x, cropSelection.x + cropSelection.width),
    y: Math.min(cropSelection.y, cropSelection.y + cropSelection.height),
    width: Math.abs(cropSelection.width),
    height: Math.abs(cropSelection.height),
  }
}

function beginCropDrag(kind: 'draw' | 'move' | 'resize', event: PointerEvent, handle?: CropHandle) {
  event.preventDefault()
  cropDrag.value = { kind, handle, start: clampCropPoint(event), orig: normalizedSelection() }
  window.addEventListener('pointermove', onCropDragMove)
  window.addEventListener('pointerup', stopCropDrag)
}

function startCropDraw(event: PointerEvent) {
  const point = clampCropPoint(event)
  cropSelection.x = point.x
  cropSelection.y = point.y
  cropSelection.width = 0
  cropSelection.height = 0
  beginCropDrag('draw', event)
}

function startCropMove(event: PointerEvent) {
  beginCropDrag('move', event)
}

function startCropResize(handle: CropHandle, event: PointerEvent) {
  beginCropDrag('resize', event, handle)
}

function onCropDragMove(event: PointerEvent) {
  const drag = cropDrag.value
  const img = cropImageEl.value
  if (!drag || !img) return
  const point = clampCropPoint(event)
  const rect = img.getBoundingClientRect()
  const dx = point.x - drag.start.x
  const dy = point.y - drag.start.y

  if (drag.kind === 'draw') {
    cropSelection.width = point.x - drag.start.x
    cropSelection.height = point.y - drag.start.y
    return
  }
  if (drag.kind === 'move') {
    cropSelection.x = Math.min(rect.width - drag.orig.width, Math.max(0, drag.orig.x + dx))
    cropSelection.y = Math.min(rect.height - drag.orig.height, Math.max(0, drag.orig.y + dy))
    cropSelection.width = drag.orig.width
    cropSelection.height = drag.orig.height
    return
  }
  // resize — edge model; a corner handle hits two branches. Edges pin at
  // CROP_MIN so the frame can't flip through itself.
  const handle = drag.handle ?? 'se'
  let left = drag.orig.x
  let top = drag.orig.y
  let right = left + drag.orig.width
  let bottom = top + drag.orig.height
  if (handle.includes('w')) left = Math.min(right - CROP_MIN, Math.max(0, drag.orig.x + dx))
  if (handle.includes('e')) right = Math.max(left + CROP_MIN, Math.min(rect.width, drag.orig.x + drag.orig.width + dx))
  if (handle.includes('n')) top = Math.min(bottom - CROP_MIN, Math.max(0, drag.orig.y + dy))
  if (handle.includes('s')) bottom = Math.max(top + CROP_MIN, Math.min(rect.height, drag.orig.y + drag.orig.height + dy))
  cropSelection.x = left
  cropSelection.y = top
  cropSelection.width = right - left
  cropSelection.height = bottom - top
}

function stopCropDrag() {
  const wasDraw = cropDrag.value?.kind === 'draw'
  cropDrag.value = null
  window.removeEventListener('pointermove', onCropDragMove)
  window.removeEventListener('pointerup', stopCropDrag)
  if (wasDraw) {
    if (!hasCropSelection.value) {
      resetCropSelection() // a stray click leaves no selection
    } else {
      Object.assign(cropSelection, normalizedSelection())
    }
  }
}

function cropRectInNaturalPixels(): CropRect | null {
  const element = cropImageEl.value
  if (!element || !hasCropSelection.value) return null
  const rect = element.getBoundingClientRect()
  const left = Math.min(cropSelection.x, cropSelection.x + cropSelection.width)
  const top = Math.min(cropSelection.y, cropSelection.y + cropSelection.height)
  const width = Math.abs(cropSelection.width)
  const height = Math.abs(cropSelection.height)
  const scaleX = element.naturalWidth / rect.width
  const scaleY = element.naturalHeight / rect.height
  const x = Math.max(0, Math.min(element.naturalWidth - 1, Math.round(left * scaleX)))
  const y = Math.max(0, Math.min(element.naturalHeight - 1, Math.round(top * scaleY)))
  return {
    x,
    y,
    width: Math.max(1, Math.min(element.naturalWidth - x, Math.round(width * scaleX))),
    height: Math.max(1, Math.min(element.naturalHeight - y, Math.round(height * scaleY))),
    previewWidth: element.naturalWidth,
    previewHeight: element.naturalHeight,
  }
}

async function submitCrop() {
  if (current.value?.status !== 'reviewing' || !image.value) return
  const rect = cropRectInNaturalPixels()
  if (!rect) {
    ElMessage.warning(t('qc.cropAreaRequired'))
    return
  }
  cropLoading.value = true
  try {
    const selectedImageId = image.value.id
    const { data } = await qcApi.cropImage(
      current.value.id,
      selectedImageId,
      current.value.sourceHash,
      rect,
    )
    // Same path as every other image action — gains the deleted-image
    // filtering and selection pruning the old manual sync skipped.
    applyTaskUpdate(data.data, selectedImageId)
    exitCropMode()
    ElMessage.success(t('qc.cropSaved'))
  } catch (error) {
    exitCropMode()
    await handleVersionOrActionError(error)
  } finally {
    cropLoading.value = false
  }
}

// --- Page selection, reject remarks and image tools ---------------------------
function toggleImageSelection(imageId: number, checked: boolean) {
  if (!batchableImageIds.value.includes(imageId)) return
  if (checked && !selectedImageIds.value.includes(imageId)) {
    selectedImageIds.value = [...selectedImageIds.value, imageId]
  } else if (!checked) {
    selectedImageIds.value = selectedImageIds.value.filter((id) => id !== imageId)
  }
}

function selectAllBatchImages() {
  selectedImageIds.value = [...batchableImageIds.value]
}

function clearBatchSelection() {
  selectedImageIds.value = []
}

function toggleAllBatchSelection() {
  if (selectedBatchIds.value.length) clearBatchSelection()
  else selectAllBatchImages()
}

function onThumbnailClick(item: MetadataQcImage, index: number, event: MouseEvent) {
  const reviewing = current.value?.status === 'reviewing'
  if (reviewing && separationMode.value) {
    toggleSeparationMarker(item.id)
    image.value = item
    return
  }
  if (reviewing && event.shiftKey && current.value) {
    // Range-select between the ACTIVE image and the clicked one (active image
    // itself stays where it is — shift+click only extends the batch selection).
    const anchorIndex = current.value.images.findIndex((entry) => entry.id === image.value?.id)
    const from = anchorIndex >= 0 ? Math.min(anchorIndex, index) : index
    const to = anchorIndex >= 0 ? Math.max(anchorIndex, index) : index
    const rangeIds = current.value.images
      .slice(from, to + 1)
      .map((entry) => entry.id)
      .filter((id) => batchableImageIds.value.includes(id))
    selectedImageIds.value = [...new Set([...selectedImageIds.value, ...rangeIds])]
    return
  }
  if (reviewing && (event.ctrlKey || event.metaKey)) {
    toggleImageSelection(item.id, !selectedBatchIds.value.includes(item.id))
    return
  }
  image.value = item
}

function resetRejectState() {
  rejectedImageIds.value = []
  Object.keys(rejectReasons).forEach((key) => delete rejectReasons[Number(key)])
}

function pageLabel(imageId: number) {
  const index = current.value?.images.findIndex((item) => item.id === imageId) ?? -1
  const name = current.value?.images[index]?.filename || imageId
  return index >= 0 ? t('qc.rejectPageLabel', { page: index + 1, name }) : String(name)
}

function syncRejectReasons(ids: number[], seed = true) {
  const nextIds = new Set(ids)
  Object.keys(rejectReasons).forEach((key) => {
    const imageId = Number(key)
    if (!nextIds.has(imageId)) delete rejectReasons[imageId]
  })
  if (seed) ids.forEach((imageId) => {
    if (!(imageId in rejectReasons)) rejectReasons[imageId] = ''
  })
}

// Rotate, deskew, luminance and delete act on every ticked page — falling
// back to the page on screen when nothing is ticked — matching the Flutter
// toolbar's single button per tool rather than a separate batch button hidden
// behind a "Show more" menu.
async function luminanceTarget() {
  if (current.value?.status !== 'reviewing') return
  const ids = targetImageIds.value
  if (!ids.length) return
  luminanceLoading.value = true
  try {
    const selectedImageId = image.value?.id
    const { data } = ids.length === 1
      ? await qcApi.luminanceImage(current.value.id, ids[0], current.value.sourceHash)
      : await qcApi.luminanceBatch(current.value.id, current.value.sourceHash, ids)
    applyTaskUpdate(data.data, selectedImageId)
    ElMessage.success(t(ids.length === 1 ? 'qc.luminanceDone' : 'qc.batchLuminanceDone'))
  } catch (error) {
    await handleVersionOrActionError(error)
  } finally {
    luminanceLoading.value = false
  }
}

// Keep in step with UPLOAD_IMAGE_EXTENSIONS in backend/app/routers/qc.py — the
// backend re-checks this and also verifies the bytes are a real image.
function isSupportedImageFile(file: File) {
  return /\.(jpe?g|png|tiff?)$/i.test(file.name)
}

function triggerReplaceUpload() {
  if (current.value?.status !== 'reviewing' || !image.value) return
  replaceInputEl.value?.click()
}

function triggerInsertUpload() {
  if (current.value?.status !== 'reviewing' || !image.value) return
  insertInputEl.value?.click()
}

async function handleReplaceUpload(event: Event) {
  const target = event.target as HTMLInputElement
  const file = target.files?.[0]
  target.value = ''
  if (!file || current.value?.status !== 'reviewing' || !image.value) return
  if (!isSupportedImageFile(file)) {
    ElMessage.warning(t('qc.imageTypeOnly'))
    return
  }
  actionLoading.value = true
  try {
    const selectedImageId = image.value.id
    const { data } = await qcApi.replaceImage(current.value.id, selectedImageId, current.value.sourceHash, file)
    applyTaskUpdate(data.data, selectedImageId)
    ElMessage.success(t('qc.replaceDone'))
  } catch (error) {
    await handleVersionOrActionError(error)
  } finally {
    actionLoading.value = false
  }
}

async function handleInsertUpload(event: Event) {
  const target = event.target as HTMLInputElement
  const file = target.files?.[0]
  target.value = ''
  if (!file || current.value?.status !== 'reviewing' || !image.value) return
  if (!isSupportedImageFile(file)) {
    ElMessage.warning(t('qc.imageTypeOnly'))
    return
  }
  actionLoading.value = true
  try {
    const selectedImageId = image.value.id
    const { data } = await qcApi.insertBeforeImage(current.value.id, selectedImageId, current.value.sourceHash, file)
    applyTaskUpdate(data.data, selectedImageId)
    ElMessage.success(t('qc.insertDone'))
  } catch (error) {
    await handleVersionOrActionError(error)
  } finally {
    actionLoading.value = false
  }
}

async function runImageAction(
  action: () => Promise<{ data: { data: MetadataQcTask } }>,
  selectedImageId: number | null | undefined = image.value?.id,
  successKey = 'qc.draftUnsaved',
) {
  if (current.value?.status !== 'reviewing') return
  actionLoading.value = true
  try {
    const { data } = await action()
    applyTaskUpdate(data.data, selectedImageId)
    ElMessage.success(t(successKey))
  } catch (error) {
    await handleVersionOrActionError(error)
  } finally {
    actionLoading.value = false
  }
}

async function deleteTargetImages() {
  if (!current.value) return
  const ids = targetImageIds.value
  if (!ids.length) return
  const confirmMessage = ids.length > 1
    ? t('qc.batchDeleteConfirm', { count: ids.length })
    : t('qc.deleteConfirm', { filename: current.value.images.find((item) => item.id === ids[0])?.filename ?? '' })
  try {
    await ElMessageBox.confirm(confirmMessage, t('qc.title'), { type: 'warning' })
  } catch {
    return
  }
  const deletedIds = new Set(ids)
  await runImageAction(async () => {
    const response = ids.length === 1
      ? await qcApi.deleteImage(current.value!.id, ids[0], current.value!.sourceHash)
      : await qcApi.deleteImagesBatch(current.value!.id, current.value!.sourceHash, ids)
    const images = response.data.data.images.filter((item) => !deletedIds.has(item.id) && item.draftState !== 'deleted')
    response.data.data = { ...response.data.data, images, imageCount: images.length }
    return response
  }, null, ids.length > 1 ? 'qc.batchDeleteDone' : 'qc.deleteDone')
}

async function rotateTarget(degrees: number) {
  if (!current.value) return
  const ids = targetImageIds.value
  if (!ids.length) return
  const selectedImageId = image.value?.id
  await runImageAction(
    () => ids.length === 1
      ? qcApi.rotateImage(current.value!.id, ids[0], current.value!.sourceHash, degrees)
      : qcApi.rotateBatch(current.value!.id, current.value!.sourceHash, ids, degrees),
    selectedImageId,
    'qc.rotateDone',
  )
}

async function deskewTarget(direction: 1 | -1) {
  if (!current.value) return
  const ids = targetImageIds.value
  if (!ids.length) return
  const degrees = deskewStep.value * direction
  const selectedImageId = image.value?.id
  await runImageAction(
    () => ids.length === 1
      ? qcApi.deskewImage(current.value!.id, ids[0], current.value!.sourceHash, degrees)
      : qcApi.deskewBatch(current.value!.id, current.value!.sourceHash, ids, degrees),
    selectedImageId,
    'qc.deskewDone',
  )
}

async function restoreCurrentImage() {
  if (!current.value || !image.value) return
  const selectedImageId = image.value.id
  await runImageAction(
    () => qcApi.restoreOriginal(current.value!.id, selectedImageId, current.value!.sourceHash),
    selectedImageId,
    'qc.restoreDone',
  )
}

async function undoDraftAction() {
  if (!current.value) return
  await runImageAction(() => qcApi.undoDraft(current.value!.id), image.value?.id, 'qc.undoDone')
}

async function redoDraftAction() {
  if (!current.value) return
  await runImageAction(() => qcApi.redoDraft(current.value!.id), image.value?.id, 'qc.redoDone')
}

async function moveCurrentImage(offset: -1 | 1) {
  if (!current.value || !image.value) return
  const ids = current.value.images.map((item) => item.id)
  const index = ids.indexOf(image.value.id)
  const nextIndex = index + offset
  if (index < 0 || nextIndex < 0 || nextIndex >= ids.length) return
  const nextIds = [...ids]
  const [moved] = nextIds.splice(index, 1)
  nextIds.splice(nextIndex, 0, moved)
  const selectedImageId = image.value.id
  await runImageAction(
    () => qcApi.reorderImages(current.value!.id, current.value!.sourceHash, nextIds),
    selectedImageId,
    'qc.reorderDone',
  )
}

// --- Separation mode: mark pages that start a new child folder -----------------
function enterSeparationMode() {
  if (current.value?.status !== 'reviewing') return
  if (cropMode.value) exitCropMode()
  separationSelection.value = new Set(appliedExtraStartIds.value)
  separationMode.value = true
  window.addEventListener('keydown', onSeparationKeydown)
}

// Cancel: drops unapplied clicks only; whatever is already applied stays.
function exitSeparationMode() {
  separationMode.value = false
  separationSelection.value = new Set()
  window.removeEventListener('keydown', onSeparationKeydown)
}

function toggleSeparationMode() {
  if (separationMode.value) exitSeparationMode()
  else enterSeparationMode()
}

function onSeparationKeydown(event: KeyboardEvent) {
  // A VISIBLE Element Plus overlay owns Esc (closed dialogs keep a display:none overlay in the DOM).
  if (event.key === 'Escape' && !event.defaultPrevented && !Array.from(document.querySelectorAll<HTMLElement>('.el-overlay')).some((el) => el.style.display !== 'none') && !separationApplying.value) exitSeparationMode()
}

// Local only - nothing is sent until Apply. Page 1 is the fixed start of folder 1.
function toggleSeparationMarker(imageId: number) {
  if (imageId === current.value?.images[0]?.id) return
  const next = new Set(separationSelection.value)
  if (next.has(imageId)) next.delete(imageId)
  else next.add(imageId)
  separationSelection.value = next
}

function clearSeparationSelection() {
  separationSelection.value = new Set()
}

async function putSeparationMarkers(ids: number[]): Promise<boolean> {
  if (!current.value || current.value.status !== 'reviewing') return false
  separationApplying.value = true
  try {
    const { data } = await qcApi.updateSeparationMarkers(current.value.id, current.value.sourceHash, ids)
    applyTaskUpdate(data.data, image.value?.id)
    ElMessage.success(t('qc.separationDone'))
    return true
  } catch (error) {
    await handleStayOrKickOut(error)
    return false
  } finally {
    separationApplying.value = false
  }
}

async function applySeparation() {
  const known = new Set(current.value?.images.map((item) => item.id))
  const wanted = [...separationSelection.value].filter((id) => known.has(id))
  // Nothing changed: a PUT would only create a phantom draft + undo step.
  if (wanted.length === appliedExtraStartIds.value.length && wanted.every((id) => appliedExtraStartIds.value.includes(id))) {
    exitSeparationMode()
    return
  }
  if (await putSeparationMarkers([...separationSelection.value].filter((id) => known.has(id)))) exitSeparationMode()
}

async function removeSeparation() {
  await putSeparationMarkers([])
}

/** Asks before the irreversible split; true = go ahead. */
async function confirmSplit(bodyKey: string, confirmKey: string): Promise<boolean> {
  const ranges = splitRanges()
  try {
    await ElMessageBox.confirm(
      t(bodyKey, { n: ranges.length, ranges: ranges.join(', ') }),
      t('qc.splitTitle', { n: ranges.length }),
      { type: 'warning', confirmButtonText: t(confirmKey), cancelButtonText: t('common.cancel') },
    )
    return true
  } catch {
    return false
  }
}

// --- Draft save / discard and leaving the desk --------------------------------
/** Returns whether the image draft was saved; saveChanges stops on false. */
async function saveDraft(options: { silent?: boolean } = {}): Promise<boolean> {
  if (current.value?.status !== 'reviewing' || !current.value.hasDraft) return false
  draftSaving.value = true
  try {
    const selectedImageId = image.value?.id
    const { data } = await qcApi.saveDraft(current.value.id, current.value.sourceHash)
    applyTaskUpdate(data.data, selectedImageId)
    if (!options.silent) ElMessage.success(t('qc.draftSaved'))
    return true
  } catch (error) {
    await handleVersionOrActionError(error)
    return false
  } finally {
    draftSaving.value = false
  }
}

async function discardDraft(
  options: { silent?: boolean; skipConfirm?: boolean } = {},
): Promise<boolean> {
  if (current.value?.status !== 'reviewing' || !current.value.hasDraft) return false
  if (!options.skipConfirm) {
    try {
      await ElMessageBox.confirm(t('qc.discardDraftConfirm'), t('qc.title'), { type: 'warning' })
    } catch {
      return false
    }
  }
  draftDiscarding.value = true
  try {
    const selectedImageId = image.value?.id
    const { data } = await qcApi.discardDraft(current.value.id)
    applyTaskUpdate(data.data, selectedImageId)
    if (!options.silent) ElMessage.success(t('qc.draftDiscarded'))
    return true
  } catch (error) {
    await handleVersionOrActionError(error)
    return false
  } finally {
    draftDiscarding.value = false
  }
}

/**
 * The one save the review desk offers: image edits AND keyed metadata.
 *
 * Metadata goes first because a successful save issues a NEW sourceHash, and
 * the draft save carries that hash - sending the stale one is a 409 the
 * reviewer can do nothing about. Each step is silent so a single toast reports
 * the whole thing, and a failed step stops the next: handleVersionOrActionError
 * may have cleared the task already.
 */
async function saveChanges() {
  if (current.value?.status !== 'reviewing' || !hasUnsavedChanges.value) return
  if (appliedExtraStartIds.value.length && !(await confirmSplit('qc.splitConfirm', 'qc.splitAndSave'))) return
  if (metadataDirty.value && !(await saveMetadata({ silent: true }))) return
  if (current.value?.status !== 'reviewing') return
  if (current.value.hasDraft && !(await saveDraft({ silent: true }))) return
  ElMessage.success(t('qc.changesSaved'))
}

/** The mirror of saveChanges: drops the image draft AND the typed metadata. */
async function discardChanges() {
  if (current.value?.status !== 'reviewing' || !hasUnsavedChanges.value) return
  try {
    await ElMessageBox.confirm(t('qc.discardChangesConfirm'), t('qc.title'), { type: 'warning' })
  } catch {
    return
  }
  // Confirmed once, above - discardDraft must not ask a second time.
  if (current.value.hasDraft && !(await discardDraft({ silent: true, skipConfirm: true }))) return
  // Re-fills from the SAVED metadata, so typed-but-unsaved keying reverts with
  // the image edits rather than surviving a discard the reviewer just asked for.
  fillMetadataFormFromCurrent()
  ElMessage.success(t('qc.changesDiscarded'))
}

async function closeCurrentTask() {
  if (current.value?.status !== 'reviewing') return
  if (current.value.hasDraft) {
    try {
      await ElMessageBox.confirm(t('qc.discardDraftConfirm'), t('qc.title'), { type: 'warning' })
    } catch {
      return
    }
  }
  actionLoading.value = true
  try {
    await qcApi.release(current.value.id)
    claimedTask.value = null
    current.value = null
    image.value = null
    selectedImageIds.value = []
    await router.push('/qc/tasks')
  } catch (error) {
    await handleVersionOrActionError(error)
  } finally {
    actionLoading.value = false
  }
}

async function returnToQcTasks() {
  clearCurrentTask()
  await router.push('/qc/tasks')
}

// --- Small display helpers, watchers and lifecycle ----------------------------
function displayValue(value: unknown) {
  return value === null || value === undefined || value === '' ? t('common.notFilled') : String(value)
}

function imageName(imageId: number) {
  return current.value?.images.find((item) => item.id === imageId)?.filename || `#${imageId}`
}

function completedTime(task: MetadataQcTask) {
  return task.submittedAt || task.claimedAt
}

async function refreshForRoute() {
  syncActiveFromRoute()
  await Promise.all([load(), loadScopeTotals()])
}

watch(
  () => route.fullPath,
  () => {
    void refreshForRoute()
  },
)

watch(
  () => current.value?.id,
  () => {
    resetRejectState()
    fillMetadataFormFromCurrent()
  },
)

// previewSrc changes on image switch, rotate/undo/redo/luminance/restore, and
// task refresh — any of which invalidates an in-progress crop frame. Exiting
// here means no per-button disabling is needed anywhere else.
watch([previewSrc, () => current.value?.status], () => {
  if (cropMode.value) exitCropMode()
})
// A different task or a status change invalidates unapplied separation clicks.
watch([() => current.value?.id, () => current.value?.status], () => {
  if (separationMode.value) exitSeparationMode()
})

onMounted(refreshForRoute)
onBeforeUnmount(() => {
  exitCropMode()
  exitSeparationMode()
  if (claimedTask.value?.status === 'reviewing') {
    void qcApi.release(claimedTask.value.id).catch(() => undefined)
  }
})
</script>

<template>
  <AppShell>
    <!-- Page header: title and Pending / Mine / Completed counters (list pages only) -->
    <div v-if="showListChrome" class="qc-page-header">
      <div class="page-title qc-page-title">
        <div><h1>{{ pageTitle }}</h1><p>{{ t('qc.subtitle') }}</p></div>
        <div class="toolbar qc-toolbar">
          <el-button :icon="'Refresh'" @click="refreshPage">{{ t('common.refresh') }}</el-button>
        </div>
      </div>
      <div class="qc-summary-strip">
        <div v-for="item in summaryItems" :key="item.label" class="qc-summary-item">
          <span>{{ item.label }}</span>
          <strong>{{ item.value }}</strong>
        </div>
      </div>
    </div>

    <!-- Available (pending) queue: table of folders waiting to be claimed -->
    <section v-if="active === 'pending'" v-loading="loading || detailLoading" class="panel pending-queue-panel">
      <div class="queue-heading">
        <div>
          <p class="eyebrow">{{ t('qc.pendingQueue') }}</p>
          <h2>{{ t('qc.pendingCount', { count: tasks.length }) }}</h2>
        </div>
        <el-alert v-if="claimedTask" type="info" :closable="false" :title="t('qc.activeTaskHint', { name: claimedTask.metadata.folderName })" show-icon />
      </div>
      <el-table :data="tasks" row-key="id" class="pending-task-table" empty-text="No pending tasks">
        <el-table-column prop="metadata.projectName" :label="t('qc.fields.projectName')" min-width="170" />
        <el-table-column prop="metadata.boxName" :label="t('qc.fields.boxDetails')" min-width="160" />
        <el-table-column prop="metadata.folderName" :label="t('qc.fields.folderName')" min-width="220" />
        <el-table-column prop="imageCount" :label="t('qc.images')" width="100" align="center" />
        <el-table-column :label="t('qc.sourceTime')" min-width="180">
          <template #default="{ row }">{{ formatTimestamp(row.metadata.sourceCreatedAt) }}</template>
        </el-table-column>
        <el-table-column :label="t('common.actions')" width="130" fixed="right">
          <template #default="{ row }">
            <el-button type="primary" link :disabled="Boolean(claimedTask)" @click="open(row)">{{ t('qc.claim') }}</el-button>
          </template>
        </el-table-column>
      </el-table>
    </section>

    <!-- Review desk (My tasks / review route): header, page rail, preview, side panel, tool strip.
         The desk is a CSS grid; each child below is placed by area in the style block. -->
    <div v-else-if="active === 'mine'" class="qc-desk" :class="{ 'qc-desk--compact': isWorkbenchRoute }">
      <template v-if="current">
        <!-- Desk header: back, folder name, Release / Reject / Pass -->
        <header class="qc-desk-header">
          <el-button class="qc-back-button" :icon="'ArrowLeft'" :loading="actionLoading" @click="returnToQcTasks">
            {{ t('common.back') }}
          </el-button>
          <div class="qc-project-title">
            <strong>{{ current.metadata.folderName }}</strong>
            <span v-if="image">{{ image.filename }}</span>
          </div>
          <div v-if="current.status === 'reviewing'" class="qc-primary-actions">
            <!-- Releases the claim back to the queue; it closes nothing. -->
            <el-button :icon="'Back'" :loading="actionLoading" @click="closeCurrentTask">
              {{ t('qc.release') }}
            </el-button>
            <!-- A separated child has no recapture target the capture app can
                 find (see backend separatedFromFolder) - disabled here rather
                 than left to fail after the click. Element Plus does not fire
                 hover events on a disabled button, so the tooltip needs its
                 own wrapper element around it. -->
            <el-tooltip
              :content="t('qc.rejectDisabledSeparated')"
              placement="top"
              :disabled="!current.separatedFromFolder"
            >
              <span>
                <el-button
                  type="danger"
                  :icon="'RefreshLeft'"
                  :loading="actionLoading"
                  :disabled="current.separatedFromFolder || separationBlocking"
                  @click="openRejectDialog"
                >
                  {{ t('qc.reject') }}
                </el-button>
              </span>
            </el-tooltip>
            <el-button type="success" :icon="'Check'" :loading="actionLoading" :disabled="!current.imageAvailable || separationBlocking" @click="approve">
              {{ t('qc.pass') }}
            </el-button>
          </div>
        </header>

        <!-- Left rail: page thumbnails, tick boxes for batch actions, split-folder grouping -->
        <aside
          v-loading="loading"
          class="qc-image-rail"
          tabindex="-1"
          @click="focusPagingRoot"
          @keydown="onPageNavKeydown"
        >
          <div class="qc-rail-summary">
            <div>
              <span>{{ t('qc.imageList') }}</span>
              <strong>{{ current.imageCount }} {{ t('qc.images') }}</strong>
            </div>
            <div v-if="current.status === 'reviewing' && appliedExtraStartIds.length && !separationMode" class="qc-separation-applied">
              <span>{{ t('qc.separationApplied', { n: appliedExtraStartIds.length + 1 }) }}</span>
              <el-button size="small" :loading="separationApplying" @click="removeSeparation">
                {{ t('qc.removeSeparation') }}
              </el-button>
            </div>
            <div v-if="current.status === 'reviewing'" class="qc-batch-tools">
              <el-checkbox
                :model-value="allBatchSelected"
                :indeterminate="batchSelectionIndeterminate"
                :disabled="!batchableImageIds.length"
                @change="toggleAllBatchSelection"
              >
                {{ t('qc.batchSelected') }} {{ batchSelectionLabel }}
              </el-checkbox>
            </div>
          </div>

          <div class="qc-thumbnail-list">
            <template v-for="(item, index) in current.images" :key="item.id">
            <div
              v-if="separationGroupById.get(item.id)?.first"
              class="qc-thumbnail-group"
            >
              {{ t('qc.separationGroup', { n: separationGroupById.get(item.id)!.folder, pages: separationGroupById.get(item.id)!.pages }, separationGroupById.get(item.id)!.pages) }}
            </div>
            <button
              type="button"
              class="qc-thumbnail"
              :aria-pressed="separationMode && index > 0 ? separationSelection.has(item.id) : undefined"
              :class="{
                active: image?.id === item.id,
                selected: selectedBatchIds.includes(item.id),
                unavailable: !item.available,
                'qc-thumbnail--grouped': separationGroupById.has(item.id),
                'qc-thumbnail--stripe-b': (separationGroupById.get(item.id)?.folder ?? 1) % 2 === 0,
                'qc-thumbnail--split': separationGroupById.get(item.id)?.first && index > 0,
              }"
              :title="item.filename"
              @click="onThumbnailClick(item, index, $event)"
            >
              <span class="qc-thumbnail-preview">
                <el-icon v-if="!item.available"><WarningFilled /></el-icon>
                <ThumbnailImage v-else :src="item.previewUrl" :alt="item.filename" />
              </span>
              <el-checkbox
                v-if="current.status === 'reviewing'"
                class="qc-thumbnail-check"
                :model-value="selectedBatchIds.includes(item.id)"
                :disabled="!item.available"
                @click.stop
                @change="(checked: boolean) => toggleImageSelection(item.id, checked)"
              />
              <span class="qc-thumbnail-index">{{ String(index + 1).padStart(2, '0') }}</span>
              <span
                v-if="current.draftImageIds.includes(item.id) || item.draftState"
                class="qc-thumbnail-unsaved"
              >
                {{ t('qc.unsavedBadge') }}
              </span>
              <span v-if="separationGroupById.get(item.id)?.first" class="qc-thumbnail-starts">
                {{ index === 0 ? t('qc.separationFirst') : t('qc.separationStarts', { n: separationGroupById.get(item.id)!.folder }) }}
              </span>
            </button>
            </template>
          </div>
        </aside>

        <!-- Preview stage: the page image, with the crop overlay and split-marking bar on top -->
        <section
          v-loading="detailLoading || previewLoading"
          class="qc-preview-stage"
          :class="{ 'qc-preview-stage--cropping': cropMode || separationMode }"
          tabindex="-1"
          @click="focusPagingRoot"
          @keydown="onPageNavKeydown"
        >
          <template v-if="image">
            <div ref="previewCanvasEl" class="qc-preview-canvas">
              <img
                v-if="previewSrc"
                ref="cropImageEl"
                class="qc-main-image"
                :src="previewSrc"
                :alt="image.filename"
                @load="syncCropOverlayBox"
                @click="openViewer"
              />
              <el-alert v-else-if="!image.available" type="error" :closable="false" :title="t('qc.imageMissing')" />
              <span v-else-if="previewError" class="error-message">{{ previewError }}</span>
              <div
                v-if="cropMode"
                class="qc-crop-overlay"
                :style="{
                  left: `${cropOverlayBox.left}px`,
                  top: `${cropOverlayBox.top}px`,
                  width: `${cropOverlayBox.width}px`,
                  height: `${cropOverlayBox.height}px`,
                }"
                @pointerdown="startCropDraw"
              >
                <div
                  v-if="hasCropSelection"
                  class="crop-selection"
                  :style="cropSelectionStyle"
                  @pointerdown.stop="startCropMove"
                >
                  <span
                    v-for="handle in CROP_HANDLES"
                    :key="handle"
                    class="crop-handle"
                    :class="`crop-handle--${handle}`"
                    @pointerdown.stop="startCropResize(handle, $event)"
                  />
                </div>
              </div>
            </div>
            <div v-if="separationMode" class="qc-crop-bar">
              <span class="qc-crop-bar__hint qc-crop-bar__hint--wrap">{{ t('qc.separationHint') }}</span>
              <el-button size="small" :disabled="separationApplying" @click="exitSeparationMode">{{ t('common.cancel') }}</el-button>
              <el-button size="small" :disabled="!separationSelection.size" @click="clearSeparationSelection">
                {{ t('qc.separationClear') }}
              </el-button>
              <el-button size="small" type="primary" :loading="separationApplying" @click="applySeparation">
                {{ t('qc.separationApply') }}
              </el-button>
            </div>
            <div v-if="cropMode" class="qc-crop-bar">
              <span class="qc-crop-bar__hint">{{ t('qc.cropHint') }}</span>
              <el-button size="small" @click="exitCropMode">{{ t('common.cancel') }}</el-button>
              <el-button size="small" :disabled="!hasCropSelection" @click="resetCropSelection">
                {{ t('common.reset') }}
              </el-button>
              <el-button
                size="small"
                type="primary"
                :loading="cropLoading"
                :disabled="!hasCropSelection"
                @click="submitCrop"
              >
                {{ t('qc.confirmCrop') }}
              </el-button>
            </div>
            <button
              v-if="currentImageIndex > 1 && !cropMode"
              class="qc-nav-button qc-nav-button--prev"
              @click="image = current.images[currentImageIndex - 2]"
              :title="t('common.previous')"
            >
              <el-icon><ArrowLeft /></el-icon>
            </button>
            <button
              v-if="currentImageIndex < current.imageCount && !cropMode"
              class="qc-nav-button qc-nav-button--next"
              @click="image = current.images[currentImageIndex]"
              :title="t('common.next')"
            >
              <el-icon><ArrowRight /></el-icon>
            </button>
          </template>
          <el-empty v-else :description="t('qc.selectImage')" />
        </section>

        <!-- Right panel: current page, reject remark, metadata form, AI review -->
        <aside class="qc-review-panel">
          <!-- Always rendered: the panel's grid rows are positional, so a
               conditional first card would shift the other two into the wrong
               rows the moment no image is selected. -->
          <section class="qc-info-card qc-current-image-card">
            <div class="qc-panel-heading">
              <span>{{ t('qc.currentImage') }}</span>
              <strong>{{ image ? `${currentImageIndex} / ${current.imageCount}` : '–' }}</strong>
            </div>
            <p class="qc-current-image-name">{{ image ? image.filename : t('qc.currentImagePlaceholder') }}</p>
            <p v-if="image?.calibrationError" role="alert">Colour calibration error: {{ image.calibrationError }}</p>
            <p v-else-if="image?.calibrationProfileId">Colour calibration: {{ image.calibrationProfileId }}</p>
          </section>
          <section class="qc-comment-card">
            <!--
              Collapsed by default, same as the AI panel and for the same
              reason: the metadata form below is read on every folder, a
              rejection remark is written on a few. Expanded, this pushed the
              form off the screen for work that usually never needs it.

              A remark already typed keeps the section open, so a draft in
              progress can never be hidden by a collapse the operator did not
              ask for.
            -->
            <header
              class="qc-comment-header"
              role="button"
              tabindex="0"
              :aria-expanded="rejectReasonOpen"
              @click="toggleRejectReason"
              @keydown.enter.prevent="toggleRejectReason"
              @keydown.space.prevent="toggleRejectReason"
            >
              <span class="qc-comment-title">{{ t('qc.rejectReason') }}</span>
              <div class="qc-comment-header-actions">
                <span v-if="currentRejectReason.trim()" class="qc-comment-filled">
                  {{ t('qc.rejectReasonEntered') }}
                </span>
                <el-icon class="qc-comment-chevron" :class="{ 'qc-comment-chevron--open': rejectReasonOpen }">
                  <ArrowDown />
                </el-icon>
              </div>
            </header>
            <div v-if="rejectReasonOpen" class="qc-comment-box">
              <span>{{ t('qc.selectRejectedImages') }}</span>
              <el-input
                v-if="current.status === 'reviewing' && image"
                v-model="currentRejectReason"
                type="textarea"
                :rows="4"
                maxlength="10000"
                show-word-limit
                resize="vertical"
              />
              <span v-else>{{ t('qc.selectImage') }}</span>
            </div>
          </section>

          <section class="qc-info-card qc-metadata-card">
            <div class="qc-panel-heading">
              <span>{{ t('qc.metadata') }}</span>
              <strong>{{ current.metadata.folderName }}</strong>
            </div>
            <el-form
              :model="metadataForm"
              label-position="top"
              class="qc-inline-metadata-form"
              :disabled="current.status !== 'reviewing' || metadataSaving"
            >
              <el-form-item
                v-for="field in editableTemplateFields"
                :key="field.key"
                :label="field.label"
                :required="field.mandatory"
              >
                <el-select
                  v-if="field.input === 'select'"
                  v-model="metadataForm[field.key]"
                  clearable
                  filterable
                  style="width: 100%"
                  @change="syncDerivedMetadataFields"
                >
                  <el-option
                    v-for="option in field.options"
                    :key="option"
                    :label="displayOption(option)"
                    :value="option"
                  />
                </el-select>
                <el-input v-else-if="field.input === 'fixed'" :model-value="field.value || ''" readonly />
                <!-- Derived, never keyed: an editable box here invites an edit
                     the mapping overwrites on the next save. -->
                <el-input
                  v-else-if="field.input === 'mapped'"
                  :model-value="metadataForm[field.key] || ''"
                  readonly
                />
                <el-input v-else v-model="metadataForm[field.key]" @input="syncDerivedMetadataFields" />
              </el-form-item>
              <el-form-item :label="t('qc.fields.recordType')">
                <el-input v-model="metadataForm.recordType" readonly />
              </el-form-item>
            </el-form>
            <!-- ONE pair for both kinds of change. Image edits and keyed
                 metadata were two buttons that each looked like the save, so
                 whichever one the reviewer pressed silently left the other
                 half unsaved. They sit here, under the form and above the AI
                 panel, because that is the last thing read before deciding. -->
            <div v-if="current.status === 'reviewing'" class="qc-draft-actions">
              <el-button
                type="success"
                :icon="'Finished'"
                :loading="savingChanges"
                :disabled="!hasUnsavedChanges || separationBlocking"
                @click="saveChanges"
              >
                {{ t('qc.saveDraft') }}
              </el-button>
              <el-button
                :icon="'Delete'"
                :loading="draftDiscarding"
                :disabled="!hasUnsavedChanges"
                @click="discardChanges"
              >
                {{ t('qc.discardDraft') }}
              </el-button>
            </div>
          </section>

          <!-- Its own section, not a tail of the metadata card: this panel is a
               peer of the form, not part of it. Nested, it read as a subsection
               of keying, and its collapse looked like it belonged to the form.

               Never gates Approve/Reject in the header above: this panel only
               informs, it never disables the escape hatch. -->
          <section class="qc-info-card qc-ai-card">
            <QcAiReviewPanel
              :controller="aiReview"
              :can-edit="current.status === 'reviewing'"
              :on-evidence-tap="jumpToImageFromAiEvidence"
            />
          </section>

        </aside>

        <!-- Bottom tool strip: image edit tools (rotate, crop, deskew, ...) -->
        <footer class="qc-tool-strip">
          <input ref="replaceInputEl" class="hidden-file-input" type="file" accept=".jpg,.jpeg,.png,.tif,.tiff" @change="handleReplaceUpload" />
          <input ref="insertInputEl" class="hidden-file-input" type="file" accept=".jpg,.jpeg,.png,.tif,.tiff" @change="handleInsertUpload" />
          <!-- Icon-only, tooltipped, ordered and grouped exactly like the Flutter
               toolbar's QcImageToolbar: rotate ccw/cw/180 -> crop -> straighten
               left/step/right -> luminance -> restore -> insert -> move up/down
               -> replace -> delete -> undo/redo. It SCROLLS horizontally rather
               than wrapping (the same reason Flutter gives: restoring the window
               from maximised must not push a tool out under a wrapped row), and
               the status text stays pinned outside the scroll region so it can
               never scroll out of sight either. -->
          <div class="qc-tool-scroll">
            <div class="qc-tool-row">
              <el-tooltip :content="batched(t('qc.rotateLeft'))" placement="top">
                <el-button circle :icon="'RefreshLeft'" :disabled="!toolsEnabled" @click="rotateTarget(-90)" />
              </el-tooltip>
              <el-tooltip :content="batched(t('qc.rotateRight'))" placement="top">
                <el-button circle :icon="'RefreshRight'" :disabled="!toolsEnabled" @click="rotateTarget(90)" />
              </el-tooltip>
              <el-tooltip :content="batched(t('qc.batchRotate'))" placement="top">
                <el-button circle :icon="'Refresh'" :disabled="!toolsEnabled" @click="rotateTarget(180)" />
              </el-tooltip>
              <el-tooltip v-if="image?.available" :content="t('qc.cropImage')" placement="top">
                <el-button
                  circle
                  :icon="'Crop'"
                  :type="cropMode ? 'primary' : 'default'"
                  :disabled="!toolsEnabled"
                  @click="toggleCropMode"
                />
              </el-tooltip>

              <span class="qc-tool-sep" aria-hidden="true"></span>

              <!-- Deskew is the fine correction after LWIP's own crop, not a
                   second pass. The step field sits between the two arrows
                   because it belongs to both equally. -->
              <el-tooltip :content="batched(t('qc.deskewMinus', { step: deskewStepLabel }))" placement="top">
                <el-button circle :icon="'CaretLeft'" :disabled="!toolsEnabled" @click="deskewTarget(-1)" />
              </el-tooltip>
              <span class="qc-deskew-step">
                <button
                  type="button"
                  class="qc-deskew-nudge"
                  :disabled="!toolsEnabled || deskewStep <= DESKEW_STEP_MIN"
                  :title="t('qc.deskewSmallerStep')"
                  @click="nudgeDeskewStep(-1)"
                >&minus;</button>
                <input
                  v-model="deskewStepText"
                  class="qc-deskew-step-input"
                  :disabled="!toolsEnabled"
                  inputmode="decimal"
                  @blur="commitDeskewStepInput"
                  @keyup.enter="commitDeskewStepInput"
                />
                <span class="qc-deskew-step-suffix">°</span>
                <button
                  type="button"
                  class="qc-deskew-nudge"
                  :disabled="!toolsEnabled || deskewStep >= DESKEW_STEP_MAX"
                  :title="t('qc.deskewBiggerStep')"
                  @click="nudgeDeskewStep(1)"
                >+</button>
              </span>
              <el-tooltip :content="batched(t('qc.deskewPlus', { step: deskewStepLabel }))" placement="top">
                <el-button circle :icon="'CaretRight'" :disabled="!toolsEnabled" @click="deskewTarget(1)" />
              </el-tooltip>

              <span class="qc-tool-sep" aria-hidden="true"></span>

              <!--
                Hidden, not disabled, when the station has luminance off. It is
                the only tool here that BAKES pixels rather than recording a
                deferred op, so a site that has switched it off has decided the
                operation must not happen at all - a greyed button still says
                "this exists, ask someone", which is the wrong message. Matches
                LWCAM, which hides it for the same reason. Clicking it when off
                answers 503; showing it at all was the bug.
              -->
              <el-tooltip v-if="luminanceAvailable" :content="batched(t('qc.luminance'))" placement="top">
                <el-button circle :icon="'Sunny'" :loading="luminanceLoading" :disabled="!toolsEnabled" @click="luminanceTarget" />
              </el-tooltip>
              <el-tooltip :content="t('qc.restoreOriginal')" placement="top">
                <el-button circle :icon="'Back'" :disabled="!toolsEnabled" @click="restoreCurrentImage" />
              </el-tooltip>

              <span class="qc-tool-sep" aria-hidden="true"></span>

              <el-tooltip :content="t('qc.insertBefore')" placement="top">
                <el-button circle :icon="'DocumentAdd'" :disabled="!toolsEnabled" @click="triggerInsertUpload" />
              </el-tooltip>
              <el-tooltip :content="t('qc.moveUp')" placement="top">
                <el-button circle :icon="'ArrowUp'" :disabled="!canMoveImageUp" @click="moveCurrentImage(-1)" />
              </el-tooltip>
              <el-tooltip :content="t('qc.moveDown')" placement="top">
                <el-button circle :icon="'ArrowDown'" :disabled="!canMoveImageDown" @click="moveCurrentImage(1)" />
              </el-tooltip>

              <span class="qc-tool-sep" aria-hidden="true"></span>

              <el-tooltip :content="t('qc.replaceImage')" placement="top">
                <el-button circle :icon="'Switch'" :disabled="!toolsEnabled" @click="triggerReplaceUpload" />
              </el-tooltip>
              <el-tooltip
                :content="targetImageIds.length > 1 ? t('qc.deleteTooltipBatch', { count: targetImageIds.length }) : t('qc.deleteTooltip')"
                placement="top"
              >
                <el-button circle type="danger" :icon="'Delete'" :disabled="!toolsEnabled" @click="deleteTargetImages" />
              </el-tooltip>

              <span class="qc-tool-sep" aria-hidden="true"></span>

              <el-tooltip :content="t('qc.undo')" placement="top">
                <el-button circle :icon="'ArrowLeftBold'" :loading="actionLoading" :disabled="!toolsEnabled" @click="undoDraftAction" />
              </el-tooltip>
              <el-tooltip :content="t('qc.redo')" placement="top">
                <el-button circle :icon="'ArrowRightBold'" :loading="actionLoading" :disabled="!toolsEnabled" @click="redoDraftAction" />
              </el-tooltip>

              <!-- QC-platform-only: splitting one folder into child folders has
                   no Flutter counterpart, so it is kept but placed after every
                   tool that does, rather than disturbing the matched order. -->
              <template v-if="current.status === 'reviewing'">
                <span class="qc-tool-sep" aria-hidden="true"></span>
                <el-tooltip :content="t('qc.separationMode')" placement="top">
                  <el-button
                    circle
                    :icon="'Scissor'"
                    :type="separationMode ? 'warning' : 'default'"
                    @click="toggleSeparationMode"
                  />
                </el-tooltip>
              </template>
            </div>
          </div>
          <div class="qc-tool-status">
            <el-icon v-if="toolbarBusy" class="is-loading"><Loading /></el-icon>
            <span v-else-if="current.status !== 'reviewing'">
              {{ isTaskSettled ? t('qc.toolbarCompletedReadOnly') : t('qc.toolbarClaimToEdit') }}
            </span>
          </div>
        </footer>
      </template>
      <div v-else class="qc-empty-desk">
        <el-button class="qc-back-button qc-empty-back-button" :icon="'ArrowLeft'" @click="returnToQcTasks">
          {{ t('common.back') }}
        </el-button>
        <el-empty class="qc-empty-content" :description="t('qc.noMineTask')" />
      </div>
    </div>

    <!-- Completed history: read-only three-column view of finished folders -->
    <div v-else class="completed-history-redesign" :class="{ 'completed-history-redesign--compact': route.name === 'qc-completed' }">
      <!-- Task list, left rail -->
      <aside v-loading="loading" class="completed-sidebar">
        <div class="completed-sidebar-header">
          <div>
            <p class="sidebar-label">{{ t('qc.completed') }}</p>
            <h3 class="total-count">{{ scopeTotals.completed ?? tasks.length }}</h3>
          </div>
        </div>

        <div class="completed-task-list">
          <el-empty v-if="!tasks.length && !loading" :description="t('qc.noTasks')" />
          <button
            v-for="task in tasks"
            :key="task.id"
            type="button"
            class="completed-task-card"
            :class="{ active: current?.id === task.id }"
            @click="open(task)"
          >
            <div class="task-card-header">
              <span class="status-badge" :data-status="task.status">
                {{ translateValue('metadataQcStatus', task.status) }}
              </span>
              <span class="image-badge">{{ task.imageCount }}</span>
            </div>
            <div class="task-card-body">
              <strong class="task-folder-name">{{ task.metadata.folderName }}</strong>
              <small class="task-project">{{ task.metadata.projectName }}</small>
              <small class="task-box">{{ task.metadata.boxName }}</small>
              <small class="task-time">{{ formatTimestamp(completedTime(task)) }}</small>
            </div>
          </button>
        </div>
      </aside>

      <!-- Image preview, centre -->
      <section v-loading="detailLoading || previewLoading" class="completed-main-preview">
        <template v-if="image && current">
          <!-- Floating toolbar -->
          <div class="image-toolbar">
            <div class="toolbar-left">
              <span class="current-filename">{{ image.filename }}</span>
              <span class="image-counter">{{ currentImageIndex }} / {{ current.imageCount }}</span>
            </div>
            <div class="toolbar-right">
              <el-button size="small" text @click="openViewer" :icon="'ZoomIn'">{{ t('qc.viewLarge') }}</el-button>
            </div>
          </div>

          <!-- Image itself -->
          <div class="image-container">
            <img v-if="previewSrc" class="main-image" :src="previewSrc" :alt="image.filename" @click="openViewer" />
            <el-alert v-else-if="!image.available" type="error" :closable="false" :title="t('qc.imageMissing')" />
            <span v-else-if="previewError" class="error-message">{{ previewError }}</span>
          </div>

          <!-- Previous/next image buttons -->
          <button
            v-if="currentImageIndex > 1"
            class="nav-button nav-prev"
            @click="image = current.images[currentImageIndex - 2]"
            :title="t('common.previous')"
          >
            <el-icon><ArrowLeft /></el-icon>
          </button>
          <button
            v-if="currentImageIndex < current.imageCount"
            class="nav-button nav-next"
            @click="image = current.images[currentImageIndex]"
            :title="t('common.next')"
          >
            <el-icon><ArrowRight /></el-icon>
          </button>
        </template>
        <el-empty v-else :description="t('common.selectTask')" />
      </section>

      <!-- Detail panel, right rail -->
      <aside class="completed-detail-sidebar">
        <template v-if="current">
          <div class="sidebar-header">
            <div>
              <p class="metadata-label">{{ t('qc.metadata') }}</p>
              <h3 class="folder-name">{{ current.metadata.folderName }}</h3>
            </div>
            <span class="status-pill" :data-status="current.status">{{ translateValue('metadataQcStatus', current.status) }}</span>
          </div>
          <div v-if="current.status === 'passed'" class="sidebar-header group-id-row">
            <div v-if="current.groupId" class="group-id-line">
              <span class="group-id-label">{{ t('qc.groupId') }}:</span>
              <span class="group-id-value">{{ current.groupId }}</span>
            </div>
            <span v-if="current.clientRework" class="status-pill" data-status="rework">{{ t('qc.clientRework') }}</span>
            <el-button
              type="danger"
              class="revert-button"
              :icon="'RefreshLeft'"
              :loading="detailLoading"
              @click="revertCurrentTask"
            >
              {{ t('qc.revert') }}
            </el-button>
          </div>

          <div class="detail-content">
            <!-- Image quick-jump strip -->
            <div class="image-quick-nav">
              <h4>{{ t('qc.images') }} ({{ current.imageCount }})</h4>
              <div class="image-chip-grid">
                <button
                  v-for="(item, index) in current.images"
                  :key="item.id"
                  type="button"
                  class="image-chip"
                  :class="{ active: image?.id === item.id, unavailable: !item.available }"
                  :title="item.filename"
                  @click="image = item"
                >
                  {{ String(index + 1).padStart(2, '0') }}
                </button>
              </div>
            </div>

            <!-- Full metadata, shown directly rather than behind a disclosure -->
            <section v-for="group in metadataGroups" :key="group.title" class="metadata-group-compact">
              <h4 v-if="group.title">{{ group.title }}</h4>
              <dl class="metadata-list-compact">
                <div v-for="field in group.fields" :key="String(field[0])">
                  <dt>{{ field[0] }}</dt>
                  <dd>{{ displayValue(field[1]) }}</dd>
                </div>
              </dl>
            </section>
          </div>
        </template>
        <el-empty v-else :description="t('common.selectTask')" />
      </aside>
    </div>

    <!-- Reject dialog: choose the pages sent back for recapture and a remark for each -->
    <el-dialog v-model="rejectDialogVisible" :title="t('qc.rejectImages')" width="520px">
      <p class="qc-reject-intro">{{ t('qc.rejectIntro') }}</p>
      <p v-if="selectedBatchIds.length" class="qc-reject-intro">{{ t('qc.rejectTickedHint', { count: selectedBatchIds.length }) }}</p>
      <el-form label-position="top">
        <el-form-item :label="t('qc.selectRejectedImages')" required>
          <el-checkbox-group v-model="rejectedImageIds" class="reject-image-options" @change="syncRejectReasons">
            <el-checkbox v-for="item in current?.images || []" :key="item.id" :value="item.id">{{ pageLabel(item.id) }}</el-checkbox>
          </el-checkbox-group>
        </el-form-item>
        <div v-if="rejectedImageIds.length" class="reject-reason-list">
          <el-form-item
            v-for="imageId in rejectedImageIds"
            :key="imageId"
            :label="`${pageLabel(imageId)} - ${t('qc.rejectReason')}`"
            required
          >
            <el-input v-model="rejectReasons[imageId]" type="textarea" :rows="3" maxlength="10000" show-word-limit />
          </el-form-item>
        </div>
      </el-form>
      <template #footer>
        <el-button @click="rejectDialogVisible = false">{{ t('common.cancel') }}</el-button>
        <el-button type="danger" :loading="actionLoading" @click="submitReject">{{ t('qc.confirmReject', { count: rejectedImageIds.length }) }}</el-button>
      </template>
    </el-dialog>

    <!-- Full-screen zoom viewer, opened by clicking the preview image -->
    <ImagePreviewViewer v-model="viewerVisible" :src="previewSrc" :alt="image?.filename" />
  </AppShell>
</template>

<style scoped>
/* --- Page header and summary counters ------------------------------------- */
.qc-page-header {
  display: grid;
  gap: 20px;
  margin-bottom: 24px;
}

.qc-page-title {
  margin-bottom: 0;
}

/* `.page-title h1` (lifewood.css) is shared with the admin views, so the
   page-wide +3px font-size pass is applied here instead, scoped by Vue to
   this component only — bumping the shared rule would leak into those. */
.qc-page-title h1 {
  font-size: 33px;
}

.qc-toolbar {
  flex-shrink: 0;
  margin-bottom: 0;
}

.qc-summary-strip {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 16px;
}

.qc-summary-item {
  position: relative;
  min-width: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: 80px;
  padding: 20px 24px;
  /* Flat, hairline-bordered panel (cardTheme: elevation 0, surfaceTintColor
     transparent) — not a drop shadow. */
  border: 1px solid var(--lw-outline-variant);
  border-radius: 12px;
  background: linear-gradient(135deg, #ffffff 0%, #f8fffe 100%);
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  overflow: hidden;
}

.qc-summary-item::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  width: 4px;
  height: 100%;
  background: linear-gradient(180deg, var(--el-color-primary) 0%, var(--el-color-success) 100%);
  transition: width 0.3s ease;
}

.qc-summary-item:hover {
  transform: translateY(-2px);
  border-color: var(--lw-outline);
}

.qc-summary-item:hover::before {
  width: 6px;
}

.qc-summary-item span {
  color: var(--el-text-color-secondary);
  font-size: 17px;
  font-weight: 500;
  letter-spacing: 0.3px;
}

.qc-summary-item strong {
  overflow: hidden;
  color: var(--el-color-primary);
  font-size: 35px;
  font-weight: 700;
  text-overflow: ellipsis;
  white-space: nowrap;
  line-height: 1;
}

/* In-place crop mode. The overlay is glued to the measured img rect, so its
   local coordinate space IS the displayed image; overflow:hidden clips the
   selection's 9999px shade (the dialog's body used to do that job). */
.qc-crop-overlay {
  position: absolute;
  z-index: 5;
  overflow: hidden;
  cursor: crosshair;
  touch-action: none;
  user-select: none;
}

.crop-selection {
  position: absolute;
  z-index: 2;
  border: 2px solid #FFB13B;
  background: rgba(255, 177, 59, 0.18);
  box-shadow: 0 0 0 9999px rgba(0, 0, 0, 0.42);
  cursor: move;
  touch-action: none;
}

.crop-handle {
  position: absolute;
  width: 14px;
  height: 14px;
  margin: -7px;
  background: #fff;
  border: 2px solid #FFB13B;
  border-radius: 2px;
  box-sizing: border-box;
}

.crop-handle--nw { left: 0; top: 0; cursor: nwse-resize; }
.crop-handle--n  { left: 50%; top: 0; cursor: ns-resize; }
.crop-handle--ne { left: 100%; top: 0; cursor: nesw-resize; }
.crop-handle--e  { left: 100%; top: 50%; cursor: ew-resize; }
.crop-handle--se { left: 100%; top: 100%; cursor: nwse-resize; }
.crop-handle--s  { left: 50%; top: 100%; cursor: ns-resize; }
.crop-handle--sw { left: 0; top: 100%; cursor: nesw-resize; }
.crop-handle--w  { left: 0; top: 50%; cursor: ew-resize; }

/* While cropping, the bar is a strip ALONG THE TOP of the viewer, in the
   layout rather than floating over it: it used to sit bottom-centre on top of
   the image, exactly where the bottom edge of the crop frame is dragged. The
   image shrinks to fit below it, and the ResizeObserver on the canvas
   re-measures the crop overlay when it does. */
.qc-preview-stage--cropping {
  flex-direction: column;
  align-items: stretch;
}

.qc-preview-stage--cropping .qc-preview-canvas {
  flex: 1;
  min-height: 0;
  height: auto;
}

.qc-crop-bar {
  order: -1;
  flex: none;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 16px;
  background: rgba(16, 22, 18, 0.82);
  white-space: nowrap;
}

.qc-crop-bar__hint--wrap {
  min-width: 0;
  white-space: normal;
}

.qc-crop-bar__hint {
  color: #D6DDD6;
  font-size: 16px;
  margin-right: auto;
}

/* --- Pending queue table -------------------------------------------------- */
.pending-queue-panel {
  /* .panel (lifewood.css) already supplies the flat hairline border */
  padding: 28px;
  border-radius: 12px;
}

.queue-heading {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 24px;
  margin-bottom: 24px;
}

.queue-heading h2 {
  margin: 6px 0 0;
  font-size: 27px;
  font-weight: 600;
}

.queue-heading .el-alert {
  max-width: 480px;
}

.pending-task-table {
  border-top: none;
  border-radius: 8px;
  overflow: hidden;
}

.pending-task-table :deep(.el-table__header) {
  background: linear-gradient(180deg, #f8fffe 0%, #f5f7f6 100%);
}

.pending-task-table :deep(.el-table__row) {
  transition: all 0.2s ease;
}

.pending-task-table :deep(.el-table__row:hover) {
  background: var(--el-color-primary-light-9);
  transform: scale(1.002);
}

.pending-task-table :deep(.cell) {
  padding: 12px 8px;
}

/* --- Preview, toolbar and detail styles shared with the Completed view ----- */
/* Current layout: image-centric */
/* Thumbnail sidebar, left */
.sidebar-header {
  display: grid;
  gap: 10px;
  padding: 16px 12px;
  border-bottom: 1px solid #D4D9D6;
  background: #F0F3F1;
}

/* Main image preview area, centre */
.image-toolbar {
  position: absolute;
  top: 12px;
  left: 12px;
  right: 12px;
  z-index: 10;
  display: grid;
  grid-template-columns: max-content minmax(0, 1fr);
  align-items: center;
  gap: 10px;
  padding: 10px 12px;
  background: rgba(44, 95, 79, 0.92);
  backdrop-filter: blur(12px);
  border-radius: 8px;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.2);
  max-width: 100%;
}

.toolbar-left {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  /* Wide enough that a normal filename never hits the ellipsis - the bar has
     the room (grid-template-columns above gives .toolbar-right its own
     minmax(0, 1fr) track), this was just capped tighter than it needed to be. */
  max-width: 520px;
}

.current-filename {
  font-size: 15px;
  font-weight: 600;
  color: white;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex: 0 1 auto;
  max-width: 440px;
  min-width: 0;
}

.image-counter {
  flex-shrink: 0;
  padding: 2px 8px;
  border-radius: 4px;
  background: rgba(255, 255, 255, 0.14);
  /* Light-on-dark, not a mid grey - this sits on the same dark green bar as
     .current-filename and was previously unstyled, inheriting the app's dark
     body text color here instead. */
  color: var(--lw-white);
  font-size: 15px;
  font-weight: 600;
  white-space: nowrap;
}

.toolbar-right {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 6px 8px;
  min-width: 0;
  overflow: visible;
}

.hidden-file-input {
  display: none;
}

.toolbar-right :deep(.el-button) {
  color: white;
  border-color: rgba(255, 255, 255, 0.3);
  height: 28px;
  margin: 0;
  padding: 0 8px;
  font-size: 14px;
  font-weight: 600;
}

.toolbar-right :deep(.el-button:hover) {
  background: rgba(255, 255, 255, 0.1);
  border-color: rgba(255, 255, 255, 0.5);
}

.image-container {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 70px 16px 16px;
}

.main-image {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
  cursor: zoom-in;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.15);
  border-radius: 4px;
  transition: transform 0.3s ease;
}

.main-image:hover {
  transform: scale(1.01);
}

.error-message {
  color: #D14343;
  font-size: 16px;
}

/* Previous/next image buttons */
.nav-button {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  width: 44px;
  height: 44px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(44, 95, 79, 0.92);
  border: none;
  border-radius: 50%;
  color: white;
  font-size: 21px;
  cursor: pointer;
  transition: all 0.2s ease;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.2);
  z-index: 10;
}

.nav-button:hover {
  background: #2C5F4F;
  transform: translateY(-50%) scale(1.1);
}

.nav-prev {
  left: 16px;
}

.nav-next {
  right: 16px;
}

/* Metadata panel, right */
.metadata-label {
  font-size: 13px;
  font-weight: 600;
  color: #5A6F66;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  margin: 0 0 4px;
}

.folder-name {
  font-size: 17px;
  font-weight: 700;
  color: #2C5F4F;
  margin: 0 0 4px;
  line-height: 1.3;
  word-break: break-word;
}

/* Group ID + rework row (the .sidebar-header above it is display:grid,
   single column; this overrides to a row layout for label, badge and
   button). */
.group-id-row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 10px;
}

.group-id-line {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 6px;
  min-width: 0;
  flex: 1 1 auto;
}

.group-id-label {
  flex-shrink: 0;
  font-size: 13px;
  font-weight: 600;
  color: #5A6F66;
  text-transform: uppercase;
  letter-spacing: 0.3px;
}

.group-id-value {
  min-width: 0;
  /* Breaks at a natural boundary (the ID's own hyphens) rather than
     mid-character - no text-overflow/ellipsis and no break-all here. */
  overflow-wrap: break-word;
  font-family: ui-monospace, SFMono-Regular, Consolas, 'Liberation Mono', Menlo, monospace;
  /* Larger than the labels around it on purpose: this is the string the ingest
     team quotes back at us, so it is read character by character rather than
     skimmed, and an O against a 0 has to be obvious. */
  font-size: 19px;
  font-weight: 700;
  color: #1A3329;
}

/* The only action on this panel - a filled, full-width button rather than
   the plain outline it was. Same semantic color as the reviewing tab's own
   "send back" action (Reject uses type="danger" too). */
.revert-button.el-button {
  width: 100%;
  height: 40px;
  font-weight: 700;
}

.metadata-group-compact {
  padding: 10px;
  border-bottom: 1px solid #E8ECEA;
}

.metadata-group-compact:last-child {
  border-bottom: none;
}

.metadata-group-compact h4 {
  margin: 0 0 6px;
  font-size: 14px;
  font-weight: 700;
  color: #2C5F4F;
}

.metadata-list-compact {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin: 0;
}

.metadata-list-compact div {
  display: grid;
  grid-template-columns: 85px 1fr;
  gap: 8px;
  align-items: baseline;
}

.metadata-list-compact dt {
  font-size: 13px;
  color: #5A6F66;
  font-weight: 500;
}

.metadata-list-compact dd {
  margin: 0;
  font-size: 14px;
  color: #1A3329;
  font-weight: 600;
  word-break: break-word;
}

/* Fixed action bar, bottom */
/* Sized and typed like the el-buttons it sits between (14px / 500 / 4px radius) */

.panel-heading {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 14px;
}

.panel-heading h2 {
  margin: 4px 0 6px;
  overflow-wrap: anywhere;
  font-size: 22px;
  font-weight: 600;
}

.panel-heading .eyebrow {
  font-size: 15px;
  font-weight: 600;
  color: var(--el-color-primary);
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.metadata-group {
  display: grid;
  gap: 10px;
  margin-top: 20px;
  padding: 16px;
  border-radius: 10px;
  background: rgba(4, 98, 65, 0.02);
  border: 1px solid rgba(4, 98, 65, 0.06);
}

.metadata-group h3 {
  margin: 0 0 8px;
  color: var(--el-text-color-primary);
  font-size: 17px;
  font-weight: 600;
}

.metadata-list {
  display: grid;
  gap: 0;
  margin: 0;
}

.metadata-list div {
  display: grid;
  grid-template-columns: minmax(100px, 0.42fr) minmax(0, 0.58fr);
  gap: 12px;
  padding: 12px 0;
  border-bottom: 1px solid rgba(19, 48, 32, 0.06);
}

.metadata-list div:last-child {
  border-bottom: none;
}

.metadata-list dt {
  color: var(--el-text-color-secondary);
  font-size: 15px;
  font-weight: 500;
}

.metadata-list dd {
  min-width: 0;
  margin: 0;
  overflow-wrap: anywhere;
  font-weight: 600;
  color: var(--el-text-color-primary);
}

/* --- Completed history view ------------------------------------------------ */
/* Completed view - redesigned */
.completed-history-redesign {
  position: relative;
  display: grid;
  grid-template-columns: minmax(240px, 280px) 1fr minmax(280px, 320px);
  gap: 0;
  height: 100%;
  max-height: 100%;
  background: var(--lw-surface-container);
  overflow: hidden;
}

.completed-history-redesign--compact {
  height: 100%;
  max-height: 100%;
}

/* Task list, left */
.completed-sidebar {
  display: flex;
  flex-direction: column;
  background: #FAFBFA;
  border-right: 1px solid #D4D9D6;
  overflow: hidden;
}

.completed-sidebar-header {
  padding: 16px;
  border-bottom: 2px solid #D4D9D6;
  background: linear-gradient(135deg, #F0F3F1 0%, #FAFBFA 100%);
}

.sidebar-label {
  font-size: 13px;
  font-weight: 600;
  color: #5A6F66;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  margin: 0 0 6px;
}

.total-count {
  font-size: 35px;
  font-weight: 700;
  color: #2C5F4F;
  margin: 0;
  line-height: 1;
}

.completed-task-list {
  flex: 1;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.completed-task-card {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px;
  border: 1.5px solid transparent;
  border-radius: 10px;
  background: #FFFFFF;
  cursor: pointer;
  transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
  text-align: left;
}

.completed-task-card:hover {
  border-color: #2C5F4F;
  background: #F8FAF9;
  transform: translateX(3px);
}

.completed-task-card.active {
  border-color: #2C5F4F;
  background: linear-gradient(135deg, #E8F3EF 0%, #F8FAF9 100%);
}

.task-card-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.status-badge {
  display: inline-flex;
  align-items: center;
  padding: 3px 8px;
  border-radius: 12px;
  font-size: 13px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.3px;
}

.status-badge[data-status="passed"] {
  background: #E8F3EF;
  color: #2C5F4F;
  border: 1px solid #2C5F4F;
}

.status-badge[data-status="rework"] {
  background: #FFF5F5;
  color: #D14343;
  border: 1px solid #D14343;
}

.image-badge {
  padding: 3px 8px;
  background: #F0F3F1;
  border-radius: 8px;
  font-size: 14px;
  font-weight: 600;
  color: #5A6F66;
}

.task-card-body {
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.task-folder-name {
  font-size: 17px;
  font-weight: 700;
  color: #1A3329;
  line-height: 1.3;
  word-break: break-word;
}

.task-project,
.task-box,
.task-time {
  font-size: 14px;
  color: #5A6F66;
  line-height: 1.3;
}

/* Image preview, centre (shared styles) */
.completed-main-preview {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  /* Deliberately NOT a --lw-* token: the viewer frame is a neutral so the
     scan's own edges read, not the brand dark (#133020). Keep it a literal. */
  background: #202824;
  overflow: hidden;
}

/* Detail panel, right */
.completed-detail-sidebar {
  display: flex;
  flex-direction: column;
  background: #FAFBFA;
  border-left: 1px solid #D4D9D6;
  overflow: hidden;
  max-height: 100%;
}

.detail-content {
  flex: 1;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-height: 100%;
}

/* Image quick-jump strip */
.image-quick-nav {
  flex-shrink: 0;
}

.image-quick-nav h4 {
  margin: 0 0 8px;
  font-size: 14px;
  font-weight: 700;
  color: #2C5F4F;
}

.image-chip-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(36px, 1fr));
  gap: 6px;
}

.image-chip {
  width: 100%;
  height: 32px;
  border: 1.5px solid #D4D9D6;
  border-radius: 6px;
  background: #FFFFFF;
  color: #5A6F66;
  font-size: 14px;
  font-weight: 700;
  cursor: pointer;
  transition: all 0.2s ease;
}

.image-chip:hover {
  border-color: #2C5F4F;
  background: #E8F3EF;
  transform: scale(1.05);
}

.image-chip.active {
  border-color: #2C5F4F;
  background: #2C5F4F;
  color: #FFFFFF;
  box-shadow: 0 2px 6px rgba(44, 95, 79, 0.25);
}

.image-chip.unavailable {
  border-color: #D14343;
  color: #D14343;
  opacity: 0.6;
}

.completed-detail {
  min-width: 0;
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(320px, 400px);
  gap: 20px;
}

.qc-reject-intro {
  margin: 0 0 12px;
  color: var(--lw-muted);
  font-size: 16px;
}

.reject-image-options {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  max-height: 260px;
  overflow-y: auto;
  padding: 8px;
  gap: 8px;
}

.reject-image-options :deep(.el-checkbox) {
  padding: 8px 12px;
  border-radius: 8px;
  transition: background 0.2s ease;
}

.reject-image-options :deep(.el-checkbox:hover) {
  background: var(--el-fill-color-light);
}

.reject-reason-list {
  display: grid;
  gap: 14px;
  max-height: 360px;
  overflow-y: auto;
  padding-right: 4px;
}

.reject-reason-list :deep(.el-form-item) {
  margin-bottom: 0;
  padding: 12px;
  border: 1px solid var(--el-border-color-lighter);
  border-radius: 8px;
  background: var(--el-fill-color-blank);
}

.reject-reason-list :deep(.el-form-item__label) {
  color: #2C5F4F;
  font-weight: 700;
}

.status-pill {
  display: inline-flex;
  align-items: center;
  padding: 4px 12px;
  border-radius: 16px;
  font-size: 15px;
  font-weight: 600;
  white-space: nowrap;
}

.status-pill[data-status="pending"] {
  background: var(--el-color-info-light-9);
  color: var(--el-color-info-dark-2);
  border: 1px solid var(--el-color-info-light-7);
}

.status-pill[data-status="reviewing"] {
  background: var(--el-color-warning-light-9);
  color: var(--el-color-warning-dark-2);
  border: 1px solid var(--el-color-warning-light-7);
}

.status-pill[data-status="passed"] {
  background: var(--el-color-success-light-9);
  color: var(--el-color-success-dark-2);
  border: 1px solid var(--el-color-success-light-7);
}

@media (max-width: 1680px) {
  .folder-name {
    font-size: 16px;
  }
}

@media (max-width: 1200px) {
  .image-toolbar {
    grid-template-columns: max-content minmax(0, 1fr);
  }

  .toolbar-right {
    gap: 4px 6px;
  }

  .toolbar-right :deep(.el-button) {
    padding: 0 6px;
    font-size: 13px;
  }
}

@media (max-width: 768px) {
  .image-toolbar {
    grid-template-columns: 1fr;
    gap: 6px;
    padding: 8px 10px;
  }

  .toolbar-left {
    width: 100%;
    flex-direction: row;
    align-items: center;
    gap: 4px;
  }

  .toolbar-right {
    justify-content: flex-start;
  }

  .current-filename {
    font-size: 15px;
  }

  .image-counter {
    font-size: 13px;
    padding: 2px 6px;
  }

  .nav-button {
    width: 36px;
    height: 36px;
    font-size: 19px;
  }

  .nav-prev {
    left: 10px;
  }

  .nav-next {
    right: 10px;
  }

}

/* Completed view - responsive */
@media (min-width: 1920px) {
  .completed-history-redesign {
    grid-template-columns: minmax(280px, 320px) 1fr minmax(300px, 340px);
  }
}

@media (max-width: 1680px) {
  .completed-history-redesign {
    grid-template-columns: 240px 1fr 280px;
  }
}

@media (max-width: 1440px) {
  .completed-history-redesign {
    grid-template-columns: 220px 1fr 260px;
  }

  .task-folder-name {
    font-size: 16px;
  }

  .total-count {
    font-size: 31px;
  }
}

@media (max-width: 1200px) {
  .completed-history-redesign {
    grid-template-columns: 200px 1fr 240px;
  }

  .completed-task-card {
    padding: 10px;
  }

  .image-chip-grid {
    grid-template-columns: repeat(auto-fill, minmax(32px, 1fr));
  }

  .image-chip {
    height: 28px;
    font-size: 13px;
  }
}

@media (max-width: 1024px) {
  .completed-history-redesign {
    grid-template-columns: 1fr;
    grid-template-rows: auto 1fr auto;
    height: auto;
    max-height: none;
  }

  .completed-sidebar {
    grid-row: 1;
    flex-direction: row;
    border-right: none;
    border-bottom: 1px solid #D4D9D6;
    max-height: 180px;
  }

  .completed-sidebar-header {
    min-width: 140px;
    border-right: 1px solid #D4D9D6;
    border-bottom: none;
  }

  .completed-task-list {
    flex-direction: row;
    overflow-x: auto;
    overflow-y: hidden;
  }

  .completed-task-card {
    min-width: 200px;
    flex-shrink: 0;
  }

  .completed-main-preview {
    grid-row: 2;
    min-height: 400px;
  }

  .completed-detail-sidebar {
    grid-row: 3;
    border-left: none;
    border-top: 1px solid #D4D9D6;
    max-height: 400px;
  }
}

@media (max-width: 768px) {
  .completed-sidebar-header {
    padding: 12px;
  }

  .total-count {
    font-size: 27px;
  }

  .completed-task-card {
    min-width: 180px;
  }

  .task-folder-name {
    font-size: 15px;
  }

  .image-chip-grid {
    grid-template-columns: repeat(auto-fill, minmax(28px, 1fr));
  }

  .image-chip {
    height: 26px;
    font-size: 12px;
  }
}

@media (max-width: 1280px) {
  .completed-detail {
    grid-template-columns: minmax(240px, 300px) minmax(0, 1fr);
  }

}

@media (max-width: 1100px) {
  .queue-heading,
  .qc-page-title {
    align-items: flex-start;
    flex-direction: column;
  }

  .queue-heading .el-alert {
    max-width: none;
  }

  .completed-detail {
    grid-template-columns: 1fr;
    min-height: auto;
  }

}

@media (max-width: 640px) {
  .qc-summary-strip {
    grid-template-columns: 1fr;
  }

  .qc-summary-item {
    min-height: 70px;
    padding: 16px 20px;
  }

  .qc-summary-item strong {
    font-size: 31px;
  }

  .metadata-list div {
    grid-template-columns: 1fr;
    gap: 6px;
  }

}

.eyebrow {
  display: block;
  margin-bottom: 4px;
  color: var(--el-text-color-secondary);
  font-size: 15px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.8px;
}

/* --- Review desk: grid, header, left rail, preview stage ------------------- */
.qc-desk {
  /* The review cards' edge. Local on purpose: --lw-line (0.14) and
     --lw-line-strong (0.24) are shared with other screens, and this is the one
     boundary that carries the panel's whole structure now that the section
     dividers are gone. Still a hairline - 2px across four stacked cards reads
     as a wireframe, not as quiet. */
  --qc-card-line: rgba(19, 48, 32, 0.34);
  position: relative;
  display: grid;
  grid-template-columns: minmax(200px, 248px) minmax(0, 1fr) minmax(380px, 440px);
  grid-template-rows: 58px minmax(0, 1fr) auto;
  height: 100%;
  max-height: 100%;
  min-height: 620px;
  overflow: hidden;
  border: 1px solid #d5dbd7;
  background: #eef1ef;
}

.qc-desk--compact {
  /* The shell content excludes the system-status banner above the desk. */
  height: 100%;
  max-height: 100%;
  min-height: 0;
}

.qc-desk-header {
  grid-column: 1 / -1;
  grid-row: 1;
  display: grid;
  grid-template-columns: minmax(140px, 170px) minmax(0, 1fr) auto;
  align-items: center;
  gap: 12px;
  padding: 8px 10px;
  border-bottom: 1px solid #d5dbd7;
  background: #f7f8f6;
}

.qc-back-button {
  justify-content: flex-start;
  height: 40px;
  border-radius: 4px;
  font-weight: 700;
}

.qc-empty-desk {
  grid-column: 1 / -1;
  grid-row: 1 / -1;
  position: relative;
  min-height: 0;
  background: #f7f8f6;
}

.qc-empty-back-button {
  position: absolute;
  top: 12px;
  left: 12px;
  z-index: 1;
  min-width: 150px;
}

.qc-empty-content {
  height: 100%;
  padding-top: 72px;
  justify-content: flex-start;
}

.qc-project-title {
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 12px;
}

.qc-project-title strong {
  min-width: 0;
  overflow: hidden;
  color: #1a3329;
  font-size: 20px;
  font-weight: 800;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.qc-project-title span {
  min-width: 0;
  overflow: hidden;
  color: #607267;
  font-size: 16px;
  font-weight: 700;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.qc-primary-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}

.qc-primary-actions :deep(.el-button) {
  height: 38px;
  min-width: 84px;
  margin: 0;
  border-radius: 4px;
  font-weight: 800;
}

.qc-image-rail {
  grid-column: 1;
  grid-row: 2 / 4;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  border-right: 1px solid #d5dbd7;
  background: #f7f8f6;
}

/* tabindex="-1" makes these two the arrow-key paging scope (see
   onPageNavKeydown) without joining the tab order or showing a focus ring —
   they are a navigation scope, not a control. */
.qc-image-rail:focus,
.qc-preview-stage:focus {
  outline: none;
}

.qc-rail-summary {
  flex: 0 0 auto;
  display: grid;
  gap: 10px;
  padding: 12px 10px;
  border-bottom: 1px solid #d5dbd7;
}

.qc-rail-summary > div:first-child {
  display: grid;
  gap: 4px;
}

.qc-rail-summary span {
  color: #607267;
  font-size: 14px;
  font-weight: 700;
}

.qc-rail-summary strong {
  min-width: 0;
  overflow: hidden;
  color: #2c5f4f;
  font-size: 18px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.qc-batch-tools {
  display: flex;
  align-items: center;
  padding: 8px;
  border: 1px solid #d5dbd7;
  border-radius: 4px;
  background: #ffffff;
}

.qc-thumbnail-list {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 10px;
  overflow-x: hidden;
  overflow-y: auto;
  /* shift+click range selection must not highlight filenames */
  user-select: none;
}

/* LWCAM image-grid philosophy: the image IS the tile. Checkbox, sequence
   number, and the unsaved badge float over it; the filename lives in the right
   panel's "Current image" card, not here. */
.qc-thumbnail {
  position: relative;
  display: block;
  width: 100%;
  /* The list is a column flexbox and flex items SHRINK by default; with
     overflow:hidden the tile has no automatic minimum, so 12 tiles would be
     crushed to share the rail height. Never shrink — the list scrolls. */
  flex: 0 0 auto;
  padding: 0;
  border: 3px solid transparent;
  border-radius: 8px;
  background: #ffffff;
  color: inherit;
  cursor: pointer;
  overflow: hidden;
  transition: border-color 0.2s ease, background 0.2s ease, box-shadow 0.2s ease;
}

.qc-thumbnail:hover,
.qc-thumbnail.active {
  border-color: #2c5f4f;
  background: #f4f8f6;
  box-shadow: 0 2px 8px rgba(44, 95, 79, 0.14);
}

.qc-thumbnail.selected {
  box-shadow: inset 0 0 0 1px #2c5f4f, 0 2px 8px rgba(44, 95, 79, 0.14);
}

.qc-thumbnail.unavailable {
  opacity: 0.56;
  background: #fff5f5;
}

/* Sits directly on the white tile — no opaque chip behind it (that read as a
   second card floating on the first). The checkbox's own bordered square
   already reads against a white tile without a ground. */
.qc-thumbnail-check {
  position: absolute;
  top: 6px;
  left: 6px;
  z-index: 2;
  display: inline-flex;
  width: 24px;
  height: 24px;
  padding-left: 2px;
}

.qc-thumbnail-check :deep(.el-checkbox__label) {
  display: none;
}

.qc-thumbnail-index {
  position: absolute;
  top: 6px;
  right: 6px;
  z-index: 2;
  padding: 2px 7px;
  border-radius: 4px;
  background: #4d7769;
  color: #ffffff;
  font-size: 14px;
  font-weight: 800;
}

/* Fills the tile at document ratio (~A4 portrait); contain rather than cover so
   a rotated or oddly-sized page is still fully visible for judging. */
.qc-thumbnail-preview {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  aspect-ratio: 1 / 1.35;
  background: #f0f2f1;
  color: #9d90b8;
  font-size: 27px;
  overflow: hidden;
}

/* Solid saffron, not the soft tint — it must read at a glance over any image */
.qc-thumbnail-unsaved {
  position: absolute;
  left: 6px;
  bottom: 6px;
  z-index: 2;
  padding: 3px 9px;
  border-radius: 4px;
  background: var(--lw-saffron);
  color: #1a3329;
  font-size: 15px;
  font-weight: 800;
  letter-spacing: 0.3px;
  box-shadow: 0 1px 5px rgba(26, 51, 41, 0.35);
}

/* "Current image" card in the right panel — full filename, wrapping, since the
   tiles no longer carry it */
.qc-current-image-name {
  margin: 0;
  color: #2f4239;
  /* matches el-button default text (e.g. "Discard draft") */
  font-size: 17px;
  font-weight: 600;
  word-break: break-all;
  line-height: 1.5;
}

/* Separation preview: a header above each folder's first card, a coloured
   stripe on every card of the folder (two alternating colours), and a yellow
   wash + border on the cards that START a new folder. */
.qc-thumbnail-group {
  flex: 0 0 auto;
  padding: 2px 4px 0;
  color: #4d5f56;
  font-size: 14px;
  font-weight: 700;
}

.qc-thumbnail--grouped::before {
  content: '';
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  z-index: 3;
  width: 6px;
  background: #2c8a6a;
}

.qc-thumbnail--grouped.qc-thumbnail--stripe-b::before {
  background: #3b82c4;
}

.qc-thumbnail.qc-thumbnail--split,
.qc-thumbnail.qc-thumbnail--split:hover,
.qc-thumbnail.qc-thumbnail--split.active {
  border-color: #e0a800;
}

.qc-thumbnail--split::after {
  content: '';
  position: absolute;
  inset: 0;
  z-index: 1;
  background: rgba(250, 204, 21, 0.3);
  pointer-events: none;
}

.qc-thumbnail-starts {
  position: absolute;
  right: 6px;
  top: 38px;
  z-index: 4;
  padding: 3px 9px;
  border-radius: 4px;
  background: #e0a800;
  color: #1a3329;
  font-size: 14px;
  font-weight: 800;
}

.qc-separation-applied {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 6px;
  font-size: 14px;
  font-weight: 700;
}

.qc-preview-stage {
  grid-column: 2;
  grid-row: 2;
  position: relative;
  min-width: 0;
  min-height: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  background: #eef1ef;
}

.qc-preview-canvas {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px 24px 18px;
  /* containing block for the crop overlay, which is positioned from the
     measured img rect relative to this element */
  position: relative;
}

.qc-main-image {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
  border-radius: 4px;
  box-shadow: 0 10px 30px rgba(18, 40, 31, 0.22);
  cursor: zoom-in;
}

.qc-nav-button {
  position: absolute;
  top: 50%;
  z-index: 6;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 48px;
  height: 48px;
  border: none;
  border-radius: 50%;
  background: #477262;
  color: #ffffff;
  cursor: pointer;
  box-shadow: 0 4px 14px rgba(18, 40, 31, 0.24);
  transform: translateY(-50%);
  transition: background 0.2s ease, transform 0.2s ease;
}

.qc-nav-button:hover {
  background: #2c5f4f;
  transform: translateY(-50%) scale(1.06);
}

.qc-nav-button--prev {
  left: 18px;
}

.qc-nav-button--next {
  right: 18px;
}

/* --- Review desk: right panel (current page, remark, metadata form) -------- */
.qc-review-panel {
  grid-column: 3;
  grid-row: 2 / 4;
  min-height: 0;
  display: grid;
  /* current image | rework reason | metadata + save pair (scrolls) | AI review.
     The template must match the child count: with only two rows, the comment
     card landed in the stretchy 1fr row (giant Rework box) and the metadata
     card fell into an implicit row at the bottom. FOUR children since the AI
     panel became a section of its own - the last row is minmax(0, auto) rather
     than auto so an expanded AI panel scrolls inside its card instead of
     pushing the metadata form out of the viewport. */
  grid-template-rows: auto auto minmax(0, 1fr) minmax(0, auto);
  gap: 8px;
  padding: 8px;
  overflow: hidden;
  border-left: 1px solid var(--lw-line-strong, #c0c8c3);
  /* A shade darker than the cards it holds, so they read as ON it. */
  background: #eef1ef;
}

/* Quiet cards: a surface and a hairline edge, and deliberately NO shadow.
   The scanned page carries the only shadow on this screen - that is what
   makes it the object being looked at - and a stack of lifted cards beside
   it would compete for the same attention. The separation comes from the
   edge and the 8px gap, which is also why the section dividers these cards
   replaced are gone: an edge AND a line is the same boundary drawn twice. */
.qc-comment-card,
.qc-info-card {
  min-width: 0;
  overflow: hidden;
  border: 1px solid var(--qc-card-line, #afb9b3);
  border-radius: 8px;
  background: #ffffff;
}

.qc-comment-card {
  display: grid;
  gap: 10px;
  padding: 12px;
}

.qc-info-card {
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 12px;
  overflow-y: auto;
}

.qc-panel-heading {
  display: grid;
  gap: 4px;
}

.qc-panel-heading span {
  color: #607267;
  font-size: 14px;
  font-weight: 800;
  letter-spacing: 0.7px;
  text-transform: uppercase;
}

.qc-panel-heading strong {
  min-width: 0;
  overflow-wrap: anywhere;
  color: #1a3329;
  font-size: 18px;
  font-weight: 800;
}

.qc-comment-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  /* No horizontal padding: .qc-comment-card already pads 12px, exactly as
     .qc-info-card does for the panels above and below. Adding more here is
     what put this label 16px to the right of CURRENT IMAGE and QC METADATA. */
  padding: 2px 0;
  cursor: pointer;
  user-select: none;
}

.qc-comment-header:focus-visible {
  outline: 2px solid var(--lw-green);
  outline-offset: -2px;
}

.qc-comment-title {
  /* Matches .qc-panel-heading span - the CURRENT IMAGE / QC METADATA label -
     so this reads as another section marker rather than a headline of its
     own floating above the buttons. */
  color: #607267;
  font-size: 14px;
  font-weight: 800;
  letter-spacing: 0.7px;
  text-transform: uppercase;
}

.qc-comment-header-actions {
  display: flex;
  align-items: center;
  gap: 10px;
}

/* Says a remark exists without expanding to prove it. */
.qc-comment-filled {
  font-size: 14px;
  color: var(--lw-green);
  font-weight: 600;
}

.qc-comment-chevron {
  transition: transform 0.16s ease;
  color: var(--lw-on-surface-variant);
}

.qc-comment-chevron--open {
  transform: rotate(180deg);
}

.qc-comment-box {
  display: grid;
  gap: 8px;
  min-height: 112px;
  padding: 10px;
  border: 1px solid #d5dbd7;
  border-radius: 4px;
  background: #ffffff;
}

.qc-comment-box p {
  margin: 0;
  color: #1a3329;
  font-size: 16px;
  font-weight: 800;
}

.qc-comment-box span {
  color: #607267;
  font-size: 15px;
  line-height: 1.4;
}

.qc-comment-box :deep(.el-textarea__inner) {
  min-height: 96px;
  border-radius: 4px;
  color: #1a3329;
  font-weight: 600;
  line-height: 1.45;
}

.qc-draft-actions {
  /* Two equal columns rather than a wrapping flex row: the pair then spans
     exactly the width of the remark box above, instead of one button
     dropping to its own line at whatever width its label happens to need. */
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}

.qc-draft-actions :deep(.el-button) {
  width: 100%;
  margin: 0;
}

/* Closes the metadata half of the card: form, then the pair that commits it,
   then a line, then the AI panel - which advises and commits nothing. */
.qc-draft-actions :deep(.el-button),
.qc-comment-box :deep(.el-button) {
  margin: 0;
  border-radius: 4px;
  font-weight: 700;
}

.qc-inline-metadata-form {
  display: grid;
  gap: 8px;
  min-width: 0;
}

.qc-inline-metadata-form :deep(.el-form-item) {
  margin-bottom: 0;
}

.qc-inline-metadata-form :deep(.el-form-item__label) {
  margin-bottom: 4px;
  color: #607267;
  font-size: 14px;
  font-weight: 800;
  line-height: 1.25;
}

.qc-inline-metadata-form :deep(.el-input__wrapper),
.qc-inline-metadata-form :deep(.el-select__wrapper) {
  min-height: 34px;
  border-radius: 4px;
}

.qc-inline-metadata-form :deep(.el-input__inner),
.qc-inline-metadata-form :deep(.el-select__placeholder) {
  min-width: 0;
  color: #1a3329;
  font-size: 15px;
  font-weight: 700;
}

/* --- Review desk: bottom tool strip ----------------------------------------- */
.qc-tool-strip {
  grid-column: 2;
  grid-row: 3;
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 58px;
  padding: 10px 14px;
  overflow: visible;
  border-top: 2px solid #2c5f4f;
  background: #f7f8f6;
}

/* The tools scroll rather than wrap: seventeen icon buttons is more than one
   row can hold at narrower widths, and wrapping would push the last tool
   under the row where nothing signals it is there (the same overflow the
   Flutter toolbar's own comment describes). */
.qc-tool-scroll {
  flex: 1 1 auto;
  min-width: 0;
  overflow-x: auto;
  overflow-y: hidden;
}

.qc-tool-row {
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 4px;
  flex-wrap: nowrap;
  width: max-content;
}

.qc-tool-sep {
  flex: 0 0 auto;
  align-self: center;
  width: 1px;
  height: 20px;
  margin: 0 4px;
  background: var(--lw-line, #d5dbd7);
}

.qc-tool-strip :deep(.el-button.is-circle) {
  flex: 0 0 auto;
  width: 34px;
  height: 34px;
  margin: 0;
  padding: 0;
}

/* The bar (.qc-tool-strip) and a plain button used to share the same
   near-white surface with only a hairline border between them, so every
   control but the red Delete read as absent. Circle tools get a real ground
   of their own here — a surface tone distinct from the bar — plus icon
   contrast from the onSurface token, not a mid grey. Danger/primary/warning
   circles (Delete, active Crop, active Separation) keep Element Plus's own
   colour treatment; this only grounds the neutral ones. */
.qc-tool-strip :deep(.el-button.is-circle:not(.el-button--primary):not(.el-button--danger):not(.el-button--warning):not(.el-button--success)) {
  border: 1px solid var(--lw-outline-variant);
  background: var(--lw-surface-container);
  color: var(--lw-on-surface);
}

.qc-tool-strip :deep(.el-button.is-circle:not(.el-button--primary):not(.el-button--danger):not(.el-button--warning):not(.el-button--success):hover) {
  border-color: var(--lw-outline);
  background: var(--lw-surface-container-high);
  color: var(--lw-on-surface);
}

.qc-tool-strip :deep(.el-button.is-circle:not(.el-button--primary):not(.el-button--danger):not(.el-button--warning):not(.el-button--success):active) {
  background: var(--lw-surface-container-highest);
}

/* Every circle tool — including the coloured ones — needs its own visible
   keyboard-focus ring; a 20-control toolbar with no focus feedback is
   unusable from the keyboard. */
.qc-tool-strip :deep(.el-button.is-circle:focus-visible) {
  outline: 2px solid var(--lw-green);
  outline-offset: 2px;
}

/* Disabled tools get an explicit muted colour AND a muted ground, rather than
   a translucent copy of the live one — a disabled tool that still looks live
   is worse than a grey one. Applies regardless of type (danger included) so
   a disabled Delete never reads as a live red button. */
.qc-tool-strip :deep(.el-button.is-circle.is-disabled) {
  border-color: var(--lw-outline-variant);
  background: var(--lw-surface-container);
  color: var(--lw-muted);
  opacity: 1;
}

.qc-deskew-step {
  display: flex;
  flex: 0 0 auto;
  align-items: center;
  gap: 2px;
  padding: 0 2px;
}

.qc-deskew-step-input {
  width: 38px;
  height: 28px;
  padding: 0 2px;
  border: 1px solid var(--lw-line, #d5dbd7);
  border-radius: 4px;
  background: #fff;
  color: var(--lw-dark);
  font-size: 15px;
  text-align: center;
}

.qc-deskew-step-input:disabled {
  color: var(--lw-muted);
  background: #f2f3f1;
}

.qc-deskew-step-suffix {
  color: var(--lw-muted);
  font-size: 14px;
}

/* Literal +/- glyphs, not icon-font glyphs: an icon font can drop tree-shaken
   codepoints in a release build (seen on a real station with Icons.add /
   Icons.remove), a text glyph from the UI font cannot go missing that way. */
.qc-deskew-nudge {
  display: flex;
  flex: 0 0 auto;
  align-items: center;
  justify-content: center;
  width: 22px;
  height: 22px;
  padding: 0;
  border: none;
  background: transparent;
  color: var(--lw-dark);
  font-size: 18px;
  font-weight: 700;
  line-height: 1;
  cursor: pointer;
}

.qc-deskew-nudge:disabled {
  color: var(--lw-muted);
  cursor: default;
}

.qc-tool-status {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  padding-left: 8px;
  color: var(--lw-muted);
  font-size: 15px;
  white-space: nowrap;
}

.qc-desk {
  border-color: var(--lw-line);
  background:
    linear-gradient(180deg, rgba(245, 238, 219, 0.72) 0, rgba(249, 247, 247, 0.98) 180px),
    var(--lw-sea-salt);
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.72);
}

.qc-desk-header,
.qc-image-rail,
.qc-review-panel,
.qc-tool-strip {
  border-color: var(--lw-line);
  background: rgba(255, 255, 255, 0.76);
}

/* Opaque under the theme too: a translucent card would show the panel's
   darker tray through it and lose the step that separates the two. */
.qc-comment-card,
.qc-info-card {
  border-color: var(--qc-card-line);
  background: var(--lw-white, #ffffff);
}

.qc-desk-header {
  background: rgba(245, 238, 219, 0.9);
}

.qc-project-title strong,
.qc-panel-heading strong,
.qc-comment-box p,
.qc-inline-metadata-form :deep(.el-input__inner),
.qc-inline-metadata-form :deep(.el-select__placeholder) {
  color: var(--lw-dark);
}

.qc-project-title span,
.qc-rail-summary span,
.qc-panel-heading span,
.qc-comment-box span,
.qc-inline-metadata-form :deep(.el-form-item__label) {
  color: var(--lw-muted);
}

.qc-rail-summary strong {
  color: var(--lw-green);
}

.qc-back-button.el-button,
.qc-primary-actions :deep(.el-button),
.qc-tool-strip :deep(.el-button):not(.is-circle),
.qc-draft-actions :deep(.el-button) {
  border-radius: 6px;
}

.qc-back-button.el-button {
  border-color: var(--lw-line);
  background: rgba(255, 255, 255, 0.72);
  color: var(--lw-dark);
  box-shadow: 0 8px 18px rgba(19, 48, 32, 0.06);
}

.qc-back-button.el-button:hover,
.qc-back-button.el-button:focus {
  border-color: var(--lw-line-strong);
  background: var(--lw-sea-salt);
  color: var(--lw-green);
}

.qc-batch-tools,
.qc-thumbnail,
.qc-comment-box,
.qc-inline-metadata-form :deep(.el-input__wrapper),
.qc-inline-metadata-form :deep(.el-select__wrapper),
.qc-comment-box :deep(.el-textarea__inner) {
  /* Flat, hairline-bordered (cardTheme: elevation 0) — not a drop shadow. */
  border-color: var(--lw-line);
  background: var(--lw-white);
}

.qc-thumbnail:hover,
.qc-thumbnail.active {
  border-color: var(--lw-green);
  background: rgba(4, 98, 65, 0.06);
}

.qc-thumbnail.selected {
  /* "Selected for transfer" tint (LifewoodColors.selectedContainer, ARGB
     0x2EFBB347 converted to rgba — see --lw-selected-container). */
  background: var(--lw-selected-container);
  box-shadow: inset 0 0 0 1px var(--lw-selected);
}

.qc-thumbnail-index,
.qc-nav-button {
  background: var(--lw-green);
  color: var(--lw-white);
}

.qc-nav-button {
  box-shadow: 0 10px 24px rgba(19, 48, 32, 0.16);
}

.qc-nav-button:hover {
  background: #034b32;
}

.qc-thumbnail-preview {
  background: var(--lw-sea-salt);
}

.qc-thumbnail-unsaved {
  background: var(--lw-saffron);
  color: var(--lw-dark);
}

.qc-thumbnail.unavailable {
  background: var(--lw-danger-soft);
}

.qc-preview-stage {
  /* Deliberately NOT a --lw-* token: the viewer frame is a neutral so the
     scan's own edges read, not the brand dark (#133020). Keep it a literal. */
  background: #202824;
}

.qc-main-image {
  border-radius: 6px;
  box-shadow: 0 18px 50px rgba(19, 48, 32, 0.16);
}

.qc-tool-strip {
  border-top-color: var(--lw-green);
}

.qc-primary-actions :deep(.el-button--success) {
  --el-button-bg-color: var(--lw-green);
  --el-button-border-color: var(--lw-green);
  --el-button-hover-bg-color: #034b32;
  --el-button-hover-border-color: #034b32;
  --el-button-active-bg-color: #034b32;
  --el-button-active-border-color: #034b32;
}

.qc-primary-actions :deep(.el-button--danger) {
  --el-button-bg-color: var(--lw-danger);
  --el-button-border-color: var(--lw-danger);
  --el-button-hover-bg-color: #c84c3b;
  --el-button-hover-border-color: #c84c3b;
}

.qc-tool-strip :deep(.el-button:not(.el-button--primary):not(.el-button--danger):not(.el-button--success)),
.qc-draft-actions :deep(.el-button:not(.el-button--primary):not(.el-button--danger):not(.el-button--success)) {
  background: rgba(255, 255, 255, 0.78);
  color: var(--lw-dark);
}

.qc-tool-strip :deep(.el-button:not(.el-button--primary):not(.el-button--danger):not(.el-button--success):hover),
.qc-draft-actions :deep(.el-button:not(.el-button--primary):not(.el-button--danger):not(.el-button--success):hover) {
  border-color: var(--lw-saffron);
  background: var(--lw-saffron-soft);
  color: var(--lw-dark);
}

@media (min-width: 1920px) {
  .qc-desk {
    grid-template-columns: minmax(190px, 230px) minmax(0, 1fr) minmax(410px, 460px);
  }
}

@media (max-width: 1440px) {
  .qc-desk {
    grid-template-columns: 180px minmax(0, 1fr) 380px;
  }

  .qc-project-title span {
    font-size: 15px;
  }
}

@media (max-width: 1200px) {
  .qc-desk {
    grid-template-columns: 160px minmax(0, 1fr) 340px;
  }

  .qc-primary-actions :deep(.el-button) {
    min-width: 72px;
    padding: 0 10px;
  }
}

@media (max-width: 1024px) {
  .qc-desk,
  .qc-desk--compact {
    grid-template-columns: 1fr;
    grid-template-rows: auto auto minmax(420px, 1fr) auto auto;
    height: auto;
    max-height: none;
    min-height: 0;
    overflow: visible;
  }

  .qc-desk-header {
    grid-column: 1;
    grid-row: 1;
    grid-template-columns: 1fr;
    align-items: stretch;
  }

  .qc-project-title,
  .qc-primary-actions {
    justify-content: center;
  }

  .qc-image-rail {
    grid-column: 1;
    grid-row: 2;
    border-right: none;
    border-bottom: 1px solid #d5dbd7;
  }

  .qc-thumbnail-list {
    flex-direction: row;
    overflow-x: auto;
    overflow-y: hidden;
  }

  .qc-thumbnail {
    width: 150px;
    flex: 0 0 150px;
  }

  .qc-thumbnail-group {
    writing-mode: vertical-rl;
    padding: 4px 2px;
  }

  .qc-preview-stage {
    grid-column: 1;
    grid-row: 3;
    min-height: 420px;
  }

  .qc-tool-strip {
    grid-column: 1;
    grid-row: 4;
  }

  .qc-review-panel {
    grid-column: 1;
    grid-row: 5;
    /* Stacked: every section sizes to its content, nothing scrolls inside.
       Spelled out to the child count like the desktop template above - it
       said `auto auto` while the panel had three children and now four, and
       the rows it did not name were implicit. Same result, but the next
       person should not have to work that out. */
    grid-template-rows: repeat(4, auto);
    border-left: none;
    border-top: 1px solid var(--lw-line-strong, #c0c8c3);
    overflow: visible;
  }
}

@media (max-width: 640px) {
  .qc-desk-header {
    padding: 8px;
  }

  .qc-project-title {
    align-items: flex-start;
    flex-direction: column;
    gap: 4px;
  }

  .qc-primary-actions {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
  }

  .qc-primary-actions :deep(.el-button) {
    width: 100%;
  }

  .qc-preview-canvas {
    padding: 12px;
  }

  .qc-nav-button {
    width: 40px;
    height: 40px;
  }

}

:deep(.el-loading-spinner) {
  margin-top: -25px;
}

:deep(.el-loading-spinner .circular) {
  width: 50px;
  height: 50px;
}
</style>
