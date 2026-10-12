local ok, err = pcall(function()

-- Clean up any previous running instance of this script
if _G.SpamPickup_Cleanup then
    pcall(_G.SpamPickup_Cleanup)
end
_G.SpamPickup_Cleanup = nil

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    pcall(function() LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer end)
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local CONFIG = {
    Enabled          = true,   -- Master toggle
    ReachAssist      = false,  -- If true: micro-steps within 2.5 studs to guarantee server accepts
    MaxReachDistance = 35,     -- Maximum distance (studs) to detect focus target
    SpamBurstCount   = 8,      -- How many concurrent RF requests to fire per burst
    HoldRepeatRate   = 0.08,   -- Interval (seconds) between bursts while holding 'E'
}

-- Connections tracking for clean unloading
local connections = {}
local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

-- =============================================================================
-- NETWORKING REFERENCES
-- =============================================================================
local function getNetRemote(name)
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if net then
        local direct = net:FindFirstChild(name)
        if direct then return direct end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

local carryRemote    = getNetRemote("RF/EggWorld/AskFieldEggCarry")
local snapshotRemote = getNetRemote("RF/EggWorld/AskFieldEggSnapshot")

-- =============================================================================
-- LIVE EGG CACHE & TRACKING
-- =============================================================================
-- eggCache: map of uid -> { Uid, Position, Name, State, CarrierUserId, LastSeen }
local eggCache = {}
local isHoldingE = false
local currentTarget = nil
local totalSpamsSent = 0
local lastBurstSpams = 0
local lastServerReply = "Waiting..."
local lastServerTime = 0

local function getRecordPos(r)
    if typeof(r) ~= "table" then return nil end
    if typeof(r.BoundsCFrame) == "CFrame" then return r.BoundsCFrame.Position end
    if typeof(r.BottomCFrame) == "CFrame" then return r.BottomCFrame.Position end
    return nil
end

local function updateRecordInCache(r)
    if typeof(r) ~= "table" then return end
    local uid = tostring(r.Uid or r.EggUid or "")
    if uid == "" then return end

    local pos = getRecordPos(r)
    local name = tostring(r.AssetCategory or r.DisplayName or r.Name or "Egg")
    local state = tostring(r.State or "Field")
    local carrier = r.CarrierUserId and tostring(r.CarrierUserId) or nil

    if not eggCache[uid] then
        eggCache[uid] = {
            Uid           = uid,
            Position      = pos,
            Name          = name,
            State         = state,
            CarrierUserId = carrier,
            LastSeen      = os.clock()
        }
    else
        local entry = eggCache[uid]
        if pos then entry.Position = pos end
        if name ~= "Egg" then entry.Name = name end
        entry.State = state
        entry.CarrierUserId = carrier
        entry.LastSeen = os.clock()
    end
end

-- Periodic snapshot sync (every 2.5 seconds)
local function refreshSnapshot()
    if not snapshotRemote then return end
    task.spawn(function()
        local okCall, res = pcall(function() return snapshotRemote:InvokeServer() end)
        if okCall and typeof(res) == "table" then
            local records = res.Records or res
            if typeof(records) == "table" then
                for _, r in pairs(records) do
                    updateRecordInCache(r)
                end
            end
        end
    end)
end
task.spawn(refreshSnapshot)

-- Push event listeners for immediate updates (dropped eggs, shifts, carries)
pcall(function()
    local evShift = getNetRemote("RE/EggWorld/FieldEggShifted")
    if evShift and evShift:IsA("RemoteEvent") then
        addConnection(evShift.OnClientEvent:Connect(function(pl)
            updateRecordInCache(pl)
        end))
    end

    local evBatch = getNetRemote("RE/EggWorld/FieldEggBatchShifted")
    if evBatch and evBatch:IsA("RemoteEvent") then
        addConnection(evBatch.OnClientEvent:Connect(function(batch)
            if typeof(batch) == "table" then
                local recs = batch.Records or batch
                if typeof(recs) == "table" then
                    for _, pl in pairs(recs) do
                        updateRecordInCache(pl)
                    end
                end
            end
        end))
    end

    local evDropped = getNetRemote("RE/EggWorld/OwnerDropped")
    if evDropped and evDropped:IsA("RemoteEvent") then
        addConnection(evDropped.OnClientEvent:Connect(function(pl)
            if typeof(pl) == "table" then
                local u = tostring(pl.Uid or pl.EggUid or "")
                if u ~= "" and eggCache[u] then
                    eggCache[u].State = "Dropped"
                    eggCache[u].CarrierUserId = nil
                    local p = getRecordPos(pl)
                    if p then eggCache[u].Position = p end
                end
            end
        end))
    end

    local evGone = getNetRemote("RE/EggWorld/FieldEggGone")
    if evGone and evGone:IsA("RemoteEvent") then
        addConnection(evGone.OnClientEvent:Connect(function(pl)
            if typeof(pl) == "table" then
                local u = tostring(pl.Uid or pl.EggUid or "")
                if u ~= "" then
                    eggCache[u] = nil
                end
            end
        end))
    end
end)

-- Background loop to keep cache fresh
local scannerRunning = true
task.spawn(function()
    while scannerRunning do
        task.wait(2.5)
        refreshSnapshot()
    end
end)

-- =============================================================================
-- CHARACTER FOCUS DETECTION & FALLBACK SCAN
-- =============================================================================
-- Resolves candidate eggs and prompts in front of character / camera
local function getBestFocusedTarget()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end

    local charPos  = root.Position
    local charLook = root.CFrame.LookVector

    local cam = Workspace.CurrentCamera
    local camPos  = cam and cam.CFrame.Position or charPos
    local camLook = cam and cam.CFrame.LookVector or charLook

    local bestTarget = nil
    local highestScore = -math.huge

    -- 1. Evaluate cached egg records from snapshot/events
    for uid, data in pairs(eggCache) do
        -- Skip eggs claimed in a base or carried by someone else
        local isCarriedByOther = data.CarrierUserId and tostring(data.CarrierUserId) ~= tostring(LocalPlayer.UserId)
        if data.State ~= "Claimed" and not isCarriedByOther and data.Position then
            local pos = data.Position
            local diff = pos - charPos
            local dist = diff.Magnitude

            if dist <= CONFIG.MaxReachDistance then
                local dir = dist > 0.01 and diff.Unit or charLook
                local charDot = charLook:Dot(dir)

                local camDiff = pos - camPos
                local camDir  = camDiff.Magnitude > 0.01 and camDiff.Unit or camLook
                local camDot  = camLook:Dot(camDir)

                -- Focus scoring: prioritize camera crosshair + character forward angle + proximity
                local angleScore = math.max(0, camDot) * 2.2 + math.max(0, charDot) * 1.2
                local score = (angleScore + 0.3) / (dist + 0.5)

                -- Strong bonus if adjacent/standing directly over the egg (< 6 studs)
                if dist <= 6.0 then
                    score = score + 3.0
                end

                if score > highestScore then
                    highestScore = score
                    bestTarget = {
                        Type     = "EggRecord",
                        Uid      = uid,
                        Name     = data.Name or "Egg",
                        Position = pos,
                        Distance = dist,
                        Prompt   = nil
                    }
                end
            end
        end
    end

    -- 2. Direct World Scan Fallback: AreaEggSlotsClient (matches 32-hex Uids in scene)
    local slotsFolder = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slotsFolder then
        for _, ch in ipairs(slotsFolder:GetChildren()) do
            local pos = nil
            if ch:IsA("BasePart") then
                pos = ch.Position
            elseif ch:IsA("Model") then
                pos = ch:GetPivot().Position
            end
            if pos then
                local diff = pos - charPos
                local dist = diff.Magnitude
                if dist <= CONFIG.MaxReachDistance then
                    local dir = dist > 0.01 and diff.Unit or charLook
                    local charDot = charLook:Dot(dir)
                    local camDiff = pos - camPos
                    local camDir  = camDiff.Magnitude > 0.01 and camDiff.Unit or camLook
                    local camDot  = camLook:Dot(camDir)

                    local angleScore = math.max(0, camDot) * 2.2 + math.max(0, charDot) * 1.2
                    local score = (angleScore + 0.3) / (dist + 0.5)
                    if dist <= 6.0 then score = score + 3.0 end

                    local uid = ch:GetAttribute("Uid") or ch:GetAttribute("EggUid")
                    if not uid and #ch.Name == 32 and ch.Name:match("^%x+$") then
                        uid = ch.Name
                    end

                    if score > highestScore then
                        highestScore = score
                        bestTarget = {
                            Type     = "SlotDirect",
                            Uid      = uid,
                            Name     = ch.Name,
                            Position = pos,
                            Distance = dist,
                            Prompt   = ch:FindFirstChildWhichIsA("ProximityPrompt", true)
                        }
                    end
                end
            end
        end
    end

    -- 3. Evaluate ProximityPrompts in Workspace (CarryAreaEgg / SmartPromptPart)
    local function checkPrompt(prompt)
        if not prompt or not prompt.Parent or not prompt.Enabled then return end
        local pName = prompt.Name:lower()
        local actText = prompt.ActionText:lower()
        local objText = prompt.ObjectText:lower()

        local isEggPrompt = (pName:find("egg") ~= nil or pName:find("carry") ~= nil
            or actText:find("carry") ~= nil or actText:find("pick") ~= nil or actText:find("egg") ~= nil
            or objText:find("egg") ~= nil)

        if not isEggPrompt then return end

        local parent = prompt.Parent
        local pos = nil
        if parent:IsA("BasePart") then
            pos = parent.Position
        elseif parent:IsA("Model") then
            pos = parent:GetPivot().Position
        elseif parent:IsA("Attachment") then
            pos = parent.WorldPosition
        end
        if not pos then return end

        local diff = pos - charPos
        local dist = diff.Magnitude
        if dist <= CONFIG.MaxReachDistance then
            local dir = dist > 0.01 and diff.Unit or charLook
            local charDot = charLook:Dot(dir)

            local camDiff = pos - camPos
            local camDir  = camDiff.Magnitude > 0.01 and camDiff.Unit or camLook
            local camDot  = camLook:Dot(camDir)

            local angleScore = math.max(0, camDot) * 2.2 + math.max(0, charDot) * 1.2
            local score = (angleScore + 0.3) / (dist + 0.5)
            if dist <= 6.0 then score = score + 3.0 end

            local uid = parent:GetAttribute("Uid") or parent:GetAttribute("EggUid") or prompt:GetAttribute("Uid")
            if not uid then
                local hex = parent.Name:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$")
                if hex then uid = hex end
            end

            -- Match against closest egg in eggCache if within 5 studs
            if not uid then
                for cUid, cData in pairs(eggCache) do
                    if cData.Position and (cData.Position - pos).Magnitude <= 5 then
                        uid = cUid
                        break
                    end
                end
            end

            local pDisplayName = prompt.ObjectText ~= "" and prompt.ObjectText or parent.Name

            if score > highestScore then
                highestScore = score
                bestTarget = {
                    Type     = "Prompt",
                    Uid      = uid,
                    Name     = pDisplayName,
                    Position = pos,
                    Distance = dist,
                    Prompt   = prompt
                }
            elseif bestTarget and (bestTarget.Position - pos).Magnitude <= 5 then
                bestTarget.Prompt = prompt
                if not bestTarget.Uid and uid then
                    bestTarget.Uid = uid
                end
            end
        end
    end

    local smartPart = Workspace:FindFirstChild("SmartPromptPart")
    if smartPart then
        for _, ch in ipairs(smartPart:GetChildren()) do
            if ch:IsA("ProximityPrompt") then checkPrompt(ch) end
        end
    end

    return bestTarget
end

-- =============================================================================
-- REACH ASSIST (MICRO-STEP)
-- =============================================================================
local function getBesideOffset(targetPos, currentPos, dist)
    dist = dist or 2.8
    local diff = Vector3.new(currentPos.X - targetPos.X, 0, currentPos.Z - targetPos.Z)
    local dir = diff.Magnitude > 0.1 and diff.Unit or Vector3.new(0, 0, 1)
    local groundY = currentPos.Y
    if math.abs(groundY - targetPos.Y) > 6 then groundY = targetPos.Y end
    local besidePos = Vector3.new(targetPos.X + dir.X * dist, groundY, targetPos.Z + dir.Z * dist)
    local lookTarget = Vector3.new(targetPos.X, groundY, targetPos.Z)
    return besidePos, lookTarget
end

local function applyReachAssist(targetPos)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root or typeof(targetPos) ~= "Vector3" then return end
    local dist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
    if dist > 3 and dist <= 30 then
        local bPos, lPos = getBesideOffset(targetPos, root.Position, 2.8)
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.lookAt(bPos, lPos)
        end)
    end
