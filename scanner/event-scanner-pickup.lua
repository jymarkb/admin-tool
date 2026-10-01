--[[
  SPEED CAP ROOT-CAUSE INVESTIGATOR
  ===================================
  Goal: find WHAT the speed-polling loop reads to decide to cap speed.

  Strategies:
    A) getconnections() on key RemoteEvents  → expose pre-existing handlers
    B) player.AttributeChanged               → catch attribute flips at pickup
    C) character.AttributeChanged            → same for character
    D) character.ChildAdded / ChildRemoved   → tool/value inserted at pickup?
    E) Humanoid.StateChanged                 → ragdoll / PlatformStand flip
    F) WalkSpeed watcher (no stack trace)    → just timing + current speed
    G) Outgoing RF/RE hook                   → AskFieldEggCarry + related
    H) Incoming RE hook (__index)            → any NEW connections on known REs

  Key REs to inspect (from 1.8-data-support.txt):
    RE/EggWorld/FieldEggCarry
    RE/Limpness/WriteLimpness
    RE/StaffConsole/WriteWalkSpeed
    RE/RigSync/CorrectionBegan
    RE/BossEvent/HazardHit
    RE/GuardPatrol/SpeedTollOffer
    RE/GuardPatrol/SpeedTollWarning
    RE/EggWorld/OwnerShifted
]]

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local pg     = player:WaitForChild("PlayerGui")

-- ============================================================
-- UI
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SpeedCapInvestigator"
screenGui.ResetOnSpawn = false
screenGui.Parent = pg

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 460, 0, 462)
main.Position = UDim2.new(0, 20, 0.15, 0)
main.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 34)
titleBar.BackgroundColor3 = Color3.fromRGB(18, 22, 40)
titleBar.BorderSizePixel = 0
titleBar.Active = true
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -40, 1, 0)
titleLbl.Position = UDim2.new(0, 10, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "SPEED CAP INVESTIGATOR — READY"
titleLbl.TextColor3 = Color3.fromRGB(100, 210, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 12
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -31, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(160, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 13
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

-- Drag
local dragging, dragStart, startPos = false, nil, nil
titleBar.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1
		or i.UserInputType == Enum.UserInputType.Touch then
		dragging = true; dragStart = i.Position; startPos = main.Position
	end
end)
UserInputService.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
		or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - dragStart
		main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
		                          startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)
UserInputService.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1
		or i.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)

local console = Instance.new("TextBox")
console.Size = UDim2.new(1, -16, 1, -88)
console.Position = UDim2.new(0, 8, 0, 42)
console.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
console.TextColor3 = Color3.fromRGB(210, 215, 230)
console.Font = Enum.Font.Code
console.TextSize = 11
console.Text = "Press START..."
console.TextWrapped = false
console.TextXAlignment = Enum.TextXAlignment.Left
console.TextYAlignment = Enum.TextYAlignment.Top
console.ClearTextOnFocus = false
console.MultiLine = true
console.Parent = main
Instance.new("UICorner", console).CornerRadius = UDim.new(0, 6)
local cp = Instance.new("UIPadding", console)
cp.PaddingLeft = UDim.new(0, 5)
cp.PaddingTop  = UDim.new(0, 5)

-- ============================================================
-- STATE
-- ============================================================

local active    = false
local logLines  = {}
local MAX_LINES = 999999999999
local conns     = {}   -- all connections made on START, cleared on STOP
local lastSpeed = nil  -- previous WalkSpeed for delta in speed watcher

-- ============================================================
-- VELOCITY STATE
-- ============================================================
local velEnabled    = false
local velTarget     = 246        -- updated from input box
local velBaseSpeed  = nil        -- auto-detected from hum.WalkSpeed on START
local velHookActive = false
local velOldNI      = nil        -- stores original __newindex
local velHBConn     = nil        -- RunService.Heartbeat connection

local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)
local origProps    = {}          -- saves original CustomPhysicalProperties


