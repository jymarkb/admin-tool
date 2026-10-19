--[[
    MOVE TO TARGET XYZ — CACHED FOREST UID + TEXT LOG

    Standalone LocalScript for Roblox Studio / an experience you own or are
    authorized to test. It adds an on-screen client log and makes at most one
    ForestStrike FireServer test call per FLY run, using the cached Forest egg UID.
    After the successful CFrame move, it sends one ForestStrike test attempt,
    then makes one AskFieldEggDrop request immediately if the client send returned
    without a local error. This ordering is best-effort:
    client-side code cannot confirm that the server accepted ForestStrike first.

    The UI shows the live HumanoidRootPart position, and the log can be selected
    for manual copying with Ctrl+C. Standard Roblox LocalScripts cannot write to
    the OS clipboard directly.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    error("This must run as a LocalScript.")
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local TARGET_POSITION = Vector3.new(961.665, 70.724, -409.558)
local MAX_LOG_LINES = 250
local GUI_NAME = "ForestStrikeTargetXYZ"

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local isFlying = false
local isStartingFlight = false
local flightToken = 0
local activeConstraint = nil
local activeAttachment = nil
local statusLabel
local flyButton
local logScroll
local logLayout
local logLabels = {}
local logHistory = {}
local positionLabel
local logCharacterPosition -- forward declaration used by the egg-drop request helper
local logPositionButton
local copyLogButton
local copyFrame
local copyTextBox
local copyStatusLabel
local copyCloseButton
local actionSequenceRunning = false
local lastEggDropRunToken = nil
local forestStrikeWatchRemote = nil
local ragdollState = nil

-- Forest egg UID is loaded once and reused for each hit attempt until REFRESH ID.
local cachedForestEggUid = nil
local cachedForestEggSource = nil
local isRefreshingForestEggUid = false
local refreshIdButton
local eggUidLabel

local function setStatus(message, color)
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = message
        statusLabel.TextColor3 = color or Color3.fromRGB(190, 220, 255)
    end
end


-- Single-LocalScript diagnostic panel. These are client-side observations only;
-- FireServer does not return a server receipt or server-side acceptance result.
local function addTextLog(message, color)
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(message))
    table.insert(logHistory, line)
    while #logHistory > MAX_LOG_LINES do
        table.remove(logHistory, 1)
    end
    print("[ForestStrike Diagnostic] " .. line)

    if not logScroll or not logScroll.Parent or not logLayout then
        return
    end

    local row = Instance.new("TextLabel")
    row.Name = "LogEntry"
    row.BackgroundTransparency = 1
    row.BorderSizePixel = 0
    row.Size = UDim2.new(1, -8, 0, 16)
    row.AutomaticSize = Enum.AutomaticSize.Y
    row.Font = Enum.Font.Code
    row.TextSize = 10
    row.TextColor3 = color or Color3.fromRGB(205, 215, 230)
    row.TextXAlignment = Enum.TextXAlignment.Left
    row.TextYAlignment = Enum.TextYAlignment.Top
    row.TextWrapped = true
    row.Text = line
    row.Parent = logScroll

    table.insert(logLabels, row)
    while #logLabels > 35 do
        local old = table.remove(logLabels, 1)
        if old and old.Parent then
            old:Destroy()
        end
    end

    task.defer(function()
        if logScroll and logScroll.Parent and logLayout then
            logScroll.CanvasSize = UDim2.new(0, 0, 0, logLayout.AbsoluteContentSize.Y + 8)
            local maxY = math.max(0, logLayout.AbsoluteContentSize.Y - logScroll.AbsoluteWindowSize.Y)
            logScroll.CanvasPosition = Vector2.new(0, maxY)
        end
    end)
end


----------------------------------------------------------------
-- POST-FLIGHT DROP REQUEST
-- The scanner reports a single Networking child named
-- "RF/EggWorld/AskFieldEggDrop" (slashes are part of the name). The request
-- is made once per successful flight, not in a retry/spam loop.
----------------------------------------------------------------
local function findEggDropRemote()
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    local packages = ReplicatedStorage:FindFirstChild("Packages")
        or ReplicatedStorage:WaitForChild("Packages", 5)
    local networking = packages and (
        packages:FindFirstChild("Networking")
        or packages:WaitForChild("Networking", 5)
    )

    if not networking then
        return nil, "ReplicatedStorage.Packages.Networking was not found"
    end

    -- The scanner log reports this as one child name containing slashes:
    -- ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggDrop"]
    -- Check that flattened name FIRST; treating RF/EggWorld as nested folders
    -- will not find it in this game's networking layout.
    local flattened = networking:FindFirstChild("RF/EggWorld/AskFieldEggDrop")
    if flattened and flattened:IsA("RemoteFunction") then
        return flattened, flattened:GetFullName()
    end

    -- Compatibility fallback in case a later version uses nested folders.
    local rfFolder = networking:FindFirstChild("RF")
    local eggWorld = rfFolder and rfFolder:FindFirstChild("EggWorld")
    local nested = eggWorld and eggWorld:FindFirstChild("AskFieldEggDrop")
    if nested and nested:IsA("RemoteFunction") then
        return nested, nested:GetFullName()
    end

    -- Last fallback: search for either known exact instance name, and do not
    -- select a similarly named object of the wrong class.
    for _, item in ipairs(networking:GetDescendants()) do
        if item:IsA("RemoteFunction") and (
            item.Name == "AskFieldEggDrop"
            or item.Name == "RF/EggWorld/AskFieldEggDrop"
        ) then
            return item, item:GetFullName()
        end
    end

    return nil, networking:GetFullName() .. " (checked flattened and nested paths)"
end

local function invokeEggDropOnce(runToken)
    if runToken ~= nil and runToken ~= flightToken then
        addTextLog("AskFieldEggDrop cancelled because this run was stopped or superseded.", Color3.fromRGB(255, 175, 135))
        return false
    end
    if runToken ~= nil and lastEggDropRunToken == runToken then
        addTextLog("AskFieldEggDrop already attempted for this run; duplicate request suppressed.", Color3.fromRGB(255, 205, 130))
        return false
    end
    if runToken ~= nil then
        lastEggDropRunToken = runToken
    end

    logCharacterPosition("immediately before AskFieldEggDrop")
    setStatus("Looking for AskFieldEggDrop...", Color3.fromRGB(255, 200, 120))
    addTextLog("Looking for RemoteFunction RF/EggWorld/AskFieldEggDrop...", Color3.fromRGB(255, 205, 130))

    local remote, detail = findEggDropRemote()
    if not remote then
        local message = "AskFieldEggDrop RemoteFunction not found: " .. tostring(detail)
        setStatus(message, Color3.fromRGB(255, 175, 135))
        addTextLog(message, Color3.fromRGB(255, 125, 125))
        warn("[ForestStrike Diagnostic] " .. message)
        return false
    end

    if not remote:IsA("RemoteFunction") then
        local message = "AskFieldEggDrop has unexpected class: " .. remote.ClassName
        setStatus(message, Color3.fromRGB(255, 125, 125))
        addTextLog(message, Color3.fromRGB(255, 125, 125))
        return false
    end

    setStatus("Calling AskFieldEggDrop once...", Color3.fromRGB(255, 200, 120))
    addTextLog("Invoking RemoteFunction: " .. detail .. " with {Reason = PlayerRequest}.", Color3.fromRGB(255, 205, 130))

    local ok, result = pcall(function()
        return remote:InvokeServer({ Reason = "PlayerRequest" })
    end)

    if not ok then
        local message = "AskFieldEggDrop InvokeServer error: " .. tostring(result)
        setStatus(message, Color3.fromRGB(255, 125, 125))
        addTextLog(message, Color3.fromRGB(255, 125, 125))
        warn("[ForestStrike Diagnostic] " .. message)
        return false
    end

    local resultText = tostring(result)
    addTextLog("AskFieldEggDrop InvokeServer returned: " .. resultText, result == false and Color3.fromRGB(255, 175, 135) or Color3.fromRGB(130, 255, 170))
    if result == false then
        setStatus("AskFieldEggDrop returned false; inspect server-side preconditions.", Color3.fromRGB(255, 175, 135))
    else
        setStatus("AskFieldEggDrop returned: " .. resultText .. " (server action not guaranteed).", Color3.fromRGB(255, 200, 120))
    end
    addTextLog("A returned value only confirms the RemoteFunction returned; it does not prove the desired game state changed.", Color3.fromRGB(255, 205, 130))
    logCharacterPosition("after AskFieldEggDrop")
    return true
end


----------------------------------------------------------------
-- FORESTSTRIKE TEST (one event send, client text log only)
----------------------------------------------------------------
local SAMPLE_GUARD_CFRAME = CFrame.new(
    605.572266, 69.3371735, -325.887329,
    0.70000118, 0, -0.714141667,
    0, 1, 0,
    0.714141667, 0, 0.70000118
)

-- Support both flattened networking child names (slashes in the name) and
-- normal nested folders. Only exact requested paths are considered first.
local function getRemote(subPath)
    local packages = ReplicatedStorage:FindFirstChild("Packages")
        or ReplicatedStorage:WaitForChild("Packages", 5)
    local networking = packages and (packages:FindFirstChild("Networking")
        or packages:WaitForChild("Networking", 5))
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
    return nil
end

local function isEggAvailable(record)
    local carrier = record.CarrierUserId or record.carrierUserId
    return carrier == nil or carrier == 0 or carrier == "" or carrier == "0"
end

local function findAnyForestEggUid()
    addTextLog("Looking for an available Forest egg UID...")
    local snapshotRemote = getRemote("RF/EggWorld/AskFieldEggSnapshot")

    if snapshotRemote and snapshotRemote:IsA("RemoteFunction") then
        addTextLog("Found AskFieldEggSnapshot; requesting one snapshot...")
        local ok, result = pcall(function()
            return snapshotRemote:InvokeServer()
        end)

        if ok and typeof(result) == "table" then
            local records = result.Records or result.records
            if typeof(records) == "table" then
                for _, record in pairs(records) do
                    if typeof(record) == "table" then
                        local uid = record.Uid or record.uid or record.UID or record.Id or record.id
                        local area = record.AreaId or record.areaId or record.Area or record.Biome or record.biome
                        local uidText = tostring(uid or "")
                        local areaText = string.lower(tostring(area or ""))
                        local uidLower = string.lower(uidText)
                        local isForest = areaText == "forest"
                            or string.find(uidLower, "_forest:slot_", 1, true) ~= nil

                        if uid and uidText ~= "" and isForest and isEggAvailable(record) then
                            addTextLog("Selected Forest UID from AskFieldEggSnapshot: " .. uidText, Color3.fromRGB(170, 225, 255))
                            return uidText, "AskFieldEggSnapshot"
                        end
                    end
                end
            else
                addTextLog("Snapshot returned no Records/records table.", Color3.fromRGB(255, 205, 130))
            end
        elseif not ok then
            addTextLog("ERROR: AskFieldEggSnapshot failed: " .. tostring(result), Color3.fromRGB(255, 125, 125))
        else
            addTextLog("Snapshot returned an unexpected type: " .. typeof(result), Color3.fromRGB(255, 205, 130))
        end
    else
        addTextLog("AskFieldEggSnapshot RemoteFunction not found; trying client slot names.", Color3.fromRGB(255, 205, 130))
    end

    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        for _, slot in ipairs(slots:GetChildren()) do
            local nameLower = string.lower(slot.Name)
            if string.find(nameLower, "_forest:slot_", 1, true) then
                addTextLog("Selected Forest UID from AreaEggSlotsClient: " .. slot.Name, Color3.fromRGB(170, 225, 255))
                return slot.Name, "Workspace.AreaEggSlotsClient"
            end
        end
    else
        addTextLog("Workspace.AreaEggSlotsClient not found.", Color3.fromRGB(255, 205, 130))
    end

    return nil, "No Forest UID was found in AskFieldEggSnapshot or AreaEggSlotsClient"
end

-- Refresh is the only path that performs a new scan. Fire/hit uses the cached UID.
local function refreshForestEggUid()
    if isRefreshingForestEggUid then
        addTextLog("Refresh already in progress; waiting for the current UID lookup.", Color3.fromRGB(255, 205, 130))
        return
    end

    isRefreshingForestEggUid = true
    if refreshIdButton and refreshIdButton.Parent then
        refreshIdButton.Active = false
        refreshIdButton.AutoButtonColor = false
        refreshIdButton.Text = "LOADING..."
    end
    addTextLog("Refreshing cached Forest egg UID...", Color3.fromRGB(120, 220, 255))

    local ok, uid, source = pcall(findAnyForestEggUid)
    if ok and uid and tostring(uid) ~= "" then
        cachedForestEggUid = tostring(uid)
        cachedForestEggSource = tostring(source or "unknown source")
        if eggUidLabel and eggUidLabel.Parent then
            eggUidLabel.Text = "Cached Forest UID: " .. cachedForestEggUid
            eggUidLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
        end
        addTextLog("Cached Forest UID loaded: " .. cachedForestEggUid .. " (" .. cachedForestEggSource .. ")", Color3.fromRGB(130, 255, 170))
    else
        local reason = ok and tostring(source or "no Forest UID found") or tostring(uid)
        addTextLog("UID refresh failed: " .. reason, Color3.fromRGB(255, 125, 125))
        if cachedForestEggUid then
            addTextLog("Keeping previous cached UID: " .. cachedForestEggUid, Color3.fromRGB(255, 205, 130))
        else
            if eggUidLabel and eggUidLabel.Parent then
                eggUidLabel.Text = "Cached Forest UID: NOT LOADED — press REFRESH ID"
                eggUidLabel.TextColor3 = Color3.fromRGB(255, 185, 130)
            end
        end
    end

    isRefreshingForestEggUid = false
    if refreshIdButton and refreshIdButton.Parent then
        refreshIdButton.Active = true
        refreshIdButton.AutoButtonColor = true
        refreshIdButton.Text = "REFRESH ID"
    end
end

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
        addTextLog("INBOUND ForestStrike event reached this client (" .. tostring(count) .. " argument(s)); this is not a confirmation of the outgoing hit.", Color3.fromRGB(130, 255, 170))
    end)
    addTextLog("Client-side listener attached for any inbound ForestStrike event.", Color3.fromRGB(160, 230, 175))