end

-- =============================================================================
-- HIGH-SPEED SPAM EXECUTION WITH DIAGNOSTICS
-- =============================================================================
local function triggerProximityPrompt(prompt)
    if not prompt or not prompt.Parent then return end
    if typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt, 0)
        pcall(fireproximityprompt, prompt)
    end
    pcall(function()
        if typeof(prompt.InputHoldBegin) == "function" then
            prompt:InputHoldBegin()
            task.delay(0.01, function()
                pcall(function() prompt:InputHoldEnd() end)
            end)
        end
    end)
end

local function executePickupSpam(target)
    if not target then return end

    -- Optional Reach Assist: step within 2.8 studs so server never rejects distance
    if CONFIG.ReachAssist and target.Position then
        applyReachAssist(target.Position)
    end

    -- Channel 1: ProximityPrompt instant trigger
    if target.Prompt then
        triggerProximityPrompt(target.Prompt)
    end

    local smartPart = Workspace:FindFirstChild("SmartPromptPart")
    if smartPart and target.Position and (smartPart.Position - target.Position).Magnitude <= 8 then
        for _, p in ipairs(smartPart:GetChildren()) do
            if p:IsA("ProximityPrompt") then
                triggerProximityPrompt(p)
            end
        end
    end

    -- Channel 2: RemoteFunction concurrent spam (RF/EggWorld/AskFieldEggCarry)
    if target.Uid and carryRemote then
        local uid = target.Uid
        local burstCount = CONFIG.SpamBurstCount
        totalSpamsSent = totalSpamsSent + burstCount
        lastBurstSpams = burstCount

        local answered = false
        for i = 1, burstCount do
            task.spawn(function()
                local okCall, res = pcall(function()
                    return carryRemote:InvokeServer({ Uid = uid })
                end)
                if not answered then
                    answered = true
                    lastServerTime = os.clock()
                    if okCall then
                        if res == true or (typeof(res) == "table" and res.Success ~= false and not res.Error and not res.error) then
                            lastServerReply = "Accepted ✓"
                        elseif res == false then
                            lastServerReply = "Refused (false)"
                        elseif typeof(res) == "table" and (res.Error or res.error) then
                            lastServerReply = "Refused: " .. tostring(res.Error or res.error)
                        else
                            lastServerReply = "Replied: " .. tostring(res)
                        end
                    else
                        lastServerReply = "Error: " .. tostring(res)
                    end
                    print(string.format("[SpamPickup] Burst of %d sent for %s (%s) -> Server: %s", burstCount, target.Name, uid, lastServerReply))
                end
            end)
        end
    elseif not target.Uid then
        lastBurstSpams = 0
        lastServerReply = "Prompt Only (No UID)"
        print("[SpamPickup] Fired ProximityPrompt only (Egg UID not resolved).")
    end
