local M = MOCK
local F = M.fixture
local S = _G.SIMPLE_RECOVERY_UI
M.pump(0.2)
local gui = F.playerGui:FindFirstChild("SimpleRecoveryUI")
local fly = M.findDescendantByName(gui, "Btn_FLYNOW16s")

-- the snapshot is the only place a distant biome exists (like the real game)
M.setExtra(F.snapshotRemote, "invokeResponder", function()
	return { Records = {
		{ Uid="cosmic-1", AreaId="Cosmic", AssetCategory="Egg",
			BoundsCFrame = { Position = Vector3.new(9000, 60, 9000), __typename="CFrame" }, __typename="table" },
		{ Uid="snow-1", AreaId="Snow", AssetCategory="Egg",
			BoundsCFrame = { Position = Vector3.new(1500, 66, 0), __typename="CFrame" }, __typename="table" },
	} }
end)

local d = S.diagnose()
print(string.format("snapshot: %d record(s), biomes: %s", d.snapshotRecords, table.concat(d.snapshotBiomes, ", ")))

S.setBiome("Cosmic")
M.clearRagdoll(); M.pump(0.3)
M.setPosition(0, 70, 0); M.pump(2.5)

local mark = #S.log()
fly.MouseButton1Click:Fire()
local g = 0
while S.flight().flying and g < 6000 do g = g + 1 M.pump(0.02) end

print("")
print("===== COSMIC FLIGHT LOG =====")
for i = mark + 1, #S.log() do
	local e = S.log()[i]
	print(string.format("[%6.2fs] %s", e.t, e.text))
end
print("=============================")
local gap = math.sqrt((F.root.Position.X - 9000)^2 + (F.root.Position.Z - 9000)^2)
print(string.format("landed %.0f studs from the Cosmic egg | height change %.2f studs",
	gap, F.root.Position.Y - 70))
print("STATUS: " .. S.status())

-- and what happens when a biome is not in the snapshot at all
M.setExtra(F.snapshotRemote, "invokeResponder", function() return { Records = {} } end)
S.setBiome("Titan")
M.pump(2.5)
S.fly("test")
print("")
print("NO-TARGET STATUS: " .. S.status())
