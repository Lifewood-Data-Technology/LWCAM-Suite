// Loads the page image the QC review screen is showing as a blob and exposes it as a src URL.
// Preview URLs need the auth token, so they are fetched through the axios client
// rather than set directly as <img src>.
// A request counter drops results from an earlier page if the reviewer has already moved
// on, and the object URL is revoked on every change and on unmount to avoid leaking memory.
import { onBeforeUnmount, ref, watch, type Ref } from 'vue'
import request from '@/api/client'
import { i18n } from '@/i18n'

interface PreviewImage {
  previewUrl: string
}

function toApiPath(url: string) {
  return url.startsWith('/api/') ? url.slice(4) : url
}

export function usePreviewImage(image: Ref<PreviewImage | null>) {
  const previewSrc = ref('')
  const previewLoading = ref(false)
  const previewError = ref('')
  let objectUrl = ''
  let requestId = 0

  function revokePreview() {
    if (objectUrl) {
      URL.revokeObjectURL(objectUrl)
      objectUrl = ''
    }
    previewSrc.value = ''
  }

  watch(
    image,
    async (nextImage) => {
      const currentRequest = ++requestId
      revokePreview()
      previewError.value = ''

      if (!nextImage?.previewUrl) return

      previewLoading.value = true
      try {
        const { data } = await request.get<Blob>(toApiPath(nextImage.previewUrl), { responseType: 'blob' })
        if (currentRequest !== requestId) return

        objectUrl = URL.createObjectURL(data)
        previewSrc.value = objectUrl
      } catch (error) {
        if (currentRequest === requestId) {
          previewError.value = (error as Error).message || i18n.global.t('errors.imageLoadFailed')
        }
      } finally {
        if (currentRequest === requestId) {
          previewLoading.value = false
        }
      }
    },
    { immediate: true },
  )

  // Bump the request id too, the way ThumbnailImage.vue does: revoking alone
  // leaves an in-flight fetch still matching `currentRequest === requestId`, so
  // it creates a fresh object URL AFTER teardown that nothing will ever revoke.
  onBeforeUnmount(() => {
    requestId += 1
    revokePreview()
  })

  return {
    previewSrc,
    previewLoading,
    previewError,
  }
}
