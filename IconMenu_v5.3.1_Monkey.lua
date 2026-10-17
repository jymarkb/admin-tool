--[[
============================================================
  ICON MENU v5.3.1 — MONKEY CHARM SLOT AUTO BUY
============================================================

  CHANGES
  - NEW: MONKEY tab (third tab)
  - MONKEY macro uses MAIN slots, starts instantly, loops route only
  - MONKEY: no Stage TP, no Win/Spawn wait, no portal unstick delay
  - OTHERS tab renamed to KEYBOARD
  - Small X button clears a specific saved macro slot
  - CLEAR ALL clears every saved macro slot
  - Saved route modes now cycle Fly / Teleport / Walk / Jump
  - Win-to-next-cycle delay is controlled by a slider
  - Auto Buy rarity is a multi-select dropdown
  - Rebindable key toggles the menu open / closed
  - COPY / PASTE supports Fly, Teleport, Walk and Jump route modes
  - Existing Fly Hold, NoClip and route behavior preserved (God Mode removed)
  - MAIN On Death toggle: continue macro after respawn
  - Slot deck shows 3 rows; SLOT DATA / EDIT is scrollable
  - MAIN macro is now generic: saved F / T / W / J route only (NO Stage TP / Win check)
  - KEYBOARD gets GAME MACRO: Stage TP -> route -> Win/Spawn retry flow
  - Auto Buy now supports Common through Exotic with requested defaults
  - Walk route EXP fix: continuously feeds Humanoid:Move while walking
  - Auto Buy uses slot keys Common/Uncommon/Rare/Mysterious only
  - BUY_COOLDOWN = 120s
  - Jump route mode: FAR ballistic jump-to-location (distance-scaled launch B→C)
============================================================
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
if not player then
	return
end

warn("[Icon Menu v5.2.2] starting")

-- ============================================================
-- SETTINGS
-- ============================================================

local MAX_SLOTS = 100
local START_SLOTS = 1

-- Jump
local superJumpEnabled = false
local jumpPower = 100
local originalJump = 50

-- Speed
local speedEnabled = false
local walkSpeed = 20
local originalSpeed = 16

-- Fly
local flyEnabled = false
local flySpeed = 50

local flying = false
local flyBody = nil
local flyGyro = nil
local flyConns = {}

-- Fly Hold
local flyHoldEnabled = false
local flyHoldKey = Enum.KeyCode.F
local flyHoldDown = false
local rebindingFly = false

-- Menu toggle key
local menuToggleKey = Enum.KeyCode.RightShift
local rebindingMenu = false
local guiOpen = true -- v5.2.1: show menu immediately after execution

-- NoClip
local noclipEnabled = false
local noclipConn = nil
local noclipOriginal = {}

-- Continue macro after death (MAIN / KEYBOARD)
local continueOnDeath = false

-- Saved route
local savedPositions = {}
local savedModes = {}

local slotCount = START_SLOTS
local nextSetMode = "Fly" -- cycles: Fly → Teleport → Walk → Jump

-- Macro
local macroRunning = false
local macroCurrentCycle = 0
local macroLoopCount = 0
local macroMode = nil -- "MAIN", "KEYBOARD", or "MONKEY"

local macroFlyTimeout = 18
local macroWalkTimeout = 25
local macroJumpTimeout = 25
local macroArriveDist = 7
local macroCycleDelay = 2 -- adjustable 0-10s slider
local macroTeleportPause = 0.25 -- pause between consecutive Teleport slots

-- Jump-to-location: far controlled jump that ends + stops on the saved point

-- Final saved slot / win-portal finish
-- After last slot: wait for WIN or SPAWN (no win).
-- If stuck at the portal (still near last slot, no win/spawn), fire 2 normal jumps.
local jumpAfterLastSlot = true -- enable portal unstick (2 jumps when stuck)
local portalStuckSeconds = 2.0 -- how long near portal with no win before unstick jumps
local portalStuckDist = 14 -- studs from last-slot position counts as "still at portal"
local portalUnstickMax = 2 -- max times to try the 2-jump unstick per cycle

local autopilotActive = false

-- Stage
local selectedStage = 1

-- Buy
local selectedRarities = {
	Common = true,
	Uncommon = true,
	Rare = true,
	Mysterious = true, -- 4th rotating slot (display may be Epic/Legendary/etc.)
}
local autoBuy = false
local lastBuyCycle = 0

local BUY_COOLDOWN = 120 -- buy interval

-- Monkey auto-buy charms (BuyCharm slot index 1/2/3)
-- Scanner proved: BuyCharm:FireServer(slotNumber)
-- Rarity is read live from ItemShop.Options.ItemN.Rarity
local monkeyAutoBuy = false
local monkeyBuyCooldown = 10 -- re-check often; shop restocks ~every 5 min
local lastMonkeyBuy = 0
local monkeyCharmRarities = {
	Rare = true,
	Epic = true,
	Legendary = true,
	Mythic = true,
}

-- ============================================================
-- FORWARD REFERENCES
-- ============================================================

local setStatus = function() end
local refreshMacroBtn = function() end
local refreshKeyboardMacroBtn = function() end
local refreshMonkeyMacroBtn = function() end
local refreshSetBtn = function() end
local refreshNextModeBtn = function() end
local refreshFlyBindLabel = function() end
local refreshMenuBindLabel = function() end
local refreshChip = function() end
local pulseChip = function() end

local makeChip

-- GUI references used later
local loopBox
local keyboardLoopBox
local keyboardMacroBtn
local monkeyLoopBox
local monkeyMacroBtn
local slotDataBox

-- ============================================================
-- CHARACTER HELPERS
-- ============================================================

local function getCharacter()
	return player.Character
end

local function getHumanoid()
	local char = getCharacter()

	if not char then
		return nil
	end

	return char:FindFirstChildOfClass("Humanoid")
end

local function getHRP()
	local char = getCharacter()

	if not char then
		return nil
	end

	return char:FindFirstChild("HumanoidRootPart")
end

-- ============================================================
-- SPAWN DETECTION
-- ============================================================

local function getLobbySpawn()

	local world =
		workspace:FindFirstChild("WORLD 2")

	if not world then
		return nil
	end

	local lobby =
		world:FindFirstChild("Lobby")

	if not lobby then
		return nil
	end

	local spawn =
		lobby:FindFirstChild("SpawnLocation")

	if spawn and spawn:IsA("BasePart") then
		return spawn
	end

	return nil
end


local function isCharacterOnLobbySpawn()

	local hrp = getHRP()
	local spawn = getLobbySpawn()

	if not hrp or not spawn then
		return false
	end

	-- Convert HRP position into SpawnLocation local space.
	local localPos =
		spawn.CFrame:PointToObjectSpace(
			hrp.Position
		)

	local halfSize =
		spawn.Size * 0.5

	-- Extra tolerance because HRP is normally several
	-- studs above the SpawnLocation surface.
	local horizontalMargin = 6
	local verticalMargin = 12

	local insideX =
		math.abs(localPos.X) <=
		halfSize.X + horizontalMargin

	local insideZ =
		math.abs(localPos.Z) <=
		halfSize.Z + horizontalMargin

	local insideY =
		math.abs(localPos.Y) <=
		halfSize.Y + verticalMargin

	return insideX and insideZ and insideY
end

local function getWins()
	local leaderstats = player:FindFirstChild("leaderstats")

	if not leaderstats then
		return 0
	end

	local wins = leaderstats:FindFirstChild("Wins")

	if not wins then
		return 0
	end

	local value = tonumber(wins.Value)

	return value or 0
end

-- ============================================================
-- SPEED
-- ============================================================

local function releaseSpeed()
	local humanoid = getHumanoid()

	if humanoid then
		humanoid.WalkSpeed = originalSpeed
	end
end

local function bindSpeedWatcher(char)
	local humanoid = char:WaitForChild("Humanoid", 5)

	if not humanoid then
		return
	end

	humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()

		if not speedEnabled then
			return
		end

		if humanoid.WalkSpeed ~= walkSpeed then
			humanoid.WalkSpeed = walkSpeed
		end

	end)
end

RunService.Stepped:Connect(function()

	local humanoid = getHumanoid()

	if not humanoid then
		return
	end

	if speedEnabled then
		if humanoid.WalkSpeed ~= walkSpeed then
			humanoid.WalkSpeed = walkSpeed
		end
	end

	if superJumpEnabled then

		if not humanoid.UseJumpPower then
			humanoid.UseJumpPower = true
		end

		if humanoid.JumpPower ~= jumpPower then
			humanoid.JumpPower = jumpPower
		end

	end

end)

-- ============================================================
-- JUMP
-- ============================================================

local function applyJump()

	local humanoid = getHumanoid()

	if not humanoid then
		return
	end

	if superJumpEnabled then

		humanoid.UseJumpPower = true
		humanoid.JumpPower = jumpPower

	else

		humanoid.JumpPower = originalJump

	end

end

-- ============================================================
-- NOCLIP
-- ============================================================

local function restoreNoclip()

	for part, originalValue in pairs(noclipOriginal) do

		if part and part.Parent then
			pcall(function()
				part.CanCollide = originalValue
			end)
		end

	end

	table.clear(noclipOriginal)

end

local function applyNoclip()

	if noclipConn then
		noclipConn:Disconnect()
		noclipConn = nil
	end

	if not noclipEnabled then

		restoreNoclip()

		return
	end

	noclipConn = RunService.Stepped:Connect(function()

		local char = getCharacter()

		if not char then
			return
		end

		for _, part in ipairs(char:GetDescendants()) do

			if part:IsA("BasePart") then

				if noclipOriginal[part] == nil then
					noclipOriginal[part] = part.CanCollide
				end

				part.CanCollide = false

			end

		end

	end)

end

-- ============================================================
-- FLY
-- ============================================================

local function stopFly()

	flying = false

	local humanoid = getHumanoid()

	if humanoid then
		humanoid.PlatformStand = false
	end

	if flyBody then
		flyBody:Destroy()
		flyBody = nil
	end

	if flyGyro then
		flyGyro:Destroy()
		flyGyro = nil
	end

	for _, connection in ipairs(flyConns) do
		connection:Disconnect()
	end

	table.clear(flyConns)

end

local function startFly()

	if flying then
		return
	end

	local hrp = getHRP()
	local humanoid = getHumanoid()

	if not hrp or not humanoid then
		return
	end

	flying = true

	humanoid.PlatformStand = true

	-- Velocity
	flyBody = Instance.new("BodyVelocity")

	flyBody.Name = "IconMenuFlyVelocity"

	flyBody.MaxForce = Vector3.new(
		math.huge,
		math.huge,
		math.huge
	)

	flyBody.Velocity = Vector3.zero
	flyBody.Parent = hrp

	-- Rotation
	flyGyro = Instance.new("BodyGyro")

	flyGyro.Name = "IconMenuFlyGyro"

	flyGyro.MaxTorque = Vector3.new(
		math.huge,
		math.huge,
		math.huge
	)

	flyGyro.P = 10000
	flyGyro.Parent = hrp

	local up = 0
	local down = 0

	table.insert(
		flyConns,

		UserInputService.InputBegan:Connect(function(input, gpe)

			if gpe or rebindingFly then
				return
			end

			if input.KeyCode == Enum.KeyCode.Space then
				up = 1
			end

			if input.KeyCode == Enum.KeyCode.LeftControl then
				down = 1
			end

		end)
	)

	table.insert(
		flyConns,

		UserInputService.InputEnded:Connect(function(input)

			if input.KeyCode == Enum.KeyCode.Space then
				up = 0
			end

			if input.KeyCode == Enum.KeyCode.LeftControl then
				down = 0
			end

		end)
	)

	table.insert(
		flyConns,

		RunService.RenderStepped:Connect(function()

			if not flying then
				return
			end

			if not hrp.Parent then
				return
			end

			if not flyBody then
				return
			end

			-- Macro owns the velocity while autopilot is active.
			if autopilotActive then
				return
			end

			local move =
				humanoid.MoveDirection +
				Vector3.new(0, up - down, 0)

			if move.Magnitude > 0 then

				flyBody.Velocity =
					move.Unit * flySpeed

			else

				flyBody.Velocity =
					Vector3.zero

			end

			if flyGyro and workspace.CurrentCamera then
				flyGyro.CFrame =
					workspace.CurrentCamera.CFrame
			end

		end)
	)

end

local function updateFly()

	local wanted =
		flyEnabled or
		(flyHoldEnabled and flyHoldDown)

	if wanted and not flying then

		startFly()

	elseif not wanted and flying and not autopilotActive then

		stopFly()

	end

end

-- ============================================================
-- SLOT SYSTEM
-- ============================================================

local function saveToSlot(slot)

	local hrp = getHRP()

	if not hrp then
		return false
	end

	if slot < 1 or slot > slotCount then
		return false
	end

	savedPositions[slot] = hrp.Position
	savedModes[slot] = nextSetMode

	return true

end

local function countSaved()

	local count = 0

	for i = 1, slotCount do

		if savedPositions[i] then
			count += 1
		end

	end

	return count

end

-- ============================================================
-- FINAL SLOT HELPERS
-- ============================================================

local function getLastSavedSlot()

	for i = slotCount, 1, -1 do

		if savedPositions[i] then
			return i
		end

	end

	return nil

end

local function jumpCharacter()

	local humanoid = getHumanoid()

	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	-- Roblox-side equivalent of a normal Space/jump request.
	-- No intentional delay is added here.
	humanoid.Jump = true

	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end)

	return true

end

-- ============================================================
-- SLOT COPY / PASTE DATA
-- ============================================================

local function normalizeMode(mode)

	mode = tostring(mode or "")
	mode = string.lower(mode)

	if mode == "t" or mode == "tp" or mode == "teleport" then
		return "Teleport"
	end

	if mode == "w" or mode == "walk" or mode == "run" or mode == "walk/run" then
		return "Walk"
	end

	if mode == "j" or mode == "jump" or mode == "jump to" or mode == "jumpto" then
		return "Jump"
	end

	return "Fly"

end

local function serializeSlots()

	local output = {}

	for i = 1, slotCount do

		local pos = savedPositions[i]

		if pos then

			local mode = savedModes[i] or "Fly"

			table.insert(
				output,
				string.format(
					"%d|%.3f|%.3f|%.3f|%s",
					i,
					pos.X,
					pos.Y,
					pos.Z,
					mode
				)
			)

		end

	end

	return table.concat(output, "\n")

end

local function parseSlotData(text)

	if type(text) ~= "string" then
		return 0, 0
	end

	-- Also allow semicolon-separated old copies.
	text = text:gsub(";", "\n")

	local imported = 0
	local highestSlot = 0

	for line in text:gmatch("[^\r\n]+") do

		local slotText, xText, yText, zText, modeText =
			line:match(
				"^%s*(%d+)%s*|%s*([^|]+)%s*|%s*([^|]+)%s*|%s*([^|]+)%s*|%s*([^|]+)%s*$"
			)

		if slotText and xText and yText and zText then

			local slot = tonumber(slotText)
			local x = tonumber(xText)
			local y = tonumber(yText)
			local z = tonumber(zText)

			if slot and x and y and z then

				slot = math.floor(slot)

				if slot >= 1 and slot <= MAX_SLOTS then

					savedPositions[slot] =
						Vector3.new(x, y, z)

					savedModes[slot] =
						normalizeMode(modeText)

					imported += 1

					if slot > highestSlot then
						highestSlot = slot
					end

				end

			end

		end

	end

	return imported, highestSlot

end

local function trySetClipboard(text)

	if type(setclipboard) == "function" then

		local ok = pcall(function()
			setclipboard(text)
		end)

		if ok then
			return true
		end

	end

	if type(toclipboard) == "function" then

		local ok = pcall(function()
			toclipboard(text)
		end)

		if ok then
			return true
		end

	end

	return false

end

local function tryGetClipboard()

	if type(getclipboard) == "function" then

		local ok, value = pcall(function()
			return getclipboard()
		end)

		if ok and type(value) == "string" then
			return value
		end

	end

	if type(get_clipboard) == "function" then

		local ok, value = pcall(function()
			return get_clipboard()
		end)

		if ok and type(value) == "string" then
			return value
		end

	end

	return nil

end

-- ============================================================
-- TRAVEL
-- ============================================================

