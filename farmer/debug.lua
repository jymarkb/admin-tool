local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ================================================================
-- CONFIG
-- ================================================================
local MAX_LOG_ENTRIES = 2000
local TRANSFORM_CAPTURE_DEFAULT = true
local TRANSFORM_JUMP_MIN_DISTANCE = 8.0
local TRANSFORM_JUMP_MIN_PSPEED = 750.0
local TRANSFORM_JUMP_RATIO = 3.0
local TRANSFORM_PROPERTY_DEDUPE_TIME = 0.006
local TRANSFORM_PROPERTY_DEDUPE_DISTANCE = 2.0
-- A sample this old is not a frame delta. The first sample after a respawn, a
-- script reload or a character swap compares against a position from minutes
-- ago, which prints a 5000-stud "move" that never happened (dt=24.04665 and
-- dt=49.49405 in the field logs). Those are reported as a gap, never as a step.
local STALE_SAMPLE_S = 1.0

-- ================================================================
-- FORENSICS (V8) - the things this scanner could not see
-- ================================================================
-- Added after a long debugging session where several failures were invisible in
-- the log. Each one below is a specific blind spot that cost us a round trip:
--   * Health set to -1000 (the exploit handler) looked identical to fall damage,
--     because only the value 0 was ever treated as "dead".
--   * A flight could write 1978 studs of CFrame and be REVERTED by the server,
--     while the scanner reported it as a large move and the scripts believed they
--     had travelled. Nothing compared a big jump against what happened next.
--   * Humanoid.Died was never subscribed - death was only inferred from hp=0.
--   * Nothing watched Touched, so a kill brick was invisible.
--   * Nothing measured the rig itself, so joints tearing (Motor6D stretch) could
--     not be distinguished from the character simply moving.
local FORENSICS_DEFAULT     = true
local EXPLOIT_HP            = -1     -- Health below this = SET, not damaged away
local BIG_JUMP_STUDS        = 50     -- a displacement this large starts a reversion watch
local REVERT_MIN_STUDS      = 40     -- coming back this far = the write did not stick
local REVERT_WINDOW_S       = 2.0    -- how long after a big jump to keep watching
local NET_WINDOW_S          = 1.0    -- window for the periodic NET displacement line
local NET_MIN_SPEED         = 100    -- only report NET while moving this fast
local RIG_STRETCH_STUDS     = 2.5    -- limb offset beyond baseline = joints stretching
local NEAR_RADIUS           = 30     -- what was around us
local TOUCH_DEDUPE_S        = 0.5    -- do not repeat the same Touched part
local VOID_WARN_STUDS       = 50     -- warn this close to FallenPartsDestroyHeight
local OBSTACLE_AHEAD_STUDS  = 30     -- raycast this far ahead while moving fast

-- Flight write ledger (V9). The scanner could see that the character MOVED; it
-- could not see what it was asked to do, or whether the server kept it.
-- Fly with humanoid:ChangeState(Freefall) and humanoid.AutoRotate = false?
--
-- OFF by default, because the field log of 04:26 is unambiguous: with those two
-- calls the server reverted EVERY write of the flight (15 rejected episodes in
-- 1.2s) and then killed the character with hp=-1000. The reference flight that
-- works never touches either one - it stays in Running for the whole climb and
-- only becomes Freefall on its own at cruise altitude.
--
-- Freefall.lua already carries the same conclusion as TOUCH_HUMANOID_STATE=false
-- and TOUCH_AUTOROTATE=false. This toggle makes it testable in one session:
-- fly twice, press STATECALLS between them, compare the two traces.
-- Does the flight move the whole MODEL or just the root?
--
-- character:PivotTo(cf) is one call that repositions every part in the rig - a
-- claim over 20 parts at once. root.CFrame = cf is one part, and the joints pull
-- the rest along. The reference flight is never reverted, so this is the other
-- variable worth isolating. OFF = root.CFrame only.
local PIVOT_WRITE_DEFAULT   = true
-- Which profile the REPLAY button flies: the ld-p3 reconstruction, or the
-- flight measured off the working script at 05:01:42.
local PROFILE_MEASURED_DEFAULT = true
local STATE_CALLS_DEFAULT   = false
local FLIGHT_TRACE_DEFAULT  = true    -- record every write the replay makes
local WRITE_CONFIRM_STUDS   = 2.0     -- within this of the target = the write held
local LOST_WRITE_WARN_S     = 0.15    -- rate limit for "the server pushed us back"
local FLIGHT_FRAME_S        = 0.045   -- per-frame trace rate (~22/s at 60 fps)
local FLIGHT_FRAME_MAX      = 60      -- ...capped at this many lines per flight
local PHYSICS_SAMPLE_S      = 1.0     -- physics sample interval during a flight
local OWNERSHIP_POLL_S      = 0.5     -- how often to look for an ownership change

-- Burst ledger (V10). A real flight arrives as ONE burst of writes no matter
-- which script produced it - the escape scripts, not just this file's REPLAY
-- button. This collapses the burst into a single block that can be replicated
-- from, and measures the thing no log has shown yet: a step that comes in
-- SHORT of the burst's cruise speed. A full reversion is a huge jump backwards;
-- a partial one looks exactly like a slow frame, and a script that targets an
-- absolute position just catches up on the next write and hides it.
local BURST_DEFAULT         = true
local BURST_MIN_STEP        = 20      -- a move this big is a teleport-style step
local BURST_GAP_S           = 0.4     -- no steps for this long = the burst ended
-- Landing within this of the last step = another channel reporting the SAME
-- write, not a new step. Compare HORIZONTALLY, with a Y allowance: the four
-- stage channels sample at different instants of one frame, and in Freefall the
-- character has fallen a few studs between them (Y, Y-3, Y-5 for one write). A 3D
-- distance test reads every one of those as a new step with dx = 0 - reproduced
-- in the harness: a 6-write burst came back as 12 steps, half of them
-- zero-horizontal phantoms, which is how the working flight's 24-25 writes were
-- reported as "36 distinct steps" and "19 step(s) under 60% of it".
local BURST_ECHO_STUDS      = 2.0     -- XZ distance for "same spot"
local BURST_ECHO_Y_STUDS    = 5.0     -- ...and how far Y may drift while still being the same spot
-- 5 studs: in Freefall at cruise the character falls ~3 studs per frame, and the
-- four stage channels sample at different points of the same frame, so one write
-- is echoed at Y, Y-3, Y-5... Collapsing those is the whole point of the echo
-- test. The launch (dy 13.9 -> 42.0) and the final drop (dy 42) are far outside
-- this band, so no real vertical step is swallowed.
local BURST_MAX_STEPS       = 150     -- bound the stored profile
-- The working flight of 05:01:42, measured. Every burst is scored against it so
-- a failed replication does not need a second log to compare by hand.
local REFERENCE_STATS = {
	name = "measured 05:01:42", steps = 25, studs = 5054.1, seconds = 1.58,
	median = 234.4, maxStep = 361.8, minStep = 59.4, reverted = 0,
	climb = 42.0, drop = -42.0, landX = 612.2,
}
local BURST_SHORT_FRACTION  = 0.6     -- below this fraction of cruise = a short step
local VEL_JUMP_STUDS        = 30      -- velocity change with no write = worth logging

local RENDER_STEP_NAME = "ReferenceFreefallReplayV7"
local RENDER_STEP_PRIORITY = Enum.RenderPriority.Character.Value + 1
local REPLAY_CORRECTION_TOLERANCE = 25.0
local REPLAY_MIN_FREEFALL_Y = 100.0

-- ================================================================
-- MEASURED PROFILE - the working flight of 05:01:42, step for step
-- ================================================================
-- Read off the log of the escape script that WORKS (37 distinct positions,
-- 25 horizontal steps, 5054.1 studs, 1.58s, +42.0 climb, -42.0 drop). Its own
-- BURST END block confirms the totals. This is the replication target: fly
-- exactly this, at this cadence, and see whether the server keeps it.
--
-- Note what the reference does NOT do: it never calls ChangeState(Freefall) and
-- never touches AutoRotate. It stays in Running for the whole climb and the
-- humanoid enters Freefall on its own at the cruise transition.
local MEASURED_LAUNCH = {
	{t = 0.000, dx = -139.8, dy = 13.9},
	{t = 0.052, dx = -353.9, dy = 35.3},   -- cumulative from the start
	{t = 0.109, dx = -421.2, dy = 42.0},   -- = cruise altitude, +42.0
}
local MEASURED_X_DELTAS = {
	-234.4, -186.8, -290.2, -131.0, -264.6, -156.5, -240.6, -180.6,
	-275.0, -146.2, -258.6, -162.5, -238.5, -182.7, -205.7, -215.5,
	-236.1, -185.1, -287.3, -133.8, -361.8, -59.4,
}
local MEASURED_CHUNK_TIMES = {
	0.055, 0.069, 0.067, 0.051, 0.058, 0.052, 0.057, 0.049, 0.056, 0.061,
	0.061, 0.063, 0.058, 0.056, 0.059, 0.061, 0.056, 0.061, 0.068, 0.057,
	0.065, 0.073,
}
local MEASURED_DROP_Y = -42.0

-- ================================================================
-- EXACT PROFILE EXTRACTED FROM ld-p3.log
-- ================================================================
-- Launch (relative to start position). Two big PreRender jumps.
local LAUNCH_PROFILE = {
	{t = 0.000, dx = -254.7, dy = 25.4, dz = 0.3},
	{t = 0.057, dx = -421.2, dy = 42.0, dz = 0.5}, -- cumulative
}

-- Freefall X chunks (relative to freefall origin = launch end).
-- Y is forced fixed; only X/Z from these deltas are applied.
local FREEFALL_X_DELTAS = {
	-284.1, -137.1, -191.0, -191.1, -39.0, -421.2,
	-192.4, -179.0, -49.8, -194.4, -226.8, -212.2,
	-184.9, -24.1, -204.6, -195.5, -21.1, -230.9,
	-190.3, -242.6, -178.6, -421.2, -257.6, -163.5,
}

-- Approximate inter-chunk times observed in the log (seconds between PreRender jumps)
local FREEFALL_CHUNK_TIMES = {
	0.000, 0.045, 0.045, 0.046, 0.073, 0.129,
	0.043, 0.043, 0.046, 0.046, 0.072, 0.052,
	0.043, 0.044, 0.051, 0.044, 0.046, 0.055,
	0.058, 0.058, 0.046, 0.140, 0.061, 0.054,
}

local DROP_OFFSET_Y = -41.9

