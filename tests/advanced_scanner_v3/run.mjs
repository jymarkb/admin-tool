import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { LuauState } from 'luau-web'
const here = path.dirname(fileURLToPath(import.meta.url))
const scanner = path.join(here, '..', '..', 'advanced_scanner_v3.lua')
const lines = []
const state = await LuauState.createAsync({ print: (...a) => {
  const text = a.map((v) => String(v)).join(' ')
  lines.push(text)
  console.log(text)
} })
state.env.setreadonly(state.env, false)
async function load(file, name) {
  return await state.loadstring(fs.readFileSync(file, 'utf8'), name, true)()
}
await load(path.join(here, 'mock.lua'), 'mock')
try {
  await load(scanner, 'advanced_scanner_v3')
} catch (e) {
  console.log('[FAIL] scanner chunk threw at load: ' + e)
  console.log('SUMMARY failures=1')
  process.exit(1)
}
await load(path.join(here, 'driver.lua'), 'driver')
const failed = lines.filter((l) => l.includes('[FAIL]')).length
console.log('')
console.log('SUMMARY failures=' + failed)
if (failed > 0) process.exitCode = 1
