--[[=========================================================================
	LIGHTDARK PATH FLIGHT  -  the lightdark route, walked slowly, with a UI

	Flies the SAME PATH the working lightdark escape flies, taken from its log
	and written in here waypoint for waypoint, at a pace slow enough that every
	write can be judged on its own:

	    35 studs every 0.5s      (70 studs/s, against the reference's ~2200)

	The 23 waypoints in PATH below are the positions the log's flight actually
	landed on, in order, with the reference's own time from its flight start:
	a 255-stud launch hop, the long straight at cruise altitude 112.7 with its
	460 and 421-stud mid-course hops, and the 163-stud hop to the pad. The last
	waypoint is the landing itself: the log falls the last 42.0 studs onto the
	forest pad at (612.2, 70.7, -325.0).

	    path 5097.9 studs -> 146 steps of 35 studs (last one 22.9) -> 73.0s

	Press FLY. Each write lands 35 studs further along the path, and 0.5s later
	the position is read back. That read is the whole test:

	    HELD      still where the write put it
	    REVERTED  the server put us back - it says from where, to where, how far
	    MOVED     something else moved us, so a physics step is not mistaken
	              for a server correction

	The next target is measured from where the character ACTUALLY is (projected
	onto the path), so a reverted step is retried rather than skipped and the
	flight cannot run away from itself. Five undone writes in a row stop it.

	Mechanism, unchanged from the lightdark log: ONE direct root.CFrame write
	per step, yaw preserved. No ChangeState(Freefall), no AutoRotate = false
	(that pair is the -1000 trigger), no velocity writes.
=========================================================================]]

-- ================================================================
-- CONFIG
-- ================================================================
local STEP_STUDS       = 35      -- studs written per step
local STEP_INTERVAL    = 0.5     -- seconds between writes
local SNAP_TO_START    = true    -- if we are not at the first waypoint, write ourselves there
local START_SNAP_STUDS = 60      -- further than this from it counts as "not there"
local NOCLIP           = true    -- parts non-collidable for the flight, restored after
local TOLERANCE        = 3.0     -- studs: within this of a position counts as "there"
local ABORT_AFTER_REVERTS = 5    -- consecutive undone writes before giving up
local PROGRESS_EVERY   = 20      -- steps between progress lines
local LOG_MAX          = 400     -- log lines kept on screen

-- ------------------------------------------------------------------
-- THE PATH, from the lightdark log. Each entry is a position the reference
-- flight landed on, with the time it got there, measured from its own start.
-- ------------------------------------------------------------------
local PATH = {
	{ t = 0.000, pos = Vector3.new(5666.0,  70.7, -327.4) },   -- start
	{ t = 0.796, pos = Vector3.new(5411.6,  96.1, -331.5) },   -- launch hop
	{ t = 0.853, pos = Vector3.new(5245.1, 112.7, -331.3) },   -- cruise start, +42.0
	{ t = 0.921, pos = Vector3.new(4961.0, 112.6, -330.9) },
	{ t = 0.966, pos = Vector3.new(4823.9, 112.7, -330.7) },
	{ t = 1.011, pos = Vector3.new(4632.9, 112.6, -330.5) },
	{ t = 1.057, pos = Vector3.new(4441.8, 112.7, -330.2) },
	{ t = 1.259, pos = Vector3.new(3981.5, 112.7, -329.6) },
	{ t = 1.302, pos = Vector3.new(3789.1, 112.5, -329.3) },
	{ t = 1.345, pos = Vector3.new(3610.1, 112.7, -329.1) },
	{ t = 1.437, pos = Vector3.new(3366.0, 112.6, -328.7) },
	{ t = 1.509, pos = Vector3.new(3139.2, 112.7, -328.4) },
	{ t = 1.561, pos = Vector3.new(2927.0, 112.6, -328.1) },
	{ t = 1.604, pos = Vector3.new(2742.2, 112.7, -327.9) },
	{ t = 1.699, pos = Vector3.new(2513.4, 112.6, -327.6) },
	{ t = 1.743, pos = Vector3.new(2317.9, 112.7, -327.3) },
	{ t = 1.844, pos = Vector3.new(2066.0, 112.6, -327.0) },
	{ t = 1.902, pos = Vector3.new(1875.7, 112.7, -326.7) },
	{ t = 1.960, pos = Vector3.new(1633.1, 112.6, -326.4) },
	{ t = 2.006, pos = Vector3.new(1454.5, 112.7, -326.1) },
	{ t = 2.146, pos = Vector3.new(1033.4, 112.7, -325.6) },
	{ t = 2.207, pos = Vector3.new( 775.7, 112.5, -325.2) },
	{ t = 2.261, pos = Vector3.new( 612.2, 112.7, -325.0) },   -- last hop to the pad
	{ t = 2.360, pos = Vector3.new( 612.2,  70.7, -325.0) },   -- the landing, -42.0
}

-- ================================================================
-- THE PATH AS A POLYLINE
-- ================================================================
local segments, TOTAL = {}, 0
for i = 1, #PATH - 1 do
	local a, b = PATH[i].pos, PATH[i + 1].pos
	local len = (b - a).Magnitude
	segments[i] = { a = a, b = b, len = len, start = TOTAL, t = PATH[i + 1].t }
	TOTAL += len
end
local STEPS = math.ceil(TOTAL / STEP_STUDS)

local function projectToPath(p)
	local bestS, bestD = 0, math.huge
	for _, seg in ipairs(segments) do
		local ab = seg.b - seg.a
		local t = 0
		if seg.len > 1e-6 then
			t = ((p - seg.a):Dot(ab)) / (seg.len * seg.len)
			t = math.max(0, math.min(1, t))     -- math.clamp is Roblox-only
		end
		local c = seg.a + ab * t
		local d = (p - c).Magnitude
		if d < bestD then bestD, bestS = d, seg.start + t * seg.len end
	end
	return bestS, bestD
end

local function samplePath(s)
	s = math.max(0, math.min(TOTAL, s))
	for _, seg in ipairs(segments) do
		if s <= seg.start + seg.len or seg == segments[#segments] then
			local t = seg.len > 1e-6 and (s - seg.start) / seg.len or 0
			return seg.a + (seg.b - seg.a) * t
		end
	end
	return PATH[#PATH].pos
end

-- the reference's own clock at a given distance along the path, so our log can
-- say how far behind the working flight we are at the same point of the route
local function refTimeAt(s)
	for _, seg in ipairs(segments) do
		if s <= seg.start + seg.len then return seg.t end
	end
	return PATH[#PATH].t
end

-- ================================================================
-- LOGGING - printed, and shown on screen
-- ================================================================
local startClock = os.clock()
local LOG = {}
-- Forward-declared: log() below reads this, and a local declared AFTER the
-- function that reads it silently becomes a GLOBAL (nil) instead - the trap that
-- has bitten debug.lua six times. The UI log list would have stayed empty while
-- the console filled up.
local pushLogLine

local function stamp()
	local t = os.clock() - startClock
	local m = math.floor(t / 60)
	local s = t - m * 60
	return string.format("[%02d:%06.3f]", m, s)
end

local function log(line, ...)
	if select("#", ...) > 0 then line = string.format(line, ...) end
	LOG[#LOG + 1] = line
	print(line)
	if pushLogLine then pushLogLine(line) end
end

local function fmtPos(p) return string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z) end
local function fmtVec(v) return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z) end
local function dash(v) if type(v) ~= "number" then return "-" end return string.format("%.1f", v) end

local function xzDist(a, b)
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- ================================================================
-- RIG  (player is declared up here: a function defined below reads it)
-- ================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- nil from GetNetworkOwner() means the SERVER owns the part, and a client CFrame
-- write on a server-owned assembly is only a request - worth a readout per step.
local function ownerName(part)
	if not part then return "?" end
	local owner
	local ok = pcall(function() owner = part:GetNetworkOwner() end)
	if not ok then return "<no-ownership-api>" end
	if owner == nil then return "server" end
	return owner == player and "you" or tostring(owner)
end

-- ================================================================
-- UI
-- ================================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LightDarkPathFlight"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 330, 0, 470)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
frame.BackgroundTransparency = 0.12
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(0, 200, 255)
stroke.Thickness = 2
stroke.Transparency = 0.3
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 24)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Text = "LIGHTDARK PATH FLIGHT"
title.TextColor3 = Color3.fromRGB(0, 200, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -32, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 15
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local function mkLabel(y, text, color, size)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -24, 0, 14)
	l.Position = UDim2.new(0, 12, 0, y)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = color or Color3.fromRGB(160, 165, 175)
	l.Font = Enum.Font.Code
	l.TextSize = size or 11
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = frame
	return l
end

local statusLabel   = mkLabel(34, "STATUS    | idle - press FLY", Color3.fromRGB(120, 220, 255), 11)
local progressLabel = mkLabel(50, string.format("PROGRESS  | step 0 of %d | 0.0 of %.1f studs (0%%)", STEPS, TOTAL))
local posLabel      = mkLabel(66, "POSITION  | -")
local verdictLabel  = mkLabel(82, "WRITES    | 0 held | 0 reverted | 0 elsewhere", Color3.fromRGB(235, 235, 180))
local routeLabel    = mkLabel(98, string.format("ROUTE     | %d waypoints from lightdark.log | %.1f studs | %.1fs", #PATH, TOTAL, STEPS * STEP_INTERVAL),
	Color3.fromRGB(150, 155, 165), 10)

local flyBtn = Instance.new("TextButton")
flyBtn.Size = UDim2.new(1, -24, 0, 30)
flyBtn.Position = UDim2.new(0, 12, 0, 118)
flyBtn.BackgroundColor3 = Color3.fromRGB(95, 55, 170)
flyBtn.Text = "FLY THE PATH (35 studs / 0.5s)"
flyBtn.TextColor3 = Color3.fromRGB(235, 245, 255)
flyBtn.Font = Enum.Font.GothamBold
flyBtn.TextSize = 12
flyBtn.Parent = frame
Instance.new("UICorner", flyBtn).CornerRadius = UDim.new(0, 8)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0, 86, 0, 24)
stopBtn.Position = UDim2.new(0, 12, 0, 152)
stopBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
stopBtn.Text = "STOP"
stopBtn.TextColor3 = Color3.fromRGB(255, 190, 190)
stopBtn.Font = Enum.Font.GothamBold
stopBtn.TextSize = 11
stopBtn.Parent = frame
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 6)

-- CLEAR matters: the log accumulates, so a pasted log can carry stale lines.
local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 62, 0, 24)
clearBtn.Position = UDim2.new(0, 104, 0, 152)
clearBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
clearBtn.Text = "CLEAR"
clearBtn.TextColor3 = Color3.fromRGB(230, 220, 190)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 11
clearBtn.Parent = frame
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0, 78, 0, 24)
copyBtn.Position = UDim2.new(1, -90, 0, 152)
copyBtn.BackgroundColor3 = Color3.fromRGB(50, 70, 110)
copyBtn.Text = "COPY LOG"
copyBtn.TextColor3 = Color3.fromRGB(210, 225, 255)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 11
copyBtn.Parent = frame
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

local logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -24, 0, 262)
logScroll.Position = UDim2.new(0, 12, 0, 184)
logScroll.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
logScroll.BackgroundTransparency = 0.25
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 4
logScroll.ScrollBarImageColor3 = Color3.fromRGB(0, 180, 220)
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.Parent = frame
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 8)

local logList = Instance.new("UIListLayout")
logList.SortOrder = Enum.SortOrder.LayoutOrder
logList.Padding = UDim.new(0, 1)
logList.Parent = logScroll

local logLines = {}
pushLogLine = function(text)
	local l = Instance.new("TextLabel")
	local n = #logLines + 1
	l.Size = UDim2.new(1, -8, 0, 12)
	l.Position = UDim2.new(0, 4, 0, 0)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.fromRGB(190, 220, 235)
	l.Font = Enum.Font.Code
	l.TextSize = 9
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.LayoutOrder = n
	l.Parent = logScroll
	logLines[n] = l
	logScroll.CanvasSize = UDim2.new(0, 0, 0, n * 13)
	logScroll.CanvasPosition = Vector2.new(0, math.max(0, n * 13 - 262))
	while #logLines > LOG_MAX do
		local old = table.remove(logLines, 1)
		if old and old.Parent then old:Destroy() end
	end
end

local function clearLog()
	for _, l in ipairs(logLines) do if l and l.Parent then l:Destroy() end end
	logLines = {}
	LOG = {}
	logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