end

local function fireForestStrikeForAnyForestEgg()
    addTextLog("ForestStrike test started; will make at most one FireServer call.", Color3.fromRGB(120, 220, 255))

    local hit = getRemote("RE/GuardPatrol/ForestStrike")
    if not hit then
        addTextLog("ERROR: Remote RE/GuardPatrol/ForestStrike was not found.", Color3.fromRGB(255, 125, 125))
        return false
    end
    if not hit:IsA("RemoteEvent") then
        addTextLog("ERROR: ForestStrike has class " .. hit.ClassName .. ", expected RemoteEvent.", Color3.fromRGB(255, 125, 125))
        return false
    end
    addTextLog("Found RemoteEvent: " .. hit:GetFullName(), Color3.fromRGB(160, 230, 175))
    connectForestStrikeInboundLogger(hit)

    -- Intentionally do not rescan the snapshot on each hit. Use the last cached UID
    -- loaded at startup or by clicking REFRESH ID.
    local eggUid = cachedForestEggUid
    local source = cachedForestEggSource
    if not eggUid or eggUid == "" then
        addTextLog("ERROR: no cached Forest UID. Click REFRESH ID first; event not sent.", Color3.fromRGB(255, 125, 125))
        return false
    end

    addTextLog("Using cached Forest UID (no scan on hit): " .. tostring(eggUid), Color3.fromRGB(170, 225, 255))
    addTextLog("GuardCFrame uses the supplied sample value; live guard not verified.", Color3.fromRGB(255, 205, 130))
    local payload = {
        GuardCFrame = SAMPLE_GUARD_CFRAME,
        EggUid = eggUid,
    }

    addTextLog("Calling FireServer once for EggUid=" .. tostring(eggUid) .. " (cached from: " .. tostring(source) .. ")...", Color3.fromRGB(255, 205, 130))
    local ok, err = pcall(function()
        hit:FireServer(payload)
    end)
    if not ok then
        addTextLog("ERROR: FireServer call failed: " .. tostring(err), Color3.fromRGB(255, 125, 125))
        warn("[Fly500] ForestStrike FireServer failed:", err)
        return false
    end

    addTextLog("CLIENT SEND OK: FireServer returned without a local error.", Color3.fromRGB(255, 205, 130))
    addTextLog("SERVER RECEIPT / hit acceptance cannot be confirmed by one LocalScript alone.", Color3.fromRGB(255, 165, 130))
    return true