local function flyToPosition(target, timeout)

	local hrp = getHRP()
	local humanoid = getHumanoid()

	if not hrp or not humanoid then
		return false
	end

	local wasFlying = flying

	if not flying then
		startFly()
	end

	if not flyBody or not flyBody.Parent then
		return false
	end

	autopilotActive = true

	local startTime = os.clock()
	local arrived = false
	local startedByMacro = macroRunning

	while autopilotActive and (macroRunning or not startedByMacro) do

		task.wait()

		hrp = getHRP()
		humanoid = getHumanoid()

		if not hrp or not humanoid then
			break
		end

		if not flyBody or not flyBody.Parent then
			break
		end

		if humanoid.Health <= 0 then
			break
		end

		local currentPosition = hrp.Position
		local delta = target - currentPosition
		local distance = delta.Magnitude

		if distance <= macroArriveDist then
			arrived = true
			break
		end

		if os.clock() - startTime > (timeout or macroFlyTimeout) then
			break
		end

		if distance > 0.001 then

			local direction = delta.Unit

			-- Full speed until ~50 studs, then soft slowdown
			local speed = flySpeed
			if distance < 50 then
				-- Linear slowdown from flySpeed → ~12
				speed = math.max(distance * (flySpeed / 50), 12)
				speed = math.min(speed, flySpeed)
			end

			-- Velocity aims at the full 3D target (can go up/diagonally).
			flyBody.Velocity = direction * speed

			-- Orientation uses horizontal yaw only so pure/steep upward
			-- targets do not pitch the character to a 90° upright face-plant.
			local horizontal = Vector3.new(direction.X, 0, direction.Z)
			if horizontal.Magnitude > 0.05 then
				humanoid:Move(horizontal.Unit, false)
				if flyGyro then
					flyGyro.CFrame = CFrame.lookAt(
						currentPosition,
						currentPosition + horizontal.Unit
					)
				end
			else
				-- Almost pure vertical: keep current yaw, still move upward.
				humanoid:Move(Vector3.zero, false)
				if flyGyro then
					local look = hrp.CFrame.LookVector
					local flatLook = Vector3.new(look.X, 0, look.Z)
					if flatLook.Magnitude > 0.05 then
						flyGyro.CFrame = CFrame.lookAt(
							currentPosition,
							currentPosition + flatLook.Unit
						)
					end
				end
			end

		end

	end

	if flyBody and flyBody.Parent then
		flyBody.Velocity = Vector3.zero
	end

	if humanoid then
		humanoid:Move(Vector3.zero)
	end

	autopilotActive = false

	if
		not wasFlying
		and flying
		and not flyEnabled
		and not (flyHoldEnabled and flyHoldDown)
	then
		stopFly()
	end

	return arrived

end

local function teleportToPosition(position)

	local hrp = getHRP()

	if not hrp then
		return false
	end

	hrp.CFrame = CFrame.new(position)

	return true

end

-- Face character toward a horizontal world direction (Y locked).
local function faceHorizontalDirection(hrp, direction)
	if not hrp or not direction then
		return
	end

	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.05 then
		return
	end

	flat = flat.Unit
	local pos = hrp.Position
	hrp.CFrame = CFrame.lookAt(pos, pos + flat)
end

local function walkToPosition(target, timeout)

	local hrp = getHRP()
	local humanoid = getHumanoid()

	if not hrp or not humanoid then
		return false
	end

	local startTime = os.clock()
	local arrived = false
	local startedByMacro = macroRunning

	-- EXP / run-state fix:
	-- Many games award walk XP only when Humanoid.MoveDirection is non-zero
	-- (real movement intent). Continuously feed Humanoid:Move every physics
	-- step AND every heartbeat so the server keeps seeing "walking".
	-- Do NOT hard-set HRP.CFrame while walking — that cancels locomotion state.
	local previousAutoRotate = humanoid.AutoRotate
	humanoid.AutoRotate = true

	local walkDir = Vector3.zero
	local walkActive = true

	local moveConn = RunService.Heartbeat:Connect(function()
		if not walkActive then
			return
		end

		local hum = getHumanoid()
		if not hum or hum.Health <= 0 then
			return
		end

		if walkDir.Magnitude > 0.001 then
			-- Continuous movement intent → MoveDirection stays active → XP ticks.
			hum:Move(walkDir, false)
		end
	end)

	while macroRunning or not startedByMacro do

		RunService.Stepped:Wait()

		hrp = getHRP()
		humanoid = getHumanoid()

		if not hrp or not humanoid or humanoid.Health <= 0 then
			break
		end

		local delta = target - hrp.Position
		local horizontalDelta = Vector3.new(delta.X, 0, delta.Z)
		local horizontalDistance = horizontalDelta.Magnitude

		if horizontalDistance <= macroArriveDist then
			arrived = true
			break
		end

		if os.clock() - startTime > (timeout or macroWalkTimeout) then
			break
		end

		if horizontalDistance > 0.001 then

			local direction = horizontalDelta.Unit
			walkDir = direction

			-- Primary physics-step movement intent (EXP-sensitive).
			humanoid:Move(direction, false)
			humanoid.AutoRotate = true

			-- Soft face without rewriting CFrame every frame (preserves walk state).
			-- AutoRotate handles most facing; only nudge if nearly sideways.
			local look = hrp.CFrame.LookVector
			local flatLook = Vector3.new(look.X, 0, look.Z)
			if flatLook.Magnitude > 0.05 then
				local dot = flatLook.Unit:Dot(direction)
				if dot < 0.5 then
					faceHorizontalDirection(hrp, direction)
				end
			else
				faceHorizontalDirection(hrp, direction)
			end

			-- Travel at the character's live WalkSpeed (picks up speed upgrades).
			local currentRunSpeed = math.max(tonumber(humanoid.WalkSpeed) or 0, 0)

			if currentRunSpeed > 0 then
				local currentVelocity = hrp.AssemblyLinearVelocity
				local desiredHorizontal = direction * currentRunSpeed

				hrp.AssemblyLinearVelocity = Vector3.new(
					desiredHorizontal.X,
					currentVelocity.Y,
					desiredHorizontal.Z
				)
			end

		else
			walkDir = Vector3.zero
		end

	end

	walkActive = false
	walkDir = Vector3.zero

	if moveConn then
		moveConn:Disconnect()
		moveConn = nil
	end

	humanoid = getHumanoid()
	if humanoid then
		humanoid:Move(Vector3.zero, false)
		pcall(function()
			humanoid.AutoRotate = previousAutoRotate
		end)
	end

	-- Stop only the horizontal macro push while preserving vertical motion.
	local finalHRP = getHRP()
	if finalHRP then
		local finalVelocity = finalHRP.AssemblyLinearVelocity
		finalHRP.AssemblyLinearVelocity = Vector3.new(0, finalVelocity.Y, 0)
	end

	return arrived

end

-- Jump-to-location (controlled far jump that STOPS on the saved point):
-- Example: Walk A→B, then Jump B→C.
-- Character is launched hard toward C, steered in air, then SNAP + hard-stop
-- on the exact saved C coordinates so the route ends on the set location.
local function jumpToPosition(target, timeout)

	local hrp = getHRP()
	local humanoid = getHumanoid()

	if not hrp or not humanoid then
		return false
	end

	if humanoid.Health <= 0 then
		return false
	end

	local startTime = os.clock()
	local arrived = false
	local startedByMacro = macroRunning

	local gravity = workspace.Gravity
	if typeof(gravity) ~= "number" or gravity < 1 then
		gravity = 196.2
	end

	local function distanceToTarget(pos)
		return (target - pos).Magnitude
	end

	local function horizontalToTarget(pos)
		local d = target - pos
		return Vector3.new(d.X, 0, d.Z)
	end

	-- Strong initial launch toward the exact target (far jump, not normal hop).
	local function applyLaunch(fromPos)
		local horiz = horizontalToTarget(fromPos)
		local horizDist = horiz.Magnitude
		local heightDiff = target.Y - fromPos.Y
		local dir = horizDist > 0.001 and horiz.Unit or Vector3.new(0, 0, 0)

		local flightTime = math.clamp(horizDist / 70, 0.6, 3.0)

		local upSpeed = (heightDiff + 0.5 * gravity * flightTime * flightTime) / math.max(flightTime, 0.05)
		upSpeed = math.clamp(upSpeed, 50, 160)

		local horizSpeed = horizDist / math.max(flightTime, 0.05)
		horizSpeed = math.clamp(horizSpeed, 50, 280)

		if horizDist > 25 then
			horizSpeed = math.max(horizSpeed, 90)
			upSpeed = math.max(upSpeed, 70)
		end
		if horizDist > 60 then
			horizSpeed = math.max(horizSpeed, 140)
			upSpeed = math.max(upSpeed, 95)
		end

		return dir * horizSpeed + Vector3.new(0, upSpeed, 0)
	end

	-- Face jump direction, enter jump state, then hard launch toward C.
	local h0 = horizontalToTarget(hrp.Position)
	local lastFaceDir = h0.Magnitude > 0.001 and h0.Unit or Vector3.new(0, 0, -1)
	faceHorizontalDirection(hrp, lastFaceDir)
	if h0.Magnitude > 0.001 then
		humanoid:Move(h0.Unit, false)
	end
	jumpCharacter()
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end)
	hrp.AssemblyLinearVelocity = applyLaunch(hrp.Position)

	local snapDist = math.max(macroArriveDist, 10)

	local function snapAndStop(faceDir)
		hrp = getHRP()
		humanoid = getHumanoid()
		if not hrp then
			return
		end

		local look = faceDir
		if not look or look.Magnitude < 0.05 then
			look = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
		end
		if look.Magnitude < 0.05 then
			look = Vector3.new(0, 0, -1)
		else
			look = look.Unit
		end

		hrp.CFrame = CFrame.lookAt(target, target + look)
		hrp.AssemblyLinearVelocity = Vector3.zero
		if humanoid then
			humanoid:Move(Vector3.zero, false)
		end
	end

	while macroRunning or not startedByMacro do

		RunService.Stepped:Wait()

		hrp = getHRP()
		humanoid = getHumanoid()

		if not hrp or not humanoid or humanoid.Health <= 0 then
			break
		end

		local pos = hrp.Position
		local dist = distanceToTarget(pos)
		local horiz = horizontalToTarget(pos)
		local horizDist = horiz.Magnitude

		-- Close enough → snap to EXACT saved location, face approach dir, hard-stop.
		if dist <= snapDist or horizDist <= snapDist then
			if horizDist > 0.05 then
				lastFaceDir = horiz.Unit
			end
			snapAndStop(lastFaceDir)
			arrived = true
			break
		end

		if os.clock() - startTime > (timeout or macroJumpTimeout) then
			snapAndStop(lastFaceDir)
			arrived = true
			break
		end

		-- Steer horizontally only — no second jump / no mid-air Jumping state.
		if horizDist > 0.001 then
			local dir = horiz.Unit
			lastFaceDir = dir

			-- Face the jump travel direction while airborne.
			faceHorizontalDirection(hrp, dir)

			humanoid:Move(dir, false)

			local vel = hrp.AssemblyLinearVelocity
			local desiredHorizSpeed = math.clamp(horizDist * 2.2, 60, 260)

			hrp.AssemblyLinearVelocity = Vector3.new(
				dir.X * desiredHorizSpeed,
				vel.Y, -- keep original launch vertical arc only
				dir.Z * desiredHorizSpeed
			)
		end

	end

	-- Final hard stop on the exact set location (facing last travel dir).
	snapAndStop(lastFaceDir)

	return arrived

end

local function travelToSlot(slot)

	local position = savedPositions[slot]

	if not position then
		return false
	end

	local mode = savedModes[slot] or "Fly"

	if mode == "Teleport" then

		setStatus("TP → SLOT " .. slot)
		return teleportToPosition(position)

	elseif mode == "Walk" then

		setStatus("WALK → SLOT " .. slot)
		return walkToPosition(position, macroWalkTimeout)

	elseif mode == "Jump" then

		setStatus("JUMP → SLOT " .. slot)
		return jumpToPosition(position, macroJumpTimeout)

	else

		setStatus("FLY → SLOT " .. slot)
		return flyToPosition(position, macroFlyTimeout)

	end

end

-- ============================================================
-- REMOTE HELPERS
-- ============================================================

local function fireRemote(remote, ...)

	if not remote then
		return false
	end

	local args = table.pack(...)

	if remote:IsA("RemoteEvent") then

		local ok = pcall(function()
			remote:FireServer(
				table.unpack(args, 1, args.n)
			)
		end)

		return ok

	end

	if remote:IsA("RemoteFunction") then

		local ok = pcall(function()
			remote:InvokeServer(
				table.unpack(args, 1, args.n)
			)
		end)

		return ok

	end

	return false

end

local function getStageRemote()

	local remotes =
		ReplicatedStorage:FindFirstChild("Remotes")

	if not remotes then
		return nil
	end

	return remotes:FindFirstChild(
		"RequestCheckpointTp"
	)

end

local function getBuyRemote()

	local packages =
		ReplicatedStorage:FindFirstChild("Packages")

	if not packages then
		return nil
	end

	local remo =
		packages:FindFirstChild("remo")

	if not remo then
		return nil
	end

	local container =
		remo:FindFirstChild("container")

	if not container then
		return nil
	end

	return container:FindFirstChild("BuyWins")

end


local function getBuyCharmRemote()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		return nil
	end
	return remotes:FindFirstChild("BuyCharm")
end

local function doStageTeleport()

	local remote = getStageRemote()

	if not remote then

		setStatus("STAGE TP REMOTE MISSING")

		return false

	end

	local success =
		fireRemote(
			remote,
			selectedStage,
			"wins"
		)

	if success then

		setStatus(
			"STAGE TP → " ..
			selectedStage
		)

	else

		setStatus("STAGE TP FAILED")

	end

	return success

end

-- ============================================================
-- MACRO
-- ============================================================

local function macroWait(seconds)

	local finish =
		os.clock() + seconds

	while macroRunning and os.clock() < finish do
		task.wait(0.1)
	end

	return macroRunning

end

-- Wait until character is alive again (used when Continue on Death is ON).
local function waitUntilAlive()
	setStatus("WAITING RESPAWN...")

	while macroRunning do
		local humanoid = getHumanoid()
		local hrp = getHRP()

		if humanoid and hrp and humanoid.Health > 0 then
			-- Brief stabilize after respawn.
			task.wait(0.6)
			return true
		end

		task.wait(0.15)
	end

	return false
end

-- Returns false if macro should abort; true if it is safe to continue.
local function ensureAliveOrHandleDeath()
	local humanoid = getHumanoid()

	if humanoid and humanoid.Health > 0 then
		return true
	end

	if continueOnDeath then
		return waitUntilAlive()
	end

	stopMacro("DIED")
	return false
end

local function stopMacro(reason)

	if not macroRunning then
		return
	end

	macroRunning = false
	autopilotActive = false

	if flyBody and flyBody.Parent then
		flyBody.Velocity = Vector3.zero
	end

	if
		flying
		and not flyEnabled
		and not (flyHoldEnabled and flyHoldDown)
	then
		stopFly()
	end

	macroMode = nil
	refreshMacroBtn()
	refreshKeyboardMacroBtn()
	refreshMonkeyMacroBtn()

	setStatus(
		"STOPPED: " ..
		(reason or "MANUAL")
	)

end

-- Two normal Space-style jumps (unstick at win portal).
local function performPortalUnstickJumps()
	setStatus("PORTAL STUCK → 2 JUMPS")
	jumpCharacter()
	if not macroWait(0.4) then
		return false
	end
	jumpCharacter()
	return macroWait(0.35)
end

-- After last slot reaches the win portal:
-- 1) WIN detected → return "WIN"
-- 2) Lobby spawn, no win → return "SPAWN"
-- 3) Still near portal / stuck → 2 normal jumps, then keep waiting
local function waitForWinOrSpawn(baselineWins, portalPos)

	local startTime = os.clock()
	local spawnConfirmStart = nil
	local nearPortalSince = nil
	local unstickCount = 0

	while macroRunning do

		local currentWins = getWins()

		-- =====================================================
		-- 1) NORMAL SUCCESS — win portal counted a win
		-- =====================================================

		if currentWins > baselineWins then

			setStatus(
				"WIN DETECTED! +" ..
				(currentWins - baselineWins)
			)

			return "WIN", currentWins
		end

		-- =====================================================
		-- 2) FALLBACK — returned to lobby spawn without a win
		-- =====================================================

		if os.clock() - startTime >= 1 then

			if isCharacterOnLobbySpawn() then

				if not spawnConfirmStart then
					spawnConfirmStart = os.clock()
				end

				if os.clock() - spawnConfirmStart >= 0.5 then

					setStatus(
						"SPAWN DETECTED — NO WIN"
					)

					return "SPAWN", currentWins
				end

			else

				spawnConfirmStart = nil

			end
		end

		-- =====================================================
		-- 3) STUCK at win portal — 2 normal jumps to unstick
		-- =====================================================

		if jumpAfterLastSlot and portalPos then
			local hrp = getHRP()
			local humanoid = getHumanoid()

			if hrp and humanoid and humanoid.Health > 0 then
				local dist = (hrp.Position - portalPos).Magnitude
				local stillAtPortal = dist <= portalStuckDist

				if stillAtPortal and not isCharacterOnLobbySpawn() then
					if not nearPortalSince then
						nearPortalSince = os.clock()
					end

					if
						unstickCount < portalUnstickMax
						and (os.clock() - nearPortalSince) >= portalStuckSeconds
					then
						unstickCount += 1
						nearPortalSince = os.clock() -- reset timer after jumps

						if not performPortalUnstickJumps() then
							return "STOPPED", currentWins
						end
					end
				else
					nearPortalSince = nil
				end
			end
		end

		task.wait(0.1)
	end

	return "STOPPED", baselineWins
