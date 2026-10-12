// Works out how many table rows fit the browser window, so admin list pages
// (QC tasks, exports) fill the screen without a page scrollbar.
// The caller passes the pixel heights of a row, the header, the footer and some padding;
// the result is a reactive pageSize (never below minRows, default 5), recomputed
// 160 ms after the window stops resizing.
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'

interface AdaptivePageSizeOptions {
  rowHeight: number
  headerHeight: number
  footerHeight: number
  safePadding: number
  minRows?: number
}

export function useAdaptivePageSize(options: AdaptivePageSizeOptions) {
  const viewportHeight = ref(typeof window === 'undefined' ? 768 : window.innerHeight)
  let resizeTimer: ReturnType<typeof window.setTimeout> | undefined

  const pageSize = computed(() => {
    const available = viewportHeight.value - options.headerHeight - options.footerHeight - options.safePadding
    return Math.max(options.minRows ?? 5, Math.floor(available / options.rowHeight))
  })

  function updateViewportHeight() {
    viewportHeight.value = window.innerHeight
  }

  function onResize() {
    if (resizeTimer) window.clearTimeout(resizeTimer)
    resizeTimer = window.setTimeout(updateViewportHeight, 160)
  }

  onMounted(() => {
    updateViewportHeight()
    window.addEventListener('resize', onResize)
  })

  onBeforeUnmount(() => {
    if (resizeTimer) window.clearTimeout(resizeTimer)
    window.removeEventListener('resize', onResize)
  })

  return { pageSize }
}