-- ================================================================
-- GUI
-- ================================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SpeedScanner"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "SpeedFrame"
frame.Size = UDim2.new(0, 360, 0, 590)
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
title.Size = UDim2.new(1, -40, 0, 26)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Text = "REFERENCE REPLAY V13"
title.TextColor3 = Color3.fromRGB(0, 200, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
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

local phaseLabel = Instance.new("TextLabel")
phaseLabel.Size = UDim2.new(1, -20, 0, 16)
phaseLabel.Position = UDim2.new(0, 10, 0, 78)
phaseLabel.BackgroundTransparency = 1
phaseLabel.Text = "Phase: IDLE | HP: —"
phaseLabel.TextColor3 = Color3.fromRGB(100, 220, 255)
phaseLabel.Font = Enum.Font.Code
phaseLabel.TextSize = 11
phaseLabel.TextXAlignment = Enum.TextXAlignment.Left
phaseLabel.Parent = frame

local posLabel = Instance.new("TextLabel")
posLabel.Size = UDim2.new(1, -20, 0, 16)
posLabel.Position = UDim2.new(0, 10, 0, 94)
posLabel.BackgroundTransparency = 1
posLabel.Text = "Pos: 0, 0, 0"
posLabel.TextColor3 = Color3.fromRGB(140, 140, 160)
posLabel.Font = Enum.Font.Code
posLabel.TextSize = 11
posLabel.TextXAlignment = Enum.TextXAlignment.Left
posLabel.Parent = frame

local logTitle = Instance.new("TextLabel")
logTitle.Size = UDim2.new(1, -20, 0, 18)
logTitle.Position = UDim2.new(0, 10, 0, 112)
logTitle.BackgroundTransparency = 1
logTitle.Text = "DETAILED EVENT + FRAME TRACE"
logTitle.TextColor3 = Color3.fromRGB(0, 180, 220)
logTitle.Font = Enum.Font.GothamBold
logTitle.TextSize = 12
logTitle.TextXAlignment = Enum.TextXAlignment.Left
logTitle.Parent = frame

local logScroll = Instance.new("ScrollingFrame")
logScroll.Name = "LogScroll"
logScroll.Size = UDim2.new(1, -20, 0, 274)
logScroll.Position = UDim2.new(0, 10, 0, 132)
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
buttonFrame.Size = UDim2.new(1, -20, 0, 146)
buttonFrame.Position = UDim2.new(0, 10, 1, -156)
buttonFrame.BackgroundTransparency = 1
buttonFrame.Parent = frame

-- ------------------------------------------------------------------
-- SIX BUTTONS, and two of them carry the whole experiment.
--
-- What was here before was eleven switches, most of them single settings you
-- had to hold in your head at once (state calls, write mode, profile, capture,
-- forensics, trace, ownership, snapshot). The flight logic is now ONE button
-- that applies the entire setup, and the diagnostics are ONE dial.
-- ------------------------------------------------------------------
local boostBtn = Instance.new("TextButton")      -- REPLAY: fly the armed setup
boostBtn.Size = UDim2.new(1, 0, 0, 32)
boostBtn.Position = UDim2.new(0, 0, 0, 0)
boostBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
boostBtn.Text = "REPLAY"
boostBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
boostBtn.Font = Enum.Font.GothamBold
boostBtn.TextSize = 13
boostBtn.Parent = buttonFrame
Instance.new("UICorner", boostBtn).CornerRadius = UDim.new(0, 6)

-- THE logic switch. One press sets state calls, write mode and profile together,
-- because they are one decision: "fly the reference setup" or "reproduce the
-- setup that gets us -1000". Splitting them into three buttons is what made the
-- panel ambiguous - a half-switched combination tests nothing.
local modeBtn = Instance.new("TextButton")
modeBtn.Size = UDim2.new(1, 0, 0, 36)
modeBtn.Position = UDim2.new(0, 0, 0, 38)
modeBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 70)
modeBtn.Text = "MODE"
modeBtn.TextColor3 = Color3.fromRGB(235, 255, 235)
modeBtn.Font = Enum.Font.GothamBold
modeBtn.TextSize = 11
modeBtn.Parent = buttonFrame
Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0, 6)

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0, 130, 0, 26)
copyBtn.Position = UDim2.new(0, 0, 0, 80)
copyBtn.BackgroundColor3 = Color3.fromRGB(0, 140, 180)
copyBtn.Text = "Copy Full Log"
copyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 12
copyBtn.Parent = buttonFrame
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 100, 0, 26)
clearBtn.Position = UDim2.new(0, 140, 0, 80)
clearBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
clearBtn.Text = "Clear Log"
clearBtn.TextColor3 = Color3.fromRGB(255, 180, 180)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 12
clearBtn.Parent = buttonFrame
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

-- How loud the log is. Full = capture + touch/prop/velocity watches + the
-- per-write trace. Ledger = the flight ledger only, for when the noise of a
-- normal world (guards, touchers, props) buries the flight.
local diagBtn = Instance.new("TextButton")
diagBtn.Size = UDim2.new(0, 170, 0, 26)
diagBtn.Position = UDim2.new(0, 0, 0, 112)
diagBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 70)
diagBtn.Text = "DIAG"
diagBtn.TextColor3 = Color3.fromRGB(220, 255, 230)
diagBtn.Font = Enum.Font.GothamBold
diagBtn.TextSize = 11
diagBtn.Parent = buttonFrame
Instance.new("UICorner", diagBtn).CornerRadius = UDim.new(0, 6)

-- Ownership + snapshot, which were two buttons doing one job: "tell me
-- everything about right now".
local dumpBtn = Instance.new("TextButton")
dumpBtn.Size = UDim2.new(0, 134, 0, 26)
dumpBtn.Position = UDim2.new(0, 180, 0, 112)
dumpBtn.BackgroundColor3 = Color3.fromRGB(60, 70, 120)
dumpBtn.Text = "DUMP NOW"
dumpBtn.TextColor3 = Color3.fromRGB(225, 230, 255)
dumpBtn.Font = Enum.Font.GothamBold
dumpBtn.TextSize = 11
dumpBtn.Parent = buttonFrame
Instance.new("UICorner", dumpBtn).CornerRadius = UDim.new(0, 6)

local feedback = Instance.new("TextLabel")
feedback.Size = UDim2.new(0, 200, 0, 18)
feedback.Position = UDim2.new(0, 10, 1, -184)
feedback.BackgroundTransparency = 1
feedback.Text = ""
feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
feedback.Font = Enum.Font.GothamBold
feedback.TextSize = 12
feedback.Visible = false
feedback.Parent = frame

-- ================================================================
-- DRAGGABLE
-- ================================================================
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

-- ================================================================
-- LOGGING
-- ================================================================
local logEntries = {}
local logLabels = {}
local activePhase = "IDLE"

local function timestamp()
	local ms = DateTime.now().UnixTimestampMillis % 1000
	return string.format("%s.%03d", os.date("%H:%M:%S"), ms)
end

local function formatPos(pos)
	return string.format("%.1f, %.1f, %.1f", pos.X, pos.Y, pos.Z)
end

local function formatVec3(v)
	return string.format("%.1f, %.1f, %.1f", v.X, v.Y, v.Z)
end

local function safeState(humanoid)
	local ok, state = pcall(function() return humanoid:GetState() end)
	return ok and tostring(state) or "<state-error>"
end

local function safeFloor(humanoid)
	local ok, floor = pcall(function() return humanoid.FloorMaterial end)
	return ok and tostring(floor) or "<floor-error>"
end

local function addLogEntry(entryText)
	table.insert(logEntries, entryText)
	pcall(function() print(entryText) end)
	if #logEntries > MAX_LOG_ENTRIES then table.remove(logEntries, 1) end

	local entry = Instance.new("TextLabel")
	entry.Size = UDim2.new(1, -8, 0, 16)
	entry.BackgroundTransparency = 1
	entry.Text = entryText
	entry.TextColor3 = Color3.fromRGB(200, 200, 200)
	entry.Font = Enum.Font.Code
	entry.TextSize = 10
	entry.TextXAlignment = Enum.TextXAlignment.Left
	entry.TextTruncate = Enum.TextTruncate.AtEnd
	entry.Parent = logScroll

	table.insert(logLabels, entry)
	while #logLabels > MAX_LOG_ENTRIES do
		if logLabels[1] then logLabels[1]:Destroy() end
		table.remove(logLabels, 1)
	end

	logScroll.CanvasSize = UDim2.new(0, 0, 0, logList.AbsoluteContentSize.Y + 10)
	logScroll.CanvasPosition = Vector2.new(0, math.max(0, logScroll.CanvasSize.Y.Offset))
end

-- ----------------------------------------------------------------
-- FORENSICS STATE (declared here on purpose)
-- clearLog() below resets this state, and the toggle buttons are built below
-- that, so these have to exist BEFORE the UI section. They used to be declared
-- down in the scanner section: every write from clearLog() then silently
-- created a GLOBAL instead of touching the real local, so CLEAR reset nothing.
-- ----------------------------------------------------------------
-- STARTUP OPTIONS THAT FLIGHT CODE READS.
-- These MUST be declared above replicateFreefall(). Declared further down (as
-- they first were) the replay reads a GLOBAL with the same name while the button
-- writes the LOCAL: the toggle looks like it works and silently does nothing.
-- Tests/debug_scanner_test.py has a static check for this exact mistake.
local stateCallsEnabled = false
local pivotWriteEnabled = PIVOT_WRITE_DEFAULT
local profileMeasured = PROFILE_MEASURED_DEFAULT
local pendingJump = nil            -- a big displacement we are watching for a reversal
-- how close in XZ a position has to be to the write for a lost height to count as
-- gravity rather than the server moving us back
local REVERT_AXIS_STUDS = 6.0
-- consecutive server reverts that matter: the kill has followed 4 in a row
local DANGER_STREAK = 3
local revertStreak = 0
local evaluatePendingJump          -- assigned in the forensics layer
local deathConnection, anchoredConnection, touchConnection
local lastTouchLogged = {}
local netSamples, lastNetLog, lastFastAt, lastVoidWarn = {}, 0, 0, 0
local lastRigWarn, rigBaseline = 0, nil
local restChecked = true
-- flight write ledger - also reset by clearLog() below, so it must live here
local flightTrace = nil
local flightTraceEnabled = FLIGHT_TRACE_DEFAULT
local lastWrite, lastLostWarn, writeSeq = nil, 0, 0
local lastOwnerSeen, lastOwnerPoll = nil, 0
local autoRotateConnection
-- burst ledger + velocity watch - clearLog() below resets these too
local burst = nil
local burstEnabled = BURST_DEFAULT
local lastVelSample, lastVelJumpAt = nil, 0
local lastTouchInfo = nil
local propertyConnections = {}

local function clearLog()
	logEntries = {}
	logLabels = {}
	for _, c in ipairs(logScroll:GetChildren()) do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	-- reset the forensics state too, so a cleared log does not carry a stale
	-- pendingJump / rig baseline into the next session
	pendingJump, rigBaseline, lastTouchLogged = nil, nil, {}
	netSamples, lastNetLog, lastFastAt, lastVoidWarn = {}, 0, 0, 0
	lastRigWarn, restChecked = 0, true
	flightTrace, lastWrite, lastLostWarn, writeSeq = nil, nil, 0, 0
	lastOwnerSeen, lastOwnerPoll = nil, 0
	burst, lastVelSample, lastVelJumpAt, lastTouchInfo = nil, nil, 0, nil
end

-- ================================================================
-- NOCLIP / PHASE
-- ================================================================
local function setNoclip(character, enabled)
	local changed = 0
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			local wanted = not enabled
			if part.CanCollide ~= wanted then
				part.CanCollide = wanted
				changed += 1
			end
		end
	end
	return changed
end

local function countNoCollide(character)
	local total, nocollide = 0, 0
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			total += 1
			if not part.CanCollide then nocollide += 1 end
		end
	end
	return total, nocollide
end

local function setPhase(newPhase, humanoid, root)
	local oldPhase = activePhase
	activePhase = tostring(newPhase or "IDLE")
	if phaseLabel and phaseLabel.Parent and humanoid and humanoid.Parent then
		phaseLabel.Text = string.format("Phase: %s | HP: %.1f", activePhase, humanoid.Health)
	end
	if oldPhase ~= activePhase and humanoid and humanoid.Parent and root and root.Parent then
		addLogEntry(string.format(
			"[%s] PHASE | %s -> %s | state=%s | pos=(%s) | vel=(%s)",
			timestamp(), oldPhase, activePhase, safeState(humanoid), formatPos(root.Position), formatVec3(root.AssemblyLinearVelocity)
		))
	end
end

-- ================================================================
-- FLIGHT WRITE LEDGER (V9)
-- ================================================================
-- Why this exists: the log could show `dP=(1978.0, ...)` but not what the script
-- had ASKED for, or whether the server kept it. Those two facts are the whole
-- difference between "the flight worked" and "the client wrote and the server
-- put us back". Every position write now goes through noteWrite(), and the
-- character is checked against that target a frame later.
local function ownerName(part)
	if not part then return "?" end
	-- The API is GetNetworkOwner(), which returns a Player, or nil when the
	-- SERVER owns the part. The first version of this called
	-- GetNetworkOwnership() - which does not exist - so every ownership readout
	-- in the field log printed <error> and told us nothing.
	local owner
	local ok = pcall(function() owner = part:GetNetworkOwner() end)
	if not ok then
		-- older/odd APIs: fall back rather than lose the line
		local ok2
		ok2, owner = pcall(function() return part:GetNetworkOwnership() end)
		if not ok2 then return "<no-ownership-api>" end
	end
	if owner == nil then return "server" end
	if owner == player then return "you" end
	local okName, name = pcall(function() return owner.Name end)
	return okName and name or "?"
end