end

local function getCharacterParts()
    local character = LocalPlayer.Character
    if not character then
        return nil, nil, "Character is not ready."
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then
        return nil, nil, "Character is not ready or is dead."
    end

    return character, root, nil, humanoid
end

logCharacterPosition = function(label)
    local character, root, problem, humanoid = getCharacterParts()
    if not root then
        addTextLog("POSITION [" .. tostring(label or "snapshot") .. "]: unavailable: " .. tostring(problem), Color3.fromRGB(255, 175, 135))
        return nil
    end

    local p = root.Position
    local v = root.AssemblyLinearVelocity
    local stateName = humanoid:GetState().Name
    local line = string.format(
        "POSITION [%s]: X=%.3f Y=%.3f Z=%.3f | velocity=(%.2f, %.2f, %.2f), speed=%.2f | state=%s",
        tostring(label or "snapshot"), p.X, p.Y, p.Z,
        v.X, v.Y, v.Z, v.Magnitude, stateName
    )
    addTextLog(line, Color3.fromRGB(170, 225, 255))
    return p
end

local function updatePositionLabel()
    if not positionLabel or not positionLabel.Parent then
        return
    end
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root then
        local p = root.Position
        positionLabel.Text = string.format("ROOT XYZ  X %.2f  Y %.2f  Z %.2f", p.X, p.Y, p.Z)
    else
        positionLabel.Text = "ROOT XYZ  character not ready"
    end