end

-- ================================================================
-- NOCLIP - explicit, tracked, restored. It never leaks.
-- ================================================================
local noclipSaved = {}

local function applyNoclip(character)
	if not NOCLIP then return 0 end
	local n = 0
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			-- save ONCE per part: calling this twice used to save the false that
			-- the first call had just written, and the "restore" then left the
			-- part non-collidable for good
			if noclipSaved[part] == nil then noclipSaved[part] = part.CanCollide end
			part.CanCollide = false
			n += 1
		end
	end
	return n
end

local function restoreNoclip()
	local n = 0
	for part, was in pairs(noclipSaved) do
		if part and part.Parent then
			part.CanCollide = was
			n += 1
		end
	end
	noclipSaved = {}
	return n
end

-- ================================================================
-- FLIGHT
-- ================================================================
local flight = {
	running = false, step = 0, s = 0, startPos = nil,
	pending = nil, held = 0, reverted = 0, elsewhere = 0,
	revertStreak = 0, arrived = false, hp = nil, state = nil,
	stopReason = nil, conn = nil, nextAt = 0, character = nil, humanoid = nil, root = nil,
}
local summaryDone = false

local function setStatus(text, color)
	if statusLabel then
		statusLabel.Text = "STATUS    | " .. text
		statusLabel.TextColor3 = color or Color3.fromRGB(120, 220, 255)
	end