end


local function startMacro()

	if macroRunning then
		setStatus("ALREADY RUNNING")
		return
	end

	if countSaved() == 0 then
		setStatus("NO SLOTS SAVED")
		return
	end

	if loopBox then
		local requested = tonumber(loopBox.Text)

		if requested then
			macroLoopCount = math.clamp(math.floor(requested), 0, 9999)
		else
			macroLoopCount = 0
		end

		loopBox.Text = tostring(macroLoopCount)
	end

	macroRunning = true
	macroMode = "MAIN"
	macroCurrentCycle = 0

	refreshMacroBtn()
	refreshKeyboardMacroBtn()
	refreshMonkeyMacroBtn()
	setStatus("MAIN MACRO STARTED")

	task.spawn(function()
		while macroRunning and macroMode == "MAIN" do

			if macroLoopCount > 0 and macroCurrentCycle >= macroLoopCount then
				stopMacro("FINISHED")
				break
			end

			macroCurrentCycle += 1
			setStatus("MAIN CYCLE " .. macroCurrentCycle)

			local lastSavedSlot = getLastSavedSlot()

			for i = 1, slotCount do
				if not macroRunning or macroMode ~= "MAIN" then
					break
				end

				if not ensureAliveOrHandleDeath() then
					break
				end

				if savedPositions[i] then
					pulseChip(i)

					local mode = savedModes[i] or "Fly"
					local success = travelToSlot(i)
					if not success then
						setStatus("SLOT " .. i .. " FAILED")
					end

					-- Pause after ANY Teleport if more saved slots remain
					-- (works for any slot numbers: 1,5,9 or 2,3,4 etc.)
					if mode == "Teleport" then
						local hasLaterSaved = false
						for j = i + 1, slotCount do
							if savedPositions[j] then
								hasLaterSaved = true
								break
							end
						end
						if hasLaterSaved then
							if not macroWait(macroTeleportPause) then
								break
							end
						end
					end

					-- Last slot = win portal area.
					-- Do not single-jump immediately. Wait briefly; if still
					-- stuck on the portal, fire 2 normal jumps to unstick.
					if jumpAfterLastSlot and i == lastSavedSlot then
						local portalPos = savedPositions[i]
						setStatus("LAST SLOT → PORTAL WAIT")
						if not macroWait(portalStuckSeconds) then
							break
						end

						local hrp = getHRP()
						if
							hrp
							and portalPos
							and (hrp.Position - portalPos).Magnitude <= portalStuckDist
						then
							if not performPortalUnstickJumps() then
								break
							end
							-- Second chance if still stuck after first pair.
							if not macroWait(portalStuckSeconds) then
								break
							end
							hrp = getHRP()
							if
								hrp
								and portalPos
								and (hrp.Position - portalPos).Magnitude <= portalStuckDist
							then
								if not performPortalUnstickJumps() then
									break
								end
							end
						end
					end
				end
			end

			if not macroRunning or macroMode ~= "MAIN" then
				break
			end

			-- MAIN is intentionally game-agnostic:
			-- no Stage TP, no Wins check, and no lobby-spawn fallback.
			if macroCycleDelay > 0 then
				setStatus("NEXT CYCLE IN " .. string.format("%.1f", macroCycleDelay) .. " SEC")
				if not macroWait(macroCycleDelay) then
					break
				end
			end
		end
	end)
end

local function startKeyboardMacro()

	if macroRunning then

		setStatus("ALREADY RUNNING")

		return

	end

	if countSaved() == 0 then

		setStatus("NO SLOTS SAVED")

		return

	end

	if keyboardLoopBox then

		local requested =
			tonumber(keyboardLoopBox.Text)

		if requested then

			macroLoopCount =
				math.clamp(
					math.floor(requested),
					0,
					9999
				)

		else

			macroLoopCount = 0

		end

		keyboardLoopBox.Text =
			tostring(macroLoopCount)

	end

	macroRunning = true
	macroMode = "KEYBOARD"
	macroCurrentCycle = 0

	refreshMacroBtn()
	refreshKeyboardMacroBtn()
	refreshMonkeyMacroBtn()

	setStatus("KEYBOARD GAME MACRO STARTED")

	task.spawn(function()

		while macroRunning do

			-- ----------------------------------------
			-- LOOP LIMIT
			-- ----------------------------------------

			if
				macroLoopCount > 0
				and macroCurrentCycle >= macroLoopCount
			then

				stopMacro("FINISHED")

				break

			end

			macroCurrentCycle += 1

			setStatus(
				"CYCLE " ..
				macroCurrentCycle
			)

			-- ----------------------------------------
			-- 1. STAGE TELEPORT
			-- ----------------------------------------

			local stageSuccess =
				doStageTeleport()

			if not stageSuccess then

				stopMacro(
					"STAGE TP FAILED"
				)

				break

			end

			if not macroWait(1.5) then
				break
			end

			-- IMPORTANT:
			-- Capture Wins AFTER Stage TP,
			-- but BEFORE running route.
			--
			-- This prevents the Stage TP itself
			-- from becoming the detected Win,
			-- while also making sure an instant
			-- Win from the saved route isn't missed.

			local baselineWins =
				getWins()

			-- Resolve the actual final SAVED slot once per cycle.
			-- Example: if 1, 2, 4 and 6 are saved, slot 6 is final.
			local lastSavedSlot =
				getLastSavedSlot()

			-- ----------------------------------------
			-- 2. RUN SAVED ROUTE
			-- ----------------------------------------

			for i = 1, slotCount do

				if not macroRunning then
					break
				end

				if not ensureAliveOrHandleDeath() then
					break
				end

				if savedPositions[i] then

					pulseChip(i)

					local mode = savedModes[i] or "Fly"
					local success =
						travelToSlot(i)

					if not success then

						setStatus(
							"SLOT " ..
								i ..
								" FAILED"
						)

					end

					-- Pause after ANY Teleport if more saved slots remain
					-- (works for any slot numbers: 1,5,9 or 2,3,4 etc.)
					if mode == "Teleport" then
						local hasLaterSaved = false
						for j = i + 1, slotCount do
							if savedPositions[j] then
								hasLaterSaved = true
								break
							end
						end
						if hasLaterSaved then
							if not macroWait(macroTeleportPause) then
								break
							end
						end
					end

					-- Last slot is the win portal position.
					-- Do NOT jump immediately — win/spawn/stuck is handled below.

				end

			end

			if not macroRunning then
				break
			end

			-- ============================================================
			-- WAIT FOR WIN / NO-WIN SPAWN / STUCK (2 JUMPS)
			-- 1) Win portal counted a win
			-- 2) Returned to lobby spawn without a win
			-- 3) Stuck at portal → 2 normal jumps, keep waiting
			-- ============================================================

			local portalPos = nil
			if lastSavedSlot then
				portalPos = savedPositions[lastSavedSlot]
			end

			setStatus(
				"WAITING FOR WIN..."
			)

			local result, currentWins =
				waitForWinOrSpawn(
					baselineWins,
					portalPos
				)

			if result == "WIN" then

				-- Normal successful win. Delay is controlled by the slider.
				setStatus(
					"WIN → WAIT " ..
					string.format("%.1f", macroCycleDelay) ..
					" SEC"
				)

				if macroCycleDelay > 0 and not macroWait(macroCycleDelay) then
					break
				end


			elseif result == "SPAWN" then

				-- We reached the finish and the server returned
				-- us to Lobby SpawnLocation, but Wins did not increase.
				--
				-- Do NOT wait 5 seconds.
				-- Immediately restart from Stage TP.

				setStatus(
					"NO WIN → RETRY CYCLE"
				)

				-- Tiny stabilization delay only.
				-- This is NOT the slot-to-slot pause.
				task.wait(0.25)


			else

				break

			end

			-- Then loop automatically back
			-- to Stage TP.

		end

	end)

end

-- ============================================================
-- MONKEY MACRO — instant / repetitive route only
-- Uses MAIN slots. No Stage TP, no Win/Spawn wait, no portal delay.
-- ============================================================

local function startMonkeyMacro()

	if macroRunning then
		setStatus("ALREADY RUNNING")
		return
	end

	if countSaved() == 0 then
		setStatus("NO SLOTS SAVED")
		return
	end

	if monkeyLoopBox then
		local requested = tonumber(monkeyLoopBox.Text)
		if requested then
			macroLoopCount = math.clamp(math.floor(requested), 0, 9999)
		else
			macroLoopCount = 0
		end
		monkeyLoopBox.Text = tostring(macroLoopCount)
	end

	macroRunning = true
	macroMode = "MONKEY"
	macroCurrentCycle = 0

	refreshMacroBtn()
	refreshKeyboardMacroBtn()
	refreshMonkeyMacroBtn()
	setStatus("MONKEY MACRO STARTED")

	task.spawn(function()
		while macroRunning and macroMode == "MONKEY" do

			if macroLoopCount > 0 and macroCurrentCycle >= macroLoopCount then
				stopMacro("FINISHED")
				break
			end

			macroCurrentCycle += 1
			setStatus("MONKEY CYCLE " .. macroCurrentCycle)

			for i = 1, slotCount do
				if not macroRunning or macroMode ~= "MONKEY" then
					break
				end

				if not ensureAliveOrHandleDeath() then
					break
				end

				if savedPositions[i] then
					pulseChip(i)

					local mode = savedModes[i] or "Fly"
					local success = travelToSlot(i)
					if not success then
						setStatus("SLOT " .. i .. " FAILED")
					end

					-- Brief pause only between consecutive Teleports
					if mode == "Teleport" then
						local hasLaterSaved = false
						for j = i + 1, slotCount do
							if savedPositions[j] then
								hasLaterSaved = true
								break
							end
						end
						if hasLaterSaved then
							if not macroWait(macroTeleportPause) then
								break
							end
						end
					end
				end
			end

			if not macroRunning or macroMode ~= "MONKEY" then
				break
			end

			-- Instant + repetitive: no cycle delay, no portal wait, no Stage TP.
			-- Tiny yield so the loop cannot hard-lock the client.
			task.wait(0.05)
		end
	end)
end

-- ============================================================
-- CHARACTER RESPAWN
-- ============================================================

local function onCharacterAdded(char)

	local humanoid =
		char:WaitForChild(
			"Humanoid",
			5
		)

	if not humanoid then
		return
	end

	table.clear(noclipOriginal)

	task.delay(1, function()

		if not humanoid.Parent then
			return
		end

		if not speedEnabled then
			originalSpeed =
				humanoid.WalkSpeed
		end

		if not superJumpEnabled then
			originalJump =
				humanoid.JumpPower
		end

	end)

	bindSpeedWatcher(char)

	if superJumpEnabled then
		applyJump()
	end

	flying = false
	flyBody = nil
	flyGyro = nil
	autopilotActive = false

	if
		flyEnabled
		or
		(flyHoldEnabled and flyHoldDown)
	then

		task.delay(
			0.3,
			updateFly
		)

	end

	humanoid.Died:Connect(function()

		if macroRunning and not continueOnDeath then
			stopMacro("DIED")
		end

	end)

end

if player.Character then

	task.spawn(
		onCharacterAdded,
		player.Character
	)

end

player.CharacterAdded:Connect(
	onCharacterAdded
)

-- ============================================================
-- GUI
-- ============================================================

local FW = 310
local PAD = 10

local CHIP_W = 68
local CHIP_STEP = 72
local ROW_H = 28

-- Remove stale menu GUI objects from previous executions.
do
	local pg = player:WaitForChild("PlayerGui")
	for _, oldName in ipairs({"IconMenuV51", "IconMenuV52", "IconMenuV521"}) do
		local oldGui = pg:FindFirstChild(oldName)
		if oldGui then
			oldGui:Destroy()
		end
	end
end

local screenGui =
	Instance.new("ScreenGui")

screenGui.Name = "IconMenuV521"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 999999
screenGui.ZIndexBehavior =
	Enum.ZIndexBehavior.Sibling

screenGui.Parent =
	player:WaitForChild("PlayerGui")

-- ============================================================
-- ICON BUTTON
-- ============================================================

local iconButton =
	Instance.new("ImageButton")

iconButton.Size =
	UDim2.new(
		0, 50,
		0, 50
	)

iconButton.Position =
	UDim2.new(
		1, -70,
		1, -70
	)

iconButton.BackgroundColor3 =
	Color3.fromRGB(
		14,
		18,
		15
	)

iconButton.Image =
	"rbxassetid://505845268"

iconButton.Parent =
	screenGui

Instance.new(
	"UICorner",
	iconButton
).CornerRadius =
	UDim.new(0, 12)

Instance.new(
	"UIStroke",
	iconButton
).Color =
	Color3.fromRGB(
		124,
		255,
		107
	)

-- Icon drag

local iconDragDistance = 0
local iconDragStart = nil
local iconStartPosition = nil

iconButton.InputBegan:Connect(function(input)

	if
		input.UserInputType ==
		Enum.UserInputType.MouseButton1
	then

		iconDragDistance = 0

		iconDragStart =
			input.Position

		iconStartPosition =
			iconButton.Position

	end

end)

UserInputService.InputChanged:Connect(function(input)

	if
		iconDragStart
		and input.UserInputType ==
			Enum.UserInputType.MouseMovement
	then

		local delta =
			input.Position -
			iconDragStart

		iconDragDistance =
			math.max(
				iconDragDistance,
				delta.Magnitude
			)

		iconButton.Position =
			UDim2.new(
				iconStartPosition.X.Scale,
				iconStartPosition.X.Offset + delta.X,

				iconStartPosition.Y.Scale,
				iconStartPosition.Y.Offset + delta.Y
			)

	end

end)

UserInputService.InputEnded:Connect(function(input)

	if
		input.UserInputType ==
		Enum.UserInputType.MouseButton1
	then

		iconDragStart = nil

	end

end)

-- ============================================================
-- MAIN WINDOW
-- ============================================================

local mainFrame =
	Instance.new("Frame")

mainFrame.Size =
	UDim2.new(
		0, FW,
		0, 600
	)

mainFrame.Position =
	UDim2.new(
		1, -(FW + 20),
		1, -630
	)

mainFrame.BackgroundColor3 =
	Color3.fromRGB(
		10,
		13,
		11
	)

mainFrame.Visible = guiOpen
mainFrame.Active = true
mainFrame.ClipsDescendants = true

mainFrame.Parent =
	screenGui

Instance.new(
	"UICorner",
	mainFrame
).CornerRadius =
	UDim.new(0, 10)

Instance.new(
	"UIStroke",
	mainFrame
).Color =
	Color3.fromRGB(
		42,
		53,
		44
	)

local function setMenuOpen(open)
	guiOpen = open
	mainFrame.Visible = open

	if open then
		screenGui.DisplayOrder = 999999

		local pg = player:FindFirstChild("PlayerGui")
		if pg and screenGui.Parent == pg then
			screenGui.Parent = nil
			screenGui.Parent = pg
		end
	end
end

-- v5.2.1: connect the icon toggle EARLY.
-- Even if a later optional GUI feature errors, the base window still opens/closes.
iconButton.MouseButton1Click:Connect(function()
	if iconDragDistance > 6 then
		return
	end

	setMenuOpen(not guiOpen)
end)

warn("[Icon Menu v5.2.2] base GUI created")

-- ============================================================
-- TITLE
-- ============================================================

local title =
	Instance.new("TextLabel")

title.Size =
	UDim2.new(
		1, 0,
		0, 32
	)

title.BackgroundColor3 =
	Color3.fromRGB(
		15,
		20,
		16
	)

title.Text =
	"MENU v5.3.1"

