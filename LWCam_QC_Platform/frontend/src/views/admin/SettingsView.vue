<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { ElMessage, ElMessageBox } from 'element-plus'
import AppShell from '@/components/AppShell.vue'
import { adminApi } from '@/api'
import type { PathSettingsVO, PathValidation, UpdateServerSettingsRequest } from '@/types'

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
  uploadEnabled: false,
  uploadS3Path: '',
  uploadS3Region: '',
  uploadS3AccessKey: '',
  uploadS3SecretKey: '',
  uploadDoneRoot: '',
  uploadSummaryRoot: '',
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
    form.uploadEnabled = data.data.upload.enabled
    form.uploadS3Path = data.data.upload.s3Path
    form.uploadS3Region = data.data.upload.region
    form.uploadS3AccessKey = data.data.upload.accessKey
    form.uploadS3SecretKey = ''
    form.uploadDoneRoot = data.data.upload.doneRoot
    form.uploadSummaryRoot = data.data.upload.summaryRoot
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

async function confirmUploadOff() {
  try {
    await ElMessageBox.confirm(
      t('admin.settings.uploadOffWarning'),
      t('admin.settings.uploadOffWarningTitle'),
      {
        type: 'warning',
        confirmButtonText: t('admin.settings.uploadOffWarningConfirm'),
        cancelButtonText: t('common.cancel'),
      },
    )
    return true
  } catch {
    return false
  }
}

function beforeChangeUpload() {
  return form.uploadEnabled ? confirmUploadOff() : Promise.resolve(true)
}

function validateUploadAndAi() {
  if (form.uploadEnabled) {
    const path = form.uploadS3Path.trim()
    const bucket = path.toLowerCase().startsWith('s3://') ? path.slice(5).split('/')[0] : ''
    if (!bucket) {
      ElMessage.error(t('admin.settings.uploadS3PathInvalid'))
      return false
    }
    if (!form.uploadS3Region.trim()) {
      ElMessage.error(t('admin.settings.uploadRegionRequired'))
      return false
    }
    if (!form.uploadS3AccessKey.trim()) {
      ElMessage.error(t('admin.settings.uploadAccessKeyRequired'))
      return false
    }
    if (!settings.value?.upload.secretKeyConfigured && !form.uploadS3SecretKey.trim()) {
      ElMessage.error(t('admin.settings.uploadSecretKeyRequired'))
      return false
    }
    if (!form.uploadDoneRoot.trim()) {
      ElMessage.error(t('admin.settings.uploadDoneRootRequired'))
      return false
    }
    if (!form.uploadSummaryRoot.trim()) {
      ElMessage.error(t('admin.settings.uploadSummaryRootRequired'))
      return false
    }
  }
  if (form.aiReviewEnabled && !settings.value?.ai.keyConfigured && !form.openrouterApiKey.trim()) {
    ElMessage.error(t('admin.settings.aiApiKeyRequired'))
    return false
  }
  return true
}

async function save() {
  if (!validateUploadAndAi()) return
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
    form.uploadEnabled = data.data.upload.enabled
    form.uploadS3Path = data.data.upload.s3Path
    form.uploadS3Region = data.data.upload.region
    form.uploadS3AccessKey = data.data.upload.accessKey
    form.uploadS3SecretKey = ''
    form.uploadDoneRoot = data.data.upload.doneRoot
    form.uploadSummaryRoot = data.data.upload.summaryRoot
    form.aiReviewEnabled = data.data.ai.enabled
    form.aiPreanalysisEnabled = data.data.ai.preanalysisEnabled
    form.openrouterApiKey = ''
    form.openrouterExtractModel = data.data.ai.extractModel
    form.openrouterCompareModel = data.data.ai.compareModel
    ElMessage.success(t('admin.settings.saved'))
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    saving.value = false
  }
}

onMounted(load)
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
        <div class="settings-field">
          <label>{{ t('admin.settings.qcImagesRoot') }}</label>
          <el-input v-model="form.qcImagesRoot" clearable :placeholder="t('admin.settings.qcImagesRootPlaceholder')" />
          <p class="muted settings-note">{{ t('admin.settings.qcImagesRootHelp') }}</p>
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.exportTempDir') }}</label>
          <el-input v-model="form.exportTempDir" clearable />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.exportOutputDir') }}</label>
          <el-input v-model="form.exportOutputDir" clearable />
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
              <span>{{ check.exists ? t('admin.settings.exists') : t('admin.settings.notExists') }}</span>
              <span v-if="check.path">{{ check.writable ? t('admin.settings.writable') : t('admin.settings.notWritable') }}</span>
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
        <p class="muted">{{ t('admin.settings.exportAutoEnabledHelp') }}</p>

        <div class="actions">
          <el-button type="primary" :loading="saving" @click="save">{{ t('admin.settings.save') }}</el-button>
        </div>
        <p class="muted settings-note">{{ t('admin.settings.noRestartNeeded') }}</p>
      </div>
    </section>

    <section class="panel" style="margin-top: 16px" v-loading="loading">
      <div class="panel-heading"><h2>{{ t('admin.settings.uploadSection') }}</h2></div>
      <div class="settings-form">
        <div class="settings-field settings-field--switch">
          <label>{{ t('admin.settings.uploadEnabled') }}</label>
          <el-switch v-model="form.uploadEnabled" :before-change="beforeChangeUpload" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.uploadS3Path') }}</label>
          <el-input v-model="form.uploadS3Path" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.uploadS3Region') }}</label>
          <el-input v-model="form.uploadS3Region" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.uploadS3AccessKey') }}</label>
          <el-input v-model="form.uploadS3AccessKey" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.uploadS3SecretKey') }}</label>
          <el-input
            v-model="form.uploadS3SecretKey"
            type="password"
            show-password
            :placeholder="t('admin.settings.savedSecretPlaceholder')"
          />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.uploadDoneRoot') }}</label>
          <el-input v-model="form.uploadDoneRoot" />
        </div>
        <div class="settings-field">
          <label>{{ t('admin.settings.uploadSummaryRoot') }}</label>
          <el-input v-model="form.uploadSummaryRoot" />
        </div>
        <p class="muted settings-note">{{ t('admin.settings.configuredBy', { target: settings?.configuredBy || '' }) }}</p>
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
</style>
