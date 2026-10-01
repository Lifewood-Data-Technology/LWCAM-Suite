<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { ElMessage, ElMessageBox } from 'element-plus'
import AppShell from '@/components/AppShell.vue'
import { adminApi } from '@/api'
import type { NetworkLogin, PathSettingsVO, PathValidation, UpdateServerSettingsRequest } from '@/types'

const { t, te } = useI18n()

const loading = ref(false)
const validating = ref(false)
const saving = ref(false)
const settings = ref<PathSettingsVO>()
const validation = ref<PathValidation>()
const aiScannerStatus = computed(() => {
  const scanner = settings.value?.aiScanner
  if (!scanner?.available) {
    return { label: 'admin.settings.scannerUnavailable', type: 'info' as const }
  }
  if (scanner.enabled && scanner.running) {
    return { label: 'admin.settings.scannerRunning', type: 'success' as const }
  }
  return { label: 'admin.settings.scannerStopped', type: 'warning' as const }
})

const form = reactive<UpdateServerSettingsRequest>({
  qcImagesRoot: '',
  exportTempDir: '',
  exportOutputDir: '',
  exportZipOutput: true,
  exportTiffOutput: true,
  luminanceEnabled: false,
  exportAutoEnabled: true,
  aiReviewEnabled: false,
  aiPreanalysisEnabled: false,
  openrouterApiKey: '',
  openrouterExtractModel: '',
  openrouterCompareModel: '',
})