end

-- =============================================================================
-- USER INTERFACE (ENHANCED HUD BADGE WITH DIAGNOSTICS)
-- =============================================================================
local function getSafeUiParent()
    if typeof(gethui) == "function" then
        local okH, h = pcall(gethui)
        if okH and h then return h end
    end
    local okCore, core = pcall(function() return game:GetService("CoreGui") end)
    if okCore and core then return core end
    return LocalPlayer:FindFirstChild("PlayerGui") or game:GetService("CoreGui")
end

local hudGui = Instance.new("ScreenGui")
hudGui.Name = "SpamPickupHUD"
hudGui.ResetOnSpawn = false
hudGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
hudGui.Parent = getSafeUiParent()

local badge = Instance.new("Frame")
badge.Name = "BadgeFrame"
badge.Size = UDim2.new(0, 270, 0, 72)
badge.Position = UDim2.new(0.5, -135, 0, 18)
badge.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
badge.BorderSizePixel = 0
badge.Active = true
badge.Draggable = true
badge.Parent = hudGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = badge

local stroke = Instance.new("UIStroke")
stroke.Thickness = 1.5
stroke.Color = Color3.fromRGB(60, 140, 220)
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = badge

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -110, 0, 22)
titleLabel.Position = UDim2.new(0, 10, 0, 4)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "⚡ Spam Pickup [E]"
titleLabel.TextColor3 = Color3.fromRGB(120, 220, 255)
titleLabel.TextSize = 13
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = badge

