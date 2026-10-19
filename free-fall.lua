-- Full script – Pure CFrame Freefall (matches your good log style)
-- LocalScript → StarterPlayerScripts or StarterGui

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ========== CREATE GUI ==========
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SpeedScanner"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "SpeedFrame"
frame.Size = UDim2.new(0, 320, 0, 380)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
frame.BackgroundTransparency = 0.12
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(0, 200, 255)
stroke.Thickness = 2
stroke.Transparency = 0.3
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 26)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Text = "SPEED SCANNER + LOG"
title.TextColor3 = Color3.fromRGB(0, 200, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -34, 0, 6)
closeBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 16
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local speedLabel = Instance.new("TextLabel")
speedLabel.Size = UDim2.new(1, -20, 0, 28)
speedLabel.Position = UDim2.new(0, 10, 0, 34)
speedLabel.BackgroundTransparency = 1
speedLabel.Text = "0.0 studs/s"
speedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
speedLabel.Font = Enum.Font.GothamBold
speedLabel.TextSize = 22
speedLabel.TextXAlignment = Enum.TextXAlignment.Left
speedLabel.Parent = frame

local stateLabel = Instance.new("TextLabel")
stateLabel.Size = UDim2.new(1, -20, 0, 16)
stateLabel.Position = UDim2.new(0, 10, 0, 62)
stateLabel.BackgroundTransparency = 1
stateLabel.Text = "State: —"
stateLabel.TextColor3 = Color3.fromRGB(160, 160, 160)
stateLabel.Font = Enum.Font.Gotham
stateLabel.TextSize = 12
stateLabel.TextXAlignment = Enum.TextXAlignment.Left
stateLabel.Parent = frame

local posLabel = Instance.new("TextLabel")
posLabel.Size = UDim2.new(1, -20, 0, 16)
posLabel.Position = UDim2.new(0, 10, 0, 78)
posLabel.BackgroundTransparency = 1
posLabel.Text = "Pos: 0, 0, 0"
posLabel.TextColor3 = Color3.fromRGB(140, 140, 160)
posLabel.Font = Enum.Font.Code
posLabel.TextSize = 11
posLabel.TextXAlignment = Enum.TextXAlignment.Left
posLabel.Parent = frame

local logTitle = Instance.new("TextLabel")
logTitle.Size = UDim2.new(1, -20, 0, 18)
logTitle.Position = UDim2.new(0, 10, 0, 98)
logTitle.BackgroundTransparency = 1
logTitle.Text = "EVENT LOG (State / Speed / XYZ)"
logTitle.TextColor3 = Color3.fromRGB(0, 180, 220)
logTitle.Font = Enum.Font.GothamBold
logTitle.TextSize = 12
logTitle.TextXAlignment = Enum.TextXAlignment.Left
logTitle.Parent = frame

local logScroll = Instance.new("ScrollingFrame")
logScroll.Name = "LogScroll"
logScroll.Size = UDim2.new(1, -20, 0, 160)
logScroll.Position = UDim2.new(0, 10, 0, 118)
logScroll.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
logScroll.BackgroundTransparency = 0.3
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 4
logScroll.ScrollBarImageColor3 = Color3.fromRGB(0, 180, 220)
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.Parent = frame
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 8)

local logList = Instance.new("UIListLayout")
logList.SortOrder = Enum.SortOrder.LayoutOrder
logList.Padding = UDim.new(0, 2)
logList.Parent = logScroll

local buttonFrame = Instance.new("Frame")
buttonFrame.Size = UDim2.new(1, -20, 0, 70)
buttonFrame.Position = UDim2.new(0, 10, 1, -80)
buttonFrame.BackgroundTransparency = 1
buttonFrame.Parent = frame

