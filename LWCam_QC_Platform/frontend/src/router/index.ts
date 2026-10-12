// Route table and navigation guard for the QC Platform web console.
// Admin pages live under /admin/*, reviewer pages under /qc/*; all four /qc/* routes
// render the same QcIndexView, which reads the route name to pick its mode.
// meta.requiresAuth / meta.roles / meta.guest drive the guard in router.beforeEach:
// it sends logged-out users to /login, forces a password change when required,
// and bounces users without a matching role to their own home page.
// router.onError at the bottom reloads the page after a redeploy invalidates old chunks.
import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', redirect: '/login' },
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue'), meta: { guest: true } },
    {
      path: '/change-password',
      name: 'change-password',
      component: () => import('@/views/ChangePasswordView.vue'),
      meta: { requiresAuth: true },
    },
    { path: '/admin', redirect: '/admin/stats' },
    {
      path: '/admin/stats',
      name: 'admin-stats',
      component: () => import('@/views/admin/StatsView.vue'),
      meta: { requiresAuth: true, roles: ['admin', 'super_admin'] },
    },
    {
      path: '/admin/qc-tasks',
      name: 'admin-qc-tasks',
      component: () => import('@/views/admin/QcTaskManageView.vue'),
      meta: { requiresAuth: true, roles: ['admin', 'super_admin'] },
    },
    {
      path: '/admin/exports',
      name: 'admin-exports',
      component: () => import('@/views/admin/ExportManageView.vue'),
      meta: { requiresAuth: true, roles: ['admin', 'super_admin'] },
    },
    {
      path: '/admin/settings',
      name: 'admin-settings',
      component: () => import('@/views/admin/SettingsView.vue'),
      meta: { requiresAuth: true, roles: ['admin', 'super_admin'] },
    },
    {
      path: '/admin/status',
      name: 'admin-status',
      component: () => import('@/views/admin/SystemStatusView.vue'),
      meta: { requiresAuth: true, roles: ['admin', 'super_admin'] },
    },
    {
      path: '/qc/tasks',
      name: 'qc-tasks',
      component: () => import('@/views/qc/QcIndexView.vue'),
      meta: { requiresAuth: true, roles: ['qc'] },
    },
    {
      path: '/qc/my-tasks',
      name: 'qc-my-tasks',
      component: () => import('@/views/qc/QcIndexView.vue'),
      meta: { requiresAuth: true, roles: ['qc'] },
    },
    {
      path: '/qc/completed',
      name: 'qc-completed',
      component: () => import('@/views/qc/QcIndexView.vue'),
      meta: { requiresAuth: true, roles: ['qc'] },
    },
    {
      path: '/qc/review/:id',
      name: 'qc-review',
      component: () => import('@/views/qc/QcIndexView.vue'),
      meta: { requiresAuth: true, roles: ['qc'] },
    },
  ],
})

router.beforeEach((to) => {
  const auth = useAuthStore()
  if (to.name === 'change-password' && auth.isLoggedIn && !auth.user?.mustChangePassword) {
    return auth.user?.homePath || '/admin/stats'
  }
  if (to.meta.guest && auth.isLoggedIn) {
    return auth.user?.homePath || '/admin/stats'
  }
  if (to.meta.requiresAuth) {
    if (!auth.isLoggedIn) return { path: '/login', query: { redirect: to.fullPath } }
    if (auth.user?.mustChangePassword && to.name !== 'change-password') {
      return { path: '/change-password' }
    }
    const roles = to.meta.roles as string[] | undefined
    if (roles && auth.user) {
      // A user can hold both QC and admin; role is only the display/default role.
      const held = auth.user.roles?.length ? auth.user.roles : [auth.user.role]
      if (!roles.some((role) => held.includes(role))) {
        return auth.user.homePath || '/login'
      }
    }
  }
  return true
})

// Every route here is a dynamic import, and Vite content-hashes the chunk it
// produces. Redeploy the console while an operator has it open - which is what
// a QC engine restart after a settings save does - and the page they are
// holding still references the OLD chunk names. The moment they navigate
// somewhere they have not been yet, the browser asks for a file that no longer
// exists, the import rejects, and vue-router swallows it: the click does
// nothing at all, with no error on screen. It looks exactly like a dead button.
//
// Reloading is the only real fix - the running app cannot repair its own stale
// manifest - so reload straight into where they were trying to go. The guard on
// `reloaded` stops a genuinely broken deploy from becoming an infinite refresh
// loop, since a second failure will not be a stale chunk.
router.onError((error, to) => {
  const message = String((error as Error)?.message ?? error)
  const isStaleChunk =
    /Failed to fetch dynamically imported module|Importing a module script failed|error loading dynamically imported module/i.test(
      message,
    )
  if (!isStaleChunk) return
  const reloaded = sessionStorage.getItem('lwcam:chunk-reload')
  if (reloaded === to.fullPath) return
  try {
    sessionStorage.setItem('lwcam:chunk-reload', to.fullPath)
  } catch {
    // Private windows and blocked site data both throw here. Losing the guard
    // only costs us the loop protection, so carry on and still reload.
  }
  window.location.assign(to.fullPath)
})

export default router