local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(1, -20, 0, 18)
targetLabel.Position = UDim2.new(0, 10, 0, 26)
targetLabel.BackgroundTransparency = 1
targetLabel.Text = "Focus: (None in range)"
targetLabel.TextColor3 = Color3.fromRGB(180, 190, 210)
targetLabel.TextSize = 11
targetLabel.Font = Enum.Font.Gotham
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Parent = badge

local diagLabel = Instance.new("TextLabel")
diagLabel.Size = UDim2.new(1, -20, 0, 18)
diagLabel.Position = UDim2.new(0, 10, 0, 46)
diagLabel.BackgroundTransparency = 1
diagLabel.Text = "Last: Ready (Press E)"
diagLabel.TextColor3 = Color3.fromRGB(140, 160, 185)
diagLabel.TextSize = 10
diagLabel.Font = Enum.Font.Gotham
diagLabel.TextXAlignment = Enum.TextXAlignment.Left
diagLabel.Parent = badge

-- Reach Assist Toggle Button
local reachBtn = Instance.new("TextButton")
reachBtn.Size = UDim2.new(0, 52, 0, 18)
reachBtn.Position = UDim2.new(1, -98, 0, 5)
reachBtn.BackgroundColor3 = Color3.fromRGB(45, 55, 75)
reachBtn.Text = "Reach OFF"
reachBtn.TextColor3 = Color3.fromRGB(200, 210, 225)
reachBtn.TextSize = 9
reachBtn.Font = Enum.Font.GothamBold
reachBtn.Parent = badge
Instance.new("UICorner", reachBtn).CornerRadius = UDim.new(0, 4)