title.TextColor3 =
	Color3.fromRGB(
		124,
		255,
		107
	)

title.Font =
	Enum.Font.GothamBold

title.TextSize = 13

title.TextXAlignment =
	Enum.TextXAlignment.Left

title.Parent =
	mainFrame

Instance.new(
	"UICorner",
	title
).CornerRadius =
	UDim.new(0, 10)

Instance.new(
	"UIPadding",
	title
).PaddingLeft =
	UDim.new(0, 12)

-- Status

local statusToken = 0

local statusLabel =
	Instance.new("TextLabel")

statusLabel.Size =
	UDim2.new(
		0, 150,
		1, 0
	)

statusLabel.Position =
	UDim2.new(
		1, -182,
		0, 0
	)

statusLabel.BackgroundTransparency = 1
statusLabel.Text = ""

statusLabel.TextColor3 =
	Color3.fromRGB(
		147,
		180,
		139
	)

statusLabel.Font =
	Enum.Font.Code

statusLabel.TextSize = 10

statusLabel.TextXAlignment =
	Enum.TextXAlignment.Right

statusLabel.Parent =
	title

-- Close (X) — fully unloads this script session
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 22)
closeBtn.Position = UDim2.new(1, -30, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(140, 40, 40)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.AutoButtonColor = true
closeBtn.ZIndex = 5
closeBtn.Parent = title
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local function unloadScript()
	-- Stop active systems
	pcall(function()
		if macroRunning then
			stopMacro("UNLOADED")
		end
	end)

	autopilotActive = false
	flyEnabled = false
	flyHoldEnabled = false
	flyHoldDown = false
	speedEnabled = false
	superJumpEnabled = false
	continueOnDeath = false
	noclipEnabled = false
	autoBuy = false
	monkeyAutoBuy = false

	pcall(stopFly)
	pcall(restoreNoclip)
	pcall(releaseSpeed)
	pcall(applyJump)

	-- Destroy floating icon + main window
	pcall(function()
		if screenGui and screenGui.Parent then
			screenGui:Destroy()
		end
	end)

	print("Icon Menu unloaded")
end

closeBtn.MouseButton1Click:Connect(function()
	unloadScript()
end)

setStatus = function(message)

	statusToken += 1

	local token =
		statusToken

	statusLabel.Text =
		string.upper(
			tostring(message)
		)

	task.delay(4, function()

		if statusToken == token then
			statusLabel.Text = ""
		end

	end)

end

-- ============================================================
-- WINDOW DRAG
-- ============================================================

local menuDragging = false
local menuDragStart = nil
local menuStartPosition = nil

title.InputBegan:Connect(function(input)

	if
		input.UserInputType ==
			Enum.UserInputType.MouseButton1
		or
		input.UserInputType ==
			Enum.UserInputType.Touch
	then

		menuDragging = true

		menuDragStart =
			input.Position

		menuStartPosition =
			mainFrame.Position

	end

end)

UserInputService.InputChanged:Connect(function(input)

	if
		menuDragging
		and
		(
			input.UserInputType ==
			Enum.UserInputType.MouseMovement
			or
			input.UserInputType ==
			Enum.UserInputType.Touch
		)
	then

		local delta =
			input.Position -
			menuDragStart

		mainFrame.Position =
			UDim2.new(
				menuStartPosition.X.Scale,
				menuStartPosition.X.Offset + delta.X,

				menuStartPosition.Y.Scale,
				menuStartPosition.Y.Offset + delta.Y
			)

	end

end)

UserInputService.InputEnded:Connect(function(input)

	if
		input.UserInputType ==
			Enum.UserInputType.MouseButton1
		or
		input.UserInputType ==
			Enum.UserInputType.Touch
	then

		menuDragging = false

	end

end)

-- ============================================================
-- TABS (MAIN | KEYBOARD | MONKEY)
-- ============================================================

local TAB_W = 0.333
local TAB_GAP = 4

local tabMainBtn = Instance.new("TextButton")
tabMainBtn.Size = UDim2.new(TAB_W, -TAB_GAP, 0, 26)
tabMainBtn.Position = UDim2.new(0, 6, 0, 36)
tabMainBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 60)
tabMainBtn.Text = "MAIN"
tabMainBtn.TextColor3 = Color3.new(1, 1, 1)
tabMainBtn.Font = Enum.Font.GothamBold
tabMainBtn.TextSize = 11
tabMainBtn.Parent = mainFrame
Instance.new("UICorner", tabMainBtn).CornerRadius = UDim.new(0, 6)

local tabOthersBtn = Instance.new("TextButton")
tabOthersBtn.Size = UDim2.new(TAB_W, -TAB_GAP, 0, 26)
tabOthersBtn.Position = UDim2.new(TAB_W, 2, 0, 36)
tabOthersBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
tabOthersBtn.Text = "KEYBOARD"
tabOthersBtn.TextColor3 = Color3.new(1, 1, 1)
tabOthersBtn.Font = Enum.Font.GothamBold
tabOthersBtn.TextSize = 11
tabOthersBtn.Parent = mainFrame
Instance.new("UICorner", tabOthersBtn).CornerRadius = UDim.new(0, 6)

local tabMonkeyBtn = Instance.new("TextButton")
tabMonkeyBtn.Size = UDim2.new(TAB_W, -TAB_GAP, 0, 26)
tabMonkeyBtn.Position = UDim2.new(TAB_W * 2, -2, 0, 36)
tabMonkeyBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
tabMonkeyBtn.Text = "MONKEY"
tabMonkeyBtn.TextColor3 = Color3.new(1, 1, 1)
tabMonkeyBtn.Font = Enum.Font.GothamBold
tabMonkeyBtn.TextSize = 11
tabMonkeyBtn.Parent = mainFrame
Instance.new("UICorner", tabMonkeyBtn).CornerRadius = UDim.new(0, 6)

local mainPage = Instance.new("Frame")
mainPage.Size = UDim2.new(1, 0, 1, -70)
mainPage.Position = UDim2.new(0, 0, 0, 68)
mainPage.BackgroundTransparency = 1
mainPage.Parent = mainFrame

local othersPage = Instance.new("Frame")
othersPage.Size = UDim2.new(1, 0, 1, -70)
othersPage.Position = UDim2.new(0, 0, 0, 68)
othersPage.BackgroundTransparency = 1
othersPage.Visible = false
othersPage.Parent = mainFrame

local monkeyPage = Instance.new("Frame")
monkeyPage.Size = UDim2.new(1, 0, 1, -70)
monkeyPage.Position = UDim2.new(0, 0, 0, 68)
monkeyPage.BackgroundTransparency = 1
monkeyPage.Visible = false
monkeyPage.Parent = mainFrame

local COLOR_TAB_ON = Color3.fromRGB(40, 120, 60)
local COLOR_TAB_OFF = Color3.fromRGB(40, 40, 55)

local function switchTab(tab)
	mainPage.Visible = (tab == "main")
	othersPage.Visible = (tab == "others")
	monkeyPage.Visible = (tab == "monkey")

	tabMainBtn.BackgroundColor3 = (tab == "main") and COLOR_TAB_ON or COLOR_TAB_OFF
	tabOthersBtn.BackgroundColor3 = (tab == "others") and COLOR_TAB_ON or COLOR_TAB_OFF
	tabMonkeyBtn.BackgroundColor3 = (tab == "monkey") and COLOR_TAB_ON or COLOR_TAB_OFF
end

tabMainBtn.MouseButton1Click:Connect(function()
	switchTab("main")
end)

tabOthersBtn.MouseButton1Click:Connect(function()
	switchTab("others")
end)

tabMonkeyBtn.MouseButton1Click:Connect(function()
	switchTab("monkey")
end)

-- ============================================================
-- OPTION CREATOR
-- ============================================================

local function createOption(
	parent,
	name,
	y,
	hasInput,
	defaultValue,
	onToggle,
	onInput
)

	local label =
		Instance.new("TextLabel")

	label.Size =
		UDim2.new(
			0, 78,
			0, 26
		)

	label.Position =
		UDim2.new(
			0, PAD,
			0, y
		)

	label.BackgroundTransparency = 1
	label.Text = name
	label.TextColor3 = Color3.new(1,1,1)
	label.Font = Enum.Font.Gotham
	label.TextSize = 13

	label.TextXAlignment =
		Enum.TextXAlignment.Left

	label.Parent =
		parent

	local button =
		Instance.new("TextButton")

	button.Size =
		UDim2.new(
			0, 46,
			0, 24
		)

	button.Position =
		UDim2.new(
			0, 92,
			0, y + 1
		)

	button.BackgroundColor3 =
		Color3.fromRGB(
			32,
			40,
			34
		)

	button.Text = "OFF"
	button.TextColor3 = Color3.new(1,1,1)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 11

	button.Parent =
		parent

	Instance.new(
		"UICorner",
		button
	).CornerRadius =
		UDim.new(0, 6)

	button.MouseButton1Click:Connect(function()

		local enabled =
			button.Text ~= "ON"

		button.Text =
			enabled and
			"ON" or
			"OFF"

		button.BackgroundColor3 =
			enabled and
			Color3.fromRGB(
				60,
				160,
				60
			)
			or
			Color3.fromRGB(
				32,
				40,
				34
			)

		onToggle(enabled)

	end)

	if hasInput then

		local input =
			Instance.new("TextBox")

		input.Size =
			UDim2.new(
				0, 62,
				0, 24
			)

		input.Position =
			UDim2.new(
				1, -72,
				0, y + 1
			)

		input.BackgroundColor3 =
			Color3.fromRGB(
				20,
				25,
				21
			)

		input.Text =
			tostring(
				defaultValue
			)

		input.TextColor3 =
			Color3.new(1,1,1)

		input.Font =
			Enum.Font.Gotham

		input.TextSize = 12

		input.ClearTextOnFocus = false

		input.Parent =
			parent

		Instance.new(
			"UICorner",
			input
		).CornerRadius =
			UDim.new(0, 6)

		input.FocusLost:Connect(function()

			local number =
				tonumber(input.Text)

			if number then

				number =
					math.clamp(
						math.floor(number),
						0,
						1e11
					)

				input.Text =
					tostring(number)

				onInput(number)

			else

				input.Text =
					tostring(
						defaultValue
					)

			end

		end)

	end

	return button

end

-- ============================================================
-- MAIN OPTIONS
-- ============================================================

createOption(
	mainPage,
	"Super Jump",
	6,
	true,
	jumpPower,

	function(enabled)

		superJumpEnabled =
			enabled

		applyJump()

	end,

	function(value)
		jumpPower = value
	end
)

createOption(
	mainPage,
	"Speed",
	36,
	true,
	walkSpeed,

	function(enabled)

		speedEnabled =
			enabled

		if not enabled then
			releaseSpeed()
		end

	end,

	function(value)
		walkSpeed = value
	end
)

createOption(
	mainPage,
	"Fly",
	66,
	true,
	flySpeed,

	function(enabled)

		flyEnabled =
			enabled

		updateFly()

	end,

	function(value)
		flySpeed = value
	end
)

-- ============================================================
-- FLY HOLD
-- ============================================================

local holdLabel =
	Instance.new("TextLabel")

holdLabel.Size =
	UDim2.new(
		0, 78,
		0, 26
	)

holdLabel.Position =
	UDim2.new(
		0, PAD,
		0, 96
	)

holdLabel.BackgroundTransparency = 1
holdLabel.Text = "Fly Hold"
holdLabel.TextColor3 = Color3.new(1,1,1)
holdLabel.Font = Enum.Font.Gotham
holdLabel.TextSize = 13

holdLabel.TextXAlignment =
	Enum.TextXAlignment.Left

holdLabel.Parent =
	mainPage

local holdBtn =
	Instance.new("TextButton")

holdBtn.Size =
	UDim2.new(
		0, 46,
		0, 24
	)

holdBtn.Position =
	UDim2.new(
		0, 92,
		0, 97
	)

holdBtn.BackgroundColor3 =
	Color3.fromRGB(
		32,
		40,
		34
	)

holdBtn.Text = "OFF"
holdBtn.TextColor3 = Color3.new(1,1,1)
holdBtn.Font = Enum.Font.GothamBold
holdBtn.TextSize = 11

holdBtn.Parent =
	mainPage

Instance.new(
	"UICorner",
	holdBtn
).CornerRadius =
	UDim.new(0, 6)

local bindBtn =
	Instance.new("TextButton")

bindBtn.Size =
	UDim2.new(
		0, 72,
		0, 24
	)

bindBtn.Position =
	UDim2.new(
		1, -82,
		0, 97
	)

bindBtn.BackgroundColor3 =
	Color3.fromRGB(
		20,
		25,
		21
	)

bindBtn.Text =
	"BIND : F"

bindBtn.TextColor3 =
	Color3.new(1,1,1)

bindBtn.Font =
	Enum.Font.Code

bindBtn.TextSize = 11

bindBtn.Parent =
	mainPage

Instance.new(
	"UICorner",
	bindBtn
).CornerRadius =
	UDim.new(0, 6)

refreshFlyBindLabel = function()

	if rebindingFly then

		bindBtn.Text =
			"PRESS KEY"

		bindBtn.BackgroundColor3 =
			Color3.fromRGB(
				0,
				110,
				194
			)

	else

		bindBtn.Text =
			"BIND : " ..
			flyHoldKey.Name

		bindBtn.BackgroundColor3 =
			Color3.fromRGB(
				20,
				25,
				21
			)

	end

end

refreshFlyBindLabel()

holdBtn.MouseButton1Click:Connect(function()

	flyHoldEnabled =
		not flyHoldEnabled

	holdBtn.Text =
		flyHoldEnabled and
		"ON" or
		"OFF"

	holdBtn.BackgroundColor3 =
		flyHoldEnabled and
		Color3.fromRGB(
			60,
			160,
			60
		)
		or
		Color3.fromRGB(
			32,
			40,
			34
		)

	if not flyHoldEnabled then
		flyHoldDown = false
	end

	updateFly()

end)

bindBtn.MouseButton1Click:Connect(function()

	rebindingFly = true

	refreshFlyBindLabel()

	setStatus("PRESS ANY KEY")

end)

-- ============================================================
-- NOCLIP + CONTINUE ON DEATH
-- ============================================================

createOption(
	mainPage,
	"NoClip",
	126,
	false,
	nil,

	function(enabled)

		noclipEnabled =
			enabled

		applyNoclip()

	end,

	nil
)

createOption(
	mainPage,
	"On Death",
	156,
	false,
	nil,

	function(enabled)

		continueOnDeath =
			enabled

		setStatus(
			enabled and
			"CONTINUE AFTER DEATH" or
			"STOP ON DEATH"
		)

	end,

	nil
)

-- ============================================================
-- ROUTE CONTROL BAR
-- ============================================================

local chips = {}
local chipRemoveButtons = {}

local setArmed = false

local COLOR_EMPTY =
	Color3.fromRGB(
		30,
		36,
		32
	)

local COLOR_SAVED =
	Color3.fromRGB(
		52,
		132,
		58
	)

local COLOR_PULSE =
	Color3.fromRGB(
		150,
		255,
		120
	)

local setBtn =
	Instance.new("TextButton")

setBtn.Size =
	UDim2.new(
		0, 44,
		0, 24
	)

setBtn.Position =
	UDim2.new(
		0, 10,
		0, 200
	)

setBtn.BackgroundColor3 =
	Color3.fromRGB(
		26,
		32,
		33
	)

setBtn.Text = "SET"

setBtn.TextColor3 =
	Color3.fromRGB(
		188,
		210,
		232
	)

setBtn.Font =
	Enum.Font.GothamBold

setBtn.TextSize = 11
setBtn.Parent = mainPage

Instance.new(
	"UICorner",
	setBtn
).CornerRadius =
	UDim.new(0, 6)

local nextModeBtn =
	Instance.new("TextButton")

nextModeBtn.Size =
	UDim2.new(
		0, 52,
		0, 24
	)

nextModeBtn.Position =
	UDim2.new(
		0, 60,
		0, 200
	)

nextModeBtn.BackgroundColor3 =
	Color3.fromRGB(
		26,
		32,
		33
	)

nextModeBtn.Font =
	Enum.Font.GothamBold

nextModeBtn.TextSize = 10
nextModeBtn.Parent = mainPage

Instance.new(
	"UICorner",
	nextModeBtn
).CornerRadius =
	UDim.new(0, 6)

local copyBtn =
	Instance.new("TextButton")

copyBtn.Size =
	UDim2.new(
		0, 44,
		0, 24
	)

copyBtn.Position =
	UDim2.new(
		0, 116,
		0, 200
	)

