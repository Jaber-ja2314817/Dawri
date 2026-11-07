import { rmSync } from 'node:fs'
import { basename, dirname } from 'node:path'

/** The run's two databases go with the run. A path set from outside is left alone. */
export default function teardown() {
  const db = process.env.DAWRI_E2E_DB
  if (db === undefined) return // A container owns its database.
  const folder = dirname(db)
  if (basename(folder).startsWith('dawri-e2e-')) rmSync(folder, { recursive: true, force: true })
}
