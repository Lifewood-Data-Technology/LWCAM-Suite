<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { ElMessage, ElMessageBox } from 'element-plus'
import AppShell from '@/components/AppShell.vue'
import { adminApi } from '@/api'
import { useAdaptivePageSize } from '@/composables/useAdaptivePageSize'
import { formatTimestamp } from '@/utils/date'
import type { ExportFailureEntry, ExportFolder, ExportIssue, ExportPreflight, ExportRun, ExportRunItem } from '@/types'

const { t, te } = useI18n()
const { pageSize } = useAdaptivePageSize({
  rowHeight: 52,
  headerHeight: 430,
  footerHeight: 76,
  safePadding: 48,
  minRows: 6,
})
const loading = ref(false)
const running = ref(false)
const folderLoading = ref(false)
const exportingFolderId = ref<number>()
const exportStatus = ref<'all' | 'exported' | 'unexported'>('all')
const page = ref(1)
const folders = ref<ExportFolder[]>([])
const total = ref(0)
const preflight = ref<ExportPreflight>()
const current = ref<ExportRun>()
const failures = ref<ExportFailureEntry[]>([])
const failuresLoading = ref(false)
const selectedFailureIds = ref<number[]>([])
const retryingSelected = ref(false)
const retryingAll = ref(false)
let pollTimer: number | undefined

function runIsActive(run?: ExportRun) {
  return ['QUEUED', 'RUNNING'].includes(run?.status || '')
}

const isActive = computed(() => runIsActive(current.value))
const canRun = computed(() =>
  Boolean(preflight.value?.ready && preflight.value.eligibleCount > 0 && !isActive.value),
)
const completedCount = computed(() =>
  (current.value?.succeeded || 0) + (current.value?.failed || 0) + (current.value?.skipped || 0),
)
const progress = computed(() => {
  if (!current.value?.total) return 0
  return Math.round((completedCount.value * 100) / current.value.total)
})
const totalPages = computed(() => Math.max(1, Math.ceil(total.value / pageSize.value)))
const pageStart = computed(() => (total.value ? (page.value - 1) * pageSize.value + 1 : 0))
const pageEnd = computed(() => Math.min(total.value, page.value * pageSize.value))

function normalizePage() {
  page.value = Math.min(page.value, totalPages.value)
}

async function fetchFolderPage(resetPage = false) {
  if (resetPage) page.value = 1
  let response = await adminApi.exportFolders(exportStatus.value, page.value, pageSize.value)
  total.value = response.data.data.total
  normalizePage()
  if (response.data.data.page !== page.value) {
    response = await adminApi.exportFolders(exportStatus.value, page.value, pageSize.value)
    total.value = response.data.data.total
  }
  folders.value = response.data.data.records
}

