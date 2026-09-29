--[[
=====================================================================
 SIMPLE RECOVERY UI  v1.0
 -------------------------------------------------------------------
 A small, self-contained tool. It does not modify any other script.

 WHAT IT GIVES YOU
   1. WALK TO FOREST EGG   - walks the character to the forest egg slot
                             using Humanoid:MoveTo (no velocity writes,
                             no CFrame writes, normal animation)
   2. PICK UP EGG          - tries the pickup the same way grok-v3 does:
                             carry remote + proximity prompts + hitbox
                             touch, repeatedly, until you hold it
   3. RECOVERY PULSE       - the pulse logic from
                             "test-ragdoll-good-recovery.lua":
                               * restores every disabled Motor6D
                               * clears PlatformStand / Sit
                               * re-enables Ragdoll / FallingDown /
                                 Physics states
                               * ChangeState(GettingUp) -> short wait ->
                                 ChangeState(Running)
                             It arms itself automatically the moment a
                             pickup is triggered, and can be toggled by
                             hand at any time.

   The pulse deliberately does NOT write AssemblyLinearVelocity, exactly
   like the original recovery script.

   ONE THING TO EXPECT
   The original pulse repeats while the game's ragdoll window is still
   open (RagdollEndTime in the future), roughly every 0.20 s. That is the
   behaviour being copied, and it is why the log shows several pulses in
   a row - each one is visible there so you can see exactly when the game
   let go.

 TRIGGERS (same checks as the recovery script)
   * LocalPlayer attribute RagdollEndTime is in the server's future
   * Humanoid state Physics / FallingDown
   * Humanoid.PlatformStand == true
   * two or more disabled Motor6D

 SAFETY
   * no CFrame / Position / Anchored writes anywhere
   * no velocity writes at all - walking is Humanoid:MoveTo
   * never calls the drop / strike remotes
   * Close disconnects everything it connected and destroys its GUI

 LIMITS
   MoveTo is a request like any other: if the server disagrees (stun,
   carry restriction, blocked path) the walk simply makes no progress -
   the status line reports that instead of pretending it worked.
=====================================================================
]]

--==================================================
-- SERVICES
--==================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

do
	local waited = 0

	while not LocalPlayer and waited < 10 do

		task.wait(0.25)
		waited = waited + 0.25
		LocalPlayer = Players.LocalPlayer
	end
end

if not LocalPlayer then

	warn("[Simple Recovery UI] LocalPlayer not available; aborting.")

	return
end

--==================================================
-- CONFIG
--==================================================

local CONFIG = {
	BIOME = "Forest",

	WALK_SPEED = 60.0,          -- written to WalkSpeed while walking
	WALK_ARRIVE_DIST = 4.0,     -- stop when this close to the egg
	WALK_TIMEOUT = 30.0,        -- give up after this many seconds
	WALK_RETARGET = 0.2,        -- re-issue MoveTo this often
	WALK_RESTORE_SPEED = true,  -- restore the original WalkSpeed when done

	PICKUP_BURST = 3.0,         -- keep trying this long
	PICKUP_INTERVAL = 0.12,
	PROMPT_RADIUS = 16.0,

	PULSE_COOLDOWN = 0.20,      -- seconds between pulses (as in the original)
	PULSE_SETTLE = 0.05,        -- settle wait at the end of a pulse
	PULSE_AUTO_ARM = true,      -- arm the pulse when a pickup is triggered
}

local REMOTE_CARRY = "RF/EggWorld/AskFieldEggCarry"

--==================================================
-- STATE
--==================================================

local scriptAlive = true
local connections = {}
local pulseEnabled = false
local pulseActive = false
local lastPulseTime = 0
local pulseCount = 0
local walking = false
local walkToken = 0
local pickupCount = 0
local savedWalkSpeed = nil
local log = {}

local gui, statusLabel, logLabel, walkButton, pickupButton, autoButton
local pulseButton, speedBox

--==================================================
-- HELPERS
--==================================================

local function safe(fn, ...)

	local ok, a, b, c = pcall(fn, ...)

	if ok then
		return true, a, b, c
	end

	return false, nil
end

