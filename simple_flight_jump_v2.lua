-- Version 2: working fast flight jump plus normal walking to biome eggs.
-- Flight math is copied unchanged from v1. Walking never picks up an egg.
-- Default: 200 studs in the character's horizontal facing direction per click.
-- Grok-v3 timing: max(distance / 750, 0.35); default 200-stud plan is 0.35s.
-- Close other movement scripts before use. Server corrections may still occur.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local GUI_NAME = "SimpleFlightJumpV2"
local SPEED = 750 -- Grok-v3 aerial baseline
local SPEED_CAP = SPEED * 1.5 -- 1125 studs/s maximum
local MIN_DURATION = 0.35
local MAX_DISTANCE = 2000
local active = nil
local flightConnection = nil -- one controller for flight, scanning, or walking
local closed = false

local previous = playerGui:FindFirstChild(GUI_NAME)
if previous then previous:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(280, 356)
panel.Position = UDim2.new(1, -290, 0.15, 0)
panel.BackgroundColor3 = Color3.fromRGB(22, 25, 35)
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

local function label(text, y, height)
	local item = Instance.new("TextLabel")
	item.Size = UDim2.new(1, -28, 0, height)
	item.Position = UDim2.fromOffset(14, y)
	item.BackgroundTransparency = 1
	item.Font = Enum.Font.Gotham
	item.TextSize = 12
	item.TextColor3 = Color3.fromRGB(210, 220, 235)
	item.TextWrapped = true
	item.Text = text
	item.Parent = panel
	return item
end

local title = label("FLIGHT JUMP · V2", 8, 24)
title.Font = Enum.Font.GothamBold
label("Distance in studs (1–2000)", 36, 16)

local distanceInput = Instance.new("TextBox")
distanceInput.Size = UDim2.new(1, -28, 0, 30)
distanceInput.Position = UDim2.fromOffset(14, 56)
distanceInput.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
distanceInput.TextColor3 = Color3.new(1, 1, 1)
distanceInput.Font = Enum.Font.Gotham
distanceInput.TextSize = 16
distanceInput.Text = "200"
distanceInput.PlaceholderText = "200"
distanceInput.ClearTextOnFocus = false
distanceInput.MultiLine = false
distanceInput.Parent = panel
Instance.new("UICorner", distanceInput).CornerRadius = UDim.new(0, 5)

local function button(text, y, height, color)
	local item = Instance.new("TextButton")
	item.Size = UDim2.new(1, -28, 0, height)
	item.Position = UDim2.fromOffset(14, y)
	item.BackgroundColor3 = color
	item.TextColor3 = Color3.new(1, 1, 1)
	item.Font = Enum.Font.GothamBold
	item.TextSize = 13
	item.Text = text
	item.Parent = panel
	Instance.new("UICorner", item).CornerRadius = UDim.new(0, 5)
	return item
end

local jumpButton = button("FLIGHT JUMP", 96, 34, Color3.fromRGB(40, 115, 180))
local biomeButton = button("BIOME: Any (click to change)", 140, 30, Color3.fromRGB(65, 75, 100))
local refreshButton = button("REFRESH BIOME LIST", 178, 26, Color3.fromRGB(65, 75, 100))
local walkButton = button("WALK TO EGG", 212, 34, Color3.fromRGB(40, 125, 90))
local stopButton = button("STOP", 254, 26, Color3.fromRGB(130, 50, 55))
local status = label("Close v1 first. Any = nearest available egg. Walk uses current speed; no pickup.", 288, 60)
local closeButton = button("×", 8, 22, Color3.fromRGB(75, 50, 55))
closeButton.Size = UDim2.fromOffset(22, 22)
closeButton.Position = UDim2.new(1, -28, 0, 8)

local function stopFlight(message)
	local run = active
	active = nil
	if flightConnection then flightConnection:Disconnect(); flightConnection = nil end
	if run then
		pcall(function()
			if run.mode == "walk" then
				run.hum:Move(Vector3.zero)
				run.hum:MoveTo(run.root.Position)
			elseif run.mode ~= "scan" then
				run.root.AssemblyLinearVelocity = Vector3.zero
				run.root.AssemblyAngularVelocity = Vector3.zero
			end
		end)
	end
	if status.Parent then status.Text = message end
end