end

local function setCounters()
	verdictLabel.Text = string.format("WRITES    | %d held | %d reverted | %d elsewhere",
		flight.held, flight.reverted, flight.elsewhere)
end

local function worldLine()
	local humanoid, root = flight.humanoid, flight.root
	local floor = humanoid.FloorMaterial
	local floorName = floor and tostring(floor) or "?"
	local grounded = floorName ~= "Enum.Material.Air" and floorName ~= "Air"
	return string.format(
		"state=%s | grounded=%s | floor=%s | vel=%s | hp=%s | owner=%s",
		tostring(humanoid:GetState()), tostring(grounded), floorName,
		fmtVec(root.AssemblyLinearVelocity), dash(humanoid.Health), ownerName(root))
end

local function checkPending(now)
	local p = flight.pending
	if not p then return end
	flight.pending = nil

	local here = flight.root.Position
	local fromWrite = xzDist(here, p.wroteTo)
	local fromBefore = xzDist(here, p.before)
	local verdict
	if fromWrite <= TOLERANCE then
		verdict = "HELD"
		flight.held += 1
		flight.revertStreak = 0
	elseif fromBefore <= TOLERANCE then
		verdict = "REVERTED - the server put us back"
		flight.reverted += 1
		flight.revertStreak += 1
	else
		verdict = "MOVED ELSEWHERE - neither where we wrote nor where we were"
		flight.elsewhere += 1
		flight.revertStreak += 1
	end

	log("%s check %03d | %.3fs after the write | now %s | %.1f studs from where it was written, %.1f from where it started | %s",
		stamp(), p.step, now - p.at, fmtPos(here), fromWrite, fromBefore, verdict)
	if verdict ~= "HELD" then
		log("%s           | wrote %s then %s | path s=%.1f/%.1f | ref reached this at t+%.2fs",
			stamp(), fmtPos(p.wroteTo), fmtPos(p.before), p.s, TOTAL, refTimeAt(p.s))
	end

	setCounters()
	if flight.revertStreak >= ABORT_AFTER_REVERTS then
		flight.stopReason = string.format(
			"%d writes in a row were undone - the server is not keeping them", ABORT_AFTER_REVERTS)
	end
end

