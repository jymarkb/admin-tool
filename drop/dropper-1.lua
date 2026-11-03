local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

--==================================================
-- SETTINGS
--==================================================

local INITIAL_FREEFALL_TIME = 0.12
local INITIAL_VERTICAL_SPEED = -13
local FALL_ACCELERATION = -200

local ENTRY_HEIGHT = 3.8
local FINAL_VERTICAL_SPEED = -5

local MAX_DESCENT_TIME = 1.5

local TRACE_INTERVAL = 0.05

local EGG_DROP_SPAM_COUNT = 8
local EGG_DROP_SPAM_INTERVAL = 0.03

local POSITION_SETTLE_TIME = 0.10

local GUARD_HIT_TIMING = 0.550
local TARGET_GUARD_AREA = "Auto"

local SAMPLE_GUARD_CFRAME = CFrame.new(
    605.572266, 69.3371735, -325.887329,
    0.70000118, 0, -0.714141667,
    0, 1, 0,
    0.714141667, 0, 0.70000118
)

--==================================================
-- CHARACTER
--==================================================

local Character
local Humanoid
local Root

local function refreshCharacter()
    Character = Player.Character or Player.CharacterAdded:Wait()
    Humanoid = Character:WaitForChild("Humanoid")
    Root = Character:WaitForChild("HumanoidRootPart")
end

refreshCharacter()

Player.CharacterAdded:Connect(function()
    task.wait(0.25)
    refreshCharacter()
end)

--==================================================
-- LOCATION
--==================================================

local SavedLocation = Vector3.new(949.147, 70.724, -412.289)

-- Start is captured automatically when RUN is pressed.
local StartLocation = nil

--==================================================
-- STATE
--==================================================

local Running = false
local Phase = "IDLE"
local RunToken = 0
local LastEggDropRunToken = nil

local isAutoEnabled = true

local cachedEggUid = nil
local cachedEggSource = nil
local isRefreshingEggUid = false
local forestStrikeWatchRemote = nil

local TestStartTime = 0
local LastTrace = 0

local runTest = nil

--==================================================
-- LOGGING
--==================================================

local Logs = {}

local function log(message)
    local line = string.format(
        "[%s] %s",
        os.date("%H:%M:%S"),
        tostring(message)
    )

    table.insert(Logs, line)

    while #Logs > 400 do
        table.remove(Logs, 1)
    end

    print(line)
end

local function vec(v)
    if not v then
        return "nil"
    end

    return string.format(
        "(%.3f, %.3f, %.3f)",
        v.X,
        v.Y,
        v.Z
    )
end

local function logCharacterPosition(label)
    if not Root or not Root.Parent or not Humanoid then
        log(string.format("POSITION [%s]: Character unavailable", tostring(label or "snapshot")))
        return nil
    end

    local p = Root.Position
    local v = Root.AssemblyLinearVelocity
    local stateName = Humanoid:GetState().Name
    log(string.format(
        "POSITION [%s]: %s | vel=%s (speed=%.2f) | state=%s",
        tostring(label or "snapshot"),
        vec(p),
        vec(v),
        v.Magnitude,
        stateName
    ))
    return p
end

local function copyLog()
    local text = table.concat(Logs, "\n")
    local success = false

    if type(setclipboard) == "function" then
        success = pcall(function()
            setclipboard(text)
        end)
    elseif type(toclipboard) == "function" then
        success = pcall(function()
            toclipboard(text)
        end)
    end

    if success then
        log("LOG COPIED")
    else
        log("Clipboard unavailable")
    end
end

--==================================================
-- GUI
--==================================================

local Gui = Instance.new("ScreenGui")
Gui.Name = "DropTesterOneLocation"
Gui.ResetOnSpawn = false
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.Parent = PlayerGui

local Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(290, 260)
Main.Position = UDim2.new(0.5, -145, 0.5, -130)

Main.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
Main.BorderSizePixel = 0

Main.Parent = Gui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0, 8)
Corner.Parent = Main

--==================================================
-- TITLE BAR
--==================================================

local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 32)

TitleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
TitleBar.BorderSizePixel = 0

TitleBar.Parent = Main

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 8)
TitleCorner.Parent = TitleBar

local TitleFix = Instance.new("Frame")
TitleFix.Size = UDim2.new(1, 0, 0, 12)
TitleFix.Position = UDim2.new(0, 0, 1, -12)

TitleFix.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
TitleFix.BorderSizePixel = 0

TitleFix.Parent = TitleBar

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -42, 1, 0)
Title.Position = UDim2.fromOffset(10, 0)

Title.BackgroundTransparency = 1
Title.Text = "Guard Dropper"

Title.TextColor3 = Color3.new(1, 1, 1)
Title.TextSize = 15
Title.Font = Enum.Font.SourceSansBold

Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = TitleBar

--==================================================
-- CLOSE
--==================================================

local Close = Instance.new("TextButton")
Close.Size = UDim2.fromOffset(24, 24)
Close.Position = UDim2.new(1, -28, 0, 4)

Close.BackgroundColor3 = Color3.fromRGB(170, 50, 50)
Close.BorderSizePixel = 0

Close.Text = "X"
Close.TextColor3 = Color3.new(1, 1, 1)
Close.TextSize = 14
Close.Font = Enum.Font.SourceSansBold

Close.Parent = TitleBar

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 6)
CloseCorner.Parent = Close

Close.MouseButton1Click:Connect(function()
    Running = false
    RunToken += 1

    if Root and Root.Parent then
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
    end

    Gui:Destroy()
end)

--==================================================
-- DRAGGING
--==================================================

local dragging = false
local dragStart
local startPos

TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        dragging = true
        dragStart = input.Position
        startPos = Main.Position
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        dragging = false
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not dragging then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then

        local delta = input.Position - dragStart

        Main.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,

            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

--==================================================
-- LABELS
--==================================================

local LocationLabel = Instance.new("TextLabel")
LocationLabel.Size = UDim2.new(1, -16, 0, 18)
LocationLabel.Position = UDim2.fromOffset(8, 36)
LocationLabel.BackgroundTransparency = 1
LocationLabel.Text = "Drop: " .. (SavedLocation and vec(SavedLocation) or "NOT SET")
LocationLabel.TextColor3 = Color3.fromRGB(215, 215, 215)
LocationLabel.TextSize = 11
LocationLabel.Font = Enum.Font.SourceSans
LocationLabel.TextXAlignment = Enum.TextXAlignment.Left
LocationLabel.Parent = Main

