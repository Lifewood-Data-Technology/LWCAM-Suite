<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'

const props = defineProps<{
  modelValue: boolean
  src: string
  alt?: string
}>()

const emit = defineEmits<{
  'update:modelValue': [value: boolean]
}>()

const { t } = useI18n()
const MIN_SCALE = 0.25
const MAX_SCALE = 5
const SCALE_STEP = 0.2

const scale = ref(1)
const rotation = ref(0)
const offset = ref({ x: 0, y: 0 })
const dragging = ref(false)
const dragStart = ref({ x: 0, y: 0 })
const dragOrigin = ref({ x: 0, y: 0 })

const visible = computed({
  get: () => props.modelValue,
  set: (value: boolean) => emit('update:modelValue', value),
})

const imageStyle = computed(() => ({
  transform: `translate(${offset.value.x}px, ${offset.value.y}px) scale(${scale.value}) rotate(${rotation.value}deg)`,
  cursor: dragging.value ? 'grabbing' : scale.value > 1 ? 'grab' : 'default',
}))

function clampScale(value: number) {
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, Number(value.toFixed(2))))
}

function resetView() {
  scale.value = 1
  rotation.value = 0
  offset.value = { x: 0, y: 0 }
}

function close() {
  visible.value = false
}

function zoom(delta: number) {
  scale.value = clampScale(scale.value + delta)
}

function rotate(delta: number) {
  rotation.value = (rotation.value + delta) % 360
}

function handleWheel(event: WheelEvent) {
  event.preventDefault()
  zoom(event.deltaY > 0 ? -SCALE_STEP : SCALE_STEP)
}

function startDrag(event: PointerEvent) {
  if (scale.value <= 1) return
  dragging.value = true
  dragStart.value = { x: event.clientX, y: event.clientY }
  dragOrigin.value = { ...offset.value }
  window.addEventListener('pointermove', handleDrag)
  window.addEventListener('pointerup', stopDrag)
}

function handleDrag(event: PointerEvent) {
  if (!dragging.value) return
  offset.value = {
    x: dragOrigin.value.x + event.clientX - dragStart.value.x,
    y: dragOrigin.value.y + event.clientY - dragStart.value.y,
  }
}

function stopDrag() {
  dragging.value = false
  window.removeEventListener('pointermove', handleDrag)
  window.removeEventListener('pointerup', stopDrag)
}

watch(
  () => [props.modelValue, props.src],
  ([isVisible]) => {
    if (isVisible) resetView()
  },
)

onBeforeUnmount(stopDrag)
</script>

<template>
  <el-dialog v-model="visible" fullscreen append-to-body :show-close="false" class="image-viewer-dialog">
    <div class="image-viewer">
      <div class="image-viewer__toolbar">
        <el-tooltip :content="t('viewer.zoomIn')" placement="bottom">
          <el-button circle :icon="'ZoomIn'" @click="zoom(SCALE_STEP)" />
        </el-tooltip>
        <el-tooltip :content="t('viewer.zoomOut')" placement="bottom">
          <el-button circle :icon="'ZoomOut'" @click="zoom(-SCALE_STEP)" />
        </el-tooltip>
        <el-tooltip :content="t('viewer.rotateLeft')" placement="bottom">
          <el-button circle :icon="'RefreshLeft'" @click="rotate(-90)" />
        </el-tooltip>
        <el-tooltip :content="t('viewer.rotateRight')" placement="bottom">
          <el-button circle :icon="'RefreshRight'" @click="rotate(90)" />
        </el-tooltip>
        <el-tooltip :content="t('viewer.reset')" placement="bottom">
          <el-button circle :icon="'Refresh'" @click="resetView" />
        </el-tooltip>
        <span class="image-viewer__scale">{{ Math.round(scale * 100) }}%</span>
        <el-tooltip :content="t('viewer.close')" placement="bottom">
          <el-button circle :icon="'Close'" @click="close" />
        </el-tooltip>
      </div>
      <div class="image-viewer__stage" @wheel="handleWheel">
        <img v-if="src" :src="src" :alt="alt || t('viewer.imagePreview')" :style="imageStyle" draggable="false" @pointerdown="startDrag" />
      </div>
    </div>
  </el-dialog>
</template>

<style scoped>
:global(.image-viewer-dialog .el-dialog__header) {
  display: none;
}

:global(.image-viewer-dialog .el-dialog__body) {
  height: 100vh;
  padding: 0;
}

.image-viewer {
  width: 100%;
  height: 100vh;
  display: grid;
  grid-template-rows: auto 1fr;
  background: rgba(11, 17, 14, 0.96);
}

.image-viewer__toolbar {
  min-height: 56px;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 10px;
  padding: 10px 16px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.12);
}

.image-viewer__scale {
  min-width: 54px;
  color: #fff;
  font-size: 14px;
  text-align: center;
}

.image-viewer__stage {
  min-width: 0;
  min-height: 0;
  display: grid;
  place-items: center;
  overflow: hidden;
  touch-action: none;
}

.image-viewer__stage img {
  max-width: 92vw;
  max-height: calc(100vh - 88px);
  object-fit: contain;
  transform-origin: center center;
  transition: transform 0.08s ease-out;
  user-select: none;
}

@media (max-width: 640px) {
  .image-viewer__toolbar {
    justify-content: flex-start;
    overflow-x: auto;
  }
}
</style>
