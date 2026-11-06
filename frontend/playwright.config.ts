import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from '@playwright/test'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..')
const port = Number(process.env.DAWRI_E2E_PORT ?? 8142)

// Workers load this file again, so the first load's choice travels in the environment.
process.env.DAWRI_E2E_DB ??= join(mkdtempSync(join(tmpdir(), 'dawri-e2e-')), 'dawri.db')
process.env.DAWRI_E2E_BASE = `http://127.0.0.1:${port}`
process.env.DAWRI_E2E_ROOT = repoRoot

export default defineConfig({
  testDir: './e2e',
  globalTeardown: './e2e/teardown.ts',
  // One demo seed is shared by every test, so nothing here may run at the same time.
  workers: 1,
  fullyParallel: false,
  forbidOnly: true,
  retries: 0,
  timeout: 90_000,
  expect: { timeout: 8_000 },
  reporter: [['list']],
  outputDir: './test-results',
  use: {
    baseURL: process.env.DAWRI_E2E_BASE,
    channel: 'chrome',
    headless: true,
    viewport: { width: 390, height: 844 },
    locale: 'en-GB',
    timezoneId: 'Asia/Qatar',
    trace: 'retain-on-failure',
    launchOptions: { args: ['--autoplay-policy=no-user-gesture-required'] },
  },
  webServer: {
    command: `.venv/bin/uvicorn backend.main:app --port ${port} --timeout-graceful-shutdown 1`,
    cwd: repoRoot,
    url: `${process.env.DAWRI_E2E_BASE}/api/health`,
    reuseExistingServer: false,
    timeout: 30_000,
    stdout: 'ignore',
    stderr: 'pipe',
    env: {
      DAWRI_DB: process.env.DAWRI_E2E_DB,
      SIMULATE_LOAD: '1',
      HF_TOKEN: '',
      DAWRI_STATIC_DIR: 'frontend/dist',
    },
  },
})