local function advanceFlight(run, dt)
	if active ~= run then return end
	local root, hum = run.root, run.hum
	if player.Character ~= run.character or not root.Parent or not hum.Parent or hum.Health <= 0 then
		stopFlight("Stopped: character changed or died.")
		return
	end
	if root.Anchored then stopFlight("Stopped: character is anchored."); return end
	if dt <= 0 then return end
	if dt > 0.5 then stopFlight("Stopped: long frame pause."); return end
	local elapsed = os.clock() - run.started
	if elapsed > run.duration + 1 then stopFlight("Could not reach the target; stopped."); return end
	-- Do not chase a large external reset with another jump.
	if (root.Position - run.lastPosition).Magnitude > SPEED_CAP * dt + 30 then
		stopFlight("Movement changed unexpectedly; stopped.")
		return
	end
	run.lastPosition = root.Position
	if elapsed >= run.duration * 0.9 and (root.Position - run.target).Magnitude <= 3 then
		stopFlight("Jump finished. Click again when ready.")
		return
	end
	local progress = math.clamp((elapsed + math.max(dt, 0.016)) / run.duration, 0, 1)
	local waypoint = run.origin:Lerp(run.target, progress)
		+ Vector3.new(0, run.height * math.sin(progress * math.pi), 0)
	local velocity = (waypoint - root.Position) / math.max(dt, 0.001)
	if velocity.Magnitude > SPEED_CAP then velocity = velocity.Unit * SPEED_CAP end
	root.AssemblyLinearVelocity = velocity
	root.AssemblyAngularVelocity = Vector3.zero
end

local function startFlight()
	if active then status.Text = "Movement already running. Wait or press Stop."; return end
	local distance = tonumber(distanceInput.Text)
	if not distance or distance ~= distance or distance < 1 or distance > MAX_DISTANCE then
		status.Text = "Enter a distance from 1 to 2000 studs."
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 or root.Anchored then
		status.Text = "Wait for a living, unanchored character."
		return
	end
	-- Only READ CFrame for facing. Never assign CFrame or Position.
	local look = root.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 0.001 then status.Text = "Face horizontally before jumping."; return end
	local origin = root.Position
	local run = {
		character = character, root = root, hum = hum,
		origin = origin, target = origin + forward.Unit * distance,
		lastPosition = origin, started = os.clock(),
		duration = math.max(distance / SPEED, MIN_DURATION),
		height = math.clamp(distance * 0.035, 8, 26),
	}
	active = run
	status.Text = string.format("Jumping about %g studs forward…", distance)
	flightConnection = RunService.Heartbeat:Connect(function(dt)
		local ok = pcall(advanceFlight, run, dt)
		if not ok and active == run then stopFlight("Flight stopped because of an error.") end
	end)
end

-- Walking is independent of the jump distance and never requests carry/drop.
local selectedBiome = "Any"
local biomeNames = { "Any" }
local snapshotRequest = nil

local function normalize(value)
	return string.lower(tostring(value or "")):gsub("[%s_%-]", "")
end

local function finite(value)
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function eggPosition(record)
	local pos
	if typeof(record.BoundsCFrame) == "CFrame" then pos = record.BoundsCFrame.Position
	elseif typeof(record.BottomCFrame) == "CFrame" then pos = record.BottomCFrame.Position
	else pos = record.Position or record.Pos or record.pos or record.P end
	if (typeof(pos) == "Vector3" or typeof(pos) == "table")
		and finite(pos.X) and finite(pos.Y) and finite(pos.Z) then
		return Vector3.new(pos.X, pos.Y, pos.Z)
	end
	return nil
end

local function parseEggs(raw)
	if typeof(raw) ~= "table" then return nil end
	local records = raw.Records or raw.records
	if typeof(records) ~= "table" then return nil end
	local eggs = {}
	for _, record in pairs(records) do
		if typeof(record) == "table" then
			local uid = record.Uid or record.uid or record.UID or record.Id or record.id
			local area = record.AreaId or record.areaId or record.Area or record.Biome or record.biome
			local pos = eggPosition(record)
			if uid and area and tostring(area) ~= "" and pos then
				local carrier = record.CarrierUserId or record.carrierUserId
				table.insert(eggs, {
					uid = tostring(uid), biome = tostring(area), position = pos,
					available = carrier == nil or carrier == false or carrier == 0 or carrier == "0" or carrier == "",
				})
			end
		end
	end
	return eggs
end

local function updateBiomes(eggs)
	local seen, names = { any = true }, {}
	for _, egg in ipairs(eggs) do
		local key = normalize(egg.biome)
		if not seen[key] then seen[key] = true; table.insert(names, egg.biome) end
	end
	table.sort(names)
	biomeNames = { "Any" }
	for _, name in ipairs(names) do table.insert(biomeNames, name) end
	-- Keep a selected biome even if it has no eggs in this snapshot. Do not
	-- silently change the requested destination to Any / another biome.
	if not seen[normalize(selectedBiome)] then table.insert(biomeNames, selectedBiome) end
	biomeButton.Text = "BIOME: " .. selectedBiome .. " (change)"
end

local function nearestEgg(eggs, biome, position)
	local best, bestDistance = nil, math.huge
	for _, egg in ipairs(eggs) do
		if egg.available and (biome == "Any" or normalize(egg.biome) == normalize(biome)) then
			local distance = (egg.position - position).Magnitude
			if distance < bestDistance then best, bestDistance = egg, distance end
		end
	end
	return best
end

local function rigValid(run)
	return player.Character == run.character and run.root.Parent and run.hum.Parent
		and run.hum.Health > 0 and not run.root.Anchored
end

