local ok, err = pcall(function()

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

local CONFIG = {
    Enabled          = true,
    ReachAssist      = true,
    MaxReachDistance = 35,
    SpamBurstCount   = 8,
}

local connections = {}
local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

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

local function extractSlotKey(uid)
    if type(uid) ~= "string" then return nil end
    return uid:match("_(%w+:Slot_%d+)$") or uid:match("(%w+:Slot_%d+)$")
end

local eggCache = {}
local currentTarget = nil
local lastBurstSpams = 0
local lastServerReply = "Ready"
local scannerRunning = true

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
    local slotKey = r.FirstAreaSlotKey or r.SlotKey or extractSlotKey(uid)

    if not eggCache[uid] then
        eggCache[uid] = {
            Uid = uid, Position = pos, Name = name, State = state,
            CarrierUserId = carrier, SlotKey = slotKey, LastSeen = os.clock()
        }
    else
        local entry = eggCache[uid]
        if pos then entry.Position = pos end
        if name ~= "Egg" then entry.Name = name end
        entry.State = state
        entry.CarrierUserId = carrier
        if slotKey then entry.SlotKey = slotKey end
        entry.LastSeen = os.clock()
    end
end

local function refreshSnapshot()
    if not snapshotRemote then return end
    task.spawn(function()
        local okCall, res = pcall(function() return snapshotRemote:InvokeServer() end)
        if okCall and typeof(res) == "table" then
            local records = res.Records or res
            if typeof(records) == "table" then
                for _, r in pairs(records) do updateRecordInCache(r) end
            end
        end
    end)
end
task.spawn(refreshSnapshot)

pcall(function()
    local function hook(name, fn)
        local ev = getNetRemote(name)
        if ev and ev:IsA("RemoteEvent") then
            addConnection(ev.OnClientEvent:Connect(fn))
        end
    end
    hook("RE/EggWorld/FieldEggShifted", updateRecordInCache)
    hook("RE/EggWorld/FieldEggBatchShifted", function(batch)
        if typeof(batch) == "table" then
            local recs = batch.Records or batch
            if typeof(recs) == "table" then
                for _, pl in pairs(recs) do updateRecordInCache(pl) end
            end
        end
    end)
    hook("RE/EggWorld/OwnerDropped", function(pl)
        if typeof(pl) == "table" then
            local u = tostring(pl.Uid or pl.EggUid or "")
            if u ~= "" and eggCache[u] then
                eggCache[u].State = "Dropped"
                eggCache[u].CarrierUserId = nil
                local p = getRecordPos(pl)
                if p then eggCache[u].Position = p end
            end
        end
    end)
    hook("RE/EggWorld/FieldEggGone", function(pl)
        if typeof(pl) == "table" then
            local u = tostring(pl.Uid or pl.EggUid or "")
            if u ~= "" then eggCache[u] = nil end
        end
    end)
end)

task.spawn(function()
    while scannerRunning do
        task.wait(2.5)
        refreshSnapshot()
    end
end)

local function getBestFocusedTarget()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end

    local charPos  = root.Position
    local charLook = root.CFrame.LookVector
    local cam = Workspace.CurrentCamera
    local camPos  = cam and cam.CFrame.Position or charPos
    local camLook = cam and cam.CFrame.LookVector or charLook

    local bestTarget, highestScore = nil, -math.huge

    for uid, data in pairs(eggCache) do
        local isCarriedByOther = data.CarrierUserId and tostring(data.CarrierUserId) ~= tostring(LocalPlayer.UserId)
        if data.State ~= "Claimed" and not isCarriedByOther and data.Position then
            local pos = data.Position
            local dist = (pos - charPos).Magnitude
            if dist <= CONFIG.MaxReachDistance then
                local dir = dist > 0.01 and (pos - charPos).Unit or charLook
                local charDot = charLook:Dot(dir)
                local camDir = ((pos - camPos).Magnitude > 0.01) and (pos - camPos).Unit or camLook
                local camDot = camLook:Dot(camDir)
                local score = (math.max(0, camDot)*2.2 + math.max(0, charDot)*1.2 + 0.3) / (dist + 0.5)
                if dist <= 6 then score = score + 3 end
                if score > highestScore then
                    highestScore = score
                    bestTarget = {
                        Type = "EggRecord", Uid = uid, Name = data.Name or "Egg",
                        Position = pos, Distance = dist, SlotKey = data.SlotKey, Prompt = nil
                    }
                end
            end
        end
    end

    local slotsFolder = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slotsFolder then
        for _, ch in ipairs(slotsFolder:GetChildren()) do
            local pos = ch:IsA("BasePart") and ch.Position or (ch:IsA("Model") and ch:GetPivot().Position)
            if pos then
                local dist = (pos - charPos).Magnitude
                if dist <= CONFIG.MaxReachDistance then
                    local dir = dist > 0.01 and (pos - charPos).Unit or charLook
                    local charDot = charLook:Dot(dir)
                    local camDir = ((pos - camPos).Magnitude > 0.01) and (pos - camPos).Unit or camLook
                    local camDot = camLook:Dot(camDir)
                    local score = (math.max(0, camDot)*2.2 + math.max(0, charDot)*1.2 + 0.3) / (dist + 0.5)
                    if dist <= 6 then score = score + 3 end
                    local uid = ch:GetAttribute("Uid") or ch:GetAttribute("EggUid")
                    if not uid and #ch.Name == 32 and ch.Name:match("^%x+$") then uid = ch.Name end
                    if score > highestScore then
                        highestScore = score
                        bestTarget = {
                            Type = "SlotDirect", Uid = uid, Name = ch.Name,
                            Position = pos, Distance = dist,
                            SlotKey = extractSlotKey(tostring(uid or "")),
                            Prompt = ch:FindFirstChildWhichIsA("ProximityPrompt", true)
                        }
                    end
                end
            end
        end
    end

    return bestTarget
end

local function applyReachAssist(targetPos)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root or typeof(targetPos) ~= "Vector3" then return end
    local dist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
    if dist > 3 and dist <= 30 then
        local diff = Vector3.new(root.Position.X - targetPos.X, 0, root.Position.Z - targetPos.Z)
        local dir = diff.Magnitude > 0.1 and diff.Unit or Vector3.new(0,0,1)
        local groundY = math.abs(root.Position.Y - targetPos.Y) > 6 and targetPos.Y or root.Position.Y
        local bPos = Vector3.new(targetPos.X + dir.X * 2.8, groundY, targetPos.Z + dir.Z * 2.8)
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.lookAt(bPos, Vector3.new(targetPos.X, groundY, targetPos.Z))
        end)
    end