local function connect(signal, callback)

	if not signal then
		return nil
	end

	local ok, conn = safe(function()
		return signal:Connect(callback)
	end)

	if ok and conn then
		connections[#connections + 1] = conn
	end

	return conn
end

local function disconnectAll()

	for _, conn in ipairs(connections) do

		safe(function()
			conn:Disconnect()
		end)
	end

	connections = {}
end

local function getCharacter()
	return LocalPlayer.Character
end

local function getRoot()

	local character = getCharacter()

	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()

	local character = getCharacter()

	return character and character:FindFirstChildOfClass("Humanoid")
end

local function note(text)

	log[#log + 1] = {
		t = os.clock(),
		text = text,
	}

	while #log > 60 do
		table.remove(log, 1)
	end

	if logLabel then

		local lines = {}

		for index = math.max(1, #log - 9), #log do

			local entry = log[index]

			lines[#lines + 1] = string.format(
				"[%7.2fs] %s",
				entry.t % 1000,
				entry.text
			)
		end

		logLabel.Text = table.concat(lines, "\n")
	end
end

local function setStatus(text)

	if statusLabel then
		statusLabel.Text = text
	end
end

--==================================================
-- EGG TARGETING (READ-ONLY)
--==================================================

local function getWorkspaceEgg(biome)

	local okArea, area = safe(function()
		return Workspace:FindFirstChild("AreaEggSlotsClient")
	end)

	if not okArea or not area then
		return nil
	end

	local wanted = string.lower(tostring(biome or ""))

	local okSlots, slots = safe(function()
		return area:GetChildren()
	end)

	if not okSlots or type(slots) ~= "table" then
		return nil
	end

	for _, slot in ipairs(slots) do

		if string.find(string.lower(tostring(slot.Name)), wanted, 1, true) then

			local okPart, part = safe(function()
				return slot:FindFirstChildWhichIsA("BasePart", true)
			end)

			if okPart and part then

				return {
					Uid = tostring(slot.Name),
					Position = part.Position,
					Source = "workspace slot",
				}
			end
		end
	end

	return nil
end

local function getRemote(subPath)

	local ok, remote = safe(function()
		return ReplicatedStorage.Packages.Networking[subPath]
	end)

	return ok and remote or nil
end

local function getForestEgg()

	local workspaceEgg = getWorkspaceEgg(CONFIG.BIOME)

	if workspaceEgg then
		return workspaceEgg
	end

	-- fall back to the read-only snapshot query
	local remote = getRemote("RF/EggWorld/AskFieldEggSnapshot")

	if not remote then
		return nil
	end

	local ok, result = safe(function()
		return remote:InvokeServer()
	end)

	if not ok or type(result) ~= "table" then
		return nil
	end

	local records = result.Records or result.records

	if type(records) ~= "table" then
		return nil
	end

	local wanted = string.lower(CONFIG.BIOME)

	for _, record in pairs(records) do

		if type(record) == "table" then

			local area = string.lower(tostring(
				record.AreaId or record.areaId or record.Area
					or record.Biome or record.biome or ""
			))

			local carrier = record.CarrierUserId or record.carrierUserId
			local bounds = record.BoundsCFrame or record.BottomCFrame
			local position = nil

			if typeof(bounds) == "CFrame" then
				position = bounds.Position
			elseif type(bounds) == "table" and bounds.Position then
				position = bounds.Position
			end

			if not position then

				local p = record.Position or record.Pos

				if typeof(p) == "Vector3" then
					position = p
				elseif type(p) == "table" and p.X and p.Y and p.Z then
					position = Vector3.new(p.X, p.Y, p.Z)
				end
			end

			if area == wanted and position
				and (carrier == nil or carrier == 0 or carrier == "") then

				return {
					Uid = tostring(record.Uid or record.uid or ""),
					Position = position,
					Source = "server snapshot",
				}
			end
		end
	end

	return nil
end

--==================================================
-- RAGDOLL DETECTION (same checks as the recovery script)
--==================================================

local function disabledMotorCount(character)

	local count = 0

	local ok, descendants = safe(function()
		return character:GetDescendants()
	end)

	if not ok or type(descendants) ~= "table" then
		return 0
	end

	for _, descendant in ipairs(descendants) do

		local okMotor, isMotor = safe(function()
			return descendant:IsA("Motor6D")
		end)

		if okMotor and isMotor then

			local okEnabled, enabled = safe(function()
				return descendant.Enabled
			end)

			if okEnabled and not enabled then
				count = count + 1
			end
		end
	end

	return count
end

local function getRagdollReason()

	local humanoid = getHumanoid()
	local character = getCharacter()

	if not humanoid or not character then
		return nil
	end

	local okEnd, ragdollEnd = safe(function()
		return LocalPlayer:GetAttribute("RagdollEndTime")
	end)

	if okEnd and type(ragdollEnd) == "number" then

		local okNow, now = safe(function()
			return Workspace:GetServerTimeNow()
		end)

		if okNow and type(now) == "number" and ragdollEnd > now then
			return "RagdollEndTime"
		end
	end

	local okState, state = safe(function()
		return humanoid:GetState()
	end)

	if okState then

		if state == Enum.HumanoidStateType.Physics then
			return "state Physics"
		end

		if state == Enum.HumanoidStateType.FallingDown then
			return "state FallingDown"
		end
	end

	local okStand, standing = safe(function()
		return humanoid.PlatformStand
	end)

	if okStand and standing then
		return "PlatformStand"
	end

	if disabledMotorCount(character) >= 2 then
		return "disabled Motor6D"
	end

	return nil
end

--==================================================
-- RECOVERY PULSE (logic from test-ragdoll-good-recovery.lua)
--==================================================

local function recoveryPulse(humanoid, character)

	if not humanoid or not character then
		return
	end

	local now = os.clock()

	if now - lastPulseTime < CONFIG.PULSE_COOLDOWN then
		return
	end

	if pulseActive then
		return
	end

	pulseActive = true
	lastPulseTime = now
	pulseCount = pulseCount + 1

	-- 1. Do NOT write AssemblyLinearVelocity here (as in the original).

	-- 2. Restore Motor6D joints
	local motorsRestored = 0

	local okDesc, descendants = safe(function()
		return character:GetDescendants()
	end)

	if okDesc and type(descendants) == "table" then

		for _, object in ipairs(descendants) do

			local okMotor, isMotor = safe(function()
				return object:IsA("Motor6D")
			end)

			if okMotor and isMotor then

				local okEnabled, enabled = safe(function()
					return object.Enabled
				end)

				if okEnabled and not enabled then

					local okSet = safe(function()
						object.Enabled = true
					end)

					if okSet then
						motorsRestored = motorsRestored + 1
					end
				end
			end
		end
	end

	-- 3. Restore Humanoid control
	safe(function()
		humanoid.PlatformStand = false
	end)

	safe(function()
		humanoid.Sit = false
	end)

	safe(function()
		humanoid.AutoRotate = true
	end)

	-- 4. Re-enable the humanoid states
	safe(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
	end)

	-- 5. Ask the Humanoid to recover
	safe(function()
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)

	task.wait()

	if not scriptAlive then
		pulseActive = false
		return
	end

	if humanoid.Parent then

		safe(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end)
	end

	note(string.format(
		"pulse #%d: %d motor(s) restored, GettingUp -> Running",
		pulseCount,
		motorsRestored
	))

	-- 6. Let physics settle
	task.wait(CONFIG.PULSE_SETTLE)

	pulseActive = false
end

connect(game:GetService("RunService").Heartbeat, function()

	if not scriptAlive or not pulseEnabled then
		return
	end

	local humanoid = getHumanoid()
	local character = getCharacter()

	if not humanoid or not character then
		return
	end

	if getRagdollReason() then
		recoveryPulse(humanoid, character)
	end
end)

--==================================================
-- WALK TO THE EGG
--==================================================

local function stopWalking(message, restore)

	walking = false
	walkToken = walkToken + 1

	local humanoid = getHumanoid()
	local root = getRoot()

	if humanoid and root then

		-- stop the move intent without writing any position
		safe(function()
			humanoid:MoveTo(root.Position)
		end)
	end

	if restore and CONFIG.WALK_RESTORE_SPEED and savedWalkSpeed ~= nil then

		if humanoid then

			safe(function()
				humanoid.WalkSpeed = savedWalkSpeed
			end)
		end

		savedWalkSpeed = nil
	end

	if walkButton then
		walkButton.Text = "WALK TO FOREST EGG"
	end

	if message then
		setStatus(message)
	end
end

local function walkToForestEgg()

	if walking then

		stopWalking("Walk stopped.", true)

		return
	end

	local egg = getForestEgg()

	if not egg then

		setStatus("No Forest egg found (no workspace slot, snapshot empty).")

		return
	end

	local humanoid = getHumanoid()
	local root = getRoot()

	if not humanoid or not root then

		setStatus("No character to walk with.")

		return
	end

	walkToken = walkToken + 1

	local token = walkToken

	walking = true

	if walkButton then
		walkButton.Text = "STOP WALKING"
	end

	if savedWalkSpeed == nil then

		local ok, value = safe(function()
			return humanoid.WalkSpeed
		end)

		savedWalkSpeed = ok and value or nil
	end

	safe(function()
		humanoid.WalkSpeed = CONFIG.WALK_SPEED
	end)

	note(string.format(
		"walking to %s (%s) at (%.0f, %.0f)",
		tostring(egg.Uid),
		tostring(egg.Source),
		egg.Position.X,
		egg.Position.Z
	))

	task.spawn(function()

		local started = os.clock()
		local lastRetarget = 0
		local lastPosition = nil
		local stalledSince = nil

		while scriptAlive and walking and token == walkToken do

			local currentHumanoid = getHumanoid()
			local currentRoot = getRoot()

			if not currentHumanoid or not currentRoot then
				stopWalking("Character unavailable; walk cancelled.", true)
				return
			end

			-- Do not fight a ragdoll; let the pulse deal with it.
			if not getRagdollReason() then

				local delta = egg.Position - currentRoot.Position
				local flat = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)

				if flat <= CONFIG.WALK_ARRIVE_DIST then

					stopWalking(string.format(
						"Arrived at %s (%.1f studs away). Ready to pick up.",
						tostring(egg.Uid),
						flat
					), true)

					return
				end

				local now = os.clock()

				if now - lastRetarget >= CONFIG.WALK_RETARGET then

					lastRetarget = now

					safe(function()
						currentHumanoid:MoveTo(egg.Position)
					end)
				end

				-- progress reporting
				if lastPosition then

					local moved = (currentRoot.Position - lastPosition).Magnitude

					if moved < 0.15 then

						if not stalledSince then
							stalledSince = now
						end

						if now - stalledSince > 2.5 then

							stopWalking(
								"Walk is not making progress (server may be "
									.. "holding the character). Stopped.",
								true
							)

							return
						end
					else
						stalledSince = nil
					end
				end

				lastPosition = currentRoot.Position

				setStatus(string.format(
					"Walking to %s ... %.0f studs left",
					tostring(egg.Uid),
					flat
				))
			end

			if os.clock() - started >= CONFIG.WALK_TIMEOUT then

				stopWalking("Walk timed out.", true)

				return
			end

			task.wait(0.05)
		end
	end)
end

--==================================================
-- PICKUP
--==================================================

local function isHoldingEgg()

	local character = getCharacter()

	if not character then
		return false
	end

	local ok, children = safe(function()
		return character:GetChildren()
	end)

	if ok and type(children) == "table" then

		for _, child in ipairs(children) do

			local name = string.lower(tostring(child.Name))
			local okTool, isTool = safe(function()
				return child:IsA("Tool")
			end)

			if ((okTool and isTool) or string.find(name, "egg", 1, true))
				and not string.find(name, "trap", 1, true) then

				return true
			end
		end
	end

	return false
end

local function triggerEggPrompts()

	safe(function()

		if type(fireproximityprompt) ~= "function" then
			return
		end

		local root = getRoot()

		if not root then
			return
		end

		local origin = root.Position

		for _, descendant in ipairs(Workspace:GetDescendants()) do

			if descendant:IsA("ProximityPrompt") then

				local part = descendant.Parent

				if part and part:IsA("BasePart")
					and (part.Position - origin).Magnitude <= CONFIG.PROMPT_RADIUS then

					pcall(function()
						fireproximityprompt(descendant, 0)
					end)
				end
			end
		end
	end)
end

local function touchEggHitbox(uid)

	safe(function()

		if type(firetouchinterest) ~= "function" then
			return
		end

		local root = getRoot()

		if not root or not uid then
			return
		end

		local area = Workspace:FindFirstChild("AreaEggSlotsClient")

		if not area then
			return
		end

		local eggModel = area:FindFirstChild(tostring(uid))

		if not eggModel then
			return
		end

		local hitbox = eggModel:FindFirstChild("Hitbox")
			or eggModel:FindFirstChildWhichIsA("BasePart")

		if not hitbox then
			return
		end

		firetouchinterest(root, hitbox, 0)

		task.defer(function()

			safe(function()
				firetouchinterest(root, hitbox, 1)
			end)
		end)
	end)
end

local function pickUpEgg()

	if isHoldingEgg() then

		setStatus("Already holding an egg.")

		return
	end

	local egg = getForestEgg()

	if not egg then

		setStatus("No Forest egg found to pick up.")

		return
	end

	local character = getCharacter()

	if not character then

		setStatus("No character.")

		return
	end

	-- Arm the recovery pulse the moment the pickup is triggered.
	if CONFIG.PULSE_AUTO_ARM and not pulseEnabled then

		pulseEnabled = true

		if pulseButton then
			pulseButton.Text = "RECOVERY PULSE: ON"
			pulseButton.BackgroundColor3 = Color3.fromRGB(40, 84, 56)
		end

		note("recovery pulse armed by pickup")
	end

	local remote = getRemote(REMOTE_CARRY)

	if not remote then

		setStatus("Carry remote not found (ReplicatedStorage.Packages.Networking).")

		return
	end

	pickupCount = pickupCount + 1

	note(string.format(
		"pickup attempt #%d on %s",
		pickupCount,
		tostring(egg.Uid)
	))

	local started = os.clock()

	task.spawn(function()

		local attempts = 0

		while scriptAlive and os.clock() - started < CONFIG.PICKUP_BURST do

			if isHoldingEgg() then

				setStatus("Picked up " .. tostring(egg.Uid) .. ".")

				note("holding: " .. tostring(egg.Uid))

				return
			end

			if getRagdollReason() then

				setStatus("Ragdoll during pickup - the pulse is handling it.")

			end

			attempts = attempts + 1

			task.spawn(function()

				safe(function()
					remote:InvokeServer({ Uid = tostring(egg.Uid) })
				end)
			end)

			triggerEggPrompts()
			touchEggHitbox(egg.Uid)

			task.wait(CONFIG.PICKUP_INTERVAL)
		end

		if not isHoldingEgg() then

			setStatus(string.format(
				"Pickup not confirmed after %d attempts (the game decides).",
				attempts
			))

			note("pickup unconfirmed after " .. tostring(attempts) .. " attempts")
		end
	end)
end

--==================================================
-- GUI
--==================================================

local function makeButton(parent, text, x, y, width, height)

	local button = Instance.new("TextButton")

	button.Name = "Btn_" .. string.gsub(text, "%W", "")
	button.Text = text
	button.Size = UDim2.new(0, width, 0, height)
	button.Position = UDim2.new(0, x, 0, y)
	button.BackgroundColor3 = Color3.fromRGB(38, 48, 66)
	button.TextColor3 = Color3.fromRGB(228, 236, 248)
	button.TextSize = 13
	button.Font = Enum.Font.SourceSans
	button.Parent = parent

	return button
end

local function refreshPulseButton()

	if not pulseButton then
		return
	end

	pulseButton.Text = "RECOVERY PULSE: " .. (pulseEnabled and "ON" or "OFF")
	pulseButton.BackgroundColor3 = pulseEnabled
		and Color3.fromRGB(40, 84, 56)
		or Color3.fromRGB(38, 48, 66)
end

local function buildGui()

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "SimpleRecoveryUI"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui or LocalPlayer:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Size = UDim2.new(0, 430, 0, 268)
	frame.Position = UDim2.new(0, 40, 0, 110)
	frame.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Text = "Simple Recovery UI  -  walk, pick up, recover"
	title.Size = UDim2.new(1, -12, 0, 22)
	title.Position = UDim2.new(0, 6, 0, 4)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(210, 230, 250)
	title.TextSize = 13
	title.Font = Enum.Font.SourceSansBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	walkButton = makeButton(frame, "WALK TO FOREST EGG", 6, 30, 200, 26)
	pickupButton = makeButton(frame, "PICK UP EGG", 212, 30, 120, 26)
	pickupButton.BackgroundColor3 = Color3.fromRGB(32, 74, 116)

	autoButton = makeButton(frame, "WALK + PICK UP", 338, 30, 86, 26)
	pulseButton = makeButton(frame, "RECOVERY PULSE: OFF", 6, 62, 200, 26)
	refreshPulseButton()

	local speedLabel = Instance.new("TextLabel")
	speedLabel.Name = "SpeedLabel"
	speedLabel.Text = "Walk speed:"
	speedLabel.Size = UDim2.new(0, 70, 0, 26)
	speedLabel.Position = UDim2.new(0, 212, 0, 62)
	speedLabel.BackgroundTransparency = 1
	speedLabel.TextColor3 = Color3.fromRGB(180, 190, 205)
	speedLabel.TextSize = 12
	speedLabel.Font = Enum.Font.SourceSans
	speedLabel.TextXAlignment = Enum.TextXAlignment.Right
	speedLabel.Parent = frame

	speedBox = Instance.new("TextBox")
	speedBox.Name = "SpeedBox"
	speedBox.Text = tostring(CONFIG.WALK_SPEED)
	speedBox.Size = UDim2.new(0, 60, 0, 26)
	speedBox.Position = UDim2.new(0, 286, 0, 62)
	speedBox.BackgroundColor3 = Color3.fromRGB(28, 33, 44)
	speedBox.TextColor3 = Color3.fromRGB(230, 236, 245)
	speedBox.TextSize = 13
	speedBox.Font = Enum.Font.Code
	speedBox.ClearTextOnFocus = false
	speedBox.Parent = frame

	local closeButton = makeButton(frame, "CLOSE", 350, 62, 74, 26)
	closeButton.BackgroundColor3 = Color3.fromRGB(96, 40, 44)

	statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Text = "Ready. Walk to the forest egg, then pick it up."
	statusLabel.Size = UDim2.new(1, -12, 0, 34)
	statusLabel.Position = UDim2.new(0, 6, 0, 94)
	statusLabel.BackgroundTransparency = 1
	statusLabel.TextColor3 = Color3.fromRGB(150, 210, 170)
	statusLabel.TextSize = 12
	statusLabel.Font = Enum.Font.SourceSans
	statusLabel.TextWrapped = true
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Top
	statusLabel.Parent = frame

	logLabel = Instance.new("TextLabel")
	logLabel.Name = "Log"
	logLabel.Text = ""
	logLabel.Size = UDim2.new(1, -12, 0, 130)
	logLabel.Position = UDim2.new(0, 6, 0, 132)
	logLabel.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	logLabel.TextColor3 = Color3.fromRGB(200, 208, 220)
	logLabel.TextSize = 11
	logLabel.Font = Enum.Font.Code
	logLabel.TextWrapped = true
	logLabel.TextXAlignment = Enum.TextXAlignment.Left
	logLabel.TextYAlignment = Enum.TextYAlignment.Top
	logLabel.Parent = frame

	-- drag by the title bar
	local dragging = false
	local dragStart, startPos

	connect(frame.InputBegan, function(input)

		if input and input.UserInputType == Enum.UserInputType.MouseButton1 then

			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end)

	connect(UserInputService.InputChanged, function(input)

		if dragging and input then

			local delta = input.Position - dragStart

			frame.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)

	connect(UserInputService.InputEnded, function(input)

		if input and input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	connect(speedBox.FocusLost, function()

		local value = tonumber(speedBox.Text)

		if value and value == value and value > 0 and value <= 2000 then

			CONFIG.WALK_SPEED = value

		else
			speedBox.Text = tostring(CONFIG.WALK_SPEED)
		end
	end)

	connect(walkButton.MouseButton1Click, function()
		walkToForestEgg()
	end)

	connect(pickupButton.MouseButton1Click, function()
		pickUpEgg()
	end)

	connect(autoButton.MouseButton1Click, function()

		if walking or isHoldingEgg() then
			setStatus("Already walking or already holding an egg.")
			return
		end

		walkToForestEgg()
		setStatus("Walking... pickup will follow automatically.")

		task.spawn(function()

			local token = walkToken
			local started = os.clock()

			while scriptAlive and walking and token == walkToken
				and os.clock() - started < CONFIG.WALK_TIMEOUT + 5 do

				task.wait(0.1)
			end

			if scriptAlive and not walking and not isHoldingEgg() then
				pickUpEgg()
			end
		end)
	end)

	connect(pulseButton.MouseButton1Click, function()

		pulseEnabled = not pulseEnabled
		refreshPulseButton()

		note("recovery pulse " .. (pulseEnabled and "ON" or "OFF"))
	end)

	connect(closeButton.MouseButton1Click, function()
		stopEverything("closed by user")
	end)
end

--==================================================
-- CHARACTER LIFECYCLE
--==================================================

connect(LocalPlayer.CharacterAdded, function(character)

	note("character respawned")

	walking = false
	walkToken = walkToken + 1
	savedWalkSpeed = nil

	if walkButton then
		walkButton.Text = "WALK TO FOREST EGG"
	end
end)

--==================================================
-- STOP
--==================================================

function stopEverything(reason)

	if not scriptAlive then
		return
	end

	scriptAlive = false
	walking = false
	walkToken = walkToken + 1
	pulseEnabled = false
	pulseActive = false

	local humanoid = getHumanoid()

	if humanoid and savedWalkSpeed ~= nil then

		safe(function()
			humanoid.WalkSpeed = savedWalkSpeed
		end)
	end

	savedWalkSpeed = nil

	disconnectAll()

	if gui then

		safe(function()
			gui:Destroy()
		end)

		gui = nil
	end

	if _G.SIMPLE_RECOVERY_UI
		and _G.SIMPLE_RECOVERY_UI.stop == stopEverything then

		_G.SIMPLE_RECOVERY_UI = nil
	end

	print("[Simple Recovery UI] stopped (" .. tostring(reason or "?") .. ")")
end

--==================================================
-- START
--==================================================

do

	local previous = _G.SIMPLE_RECOVERY_UI

	if type(previous) == "table" and type(previous.stop) == "function" then

		safe(function()
			previous.stop("replaced by a newer run")
		end)
	end
end

safe(buildGui)

note("ready (read/write scope: humanoid move + joints/state only)")

_G.SIMPLE_RECOVERY_UI = {
	version = "1.0",
	config = CONFIG,
	stop = stopEverything,
	walk = walkToForestEgg,
	stopWalking = function()
		stopWalking("Walk stopped.", true)
	end,
	pickUp = pickUpEgg,
	setPulse = function(enabled)

		pulseEnabled = enabled and true or false
		refreshPulseButton()
	end,
	pulse = function()
		return {
			enabled = pulseEnabled,
			active = pulseActive,
			count = pulseCount,
		}
	end,
	forcePulse = function()

		local humanoid = getHumanoid()
		local character = getCharacter()

		if humanoid and character then
			recoveryPulse(humanoid, character)
		end
	end,
	status = function()
		return statusLabel and statusLabel.Text or ""
	end,
	logText = function()

		local lines = {}

		for _, entry in ipairs(log) do
			lines[#lines + 1] = string.format("[%7.2fs] %s", entry.t % 1000, entry.text)
		end

		return table.concat(lines, "\n")
	end,
	state = function()

		return {
			alive = scriptAlive,
			walking = walking,
			holding = isHoldingEgg(),
			pulseEnabled = pulseEnabled,
			pulseCount = pulseCount,
			ragdollReason = getRagdollReason(),
		}
	end,
	target = function()

		local egg = getForestEgg()

		if not egg then
			return nil
		end

		return {
			Uid = egg.Uid,
			Source = egg.Source,
			X = egg.Position.X,
			Y = egg.Position.Y,
			Z = egg.Position.Z,
		}
	end,
}