async function loadAll() {
  loading.value = true
  try {
    const [preflightResult] = await Promise.all([
      adminApi.exportPreflight(),
      fetchFolderPage(),
      loadFailures(),
    ])
    preflight.value = preflightResult.data.data
    current.value = preflight.value.activeRun
    if (isActive.value) schedulePoll()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

async function loadFailures() {
  failuresLoading.value = true
  try {
    const { data } = await adminApi.exportFailures()
    failures.value = data.data
    selectedFailureIds.value = selectedFailureIds.value.filter((id) =>
      failures.value.some((entry) => entry.folderId === id),
    )
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    failuresLoading.value = false
  }
}

function failureErrorMessage(entry: ExportFailureEntry) {
  if (entry.errorKey) {
    const key = `admin.exports.errors.${entry.errorKey}`
    if (te(key)) return t(key, entry.errorParams || {})
  }
  return entry.error || t('admin.exports.unknownError')
}

async function retrySelectedFailures() {
  if (!selectedFailureIds.value.length || isActive.value) return
  try {
    await ElMessageBox.confirm(t('admin.exports.retryConfirm'), t('admin.exports.retrySelected'), { type: 'warning' })
  } catch {
    return
  }
  retryingSelected.value = true
  try {
    const { data } = await adminApi.retryExports(selectedFailureIds.value)
    current.value = data.data
    selectedFailureIds.value = []
    ElMessage.success(t('admin.exports.retryStarted'))
    schedulePoll()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    retryingSelected.value = false
  }
}

async function retryAllFailures() {
  if (!failures.value.length || isActive.value) return
  try {
    await ElMessageBox.confirm(t('admin.exports.retryAllConfirm'), t('admin.exports.retryAll'), { type: 'warning' })
  } catch {
    return
  }
  retryingAll.value = true
  try {
    const { data } = await adminApi.retryExports()
    current.value = data.data
    selectedFailureIds.value = []
    ElMessage.success(t('admin.exports.retryStarted'))
    schedulePoll()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    retryingAll.value = false
  }
}

async function loadFolders(resetPage = false) {
  folderLoading.value = true
  try {
    await fetchFolderPage(resetPage)
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    folderLoading.value = false
  }
}

function stopPolling() {
  if (pollTimer !== undefined) {
    window.clearTimeout(pollTimer)
    pollTimer = undefined
  }
}

function schedulePoll() {
  if (pollTimer !== undefined || !isActive.value) return
  pollTimer = window.setTimeout(() => {
    pollTimer = undefined
    void poll()
  }, 3000)
}

function showFailureNotice(run?: ExportRun) {
  const failedItems = run?.items.filter((item) => item.status === 'FAILED') || []
  if (!failedItems.length) return
  const visibleItems = failedItems.slice(0, 3)
  const details = visibleItems
    .map((item) => t('admin.exports.failedItem', {
      id: item.folderId,
      error: exportErrorMessage(item),
    }))
    .join('; ')
  const remaining = failedItems.length - visibleItems.length
  const more = remaining > 0 ? t('admin.exports.failedMore', { count: remaining }) : ''
  ElMessage({
    type: 'error',
    message: t('admin.exports.failedNotice', {
      count: failedItems.length,
      details,
      more,
    }),
    duration: 10000,
    showClose: true,
  })
}

function exportErrorMessage(issue?: ExportIssue | ExportRunItem) {
  if (issue?.errorKey) {
    const key = `admin.exports.errors.${issue.errorKey}`
    if (te(key)) return t(key, issue.errorParams || {})
  }
  if ('error' in (issue || {}) && (issue as ExportRunItem).error) {
    return (issue as ExportRunItem).error as string
  }
  return t('admin.exports.unknownError')
}

const preflightErrorDescription = computed(() =>
  (preflight.value?.errors || [])
    .map((issue) => exportErrorMessage(issue))
    .join('; '),
)

function qcStatusLabel(status: string) {
  const key = `admin.exports.qcStatuses.${status.toLowerCase()}`
  return te(key) ? t(key) : status
}

async function poll() {
  try {
    const { data } = await adminApi.currentExport()
    const finishedRun = data.data || undefined
    current.value = finishedRun
    if (runIsActive(finishedRun)) {
      schedulePoll()
      return
    }
    stopPolling()
    await loadAll()
    showFailureNotice(finishedRun)
  } catch {
    schedulePoll()
  }
}

async function exportFolder(folder: ExportFolder) {
  if (!folder.exportable || folder.isExported || isActive.value) return
  try {
    await ElMessageBox.confirm(
      t('admin.exports.singleConfirm', { name: folder.folderName }),
      t('admin.exports.export'),
      { type: 'warning' },
    )
  } catch {
    return
  }
  exportingFolderId.value = folder.folderId
  try {
    const { data } = await adminApi.runFolderExport(folder.folderId)
    current.value = data.data
    ElMessage.success(t('admin.exports.started'))
    schedulePoll()
  } catch (error) {
    ElMessage.error((error as Error).message)
    await loadAll()
  } finally {
    exportingFolderId.value = undefined
  }
}

function exportActionLabel(folder: ExportFolder) {
  if (folder.isExported) return t('admin.exports.exported')
  if (!folder.exportable) return t('admin.exports.waitingQc')
  return t('admin.exports.export')
}

function changePage(nextPage: number) {
  if (nextPage < 1 || nextPage > totalPages.value || nextPage === page.value) return
  page.value = nextPage
  void loadFolders()
}

async function startExport() {
  try {
    await ElMessageBox.confirm(
      t('admin.exports.runConfirm', { count: preflight.value?.eligibleCount || 0 }),
      t('admin.exports.run'),
      { type: 'warning' },
    )
  } catch {
    return
  }
  running.value = true
  try {
    const { data } = await adminApi.runExport()
    current.value = data.data
    ElMessage.success(t('admin.exports.started'))
    schedulePoll()
  } catch (error) {
    ElMessage.error((error as Error).message)
    await loadAll()
  } finally {
    running.value = false
  }
}

onMounted(() => {
  void loadAll()
})

onBeforeUnmount(() => {
  stopPolling()
})

watch(pageSize, () => {
  page.value = 1
  void loadFolders()
})
</script>

<template>
  <AppShell>
    <div class="page-title">
      <div>
        <h1>{{ t('admin.exports.title') }}</h1>
        <p>{{ t('admin.exports.subtitle') }}</p>
      </div>
      <el-button :icon="'Refresh'" :loading="loading" @click="loadAll">{{ t('common.refresh') }}</el-button>
    </div>

    <el-alert
      v-if="preflight && !preflight.ready"
      type="error"
      :title="t('admin.exports.notReady')"
      :description="preflightErrorDescription"
      show-icon
      :closable="false"
    />

    <div class="metric-grid export-metrics">
      <div class="metric accent">
        <span>{{ t('admin.exports.eligible') }}</span><strong>{{ preflight?.eligibleCount || 0 }}</strong>
      </div>
      <div class="metric green">
        <span>{{ t('admin.exports.exportedFolders') }}</span><strong>{{ preflight?.exportedCount || 0 }}</strong>
      </div>
    </div>

    <section class="panel action-panel">
      <div>
        <h2>{{ t('admin.exports.batch') }}</h2>
        <p v-if="preflight?.config">
          {{ preflight.config.csvEncoding }} / {{ preflight.config.csvLineEnding }} ·
          {{ preflight.config.outputDir }}
        </p>
      </div>
      <div class="actions">
        <el-button type="primary" :disabled="!canRun" :loading="running" @click="startExport">
          {{ t('admin.exports.run') }}
        </el-button>
      </div>
      <div v-if="isActive && current" class="running-progress">
        <span>{{ t('admin.exports.exportingProgress', { completed: completedCount, total: current.total }) }}</span>
        <el-progress :percentage="progress" />
      </div>
    </section>

    <section v-if="failures.length || failuresLoading" class="panel table-panel">
      <div class="panel-heading folder-list-heading">
        <h2>{{ t('admin.exports.failuresTitle') }}</h2>
        <div class="actions">
          <el-button
            size="small"
            :disabled="!selectedFailureIds.length || isActive"
            :loading="retryingSelected"
            @click="retrySelectedFailures"
          >
            {{ t('admin.exports.retrySelected') }}
          </el-button>
          <el-button size="small" type="primary" :disabled="isActive" :loading="retryingAll" @click="retryAllFailures">
            {{ t('admin.exports.retryAll') }}
          </el-button>
        </div>
      </div>
      <el-table
        v-loading="failuresLoading"
        :data="failures"
        max-height="360"
        row-key="folderId"
        @selection-change="(rows: ExportFailureEntry[]) => (selectedFailureIds = rows.map((row) => row.folderId))"
      >
        <el-table-column type="selection" width="46" />
        <el-table-column prop="folderId" :label="t('admin.exports.folderId')" min-width="130" />
        <el-table-column prop="folderName" :label="t('admin.exports.folder')" min-width="180" show-overflow-tooltip />
        <el-table-column :label="t('admin.exports.error')" min-width="260" show-overflow-tooltip>
          <template #default="{ row }">{{ failureErrorMessage(row) }}</template>
        </el-table-column>
        <el-table-column :label="t('common.actions')" min-width="170">
          <template #default="{ row }">{{ t('admin.exports.failureAttempts', { count: row.attempts || 1 }) }}</template>
        </el-table-column>
      </el-table>
    </section>

    <section class="panel table-panel">
      <div class="panel-heading folder-list-heading">
        <h2>{{ t('admin.exports.allFolders') }}</h2>
        <el-select v-model="exportStatus" class="export-filter" @change="loadFolders(true)">
          <el-option :label="t('admin.exports.filterAll')" value="all" />
          <el-option :label="t('admin.exports.filterExported')" value="exported" />
          <el-option :label="t('admin.exports.filterUnexported')" value="unexported" />
        </el-select>
      </div>
      <el-table v-if="folders.length" v-loading="folderLoading" :data="folders" max-height="560">
        <el-table-column prop="folderId" :label="t('admin.exports.folderId')" min-width="130" />
        <el-table-column prop="folderName" :label="t('admin.exports.folder')" min-width="180" show-overflow-tooltip />
        <el-table-column prop="folderSeq" :label="t('admin.exports.sequence')" min-width="130" />
        <el-table-column prop="boxName" :label="t('admin.exports.box')" min-width="160" show-overflow-tooltip />
        <el-table-column :label="t('admin.exports.project')" min-width="240" show-overflow-tooltip>
          <template #default="{ row }">{{ row.projectId }} · {{ row.projectName }}</template>
        </el-table-column>
        <el-table-column prop="imageCount" :label="t('admin.exports.images')" min-width="130" />
        <el-table-column :label="t('admin.exports.qc')" min-width="130">
          <template #default="{ row }">{{ qcStatusLabel(row.qcStatus) }}</template>
        </el-table-column>
        <el-table-column :label="t('admin.exports.exportStatus')" min-width="160">
          <template #default="{ row }">
            <el-tag :type="row.isExported ? 'success' : 'info'">
              {{ row.isExported ? t('admin.exports.exported') : t('admin.exports.unexported') }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="groupId" :label="t('admin.exports.groupId')" min-width="220" show-overflow-tooltip />
        <el-table-column :label="t('admin.exports.exportedAt')" min-width="180">
          <template #default="{ row }">{{ formatTimestamp(row.exportedTime) }}</template>
        </el-table-column>
        <el-table-column :label="t('admin.exports.uploadStatus')" min-width="220" show-overflow-tooltip>
          <template #default="{ row }">
            <template v-if="row.uploadError">
              <el-tag type="danger">{{ t('admin.exports.uploadFailed') }}</el-tag> {{ row.uploadError }}
            </template>
            <span v-else-if="row.uploadedTime">{{ t('admin.exports.uploaded') }} · {{ formatTimestamp(row.uploadedTime) }}</span>
            <span v-else>{{ t('admin.exports.notUploaded') }}</span>
          </template>
        </el-table-column>
        <el-table-column :label="t('common.actions')" min-width="170" fixed="right">
          <template #default="{ row }">
            <el-button
              type="primary"
              size="small"
              :disabled="!row.exportable || row.isExported || isActive"
              :loading="exportingFolderId === row.folderId"
              @click="exportFolder(row)"
            >
              {{ exportActionLabel(row) }}
            </el-button>
          </template>
        </el-table-column>
      </el-table>
      <el-empty v-else :description="t('admin.exports.noFolders')" />
      <footer class="bottom-pager">
        <el-button :disabled="page <= 1" :icon="'ArrowLeft'" @click="changePage(page - 1)">
          {{ t('common.previousPage') }}
        </el-button>
        <span class="pager-status">
          {{ t('common.pageStatus', { page, pages: totalPages, total }) }}
          <small>{{ t('common.rangeStatus', { start: pageStart, end: pageEnd }) }}</small>
        </span>
        <el-button :disabled="page >= totalPages" @click="changePage(page + 1)">
          {{ t('common.nextPage') }}<el-icon class="el-icon--right"><ArrowRight /></el-icon>
        </el-button>
      </footer>
    </section>
  </AppShell>
</template>

<style scoped>
.page-title,
.action-panel {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
}
.page-title { margin-bottom: 20px; }
.page-title h1 { margin: 0 0 6px; font-size: 31px; }
.page-title p, .action-panel p { margin: 0; color: var(--el-text-color-secondary); }
.export-metrics { margin: 20px 0; }
.action-panel { padding: 22px 24px; margin-bottom: 20px; flex-wrap: wrap; }
.action-panel h2 { margin: 0 0 8px; }
.running-progress { flex-basis: 100%; color: var(--el-text-color-secondary); }
.running-progress .el-progress { margin-top: 8px; }
.actions { display: flex; gap: 10px; }
.table-panel { margin-bottom: 20px; overflow: hidden; }
.panel-heading { padding: 18px 22px; border-bottom: 1px solid var(--el-border-color-lighter); }
.panel-heading h2 { margin: 0; font-size: 21px; }
.folder-list-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.export-filter { width: 170px; }
.bottom-pager {
  margin-top: 0;
  padding: 16px 22px;
  border-top: 1px solid var(--el-border-color-lighter);
}
</style>
