--[[
    EGG SNAPSHOT & EDGE-CASE SCANNER
    Purpose:
      1. Directly audits "RF/EggWorld/AskFieldEggSnapshot" to inspect returned data structure,
         records count, active biomes, and rare spawn metadata.
      2. Monitors & classifies edge cases in real-time:
         - "Night Reset": Standard 5-minute batch spawns (FieldEggBatchShifted).
         - "Admin Abuse Events": Mid-cycle egg spawns, admin alerts, and sudden rare waves.
         - Single Egg Shifts: Drop, Carry, and Despawn events.
      3. Verifies whether field eggs match the engine audit.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

if _G.EggSnapshotScanner_Cleanup then
    pcall(_G.EggSnapshotScanner_Cleanup)
end

local function getGuiParent()
    if typeof(gethui) == "function" then
        local ok, parent = pcall(gethui)
        if ok and parent then return parent end
    end
    return PlayerGui or CoreGui
end

local function getNetRemote(name)
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

local Remotes = {
    AskFieldEggSnapshot = getNetRemote("RF/EggWorld/AskFieldEggSnapshot"),
    FieldEggBatchShifted = getNetRemote("RE/EggWorld/FieldEggBatchShifted"),
    FieldEggRaritiesShown = getNetRemote("RE/EggWorld/FieldEggRaritiesShown"),
    FieldEggShifted = getNetRemote("RE/EggWorld/FieldEggShifted"),
    FieldEggGone = getNetRemote("RE/EggWorld/FieldEggGone"),
    FieldEggCycleCountdown = getNetRemote("RE/EggWorld/FieldEggCycleCountdown"),
    AlertsRaise = getNetRemote("RE/Alerts/Raise"),
    BroadcastsRaiseNotice = getNetRemote("RE/Broadcasts/RaiseNotice"),
    LiveEventsBegan = getNetRemote("RE/LiveEvents/Began"),
}

local state = {
    alive = true,
    liveMonitoring = true,
    connections = {},
    lastNightResetTime = nil,
    totalNightResets = 0,
    totalAdminEvents = 0,
    trackedEggsCount = 0,
    lastSnapshotTime = 0,
}

local logLines = {}
local MAX_LOG_LINES = 250

local function dumpTableCompact(t)
    if type(t) ~= "table" then return tostring(t) end
    local parts = {}
    for k, v in pairs(t) do
        local vs = type(v) == "table" and dumpTableCompact(v) or tostring(v)
        table.insert(parts, string.format("%s=%s", tostring(k), vs))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function appendLog(text)
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] %s", timestamp, tostring(text))
    table.insert(logLines, line)
    if #logLines > MAX_LOG_LINES then
        table.remove(logLines, 1)
    end
    print("[EggSnapshotScanner] " .. tostring(text))
end

-- ============================================================
-- 1. SNAPSHOT AUDIT FUNCTION
-- ============================================================

local function auditFieldSnapshot()
    appendLog("==================================================")
    appendLog(">>> AUDITING RF/EggWorld/AskFieldEggSnapshot...")

    local rf = Remotes.AskFieldEggSnapshot
    if not rf or not rf:IsA("RemoteFunction") then
        appendLog("[-] ERROR: RF/EggWorld/AskFieldEggSnapshot was not found in ReplicatedStorage!")
        return
    end

    local t0 = os.clock()
    local ok, res = pcall(function()
        return rf:InvokeServer()
    end)
    local latencyMs = (os.clock() - t0) * 1000.0

    if not ok then
        appendLog("[-] InvokeServer failed: " .. tostring(res))
        return
    end

    if type(res) ~= "table" then
        appendLog("[-] Unexpected return type: " .. typeof(res) .. " (expected Table)")
        return
    end

    state.lastSnapshotTime = os.clock()
    appendLog(string.format("[+] AskFieldEggSnapshot responded in %.1f ms", latencyMs))

    -- Check top-level keys
    local topKeys = {}
    for k in pairs(res) do table.insert(topKeys, tostring(k)) end
    table.sort(topKeys)
    appendLog("Top-Level Return Keys: { " .. table.concat(topKeys, ", ") .. " }")

    local records = res.Records
    local rareSpawns = res.RareSpawns

    -- Audit RareSpawns
    if type(rareSpawns) == "table" then
        local rareCount = 0
        local sampleRares = {}
        for uid, rId in pairs(rareSpawns) do
            rareCount = rareCount + 1
            if type(rId) == "table" and rId.EggUid and rId.RarityId then
                if rareCount <= 5 then
                    table.insert(sampleRares, string.format("%s = %s", tostring(rId.EggUid):sub(1, 8), tostring(rId.RarityId)))
                end
            elseif type(uid) == "string" and type(rId) == "string" then
                if rareCount <= 5 then
                    table.insert(sampleRares, string.format("%s = %s", uid:sub(1, 8), rId))
                end
            end
        end
        appendLog(string.format("  RareSpawns Count: %d | Samples: [ %s ]", rareCount, table.concat(sampleRares, ", ")))
    else
        appendLog("  RareSpawns: none or not a table")
    end

    -- Audit Records
    if type(records) ~= "table" then
        appendLog("[-] 'Records' key is missing or not a table!")
        return
    end

    local totalRecords = 0
    local stateCounts = { Slot = 0, Dropped = 0, Carried = 0, Claimed = 0, Other = 0 }
    local biomeCounts = {}
    local sampleRecords = {}

    for _, r in pairs(records) do
        if type(r) == "table" then
            totalRecords = totalRecords + 1
            local st = tostring(r.State or "Other")
            stateCounts[st] = (stateCounts[st] or 0) + 1

            local biome = tostring(r.AreaId or "Unknown")
            biomeCounts[biome] = (biomeCounts[biome] or 0) + 1

            if #sampleRecords < 3 then
                table.insert(sampleRecords, r)
            end
        end
    end

    state.trackedEggsCount = totalRecords
    appendLog(string.format("  Total Active Records: %d", totalRecords))
    appendLog(string.format("  States: Nest/Slot=%d, Dropped=%d, Carried=%d, Claimed=%d",
        stateCounts.Slot or 0, stateCounts.Dropped or 0, stateCounts.Carried or 0, stateCounts.Claimed or 0))

    -- Biome breakdown
    local biomeParts = {}
    for bName, bCount in pairs(biomeCounts) do
        table.insert(biomeParts, string.format("%s:%d", bName, bCount))
    end
    table.sort(biomeParts)
    appendLog("  Biomes: " .. table.concat(biomeParts, " | "))

    -- Sample Records Deep Inspection
    appendLog("  --- Sample Records (First 3) ---")
    for i, sr in ipairs(sampleRecords) do
        local uid = tostring(sr.Uid or sr.EggUid or "N/A")
        local cat = tostring(sr.AssetCategory or sr.DisplayName or sr.Name or "N/A")
        local area = tostring(sr.AreaId or "N/A")
        local st = tostring(sr.State or "N/A")
        local cf = sr.BoundsCFrame or sr.BottomCFrame
        local posStr = "nil"
        if typeof(cf) == "CFrame" or typeof(cf) == "Vector3" then
            local p = cf.Position or cf
            posStr = string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
        elseif type(cf) == "table" and cf.X and cf.Y and cf.Z then
            posStr = string.format("(%.1f, %.1f, %.1f)", cf.X, cf.Y, cf.Z)
        end
        local muts = type(sr.Mutations) == "table" and (#sr.Mutations > 0 and table.concat(sr.Mutations, ",") or "none") or "none"
        appendLog(string.format("    [%d] UID: %s... | Category: %s | Area: %s | State: %s | Pos: %s | Mutations: %s",
            i, uid:sub(1, 10), cat, area, st, posStr, muts))
    end

    appendLog("==================================================")
end

-- ============================================================
-- 2. EDGE CASES MONITOR (NIGHT RESET VS ADMIN ABUSE)
-- ============================================================

local function startEdgeCaseMonitor()
    for _, c in ipairs(state.connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(state.connections)

    appendLog("[EdgeCaseMonitor] Listening for Night Resets, Admin Abuse Events, & Wave Spawns...")

    -- A. Batch Spawn Event (FieldEggBatchShifted)
    if Remotes.FieldEggBatchShifted and Remotes.FieldEggBatchShifted:IsA("RemoteEvent") then
        local conn = Remotes.FieldEggBatchShifted.OnClientEvent:Connect(function(batch)
            if not state.alive or not state.liveMonitoring then return end
            local now = os.clock()
            local batchCount = type(batch) == "table" and #batch or 0
            if batchCount == 0 and type(batch) == "table" then
                for _ in pairs(batch) do batchCount = batchCount + 1 end
            end

            local timeSinceLast = state.lastNightResetTime and (now - state.lastNightResetTime) or nil
            local isStandardNightReset = false

            -- Standard Night Reset runs on a 5-minute (300s) cycle with 50+ eggs
            if timeSinceLast == nil or (timeSinceLast >= 270 and timeSinceLast <= 330) or batchCount >= 50 then
                isStandardNightReset = true
            end

            if isStandardNightReset then
                state.totalNightResets = state.totalNightResets + 1
                state.lastNightResetTime = now
                local cycleInfo = timeSinceLast and string.format(" (after %.1fs / 5m cycle)", timeSinceLast) or " (initial / first detected)"
                appendLog(string.format("🌙 [NIGHT RESET #%d] Full batch spawn detected via FieldEggBatchShifted! Eggs spawned: %d%s",
                    state.totalNightResets, batchCount, cycleInfo))
            else
                -- MID-CYCLE SPAWN: Admin Abuse Event or sudden wave!
                state.totalAdminEvents = state.totalAdminEvents + 1
                local elapsedStr = timeSinceLast and string.format("%.1fs into the current cycle (MID-CYCLE SPAWN!)", timeSinceLast) or "mid-cycle"
                appendLog(string.format("🚨 [ADMIN ABUSE / SPECIAL SPAWN #%d] Batch of %d egg(s) spawned %s!",
                    state.totalAdminEvents, batchCount, elapsedStr))
            end
        end)
        table.insert(state.connections, conn)
    end

    -- B. Rarities Shown Event (Admin Spawns or Rare Egg Announcements)
    if Remotes.FieldEggRaritiesShown and Remotes.FieldEggRaritiesShown:IsA("RemoteEvent") then
        local conn = Remotes.FieldEggRaritiesShown.OnClientEvent:Connect(function(payload)
            if not state.alive or not state.liveMonitoring then return end
            local now = os.clock()
            local timeSinceLast = state.lastNightResetTime and (now - state.lastNightResetTime) or nil
            local elapsedStr = timeSinceLast and string.format(" [%.1fs after last reset]", timeSinceLast) or ""

            local items = {}
            if type(payload) == "table" and type(payload.RareSpawns) == "table" then
                for _, r in pairs(payload.RareSpawns) do
                    if type(r) == "table" and r.EggUid and r.RarityId then
                        table.insert(items, string.format("%s: %s", tostring(r.RarityId), tostring(r.EggUid):sub(1, 8)))
                    end
                end
            end

            local details = #items > 0 and table.concat(items, ", ") or "payload received"
            appendLog(string.format("✨ [RARE / ADMIN SPAWN ALERT] FieldEggRaritiesShown%s -> %s", elapsedStr, details))
        end)
        table.insert(state.connections, conn)
    end

    -- C. Single Egg State Shifted & Burst Wave Detector
    local shiftBurstCount = 0
    local burstFlushThread = nil

    local function flushBurst()
        if not state.alive or not state.liveMonitoring then return end
        if shiftBurstCount >= 25 then
            local now = os.clock()
            local timeSinceReset = state.lastNightResetTime and (now - state.lastNightResetTime) or nil
            if timeSinceReset == nil or timeSinceReset >= 270 then
                state.totalNightResets = state.totalNightResets + 1
                state.lastNightResetTime = now
                appendLog(string.format("🌙 [NIGHT RESET #%d] Mass wave of %d eggs refreshed across biomes (5m cycle)!",
                    state.totalNightResets, shiftBurstCount))
            else
                state.totalAdminEvents = state.totalAdminEvents + 1
                appendLog(string.format("🚨 [ADMIN ABUSE / SPECIAL WAVE #%d] Mass wave of %d eggs spawned mid-cycle (%.1fs into cycle)!",
                    state.totalAdminEvents, shiftBurstCount, timeSinceReset))
            end
        end
        shiftBurstCount = 0
        burstFlushThread = nil
    end

    if Remotes.FieldEggShifted and Remotes.FieldEggShifted:IsA("RemoteEvent") then
        local conn = Remotes.FieldEggShifted.OnClientEvent:Connect(function(payload)
            if not state.alive or not state.liveMonitoring then return end
            shiftBurstCount = shiftBurstCount + 1
            if burstFlushThread then
                pcall(function() task.cancel(burstFlushThread) end)
            end
            burstFlushThread = task.delay(1.2, flushBurst)

            if type(payload) == "table" then
                local uid = tostring(payload.Uid or payload.EggUid or "N/A"):sub(1, 8)
                local st = tostring(payload.State or "Shifted")
                local carrier = payload.CarrierUserId and (" Carrier=" .. tostring(payload.CarrierUserId)) or ""
                local area = payload.AreaId and (" Area=" .. tostring(payload.AreaId)) or ""
                appendLog(string.format("⚡ [EGG SHIFTED] Uid=%s... -> State=%s%s%s", uid, st, carrier, area))
            end
        end)
        table.insert(state.connections, conn)
    end

    -- D. Egg Despawn Event (Cycle expiry)
    if Remotes.FieldEggGone and Remotes.FieldEggGone:IsA("RemoteEvent") then
        local conn = Remotes.FieldEggGone.OnClientEvent:Connect(function(payload)
            if not state.alive or not state.liveMonitoring then return end
            local uid = type(payload) == "table" and tostring(payload.Uid or payload.EggUid or "") or tostring(payload or "")
            appendLog(string.format("💨 [EGG GONE / DESPAWN] Uid: %s...", uid:sub(1, 8)))
        end)
        table.insert(state.connections, conn)
    end

    -- E. Admin Broadcast / Live Events Alert (Formatted)
    if Remotes.BroadcastsRaiseNotice and Remotes.BroadcastsRaiseNotice:IsA("RemoteEvent") then
        local conn = Remotes.BroadcastsRaiseNotice.OnClientEvent:Connect(function(msg)
            if not state.alive or not state.liveMonitoring then return end
            appendLog(string.format("📢 [BROADCAST NOTICE] %s", dumpTableCompact(msg)))
        end)
        table.insert(state.connections, conn)
    end

    if Remotes.AlertsRaise and Remotes.AlertsRaise:IsA("RemoteEvent") then
        local conn = Remotes.AlertsRaise.OnClientEvent:Connect(function(msg)
            if not state.alive or not state.liveMonitoring then return end
            appendLog(string.format("⚠️ [ALERT RAISED] %s", dumpTableCompact(msg)))
        end)
        table.insert(state.connections, conn)
    end
end

-- ============================================================
-- 3. USER INTERFACE
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggSnapshotScannerUI"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = getGuiParent()

local W, H = 550, 460
local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(W, H)
frame.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
frame.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(75, 155, 245)
stroke.Thickness = 1.5

-- Title Bar
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = Color3.fromRGB(26, 36, 54)
topBar.BorderSizePixel = 0
topBar.Parent = frame
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -70, 1, 0)
titleLbl.Position = UDim2.fromOffset(12, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "📡 EGG SNAPSHOT & EDGE-CASE SCANNER"
titleLbl.TextColor3 = Color3.fromRGB(235, 245, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 12
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(26, 26)
closeBtn.Position = UDim2.new(1, -32, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 45)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- Dragging
do
    local dragging, dragStart, startPos = false, nil, nil
    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- Button Bar
local btnContainer = Instance.new("Frame")
btnContainer.Size = UDim2.new(1, -20, 0, 32)
btnContainer.Position = UDim2.fromOffset(10, 42)
btnContainer.BackgroundTransparency = 1
btnContainer.Parent = frame

local function createButton(text, xOffset, width, color, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(width, 30)
    btn.Position = UDim2.fromOffset(xOffset, 0)
    btn.BackgroundColor3 = color
    btn.Text = text
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.Parent = btnContainer
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    btn.MouseButton1Click:Connect(callback)
    return btn
end

-- Log Box
local logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -20, 1, -125)
logScroll.Position = UDim2.fromOffset(10, 80)
logScroll.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 6
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.Parent = frame
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 6)

local logText = Instance.new("TextLabel")
logText.Size = UDim2.new(1, -12, 0, 0)
logText.Position = UDim2.fromOffset(6, 6)
logText.BackgroundTransparency = 1
logText.TextColor3 = Color3.fromRGB(205, 240, 220)
logText.Font = Enum.Font.Code
logText.TextSize = 11
logText.TextXAlignment = Enum.TextXAlignment.Left
logText.TextYAlignment = Enum.TextYAlignment.Top
logText.TextWrapped = true
logText.Parent = logScroll

local function updateLogUI()
    local fullText = table.concat(logLines, "\n")
    logText.Text = fullText
    local estHeight = math.max(300, #logLines * 16 + 20)
    logText.Size = UDim2.new(1, -12, 0, estHeight)
    logScroll.CanvasSize = UDim2.new(0, 0, 0, estHeight + 10)
    logScroll.CanvasPosition = Vector2.new(0, estHeight)
end

local logDirty = false
local oldAppend = appendLog
appendLog = function(t)
    oldAppend(t)
    logDirty = true
end

RunService.Heartbeat:Connect(function()
    if logDirty and state.alive then
        logDirty = false
        updateLogUI()
    end
end)

-- Buttons
createButton("🔍 AUDIT SNAPSHOT", 0, 150, Color3.fromRGB(35, 130, 75), function()
    task.spawn(auditFieldSnapshot)
end)

local liveToggleBtn
liveToggleBtn = createButton("● LIVE EVENTS: ON", 158, 150, Color3.fromRGB(50, 105, 195), function()
    state.liveMonitoring = not state.liveMonitoring
    if state.liveMonitoring then
        liveToggleBtn.Text = "● LIVE EVENTS: ON"
        liveToggleBtn.BackgroundColor3 = Color3.fromRGB(50, 105, 195)
        appendLog("[UI] Live event monitoring resumed.")
    else
        liveToggleBtn.Text = "○ LIVE EVENTS: OFF"
        liveToggleBtn.BackgroundColor3 = Color3.fromRGB(90, 90, 110)
        appendLog("[UI] Live event monitoring paused.")
    end
end)

createButton("📋 COPY LOG", 316, 95, Color3.fromRGB(115, 80, 165), function()
    local full = table.concat(logLines, "\n")
    local copied = false
    if typeof(setclipboard) == "function" then
        copied = pcall(setclipboard, full)
    elseif typeof(toclipboard) == "function" then
        copied = pcall(toclipboard, full)
    end
    if copied then
        appendLog("[UI] Full log copied to clipboard successfully!")
    else
        appendLog("[UI] Clipboard API unavailable.")
    end
end)

createButton("🗑 CLEAR", 419, 90, Color3.fromRGB(80, 80, 90), function()
    table.clear(logLines)
    appendLog("Log cleared.")
    updateLogUI()
end)

-- Status bar at bottom
local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1, -20, 0, 24)
statusLbl.Position = UDim2.new(0, 10, 1, -34)
statusLbl.BackgroundTransparency = 1
statusLbl.Text = "Status: Initializing..."
statusLbl.TextColor3 = Color3.fromRGB(160, 200, 240)
statusLbl.Font = Enum.Font.Gotham
statusLbl.TextSize = 10
statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.Parent = frame

task.spawn(function()
    while state.alive do
        task.wait(1.0)
        if not state.alive then break end
        local resetStr = "None yet"
        if state.lastNightResetTime then
            local sec = math.floor(os.clock() - state.lastNightResetTime)
            resetStr = string.format("%dm %02ds ago", math.floor(sec/60), sec%60)
        end
        statusLbl.Text = string.format("Night Resets: %d (Last: %s) | Admin Events: %d | Tracked Field Eggs: %d",
            state.totalNightResets, resetStr, state.totalAdminEvents, state.trackedEggsCount)
    end
end)

-- Cleanup
local function cleanup()
    state.alive = false
    state.liveMonitoring = false
    for _, c in ipairs(state.connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(state.connections)
    _G.EggSnapshotScanner_Cleanup = nil
    if screenGui and screenGui.Parent then
        pcall(function() screenGui:Destroy() end)
    end
end
_G.EggSnapshotScanner_Cleanup = cleanup
closeBtn.MouseButton1Click:Connect(cleanup)

-- Launch
appendLog("Egg Snapshot & Edge-Case Scanner initialized.")
task.spawn(function()
    task.wait(0.1)
    auditFieldSnapshot()
    startEdgeCaseMonitor()
end)