local function doStep(now)
	checkPending(now)
	if flight.stopReason or flight.arrived or not flight.running then return end

	local before = flight.root.Position
	local here, offPath = projectToPath(before)
	if flight.step == 0 then flight.startPos = before end
	if flight.step > 0 and here < flight.s - 1 then
		log("%s LAGGING   | s=%.1f but the character is at s=%.1f | the last write did not hold - retrying from where it is",
			stamp(), flight.s, here)
	end
	local fromS = here
	flight.s = here
	if offPath > 60 then
		log("%s DRIFT      | %.1f studs off the path - the next write pulls back onto it", stamp(), offPath)
	end

	local targetS = math.min(flight.s + STEP_STUDS, TOTAL)
	local target = samplePath(targetS)

	-- THE WRITE. One direct root.CFrame assignment - the mechanism the working
	-- lightdark log shows. Yaw carried over: a bare CFrame.new() resets the
	-- facing, which yanks the character round and is not what the reference does.
	local yaw = flight.root.Orientation.Y
	flight.root.CFrame = CFrame.new(target) * CFrame.Angles(0, math.rad(yaw), 0)

	local landed = flight.root.Position
	local off = (landed - target).Magnitude
	flight.step += 1
	flight.s = targetS
	flight.pending = { step = flight.step, before = before, wroteTo = target, at = now, s = targetS }

	log("%s step %03d | s=%.1f -> %.1f of %.1f (%d%%) | asked %s | landed %s | off by %.2f | ref t+%.2fs",
		stamp(), flight.step, fromS, targetS, TOTAL, math.floor((targetS / TOTAL) * 100),
		fmtPos(target), fmtPos(landed), off, refTimeAt(targetS))
	log("%s          | %s", stamp(), worldLine())

	progressLabel.Text = string.format("PROGRESS  | step %d of %d | %.1f of %.1f studs (%d%%)",
		flight.step, STEPS, targetS, TOTAL, math.floor((targetS / TOTAL) * 100))
	posLabel.Text = "POSITION  | " .. fmtPos(landed)

	if targetS >= TOTAL - 0.001 then flight.arrived = true end
end

