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

local POSITION_SETTLE_TIME = 0.30

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

local cachedEggUid = nil
local cachedEggSource = nil
local isRefreshingEggUid = false
local forestStrikeWatchRemote = nil

local TestStartTime = 0
local LastTrace = 0

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
Main.Size = UDim2.fromOffset(285, 235)
Main.Position = UDim2.new(0.5, -142, 0.5, -117)

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
Title.Text = "Drop / Freefall Tester"

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

TitleBar.InputEnded:Connect(function(input)
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
-- LOCATION LABEL
--==================================================

local LocationLabel = Instance.new("TextLabel")
LocationLabel.Size = UDim2.new(1, -16, 0, 26)
LocationLabel.Position = UDim2.fromOffset(8, 38)
LocationLabel.BackgroundTransparency = 1
LocationLabel.Text = "Drop/Landing: " .. (SavedLocation and vec(SavedLocation) or "NOT SET")
LocationLabel.TextColor3 = Color3.fromRGB(215, 215, 215)
LocationLabel.TextSize = 12
LocationLabel.Font = Enum.Font.SourceSans
LocationLabel.TextWrapped = true
LocationLabel.TextXAlignment = Enum.TextXAlignment.Left
LocationLabel.TextYAlignment = Enum.TextYAlignment.Top
LocationLabel.Parent = Main

--==================================================
-- EGG UID LABEL
--==================================================

local EggUidLabel = Instance.new("TextLabel")
EggUidLabel.Size = UDim2.new(1, -16, 0, 22)
EggUidLabel.Position = UDim2.fromOffset(8, 64)
EggUidLabel.BackgroundTransparency = 1
EggUidLabel.Text = "Egg UID: loading..."
EggUidLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
EggUidLabel.TextSize = 11
EggUidLabel.Font = Enum.Font.SourceSans
EggUidLabel.TextWrapped = true
EggUidLabel.TextXAlignment = Enum.TextXAlignment.Left
EggUidLabel.Parent = Main

--==================================================
-- STATUS
--==================================================

local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, -16, 0, 22)
Status.Position = UDim2.fromOffset(8, 88)
Status.BackgroundTransparency = 1
Status.Text = "Status: Idle"
Status.TextColor3 = Color3.fromRGB(150, 220, 150)
Status.TextSize = 12
Status.Font = Enum.Font.SourceSans
Status.TextWrapped = true
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.Parent = Main

--==================================================
-- BUTTON CREATOR
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
        114,
        UDim2.new(0.58, -10, 0, 30),
        30,
        Color3.fromRGB(65, 90, 135)
    )

local RefreshIdButton =
    makeButton(
        "REFRESH ID",
        0,
        114,
        UDim2.new(0.42, -6, 0, 30),
        30,
        Color3.fromRGB(40, 85, 130)
    )
RefreshIdButton.Position = UDim2.new(0.58, 2, 0, 114)

local RunButton =
    makeButton(
        "RUN: STRIKE → DROP → LAND",
        8,
        150,
        UDim2.new(1, -16, 0, 32),
        32,
        Color3.fromRGB(45, 125, 65)
    )

local CopyButton =
    makeButton(
        "COPY LOG",
        8,
        188,
        UDim2.new(1, -16, 0, 28),
        28,
        Color3.fromRGB(50, 90, 160)
    )

--==================================================
-- SET LOCATION
--==================================================

SetLocationButton.MouseButton1Click:Connect(function()
    if Running then
        Status.Text =
            "Status: Stop the current test first"
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
        "Drop/Landing: " .. vec(SavedLocation)

    Status.Text =
        "Status: Location saved"

    log(
        "DROP / LANDING LOCATION = "
        .. vec(SavedLocation)
    )
end)

RefreshIdButton.MouseButton1Click:Connect(function()
    refreshEggUid()
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

    Status.Text =
        "Status: Stopped"
end

--==================================================
-- RUN
--==================================================

local function runTest()

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
    -- FOREST STRIKE (FIRST TRIGGER ON RUN)
    --------------------------------------------------

    Phase = "FOREST STRIKE"
    Status.Text =
        "Status: Forest Strike"

    log("PHASE = FOREST STRIKE")

    fireForestStrike()

    task.wait(0.05)

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

            stopTest()
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

    Status.Text =
        "Status: Landed"

    log("TEST END")
    log("----------------------------------------")
end

RunButton.MouseButton1Click:Connect(runTest)

CopyButton.MouseButton1Click:Connect(copyLog)

--==================================================
-- INIT
--==================================================

log("One-location Drop / Freefall Tester loaded")
log("Landing location preset to " .. vec(SavedLocation))
log("RUN automatically captures START location")
log("ForestStrike triggers FIRST on RUN press")
log(string.format("Position settles (%.2fs) then EggDrop (%dx spam)", POSITION_SETTLE_TIME, EGG_DROP_SPAM_COUNT))

-- Automatically query egg UID on script startup
task.defer(function()
    refreshEggUid()
end)