end

local function destroyFlightObjects(constraint, attachment)
    if constraint and constraint.Parent then
        constraint:Destroy()
    end
    if attachment and attachment.Parent then
        attachment:Destroy()
    end

    if activeConstraint == constraint then
        activeConstraint = nil
    end
    if activeAttachment == attachment then
        activeAttachment = nil
    end
end

local function stopFlight(message)
    flightToken += 1
    isFlying = false
    isStartingFlight = false
    actionSequenceRunning = false

    local constraint = activeConstraint
    local attachment = activeAttachment
    activeConstraint = nil
    activeAttachment = nil
    destroyFlightObjects(constraint, attachment)

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root then
        local verticalSpeed = root.AssemblyLinearVelocity.Y
        root.AssemblyLinearVelocity = Vector3.new(0, verticalSpeed, 0)
        root.AssemblyAngularVelocity = Vector3.zero
    end

    if flyButton and flyButton.Parent then
        flyButton.Active = true
        flyButton.AutoButtonColor = true
    end
    setStatus(message or "Move stopped.", Color3.fromRGB(255, 175, 135))
    addTextLog(message or "Move stopped.", Color3.fromRGB(255, 175, 135))
    logCharacterPosition("when Stop was clicked")
end

----------------------------------------------------------------
-- LOCAL RAGDOLL: client-side visual/physics effect only
-- This does not invoke any game remotes or server-side game mechanic.
----------------------------------------------------------------
local function restoreRagdoll(message)
    local state = ragdollState
    if not state then
        return
    end
    ragdollState = nil

    -- Remove replacement constraints and their attachments first.
    for _, constraint in ipairs(state.constraints) do
        if constraint and constraint.Parent then
            constraint:Destroy()
        end
    end
    for _, attachment in ipairs(state.attachments) do
        if attachment and attachment.Parent then
            attachment:Destroy()
        end
    end

    -- Restore joints to their original enabled state.
    for _, item in ipairs(state.joints) do
        if item.motor and item.motor.Parent then
            item.motor.Enabled = item.wasEnabled
        end
    end

    local humanoid = state.humanoid
    if humanoid and humanoid.Parent then
        -- Re-enable joints before restoring RequiresNeck to avoid killing the rig.
        humanoid.RequiresNeck = state.wasRequiresNeck
        humanoid.PlatformStand = state.wasPlatformStand
        humanoid.AutoRotate = state.wasAutoRotate
        if humanoid.Health > 0 then
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end

    if message then
        setStatus(message, Color3.fromRGB(190, 220, 255))
    end
end

local function toggleLocalRagdoll()
    local character, _, problem, humanoid = getCharacterParts()
    if not character then
        setStatus(problem or "Character is not ready.", Color3.fromRGB(255, 125, 125))
        return
    end

    if ragdollState then
        if ragdollState.character == character then
            restoreRagdoll("Local ragdoll recovered.")
            return
        else
            -- Clean up the previous character if the player respawned.
            restoreRagdoll(nil)
        end
    end

    local state = {
        character = character,
        humanoid = humanoid,
        wasRequiresNeck = humanoid.RequiresNeck,
        wasPlatformStand = humanoid.PlatformStand,
        wasAutoRotate = humanoid.AutoRotate,
        joints = {},
        constraints = {},
        attachments = {},
    }
    ragdollState = state
    -- Disable the neck requirement before disabling its Motor6D joint.
    humanoid.RequiresNeck = false
    local jointCount = 0

    -- Temporarily replace enabled Motor6D joints with BallSocketConstraints.
    -- Equipped tools are skipped so the tool's grip is not altered.
    for _, item in ipairs(character:GetDescendants()) do
        if item:IsA("Motor6D")
            and item.Enabled
            and item.Part0
            and item.Part1
            and not item:FindFirstAncestorOfClass("Tool") then

            local motor = item
            local attachment0 = Instance.new("Attachment")
            attachment0.Name = "__LocalRagdollAttachment0"
            attachment0.CFrame = motor.C0
            attachment0.Parent = motor.Part0

            local attachment1 = Instance.new("Attachment")
            attachment1.Name = "__LocalRagdollAttachment1"
            attachment1.CFrame = motor.C1
            attachment1.Parent = motor.Part1

            local constraint = Instance.new("BallSocketConstraint")
            constraint.Name = "__LocalRagdollConstraint"
            constraint.Attachment0 = attachment0
            constraint.Attachment1 = attachment1
            constraint.LimitsEnabled = true
            constraint.UpperAngle = 45
            constraint.TwistLimitsEnabled = true
            constraint.TwistLowerAngle = -45
            constraint.TwistUpperAngle = 45
            constraint.Parent = motor.Part0

            table.insert(state.joints, {
                motor = motor,
                wasEnabled = motor.Enabled,
            })
            table.insert(state.attachments, attachment0)
            table.insert(state.attachments, attachment1)
            table.insert(state.constraints, constraint)
            motor.Enabled = false
            jointCount += 1
        end
    end

    if jointCount == 0 then
        restoreRagdoll(nil)
        setStatus("No active character joints found to ragdoll.", Color3.fromRGB(255, 125, 125))
        return
    end

    humanoid.AutoRotate = false
    humanoid.PlatformStand = true
    humanoid:ChangeState(Enum.HumanoidStateType.Physics)
    setStatus("Brief local ragdoll pulse active.", Color3.fromRGB(255, 200, 120))