local boostBtn = Instance.new("TextButton")
boostBtn.Size = UDim2.new(1, 0, 0, 32)
boostBtn.Position = UDim2.new(0, 0, 0, 0)
boostBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
boostBtn.Text = "REPLICATE FREEFALL (CFrame ZeroVel)"
boostBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
boostBtn.Font = Enum.Font.GothamBold
boostBtn.TextSize = 13
boostBtn.Parent = buttonFrame
Instance.new("UICorner", boostBtn).CornerRadius = UDim.new(0, 6)

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0, 130, 0, 26)
copyBtn.Position = UDim2.new(0, 0, 0, 40)
copyBtn.BackgroundColor3 = Color3.fromRGB(0, 140, 180)
copyBtn.Text = "Copy Full Log"
copyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 12
copyBtn.Parent = buttonFrame
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 100, 0, 26)
clearBtn.Position = UDim2.new(0, 140, 0, 40)
clearBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
clearBtn.Text = "Clear Log"
clearBtn.TextColor3 = Color3.fromRGB(255, 180, 180)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 12
clearBtn.Parent = buttonFrame
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

local feedback = Instance.new("TextLabel")
feedback.Size = UDim2.new(0, 180, 0, 18)
feedback.Position = UDim2.new(1, -190, 1, -18)
feedback.BackgroundTransparency = 1
feedback.Text = ""
feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
feedback.Font = Enum.Font.GothamBold
feedback.TextSize = 12
feedback.Visible = false
feedback.Parent = frame

-- ========== DRAGGABLE ==========
local dragging, dragStart, startPos = false, nil, nil
frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
		frame.ZIndex = 10
	end
end)
frame.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
		frame.ZIndex = 1
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

-- ========== LOG ==========
local logEntries = {}
local MAX_LOG_ENTRIES = 120

local function addLogEntry(text)
	table.insert(logEntries, text)
	if #logEntries > MAX_LOG_ENTRIES then table.remove(logEntries, 1) end

	local entry = Instance.new("TextLabel")
	entry.Size = UDim2.new(1, -8, 0, 16)
	entry.BackgroundTransparency = 1
	entry.Text = text
	entry.TextColor3 = Color3.fromRGB(200, 200, 200)
	entry.Font = Enum.Font.Code
	entry.TextSize = 11
	entry.TextXAlignment = Enum.TextXAlignment.Left
	entry.TextTruncate = Enum.TextTruncate.AtEnd
	entry.Parent = logScroll

	local labels = {}
	for _, c in ipairs(logScroll:GetChildren()) do
		if c:IsA("TextLabel") then table.insert(labels, c) end
	end
	if #labels > MAX_LOG_ENTRIES then labels[1]:Destroy() end

	logScroll.CanvasSize = UDim2.new(0, 0, 0, logList.AbsoluteContentSize.Y + 10)
	logScroll.CanvasPosition = Vector2.new(0, logScroll.CanvasSize.Y.Offset)
end

local function clearLog()
	logEntries = {}
	for _, c in ipairs(logScroll:GetChildren()) do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
end

local function formatPos(pos)
	return string.format("%.1f, %.1f, %.1f", pos.X, pos.Y, pos.Z)
end

-- Replace the replicateFreefall function with this one

local function replicateFreefall()
	local character = player.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end

	-- Force high Y like the good log (≈112)
	if root.Position.Y < 100 then
		root.CFrame = CFrame.new(root.Position.X, 112.7, root.Position.Z)
	end

	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero

	-- Exact direction from your log: mostly -X, tiny +Z, Y locked
	local direction = Vector3.new(-1, 0, 0.00147).Unit   -- matches the real delta

	local totalDistance = 4626
	local steps = 24
	local stepSize = totalDistance / steps

	addLogEntry(string.format("[%s] REPLICATE FREEFALL started | %s", os.date("%H:%M:%S"), formatPos(root.Position)))

	feedback.Text = "Moving -X (matching log)..."
	feedback.TextColor3 = Color3.fromRGB(255, 140, 80)
	feedback.Visible = true

	task.spawn(function()
		for i = 1, steps do
			if not root or not root.Parent then break end

			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

			-- Move
			local newPos = root.Position + direction * stepSize
			-- Keep Y locked at 112.7 exactly like the log
			newPos = Vector3.new(newPos.X, 112.7, newPos.Z)
			root.CFrame = CFrame.new(newPos)

			-- Keep velocity zero
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero

			RunService.Heartbeat:Wait()
		end

		if root and root.Parent then
			addLogEntry(string.format("[%s] REPLICATE FREEFALL finished | %s", os.date("%H:%M:%S"), formatPos(root.Position)))
		end
		feedback.Visible = false
	end)