-- A nil return from GetNetworkOwner() MEANS the server owns it. If the server
-- owns the assembly, a client CFrame write is a request, not a fact.
local function ownershipLine(character, root)
	if not character then return "no character | root=" .. ownerName(root) end
	local tally, order = {}, {}
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			local o = ownerName(part)
			if not tally[o] then tally[o] = 0; order[#order + 1] = o end
			tally[o] += 1
		end
	end
	local bits = {}
	for _, o in ipairs(order) do
		bits[#bits + 1] = string.format("%s x%d", o, tally[o])
	end
	return string.format("root=%s | parts: %s", ownerName(root), table.concat(bits, ", "))
end

local function grounded(part)
	local ok, g = pcall(function() return part:IsGrounded() end)
	if not ok then return "?" end
	return tostring(g)
end

-- How long since this part last received a network update. A spike here means
-- the client is out of touch with the server, which is when writes get undone.
local function receiveAge(part)
	local ok, age = pcall(function() return part.ReceiveAge end)
	if not ok or age == nil then return "?" end
	return string.format("%.2f", age)
end

local function physicsLine()
	local out = {}
	local function add(label, fn)
		local ok, v = pcall(fn)
		out[#out + 1] = string.format("%s=%s", label, ok and tostring(v) or "<err>")
	end
	add("realFPS", function() return string.format("%.1f", workspace:GetRealPhysicsFPS()) end)
	add("throttle", function() return string.format("%.0f%%", workspace:GetPhysicsThrottling()) end)
	add("gravity", function() return string.format("%.1f", workspace.Gravity) end)
	add("awake", function() return tostring(workspace:GetNumAwakeParts()) end)
	add("ping", function() return string.format("%.3fs", player:GetNetworkPing()) end)
	return table.concat(out, " | ")
end

-- The exact numbers of the reference profile, in the log, so a trace is
-- self-contained: this is what a replication has to reproduce.
-- ----------------------------------------------------------------
-- BURST LEDGER (V10)
-- ----------------------------------------------------------------
local function numOrDash(v)
	if type(v) ~= "number" then return "?" end
	return string.format("%.1f", v)
end

local function openBurst(pos, delta, now, humanoid, root)
	local startPos = pos - delta
	local nc, total = 0, 0
	if player.Character then total, nc = countNoCollide(player.Character) end
	burst = {
		startTime = now, lastStepAt = now, startPos = startPos, prevStepPos = startPos,
		stepY = pos.Y,
		endPos = pos, dir = nil, steps = {}, lines = 0, echoes = 0,
		maxY = math.max(startPos.Y, pos.Y), minY = math.min(startPos.Y, pos.Y),
		sumDt = 0, dtCount = 0, worstDt = 0, drop = 0, states = {},
		backTotal = 0, worstBack = 0, worstBackAt = 0, backSteps = 0,
		lastTouch = lastTouchInfo, sources = {}, sizes = {},
	}
	burst.states[safeState(humanoid)] = true
	addLogEntry(string.format("[%s] ============ BURST START ============", timestamp()))
	addLogEntry(string.format(
		"[%s]   at        | (%s) | state=%s | vel=(%s) | nc=%d/%d | floor=%s",
		timestamp(), formatPos(startPos), safeState(humanoid),
		formatVec3(root.AssemblyLinearVelocity), nc, total, safeFloor(humanoid)))
	addLogEntry(string.format(
		"[%s]   body      | walkSpeed=%s | hipHeight=%s | jumpPower=%s | grounded=%s | owner=%s%s",
		timestamp(), numOrDash(humanoid.WalkSpeed), numOrDash(humanoid.HipHeight),
		numOrDash(humanoid.JumpPower), grounded(root), ownerName(root),
		burst.lastTouch and string.format(" | lastTouch=%s (%.2fs before)",
			burst.lastTouch.name, now - burst.lastTouch.time) or " | lastTouch=none"))
end

-- Close and report. Called when a gap appears (a new burst starts elsewhere, or
-- the tick notices) so a burst that simply stops still gets summarised.
local function closeBurst(now, why)
	local b = burst
	if not b then return end
	burst = nil
	local dur = math.max(now - b.startTime, 1e-3)
	local net = (b.endPos - b.startPos).Magnitude
	local n = #b.steps
	local rise = b.maxY - b.startPos.Y
	local cruise, short, total = 0, 0, 0
	local minStep, maxStep, sumStep = math.huge, 0, 0
	for _, s in ipairs(b.steps) do
		if s.speed > cruise then cruise = s.speed end
		total += s.dist
		minStep = math.min(minStep, s.dist)
		maxStep = math.max(maxStep, s.dist)
		sumStep += s.dist
	end
	if n == 0 then minStep = 0 end
	for _, s in ipairs(b.steps) do
		if cruise > 0 and s.speed < cruise * BURST_SHORT_FRACTION then short += 1 end
	end
	local order = {}
	for state in pairs(b.states) do order[#order + 1] = state end
	table.sort(order)

	addLogEntry(string.format("[%s] ============ BURST END | %d steps | %s ============",
		timestamp(), n, why or "done"))
	addLogEntry(string.format(
		"[%s]   moved     | %.1f studs in %.2fs (%.0f studs/s) | now at (%s)",
		timestamp(), net, dur, net / dur, formatPos(b.endPos)))
	addLogEntry(string.format(
		"[%s]   from      | (%s) | %.1f studs of writes across %d logged move(s)",
		timestamp(), formatPos(b.startPos), total, b.lines))
	addLogEntry(string.format(
		"[%s]   Y         | start %.1f -> peak %.1f (%+.1f) | final drop %+.1f | min %.1f",
		timestamp(), b.startPos.Y, b.maxY, rise, b.drop, b.minY))
	addLogEntry(string.format(
		"[%s]   steps     | %d distinct (%d channel echoes) | min %.1f | max %.1f | avg %.1f",
		timestamp(), n, b.echoes, minStep, maxStep, n > 0 and (sumStep / n) or 0))
	if b.dtCount > 0 then
		local avgDt = b.sumDt / b.dtCount
		addLogEntry(string.format(
			"[%s]   timing    | avg frame %.3fs (%.0f fps) | worst %.3fs | %d sample(s)",
			timestamp(), avgDt, avgDt > 0 and (1 / avgDt) or 0, b.worstDt, b.dtCount))
	end
	addLogEntry(string.format(
		"[%s]   speed     | cruise %.0f studs/s | %d step(s) under %d%% of it",
		timestamp(), cruise, short, math.floor(BURST_SHORT_FRACTION * 100)))
	if b.worstBack > REVERT_MIN_STUDS then
		addLogEntry(string.format(
			"[%s] BURST REVERSED | worst single step went back %.1f studs (step %d) | %.1f studs total",
			timestamp(), b.worstBack, b.worstBackAt, b.backTotal))
	else
		addLogEntry(string.format(
			"[%s]   reversal  | none - no step went backwards", timestamp()))
	end
	local srcOrder = {}
	for k in pairs(b.sources) do srcOrder[#srcOrder + 1] = k end
	table.sort(srcOrder)
	local srcBits = {}
	for _, k in ipairs(srcOrder) do
		srcBits[#srcBits + 1] = string.format("%s %d", k, b.sources[k])
	end
	addLogEntry(string.format("[%s]   sources   | %s", timestamp(),
		#srcBits > 0 and table.concat(srcBits, " | ") or "none"))
	local sizeOrder = { "<20", "20-60", "60-100", "100-150", "150-200", "200-300", "300+" }
	local sizeBits, median, half = {}, math.huge, 0
	for _, k in ipairs(sizeOrder) do
		if b.sizes[k] then
			sizeBits[#sizeBits + 1] = string.format("%s %d", k, b.sizes[k])
		end
	end
	-- median step size: the single most useful number for matching a writer's
	-- step quantum, which the average hides
	half = math.floor(n / 2)
	local sorted = {}
	for i, s in ipairs(b.steps) do sorted[i] = s.dist end
	table.sort(sorted)
	if n > 0 then median = sorted[math.max(1, half)] end
	addLogEntry(string.format("[%s]   sizes     | %s | median %.1f",
		timestamp(), #sizeBits > 0 and table.concat(sizeBits, " | ") or "none", median))
	if b.dtCount > 0 then
		addLogEntry(string.format(
			"[%s]   rate      | %.0f steps/s | %.2f steps per frame sample",
			timestamp(), n / dur, n / b.dtCount))
	end
	-- what moved it? This is the question a position-only log cannot answer.
	if not b.sources.CFrameChanged then
		addLogEntry(string.format(
			"[%s]   mechanism | no CFrameChanged event: root.CFrame was never assigned, so a PivotTo, a body mover or another part did the moving",
			timestamp()))
	else
		addLogEntry(string.format(
			"[%s]   mechanism | %d direct root.CFrame write(s) seen",
			timestamp(), b.sources.CFrameChanged))
	end
	addLogEntry(string.format("[%s]   states    | %s", timestamp(), table.concat(order, " -> ")))
	if b.lastTouch then
		addLogEntry(string.format("[%s]   lastTouch | %s | %.2fs before the first step",
			timestamp(), b.lastTouch.name, math.max(b.startTime - b.lastTouch.time, 0)))
	end
	local verdict
	if n == 0 then
		verdict = "NO STEPS - every move was an echo of another channel"
	elseif b.worstBack > REVERT_MIN_STUDS then
		verdict = string.format("REVERTED - %d steps, but %.0f studs were pushed back",
			n, b.backTotal)
	elseif short >= math.max(2, math.floor(n * 0.25)) then
		verdict = string.format(
			"PARTIAL - %d of %d steps came in short of cruise; the writes were being pushed back",
			short, n)
	elseif net < 1 then
		verdict = "DID NOT MOVE - the writes did not stick"
	else
		verdict = string.format(
			"HELD - every step stuck, the character really moved %.0f studs", net)
	end
	addLogEntry(string.format("[%s]   verdict   | %s", timestamp(), verdict))

	-- ---- how does this compare to the flight we are trying to reproduce? ----
	local ref = REFERENCE_STATS
	local verdictLine
	if b.worstBack > REVERT_MIN_STUDS or short >= math.max(2, math.floor(n * 0.25)) then
		verdictLine = "DOES NOT MATCH - the reference has " .. ref.reverted
			.. " reverted steps; this one had " .. b.backSteps
			.. " step(s) pushed back (" .. string.format("%.0f", b.backTotal) .. " studs)"
	elseif net < 1 then
		verdictLine = "DOES NOT MATCH - this one did not move at all"
	elseif math.abs(n - ref.steps) <= 6 and math.abs(net - ref.studs) < ref.studs * 0.25 then
		verdictLine = "MATCHES the reference within tolerance"
	else
		verdictLine = string.format(
			"MOVED, BUT NOT THE SAME - %d steps (ref %d) and %.0f studs (ref %.0f)",
			n, ref.steps, net, ref.studs)
	end
	addLogEntry(string.format("[%s] REFERENCE DIFF | %s", timestamp(), verdictLine))
	addLogEntry(string.format(
		"[%s]   this flight | %d steps | %.1f studs | %.2fs | median %.1f | %d pushed back",
		timestamp(), n, net, dur, n > 0 and sorted[math.max(1, half)] or 0, b.backSteps))
	addLogEntry(string.format(
		"[%s]   reference   | %d steps | %.1f studs | %.2fs | median %.1f | %d reverted",
		timestamp(), ref.steps, ref.studs, ref.seconds, ref.median, ref.reverted))

	-- the replication payload: every distinct step as (t, dx, dy), 8 per line
	if n > 0 then
		local dz = 0
		for _, s in ipairs(b.steps) do dz = math.max(dz, math.abs(s.dz)) end
		addLogEntry(string.format(
			"[%s] BURST STEPS | (t/dx/dy) | dz max %.1f | %d step(s)%s",
			timestamp(), dz, n, n >= BURST_MAX_STEPS and " - TRUNCATED" or ""))
		local chunk = {}
		for _, s in ipairs(b.steps) do
			chunk[#chunk + 1] = string.format("%.3f/%+.1f/%+.1f", s.t, s.dx, s.dy)
			if #chunk >= 8 then
				addLogEntry(string.format("[%s] BURST STEPS | %s", timestamp(),
					table.concat(chunk, ", ")))
				chunk = {}
			end
		end
		if #chunk > 0 then
			addLogEntry(string.format("[%s] BURST STEPS | %s", timestamp(),
				table.concat(chunk, ", ")))
		end
	end
end

-- Every logged move passes through here. Which script produced it does not
-- matter: a real flight is one burst of teleport-style writes.
local function noteBurstStep(source, pos, delta, now, humanoid, root, dt, vMag)
	if not burstEnabled or not root then return end
	-- Movement the velocity already accounts for is the coast, not a step.
	-- Counting it would bury the flight profile in physics frames.
	local dist = delta.Magnitude
	if vMag > 1 and dist <= (vMag * (dt or 0)) * 1.5 + 4 then return end
	if not burst or (now - burst.lastStepAt) > BURST_GAP_S then
		if burst then closeBurst(now, "gap") end
		openBurst(pos, delta, now, humanoid, root)
	end
	local b = burst
	b.lines += 1
	b.lastStepAt = now
	-- WHICH channel saw this move is a mechanism clue, not a curiosity: the
	-- CFrameChanged hook fires at the instant of the write, while the stage
	-- channels only sample per frame. A flight with CFrameChanged = 0 never
	-- assigned root.CFrame, so something else moved the character.
	b.sources[source] = (b.sources[source] or 0) + 1
	do
		local key
		if dist < 20 then key = "<20"
		elseif dist < 60 then key = "20-60"
		elseif dist < 100 then key = "60-100"
		elseif dist < 150 then key = "100-150"
		elseif dist < 200 then key = "150-200"
		elseif dist < 300 then key = "200-300"
		else key = "300+" end
		b.sizes[key] = (b.sizes[key] or 0) + 1
	end
	b.endPos = pos
	b.maxY = math.max(b.maxY, pos.Y)
	b.minY = math.min(b.minY, pos.Y)
	b.states[safeState(humanoid)] = true
	if dt and dt > 0 then
		b.sumDt += dt
		b.dtCount += 1
		if dt > b.worstDt then b.worstDt = dt end
	end
	-- echoes of one write land on the same position: four stage channels report
	-- the same write, and counting them as steps inflates the profile 4x
	local driftXZ = (Vector3.new(pos.X - b.prevStepPos.X, 0, pos.Z - b.prevStepPos.Z)).Magnitude
	-- Y is measured against the step we recorded, not against the sample before
	-- this one: a chain of echoes would otherwise walk the anchor down with it
	-- and collapse a real fall into a single "step".
	if driftXZ <= BURST_ECHO_STUDS
		and math.abs(pos.Y - b.stepY) <= BURST_ECHO_Y_STUDS then
		b.echoes += 1
		-- Echoes of one write carry different frame deltas, because each stage
		-- channel samples at its own point in the frame. Keep the LARGEST: it is
		-- the one the writer actually had, and using a small echo dt inflates the
		-- step's implied speed (and with it the cruise the shortfall is judged
		-- against).
		local last = b.steps[#b.steps]
		if last and dt and dt > (last.dt or 0) then
			last.dt = dt
			last.speed = last.dist / dt
		end
		return
	end
	if #b.steps >= BURST_MAX_STEPS then return end
	-- the direction of the flight is set by its first real step, so "backwards"
	-- means backwards relative to where this burst is going
	if not b.dir and dist > 1 then b.dir = (1 / dist) * delta end
	if b.dir then
		local along = delta:Dot(b.dir)
		if along < 0 then
			b.backTotal += -along
			b.backSteps += 1
			if -along > b.worstBack then
				b.worstBack = -along
				b.worstBackAt = #b.steps + 1
			end
		end
	end
	if delta.Y < 0 then b.drop = math.min(b.drop, delta.Y) end
	b.steps[#b.steps + 1] = {
		t = now - b.startTime, dx = delta.X, dy = delta.Y, dz = delta.Z,
		dist = dist, dt = dt, speed = (dt and dt > 0) and (dist / dt) or 0,
	}
	b.prevStepPos = pos
	b.stepY = pos.Y
end

local function logReplayParams()
	local useMeasured = profileMeasured
	local srcLaunch = useMeasured and MEASURED_LAUNCH or LAUNCH_PROFILE
	local srcDeltas = useMeasured and MEASURED_X_DELTAS or FREEFALL_X_DELTAS
	local srcTimes = useMeasured and MEASURED_CHUNK_TIMES or FREEFALL_CHUNK_TIMES
	local srcDrop = useMeasured and MEASURED_DROP_Y or DROP_OFFSET_Y
	local deltas, times, total = {}, {}, 0
	for i, dx in ipairs(srcDeltas) do
		deltas[#deltas + 1] = string.format("%.1f", dx)
		times[#times + 1] = string.format("%.3f", srcTimes[i] or 0.045)
		total += math.abs(dx)
	end
	local launch = srcLaunch[#srcLaunch]
	local launchDist = Vector3.new(launch.dx, launch.dy, launch.dz).Magnitude
	addLogEntry(string.format(
		"[%s] REPLAY PARAMS | %s | launch=%d steps (%.1f studs) | chunks=%d (%.1f studs) | dropOffsetY=%.1f",
		timestamp(), useMeasured and "MEASURED 05:01:42" or "ld-p3",
		#srcLaunch, launchDist, #srcDeltas, total, srcDrop))
	addLogEntry(string.format("[%s]   dx = %s", timestamp(), table.concat(deltas, ",")))
	addLogEntry(string.format("[%s]   dt = %s", timestamp(), table.concat(times, ",")))
	addLogEntry(string.format(
		"[%s]   tolerance=%.1f | minFreefallY=%.1f | renderPriority=%d | expected total=%.1f studs",
		timestamp(), REPLAY_CORRECTION_TOLERANCE, REPLAY_MIN_FREEFALL_Y,
		RENDER_STEP_PRIORITY, launchDist + total))
	return launchDist + total
end

local function beginFlightTrace(name, humanoid, root, startPos, requestedStuds)
	if not flightTraceEnabled then return end
	local now = os.clock()
	flightTrace = {
		name = name, startTime = now, startPos = startPos, requested = requestedStuds,
		writes = 0, lost = 0, held = 0, frames = 0, events = 0,
		lastFrameAt = 0, lastPhysicsAt = now, lastTarget = nil,
	}
	addLogEntry(string.format("[%s] ============ FLIGHT TRACE START | %s ============",
		timestamp(), name))
	addLogEntry(string.format(
		"[%s]   from=(%s) | state=%s | hp=%.1f | floor=%s | noclip=on",
		timestamp(), formatPos(startPos), safeState(humanoid), humanoid.Health, safeFloor(humanoid)))
	addLogEntry(string.format("[%s]   owner | %s", timestamp(),
		ownershipLine(player.Character, root)))
	local okMass, mass = pcall(function() return root.AssemblyMass end)
	addLogEntry(string.format("[%s]   root  | grounded=%s | receiveAge=%s | anchored=%s | mass=%.1f",
		timestamp(), grounded(root), receiveAge(root), tostring(root.Anchored),
		okMass and mass or -1))
	addLogEntry(string.format("[%s]   physics | %s", timestamp(), physicsLine()))
end

-- Called from forceTransform() - the single place the replay writes a position.
local function noteWrite(kind, target)
	writeSeq += 1
	lastWrite = { seq = writeSeq, kind = kind, target = target, time = os.clock(), bad = false }
	if flightTrace then
		flightTrace.writes += 1
		flightTrace.lastTarget = target
	end
end

-- Anything the replay DOES that is not a position write. ChangeState/AutoRotate
-- were completely invisible in the log before this - and they are the -1000.
local function noteEvent(root, kind, detail)
	if flightTrace then flightTrace.events += 1 end
	addLogEntry(string.format(
		"[%s] ACTION | %s%s | phase=%s | t+%.3fs | pos=(%s) | owner=%s",
		timestamp(), kind, detail and (" | " .. detail) or "", activePhase,
		flightTrace and (os.clock() - flightTrace.startTime) or 0,
		root and formatPos(root.Position) or "?", ownerName(root)))
end

-- Hysteresis: count one "episode" each time the character leaves the target the
-- replay asked for, and one recovery each time it comes back. A flapping
-- character therefore reads as N episodes rather than N log lines.
local function checkWriteOutcome(humanoid, root, now)
	if not lastWrite or not lastWrite.target or not root then return end
	local err = (root.Position - lastWrite.target).Magnitude
	local off = err > WRITE_CONFIRM_STUDS
	if off and not lastWrite.bad then
		lastWrite.bad = true
		if flightTrace then flightTrace.lost += 1 end
		if (now - lastLostWarn) > LOST_WRITE_WARN_S then
			lastLostWarn = now
			addLogEntry(string.format(
				"[%s] WRITE REJECTED | #%d %s | asked=(%s) | character at (%s) | off by %.1f studs",
				timestamp(), lastWrite.seq, lastWrite.kind, formatPos(lastWrite.target),
				formatPos(root.Position), err))
			addLogEntry(string.format(
				"[%s]   owner=%s | state=%s | vel=(%s) | grounded=%s | phase=%s",
				timestamp(), ownerName(root), safeState(humanoid),
				formatVec3(root.AssemblyLinearVelocity), grounded(root), activePhase))
		end
	elseif not off and lastWrite.bad then
		lastWrite.bad = false
		if flightTrace then flightTrace.held += 1 end
		addLogEntry(string.format(
			"[%s] WRITE HELD AGAIN | #%d | back within %.1f studs of (%s) after %.2fs",
			timestamp(), lastWrite.seq, WRITE_CONFIRM_STUDS, formatPos(lastWrite.target),
			now - lastWrite.time))
	end
end

-- Bounded per-frame record: asked vs actual, per frame, so the flight can be
-- replayed from the log alone.
local function traceFrame(humanoid, root, now)
	if not flightTrace or not root then return end
	if flightTrace.frames >= FLIGHT_FRAME_MAX then return end
	if (now - flightTrace.lastFrameAt) < FLIGHT_FRAME_S then return end
	flightTrace.lastFrameAt = now
	flightTrace.frames += 1
	local target = flightTrace.lastTarget
	addLogEntry(string.format(
		"[%s] FRAME %03d | t+%.3fs | pos=(%s) | asked=(%s) | off=%.1f | state=%s | vel=(%s) | grounded=%s | owner=%s",
		timestamp(), flightTrace.frames, now - flightTrace.startTime, formatPos(root.Position),
		target and formatPos(target) or "-",
		target and (root.Position - target).Magnitude or -1,
		safeState(humanoid), formatVec3(root.AssemblyLinearVelocity),
		grounded(root), ownerName(root)))
end

local function endFlightTrace(reason, humanoid, root)
	if not flightTrace then return end
	local t = flightTrace
	local now = os.clock()
	local pos = root and root.Position or t.startPos
	local net = (pos - t.startPos).Magnitude
	local dur = math.max(now - t.startTime, 1e-3)
	addLogEntry(string.format("[%s] ============ FLIGHT TRACE END | %s ============",
		timestamp(), reason or "done"))
	addLogEntry(string.format(
		"[%s]   duration  | %.2fs | %d writes (%.0f/s) | %d frame samples | %d action(s)",
		timestamp(), dur, t.writes, t.writes / dur, t.frames, t.events))
	addLogEntry(string.format("[%s]   requested | %s studs | profile expected",
		timestamp(), t.requested and string.format("%.0f", t.requested) or "?"))
	addLogEntry(string.format("[%s]   achieved  | %.1f studs net | (%s) -> (%s)",
		timestamp(), net, formatPos(t.startPos), formatPos(pos)))
	addLogEntry(string.format(
		"[%s]   writes    | %d off-target episode(s) | %d recovered | tolerance %.1f studs",
		timestamp(), t.lost, t.held, WRITE_CONFIRM_STUDS))
	local verdict
	if t.writes == 0 then
		verdict = "NOTHING WAS WRITTEN - the replay never reached a write"
	elseif net < 1 then
		verdict = "THE CHARACTER DID NOT MOVE - writes are not sticking"
	elseif t.lost == 0 then
		verdict = "ALL WRITES HELD - the server accepted every write"
	elseif t.lost <= 2 then
		verdict = string.format(
			"%d pushback episode(s) but the flight still moved %.0f studs", t.lost, net)
	else
		verdict = string.format("THE SERVER FOUGHT BACK %d TIMES - expect rubberbanding", t.lost)
	end
	addLogEntry(string.format("[%s]   verdict   | %s", timestamp(), verdict))
	addLogEntry(string.format("[%s]   owner     | %s", timestamp(),
		ownershipLine(player.Character, root)))
	addLogEntry(string.format("[%s]   physics   | %s", timestamp(), physicsLine()))
	flightTrace = nil
	lastWrite = nil
end

-- ================================================================
-- TRANSFORM APPLICATION
-- ================================================================
local function applyReferenceTransform(character, root, requestedPos)
	if not character or not character.Parent or not root or not root.Parent then
		return false
	end
	local yaw = math.rad(root.Orientation.Y)
	character:PivotTo(CFrame.new(requestedPos) * CFrame.Angles(0, yaw, 0))
	return true
end

local function safeUnbind()
	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
end

-- ================================================================
-- REPLAY ENGINE (exact ld-p3 profile)
-- ================================================================
local replicationRunning = false
local lastReplicationStart = 0

local function replicateFreefall()
	if replicationRunning then return end

	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then return end
	if humanoid.Health <= 0 then
		addLogEntry(string.format("[%s] START ABORTED | already dead", timestamp()))
		return
	end

	replicationRunning = true
	lastReplicationStart = os.clock()
	local originalAutoRotate = humanoid.AutoRotate
	local startPos = root.Position
	local noclipChanged = setNoclip(character, true)
	local abortedReason = nil

	-- the active profile, so both can be flown from the same engine
	local profileLaunch = profileMeasured and MEASURED_LAUNCH or LAUNCH_PROFILE
	local profileDeltas = profileMeasured and MEASURED_X_DELTAS or FREEFALL_X_DELTAS
	local profileTimes = profileMeasured and MEASURED_CHUNK_TIMES or FREEFALL_CHUNK_TIMES
	local profileDropY = profileMeasured and MEASURED_DROP_Y or DROP_OFFSET_Y
	local profileName = profileMeasured and "measured-0501 (working script)" or "ld-p3 (reconstruction)"

	local launchEnd = startPos + Vector3.new(profileLaunch[#profileLaunch].dx, profileLaunch[#profileLaunch].dy, profileLaunch[#profileLaunch].dz or 0)
	local freefallOrigin = launchEnd
	local fixedY = launchEnd.Y
	local fixedZ = launchEnd.Z

	addLogEntry(string.format(
		"[%s] REPLAY START V13 | profile=%s | start=(%s) | launchEnd=(%s) | chunks=%d | noclip=%d | stateCalls=%s | write=%s",
		timestamp(), profileName, formatPos(startPos), formatPos(launchEnd), #profileDeltas,
		noclipChanged, stateCallsEnabled and "ON (ChangeState+AutoRotate, the -1000 pair)"
			or "OFF (matching the reference)",
		pivotWriteEnabled and "PivotTo+CFrame (whole rig)" or "CFrame only (root, joints follow)"
	))

	local expectedStuds = logReplayParams()
	beginFlightTrace("replicateFreefall", humanoid, root, startPos, expectedStuds)

	feedback.Text = profileMeasured and "Replaying MEASURED (05:01:42)..." or "Replaying ld-p3..."
	feedback.TextColor3 = Color3.fromRGB(255, 160, 90)
	feedback.Visible = true

	setPhase("LAUNCH", humanoid, root)

	-- Force Freefall early so the humanoid fights less.
	-- These two lines are the known -1000 trigger and they used to leave NO trace
	-- in the log at all: a replay that died 0.03s in looked identical to one that
	-- never started. They are recorded now, and they can be switched off.
	if stateCallsEnabled then
		noteEvent(root, "ChangeState(Freefall)", "the -1000 trigger")
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		noteEvent(root, "AutoRotate=false", "the -1000 trigger")
		humanoid.AutoRotate = false
	else
		addLogEntry(string.format(
			"[%s] STATE CALLS | SKIPPED ChangeState(Freefall) + AutoRotate=false | launching in whatever state the humanoid is in (the reference does)",
			timestamp()))
	end

	local startClock = os.clock()
	local launchIndex = 0
	local freefallIndex = 0
	local freefallStarted = false
	local dropDone = false
	local currentTarget = startPos          -- sticky target
	local consecutiveErrors = 0
	local MAX_CONSECUTIVE_ERRORS = 8        -- only abort after sustained fight
	local freefallClock = 0

	local function forceTransform(pos)
		if not character.Parent or not root.Parent then return false end
		local yaw = math.rad(root.Orientation.Y)
		local cf = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
		if pivotWriteEnabled then
			character:PivotTo(cf)          -- every part in the rig, in one claim
		end
		root.CFrame = cf                   -- one part; the joints carry the rest
		-- Keep velocity near zero so physics doesn't drag us
		root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
		-- the one place this replay writes a position: record the intent
		noteWrite(pivotWriteEnabled and "PivotTo+CFrame" or "CFrame only", pos)
		return true
	end

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_STEP_PRIORITY, function(dt)
		if abortedReason or dropDone then return end
		if not character.Parent or not humanoid.Parent or not root.Parent then
			abortedReason = "character disappeared"
			return
		end
		if humanoid.Health <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Dead then
			abortedReason = "Humanoid Dead"
			return
		end

		local elapsed = os.clock() - startClock

		-- Always re-apply the current sticky target first
		if currentTarget then
			forceTransform(currentTarget)
		end

		-- Check for sustained correction
		if currentTarget then
			local err = (root.Position - currentTarget).Magnitude
			if err > REPLAY_CORRECTION_TOLERANCE then
				consecutiveErrors += 1
				if consecutiveErrors == 1 or consecutiveErrors % 4 == 0 then
					addLogEntry(string.format(
						"[%s] CORRECTION FIGHT | err=%.1f | frames=%d | actual=(%s) | target=(%s)",
						timestamp(), err, consecutiveErrors, formatPos(root.Position), formatPos(currentTarget)
					))
				end
				if consecutiveErrors >= MAX_CONSECUTIVE_ERRORS then
					abortedReason = string.format("sustained correction %.1f studs", err)
					return
				end
			else
				consecutiveErrors = 0
			end
		end

		-- ---------- LAUNCH PHASE ----------
		if not freefallStarted then
			local nextIdx = launchIndex + 1
			if nextIdx <= #profileLaunch and elapsed >= profileLaunch[nextIdx].t then
				local item = profileLaunch[nextIdx]
				currentTarget = startPos + Vector3.new(item.dx, item.dy, item.dz or 0)
				forceTransform(currentTarget)
				launchIndex = nextIdx

				addLogEntry(string.format(
					"[%s] LAUNCH CHUNK | i=%d/%d | t=%.3f | target=(%s) | actual=(%s) | state=%s",
					timestamp(), launchIndex, #profileLaunch, item.t,
					formatPos(currentTarget), formatPos(root.Position), safeState(humanoid)
				))

				if launchIndex >= #profileLaunch then
					freefallStarted = true
					freefallClock = os.clock()
					setPhase("FREEFALL", humanoid, root)
					if stateCallsEnabled then
						noteEvent(root, "ChangeState(Freefall)", "again, at freefall start")
						humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
					end
					addLogEntry(string.format(
						"[%s] FREEFALL START | pos=(%s) | state=%s",
						timestamp(), formatPos(root.Position), safeState(humanoid)
					))
				end
			end
			return
		end

		-- ---------- FREEFALL CHUNKS ----------
		if freefallStarted and freefallIndex < #profileDeltas then
			local nextIdx = freefallIndex + 1
			local targetTime = 0
			for i = 1, nextIdx do
				targetTime += (profileTimes[i] or 0.045)
			end

			if (os.clock() - freefallClock) >= targetTime then
				local dx = profileDeltas[nextIdx]
				local prevX = currentTarget and currentTarget.X or freefallOrigin.X
				currentTarget = Vector3.new(prevX + dx, fixedY, fixedZ)
				forceTransform(currentTarget)
				freefallIndex = nextIdx

				addLogEntry(string.format(
					"[%s] FREEFALL CHUNK | i=%d/%d | dx=%.1f | target=(%s) | actual=(%s) | state=%s",
					timestamp(), freefallIndex, #profileDeltas, dx,
					formatPos(currentTarget), formatPos(root.Position), safeState(humanoid)
				))
			end
			return
		end

		-- ---------- FINAL DROP ----------
		if freefallIndex >= #profileDeltas and not dropDone then
			currentTarget = Vector3.new(currentTarget.X, fixedY + profileDropY, fixedZ)
			forceTransform(currentTarget)
			dropDone = true
			setPhase("DROP", humanoid, root)
			addLogEntry(string.format(
				"[%s] DROP | target=(%s) | actual=(%s) | state=%s",
				timestamp(), formatPos(currentTarget), formatPos(root.Position), safeState(humanoid)
			))
		end
	end)

	-- Wait
	while not dropDone and not abortedReason and character.Parent and humanoid.Parent do
		RunService.Heartbeat:Wait()
	end

	safeUnbind()
	endFlightTrace(abortedReason or "flight complete", humanoid, root)
	setNoclip(character, false)
	if stateCallsEnabled and humanoid and humanoid.Parent then
		humanoid.AutoRotate = originalAutoRotate
	end

	if abortedReason then
		feedback.Text = "ABORT: " .. tostring(abortedReason)
		feedback.TextColor3 = Color3.fromRGB(255, 90, 90)
		addLogEntry(string.format("[%s] ABORTED | %s | pos=(%s)", timestamp(), abortedReason, root and formatPos(root.Position) or "?"))
	else
		setPhase("LANDING_WATCH", humanoid, root)
		local watchStart = os.clock()
		local lastState = humanoid:GetState()
		while character.Parent and humanoid.Parent and (os.clock() - watchStart) < 3.0 do
			local st = humanoid:GetState()
			if st ~= lastState then
				addLogEntry(string.format(
					"[%s] LANDING STATE | %s -> %s | pos=(%s) | floor=%s",
					timestamp(), tostring(lastState), tostring(st), formatPos(root.Position), safeFloor(humanoid)
				))
				lastState = st
			end
			if st == Enum.HumanoidStateType.Landed or st == Enum.HumanoidStateType.Running then
				break
			end
			RunService.Heartbeat:Wait()
		end
		addLogEntry(string.format(
			"[%s] REPLAY FINISHED | total=%.2fs | final=(%s) | state=%s",
			timestamp(), os.clock() - lastReplicationStart, formatPos(root.Position), safeState(humanoid)
		))
		feedback.Text = "Replay finished"
		feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
	end

	setPhase("IDLE", humanoid, root)
	replicationRunning = false
	task.delay(2.5, function()
		if feedback and feedback.Parent then feedback.Visible = false end
	end)
end

-- ================================================================
-- HIGH-RESOLUTION TRANSFORM SCANNER (kept from V5)
-- ================================================================
local connection, stateConnection, healthConnection
local preSimulationConnection, postSimulationConnection, preRenderConnection
local cframeConnection
local transformCaptureEnabled = TRANSFORM_CAPTURE_DEFAULT
local forensicsEnabled = FORENSICS_DEFAULT
stateCallsEnabled = STATE_CALLS_DEFAULT
-- PER-SOURCE previous samples. This used to be ONE table shared by all four
-- stage channels (Heartbeat, PreSimulation, PostSimulation, PreRender), so each
-- channel overwrote the others' previous sample. That made `dt` a gap between
-- two DIFFERENT channels rather than a frame delta (hence dt=40.53135 on an idle
-- character), and it made `src` close to arbitrary - the reason src=PreSimulation
-- effectively never appeared in the logs.
local transformStagePrevious = {}
local transformPropertyPrevious = nil
local lastTransformJumpLogTime = 0
local lastTransformJumpLogPos = nil

local function resetTransformTelemetry(root)
	local now = os.clock()
	local pos = root.Position
	transformStagePrevious = {}   -- each channel gets its own slot on first use
	transformPropertyPrevious = { time = now, position = pos, velocity = root.AssemblyLinearVelocity, cframe = root.CFrame }
	lastTransformJumpLogTime = 0
	lastTransformJumpLogPos = pos
end

-- ================================================================
-- THE TWO PRESETS - what the MODE button applies
-- ================================================================
-- One press sets state calls, write mode AND profile, because they are one
-- decision, not three. Mode 1 is the setup the working logs argue for; mode 2 is
-- the setup that produced every -1000 death, kept so a failure can be reproduced
-- on demand. Defaults come from the *_DEFAULT constants so the two cannot drift.
local FLIGHT_MODES = {
	{
		name = "TEST (the reference setup)",
		detail = "stateCalls OFF | whole rig | measured profile",
		stateCalls = STATE_CALLS_DEFAULT,
		pivotWrite = PIVOT_WRITE_DEFAULT,
		measured = PROFILE_MEASURED_DEFAULT,
		color = Color3.fromRGB(35, 110, 70),
	},
	{
		name = "CONTROL (the -1000 setup)",
		detail = "stateCalls ON | root CFrame only | ld-p3 profile",
		stateCalls = true,
		pivotWrite = false,
		measured = false,
		color = Color3.fromRGB(140, 60, 45),
	},
}
local modeIndex = 1

-- How loud the log is. Both keep the flight ledger; LEDGER drops the world
-- noise (touch/prop/velocity watches) and the per-write trace.
local DIAG_MODES = {
	{
		name = "FULL",
		detail = "capture + watches + flight trace",
		capture = TRANSFORM_CAPTURE_DEFAULT,
		forensics = FORENSICS_DEFAULT,
		trace = FLIGHT_TRACE_DEFAULT,
		color = Color3.fromRGB(35, 110, 70),
	},
	{
		name = "LEDGER",
		detail = "flight ledger only, no watches or trace",
		capture = true,
		forensics = false,
		trace = false,
		color = Color3.fromRGB(90, 80, 50),
	},
}
local diagIndex = 1

local function refreshButtons()
	local m = FLIGHT_MODES[modeIndex]
	modeBtn.Text = string.format("MODE: %s\n%s", m.name, m.detail)
	modeBtn.BackgroundColor3 = m.color
	boostBtn.Text = string.format("REPLAY - %s",
		FLIGHT_MODES[modeIndex].stateCalls and "root CFrame only, ld-p3" or "the reference setup")
	local d = DIAG_MODES[diagIndex]
	diagBtn.Text = string.format("DIAG: %s (%s)", d.name, d.detail)
	diagBtn.BackgroundColor3 = d.color
end

local function applyMode(i, announce)
	modeIndex = i
	local m = FLIGHT_MODES[i]
	stateCallsEnabled = m.stateCalls
	pivotWriteEnabled = m.pivotWrite
	profileMeasured = m.measured
	refreshButtons()
	if announce then
		addLogEntry(string.format("[%s] MODE | %s | %s", timestamp(), m.name, m.detail))
		addLogEntry(string.format(
			"[%s]   stateCalls=%s | write=%s | profile=%s | %d chunks",
			timestamp(), tostring(stateCallsEnabled),
			pivotWriteEnabled and "PivotTo + root.CFrame" or "root.CFrame only",
			profileMeasured and "MEASURED 05:01:42" or "ld-p3",
			profileMeasured and #MEASURED_X_DELTAS or #FREEFALL_X_DELTAS))
		addLogEntry(string.format(
			"[%s]   %s", timestamp(),
			m.stateCalls
				and "CONTROL: this is the launch that gets killed - expecting the -1000"
				or "TEST: no ChangeState, no AutoRotate, flying the reference's own steps"))
	end
end

local function applyDiag(i, announce)
	diagIndex = i
	local d = DIAG_MODES[i]
	transformCaptureEnabled = d.capture
	forensicsEnabled = d.forensics
	flightTraceEnabled = d.trace
	if not flightTraceEnabled then flightTrace, lastWrite = nil, nil end
	if not forensicsEnabled then pendingJump, rigBaseline = nil, nil end
	refreshButtons()
	if announce then
		addLogEntry(string.format("[%s] DIAG | %s | %s", timestamp(), d.name, d.detail))
		addLogEntry(string.format(
			"[%s]   capture=%s | forensics=%s | flightTrace=%s",
			timestamp(), tostring(transformCaptureEnabled), tostring(forensicsEnabled),
			tostring(flightTraceEnabled)))
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if transformCaptureEnabled and root then resetTransformTelemetry(root) end
end

local function maybeLogTransformJump(source, humanoid, root, now, previousTime, previousPos, previousVel)
	if not transformCaptureEnabled or not humanoid or not root then return end
	local pos = root.Position
	local vel = root.AssemblyLinearVelocity
	local dt = math.max(now - previousTime, 1e-5)
	local delta = pos - previousPos
	local dist = delta.Magnitude
	local pSpeed = dist / dt
	local vMag = vel.Magnitude
	local velocityRatio = pSpeed / math.max(vMag, 0.1)

	local isJump = dist >= TRANSFORM_JUMP_MIN_DISTANCE
	local isMismatch = dist > 2 and pSpeed >= TRANSFORM_JUMP_MIN_PSPEED and velocityRatio >= TRANSFORM_JUMP_RATIO
	if not (isJump or isMismatch) then return end

	-- A stale previous sample is not movement: it is the scanner having lost
	-- track (respawn, reload, character swap). Report the gap and stop, or the
	-- burst ledger records a phantom multi-thousand-stud step.
	if dt > STALE_SAMPLE_S then
		addLogEntry(string.format(
			"[%s] SAMPLE GAP | %s-%s | %.2fs since the last sample of this channel | from=(%s) to (%s) | dist=%.1f | NOT a move - the sampler lost track",
			timestamp(), source, activePhase, dt, formatPos(previousPos), formatPos(pos), dist))
		return
	end

	-- Remember a big displacement so the forensics tick can see whether the
	-- server KEEPS it. This is the check that was missing: a write that does not
	-- stick is otherwise indistinguishable from one that does.
	if forensicsEnabled and dist >= BIG_JUMP_STUDS then
		-- Settle any jump we were still watching FIRST. A reversion arrives as a
		-- jump of its own (the server puts us back), so without this the new
		-- sample simply overwrote the pending one and the reversal was never
		-- seen - the sampler wiped the evidence before the tick could read it.
		if evaluatePendingJump then evaluatePendingJump(humanoid, root, now) end
		pendingJump = {
			from = previousPos, to = pos, time = now, dist = dist,
			dir = dist > 1e-6 and (1 / dist) * delta or Vector3.zero,
		}
	end

	if lastTransformJumpLogPos and (now - lastTransformJumpLogTime) <= TRANSFORM_PROPERTY_DEDUPE_TIME
		and (pos - lastTransformJumpLogPos).Magnitude <= TRANSFORM_PROPERTY_DEDUPE_DISTANCE then
		return
	end

	lastTransformJumpLogTime = now
	lastTransformJumpLogPos = pos

	-- Feed the burst ledger. This runs for EVERY move the scanner sees, whoever
	-- caused it - the escape scripts fly without ever touching this file's UI.
	noteBurstStep(source, pos, delta, now, humanoid, root, dt, vMag)

	local class = isMismatch and "TRANSFORM_JUMP" or "LARGE_MOVE"
	addLogEntry(string.format(
		"[%s] %s | src=%s | phase=%s | state=%s | dt=%.5f | dP=(%s) | dist=%.2f | pSpd=%.1f | vel=(%s) | vMag=%.1f | vRatio=%.1fx%s | pos=(%s)",
		timestamp(), class, source, activePhase, safeState(humanoid), dt, formatVec3(delta), dist, pSpeed, formatVec3(vel), vMag, velocityRatio,
		-- vRatio = pSpeed / max(vMag, 0.1) is meaningless when vMag is 0: the
		-- ratio then just reports the clamp, so flag it instead of letting a
		-- huge number imply a mismatch that was never measured.
		vMag < 0.1 and " | zeroVel=1 (vRatio is the clamp, not a real ratio)"
			-- vRatio near 1 means the velocity already explains this movement:
			-- that is a coast, not a teleport, and tagging it keeps the flight
			-- steps distinguishable from physics at a glance
			or (velocityRatio > 0.5 and velocityRatio < 2.0
				and " | physics-explained" or ""),
		formatPos(pos)
	))
end

local function sampleTransformStage(source, humanoid, root)
	if not transformCaptureEnabled or not root then return end
	local now = os.clock()
	-- keyed by source: a per-channel previous sample, so dt is a real frame delta
	-- for that channel and `src` means what it says
	local prev = transformStagePrevious[source]
	if not prev then
		transformStagePrevious[source] = {
			time = now, position = root.Position, velocity = root.AssemblyLinearVelocity,
		}
		return
	end
	maybeLogTransformJump(source, humanoid, root, now, prev.time, prev.position, prev.velocity)
	transformStagePrevious[source] = {
		time = now,
		position = root.Position,
		velocity = root.AssemblyLinearVelocity,
	}
end

local function sampleTransformProperty(source, humanoid, root)
	if not transformCaptureEnabled or not root then return end
	local now = os.clock()
	if not transformPropertyPrevious then
		transformPropertyPrevious = { time = now, position = root.Position, velocity = root.AssemblyLinearVelocity, cframe = root.CFrame }
		return
	end
	local prev = transformPropertyPrevious
	maybeLogTransformJump(source, humanoid, root, now, prev.time, prev.position, prev.velocity or root.AssemblyLinearVelocity)
	transformPropertyPrevious = {
		time = now,
		position = root.Position,
		velocity = root.AssemblyLinearVelocity,
		cframe = root.CFrame,
	}
end

-- ================================================================
-- FORENSICS LAYER (V8)
-- ================================================================
local ForensicsWorkspace = game:GetService("Workspace")

local function isGuardNamed(name)
	local n = string.lower(tostring(name))
	return string.find(n, "guard", 1, true) ~= nil
		or string.find(n, "bounds", 1, true) ~= nil
		or string.find(n, "collision", 1, true) ~= nil
end

local function pointInsidePart(part, pos)
	local ok, lp = pcall(function() return part.CFrame:PointToObjectSpace(pos) end)
	if not ok or not lp then return false end
	local ok2, size = pcall(function() return part.Size end)
	if not ok2 or not size then return false end
	return math.abs(lp.X) <= size.X / 2
		and math.abs(lp.Y) <= size.Y / 2
		and math.abs(lp.Z) <= size.Z / 2
end

local function partsAround(pos, radius)
	local char = player.Character
	local ok, list = pcall(function()
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char }
		return ForensicsWorkspace:GetPartBoundsInRadius(pos, radius, params)
	end)
	if ok and list then return list end
	return {}
end

-- How far is the ground below? nil means nothing within maxDistance.
-- safeFloor() reports FloorMaterial (a string), so it can never be used as a
-- height - the first version of the void check compared Y against that string
-- and was dead code. Measure the gap with a ray instead.
local function groundGap(pos, maxDistance)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local ok, hit = pcall(function()
		return ForensicsWorkspace:Raycast(pos - Vector3.new(0, 3, 0),
			Vector3.new(0, -1, 0) * maxDistance, params)
	end)
	if not ok or not hit then return nil, nil end
	return (hit.Distance or 0) + 3, hit.Instance
end

-- What is straight ahead? Straight-line, from the root, along the facing
-- direction - so "I am flying into something" is visible before the impact.
local function obstacleAhead(root, maxDistance)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	local ok, hit = pcall(function()
		return ForensicsWorkspace:Raycast(root.Position,
			root.CFrame.LookVector * maxDistance, params)
	end)
	if not ok then return "<raycast-error>" end
	if not hit then return string.format("clear for %.0f studs", maxDistance) end
	local inst = hit.Instance
	local name = inst and inst:GetFullName() or "?"
	return string.format("%s | class=%s | %.1f studs | collide=%s | material=%s%s",
		name, inst and inst.ClassName or "?", hit.Distance or -1,
		tostring(inst and inst.CanCollide), tostring(inst and inst.Material),
		isGuardNamed(name) and " | GUARD-NAMED" or "")
end

-- Name what is near a point. Guard-named parts are flagged: the guard volumes and
-- collision walls were the furniture around every failure so far, and they are
-- invisible in a position-only log.
local function logNearby(pos, radius, label)
	local seen, n = {}, 0
	for _, p in ipairs(partsAround(pos, radius)) do
		local name = p:GetFullName()
		if not seen[name] then
			seen[name] = true
			n += 1
			if n <= 10 then
				addLogEntry(string.format(
					"[%s] %s | %s | class=%s | dist=%.1f | collide=%s | material=%s%s",
					timestamp(), label, name, p.ClassName,
					(p.Position - pos).Magnitude, tostring(p.CanCollide),
					tostring(p.Material), isGuardNamed(name) and " | GUARD-NAMED" or ""))
			end
		end
	end
	return n
end

local function logDeath(reason, humanoid, root)
	local pos = root and root.Position
	local char = player.Character
	local parts, nocollide = 0, 0
	if char then parts, nocollide = countNoCollide(char) end
	addLogEntry(string.format("[%s] ================ DEATH ================", timestamp()))
	addLogEntry(string.format("[%s]   reason     | %s", timestamp(), reason))
	addLogEntry(string.format("[%s]   health     | %.1f / %.1f  %s",
		timestamp(), humanoid and humanoid.Health or -1, humanoid and humanoid.MaxHealth or -1,
		(humanoid and humanoid.Health <= EXPLOIT_HP) and "<-- EXPLOIT HANDLER, not damage" or ""))
	addLogEntry(string.format("[%s]   state      | %s | pos=(%s)", timestamp(),
		humanoid and safeState(humanoid) or "?", formatPos(pos)))
	addLogEntry(string.format("[%s]   phase      | %s | nc=%d/%d | floor=%s",
		timestamp(), activePhase, nocollide, parts, humanoid and safeFloor(humanoid) or "?"))
	if root then
		addLogEntry(string.format("[%s]   velocity   | (%s) | anchored=%s",
			timestamp(), formatVec3(root.AssemblyLinearVelocity), tostring(root.Anchored)))
	end
	if pos then logNearby(pos, NEAR_RADIUS, "  NEAR") end
	addLogEntry(string.format("[%s] =======================================", timestamp()))
end

-- A rig that has stretched is joints tearing, which is a different problem from
-- the character moving and would otherwise be invisible.
local function checkRigStretch(root)
	local char = player.Character
	if not char or not root then return end
	local torso = char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
	local head = char:FindFirstChild("Head")
	if not (torso and head) then return end
	local dT = (torso.Position - root.Position).Magnitude
	local dH = (head.Position - root.Position).Magnitude
	if not rigBaseline then
		rigBaseline = { t = dT, h = dH }
		return
	end
	local now = os.clock()
	local dt_, dh_ = math.abs(dT - rigBaseline.t), math.abs(dH - rigBaseline.h)
	if (dt_ > RIG_STRETCH_STUDS or dh_ > RIG_STRETCH_STUDS) and (now - lastRigWarn) > 0.5 then
		lastRigWarn = now
		addLogEntry(string.format(
			"[%s] RIG STRETCH | torso %+.1f | head %+.1f | limit %.1f | state=%s | pos=(%s)",
			timestamp(), dT - rigBaseline.t, dH - rigBaseline.h, RIG_STRETCH_STUDS,
			safeState(char:FindFirstChildOfClass("Humanoid")), formatPos(root.Position)))
	end
end

local function checkResting(root)
	local char = player.Character
	if not char then return end
	local inside = 0
	for _, p in ipairs(partsAround(root.Position, 8)) do
		if p.CanCollide and pointInsidePart(p, root.Position) then
			inside += 1
			addLogEntry(string.format("[%s] INSIDE SOLID | %s | class=%s | material=%s",
				timestamp(), p:GetFullName(), p.ClassName, tostring(p.Material)))
		end
	end
	if inside == 0 then
		addLogEntry(string.format("[%s] AT REST | clear of solid geometry | pos=(%s)",
			timestamp(), formatPos(root.Position)))
	end
end

local function onTouched(myPart, other)
	if not forensicsEnabled or not other then return end
	local now = os.clock()
	local name = other:GetFullName()
	local first = not lastTouchLogged[name]
	-- The floor we walk on fires Touched constantly, and logging every one of
	-- those would bury the log. Rule: any part is reported the FIRST time it is
	-- touched, and after that only if it is interesting (guard-named or
	-- non-collidable, i.e. a trigger volume), rate-limited by TOUCH_DEDUPE_S.
	if not (first or isGuardNamed(name) or not other.CanCollide) then
		lastTouchLogged[name] = now
		return
	end
	if not first and (now - lastTouchLogged[name]) < TOUCH_DEDUPE_S then return end
	lastTouchLogged[name] = now
	-- remember it: a burst that starts right after a touch can name the culprit
	lastTouchInfo = { name = name, time = now }
	addLogEntry(string.format(
		"[%s] TOUCHED | %s | class=%s | collide=%s | material=%s | my part=%s%s",
		timestamp(), name, other.ClassName, tostring(other.CanCollide),
		tostring(other.Material), myPart.Name,
		isGuardNamed(name) and " | GUARD-NAMED" or ""))
end

local function subscribeTouches(character)
	if touchConnection then
		for _, c in ipairs(touchConnection) do c:Disconnect() end
	end
	touchConnection = {}
	for _, p in ipairs(character:GetDescendants()) do
		if p:IsA("BasePart") then
			touchConnection[#touchConnection + 1] = p.Touched:Connect(function(other)
				onTouched(p, other)
			end)
		end
	end
	addLogEntry(string.format("[%s] TOUCH WATCH | %d parts subscribed",
		timestamp(), #touchConnection))
end

-- One tick, called from the same Heartbeat as the transform sampler.
local function forensicsTick(humanoid, root)
	if not forensicsEnabled or not root then return end
	local now = os.clock()
	local pos = root.Position
	local speed = root.AssemblyLinearVelocity.Magnitude

	-- A change of network ownership explains both a refused write and a
	-- rubberband, and it was never visible anywhere in the log.
	if (now - lastOwnerPoll) > OWNERSHIP_POLL_S then
		lastOwnerPoll = now
		local mine = (ownerName(root) == "you")
		if lastOwnerSeen == nil then
			lastOwnerSeen = mine
		elseif lastOwnerSeen ~= mine then
			lastOwnerSeen = mine
			addLogEntry(string.format(
				"[%s] OWNERSHIP | root is now %s | %s | phase=%s | pos=(%s)",
				timestamp(), mine and "client-owned (writes are authoritative)"
					or "SERVER-OWNED (writes are only requests)",
				ownershipLine(player.Character, root), activePhase, formatPos(pos)))
		end
	end

	-- ---- the burst ledger ------------------------------------------------
	-- A burst that simply STOPS produces no further steps, so nothing would ever
	-- close it. The tick is what turns it into a summary.
	if burst and (now - burst.lastStepAt) > BURST_GAP_S then
		closeBurst(now, "stopped")
	end

	-- ---- velocity changes with no position write --------------------------
	-- The post-flight push is exactly this: the character sat still, then a large
	-- horizontal velocity appeared and coasted it 140 studs. Nothing else in the
	-- log could show it, because every other line is triggered by a position.
	local vel = root.AssemblyLinearVelocity
	if lastVelSample then
		local dv = (vel - lastVelSample).Magnitude
		if dv >= VEL_JUMP_STUDS and (now - lastVelJumpAt) > 0.2 then
			lastVelJumpAt = now
			addLogEntry(string.format(
				"[%s] VELOCITY JUMP | (%s) -> (%s) | change %.1f studs/s | state=%s | pos=(%s)",
				timestamp(), formatVec3(lastVelSample), formatVec3(vel), dv,
				safeState(humanoid), formatPos(pos)))
			addLogEntry(string.format(
				"[%s]   grounded=%s | floor=%s | nc=%s | owner=%s%s",
				timestamp(), grounded(root), safeFloor(humanoid),
				player.Character and select(1, countNoCollide(player.Character)) or "?",
				ownerName(root),
				lastTouchInfo and string.format(" | lastTouch=%s (%.2fs ago)",
					lastTouchInfo.name, now - lastTouchInfo.time) or ""))
		end
	end
	lastVelSample = vel

	-- ---- the flight write ledger -----------------------------------------
	if flightTrace or lastWrite then
		checkWriteOutcome(humanoid, root, now)
		traceFrame(humanoid, root, now)
	end
	if flightTrace and (now - flightTrace.lastPhysicsAt) > PHYSICS_SAMPLE_S then
		flightTrace.lastPhysicsAt = now
		addLogEntry(string.format(
			"[%s] PHYSICS | t+%.2fs | %s | owner=%s | vel=(%s) | state=%s",
			timestamp(), now - flightTrace.startTime, physicsLine(), ownerName(root),
			formatVec3(root.AssemblyLinearVelocity), safeState(humanoid)))
	end

	-- ---- did the last big jump STICK? ----------------------------------
	evaluatePendingJump(humanoid, root, now)

	-- ---- net displacement while moving fast ------------------------------
	netSamples[#netSamples + 1] = { t = now, p = pos }
	while #netSamples > 1 and (now - netSamples[1].t) > NET_WINDOW_S do
		table.remove(netSamples, 1)
	end
	if speed >= NET_MIN_SPEED then lastFastAt = now; restChecked = false end
	if #netSamples > 1 and speed >= NET_MIN_SPEED and (now - lastNetLog) > 0.35 then
		lastNetLog = now
		local a, b = netSamples[1], netSamples[#netSamples]
		local d = b.p - a.p
		addLogEntry(string.format(
			"[%s] NET | %.2fs | dP=(%s) | net=%.1f | speed=%.1f | state=%s",
			timestamp(), b.t - a.t, formatVec3(d), d.Magnitude, speed, safeState(humanoid)))
	end

	-- ---- rig health, every tick ------------------------------------------
	-- joints tear WHILE moving, so this cannot wait for the next rest: it is
	-- rate-limited inside checkRigStretch instead
	checkRigStretch(root)

	-- ---- once we come to rest, check where we actually ended up ----------
	if not restChecked and speed < 5 and (now - lastFastAt) > 0.15 then
		restChecked = true
		checkResting(root)
	end

	-- ---- void proximity --------------------------------------------------
	-- One ray per second at most: this runs inside the Heartbeat.
	if (now - lastVoidWarn) > 1.0 then
		local gap, surface = groundGap(pos, VOID_WARN_STUDS + 50)
		if gap and gap > VOID_WARN_STUDS then
			lastVoidWarn = now
			addLogEntry(string.format(
				"[%s] VOID WARNING | ground %.1f studs below | limit %.1f | surface=%s",
				timestamp(), gap, VOID_WARN_STUDS,
				surface and surface:GetFullName() or "?"))
		elseif not gap then
			lastVoidWarn = now
			addLogEntry(string.format(
				"[%s] VOID WARNING | no ground within %.0f studs below | pos=(%s)",
				timestamp(), VOID_WARN_STUDS + 50, formatPos(pos)))
		end
	end
end

-- Did the last big jump actually hold? Called both from the tick and from the
-- sampler (before it arms a new jump).
--
-- TWO things undo a write, and until the 23:38 flight this verdict could not tell
-- them apart: the SERVER puts the character back along the ground, GRAVITY pulls
-- it down. The old test used one 3D number against `back`, so a flight that was
-- climbing along a path reported "REVERTED" every step when nothing was wrong but
-- the height - and a real server revert looked the same as the fall. The axis is
-- the whole answer, so it is measured and named now.
evaluatePendingJump = function(humanoid, root, now)
	if not pendingJump or not root then return end
	local age = now - pendingJump.time
	local here = root.Position
	local back = -(here - pendingJump.to):Dot(pendingJump.dir)
	local dxz = Vector3.new(here.X - pendingJump.to.X, 0, here.Z - pendingJump.to.Z).Magnitude
	local dy = pendingJump.to.Y - here.Y                 -- + = we are BELOW the write
	local nextStep = (pendingJump.to - pendingJump.from).Magnitude
	if dy > REVERT_MIN_STUDS and dxz <= REVERT_AXIS_STUDS then
		-- horizontal claim survived, height did not: the game's gravity, not the
		-- server. Nothing here is a signal about write acceptance - but a flight
		-- that never gets off the ground is worth saying out loud.
		revertStreak = 0
		local fall = 0.5 * workspace.Gravity * age * age
		addLogEntry(string.format(
			"[%s] SAGGED | %.0f studs below the write %.2fs after it | the height did not hold, the position did | gravity pulls %.0f studs in that time",
			timestamp(), dy, age, fall))
		addLogEntry(string.format(
			"[%s]   wrote (%s) | now (%s) | XZ still within %.1f studs - this is gravity, NOT a server revert",
			timestamp(), formatPos(pendingJump.to), formatPos(here), dxz))
		pendingJump = nil
	elseif back >= REVERT_MIN_STUDS and dxz > REVERT_AXIS_STUDS then
		revertStreak += 1
		addLogEntry(string.format(
			"[%s] REVERTED | %.0f studs back %.2fs after a +%.0f stud jump | HORIZONTAL - the server moved us",
			timestamp(), back, age, pendingJump.dist))
		addLogEntry(string.format(
			"[%s]   wrote to (%s) | now at (%s) | the write did NOT stick",
			timestamp(), formatPos(pendingJump.to), formatPos(here)))
		-- the streak is the thing that precedes the kill: 04:26 died after 15
		-- rejected writes, 23:38 died 0.06s after its 4th revert in a row
		addLogEntry(string.format(
			"[%s]   streak   | %d server revert(s) in a row%s",
			timestamp(), revertStreak,
			revertStreak >= DANGER_STREAK
				and " - THIS IS THE PATTERN THAT ENDS IN THE -1000" or ""))
		if revertStreak == DANGER_STREAK then
			addLogEntry(string.format(
				"[%s] DANGER   | %d straight server reverts - the -1000 has followed a streak like this. Stop writing and look at what the server is refusing.",
				timestamp(), revertStreak))
		end
		pendingJump = nil
	elseif age > REVERT_WINDOW_S then
		-- a step that held both axes clears the streak: the server was not refusing
		-- us, whatever the previous lines said
		if revertStreak > 0 then revertStreak = 0 end
		addLogEntry(string.format(
			"[%s] KEPT | +%.0f stud jump held for %.1fs | landed (%s) | speed=%.1f",
			timestamp(), pendingJump.dist, age, formatPos(pendingJump.to),
			root.AssemblyLinearVelocity.Magnitude))
		pendingJump = nil
	end
end

local function disconnectForensics()
	for _, conn in ipairs({deathConnection, anchoredConnection, autoRotateConnection}) do
		if conn then conn:Disconnect() end
	end
	deathConnection, anchoredConnection, autoRotateConnection = nil, nil, nil
	for _, conn in ipairs(propertyConnections) do
		if conn then conn:Disconnect() end
	end
	propertyConnections = {}
	burst, lastVelSample, lastTouchInfo = nil, nil, nil
	flightTrace, lastWrite = nil, nil
	if touchConnection then
		for _, c in ipairs(touchConnection) do c:Disconnect() end
		touchConnection = nil
	end
	pendingJump, lastTouchLogged = nil, {}
	netSamples, lastNetLog, lastFastAt, lastVoidWarn = {}, 0, 0, 0
	lastRigWarn, rigBaseline, restChecked = 0, nil, true
end

local function disconnectTelemetry()
	disconnectForensics()
	for _, conn in ipairs({connection, stateConnection, healthConnection, preSimulationConnection, postSimulationConnection, preRenderConnection, cframeConnection}) do
		if conn then conn:Disconnect() end
	end
	connection, stateConnection, healthConnection = nil, nil, nil
	preSimulationConnection, postSimulationConnection, preRenderConnection, cframeConnection = nil, nil, nil, nil
end

local function startTracking(character)
	disconnectTelemetry()
	local root = character:WaitForChild("HumanoidRootPart", 5)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not root or not humanoid then return end

	resetTransformTelemetry(root)

	connection = RunService.Heartbeat:Connect(function()
		if not root.Parent or not humanoid.Parent then return end
		sampleTransformStage("Heartbeat", humanoid, root)
		forensicsTick(humanoid, root)
		local speed = root.AssemblyLinearVelocity.Magnitude
		speedLabel.Text = string.format("%.1f studs/s", speed)
		posLabel.Text = "Pos: " .. formatPos(root.Position)
		stateLabel.Text = "State: " .. tostring(humanoid:GetState())
		phaseLabel.Text = string.format("Phase: %s | HP: %.1f", activePhase, humanoid.Health)
		if speed < 16 then speedLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
		elseif speed < 50 then speedLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
		elseif speed < 120 then speedLabel.TextColor3 = Color3.fromRGB(0, 200, 255)
		else speedLabel.TextColor3 = Color3.fromRGB(255, 80, 80) end
	end)

	preSimulationConnection = RunService.PreSimulation:Connect(function()
		if root.Parent and humanoid.Parent then sampleTransformStage("PreSimulation", humanoid, root) end
	end)
	postSimulationConnection = RunService.PostSimulation:Connect(function()
		if root.Parent and humanoid.Parent then sampleTransformStage("PostSimulation", humanoid, root) end
	end)
	if RunService.PreRender then
		preRenderConnection = RunService.PreRender:Connect(function()
			if root.Parent and humanoid.Parent then sampleTransformStage("PreRender", humanoid, root) end
		end)
	end
	cframeConnection = root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if root.Parent and humanoid.Parent then sampleTransformProperty("CFrameChanged", humanoid, root) end
	end)

	stateConnection = humanoid.StateChanged:Connect(function(old, new)
		if not root.Parent then return end
		local total, nc = countNoCollide(character)
		addLogEntry(string.format(
			"[%s] STATE | phase=%s | %s -> %s | speed=%.1f | pos=(%s) | hp=%.1f | floor=%s | nc=%d/%d",
			timestamp(), activePhase, tostring(old), tostring(new), root.AssemblyLinearVelocity.Magnitude,
			formatPos(root.Position), humanoid.Health, safeFloor(humanoid), nc, total
		))
	end)

	healthConnection = humanoid.HealthChanged:Connect(function(hp)
		-- A normal death arrives at 0. A large NEGATIVE value means something SET
		-- it, and -1000 specifically is the server's lethal exploit handler. This
		-- distinction cost a whole debugging session, because hp=0 and hp=-1000
		-- were reported the same way.
		local external = hp <= EXPLOIT_HP
		addLogEntry(string.format(
			"[%s] HEALTH | phase=%s | hp=%.1f/%.1f | %s | state=%s | pos=(%s)",
			timestamp(), activePhase, hp, humanoid.MaxHealth,
			external and "EXTERNAL KILL - health was SET, this is not damage"
				or "normal change",
			safeState(humanoid), formatPos(root.Position)))
		if external then
			logNearby(root.Position, NEAR_RADIUS, "  NEAR AT KILL")
		end
	end)

	-- AutoRotate=false is half of the known -1000 trigger. If anything sets it -
	-- this script, another script, or the server - the log should say so.
	autoRotateConnection = humanoid:GetPropertyChangedSignal("AutoRotate"):Connect(function()
		addLogEntry(string.format("[%s] AUTOROTATE | %s -> %s | phase=%s | state=%s",
			timestamp(), tostring(not humanoid.AutoRotate), tostring(humanoid.AutoRotate),
			activePhase, safeState(humanoid)))
	end)

	-- Properties that explain a flight and were never visible: an escape script
	-- sets these, and a change with no position write leaves no other trace.
	for _, item in ipairs({
		{ humanoid, "WalkSpeed" }, { humanoid, "JumpPower" }, { humanoid, "JumpHeight" },
		{ humanoid, "HipHeight" }, { humanoid, "PlatformStand" },
		{ root, "CanCollide" }, { root, "Massless" },
	}) do
		local inst, prop = item[1], item[2]
		if inst then
			propertyConnections[#propertyConnections + 1] =
				inst:GetPropertyChangedSignal(prop):Connect(function()
					local v = inst[prop]
					addLogEntry(string.format(
						"[%s] PROP | %s = %s | state=%s | phase=%s | pos=(%s)",
						timestamp(), prop,
						type(v) == "number" and string.format("%.1f", v) or tostring(v),
						safeState(humanoid), activePhase, formatPos(root.Position)))
				end)
		end
	end

	deathConnection = humanoid.Died:Connect(function()
		logDeath("Humanoid.Died fired", humanoid, root)
	end)

	-- being Anchored explains "I cannot move at all" and nothing else would show it
	anchoredConnection = root:GetPropertyChangedSignal("Anchored"):Connect(function()
		addLogEntry(string.format("[%s] ANCHORED | %s | pos=(%s)",
			timestamp(), tostring(root.Anchored), formatPos(root.Position)))
	end)

	subscribeTouches(character)

	addLogEntry(string.format(
		"[%s] SCANNER READY V13 | jumpMin=%.1f | pspeedMin=%.1f | ratioMin=%.1f | capture=%s | forensics=%s",
		timestamp(), TRANSFORM_JUMP_MIN_DISTANCE, TRANSFORM_JUMP_MIN_PSPEED,
		TRANSFORM_JUMP_RATIO, tostring(transformCaptureEnabled), tostring(forensicsEnabled)))
	addLogEntry(string.format(
		"[%s]   baseline | hp=%.1f/%.1f | floor=%s | state=%s | pos=(%s)",
		timestamp(), humanoid.Health, humanoid.MaxHealth, safeFloor(humanoid),
		safeState(humanoid), formatPos(root.Position)))
	addLogEntry(string.format(
		"[%s]   watches | bigJump=%.0f | revert=%.0f in %.1fs | rigStretch=%.1f | net=%.1fs @ %.0f+ studs/s",
		timestamp(), BIG_JUMP_STUDS, REVERT_MIN_STUDS, REVERT_WINDOW_S,
		RIG_STRETCH_STUDS, NET_WINDOW_S, NET_MIN_SPEED))
	addLogEntry(string.format(
		"[%s]   flightTrace=%s | frame=%.3fs (max %d) | writes are checked against the ask by %.1f studs",
		timestamp(), tostring(flightTraceEnabled), FLIGHT_FRAME_S, FLIGHT_FRAME_MAX,
		WRITE_CONFIRM_STUDS))
	addLogEntry(string.format(
		"[%s]   burst=%s | step>=%.0f | gap=%.2fs | velocity watch %.0f studs/s | walkSpeed/hipHeight/jump watched",
		timestamp(), tostring(burstEnabled), BURST_MIN_STEP, BURST_GAP_S, VEL_JUMP_STUDS))
	addLogEntry(string.format(
		"[%s]   stateCalls=%s | write=%s | staleSample=%.1fs (older than this is a gap, not a move)",
		timestamp(), tostring(stateCallsEnabled),
		pivotWriteEnabled and "PivotTo+CFrame" or "CFrame only", STALE_SAMPLE_S))
	addLogEntry(string.format("[%s]   profile=%s | measured profile: 25 steps, 5054 studs, 1.58s",
		timestamp(), profileMeasured and "MEASURED" or "ld-p3"))
end

-- ================================================================
-- BUTTONS
-- ================================================================
closeBtn.MouseButton1Click:Connect(function()
	disconnectTelemetry()
	safeUnbind()
	screenGui:Destroy()
end)

boostBtn.MouseButton1Click:Connect(function()
	task.spawn(function()
		local ok, err = xpcall(replicateFreefall, function(e)
			return tostring(e) .. "\n" .. debug.traceback()
		end)
		if not ok then
			addLogEntry(string.format("[%s] SCRIPT ERROR | %s", timestamp(), tostring(err)))
			feedback.Text = "SCRIPT ERROR"
			feedback.TextColor3 = Color3.fromRGB(255, 90, 90)
			feedback.Visible = true
		end
	end)
end)

copyBtn.MouseButton1Click:Connect(function()
	local success = pcall(function()
		setclipboard(table.concat(logEntries, "\n"))
	end)
	feedback.Text = success and "Log Copied!" or "Copy failed"
	feedback.TextColor3 = success and Color3.fromRGB(100, 255, 150) or Color3.fromRGB(255, 100, 100)
	feedback.Visible = true
	task.delay(1.8, function() if feedback and feedback.Parent then feedback.Visible = false end end)
end)

clearBtn.MouseButton1Click:Connect(function()
	clearLog()
	feedback.Text = "Log Cleared"
	feedback.TextColor3 = Color3.fromRGB(255, 180, 80)
	feedback.Visible = true
	task.delay(1.5, function() if feedback and feedback.Parent then feedback.Visible = false end end)
end)

-- MODE: the whole flight logic in one press.
modeBtn.MouseButton1Click:Connect(function()
	applyMode(modeIndex % #FLIGHT_MODES + 1, true)
	feedback.Text = FLIGHT_MODES[modeIndex].name
	feedback.TextColor3 = FLIGHT_MODES[modeIndex].stateCalls
		and Color3.fromRGB(255, 150, 120) or Color3.fromRGB(100, 255, 150)
	feedback.Visible = true
	task.delay(2.5, function() if feedback and feedback.Parent then feedback.Visible = false end end)
end)

-- DIAG: how loud the log is.
diagBtn.MouseButton1Click:Connect(function()
	applyDiag(diagIndex % #DIAG_MODES + 1, true)
	feedback.Text = "DIAG: " .. DIAG_MODES[diagIndex].name
	feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
	feedback.Visible = true
	task.delay(2, function() if feedback and feedback.Parent then feedback.Visible = false end end)
end)

-- DUMP: ownership + snapshot in one press, for the moment something feels wrong.
dumpBtn.MouseButton1Click:Connect(function()
	local char = player.Character
	local rt = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	-- ---- who owns me, and can we see the server? ----
	addLogEntry(string.format("[%s] ---- OWNERSHIP -------------------------", timestamp()))
	addLogEntry(string.format("[%s]   root      | %s", timestamp(), ownerName(rt)))
	addLogEntry(string.format("[%s]   character | %s", timestamp(), ownershipLine(char, rt)))
	addLogEntry(string.format("[%s]   root      | receiveAge=%s | grounded=%s | anchored=%s",
		timestamp(), receiveAge(rt), grounded(rt),
		rt and tostring(rt.Anchored) or "?"))
	addLogEntry(string.format("[%s]   physics   | %s", timestamp(), physicsLine()))

	-- ---- what is around us, is the rig stretched, are we inside anything ----
	if hum and rt then
		addLogEntry(string.format("[%s] ---- SNAPSHOT --------------------------", timestamp()))
		addLogEntry(string.format("[%s]   state=%s | hp=%.1f/%.1f | phase=%s | pos=(%s)",
			timestamp(), safeState(hum), hum.Health, hum.MaxHealth, activePhase, formatPos(rt.Position)))
		local gap, surface = groundGap(rt.Position, VOID_WARN_STUDS + 50)
		addLogEntry(string.format("[%s]   vel=(%s) | speed=%.1f | anchored=%s | floor=%s",
			timestamp(), formatVec3(rt.AssemblyLinearVelocity),
			rt.AssemblyLinearVelocity.Magnitude, tostring(rt.Anchored), safeFloor(hum)))
		addLogEntry(string.format("[%s]   ground below | %s | %s",
			timestamp(),
			gap and string.format("%.1f studs", gap) or "none within 100 studs",
			surface and surface:GetFullName() or "?"))
		addLogEntry(string.format("[%s]   ahead | %s", timestamp(),
			obstacleAhead(rt, OBSTACLE_AHEAD_STUDS)))
		logNearby(rt.Position, NEAR_RADIUS, "  SNAP NEAR")
		checkRigStretch(rt)
		checkResting(rt)
	end
	addLogEntry(string.format("[%s] ----------------------------------------", timestamp()))
	feedback.Text = "Ownership + snapshot logged"
	feedback.TextColor3 = Color3.fromRGB(100, 255, 150)
	feedback.Visible = true
	task.delay(1.5, function() if feedback and feedback.Parent then feedback.Visible = false end end)
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

-- Arm both dials from their defaults before anything can be pressed, so the
-- labels and the behaviour can never disagree.
applyMode(modeIndex, false)
applyDiag(diagIndex, false)

addLogEntry(string.format(
	"[%s] SCRIPT READY V13 | mode=%s | stateCalls=%s | write=%s | profile=%s | diag=%s",
	timestamp(), FLIGHT_MODES[modeIndex].name, tostring(stateCallsEnabled),
	pivotWriteEnabled and "PivotTo+CFrame" or "CFrame only",
	profileMeasured and "measured" or "ld-p3", DIAG_MODES[diagIndex].name))

player.CharacterAdded:Connect(startTracking)
if player.Character then
	startTracking(player.Character)
end