reachBtn.MouseButton1Click:Connect(function()
    CONFIG.ReachAssist = not CONFIG.ReachAssist
    if CONFIG.ReachAssist then
        reachBtn.Text = "Reach ON"
        reachBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 180)
        reachBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    else
        reachBtn.Text = "Reach OFF"
        reachBtn.BackgroundColor3 = Color3.fromRGB(45, 55, 75)
        reachBtn.TextColor3 = Color3.fromRGB(200, 210, 225)
    end
end)

-- Master Toggle Button
local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(0, 36, 0, 18)
toggleBtn.Position = UDim2.new(1, -42, 0, 5)
toggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
toggleBtn.Text = "ON"
toggleBtn.TextColor3 = Color3.fromRGB(240, 255, 240)
toggleBtn.TextSize = 10
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.Parent = badge
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 4)

toggleBtn.MouseButton1Click:Connect(function()
    CONFIG.Enabled = not CONFIG.Enabled
    if CONFIG.Enabled then
        toggleBtn.Text = "ON"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
        stroke.Color = Color3.fromRGB(60, 140, 220)
    else
        toggleBtn.Text = "OFF"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(120, 45, 45)
        stroke.Color = Color3.fromRGB(80, 80, 90)
        targetLabel.Text = "Status: Disabled"
        targetLabel.TextColor3 = Color3.fromRGB(160, 160, 160)
        diagLabel.Text = "Spam pickup is OFF"
    end
end)