-- RemoteEvent patterns to watch (key = label, value = substring of GetFullName())
local RE_WATCH = {
	FieldEggCarry    = "EggWorld/FieldEggCarry",
	OwnerShifted     = "EggWorld/OwnerShifted",
	WriteLimpness    = "Limpness/WriteLimpness",
	WriteWalkSpeed   = "StaffConsole/WriteWalkSpeed",
	SpeedPowerVerdict= "StaffConsole/SpeedPowerVerdict",
	CorrectionBegan  = "RigSync/CorrectionBegan",
	HazardHit           = "BossEvent/HazardHit",
	SpeedTollOffer      = "GuardPatrol/SpeedTollOffer",
	SpeedTollWarning    = "GuardPatrol/SpeedTollWarning",
	FieldEggShifted     = "EggWorld/FieldEggShifted",    -- egg state/size changes
}

-- Outgoing remotes to log
local RF_WATCH = {
	["AskFieldEggCarry"]       = true,
	["AskFieldEggDrop"]        = true,
	["AskFieldEggSnapshot"]    = true,  -- called post-pickup to get egg metadata
	["AskFieldEggRarityShows"] = true,  -- may expose size/rarity
	["Reconcile"]              = true,
}

-- Outgoing remotes to silence entirely
local RF_BLACKLIST = {
	["ProbeSatchel"]    = true,
	["Ping"]            = true,
	["Fps"]             = true,
	["AskIdleHopFlush"] = true,
	["SubmitIdleHop"]   = true,
	["SubmitIdleState"] = true,
	["FetchSummary"]    = true,
}

-- ============================================================
-- LOGGER
-- ============================================================

local function ts()
	return string.format("%.3f", tick())
end

local function setTitle(t)
	pcall(function() titleLbl.Text = "SPEED CAP INVESTIGATOR — " .. t end)
end

local function emit(txt)
	table.insert(logLines, txt)
	while #logLines > MAX_LINES do table.remove(logLines, 1) end
	pcall(function() console.Text = table.concat(logLines, "\n") end)
end

local function getSpeed()
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	return h and h.WalkSpeed or -1
end

