--[[
    ================================================================================
    AUTO HATCH EGG AUTOMATION & DIAGNOSTIC TEST SUITE
    ================================================================================
    Standalone Automation & Diagnostic Tool for "Steal an Egg" (Roblox)
    Specifically created to test and verify the Auto Hatch feature before
    integrating it below Auto Pen in EggGoToUI_v10.lua.

    Target Remote:
      InvokeServer -> ReplicatedStorage.Packages.Networking.RF/EggWorld/AskHatch
      Arguments:
        [1] = "<EggUid>" (e.g. "195552ae54d5418bb16ac9265c445b83")

    Auxiliary Remotes & Fallbacks:
      - RF/EggWorld/AskFinishHatch: Complete hatch sequence / claim pet
      - RF/EggWorld/AskSkipGrowth: Skip growth if available
      - RF/ProfileMirror/FetchProfile: Authoritative inventory & placed eggs state
      - ProximityPrompt trigger fallback via fireproximityprompt

    Features:
      1. Placed Egg Discovery Engine:
         - Inspects Workspace.PlacedEggRenders for player-owned placed eggs (<UserId>_<EggUid>).
         - Inspects RF/ProfileMirror/FetchProfile(LocalPlayer).EggInventory (Placement ~= nil).
         - Extracts UID, Species/Category, Weight, Hatch timer, and ProximityPrompts.
      2. Direct Hatch Invocation:
         - Fires RF/EggWorld/AskHatch with exact UID parameter.
         - Captures and displays server return values, success/failure status, and latency.
      3. Hatch All Placed Eggs:
         - Rapidly or sequentially triggers AskHatch for all eggs residing in player's pen.
      4. Autonomous Background Auto Hatch Loop:
         - Continuously monitors placed eggs and triggers AskHatch as soon as eggs are ready.
         - Intelligent backoff/cooldown tracker to prevent remote throttling on non-ready eggs.
      5. Pen Navigation (Optional Walk):
         - Resolves Pen position and smoothly walks character to pen if proximity is required.
      6. Dedicated Modern HUD:
         - Draggable window, live state metrics, customizable UID input box,
           diagnostic log console with auto-scroll and clipboard copy.

    NOTE: EggGoToUI_v10.lua is NOT modified. This script is fully standalone.
    ================================================================================
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ================================================================================
-- CONFIGURATION & DEFAULTS
-- ================================================================================
local CONFIG = {
    TargetUid           = "195552ae54d5418bb16ac9265c445b83", -- Sample UID provided by user
    AutoHatch           = false,                               -- Continuous auto-hatch toggle
    ScanInterval        = 2.0,                                 -- Seconds between auto-hatch scans
    HatchBatchDelay     = 0.35,                                -- Seconds between hatching individual eggs in batch
    CallFinishHatch     = true,                                -- Whether to call AskFinishHatch after AskHatch
    WalkToPenBeforeHatch= false,                               -- Walk to pen before triggering hatch
    SafeZoneFallback    = Vector3.new(534.090, 70.724, -326.616),
}

-- Runtime State
local State = {
    IsRunning           = false,
    IsBusy              = false,
    CurrentPhase        = "Idle",
    PlacedEggs          = {},
    LastScanTime        = 0,
    TotalHatched        = 0,
    PenPosition         = nil,
    MyPlot              = nil,
    MyPlotIndex         = nil,
    HatchCooldowns      = {}, -- [uid] = timestamp of last attempt to avoid spamming
    LoopThread          = nil,
}

-- ================================================================================
-- NETWORKING HELPERS
-- ================================================================================
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
    AskHatch            = getNetRemote("RF/EggWorld/AskHatch"),
    AskFinishHatch      = getNetRemote("RF/EggWorld/AskFinishHatch"),
    AskSkipGrowth       = getNetRemote("RF/EggWorld/AskSkipGrowth"),
    FetchProfile        = getNetRemote("RF/ProfileMirror/FetchProfile"),
    AskLiveSnapshot     = getNetRemote("RF/EggWorld/AskLiveSnapshot"),
}

local function refreshRemotes()
    local mapping = {
        AskHatch        = "RF/EggWorld/AskHatch",
        AskFinishHatch  = "RF/EggWorld/AskFinishHatch",
        AskSkipGrowth   = "RF/EggWorld/AskSkipGrowth",
        FetchProfile    = "RF/ProfileMirror/FetchProfile",
        AskLiveSnapshot = "RF/EggWorld/AskLiveSnapshot",
    }
    for k, fullName in pairs(mapping) do
        if not Remotes[k] then
            Remotes[k] = getNetRemote(fullName)
        end
    end
end

-- ================================================================================
-- LOGGING PIPELINE
-- ================================================================================
local logEntries = {}
local logCallback = nil

local function logMsg(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    local timestamp = os.date("%H:%M:%S")
    local formatted = string.format("[%s] %s", timestamp, msg)
    table.insert(logEntries, formatted)
    if #logEntries > 120 then
        table.remove(logEntries, 1)
    end
    print("[AutoHatchTest] " .. msg)
    if logCallback then
        pcall(logCallback, formatted)
    end
end

-- ================================================================================
-- LOCAL PLAYER & MOVEMENT UTILITIES
-- ================================================================================
local function getCharParts()
    local char = LocalPlayer.Character
    if not char then return nil, nil, nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    return char, root, hum
end

local function distXZ(a, b)
    if not a or not b then return math.huge end
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- Pure walk navigation toward target
local function moveToPosition(targetPos, arrivalDist, cancelCheck)
    arrivalDist = arrivalDist or 3.0
    local char, root, hum = getCharParts()
    if not char or not root or not hum then return false end

    local startTime = os.clock()
    local timeout = 45.0

    while (os.clock() - startTime) < timeout do
        if cancelCheck and cancelCheck() then
            pcall(function() hum:Move(Vector3.zero) end)
            return false
        end
        if not LocalPlayer.Character or not root.Parent or hum.Health <= 0 then break end

        local curPos = root.Position
        local xz = distXZ(curPos, targetPos)
        if xz <= arrivalDist then
            pcall(function() hum:Move(Vector3.zero) end)
            return true
        end

        local dir = Vector3.new(targetPos.X - curPos.X, 0, targetPos.Z - curPos.Z)
        if dir.Magnitude > 0.1 then
            hum:Move(dir.Unit, false)
            hum:MoveTo(targetPos)
        end

        task.wait(0.08)
    end

    pcall(function() hum:Move(Vector3.zero) end)
    return distXZ(root.Position, targetPos) <= arrivalDist
end

-- ================================================================================
-- PEN & PLOT DISCOVERY
-- ================================================================================
local function findMyPlot()
    local plotsFolder = Workspace:FindFirstChild("Plots") or Workspace:FindFirstChild("Bases")
    if not plotsFolder then return nil, nil end

    local myIdStr = tostring(LocalPlayer.UserId)
    local myName  = string.lower(LocalPlayer.Name)

    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local pAttrs = plot:GetAttributes()
        local ownerAttr = pAttrs.Owner or pAttrs.OwnerId or pAttrs.Player or pAttrs.UserId or pAttrs.ClaimedBy
        if ownerAttr then
            local strOwner = tostring(ownerAttr):lower()
            if strOwner == myIdStr or strOwner == myName then
                local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                State.MyPlot = plot
                State.MyPlotIndex = idx
                return plot, idx
            end
        end
    end

    for _, plot in ipairs(plotsFolder:GetChildren()) do
        for _, desc in ipairs(plot:GetDescendants()) do
            if desc:IsA("TextLabel") or desc:IsA("SurfaceGui") then
                local txt = desc:IsA("TextLabel") and desc.Text:lower() or ""
                if string.find(txt, myName, 1, true) or string.find(txt, string.lower(LocalPlayer.DisplayName), 1, true) then
                    local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                    State.MyPlot = plot
                    State.MyPlotIndex = idx
                    return plot, idx
                end
            end
        end
    end

    return nil, nil
end

local function findMyPen()
    -- 1. Try finding pen position from existing PlacedEggRenders for this player
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    if placedRenders then
        local myPrefix = tostring(LocalPlayer.UserId) .. "_"
        local eggPositions = {}
        for _, egg in ipairs(placedRenders:GetChildren()) do
            if string.find(egg.Name, myPrefix, 1, true) then
                local p = nil
                if egg:IsA("BasePart") then p = egg.Position
                elseif egg:IsA("Model") then
                    local ok, piv = pcall(function() return egg:GetPivot().Position end)
                    p = ok and piv or (egg.PrimaryPart and egg.PrimaryPart.Position)
                end
                if p then table.insert(eggPositions, p) end
            end
        end
        if #eggPositions > 0 then
            local avgX, avgY, avgZ = 0, 0, 0
            for _, pos in ipairs(eggPositions) do
                avgX = avgX + pos.X
                avgY = avgY + pos.Y
                avgZ = avgZ + pos.Z
            end
            local center = Vector3.new(avgX / #eggPositions, avgY / #eggPositions, avgZ / #eggPositions)
            State.PenPosition = center
            return center
        end
    end

    -- 2. Try finding Pen / Nest / Incubator within MyPlot
    local plot = State.MyPlot or findMyPlot()
    if plot then
        for _, desc in ipairs(plot:GetDescendants()) do
            local low = string.lower(desc.Name)
            if (low:find("pen") or low:find("nest") or low:find("incubator") or low:find("eggspot") or low:find("delivery"))
               and desc:IsA("BasePart") then
                State.PenPosition = desc.Position
                return desc.Position
            end
        end
        local ok, piv = pcall(function() return plot:GetPivot().Position end)
        if ok and piv then
            State.PenPosition = piv
            return piv
        end
    end

    State.PenPosition = CONFIG.SafeZoneFallback
    return CONFIG.SafeZoneFallback
end

-- ================================================================================
-- PLACED EGG DISCOVERY & INSPECTION ENGINE
-- ================================================================================
local function scanPlacedEggs()
    refreshRemotes()
    local placed = {}
    local seenUids = {}
    local myUserId = tostring(LocalPlayer.UserId)
    local myPrefix = myUserId .. "_"

    -- Source A: Workspace.PlacedEggRenders (Physical visual render models in Pen)
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    if placedRenders then
        for _, eggInst in ipairs(placedRenders:GetChildren()) do
            if string.find(eggInst.Name, myPrefix, 1, true) then
                local rawUid = string.gsub(eggInst.Name, "^" .. myPrefix, "")
                if rawUid and rawUid ~= "" and not seenUids[rawUid] then
                    seenUids[rawUid] = true

                    -- Inspect child ProximityPrompt if present
                    local prompt = nil
                    for _, d in ipairs(eggInst:GetDescendants()) do
                        if d:IsA("ProximityPrompt") then
                            prompt = d
                            break
                        end
                    end

                    -- Inspect billboard/timer text if present
                    local statusText = ""
                    for _, d in ipairs(eggInst:GetDescendants()) do
                        if d:IsA("TextLabel") and d.Text ~= "" then
                            local low = d.Text:lower()
                            if low:find("ready") or low:find("hatch") or low:find("s") or low:find("m") or low:find("%d") then
                                statusText = d.Text
                                break
                            end
                        end
                    end

                    -- Check attributes
                    local attrs = eggInst:GetAttributes()
                    local cat = attrs.AssetCategory or attrs.Species or attrs.Category or attrs.Name or "PlacedEgg"
                    local isReady = attrs.Ready == true or attrs.Hatchable == true or (statusText:lower():find("ready") ~= nil)

                    table.insert(placed, {
                        Uid             = rawUid,
                        DisplayName     = tostring(cat),
                        Category        = tostring(cat),
                        Source          = "PlacedEggRenders",
                        Instance        = eggInst,
                        Prompt          = prompt,
                        StatusText      = statusText,
                        IsReady         = isReady,
                        Attributes      = attrs,
                    })
                end
            end
        end
    end

    -- Source B: RF/ProfileMirror/FetchProfile (Authoritative Player Data)
    if Remotes.FetchProfile then
        local ok, prof = pcall(function() return Remotes.FetchProfile:InvokeServer(LocalPlayer) end)
        if not ok or type(prof) ~= "table" then
            ok, prof = pcall(function() return Remotes.FetchProfile:InvokeServer() end)
        end

        if ok and type(prof) == "table" and type(prof.EggInventory) == "table" then
            for eggUid, eggData in pairs(prof.EggInventory) do
                local uidStr = tostring(eggUid)
                if type(eggData) == "table" then
                    -- PLACED EGG CRITERIA: Placement ~= nil and Placement ~= false and Placement ~= ""
                    local isPlaced = (eggData.Placement ~= nil and eggData.Placement ~= false and eggData.Placement ~= "")
                    if isPlaced then
                        local cat = tostring(eggData.AssetCategory or eggData.Category or eggData.Species or "Egg")
                        local isReady = (eggData.ReadyToHatch == true or eggData.Ready == true or eggData.Hatchable == true)

                        if not seenUids[uidStr] then
                            seenUids[uidStr] = true
                            table.insert(placed, {
                                Uid         = uidStr,
                                DisplayName = tostring(eggData.DisplayName or cat),
                                Category    = cat,
                                Source      = "ProfileMirror",
                                Placement   = eggData.Placement,
                                IsReady     = isReady,
                                RawData     = eggData,
                            })
                        else
                            -- Enrich existing entry from PlacedEggRenders with Profile Data
                            for _, item in ipairs(placed) do
                                if item.Uid == uidStr then
                                    item.Placement = eggData.Placement
                                    item.RawData = eggData
                                    if eggData.DisplayName then item.DisplayName = tostring(eggData.DisplayName) end
                                    if isReady then item.IsReady = true end
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    State.PlacedEggs = placed
    State.LastScanTime = os.clock()
    return placed
end

-- ================================================================================
-- HATCHING EXECUTION ENGINE
-- ================================================================================

-- Executes AskHatch with the exact parameters specified by the user
local function executeHatch(eggUid, skipCooldownCheck)
    if not eggUid or eggUid == "" then
        logMsg("❌ Cannot hatch: Egg UID is empty or nil.")
        return false, "Empty UID"
    end

    refreshRemotes()
    local rfHatch = Remotes.AskHatch
    if not rfHatch then
        logMsg("❌ RemoteFunction 'RF/EggWorld/AskHatch' not found in Networking!")
        return false, "Remote Not Found"
    end

    -- Cooldown check (prevent hammering failed UIDs within 3 seconds)
    local now = os.clock()
    if not skipCooldownCheck then
        local lastAttempt = State.HatchCooldowns[eggUid] or 0
        if (now - lastAttempt) < 3.0 then
            return false, "On Cooldown"
        end
    end
    State.HatchCooldowns[eggUid] = now

    logMsg("▶ Invoking RF/EggWorld/AskHatch for UID: %s", eggUid)
    local t0 = os.clock()
    local ok, result = pcall(function()
        return rfHatch:InvokeServer(eggUid)
    end)
    local elapsed = (os.clock() - t0) * 1000

    if ok then
        logMsg("✓ AskHatch returned in %.1fms: %s", elapsed, tostring(result))
        State.TotalHatched = State.TotalHatched + 1

        -- Optionally invoke AskFinishHatch if enabled
        if CONFIG.CallFinishHatch and Remotes.AskFinishHatch then
            task.spawn(function()
                task.wait(0.15)
                pcall(function()
                    local okF, resF = pcall(function() return Remotes.AskFinishHatch:InvokeServer(eggUid) end)
                    if okF then
                        logMsg("  ↳ AskFinishHatch result: %s", tostring(resF))
                    end
                end)
            end)
        end

        return true, result
    else
        logMsg("❌ AskHatch InvokeServer FAILED in %.1fms! Error: %s", elapsed, tostring(result))
        return false, result
    end
end

-- ProximityPrompt fallback trigger
local function triggerHatchPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    logMsg("▶ Triggering Hatch ProximityPrompt: %s (Action: %q)", prompt:GetFullName(), prompt.ActionText)
    
    if typeof(fireproximityprompt) == "function" then
        local ok, err = pcall(function() fireproximityprompt(prompt) end)
        if ok then
            logMsg("✓ fireproximityprompt succeeded.")
            return true
        end
    end

    -- Native trigger fallback
    pcall(function()
        prompt:InputHoldBegin()
        task.wait(prompt.HoldDuration > 0 and (prompt.HoldDuration + 0.05) or 0.05)
        prompt:InputHoldEnd()
    end)
    return true
end

-- Walk to Pen & Stop Center
local function executeWalkToPen()
    if State.IsBusy then
        logMsg("⚠️ Another action is in progress.")
        return false
    end
    State.IsBusy = true
    State.CurrentPhase = "WalkingToPen"
    logMsg("▶ Walking to Pen Center...")

    local penPos = State.PenPosition or findMyPen()
    if not penPos then
        logMsg("❌ Pen position could not be resolved.")
        State.CurrentPhase = "Idle"
        State.IsBusy = false
        return false
    end

    local arrived = moveToPosition(penPos, 3.0)
    local _, _, hum = getCharParts()
    if hum then pcall(function() hum:Move(Vector3.zero) end) end

    if arrived then
        logMsg("✓ Arrived at Pen Center (%.1f, %.1f, %.1f)", penPos.X, penPos.Y, penPos.Z)
        State.CurrentPhase = "AtPen"
    else
        logMsg("⚠️ Could not reach pen center.")
        State.CurrentPhase = "Idle"
    end
    State.IsBusy = false
    return arrived
end

-- Hatch All Placed Eggs in Pen
local function executeHatchAllPlaced()
    if State.IsBusy then
        logMsg("⚠️ Action in progress. Please wait.")
        return
    end
    State.IsBusy = true
    State.CurrentPhase = "HatchingAll"

    logMsg("==================================================")
    logMsg("🐣 SCANNING & HATCHING ALL PLACED EGGS IN PEN...")
    logMsg("==================================================")

    local placed = scanPlacedEggs()
    logMsg("Discovered %d placed eggs in Pen/Inventory.", #placed)

    if #placed == 0 then
        logMsg("ℹ️ No placed eggs detected in Pen.")
        State.CurrentPhase = "Idle"
        State.IsBusy = false
        return
    end

    local hatchedCount = 0
    for idx, item in ipairs(placed) do
        logMsg("[%d/%d] Hatching %s (UID: %s)...", idx, #placed, item.DisplayName, item.Uid)
        local ok, res = executeHatch(item.Uid, true)
        if ok then
            hatchedCount = hatchedCount + 1
        end
        if item.Prompt then
            triggerHatchPrompt(item.Prompt)
        end
        task.wait(CONFIG.HatchBatchDelay or 0.35)
    end

    logMsg("==================================================")
    logMsg("✓ BATCH HATCH COMPLETE: %d/%d successfully triggered.", hatchedCount, #placed)
    logMsg("==================================================")

    State.CurrentPhase = "Idle"
    State.IsBusy = false
end

-- ================================================================================
-- AUTONOMOUS BACKGROUND AUTO HATCH LOOP
-- ================================================================================
local function startAutoHatchLoop()
    if State.LoopThread then return end
    CONFIG.AutoHatch = true
    State.IsRunning = true
    logMsg("==================================================")
    logMsg("🚀 AUTO HATCH LOOP STARTED (Continuous Pen Monitor)")
    logMsg("==================================================")

    State.LoopThread = task.spawn(function()
        while CONFIG.AutoHatch do
            State.CurrentPhase = "AutoScanning"
            local placed = scanPlacedEggs()

            if #placed > 0 then
                for _, item in ipairs(placed) do
                    if not CONFIG.AutoHatch then break end
                    -- If egg is ready, or if in general placed egg monitor
                    local ok, err = executeHatch(item.Uid, false)
                    if ok then
                        task.wait(CONFIG.HatchBatchDelay or 0.35)
                    end
                end
            end

            State.CurrentPhase = "AutoWaiting"
            local waitTime = CONFIG.ScanInterval or 2.0
            local startWait = os.clock()
            while CONFIG.AutoHatch and (os.clock() - startWait) < waitTime do
                task.wait(0.2)
            end
        end

        State.IsRunning = false
        State.LoopThread = nil
        State.CurrentPhase = "Idle"
        logMsg("⏹️ Auto Hatch loop stopped.")
    end)
end

local function stopAutoHatchLoop()
    CONFIG.AutoHatch = false
    State.IsRunning = false
    if State.LoopThread then
        task.cancel(State.LoopThread)
        State.LoopThread = nil
    end
    State.CurrentPhase = "Idle"
    logMsg("⏹️ Auto Hatch loop stopped by user.")
end

-- ================================================================================
-- MODERN INTERACTIVE IN-GAME HUD
-- ================================================================================
local function createUI()
    local getHui = gethui or function() return CoreGui end
    local uiParent = nil
    pcall(function() uiParent = getHui() end)
    if not uiParent then
        uiParent = LocalPlayer:FindFirstChild("PlayerGui") or CoreGui
    end

    local old = uiParent:FindFirstChild("AutoHatchTestGui")
    if old then pcall(function() old:Destroy() end) end

    local gui = Instance.new("ScreenGui")
    gui.Name = "AutoHatchTestGui"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 99999
    pcall(function() gui.Parent = uiParent end)
    if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    -- Main Container Frame
    local W, H = 430, 520
    local main = Instance.new("Frame")
    main.Size = UDim2.new(0, W, 0, H)
    main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
    main.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
    main.BorderSizePixel = 0
    main.Active = true
    main.Parent = gui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", main)
    stroke.Color = Color3.fromRGB(80, 175, 240)
    stroke.Thickness = 1.5

    -- Draggable Title Bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 40)
    titleBar.BackgroundColor3 = Color3.fromRGB(26, 34, 50)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -50, 1, 0)
    titleLbl.Position = UDim2.new(0, 12, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "🥚 AUTO HATCH TEST SUITE 🐣"
    titleLbl.TextColor3 = Color3.fromRGB(235, 245, 255)
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 13
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 28, 0, 28)
    closeBtn.Position = UDim2.new(1, -34, 0, 6)
    closeBtn.BackgroundColor3 = Color3.fromRGB(190, 50, 50)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 13
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
    closeBtn.MouseButton1Click:Connect(function()
        stopAutoHatchLoop()
        gui:Destroy()
    end)

    -- Dragging Handler
    local dragging, dragStart, startPos = false, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    -- Status Card
    local statusCard = Instance.new("Frame")
    statusCard.Size = UDim2.new(1, -20, 0, 48)
    statusCard.Position = UDim2.new(0, 10, 0, 46)
    statusCard.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
    statusCard.BorderSizePixel = 0
    statusCard.Parent = main
    Instance.new("UICorner", statusCard).CornerRadius = UDim.new(0, 8)

    local statusTitle = Instance.new("TextLabel")
    statusTitle.Size = UDim2.new(0.5, 0, 0, 16)
    statusTitle.Position = UDim2.new(0, 8, 0, 6)
    statusTitle.BackgroundTransparency = 1
    statusTitle.Text = "STATUS / PHASE"
    statusTitle.TextColor3 = Color3.fromRGB(150, 180, 220)
    statusTitle.Font = Enum.Font.GothamBold
    statusTitle.TextSize = 10
    statusTitle.TextXAlignment = Enum.TextXAlignment.Left
    statusTitle.Parent = statusCard

    local statusVal = Instance.new("TextLabel")
    statusVal.Size = UDim2.new(0.5, 0, 0, 20)
    statusVal.Position = UDim2.new(0, 8, 0, 22)
    statusVal.BackgroundTransparency = 1
    statusVal.Text = "Idle"
    statusVal.TextColor3 = Color3.fromRGB(100, 225, 140)
    statusVal.Font = Enum.Font.GothamBold
    statusVal.TextSize = 12
    statusVal.TextXAlignment = Enum.TextXAlignment.Left
    statusVal.Parent = statusCard

    local statsCountLbl = Instance.new("TextLabel")
    statsCountLbl.Size = UDim2.new(0.5, -8, 1, -8)
    statsCountLbl.Position = UDim2.new(0.5, 0, 0, 4)
    statsCountLbl.BackgroundTransparency = 1
    statsCountLbl.Text = "Eggs in Pen: 0\nHatched: 0"
    statsCountLbl.TextColor3 = Color3.fromRGB(210, 225, 245)
    statsCountLbl.Font = Enum.Font.GothamMedium
    statsCountLbl.TextSize = 11
    statsCountLbl.TextXAlignment = Enum.TextXAlignment.Right
    statsCountLbl.Parent = statusCard

    -- Target UID Input Row
    local uidCard = Instance.new("Frame")
    uidCard.Size = UDim2.new(1, -20, 0, 36)
    uidCard.Position = UDim2.new(0, 10, 0, 100)
    uidCard.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
    uidCard.BorderSizePixel = 0
    uidCard.Parent = main
    Instance.new("UICorner", uidCard).CornerRadius = UDim.new(0, 8)

    local uidLabel = Instance.new("TextLabel")
    uidLabel.Size = UDim2.new(0, 32, 1, 0)
    uidLabel.Position = UDim2.new(0, 8, 0, 0)
    uidLabel.BackgroundTransparency = 1
    uidLabel.Text = "UID:"
    uidLabel.TextColor3 = Color3.fromRGB(150, 180, 220)
    uidLabel.Font = Enum.Font.GothamBold
    uidLabel.TextSize = 11
    uidLabel.TextXAlignment = Enum.TextXAlignment.Left
    uidLabel.Parent = uidCard

    local uidBox = Instance.new("TextBox")
    uidBox.Size = UDim2.new(1, -95, 1, -8)
    uidBox.Position = UDim2.new(0, 42, 0, 4)
    uidBox.BackgroundColor3 = Color3.fromRGB(14, 18, 26)
    uidBox.TextColor3 = Color3.fromRGB(255, 215, 80)
    uidBox.Font = Enum.Font.Code
    uidBox.TextSize = 10
    uidBox.ClearTextOnFocus = false
    uidBox.Text = CONFIG.TargetUid
    uidBox.Parent = uidCard
    Instance.new("UICorner", uidBox).CornerRadius = UDim.new(0, 5)

    uidBox.FocusLost:Connect(function()
        CONFIG.TargetUid = string.gsub(uidBox.Text, "%s+", "")
        logMsg("Target UID updated: %s", CONFIG.TargetUid)
    end)

    local pasteBtn = Instance.new("TextButton")
    pasteBtn.Size = UDim2.new(0, 46, 1, -8)
    pasteBtn.Position = UDim2.new(1, -50, 0, 4)
    pasteBtn.BackgroundColor3 = Color3.fromRGB(45, 60, 90)
    pasteBtn.Text = "Paste"
    pasteBtn.TextColor3 = Color3.new(1, 1, 1)
    pasteBtn.Font = Enum.Font.GothamBold
    pasteBtn.TextSize = 10
    pasteBtn.Parent = uidCard
    Instance.new("UICorner", pasteBtn).CornerRadius = UDim.new(0, 5)
    pasteBtn.MouseButton1Click:Connect(function()
        local clip = getclipboard and getclipboard() or nil
        if clip and #clip >= 10 then
            clip = string.gsub(clip, "%s+", "")
            CONFIG.TargetUid = clip
            uidBox.Text = clip
            logMsg("Pasted UID from clipboard: %s", clip)
        else
            logMsg("⚠️ Clipboard is empty or getclipboard not supported.")
        end
    end)

    -- Button Helper
    local function makeButton(name, text, pos, size, bgCol, onClick)
        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Text = text
        btn.Position = pos
        btn.Size = size
        btn.BackgroundColor3 = bgCol
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
        btn.MouseButton1Click:Connect(onClick)
        return btn
    end

    -- Button Row 1: Manual Trigger UID & Scan Placed Eggs
    local btnHatchTarget = makeButton("BtnHatchTarget", "⚡ HATCH TARGET UID", UDim2.new(0, 10, 0, 142), UDim2.new(0.5, -14, 0, 30), Color3.fromRGB(45, 135, 75), function()
        local uid = string.gsub(uidBox.Text, "%s+", "")
        if uid == "" then
            logMsg("❌ Please specify or paste an Egg UID to hatch.")
            return
        end
        CONFIG.TargetUid = uid
        task.spawn(function()
            executeHatch(uid, true)
        end)
    end)

    local btnScan = makeButton("BtnScan", "🔍 SCAN PEN EGGS", UDim2.new(0.5, 4, 0, 142), UDim2.new(0.5, -14, 0, 30), Color3.fromRGB(50, 100, 180), function()
        task.spawn(function()
            logMsg("Scanning placed eggs in Pen...")
            local list = scanPlacedEggs()
            logMsg("Found %d placed eggs in Pen:", #list)
            for idx, item in ipairs(list) do
                logMsg("  [%d] %s | UID: %s | Source: %s | Ready: %s", idx, item.DisplayName, item.Uid, item.Source, tostring(item.IsReady))
            end
        end)
    end)

    -- Button Row 2: Hatch All Placed Eggs & Auto Hatch Toggle
    local btnHatchAll = makeButton("BtnHatchAll", "✨ HATCH ALL PLACED", UDim2.new(0, 10, 0, 178), UDim2.new(0.5, -14, 0, 30), Color3.fromRGB(160, 100, 30), function()
        task.spawn(executeHatchAllPlaced)
    end)

    local toggleAutoBtn = makeButton("BtnToggleAuto", "🐣 AUTO HATCH: OFF", UDim2.new(0.5, 4, 0, 178), UDim2.new(0.5, -14, 0, 30), Color3.fromRGB(45, 50, 65), function()
        if CONFIG.AutoHatch then
            stopAutoHatchLoop()
        else
            startAutoHatchLoop()
        end
    end)

    local function updateAutoHatchBtn()
        if CONFIG.AutoHatch then
            toggleAutoBtn.Text = "🐣 AUTO HATCH: ON"
            toggleAutoBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
        else
            toggleAutoBtn.Text = "🐣 AUTO HATCH: OFF"
            toggleAutoBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
        end
    end

    -- Button Row 3: Optional Walk to Pen
    local btnWalkPen = makeButton("BtnWalkPen", "📍 WALK TO PEN CENTER", UDim2.new(0, 10, 0, 214), UDim2.new(1, -20, 0, 28), Color3.fromRGB(70, 60, 120), function()
        task.spawn(executeWalkToPen)
    end)

    -- Log Box Frame
    local logBoxFrame = Instance.new("Frame")
    logBoxFrame.Size = UDim2.new(1, -20, 0, 230)
    logBoxFrame.Position = UDim2.new(0, 10, 0, 248)
    logBoxFrame.BackgroundColor3 = Color3.fromRGB(12, 15, 22)
    logBoxFrame.BorderSizePixel = 0
    logBoxFrame.Parent = main
    Instance.new("UICorner", logBoxFrame).CornerRadius = UDim.new(0, 8)
    local logStroke = Instance.new("UIStroke", logBoxFrame)
    logStroke.Color = Color3.fromRGB(40, 50, 70)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -12, 1, -12)
    scroll.Position = UDim2.new(0, 6, 0, 6)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = logBoxFrame

    local logTxt = Instance.new("TextLabel")
    logTxt.Size = UDim2.new(1, -6, 0, 0)
    logTxt.BackgroundTransparency = 1
    logTxt.TextColor3 = Color3.fromRGB(180, 195, 215)
    logTxt.Font = Enum.Font.Code
    logTxt.TextSize = 10
    logTxt.TextXAlignment = Enum.TextXAlignment.Left
    logTxt.TextYAlignment = Enum.TextYAlignment.Top
    logTxt.TextWrapped = true
    logTxt.Text = "Auto Hatch Test Suite ready. Logs will appear here..."
    logTxt.Parent = scroll

    logCallback = function(_)
        local fullText = table.concat(logEntries, "\n")
        logTxt.Text = fullText
        local textBounds = logTxt.TextBounds
        logTxt.Size = UDim2.new(1, -6, 0, math.max(textBounds.Y, 20))
        scroll.CanvasSize = UDim2.new(0, 0, 0, textBounds.Y + 10)
        scroll.CanvasPosition = Vector2.new(0, math.max(0, textBounds.Y - scroll.AbsoluteSize.Y + 10))
    end

    -- Bottom Toolbar: Clear & Copy
    makeButton("BtnClear", "Clear", UDim2.new(0, 10, 0, 484), UDim2.new(0, 60, 0, 26), Color3.fromRGB(35, 42, 58), function()
        table.clear(logEntries)
        logTxt.Text = "Cleared."
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    end)

    makeButton("BtnCopy", "Copy Logs", UDim2.new(0, 76, 0, 484), UDim2.new(0, 80, 0, 26), Color3.fromRGB(45, 60, 90), function()
        if setclipboard then
            setclipboard(table.concat(logEntries, "\n"))
            logMsg("✓ Logs copied to clipboard!")
        end
    end)

    -- Status Poller
    task.spawn(function()
        while gui and gui.Parent do
            task.wait(0.35)
            statusVal.Text = State.CurrentPhase
            if State.CurrentPhase == "Idle" then
                statusVal.TextColor3 = Color3.fromRGB(100, 225, 140)
            elseif State.CurrentPhase:find("Hatching") then
                statusVal.TextColor3 = Color3.fromRGB(255, 180, 60)
            elseif State.CurrentPhase:find("Walking") then
                statusVal.TextColor3 = Color3.fromRGB(220, 140, 240)
            else
                statusVal.TextColor3 = Color3.fromRGB(100, 190, 255)
            end

            statsCountLbl.Text = string.format("Eggs in Pen: %d\nHatched: %d", #State.PlacedEggs, State.TotalHatched)
            updateAutoHatchBtn()
        end
    end)

    logMsg("AutoHatchTest GUI initialized successfully.")
end

-- ================================================================================
-- INITIALIZATION PIPELINE
-- ================================================================================
local function init()
    logMsg("==================================================")
    logMsg("INITIALIZING AUTO HATCH TEST SUITE...")
    logMsg("Target Remote: RF/EggWorld/AskHatch")
    logMsg("Sample UID: %s", CONFIG.TargetUid)
    logMsg("==================================================")

    refreshRemotes()
    findMyPlot()
    findMyPen()
    scanPlacedEggs()
    createUI()

    logMsg("Initialization complete. Ready to hatch!")
end

task.spawn(init)