end

local function triggerProximityPrompt(prompt)
    if not prompt or not prompt.Parent then return end
    if typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt, 0)
        pcall(fireproximityprompt, prompt)
    end
    pcall(function()
        if typeof(prompt.InputHoldBegin) == "function" then
            prompt:InputHoldBegin()
            task.delay(0.01, function() pcall(function() prompt:InputHoldEnd() end) end)
        end
    end)
end

local function executePickupSpam(target)
    if not target then return end

    if CONFIG.ReachAssist and target.Position then
        applyReachAssist(target.Position)
    end

    if target.Prompt then
        triggerProximityPrompt(target.Prompt)
    end

    if target.Uid and carryRemote then
        local payload = { Uid = target.Uid }
        lastBurstSpams = CONFIG.SpamBurstCount

        local answered = false
        for i = 1, CONFIG.SpamBurstCount do
            task.spawn(function()
                local okCall, res = pcall(function()
                    return carryRemote:InvokeServer(payload)
                end)
                if not answered then
                    answered = true
                    if okCall then
                        if res == true or (typeof(res) == "table" and res.Success ~= false and not res.Error and not res.error) then
                            lastServerReply = "Accepted ✓"
                        elseif res == false then
                            lastServerReply = "Refused"
                        elseif typeof(res) == "table" and (res.Error or res.error) then
                            lastServerReply = "Refused"
                        else
                            lastServerReply = "Replied"
                        end
                    else
                        lastServerReply = "Error"
                    end
                end
            end)
        end
    else
        lastBurstSpams = 0
        lastServerReply = "No Uid"
    end
end

-- UI
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
badge.Size = UDim2.new(0, 280, 0, 72)
badge.Position = UDim2.new(0.5, -140, 0, 14)
badge.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
badge.BorderSizePixel = 0
badge.Active = true
badge.Draggable = true
badge.Parent = hudGui
Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke")
stroke.Thickness = 1.5
stroke.Color = Color3.fromRGB(60, 140, 220)
stroke.Parent = badge

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -90, 0, 22)
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
targetLabel.Text = "Focus: (None)"
targetLabel.TextColor3 = Color3.fromRGB(180, 190, 210)
targetLabel.TextSize = 11
targetLabel.Font = Enum.Font.Gotham
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Parent = badge