local GuardLabel = Instance.new("TextLabel")
GuardLabel.Size = UDim2.new(1, -16, 0, 18)
GuardLabel.Position = UDim2.fromOffset(8, 54)
GuardLabel.BackgroundTransparency = 1
GuardLabel.Text = "Guard: " .. TARGET_GUARD_AREA .. " (RE/GuardPatrol/Rouse)"
GuardLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
GuardLabel.TextSize = 11
GuardLabel.Font = Enum.Font.SourceSans
GuardLabel.TextXAlignment = Enum.TextXAlignment.Left
GuardLabel.Parent = Main

local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, -16, 0, 18)
Status.Position = UDim2.fromOffset(8, 72)
Status.BackgroundTransparency = 1
Status.Text = "Status: Ready — press E on egg in any area"
Status.TextColor3 = Color3.fromRGB(150, 220, 150)
Status.TextSize = 11
Status.Font = Enum.Font.SourceSans
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.Parent = Main

--==================================================
-- TIMING CONTROLS (Row Y=92)
--==================================================

local TimingLabel = Instance.new("TextLabel")
TimingLabel.Size = UDim2.new(0.46, -10, 0, 26)
TimingLabel.Position = UDim2.fromOffset(8, 92)
TimingLabel.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
TimingLabel.BorderSizePixel = 0
TimingLabel.Text = string.format("Timing: %.3fs", GUARD_HIT_TIMING)
TimingLabel.TextColor3 = Color3.fromRGB(255, 220, 130)
TimingLabel.TextSize = 12
TimingLabel.Font = Enum.Font.SourceSansBold
TimingLabel.Parent = Main
local tlCorner = Instance.new("UICorner")
tlCorner.CornerRadius = UDim.new(0, 6)
tlCorner.Parent = TimingLabel

local function getPingMs()
    local ok, stats = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(stats) == "number" and stats > 0 then
        return math.floor(stats + 0.5)
    end
    local ok2, ping = pcall(function()
        return Player:GetNetworkPing() * 2000
    end)
    if ok2 and type(ping) == "number" and ping > 0 then
        return math.floor(ping + 0.5)
    end
    return 68
end

local function updateTimingUI()
    if TimingLabel and TimingLabel.Parent then
        local ping = getPingMs()
        TimingLabel.Text = string.format("Time: %.3fs (%dms)", GUARD_HIT_TIMING, ping)
    end
end

local TimingMinusBtn = Instance.new("TextButton")
TimingMinusBtn.Size = UDim2.new(0, 38, 0, 26)
TimingMinusBtn.Position = UDim2.new(0.46, 0, 0, 92)
TimingMinusBtn.BackgroundColor3 = Color3.fromRGB(150, 60, 60)
TimingMinusBtn.BorderSizePixel = 0
TimingMinusBtn.Text = "[-]"
TimingMinusBtn.TextColor3 = Color3.new(1, 1, 1)
TimingMinusBtn.TextSize = 14
TimingMinusBtn.Font = Enum.Font.SourceSansBold
TimingMinusBtn.Parent = Main
local tmCorner = Instance.new("UICorner")
tmCorner.CornerRadius = UDim.new(0, 6)
tmCorner.Parent = TimingMinusBtn

local TimingPlusBtn = Instance.new("TextButton")
TimingPlusBtn.Size = UDim2.new(0, 38, 0, 26)
TimingPlusBtn.Position = UDim2.new(0.46, 42, 0, 92)
TimingPlusBtn.BackgroundColor3 = Color3.fromRGB(60, 130, 60)
TimingPlusBtn.BorderSizePixel = 0
TimingPlusBtn.Text = "[+]"
TimingPlusBtn.TextColor3 = Color3.new(1, 1, 1)
TimingPlusBtn.TextSize = 14
TimingPlusBtn.Font = Enum.Font.SourceSansBold
TimingPlusBtn.Parent = Main
local tpCorner = Instance.new("UICorner")
tpCorner.CornerRadius = UDim.new(0, 6)
tpCorner.Parent = TimingPlusBtn

local TimingResetBtn = Instance.new("TextButton")
TimingResetBtn.Size = UDim2.new(1, -0.46 - 92, 0, 26)
TimingResetBtn.Position = UDim2.new(0.46, 84, 0, 92)
TimingResetBtn.BackgroundColor3 = Color3.fromRGB(60, 75, 110)
TimingResetBtn.BorderSizePixel = 0
TimingResetBtn.Text = "RST"
TimingResetBtn.TextColor3 = Color3.new(1, 1, 1)
TimingResetBtn.TextSize = 11
TimingResetBtn.Font = Enum.Font.SourceSansBold
TimingResetBtn.Parent = Main
local trCorner = Instance.new("UICorner")
trCorner.CornerRadius = UDim.new(0, 6)
trCorner.Parent = TimingResetBtn

TimingMinusBtn.MouseButton1Click:Connect(function()
    GUARD_HIT_TIMING = math.max(0.000, math.floor((GUARD_HIT_TIMING - 0.010) * 1000 + 0.5) / 1000)
    updateTimingUI()
    log(string.format("Timing delay decreased to: %.3fs", GUARD_HIT_TIMING))
end)

TimingPlusBtn.MouseButton1Click:Connect(function()
    GUARD_HIT_TIMING = math.min(2.000, math.floor((GUARD_HIT_TIMING + 0.010) * 1000 + 0.5) / 1000)
    updateTimingUI()
    log(string.format("Timing delay increased to: %.3fs", GUARD_HIT_TIMING))
end)

TimingResetBtn.MouseButton1Click:Connect(function()
    local ping = getPingMs()
    GUARD_HIT_TIMING = math.clamp(math.floor((0.480 + (ping / 1000)) * 1000 + 0.5) / 1000, 0.400, 0.850)
    updateTimingUI()
    log(string.format("Timing delay reset to ping-calibrated baseline: %.3fs (ping=%dms)", GUARD_HIT_TIMING, ping))
end)

--==================================================
-- BUTTON CREATOR & ACTION BUTTONS
--==================================================

local function makeButton(text, x, y, width, height, color)
    local button = Instance.new("TextButton")
    button.Size = width or UDim2.new(1, -16, 0, 30)
    button.Position = UDim2.new(0, x or 8, 0, y)
    button.BackgroundColor3 = color or Color3.fromRGB(55, 55, 55)
    button.BorderSizePixel = 0
    button.Text = text
    button.TextColor3 = Color3.new(1, 1, 1)
    button.TextSize = 12
    button.Font = Enum.Font.SourceSansBold
    button.Parent = Main

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = button

    return button