local function scanEggs(onResult)
	if active then status.Text = "Movement already running. Wait or press Stop."; return end
	if snapshotRequest then status.Text = "Previous egg scan still pending. Try again after it finishes."; return end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 or root.Anchored then
		status.Text = "Wait for a living, unanchored character."
		return
	end
	local found, remote = pcall(function()
		return ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggSnapshot"]
	end)
	if not found or not remote then status.Text = "Egg snapshot remote is unavailable."; return end
	local run = { mode = "scan", character = character, root = root, hum = hum }
	active = run
	status.Text = "Scanning live biome eggs…"
	local request = { done = false }
	snapshotRequest = request
	local deadline = os.clock() + 3
	task.spawn(function()
		if active == run and not closed then
			request.ok, request.result = pcall(function() return remote:InvokeServer() end)
		end
		request.done = true
		if snapshotRequest == request then snapshotRequest = nil end
		-- A late response changes no UI, target, or movement state.
	end)
	flightConnection = RunService.Heartbeat:Connect(function()
		if active ~= run then return end
		if not rigValid(run) then stopFlight("Stopped: character changed, died, or anchored."); return end
		if os.clock() > deadline then stopFlight("Egg scan timed out. No walking started."); return end
		if not request.done then return end
		local ok, eggs = pcall(parseEggs, request.result)
		if not request.ok or not ok or not eggs then stopFlight("Could not read the egg snapshot."); return end
		stopFlight("Egg scan complete.")
		updateBiomes(eggs)
		onResult(eggs)
	end)
end

local function walkToEgg(egg)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 or root.Anchored then status.Text = "Character is not ready."; return end
	if hum.WalkSpeed <= 0 then status.Text = "Walk speed is zero. Walking was not started."; return end
	local target = egg.position + Vector3.new(0, 3, 0)
	local distance = (target - root.Position).Magnitude
	local run = {
		mode = "walk", character = character, root = root, hum = hum,
		target = target, bestDistance = distance, progressAt = os.clock(), nextMove = 0,
		deadline = os.clock() + math.clamp(distance / hum.WalkSpeed * 2 + 10, 30, 600),
	}
	active = run
	local function step()
		if active ~= run then return end
		if not rigValid(run) then stopFlight("Stopped: character changed, died, or anchored."); return end
		local delta = target - root.Position
		local flatDistance = Vector3.new(delta.X, 0, delta.Z).Magnitude
		if flatDistance <= 4 and math.abs(delta.Y) <= 8 and hum.FloorMaterial ~= Enum.Material.Air then
			stopFlight("Reached " .. egg.biome .. " egg position. No pickup.")
			return
		end
		local now = os.clock()
		if delta.Magnitude < run.bestDistance - 1 then
			run.bestDistance, run.progressAt = delta.Magnitude, now
		end
		if now >= run.deadline then stopFlight("Walking timed out. Press Stop or choose a closer egg."); return end
		if now - run.progressAt > 10 then stopFlight("Walking blocked or no progress for 10 seconds."); return end
		if now >= run.nextMove then
			run.nextMove = now + 0.25
			-- Normal walking: do not set speed, CFrame, velocity, or humanoid state.
			hum:MoveTo(Vector3.new(target.X, root.Position.Y, target.Z))
			status.Text = string.format("Walking to %s egg · %.0f studs away", egg.biome, flatDistance)
		end
	end
	flightConnection = RunService.Heartbeat:Connect(function()
		local ok = pcall(step)
		if not ok and active == run then stopFlight("Walking stopped because of an error.") end
	end)
end

local function cycleBiome()
	local index = 1
	for i, name in ipairs(biomeNames) do if normalize(name) == normalize(selectedBiome) then index = i; break end end
	selectedBiome = biomeNames[index % #biomeNames + 1]
	biomeButton.Text = "BIOME: " .. selectedBiome .. " (change)"
end

biomeButton.Activated:Connect(function()
	if active then status.Text = "Stop movement before changing biome."; return end
	if #biomeNames == 1 then
		scanEggs(function() cycleBiome(); status.Text = "Choose a biome, then press Walk to Egg." end)
	else cycleBiome() end
end)
refreshButton.Activated:Connect(function()
	scanEggs(function(eggs) status.Text = string.format("Found %d egg records. Choose a biome or Any.", #eggs) end)
end)
walkButton.Activated:Connect(function()
	local requestedBiome = selectedBiome
	scanEggs(function(eggs)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not root then status.Text = "Character is not ready."; return end
		local egg = nearestEgg(eggs, requestedBiome, root.Position)
		if not egg then status.Text = "No available egg in " .. requestedBiome .. ". No fallback used."; return end
		walkToEgg(egg)
	end)
end)

jumpButton.Activated:Connect(startFlight)
stopButton.Activated:Connect(function() stopFlight("Stopped. Ready to fly or walk.") end)
closeButton.Activated:Connect(function() gui:Destroy() end)
local removingConnection = player.CharacterRemoving:Connect(function(character)
	if active and active.character == character then stopFlight("Stopped: character removed.") end
end)
gui.Destroying:Connect(function()
	closed = true
	stopFlight("Closed.")
	removingConnection:Disconnect()
end)
