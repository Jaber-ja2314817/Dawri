import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// Replaced at build time, so the inspect branch in session.tsx is dead code in a normal build.
const inspect = process.env.VITE_INSPECT ?? ''

export default defineConfig({
  plugins: [react(), tailwindcss()],
  define: {
    'import.meta.env.VITE_INSPECT': JSON.stringify(inspect),
  },
  server: {
    port: 5173,
    proxy: {
      // SSE passes through: no response buffering here, and the backend sends no-cache.
      '/api': { target: 'http://127.0.0.1:7860', changeOrigin: true },
    },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    include: ['src/**/*.test.{ts,tsx}'],
    exclude: ['e2e/**', 'node_modules/**'],
  },
})
