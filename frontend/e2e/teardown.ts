import { rmSync } from 'node:fs'
import { basename, dirname } from 'node:path'

/** The run's database goes with the run. A path set from outside is left alone. */
export default function teardown() {
  const folder = dirname(process.env.DAWRI_E2E_DB as string)
  if (basename(folder).startsWith('dawri-e2e-')) rmSync(folder, { recursive: true, force: true })
}