copyBtn.BackgroundColor3 =
	Color3.fromRGB(
		40,
		60,
		90
	)

copyBtn.Text = "COPY"
copyBtn.TextColor3 = Color3.new(1,1,1)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 10

copyBtn.Parent =
	mainPage

Instance.new(
	"UICorner",
	copyBtn
).CornerRadius =
	UDim.new(0, 6)

local pasteBtn =
	Instance.new("TextButton")

pasteBtn.Size =
	UDim2.new(
		0, 44,
		0, 24
	)

pasteBtn.Position =
	UDim2.new(
		0, 164,
		0, 200
	)

pasteBtn.BackgroundColor3 =
	Color3.fromRGB(
		70,
		50,
		100
	)

pasteBtn.Text = "PASTE"
pasteBtn.TextColor3 = Color3.new(1,1,1)
pasteBtn.Font = Enum.Font.GothamBold
pasteBtn.TextSize = 10

pasteBtn.Parent =
	mainPage

Instance.new(
	"UICorner",
	pasteBtn
).CornerRadius =
	UDim.new(0, 6)

local macroBtn =
	Instance.new("TextButton")

macroBtn.Size =
	UDim2.new(
		0, 82,
		0, 24
	)

macroBtn.Position =
	UDim2.new(
		0, 216,
		0, 200
	)

macroBtn.BackgroundColor3 =
	Color3.fromRGB(
		34,
		66,
		31
	)

macroBtn.Text = "MACRO"

macroBtn.TextColor3 =
	Color3.fromRGB(
		183,
		232,
		164
	)

macroBtn.Font =
	Enum.Font.GothamBold

macroBtn.TextSize = 11

macroBtn.Parent =
	mainPage

Instance.new(
	"UICorner",
	macroBtn
).CornerRadius =
	UDim.new(0, 6)

refreshSetBtn = function()

	setBtn.BackgroundColor3 =
		setArmed and
		Color3.fromRGB(
			0,
			110,
			194
		)
		or
		Color3.fromRGB(
			26,
			32,
			33
		)

	setBtn.Text =
		setArmed and
		"..." or
		"SET"

end

refreshMacroBtn = function()

	macroBtn.Text =
		macroRunning and
		"STOP" or
		"MACRO"

	macroBtn.BackgroundColor3 =
		macroRunning and
		Color3.fromRGB(
			178,
			58,
			58
		)
		or
		Color3.fromRGB(
			34,
			66,
			31
		)

	macroBtn.TextColor3 =
		macroRunning and
		Color3.new(1,1,1)
		or
		Color3.fromRGB(
			183,
			232,
			164
		)

end
refreshNextModeBtn = function()

	if nextSetMode == "Fly" then

		nextModeBtn.Text = "Next:F"
		nextModeBtn.TextColor3 = Color3.fromRGB(140, 190, 255)

	elseif nextSetMode == "Teleport" then

		nextModeBtn.Text = "Next:T"
		nextModeBtn.TextColor3 = Color3.fromRGB(255, 200, 80)

	elseif nextSetMode == "Walk" then

		nextModeBtn.Text = "Next:W"
		nextModeBtn.TextColor3 = Color3.fromRGB(120, 255, 165)

	else

		nextModeBtn.Text = "Next:J"
		nextModeBtn.TextColor3 = Color3.fromRGB(255, 160, 80)

	end

end

refreshSetBtn()
refreshNextModeBtn()
refreshMacroBtn()

setBtn.MouseButton1Click:Connect(function()

	setArmed =
		not setArmed

	refreshSetBtn()

	if setArmed then

		setStatus(
			"TAP SLOT → " ..
			nextSetMode
		)

	else

		setStatus("SET CANCELLED")

	end

end)

nextModeBtn.MouseButton1Click:Connect(function()

	if nextSetMode == "Fly" then
		nextSetMode = "Teleport"
	elseif nextSetMode == "Teleport" then
		nextSetMode = "Walk"
	elseif nextSetMode == "Walk" then
		nextSetMode = "Jump"
	else
		nextSetMode = "Fly"
	end

	refreshNextModeBtn()

end)

macroBtn.MouseButton1Click:Connect(function()

	if macroRunning then

		stopMacro("MANUAL")

	else

		startMacro()

	end

end)

-- ============================================================
-- SLOT CHIPS — SCROLLABLE FLY / TELEPORT DECK
-- ============================================================

local SLOT_SCROLL_HEIGHT = 90 -- 3 visible rows

local slotScroll =
	Instance.new("ScrollingFrame")

slotScroll.Size =
	UDim2.new(
		1, -20,
		0, SLOT_SCROLL_HEIGHT
	)

slotScroll.Position =
	UDim2.new(
		0, 10,
		0, 236
	)

slotScroll.BackgroundColor3 =
	Color3.fromRGB(
		14,
		18,
		15
	)

slotScroll.BorderSizePixel = 0
slotScroll.ScrollBarThickness = 4
slotScroll.ScrollingDirection = Enum.ScrollingDirection.Y
slotScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
slotScroll.Parent = mainPage

Instance.new(
	"UICorner",
	slotScroll
).CornerRadius =
	UDim.new(0, 6)

local function updateSlotScrollCanvas()

	local rows =
		math.max(
			1,
			math.ceil(slotCount / 4)
		)

	local contentHeight =
		4 + rows * ROW_H

	slotScroll.CanvasSize =
		UDim2.new(
			0, 0,
			0, contentHeight
		)

end

local function chipPosition(slot)

	local column =
		(slot - 1) % 4

	local row =
		math.floor(
			(slot - 1) / 4
		)

	return UDim2.new(
		0,
		column * CHIP_STEP,

		0,
		3 + row * ROW_H
	)

end
refreshChip = function(slot)

	local button = chips[slot]
	local removeX = chipRemoveButtons[slot]

	if not button then
		return
	end

	local mode = savedModes[slot] or "Fly"
	local letter = "F"

	if mode == "Teleport" then
		letter = "T"
	elseif mode == "Walk" then
		letter = "W"
	elseif mode == "Jump" then
		letter = "J"
	end

	if savedPositions[slot] then

		button.Text = slot .. " " .. letter
		button.BackgroundColor3 = COLOR_SAVED
		button.TextColor3 = Color3.new(1,1,1)

		if removeX then
			removeX.Visible = true
		end

	else

		button.Text = tostring(slot)
		button.BackgroundColor3 = COLOR_EMPTY
		button.TextColor3 = Color3.fromRGB(140, 150, 142)

		if removeX then
			removeX.Visible = false
		end

	end

end

pulseChip = function(slot)

	local button =
		chips[slot]

	if not button then
		return
	end

	button.BackgroundColor3 =
		COLOR_PULSE

	task.delay(0.25, function()
		refreshChip(slot)
	end)

end

makeChip = function(slot)

	if chips[slot] then
		return chips[slot]
	end

	local button = Instance.new("TextButton")

	button.Size = UDim2.new(0, CHIP_W, 0, 22)
	button.Position = chipPosition(slot)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 11
	button.AutoButtonColor = false
	button.Parent = slotScroll

	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)

	local removeX = Instance.new("TextButton")
	removeX.Name = "RemoveSlot"
	removeX.Size = UDim2.new(0, 16, 0, 16)
	removeX.Position = UDim2.new(1, -18, 0, 3)
	removeX.BackgroundColor3 = Color3.fromRGB(150, 45, 45)
	removeX.Text = "×"
	removeX.TextColor3 = Color3.new(1,1,1)
	removeX.Font = Enum.Font.GothamBold
	removeX.TextSize = 11
	removeX.AutoButtonColor = true
	removeX.Visible = false
	removeX.ZIndex = button.ZIndex + 2
	removeX.Parent = button
	Instance.new("UICorner", removeX).CornerRadius = UDim.new(0, 4)

	chips[slot] = button
	chipRemoveButtons[slot] = removeX

	refreshChip(slot)

	removeX.MouseButton1Click:Connect(function()
		if not savedPositions[slot] then
			return
		end

		savedPositions[slot] = nil
		savedModes[slot] = nil
		refreshChip(slot)
		setStatus("CLEARED SLOT " .. slot)
	end)

	button.MouseButton1Click:Connect(function()

		if setArmed then

			if saveToSlot(slot) then
				refreshChip(slot)
				pulseChip(slot)
				setArmed = false
				refreshSetBtn()
				setStatus("SAVED SLOT " .. slot .. " " .. (savedModes[slot] or "Fly"))
			end

			return
		end

		if savedPositions[slot] then
			pulseChip(slot)
			task.spawn(function()
				travelToSlot(slot)
			end)
		else
			setStatus("EMPTY — PRESS SET")
		end

	end)

	-- Right click cycles the saved route mode F / T / W / J.
	button.MouseButton2Click:Connect(function()

		if not savedPositions[slot] then
			return
		end

		local mode = savedModes[slot] or "Fly"
		if mode == "Fly" then
			savedModes[slot] = "Teleport"
		elseif mode == "Teleport" then
			savedModes[slot] = "Walk"
		elseif mode == "Walk" then
			savedModes[slot] = "Jump"
		else
			savedModes[slot] = "Fly"
		end

		refreshChip(slot)
		setStatus("SLOT " .. slot .. " → " .. savedModes[slot])
	end)

	return button

end

do
	local ok, err = pcall(function()
		for i = 1, START_SLOTS do
			makeChip(i)
		end
		updateSlotScrollCanvas()
	end)

	if not ok then
		warn("[Icon Menu v5.2.2] slot deck init error:", err)
	end
end

-- ============================================================
-- ADD / REMOVE SLOT
-- ============================================================

local addBtn =
	Instance.new("TextButton")

addBtn.Size =
	UDim2.new(
		0, 24,
		0, 24
	)

addBtn.Position =
	UDim2.new(
		0, 10,
		0, 360
	)

addBtn.BackgroundColor3 =
	Color3.fromRGB(
		21,
		27,
		21
	)

addBtn.Text = "+"
addBtn.TextColor3 = Color3.new(1,1,1)
addBtn.Font = Enum.Font.GothamBold
addBtn.TextSize = 14

addBtn.Parent =
	mainPage

Instance.new(
	"UICorner",
	addBtn
).CornerRadius =
	UDim.new(0, 6)

local removeBtn =
	Instance.new("TextButton")

removeBtn.Size =
	UDim2.new(
		0, 24,
		0, 24
	)

removeBtn.Position =
	UDim2.new(
		0, 40,
		0, 360
	)

removeBtn.BackgroundColor3 =
	Color3.fromRGB(
		21,
		27,
		21
	)

removeBtn.Text = "-"
removeBtn.TextColor3 = Color3.new(1,1,1)
removeBtn.Font = Enum.Font.GothamBold
removeBtn.TextSize = 14

removeBtn.Parent =
	mainPage

Instance.new(
	"UICorner",
	removeBtn
).CornerRadius =
	UDim.new(0, 6)

addBtn.MouseButton1Click:Connect(function()

	if slotCount >= MAX_SLOTS then

		setStatus("MAX " .. MAX_SLOTS .. " SLOTS")

		return

	end

	slotCount += 1

	makeChip(slotCount)
	updateSlotScrollCanvas()

	setStatus(
		"ADDED SLOT " ..
		slotCount
	)

end)

removeBtn.MouseButton1Click:Connect(function()

	if slotCount <= 1 then
		return
	end

	savedPositions[slotCount] = nil
	savedModes[slotCount] = nil

	if chips[slotCount] then

		chips[slotCount]:Destroy()
		chips[slotCount] = nil
		chipRemoveButtons[slotCount] = nil

	end

	slotCount -= 1
	updateSlotScrollCanvas()

	setStatus("SLOT REMOVED")

end)

-- ============================================================
-- CLEAR ALL SAVED MACRO SLOTS
-- ============================================================

do
	local ok, err = pcall(function()
	
	local clearAllBtn = Instance.new("TextButton")
	clearAllBtn.Size = UDim2.new(0, 66, 0, 24)
	clearAllBtn.Position = UDim2.new(0, 176, 0, 360)
	clearAllBtn.BackgroundColor3 = Color3.fromRGB(105, 45, 45)
	clearAllBtn.Text = "CLEAR ALL"
	clearAllBtn.TextColor3 = Color3.new(1,1,1)
	clearAllBtn.Font = Enum.Font.GothamBold
	clearAllBtn.TextSize = 9
	clearAllBtn.Parent = mainPage
	Instance.new("UICorner", clearAllBtn).CornerRadius = UDim.new(0, 6)
	
	clearAllBtn.MouseButton1Click:Connect(function()
		for i = 1, slotCount do
			savedPositions[i] = nil
			savedModes[i] = nil
			refreshChip(i)
		end
	
		if slotDataBox then
			slotDataBox.Text = ""
		end
	
		setArmed = false
		refreshSetBtn()
		setStatus("ALL MACRO SLOTS CLEARED")
	end)
	
	end)

	if not ok then
		warn("[Icon Menu v5.2.2] clear-all GUI error:", err)
	end
end

-- ============================================================
-- MACRO LOOP COUNT
-- ============================================================

local loopLabel =
	Instance.new("TextLabel")

loopLabel.Size =
	UDim2.new(
		0, 14,
		0, 24
	)

loopLabel.Position =
	UDim2.new(
		0, 246,
		0, 360
	)

loopLabel.BackgroundTransparency = 1
loopLabel.Text = "L"
loopLabel.TextColor3 = Color3.new(1,1,1)
loopLabel.Font = Enum.Font.Gotham
loopLabel.TextSize = 11

loopLabel.Parent =
	mainPage

loopBox =
	Instance.new("TextBox")

loopBox.Size =
	UDim2.new(
		0, 38,
		0, 24
	)

loopBox.Position =
	UDim2.new(
		0, 260,
		0, 360
	)

loopBox.BackgroundColor3 =
	Color3.fromRGB(
		20,
		25,
		21
	)

loopBox.Text = "0"
loopBox.PlaceholderText = "0 = ∞"
loopBox.TextColor3 = Color3.new(1,1,1)
loopBox.Font = Enum.Font.Code
loopBox.TextSize = 11
loopBox.ClearTextOnFocus = false

loopBox.Parent =
	mainPage

Instance.new(
	"UICorner",
	loopBox
).CornerRadius =
	UDim.new(0, 6)

-- ============================================================
-- SLOT DATA BOX (SCROLLABLE)
-- ============================================================

local dataLabel =
	Instance.new("TextLabel")

dataLabel.Size =
	UDim2.new(
		0, 120,
		0, 18
	)

dataLabel.Position =
	UDim2.new(
		0, 10,
		0, 392
	)

dataLabel.BackgroundTransparency = 1

dataLabel.Text =
	"SLOT DATA / EDIT"

dataLabel.TextColor3 =
	Color3.fromRGB(
		150,
		175,
		150
	)

dataLabel.Font =
	Enum.Font.GothamBold

dataLabel.TextSize = 10

dataLabel.TextXAlignment =
	Enum.TextXAlignment.Left

dataLabel.Parent =
	mainPage

local slotDataScroll =
	Instance.new("ScrollingFrame")

slotDataScroll.Size =
	UDim2.new(
		1, -20,
		0, 70
	)

slotDataScroll.Position =
	UDim2.new(
		0, 10,
		0, 412
	)

slotDataScroll.BackgroundColor3 =
	Color3.fromRGB(
		16,
		20,
		17
	)

slotDataScroll.BorderSizePixel = 0
slotDataScroll.ScrollBarThickness = 5
slotDataScroll.ScrollingDirection =
	Enum.ScrollingDirection.Y
slotDataScroll.CanvasSize =
	UDim2.new(0, 0, 0, 70)
slotDataScroll.AutomaticCanvasSize =
	Enum.AutomaticSize.Y
slotDataScroll.Parent =
	mainPage

Instance.new(
	"UICorner",
	slotDataScroll
).CornerRadius =
	UDim.new(0, 6)

slotDataBox =
	Instance.new("TextBox")

slotDataBox.Size =
	UDim2.new(
		1, -10,
		0, 200
	)

slotDataBox.Position =
	UDim2.new(
		0, 0,
		0, 0
	)

slotDataBox.BackgroundTransparency = 1

slotDataBox.Text = ""

slotDataBox.PlaceholderText =
	"1|X|Y|Z|Fly\n2|X|Y|Z|Teleport\n3|X|Y|Z|Walk\n4|X|Y|Z|Jump"

slotDataBox.TextColor3 =
	Color3.fromRGB(
		220,
		230,
		220
	)

slotDataBox.PlaceholderColor3 =
	Color3.fromRGB(
		90,
		105,
		92
	)

