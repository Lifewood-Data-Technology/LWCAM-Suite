import { defineStore } from 'pinia'
import type { UserInfo } from '@/types'

interface AuthState {
  token: string
  user: UserInfo | null
}

const STORAGE_KEY = 'lwcam_lifewood_auth'

function loadState(): AuthState {
  const raw = localStorage.getItem(STORAGE_KEY)
  if (!raw) return { token: '', user: null }
  try {
    return JSON.parse(raw) as AuthState
  } catch {
    return { token: '', user: null }
  }
}

export const useAuthStore = defineStore('auth', {
  state: (): AuthState => loadState(),
  getters: {
    isLoggedIn: (state) => Boolean(state.token && state.user),
  },
  actions: {
    setAuth(token: string, user: UserInfo) {
      this.token = token
      this.user = user
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ token, user }))
    },
    setUser(user: UserInfo) {
      this.user = user
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ token: this.token, user }))
    },
    clear() {
      this.token = ''
      this.user = null
      localStorage.removeItem(STORAGE_KEY)
    },
  },
})

