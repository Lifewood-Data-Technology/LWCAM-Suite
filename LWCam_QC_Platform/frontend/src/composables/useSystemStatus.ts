import { onBeforeUnmount, onMounted, ref } from 'vue'
import { adminApi } from '@/api'
import type { SystemStatus } from '@/types'

/** Polls /admin/system-status. A failed poll keeps the last answer: the banner
 * must not flicker away because one request timed out. */
export function useSystemStatus(intervalMs: number, enabled = true, showAll: () => boolean = () => false) {
  const status = ref<SystemStatus | null>(null)
  const loading = ref(false)
  let timer: number | undefined

  async function refresh() {
    loading.value = true
    try {
      status.value = (await adminApi.systemStatus(showAll())).data.data
    } catch {
      // keep the previous status
    } finally {
      loading.value = false
    }
  }

  onMounted(() => {
    if (!enabled) return
    void refresh()
    timer = window.setInterval(refresh, intervalMs)
  })
  onBeforeUnmount(() => window.clearInterval(timer))

  return { status, loading, refresh }
}
