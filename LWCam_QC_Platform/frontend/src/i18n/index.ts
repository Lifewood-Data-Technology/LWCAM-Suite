import { createI18n } from 'vue-i18n'
import enUS from '@/i18n/locales/en-US'

// One locale on purpose. The console is English-only, so vue-i18n is kept for
// what it still earns its place doing — a keyed message store that
// translateValue() and the te()-guarded errorKey/qcStatuses lookups dispatch
// against — not for translation.
export const i18n = createI18n({
  legacy: false,
  locale: 'en-US',
  messages: {
    'en-US': enUS,
  },
})

export function translateValue(prefix: string, value: string | undefined | null) {
  if (!value) return ''
  const key = `${prefix}.${value}`
  const translated = i18n.global.t(key)
  return translated === key ? value : translated
}
