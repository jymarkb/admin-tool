local M = MOCK
local F = M.fixture
local API = _G.ADVANCED_SCANNER_V3
M.reset()

-- scenario: carrying an egg in the far egg area, boss hazard fires, physics launch (like the 01:33 log)
M.setAttribute(F.player, "AreaId", "Jungle")
API.watch(true)
M.pump(0.1)

local left = M.journalText()
print("--- FULL SCAN (excerpt) ---")
API.scan()
local g = 0
while not string.find(M.journalText(), "SCAN COMPLETE", 1, true) and g < 4000 do g = g + 1 M.pump(0.02) end
local shown, want = 0, {
	"REMOTE INVENTORY", "RE/BossEvent", "RE/EggWorld", "RE/Limpness", "RE/ZoneProbe",
	"FOCUS family", "OBJECT SEARCH", "TreadmillUpgrade", "RagdollEndTime = ",
}
for _, e in ipairs(API.journal()) do
	for _, w in ipairs(want) do
		if string.find(e.line, w, 1, true) then print("  " .. e.line) shown = shown + 1 break end
	end
	if shown > 16 then break end
end

API.clear()
print("")
print("--- LIVE CAPTURE: boss hit while carrying ---")
M.fireRemote(F.watchTargets[2], { source = "scramble", damage = 15, power = 1.4 })
M.setAttribute(F.player, "RagdollEndTime", M.serverNow() + 2.4)     -- server announces the limp window
M.drive(function() F.humanoid._props._State = M.enumItem("HumanoidStateType", "Physics") end)
M.setVelocity(-495, 71, -26)                                        -- launch (from the real log)
M.pump(0.4)
M.setVelocity(-496, 40, -25)
M.pump(0.5)
M.setHealth(F.humanoid, 85)
M.pump(1.6)
M.drive(function() F.humanoid:ChangeState(M.enumItem("HumanoidStateType", "GettingUp")) end)
M.pump(0.1)
M.drive(function() F.humanoid:ChangeState(M.enumItem("HumanoidStateType", "Running")) end)
M.pump(0.3)

for _, e in ipairs(API.journal()) do
	if e.tag == "RE" or e.tag == "HIT" or e.tag == "ATTR" or e.tag == "HEALTH"
		or e.tag == "STATE" or e.tag == "STATUS" or e.tag == "WATCH" then
		print("  " .. e.line)
	end
end

print("")
print("--- EXPORT (what COPY RESULTS gives you) ---")
local text = API.export()
for _, line in ipairs({ text:match("([^\n]*)\n"), text:match("\n([^\n]*)\n"),
	"… (" .. select(2, text:gsub("\n", "")) .. " lines total)" }) do print("  " .. line) end
print("  stats: " .. string.format("events=%d suppressed=%d outgoingCalls=%d",
	API.stats().events, API.stats().suppressed, API.stats().outgoingCalls))