end

local SetLocationButton =
    makeButton(
        "SET LANDING",
        8,
        124,
        UDim2.new(0.50, -10, 0, 28),
        28,
        Color3.fromRGB(65, 90, 135)
    )

local AutoToggleBtn =
    makeButton(
        "[AUTO: ON]",
        0,
        124,
        UDim2.new(0.50, -6, 0, 28),
        28,
        Color3.fromRGB(45, 125, 65)
    )
AutoToggleBtn.Position = UDim2.new(0.50, 2, 0, 124)

local RunButton =
    makeButton(
        "RUN MANUAL: ROUSE → DROP",
        8,
        158,
        UDim2.new(1, -16, 0, 32),
        32,
        Color3.fromRGB(50, 115, 60)
    )

local CopyButton =
    makeButton(
        "COPY LOG",
        8,
        196,
        UDim2.new(0.36, -8, 0, 26),
        26,
        Color3.fromRGB(50, 90, 160)
    )

local RouseOnlyButton =
    makeButton(
        "ROUSE",
        0,
        196,
        UDim2.new(0.32, -6, 0, 26),
        26,
        Color3.fromRGB(150, 100, 45)
    )
RouseOnlyButton.Position = UDim2.new(0.36, 0, 0, 196)

local StopButton =
    makeButton(
        "STOP",
        0,
        196,
        UDim2.new(0.32, -6, 0, 26),
        26,
        Color3.fromRGB(130, 50, 50)
    )
StopButton.Position = UDim2.new(0.68, 2, 0, 196)

local HintLabel = Instance.new("TextLabel")
HintLabel.Size = UDim2.new(1, -16, 0, 18)
HintLabel.Position = UDim2.fromOffset(8, 228)
HintLabel.BackgroundTransparency = 1
HintLabel.Text = "Press E on egg: Request true -> Sets timing & drops"
HintLabel.TextColor3 = Color3.fromRGB(160, 220, 170)
HintLabel.TextSize = 10
HintLabel.Font = Enum.Font.SourceSansItalic
HintLabel.TextXAlignment = Enum.TextXAlignment.Center
HintLabel.Parent = Main

--==================================================
-- BUTTON HANDLERS
--==================================================

SetLocationButton.MouseButton1Click:Connect(function()
    if Running then
        Status.Text =
            "Status: Stop current test first"
        return
    end

    refreshCharacter()

    if not Root or not Root.Parent then
        Status.Text =
            "Status: Character unavailable"
        return
    end

    SavedLocation = Root.Position

    LocationLabel.Text =
        "Drop: " .. vec(SavedLocation)

    Status.Text =
        "Status: Location saved"

    log(
        "DROP / LANDING LOCATION = "
        .. vec(SavedLocation)
    )
end)

AutoToggleBtn.MouseButton1Click:Connect(function()
    isAutoEnabled = not isAutoEnabled
    if isAutoEnabled then
        AutoToggleBtn.Text = "[AUTO: ON]"
        AutoToggleBtn.BackgroundColor3 = Color3.fromRGB(45, 125, 65)
        HintLabel.Text = "Auto: Pick up egg in any area -> Auto Run"
        HintLabel.TextColor3 = Color3.fromRGB(160, 220, 170)
        Status.Text = "Status: Auto-detect active"
        log("Auto-Detect: ENABLED (Will auto-run upon egg pickup)")
    else
        AutoToggleBtn.Text = "[AUTO: OFF]"
        AutoToggleBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
        HintLabel.Text = "Auto off: manual RUN button only"
        HintLabel.TextColor3 = Color3.fromRGB(160, 160, 160)
        Status.Text = "Status: Auto-detect disabled"
        log("Auto-Detect: DISABLED (Manual RUN only)")
    end
end)

--==================================================
-- TRACE
--==================================================

local function trace(label)
    if not Root or not Root.Parent then
        return
    end

    local now = os.clock()

    if now - LastTrace < TRACE_INTERVAL then
        return
    end

    LastTrace = now

    log(
        label
        .. " | pos="
        .. vec(Root.Position)
        .. " | vel="
        .. vec(Root.AssemblyLinearVelocity)
    )
end

--==================================================
-- REMOTE RESOLVER & EGG UID HELPERS
--==================================================

local function getRemote(subPath)
    local packages = ReplicatedStorage:FindFirstChild("Packages")
        or ReplicatedStorage:WaitForChild("Packages", 5)
    local networking = packages and (
        packages:FindFirstChild("Networking")
        or packages:WaitForChild("Networking", 5)
    )
    if not networking then
        return nil
    end

    local flattened = networking:FindFirstChild(subPath)
    if flattened then
        return flattened
    end

    local current = networking
    for segment in string.gmatch(subPath, "[^/]+") do
        current = current and current:FindFirstChild(segment)
    end
    if current then
        return current
    end

    local leaf = string.match(subPath, "[^/]+$")
    for _, item in ipairs(networking:GetDescendants()) do
        if item.Name == subPath or item.Name == leaf then
            return item
        end
    end
    return nil
end

local function isEggAvailable(record)
    local carrier = record.CarrierUserId or record.carrierUserId
    return carrier == nil or carrier == 0 or carrier == "" or carrier == "0"
end