-- =============================================================================
-- HEARTBEAT MONITOR & INPUT BINDINGS
-- =============================================================================
addConnection(RunService.Heartbeat:Connect(function()
    if not CONFIG.Enabled then return end

    currentTarget = getBestFocusedTarget()

    if isHoldingE then
        if currentTarget then
            targetLabel.Text = string.format("⚡ SPAMMING: %s (%.1f studs)", currentTarget.Name, currentTarget.Distance)
            targetLabel.TextColor3 = Color3.fromRGB(255, 220, 60)
            stroke.Color = Color3.fromRGB(255, 200, 40)
        else
            targetLabel.Text = "⚡ Spamming [E] (Searching...)"
            targetLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
            stroke.Color = Color3.fromRGB(255, 160, 60)
        end
    else
        if currentTarget then
            local dist = currentTarget.Distance
            local inRangeText = dist <= 8.5 and " [IN RANGE]" or " [GET CLOSER]"
            targetLabel.Text = string.format("Focus: %s (%.1f studs)%s", currentTarget.Name, dist, inRangeText)
            if dist <= 8.5 then
                targetLabel.TextColor3 = Color3.fromRGB(120, 255, 160) -- Green = Guaranteed Server Range
                stroke.Color = Color3.fromRGB(60, 180, 120)
            else
                targetLabel.TextColor3 = Color3.fromRGB(255, 190, 80) -- Orange = Out of server pickup range
                stroke.Color = Color3.fromRGB(200, 140, 60)
            end
        else
            targetLabel.Text = "Focus: (None in range)"
            targetLabel.TextColor3 = Color3.fromRGB(160, 175, 195)
            stroke.Color = Color3.fromRGB(50, 70, 95)
        end
    end

    -- Diagnostics label update
    if lastBurstSpams > 0 then
        diagLabel.Text = string.format("Sent: %d spams/burst | Server: %s", lastBurstSpams, lastServerReply)
        if lastServerReply:find("Accepted") then
            diagLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
        elseif lastServerReply:find("Refused") or lastServerReply:find("Error") then
            diagLabel.TextColor3 = Color3.fromRGB(255, 130, 130)
        else
            diagLabel.TextColor3 = Color3.fromRGB(180, 200, 220)
        end
    end
end))

-- Continuous spam loop while holding E
task.spawn(function()
    while scannerRunning do
        if CONFIG.Enabled and isHoldingE then
            local target = currentTarget or getBestFocusedTarget()
            if target then
                executePickupSpam(target)
            end
            task.wait(CONFIG.HoldRepeatRate)
        else
            task.wait(0.04)
        end
    end
end)

-- UserInputService listeners
addConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if not CONFIG.Enabled then return end

    if input.KeyCode == Enum.KeyCode.E then
        isHoldingE = true
        local target = currentTarget or getBestFocusedTarget()
        if target then
            executePickupSpam(target)
        end
    end
end))

addConnection(UserInputService.InputEnded:Connect(function(input, gameProcessed)
    if input.KeyCode == Enum.KeyCode.E then
        isHoldingE = false
    end
end))

-- =============================================================================
-- CLEANUP ROUTINE
-- =============================================================================
local function fullCleanup()
    scannerRunning = false
    isHoldingE = false
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(connections)
    if hudGui and hudGui.Parent then
        pcall(function() hudGui:Destroy() end)
    end
    print("[SpamPickup] Script unloaded and cleaned up successfully.")
end

_G.SpamPickup_Cleanup = fullCleanup

print("[SpamPickup v2.0] Loaded! Press or hold [E] while focusing an egg. Reach Assist & Server response diagnostics enabled.")

end) -- end pcall

if not ok then
    warn("[SpamPickup] Initialization failed: " .. tostring(err))
end