end

----------------------------------------------------------------
-- RAGDOLL PULSE: briefly ragdoll, restore the same position/joints,
-- then use Freefall during the flight phase.
----------------------------------------------------------------
local function pulseRagdollAndRecover(character, root, humanoid)
    -- Ensure no old ragdoll session remains active.
    if ragdollState then
        restoreRagdoll(nil)
    end

    -- Preserve the launch pose so the brief physics change does not displace
    -- the character before flight begins.
    local savedCFrame = root.CFrame
    local savedLinearVelocity = root.AssemblyLinearVelocity
    local savedAngularVelocity = root.AssemblyAngularVelocity

    toggleLocalRagdoll()
    if not ragdollState or ragdollState.character ~= character then
        return false, "Ragdoll pulse failed; flight cancelled."
    end

    -- Leave ragdoll active for one physics frame, then recover immediately.
    RunService.Heartbeat:Wait()

    if LocalPlayer.Character ~= character
        or not root.Parent
        or not humanoid.Parent
        or humanoid.Health <= 0 then
        restoreRagdoll(nil)
        return false, "Character changed during ragdoll pulse; flight cancelled."
    end

    restoreRagdoll(nil)

    if root.Parent then
        root.CFrame = savedCFrame
        root.AssemblyLinearVelocity = savedLinearVelocity
        root.AssemblyAngularVelocity = savedAngularVelocity
    end

    -- The rig is recovered, but enter Freefall so flight does not use the
    -- ragdoll Physics state or a running/GettingUp state.
    humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
    setStatus("Ragdoll recovered; entering Freefall for flight.")
    return true
end

----------------------------------------------------------------
-- FLIGHT: horizontal forward vector + constant LinearVelocity
----------------------------------------------------------------
local function startFlight()
    if isFlying or isStartingFlight or actionSequenceRunning then
        setStatus("Move/ForestStrike/drop sequence is already running.", Color3.fromRGB(255, 200, 100))
        addTextLog("Ignored new Move click because the current action sequence is still running.", Color3.fromRGB(255, 205, 130))
        return
    end

    local character, root, problem, humanoid = getCharacterParts()
    if not root then
        setStatus(problem or "Character is not ready.", Color3.fromRGB(255, 125, 125))
        addTextLog(problem or "Character is not ready.", Color3.fromRGB(255, 125, 125))
        return
    end

    addTextLog(string.format(
        "MOVE clicked; target XYZ = %.3f, %.3f, %.3f.",
        TARGET_POSITION.X, TARGET_POSITION.Y, TARGET_POSITION.Z
    ), Color3.fromRGB(120, 220, 255))
    logCharacterPosition("before ragdoll / target move")

    -- Reserve this run before the one-frame ragdoll pulse so Stop can cancel it.
    flightToken += 1
    local myToken = flightToken
    isStartingFlight = true
    if flyButton and flyButton.Parent then
        flyButton.Active = false
        flyButton.AutoButtonColor = false
    end

    local ragdollOk, ragdollProblem = pulseRagdollAndRecover(character, root, humanoid)
    if flightToken ~= myToken then
        restoreRagdoll(nil)
        isStartingFlight = false
        setStatus("Move cancelled.", Color3.fromRGB(255, 175, 135))
        addTextLog("Move cancelled before the target CFrame was applied.", Color3.fromRGB(255, 175, 135))
        return
    end
    if not ragdollOk then
        isStartingFlight = false
        if flyButton and flyButton.Parent then
            flyButton.Active = true
            flyButton.AutoButtonColor = true
        end
        local message = ragdollProblem or "Could not recover from ragdoll; move cancelled."
        setStatus(message, Color3.fromRGB(255, 125, 125))
        addTextLog(message, Color3.fromRGB(255, 125, 125))
        return
    end

    local currentCharacter, currentRoot, currentProblem, currentHumanoid = getCharacterParts()
    if not currentRoot or currentCharacter ~= character or currentRoot ~= root or currentHumanoid ~= humanoid then
        isStartingFlight = false
        if flyButton and flyButton.Parent then
            flyButton.Active = true
            flyButton.AutoButtonColor = true
        end
        local message = currentProblem or "Character changed during recovery; move cancelled."
        setStatus(message, Color3.fromRGB(255, 125, 125))
        addTextLog(message, Color3.fromRGB(255, 125, 125))
        return
    end

    if humanoid.Health <= 0 then
        isStartingFlight = false
        if flyButton and flyButton.Parent then
            flyButton.Active = true
            flyButton.AutoButtonColor = true
        end
        setStatus("Character died before target movement; cancelled.", Color3.fromRGB(255, 125, 125))
        addTextLog("Character died before target movement; cancelled.", Color3.fromRGB(255, 125, 125))
        return
    end

    -- Offset the whole model so HumanoidRootPart lands at the exact requested XYZ,
    -- preserving the character's current orientation and rig pivot relationship.
    local targetDelta = TARGET_POSITION - root.Position
    local targetCFrame = character:GetPivot() + targetDelta
    addTextLog(string.format(
        "Applying character:PivotTo() for root target %.3f, %.3f, %.3f...",
        TARGET_POSITION.X, TARGET_POSITION.Y, TARGET_POSITION.Z
    ), Color3.fromRGB(255, 205, 130))

    local pivotOk, pivotError = pcall(function()
        character:PivotTo(targetCFrame)
    end)

    if not pivotOk then
        isStartingFlight = false
        if flyButton and flyButton.Parent then
            flyButton.Active = true
            flyButton.AutoButtonColor = true
        end
        local message = "PivotTo failed: " .. tostring(pivotError)
        setStatus(message, Color3.fromRGB(255, 125, 125))
        addTextLog(message, Color3.fromRGB(255, 125, 125))
        return
    end

    -- Stop carried horizontal/angular motion at the destination, then remain in
    -- Freefall so gravity behaves normally if the target is above the ground.
    if root and root.Parent then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
    humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

    local actualPosition = root.Position
    addTextLog(string.format(
        "PIVOT OK. Root now at %.3f, %.3f, %.3f (requested %.3f, %.3f, %.3f).",
        actualPosition.X, actualPosition.Y, actualPosition.Z,
        TARGET_POSITION.X, TARGET_POSITION.Y, TARGET_POSITION.Z
    ), Color3.fromRGB(130, 255, 170))
    logCharacterPosition("immediately after PivotTo / before ForestStrike")

    local guardPos = SAMPLE_GUARD_CFRAME.Position
    local guardDistance = (root.Position - guardPos).Magnitude
    addTextLog(string.format(
        "GuardCFrame payload is the fixed sample at X=%.3f Y=%.3f Z=%.3f; current root-to-sample distance=%.1f studs. The live guard was not discovered.",
        guardPos.X, guardPos.Y, guardPos.Z, guardDistance
    ), Color3.fromRGB(255, 205, 130))

    setStatus(string.format(
        "Moved to target XYZ: %.3f, %.3f, %.3f",
        TARGET_POSITION.X, TARGET_POSITION.Y, TARGET_POSITION.Z
    ), Color3.fromRGB(105, 255, 165))

    -- Keep the full sequence serialized: send one ForestStrike attempt using the
    -- cached UID, wait briefly for the server to process it, then invoke the
    -- original drop-request RemoteFunction once. This is best-effort only; there
    -- is no server acknowledgement exposed to this LocalScript.
    isStartingFlight = false
    isFlying = false
    actionSequenceRunning = true
    task.spawn(function()
        local sent = fireForestStrikeForAnyForestEgg()
        logCharacterPosition("after ForestStrike FireServer call")

        if flightToken ~= myToken then
            addTextLog("Sequence cancelled after ForestStrike because Stop was clicked or a newer run began.", Color3.fromRGB(255, 175, 135))
            return
        end

        if sent then
            if flightToken ~= myToken then
                addTextLog("AskFieldEggDrop skipped because the sequence was stopped or superseded before the request began.", Color3.fromRGB(255, 175, 135))
            else
                addTextLog("No intentional delay: calling AskFieldEggDrop immediately after the local FireServer call returned.", Color3.fromRGB(255, 205, 130))
                invokeEggDropOnce(myToken)
            end
        else
            addTextLog("AskFieldEggDrop skipped because ForestStrike was not sent (missing UID/remote or local error).", Color3.fromRGB(255, 175, 135))
        end

        if flightToken == myToken then
            actionSequenceRunning = false
            if flyButton and flyButton.Parent then
                flyButton.Active = true
                flyButton.AutoButtonColor = true
            end
            logCharacterPosition("end of sequence")
        end
    end)

    if flyButton and flyButton.Parent then
        flyButton.Active = false
        flyButton.AutoButtonColor = false
    end
