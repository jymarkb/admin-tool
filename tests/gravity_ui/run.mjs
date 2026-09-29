import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { LuauState } from 'luau-web'
const here = path.dirname(fileURLToPath(import.meta.url))
const script = path.join(here, '..', '..', 'simple_gravity_ui.lua')
const state = await LuauState.createAsync({ print: (...a) => console.log(a.map(String).join(' ')) })
state.env.setreadonly(state.env, false)
async function load(file, name) {
  return await state.loadstring(fs.readFileSync(file, 'utf8'), name, true)()
}
async function run(src, name) {
  return await state.loadstring(src, name, true)()
}
await load(path.join(here, 'mock.lua'), 'mock')
// load 1: executor exposes gethui -> panel must go to the hidden container
await load(script, 'simple_gravity_ui #1')
// load 2: no gethui -> falls back to PlayerGui, and the rerun guard kills load 1's panel
await run('_G.gethui = nil', 'clear_gethui')
await load(script, 'simple_gravity_ui #2')
await load(path.join(here, 'driver.lua'), 'driver')
