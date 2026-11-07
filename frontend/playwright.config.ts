import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig, type PlaywrightTestConfig } from '@playwright/test'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '..')
const port = Number(process.env.DAWRI_E2E_PORT ?? 8142)
const standInPort = port + 10
const REAL_MODE = /real-mode\.spec\.ts$/

// DAWRI_E2E_CONTAINER names a running dawri:local: no server of our own, and its DB is its own.
const container = process.env.DAWRI_E2E_CONTAINER

const base = (at: number) => `http://127.0.0.1:${at}`
const staticDir = process.env.DAWRI_E2E_STATIC ?? 'frontend/dist'

function server(command: string, at: number, db: string) {
  return {
    command,
    cwd: repoRoot,
    url: `${base(at)}/api/health`,
    reuseExistingServer: false,
    timeout: 30_000,
    stdout: 'ignore' as const,
    stderr: 'pipe' as const,
    env: { DAWRI_DB: db, SIMULATE_LOAD: '1', HF_TOKEN: '', DAWRI_STATIC_DIR: staticDir },
  }
}

// Workers load this file again, so the first load's choice travels in the environment.
if (container === undefined) {
  process.env.DAWRI_E2E_DB ??= join(mkdtempSync(join(tmpdir(), 'dawri-e2e-')), 'dawri.db')
}
const db = container === undefined ? (process.env.DAWRI_E2E_DB as string) : '/tmp/dawri.db'
const standInDb = join(dirname(db), 'stand-in.db')

process.env.DAWRI_E2E_BASE = base(port)
process.env.DAWRI_E2E_ROOT = repoRoot

const simulatedProject = {
  name: 'simulated',
  testIgnore: REAL_MODE,
  use: { baseURL: base(port) },
  metadata: { db },
}
const standInProject = {
  name: 'stand-in',
  testMatch: REAL_MODE,
  use: { baseURL: base(standInPort) },
  metadata: { db: standInDb },
}

const servers: PlaywrightTestConfig['webServer'] =
  container === undefined
    ? [
        server(
          `.venv/bin/uvicorn backend.main:app --port ${port} --timeout-graceful-shutdown 1`,
          port,
          db,
        ),
        server(
          `.venv/bin/python -m backend.tests.standin_server --port ${standInPort}`,
          standInPort,
          standInDb,
        ),
      ]
    : undefined

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
  outputDir: process.env.DAWRI_E2E_OUTPUT ?? './test-results',
  use: {
    channel: 'chrome',
    headless: true,
    viewport: { width: 390, height: 844 },
    locale: 'en-GB',
    timezoneId: 'Asia/Qatar',
    trace: 'retain-on-failure',
    launchOptions: { args: ['--autoplay-policy=no-user-gesture-required'] },
  },
  projects: container === undefined ? [simulatedProject, standInProject] : [simulatedProject],
  webServer: servers,
})
