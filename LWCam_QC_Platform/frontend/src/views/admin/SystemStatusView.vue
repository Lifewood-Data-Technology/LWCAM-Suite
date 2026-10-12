<!-- Admin "System status" page of the QC Platform web console: health of every part of the suite. -->
<!-- Each capture PC, LWIP, QC and Upload service reports a heartbeat to the database; this page lists them (state, version, last error, backlog). -->
<!-- Polled every 30 s through useSystemStatus; the same data feeds the red banner in AppShell. "Forget this PC" removes a stale row. -->
<!-- The backlog sentences below are plain English on purpose (operator diagnostics, not translated). -->
<script setup lang="ts">
import { ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi } from '@/api'
import AppShell from '@/components/AppShell.vue'
import { useSystemStatus } from '@/composables/useSystemStatus'
import { formatTimestamp } from '@/utils/date'
import type { ServiceHeartbeat } from '@/types'

const { t } = useI18n()
const showAll = ref(false)
const { status, loading, refresh } = useSystemStatus(30_000, true, () => showAll.value)

async function forget(row: ServiceHeartbeat) {
  if (!row.host) return
  try {
    await ElMessageBox.confirm(t('admin.status.forgetConfirm', { part: row.part, pc: row.host }), t('admin.status.title'), { type: 'warning' })
  } catch {
    return
  }
  await adminApi.forgetPc(row.part, row.host)
  ElMessage.success(t('admin.status.forgotten'))
  await refresh()
}

function tagType(state: string) {
  return state === 'red' ? 'danger' : state === 'grey' ? 'info' : 'success'
}

// ponytail: plain English here, not i18n - these are operator diagnostics, add to the locale files if translated.
const sentences: Record<string, (v: number, b: Record<string, unknown>) => string | null> = {
  approved_not_exported: (v, b) => (v > 0 ? `${v} folders approved but not exported for ${b.oldest_approved_minutes ?? '?'} min` : null),
  oldest_approved_minutes: () => null,
  exports_busy: (v) => (v > 0 ? `${v} folders skipped: another export holds their lock` : null),
  input_unreachable: (v) => (v ? 'input folder unreachable' : null),
  unreported: (v, b) => (v > 0 ? `${v} finished folders not yet in the database (oldest ${b.oldest_unreported_minutes ?? '?'} min)` : null),
  oldest_unreported_minutes: () => null,
  db_pending: (v) => (v > 0 ? `${v} uploaded folders not yet written back to the database` : null),
  last_scan_minutes_ago: (v) => `last scan ${v} min ago`,
  scan_interval_minutes: () => null,
  transfers_waiting: (v, b) => (v > 0 ? `${v} transfers waiting for the LWIP share (oldest ${b.oldest_transfer_wait_minutes ?? '?'} min)` : null),
  oldest_transfer_wait_minutes: () => null,
}

function backlog(row: ServiceHeartbeat) {
  const data = row.backlog || {}
  const parts = Object.entries(data)
    .map(([key, value]) => (sentences[key] ? sentences[key](Number(value), data) : `${key}: ${value}`))
    .filter((part): part is string => !!part)
  return parts.length ? parts.join(', ') : '-'
}
</script>

<template>
  <AppShell>
    <div class="page-title">
      <div>
        <h1>{{ t('admin.status.title') }}</h1>
        <p v-if="status">
          {{ t('admin.status.versionLine', { version: status.serverVersion, level: status.databaseSchemaLevel ?? '?', required: status.requiredSchemaLevel }) }}
        </p>
      </div>
      <div>
        <el-checkbox v-model="showAll" @change="refresh">{{ t('admin.status.showAll') }}</el-checkbox>
        <el-button :icon="'Refresh'" :loading="loading" @click="refresh">{{ t('common.refresh') }}</el-button>
      </div>
    </div>

    <el-alert
      v-if="status && status.databaseSchemaLevel !== null && status.databaseSchemaLevel < status.requiredSchemaLevel"
      type="error"
      :title="t('admin.status.schemaOld', { level: status.databaseSchemaLevel, required: status.requiredSchemaLevel })"
      show-icon
      :closable="false"
    />
    <el-alert
      v-if="status && status.uploadFailedFolders"
      type="warning"
      :title="t('admin.status.uploadFailed', { count: status.uploadFailedFolders })"
      show-icon
      :closable="false"
    />

    <section class="panel table-panel">
      <el-table v-loading="loading && !status" :data="status?.services || []">
        <el-table-column :label="t('admin.status.state')" width="110">
          <template #default="{ row }">
            <el-tag :type="tagType(row.state)">
              {{ row.neverReported ? t('admin.status.neverReported') : t(`admin.status.${row.state}`) }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="part" :label="t('admin.status.part')" min-width="120" />
        <el-table-column prop="host" :label="t('admin.status.pc')" min-width="150" show-overflow-tooltip />
        <el-table-column prop="version" :label="t('admin.status.version')" min-width="130" show-overflow-tooltip />
        <el-table-column :label="t('admin.status.lastSeen')" min-width="170">
          <template #default="{ row }">
            <span v-if="row.state === 'grey'">{{ t('admin.status.offlineSince', { time: formatTimestamp(row.last_seen) }) }}</span>
            <span v-else-if="row.last_seen">{{ formatTimestamp(row.last_seen) }}</span>
          </template>
        </el-table-column>
        <el-table-column :label="t('admin.status.lastOk')" min-width="170">
          <template #default="{ row }">{{ formatTimestamp(row.last_ok) }}</template>
        </el-table-column>
        <el-table-column :label="t('admin.status.lastError')" min-width="260" show-overflow-tooltip>
          <template #default="{ row }">
            <span v-if="row.last_error">{{ formatTimestamp(row.last_error_at) }} · {{ row.last_error }}</span>
          </template>
        </el-table-column>
        <el-table-column :label="t('admin.status.backlog')" min-width="240" show-overflow-tooltip>
          <template #default="{ row }">{{ backlog(row) }}</template>
        </el-table-column>
        <el-table-column width="150">
          <template #default="{ row }">
            <el-button v-if="row.host" size="small" text type="danger" @click="forget(row)">{{ t('admin.status.forget') }}</el-button>
          </template>
        </el-table-column>
      </el-table>
      <el-empty v-if="status && !status.services.length" :description="t('admin.status.empty')" />
    </section>
  </AppShell>
</template>

<style scoped>
.page-title { display: flex; align-items: center; justify-content: space-between; gap: 24px; margin-bottom: 20px; }
.page-title h1 { margin: 0 0 6px; font-size: 31px; }
.page-title p { margin: 0; color: var(--el-text-color-secondary); }
.table-panel { margin-top: 16px; overflow: hidden; }
</style>
