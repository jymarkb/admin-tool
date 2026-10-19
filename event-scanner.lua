
--[[
  REMOTE LOGGER / CONSOLE

  Logs:
    FireServer
    InvokeServer

  UI:
    START
    STOP
    COPY
    CLOSE

  The logger is PASSIVE:
    - It does not block remotes
    - It does not modify arguments
    - It does not replace the return value
    - The original game call always runs normally
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

-- ======================
-- TITLE
-- ======================

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

-- ======================
-- CLOSE
-- ======================

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

-- ======================
-- DRAG
-- ======================

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
	if dragging
		and (
			input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
		) then

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

-- ======================
-- CONSOLE
-- ======================

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

local function updateConsole()
	if not console or not console.Parent then
		return
	end

	pcall(function()
		console.Text = table.concat(logLines, "\n")
	end)
end

local function setStatus(text)
	if not title or not title.Parent then
		return
	end

	pcall(function()
		title.Text = "REMOTE LOGGER - " .. tostring(text)
	end)
end

-- ======================
-- BUTTON CREATOR
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

-- ======================
-- START
-- ======================

local startBtn = createBtn(
	"START",
	8,
	90,
	Color3.fromRGB(40, 150, 70)
)

startBtn.MouseButton1Click:Connect(function()
	loggingEnabled = true

	startBtn.Text = "STARTED"
	startBtn.BackgroundColor3 = Color3.fromRGB(30, 190, 80)

	setStatus("LOGGING")
end)

-- ======================
-- STOP
-- ======================

local stopBtn = createBtn(
	"STOP",
	106,
	90,
	Color3.fromRGB(160, 70, 60)
)

stopBtn.MouseButton1Click:Connect(function()
	loggingEnabled = false

	startBtn.Text = "START"
	startBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 70)

	setStatus("STOPPED")
end)

-- ======================
-- COPY
-- ======================

local copyBtn = createBtn(
	"COPY",
	204,
	90,
	Color3.fromRGB(70, 100, 170)
)

copyBtn.MouseButton1Click:Connect(function()
	local text = table.concat(logLines, "\n")

	if setclipboard then
		pcall(function()
			setclipboard(text)
		end)

		setStatus("COPIED")
	else
		setStatus("COPY UNAVAILABLE")
	end
end)

-- ======================
-- CLOSE
-- ======================

closeBtn.MouseButton1Click:Connect(function()
	loggingEnabled = false

	if screenGui then
		screenGui:Destroy()
	end
end)


-- ======================
-- VALUE FORMATTER
-- ======================

local function formatValue(value, depth, visited)
	depth = depth or 0
	visited = visited or {}

	if value == nil then
		return "nil"
	end

	local valueType = typeof(value)

	-- Simple values
	if valueType == "string" then
		return '"' .. value .. '"'
	elseif valueType == "number"
		or valueType == "boolean"
		or valueType == "EnumItem" then
		return tostring(value)
	elseif valueType == "Instance" then
		local ok, fullName = pcall(function()
			return value:GetFullName()
		end)

		if ok then
			return "<Instance: " .. fullName .. ">"
		end

		return "<Instance>"
	end

	-- Tables
	if valueType == "table" then
		if depth >= 6 then
			return "{...}"
		end

		if visited[value] then
			return "<recursive table>"
		end

		visited[value] = true

		local lines = {"{"}

		for key, childValue in pairs(value) do
			local keyText = tostring(key)

			local childText
			local ok, result = pcall(function()
				return formatValue(childValue, depth + 1, visited)
			end)

			if ok then
				childText = result
			else
				childText = "<unable to read value>"
			end

			table.insert(
				lines,
				string.rep("  ", depth + 1)
					.. "[" .. keyText .. "] = "
					.. childText
			)
		end

		table.insert(
			lines,
			string.rep("  ", depth) .. "}"
		)

		return table.concat(lines, "\n")
	end

	-- Other userdata/types
	local ok, result = pcall(function()
		return tostring(value)
	end)

	if ok then
		return result
	end

	return "<unknown value>"
end

-- ======================
-- REMOTE LOGGER
-- ======================

local oldNamecall

oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
	local method = getnamecallmethod()

	-- Only handle remote calls we want to observe.
	if method ~= "FireServer" and method ~= "InvokeServer" then
		return oldNamecall(self, ...)

	end

	-- Preserve the exact arguments.
	local packedArgs = table.pack(...)

	-- ==========================================
	-- ORIGINAL GAME CALL HAPPENS FIRST
	-- ==========================================

	-- Capture the original return values without changing them.
	local packedResults = table.pack(
		oldNamecall(self, ...)
	)

	-- ==========================================
	-- LOG AFTER ORIGINAL CALL FINISHES
	-- ==========================================

	if loggingEnabled then
		pcall(function()

			local remoteName = self:GetFullName()

			-- Ignore unwanted remotes
			if remoteName == "ReplicatedStorage.Packages.Networking.RF/AwayEarnings/FetchSummary"
				or remoteName == "ReplicatedStorage.UserGenerated.Analytics.ClientKit.Ping" then
				return
			end

			local entry = {}

			table.insert(entry, "==============================")
			table.insert(entry, method)
			table.insert(entry, remoteName)

			-- ======================
			-- ARGUMENTS
			-- ======================

			table.insert(entry, "Arguments:")

			if packedArgs.n == 0 then
				table.insert(entry, "  none")
			else
				for i = 1, packedArgs.n do
					local value = packedArgs[i]

					local formatted

					local ok, result = pcall(function()
						return formatValue(value)
					end)

					if ok then
						formatted = result
					else
						formatted = "<format error>"
					end

					table.insert(
						entry,
						"  [" .. i .. "] = " .. formatted
					)
				end
			end

			-- ======================
			-- RETURN VALUE
			-- ======================

			if method == "InvokeServer" then
				table.insert(entry, "")
				table.insert(entry, "Return:")

				if packedResults.n == 0 then
					table.insert(entry, "  none")
				else
					for i = 1, packedResults.n do
						local value = packedResults[i]

						local formatted

						local ok, result = pcall(function()
							return formatValue(value)
						end)

						if ok then
							formatted = result
						else
							formatted = "<format error>"
						end

						table.insert(
							entry,
							"  [" .. i .. "] = " .. formatted
						)
					end
				end
			end

			-- ======================
			-- SAVE LOG
			-- ======================

			table.insert(
				logLines,
				table.concat(entry, "\n")
			)

			-- Maximum 100 entries
			if #logLines > 100 then
				table.remove(logLines, 1)
			end

			updateConsole()
		end)
	end

	-- ==========================================
	-- RETURN THE ORIGINAL RESULT UNCHANGED
	-- ==========================================

	return table.unpack(
		packedResults,
		1,
		packedResults.n
	)
end)





setStatus("READY")