local function findAnyEggUid()
    log("Looking for available Egg UID...")
    local snapshotRemote = getRemote("RF/EggWorld/AskFieldEggSnapshot")

    if snapshotRemote and snapshotRemote:IsA("RemoteFunction") then
        local ok, result = pcall(function()
            return snapshotRemote:InvokeServer()
        end)

        if ok and typeof(result) == "table" then
            local records = result.Records or result.records
            if typeof(records) == "table" then
                local fallbackUid = nil
                local fallbackSource = nil

                for _, record in pairs(records) do
                    if typeof(record) == "table" then
                        local uid = record.Uid or record.uid or record.UID or record.Id or record.id
                        local area = record.AreaId or record.areaId or record.Area or record.Biome or record.biome
                        local uidText = tostring(uid or "")
                        local areaText = string.lower(tostring(area or ""))
                        local uidLower = string.lower(uidText)
                        local isForest = areaText == "forest"
                            or string.find(uidLower, "_forest:slot_", 1, true) ~= nil

                        if uid and uidText ~= "" and isEggAvailable(record) then
                            if isForest then
                                log("Selected Forest UID from AskFieldEggSnapshot: " .. uidText)
                                return uidText, "AskFieldEggSnapshot (Forest)"
                            elseif not fallbackUid then
                                fallbackUid = uidText
                                fallbackSource = "AskFieldEggSnapshot (" .. (areaText ~= "" and areaText or "Any") .. ")"
                            end
                        end
                    end
                end

                if fallbackUid then
                    log("Selected available UID from AskFieldEggSnapshot: " .. fallbackUid)
                    return fallbackUid, fallbackSource
                end
            end
        end
    end

    -- Fallback: AreaEggSlotsClient in workspace (from latest.log)
    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        local fallbackSlot = nil
        for _, slot in ipairs(slots:GetChildren()) do
            local nameLower = string.lower(slot.Name)
            if string.find(nameLower, "_forest:slot_", 1, true) then
                log("Selected Forest UID from AreaEggSlotsClient: " .. slot.Name)
                return slot.Name, "Workspace.AreaEggSlotsClient (Forest)"
            elseif not fallbackSlot then
                fallbackSlot = slot.Name
            end
        end

        if fallbackSlot then
            log("Selected UID from AreaEggSlotsClient: " .. fallbackSlot)
            return fallbackSlot, "Workspace.AreaEggSlotsClient"
        end
    end

    return nil, "No available Egg UID found"
end

local function refreshEggUid(sync)
    if isRefreshingEggUid then
        log("UID refresh already in progress...")
        return
    end

    local function doRefresh()
        isRefreshingEggUid = true
        if RefreshIdButton and RefreshIdButton.Parent then
            RefreshIdButton.Text = "LOADING..."
        end
        log("Refreshing cached Egg UID...")

        local ok, uid, source = pcall(findAnyEggUid)
        if ok and uid and tostring(uid) ~= "" then
            cachedEggUid = tostring(uid)
            cachedEggSource = tostring(source or "unknown")
            log(string.format("Cached Egg UID loaded: %s (%s)", cachedEggUid, cachedEggSource))
            if EggUidLabel and EggUidLabel.Parent then
                EggUidLabel.Text = "Egg UID: " .. cachedEggUid
                EggUidLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
            end
        else
            local reason = ok and tostring(source or "none found") or tostring(uid)
            log("UID refresh failed: " .. reason)
            if not cachedEggUid then
                if EggUidLabel and EggUidLabel.Parent then
                    EggUidLabel.Text = "Egg UID: NOT LOADED (Press Refresh)"
                    EggUidLabel.TextColor3 = Color3.fromRGB(255, 185, 130)
                end
            end
        end

        isRefreshingEggUid = false
        if RefreshIdButton and RefreshIdButton.Parent then
            RefreshIdButton.Text = "REFRESH ID"
        end
    end

    if sync then
        doRefresh()
    else
        task.spawn(doRefresh)
    end
end

--==================================================
-- BIOME GUARD ROUSE (TITAN TEMPLE)
--==================================================

local function getClosestGuard(playerPos)
    local bestGuard = nil
    local bestDist = math.huge
    local bestAreaName = "Forest"

    pcall(function()
        local guardAreas = workspace:FindFirstChild("GuardAreas", true)
        if not guardAreas and workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Areas") then
            guardAreas = workspace.World.Areas:FindFirstChild("GuardAreas")
        end
        if guardAreas then
            for _, area in ipairs(guardAreas:GetChildren()) do
                local guard = area:FindFirstChild("Guard")
                    or area:FindFirstChild("ForestGuardAuthored")
                if guard then
                    local pivot = guard:GetPivot()
                    if pivot then
                        local dist = (pivot.Position - playerPos).Magnitude
                        if dist < bestDist then
                            bestDist = dist
                            bestGuard = guard
                            bestAreaName = area.Name
                        end
                    end
                end
            end
        end
    end)

    return bestGuard, bestAreaName, bestDist
end

local function rouseGuard(guard, areaName)
    areaName = areaName or TARGET_GUARD_AREA
    log("----------------------------------------")
    log(string.format("ROUSING GUARD: %s", tostring(areaName)))

    local event = getRemote("RE/GuardPatrol/Rouse")
    if not event then
        log("ERROR: Remote RE/GuardPatrol/Rouse not found")
        return false
    end

    if not guard then
        log(string.format("ERROR: Guard for '%s' not found", tostring(areaName)))
        return false
    end

    local ok, err = pcall(function()
        if type(firesignal) == "function" then
            firesignal(event.OnClientEvent, guard)
            return true
        elseif type(getconnections) == "function" then
            for _, conn in ipairs(getconnections(event.OnClientEvent)) do
                if conn.Function then
                    task.spawn(conn.Function, guard)
                elseif conn.Fire then
                    conn:Fire(guard)
                end
            end
            return true
        else
            error("Neither firesignal nor getconnections is supported in executor")
        end
    end)

    if not ok then
        log("ERROR: Rouse firesignal failed: " .. tostring(err))
        return false
    end

    log(string.format("Guard '%s' roused successfully via firesignal!", tostring(areaName)))
    return true
end

--==================================================
-- EGG CARRY REQUEST HOOK (AskFieldEggCarry)
--==================================================

local function isHoldingEgg()
    if Character then
        for _, child in ipairs(Character:GetChildren()) do
            local cName = string.lower(child.Name)
            if child:IsA("Tool") and not string.find(cName, "trap", 1, true) then return true end
            if string.find(cName, "egg", 1, true) then return true end
        end
    end
    if Player:GetAttribute("IsCarrying") == true or Player:GetAttribute("HoldingEgg") == true then
        return true
    end
    local cra = workspace:FindFirstChild("ClientRenderedAssets")
    if cra and Player then
        local uidStr = tostring(Player.UserId)
        for _, m in ipairs(cra:GetChildren()) do
            if string.find(m.Name, uidStr, 1, true) then
                return true
            end
        end
    end
    return false
end