local function finish(reason)
	if summaryDone then return end
	summaryDone = true
	flight.running = false
	flight.stopReason = flight.stopReason or reason

	if flight.conn then
		flight.conn:Disconnect()
		flight.conn = nil
	end

	if flight.pending then
		local p = flight.pending
		flight.pending = nil
		local here = flight.root.Position
		local fromWrite = xzDist(here, p.wroteTo)
		local fromBefore = xzDist(here, p.before)
		local verdict
		if fromWrite <= TOLERANCE then verdict = "HELD"; flight.held += 1
		elseif fromBefore <= TOLERANCE then verdict = "REVERTED - the server put us back"; flight.reverted += 1
		else verdict = "MOVED ELSEWHERE"; flight.elsewhere += 1 end
		log("%s check %03d | FINAL | now %s | %.1f from the write, %.1f from where it started | %s",
			stamp(), p.step, fmtPos(here), fromWrite, fromBefore, verdict)
	end

	local here = flight.root.Position
	local pad = PATH[#PATH].pos
	local padDist = (here - pad).Magnitude
	local xzNet = flight.startPos and xzDist(here, flight.startPos) or 0
	local restored = restoreNoclip()

	log("============ PATH FLIGHT SUMMARY ============")
	log("route     | lightdark.log, %d waypoints | %.1f studs of path", #PATH, TOTAL)
	log("asked     | %d steps x %.1f studs = %.1f studs of path over %.1fs",
		flight.step, STEP_STUDS, math.min(flight.step * STEP_STUDS, TOTAL), flight.step * STEP_INTERVAL)
	log("walked    | %.1f of %.1f studs of path (%.0f%%)",
		math.min(flight.s, TOTAL), TOTAL, (math.min(flight.s, TOTAL) / TOTAL) * 100)
	log("position  | start %s -> end %s",
		flight.startPos and fmtPos(flight.startPos) or "?", fmtPos(here))
	log("net       | %.1f studs across the ground (%.1f to the pad in a straight line, %.1f left)",
		xzNet, (flight.startPos and xzDist(flight.startPos, pad)) or 0, padDist)
	if flight.arrived then
		log("LANDED    | at the forest pad %s | %.1f studs from it | floor=%s | hp=%s",
			fmtPos(pad), padDist, tostring(flight.humanoid.FloorMaterial), dash(flight.humanoid.Health))
	else
		log("not landed| %.1f studs short of the pad | s=%.1f/%.1f",
			padDist, math.min(flight.s, TOTAL), TOTAL)
	end
	log("steps     | %d HELD | %d REVERTED | %d moved elsewhere",
		flight.held, flight.reverted, flight.elsewhere)
	log("health    | hp=%s | state=%s | floor=%s",
		dash(flight.humanoid.Health), tostring(flight.humanoid:GetState()),
		tostring(flight.humanoid.FloorMaterial))
	if NOCLIP then log("noclip    | restored CanCollide on %d part(s) - nothing leaked", restored) end

	local verdict
	if flight.reverted > 0 and flight.held == 0 then
		verdict = "THE SERVER IS UNDOING THEM - not one write survived"
	elseif flight.reverted > 0 then
		verdict = string.format("PARTIAL - %d of %d writes survived, %d were undone",
			flight.held, flight.held + flight.reverted, flight.reverted)
	elseif flight.step > 0 and flight.held == flight.step then
		verdict = "THE WRITES STICK - the server kept every step"
	else
		verdict = "INCONCLUSIVE - reads did not match either position"
	end
	log("verdict   | %s", verdict)
	log("stopped   | %s", flight.stopReason)
	log("=============================================")

	setCounters()
	setStatus(verdict:sub(1, 42), flight.reverted > 0 and Color3.fromRGB(255, 150, 120)
		or Color3.fromRGB(120, 255, 160))
	_G.LIGHTDARK_FLIGHT_RUNNING = false
end

-- ================================================================
-- START / STOP
-- ================================================================
local function startFlight()
	if flight.running then
		log("%s already flying - press STOP first", stamp())
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and humanoid and root) then
		log("%s no character - respawn and press FLY again", stamp())
		setStatus("no character", Color3.fromRGB(255, 150, 120))
		return
	end

	flight = {
		running = true, step = 0, s = 0, startPos = nil, pending = nil,
		held = 0, reverted = 0, elsewhere = 0, revertStreak = 0, arrived = false,
		hp = humanoid.Health, state = tostring(humanoid:GetState()),
		stopReason = nil, conn = nil, nextAt = 0,
		character = character, humanoid = humanoid, root = root,
	}
	summaryDone = false
	_G.LIGHTDARK_FLIGHT_RUNNING = true
	_G.LIGHTDARK_FLIGHT_STOP = false

	log("============ LIGHTDARK PATH FLIGHT ============")
	log("%s route     | %d waypoints taken from lightdark.log | %.1f studs of path",
		stamp(), #PATH, TOTAL)
	log("%s config    | %.1f studs every %.2fs x %d steps = %.1fs",
		stamp(), STEP_STUDS, STEP_INTERVAL, STEPS, STEPS * STEP_INTERVAL)
	log("%s start     | %s | hp=%s | state=%s",
		stamp(), fmtPos(root.Position), dash(humanoid.Health), tostring(humanoid:GetState()))
	log("%s not called| ChangeState(Freefall) and AutoRotate stay untouched - the -1000 pair",
		stamp())

	local here0, off0 = projectToPath(root.Position)
	log("%s position  | s=%.1f of %.1f along the path | %.1f studs off it", stamp(), here0, TOTAL, off0)

	if SNAP_TO_START then
		local first = PATH[1].pos
		local d = (root.Position - first).Magnitude
		if d > START_SNAP_STUDS then
			log("%s snap      | %.1f studs from the first waypoint - one write to it", stamp(), d)
			local yaw = root.Orientation.Y
			root.CFrame = CFrame.new(first) * CFrame.Angles(0, math.rad(yaw), 0)
			local after = (root.Position - first).Magnitude
			log("%s snap      | wrote %s | now %s | %.2f studs off | %s",
				stamp(), fmtPos(first), fmtPos(root.Position), after, worldLine())
			if after > TOLERANCE then
				log("%s snap      | DID NOT HOLD - flying from wherever the character is instead", stamp())
			end
		else
			log("%s snap      | already at the first waypoint (%.1f studs) - flying from here", stamp(), d)
		end
	end

	local nc = applyNoclip(character)
	if NOCLIP then log("%s noclip    | %d part(s) set non-collidable for the flight", stamp(), nc) end

	setStatus("flying | 35 studs every 0.5s", Color3.fromRGB(255, 220, 120))
	setCounters()

	flight.nextAt = os.clock() + STEP_INTERVAL
	log("%s FLYING     | the first write is now", stamp())
	doStep(os.clock())

	flight.conn = RunService.Heartbeat:Connect(function()
		if _G.LIGHTDARK_FLIGHT_STOP then
			finish("stopped")
			return
		end
		if flight.humanoid.Health <= 0 then
			log("%s DEATH      | hp=%s at step %d | %s",
				stamp(), dash(flight.humanoid.Health), flight.step,
				flight.humanoid.Health < 0 and "EXTERNAL KILL: hp was SET, this is not damage"
					or "normal death")
			finish("the character died at step " .. flight.step)
			return
		end

		local now = os.clock()
		local state = tostring(flight.humanoid:GetState())
		if state ~= flight.state then
			log("%s STATE      | %s -> %s | %s", stamp(), flight.state or "?", state, worldLine())
			flight.state = state
		end
		if flight.humanoid.Health ~= flight.hp then
			log("%s HEALTH     | %s -> %s", stamp(), dash(flight.hp), dash(flight.humanoid.Health))
			flight.hp = flight.humanoid.Health
		end

		-- 1e-6: 30 frames of 1/60 sum to 0.49999999999999994, which is not >= 0.5,
		-- so an exact scheduler would run one frame late every step.
		if not flight.arrived and now >= flight.nextAt - 1e-6 then
			flight.nextAt += STEP_INTERVAL
			if flight.nextAt < now then flight.nextAt = now + STEP_INTERVAL end
			doStep(now)
			if flight.step > 0 and flight.step % PROGRESS_EVERY == 0 and not flight.arrived then
				log("%s PROGRESS   | step %d of %d | %.1f of %.1f studs | %d%% | ref reached this at t+%.2fs",
					stamp(), flight.step, STEPS, math.min(flight.s, TOTAL), TOTAL,
					math.floor((math.min(flight.s, TOTAL) / TOTAL) * 100), refTimeAt(flight.s))
			end
		end

		if flight.arrived and now >= flight.nextAt - 1e-6 then
			finish("landed at the forest pad")
		elseif flight.stopReason then
			finish(flight.stopReason)
		end
	end)
end

flyBtn.MouseButton1Click:Connect(startFlight)

stopBtn.MouseButton1Click:Connect(function()
	if flight.running then
		_G.LIGHTDARK_FLIGHT_STOP = true
	else
		setStatus("idle - nothing to stop")
	end
end)

clearBtn.MouseButton1Click:Connect(function()
	clearLog()
	setStatus("log cleared")
end)

copyBtn.MouseButton1Click:Connect(function()
	local ok = pcall(function() setclipboard(table.concat(LOG, "\n")) end)
	setStatus(ok and "log copied" or "copy failed",
		ok and Color3.fromRGB(120, 255, 160) or Color3.fromRGB(255, 150, 120))
end)

closeBtn.MouseButton1Click:Connect(function()
	if flight.running then _G.LIGHTDARK_FLIGHT_STOP = true end
	screenGui:Destroy()
end)

-- ---- draggable -----------------------------------------------------------
local dragging, dragStart, startPos = false, nil, nil
frame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
	end
end)
frame.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if dragging and dragStart and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
			startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)

setCounters()
log("%s READY     | %d waypoints | %.1f studs | %d steps at %.1f studs every %.2fs",
	stamp(), #PATH, TOTAL, STEPS, STEP_STUDS, STEP_INTERVAL)
log("%s READY     | press FLY. Nothing is written until you do.", stamp())
