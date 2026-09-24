<script setup lang="ts">
import { reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { ElMessage } from 'element-plus'
import { authApi } from '@/api'
import { useAuthStore } from '@/stores/auth'
import logo from '@/assets/lwcam-logo.png'

const router = useRouter()
const auth = useAuthStore()
const { t } = useI18n()
const loading = ref(false)
const form = reactive({ oldPassword: '', newPassword: '', confirmPassword: '' })

function logout() {
  auth.clear()
  router.push('/login')
}

async function submit() {
  if (form.newPassword !== form.confirmPassword) {
    ElMessage.error(t('auth.passwordMismatch'))
    return
  }
  loading.value = true
  try {
    const { data } = await authApi.changePassword(form.oldPassword, form.newPassword)
    auth.setUser(data.data)
    ElMessage.success(t('auth.passwordChanged'))
    router.push(data.data.homePath || '/admin/stats')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <!-- Same card as the login it follows: this is still the front door, and a
       forced password change that looks like a different app is alarming at
       exactly the moment the operator is least sure what is happening. -->
  <div class="auth-page">
    <el-form class="auth-form" :model="form" label-position="top" @keyup.enter="submit">
      <span class="auth-accent" aria-hidden="true" />
      <img class="auth-logo" :src="logo" :alt="t('common.logoAlt')" />
      <h2>{{ t('auth.changePassword') }}</h2>
      <p class="hint hint--lead">{{ t('auth.changePasswordHint') }}</p>
      <el-form-item :label="t('auth.oldPassword')">
        <el-input v-model="form.oldPassword" type="password" size="large" show-password autocomplete="current-password" />
      </el-form-item>
      <el-form-item :label="t('auth.newPassword')">
        <el-input v-model="form.newPassword" type="password" size="large" show-password autocomplete="new-password" />
      </el-form-item>
      <el-form-item :label="t('auth.confirmPassword')">
        <el-input v-model="form.confirmPassword" type="password" size="large" show-password autocomplete="new-password" />
      </el-form-item>
      <el-button type="primary" size="large" :loading="loading" class="auth-submit" @click="submit">
        {{ t('auth.changePassword') }}
      </el-button>
      <el-button size="large" class="auth-submit auth-submit--secondary" @click="logout">
        {{ t('common.logout') }}
      </el-button>
    </el-form>
  </div>
</template>