slotDataBox.Font =
	Enum.Font.Code

slotDataBox.TextSize = 10

slotDataBox.ClearTextOnFocus = false
slotDataBox.MultiLine = true
slotDataBox.TextWrapped = false

slotDataBox.TextXAlignment =
	Enum.TextXAlignment.Left

slotDataBox.TextYAlignment =
	Enum.TextYAlignment.Top

slotDataBox.Parent =
	slotDataScroll

local dataPadding =
	Instance.new("UIPadding")

dataPadding.PaddingLeft =
	UDim.new(0, 6)

dataPadding.PaddingRight =
	UDim.new(0, 6)

dataPadding.PaddingTop =
	UDim.new(0, 5)

dataPadding.Parent =
	slotDataBox

-- Grow text box height with content so the ScrollingFrame can scroll.
local function refreshSlotDataCanvas()
	local lineCount = 1
	for _ in string.gmatch(slotDataBox.Text, "\n") do
		lineCount += 1
	end
	local contentHeight = math.max(70, lineCount * 14 + 12)
	slotDataBox.Size = UDim2.new(1, -10, 0, contentHeight)
	slotDataScroll.CanvasSize = UDim2.new(0, 0, 0, contentHeight)
end

slotDataBox:GetPropertyChangedSignal("Text"):Connect(refreshSlotDataCanvas)
refreshSlotDataCanvas()

-- ============================================================
-- MAIN MACRO CYCLE DELAY SLIDER (0 - 10 SECONDS)
-- ============================================================

do
	local ok, err = pcall(function()
	
	local delayLabel = Instance.new("TextLabel")
	delayLabel.Size = UDim2.new(0, 90, 0, 22)
	delayLabel.Position = UDim2.new(0, 10, 0, 490)
	delayLabel.BackgroundTransparency = 1
	delayLabel.TextColor3 = Color3.new(1,1,1)
	delayLabel.Font = Enum.Font.Gotham
	delayLabel.TextSize = 11
	delayLabel.TextXAlignment = Enum.TextXAlignment.Left
	delayLabel.Parent = mainPage
	
	local delayTrack = Instance.new("Frame")
	delayTrack.Size = UDim2.new(0, 150, 0, 6)
	delayTrack.Position = UDim2.new(0, 98, 0, 498)
	delayTrack.BackgroundColor3 = Color3.fromRGB(45, 55, 47)
	delayTrack.BorderSizePixel = 0
	delayTrack.Parent = mainPage
	Instance.new("UICorner", delayTrack).CornerRadius = UDim.new(1, 0)
	
	local delayKnob = Instance.new("TextButton")
	delayKnob.Size = UDim2.new(0, 14, 0, 14)
	delayKnob.AnchorPoint = Vector2.new(0.5, 0.5)
	delayKnob.BackgroundColor3 = Color3.fromRGB(124, 255, 107)
	delayKnob.Text = ""
	delayKnob.AutoButtonColor = false
	delayKnob.Parent = delayTrack
	Instance.new("UICorner", delayKnob).CornerRadius = UDim.new(1, 0)
	
	local delayValue = Instance.new("TextLabel")
	delayValue.Size = UDim2.new(0, 48, 0, 22)
	delayValue.Position = UDim2.new(1, -58, 0, 490)
	delayValue.BackgroundTransparency = 1
	delayValue.TextColor3 = Color3.fromRGB(190, 220, 190)
	delayValue.Font = Enum.Font.Code
	delayValue.TextSize = 11
	delayValue.TextXAlignment = Enum.TextXAlignment.Right
	delayValue.Parent = mainPage
	
	local delayDragging = false
	local DELAY_MIN = 0
	local DELAY_MAX = 10
	local DELAY_STEP = 0.5
	
	local function refreshDelaySlider()
		local alpha = (macroCycleDelay - DELAY_MIN) / (DELAY_MAX - DELAY_MIN)
		delayKnob.Position = UDim2.new(alpha, 0, 0.5, 0)
		delayLabel.Text = "Cycle Delay"
		delayValue.Text = string.format("%.1fs", macroCycleDelay)
	end
	
	local function setDelayFromScreenX(screenX)
		local left = delayTrack.AbsolutePosition.X
		local width = math.max(delayTrack.AbsoluteSize.X, 1)
		local alpha = math.clamp((screenX - left) / width, 0, 1)
		local raw = DELAY_MIN + alpha * (DELAY_MAX - DELAY_MIN)
		macroCycleDelay = math.floor(raw / DELAY_STEP + 0.5) * DELAY_STEP
		macroCycleDelay = math.clamp(macroCycleDelay, DELAY_MIN, DELAY_MAX)
		refreshDelaySlider()
	end
	
	local function beginDelayDrag(input)
		delayDragging = true
		setDelayFromScreenX(input.Position.X)
	end
	
	delayTrack.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDelayDrag(input)
		end
	end)
	
	delayKnob.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDelayDrag(input)
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if delayDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setDelayFromScreenX(input.Position.X)
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			delayDragging = false
		end
	end)
	
	refreshDelaySlider()
	
	end)

	if not ok then
		warn("[Icon Menu v5.2.2] delay slider error:", err)
	end
end

-- ============================================================
-- REAL COPY
-- ============================================================

copyBtn.MouseButton1Click:Connect(function()

	local data =
		serializeSlots()

	slotDataBox.Text = data

	if data == "" then

		setStatus("NO SAVED SLOTS")

		return

	end

	local clipboardSuccess =
		trySetClipboard(data)

	if clipboardSuccess then

		setStatus(
			"COPIED " ..
			countSaved() ..
			" SLOTS"
		)

	else

		setStatus(
			"DATA BOX READY"
		)

	end

end)

-- ============================================================
-- REAL PASTE
-- ============================================================

pasteBtn.MouseButton1Click:Connect(function()

	local source =
		slotDataBox.Text

	-- If the editor box is empty,
	-- try the executor clipboard.
	if
		type(source) ~= "string"
		or source:match("^%s*$")
	then

		local clipboard =
			tryGetClipboard()

		if clipboard then

			source = clipboard
			slotDataBox.Text =
				clipboard

		end

	end

	if
		type(source) ~= "string"
		or source:match("^%s*$")
	then

		setStatus(
			"NO SLOT DATA"
		)

		return

	end

	local imported, highestSlot =
		parseSlotData(source)

	if imported <= 0 then

		setStatus(
			"INVALID SLOT DATA"
		)

		return

	end

	-- Automatically create required chips.
	if highestSlot > slotCount then

		for i =
			slotCount + 1,
			highestSlot
		do

			makeChip(i)

		end

		slotCount =
			math.min(
				highestSlot,
				MAX_SLOTS
			)

	end

	updateSlotScrollCanvas()

	for i = 1, slotCount do
		refreshChip(i)
	end

	setStatus(
		"PASTED " ..
			imported ..
			" SLOTS"
	)

end)

-- ============================================================
-- OTHERS PAGE
-- ============================================================

-- ============================================================
-- STAGE DROPDOWN
-- ============================================================

local stageLabel =
	Instance.new("TextLabel")

stageLabel.Size =
	UDim2.new(
		0, 50,
		0, 26
	)

stageLabel.Position =
	UDim2.new(
		0, PAD,
		0, 10
	)

stageLabel.BackgroundTransparency = 1
stageLabel.Text = "Stage"
stageLabel.TextColor3 = Color3.new(1,1,1)
stageLabel.Font = Enum.Font.Gotham
stageLabel.TextSize = 13

stageLabel.Parent =
	othersPage

local stageBtn =
	Instance.new("TextButton")

stageBtn.Size =
	UDim2.new(
		0, 105,
		0, 24
	)

stageBtn.Position =
	UDim2.new(
		0, 60,
		0, 11
	)

stageBtn.BackgroundColor3 =
	Color3.fromRGB(
		0,
		120,
		200
	)

stageBtn.Text =
	"Stage 1 ▼"

stageBtn.TextColor3 =
	Color3.new(1,1,1)

stageBtn.Font =
	Enum.Font.GothamBold

stageBtn.TextSize = 12

stageBtn.Parent =
	othersPage

Instance.new(
	"UICorner",
	stageBtn
).CornerRadius =
	UDim.new(0, 6)

local stageList =
	Instance.new("ScrollingFrame")

stageList.Size =
	UDim2.new(
		0, 105,
		0, 160
	)

stageList.Position =
	UDim2.new(
		0, 60,
		0, 38
	)

stageList.BackgroundColor3 =
	Color3.fromRGB(
		30,
		30,
		45
	)

stageList.BorderSizePixel = 0
stageList.Visible = false
stageList.ZIndex = 20

stageList.ScrollBarThickness = 4

stageList.CanvasSize =
	UDim2.new(
		0, 0,
		0, 20 * 28
	)

stageList.Parent =
	othersPage

Instance.new(
	"UICorner",
	stageList
).CornerRadius =
	UDim.new(0, 6)

local stageLayout =
	Instance.new("UIListLayout")

stageLayout.Parent =
	stageList

for stage = 1, 20 do

	local option =
		Instance.new("TextButton")

	option.Size =
		UDim2.new(
			1, 0,
			0, 27
		)

	option.BackgroundColor3 =
		Color3.fromRGB(
			40,
			40,
			60
		)

	option.Text =
		"Stage " .. stage

	option.TextColor3 =
		Color3.new(1,1,1)

	option.Font =
		Enum.Font.Gotham

	option.TextSize = 12
	option.ZIndex = 21

	option.LayoutOrder =
		stage

	option.Parent =
		stageList

	option.MouseButton1Click:Connect(function()

		selectedStage =
			stage

		stageBtn.Text =
			"Stage " ..
			stage ..
			" ▼"

		stageList.Visible =
			false

		setStatus(
			"STAGE " ..
			stage
		)

	end)

end

stageBtn.MouseButton1Click:Connect(function()

	stageList.Visible =
		not stageList.Visible

end)

-- Manual Stage TP button

local stageTPBtn =
	Instance.new("TextButton")

stageTPBtn.Size =
	UDim2.new(
		0, 86,
		0, 24
	)

stageTPBtn.Position =
	UDim2.new(
		1, -96,
		0, 11
	)

stageTPBtn.BackgroundColor3 =
	Color3.fromRGB(
		0,
		130,
		220
	)

stageTPBtn.Text = "TELEPORT"
stageTPBtn.TextColor3 = Color3.new(1,1,1)
stageTPBtn.Font = Enum.Font.GothamBold
stageTPBtn.TextSize = 11

stageTPBtn.Parent =
	othersPage

Instance.new(
	"UICorner",
	stageTPBtn
).CornerRadius =
	UDim.new(0, 6)

stageTPBtn.MouseButton1Click:Connect(function()

	doStageTeleport()

end)


-- ============================================================
-- KEYBOARD GAME MACRO
-- Uses the SAME saved route slots from MAIN, but keeps the
-- game-specific Stage TP -> route -> Win/Spawn flow.
-- ============================================================

do
	local ok, err = pcall(function()

		local gameMacroLabel = Instance.new("TextLabel")
		gameMacroLabel.Size = UDim2.new(0, 86, 0, 26)
		gameMacroLabel.Position = UDim2.new(0, PAD, 0, 94)
		gameMacroLabel.BackgroundTransparency = 1
		gameMacroLabel.Text = "Game Macro"
		gameMacroLabel.TextColor3 = Color3.new(1,1,1)
		gameMacroLabel.Font = Enum.Font.Gotham
		gameMacroLabel.TextSize = 12
		gameMacroLabel.TextXAlignment = Enum.TextXAlignment.Left
		gameMacroLabel.Parent = othersPage

		keyboardMacroBtn = Instance.new("TextButton")
		keyboardMacroBtn.Size = UDim2.new(0, 94, 0, 24)
		keyboardMacroBtn.Position = UDim2.new(0, 96, 0, 95)
		keyboardMacroBtn.BackgroundColor3 = Color3.fromRGB(34, 66, 31)
		keyboardMacroBtn.Text = "GAME MACRO"
		keyboardMacroBtn.TextColor3 = Color3.fromRGB(183, 232, 164)
		keyboardMacroBtn.Font = Enum.Font.GothamBold
		keyboardMacroBtn.TextSize = 10
		keyboardMacroBtn.Parent = othersPage
		Instance.new("UICorner", keyboardMacroBtn).CornerRadius = UDim.new(0, 6)

		local keyboardLoopLabel = Instance.new("TextLabel")
		keyboardLoopLabel.Size = UDim2.new(0, 14, 0, 24)
		keyboardLoopLabel.Position = UDim2.new(0, 198, 0, 95)
		keyboardLoopLabel.BackgroundTransparency = 1
		keyboardLoopLabel.Text = "L"
		keyboardLoopLabel.TextColor3 = Color3.new(1,1,1)
		keyboardLoopLabel.Font = Enum.Font.Gotham
		keyboardLoopLabel.TextSize = 11
		keyboardLoopLabel.Parent = othersPage

		keyboardLoopBox = Instance.new("TextBox")
		keyboardLoopBox.Size = UDim2.new(0, 50, 0, 24)
		keyboardLoopBox.Position = UDim2.new(0, 214, 0, 95)
		keyboardLoopBox.BackgroundColor3 = Color3.fromRGB(20, 25, 21)
		keyboardLoopBox.Text = "0"
		keyboardLoopBox.PlaceholderText = "0 = inf"
		keyboardLoopBox.TextColor3 = Color3.new(1,1,1)
		keyboardLoopBox.Font = Enum.Font.Code
		keyboardLoopBox.TextSize = 10
		keyboardLoopBox.ClearTextOnFocus = false
		keyboardLoopBox.Parent = othersPage
		Instance.new("UICorner", keyboardLoopBox).CornerRadius = UDim.new(0, 6)

		refreshKeyboardMacroBtn = function()
			if not keyboardMacroBtn then
				return
			end

			keyboardMacroBtn.Text = macroRunning and "STOP" or "GAME MACRO"
			keyboardMacroBtn.BackgroundColor3 = macroRunning
				and Color3.fromRGB(178, 58, 58)
				or Color3.fromRGB(34, 66, 31)
			keyboardMacroBtn.TextColor3 = macroRunning
				and Color3.new(1,1,1)
				or Color3.fromRGB(183, 232, 164)
		end

		refreshKeyboardMacroBtn()

		keyboardMacroBtn.MouseButton1Click:Connect(function()
			if macroRunning then
				stopMacro("MANUAL")
			else
				startKeyboardMacro()
			end
		end)

	end)

	if not ok then
		warn("[Icon Menu v5.2.2] keyboard game-macro GUI error:", err)
	end
end

-- ============================================================
-- RARITY MULTI-SELECT DROPDOWN + AUTO BUY
-- ============================================================
-- Shop slots (from live log):
--   ShopItemsFrame.Common
--   ShopItemsFrame.Uncommon
--   ShopItemsFrame.Rare
--   ShopItemsFrame.Mysterious  <-- 4th slot is ALWAYS this key
--                                (UI may show Epic/Legendary/Mythic/...)
-- BuyWins RemoteEvent expects the slot KEY, not the display rarity.
-- ============================================================