local function hookEggCarryRequest()
    -- Intercept AskFieldEggCarry InvokeServer: triggers when you press E and pickup is OK
    if type(hookmetamethod) == "function" then
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if method == "InvokeServer" then
                local name = tostring(self)
                if string.find(name, "AskFieldEggCarry", 1, true) then
                    local callArgs = {...}
                    local results = table.pack(oldNamecall(self, ...))
                    -- If server returns true, egg pickup was successful!
                    if results[1] == true then
                        if callArgs[1] and typeof(callArgs[1]) == "table" and callArgs[1].Uid then
                            cachedEggUid = tostring(callArgs[1].Uid)
                            cachedEggSource = "AskFieldEggCarry Hook"
                            log("[HOOK] Captured Egg UID: " .. cachedEggUid)
                            if EggUidLabel and EggUidLabel.Parent then
                                EggUidLabel.Text = "Egg UID: " .. cachedEggUid
                                EggUidLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
                            end
                        end
                        task.spawn(function()
                            log("----------------------------------------")
                            log("[PICKUP OK] AskFieldEggCarry returned true!")
                            if not Running and isAutoEnabled and runTest then
                                runTest()
                            end
                        end)
                    end
                    return table.unpack(results, 1, results.n)
                end
            end
            return oldNamecall(self, ...)
        end)
        log("Hooked AskFieldEggCarry request listener (__namecall).")
    else
        log("WARN: hookmetamethod unavailable; manual RUN button required.")
    end

    -- Also listen to server confirmation event RE/EggWorld/FieldEggCarry if received
    pcall(function()
        local rem = getRemote("RE/EggWorld/FieldEggCarry")
        if rem and rem:IsA("RemoteEvent") then
            rem.OnClientEvent:Connect(function(...)
                if not Running and isAutoEnabled and runTest then
                    log("[PICKUP OK] FieldEggCarry event received from server!")
                    runTest()
                end
            end)
        end
    end)
end

--==================================================
-- FOREST STRIKE
--==================================================

local function connectForestStrikeInboundLogger(remote)
    if forestStrikeWatchRemote == remote then
        return
    end
    if not remote or not remote:IsA("RemoteEvent") then
        return
    end

    forestStrikeWatchRemote = remote
    remote.OnClientEvent:Connect(function(...)
        local count = select("#", ...)
        log("INBOUND ForestStrike event received (" .. tostring(count) .. " args)")
    end)
    log("Attached listener for inbound ForestStrike events.")
end

local function fireForestStrike()
    log("----------------------------------------")
    log("FOREST STRIKE TRIGGERED")

    local remote = getRemote("RE/GuardPatrol/ForestStrike")
    if not remote then
        log("ERROR: ForestStrike remote (RE/GuardPatrol/ForestStrike) not found")
        return false
    end
    if not remote:IsA("RemoteEvent") then
        log("ERROR: ForestStrike has unexpected class: " .. remote.ClassName)
        return false
    end

    connectForestStrikeInboundLogger(remote)

    if not cachedEggUid or cachedEggUid == "" then
        log("No cached Egg UID. Performing immediate lookup...")
        refreshEggUid(true)
    end

    if not cachedEggUid or cachedEggUid == "" then
        log("ERROR: ForestStrike skipped — no Egg UID available!")
        return false
    end

    -- Guard CFrame: try finding live forest guard or use proven sample
    local guardCFrame = SAMPLE_GUARD_CFRAME
    pcall(function()
        local guard = workspace:FindFirstChild("World", true)
        if guard then
            local forestGuard = guard:FindFirstChild("ForestGuardAuthored", true)
                or guard:FindFirstChild("Forest", true)
            if forestGuard then
                local pivot = forestGuard:GetPivot()
                if pivot then guardCFrame = pivot end
            end
        end
    end)

    local payload = {
        GuardCFrame = guardCFrame,
        EggUid = cachedEggUid,
    }

    log(string.format("Calling ForestStrike:FireServer with EggUid=%s...", cachedEggUid))

    local ok, err = pcall(function()
        remote:FireServer(payload)
    end)

    if not ok then
        log("ERROR: ForestStrike FireServer failed: " .. tostring(err))
        return false
    end

    log("ForestStrike FireServer sent OK!")
    return true
end

--==================================================
-- EGG DROP REMOTE & INVOCATION
--==================================================

local function findEggDropRemote()
    local remote = getRemote("RF/EggWorld/AskFieldEggDrop")
    if remote and remote:IsA("RemoteFunction") then
        return remote, remote:GetFullName()
    end
    return nil, "RF/EggWorld/AskFieldEggDrop not found"
end

local function invokeEggDropSpam(runToken, count)
    count = count or EGG_DROP_SPAM_COUNT

    if runToken ~= nil and runToken ~= RunToken then
        log("AskFieldEggDrop cancelled because this run was stopped or superseded.")
        return false
    end
    if runToken ~= nil and LastEggDropRunToken == runToken then
        log("AskFieldEggDrop already attempted for this run; duplicate request suppressed.")
        return false
    end
    if runToken ~= nil then
        LastEggDropRunToken = runToken
    end

    log(string.format("Looking for RemoteFunction RF/EggWorld/AskFieldEggDrop (Spam %dx)...", count))

    local remote, detail = findEggDropRemote()
    if not remote then
        local message = "AskFieldEggDrop RemoteFunction not found: " .. tostring(detail)
        log(message)
        warn("[EggDrop Diagnostic] " .. message)
        return false
    end

    if not remote:IsA("RemoteFunction") then
        local message = "AskFieldEggDrop has unexpected class: " .. remote.ClassName
        log(message)
        return false
    end

    logCharacterPosition("before AskFieldEggDrop spam sequence")
    log(string.format("Starting AskFieldEggDrop spam (%dx, %.2fs interval)...", count, EGG_DROP_SPAM_INTERVAL))

    for i = 1, count do
        if runToken ~= nil and runToken ~= RunToken then
            log(string.format("AskFieldEggDrop [#%d/%d] cancelled (run superseded)", i, count))
            break
        end
        if not Running then
            log(string.format("AskFieldEggDrop [#%d/%d] cancelled (test stopped)", i, count))
            break
        end

        task.spawn(function()
            local sendPos = Root and Root.Parent and Root.Position
            local ok, result = pcall(function()
                return remote:InvokeServer({ Reason = "PlayerRequest" })
            end)
            if not ok or result == false then
                pcall(function()
                    local res2 = remote:InvokeServer()
                    if res2 ~= nil then
                        result = res2
                        ok = true
                    end
                end)
            end

            local statusStr = ok and tostring(result) or ("ERROR: " .. tostring(result))
            log(string.format(
                "AskFieldEggDrop [#%d/%d] returned: %s | pos=%s",
                i,
                count,
                statusStr,
                vec(sendPos)
            ))
        end)

        if i < count then
            task.wait(EGG_DROP_SPAM_INTERVAL)
        end
    end

    logCharacterPosition("after AskFieldEggDrop spam sequence")
    return true
