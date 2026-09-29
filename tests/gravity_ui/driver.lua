-- Offline checks for simple_gravity_ui.lua.
-- run.mjs loads the script TWICE: once with gethui available (panel -> hidden container) and once with
-- gethui cleared (panel -> PlayerGui). These checks run against the second, live instance.
local M = MOCK
local API = _G.SIMPLE_GRAVITY_UI
local total, passed = 0, 0
local function check(name, cond, detail)
	total = total + 1
	if cond then passed = passed + 1; print(string.format("[PASS] %s", name))
	else print(string.format("[FAIL] %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or "")) end
end
local function has(text, needle) return string.find(tostring(text or ""), needle, 1, true) ~= nil end
local WS = M.workspace
local gravity = function() return WS.Gravity end   -- read the service directly: luau-web import-caches
	-- the bare `workspace.Gravity` global chain, so a bare-global read can look stale in this harness
local function near(a, b) return a ~= nil and math.abs(a - b) < 0.001 end

--=================== A. boot ===================
check("script exposes its API", API ~= nil and type(API.set) == "function")
check("rerun guard destroyed the gethui-parented panel", #M.services.CoreGui:GetChildren() == 0,
	#M.services.CoreGui:GetChildren())
check("panel parents to PlayerGui when gethui is missing", #M.guiParents == 2 and M.guiParents[2] == "PlayerGui",
	table.concat(M.guiParents, ","))
check("first load used the executor's hidden container", M.guiParents[1] == "CoreGui", M.guiParents[1])
check("exactly one gravity panel exists", #M.playerGui:GetChildren() == 1, #M.playerGui:GetChildren())
for _, name in ipairs({ "Btn_ZERO", "Btn_MOON", "Btn_LOW", "Btn_NORMAL", "Btn_HIGH", "Btn_APPLY", "Btn_RESET",
	"Btn_HOLD", "Btn_CLOSE", "Input", "Status", "Title" }) do
	check("GUI has " .. name, M.button(name) ~= nil)
end
check("game gravity captured at load", near(API.status().original, 196.2), API.status().original)
check("starts on the game's own value", near(gravity(), 196.2), gravity())
check("HOLD is on by default", API.status().hold == true)
check("nothing was fired at a remote", #M.remoteCalls == 0, #M.remoteCalls)

--=================== B. preset buttons ===================
for _, preset in ipairs({ { "ZERO", 0 }, { "MOON", 50 }, { "LOW", 100 }, { "NORMAL", 196.2 }, { "HIGH", 400 } }) do
	M.click("Btn_" .. preset[1])
	check(preset[1] .. " button sets gravity to " .. preset[2], near(gravity(), preset[2]),
		string.format("gravity=%s", tostring(gravity())))
end
check("active preset is highlighted", M.button("Btn_HIGH").BackgroundColor3.G > M.button("Btn_ZERO").BackgroundColor3.G,
	string.format("high G=%s zero G=%s", tostring(M.button("Btn_HIGH").BackgroundColor3.G),
		tostring(M.button("Btn_ZERO").BackgroundColor3.G)))
check("status shows the value in effect", has(M.button("Status").Text, "in effect"), M.button("Status").Text)
M.click("Btn_ZERO")
check("zero gravity really is 0", gravity() == 0, gravity())

--=================== C. custom value ===================
M.button("Input").Text = "123.5"
M.click("Btn_APPLY")
check("APPLY sets the typed value", near(gravity(), 123.5), gravity())
M.button("Input").Text = "-50"
M.click("Btn_APPLY")
check("negative gravity is allowed (fall upward)", near(gravity(), -50), gravity())
M.button("Input").Text = "99999"
M.click("Btn_APPLY")
check("above MAX is clamped to 5000", near(gravity(), 5000), gravity())
M.button("Input").Text = "-99999"
M.click("Btn_APPLY")
check("below MIN is clamped to -500", near(gravity(), -500), gravity())
local beforeBad = gravity()
M.button("Input").Text = "abc"
M.click("Btn_APPLY")
check("garbage input does not change gravity", near(gravity(), beforeBad), gravity())
check("garbage input is reported, not swallowed", has(M.button("History").Text, "not a number"),
	M.button("History").Text)
check("garbage input raised no Lua error", #M.errors == 0, M.errors[1] or "")
M.button("Input").Text = ""
M.click("Btn_APPLY")
check("empty input is refused too", near(gravity(), beforeBad), gravity())

--=================== D. RESET ===================
M.click("Btn_RESET")
check("RESET puts the game's value back", near(gravity(), 196.2), gravity())
check("RESET clears the highlight", M.button("Btn_ZERO").BackgroundColor3.G == M.button("Btn_HIGH").BackgroundColor3.G,
	string.format("zero G=%s high G=%s", tostring(M.button("Btn_ZERO").BackgroundColor3.G),
		tostring(M.button("Btn_HIGH").BackgroundColor3.G)))

--=================== E. HOLD ===================
M.click("Btn_MOON")
check("moon gravity applied", near(gravity(), 50), gravity())
-- the game re-replicates its own gravity while HOLD is on -> our value must come back
M.drive(function() WS.Gravity = 196.2 end)
M.pump(0.1)
check("HOLD re-applies after the game overwrites it", near(gravity(), 50), gravity())
check("HOLD counts the re-apply", API.status().held == 1, API.status().held)
check("HOLD says so in the status line", has(M.button("Status").Text, "kept 1x"), M.button("Status").Text)
M.drive(function() WS.Gravity = 196.2 end)
M.pump(0.1)
check("HOLD keeps working on repeated overwrites", near(gravity(), 50) and API.status().held == 2,
	string.format("gravity=%s held=%s", tostring(gravity()), tostring(API.status().held)))

M.click("Btn_HOLD")
check("HOLD button turns it off", API.status().hold == false and M.button("Btn_HOLD").Text == "HOLD: OFF",
	M.button("Btn_HOLD").Text)
M.drive(function() WS.Gravity = 196.2 end)
M.pump(0.1)
check("with HOLD off the game's value wins", near(gravity(), 196.2), gravity())
check("held counter stops moving with HOLD off", API.status().held == 2, API.status().held)
M.click("Btn_HOLD")
check("HOLD button turns it back on", API.status().hold == true and M.button("Btn_HOLD").Text == "HOLD: ON",
	M.button("Btn_HOLD").Text)

--=================== F. API + read-only ===================
check("API.set works like the buttons", (function()
	local ok, value = API.set(77)
	return ok == true and near(value, 77) and near(gravity(), 77)
end)(), tostring(gravity()))
check("API.hold is honoured", API.hold(false) == false and API.status().hold == false)
API.hold(true)
check("API.status reports target and original",
	near(API.status().target, 77) and near(API.status().original, 196.2), tostring(API.status().target))
check("API.log keeps a short history", #API.log() > 0 and type(API.log()) == "table")
check("character was never written to", M.writtenTo(M.character) == nil and M.writtenTo(M.humanoid) == nil
	and M.writtenTo(M.root) == nil)
check("only Workspace.Gravity was written on the game side", (function()
	for _, w in ipairs(M.writes) do if w.inst ~= WS or w.key ~= "Gravity" then return false, w.key end end
	return true
end)())
check("no remotes fired all session", #M.remoteCalls == 0, #M.remoteCalls)

--=================== G. cross-check: the hold is the only writer ===================
-- a value equal to our target is not re-applied (no write churn)
local writesBefore = #M.writes
M.pump(0.5)
check("no write churn while nothing changes", #M.writes == writesBefore,
	string.format("%d -> %d", writesBefore, #M.writes))

--=================== H. close ===================
local connsBefore = M.aliveConnections()
M.click("Btn_CLOSE")
M.pump(0.2)
check("CLOSE removes the panel", M.findDescendantByName(M.playerGui, "SimpleGravityUI") == nil)
check("CLOSE restores the game's gravity", near(gravity(), 196.2), gravity())
check("CLOSE clears the global", _G.SIMPLE_GRAVITY_UI == nil)
check("CLOSE disconnects every listener", M.aliveConnections() < connsBefore and M.aliveConnections() == 0,
	string.format("%d -> %d", connsBefore, M.aliveConnections()))
M.drive(function() WS.Gravity = 10 end)
M.pump(0.1)
check("closed panel no longer fights the game", near(gravity(), 10), gravity())
check("no Lua errors during the whole run", #M.errors == 0, M.errors[1] or "")

print(string.format("RESULT checks=%d passed=%d failed=%d", total, passed, total - passed))
print(string.format("SUMMARY failures=%d", total - passed))
