// Shared axios client of the QC Platform web console. Every API call goes
// through it: it adds the login token, turns error responses into translated
// messages (ApiError carries the HTTP status) and handles an expired login.
import axios, { type AxiosError, type InternalAxiosRequestConfig } from 'axios'
import { i18n } from '@/i18n'
import router from '@/router'
import { useAuthStore } from '@/stores/auth'
import type { ApiResponse } from '@/types'

/** An Error carrying the failed response's HTTP status, so callers can branch on it
 * (e.g. a 404 from claim-next means "queue empty", not a real failure). Every request
 * goes through the interceptor below, so this is the one place that needs to attach it. */
export interface ApiError extends Error {
  status?: number
}

const request = axios.create({
  baseURL: '/api',
  timeout: 15000,
})

function localizedApiMessage(payload?: ApiResponse<unknown>) {
  const detail = payload?.data as
    | { errorKey?: string; errorParams?: Record<string, unknown> }
    | null
    | undefined
  if (detail?.errorKey) {
    // Try the errorKey as its own full i18n key first — most endpoints key their own
    // messages directly. Fall back to the legacy admin.exports-prefixed lookup, the
    // only namespace that existed when this prefix was hardcoded for every endpoint.
    if (i18n.global.te(detail.errorKey)) {
      return i18n.global.t(detail.errorKey, detail.errorParams || {})
    }
    const legacyKey = `admin.exports.errors.${detail.errorKey}`
    if (i18n.global.te(legacyKey)) {
      return i18n.global.t(legacyKey, detail.errorParams || {})
    }
  }
  return payload?.message
}

request.interceptors.request.use((config: InternalAxiosRequestConfig) => {
  const auth = useAuthStore()
  if (auth.token) {
    config.headers.Authorization = `Bearer ${auth.token}`
  }
  return config
})

request.interceptors.response.use(
  (response) => {
    if (response.config.responseType === 'blob') return response
    const payload = response.data as ApiResponse<unknown>
    if (payload.code !== 0) {
      return Promise.reject(new Error(localizedApiMessage(payload) || i18n.global.t('errors.requestFailed')))
    }
    return response
  },
  (error: AxiosError<ApiResponse<unknown>>) => {
    const message =
      localizedApiMessage(error.response?.data) ||
      error.message ||
      i18n.global.t('errors.network')
    if (error.response?.status === 401) {
      const auth = useAuthStore()
      auth.clear()
      if (router.currentRoute.value.path !== '/login') {
        // Say WHY when this account signed in somewhere else: otherwise it
        // looks like a random logout.
        const detail = error.response.data?.data as { errorKey?: string } | null | undefined
        const replaced = detail?.errorKey === 'auth.signedInElsewhere'
        router.push({
          path: '/login',
          query: { redirect: router.currentRoute.value.fullPath, ...(replaced ? { reason: 'elsewhere' } : {}) },
        })
      }
    }
    const apiError: ApiError = new Error(message)
    apiError.status = error.response?.status
    return Promise.reject(apiError)
  },
)

export default request