do
	local ok, err = pcall(function()

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Size = UDim2.new(0, 48, 0, 26)
	rarityLabel.Position = UDim2.new(0, PAD, 0, 55)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Text = "Slots"
	rarityLabel.TextColor3 = Color3.new(1,1,1)
	rarityLabel.Font = Enum.Font.Gotham
	rarityLabel.TextSize = 13
	rarityLabel.Parent = othersPage

	-- Only the 4 real shop slot keys
	local rarities = { "Common", "Uncommon", "Rare", "Mysterious" }
	local rarityColors = {
		Common = Color3.fromRGB(120, 120, 120),
		Uncommon = Color3.fromRGB(40, 160, 70),
		Rare = Color3.fromRGB(40, 100, 200),
		Mysterious = Color3.fromRGB(180, 80, 200),
	}

	local rarityBtn = Instance.new("TextButton")
	rarityBtn.Size = UDim2.new(0, 104, 0, 24)
	rarityBtn.Position = UDim2.new(0, 60, 0, 56)
	rarityBtn.BackgroundColor3 = Color3.fromRGB(55, 65, 58)
	rarityBtn.TextColor3 = Color3.new(1,1,1)
	rarityBtn.Font = Enum.Font.GothamBold
	rarityBtn.TextSize = 10
	rarityBtn.Text = "Slots ▼"
	rarityBtn.Parent = othersPage
	Instance.new("UICorner", rarityBtn).CornerRadius = UDim.new(0, 6)

	local rarityList = Instance.new("ScrollingFrame")
	rarityList.Size = UDim2.new(0, 118, 0, 120)
	rarityList.Position = UDim2.new(0, 60, 0, 83)
	rarityList.BackgroundColor3 = Color3.fromRGB(25, 30, 27)
	rarityList.BorderSizePixel = 0
	rarityList.Visible = false
	rarityList.ZIndex = 30
	rarityList.ScrollBarThickness = 4
	rarityList.ScrollingDirection = Enum.ScrollingDirection.Y
	rarityList.CanvasSize = UDim2.new(0, 0, 0, #rarities * 27 + 4)
	rarityList.Parent = othersPage
	Instance.new("UICorner", rarityList).CornerRadius = UDim.new(0, 6)

	local rarityLayout = Instance.new("UIListLayout")
	rarityLayout.Padding = UDim.new(0, 1)
	rarityLayout.Parent = rarityList

	local rarityOptionButtons = {}

	local function getSelectedRarityList()
		local list = {}
		for _, rarity in ipairs(rarities) do
			if selectedRarities[rarity] then
				table.insert(list, rarity)
			end
		end
		return list
	end

	local function refreshRarityDropdown()
		local selected = getSelectedRarityList()
		if #selected == 0 then
			rarityBtn.Text = "None ▼"
		elseif #selected == 1 then
			rarityBtn.Text = selected[1] .. " ▼"
		else
			rarityBtn.Text = tostring(#selected) .. " selected ▼"
		end

		for rarity, button in pairs(rarityOptionButtons) do
			local checked = selectedRarities[rarity] == true
			button.Text = (checked and "✓ " or "□ ") .. rarity
			button.BackgroundColor3 = checked and rarityColors[rarity] or Color3.fromRGB(35, 40, 36)
		end
	end

	for index, rarity in ipairs(rarities) do
		local option = Instance.new("TextButton")
		option.Size = UDim2.new(1, -4, 0, 26)
		option.BackgroundColor3 = Color3.fromRGB(35, 40, 36)
		option.TextColor3 = Color3.new(1,1,1)
		option.Font = Enum.Font.Gotham
		option.TextSize = 10
		option.TextXAlignment = Enum.TextXAlignment.Left
		option.LayoutOrder = index
		option.ZIndex = 31
		option.Parent = rarityList
		Instance.new("UICorner", option).CornerRadius = UDim.new(0, 4)
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.Parent = option
		rarityOptionButtons[rarity] = option

		option.MouseButton1Click:Connect(function()
			selectedRarities[rarity] = not selectedRarities[rarity]
			refreshRarityDropdown()
			setStatus("SLOT " .. rarity .. (selectedRarities[rarity] and " ON" or " OFF"))
		end)
	end

	rarityBtn.MouseButton1Click:Connect(function()
		rarityList.Visible = not rarityList.Visible
	end)

	refreshRarityDropdown()

	local autoBuyBtn = Instance.new("TextButton")
	autoBuyBtn.Size = UDim2.new(0, 76, 0, 24)
	autoBuyBtn.Position = UDim2.new(0, 170, 0, 56)
	autoBuyBtn.BackgroundColor3 = Color3.fromRGB(32, 40, 34)
	autoBuyBtn.Text = "AUTO: OFF"
	autoBuyBtn.TextColor3 = Color3.new(1,1,1)
	autoBuyBtn.Font = Enum.Font.GothamBold
	autoBuyBtn.TextSize = 10
	autoBuyBtn.Parent = othersPage
	Instance.new("UICorner", autoBuyBtn).CornerRadius = UDim.new(0, 6)

	local cooldownLabel = Instance.new("TextLabel")
	cooldownLabel.Size = UDim2.new(0, 48, 0, 24)
	cooldownLabel.Position = UDim2.new(1, -55, 0, 56)
	cooldownLabel.BackgroundTransparency = 1
	cooldownLabel.Text = ""
	cooldownLabel.TextColor3 = Color3.fromRGB(180,180,180)
	cooldownLabel.Font = Enum.Font.Code
	cooldownLabel.TextSize = 10
	cooldownLabel.Parent = othersPage

	autoBuyBtn.MouseButton1Click:Connect(function()
		if not autoBuy and #getSelectedRarityList() == 0 then
			setStatus("SELECT AT LEAST 1 SLOT")
			return
		end

		autoBuy = not autoBuy
		autoBuyBtn.Text = autoBuy and "AUTO: ON" or "AUTO: OFF"
		autoBuyBtn.BackgroundColor3 = autoBuy and Color3.fromRGB(60,160,60) or Color3.fromRGB(32,40,34)

		if autoBuy then
			lastBuyCycle = os.clock() - BUY_COOLDOWN
		end

		setStatus(autoBuy and "AUTO BUY ON" or "AUTO BUY OFF")
	end)

	-- ============================================================
	-- AUTO BUY LOOP (slot-key based)
	-- ============================================================
	local SHOP_SLOT_KEYS = { "Common", "Uncommon", "Rare", "Mysterious" }

	local function getShopItemsFrame()
		local pg = player:FindFirstChild("PlayerGui")
		if not pg then return nil end
		local speed = pg:FindFirstChild("SpeedGameUI")
		if not speed then return nil end
		local modals = speed:FindFirstChild("Modals")
		if not modals then return nil end
		local shopModal = modals:FindFirstChild("ItemShopModal")
		if not shopModal then return nil end
		return shopModal:FindFirstChild("ShopItemsFrame")
	end

	local function slotIsSoldOut(slotFrame)
		if not slotFrame then return true end
		for _, obj in ipairs(slotFrame:GetDescendants()) do
			if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
				local t = string.lower(tostring(obj.Text or ""))
				if (string.find(t, "sold out", 1, true) or string.find(t, "soldout", 1, true))
					and obj:IsA("GuiObject") and obj.Visible
				then
					return true
				end
			end
		end
		return false
	end

	local function getDisplayRarity(slotFrame)
		if not slotFrame then return nil end
		local rarityFolder = slotFrame:FindFirstChild("Rarity")
		if not rarityFolder then return nil end
		local rarityText = rarityFolder:FindFirstChild("RarityText")
		if rarityText and (rarityText:IsA("TextLabel") or rarityText:IsA("TextButton")) then
			return tostring(rarityText.Text or "")
		end
		return nil
	end

	local function scanLiveShopSlots()
		local results = {}
		local frame = getShopItemsFrame()
		if not frame then
			return results, false
		end
		for _, key in ipairs(SHOP_SLOT_KEYS) do
			local slotFrame = frame:FindFirstChild(key)
			if slotFrame then
				table.insert(results, {
					key = key,
					display = getDisplayRarity(slotFrame) or key,
					soldOut = slotIsSoldOut(slotFrame),
				})
			end
		end
		return results, true
	end

	-- Buy up to 2 selected slots that are not sold out
	local function getBuyTargets()
		local slots, shopOpen = scanLiveShopSlots()
		local targets = {}
		if not shopOpen then
			return targets, slots, shopOpen
		end
		for _, slot in ipairs(slots) do
			if not slot.soldOut and selectedRarities[slot.key] then
				table.insert(targets, slot)
				if #targets >= 2 then
					break
				end
			end
		end
		return targets, slots, shopOpen
	end

	task.spawn(function()
		while true do
			if autoBuy then
				local currentTime = os.clock()
				local elapsed = currentTime - lastBuyCycle

				if elapsed >= BUY_COOLDOWN then
					local buyRemote = getBuyRemote()
					local targets, slots, shopOpen = getBuyTargets()

					if not buyRemote then
						setStatus("BUY REMOTE MISSING")
						lastBuyCycle = os.clock() - (BUY_COOLDOWN - 15)

					elseif #getSelectedRarityList() == 0 then
						setStatus("NO SLOT SELECTED")
						lastBuyCycle = os.clock()

					elseif not shopOpen then
						-- Shop modal may be closed; still try selected keys directly
						local selected = getSelectedRarityList()
						local totalSuccess = 0
						local boughtNames = {}
						for i, key in ipairs(selected) do
							if i > 2 then break end
							local okFire = false
							for _ = 1, 3 do
								if fireRemote(buyRemote, key) then
									totalSuccess += 1
									okFire = true
								end
								task.wait(0.30)
							end
							if okFire then
								table.insert(boughtNames, key)
							end
						end
						lastBuyCycle = os.clock()
						if totalSuccess > 0 then
							setStatus("BOUGHT " .. totalSuccess .. "x [" .. table.concat(boughtNames, ", ") .. "]")
						else
							setStatus("SHOP CLOSED — BUY ATTEMPTED")
						end

					elseif #targets == 0 then
						local summary = {}
						for _, s in ipairs(slots) do
							table.insert(summary, s.key .. (s.soldOut and "=OUT" or ("=" .. tostring(s.display))))
						end
						setStatus("NOTHING TO BUY: " .. table.concat(summary, " "))
						lastBuyCycle = os.clock()

					else
						local totalSuccess = 0
						local boughtNames = {}
						for _, slot in ipairs(targets) do
							local okFire = false
							for _ = 1, 3 do
								if fireRemote(buyRemote, slot.key) then
									totalSuccess += 1
									okFire = true
								end
								task.wait(0.30)
							end
							if okFire then
								table.insert(boughtNames, slot.key .. "(" .. tostring(slot.display) .. ")")
							end
						end
						lastBuyCycle = os.clock()
						if totalSuccess > 0 then
							setStatus("BOUGHT " .. totalSuccess .. "x [" .. table.concat(boughtNames, ", ") .. "]")
						else
							local names = {}
							for _, s in ipairs(targets) do table.insert(names, s.key) end
							setStatus("BUY FAILED: " .. table.concat(names, ", "))
						end
					end
				else
					cooldownLabel.Text = math.ceil(BUY_COOLDOWN - elapsed) .. "s"
				end
			else
				cooldownLabel.Text = ""
			end

			task.wait(1)
		end
	end)

	end)

	if not ok then
		warn("[Icon Menu v5.2.5] rarity/auto-buy GUI error:", err)
	end
end

-- ============================================================
-- MENU TOGGLE KEY BIND
-- ============================================================

do
	local ok, err = pcall(function()
	
	local menuBindLabel = Instance.new("TextLabel")
	menuBindLabel.Size = UDim2.new(0, 88, 0, 26)
	menuBindLabel.Position = UDim2.new(0, 10, 0, 215)
	menuBindLabel.BackgroundTransparency = 1
	menuBindLabel.Text = "Menu Toggle"
	menuBindLabel.TextColor3 = Color3.new(1,1,1)
	menuBindLabel.Font = Enum.Font.Gotham
	menuBindLabel.TextSize = 12
	menuBindLabel.TextXAlignment = Enum.TextXAlignment.Left
	menuBindLabel.Parent = othersPage
	
	local menuBindBtn = Instance.new("TextButton")
	menuBindBtn.Size = UDim2.new(0, 120, 0, 24)
	menuBindBtn.Position = UDim2.new(0, 105, 0, 216)
	menuBindBtn.BackgroundColor3 = Color3.fromRGB(20,25,21)
	menuBindBtn.TextColor3 = Color3.new(1,1,1)
	menuBindBtn.Font = Enum.Font.Code
	menuBindBtn.TextSize = 10
	menuBindBtn.Parent = othersPage
	Instance.new("UICorner", menuBindBtn).CornerRadius = UDim.new(0, 6)
	
	refreshMenuBindLabel = function()
		if rebindingMenu then
			menuBindBtn.Text = "PRESS KEY"
			menuBindBtn.BackgroundColor3 = Color3.fromRGB(0,110,194)
		else
			menuBindBtn.Text = "BIND : " .. menuToggleKey.Name
			menuBindBtn.BackgroundColor3 = Color3.fromRGB(20,25,21)
		end
	end
	
	refreshMenuBindLabel()
	
	menuBindBtn.MouseButton1Click:Connect(function()
		rebindingMenu = true
		refreshMenuBindLabel()
		setStatus("PRESS MENU KEY")
	end)
	
	end)

	if not ok then
		warn("[Icon Menu v5.2.2] menu-key bind GUI error:", err)
	end
end

-- ============================================================
-- MACRO INFORMATION
-- ============================================================

do
	local ok, err = pcall(function()
	
	local infoLabel = Instance.new("TextLabel")
	infoLabel.Size = UDim2.new(1, -20, 0, 120)
	infoLabel.Position = UDim2.new(0, 10, 0, 255)
	infoLabel.BackgroundTransparency = 1
	infoLabel.Text =
		"KEYBOARD GAME MACRO:\n" ..
		"1. Stage TP / save Win baseline\n" ..
		"2. Run MAIN F / T / W / J saved slots\n" ..
		"3. Last slot = win portal\n" ..
		"4. Win → cycle delay → repeat\n" ..
		"5. Spawn no Win → retry | Stuck → 2 jumps"
	infoLabel.TextColor3 = Color3.fromRGB(140,150,140)
	infoLabel.Font = Enum.Font.Gotham
	infoLabel.TextSize = 11
	infoLabel.TextXAlignment = Enum.TextXAlignment.Left
	infoLabel.TextYAlignment = Enum.TextYAlignment.Top
	infoLabel.Parent = othersPage
	
	end)

	if not ok then
		warn("[Icon Menu v5.2.2] macro info GUI error:", err)
	end
end

-- ============================================================
-- OPEN / CLOSE MENU
-- Icon click handler is connected early in v5.2.1.
-- ============================================================

-- ============================================================
-- KEYBOARD INPUT + REBIND
-- ============================================================

UserInputService.InputBegan:Connect(function(input, gpe)

	if rebindingMenu then
		if input.KeyCode == Enum.KeyCode.Escape then
			rebindingMenu = false
			refreshMenuBindLabel()
			setStatus("MENU BIND CANCELLED")
			return
		end

		if input.KeyCode ~= Enum.KeyCode.Unknown then
			menuToggleKey = input.KeyCode
			rebindingMenu = false
			refreshMenuBindLabel()
			setStatus("MENU BOUND: " .. menuToggleKey.Name)
		end
		return
	end

	if rebindingFly then

		if input.KeyCode == Enum.KeyCode.Escape then
			rebindingFly = false
			refreshFlyBindLabel()
			setStatus("BIND CANCELLED")
			return
		end

		if input.KeyCode ~= Enum.KeyCode.Unknown then
			flyHoldKey = input.KeyCode
			rebindingFly = false
			refreshFlyBindLabel()
			setStatus("BOUND: " .. flyHoldKey.Name)
		end
		return
	end

	if gpe then
		return
	end

	if input.KeyCode == menuToggleKey then
		setMenuOpen(not guiOpen)
		return
	end

	if flyHoldEnabled and input.KeyCode == flyHoldKey then
		flyHoldDown = true
		updateFly()
	end

end)

UserInputService.InputEnded:Connect(function(input)
	if flyHoldEnabled and input.KeyCode == flyHoldKey then
		flyHoldDown = false
		updateFly()
	end
end)

-- ============================================================
-- READY
-- ============================================================

-- ============================================================
-- MONKEY PAGE — instant repetitive route macro
-- Uses slots set on MAIN. No Stage TP / Win wait / portal delay.
-- ============================================================

do
	local ok, err = pcall(function()

		local monkeyTitle = Instance.new("TextLabel")
		monkeyTitle.Size = UDim2.new(1, -20, 0, 22)
		monkeyTitle.Position = UDim2.new(0, 10, 0, 10)
		monkeyTitle.BackgroundTransparency = 1
		monkeyTitle.Text = "MONKEY MACRO"
		monkeyTitle.TextColor3 = Color3.fromRGB(124, 255, 107)
		monkeyTitle.Font = Enum.Font.GothamBold
		monkeyTitle.TextSize = 13
		monkeyTitle.TextXAlignment = Enum.TextXAlignment.Left
		monkeyTitle.Parent = monkeyPage

		local monkeyDesc = Instance.new("TextLabel")
		monkeyDesc.Size = UDim2.new(1, -20, 0, 70)
		monkeyDesc.Position = UDim2.new(0, 10, 0, 36)
		monkeyDesc.BackgroundTransparency = 1
		monkeyDesc.Text =
			"Uses the route slots you set on MAIN.\n" ..
			"• Starts instantly\n" ..
			"• Loops the route as fast as possible\n" ..
			"• No Stage TP · No Win/Spawn wait · No portal delay"
		monkeyDesc.TextColor3 = Color3.fromRGB(160, 175, 160)
		monkeyDesc.Font = Enum.Font.Gotham
		monkeyDesc.TextSize = 11
		monkeyDesc.TextXAlignment = Enum.TextXAlignment.Left
		monkeyDesc.TextYAlignment = Enum.TextYAlignment.Top
		monkeyDesc.Parent = monkeyPage

		local monkeyMacroLabel = Instance.new("TextLabel")
		monkeyMacroLabel.Size = UDim2.new(0, 86, 0, 26)
		monkeyMacroLabel.Position = UDim2.new(0, 10, 0, 120)
		monkeyMacroLabel.BackgroundTransparency = 1
		monkeyMacroLabel.Text = "Monkey Macro"
		monkeyMacroLabel.TextColor3 = Color3.new(1, 1, 1)
		monkeyMacroLabel.Font = Enum.Font.Gotham
		monkeyMacroLabel.TextSize = 12
		monkeyMacroLabel.TextXAlignment = Enum.TextXAlignment.Left
		monkeyMacroLabel.Parent = monkeyPage

		monkeyMacroBtn = Instance.new("TextButton")
		monkeyMacroBtn.Size = UDim2.new(0, 110, 0, 28)
		monkeyMacroBtn.Position = UDim2.new(0, 100, 0, 119)
		monkeyMacroBtn.BackgroundColor3 = Color3.fromRGB(34, 66, 31)
		monkeyMacroBtn.Text = "MONKEY MACRO"
		monkeyMacroBtn.TextColor3 = Color3.fromRGB(183, 232, 164)
		monkeyMacroBtn.Font = Enum.Font.GothamBold
		monkeyMacroBtn.TextSize = 11
		monkeyMacroBtn.Parent = monkeyPage
		Instance.new("UICorner", monkeyMacroBtn).CornerRadius = UDim.new(0, 6)

		local monkeyLoopLabel = Instance.new("TextLabel")
		monkeyLoopLabel.Size = UDim2.new(0, 14, 0, 24)
		monkeyLoopLabel.Position = UDim2.new(0, 220, 0, 121)
		monkeyLoopLabel.BackgroundTransparency = 1
		monkeyLoopLabel.Text = "L"
		monkeyLoopLabel.TextColor3 = Color3.new(1, 1, 1)
		monkeyLoopLabel.Font = Enum.Font.Gotham
		monkeyLoopLabel.TextSize = 11
		monkeyLoopLabel.Parent = monkeyPage

		monkeyLoopBox = Instance.new("TextBox")
		monkeyLoopBox.Size = UDim2.new(0, 50, 0, 24)
		monkeyLoopBox.Position = UDim2.new(0, 236, 0, 121)
		monkeyLoopBox.BackgroundColor3 = Color3.fromRGB(20, 25, 21)
		monkeyLoopBox.Text = "0"
		monkeyLoopBox.PlaceholderText = "0 = inf"
		monkeyLoopBox.TextColor3 = Color3.new(1, 1, 1)
		monkeyLoopBox.Font = Enum.Font.Code
		monkeyLoopBox.TextSize = 10
		monkeyLoopBox.ClearTextOnFocus = false
		monkeyLoopBox.Parent = monkeyPage
		Instance.new("UICorner", monkeyLoopBox).CornerRadius = UDim.new(0, 6)

		refreshMonkeyMacroBtn = function()
			if not monkeyMacroBtn then
				return
			end
			monkeyMacroBtn.Text = macroRunning and "STOP" or "MONKEY MACRO"
			monkeyMacroBtn.BackgroundColor3 = macroRunning
				and Color3.fromRGB(178, 58, 58)
				or Color3.fromRGB(34, 66, 31)
			monkeyMacroBtn.TextColor3 = macroRunning
				and Color3.new(1, 1, 1)
				or Color3.fromRGB(183, 232, 164)
		end

		refreshMonkeyMacroBtn()

		monkeyMacroBtn.MouseButton1Click:Connect(function()
			if macroRunning then
				stopMacro("MANUAL")
			else
				startMonkeyMacro()
			end
		end)

		local tipLabel = Instance.new("TextLabel")
		tipLabel.Size = UDim2.new(1, -20, 0, 60)
		tipLabel.Position = UDim2.new(0, 10, 0, 155)
		tipLabel.BackgroundTransparency = 1
		tipLabel.Text =
			"TIP: Set route on MAIN → start MONKEY MACRO.\n" ..
			"No Stage TP / Win wait / portal delay."
		tipLabel.TextColor3 = Color3.fromRGB(130, 145, 130)
		tipLabel.Font = Enum.Font.Gotham
		tipLabel.TextSize = 11
		tipLabel.TextXAlignment = Enum.TextXAlignment.Left
		tipLabel.TextYAlignment = Enum.TextYAlignment.Top
		tipLabel.Parent = monkeyPage

		-- ============================================================
		-- MONKEY AUTO BUY CHARMS
		-- BuyCharm:FireServer(slot) where slot = 1, 2, or 3
		-- Rarity read from PlayerGui.Main.UIs.ItemShop.Options.ItemN.Rarity
		-- ============================================================
		local buyHeader = Instance.new("TextLabel")
		buyHeader.Size = UDim2.new(1, -20, 0, 20)
		buyHeader.Position = UDim2.new(0, 10, 0, 220)
		buyHeader.BackgroundTransparency = 1
		buyHeader.Text = "AUTO BUY CHARMS (slots 1-3)"
		buyHeader.TextColor3 = Color3.fromRGB(124, 255, 107)
		buyHeader.Font = Enum.Font.GothamBold
		buyHeader.TextSize = 12
		buyHeader.TextXAlignment = Enum.TextXAlignment.Left
		buyHeader.Parent = monkeyPage

		local rarityList = { "Rare", "Epic", "Legendary", "Mythic" }
		local rarityColors = {
			Rare = Color3.fromRGB(40, 100, 200),
			Epic = Color3.fromRGB(140, 60, 200),
			Legendary = Color3.fromRGB(220, 160, 40),
			Mythic = Color3.fromRGB(220, 60, 80),
		}
		local rarityButtons = {}

		local function refreshRarityButtons()
			for _, rarity in ipairs(rarityList) do
				local btn = rarityButtons[rarity]
				if btn then
					local on = monkeyCharmRarities[rarity] == true
					btn.Text = (on and "✓ " or "□ ") .. rarity
					btn.BackgroundColor3 = on and rarityColors[rarity] or Color3.fromRGB(32, 40, 34)
				end
			end
		end

		for i, rarity in ipairs(rarityList) do
			local col = (i - 1) % 2
			local row = math.floor((i - 1) / 2)
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(0, 140, 0, 24)
			btn.Position = UDim2.new(0, 10 + col * 148, 0, 246 + row * 30)
			btn.BackgroundColor3 = Color3.fromRGB(32, 40, 34)
			btn.Text = "□ " .. rarity
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.Font = Enum.Font.GothamBold
			btn.TextSize = 11
			btn.Parent = monkeyPage
			Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
			rarityButtons[rarity] = btn

			btn.MouseButton1Click:Connect(function()
				monkeyCharmRarities[rarity] = not monkeyCharmRarities[rarity]
				refreshRarityButtons()
				setStatus("CHARM " .. rarity .. (monkeyCharmRarities[rarity] and " ON" or " OFF"))
			end)
		end
		refreshRarityButtons()

		local liveLabel = Instance.new("TextLabel")
		liveLabel.Size = UDim2.new(1, -20, 0, 36)
		liveLabel.Position = UDim2.new(0, 10, 0, 312)
		liveLabel.BackgroundTransparency = 1
		liveLabel.Text = "Shop: scanning..."
		liveLabel.TextColor3 = Color3.fromRGB(180, 200, 180)
		liveLabel.Font = Enum.Font.Code
		liveLabel.TextSize = 11
		liveLabel.TextXAlignment = Enum.TextXAlignment.Left
		liveLabel.TextYAlignment = Enum.TextYAlignment.Top
		liveLabel.Parent = monkeyPage

		local monkeyAutoBuyBtn = Instance.new("TextButton")
		monkeyAutoBuyBtn.Size = UDim2.new(0, 100, 0, 26)
		monkeyAutoBuyBtn.Position = UDim2.new(0, 10, 0, 356)
		monkeyAutoBuyBtn.BackgroundColor3 = Color3.fromRGB(32, 40, 34)
		monkeyAutoBuyBtn.Text = "AUTO: OFF"
		monkeyAutoBuyBtn.TextColor3 = Color3.new(1, 1, 1)
		monkeyAutoBuyBtn.Font = Enum.Font.GothamBold
		monkeyAutoBuyBtn.TextSize = 11
		monkeyAutoBuyBtn.Parent = monkeyPage
		Instance.new("UICorner", monkeyAutoBuyBtn).CornerRadius = UDim.new(0, 6)

		local cdLabel = Instance.new("TextLabel")
		cdLabel.Size = UDim2.new(0, 24, 0, 26)
		cdLabel.Position = UDim2.new(0, 120, 0, 356)
		cdLabel.BackgroundTransparency = 1
		cdLabel.Text = "CD"
		cdLabel.TextColor3 = Color3.new(1, 1, 1)
		cdLabel.Font = Enum.Font.Gotham
		cdLabel.TextSize = 11
		cdLabel.Parent = monkeyPage

		local cdBox = Instance.new("TextBox")
		cdBox.Size = UDim2.new(0, 48, 0, 24)
		cdBox.Position = UDim2.new(0, 148, 0, 357)
		cdBox.BackgroundColor3 = Color3.fromRGB(20, 25, 21)
		cdBox.Text = tostring(monkeyBuyCooldown)
		cdBox.PlaceholderText = "sec"
		cdBox.TextColor3 = Color3.new(1, 1, 1)
		cdBox.Font = Enum.Font.Code
		cdBox.TextSize = 11
		cdBox.ClearTextOnFocus = false
		cdBox.Parent = monkeyPage
		Instance.new("UICorner", cdBox).CornerRadius = UDim.new(0, 6)

		cdBox.FocusLost:Connect(function()
			local n = tonumber(cdBox.Text)
			if n then
				monkeyBuyCooldown = math.clamp(math.floor(n), 3, 600)
				cdBox.Text = tostring(monkeyBuyCooldown)
			else
				cdBox.Text = tostring(monkeyBuyCooldown)
			end
		end)

		local cooldownLabel = Instance.new("TextLabel")
		cooldownLabel.Size = UDim2.new(0, 70, 0, 26)
		cooldownLabel.Position = UDim2.new(0, 206, 0, 356)
		cooldownLabel.BackgroundTransparency = 1
		cooldownLabel.Text = ""
		cooldownLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
		cooldownLabel.Font = Enum.Font.Code
		cooldownLabel.TextSize = 11
		cooldownLabel.Parent = monkeyPage

		local function anyCharmRaritySelected()
			for _, rarity in ipairs(rarityList) do
				if monkeyCharmRarities[rarity] then
					return true
				end
			end
			return false
		end

		monkeyAutoBuyBtn.MouseButton1Click:Connect(function()
			if not monkeyAutoBuy and not anyCharmRaritySelected() then
				setStatus("SELECT AT LEAST 1 RARITY")
				return
			end
			monkeyAutoBuy = not monkeyAutoBuy
			monkeyAutoBuyBtn.Text = monkeyAutoBuy and "AUTO: ON" or "AUTO: OFF"
			monkeyAutoBuyBtn.BackgroundColor3 = monkeyAutoBuy
				and Color3.fromRGB(60, 160, 60)
				or Color3.fromRGB(32, 40, 34)
			if monkeyAutoBuy then
				lastMonkeyBuy = os.clock() - monkeyBuyCooldown
			end
			setStatus(monkeyAutoBuy and "CHARM AUTO BUY ON" or "CHARM AUTO BUY OFF")
		end)

		local noteLabel = Instance.new("TextLabel")
		noteLabel.Size = UDim2.new(1, -20, 0, 55)
		noteLabel.Position = UDim2.new(0, 10, 0, 392)
		noteLabel.BackgroundTransparency = 1
		noteLabel.Text =
			"BuyCharm = slot number (1 / 2 / 3).\n" ..
			"Shop rarities swap about every 5 minutes.\n" ..
			"Only buys slots whose LIVE rarity is selected."
		noteLabel.TextColor3 = Color3.fromRGB(120, 135, 120)
		noteLabel.Font = Enum.Font.Gotham
		noteLabel.TextSize = 10
		noteLabel.TextXAlignment = Enum.TextXAlignment.Left
		noteLabel.TextYAlignment = Enum.TextYAlignment.Top
		noteLabel.Parent = monkeyPage

		-- Read live shop slots from ItemShop UI
		local function getItemShopOptions()
			local pg = player:FindFirstChild("PlayerGui")
			if not pg then return nil end
			local main = pg:FindFirstChild("Main")
			if not main then return nil end
			local uis = main:FindFirstChild("UIs")
			if not uis then return nil end
			local itemShop = uis:FindFirstChild("ItemShop")
			if not itemShop then return nil end
			return itemShop:FindFirstChild("Options")
		end

		local function readShopSlots()
			local options = getItemShopOptions()
			local slots = {}
			if not options then
				return slots, false
			end
			for i = 1, 3 do
				local item = options:FindFirstChild("Item" .. i)
				local rarityName = nil
				if item then
					local rarityLabel = item:FindFirstChild("Rarity")
					if rarityLabel and (rarityLabel:IsA("TextLabel") or rarityLabel:IsA("TextButton")) then
						rarityName = tostring(rarityLabel.Text or "")
					end
					-- also search descendants if direct child missing
					if (not rarityName or rarityName == "") then
						for _, d in ipairs(item:GetDescendants()) do
							if (d:IsA("TextLabel") or d:IsA("TextButton")) and string.lower(d.Name) == "rarity" then
								rarityName = tostring(d.Text or "")
								break
							end
						end
					end
				end
				table.insert(slots, {
					slot = i,
					rarity = rarityName or "?",
				})
			end
			return slots, true
		end

		local function normalizeRarity(text)
			text = string.lower(tostring(text or ""))
			if string.find(text, "mythic", 1, true) then return "Mythic" end
			if string.find(text, "legend", 1, true) then return "Legendary" end
			if string.find(text, "epic", 1, true) then return "Epic" end
			if string.find(text, "rare", 1, true) then return "Rare" end
			-- common extras some games use
			if string.find(text, "common", 1, true) then return "Common" end
			if string.find(text, "uncommon", 1, true) then return "Uncommon" end
			return nil
		end

		-- Live shop preview + auto-buy loop
		task.spawn(function()
			while true do
				local slots, shopFound = readShopSlots()
				if shopFound and #slots > 0 then
					local parts = {}
					for _, s in ipairs(slots) do
						local norm = normalizeRarity(s.rarity) or s.rarity
						local mark = (normalizeRarity(s.rarity) and monkeyCharmRarities[normalizeRarity(s.rarity)]) and "*" or ""
						table.insert(parts, tostring(s.slot) .. "=" .. tostring(norm) .. mark)
					end
					liveLabel.Text = "Shop: " .. table.concat(parts, "  ")
				else
					liveLabel.Text = "Shop: ItemShop not found (open shop once)"
				end

				if monkeyAutoBuy then
					local elapsed = os.clock() - lastMonkeyBuy
					if elapsed >= monkeyBuyCooldown then
						local remote = getBuyCharmRemote()
						if not remote then
							setStatus("BuyCharm REMOTE MISSING")
							lastMonkeyBuy = os.clock()
						else
							slots, shopFound = readShopSlots()
							local bought = {}

							if shopFound then
								for _, s in ipairs(slots) do
									local norm = normalizeRarity(s.rarity)
									if norm and monkeyCharmRarities[norm] then
										local okFire = false
										for _ = 1, 2 do
											if fireRemote(remote, s.slot) then
												okFire = true
											end
											task.wait(0.25)
										end
										if okFire then
											table.insert(bought, "slot" .. s.slot .. "(" .. norm .. ")")
										end
									end
								end
							else
								-- Fallback: if UI missing, still try selected rarities as... no, must use slot numbers
								setStatus("OPEN ITEMSHOP — need live rarities")
							end

							lastMonkeyBuy = os.clock()
							if #bought > 0 then
								setStatus("CHARM BUY: " .. table.concat(bought, ", "))
							elseif shopFound then
								setStatus("WAIT RESTOCK (~5m) — no selected rarity")
							end
						end
					else
						cooldownLabel.Text = math.ceil(monkeyBuyCooldown - elapsed) .. "s"
					end
				else
					cooldownLabel.Text = ""
				end

				task.wait(1)
			end
		end)

	end)

	if not ok then
		warn("[Icon Menu v5.3.1] monkey page GUI error:", err)
	end
end

-- ============================================================
-- READY
-- ============================================================

setStatus("READY")

print("Icon Menu v5.3.1 loaded")
