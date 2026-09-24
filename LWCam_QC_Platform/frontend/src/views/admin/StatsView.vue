<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { ElMessage } from 'element-plus'
import * as echarts from 'echarts/core'
import { TooltipComponent, LegendComponent, GridComponent } from 'echarts/components'
import { PieChart, LineChart } from 'echarts/charts'
import { CanvasRenderer } from 'echarts/renderers'
import AppShell from '@/components/AppShell.vue'
import { adminApi } from '@/api'
import { translateValue } from '@/i18n'
import type { StatsOverview } from '@/types'

echarts.use([TooltipComponent, LegendComponent, GridComponent, PieChart, LineChart, CanvasRenderer])

const { t } = useI18n()
const loading = ref(false)
const chartRef = ref<HTMLDivElement | null>(null)
const trendChartRef = ref<HTMLDivElement | null>(null)
let chart: echarts.ECharts | null = null
let trendChart: echarts.ECharts | null = null
const stats = ref<StatsOverview>({
  todayNewTasks: 0,
  todayCompletedTasks: 0,
  todayQcPassRate: 0,
  totalUsers: 0,
  totalTasks: 0,
  pendingClaimTasks: 0,
  taskTrend: [],
  taskStatusDistribution: [],
  reviewerWorkload: [],
})

const statusDistribution = computed(() =>
  stats.value.taskStatusDistribution.map((item) => ({
    name: translateValue('metadataQcStatus', item.status || item.label),
    value: item.count,
  })),
)

const trendDates = computed(() => stats.value.taskTrend.map((item) => String(item.date ?? '')))
const trendCounts = computed(() => stats.value.taskTrend.map((item) => Number(item.count ?? 0)))

// reviewer_workload (admin.py) only counts folders with qc_reviewed_by set, so a
// folder decided before that column existed has no reviewer and is dropped —
// these two totals are never meant to match. Comparing against the raw
// pass/rework counts from taskStatusDistribution (unaffected by that exclusion)
// is what lets the UI say so instead of leaving someone to reconcile them.
const reviewedFolderCount = computed(() =>
  stats.value.taskStatusDistribution
    .filter((item) => item.label === 'pass' || item.label === 'rework')
    .reduce((sum, item) => sum + item.count, 0),
)
const workloadTotal = computed(() =>
  stats.value.reviewerWorkload.reduce((sum, row) => sum + row.total, 0),
)
const workloadGap = computed(() => reviewedFolderCount.value - workloadTotal.value)

async function load() {
  loading.value = true
  try {
    const { data } = await adminApi.stats()
    stats.value = data.data
    await nextTick()
    renderChart()
  } catch (error) {
    ElMessage.error((error as Error).message)
  } finally {
    loading.value = false
  }
}

function renderChart() {
  if (!chartRef.value) return
  chart ||= echarts.init(chartRef.value)
  chart.setOption({
    tooltip: { trigger: 'item' },
    legend: { bottom: 0, left: 'center' },
    series: [
      {
        name: t('admin.stats.distribution'),
        type: 'pie',
        radius: ['46%', '70%'],
        center: ['50%', '42%'],
        avoidLabelOverlap: true,
        data: statusDistribution.value,
      },
    ],
  })
  if (!trendChartRef.value) return
  trendChart ||= echarts.init(trendChartRef.value)
  trendChart.setOption({
    tooltip: { trigger: 'axis' },
    grid: { left: 40, right: 20, top: 20, bottom: 30 },
    xAxis: { type: 'category', data: trendDates.value },
    yAxis: { type: 'value', minInterval: 1 },
    series: [
      {
        name: t('admin.stats.taskTrendCount'),
        type: 'line',
        smooth: true,
        areaStyle: {},
        data: trendCounts.value,
      },
    ],
  })
}

function resizeChart() {
  chart?.resize()
  trendChart?.resize()
}

onMounted(() => {
  load()
  window.addEventListener('resize', resizeChart)
})

onBeforeUnmount(() => {
  window.removeEventListener('resize', resizeChart)
  chart?.dispose()
  trendChart?.dispose()
})
</script>

<template>
  <AppShell>
    <div class="page-title">
      <div>
        <h1>{{ t('admin.stats.title') }}</h1>
        <p>{{ t('admin.stats.subtitle') }}</p>
      </div>
      <el-button :icon="'Refresh'" :loading="loading" @click="load">{{ t('common.refresh') }}</el-button>
    </div>

    <div class="metric-grid">
      <div class="metric accent"><span>{{ t('admin.stats.todayNew') }}</span><strong>{{ stats.todayNewTasks }}</strong></div>
      <div class="metric green"><span>{{ t('admin.stats.todayCompleted') }}</span><strong>{{ stats.todayCompletedTasks }}</strong></div>
      <div class="metric green"><span>{{ t('admin.stats.todayPassRate') }}</span><strong>{{ stats.todayQcPassRate }}%</strong></div>
      <div class="metric"><span>{{ t('admin.stats.pendingClaim') }}</span><strong>{{ stats.pendingClaimTasks }}</strong></div>
      <div class="metric"><span>{{ t('admin.stats.totalUsers') }}</span><strong>{{ stats.totalUsers }}</strong></div>
      <div class="metric"><span>{{ t('admin.stats.totalTasks') }}</span><strong>{{ stats.totalTasks }}</strong></div>
    </div>

    <div class="stats-grid">
      <section class="panel chart-panel">
        <div class="panel-heading">
          <h2>{{ t('admin.stats.distribution') }}</h2>
        </div>
        <div ref="chartRef" class="status-chart" />
      </section>
      <section class="panel table-panel table-panel--compact">
        <el-table :data="stats.taskStatusDistribution" height="360">
          <el-table-column :label="t('common.status')">
            <template #default="{ row }">{{ translateValue('metadataQcStatus', row.status || row.label) }}</template>
          </el-table-column>
          <el-table-column prop="count" :label="t('admin.stats.count')" min-width="140" />
        </el-table>
      </section>
    </div>
    <section class="panel chart-panel" style="margin-top: 16px">
      <div class="panel-heading"><h2>{{ t('admin.stats.taskTrend') }}</h2></div>
      <div ref="trendChartRef" class="status-chart" />
    </section>

    <section class="panel table-panel" style="margin-top: 16px">
      <div class="panel-heading"><h2>{{ t('admin.stats.reviewerWorkload') }}</h2></div>
      <el-table :data="stats.reviewerWorkload">
        <el-table-column prop="reviewerName" :label="t('admin.stats.reviewer')" min-width="160" />
        <el-table-column prop="total" :label="t('admin.stats.totalReviewed')" min-width="155" />
        <el-table-column prop="approved" :label="t('admin.stats.approved')" min-width="150" />
        <el-table-column prop="rejected" :label="t('admin.stats.rejected')" min-width="150" />
      </el-table>
      <p v-if="workloadGap > 0" class="muted workload-gap-note">
        {{ t('admin.stats.workloadGapNote', { gap: workloadGap, total: reviewedFolderCount }) }}
      </p>
    </section>
  </AppShell>
</template>

<style scoped>
.workload-gap-note {
  margin: 0;
  padding: 14px 22px;
  font-size: 16px;
  border-top: 1px solid var(--el-border-color-lighter);
}
</style>