end
-- ========== BUTTONS ==========
closeBtn.MouseButton1Click:Connect(function()
	screenGui:Destroy()
end)

boostBtn.MouseButton1Click:Connect(replicateFreefall)

copyBtn.MouseButton1Click:Connect(function()
	if #logEntries == 0 then
		feedback.Text = "Log empty"
		feedback.TextColor3 = Color3.fromRGB(255, 180, 80)
	else
		local success = pcall(function()
			setclipboard(table.concat(logEntries, "\n"))
		end)
		feedback.Text = success and "Log Copied!" or "Copy failed"
		feedback.TextColor3 = success and Color3.fromRGB(100, 255, 150) or Color3.fromRGB(255, 100, 100)
	end
	feedback.Visible = true
	task.delay(1.8, function()
		if feedback and feedback.Parent then feedback.Visible = false end
	end)
end)

clearBtn.MouseButton1Click:Connect(function()
	clearLog()
	feedback.Text = "Log Cleared"
	feedback.TextColor3 = Color3.fromRGB(255, 180, 80)
	feedback.Visible = true
	task.delay(1.5, function()
		if feedback and feedback.Parent then feedback.Visible = false end
	end)
end)

local function addHover(btn, normal, hover)
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = hover}):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = normal}):Play()
	end)
end
addHover(closeBtn, Color3.fromRGB(40, 40, 50), Color3.fromRGB(70, 30, 30))
addHover(boostBtn, Color3.fromRGB(180, 40, 40), Color3.fromRGB(220, 60, 60))
addHover(copyBtn, Color3.fromRGB(0, 140, 180), Color3.fromRGB(0, 180, 220))
addHover(clearBtn, Color3.fromRGB(80, 40, 40), Color3.fromRGB(120, 50, 50))

-- ========== TRACKING ==========
local connection, stateConnection
local lastSpeed = 0
local SPEED_THRESHOLD = 6

local function startTracking(character)
	if connection then connection:Disconnect() end
	if stateConnection then stateConnection:Disconnect() end

	local root = character:WaitForChild("HumanoidRootPart", 5)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not root or not humanoid then return end

	lastSpeed = 0

	connection = RunService.Heartbeat:Connect(function()
		if not root or not root.Parent then return end

		local speed = root.AssemblyLinearVelocity.Magnitude
		local pos = root.Position

		speedLabel.Text = string.format("%.1f studs/s", speed)
		posLabel.Text = "Pos: " .. formatPos(pos)
		stateLabel.Text = "State: " .. tostring(humanoid:GetState())

		if speed < 16 then
			speedLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
		elseif speed < 50 then
			speedLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
		elseif speed < 120 then
			speedLabel.TextColor3 = Color3.fromRGB(0, 200, 255)
		else
			speedLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
		end

		if math.abs(speed - lastSpeed) >= SPEED_THRESHOLD then
			lastSpeed = speed
			addLogEntry(string.format("[%s] %.1f s/s | %s | %s",
				os.date("%H:%M:%S"), speed, tostring(humanoid:GetState()), formatPos(pos)))
		end
	end)

	stateConnection = humanoid.StateChanged:Connect(function(old, new)
		if not root or not root.Parent then return end
		local speed = root.AssemblyLinearVelocity.Magnitude
		local pos = root.Position
		addLogEntry(string.format("[%s] STATE %s → %s | %.1f s/s | %s",
			os.date("%H:%M:%S"), tostring(old), tostring(new), speed, formatPos(pos)))
		lastSpeed = speed
	end)
end

player.CharacterAdded:Connect(startTracking)
if player.Character then startTracking(player.Character) end