async function load() {
  loading.value = true
  try {
    const { data } = await adminApi.pathSettings()
    settings.value = data.data
    form.qcImagesRoot = data.data.qcImagesRoot.value
    form.exportTempDir = data.data.exportTempDir.value
    form.exportOutputDir = data.data.exportOutputDir.value
    form.exportTiffOutput = data.data.exportTiffOutput
    form.exportZipOutput = data.data.exportZipOutput
    form.luminanceEnabled = data.data.luminanceEnabled
    form.exportAutoEnabled = data.data.exportAutoEnabled
    form.aiReviewEnabled = data.data.ai.enabled
    form.aiPreanalysisEnabled = data.data.ai.preanalysisEnabled
    form.openrouterApiKey = ''
    form.openrouterExtractModel = data.data.ai.extractModel
    form.openrouterCompareModel = data.data.ai.compareModel
    validation.value = undefined
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

async function runValidation(): Promise<PathValidation | undefined> {
  // Validate the values being edited, including a root not saved yet.
  validating.value = true
  try {
    const { data } = await adminApi.validatePathSettings({
      qcImagesRoot: form.qcImagesRoot,
      // Keep Station Setup mappings in the probe when no image root overrides them.
      captureImageStoredPrefix: settings.value?.captureImageStoredPrefix.value || '',
      captureImageLocalRoot: settings.value?.captureImageLocalRoot.value || '',
      exportTempDir: form.exportTempDir,
      exportOutputDir: form.exportOutputDir,
    })
    validation.value = data.data
    return data.data
  } catch (error) {
    ElMessage.error((error as Error).message)
    return undefined
  } finally {
    validating.value = false
  }
}

function checkLabel(key: string) {
  const i18nKey = 'admin.settings.checkLabels.' + key
  return te(i18nKey) ? t(i18nKey) : key
}

async function confirmTiffOff() {
  try {
    await ElMessageBox.confirm(t('admin.settings.tiffWarning'), t('admin.settings.tiffWarningTitle'), {
      type: 'warning',
      confirmButtonText: t('admin.settings.tiffWarningConfirm'),
      cancelButtonText: t('common.cancel'),
    })
    return true
  } catch {
    return false
  }
}

// Confirm only when turning off the lossless output setting.
function beforeChangeTiff() {
  return form.exportTiffOutput ? confirmTiffOff() : Promise.resolve(true)
}

async function confirmAutoExportOff() {
  try {
    await ElMessageBox.confirm(
      t('admin.settings.exportAutoWarning'),
      t('admin.settings.exportAutoWarningTitle'),
      {
        type: 'warning',
        confirmButtonText: t('admin.settings.exportAutoWarningConfirm'),
        cancelButtonText: t('common.cancel'),
      },
    )
    return true
  } catch {
    return false
  }
}

// Turning this off leaves approved folders waiting for manual export.
function beforeChangeAutoExport() {
  return form.exportAutoEnabled ? confirmAutoExportOff() : Promise.resolve(true)
}

function validateAi() {
  if (form.aiReviewEnabled && !settings.value?.ai.keyConfigured && !form.openrouterApiKey.trim()) {
    ElMessage.error(t('admin.settings.aiApiKeyRequired'))
    return false
  }
  return true
}

async function save() {
  if (!validateAi()) return
  const result = await runValidation()
  if (!result) return
  if (!result.ok) {
    ElMessage.error(t('admin.settings.validationFailed'))
    return
  }
  if (result.totalFolders > 0 && result.resolvedFolders === 0) {
    try {
      await ElMessageBox.confirm(
        t('admin.settings.saveConfirmZero', { total: result.totalFolders }),
        t('admin.settings.save'),
        { type: 'warning' },
      )
    } catch {
      return
    }
  }
  saving.value = true
  try {
    const { data } = await adminApi.updateServerSettings(form)
    settings.value = data.data
    form.qcImagesRoot = data.data.qcImagesRoot.value
    form.exportTempDir = data.data.exportTempDir.value
    form.exportOutputDir = data.data.exportOutputDir.value
    form.exportTiffOutput = data.data.exportTiffOutput
    form.exportZipOutput = data.data.exportZipOutput
    form.luminanceEnabled = data.data.luminanceEnabled
    form.exportAutoEnabled = data.data.exportAutoEnabled
    form.aiReviewEnabled = data.data.ai.enabled
    form.aiPreanalysisEnabled = data.data.ai.preanalysisEnabled
    form.openrouterApiKey = ''
    form.openrouterExtractModel = data.data.ai.extractModel
    form.openrouterCompareModel = data.data.ai.compareModel
    ElMessage.success(t('admin.settings.saved'))
    loadNetLogins()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    saving.value = false
  }
}

// --- Network folder logins ------------------------------------------------
// One list per PC, shared with LWIP and Upload on the same PC; the backend
// (app/core/netlogin.py) says why. Passwords are sent, never shown.
const netLogins = ref<NetworkLogin[]>([])
const netChecked = ref(false)
const netChecking = ref(false)
const netSaving = ref(false)
const netForm = reactive({ host: '', username: '', password: '' })

// The saved list knows the SAVED folders; a network path typed above but not
// saved yet (Save refuses it until it validates) still needs its row, or
// there is nowhere to add the login that would let it validate.
const netRows = computed<NetworkLogin[]>(() => {
  const rows = [...netLogins.value]
  const known = new Set(rows.map((row) => row.host.toLowerCase()))
  for (const path of [form.qcImagesRoot, form.exportTempDir, form.exportOutputDir]) {
    const host = /^[\\/]{2}([^\\/?]+)/.exec((path || '').trim())?.[1]
    if (host && !known.has(host.toLowerCase())) {
      known.add(host.toLowerCase())
      rows.push({ host, username: '', saved: false, usedByThisService: true })
    }
  }
  return rows
})

async function loadNetLogins() {
  try {
    const { data } = await adminApi.networkLogins()
    netLogins.value = data.data.logins
    netChecked.value = false
  } catch (error) {
    ElMessage.error((error as Error).message)
    return
  }
  // The list is instant; the check signs in and tries each folder, so it follows.
  await checkNetLogins()
}

async function checkNetLogins() {
  netChecking.value = true
  try {
    const { data } = await adminApi.checkNetworkLogins()
    netLogins.value = data.data.logins
    netChecked.value = true
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    netChecking.value = false
  }
}

function editNetLogin(row: NetworkLogin) {
  netForm.host = row.host
  netForm.username = row.username
  netForm.password = ''
}

async function removeNetLogin(row: NetworkLogin) {
  try {
    await ElMessageBox.confirm(
      t('admin.settings.netLoginRemoveConfirm', { host: row.host }),
      t('admin.settings.netLoginRemove'),
      { type: 'warning', cancelButtonText: t('common.cancel') },
    )
  } catch {
    return
  }
  try {
    await adminApi.removeNetworkLogin(row.host)
  } catch (error) {
    ElMessage.error((error as Error).message)
  }
  await loadNetLogins()
}

async function saveNetLogin() {
  netSaving.value = true
  try {
    const { data } = await adminApi.saveNetworkLogin({ ...netForm })
    netForm.password = ''
    if (data.data.error) {
      ElMessage.warning(t('admin.settings.netLoginSavedButFailed', { error: data.data.error }))
    } else {
      ElMessage.success(t('admin.settings.netLoginSaved'))
    }
    await loadNetLogins()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    netSaving.value = false
  }
}

onMounted(() => {
  load()
  loadNetLogins()
})
</script>

<template>
  <AppShell>
    <div class="page-title">
      <div>
        <h1>{{ t('admin.settings.title') }}</h1>
        <p>{{ t('admin.settings.subtitle') }}</p>
      </div>
      <el-button :icon="'Refresh'" :loading="loading" @click="load">{{ t('common.refresh') }}</el-button>
    </div>

    <section class="panel" v-loading="loading">
      <div class="panel-heading"><h2>{{ t('admin.settings.editableSection') }}</h2></div>
      <div class="settings-form">
        <p class="muted settings-note">{{ t('admin.settings.pathsNetworkNote') }}</p>
        <div class="settings-field">
          <label>{{ t('admin.settings.qcImagesRoot') }}</label>
          <el-input v-model="form.qcImagesRoot" clearable :placeholder="t('admin.settings.qcImagesRootPlaceholder')" />
          <p class="muted settings-note">{{ t('admin.settings.qcImagesRootHelp') }}</p>
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.exportTempDir') }}</label>
          <el-input v-model="form.exportTempDir" clearable />
          <p class="muted settings-note">{{ t('admin.settings.exportTempDirHelp') }}</p>
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.exportOutputDir') }}</label>
          <el-input v-model="form.exportOutputDir" clearable />
          <p class="muted settings-note">{{ t('admin.settings.exportOutputDirHelp') }}</p>
        </div>

        <div class="actions">
          <el-button :loading="validating" @click="runValidation">{{ t('admin.settings.validate') }}</el-button>
        </div>

        <div v-if="validation" class="validation-result">
          <el-alert
            :type="validation.ok ? 'success' : 'error'"
            :title="validation.ok ? t('admin.settings.validationOk') : t('admin.settings.validationFailed')"
            :closable="false"
            show-icon
          />
          <ul class="check-list">
            <li v-for="check in validation.checks" :key="check.key">
              <strong>{{ checkLabel(check.key) }}</strong>
              <template v-if="check.key !== 'exportTempDirSeparate'">
                <span>{{ check.exists ? t('admin.settings.exists') : t('admin.settings.notExists') }}</span>
                <span v-if="check.path">{{ check.writable ? t('admin.settings.writable') : t('admin.settings.notWritable') }}</span>
              </template>
              <span v-if="check.message" class="check-message">{{ check.message }}</span>
            </li>
          </ul>
          <el-alert
            v-if="validation.totalFolders > 0 && validation.resolvedFolders === 0"
            type="warning"
            :title="t('admin.settings.resolvedFoldersZero', { total: validation.totalFolders })"
            :closable="false"
            show-icon
          />
          <p v-else-if="validation.totalFolders > 0">
            {{ t('admin.settings.resolvedFolders', { resolved: validation.resolvedFolders, total: validation.totalFolders }) }}
          </p>
          <p v-else class="muted">{{ t('admin.settings.resolvedFoldersNone') }}</p>
        </div>

        <div class="settings-field settings-field--switch">
          <label>{{ t('admin.settings.exportZipOutput') }}</label>
          <el-switch v-model="form.exportZipOutput" />
        </div>

        <div class="settings-field settings-field--switch">
          <label>{{ t('admin.settings.exportTiffOutput') }}</label>
          <el-switch v-model="form.exportTiffOutput" :before-change="beforeChangeTiff" />
        </div>

        <div class="settings-field settings-field--switch">
          <label>{{ t('admin.settings.luminanceEnabled') }}</label>
          <el-switch v-model="form.luminanceEnabled" />
        </div>

        <div class="settings-field settings-field--switch">
          <label>{{ t('admin.settings.exportAutoEnabled') }}</label>
          <el-switch v-model="form.exportAutoEnabled" :before-change="beforeChangeAutoExport" />
        </div>

        <div class="actions">
          <el-button type="primary" :loading="saving" @click="save">{{ t('admin.settings.save') }}</el-button>
        </div>
      </div>
    </section>

    <section class="panel" style="margin-top: 16px">
      <div class="panel-heading"><h2>{{ t('admin.settings.netLoginSection') }}</h2></div>
      <div class="settings-form">
        <p class="muted settings-note">{{ t('admin.settings.netLoginNote') }}</p>
        <p v-if="!netRows.length" class="muted settings-note">{{ t('admin.settings.netLoginNone') }}</p>
        <div v-for="row in netRows" :key="row.host" class="net-row">
          <div class="net-head">
            <strong>{{ row.host }}</strong>
            <span class="muted">
              {{ row.saved ? t('admin.settings.netLoginSignsInAs', { user: row.username }) : t('admin.settings.netLoginNotSaved') }}
            </span>
          </div>
          <template v-if="netChecked">
            <span v-if="row.saved" :class="row.loginError ? 'check-message' : 'net-ok'">
              {{ row.loginError || t('admin.settings.netLoginSignedIn') }}
            </span>
            <span v-for="folder in row.folders || []" :key="folder.path" :class="folder.error ? 'check-message' : 'muted'">
              <template v-if="folder.error">&#10007;</template><template v-else>&#10003;</template>
              {{ folder.path }}<template v-if="folder.error"> &mdash; {{ folder.error }}</template>
            </span>
          </template>
          <div class="actions">
            <el-button size="small" @click="editNetLogin(row)">
              {{ row.saved ? t('admin.settings.netLoginChange') : t('admin.settings.netLoginAdd') }}
            </el-button>
            <el-button v-if="row.saved" size="small" type="danger" plain @click="removeNetLogin(row)">
              {{ t('admin.settings.netLoginRemove') }}
            </el-button>
          </div>
        </div>
        <div class="actions">
          <el-button :loading="netChecking" @click="checkNetLogins">{{ t('admin.settings.netLoginTest') }}</el-button>
        </div>

        <h3 class="net-form-title">{{ t('admin.settings.netLoginFormTitle') }}</h3>
        <div class="settings-field">
          <label>{{ t('admin.settings.netLoginHost') }}</label>
          <el-input v-model="netForm.host" placeholder="FILE-PC" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.netLoginUser') }}</label>
          <el-input v-model="netForm.username" placeholder="FILE-PC\lwcam-share" autocomplete="off" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.netLoginPassword') }}</label>
          <el-input
            v-model="netForm.password"
            type="password"
            show-password
            autocomplete="new-password"
            :placeholder="t('admin.settings.netLoginPasswordPlaceholder')"
          />
        </div>
        <div class="actions">
          <el-button type="primary" :loading="netSaving" @click="saveNetLogin">{{ t('admin.settings.netLoginSave') }}</el-button>
        </div>
      </div>
    </section>

    <section class="panel" style="margin-top: 16px" v-loading="loading">
      <div class="panel-heading"><h2>{{ t('admin.settings.aiSection') }}</h2></div>
      <div class="settings-form">
        <div class="settings-field settings-field--switch">
          <label>{{ t('admin.settings.aiReviewEnabled') }}</label>
          <el-switch v-model="form.aiReviewEnabled" />
        </div>
        <div v-if="settings" class="settings-field settings-field--switch">
          <label>{{ t('admin.settings.aiScannerStatus') }}</label>
          <el-tag :type="aiScannerStatus.type">{{ t(aiScannerStatus.label) }}</el-tag>
        </div>
        <div class="settings-field settings-field--switch">
          <label>{{ t('admin.settings.aiPreanalysisEnabled') }}</label>
          <el-switch v-model="form.aiPreanalysisEnabled" :disabled="!form.aiReviewEnabled" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.aiApiKey') }}</label>
          <el-input
            v-model="form.openrouterApiKey"
            type="password"
            show-password
            :placeholder="t('admin.settings.savedSecretPlaceholder')"
          />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.aiExtractModel') }}</label>
          <el-input v-model="form.openrouterExtractModel" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.aiCompareModel') }}</label>
          <el-input v-model="form.openrouterCompareModel" />
        </div>
        <p v-if="settings" class="muted settings-note">{{ t('admin.settings.configuredBy', { target: settings.configuredBy }) }}</p>
      </div>
    </section>
  </AppShell>
</template>

<style scoped>
.settings-form {
  padding: 28px 32px;
  display: flex;
  flex-direction: column;
  gap: 22px;
  /* Wide enough for a real Windows path without truncating it, which is the
     whole content of this form. The old 640px cap left two short fields
     stranded in a card several times their width - the reading line here is a
     file path, not prose, so the usual ~70ch measure does not apply. */
  max-width: 1100px;
}
.settings-field {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

/* A file path is the content of this form, not a caption about it - it should
   be as readable as the label above it. Monospace so a stray space or a
   doubled separator is visible. */
.settings-field :deep(.el-input__inner) {
  font-size: 18px;
  font-family: 'Cascadia Mono', Consolas, 'Courier New', monospace;
}
.settings-field--switch {
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
}
.settings-field label {
  font-weight: 600;
  color: var(--el-text-color-primary);
}
.settings-note {
  margin: 0;
  font-size: 16px;
}
.validation-result {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.check-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.check-list li {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  align-items: baseline;
  font-size: 16px;
}
.check-message {
  color: var(--el-color-danger);
}
.actions {
  display: flex;
  gap: 10px;
}
.net-row {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding-top: 12px;
  border-top: 1px solid var(--el-border-color-lighter);
  font-size: 16px;
  overflow-wrap: anywhere;
}
.net-head {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  align-items: baseline;
}
.net-ok {
  color: var(--el-color-success);
}
.net-form-title {
  margin: 8px 0 0;
  font-size: 16px;
}
</style>
