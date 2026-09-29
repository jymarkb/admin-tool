local M = MOCK
local F = M.fixture
local total, passed = 0, 0
local function check(name, cond, detail)
	total = total + 1
	if cond then passed = passed + 1; print(string.format("[PASS] %s", name))
	else print(string.format("[FAIL] %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or "")) end
end
local S = _G.SIMPLE_RECOVERY_UI
check("second run exposes a fresh instance", type(S) == "table")
if type(S) ~= "table" then
	print(string.format("RESULT checks=%d passed=%d failed=%d", total, passed, total - passed)); return
end
check("second instance is a new object", S ~= M.firstInstance)
local sawReplaced = false
for _, text in ipairs(M.prints) do
	if string.find(text, "stopped (replaced by a newer run)", 1, true) then sawReplaced = true break end
end
check("old instance stopped by the rerun guard", sawReplaced)
local guiCount = 0
for _, child in ipairs(F.playerGui:GetChildren()) do
	if tostring(child.Name) == "SimpleRecoveryUI" then guiCount = guiCount + 1 end
end
check("exactly one UI remains", guiCount == 1, guiCount)
check("rerun did not multiply connections",
	M.aliveConnections() <= M.firstConnectionCount + 2,
	string.format("%d vs %d", M.aliveConnections(), M.firstConnectionCount))

M.clearRagdoll(); M.pump(0.5)
M.setPosition(0, 70, 0)
local gui = F.playerGui:FindFirstChild("SimpleRecoveryUI")
local walkButton = M.findDescendantByName(gui, "Btn_WALKTOFORESTEGG")
walkButton.MouseButton1Click:Fire()
local guard = 0
while S.state().walking and guard < 4000 do guard = guard + 1; M.pump(0.02) end
check("new instance walks to the egg", F.root.Position.X > 290, F.root.Position.X)

S.setPulse(true); S.setFlyAfterPulse(true); S.setBiome("Snow")
M.setPosition(0, 70, 0); M.pump(2.5)
M.simulateRagdoll(6)
M.pump(0.6)
check("new instance flies after the pulse", S.flight().flying == true)
guard = 0
while S.flight().flying and guard < 6000 do guard = guard + 1; M.pump(0.02) end
check("new instance flight completes", S.flight().flying == false)
check("new instance flew toward Snow", F.root.Position.X > 1200, F.root.Position.X)

local closeButton = M.findDescendantByName(gui, "Btn_CLOSE")
closeButton.MouseButton1Click:Fire()
M.pump(0.5)
check("close removes the UI", F.playerGui:FindFirstChild("SimpleRecoveryUI") == nil)
check("close leaves no connections", M.aliveConnections() == 0, M.aliveConnections())
check("close clears the global", _G.SIMPLE_RECOVERY_UI == nil)
check("WalkSpeed restored after close", F.humanoid.WalkSpeed == 16, F.humanoid.WalkSpeed)
local errorsAfter = #M.errors
M.pump(1.0)
check("no uncaught errors", #M.errors == errorsAfter, M.errors[#M.errors])
print(string.format("RESULT checks=%d passed=%d failed=%d", total, passed, total - passed))