end

----------------------------------------------------------------
-- GUI
----------------------------------------------------------------
local previousGui = PlayerGui:FindFirstChild(GUI_NAME)
if previousGui then
    previousGui:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.Parent = PlayerGui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(390, 470)
panel.Position = UDim2.new(0, 24, 0.35, 0)
panel.BackgroundColor3 = Color3.fromRGB(18, 23, 34)
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 28)
title.Position = UDim2.fromOffset(8, 5)
title.BackgroundTransparency = 1
title.Text = "RAGDOLL + TARGET CFRAME"
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = Color3.fromRGB(120, 220, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = panel

local details = Instance.new("TextLabel")
details.Size = UDim2.new(1, -16, 0, 22)
details.Position = UDim2.fromOffset(8, 32)
details.BackgroundTransparency = 1
details.Text = string.format("Ragdoll recovery + CFrame target • %.3f, %.3f, %.3f", TARGET_POSITION.X, TARGET_POSITION.Y, TARGET_POSITION.Z)
details.Font = Enum.Font.Gotham
details.TextSize = 10
details.TextColor3 = Color3.fromRGB(190, 200, 220)
details.TextXAlignment = Enum.TextXAlignment.Left
details.Parent = panel

flyButton = Instance.new("TextButton")
flyButton.Name = "FlyButton"
flyButton.Size = UDim2.new(0.40, -8, 0, 32)
flyButton.Position = UDim2.fromOffset(8, 59)
flyButton.BackgroundColor3 = Color3.fromRGB(28, 125, 75)
flyButton.Text = "MOVE TO TARGET"
flyButton.TextColor3 = Color3.new(1, 1, 1)
flyButton.Font = Enum.Font.GothamBold
flyButton.TextSize = 10
flyButton.Parent = panel
Instance.new("UICorner", flyButton).CornerRadius = UDim.new(0, 5)

refreshIdButton = Instance.new("TextButton")
refreshIdButton.Name = "RefreshForestIdButton"
refreshIdButton.Size = UDim2.new(0.30, -8, 0, 32)
refreshIdButton.Position = UDim2.new(0.40, 6, 0, 59)
refreshIdButton.BackgroundColor3 = Color3.fromRGB(40, 87, 130)
refreshIdButton.Text = "REFRESH ID"
refreshIdButton.TextColor3 = Color3.new(1, 1, 1)
refreshIdButton.Font = Enum.Font.GothamBold
refreshIdButton.TextSize = 10
refreshIdButton.Parent = panel
Instance.new("UICorner", refreshIdButton).CornerRadius = UDim.new(0, 5)

local stopButton = Instance.new("TextButton")
stopButton.Name = "StopButton"
stopButton.Size = UDim2.new(0.30, -8, 0, 32)
stopButton.Position = UDim2.new(0.70, 0, 0, 59)
stopButton.BackgroundColor3 = Color3.fromRGB(120, 45, 45)
stopButton.Text = "STOP"
stopButton.TextColor3 = Color3.new(1, 1, 1)
stopButton.Font = Enum.Font.GothamBold
stopButton.TextSize = 10
stopButton.Parent = panel
Instance.new("UICorner", stopButton).CornerRadius = UDim.new(0, 5)


statusLabel = Instance.new("TextLabel")
eggUidLabel = Instance.new("TextLabel")
eggUidLabel.Name = "CachedForestUID"
eggUidLabel.Size = UDim2.new(1, -16, 0, 20)
eggUidLabel.Position = UDim2.fromOffset(8, 94)
eggUidLabel.BackgroundTransparency = 1
eggUidLabel.Text = "Cached Forest UID: loading..."
eggUidLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
eggUidLabel.Font = Enum.Font.Code
eggUidLabel.TextSize = 9
eggUidLabel.TextWrapped = true
eggUidLabel.TextXAlignment = Enum.TextXAlignment.Left
eggUidLabel.Parent = panel

statusLabel.Size = UDim2.new(1, -16, 0, 26)
statusLabel.Position = UDim2.fromOffset(8, 115)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Ready. Move to the configured XYZ target."
statusLabel.TextColor3 = Color3.fromRGB(190, 220, 255)
statusLabel.Font = Enum.Font.Code
statusLabel.TextSize = 10
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = panel

positionLabel = Instance.new("TextLabel")
positionLabel.Name = "LiveRootPosition"
positionLabel.Size = UDim2.new(1, -16, 0, 17)
positionLabel.Position = UDim2.fromOffset(8, 141)
positionLabel.BackgroundTransparency = 1
positionLabel.Text = "ROOT XYZ  loading..."
positionLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
positionLabel.Font = Enum.Font.Code
positionLabel.TextSize = 10
positionLabel.TextXAlignment = Enum.TextXAlignment.Left
positionLabel.Parent = panel

logPositionButton = Instance.new("TextButton")
logPositionButton.Name = "LogPositionButton"
logPositionButton.Size = UDim2.fromOffset(112, 24)
logPositionButton.Position = UDim2.fromOffset(8, 161)
logPositionButton.BackgroundColor3 = Color3.fromRGB(45, 85, 115)
logPositionButton.Text = "LOG POSITION"
logPositionButton.TextColor3 = Color3.new(1, 1, 1)
logPositionButton.Font = Enum.Font.GothamBold
logPositionButton.TextSize = 9
logPositionButton.Parent = panel
Instance.new("UICorner", logPositionButton).CornerRadius = UDim.new(0, 5)

copyLogButton = Instance.new("TextButton")
copyLogButton.Name = "CopyLogButton"
copyLogButton.Size = UDim2.fromOffset(112, 24)
copyLogButton.Position = UDim2.fromOffset(126, 161)
copyLogButton.BackgroundColor3 = Color3.fromRGB(80, 75, 125)
copyLogButton.Text = "COPY LOG"
copyLogButton.TextColor3 = Color3.new(1, 1, 1)
copyLogButton.Font = Enum.Font.GothamBold
copyLogButton.TextSize = 9
copyLogButton.Parent = panel
Instance.new("UICorner", copyLogButton).CornerRadius = UDim.new(0, 5)

local logTitle = Instance.new("TextLabel")
logTitle.Name = "TextLogTitle"
logTitle.Size = UDim2.new(1, -16, 0, 17)
logTitle.Position = UDim2.fromOffset(8, 188)
logTitle.BackgroundTransparency = 1
logTitle.Text = "FORESTSTRIKE / TARGET MOVE LOG (CLIENT SIDE)"
logTitle.Font = Enum.Font.GothamBold
logTitle.TextSize = 10
logTitle.TextColor3 = Color3.fromRGB(120, 220, 255)
logTitle.TextXAlignment = Enum.TextXAlignment.Left
logTitle.Parent = panel

logScroll = Instance.new("ScrollingFrame")
logScroll.Name = "TextLog"
logScroll.Position = UDim2.fromOffset(8, 207)
logScroll.Size = UDim2.new(1, -16, 1, -215)
logScroll.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 6
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.AutomaticCanvasSize = Enum.AutomaticSize.None
logScroll.Parent = panel
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 5)

