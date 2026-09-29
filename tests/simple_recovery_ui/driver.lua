local M = MOCK
local F = M.fixture
local total, passed = 0, 0
local function check(name, cond, detail)
	total = total + 1
	if cond then passed = passed + 1; print(string.format("[PASS] %s", name))
	else print(string.format("[FAIL] %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or "")) end
end
local function has(text, needle) return string.find(tostring(text or ""), needle, 1, true) ~= nil end
local S = _G.SIMPLE_RECOVERY_UI
M.firstInstance = S
local function logEntry(fragment, from)
	for i = (from or 0) + 1, #S.log() do
		if has(S.log()[i].text, fragment) then return S.log()[i] end
	end
	return nil
end
local function waitFor(pred, limit)
	local g = 0
	while not pred() and g < (limit or 4000) do g = g + 1; M.pump(0.02) end
	return pred()
end

check("script exposes its API", type(S) == "table")
if type(S) ~= "table" then
	print(string.format("RESULT checks=%d passed=%d failed=%d", total, passed, total - passed)); return
end
M.pump(0.2)
local gui = F.playerGui:FindFirstChild("SimpleRecoveryUI")
check("UI is created", gui ~= nil)
check("pulse starts OFF", S.pulse().enabled == false)
check("auto fly starts ON", S.flight().autoFly == true)
check("flight biome defaults to Snow", S.flight().biome == "Snow", S.flight().biome)
check("target resolves to the Forest slot", S.target() and S.target().Uid == "Forest Egg Slot",
	S.target() and S.target().Uid)

local walkButton = M.findDescendantByName(gui, "Btn_WALKTOFORESTEGG")
local pickupButton = M.findDescendantByName(gui, "Btn_PICKUPEGG")
local pulseButton = M.findDescendantByName(gui, "Btn_RECOVERYPULSEOFF")
local flyButton = M.findDescendantByName(gui, "Btn_FLYNOW16s")
local flyAfterButton = M.findDescendantByName(gui, "Btn_AUTOFLYON")
local closeButton = M.findDescendantByName(gui, "Btn_CLOSE")
check("walk button exists", walkButton ~= nil)
check("pickup button exists", pickupButton ~= nil)
check("pulse button exists", pulseButton ~= nil)
check("fly button exists", flyButton ~= nil)
check("auto-fly button exists", flyAfterButton ~= nil)
check("close button exists", closeButton ~= nil)

M.writesArmed = true
M.violations = {}

--=========== walk ===========
M.setPosition(0, 70, 0)
walkButton.MouseButton1Click:Fire()
M.pump(0.3)
check("walking state set", S.state().walking == true)
check("Humanoid:MoveTo used", #M.moveToCalls >= 1)
check("MoveTo aimed at the forest egg",
	#M.moveToCalls >= 1 and math.abs(M.moveToCalls[1].position.X - 300) < 1)
check("WalkSpeed raised for the walk", F.humanoid.WalkSpeed > 16, F.humanoid.WalkSpeed)
check("arrives at the egg", waitFor(function() return S.state().walking == false end), S.status())
check("character moved to the egg", F.root.Position.X > 290, F.root.Position.X)
check("WalkSpeed restored after walking", F.humanoid.WalkSpeed == 16, F.humanoid.WalkSpeed)

--=========== pickup arms the pulse ===========
pickupButton.MouseButton1Click:Fire()
M.pump(0.3)
local carryCalls = M.remoteCallsFor("AskFieldEggCarry")
check("pickup uses the carry remote", #carryCalls >= 1, #carryCalls)
check("carry sends the forest uid",
	#carryCalls >= 1 and type(carryCalls[1].args[1]) == "table"
		and tostring(carryCalls[1].args[1].Uid) == "Forest Egg Slot")
check("proximity prompts fired", #M.promptFires >= 1)
check("hitbox touch fired", #M.touchFires >= 1)
check("pickup auto-armed the pulse", S.pulse().enabled == true)

--=========== pulse alone (auto-fly off) ===========
M.pump(3.2)
S.setFlyAfterPulse(false)
M.pump(0.2)
M.writes = {}
M.simulateRagdoll(6)
M.pump(1.2)
check("pulses fired while ragdolled", S.pulse().count >= 1, S.pulse().count)
check("no flight while auto-fly is OFF", S.flight().flying == false)
local pulseVelocityWrites = 0
for _, w in ipairs(M.writes) do
	if w.key == "AssemblyLinearVelocity" then pulseVelocityWrites = pulseVelocityWrites + 1 end
end
check("pulse alone writes no velocity", pulseVelocityWrites == 0, pulseVelocityWrites)
check("Motor6D restored by the pulse", M.allMotorsEnabled())
check("PlatformStand cleared by the pulse", F.humanoid.PlatformStand == false)
check("state driven back to Running",
	tostring(F.humanoid:GetState()) == "Enum.HumanoidStateType.Running")
check("states re-enabled via SetStateEnabled", #M.stateEnabled >= 3, #M.stateEnabled)
check("pulse log entry present", has(S.logText(), "pulse #1"))

M.endRagdoll(); M.pump(0.6)

--=========== pulse -> straight flight (grok formula) ===========
S.setFlyAfterPulse(true)
S.setBiome("Snow")
M.setPosition(0, 70, 0)
M.pump(2.5)
M.writes = {}
local originY = F.root.Position.Y
local flightMark = #S.log()

M.simulateRagdoll(6)
M.pump(0.6)

check("flight starts right after the pulse", S.flight().flying == true, tostring(S.flight().flying))
M.pump(0.3)
check("state stays Running while flying", tostring(F.humanoid:GetState()) == "Enum.HumanoidStateType.Running")
check("motors stay enabled while flying", M.allMotorsEnabled())
check("WalkSpeed forced to 500 while flying", F.humanoid.WalkSpeed == 500, F.humanoid.WalkSpeed)
check("angular velocity zeroed (no rollover)",
	F.root.AssemblyAngularVelocity.Magnitude < 0.001)
check("held part neutralised during flight",
	F.held.Massless == true and F.held.CanCollide == false)
local sawVelocityWrite = false
for _, w in ipairs(M.writes) do
	if w.key == "AssemblyLinearVelocity" and w.value.Magnitude > 1 then sawVelocityWrite = true end
end
check("flight drives with velocity", sawVelocityWrite)
check("flight ends on its own", waitFor(function() return S.flight().flying == false end))
check("flew straight toward the Snow egg", F.root.Position.X > 1200, F.root.Position.X)
check("straight path: height barely changed",
	math.abs(F.root.Position.Y - originY) < 3.0, F.root.Position.Y - originY)
check("WalkSpeed restored after the flight", F.humanoid.WalkSpeed == 16, F.humanoid.WalkSpeed)
check("held part restored after the flight",
	F.held.CanCollide == true and F.held.Massless == false)
check("velocity zeroed at the end", F.root.AssemblyLinearVelocity.Magnitude < 0.001)
local startLine, endLine = logEntry("flight started to Snow", flightMark), nil
for i = flightMark + 1, #S.log() do
	local e = S.log()[i]
	if has(e.text, "flight ") and has(e.text, "flew") then endLine = e end
end
check("flight start logged", startLine ~= nil)
check("flight end logged with distance", endLine ~= nil, S.logText())
check("flight duration about 1.6s",
	startLine and endLine and math.abs((endLine.t - startLine.t) - 1.6) <= 0.3,
	startLine and endLine and (endLine.t - startLine.t))

--=========== grok targeting: Cosmic (snapshot only) ===========
M.setExtra(F.snapshotRemote, "invokeResponder", function()
	return { Records = {
		{ Uid = "cosmic-1", AreaId = "Cosmic", AssetCategory = "Egg",
			BoundsCFrame = { Position = Vector3.new(9000, 60, 9000), __typename = "CFrame" },
			__typename = "table" },
		{ Uid = "snow-9", AreaId = "Snow", AssetCategory = "Egg",
			BoundsCFrame = { Position = Vector3.new(1500, 66, 0), __typename = "CFrame" },
			__typename = "table" },
	} }
end)

local diagnose = S.diagnose()
check("diagnose sees the snapshot records", diagnose.snapshotRecords == 2, tostring(diagnose.snapshotRecords))
check("diagnose lists Cosmic", (function()
	for _, name in ipairs(diagnose.snapshotBiomes) do if name == "Cosmic" then return true end end
	return false
end)(), table.concat(diagnose.snapshotBiomes, ","))

S.setBiome("Cosmic")
M.clearRagdoll(); M.pump(0.3)
M.setPosition(0, 70, 0)
M.pump(2.5)
local cosmicMark = #S.log()
flyButton.MouseButton1Click:Fire()
M.pump(0.3)
check("Cosmic flight starts from the snapshot target", S.flight().flying == true,
	tostring(S.flight().flying))
local g = 0
while S.flight().flying and g < 6000 do g = g + 1; M.pump(0.02) end
local gapToCosmic = math.sqrt((F.root.Position.X - 9000)^2 + (F.root.Position.Z - 9000)^2)
check("flew all the way to Cosmic", gapToCosmic < 150, gapToCosmic)
local cosmicLine = logEntry("flight started to Cosmic", cosmicMark)
check("Cosmic flight logged the snapshot as the source",
	cosmicLine ~= nil and has(cosmicLine.text, "server snapshot"),
	cosmicLine and cosmicLine.text)
check("Cosmic flight used a scaled clamp above grok's 1125",
	cosmicLine ~= nil and tonumber(string.match(cosmicLine.text, "clamp (%d+)")) > 1125,
	cosmicLine and cosmicLine.text)

--=========== missing biome explains itself ===========
M.setExtra(F.snapshotRemote, "invokeResponder", function() return { Records = {} } end)
S.setBiome("Titan")
M.pump(2.5)
check("no flight when the biome is nowhere", S.fly("test") == false)
check("status names the biome and the snapshot count",
	has(S.status(), "No Titan target") and has(S.status(), "snapshot:"), S.status())
S.setBiome("Snow")
M.pump(0.5)

--=========== manual FLY NOW ===========
M.clearRagdoll(); M.pump(0.5)
M.setPosition(0, 70, 0)
M.pump(2.5)
check("nothing flying before the manual test", S.flight().flying == false)
local manualMark = #S.log()
flyButton.MouseButton1Click:Fire()
M.pump(0.2)
check("manual flight starts", S.flight().flying == true)
check("manual flight ends", waitFor(function() return S.flight().flying == false end))
local mStart = logEntry("flight started to", manualMark)
local mEnd = nil
for i = manualMark + 1, #S.log() do
	local e = S.log()[i]
	if has(e.text, "flight ") and has(e.text, "flew") then mEnd = e end
end
check("manual flight lasted about 1.6s",
	mStart and mEnd and math.abs((mEnd.t - mStart.t) - 1.6) <= 0.3,
	mStart and mEnd and (mEnd.t - mStart.t))

--=========== pulse OFF ===========
local countBefore = S.pulse().count
pulseButton.MouseButton1Click:Fire()
M.pump(0.2)
check("pulse turned OFF", S.pulse().enabled == false)
M.simulateRagdoll(8)
M.pump(1.5)
check("no pulses while OFF", S.pulse().count == countBefore,
	string.format("%d -> %d", countBefore, S.pulse().count))
M.endRagdoll(); M.pump(0.3)

--=========== safety ===========
M.writesArmed = false
check("no forbidden writes (CFrame/Position/Anchored) all session",
	#M.violations == 0, M.violationText())
check("no runtime errors inside any callback", #M.errors == 0, M.errors[1])
check("never calls the drop remote", #M.remoteCallsFor("AskFieldEggDrop") == 0)
M.firstConnectionCount = M.aliveConnections()
print(string.format("RESULT checks=%d passed=%d failed=%d", total, passed, total - passed))