end

--==================================================
-- STOP SAFELY ON CHARACTER LOSS
--==================================================

local function stopTest()
    Running = false
    RunToken += 1

    if Root and Root.Parent then
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
    end

    wasHolding = false
    autoCooldown = false

    Status.Text =
        "Status: Stopped"
end

--==================================================
-- RUN
--==================================================

runTest = function()

    if Running then
        return
    end

    if not SavedLocation then
        Status.Text =
            "Status: Set Drop/Landing Location first"
        return
    end

    refreshCharacter()

    if not Root or not Humanoid then
        Status.Text =
            "Status: Character unavailable"
        return
    end

    Running = true
    RunToken += 1
    local currentRunToken = RunToken
    TestStartTime = os.clock()
    LastTrace = 0

    --------------------------------------------------
    -- START
    --------------------------------------------------

    StartLocation = Root.Position

    log("----------------------------------------")
    log("TEST START")

    log(
        "START = "
        .. vec(StartLocation)
    )

    log(
        "DROP / LANDING = "
        .. vec(SavedLocation)
    )

    --------------------------------------------------
    -- BIOME DETECTION & GUARD ROUSE
    --------------------------------------------------

    local guard, detectedArea, guardDist = getClosestGuard(StartLocation)
    TARGET_GUARD_AREA = detectedArea or "Forest"
    if GuardLabel and GuardLabel.Parent then
        GuardLabel.Text = string.format("Guard: %s (%.0fst)", TARGET_GUARD_AREA, guardDist or 0)
    end

    Phase = "GUARD ROUSE & WAIT"
    Status.Text = string.format("Status: Waiting %s hit (%.3fs)...", TARGET_GUARD_AREA, GUARD_HIT_TIMING)

    log(string.format("PHASE = GUARD ROUSE & WAIT (Target: %s, Dist: %.1f studs)", TARGET_GUARD_AREA, guardDist or 0))
    log(string.format("Timing delay assumption: %.3fs", GUARD_HIT_TIMING))

    local rouseT0 = os.clock()
    local struck = false
    local strikeSource = "none"
    local strikeTime = 0
    local tempConns = {}

    local function onStrike(source)
        if not struck then
            struck = true
            strikeSource = source
            strikeTime = os.clock()
            log(string.format("STRIKE TRIGGERED! Source: %s (+%.4fs from Rouse)", tostring(source), strikeTime - rouseT0))
        end
    end

    local function finishRun(success, dist)
        Running = false
        Phase = success and "SUCCESS" or "FAILED"

        if not success then
            local oldTiming = GUARD_HIT_TIMING
            if not struck then
                local step = 0.025
                GUARD_HIT_TIMING = math.clamp(math.floor((GUARD_HIT_TIMING + step) * 1000 + 0.5) / 1000, 0.450, 0.850)
                updateTimingUI()

                Status.Text = string.format("Too early! Timing -> %.3fs (Press E)", GUARD_HIT_TIMING)
                Status.TextColor3 = Color3.fromRGB(255, 120, 120)
                log("----------------------------------------")
                log(string.format("RESULT: FAILED — Snapped back to %s (%.1f studs from drop).", TARGET_GUARD_AREA, dist))
                log(string.format("[DIAGNOSIS] Guard strike was NOT detected before timeout (%.3fs). Teleport occurred TOO EARLY!", oldTiming))
                log(string.format("[AUTO-ADJUST] Timing auto-increased to %.3fs (+%.3fs).", GUARD_HIT_TIMING, step))
                log(string.format("[NEXT] Press E on egg in %s to retry at %.3fs!", TARGET_GUARD_AREA, GUARD_HIT_TIMING))
            else
                local step = 0.020
                GUARD_HIT_TIMING = math.clamp(math.floor((GUARD_HIT_TIMING - step) * 1000 + 0.5) / 1000, 0.400, 0.850)
                updateTimingUI()

                Status.Text = string.format("Too late! Timing -> %.3fs (Press E)", GUARD_HIT_TIMING)
                Status.TextColor3 = Color3.fromRGB(255, 160, 100)
                log("----------------------------------------")
                log(string.format("RESULT: FAILED — Snapped back despite strike (%s).", tostring(strikeSource)))
                log("[DIAGNOSIS] Strike registered but hit authority expired before drop completed.")
                log(string.format("[AUTO-ADJUST] Timing auto-lowered to %.3fs (-%.3fs).", oldTiming, GUARD_HIT_TIMING, step))
                log(string.format("[NEXT] Press E on egg in %s to retry at %.3fs!", TARGET_GUARD_AREA, GUARD_HIT_TIMING))
            end
        else
            Status.Text = string.format("Success! Landed at drop (Timing: %.3fs)", GUARD_HIT_TIMING)
            Status.TextColor3 = Color3.fromRGB(150, 255, 150)
            log("----------------------------------------")
            log(string.format("RESULT: SUCCESS — Replicated at drop location (error: %.2f studs)!", dist))
            log(string.format("[SAVED] Winning timing verified: %.3fs! Egg dropped into pen.", GUARD_HIT_TIMING))
        end

        log("TEST END")
        log("----------------------------------------")
    end

    local function checkMotorsDisabled(ch)
        if not ch then return false end
        local off = 0
        for _, m in ipairs(ch:GetDescendants()) do
            if m:IsA("Motor6D") and not m.Enabled then
                off = off + 1
                if off >= 2 then return true end
            end
        end
        return false
    end

    -- Hook hit / damage / ragdoll detection listeners
    pcall(function()
        local net = ReplicatedStorage:FindFirstChild("Packages")
            and ReplicatedStorage.Packages:FindFirstChild("Networking")
        if net then
            local fToll = net:FindFirstChild("RE/GuardPatrol/SpeedTollOffer")
            if fToll and fToll:IsA("RemoteEvent") then
                table.insert(tempConns, fToll.OnClientEvent:Connect(function() onStrike("SpeedTollOffer") end))
            end
            local fWarn = net:FindFirstChild("RE/GuardPatrol/SpeedTollWarning")
            if fWarn and fWarn:IsA("RemoteEvent") then
                table.insert(tempConns, fWarn.OnClientEvent:Connect(function() onStrike("SpeedTollWarning") end))
            end
            local fHazard = net:FindFirstChild("RE/BossEvent/HazardHit")
            if fHazard and fHazard:IsA("RemoteEvent") then
                table.insert(tempConns, fHazard.OnClientEvent:Connect(function() onStrike("HazardHit") end))
            end
            local fStrike = net:FindFirstChild("RE/GuardPatrol/ForestStrike")
            if fStrike and fStrike:IsA("RemoteEvent") then
                table.insert(tempConns, fStrike.OnClientEvent:Connect(function() onStrike("ForestStrike") end))
            end
            local fHandoff = net:FindFirstChild("RE/GuardPatrol/ForestHandoff")
            if fHandoff and fHandoff:IsA("RemoteEvent") then
                table.insert(tempConns, fHandoff.OnClientEvent:Connect(function() onStrike("ForestHandoff") end))
            end
        end
    end)

    local baselineRagdoll = Player:GetAttribute("RagdollEndTime") or 0
    if typeof(baselineRagdoll) ~= "number" then baselineRagdoll = 0 end
    table.insert(tempConns, Player.AttributeChanged:Connect(function(attr)
        if attr == "RagdollEndTime" then
            local v = Player:GetAttribute("RagdollEndTime") or 0
            if typeof(v) == "number" and v > baselineRagdoll + 0.15 then
                onStrike("PlayerRagdollEndTime:" .. string.format("%.2f", v))
            end
        end
    end))

    if Character then
        local charBaselineRagdoll = Character:GetAttribute("RagdollEndTime") or 0
        if typeof(charBaselineRagdoll) ~= "number" then charBaselineRagdoll = 0 end
        table.insert(tempConns, Character.AttributeChanged:Connect(function(attr)
            if attr == "RagdollEndTime" then
                local v = Character:GetAttribute("RagdollEndTime") or 0
                if typeof(v) == "number" and v > charBaselineRagdoll + 0.15 then
                    onStrike("CharRagdollEndTime:" .. string.format("%.2f", v))
                end
            elseif attr == "IsRagdolled" or attr == "Ragdoll" then
                if Character:GetAttribute(attr) == true then
                    onStrike("CharAttr:" .. attr)
                end
            end
        end))
    end

    if Humanoid then
        table.insert(tempConns, Humanoid.StateChanged:Connect(function(_, newState)
            if newState == Enum.HumanoidStateType.Physics
                or newState == Enum.HumanoidStateType.Ragdoll
                or newState == Enum.HumanoidStateType.FallingDown
                or newState == Enum.HumanoidStateType.Dead then
                onStrike("HumanoidState:" .. newState.Name)
            end
        end))
    end

    -- Trigger Rouse on local biome guard
    rouseGuard(guard, TARGET_GUARD_AREA)

    -- Wait timing delay (or proceed if early strike confirmed)
    if GUARD_HIT_TIMING > 0 then
        local waitStart = os.clock()
        while Running and (os.clock() - waitStart < GUARD_HIT_TIMING) do
            -- Continuous physical indicator polling
            if Root and Root.Parent then
                if Root.AssemblyLinearVelocity.Magnitude > 12 then
                    onStrike("VelocityKnockback:" .. string.format("%.1f", Root.AssemblyLinearVelocity.Magnitude))
                elseif StartLocation and (Root.Position - StartLocation).Magnitude > 3.0 then
                    onStrike("Displaced:" .. string.format("%.1f", (Root.Position - StartLocation).Magnitude))
                elseif checkMotorsDisabled(Character) then
                    onStrike("MotorsDisabled")
                elseif Humanoid then
                    local st = Humanoid:GetState()
                    if st == Enum.HumanoidStateType.Physics
                        or st == Enum.HumanoidStateType.Ragdoll
                        or st == Enum.HumanoidStateType.FallingDown then
                        onStrike("PolledState:" .. st.Name)
                    end
                end
            end

            if struck then
                log(string.format("Strike confirmed during wait window at +%.4fs! (%s) Proceeding...", os.clock() - waitStart, tostring(strikeSource)))
                break
            end
            RunService.Heartbeat:Wait()
        end
    end

    -- Cleanup hit listeners
    for _, conn in ipairs(tempConns) do
        pcall(function() conn:Disconnect() end)
    end

    if not Running then
        return
    end

    -- Verify egg is still held before teleporting
    local isHeld = isHoldingEgg()
    log(string.format("Pre-teleport egg status: holding=%s", tostring(isHeld)))
    if not isHeld then
        log("[WARN] Egg is not held before teleport! (Guard may have stripped it early)")
    end

    --------------------------------------------------
    -- POSITION AT DROP
    --------------------------------------------------

    Phase = "DROP POSITION"
    Status.Text =
        "Status: Drop position"

    log("PHASE = DROP POSITION")

    Root.CFrame =
        CFrame.new(SavedLocation)

    Root.AssemblyLinearVelocity =
        Vector3.zero

    Root.AssemblyAngularVelocity =
        Vector3.zero

    log(
        "DROP POSITIONED | pos="
        .. vec(Root.Position)
    )

    -- Trigger AskFieldEggDrop spam immediately so the drop request arrives
    -- while server hit authority / knockback is still active!
    task.spawn(function()
        invokeEggDropSpam(currentRunToken, EGG_DROP_SPAM_COUNT)
    end)

    -- Allow position replication to settle on the server before dropping
    if POSITION_SETTLE_TIME > 0 then
        Status.Text =
            "Status: Replicating position..."
        log(string.format("HOLD / REPLICATING POSITION (%.2fs)...", POSITION_SETTLE_TIME))

        local settleStart = os.clock()
        while Running and (os.clock() - settleStart < POSITION_SETTLE_TIME) do
            Root.CFrame = CFrame.new(SavedLocation)
            Root.AssemblyLinearVelocity = Vector3.zero
            Root.AssemblyAngularVelocity = Vector3.zero
            RunService.Heartbeat:Wait()
        end
    end

    -- Check if position held or rubberbanded during hold
    local distFromDrop = (Root.Position - SavedLocation).Magnitude
    if distFromDrop > 50 then
        log(string.format("[WARN] RUBBERBAND DETECTED DURING HOLD! pos=%s (%.1f studs from drop).", vec(Root.Position), distFromDrop))
        finishRun(false, distFromDrop)
        return
    else
        log(string.format("[OK] Position held at drop location (dist=%.2f studs). Hit authority active!", distFromDrop))
    end

    --------------------------------------------------
    -- INITIAL FREEFALL
    --------------------------------------------------

    Phase = "FREEFALL"
    Status.Text =
        "Status: Freefall"

    log("PHASE = FREEFALL")

    Humanoid:ChangeState(
        Enum.HumanoidStateType.Freefall
    )

    local fallStart =
        os.clock()

    local lastTime =
        fallStart

    local velocityY =
        INITIAL_VERTICAL_SPEED

    log(
        "FREEFALL START | pos="
        .. vec(Root.Position)
        .. " | vel="
        .. vec(Root.AssemblyLinearVelocity)
    )

    -- Trigger AskFieldEggDrop spam during freefall without blocking the physics loop
    task.spawn(function()
        invokeEggDropSpam(currentRunToken, EGG_DROP_SPAM_COUNT)
    end)

    while Running do

        local now =
            os.clock()

        local elapsed =
            now - fallStart

        if elapsed >= INITIAL_FREEFALL_TIME then
            break
        end

        local dt =
            now - lastTime

        if dt > 0 then
            velocityY =
                velocityY
                + FALL_ACCELERATION * dt

            Root.AssemblyLinearVelocity =
                Vector3.new(
                    0,
                    velocityY,
                    0
                )
        end

        lastTime = now

        trace("FREEFALL")

        RunService.Heartbeat:Wait()
    end

    if not Running then
        return
    end

    log(
        "FREEFALL END | elapsed="
        .. string.format(
            "%.4f",
            os.clock() - fallStart
        )
        .. " | pos="
        .. vec(Root.Position)
        .. " | vel="
        .. vec(Root.AssemblyLinearVelocity)
    )

    --------------------------------------------------
    -- LOCAL DROP TRANSITION
    --------------------------------------------------

    Phase = "DROP TRANSITION"
    Status.Text =
        "Status: Drop transition"

    log(
        "PHASE = DROP TRANSITION"
    )

    local entry =
        SavedLocation
        + Vector3.new(
            0,
            ENTRY_HEIGHT,
            0
        )

    local previous =
        Root.Position

    Root.CFrame =
        CFrame.new(entry)

    Root.AssemblyLinearVelocity =
        Vector3.new(
            0,
            FINAL_VERTICAL_SPEED,
            0
        )

    Root.AssemblyAngularVelocity =
        Vector3.zero

    Humanoid:ChangeState(
        Enum.HumanoidStateType.Freefall
    )

    log(
        "LOCAL DROP TRANSITION"
        .. " | previous="
        .. vec(previous)
        .. " | entry="
        .. vec(entry)
        .. " | distance="
        .. string.format(
            "%.3f",
            (entry - previous).Magnitude
        )
    )

    --------------------------------------------------
    -- FINAL DESCENT
    --------------------------------------------------

    Phase = "FINAL DESCENT"
    Status.Text =
        "Status: Final descent"

    log("PHASE = FINAL DESCENT")

    local descentStart =
        os.clock()

    local lastDescentTime =
        descentStart

    local descentVelocity =
        FINAL_VERTICAL_SPEED

    while Running do

        local now =
            os.clock()

        if now - descentStart >= MAX_DESCENT_TIME then

            log(
                "FINAL DESCENT TIMEOUT"
            )

            local curDist = (Root.Position - SavedLocation).Magnitude
            finishRun(curDist <= 50, curDist)
            return
        end

        local current =
            Root.Position

        local difference =
            current.Y - SavedLocation.Y

        if difference <= 0.15 then
            break
        end

        local dt =
            now - lastDescentTime

        if dt > 0 then
            descentVelocity =
                math.max(
                    descentVelocity
                    + FALL_ACCELERATION * 0.20 * dt,
                    -32
                )

            Root.AssemblyLinearVelocity =
                Vector3.new(
                    0,
                    descentVelocity,
                    0
                )
        end

        lastDescentTime = now

        trace("FINAL DESCENT")

        RunService.Heartbeat:Wait()
    end

    if not Running then
        return
    end

    --------------------------------------------------
    -- LAND
    --------------------------------------------------

    Phase = "LANDING"

    Status.Text =
        "Status: Landing"

    log("PHASE = LANDING")

    Root.CFrame =
        CFrame.new(SavedLocation)

    Root.AssemblyLinearVelocity =
        Vector3.zero

    Root.AssemblyAngularVelocity =
        Vector3.zero

    Humanoid:ChangeState(
        Enum.HumanoidStateType.Landed
    )

    log(
        "LANDED | final="
        .. vec(Root.Position)
    )

    log(
        "START="
        .. vec(StartLocation)
    )

    log(
        "DROP/LANDING="
        .. vec(SavedLocation)
    )

    log(
        "TOTAL TIME="
        .. string.format(
            "%.4f",
            os.clock() - TestStartTime
        )
    )

    Running = false
    Phase = "LANDED"

    local finalDist = (Root.Position - SavedLocation).Magnitude
    finishRun(finalDist <= 50, finalDist)
