// Polling logic for AI review jobs in the QC Platform console: backoff delays,
// what counts as progress, and which HTTP errors stop the polling. Used by
// useAiReview.ts; the decision functions are pure so they are easy to test.
import type { AiReviewJob } from '@/types'
import type { ApiError } from '@/api/client'

/**
 * Polls one AI review job until it finishes.
 *
 * Ported verbatim from the Flutter reference (`services/qc_ai_poller.dart`)
 * rather than re-derived: the constants below were tuned against the real
 * engine, and re-deriving them re-finds the same bugs. Kept as pure,
 * exported functions plus a small stateful class so the decision logic
 * (next delay, progress signature, fatal-vs-retryable) is trivially
 * testable even without a test runner configured for this project yet.
 */

/** Backoff ladder. The first delay is short because most jobs report their
 * first page quickly. */
export const AI_REVIEW_POLL_DELAYS_MS = [1000, 2000, 4000, 8000, 10000] as const

/** Status codes that mean the job is not ours to watch any more: someone
 * else took the claim, the job is gone, or the folder moved on. Retrying
 * any of these just repeats the same answer. */
export const AI_REVIEW_FATAL_STATUS_CODES = [403, 404, 409] as const

/** How far apart two polls should be, given whether the job moved since the
 * last one. Progress resets the ladder; a quiet job climbs it. */
export function nextDelayIndex(current: number, progressed: boolean): number {
  if (progressed) return 0
  return current + 1 >= AI_REVIEW_POLL_DELAYS_MS.length ? AI_REVIEW_POLL_DELAYS_MS.length - 1 : current + 1
}

/** What changing here counts as the job having moved. */
export function progressSignature(job: AiReviewJob): string {
  return `${job.status}:${job.stage ?? ''}:${job.progress.processedImages}:${job.progress.totalImages}`
}

export function isFatalStatus(status: number | undefined): boolean {
  return status !== undefined && (AI_REVIEW_FATAL_STATUS_CODES as readonly number[]).includes(status)
}

export function isFinished(job: AiReviewJob): boolean {
  return job.status === 'succeeded' || job.status === 'failed' || job.status === 'cancelled'
}

export function isRunning(job: AiReviewJob): boolean {
  return job.status === 'queued' || job.status === 'running'
}

/**
 * Whether starting a review now should force a new run, and whether to ask
 * the reviewer first.
 *
 * A failed or cancelled job is worth retrying outright. A finished job that
 * still matches the folder would be thrown away by a re-run, so that one is
 * worth a confirmation. Anything else — no job, or one already running —
 * needs neither.
 */
export function startAction(job: AiReviewJob | null | undefined): { force: boolean; confirmRerun: boolean } {
  if (!job) return { force: false, confirmRerun: false }
  if (job.status === 'failed' || job.status === 'cancelled') return { force: true, confirmRerun: false }
  if (job.status === 'succeeded' && !job.stale) return { force: true, confirmRerun: true }
  return { force: false, confirmRerun: false }
}

/** The stage to show, filling in what the engine leaves implicit.
 *
 * A running job that has read every page but not yet reported is comparing,
 * even before it says so. */
export function resolveStage(job: AiReviewJob | null | undefined): string | null {
  if (!job) return null
  if (job.status === 'queued') return 'queued'
  if (job.stage) return job.stage
  if (job.status !== 'running') return null
  if (job.progress.totalImages > 0 && job.progress.processedImages >= job.progress.totalImages) return 'comparing'
  return 'extracting'
}

export interface AiReviewPollerCallbacks {
  onUpdate: (job: AiReviewJob) => void
  onFinished: (job: AiReviewJob) => void
  onFatal: (error: ApiError) => void
}

/**
 * Watches one job until it reaches a terminal state.
 *
 * The generation counter stops a stale timer from a previous claim
 * overwriting the current one: `stop()` bumps it, so a poll already in
 * flight from a job we've moved on from finds `generation !== this.generation`
 * and quietly drops its own result instead of calling back into whatever is
 * now current.
 */
export class AiReviewPoller {
  constructor(private readonly fetchJob: (folderId: number, jobId: string) => Promise<AiReviewJob>) {}

  private timer: ReturnType<typeof setTimeout> | undefined
  private stopped = true
  private generation = 0
  private delayIndex = 0
  private lastSignature = ''

  start(folderId: number, jobId: string, callbacks: AiReviewPollerCallbacks, initial?: AiReviewJob): void {
    this.stop()
    this.stopped = false
    const generation = ++this.generation
    this.delayIndex = 0
    this.lastSignature = initial ? progressSignature(initial) : ''
    this.schedule(generation, folderId, jobId, callbacks)
  }

  stop(): void {
    this.stopped = true
    this.generation++
    if (this.timer !== undefined) clearTimeout(this.timer)
    this.timer = undefined
    this.delayIndex = 0
    this.lastSignature = ''
  }

  private schedule(generation: number, folderId: number, jobId: string, callbacks: AiReviewPollerCallbacks): void {
    if (this.stopped || generation !== this.generation) return
    this.timer = setTimeout(
      () => void this.poll(generation, folderId, jobId, callbacks),
      AI_REVIEW_POLL_DELAYS_MS[this.delayIndex],
    )
  }

  private async poll(
    generation: number,
    folderId: number,
    jobId: string,
    callbacks: AiReviewPollerCallbacks,
  ): Promise<void> {
    if (this.stopped || generation !== this.generation) return
    try {
      const job = await this.fetchJob(folderId, jobId)
      if (this.stopped || generation !== this.generation) return

      callbacks.onUpdate(job)
      if (isFinished(job)) {
        this.timer = undefined
        callbacks.onFinished(job)
        return
      }

      const signature = progressSignature(job)
      this.delayIndex = nextDelayIndex(this.delayIndex, signature !== this.lastSignature)
      this.lastSignature = signature
      this.schedule(generation, folderId, jobId, callbacks)
    } catch (error) {
      if (this.stopped || generation !== this.generation) return
      const status = (error as ApiError).status
      if (isFatalStatus(status)) {
        this.timer = undefined
        callbacks.onFatal(error as ApiError)
        return
      }
      // Everything else is worth another try: the engine is a local process
      // and a dropped connection here usually means it was busy, not broken.
      this.delayIndex = nextDelayIndex(this.delayIndex, false)
      this.schedule(generation, folderId, jobId, callbacks)
    }
  }
}
