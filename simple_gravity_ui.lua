--[[
	SIMPLE GRAVITY UI — separate script
	==================================
	A small draggable panel with one button per gravity preset plus a custom value field. It changes
	exactly one thing: workspace.Gravity on your client.

	HOW IT WORKS
	  Your character is simulated on your own machine (you have network ownership of it), so the value
	  you set here is the gravity you actually fall at. The server keeps its own value and can
	  re-replicate it at any time (respawn, biome change, an event — this game has an
	  RE/GravityDisruptor/Burst remote, so it really does change gravity itself).
	  HOLD notices that and puts your value straight back; the status line shows how many times it had
	  to (kept Nx). Turn HOLD off if you want the game's value to win.

	WHAT IT DOES
	  * workspace.Gravity = preset / custom value (clamped to MIN..MAX, negative = fall upward)
	  * RESET puts the game's own value back
	  * nothing else — no remotes, no flight, no pickup, no character property writes

	USAGE (executor)
	  paste + run -> panel appears -> click a preset or type a value and press APPLY
	  _G.SIMPLE_GRAVITY_UI.set(50) / .reset() / .hold(false) / .status() / .log() / .destroy()

	NOTE
	  Client-only: other players still see the server's gravity. Some places (water, vehicles) run their
	  own gravity, and a re-apply can take a frame — the status line tells you when that happens.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")   -- same service as the `workspace` global, but held live in a local
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GUI_NAME = "SimpleGravityUI"
local CONFIG = {
	MIN = -500,          -- negative gravity makes you fall upward
	MAX = 5000,
	PRESETS = {
		{ name = "ZERO",   value = 0 },
		{ name = "MOON",   value = 50 },
		{ name = "LOW",    value = 100 },
		{ name = "NORMAL", value = 196.2 },
		{ name = "HIGH",   value = 400 },
	},
	HOLD_DEFAULT = true,
	LOG_LINES = 3,
}

-- ---------------------------------------------------------------- rerun guard
local previous = _G.SIMPLE_GRAVITY_UI
if previous and type(previous.destroy) == "function" then
	pcall(previous.destroy)
end
for _, child in ipairs(playerGui:GetChildren()) do
	if child.Name == GUI_NAME then pcall(function() child:Destroy() end) end
end

-- ---------------------------------------------------------------- state
local originalGravity = Workspace.Gravity     -- the game's own value, captured at load
local target = originalGravity                -- value we want the client to use
local holdEnabled = CONFIG.HOLD_DEFAULT
local heldCount = 0
local closed = false
local logLines = {}
local gui, statusLabel, logLabel, inputBox
local presetButtons = {}
local connections = {}

local function track(conn)
	connections[#connections + 1] = conn
	return conn
end

local function fmt(value)
	return string.format("%.1f", value)
end

local function say(text)
	logLines[#logLines + 1] = string.format("%s  %s", os.date("%H:%M:%S"), text)
	while #logLines > CONFIG.LOG_LINES do table.remove(logLines, 1) end
	if logLabel then logLabel.Text = table.concat(logLines, "\n") end
end

local function paintPresets()
	for _, entry in ipairs(presetButtons) do
		local active = math.abs(target - entry.value) < 0.001
		entry.button.BackgroundColor3 = active and Color3.fromRGB(70, 130, 90)
			or Color3.fromRGB(35, 40, 55)
	end
end

local function refresh()
	paintPresets()
	if not statusLabel then return end
	local live = Workspace.Gravity
	local state = (math.abs(live - target) < 0.001) and "in effect" or ("waiting for the game to release " .. fmt(live))
	statusLabel.Text = string.format("gravity %s   (game %s)\nHOLD %s · kept %dx · %s",
		fmt(live), fmt(originalGravity), holdEnabled and "ON" or "OFF", heldCount, state)
end

-- ---------------------------------------------------------------- gravity control
local function apply(reason)
	if closed or target == nil then return end
	if math.abs(Workspace.Gravity - target) < 0.001 then return end
	Workspace.Gravity = target
	say(string.format("gravity -> %s (%s)", fmt(target), reason or "set"))
end

local function setGravity(value, reason)
	local number = tonumber(value)
	if not number or number ~= number or number == math.huge or number == -math.huge then
		say("not a number: " .. tostring(value))
		refresh()
		return false, "not a number"
	end
	local clamped = math.clamp(number, CONFIG.MIN, CONFIG.MAX)
	target = clamped
	if clamped ~= number then
		say(string.format("%s is outside %d..%d, clamped to %s", fmt(number), CONFIG.MIN, CONFIG.MAX, fmt(clamped)))
	end
	apply(reason or "set")
	refresh()
	return true, clamped
end

local function resetGravity()
	target = originalGravity
	Workspace.Gravity = originalGravity
	say("reset to the game's own value " .. fmt(originalGravity))
	refresh()
end

local function setHold(on)
	holdEnabled = on and true or false
	say("hold " .. (holdEnabled and "ON — your value wins" or "OFF — the game's value wins"))
	refresh()
	return holdEnabled
end

-- The server re-replicates its own gravity sometimes; HOLD puts ours back when that happens.
local gravityChanged = track(Workspace:GetPropertyChangedSignal("Gravity"):Connect(function()
	if closed or not holdEnabled or target == nil then
		refresh()
		return
	end
	if math.abs(Workspace.Gravity - target) < 0.001 then
		refresh()
		return
	end
	heldCount = heldCount + 1
	apply("held #" .. heldCount)
	refresh()
end))

-- ---------------------------------------------------------------- GUI
local function buildGui()
	local function make(className, props, parent)
		local item = Instance.new(className)
		for key, value in pairs(props) do item[key] = value end
		item.Parent = parent
		return item
	end

	-- executors that expose gethui keep the panel out of PlayerGui so the game cannot hide it
	local parent = playerGui
	local ok, hidden = pcall(function() return gethui and gethui() end)
	if ok and hidden then parent = hidden end

	gui = make("ScreenGui", { Name = GUI_NAME, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, parent)
	local panel = make("Frame", { Name = "Panel", Size = UDim2.fromOffset(250, 268),
		Position = UDim2.new(1, -262, 0.2, 0), BackgroundColor3 = Color3.fromRGB(22, 25, 35),
		BorderSizePixel = 0, Active = true }, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, panel)

	local title = make("TextLabel", { Name = "Title", Size = UDim2.new(1, -28, 0, 20), Position = UDim2.fromOffset(14, 8),
		BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 14,
		TextColor3 = Color3.fromRGB(255, 220, 100), TextXAlignment = Enum.TextXAlignment.Left,
		Text = "GRAVITY · SIMPLE" }, panel)
	make("TextLabel", { Name = "Hint", Size = UDim2.new(1, -28, 0, 26), Position = UDim2.fromOffset(14, 30),
		BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11, TextWrapped = true,
		TextColor3 = Color3.fromRGB(150, 160, 178), TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Client-side Workspace.Gravity. HOLD puts your value back if the game overwrites it." }, panel)

	local function button(name, text, x, y, width, color)
		return make("TextButton", { Name = name, Size = UDim2.fromOffset(width, 28), Position = UDim2.fromOffset(x, y),
			BackgroundColor3 = color or Color3.fromRGB(35, 40, 55), BorderSizePixel = 0, AutoButtonColor = true,
			Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Color3.fromRGB(235, 240, 250), Text = text }, panel)
	end

	for index, preset in ipairs(CONFIG.PRESETS) do
		local column = (index - 1) % 3
		local row = math.floor((index - 1) / 3)
		local item = button("Btn_" .. preset.name, preset.name, 14 + column * 76, 62 + row * 34, 70)
		presetButtons[#presetButtons + 1] = { button = item, value = preset.value, name = preset.name }
		track(item.Activated:Connect(function() setGravity(preset.value, preset.name) end))
	end

	inputBox = make("TextBox", { Name = "Input", Size = UDim2.fromOffset(150, 28), Position = UDim2.fromOffset(14, 130),
		BackgroundColor3 = Color3.fromRGB(35, 40, 55), BorderSizePixel = 0, ClearTextOnFocus = false,
		Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = Color3.new(1, 1, 1),
		PlaceholderText = "custom value (-500 to 5000)", Text = "" }, panel)
	local applyButton = button("Btn_APPLY", "APPLY", 170, 130, 66, Color3.fromRGB(50, 90, 130))
	track(applyButton.Activated:Connect(function() setGravity(inputBox.Text, "custom") end))
	track(inputBox.FocusLost:Connect(function() setGravity(inputBox.Text, "custom") end))

	local resetButton = button("Btn_RESET", "RESET", 14, 164, 70)
	local holdButton = button("Btn_HOLD", "HOLD: ON", 90, 164, 70, Color3.fromRGB(70, 130, 90))
	local closeButton = button("Btn_CLOSE", "CLOSE", 166, 164, 70, Color3.fromRGB(70, 50, 50))
	track(resetButton.Activated:Connect(function() resetGravity() end))
	track(holdButton.Activated:Connect(function()
		setHold(not holdEnabled)
		holdButton.Text = holdEnabled and "HOLD: ON" or "HOLD: OFF"
		holdButton.BackgroundColor3 = holdEnabled and Color3.fromRGB(70, 130, 90) or Color3.fromRGB(35, 40, 55)
	end))
	track(closeButton.Activated:Connect(function()
		resetGravity()          -- never leave the player floating after the panel closes
		destroy()
	end))

	statusLabel = make("TextLabel", { Name = "Status", Size = UDim2.new(1, -28, 0, 34), Position = UDim2.fromOffset(14, 196),
		BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 11, TextWrapped = true,
		TextColor3 = Color3.fromRGB(170, 220, 255), TextXAlignment = Enum.TextXAlignment.Left, Text = "idle" }, panel)
	logLabel = make("TextLabel", { Name = "History", Size = UDim2.new(1, -28, 0, 30), Position = UDim2.fromOffset(14, 232),
		BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 10, TextWrapped = true,
		TextColor3 = Color3.fromRGB(130, 140, 158), TextXAlignment = Enum.TextXAlignment.Left, Text = "" }, panel)

	-- drag
	local dragging, dragStart, startPos = false, nil, nil
	track(title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, panel.Position
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))

	return true
end

function destroy()
	if closed then return end
	closed = true
	for _, conn in ipairs(connections) do pcall(function() conn:Disconnect() end) end
	table.clear(connections)
	if gui then pcall(function() gui:Destroy() end) end
	if _G.SIMPLE_GRAVITY_UI == API then _G.SIMPLE_GRAVITY_UI = nil end
end

local guiOk = buildGui()
say(string.format("loaded — game gravity %s, holding %s", fmt(originalGravity), holdEnabled and "ON" or "OFF"))
refresh()

API = {
	set = function(value) return setGravity(value, "api") end,
	reset = resetGravity,
	hold = setHold,
	status = function()
		return { gravity = Workspace.Gravity, target = target, original = originalGravity,
			hold = holdEnabled, held = heldCount, gui = guiOk }
	end,
	log = function()
		local out = {}
		for i, line in ipairs(logLines) do out[i] = line end
		return out
	end,
	destroy = destroy,
}
_G.SIMPLE_GRAVITY_UI = API
return API