local function formatVal(v, depth)
	depth = depth or 0
	if v == nil then return "nil" end
	local t = typeof(v)
	if t == "string"  then return '"'..v..'"' end
	if t == "number" or t == "boolean" or t == "EnumItem" then return tostring(v) end
	if t == "Instance" then
		local ok, n = pcall(function() return v:GetFullName() end)
		return ok and "<"..n..">" or "<Instance>"
	end
	if t == "table" and depth < 3 then
		local parts = {}
		for k, cv in pairs(v) do
			local ok, s = pcall(formatVal, cv, depth+1)
			parts[#parts+1] = "["..tostring(k).."]=".. (ok and s or "?")
		end
		return "{".. table.concat(parts,", ") .."}"
	end
	local ok, s = pcall(tostring, v)
	return ok and s or "<?>"
end

-- ============================================================
-- STRATEGY A: getconnections() dump on key RemoteEvents
-- Runs once at START to reveal pre-existing handlers we can't hook
-- ============================================================

local function dumpExistingConnections()
	if not getconnections then
		emit("[CONN DUMP] getconnections() not available — skipping")
		return
	end

	-- Walk all descendants to find matching REs
	for label, pattern in pairs(RE_WATCH) do
		for _, v in ipairs(game:GetDescendants()) do
			local ok, isRE = pcall(function()
				return v:IsA("RemoteEvent") and v:GetFullName():find(pattern, 1, true)
			end)
			if ok and isRE then
				local fullName = v:GetFullName()
				local ok2, conList = pcall(getconnections, v.OnClientEvent)
				if ok2 and conList then
					local lines = {
						string.format("[CONN DUMP] %s  (%s)  — %d handler(s):",
							label, fullName, #conList)
					}
					for i, c in ipairs(conList) do
						local fnStr  = "?"
						local srcStr = ""
						pcall(function()
							fnStr = tostring(c.Function)
							if c.Script then
								srcStr = " @ "..tostring(c.Script)
							end
						end)
						lines[#lines+1] = string.format(
							"  [%d] enabled=%s  fn=%s%s",
							i, tostring(c.Enabled), fnStr, srcStr
						)
					end
					emit(table.concat(lines, "\n"))
				else
					emit(string.format("[CONN DUMP] %s (%s) — getconnections failed", label, fullName))
				end
				break  -- found this RE, move to next label
			end
		end
	end
end

-- ============================================================
-- STRATEGY B + C: Attribute change monitors
-- ============================================================

local function attachAttributeWatchers()
	-- Player attributes
	local pc = player.AttributeChanged:Connect(function(attrName)
		if not active then return end
		local val = player:GetAttribute(attrName)
		emit(string.format(
			"[PLAYER ATTR] %s  t=%s  spd=%.4f\n  %s = %s",
			ts(), ts(), getSpeed(), attrName, tostring(val)
		))
	end)
	conns[#conns+1] = pc

	-- Character attributes
	local char = player.Character
	if not char then return end
	local cc = char.AttributeChanged:Connect(function(attrName)
		if not active then return end
		local val = char:GetAttribute(attrName)
		emit(string.format(
			"[CHAR ATTR]   %s  spd=%.4f\n  %s = %s",
			ts(), getSpeed(), attrName, tostring(val)
		))
	end)
	conns[#conns+1] = cc
end

-- ============================================================
-- STRATEGY D: character ChildAdded / ChildRemoved
-- ============================================================

local function attachChildWatchers()
	local char = player.Character
	if not char then return end

	local added = char.ChildAdded:Connect(function(child)
		if not active then return end
		emit(string.format(
			"[CHAR +CHILD] %s  spd=%.4f\n  + %s (%s)",
			ts(), getSpeed(), child.Name, child.ClassName
		))
		-- If it has a Value, log it too
		if child:IsA("ValueBase") then
			emit(string.format("    .Value = %s", tostring(child.Value)))
		end
	end)
	conns[#conns+1] = added

	local removed = char.ChildRemoved:Connect(function(child)
		if not active then return end
		emit(string.format(
			"[CHAR -CHILD] %s  spd=%.4f\n  - %s (%s)",
			ts(), getSpeed(), child.Name, child.ClassName
		))
	end)
	conns[#conns+1] = removed
end

-- ============================================================
-- STRATEGY E: Humanoid state + PlatformStand watcher
-- ============================================================

local function attachHumanoidWatchers()
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	-- State changes (ragdoll = Physics or FallingDown)
	local sc = hum.StateChanged:Connect(function(old, new)
		if not active then return end
		emit(string.format(
			"[HUM STATE]   %s  spd=%.4f\n  %s -> %s",
			ts(), getSpeed(),
			tostring(old):gsub("Enum%.HumanoidStateType%.",""),
			tostring(new):gsub("Enum%.HumanoidStateType%.","")
		))
	end)
	conns[#conns+1] = sc

	-- PlatformStand flip (ragdoll sets this true)
	local ps = hum:GetPropertyChangedSignal("PlatformStand"):Connect(function()
		if not active then return end
		emit(string.format(
			"[PLATFORMSTAND] %s  spd=%.4f  PlatformStand=%s",
			ts(), getSpeed(), tostring(hum.PlatformStand)
		))
	end)
	conns[#conns+1] = ps

	-- JumpPower / JumpHeight changes (speed controller may touch these too)
	local jp = hum:GetPropertyChangedSignal("JumpPower"):Connect(function()
		if not active then return end
		emit(string.format(
			"[JUMPOWER]    %s  spd=%.4f  JumpPower=%.4f",
			ts(), getSpeed(), hum.JumpPower
		))
	end)
	conns[#conns+1] = jp
end

-- ============================================================
-- STRATEGY F: WalkSpeed watcher (timing only, no stack trace)
-- ============================================================


local function attachSpeedWatcher()
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	lastSpeed = hum.WalkSpeed

	local sw = hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if not active then return end
		local now   = getSpeed()
		local delta = now - (lastSpeed or now)
		emit(string.format(
			"[SPEED]       %s  %.4f -> %.4f  delta=%.4f (%s)",
			ts(), lastSpeed or 0, now, delta,
			delta < 0 and "SLOWER" or "FASTER"
		))
		lastSpeed = now
	end)
	conns[#conns+1] = sw
	emit(string.format("[WATCHER] WalkSpeed watcher attached  current=%.4f", hum.WalkSpeed))
end

-- ============================================================
-- STRATEGY H: Incoming RE hook (__index) for NEW connections
-- ============================================================

local incomingHookDone = false
local oldIndex

local function attachIncomingHook()
	if incomingHookDone then return end
	incomingHookDone = true

	oldIndex = hookmetamethod(game, "__index", function(self, key)
		local result = oldIndex(self, key)

		if not active or key ~= "OnClientEvent" then return result end

		local isRE = false
		pcall(function() isRE = self:IsA("RemoteEvent") end)
		if not isRE then return result end

		local remoteName = ""
		pcall(function() remoteName = self:GetFullName() end)

		local label = nil
		for tag, pattern in pairs(RE_WATCH) do
			if remoteName:find(pattern, 1, true) then label = tag break end
		end
		if not label then return result end

		-- Wrap Connect to intercept the callback
		return {
			Connect = function(_, cb)
				return result:Connect(function(...)
					if active then
						local args = {...}
						local lines = {
							string.format(">>> INCOMING [%s]  t=%s  spd=%.4f",
								label, ts(), getSpeed())
						}
						for i, v in ipairs(args) do
							local ok, s = pcall(formatVal, v)
							lines[#lines+1] = "  ["..i.."] = "..(ok and s or "<err>")
						end
						emit(table.concat(lines, "\n"))
					end
					return cb(...)
				end)
			end,
			Wait = function(_) return result:Wait() end,
		}
	end)

	emit("[INCOMING HOOK] Active for new OnClientEvent connections")
end

-- ============================================================
-- STRATEGY G: Outgoing RF/RE hook (FireServer / InvokeServer)
-- ============================================================

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
	local method = getnamecallmethod()
	if method ~= "FireServer" and method ~= "InvokeServer" then
		return oldNamecall(self, ...)
	end

	local pArgs    = table.pack(...)
	local pResults = table.pack(oldNamecall(self, ...))

	if active then pcall(function()
		local rn = self:GetFullName()

		-- Check blacklist by tail segment
		local tail = rn:match("([^/%.]+)$") or rn
		if RF_BLACKLIST[tail] then return end

		-- Only log if it's in the watch list or explicitly egg-related
		local isWatched = RF_WATCH[tail]
		      or rn:find("EggWorld",   1, true)
		      or rn:find("RigSync",    1, true)
		      or rn:find("Limpness",   1, true)
		      or rn:find("GuardPatrol",1, true)
		      or rn:find("BossEvent",  1, true)

		if not isWatched then return end

		local lines = {
			"------------------------------",
			string.format("[%s] %s  spd=%.4f", ts(), method, getSpeed()),
			rn,
		}

		if rn:find("AskFieldEggCarry", 1, true) then
			lines[#lines+1] = "*** EGG PICKUP ***"

			-- If pickup succeeded, schedule egg metadata fetch
			if method == "InvokeServer" and pResults[1] == true then
				local uid = ""
				pcall(function()
					if type(pArgs[1]) == "table" then uid = tostring(pArgs[1].Uid or "") end
				end)
				local speedNow   = getSpeed()
				local speedDelta = speedNow - (lastSpeed or speedNow)
				task.defer(function()
					fetchEggSnapshot(uid, speedDelta)
				end)
			end
		end

		-- Args
		lines[#lines+1] = "Args:"
		if pArgs.n == 0 then
			lines[#lines+1] = "  none"
		else
			for i = 1, pArgs.n do
				local ok, s = pcall(formatVal, pArgs[i])
				lines[#lines+1] = "  ["..i.."] = "..(ok and s or "<err>")
			end
		end

		if method == "InvokeServer" then
			lines[#lines+1] = "Return:"
			if pResults.n == 0 then
				lines[#lines+1] = "  none"
			else
				for i = 1, pResults.n do
					local ok, s = pcall(formatVal, pResults[i])
					lines[#lines+1] = "  ["..i.."] = "..(ok and s or "<err>")
				end
			end
		end

		emit(table.concat(lines, "\n"))
	end) end

	return table.unpack(pResults, 1, pResults.n)
end)

-- ============================================================
-- EGG SNAPSHOT: call AskFieldEggSnapshot + scan model size
-- Called automatically after AskFieldEggCarry returns true
-- ============================================================

local function findRF(namePart)
	for _, v in ipairs(game:GetDescendants()) do
		local ok, match = pcall(function()
			return v:IsA("RemoteFunction") and v:GetFullName():find(namePart, 1, true)
		end)
		if ok and match then return v end
	end
	return nil
end

local function scanEggModelSize(uid)
	-- After pickup, the egg model appears in ClientRenderedAssets keyed by UserId_uid
	-- Search workspace for any model whose name contains the uid or was recently added
	local lines = { "[EGG MODEL] Scanning workspace for egg model..." }
	local found = false

	-- Check ClientRenderedAssets first (known location from support data)
	local cra = workspace:FindFirstChild("ClientRenderedAssets")
	if cra then
		for _, model in ipairs(cra:GetChildren()) do
			-- Model name is usually UserId_uid hash
			local root = model:FindFirstChild("Root") or model.PrimaryPart
			             or model:FindFirstChildOfClass("Part")
			             or model:FindFirstChildOfClass("MeshPart")
			if root then
				local size = root.Size
				lines[#lines+1] = string.format(
					"  [CRA] %s  RootSize=(%.2f, %.2f, %.2f)  Vol=%.2f",
					model.Name, size.X, size.Y, size.Z,
					size.X * size.Y * size.Z
				)
				found = true
			end
		end
	end

	-- Also check character for attached egg tool/model
	local char = player.Character
	if char then
		for _, child in ipairs(char:GetChildren()) do
			if child:IsA("Tool") or child:IsA("Model") then
				local root = child.PrimaryPart or child:FindFirstChildOfClass("Part")
				if root then
					lines[#lines+1] = string.format(
						"  [CHAR] %s  RootSize=(%.2f, %.2f, %.2f)  Vol=%.2f",
						child.Name, root.Size.X, root.Size.Y, root.Size.Z,
						root.Size.X * root.Size.Y * root.Size.Z
					)
					found = true
				end
			end
		end
	end

	if not found then
		lines[#lines+1] = "  (no egg model found in ClientRenderedAssets or Character)"
	end
	emit(table.concat(lines, "\n"))
end

local function fetchEggSnapshot(uid, speedDelta)
	-- Small delay so the server has time to process before we query
	task.delay(0.3, function()
		if not active then return end

		emit(string.format(
			"[EGG SNAPSHOT] Querying for Uid=%s  speedDelta=%.4f",
			uid, speedDelta
		))

		-- Try AskFieldEggSnapshot
		local snapshotRF = findRF("AskFieldEggSnapshot")
		if snapshotRF then
			local ok, result = pcall(function()
				return snapshotRF:InvokeServer({ Uid = uid })
			end)
			if ok and result ~= nil then
				local ok2, s = pcall(formatVal, result)
				emit("[EGG SNAPSHOT] AskFieldEggSnapshot result:\n  " .. (ok2 and s or "<format err>"))
			else
				emit("[EGG SNAPSHOT] AskFieldEggSnapshot failed: " .. tostring(result))
			end
		else
			emit("[EGG SNAPSHOT] AskFieldEggSnapshot RF not found")
		end

		-- Try AskFieldEggRarityShows (may expose rarity/size tier)
		local rarityRF = findRF("AskFieldEggRarityShows")
		if rarityRF then
			local ok, result = pcall(function()
				return rarityRF:InvokeServer({ Uid = uid })
			end)
			if ok and result ~= nil then
				local ok2, s = pcall(formatVal, result)
				emit("[EGG RARITY] AskFieldEggRarityShows result:\n  " .. (ok2 and s or "<format err>"))
			else
				emit("[EGG RARITY] AskFieldEggRarityShows failed or nil")
			end
		end

		-- Scan workspace for physical egg model + size
		scanEggModelSize(uid)
	end)
end

-- ============================================================
-- SNAPSHOT: dump current state for baseline comparison
-- ============================================================

local function snapshotState(label)
	local char = player.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")

	local lines = { "===== "..label.." =====" }

	-- Player attributes
	lines[#lines+1] = "-- Player Attributes --"
	local pattrs = player:GetAttributes()
	local any = false
	for k, v in pairs(pattrs) do
		any = true
		lines[#lines+1] = "  "..k.." = "..tostring(v)
	end
	if not any then lines[#lines+1] = "  (none)" end

	-- Character attributes
	if char then
		lines[#lines+1] = "-- Character Attributes --"
		local cattrs = char:GetAttributes()
		any = false
		for k, v in pairs(cattrs) do
			any = true
			lines[#lines+1] = "  "..k.." = "..tostring(v)
		end
		if not any then lines[#lines+1] = "  (none)" end
	end

	-- Humanoid
	if hum then
		lines[#lines+1] = string.format(
			"-- Humanoid -- WalkSpeed=%.4f  JumpPower=%.4f  JumpHeight=%.4f  PlatformStand=%s  State=%s",
			hum.WalkSpeed, hum.JumpPower, hum.JumpHeight,
			tostring(hum.PlatformStand),
			tostring(hum:GetState()):gsub("Enum%.HumanoidStateType%.","")
		)
	end

	-- Character children that are ValueBase or Tools (things the speed loop might read)
	if char then
		lines[#lines+1] = "-- Character ValueBase/Tool children --"
		any = false
		for _, v in ipairs(char:GetChildren()) do
			if v:IsA("ValueBase") or v:IsA("Tool") or v:IsA("BoolValue")
				or v:IsA("NumberValue") or v:IsA("StringValue") or v:IsA("ObjectValue") then
				any = true
				local vstr = ""
				pcall(function() vstr = " = "..tostring(v.Value) end)
				lines[#lines+1] = "  "..v.Name.." ("..v.ClassName..")"..vstr
			end
		end
		if not any then lines[#lines+1] = "  (none)" end
	end

	lines[#lines+1] = "============================="
	emit(table.concat(lines, "\n"))
end

-- ============================================================
-- VELOCITY ENGINE
-- ============================================================

local RunService = game:GetService("RunService")

local function setFriction(enable)
	local char = player.Character
	if not char then return end
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") then
			if enable then
				if origProps[p] == nil then origProps[p] = p.CustomPhysicalProperties end
				pcall(function() p.CustomPhysicalProperties = zeroFriction end)
			else
				pcall(function() p.CustomPhysicalProperties = origProps[p] end)
				origProps[p] = nil
			end
		end
	end
end

-- __newindex hook: intercepts every WalkSpeed write on any Humanoid
-- so the egg-weight script can never lower it while vel is active
local function installVelHook()
	if velHookActive then return end
	if not hookmetamethod then
		emit("[VEL HOOK] hookmetamethod unavailable — egg writes not blocked")
		return
	end
	velOldNI = hookmetamethod(game, "__newindex", function(self, key, value)
		if key == "WalkSpeed" and velEnabled then
			local ok, isH = pcall(function() return self:IsA("Humanoid") end)
			if ok and isH then
				-- Replace egg-weight script's write with our target
				return velOldNI(self, key, velTarget)
			end
		end
		return velOldNI(self, key, value)
	end)
	velHookActive = true
	emit("[VEL HOOK] Active — WalkSpeed writes intercepted")
end

local function startVelocity()
	if velEnabled then return end
	velEnabled = true

	-- Auto-detect base speed from current WalkSpeed
	local char = player.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		velBaseSpeed = hum.WalkSpeed
		-- Default target to base if user hasn't changed it
		if velTarget <= 0 then velTarget = velBaseSpeed end
		emit(string.format("[VEL] Started — base=%.4f  target=%.4f", velBaseSpeed, velTarget))
	end

	installVelHook()
	setFriction(true)

	-- Heartbeat: write WalkSpeed + inject AssemblyLinearVelocity
	velHBConn = RunService.Heartbeat:Connect(function()
		if not velEnabled then return end
		local c = player.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		local r = c and c:FindFirstChild("HumanoidRootPart")
		if not h or not r then return end

		-- Let ragdoll states proceed naturally (hook still blocks WalkSpeed writes)
		local st = h:GetState()
		if st == Enum.HumanoidStateType.Physics
			or st == Enum.HumanoidStateType.Ragdoll
			or st == Enum.HumanoidStateType.FallingDown then
			return
		end

		-- Assert WalkSpeed = velTarget (hook ensures egg scripts can't override it)
		if h.WalkSpeed ~= velTarget then
			pcall(function() h.WalkSpeed = velTarget end)
		end

		-- Inject velocity when moving
		if h.MoveDirection.Magnitude > 0.05 then
			local dir = h.MoveDirection.Unit
			r.AssemblyLinearVelocity = Vector3.new(
				dir.X * velTarget,
				r.AssemblyLinearVelocity.Y,
				dir.Z * velTarget
			)
		end
	end)
end

local function stopVelocity()
	if not velEnabled then return end
	velEnabled = false

	if velHBConn then velHBConn:Disconnect() velHBConn = nil end
	setFriction(false)

	-- Restore actual WalkSpeed (base, not our override)
	local char = player.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if hum and velBaseSpeed then
		pcall(function() hum.WalkSpeed = velBaseSpeed end)
	end
	emit(string.format("[VEL] Stopped — WalkSpeed restored to %.4f", velBaseSpeed or -1))
end

-- ============================================================
-- BUTTONS
-- ============================================================

-- Row 1: START / STOP / COPY  (moved up by 42px to make room for vel row)
local function makeBtn(text, x, w, col, rowOffset)
	rowOffset = rowOffset or 0
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, w, 0, 34)
	b.Position = UDim2.new(0, x, 1, -86 + rowOffset)
	b.BackgroundColor3 = col
	b.Text = text
	b.TextColor3 = Color3.new(1,1,1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.Parent = main
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

local startBtn = makeBtn("START", 8,   136, Color3.fromRGB(30, 135, 60))
local stopBtn  = makeBtn("STOP",  152, 136, Color3.fromRGB(155, 60, 50))
local copyBtn  = makeBtn("COPY",  296, 148, Color3.fromRGB(55, 90, 160))

-- Row 2: VEL input + VEL ON/OFF button
local velInputBox = Instance.new("TextBox")
velInputBox.Size = UDim2.new(0, 120, 0, 34)
velInputBox.Position = UDim2.new(0, 8, 1, -44)
velInputBox.BackgroundColor3 = Color3.fromRGB(20, 24, 36)
velInputBox.Text = tostring(velTarget)
velInputBox.PlaceholderText = "e.g. 290"
velInputBox.TextColor3 = Color3.fromRGB(255, 255, 255)
velInputBox.Font = Enum.Font.GothamBold
velInputBox.TextSize = 13
velInputBox.ClearTextOnFocus = false
velInputBox.Parent = main
Instance.new("UICorner", velInputBox).CornerRadius = UDim.new(0, 6)
Instance.new("UIStroke", velInputBox).Color = Color3.fromRGB(60, 80, 120)

local velBtn = Instance.new("TextButton")
velBtn.Size = UDim2.new(0, 316, 0, 34)
velBtn.Position = UDim2.new(0, 136, 1, -44)
velBtn.BackgroundColor3 = Color3.fromRGB(60, 40, 90)
velBtn.Text = "⚡ VEL OFF  (base: detecting...)"
velBtn.TextColor3 = Color3.new(1,1,1)
velBtn.Font = Enum.Font.GothamBold
velBtn.TextSize = 12
velBtn.Parent = main
Instance.new("UICorner", velBtn).CornerRadius = UDim.new(0, 6)

-- Update velTarget live when input changes
velInputBox:GetPropertyChangedSignal("Text"):Connect(function()
	local v = tonumber(velInputBox.Text)
	if v and v > 0 then
		velTarget = v
		if velEnabled then
			velBtn.Text = string.format("⚡ VEL ON  %.0f  (base %.0f)", velTarget, velBaseSpeed or 0)
		end
	end
end)

velBtn.MouseButton1Click:Connect(function()
	-- Parse input box first
	local v = tonumber(velInputBox.Text)
	if v and v > 0 then velTarget = v end

	if velEnabled then
		stopVelocity()
		velBtn.Text = string.format("⚡ VEL OFF  (base: %.0f)", velBaseSpeed or 0)
		velBtn.BackgroundColor3 = Color3.fromRGB(60, 40, 90)
	else
		startVelocity()
		velBtn.Text = string.format("⚡ VEL ON  %.0f  (base %.0f)", velTarget, velBaseSpeed or 0)
		velBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 60)
	end
end)

-- --------------------------------------------------------

startBtn.MouseButton1Click:Connect(function()
	active    = true
	logLines  = {}
	conns     = {}
	lastSpeed = nil

	startBtn.Text = "STARTED"
	startBtn.BackgroundColor3 = Color3.fromRGB(20, 180, 70)
	setTitle("ACTIVE")

	-- Auto-detect base speed for velocity display
	local char = player.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		velBaseSpeed = hum.WalkSpeed
		velTarget    = velTarget > 0 and velTarget or velBaseSpeed
		velInputBox.Text = tostring(math.floor(velTarget))
		velBtn.Text = string.format("⚡ VEL OFF  (base: %.0f)", velBaseSpeed)
	end

	-- Baseline snapshot
	snapshotState("SNAPSHOT ON START")

	-- Attach all monitors
	attachSpeedWatcher()
	attachAttributeWatchers()
	attachChildWatchers()
	attachHumanoidWatchers()
	attachIncomingHook()

	-- Dump existing RE connections (runs once)
	task.defer(dumpExistingConnections)
end)

stopBtn.MouseButton1Click:Connect(function()
	active = false
	startBtn.Text = "START"
	startBtn.BackgroundColor3 = Color3.fromRGB(30, 135, 60)
	setTitle("STOPPED")

	-- Take a final snapshot for comparison
	snapshotState("SNAPSHOT ON STOP")

	-- Disconnect all monitors
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	conns = {}
end)

copyBtn.MouseButton1Click:Connect(function()
	local txt = table.concat(logLines, "\n")
	if setclipboard then
		pcall(setclipboard, txt)
		setTitle("COPIED")
	else
		setTitle("COPY UNAVAILABLE")
	end
end)

closeBtn.MouseButton1Click:Connect(function()
	active = false
	stopVelocity()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	if screenGui then screenGui:Destroy() end
end)

setTitle("READY")