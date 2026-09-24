<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { ElMessage, ElMessageBox } from 'element-plus'
import AppShell from '@/components/AppShell.vue'
import { adminApi } from '@/api'
import { useAdaptivePageSize } from '@/composables/useAdaptivePageSize'
import { formatTimestamp } from '@/utils/date'
import type { AdminQcTask, ProjectOption } from '@/types'

const { t } = useI18n()
const { pageSize } = useAdaptivePageSize({ rowHeight: 52, headerHeight: 235, footerHeight: 76, safePadding: 48, minRows: 6 })
const loading = ref(false)
const tasks = ref<AdminQcTask[]>([])
const projects = ref<ProjectOption[]>([])
const total = ref(0)
const releasingFolders = ref(new Set<number>())
const clock = ref(Date.now())
const query = reactive({
  page: 1,
  size: pageSize.value,
  keyword: '',
  projectId: undefined as number | undefined,
})
let clockTimer: number | undefined

const totalPages = computed(() => Math.max(1, Math.ceil(total.value / query.size)))
const pageStart = computed(() => (total.value ? (query.page - 1) * query.size + 1 : 0))
const pageEnd = computed(() => Math.min(total.value, query.page * query.size))

async function load() {
  loading.value = true
  try {
    query.size = pageSize.value
    const { data } = await adminApi.qcTasks({
      page: query.page,
      size: query.size,
      keyword: query.keyword || undefined,
      projectId: query.projectId,
    })
    tasks.value = data.data.records
    total.value = data.data.total
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

async function loadProjects() {
  const { data } = await adminApi.projectOptions()
  projects.value = data.data
}

function search() {
  query.page = 1
  void load()
}

function changePage(nextPage: number) {
  if (nextPage < 1 || nextPage > totalPages.value || nextPage === query.page) return
  query.page = nextPage
  void load()
}

function formatDuration(value?: string) {
  if (!value) return '—'
  const startedAt = new Date(value).getTime()
  if (Number.isNaN(startedAt)) return '—'
  const totalMinutes = Math.max(0, Math.floor((clock.value - startedAt) / 60000))
  const days = Math.floor(totalMinutes / 1440)
  const hours = Math.floor((totalMinutes % 1440) / 60)
  const minutes = totalMinutes % 60
  if (days) return t('admin.qcTasks.durationDays', { days, hours })
  if (hours) return t('admin.qcTasks.durationHours', { hours, minutes })
  return t('admin.qcTasks.durationMinutes', { minutes })
}

async function releaseTask(task: AdminQcTask) {
  try {
    await ElMessageBox.confirm(
      t('admin.qcTasks.releaseConfirm', { folder: task.folderName, reviewer: task.reviewerUserId }),
      t('admin.qcTasks.releaseTitle'),
      { type: 'warning' },
    )
  } catch {
    return
  }

  releasingFolders.value = new Set(releasingFolders.value).add(task.folderId)
  try {
    await adminApi.releaseQcTask(task.folderId)
    ElMessage.success(t('admin.qcTasks.releaseDone'))
    await load()
  } catch (error) {
    ElMessage.error((error as Error).message)
    await load()
  } finally {
    const next = new Set(releasingFolders.value)
    next.delete(task.folderId)
    releasingFolders.value = next
  }
}

watch(pageSize, (value, oldValue) => {
  if (!oldValue || value === oldValue) return
  query.size = value
  query.page = 1
  void load()
})

onMounted(async () => {
  clockTimer = window.setInterval(() => { clock.value = Date.now() }, 60_000)
  try {
    await Promise.all([load(), loadProjects()])
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
})

onBeforeUnmount(() => {
  if (clockTimer !== undefined) window.clearInterval(clockTimer)
})
</script>

<template>
  <AppShell>
    <div class="page-title">
      <div>
        <h1>{{ t('admin.qcTasks.title') }}</h1>
        <p>{{ t('admin.qcTasks.subtitle') }}</p>
      </div>
      <el-button :icon="'Refresh'" :loading="loading" @click="load">{{ t('common.refresh') }}</el-button>
    </div>

    <div class="toolbar">
      <el-input
        v-model="query.keyword"
        :placeholder="t('admin.qcTasks.keyword')"
        clearable
        style="width: 280px"
        @keyup.enter="search"
        @clear="search"
      />
      <el-select
        v-model="query.projectId"
        :placeholder="t('admin.qcTasks.project')"
        clearable
        filterable
        style="width: 240px"
        @change="search"
      >
        <el-option
          v-for="project in projects"
          :key="project.id"
          :value="project.id"
          :label="`${project.projectName} (${project.projectId})`"
        />
      </el-select>
      <el-button :icon="'Search'" @click="search">{{ t('common.search') }}</el-button>
    </div>

    <section class="panel table-panel">
      <div class="qc-task-summary">
        <div>
          <span>{{ t('admin.qcTasks.reviewingTotal') }}</span>
          <strong>{{ total }}</strong>
        </div>
        <p>{{ t('admin.qcTasks.releaseHint') }}</p>
      </div>
      <el-table
        v-loading="loading"
        class="qc-task-table"
        :data="tasks"
        row-key="folderId"
        :height="pageSize * 52 + 52"
      >
        <el-table-column prop="projectName" :label="t('admin.qcTasks.project')" min-width="64">
          <template #default="{ row }">{{ row.projectName || row.projectCode || '—' }}</template>
        </el-table-column>
        <el-table-column prop="boxName" :label="t('admin.qcTasks.box')" min-width="54" />
        <el-table-column prop="folderName" :label="t('admin.qcTasks.folder')" min-width="64" />
        <el-table-column prop="imageCount" :label="t('admin.qcTasks.images')" min-width="44" align="center" />
        <el-table-column prop="reviewerUserId" :label="t('admin.qcTasks.reviewer')" min-width="64" />
        <el-table-column :label="t('admin.qcTasks.claimedAt')" min-width="96">
          <template #default="{ row }">{{ formatTimestamp(row.claimedAt) }}</template>
        </el-table-column>
        <el-table-column :label="t('admin.qcTasks.duration')" min-width="60">
          <template #default="{ row }"><span class="duration-pill">{{ formatDuration(row.claimedAt) }}</span></template>
        </el-table-column>
        <el-table-column :label="t('common.actions')" min-width="52">
          <template #default="{ row }">
            <el-button
              link
              type="danger"
              :loading="releasingFolders.has(row.folderId)"
              @click="releaseTask(row)"
            >
              {{ t('admin.qcTasks.release') }}
            </el-button>
          </template>
        </el-table-column>
      </el-table>
      <footer class="bottom-pager">
        <el-button :disabled="query.page <= 1" :icon="'ArrowLeft'" @click="changePage(query.page - 1)">{{ t('common.previousPage') }}</el-button>
        <span class="pager-status">
          {{ t('common.pageStatus', { page: query.page, pages: totalPages, total }) }}
          <small>{{ t('common.rangeStatus', { start: pageStart, end: pageEnd }) }}</small>
        </span>
        <el-button :disabled="query.page >= totalPages" @click="changePage(query.page + 1)">
          {{ t('common.nextPage') }}<el-icon class="el-icon--right"><ArrowRight /></el-icon>
        </el-button>
      </footer>
    </section>
  </AppShell>
</template>

<style scoped>
.qc-task-summary {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 32px;
  padding: 24px 28px;
  border-bottom: 2px solid var(--el-border-color-lighter);
  background: linear-gradient(135deg, rgba(4, 98, 65, 0.02) 0%, rgba(255, 255, 255, 0.8) 100%);
}

.qc-task-summary div {
  display: flex;
  align-items: baseline;
  gap: 16px;
}

.qc-task-summary span {
  font-size: 17px;
  font-weight: 500;
  color: var(--el-text-color-secondary);
}

.qc-task-summary strong {
  color: var(--el-color-primary);
  font-size: 39px;
  font-weight: 700;
  text-shadow: 0 2px 4px rgba(4, 98, 65, 0.1);
}

.qc-task-summary p {
  margin: 0;
  color: var(--el-text-color-secondary);
  font-size: 16px;
  line-height: 1.5;
  max-width: 400px;
}

.qc-task-table {
  border-radius: 0 0 12px 12px;
  overflow: hidden;
}

.qc-task-table :deep(.el-table__header) {
  background: linear-gradient(180deg, #f8fffe 0%, #f0f4f3 100%);
}

.qc-task-table :deep(.el-table__header th) {
  font-weight: 600;
  font-size: 16px;
  color: var(--el-text-color-primary);
  border-bottom: 2px solid var(--el-border-color-light);
}

.qc-task-table :deep(.el-table__row) {
  transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
}

.qc-task-table :deep(.el-table__row:hover) {
  background: var(--el-color-primary-light-9);
  transform: scale(1.001);
}

.qc-task-table :deep(.cell) {
  padding-inline: 10px;
  white-space: normal;
  overflow-wrap: anywhere;
  line-height: 1.4;
  font-size: 16px;
}

.duration-pill {
  display: inline-flex;
  align-items: center;
  padding: 5px 12px;
  border-radius: 20px;
  background: linear-gradient(135deg, var(--el-color-warning-light-9) 0%, var(--el-color-warning-light-8) 100%);
  color: var(--el-color-warning-dark-2);
  font-size: 15px;
  font-weight: 600;
  border: 1px solid var(--el-color-warning-light-7);
  box-shadow: 0 1px 3px rgba(230, 162, 60, 0.1);
}

.table-panel {
  border-radius: 12px;
  overflow: hidden;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.04), 0 1px 3px rgba(0, 0, 0, 0.02);
}

.bottom-pager {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 16px 24px;
  border-top: 1px solid var(--el-border-color-lighter);
  background: linear-gradient(180deg, #ffffff 0%, #fafcfb 100%);
}

.pager-status {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  font-size: 17px;
  font-weight: 500;
  color: var(--el-text-color-primary);
}

.pager-status small {
  font-size: 15px;
  font-weight: 400;
  color: var(--el-text-color-secondary);
}

.page-title {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 24px;
  margin-bottom: 24px;
}

.page-title h1 {
  font-size: 31px;
  font-weight: 700;
  margin-bottom: 6px;
}

.page-title p {
  color: var(--el-text-color-secondary);
  font-size: 17px;
  margin: 0;
}

.toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  margin-bottom: 20px;
}

.toolbar :deep(.el-input__wrapper),
.toolbar :deep(.el-select .el-input__wrapper) {
  border-radius: 10px;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06);
  transition: all 0.2s ease;
}

.toolbar :deep(.el-input__wrapper:hover),
.toolbar :deep(.el-select .el-input__wrapper:hover) {
  box-shadow: 0 2px 6px rgba(4, 98, 65, 0.1);
}

.toolbar :deep(.el-button) {
  border-radius: 10px;
  font-weight: 500;
}

@media (max-width: 768px) {
  .qc-task-summary {
    flex-direction: column;
    align-items: flex-start;
    gap: 16px;
  }

  .qc-task-summary p {
    max-width: none;
  }

  .page-title {
    flex-direction: column;
  }

  .toolbar {
    flex-direction: column;
    align-items: stretch;
  }

  .toolbar :deep(.el-input),
  .toolbar :deep(.el-select) {
    width: 100% !important;
  }
}
</style>
