--[[
	ADVANCED GAME SCANNER v3 — LISTENER BUILD
	========================================
	Built on the v2 inventory scanner (FULL SCAN / COPY RESULTS / drag). v3 adds the live layer that the
	01:33 / 01:43 boss-hit logs could not give us:

	  (build r2)  AUTO_WATCH starts the listener at load; repeat FULL SCANs print inventory diffs only;
	              the export header reports userId (one line said "hired" before)
	  FULL SCAN   leaderstats, player + character attributes, humanoid/movement snapshot,
	              remote inventory (RemoteEvent + RemoteFunction, grouped by family),
	              token-matched object search (word matching — "Trunk" no longer matches "run")
	  WATCH       listen-only hook on every RemoteEvent in ReplicatedStorage
	              (ALL mode = everything, FOCUS mode = boss / ragdoll / carry candidates only)
	              logs remote name + serialized payload + millisecond timeline, with per-remote
	              rate limiting (flood suppression counters, never drops silently)
	  ATTRIBUTES  RagdollEndTime is decoded to wall-clock + remaining seconds, AreaId, carry flags,
	              on the Player (and the Character if present)
	  SIGNALS     Health / WalkSpeed / Humanoid state / PlatformStand / Anchored / NetworkOwner /
	              Tool add-remove (carry), CharacterAdded
	  HIT         flags the first frame where |dv| > 400 studs/s (state is reported, not required), and
	              after each hit it re-arms only once the debounce window has passed — a second launch
	              inside the window is intentionally not logged, and prints the
	              remote events that fired in the 250 ms before it -> attributes the launch to a remote
	  WALKSPEED   flags WalkSpeed being forced (>100 while not ragdolled) = script-driven movement,
	              which is how you tell YOUR flight apart from the game's own transport
	  HUD         live line: state, health, walkspeed, speed, ragdoll countdown, area, watch stats

	READ-ONLY GUARANTEE
	  * never calls FireServer / InvokeServer / FireAllClients on anything
	  * never writes to the character (no CFrame, Position, Velocity, WalkSpeed, attributes)
	  * only connects to signals, reads properties, and draws its own GUI
	  Writes are detectable: _G.ADVANCED_SCANNER_V3.stats().outgoingCalls is always 0.

	USAGE (executor)
	  paste + run -> window appears -> FULL SCAN for the inventory -> WATCH ON before you play
	  -> COPY RESULTS and paste the log. Do a hit right after WATCH ON so the hit block is easy to find.

	API
	  _G.ADVANCED_SCANNER_V3.scan() / .watch(true|false) / .setMode("all"|"focus") / .clear()
	  .copy() / .status() / .journal() / .stats() / .destroy()
	  ._internals exposes tokens(), decodeRagdoll(), serialize(), watchList() for offline tests.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
	localPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ---------------------------------------------------------------- rerun guard
if _G.ADVANCED_SCANNER_V3 and type(_G.ADVANCED_SCANNER_V3.destroy) == "function" then
	pcall(function() _G.ADVANCED_SCANNER_V3.destroy() end)
end

-- ---------------------------------------------------------------- config
local CONFIG = {
	MAX_JOURNAL        = 4000,   -- ring buffer cap (drops oldest, counted in stats)
	RENDER_LINES       = 400,    -- lines shown in the box
	RENDER_HZ          = 8,
	HIT_DV             = 400,    -- studs/s velocity change in one frame that counts as a hit
	HIT_DEBOUNCE       = 1.0,
	ATTRIB_WINDOW      = 0.25,   -- seconds of preceding remote events attached to a HIT row
	FASTMOVE_SPEED     = 200,    -- studs/s that counts as "something is driving me fast"
	FASTMOVE_STREAK    = 3,      -- frames in a row
	WALKSPEED_JOLT     = 50,     -- WalkSpeed change that is worth logging
	RATE_LIMIT         = 30,     -- per remote, per second
	RECENT_EVENTS      = 40,     -- ring of recent remote firings for HIT attribution
	STATUS_HZ          = 1,      -- HUD/status row rate while watching
	SCAN_LIMIT_OBJECTS = 60,     -- matched objects printed by FULL SCAN
	AUTO_WATCH         = true,   -- start listening as soon as the script loads (a hit can't be missed)
	SKIP_REPEAT_SCAN   = true,   -- repeat FULL SCANs print inventory changes only + skip the Workspace walk
}

-- Remote families worth watching in FOCUS mode (substring match on the full path).
local FOCUS_PATTERNS = {
	"BossEvent", "ScrambleBoss", "Scramble/", "GuardPatrol", "SammyEvent", "MonsterEvent",
	"MonsterParasite", "BossFlightRemotes", "BeginFlight", "Limpness", "ZoneProbe", "RigSync",
	"SharedFx", "EggWorld", "EggCapture", "AdEggBoostRemotes", "JoltOnce", "Hazard", "Strike",
	"Hit", "Ragdoll", "Carry", "Anchor", "Correct", "Telemetry",
}

-- ---------------------------------------------------------------- state
local T0 = os.clock()
local journal, journalCount, dropped = {}, 0, 0
local dirty, lastRender = false, 0
local watching, watchMode = false, "focus"
local watchConns, extraConns = {}, {}
local remoteStats, recentEvents = {}, {}
local hits, lastHitT = 0, -1
local firstScanDone = false
local lastInventory = {}
local lastEventT = 0
local lastErrorT = 0
local simulate = { connectFailure = false }   -- diagnostics hook: lets the offline suite prove rollback works

local watchedRemoteNames = {}
local API
local countWatched, matchesFocus, watchList, doScan, doCopy, doExport, setWatch, destroy
local connectWatch, disconnectWatch
local lastVelocity, lastWalkSpeed, lastHealth, lastState = nil, nil, nil, nil
local lastFastMove, fastMoveStreak = 0, 0
local lastStatus, statusRows = 0, 0
local connectionCount = 0
local function track(conn)
	extraConns[#extraConns + 1] = conn
	connectionCount = connectionCount + 1
	return conn
end

local function now() return os.clock() end
local function elapsed() return now() - T0 end
local function stamp()
	local e = elapsed()
	return string.format("[%8.3f]", e)
end

local function say(tag, text)
	journalCount = journalCount + 1
	local entry = { n = journalCount, t = elapsed(), tag = tag, text = tostring(text),
		line = string.format("%s #%04d %-11s %s", stamp(), journalCount, tag, tostring(text)) }
	journal[#journal + 1] = entry
	if #journal > CONFIG.MAX_JOURNAL then
		table.remove(journal, 1)
		dropped = dropped + 1
	end
	dirty = true
	return entry
end

local function reportError(what, err)
	local t = now()
	-- never let a repeating error flood the journal, but the FIRST one must always be visible
	if lastErrorT > 0 and (t - lastErrorT) < 1 then return end
	lastErrorT = t
	say("ERROR", what .. ": " .. tostring(err))
end

local function sep(title)
	say("----", "===== " .. title .. " =====")
end

local function fmtVec(v)
	if type(v) ~= "table" or v.X == nil then return tostring(v) end
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

-- Serialize a remote payload argument, safely and compactly.
local function serializeValue(v, depth)
	depth = depth or 0
	local tv = type(v)
	if tv == "string" then
		if #v > 160 then v = string.sub(v, 1, 160) .. "…" end
		return string.format("%q", v)
	elseif tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
		return (string.format("%.3f", v):gsub("%.000$", ""))
	elseif tv == "boolean" then
		return tostring(v)
	elseif tv == "nil" then
		return "nil"
	elseif tv == "Instance" then
		local ok, name = pcall(function() return v:GetFullName() end)
		return "Instance(" .. (ok and name or "?") .. ")"
	elseif tv == "Vector3" then
		return fmtVec(v)
	elseif tv == "table" then
		if depth >= 2 then return "{…}" end
		local parts, n = {}, 0
		for k, val in pairs(v) do
			n = n + 1
			if n > 8 then parts[#parts + 1] = "…" break end
			local key = tostring(k)
			parts[#parts + 1] = key .. "=" .. serializeValue(val, depth + 1)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(v)
end

local function serializeArgs(...)
	local n = select("#", ...)
	if n == 0 then return "" end
	local parts = {}
	for i = 1, math.min(n, 4) do
		parts[#parts + 1] = serializeValue((select(i, ...)))
	end
	if n > 4 then parts[#parts + 1] = "…(+" .. (n - 4) .. ")" end
	return table.concat(parts, " | ")
end

-- Split a name into lower-case word tokens (camelCase + non-alphanumeric boundaries).
-- "Trunk" -> {"trunk"}  (so it can never match "run");  "TreadmillBottom" -> {"treadmill","bottom"}
local function tokens(name)
	local out, word = {}, {}
	local s = tostring(name)
	local prevLower = false
	for i = 1, #s do
		local c = string.sub(s, i, i)
		if c:match("[%w]") then
			local isUpper = c:match("%u") ~= nil
			local isDigit = c:match("%d") ~= nil
			if isUpper and prevLower and #word > 0 then
				out[#out + 1] = table.concat(word):lower()
				word = {}
			end
			word[#word + 1] = c
			prevLower = (not isUpper) or isDigit
		else
			if #word > 0 then out[#out + 1] = table.concat(word):lower() word = {} end
			prevLower = false
		end
	end
	if #word > 0 then out[#out + 1] = table.concat(word):lower() end
	return out
end

local function hasToken(name, wanted)
	for _, tok in ipairs(tokens(name)) do
		if tok == wanted then return true end
	end
	return false
end

-- RagdollEndTime / JoinTick are Unix epoch seconds published as Player attributes.
local function serverNow()
	local ok, t = pcall(function() return Workspace:GetServerTimeNow() end)
	if ok and type(t) == "number" then return t end
	return os.time()
end

local function clockOf(epoch)
	if type(epoch) ~= "number" or epoch <= 0 then return "?" end
	local ok, s = pcall(function()
		return DateTime.fromUnixTimestamp(math.floor(epoch)):Format("%H:%M:%S")
	end)
	if ok and s then return s end
	local ok2, s2 = pcall(function() return os.date("%H:%M:%S", math.floor(epoch)) end)
	return ok2 and s2 or "?"
end

local function decodeRagdoll(value)
	if type(value) ~= "number" or value <= 0 then
		return { raw = value, valid = false, remaining = nil, clock = "?", text = tostring(value) }
	end
	local remaining = value - serverNow()
	local when = (remaining >= 0)
		and string.format("%.1fs left", remaining)
		or string.format("ended %.1fs ago", -remaining)
	return { raw = value, valid = true, remaining = remaining, clock = clockOf(value),
		text = string.format("%.2f (%s | %s)", value, clockOf(value), when) }
end

local function ragdollRemaining()
	local v = localPlayer:GetAttribute("RagdollEndTime")
	if type(v) ~= "number" or v <= 0 then return nil end
	local left = v - serverNow()
	if left <= 0 then return 0 end
	return left
end

-- ---------------------------------------------------------------- GUI
local GUI_NAME = "AdvancedScanner_v3"
local guiParent
do
	local ok, hui = pcall(function() return gethui and gethui() end)
	if ok and hui then guiParent = hui
	else
		ok, guiParent = pcall(function() return localPlayer:WaitForChild("PlayerGui") end)
		if not ok then guiParent = nil end
	end
end

local gui, logBox, listLayout, statusLabel, modeButton, watchButton, watchLabel = nil, nil, nil, nil, nil, nil, nil
local renderedLabels = {}

local function make(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props or {}) do inst[k] = v end
	if parent then inst.Parent = parent end
	return inst
end

local function buildGui()
	if not guiParent then return false end
	gui = make("ScreenGui", { Name = GUI_NAME, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, guiParent)

	local main = make("Frame", { Name = "Main", Size = UDim2.new(0, 460, 0, 560),
		Position = UDim2.new(0.5, -230, 0.5, -280), BackgroundColor3 = Color3.fromRGB(16, 20, 18),
		BorderSizePixel = 0 }, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, main)

	local title = make("TextLabel", { Name = "Title", Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = Color3.fromRGB(24, 32, 26), Text = "  ADVANCED SCANNER v3 (listener)",
		TextColor3 = Color3.fromRGB(120, 255, 100), Font = Enum.Font.GothamBold, TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0 }, main)

	local closeBtn = make("TextButton", { Name = "Btn_CLOSE", Size = UDim2.new(0, 28, 0, 24),
		Position = UDim2.new(1, -32, 0, 3), BackgroundColor3 = Color3.fromRGB(90, 40, 40), Text = "X",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 13, BorderSizePixel = 0 }, main)

	local scanBtn = make("TextButton", { Name = "Btn_FULLSCAN", Size = UDim2.new(0, 108, 0, 30),
		Position = UDim2.new(0, 10, 0, 36), BackgroundColor3 = Color3.fromRGB(40, 120, 55), Text = "FULL SCAN",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 13, BorderSizePixel = 0 }, main)

	watchButton = make("TextButton", { Name = "Btn_WATCH", Size = UDim2.new(0, 108, 0, 30),
		Position = UDim2.new(0, 124, 0, 36), BackgroundColor3 = Color3.fromRGB(40, 90, 140), Text = "WATCH: OFF",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 13, BorderSizePixel = 0 }, main)
	watchLabel = watchButton

	modeButton = make("TextButton", { Name = "Btn_MODE", Size = UDim2.new(0, 100, 0, 30),
		Position = UDim2.new(0, 238, 0, 36), BackgroundColor3 = Color3.fromRGB(70, 70, 40), Text = "MODE: FOCUS",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 13, BorderSizePixel = 0 }, main)

	local copyBtn = make("TextButton", { Name = "Btn_COPY", Size = UDim2.new(0, 106, 0, 30),
		Position = UDim2.new(1, -116, 0, 36), BackgroundColor3 = Color3.fromRGB(60, 60, 130), Text = "COPY RESULTS",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 12, BorderSizePixel = 0 }, main)

	statusLabel = make("TextLabel", { Name = "Status", Size = UDim2.new(1, -20, 0, 34),
		Position = UDim2.new(0, 10, 0, 72), BackgroundTransparency = 1, Text = "idle",
		TextColor3 = Color3.fromRGB(255, 220, 100), Font = Enum.Font.Code, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true }, main)

	logBox = make("ScrollingFrame", { Name = "Log", Size = UDim2.new(1, -20, 1, -156),
		Position = UDim2.new(0, 10, 0, 112), BackgroundColor3 = Color3.fromRGB(10, 13, 11),
		BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.new(0, 0, 0, 0) }, main)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, logBox)
	listLayout = make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, logBox)

	-- actions
	track(scanBtn.MouseButton1Click:Connect(function() task.spawn(doScan) end))
	track(closeBtn.MouseButton1Click:Connect(function() destroy() end))
	track(copyBtn.MouseButton1Click:Connect(function() doCopy(copyBtn) end))
	local clearBtn = make("TextButton", { Name = "Btn_CLEAR", Size = UDim2.new(0, 90, 0, 26),
		Position = UDim2.new(1, -100, 1, -32), BackgroundColor3 = Color3.fromRGB(70, 50, 50), Text = "CLEAR",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 12, BorderSizePixel = 0 }, main)
	if clearBtn then
		track(clearBtn.MouseButton1Click:Connect(function()
			local ok, err = pcall(API.clear)
			if not ok then reportError("CLEAR failed", err) end
		end))
	end
	track(modeButton.MouseButton1Click:Connect(function()
		local ok, err = pcall(function()
			applyMode((watchMode == "focus") and "all" or "focus")
		end)
		if not ok then reportError("MODE button failed", err) end
	end))
	track(watchButton.MouseButton1Click:Connect(function()
		local ok, err = pcall(function() setWatch(not watching) end)
		if not ok then reportError("WATCH button failed", err) end
	end))

	-- drag
	local dragging, dragStart, startPos = false, nil, nil
	track(title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, main.Position
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))

	return true
end

-- ---------------------------------------------------------------- rendering
local function render()
	if not logBox then return end
	local total = #journal
	local from = math.max(1, total - CONFIG.RENDER_LINES + 1)
	local shown = total - from + 1
	while #renderedLabels > shown do
		local lbl = table.remove(renderedLabels)
		if lbl then pcall(function() lbl:Destroy() end) end
	end
	for i = from, total do
		local idx = i - from + 1
		local entry = journal[i]
		local lbl = renderedLabels[idx]
		if not lbl then
			lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Font = Enum.Font.Code
			lbl.TextSize = 12
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.TextWrapped = true
			lbl.Size = UDim2.new(1, -12, 0, 16)
			lbl.AutomaticSize = Enum.AutomaticSize.Y
			lbl.TextColor3 = (entry.tag == "HIT" and Color3.fromRGB(255, 120, 120))
				or (entry.tag == "WALKSPEED" and Color3.fromRGB(255, 200, 100))
				or (entry.tag == "TOOL" and Color3.fromRGB(120, 220, 255))
				or (entry.tag == "ATTR" and Color3.fromRGB(200, 160, 255))
				or Color3.fromRGB(200, 210, 200)
			lbl.LayoutOrder = idx
			lbl.Parent = logBox
			renderedLabels[idx] = lbl
		end
		lbl.Text = entry.line
	end
	logBox.CanvasSize = UDim2.new(0, 0, 0, shown * 18 + 20)
	if listLayout then
		pcall(function() logBox.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 20) end)
	end
end

local function refreshStatus()
	if not statusLabel then return end
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local left = ragdollRemaining()
	local stats = API.stats()
	statusLabel.Text = string.format(
		"watch=%s mode=%s | events=%d (~%d/min) suppressed=%d | state=%s hp=%s ws=%s speed=%s | ragdoll=%s | area=%s",
		watching and "ON" or "OFF", watchMode, stats.events, stats.perMinute, stats.suppressed,
		hum and tostring(hum:GetState()):gsub("Enum.HumanoidStateType.", "") or "?",
		hum and tostring(math.floor(hum.Health)) or "?",
		hum and tostring(hum.WalkSpeed) or "?",
		root and string.format("%.0f", root.AssemblyLinearVelocity.Magnitude) or "?",
		left and string.format("%.1fs", left) or "-",
		tostring(localPlayer:GetAttribute("AreaId") or "?"))
end

-- ---------------------------------------------------------------- FULL SCAN
local function scanLeaderstats()
	sep("LEADERSTATS")
	local ls = localPlayer:FindFirstChild("leaderstats")
	if not ls then say("INFO", "(no leaderstats)") return end
	for _, v in ipairs(ls:GetChildren()) do
		local ok, val = pcall(function() return v.Value end)
		say("LEADERSTATS", string.format("%s = %s", v.Name, ok and tostring(val) or "?"))
	end
end

local function scanPlayerAttributes()
	sep("PLAYER ATTRIBUTES")
	local ok, attrs = pcall(function() return localPlayer:GetAttributes() end)
	if not ok or not attrs or next(attrs) == nil then say("INFO", "(none)") return end
	local names = {}
	for name in pairs(attrs) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local value = attrs[name]
		if name == "RagdollEndTime" or name == "JoinTick" then
			local d = decodeRagdoll(value)
			say("ATTR", string.format("%s = %s  -> %s", name, tostring(value),
				name == "RagdollEndTime" and d.text or clockOf(tonumber(value) or 0)))
		elseif name == "AreaId" then
			say("ATTR", string.format("%s = %s   <- current biome", name, tostring(value)))
		else
			say("ATTR", string.format("%s = %s", name, tostring(value)))
		end
	end
	local left = ragdollRemaining()
	local raw = localPlayer:GetAttribute("RagdollEndTime")
	if left and left > 0 then
		say("ATTR", string.format("RAGDOLL ACTIVE — %.2fs left (server window)", left))
	elseif type(raw) == "number" and raw > 0 then
		say("ATTR", string.format(
			"no ragdoll now — RagdollEndTime is a stamp of the LAST one (ended %.1fs ago); a hit only counts while it is in the future",
			serverNow() - raw))
	else
		say("ATTR", "no ragdoll now — RagdollEndTime not set this session")
	end
	say("ATTR", string.format("server time now = %.3f (%s)", serverNow(), clockOf(serverNow())))
end

local function scanCharacter()
	sep("CHARACTER")
	local char = localPlayer.Character
	if not char then say("INFO", "(no character)") return end
	local ok, attrs = pcall(function() return char:GetAttributes() end)
	if ok and attrs and next(attrs) ~= nil then
		local names = {}
		for name in pairs(attrs) do names[#names + 1] = name end
		table.sort(names)
		for _, name in ipairs(names) do
			say("CHARATTR", string.format("%s = %s", name, tostring(attrs[name])))
		end
	else
		say("CHARATTR", "(no character attributes)")
	end

	local tools = {}
	for _, child in ipairs(char:GetChildren()) do
		if child:IsA("Tool") then tools[#tools + 1] = child.Name end
	end
	say("CARRY", string.format("tools=%d %s | IsCarrying=%s | egg-ish children=%d",
		#tools, (#tools > 0 and ("[" .. table.concat(tools, ", ") .. "]") or ""),
		tostring(localPlayer:GetAttribute("IsCarrying")),
		(function()
			local n = 0
			for _, d in ipairs(char:GetDescendants()) do
				if hasToken(d.Name, "egg") then n = n + 1 end
			end
			return n
		end)()))
end

local function scanHumanoid()
	sep("MOVEMENT SNAPSHOT")
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then say("INFO", "(no humanoid/root)") return end
	local okState, state = pcall(function() return hum:GetState() end)
	local netOwner = "n/a on client"
	local okOwner = pcall(function()
		local o = root:GetNetworkOwner()
		netOwner = o and o.Name or "nil"
	end)
	if not okOwner then netOwner = "client-side read blocked" end
	say("MOVE", string.format(
		"state=%s hp=%.1f/%.1f ws=%.1f pos=%s vel=%s (%.0f studs/s) plat=%s anch=%s net=%s",
		okState and tostring(state):gsub("Enum.HumanoidStateType.", "") or "?", hum.Health, hum.MaxHealth,
		hum.WalkSpeed, fmtVec(root.Position), fmtVec(root.AssemblyLinearVelocity),
		root.AssemblyLinearVelocity.Magnitude, tostring(hum.PlatformStand), tostring(root.Anchored), netOwner))
end

local function scanObjects()
	sep("OBJECT SEARCH (token-matched: run / running / treadmill / belt — 'plot' noise removed)")
	if firstScanDone and CONFIG.SKIP_REPEAT_SCAN then
		say("OBJECTS", "skipped — object set does not change mid-session; a full Workspace walk costs ~1s " ..
			"(CONFIG.SKIP_REPEAT_SCAN=false to force it)")
		return
	end
	local wanted = { run = true, running = true, treadmill = true, belt = true }
	local matches, checked = {}, 0
	for _, obj in ipairs(Workspace:GetDescendants()) do
		checked = checked + 1
		if checked % 2000 == 0 then task.wait() end
		local hitToken
		for _, tok in ipairs(tokens(obj.Name)) do
			if wanted[tok] then hitToken = tok break end
		end
		if hitToken then
			matches[#matches + 1] = string.format("%s -> %s  [%s]", obj.ClassName, obj:GetFullName(), hitToken)
			if #matches > 400 then break end
		end
	end
	say("OBJECTS", string.format("scanned %d instances, %d token matches", checked, #matches))
	for i = 1, math.min(#matches, CONFIG.SCAN_LIMIT_OBJECTS) do
		say("OBJECTS", matches[i])
	end
	if #matches > CONFIG.SCAN_LIMIT_OBJECTS then
		say("OBJECTS", string.format("… %d more (increase CONFIG.SCAN_LIMIT_OBJECTS to see)", #matches - CONFIG.SCAN_LIMIT_OBJECTS))
	end
end

local function remoteFamily(fullName)
	-- ReplicatedStorage.Packages.Networking.RE/BossEvent/HazardHit -> "RE/BossEvent"
	local path = tostring(fullName):gsub("^game%.", ""):gsub("^ReplicatedStorage%.", "")
		:gsub("^Packages%.", ""):gsub("^Networking%.", "")
	local kind, rest = string.match(path, "^(R[EF])/(.+)$")
	if kind and rest then
		local first = string.match(rest, "^([^/]+)")
		if first then return kind .. "/" .. first end
	end
	return path
end

local function scanRemotes()
	sep("REMOTE INVENTORY")
	local groups, total, rf = {}, 0, 0
	for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
		local isRE = obj:IsA("BaseRemoteEvent") or obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent")
		local isRF = obj:IsA("RemoteFunction")
		if isRE or isRF then
			total = total + 1
			if isRF then rf = rf + 1 end
			local fam = remoteFamily(obj:GetFullName())
			groups[fam] = groups[fam] or { re = 0, rf = 0, names = {} }
			if isRE then groups[fam].re = groups[fam].re + 1 else groups[fam].rf = groups[fam].rf + 1 end
			if #groups[fam].names < 14 then
				local short = tostring(obj:GetFullName()):gsub("ReplicatedStorage%.Packages%.Networking%.", "")
				groups[fam].names[#groups[fam].names + 1] = short
			end
			local shortPath = tostring(obj:GetFullName()):gsub("^game%.", ""):gsub("^ReplicatedStorage%.", "")
			if matchesFocus(shortPath) then groups[fam].focused = true end
			if watchedRemoteNames[obj] then groups[fam].watched = true end
		end
	end
	local fams = {}
	for name, g in pairs(groups) do fams[#fams + 1] = { name = name, g = g } end
	table.sort(fams, function(a, b) return a.name < b.name end)

	local function printFamily(f)
		local g = f.g
		say("REMOTES", string.format("%-34s RE=%-3d RF=%-3d %s", f.name, g.re, g.rf,
			(g.watched and "  <-- LISTENING" or (g.focused and "  <-- FOCUS family (hit/ragdoll/carry)" or ""))))
		for _, n in ipairs(g.names) do say("REMOTES", "      " .. n) end
		if (g.re + g.rf) > #g.names then say("REMOTES", string.format("      … %d more", (g.re + g.rf) - #g.names)) end
	end

	say("REMOTES", string.format("total=%d (RemoteEvent=%d RemoteFunction=%d) families=%d",
		total, total - rf, rf, #fams))
	if firstScanDone and CONFIG.SKIP_REPEAT_SCAN then
		local added, changed, removed = {}, {}, {}
		for _, f in ipairs(fams) do
			local old = lastInventory[f.name]
			if not old then added[#added + 1] = f
			elseif old.re ~= f.g.re or old.rf ~= f.g.rf then changed[#changed + 1] = f end
		end
		for name in pairs(lastInventory) do
			if not groups[name] then removed[#removed + 1] = name end
		end
		table.sort(removed)
		if (#added + #changed + #removed) == 0 then
			say("REMOTES", "inventory unchanged since the previous scan — family listing suppressed " ..
				"(CONFIG.SKIP_REPEAT_SCAN=false for the full dump every time)")
		else
			say("REMOTES", string.format("inventory changed: %d added, %d changed, %d removed",
				#added, #changed, #removed))
			for _, f in ipairs(added) do
				say("REMOTES", "NEW  " .. f.name)
				printFamily(f)
			end
			for _, f in ipairs(changed) do
				local old = lastInventory[f.name]
				say("REMOTES", string.format("CHANGED %-28s RE %d->%d  RF %d->%d",
					f.name, old.re, f.g.re, old.rf, f.g.rf))
			end
			for _, name in ipairs(removed) do say("REMOTES", "GONE " .. name) end
		end
	else
		for _, f in ipairs(fams) do printFamily(f) end
		say("REMOTES", "full family listing (first scan of this session)")
	end
	lastInventory = {}
	for name, g in pairs(groups) do lastInventory[name] = { re = g.re, rf = g.rf } end
	local planned = #watchList(watchMode)
	say("REMOTES", string.format("watching now: %d | %s mode selects %d of %d remote events%s",
		countWatched(), watchMode, planned, total, watching and "" or " (WATCH is OFF)"))
end

doScan = function()
	sep("FULL SCAN")
	if not watching then
		say("TIP", "WATCH is OFF — press WATCH: ON before you play so a hit is recorded with the remote that caused it")
	end
	say("INFO", string.format("player=%s userId=%d | mode=%s | server clock %s",
		localPlayer.Name, localPlayer.UserId or 0, watchMode, clockOf(serverNow())))
	scanLeaderstats()
	scanPlayerAttributes()
	scanCharacter()
	scanHumanoid()
	scanRemotes()
	scanObjects()
	sep("SCAN COMPLETE")
	say("INFO", "read-only: no remote calls made, no character properties written")
	firstScanDone = true
	refreshStatus()
end

-- ---------------------------------------------------------------- watch layer
countWatched = function()
	local n = 0
	for _ in pairs(watchedRemoteNames) do n = n + 1 end
	return n
end

matchesFocus = function(path)
	local lower = path:lower()
	for _, pat in ipairs(FOCUS_PATTERNS) do
		if string.find(lower, pat:lower(), 1, true) then return true end
	end
	return false
end

watchList = function(mode)
	mode = mode or watchMode
	local list = {}
	for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
		if obj:IsA("BaseRemoteEvent") or obj:IsA("RemoteEvent") or obj:IsA("UnreliableRemoteEvent") then
			local path = tostring(obj:GetFullName()):gsub("^game%.", ""):gsub("^ReplicatedStorage%.", "")
			if mode == "all" or matchesFocus(path) then
				list[#list + 1] = { instance = obj, path = path }
			end
		end
	end
	table.sort(list, function(a, b) return a.path < b.path end)
	return list
end

local function statsSnapshot()
	local events, suppressed, lastSecond = 0, 0, 0
	local t = now()
	for _, st in pairs(remoteStats) do
		events = events + st.count
		suppressed = suppressed + st.suppressed
		if t - st.last <= 1 then lastSecond = lastSecond + st.inWindow end
	end
	local run = math.max(elapsed(), 0.001)
	return { events = events, suppressed = suppressed, perMinute = math.floor(events / run * 60),
		recentPerSecond = lastSecond, outgoingCalls = 0, entries = #journal, dropped = dropped,
		connections = connectionCount, remoteStats = remoteStats,
		quiet = (lastEventT > 0) and (t - lastEventT) or nil }
end

local function remoteStat(path)
	local st = remoteStats[path]
	if not st then
		st = { count = 0, window = now(), inWindow = 0, suppressed = 0, last = 0 }
		remoteStats[path] = st
	end
	return st
end

local function onRemoteFired(path, ...)
	local t = now()
	lastEventT = t
	local okArgs, payload = pcall(serializeArgs, ...)
	if not okArgs then payload = "<payload could not be serialized: " .. tostring(payload) .. ">" end
	local st = remoteStat(path)
	st.count = st.count + 1
	st.last = t
	if t - st.window >= 1 then
		st.window = t
		st.inWindow = 0
	end
	-- remember for HIT attribution regardless of rate limiting
	recentEvents[#recentEvents + 1] = { t = t, path = path, args = payload }
	while #recentEvents > CONFIG.RECENT_EVENTS do table.remove(recentEvents, 1) end

	st.inWindow = st.inWindow + 1
	if st.inWindow > CONFIG.RATE_LIMIT then
		st.suppressed = st.suppressed + 1
		-- one summary row per second so floods are visible but don't drown the log
		if not st.rateRowT or (t - st.rateRowT) >= 1 then
			st.rateRowT = t
			say("RATE", string.format("%s flood: %d in the last second (logging suppressed)", path, st.inWindow))
		end
		return
	end
	say("RE", path .. (payload ~= "" and ("  |  " .. payload) or ""))
end

-- Connects the requested mode's remotes into a fresh set and only then swaps out the old ones, so a
-- failure can never leave the scanner silently dead (a live run showed mode=all with a stale watched=65
-- and zero events received — that state is impossible now).
connectWatch = function(mode)
	mode = mode or watchMode
	local newConns, newNames, connected, planned = {}, {}, 0, 0
	local ok, err = pcall(function()
		if simulate.connectFailure then error("simulated connect failure (diagnostic hook)") end
		local list = watchList(mode)
		planned = #list
		for _, entry in ipairs(list) do
			newNames[entry.instance] = true
			local cok = pcall(function()
				local conn = entry.instance.OnClientEvent:Connect(function(...)
					onRemoteFired(entry.path, ...)
				end)
				newConns[#newConns + 1] = conn
				extraConns[#extraConns + 1] = conn
				connectionCount = connectionCount + 1
			end)
			if cok then connected = connected + 1 else newNames[entry.instance] = nil end
		end
	end)
	if not ok then
		for _, conn in ipairs(newConns) do pcall(function() conn:Disconnect() end) end
		return 0, tostring(err), planned
	end
	for _, conn in ipairs(watchConns) do pcall(function() conn:Disconnect() end) end
	watchConns = newConns
	watchedRemoteNames = newNames
	watchMode = mode
	say("WATCH", string.format("listening on %d of %d remote event(s) — %s mode (read-only, OnClientEvent only)",
		connected, planned, mode))
	if connected < planned then
		say("WARN", string.format("%d of %d remotes could not be hooked in %s mode",
			planned - connected, planned, mode))
	end
	return connected, nil, planned
end

disconnectWatch = function()
	for _, conn in ipairs(watchConns) do pcall(function() conn:Disconnect() end) end
	table.clear(watchConns)
	watchedRemoteNames = {}
	local kept = {}
	for _, conn in ipairs(extraConns) do
		if not conn.disconnected then kept[#kept + 1] = conn end
	end
	extraConns = kept
	say("WATCH", "listener disconnected")
end

local function describeRagdollForHit()
	local v = localPlayer:GetAttribute("RagdollEndTime")
	if type(v) ~= "number" or v <= 0 then return "RagdollEndTime=none" end
	local left = v - serverNow()
	return string.format("RagdollEndTime=%s (%+.1fs) area=%s", clockOf(v), left,
		tostring(localPlayer:GetAttribute("AreaId") or "?"))
end

local function hitReport(dv, vel, root, hum)
	local t = now()
	local recent = {}
	for i = #recentEvents, 1, -1 do
		local e = recentEvents[i]
		if (t - e.t) > CONFIG.ATTRIB_WINDOW then break end
		table.insert(recent, 1, e)
	end
	local attribution = "(no remote event in the previous 0.25s)"
	if #recent > 0 then
		local parts = {}
		for _, e in ipairs(recent) do
			parts[#parts + 1] = string.format("%s @%+.0fms%s", e.path, (e.t - t) * 1000,
				e.args ~= "" and (" [" .. e.args .. "]") or "")
		end
		attribution = table.concat(parts, "  ||  ")
	end
	hits = hits + 1
	say("HIT", string.format("#%d dv=%.0f studs/s | vel=%s (%.0f) | pos=%s | %s | %s",
		hits, dv, fmtVec(vel), math.sqrt(vel.X * vel.X + vel.Y * vel.Y + vel.Z * vel.Z),
		fmtVec(root.Position), describeRagdollForHit(), attribution))
end

local function onAttribute(name, value)
	if name == "RagdollEndTime" then
		local d = decodeRagdoll(value)
		say("ATTR", string.format("RagdollEndTime -> %s", d.text))
	elseif name == "AreaId" then
		say("ATTR", string.format("AreaId -> %s", tostring(value)))
	elseif string.find(name:lower(), "ragdoll", 1, true) or string.find(name:lower(), "carry", 1, true)
		or string.find(name:lower(), "limp", 1, true) then
		say("ATTR", string.format("%s -> %s", name, tostring(value)))
	end
end

local function connectSignals()
	track(localPlayer.AttributeChanged:Connect(function(name, value)
		if value == nil then value = localPlayer:GetAttribute(name) end
		onAttribute(name, value)
	end))
	local ok, err = pcall(function()
		track(localPlayer.Changed:Connect(function(prop)
			if prop == "Character" then
				say("SIGNAL", "Character changed (respawn)")
				lastVelocity, lastWalkSpeed, lastHealth, lastState = nil, nil, nil, nil
			end
		end))
	end)
	if not ok then say("INFO", "player.Changed unavailable: " .. tostring(err)) end

	local function hookCharacter(char)
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum then return end
		track(hum.HealthChanged:Connect(function(hp)
			if lastHealth and math.abs(hp - lastHealth) > 0.01 then
				say("HEALTH", string.format("%.1f -> %.1f (%+.1f)", lastHealth, hp, hp - lastHealth))
			end
			lastHealth = hp
		end))
		track(hum.StateChanged:Connect(function(a, b, c)
			-- Roblox passes (old, new); tolerate a leading instance argument too
			local old, new = a, b
			if type(a) == "table" and a.ClassName ~= nil then
				-- instance-prefixed signature: (self, newState, previousState)
				new, old = b, c
			end
			local function label(v) return tostring(v):gsub("Enum.HumanoidStateType.", "") end
			say("STATE", string.format("%s -> %s", label(old), label(new)))
			lastState = new
		end))
		track(hum.Changed:Connect(function(prop)
			if prop == "WalkSpeed" then
				local ws = hum.WalkSpeed
				if lastWalkSpeed and math.abs(ws - lastWalkSpeed) >= CONFIG.WALKSPEED_JOLT then
					local note = ""
					if math.abs(ws - 500) <= 2 then
						note = "   <-- matches the flight script constant (500)"
					elseif ws >= 100 then
						note = "   <-- high (game speed stat / unknown writer)"
					end
					say("WALKSPEED", string.format("%.0f -> %.0f%s", lastWalkSpeed, ws, note))
				end
				lastWalkSpeed = ws
			elseif prop == "PlatformStand" then
				say("SIGNAL", "PlatformStand = " .. tostring(hum.PlatformStand))
			end
		end))
		track(char.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then say("TOOL", "+ " .. child.Name .. "  (carrying)") end
		end))
		track(char.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then say("TOOL", "- " .. child.Name .. "  (no longer carrying)") end
		end))
		lastHealth, lastWalkSpeed = hum.Health, hum.WalkSpeed
		lastState = hum:GetState()
		local root = char:FindFirstChild("HumanoidRootPart")
		if root then
			track(root.Changed:Connect(function(prop)
				if prop == "Anchored" then say("SIGNAL", "Anchored = " .. tostring(root.Anchored)) end
			end))
		end
	end

	local char = localPlayer.Character
	if char then hookCharacter(char) end
	track(localPlayer.CharacterAdded:Connect(function(newChar)
		say("SIGNAL", "CharacterAdded")
		task.wait(0.1)
		hookCharacter(newChar)
	end))
end

local heartbeatBody

local function heartbeat()
	local ok, err = pcall(heartbeatBody)
	if not ok then reportError("heartbeat error (detection is affected)", err) end
end

heartbeatBody = function()
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then return end

	local vel = root.AssemblyLinearVelocity
	local speed = vel.Magnitude
	if watching then
		local dv = lastVelocity and (vel - lastVelocity).Magnitude or 0
		if dv > CONFIG.HIT_DV then
			local t = now()
			if (t - lastHitT) >= CONFIG.HIT_DEBOUNCE then
				lastHitT = t
				hitReport(dv, vel, root, hum)
			end
		end
		-- script-driven fast movement (not ragdolled, not a hit)
		if speed > CONFIG.FASTMOVE_SPEED and hum:GetState() ~= Enum.HumanoidStateType.Physics then
			fastMoveStreak = fastMoveStreak + 1
			local t = now()
			if fastMoveStreak >= CONFIG.FASTMOVE_STREAK and (t - lastFastMove) > 0.5 then
				lastFastMove = t
				say("FASTMOVE", string.format("%.0f studs/s ws=%.0f state=%s (driver running, not ragdolled)",
					speed, hum.WalkSpeed, tostring(hum:GetState()):gsub("Enum.HumanoidStateType.", "")))
			end
		else
			fastMoveStreak = 0
		end
	end
	lastVelocity = vel

	-- status row once a second while watching (gives the copied log a timeline)
	local t = now()
	if watching and (t - lastStatus) >= (1 / CONFIG.STATUS_HZ) then
		lastStatus = t
		statusRows = statusRows + 1
		local left = ragdollRemaining()
		local st = statsSnapshot()
		say("STATUS", string.format(
			"state=%s hp=%.0f ws=%.0f speed=%.0f ragdoll=%s area=%s | watched=%d/%s | events=%d quiet=%s%s",
			tostring(hum:GetState()):gsub("Enum.HumanoidStateType.", ""), hum.Health, hum.WalkSpeed, speed,
			left and string.format("%.1fs", left) or "-",
			tostring(localPlayer:GetAttribute("AreaId") or "?"),
			countWatched(), watchMode, st.events,
			st.quiet and string.format("%.0fs", st.quiet) or "-",
			(#recentEvents > 0) and "" or " | (no remote has fired yet)"))
	end

	local world = now()
	if (world - lastRender) >= (1 / CONFIG.RENDER_HZ) then
		lastRender = world
		if dirty then render() dirty = false end
		refreshStatus()
	end
end

local function applyMode(mode)
	mode = (mode == "all") and "all" or "focus"
	if modeButton then modeButton.Text = "MODE: " .. string.upper(mode) end
	if mode == watchMode and watching then return watchMode end
	if not watching then
		watchMode = mode
		say("INFO", string.format("mode = %s | %d remote event(s) will be watched when WATCH turns on",
			mode, #watchList(mode)))
		return watchMode
	end
	local connected, failure, planned = connectWatch(mode)
	if failure then
		reportError("mode change to " .. mode .. " failed (previous listener kept)", failure)
		if modeButton then modeButton.Text = "MODE: " .. string.upper(watchMode) end
		return watchMode
	end
	say("INFO", string.format("mode = %s | reconnected %d of %d remote event(s)", mode, connected, planned))
	return watchMode
end

local function setWatch(on)
	if on and not watching then
		watching = true
		local connected, failure, planned = connectWatch(watchMode)
		if failure then
			watching = false
			reportError("WATCH could not start", failure)
		elseif connected == 0 then
			watching = false
			reportError("WATCH could not start", "no remotes could be hooked")
		else
			say("WATCH", string.format("watching %d remote(s) in %s mode", connected, watchMode))
		end
		if watchButton then watchButton.Text = "WATCH: ON" end
		say("WATCH", "watching ON — play now; a hit will produce a HIT row with the remote that caused it")
		local left = ragdollRemaining()
		if left then say("ATTR", string.format("ragdoll window active: %.1fs left", left)) end
	elseif (not on) and watching then
		watching = false
		disconnectWatch()
		if watchButton then watchButton.Text = "WATCH: OFF" end
	end
	return watching
end

-- ---------------------------------------------------------------- copy / API
doCopy = function(button)
	local text = doExport()
	local ok = false
	if setclipboard then
		ok = pcall(function() setclipboard(text) end)
	end
	if button then
		button.Text = ok and "COPIED!" or "NO CLIPBOARD"
		task.delay(1.5, function() button.Text = "COPY RESULTS" end)
	end
	return ok, text
end

doExport = function()
	local lines = {
		"===== ADVANCED SCANNER v3 (listener) =====",
		string.format("exported at t+%.3fs | entries=%d dropped=%d | watch=%s mode=%s | watched=%d",
			elapsed(), #journal, dropped, watching and "ON" or "OFF", watchMode, countWatched()),
		string.format("player=%s | userId=%s", localPlayer.Name, tostring(localPlayer.UserId)),
		"",
	}
	for _, entry in ipairs(journal) do
		lines[#lines + 1] = entry.line
	end
	return table.concat(lines, "\n")
end

destroy = function()
	pcall(function()
		for _, conn in ipairs(extraConns) do conn:Disconnect() end
		for _, conn in ipairs(watchConns) do conn:Disconnect() end
	end)
	table.clear(extraConns)
	table.clear(watchConns)
	if gui then pcall(function() gui:Destroy() end) end
	_G.ADVANCED_SCANNER_V3 = nil
end

API = {}
API.scan = function() task.spawn(doScan) return true end
API.watch = setWatch
API.setMode = function(mode) return applyMode(mode) end
API.clear = function()
	local st = statsSnapshot()
	local snapshot = string.format("journal cleared — state kept: watch=%s mode=%s watched=%d (pre-clear events=%d)",
		watching and "ON" or "OFF", watchMode, countWatched(), st.events)
	table.clear(journal)
	journalCount, dropped = 0, 0
	dirty = true
	say("INFO", snapshot)
end
API.copy = function() return doCopy(nil) end
API.export = doExport
API.status = function()
	return { watching = watching, mode = watchMode, watched = countWatched(),
		ragdollRemaining = ragdollRemaining(), hits = hits,
		statusText = statusLabel and statusLabel.Text or "" }
end
API.journal = function()
	local out = {}
	for i, e in ipairs(journal) do out[i] = { n = e.n, t = e.t, tag = e.tag, text = e.text, line = e.line } end
	return out
end
API.stats = function() return statsSnapshot() end
API.destroy = destroy
API._internals = {
	tokens = tokens, hasToken = hasToken, decodeRagdoll = decodeRagdoll, serializeValue = serializeValue,
	serializeArgs = serializeArgs, watchList = watchList, matchesFocus = matchesFocus,
	recentEvents = function() return recentEvents end, conns = function() return extraConns end,
	simulate = simulate,
}

_G.ADVANCED_SCANNER_V3 = API

local guiOk = buildGui()
if guiOk then
	refreshStatus()
	sep("READY")
	say("INFO", "v3 listener ready. FULL SCAN = inventory, WATCH ON = live capture, COPY RESULTS = paste here.")
else
	say("INFO", "GUI could not be parented (no PlayerGui) — API still available")
end
if CONFIG.AUTO_WATCH then
	say("INFO", "AUTO_WATCH is on — the listener starts with the script, so a hit is captured even if you forget the button")
	setWatch(true)
end

track(RunService.Heartbeat:Connect(heartbeat))
connectSignals()
return API
