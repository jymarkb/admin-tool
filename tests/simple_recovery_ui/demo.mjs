import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { LuauState } from 'luau-web'
const here = path.dirname(fileURLToPath(import.meta.url))
const state = await LuauState.createAsync({ print: (...a) => console.log(...a) })
state.env.setreadonly(state.env, false)
async function load(f, n) { await state.loadstring(fs.readFileSync(f, 'utf8'), n, true)() }
await load(path.join(here, 'mock.lua'), 'mock')
await load(path.join(here, '..', '..', 'simple_recovery_ui.lua'), 'ui')
await load(path.join(here, 'demo.lua'), 'demo')
