--[[
  REMOTE LOGGER + CHARACTER SNAPSHOTS

  - On START: dumps full character state
  - After egg pickup: dumps full character state again
  - Still logs every FireServer / InvokeServer
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")

-- ======================
-- UI
-- ======================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RemoteLogger"
screenGui.ResetOnSpawn = false
screenGui.Parent = pg

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 420, 0, 400)
main.Position = UDim2.new(0, 20, 0.25, 0)
main.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 34)
title.Position = UDim2.new(0, 10, 0, 0)
title.BackgroundTransparency = 1
title.Text = "REMOTE LOGGER"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = main

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -33, 0, 3)
closeBtn.BackgroundColor3 = Color3.fromRGB(160, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.Parent = main

Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- Drag
local dragging = false
local dragStart
local startPos

title.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = main.Position
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		main.Position = UDim2.new(
			startPos.X.Scale,
			startPos.X.Offset + delta.X,
			startPos.Y.Scale,
			startPos.Y.Offset + delta.Y
		)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)

-- Console
local console = Instance.new("TextBox")
console.Size = UDim2.new(1, -16, 1, -105)
console.Position = UDim2.new(0, 8, 0, 43)
console.BackgroundColor3 = Color3.fromRGB(10, 10, 16)
console.TextColor3 = Color3.fromRGB(210, 210, 220)
console.Font = Enum.Font.Code
console.TextSize = 12
console.Text = "REMOTE LOGGER READY\nPress START to begin logging..."
console.TextWrapped = false
console.TextXAlignment = Enum.TextXAlignment.Left
console.TextYAlignment = Enum.TextYAlignment.Top
console.ClearTextOnFocus = false
console.MultiLine = true
console.Parent = main

Instance.new("UICorner", console).CornerRadius = UDim.new(0, 6)

local padding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 6)
padding.PaddingRight = UDim.new(0, 6)
padding.PaddingTop = UDim.new(0, 6)
padding.Parent = console

-- ======================
-- LOGGER STATE
-- ======================

local loggingEnabled = false
local logLines = {}

local eggJustFired = false
local eggWindowUntil = 0
local EGG_REMOTE = "ReplicatedStorage.Packages.Networking.RF/EggWorld/AskFieldEggCarry"

local function updateConsole()
	if not console or not console.Parent then return end
	pcall(function()
		console.Text = table.concat(logLines, "\n")
	end)
end

local function setStatus(text)
	if not title or not title.Parent then return end
	pcall(function()
		title.Text = "REMOTE LOGGER - " .. tostring(text)
	end)
end

local function addLog(text)
	table.insert(logLines, text)
	if #logLines > 150 then
		table.remove(logLines, 1)
	end
	updateConsole()
end

-- ======================
-- CHARACTER SNAPSHOT
-- ======================

local function snapshotCharacter(label)
	local char = player.Character
	if not char then
		addLog("[" .. label .. "] NO CHARACTER")
		return
	end

	local lines = {}
	table.insert(lines, "========== " .. label .. " ==========")
	table.insert(lines, "Character: " .. char:GetFullName())

	-- Character attributes
	table.insert(lines, "--- Character Attributes ---")
	local attrs = char:GetAttributes()
	local hasAttr = false
	for k, v in pairs(attrs) do
		hasAttr = true
		table.insert(lines, "  " .. tostring(k) .. " = " .. tostring(v))
	end
	if not hasAttr then
		table.insert(lines, "  (none)")
	end

	-- Humanoid
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		table.insert(lines, "--- Humanoid ---")
		table.insert(lines, "  WalkSpeed = " .. tostring(hum.WalkSpeed))
		table.insert(lines, "  JumpPower = " .. tostring(hum.JumpPower))
		table.insert(lines, "  JumpHeight = " .. tostring(hum.JumpHeight))
		table.insert(lines, "  MaxSlopeAngle = " .. tostring(hum.MaxSlopeAngle))
		table.insert(lines, "  Health = " .. tostring(hum.Health))
		table.insert(lines, "  MaxHealth = " .. tostring(hum.MaxHealth))
		table.insert(lines, "  HipHeight = " .. tostring(hum.HipHeight))

		table.insert(lines, "--- Humanoid Attributes ---")
		local hattrs = hum:GetAttributes()
		local hasH = false
		for k, v in pairs(hattrs) do
			hasH = true
			table.insert(lines, "  " .. tostring(k) .. " = " .. tostring(v))
		end
		if not hasH then
			table.insert(lines, "  (none)")
		end
	else
		table.insert(lines, "--- Humanoid: MISSING ---")
	end

	-- Value objects under character
	table.insert(lines, "--- Value Objects under Character ---")
	local foundValue = false
	for _, v in ipairs(char:GetDescendants()) do
		if v:IsA("ValueBase") then
			foundValue = true
			table.insert(lines, "  " .. v:GetFullName() .. " = " .. tostring(v.Value))
		end
	end
	if not foundValue then
		table.insert(lines, "  (none)")
	end

	table.insert(lines, "====================================")

	addLog(table.concat(lines, "\n"))
end

-- ======================
-- BUTTONS
-- ======================

