<script setup lang="ts">
import { computed, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { ElMessageBox } from 'element-plus'
import type { UseAiReviewReturn } from '@/composables/useAiReview'
import type { AiReviewField } from '@/types'

/**
 * Findings panel for the AI-assisted metadata review, ported from the
 * Flutter reference (`qc_ai_review_panel.dart`). Deliberately not a verdict
 * screen: the engine reads the pages and reports, the reviewer decides, so a
 * finding it cannot stand behind is shown with no checkbox rather than
 * hidden, and nothing is written until the reviewer ticks something and
 * presses Apply.
 *
 * Never gates Approve/Reject — those live in QcIndexView's own toolbar and
 * read nothing from this panel or its controller.
 */
const props = defineProps<{
  controller: UseAiReviewReturn
  /** Mirrors QcReviewController.canEdit: true only while this reviewer holds
   * the claim. Claiming a task and running a review are two separate things —
   * this panel only gates the SECOND one. */
  canEdit: boolean
  onEvidenceTap?: (imageId: number) => void
}>()

const { t } = useI18n()

// Collapsed by default: metadata is read on every folder, the AI review only
// on some (matches the Flutter reference's own reasoning for a collapsible
// section). One instance per claimed folder — see QcIndexView, which mounts
// this behind `v-if="current"` — so this resets to collapsed on a new folder
// and stays put while the operator pages through the same one.
const collapsed = ref(true)
function toggleCollapsed() {
  collapsed.value = !collapsed.value
}

const job = computed(() => props.controller.job.value)

function verdictLabel(field: AiReviewField) {
  switch (field.verdict) {
    case 'match':
      return t('qc.aiReview.verdictMatch')
    case 'mismatch':
      return t('qc.aiReview.verdictMismatch')
    case 'not_visible':
      return t('qc.aiReview.verdictNotVisible')
    default:
      return t('qc.aiReview.verdictUncertain')
  }
}

const stageText = computed(() => {
  const current = job.value
  const total = current?.progress.totalImages ?? 0
  const done = current?.progress.processedImages ?? 0
  switch (props.controller.stage.value) {
    case 'queued':
      return t('qc.aiReview.stageQueued')
    case 'extracting':
      return total > 0 ? t('qc.aiReview.stageExtracting', { done, total }) : t('qc.aiReview.stageExtractingUnknown')
    case 'comparing':
      return t('qc.aiReview.stageComparing')
    default:
      return t('qc.aiReview.stageWorking')
  }
})

const progressPercent = computed(() => {
  const current = job.value
  if (!current || props.controller.stage.value !== 'extracting' || !current.progress.totalImages) return undefined
  return Math.round((current.progress.processedImages / current.progress.totalImages) * 100)
})

const overallText = computed(() => {
  switch (job.value?.result?.overallStatus) {
    case 'consistent':
      return t('qc.aiReview.overallConsistent')
    case 'needs_review':
      return t('qc.aiReview.overallNeedsReview')
    default:
      return t('qc.aiReview.overallInsufficient')
  }
})

async function runReview() {
  if (props.controller.wouldDiscardResult.value) {
    try {
      await ElMessageBox.confirm(t('qc.aiReview.rerunConfirm'), t('qc.title'), { type: 'warning' })
    } catch {
      return
    }
  }
  await props.controller.start()
}

function selectAllOrClear() {
  if (props.controller.selected.value.size === props.controller.appliable.value.length) {
    props.controller.clearSelection()
  } else {
    props.controller.selectAll()
  }
}
</script>

<template>
  <section class="qc-ai-review">
    <div v-if="!canEdit" class="qc-ai-review__note">{{ t('qc.aiReview.claimFirst') }}</div>
    <div v-else-if="controller.disabled.value" class="qc-ai-review__note">{{ t('qc.aiReview.switchedOff') }}</div>
    <template v-else>
      <header
        class="qc-ai-review__header"
        role="button"
        tabindex="0"
        :aria-expanded="!collapsed"
        @click="toggleCollapsed"
        @keydown.enter.prevent="toggleCollapsed"
        @keydown.space.prevent="toggleCollapsed"
      >
        <span class="qc-ai-review__title">{{ t('qc.aiReview.title') }}</span>
        <div class="qc-ai-review__header-actions">
          <el-button
            size="small"
            type="primary"
            plain
            :loading="controller.starting.value"
            :disabled="controller.running.value"
            @click.stop="runReview"
          >
            {{ job ? t('qc.aiReview.runAgain') : t('qc.aiReview.run') }}
          </el-button>
          <el-icon class="qc-ai-review__chevron" :class="{ 'qc-ai-review__chevron--open': !collapsed }">
            <ArrowDown />
          </el-icon>
        </div>
      </header>

      <template v-if="!collapsed">
      <p v-if="controller.error.value" class="qc-ai-review__error">{{ controller.error.value }}</p>

      <div v-if="controller.running.value" class="qc-ai-review__progress">
        <el-progress :percentage="progressPercent ?? 0" :indeterminate="progressPercent === undefined" :show-text="false" />
        <span>{{ stageText }}</span>
      </div>

      <p v-if="job && !controller.running.value && controller.isStale.value" class="qc-ai-review__stale">
        {{ t('qc.aiReview.staleNotice') }}
      </p>
      <p v-if="job?.status === 'failed'" class="qc-ai-review__error">
        {{ job.error || t('qc.aiReview.failed') }}
      </p>

      <div v-if="!job" class="qc-ai-review__note">{{ t('qc.aiReview.noReviewYet') }}</div>
      <div v-else-if="controller.running.value" class="qc-ai-review__note">{{ t('qc.aiReview.running') }}</div>
      <div v-else-if="job.status === 'cancelled'" class="qc-ai-review__note">
        {{ job.cancelReason || t('qc.aiReview.cancelled') }}
      </div>
      <template v-else-if="job.result">
        <p class="qc-ai-review__overall">{{ overallText }}</p>

        <template v-if="controller.appliable.value.length">
          <p class="qc-ai-review__section-label">
            {{ controller.isStale.value ? t('qc.aiReview.suggestionsStale') : t('qc.aiReview.suggestions') }}
          </p>
          <div v-for="field in controller.appliable.value" :key="field.key" class="qc-ai-review__card">
            <div class="qc-ai-review__card-row">
              <el-checkbox
                v-if="!controller.isStale.value"
                :model-value="controller.selected.value.has(field.key)"
                :disabled="controller.applying.value"
                @change="(checked: boolean) => controller.toggle(field.key, checked)"
              />
              <strong class="qc-ai-review__field-key">{{ field.key }}</strong>
              <el-tag size="small" :type="field.verdict === 'mismatch' ? 'danger' : 'info'">
                {{ verdictLabel(field) }} · {{ Math.round(field.confidence * 100) }}%
              </el-tag>
            </div>
            <div class="qc-ai-review__values">
              <span>{{ t('qc.aiReview.keyed') }}: {{ field.currentValue || '—' }}</span>
              <span v-if="field.suggestedValue">{{ t('qc.aiReview.pagesShow') }}: {{ field.suggestedValue }}</span>
            </div>
            <button
              v-for="evidence in field.evidence"
              :key="`${evidence.imageId}-${evidence.observation}`"
              type="button"
              class="qc-ai-review__evidence"
              @click="onEvidenceTap?.(evidence.imageId)"
            >
              {{ evidence.filename }}: {{ evidence.observation }}
            </button>
          </div>
        </template>

        <template v-if="controller.advisory.value.length">
          <p class="qc-ai-review__section-label">{{ t('qc.aiReview.alsoNoted') }}</p>
          <div v-for="field in controller.advisory.value" :key="field.key" class="qc-ai-review__card">
            <div class="qc-ai-review__card-row">
              <strong class="qc-ai-review__field-key">{{ field.key }}</strong>
              <el-tag size="small" type="info">{{ verdictLabel(field) }}</el-tag>
            </div>
            <div class="qc-ai-review__values">
              <span>{{ t('qc.aiReview.keyed') }}: {{ field.currentValue || '—' }}</span>
              <span v-if="field.suggestedValue">{{ t('qc.aiReview.pagesShow') }}: {{ field.suggestedValue }}</span>
            </div>
          </div>
        </template>

        <p v-if="!controller.appliable.value.length && !controller.advisory.value.length" class="qc-ai-review__note">
          {{ t('qc.aiReview.nothingToReport') }}
        </p>
      </template>
      <p v-else class="qc-ai-review__note">{{ t('qc.aiReview.noFindings') }}</p>

      <footer v-if="controller.appliable.value.length && !controller.isStale.value" class="qc-ai-review__apply-bar">
        <el-button size="small" link :disabled="controller.applying.value" @click="selectAllOrClear">
          {{ controller.selected.value.size === controller.appliable.value.length ? t('common.less') : t('qc.aiReview.selectAll') }}
        </el-button>
        <span class="qc-ai-review__count">
          {{ t('qc.aiReview.selectedCount', { count: controller.selected.value.size, total: controller.appliable.value.length }) }}
        </span>
        <el-button
          size="small"
          type="primary"
          :loading="controller.applying.value"
          :disabled="!controller.selected.value.size"
          @click="controller.apply()"
        >
          {{ t('qc.aiReview.apply') }}
        </el-button>
      </footer>
      </template>
    </template>
  </section>
</template>

<style scoped>
/* New component, no existing style to fit — kept plain and functional. The
 * re-skin pass owns visual design; this only lays things out. */
.qc-ai-review {
  border-top: 1px solid var(--el-border-color-lighter);
  margin-top: 12px;
  padding-top: 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.qc-ai-review__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  cursor: pointer;
}
.qc-ai-review__header-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}
.qc-ai-review__chevron {
  transition: transform 0.16s ease;
  color: var(--el-text-color-secondary);
}
.qc-ai-review__chevron--open {
  transform: rotate(180deg);
}
.qc-ai-review__title {
  font-weight: 600;
  font-size: 16px;
}
.qc-ai-review__note {
  color: var(--el-text-color-secondary);
  font-size: 15px;
}
.qc-ai-review__error {
  color: var(--el-color-danger);
  font-size: 15px;
  margin: 0;
}
.qc-ai-review__stale {
  color: var(--el-color-danger);
  font-size: 15px;
  margin: 0;
}
.qc-ai-review__progress {
  display: flex;
  flex-direction: column;
  gap: 4px;
  font-size: 15px;
  color: var(--el-text-color-secondary);
}
.qc-ai-review__overall {
  font-size: 15px;
  margin: 0;
}
.qc-ai-review__section-label {
  font-size: 14px;
  font-weight: 600;
  color: var(--el-text-color-secondary);
  margin: 4px 0 0;
}
.qc-ai-review__card {
  border: 1px solid var(--el-border-color-lighter);
  border-radius: 4px;
  padding: 8px;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.qc-ai-review__card-row {
  display: flex;
  align-items: center;
  gap: 8px;
}
.qc-ai-review__field-key {
  flex: 1;
  font-size: 15px;
}
.qc-ai-review__values {
  display: flex;
  flex-direction: column;
  gap: 2px;
  font-size: 15px;
  color: var(--el-text-color-secondary);
}
.qc-ai-review__evidence {
  text-align: left;
  background: none;
  border: none;
  padding: 0;
  font-size: 14px;
  color: var(--el-color-primary);
  cursor: pointer;
}
.qc-ai-review__apply-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  border-top: 1px solid var(--el-border-color-lighter);
  padding-top: 8px;
}
.qc-ai-review__count {
  flex: 1;
  font-size: 15px;
  color: var(--el-text-color-secondary);
}
</style>