logLayout = Instance.new("UIListLayout")
logLayout.Name = "LogLayout"
logLayout.Padding = UDim.new(0, 3)
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Parent = logScroll

logLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    if logScroll and logScroll.Parent then
        logScroll.CanvasSize = UDim2.new(0, 0, 0, logLayout.AbsoluteContentSize.Y + 8)
    end
end)

-- Copy/export overlay: normal Roblox LocalScripts cannot access the OS clipboard.
-- This opens a multiline TextBox, selects the log, and lets the user press Ctrl+C.
copyFrame = Instance.new("Frame")
copyFrame.Name = "CopyLogFrame"
copyFrame.Size = UDim2.fromOffset(520, 350)
copyFrame.AnchorPoint = Vector2.new(0.5, 0.5)
copyFrame.Position = UDim2.fromScale(0.5, 0.5)
copyFrame.BackgroundColor3 = Color3.fromRGB(18, 23, 34)
copyFrame.BorderSizePixel = 0
copyFrame.Visible = false
copyFrame.ZIndex = 20
copyFrame.Parent = gui
Instance.new("UICorner", copyFrame).CornerRadius = UDim.new(0, 8)

local copyTitle = Instance.new("TextLabel")
copyTitle.Name = "CopyLogTitle"
copyTitle.Size = UDim2.new(1, -90, 0, 26)
copyTitle.Position = UDim2.fromOffset(10, 6)
copyTitle.BackgroundTransparency = 1
copyTitle.Text = "LOG EXPORT — PRESS CTRL+C"
copyTitle.Font = Enum.Font.GothamBold
copyTitle.TextSize = 12
copyTitle.TextColor3 = Color3.fromRGB(120, 220, 255)
copyTitle.TextXAlignment = Enum.TextXAlignment.Left
copyTitle.ZIndex = 21
copyTitle.Parent = copyFrame

