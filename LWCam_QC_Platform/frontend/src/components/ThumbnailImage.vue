<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { Document } from '@element-plus/icons-vue'
import request from '@/api/client'

// Lazy authenticated thumbnail for the image rail. The preview endpoint needs
// the bearer token, so a plain <img src> can't be used — same blob approach as
// usePreviewImage. Fetches only once the element scrolls into view (folders can
// run to 100+ pages) and falls back to the document icon while loading/on error.
const props = defineProps<{ src: string; alt?: string }>()

const rootEl = ref<HTMLElement | null>(null)
const objectUrl = ref('')
let observer: IntersectionObserver | null = null
let requestId = 0

function toApiPath(url: string) {
  return url.startsWith('/api/') ? url.slice(4) : url
}

function revoke() {
  if (objectUrl.value) {
    URL.revokeObjectURL(objectUrl.value)
    objectUrl.value = ''
  }
}

async function load() {
  const currentRequest = ++requestId
  revoke()
  if (!props.src) return
  try {
    // First view of a folder fires one preview-generation request per image;
    // the server renders them with Pillow, so a 12-image folder can hold the
    // slowest requests well past the default 15s timeout. Generated previews
    // are disk-cached server-side, so only the first look is slow.
    const { data } = await request.get<Blob>(toApiPath(props.src), {
      responseType: 'blob',
      timeout: 60000,
    })
    if (currentRequest !== requestId) return
    objectUrl.value = URL.createObjectURL(data)
  } catch {
    // Icon fallback stays — a broken thumbnail must not break the rail.
  }
}

onMounted(() => {
  observer = new IntersectionObserver(
    (entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        observer?.disconnect()
        observer = null
        void load()
      }
    },
    { rootMargin: '200px' },
  )
  if (rootEl.value) observer.observe(rootEl.value)
})

// previewUrl carries a ?v= version that changes on every edit, so a src change
// means the image content changed — refetch (only if already loaded once;
// otherwise the observer will pick it up).
watch(
  () => props.src,
  () => {
    if (!observer) void load()
  },
)

onBeforeUnmount(() => {
  observer?.disconnect()
  requestId += 1
  revoke()
})
</script>

<template>
  <span ref="rootEl" class="thumbnail-image">
    <img v-if="objectUrl" :src="objectUrl" :alt="alt" draggable="false" />
    <el-icon v-else><Document /></el-icon>
  </span>
</template>

<style scoped>
.thumbnail-image {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
}

.thumbnail-image img {
  width: 100%;
  height: 100%;
  /* contain, not cover: QC judges crop/rotation state from these, so a rotated
     or oddly-sized page must be fully visible, never silently cropped */
  object-fit: contain;
}
</style>
