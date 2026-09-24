<script setup lang="ts">
import { reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { ElMessage } from 'element-plus'
import { authApi } from '@/api'
import { useAuthStore } from '@/stores/auth'
import logo from '@/assets/lwcam-logo.png'

const router = useRouter()
const route = useRoute()
const auth = useAuthStore()
const { t } = useI18n()
const loading = ref(false)
const form = reactive({ username: '', password: '' })

async function submit() {
  loading.value = true
  try {
    const { data } = await authApi.login(form)
    auth.setAuth(data.data.token, data.data.user)
    if (data.data.user.mustChangePassword) {
      router.push('/change-password')
      return
    }
    router.push((route.query.redirect as string) || data.data.user.homePath || '/admin/stats')
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <!--
    Deliberately the LWCAM desktop login, not a web-style split hero: the same
    operators sign in to both, and a different-looking door to the same account
    reads as a different system. Card, saffron rule, logo, two fields, one
    full-width button - the order and proportions come from
    LWCAM/lib/pages/login_page.dart.
  -->
  <div class="auth-page">
    <el-form class="auth-form" :model="form" label-position="top" @keyup.enter="submit">
      <!-- The brand sheet's accent rule. 56x5 with a 3px radius, as in Flutter. -->
      <span class="auth-accent" aria-hidden="true" />
      <img class="auth-logo" :src="logo" :alt="t('common.logoAlt')" />
      <el-form-item :label="t('auth.username')">
        <el-input v-model="form.username" size="large" autocomplete="username" />
      </el-form-item>
      <el-form-item :label="t('auth.password')">
        <el-input v-model="form.password" type="password" size="large" show-password autocomplete="current-password" />
      </el-form-item>
      <el-button type="primary" size="large" :loading="loading" class="auth-submit" @click="submit">
        {{ t('auth.login') }}
      </el-button>
      <p class="hint">{{ t('auth.accountManagedByAdmin') }}</p>
    </el-form>
  </div>
</template>
