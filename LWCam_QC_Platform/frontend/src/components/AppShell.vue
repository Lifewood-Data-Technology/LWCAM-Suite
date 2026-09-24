<script setup lang="ts">
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { translateValue } from '@/i18n'
import { useAuthStore } from '@/stores/auth'
import logo from '@/assets/lifewood-logo.jpg'

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()
const { t } = useI18n()

const navItems = computed(() => {
  // Same expression the router guard uses (router/index.ts) — a user can hold both
  // qc and admin, and role is only the display/default role, so nav must be built
  // from the full roles[] or a held role's console silently becomes unreachable.
  const held = auth.user?.roles?.length ? auth.user.roles : [auth.user?.role]
  const items: Array<{ to: string; icon: string; label: string }> = []
  if (held.includes('qc')) {
    items.push(
      { to: '/qc/tasks', icon: 'Download', label: t('qc.pending') },
      { to: '/qc/my-tasks', icon: 'Finished', label: t('qc.mine') },
      { to: '/qc/completed', icon: 'CircleCheck', label: t('qc.completed') },
    )
  }
  if (held.includes('admin') || held.includes('super_admin')) {
    items.push(
      { to: '/admin/stats', icon: 'DataAnalysis', label: t('nav.stats') },
      { to: '/admin/qc-tasks', icon: 'Unlock', label: t('nav.qcTasks') },
      { to: '/admin/exports', icon: 'UploadFilled', label: t('nav.exports') },
      { to: '/admin/settings', icon: 'Setting', label: t('nav.settings') },
    )
  }
  return items
})

const immersiveQc = computed(() => route.name === 'qc-my-tasks' || route.name === 'qc-review')

// The QC workspaces are full-bleed panels that manage their own internal
// padding; the shell's own gutter just framed them in a differently-coloured
// border. The Available queue is an ordinary card page and keeps its gutter.
const flushContent = computed(() =>
  ['qc-my-tasks', 'qc-review', 'qc-completed'].includes(String(route.name)),
)

function logout() {
  auth.clear()
  router.push('/login')
}
</script>

<template>
  <div class="shell" :class="{ 'shell--immersive': immersiveQc }">
    <aside v-if="!immersiveQc" class="sidebar">
      <div class="brand-mini">
        <img :src="logo" alt="lifewood" />
      </div>
      <nav class="nav-list">
        <RouterLink v-for="item in navItems" :key="item.to" :to="item.to" class="nav-item">
          <el-icon><component :is="item.icon" /></el-icon>
          <span>{{ item.label }}</span>
        </RouterLink>
      </nav>
    </aside>

    <main class="main">
      <header v-if="!immersiveQc" class="topbar">
        <div>
          <strong>{{ auth.user?.userId }}</strong>
          <span class="muted"> / {{ translateValue('roles', auth.user?.role) }}</span>
          <span v-if="auth.user?.mustChangePassword" class="muted"> · {{ t('auth.passwordChangeHint') }}</span>
        </div>
        <div class="topbar-actions">
          <el-button class="topbar-action-button" :icon="'SwitchButton'" @click="logout">{{ t('common.logout') }}</el-button>
        </div>
      </header>
      <section class="content" :class="{ 'content--flush': flushContent }">
        <slot />
      </section>
    </main>
  </div>
</template>