copyCloseButton = Instance.new("TextButton")
copyCloseButton.Name = "CloseCopyLogButton"
copyCloseButton.Size = UDim2.fromOffset(64, 24)
copyCloseButton.Position = UDim2.new(1, -74, 0, 6)
copyCloseButton.BackgroundColor3 = Color3.fromRGB(100, 45, 45)
copyCloseButton.Text = "CLOSE"
copyCloseButton.TextColor3 = Color3.new(1, 1, 1)
copyCloseButton.Font = Enum.Font.GothamBold
copyCloseButton.TextSize = 10
copyCloseButton.ZIndex = 21
copyCloseButton.Parent = copyFrame
Instance.new("UICorner", copyCloseButton).CornerRadius = UDim.new(0, 5)

copyTextBox = Instance.new("TextBox")
copyTextBox.Name = "SelectableLogText"
copyTextBox.Position = UDim2.fromOffset(10, 36)
copyTextBox.Size = UDim2.new(1, -20, 1, -70)
copyTextBox.BackgroundColor3 = Color3.fromRGB(8, 11, 18)
copyTextBox.BorderSizePixel = 0
copyTextBox.ClearTextOnFocus = false
copyTextBox.MultiLine = true
copyTextBox.TextEditable = true
copyTextBox.TextWrapped = false
copyTextBox.TextXAlignment = Enum.TextXAlignment.Left
copyTextBox.TextYAlignment = Enum.TextYAlignment.Top
copyTextBox.Font = Enum.Font.Code
copyTextBox.TextSize = 10
copyTextBox.TextColor3 = Color3.fromRGB(220, 230, 242)
copyTextBox.Text = ""
copyTextBox.ZIndex = 21
copyTextBox.Parent = copyFrame
Instance.new("UICorner", copyTextBox).CornerRadius = UDim.new(0, 5)

copyStatusLabel = Instance.new("TextLabel")
copyStatusLabel.Name = "CopyLogHint"
copyStatusLabel.Size = UDim2.new(1, -20, 0, 24)
copyStatusLabel.Position = UDim2.new(0, 10, 1, -28)
copyStatusLabel.BackgroundTransparency = 1
copyStatusLabel.Text = "Log selected when possible. Press Ctrl+C to copy; clipboard write is not exposed to LocalScripts."
copyStatusLabel.Font = Enum.Font.Gotham
copyStatusLabel.TextSize = 10
copyStatusLabel.TextColor3 = Color3.fromRGB(190, 200, 220)
copyStatusLabel.TextWrapped = true
copyStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
copyStatusLabel.ZIndex = 21
copyStatusLabel.Parent = copyFrame

local function openCopyLog()
    copyTextBox.Text = table.concat(logHistory, "\n")
    copyFrame.Visible = true
    copyStatusLabel.Text = "Press Ctrl+C to copy the selected log. (Roblox LocalScripts cannot write clipboard directly.)"
    task.defer(function()
        if copyTextBox and copyTextBox.Parent then
            copyTextBox:CaptureFocus()
            pcall(function()
                copyTextBox.SelectionStart = 1
                copyTextBox.CursorPosition = #copyTextBox.Text + 1
            end)
        end
    end)
end

copyLogButton.Activated:Connect(openCopyLog)
copyCloseButton.Activated:Connect(function()
    copyFrame.Visible = false
    if copyTextBox then
        copyTextBox:ReleaseFocus()
    end
end)
logPositionButton.Activated:Connect(function()
    logCharacterPosition("manual LOG POSITION button")
    updatePositionLabel()
end)

addTextLog(string.format("Ready. Target XYZ: %.3f, %.3f, %.3f.", TARGET_POSITION.X, TARGET_POSITION.Y, TARGET_POSITION.Z), Color3.fromRGB(160, 230, 175))
addTextLog("Forest UID is cached; hitting does not rescan it.", Color3.fromRGB(160, 230, 175))
addTextLog("Sequence: PivotTo -> one ForestStrike send -> AskFieldEggDrop immediately (no intentional delay).", Color3.fromRGB(255, 205, 130))
addTextLog("CLIENT SEND OK is not proof of server receipt or hit acceptance. GuardCFrame is still the fixed sample.", Color3.fromRGB(255, 205, 130))
updatePositionLabel()
task.spawn(function()
    while gui.Parent do
        updatePositionLabel()
        task.wait(0.15)
    end
end)

flyButton.Activated:Connect(startFlight)
refreshIdButton.Activated:Connect(function()
    task.spawn(refreshForestEggUid)
end)
stopButton.Activated:Connect(function()
    stopFlight("Move stopped by user.")
    addTextLog("Stop clicked; any sequence that has not started AskFieldEggDrop will be cancelled.", Color3.fromRGB(255, 175, 135))
end)

-- Load one UID at startup. It is reused on hit until REFRESH ID is clicked.
task.spawn(refreshForestEggUid)

gui.Destroying:Connect(function()
    if isFlying or isStartingFlight or actionSequenceRunning then
        stopFlight("Move cancelled because the UI was closed.")
    end
    if ragdollState then
        restoreRagdoll(nil)
    end
end)
