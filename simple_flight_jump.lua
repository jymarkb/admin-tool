-- Standalone, velocity-only flight jump. Does not load or alter other scripts.
-- Default: 200 studs in the character's horizontal facing direction per click.
-- Grok-v3 timing: max(distance / 750, 0.35); default 200-stud plan is 0.35s.
-- Close other movement scripts before use. Server corrections may still occur.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local GUI_NAME = "SimpleFlightJump"
local SPEED = 750 -- Grok-v3 aerial baseline
local SPEED_CAP = SPEED * 1.5 -- 1125 studs/s maximum
local MIN_DURATION = 0.35
local MAX_DISTANCE = 2000
local active = nil
local flightConnection = nil

local previous = playerGui:FindFirstChild(GUI_NAME)
if previous then previous:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(280, 224)
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

local title = label("FLIGHT JUMP", 8, 24)
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
local stopButton = button("STOP", 140, 26, Color3.fromRGB(130, 50, 55))
local status = label("Face a direction. Close other movement scripts before use.", 174, 38)
local closeButton = button("×", 8, 22, Color3.fromRGB(75, 50, 55))
closeButton.Size = UDim2.fromOffset(22, 22)
closeButton.Position = UDim2.new(1, -28, 0, 8)

local function stopFlight(message)
	local run = active
	active = nil
	if flightConnection then flightConnection:Disconnect(); flightConnection = nil end
	if run then
		pcall(function()
			run.root.AssemblyLinearVelocity = Vector3.zero
			run.root.AssemblyAngularVelocity = Vector3.zero
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
	if active then status.Text = "Already flying. Wait or press Stop."; return end
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

jumpButton.Activated:Connect(startFlight)
stopButton.Activated:Connect(function() stopFlight("Stopped. Ready for another jump.") end)
closeButton.Activated:Connect(function() gui:Destroy() end)
local removingConnection = player.CharacterRemoving:Connect(function(character)
	if active and active.character == character then stopFlight("Stopped: character removed.") end
end)
gui.Destroying:Connect(function()
	stopFlight("Closed.")
	removingConnection:Disconnect()
end)