local function createBtn(text, x, width, color)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, width, 0, 34)
	btn.Position = UDim2.new(0, x, 1, -45)
	btn.BackgroundColor3 = color
	btn.Text = text
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 13
	btn.Parent = main
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
	return btn
end

local startBtn = createBtn("START", 8, 90, Color3.fromRGB(40, 150, 70))
startBtn.MouseButton1Click:Connect(function()
	loggingEnabled = true
	startBtn.Text = "STARTED"
	startBtn.BackgroundColor3 = Color3.fromRGB(30, 190, 80)
	setStatus("LOGGING")

	-- Snapshot on start
	snapshotCharacter("SNAPSHOT ON START")
end)

local stopBtn = createBtn("STOP", 106, 90, Color3.fromRGB(160, 70, 60))
stopBtn.MouseButton1Click:Connect(function()
	loggingEnabled = false
	startBtn.Text = "START"
	startBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 70)
	setStatus("STOPPED")
end)

local copyBtn = createBtn("COPY", 204, 90, Color3.fromRGB(70, 100, 170))
copyBtn.MouseButton1Click:Connect(function()
	local text = table.concat(logLines, "\n")
	if setclipboard then
		pcall(function() setclipboard(text) end)
		setStatus("COPIED")
	else
		setStatus("COPY UNAVAILABLE")
	end
end)

closeBtn.MouseButton1Click:Connect(function()
	loggingEnabled = false
	if screenGui then screenGui:Destroy() end
end)

-- ======================
-- VALUE FORMATTER
-- ======================

local function formatValue(value, depth, visited)
	depth = depth or 0
	visited = visited or {}

	if value == nil then return "nil" end
	local valueType = typeof(value)

	if valueType == "string" then
		return '"' .. value .. '"'
	elseif valueType == "number" or valueType == "boolean" or valueType == "EnumItem" then
		return tostring(value)
	elseif valueType == "Instance" then
		local ok, fullName = pcall(function() return value:GetFullName() end)
		return ok and ("<Instance: " .. fullName .. ">") or "<Instance>"
	end

	if valueType == "table" then
		if depth >= 6 then return "{...}" end
		if visited[value] then return "<recursive table>" end
		visited[value] = true

		local lines = {"{"}
		for key, childValue in pairs(value) do
			local childText
			local ok, result = pcall(function()
				return formatValue(childValue, depth + 1, visited)
			end)
			childText = ok and result or "<unable to read value>"
			table.insert(lines, string.rep("  ", depth + 1) .. "[" .. tostring(key) .. "] = " .. childText)
		end
		table.insert(lines, string.rep("  ", depth) .. "}")
		return table.concat(lines, "\n")
	end

	local ok, result = pcall(function() return tostring(value) end)
	return ok and result or "<unknown value>"
end

-- ======================
-- REMOTE HOOK
-- ======================

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
	local method = getnamecallmethod()

	if method ~= "FireServer" and method ~= "InvokeServer" then
		return oldNamecall(self, ...)
	end

	local packedArgs = table.pack(...)
	local packedResults = table.pack(oldNamecall(self, ...))

	if loggingEnabled then
		pcall(function()
			local remoteName = self:GetFullName()

			if remoteName == "ReplicatedStorage.Packages.Networking.RF/AwayEarnings/FetchSummary"
				or remoteName == "ReplicatedStorage.UserGenerated.Analytics.ClientKit.Ping" then
				return
			end

			local now = tick()
			local timeStr = string.format("%.3f", now)

			local entry = {}
			table.insert(entry, "==============================")
			table.insert(entry, "[" .. timeStr .. "] " .. method)
			table.insert(entry, remoteName)

			local isEgg = (remoteName == EGG_REMOTE)

			if isEgg then
				eggJustFired = true
				eggWindowUntil = now + 2.5
				table.insert(entry, "*** EGG PICKUP DETECTED ***")
			end

			if eggJustFired and now < eggWindowUntil and not isEgg then
				table.insert(entry, "*** TRIGGERED AFTER EGG PICKUP ***")
			end

			if eggJustFired and now >= eggWindowUntil then
				eggJustFired = false
			end

			-- Arguments
			table.insert(entry, "Arguments:")
			if packedArgs.n == 0 then
				table.insert(entry, "  none")
			else
				for i = 1, packedArgs.n do
					local ok, formatted = pcall(formatValue, packedArgs[i])
					table.insert(entry, "  [" .. i .. "] = " .. (ok and formatted or "<format error>"))
				end
			end

			-- Return
			if method == "InvokeServer" then
				table.insert(entry, "")
				table.insert(entry, "Return:")
				if packedResults.n == 0 then
					table.insert(entry, "  none")
				else
					for i = 1, packedResults.n do
						local ok, formatted = pcall(formatValue, packedResults[i])
						table.insert(entry, "  [" .. i .. "] = " .. (ok and formatted or "<format error>"))
					end
				end
			end

			addLog(table.concat(entry, "\n"))

			-- Snapshot right after successful egg pickup
			if isEgg and packedResults[1] == true then
				task.defer(function()
					snapshotCharacter("SNAPSHOT AFTER EGG PICKUP")
				end)
			end
		end)
	end

	return table.unpack(packedResults, 1, packedResults.n)
end)

setStatus("READY")