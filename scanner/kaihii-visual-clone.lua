--[[
    STEAL AN EGG - COMPLETE CHARACTER & LEADERBOARD VISUAL CLONE
    Target: Kaihii (or any specified target player)
    
    What This Script Does (100% Client-Side Visual & Stat Spoof):
      1. Leaderboard & Stat Spoofing:
         - Spoofs LocalPlayer.leaderstats.Speed to 6,162,346,174,498 (6.16 Trillion).
         - Spoofs LocalPlayer.leaderstats["Money/s"] to 359,310,825,601 (359.3 Billion).
         - Installs real-time locks so game client scripts cannot revert the display values.
      2. Full Avatar & Rig Replication:
         - Clones all target Accessories (VarietyShades02, Accessory (z), Headphones, etc.).
         - Clones Shirt, Pants, and ShirtGraphic.
         - Clones Head Face Decal and BodyColors.
         - Matches R15 Body Depth, Height, Width, and Head scaling.
      3. Animation Stride Sync:
         - Adjusts running animation playback speed to match Kaihii's rapid 21.21x stride.
      4. Complete Restore Engine:
         - Automatically caches your original avatar, clothes, and real leaderboard stats.
         - 1-click restore reverts everything back to your original character state cleanly.
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- Guaranteed visible UI mount
local function getGuiParent()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local uiParent = getGuiParent()

-- Destroy previous instance if open
local existingGui = uiParent:FindFirstChild("KaihiiVisualCloneGui")
if existingGui then
    pcall(function() existingGui:Destroy() end)
end

-- ============================================================
-- STATE & CONFIG
-- ============================================================

local cloneActive       = false
local targetNameQuery   = "Kaihii"
local strideSyncActive  = true

-- Spoof values (fallback to Kaihii's scanned stats if target not live in server)
local fallbackSpeedStat = 6162346174498
local fallbackMoneyStat = 359310825601

-- Original Player Cache for Clean Restore
local originalLeaderstats = {}
local originalAccessories = {}
local originalClothing    = {}
local originalColors      = nil
local originalScales      = {}
local originalFaceTexture = nil

-- Runtime connections
local statLockConnections = {}
local animationConn       = nil

-- Forward declaration for UI update
local updateUiMetrics     = nil

-- ============================================================
-- TARGET RESOLVER
-- ============================================================

local function resolveTarget(nameQuery)
    nameQuery = (nameQuery or "Kaihii"):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local targetPlr, targetChar

    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == nameQuery or p.DisplayName:lower() == nameQuery then
            targetPlr = p
            targetChar = p.Character
            break
        end
    end

    if not targetPlr then
        for _, p in ipairs(Players:GetPlayers()) do
            if string.find(p.Name:lower(), nameQuery, 1, true) or string.find(p.DisplayName:lower(), nameQuery, 1, true) then
                targetPlr = p
                targetChar = p.Character
                break
            end
        end
    end

    if not targetChar then
        for _, obj in ipairs(Workspace:GetChildren()) do
            if obj:IsA("Model") and (obj:FindFirstChildOfClass("Humanoid") or obj:FindFirstChild("HumanoidRootPart")) then
                if obj.Name:lower() == nameQuery or string.find(obj.Name:lower(), nameQuery, 1, true) then
                    targetChar = obj
                    break
                end
            end
        end
    end

    return targetPlr, targetChar
end

-- ============================================================
-- LEADERBOARD & ATTRIBUTE SPOOFER
-- ============================================================

local function lockLeaderstat(valObj, desiredValue)
    if not valObj then return end
    pcall(function() valObj.Value = desiredValue end)

    local conn = valObj:GetPropertyChangedSignal("Value"):Connect(function()
        if cloneActive and valObj.Value ~= desiredValue then
            pcall(function() valObj.Value = desiredValue end)
        end
    end)
    table.insert(statLockConnections, conn)
end

local function applyLeaderboardSpoof()
    local targetPlr, _ = resolveTarget(targetNameQuery)
    local targetSpeedVal = fallbackSpeedStat
    local targetMoneyVal = fallbackMoneyStat

    if targetPlr then
        local tLead = targetPlr:FindFirstChild("leaderstats")
        if tLead then
            local sp = tLead:FindFirstChild("Speed")
            local mo = tLead:FindFirstChild("Money/s") or tLead:FindFirstChild("Money")
            if sp and typeof(sp.Value) == "number" then targetSpeedVal = sp.Value end
            if mo and typeof(mo.Value) == "number" then targetMoneyVal = mo.Value end
        end
    end

    local lead = LocalPlayer:FindFirstChild("leaderstats")
    if not lead then return end

    local speedObj = lead:FindFirstChild("Speed")
    if speedObj and typeof(speedObj.Value) == "number" then
        if originalLeaderstats.Speed == nil then
            originalLeaderstats.Speed = speedObj.Value
        end
        lockLeaderstat(speedObj, targetSpeedVal)
    end

    local moneyObj = lead:FindFirstChild("Money/s") or lead:FindFirstChild("Money")
    if moneyObj and typeof(moneyObj.Value) == "number" then
        if originalLeaderstats.Money == nil then
            originalLeaderstats.Money = moneyObj.Value
        end
        lockLeaderstat(moneyObj, targetMoneyVal)
    end

    -- Mirror target player attributes if available
    if targetPlr then
        pcall(function()
            for attrName, attrVal in pairs(targetPlr:GetAttributes()) do
                LocalPlayer:SetAttribute(attrName, attrVal)
            end
        end)
    end
end

local function restoreLeaderboard()
    for _, conn in ipairs(statLockConnections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(statLockConnections)

    local lead = LocalPlayer:FindFirstChild("leaderstats")
    if lead then
        if originalLeaderstats.Speed ~= nil then
            local sp = lead:FindFirstChild("Speed")
            if sp then pcall(function() sp.Value = originalLeaderstats.Speed end) end
        end
        if originalLeaderstats.Money ~= nil then
            local mo = lead:FindFirstChild("Money/s") or lead:FindFirstChild("Money")
            if mo then pcall(function() mo.Value = originalLeaderstats.Money end) end
        end
    end
end

-- ============================================================
-- AVATAR & VISUAL CHARACTER CLONER
-- ============================================================

local function cacheAndClearOriginalAppearance(char)
    if not char then return end

    -- 1. Cache & remove accessories
    table.clear(originalAccessories)
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Accessory") then
            local cloneAcc = item:Clone()
            table.insert(originalAccessories, cloneAcc)
            item:Destroy()
        end
    end

    -- 2. Cache & remove clothing
    table.clear(originalClothing)
    local shirt = char:FindFirstChildOfClass("Shirt")
    if shirt then
        originalClothing.Shirt = shirt.ShirtTemplate
        shirt:Destroy()
    end
    local pants = char:FindFirstChildOfClass("Pants")
    if pants then
        originalClothing.Pants = pants.PantsTemplate
        pants:Destroy()
    end
    local graphic = char:FindFirstChildOfClass("ShirtGraphic")
    if graphic then
        originalClothing.Graphic = graphic.Graphic
        graphic:Destroy()
    end

    -- 3. Cache BodyColors
    local bc = char:FindFirstChildOfClass("BodyColors")
    if bc then
        originalColors = bc:Clone()
    end

    -- 4. Cache Face Decal
    local head = char:FindFirstChild("Head")
    local face = head and head:FindFirstChildOfClass("Decal")
    if face then
        originalFaceTexture = face.Texture
    end

    -- 5. Cache R15 Scales
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        for _, scaleName in ipairs({"BodyDepthScale", "BodyHeightScale", "BodyWidthScale", "HeadScale", "BodyProportionScale", "BodyTypeScale"}) do
            local sc = hum:FindFirstChild(scaleName)
            if sc and sc:IsA("NumberValue") then
                originalScales[scaleName] = sc.Value
            end
        end
    end
end

local function applyVisualClone()
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not hum then return false end

    local _, targetChar = resolveTarget(targetNameQuery)
    if not targetChar then
        warn("[Visual Clone] Target character model not found in Workspace!")
        return false
    end

    cacheAndClearOriginalAppearance(char)

    -- 1. Clone Accessories from Target
    for _, item in ipairs(targetChar:GetChildren()) do
        if item:IsA("Accessory") then
            pcall(function()
                local clonedAcc = item:Clone()
                clonedAcc.Parent = char
                hum:AddAccessory(clonedAcc)
            end)
        end
    end

    -- 2. Clone Clothing from Target
    local tShirt = targetChar:FindFirstChildOfClass("Shirt")
    if tShirt then
        local s = Instance.new("Shirt")
        s.Name = "Shirt"
        s.ShirtTemplate = tShirt.ShirtTemplate
        s.Parent = char
    end

    local tPants = targetChar:FindFirstChildOfClass("Pants")
    if tPants then
        local p = Instance.new("Pants")
        p.Name = "Pants"
        p.PantsTemplate = tPants.PantsTemplate
        p.Parent = char
    end

    local tGraphic = targetChar:FindFirstChildOfClass("ShirtGraphic")
    if tGraphic then
        local g = Instance.new("ShirtGraphic")
        g.Name = "ShirtGraphic"
        g.Graphic = tGraphic.Graphic
        g.Parent = char
    end

    -- 3. Clone Body Colors
    local tBc = targetChar:FindFirstChildOfClass("BodyColors")
    if tBc then
        local myBc = char:FindFirstChildOfClass("BodyColors") or Instance.new("BodyColors", char)
        pcall(function()
            myBc.HeadColor3 = tBc.HeadColor3
            myBc.TorsoColor3 = tBc.TorsoColor3
            myBc.LeftArmColor3 = tBc.LeftArmColor3
            myBc.RightArmColor3 = tBc.RightArmColor3
            myBc.LeftLegColor3 = tBc.LeftLegColor3
            myBc.RightLegColor3 = tBc.RightLegColor3
        end)
    end

    -- 4. Clone Face Decal
    local tHead = targetChar:FindFirstChild("Head")
    local tFace = tHead and tHead:FindFirstChildOfClass("Decal")
    local myHead = char:FindFirstChild("Head")
    local myFace = myHead and myHead:FindFirstChildOfClass("Decal")
    if tFace and myFace then
        myFace.Texture = tFace.Texture
    end

    -- 5. Clone R15 Scales
    local tHum = targetChar:FindFirstChildOfClass("Humanoid")
    if tHum and hum then
        for _, scaleName in ipairs({"BodyDepthScale", "BodyHeightScale", "BodyWidthScale", "HeadScale", "BodyProportionScale", "BodyTypeScale"}) do
            local tSc = tHum:FindFirstChild(scaleName)
            local mySc = hum:FindFirstChild(scaleName)
            if tSc and mySc and tSc:IsA("NumberValue") and mySc:IsA("NumberValue") then
                pcall(function() mySc.Value = tSc.Value end)
            end
        end
    end

    return true
end

local function restoreOriginalAppearance()
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not hum then return end

    -- 1. Remove cloned accessories
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Accessory") then
            pcall(function() item:Destroy() end)
        end
    end

    -- 2. Restore original accessories
    for _, acc in ipairs(originalAccessories) do
        if acc and acc.Parent == nil then
            pcall(function()
                acc.Parent = char
                hum:AddAccessory(acc)
            end)
        end
    end

    -- 3. Remove cloned clothes and restore original
    local s = char:FindFirstChildOfClass("Shirt")
    if s then s:Destroy() end
    if originalClothing.Shirt then
        local ns = Instance.new("Shirt", char)
        ns.ShirtTemplate = originalClothing.Shirt
    end

    local p = char:FindFirstChildOfClass("Pants")
    if p then p:Destroy() end
    if originalClothing.Pants then
        local np = Instance.new("Pants", char)
        np.PantsTemplate = originalClothing.Pants
    end

    local g = char:FindFirstChildOfClass("ShirtGraphic")
    if g then g:Destroy() end
    if originalClothing.Graphic then
        local ng = Instance.new("ShirtGraphic", char)
        ng.Graphic = originalClothing.Graphic
    end

    -- 4. Restore BodyColors
    if originalColors then
        local myBc = char:FindFirstChildOfClass("BodyColors")
        if myBc then myBc:Destroy() end
        originalColors:Clone().Parent = char
    end

    -- 5. Restore Face Decal
    if originalFaceTexture then
        local head = char:FindFirstChild("Head")
        local face = head and head:FindFirstChildOfClass("Decal")
        if face then face.Texture = originalFaceTexture end
    end

    -- 6. Restore Scales
    if hum then
        for scaleName, scaleVal in pairs(originalScales) do
            local mySc = hum:FindFirstChild(scaleName)
            if mySc and mySc:IsA("NumberValue") then
                pcall(function() mySc.Value = scaleVal end)
            end
        end
    end
end

-- ============================================================
-- ANIMATION STRIDE SYNCHRONIZER
-- ============================================================

local function syncStrideAnimations()
    if not cloneActive or not strideSyncActive then return end
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        if track.WeightCurrent > 0.2 and track.Length > 0 then
            local n = track.Name:lower()
            if n:find("run") or n:find("walk") or n:find("sprint") or track.Speed > 0.5 then
                -- Match Kaihii's stride multiplier (21.21x)
                if math.abs(track.Speed - 21.21) > 0.5 then
                    pcall(function() track:AdjustSpeed(21.21) end)
                end
            end
        end
    end
end

-- ============================================================
-- ACTIVATION / TEARDOWN CONTROLLER
-- ============================================================

local function startClone()
    cloneActive = true

    -- 1. Apply Leaderboard & Attribute Spoof
    applyLeaderboardSpoof()

    -- 2. Apply Visual Character & Outfit Clone
    applyVisualClone()

    -- 3. Stride Animation Loop
    if animationConn then animationConn:Disconnect() end
    animationConn = RunService.Heartbeat:Connect(syncStrideAnimations)

    return true
end

local function stopClone()
    cloneActive = false

    if animationConn then
        animationConn:Disconnect()
        animationConn = nil
    end

    -- 1. Restore real leaderboard stats
    restoreLeaderboard()

    -- 2. Restore real character appearance
    restoreOriginalAppearance()
end

-- ============================================================
-- USER INTERFACE
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "KaihiiVisualCloneGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = uiParent

local W, H = 460, 310
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(140, 90, 240)
mainStroke.Thickness = 1.5

-- Top Bar
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = Color3.fromRGB(32, 26, 48)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🎭 KAIHII FULL VISUAL & LEADERBOARD CLONE"
titleLbl.TextColor3 = Color3.fromRGB(240, 220, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 11.5
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -32, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function()
    stopClone()
    screenGui:Destroy()
end)

-- Draggable Logic
do
    local dragging, dragInput, dragStart, startPos
    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    topBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- Row 1: Target Input
local r1 = Instance.new("Frame")
r1.Size = UDim2.new(1, -24, 0, 28)
r1.Position = UDim2.new(0, 12, 0, 42)
r1.BackgroundTransparency = 1
r1.Parent = main

local tLbl = Instance.new("TextLabel")
tLbl.Size = UDim2.new(0, 95, 1, 0)
tLbl.BackgroundTransparency = 1
tLbl.Text = "Target Player:"
tLbl.TextColor3 = Color3.fromRGB(210, 190, 255)
tLbl.Font = Enum.Font.GothamBold
tLbl.TextSize = 11.5
tLbl.TextXAlignment = Enum.TextXAlignment.Left
tLbl.Parent = r1

local targetBox = Instance.new("TextBox")
targetBox.Size = UDim2.new(1, -100, 1, 0)
targetBox.Position = UDim2.new(0, 100, 0, 0)
targetBox.BackgroundColor3 = Color3.fromRGB(28, 24, 44)
targetBox.Text = targetNameQuery
targetBox.TextColor3 = Color3.fromRGB(255, 230, 120)
targetBox.Font = Enum.Font.GothamBold
targetBox.TextSize = 11.5
targetBox.ClearTextOnFocus = false
targetBox.Parent = r1
Instance.new("UICorner", targetBox).CornerRadius = UDim.new(0, 6)
local tbStroke = Instance.new("UIStroke", targetBox)
tbStroke.Color = Color3.fromRGB(90, 70, 140)

targetBox.FocusLost:Connect(function()
    targetNameQuery = targetBox.Text
    if cloneActive then
        startClone()
    end
    if updateUiMetrics then updateUiMetrics() end
end)

-- Row 2: Live Metrics & Clone Details Card
local card = Instance.new("Frame")
card.Size = UDim2.new(1, -24, 0, 88)
card.Position = UDim2.new(0, 12, 0, 75)
card.BackgroundColor3 = Color3.fromRGB(14, 12, 22)
card.BorderSizePixel = 0
card.Parent = main
Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)
local cardStroke = Instance.new("UIStroke", card)
cardStroke.Color = Color3.fromRGB(60, 45, 90)

local metricStats = Instance.new("TextLabel")
metricStats.Size = UDim2.new(1, -16, 0, 18)
metricStats.Position = UDim2.new(0, 10, 0, 6)
metricStats.BackgroundTransparency = 1
metricStats.Text = "• Spoofed Leaderboard: 6.16 Trillion Speed | 359.3 Billion Money/s"
metricStats.TextColor3 = Color3.fromRGB(255, 225, 120)
metricStats.Font = Enum.Font.GothamBold
metricStats.TextSize = 10.5
metricStats.TextXAlignment = Enum.TextXAlignment.Left
metricStats.Parent = card

local metricAvatar = Instance.new("TextLabel")
metricAvatar.Size = UDim2.new(1, -16, 0, 18)
metricAvatar.Position = UDim2.new(0, 10, 0, 26)
metricAvatar.BackgroundTransparency = 1
metricAvatar.Text = "• Avatar: VarietyShades02, Accessory (z), Headphones, Clothes & Colors"
metricAvatar.TextColor3 = Color3.fromRGB(210, 180, 255)
metricAvatar.Font = Enum.Font.Gotham
metricAvatar.TextSize = 10
metricAvatar.TextXAlignment = Enum.TextXAlignment.Left
metricAvatar.Parent = card

local metricStride = Instance.new("TextLabel")
metricStride.Size = UDim2.new(1, -16, 0, 18)
metricStride.Position = UDim2.new(0, 10, 0, 46)
metricStride.BackgroundTransparency = 1
metricStride.Text = "• Stride Multiplier: 21.21x Run Animation Playback Rate"
metricStride.TextColor3 = Color3.fromRGB(150, 240, 190)
metricStride.Font = Enum.Font.Gotham
metricStride.TextSize = 10
metricStride.TextXAlignment = Enum.TextXAlignment.Left
metricStride.Parent = card

local metricStatus = Instance.new("TextLabel")
metricStatus.Size = UDim2.new(1, -16, 0, 18)
metricStatus.Position = UDim2.new(0, 10, 0, 66)
metricStatus.BackgroundTransparency = 1
metricStatus.Text = "• Status: Inactive (Normal Appearance)"
metricStatus.TextColor3 = Color3.fromRGB(170, 175, 190)
metricStatus.Font = Enum.Font.GothamBold
metricStatus.TextSize = 10
metricStatus.TextXAlignment = Enum.TextXAlignment.Left
metricStatus.Parent = card

updateUiMetrics = function()
    if cloneActive then
        metricStatus.Text = string.format("• Status: ACTIVE — Local character & leaderboard mirrored to %s", targetNameQuery)
        metricStatus.TextColor3 = Color3.fromRGB(140, 255, 180)
    else
        metricStatus.Text = "• Status: Inactive (Original Appearance & Real Stats Restored)"
        metricStatus.TextColor3 = Color3.fromRGB(170, 175, 190)
    end
end

-- Row 3: Action Buttons
local r3 = Instance.new("Frame")
r3.Size = UDim2.new(1, -24, 0, 28)
r3.Position = UDim2.new(0, 12, 0, 170)
r3.BackgroundTransparency = 1
r3.Parent = main

local reapplyBtn = Instance.new("TextButton")
reapplyBtn.Size = UDim2.new(0.48, 0, 1, 0)
reapplyBtn.BackgroundColor3 = Color3.fromRGB(45, 38, 65)
reapplyBtn.Text = "🔄 Re-Sync From Target"
reapplyBtn.TextColor3 = Color3.fromRGB(220, 200, 255)
reapplyBtn.Font = Enum.Font.GothamBold; reapplyBtn.TextSize = 10.5
reapplyBtn.Parent = r3
Instance.new("UICorner", reapplyBtn).CornerRadius = UDim.new(0, 6)
reapplyBtn.MouseButton1Click:Connect(function()
    if cloneActive then
        startClone()
        updateUiMetrics()
    end
end)

local strideBtn = Instance.new("TextButton")
strideBtn.Size = UDim2.new(0.48, 0, 1, 0)
strideBtn.Position = UDim2.new(0.52, 0, 0, 0)
strideBtn.BackgroundColor3 = strideSyncActive and Color3.fromRGB(35, 75, 55) or Color3.fromRGB(50, 48, 60)
strideBtn.Text = strideSyncActive and "🏃 Stride 21.21x: ON" or "🏃 Stride 21.21x: OFF"
strideBtn.TextColor3 = strideSyncActive and Color3.fromRGB(180, 255, 200) or Color3.fromRGB(180, 180, 190)
strideBtn.Font = Enum.Font.GothamBold; strideBtn.TextSize = 10.5
strideBtn.Parent = r3
Instance.new("UICorner", strideBtn).CornerRadius = UDim.new(0, 6)

strideBtn.MouseButton1Click:Connect(function()
    strideSyncActive = not strideSyncActive
    strideBtn.BackgroundColor3 = strideSyncActive and Color3.fromRGB(35, 75, 55) or Color3.fromRGB(50, 48, 60)
    strideBtn.Text = strideSyncActive and "🏃 Stride 21.21x: ON" or "🏃 Stride 21.21x: OFF"
    strideBtn.TextColor3 = strideSyncActive and Color3.fromRGB(180, 255, 200) or Color3.fromRGB(180, 180, 190)
end)

-- Row 4: Big Toggle Button
local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(1, -24, 0, 44)
toggleBtn.Position = UDim2.new(0, 12, 0, 208)
toggleBtn.BackgroundColor3 = Color3.fromRGB(45, 40, 60)
toggleBtn.Text = "🎭 ENABLE KAIHII VISUAL & STAT CLONE [OFF]"
toggleBtn.TextColor3 = Color3.fromRGB(220, 210, 240)
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 12.5
toggleBtn.Parent = main
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 8)
local toggleStroke = Instance.new("UIStroke", toggleBtn)
toggleStroke.Color = Color3.fromRGB(100, 75, 140)
toggleStroke.Thickness = 1.5

local footerLbl = Instance.new("TextLabel")
footerLbl.Size = UDim2.new(1, -24, 0, 20)
footerLbl.Position = UDim2.new(0, 12, 0, 260)
footerLbl.BackgroundTransparency = 1
footerLbl.Text = "Client-side visual spoof • Reverts 100% cleanly on toggle off or GUI close"
footerLbl.TextColor3 = Color3.fromRGB(160, 145, 185)
footerLbl.Font = Enum.Font.Gotham
footerLbl.TextSize = 9.5
footerLbl.Parent = main

toggleBtn.MouseButton1Click:Connect(function()
    if cloneActive then
        stopClone()
        toggleBtn.BackgroundColor3 = Color3.fromRGB(45, 40, 60)
        toggleBtn.Text = "🎭 ENABLE KAIHII VISUAL & STAT CLONE [OFF]"
        toggleBtn.TextColor3 = Color3.fromRGB(220, 210, 240)
        toggleStroke.Color = Color3.fromRGB(100, 75, 140)
        updateUiMetrics()
    else
        startClone()
        toggleBtn.BackgroundColor3 = Color3.fromRGB(90, 45, 145)
        toggleBtn.Text = "🎭 KAIHII CLONE ACTIVE: ON (VISUAL & 6.16T LEADERBOARD)"
        toggleBtn.TextColor3 = Color3.fromRGB(245, 230, 255)
        toggleStroke.Color = Color3.fromRGB(180, 120, 255)
        updateUiMetrics()
    end
end)

-- Re-apply on character respawn
LocalPlayer.CharacterAdded:Connect(function(newChar)
    if cloneActive then
        task.wait(0.5)
        startClone()
        updateUiMetrics()
    end
end)

screenGui.Destroying:Connect(function()
    stopClone()
end)

updateUiMetrics()
print("[Kaihii Visual Clone] Initialized. Ready to spoof leaderboard & clone avatar.")
