// State and actions for the QC Platform's AI metadata review: start a job for
// the folder on screen, watch it through AiReviewPoller, and apply selected
// suggestions. QcAiReviewPanel.vue is the view; the review screen merges the
// task returned by an apply.
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { qcApi } from '@/api'
import type { ApiError } from '@/api/client'
import type { AiReviewField, AiReviewJob, MetadataQcTask } from '@/types'
import { AiReviewPoller, isRunning, resolveStage, startAction } from './useAiReviewPoller'

/**
 * The engine's own bar for accepting a suggestion (`APPLY_CONFIDENCE` in
 * `backend/app/services/ai_review.py` and `schemas/qc.py`). The apply
 * endpoint rejects anything under this with a 400, so a checkbox for a field
 * below it would just be a slower way to see "no" — kept here, named, rather
 * than hardcoded twice.
 */
export const AI_REVIEW_APPLY_CONFIDENCE = 0.8

function canApplyField(field: AiReviewField): boolean {
  return field.verdict === 'mismatch' && field.confidence >= AI_REVIEW_APPLY_CONFIDENCE && !!field.suggestedValue
}

/**
 * Runs the AI metadata review for the task on screen and holds its findings.
 *
 * Ported from the Flutter reference's `QcAiReviewController`. Deliberately
 * owns only the AI job — applying a suggestion writes the metadata draft and
 * comes back as a new task, which the caller merges the same way it merges
 * every other draft mutation (`onApplied`).
 *
 * `task` and `canEdit` are getters, not refs, so this composable always reads
 * the caller's current value rather than a snapshot taken at setup — the same
 * `current` ref QcIndexView already mutates on every draft action.
 */
export function useAiReview(
  task: () => MetadataQcTask | null | undefined,
  canEdit: () => boolean,
  onApplied: (task: MetadataQcTask) => void,
) {
  const job = ref<AiReviewJob | null>(null)
  const loading = ref(false)
  const starting = ref(false)
  const applying = ref(false)
  const error = ref('')
  // Set when the engine says AI review is switched off. That is a decision
  // made in LWCam Admin, not a fault, so the panel explains rather than
  // offers a retry that cannot succeed.
  const disabled = ref(false)
  const selected = ref<Set<string>>(new Set())

  const poller = new AiReviewPoller((folderId, jobId) => qcApi.aiReviewJob(folderId, jobId).then((r) => r.data.data))

  const appliable = computed(() => job.value?.result?.fieldReviews.filter(canApplyField) ?? [])
  const advisory = computed(() => job.value?.result?.fieldReviews.filter((f) => !canApplyField(f)) ?? [])
  const isStale = computed(() => job.value?.stale ?? false)
  const stage = computed(() => resolveStage(job.value))
  const running = computed(() => (job.value ? isRunning(job.value) : false))
  /** Whether starting now would discard a good result, so the view can ask. */
  const wouldDiscardResult = computed(() => startAction(job.value).confirmRerun)

  /** Takes a job as the current one, dropping any ticks it invalidates. */
  function adopt(next: AiReviewJob) {
    job.value = next
    const keys = new Set((next.result?.fieldReviews ?? []).filter(canApplyField).map((f) => f.key))
    selected.value = new Set([...selected.value].filter((key) => keys.has(key)))
  }

  function watchJob(from: AiReviewJob) {
    poller.start(
      from.folderId,
      from.jobId,
      {
        onUpdate: adopt,
        onFinished: adopt,
        onFatal: (e) => {
          error.value = e.message
        },
      },
      from,
    )
  }

  /** Picks up a review that already exists — most often one the AI scanner
   * ran before the reviewer opened the folder. The endpoint returns null
   * cleanly when there is none; that is not an error. */
  async function loadLatest() {
    const current = task()
    if (!current || !canEdit()) return
    loading.value = true
    try {
      const { data } = await qcApi.latestAiReview(current.id)
      if (!data.data) {
        job.value = null
        return
      }
      adopt(data.data)
      // A job left running from a previous session still needs watching.
      if (isRunning(data.data)) watchJob(data.data)
    } catch (e) {
      // 403 means the claim is not ours; the panel already says to claim first.
      if ((e as ApiError).status !== 403) error.value = (e as Error).message
    } finally {
      loading.value = false
    }
  }

  async function start(): Promise<boolean> {
    const current = task()
    if (!current || !canEdit()) return false
    starting.value = true
    error.value = ''
    try {
      const { data } = await qcApi.startAiReview(current.id, current.sourceHash, startAction(job.value).force)
      disabled.value = false
      adopt(data.data)
      if (isRunning(data.data)) watchJob(data.data)
      return true
    } catch (e) {
      // 503 is the engine reporting a setting, not a failure — shown as a
      // state, not a retryable error. Never used to gate Approve/Reject.
      if ((e as ApiError).status === 503) disabled.value = true
      error.value = (e as Error).message
      return false
    } finally {
      starting.value = false
    }
  }

  function toggle(key: string, on: boolean) {
    const next = new Set(selected.value)
    if (on) next.add(key)
    else next.delete(key)
    selected.value = next
  }

  function selectAll() {
    selected.value = new Set(appliable.value.map((f) => f.key))
  }

  function clearSelection() {
    selected.value = new Set()
  }

  /** Writes the ticked suggestions into the metadata draft. */
  async function apply(): Promise<boolean> {
    const current = task()
    const currentJob = job.value
    if (!current || !currentJob || selected.value.size === 0) return false
    applying.value = true
    error.value = ''
    try {
      const { data } = await qcApi.applyAiReview(current.id, current.sourceHash, currentJob.inputHash, [
        ...selected.value,
      ])
      onApplied(data.data)
      selected.value = new Set()
      // The applied values are now the metadata, so the findings that
      // described the old ones are out of date — ask the engine for the
      // current picture rather than leave a stale checkmark on screen.
      await loadLatest()
      return true
    } catch (e) {
      error.value = (e as Error).message
      return false
    } finally {
      applying.value = false
    }
  }

  // Resets and reloads whenever the folder itself changes (claim, revert,
  // claim-next). `task()` is reassigned on every draft mutation of the SAME
  // folder too, but its `id` only changes on an actual folder switch, so this
  // naturally fires once per claim rather than on every edit — the same
  // effect the Flutter controller gets from its `_latestLoaded` guard.
  watch(
    () => task()?.id,
    () => {
      poller.stop()
      job.value = null
      error.value = ''
      disabled.value = false
      selected.value = new Set()
      if (canEdit()) void loadLatest()
    },
    { immediate: true },
  )

  onBeforeUnmount(() => poller.stop())

  return {
    job,
    loading,
    starting,
    applying,
    error,
    disabled,
    selected,
    appliable,
    advisory,
    isStale,
    stage,
    running,
    wouldDiscardResult,
    loadLatest,
    start,
    apply,
    toggle,
    selectAll,
    clearSelection,
  }
}

export type UseAiReviewReturn = ReturnType<typeof useAiReview>