local diagLabel = Instance.new("TextLabel")
diagLabel.Size = UDim2.new(1, -20, 0, 18)
diagLabel.Position = UDim2.new(0, 10, 0, 46)
diagLabel.BackgroundTransparency = 1
diagLabel.Text = "Ready — TAP E"
diagLabel.TextColor3 = Color3.fromRGB(140, 160, 185)
diagLabel.TextSize = 10
diagLabel.Font = Enum.Font.Gotham
diagLabel.TextXAlignment = Enum.TextXAlignment.Left
diagLabel.Parent = badge

-- Reach toggle
local reachBtn = Instance.new("TextButton")
reachBtn.Size = UDim2.new(0, 52, 0, 18)
reachBtn.Position = UDim2.new(1, -98, 0, 5)
reachBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 180)
reachBtn.Text = "Reach ON"
reachBtn.TextColor3 = Color3.new(1,1,1)
reachBtn.TextSize = 9
reachBtn.Font = Enum.Font.GothamBold
reachBtn.Parent = badge
Instance.new("UICorner", reachBtn).CornerRadius = UDim.new(0, 4)
reachBtn.MouseButton1Click:Connect(function()
    CONFIG.ReachAssist = not CONFIG.ReachAssist
    reachBtn.Text = CONFIG.ReachAssist and "Reach ON" or "Reach OFF"
    reachBtn.BackgroundColor3 = CONFIG.ReachAssist and Color3.fromRGB(40, 110, 180) or Color3.fromRGB(45, 55, 75)
end)

-- Master toggle
local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(0, 36, 0, 18)
toggleBtn.Position = UDim2.new(1, -42, 0, 5)
toggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
toggleBtn.Text = "ON"
toggleBtn.TextColor3 = Color3.new(1,1,1)
toggleBtn.TextSize = 10
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.Parent = badge
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 4)
toggleBtn.MouseButton1Click:Connect(function()
    CONFIG.Enabled = not CONFIG.Enabled
    toggleBtn.Text = CONFIG.Enabled and "ON" or "OFF"
    toggleBtn.BackgroundColor3 = CONFIG.Enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(120, 45, 45)
    stroke.Color = CONFIG.Enabled and Color3.fromRGB(60, 140, 220) or Color3.fromRGB(80, 80, 90)
end)

-- X close button
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 22, 0, 22)
closeBtn.Position = UDim2.new(1, -26, 0, 3)
closeBtn.BackgroundColor3 = Color3.fromRGB(160, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = badge
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

-- Heartbeat
addConnection(RunService.Heartbeat:Connect(function()
    if not CONFIG.Enabled then return end
    currentTarget = getBestFocusedTarget()
    if currentTarget then
        local dist = currentTarget.Distance
        local tag = dist <= 8.5 and " [IN RANGE]" or " [CLOSER]"
        targetLabel.Text = string.format("Focus: %s (%.1f)%s", currentTarget.Name, dist, tag)
        targetLabel.TextColor3 = dist <= 8.5 and Color3.fromRGB(120, 255, 160) or Color3.fromRGB(255, 190, 80)
        stroke.Color = dist <= 8.5 and Color3.fromRGB(60, 180, 120) or Color3.fromRGB(200, 140, 60)
    else
        targetLabel.Text = "Focus: (None)"
        targetLabel.TextColor3 = Color3.fromRGB(160, 175, 195)
        stroke.Color = Color3.fromRGB(50, 70, 95)
    end
    if lastBurstSpams > 0 then
        diagLabel.Text = string.format("Sent %d | %s", lastBurstSpams, lastServerReply)
        diagLabel.TextColor3 = lastServerReply:find("Accepted") and Color3.fromRGB(120, 255, 150)
            or Color3.fromRGB(180, 200, 220)
    end
end))

-- Input — TAP only
addConnection(UserInputService.InputBegan:Connect(function(input)
    if not CONFIG.Enabled then return end
    if input.KeyCode == Enum.KeyCode.E then
        local target = currentTarget or getBestFocusedTarget()
        if target then
            executePickupSpam(target)
        end
    end
end))

local function fullCleanup()
    scannerRunning = false
    CONFIG.Enabled = false
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(connections)
    if hudGui and hudGui.Parent then
        pcall(function() hudGui:Destroy() end)
    end
    print("[SpamPickup] Closed.")
end

_G.SpamPickup_Cleanup = fullCleanup
closeBtn.MouseButton1Click:Connect(fullCleanup)

print("[SpamPickup] Clean version loaded. TAP E | X to close.")

end)

if not ok then
    warn("[SpamPickup] FAILED: " .. tostring(err))
end