end

RunButton.MouseButton1Click:Connect(function()
    runTest()
end)

RouseOnlyButton.MouseButton1Click:Connect(function()
    if Running then
        Status.Text = "Status: Test is running"
        return
    end
    Status.Text = "Status: Testing Rouse..."
    refreshCharacter()
    local pos = (Root and Root.Position) or Vector3.zero
    local guard, areaName, dist = getClosestGuard(pos)
    if guard then
        TARGET_GUARD_AREA = areaName
        local ok = rouseGuard(guard, areaName)
        if ok then
            Status.Text = string.format("Status: %s Guard roused!", areaName)
        else
            Status.Text = "Status: Rouse failed (see log)"
        end
    else
        Status.Text = "Status: No guard nearby"
    end
end)

StopButton.MouseButton1Click:Connect(function()
    if Running then
        stopTest()
        Status.Text = "Status: Stopped"
        log("Test stopped by user.")
    end
end)

CopyButton.MouseButton1Click:Connect(copyLog)

--==================================================
-- INIT
--==================================================

hookEggCarryRequest()
updateTimingUI()

local initPing = getPingMs()
log("Guard Drop Tester loaded")
log("Landing location preset to " .. vec(SavedLocation))
log("Focus Biome Guard: Dynamic closest area (RE/GuardPatrol/Rouse)")
log(string.format("Initial Timing delay: %.3fs (live ping: %dms; adjust with [-]/[+] buttons)", GUARD_HIT_TIMING, initPing))
log("Press E on egg in any area:")
log(" -> When request returns true, timing wait begins & hit is verified!")
log(" -> If timed out before hit, timing steps up. If strike expired, timing steps down.")