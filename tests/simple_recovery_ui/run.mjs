import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { LuauState } from 'luau-web'
const here = path.dirname(fileURLToPath(import.meta.url))
const scriptPath = path.join(here, '..', '..', 'simple_recovery_ui.lua')
const lines = []
const state = await LuauState.createAsync({ print: (...a) => {
  const text = a.map((v) => String(v)).join(' ')
  lines.push(text)
  console.log(text)
} })
state.env.setreadonly(state.env, false)
async function load(file, name) { await state.loadstring(fs.readFileSync(file, 'utf8'), name, true)() }
await load(path.join(here, 'mock.lua'), 'mock')
await load(scriptPath, 'ui-1')
await load(path.join(here, 'driver.lua'), 'driver-1')
await load(scriptPath, 'ui-2')
await load(path.join(here, 'driver2.lua'), 'driver-2')
const failed = lines.filter((l) => l.includes('[FAIL]')).length
console.log('')
console.log(`SUMMARY failures=${failed}`)
if (failed > 0) process.exitCode = 1
