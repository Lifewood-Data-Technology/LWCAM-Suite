import { createApp } from 'vue'
import { createPinia } from 'pinia'
import ElementPlus from 'element-plus'
import 'element-plus/dist/index.css'
import * as ElementPlusIconsVue from '@element-plus/icons-vue'

import App from '@/App.vue'
import { i18n } from '@/i18n'
import router from '@/router'
import { authApi } from '@/api'
import { useAuthStore } from '@/stores/auth'
import '@/styles/lifewood.css'
import '@/styles/auth.css'

const app = createApp(App)

for (const [key, component] of Object.entries(ElementPlusIconsVue)) {
  app.component(key, component)
}

app.use(createPinia())
app.use(router)
// Every control one step up. The console is used all day on a full desktop
// window, and Element Plus's default sizing is tuned for dense dashboards -
// on a 1080p screen the forms were small islands in a lot of empty space.
// Set once here rather than size="large" repeated on a hundred elements.
app.use(ElementPlus, { size: 'large' })
app.use(i18n)
app.mount('#app')

// Check in once a minute while signed in: the server treats a sign-in silent
// for 3 minutes as a closed browser and lets the account sign in elsewhere
// (app/core/security.py). Also how a signed-out tab finds out promptly.
window.setInterval(() => {
  if (useAuthStore().token) authApi.me().catch(() => undefined)
}, 60_000)

