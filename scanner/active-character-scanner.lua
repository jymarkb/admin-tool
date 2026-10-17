--[[
    ========================================================================
    ⚡ ACTIVE CHARACTER TELEMETRY SCANNER (v1.0)
    ========================================================================
    A dedicated live, real-time character telemetry monitor for Steal an Egg.
    Focuses 100% on the physical avatar state:
      1. 📍 LOCATION & BIOME:
         - Real-time Position (X, Y, Z), Biome Auto-Detection, Altitude (Y),
           Floor Material, Grounded / Airborne status.
      2. ⚙️ MOTORS & RIG JOINTS:
         - Motor6D count (Enabled / Disabled), exact list of disabled joints
           (identifies ragdoll joints immediately), Rig Type (R15/R6),
           HumanoidState (Physics, Ragdoll, Running, Freefall, GettingUp, etc.).
      3. ⚡ FLIGHT SPEED & PHYSICS:
         - Linear Velocity Magnitude (studs/s), Horizontal Speed (Vh),
           Vertical Speed (Vy with Climbing/Falling/Slamming indicators),
           WalkSpeed vs Actual Speed, Acceleration spikes, Session Peak Speed.
      4. 🛡️ RAGDOLL & STRIKE MONITOR:
         - RagdollEndTime attribute countdown, Stun status, Guard strike
           remote listener (ForestStrike, SpeedTollOffer, ForestHandoff).
      5. 🥚 CARRIED EGG & TOOL DETECTOR:
         - Tool equipped, ClientRenderedAssets models, Massless / CanCollide.
      6. 📜 LIVE EVENT STREAM:
         - Timestamped microsecond event log of velocity spikes, motor
           disconnects, guard strikes, and state transitions.

    Supports monitoring SELF (LocalPlayer) or ANY other player (e.g. Kaihii).
    Includes LIVE/PAUSE, COPY, SAVE FILE (active-character-scan.log), and MINIMIZE.
    ========================================================================
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ========================================================================
-- UI MOUNT
-- ========================================================================
local function getGuiParent()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local uiParent = getGuiParent()
local GUI_NAME = "ActiveCharacterTelemetryScannerGui"
local existingGui = uiParent:FindFirstChild(GUI_NAME)
if existingGui then
    pcall(function() existingGui:Destroy() end)
end

-- ========================================================================
-- BIOME DETECTION MAPPING
-- ========================================================================
local BIOME_CENTERS = {
    ["Forest"]         = Vector3.new(597.2, 68.2, -328.3),
    ["Lake"]           = Vector3.new(744.0, 68.5, -409.0),
    ["Desert"]         = Vector3.new(949.8, 68.8, -324.2),
    ["Jungle"]         = Vector3.new(1189.0, 68.8, -409.4),
    ["Snow"]           = Vector3.new(1492.4, 69.4, -314.7),
    ["Volcano"]        = Vector3.new(1879.2, 68.7, -397.9),
    ["Abyss Ocean"]    = Vector3.new(2281.6, 70.0, -327.0),
    ["Prehistoric"]    = Vector3.new(2813.6, 68.9, -397.9),
    ["Cherry Blossom"] = Vector3.new(3354.1, 68.8, -402.4),
    ["Cosmic"]         = Vector3.new(3392.1, 68.4, -324.9),
    ["Titan Temple"]   = Vector3.new(4797.7, 69.9, -328.6),
    ["Light Dark"]     = Vector3.new(5662.7, 70.7, -328.6),
}

local function detectBiome(pos, playerObj)
    if playerObj then
        local a = playerObj:GetAttribute("AreaId") or playerObj:GetAttribute("Area") or playerObj:GetAttribute("Biome")
        if a and tostring(a) ~= "" then return tostring(a) end
        local c = playerObj.Character
        if c then
            local ca = c:GetAttribute("AreaId") or c:GetAttribute("Area") or c:GetAttribute("Biome")
            if ca and tostring(ca) ~= "" then return tostring(ca) end
        end
    end
    if not pos then return "Unknown" end

    local closestBiome = "World"
    local closestDist = math.huge
    for name, center in pairs(BIOME_CENTERS) do
        local d = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(center.X, 0, center.Z)).Magnitude
        if d < closestDist then
            closestDist = d
            closestBiome = name
        end
    end

    if closestDist <= 220 then
        return closestBiome
    elseif closestDist <= 350 then
        return closestBiome .. " (Border)"
    else
        return string.format("Transit (%s ~%.0fm)", closestBiome, closestDist)
    end
end

-- ========================================================================
-- SCANNER STATE
-- ========================================================================
local isLiveActive = true
local currentTargetName = LocalPlayer.Name
local peakSpeed = 0.0
local lastPosition = nil
local lastVel = Vector3.zero
local lastTime = os.clock()
local lastStrikeInfo = "None detected"
local lastStrikeTime = 0
local autoScroll = true

local eventLog = {}

local function logEvent(text, color)
    local timestamp = os.date("%H:%M:%S")
    local ms = math.floor((os.clock() % 1) * 1000)
    local line = string.format("[%s.%03d] %s", timestamp, ms, text)
    table.insert(eventLog, { text = line, color = color or Color3.fromRGB(200, 215, 235) })
    -- no limit – keeps the entire session history
end

-- ========================================================================
-- REMOTE GUARD STRIKE HOOK
-- ========================================================================
pcall(function()
    local net = ReplicatedStorage:FindFirstChild("Packages")
    if net then net = net:FindFirstChild("Networking") end
    if not net then return end

    local function hookRemote(name, label)
        local rem = net:FindFirstChild(name)
        if rem and rem:IsA("RemoteEvent") then
            rem.OnClientEvent:Connect(function(...)
                local now = os.clock()
                lastStrikeTime = now
                lastStrikeInfo = string.format("%s (%s)", label, os.date("%H:%M:%S"))
                logEvent(string.format("💥 GUARD HIT EVENT: %s received from server!", label), Color3.fromRGB(255, 120, 120))
            end)
        end
    end

    hookRemote("RE/GuardPatrol/ForestStrike", "ForestStrike")
    hookRemote("RE/GuardPatrol/SpeedTollOffer", "SpeedTollOffer")
    hookRemote("RE/GuardPatrol/ForestHandoff", "ForestHandoff")
end)

-- ========================================================================
-- UI BUILDER
-- ========================================================================
local W, H = 640, 560
local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.DisplayOrder = 100000
gui.Parent = uiParent

local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.45, -H/2)
main.BackgroundColor3 = Color3.fromRGB(15, 17, 24)
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(50, 110, 200)
mainStroke.Thickness = 1.5

-- Dragging Behavior
do
    local dragging = false
    local dragInput, dragStart, startPos
    main.InputBegan:Connect(function(input)
        if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and input.Position.Y - main.AbsolutePosition.Y <= 34 then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    main.InputChanged:Connect(function(input)
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

-- Top Bar
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 34)
topBar.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -170, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "⚡ ACTIVE CHARACTER TELEMETRY SCANNER"
titleLbl.TextColor3 = Color3.fromRGB(220, 235, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 11.5
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local liveIndicator = Instance.new("TextLabel")
liveIndicator.Size = UDim2.new(0, 65, 0, 20)
liveIndicator.Position = UDim2.new(1, -165, 0, 7)
liveIndicator.BackgroundColor3 = Color3.fromRGB(25, 60, 40)
liveIndicator.Text = "● LIVE"
liveIndicator.TextColor3 = Color3.fromRGB(100, 255, 150)
liveIndicator.Font = Enum.Font.GothamBold
liveIndicator.TextSize = 10
liveIndicator.Parent = topBar
Instance.new("UICorner", liveIndicator).CornerRadius = UDim.new(0, 4)

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 24, 0, 24)
minBtn.Position = UDim2.new(1, -62, 0, 5)
minBtn.BackgroundColor3 = Color3.fromRGB(45, 52, 70)
minBtn.Text = "—"
minBtn.TextColor3 = Color3.fromRGB(210, 225, 255)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 12
minBtn.Parent = topBar
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 5)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -32, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 60)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

-- ========================================================================
-- TARGET BAR & PLAYER CHIPS
-- ========================================================================
local targetBar = Instance.new("Frame")
targetBar.Size = UDim2.new(1, -24, 0, 28)
targetBar.Position = UDim2.new(0, 12, 0, 42)
targetBar.BackgroundTransparency = 1
targetBar.Parent = main

local tLbl = Instance.new("TextLabel")
tLbl.Size = UDim2.new(0, 52, 1, 0)
tLbl.BackgroundTransparency = 1
tLbl.Text = "TARGET:"
tLbl.TextColor3 = Color3.fromRGB(160, 185, 220)
tLbl.Font = Enum.Font.GothamBold
tLbl.TextSize = 11
tLbl.TextXAlignment = Enum.TextXAlignment.Left
tLbl.Parent = targetBar

local targetInput = Instance.new("TextBox")
targetInput.Size = UDim2.new(0, 180, 1, 0)
targetInput.Position = UDim2.new(0, 56, 0, 0)
targetInput.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
targetInput.Text = LocalPlayer.Name
targetInput.TextColor3 = Color3.fromRGB(255, 235, 140)
targetInput.Font = Enum.Font.GothamBold
targetInput.TextSize = 11
targetInput.ClearTextOnFocus = false
targetInput.Parent = targetBar
Instance.new("UICorner", targetInput).CornerRadius = UDim.new(0, 5)
local tiStroke = Instance.new("UIStroke", targetInput)
tiStroke.Color = Color3.fromRGB(60, 95, 150)
tiStroke.Thickness = 1

local selfBtn = Instance.new("TextButton")
selfBtn.Size = UDim2.new(0, 75, 1, 0)
selfBtn.Position = UDim2.new(0, 242, 0, 0)
selfBtn.BackgroundColor3 = Color3.fromRGB(45, 55, 75)
selfBtn.Text = "ME (SELF)"
selfBtn.TextColor3 = Color3.fromRGB(180, 220, 255)
selfBtn.Font = Enum.Font.GothamBold
selfBtn.TextSize = 10
selfBtn.Parent = targetBar
Instance.new("UICorner", selfBtn).CornerRadius = UDim.new(0, 5)

-- Chips Scroll
local chipsScroll = Instance.new("ScrollingFrame")
chipsScroll.Size = UDim2.new(1, -325, 1, 0)
chipsScroll.Position = UDim2.new(0, 325, 0, 0)
chipsScroll.BackgroundTransparency = 1
chipsScroll.BorderSizePixel = 0
chipsScroll.ScrollBarThickness = 2
chipsScroll.ScrollBarImageColor3 = Color3.fromRGB(60, 100, 160)
chipsScroll.ScrollingDirection = Enum.ScrollingDirection.X
chipsScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
chipsScroll.Parent = targetBar

local chipsLayout = Instance.new("UIListLayout")
chipsLayout.FillDirection = Enum.FillDirection.Horizontal
chipsLayout.Padding = UDim.new(0, 6)
chipsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
chipsLayout.Parent = chipsScroll

local function populateChips()
    for _, ch in ipairs(chipsScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local isKaihii = (p.Name:lower():find("kaihii") or p.DisplayName:lower():find("kaihii"))
            local chip = Instance.new("TextButton")
            chip.Size = UDim2.new(0, 0, 0, 24)
            chip.AutomaticSize = Enum.AutomaticSize.X
            chip.BackgroundColor3 = isKaihii and Color3.fromRGB(90, 70, 20) or Color3.fromRGB(30, 35, 48)
            chip.Text = string.format(" %s ", p.DisplayName)
            chip.TextColor3 = isKaihii and Color3.fromRGB(255, 230, 120) or Color3.fromRGB(190, 210, 235)
            chip.Font = isKaihii and Enum.Font.GothamBold or Enum.Font.Gotham
            chip.TextSize = 10
            chip.Parent = chipsScroll
            Instance.new("UICorner", chip).CornerRadius = UDim.new(0, 4)

            chip.MouseButton1Click:Connect(function()
                targetInput.Text = p.Name
                currentTargetName = p.Name
                logEvent("🎯 Target changed to: " .. p.Name, Color3.fromRGB(140, 200, 255))
            end)
        end
    end
end
pcall(populateChips)
Players.PlayerAdded:Connect(function() pcall(populateChips) end)
Players.PlayerRemoving:Connect(function() pcall(populateChips) end)

selfBtn.MouseButton1Click:Connect(function()
    targetInput.Text = LocalPlayer.Name
    currentTargetName = LocalPlayer.Name
    logEvent("🎯 Target changed to: SELF (" .. LocalPlayer.Name .. ")", Color3.fromRGB(140, 255, 180))
end)

targetInput.FocusLost:Connect(function()
    local text = targetInput.Text:gsub("%s+", "")
    if text ~= "" then
        currentTargetName = text
        logEvent("🎯 Target set to: " .. currentTargetName, Color3.fromRGB(140, 200, 255))
    end
end)

-- ========================================================================
-- TELEMETRY CARDS CONTAINER (Upper Section: 4 Cards)
-- ========================================================================
local CARDS_Y = 76
local CARD_W = (W - 24 - 10) / 2
local CARD_H = 120

local function createCard(title, x, y, icon)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(0, CARD_W, 0, CARD_H)
    card.Position = UDim2.new(0, x, 0, y)
    card.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
    card.BorderSizePixel = 0
    card.Parent = main
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)
    local st = Instance.new("UIStroke", card)
    st.Color = Color3.fromRGB(38, 46, 64)
    st.Thickness = 1

    local cTitle = Instance.new("TextLabel")
    cTitle.Size = UDim2.new(1, -16, 0, 20)
    cTitle.Position = UDim2.new(0, 8, 0, 4)
    cTitle.BackgroundTransparency = 1
    cTitle.Text = string.format("%s %s", icon, title)
    cTitle.TextColor3 = Color3.fromRGB(140, 175, 225)
    cTitle.Font = Enum.Font.GothamBold
    cTitle.TextSize = 10.5
    cTitle.TextXAlignment = Enum.TextXAlignment.Left
    cTitle.Parent = card

    local content = Instance.new("TextLabel")
    content.Size = UDim2.new(1, -16, 0, CARD_H - 28)
    content.Position = UDim2.new(0, 8, 0, 24)
    content.BackgroundTransparency = 1
    content.Text = "Waiting for data..."
    content.TextColor3 = Color3.fromRGB(220, 230, 245)
    content.Font = Enum.Font.Code
    content.TextSize = 9.5
    content.TextXAlignment = Enum.TextXAlignment.Left
    content.TextYAlignment = Enum.TextYAlignment.Top
    content.RichText = true
    content.Parent = card

    return content
end

-- Card 1: Location & Biome
local cardLocation = createCard("LOCATION & ENVIRONMENT", 12, CARDS_Y, "📍")
-- Card 2: Velocity & Flight
local cardVelocity = createCard("FLIGHT SPEED & VELOCITY", 12 + CARD_W + 10, CARDS_Y, "⚡")
-- Card 3: Motors & Rig
local cardMotors   = createCard("MOTORS & RIG STATE", 12, CARDS_Y + CARD_H + 8, "⚙️")
-- Card 4: Ragdoll & Egg
local cardRagdoll  = createCard("RAGDOLL & CARRIED EGG", 12 + CARD_W + 10, CARDS_Y + CARD_H + 8, "🥚")

-- ========================================================================
-- ACTION CONTROLS BAR (Row 3: Live Toggle, Copy, Save, Clear, AutoScroll)
-- ========================================================================
local ROW3_Y = CARDS_Y + (CARD_H * 2) + 16
local actBar = Instance.new("Frame")
actBar.Size = UDim2.new(1, -24, 0, 26)
actBar.Position = UDim2.new(0, 12, 0, ROW3_Y)
actBar.BackgroundTransparency = 1
actBar.Parent = main

local liveBtn = Instance.new("TextButton")
liveBtn.Size = UDim2.new(0, 110, 1, 0)
liveBtn.BackgroundColor3 = Color3.fromRGB(30, 130, 75)
liveBtn.Text = "⏸ PAUSE STREAM"
liveBtn.TextColor3 = Color3.new(1, 1, 1)
liveBtn.Font = Enum.Font.GothamBold
liveBtn.TextSize = 10
liveBtn.Parent = actBar
Instance.new("UICorner", liveBtn).CornerRadius = UDim.new(0, 5)

local resetPeakBtn = Instance.new("TextButton")
resetPeakBtn.Size = UDim2.new(0, 90, 1, 0)
resetPeakBtn.Position = UDim2.new(0, 116, 0, 0)
resetPeakBtn.BackgroundColor3 = Color3.fromRGB(45, 52, 70)
resetPeakBtn.Text = "RESET PEAK"
resetPeakBtn.TextColor3 = Color3.fromRGB(200, 220, 245)
resetPeakBtn.Font = Enum.Font.GothamBold
resetPeakBtn.TextSize = 10
resetPeakBtn.Parent = actBar
Instance.new("UICorner", resetPeakBtn).CornerRadius = UDim.new(0, 5)

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0, 95, 1, 0)
copyBtn.Position = UDim2.new(0, 212, 0, 0)
copyBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 160)
copyBtn.Text = "📋 COPY LOG"
copyBtn.TextColor3 = Color3.new(1, 1, 1)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 10
copyBtn.Parent = actBar
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 5)

local saveBtn = Instance.new("TextButton")
saveBtn.Size = UDim2.new(0, 95, 1, 0)
saveBtn.Position = UDim2.new(0, 313, 0, 0)
saveBtn.BackgroundColor3 = Color3.fromRGB(95, 60, 140)
saveBtn.Text = "💾 SAVE FILE"
saveBtn.TextColor3 = Color3.new(1, 1, 1)
saveBtn.Font = Enum.Font.GothamBold
saveBtn.TextSize = 10
saveBtn.Parent = actBar
Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 5)

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 80, 1, 0)
clearBtn.Position = UDim2.new(0, 414, 0, 0)
clearBtn.BackgroundColor3 = Color3.fromRGB(55, 60, 75)
clearBtn.Text = "CLEAR LOG"
clearBtn.TextColor3 = Color3.fromRGB(210, 215, 230)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 10
clearBtn.Parent = actBar
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 5)

local autoScrollBtn = Instance.new("TextButton")
autoScrollBtn.Size = UDim2.new(0, 110, 1, 0)
autoScrollBtn.Position = UDim2.new(1, -110, 0, 0)
autoScrollBtn.BackgroundColor3 = Color3.fromRGB(35, 75, 115)
autoScrollBtn.Text = "AUTO-SCROLL: ON"
autoScrollBtn.TextColor3 = Color3.fromRGB(180, 230, 255)
autoScrollBtn.Font = Enum.Font.GothamBold
autoScrollBtn.TextSize = 9.5
autoScrollBtn.Parent = actBar
Instance.new("UICorner", autoScrollBtn).CornerRadius = UDim.new(0, 5)

-- ========================================================================
-- LIVE EVENT STREAM VIEWER (Lower Section)
-- ========================================================================
local LOG_Y = ROW3_Y + 34
local LOG_H = H - LOG_Y - 12

local logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -24, 0, LOG_H)
logScroll.Position = UDim2.new(0, 12, 0, LOG_Y)
logScroll.BackgroundColor3 = Color3.fromRGB(10, 12, 17)
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 5
logScroll.ScrollBarImageColor3 = Color3.fromRGB(50, 95, 170)
logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.Parent = main
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 8)
local logStroke = Instance.new("UIStroke", logScroll)
logStroke.Color = Color3.fromRGB(32, 40, 58)
logStroke.Thickness = 1

local logBox = Instance.new("TextBox")
logBox.Size = UDim2.new(1, -14, 0, 0)
logBox.Position = UDim2.new(0, 7, 0, 6)
logBox.AutomaticSize = Enum.AutomaticSize.Y
logBox.BackgroundTransparency = 1
logBox.MultiLine = true
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.Font = Enum.Font.Code
logBox.TextSize = 9.5
logBox.TextColor3 = Color3.fromRGB(190, 220, 245)
logBox.Text = "-- Active Character Telemetry Event Stream Initialized --"
logBox.Parent = logScroll

-- ========================================================================
-- TARGET RESOLVER
-- ========================================================================
local function resolveTarget()
    local name = currentTargetName:lower()
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == name or p.DisplayName:lower() == name or p.Name:lower():find(name, 1, true) then
            return p, p.Character
        end
    end
    -- Fallback: Check Workspace directly for character model
    for _, c in ipairs(Workspace:GetChildren()) do
        if c:IsA("Model") and c:FindFirstChildOfClass("Humanoid") then
            if c.Name:lower() == name or c.Name:lower():find(name, 1, true) then
                return nil, c
            end
        end
    end
    return LocalPlayer, LocalPlayer.Character
end

-- ========================================================================
-- TELEMETRY SCAN & UPDATE LOOP
-- ========================================================================
local lastStateName = ""
local lastMotorsDisabledCount = 0
local lastRagdollEndTime = 0
local lastToolName = ""
local frameCount = 0

local function updateTelemetry()
    if not isLiveActive then return end
    frameCount = frameCount + 1

    local pObj, char = resolveTarget()
    if not char then
        cardLocation.Text = "<font color='#FF6666'>Character not found in Workspace!</font>"
        cardVelocity.Text = "N/A"
        cardMotors.Text   = "N/A"
        cardRagdoll.Text  = "N/A"
        return
    end

    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    local hum = char:FindFirstChildOfClass("Humanoid")
    local now = os.clock()
    local dt = math.max(now - lastTime, 0.001)

    -- 1. LOCATION & BIOME
    local posStr, biomeStr, altStr, floorStr
    local pos = hrp and hrp.Position
    if pos then
        posStr = string.format("<b>Pos:</b> (%.1f, %.1f, %.1f)", pos.X, pos.Y, pos.Z)
        local detectedB = detectBiome(pos, pObj)
        biomeStr = string.format("<b>Biome:</b> <font color='#80FFB0'>%s</font>", detectedB)
        local altAboveGround = pos.Y - 68.2
        local altTag = altAboveGround > 3 and string.format("+%.1f studs (Mid-Air)", altAboveGround) or string.format("%.1f (Grounded)", altAboveGround)
        altStr = string.format("<b>Altitude:</b> Y=%.1f [%s]", pos.Y, altTag)
    else
        posStr = "<b>Pos:</b> (No RootPart)"
        biomeStr = "<b>Biome:</b> Unknown"
        altStr = "<b>Altitude:</b> N/A"
    end

    local flMat = hum and tostring(hum.FloorMaterial.Name) or "None"
    local grounded = flMat ~= "Air"
    local groundTag = grounded and string.format("<font color='#66FF88'>Grounded (%s)</font>", flMat) or "<font color='#FFCC66'>AIRBORNE</font>"
    floorStr = string.format("<b>Surface:</b> %s", groundTag)

    cardLocation.Text = string.format("%s\n%s\n%s\n%s", posStr, biomeStr, altStr, floorStr)

    -- 2. FLIGHT SPEED & VELOCITY
    local vel = (hrp and hrp.AssemblyLinearVelocity) or Vector3.zero
    local speed = vel.Magnitude
    local vh = math.sqrt(vel.X^2 + vel.Z^2)
    local vy = vel.Y

    if speed > peakSpeed then
        peakSpeed = speed
    end

    local vyTag
    if vy > 5 then
        vyTag = string.format("<font color='#80D0FF'>▲ +%.1f (Climbing)</font>", vy)
    elseif vy < -30 then
        vyTag = string.format("<font color='#FF4444'>▼ %.1f [SLAMMING!]</font>", vy)
    elseif vy < -5 then
        vyTag = string.format("<font color='#FFB066'>▼ %.1f (Falling)</font>", vy)
    else
        vyTag = string.format("<font color='#A0A0A0'>― %.1f (Level)</font>", vy)
    end

    local speedColor = "#A0B0C0"
    if speed >= 300 then
        speedColor = "#E066FF" -- Supersonic Purple
    elseif speed >= 100 then
        speedColor = "#FFB040" -- Fast Flight Orange
    elseif speed >= 25 then
        speedColor = "#66D0FF" -- Moving Blue
    end

    local wSpeed = hum and hum.WalkSpeed or 0
    local velText = string.format("<b>Speed:</b> <font color='%s'><b>%.1f</b> studs/s</font> (Peak: <b>%.1f</b>)\n<b>Horizontal (Vh):</b> %.1f studs/s\n<b>Vertical (Vy):</b> %s\n<b>Humanoid.WalkSpeed:</b> %.1f",
        speedColor, speed, peakSpeed, vh, vyTag, wSpeed)
    cardVelocity.Text = velText

    -- Velocity spike detector
    if (speed - lastVel.Magnitude) > 80 and speed > 150 then
        logEvent(string.format("⚡ VELOCITY SPIKE: %.1f studs/s (+%.1f) | Vh=%.1f, Vy=%.1f", speed, speed - lastVel.Magnitude, vh, vy), Color3.fromRGB(255, 215, 80))
    end
    if vy < -50 and lastVel.Y >= -20 then
        logEvent(string.format("⚠️ DOWNWARD SLAM DETECTED: Vy = %.1f studs/s!", vy), Color3.fromRGB(255, 90, 90))
    end

    -- 3. MOTORS & RIG STATE
    local totalMotors = 0
    local enabledMotors = 0
    local disabledMotors = {}

    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("Motor6D") then
            totalMotors = totalMotors + 1
            if d.Enabled then
                enabledMotors = enabledMotors + 1
            else
                table.insert(disabledMotors, d.Name)
            end
        end
    end

    local rigType = hum and tostring(hum.RigType.Name) or "Unknown"
    local humState = hum and tostring(hum:GetState().Name) or "None"
    local pStand = hum and hum.PlatformStand or false
    local sit = hum and hum.Sit or false

    local motorStatusTag
    if #disabledMotors > 0 then
        motorStatusTag = string.format("<font color='#FF5555'><b>%d/%d</b> (%d DISABLED!)</font>", enabledMotors, totalMotors, #disabledMotors)
    else
        motorStatusTag = string.format("<font color='#66FF88'><b>%d/%d OK</b> (All Enabled)</font>", enabledMotors, totalMotors)
    end

    local disListStr = #disabledMotors > 0 and table.concat(disabledMotors, ", ") or "None (Rig Intact)"
    if #disListStr > 42 then disListStr = disListStr:sub(1, 39) .. "..." end

    local stateColor = (humState == "Physics" or humState == "Ragdoll" or humState == "FallingDown") and "#FF6666" or "#80FFB0"
    local motorText = string.format("<b>Motors:</b> %s\n<b>Disabled:</b> <font color='#FFBB88'>%s</font>\n<b>HumanoidState:</b> <font color='%s'>%s</font> (Rig: %s)\n<b>Physics:</b> PlatformStand=%s, Sit=%s",
        motorStatusTag, disListStr, stateColor, humState, rigType, tostring(pStand), tostring(sit))
    cardMotors.Text = motorText

    -- Motor change event logger
    if #disabledMotors ~= lastMotorsDisabledCount then
        if #disabledMotors > lastMotorsDisabledCount then
            logEvent(string.format("⚠️ MOTORS DISABLED (+%d): %s (Total Disabled: %d)", #disabledMotors - lastMotorsDisabledCount, table.concat(disabledMotors, ", "), #disabledMotors), Color3.fromRGB(255, 100, 100))
        elseif #disabledMotors < lastMotorsDisabledCount then
            logEvent(string.format("🛡️ MOTORS RESTORED: %d/%d now enabled", enabledMotors, totalMotors), Color3.fromRGB(100, 255, 160))
        end
        lastMotorsDisabledCount = #disabledMotors
    end

    -- HumanoidState change event logger
    if humState ~= lastStateName and lastStateName ~= "" then
        local stColor = (humState == "Physics" or humState == "Ragdoll") and Color3.fromRGB(255, 120, 120) or Color3.fromRGB(180, 230, 255)
        logEvent(string.format("🔄 State Change: %s -> %s", lastStateName, humState), stColor)
    end
    lastStateName = humState

    -- 4. RAGDOLL & CARRIED EGG
    local ragdollEndTime = pObj and pObj:GetAttribute("RagdollEndTime") or 0
    if typeof(ragdollEndTime) ~= "number" then ragdollEndTime = 0 end
    local ragRemaining = math.max(0, ragdollEndTime - now)
    local ragTag = ragRemaining > 0 and string.format("<font color='#FF5555'><b>STUNNED (+%.2fs remaining)</b></font>", ragRemaining) or "<font color='#66FF88'>Clear (0.0s)</font>"

    if ragdollEndTime > (lastRagdollEndTime + 0.5) and ragRemaining > 0.5 then
        logEvent(string.format("⚡ RAGDOLL ATTRIBUTE SET: RagdollEndTime = %.2f (+%.2fs duration)", ragdollEndTime, ragRemaining), Color3.fromRGB(255, 140, 60))
    end
    lastRagdollEndTime = ragdollEndTime

    -- Carried tool & egg
    local heldTool = nil
    for _, ch in ipairs(char:GetChildren()) do
        if ch:IsA("Tool") then
            heldTool = ch
            break
        end
    end

    local toolDesc = "None in hand"
    local isHoldingEgg = false
    if heldTool then
        local tName = heldTool.Name
        local isEgg = tName:lower():find("egg") or (heldTool:GetAttribute("ItemType") == "Egg")
        if isEgg then
            isHoldingEgg = true
            toolDesc = string.format("<font color='#FFD060'>🥚 %s [ACTIVE EGG]</font>", tName)
        else
            toolDesc = string.format("%s (Tool)", tName)
        end
    end

    -- Check ClientRenderedAssets
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    local craEggCount = 0
    if cra and pObj then
        local uidStr = tostring(pObj.UserId)
        for _, m in ipairs(cra:GetChildren()) do
            if string.find(m.Name, uidStr) then
                craEggCount = craEggCount + 1
                isHoldingEgg = true
            end
        end
    end

    local craTag = craEggCount > 0 and string.format("<font color='#FFD060'>YES (%d rendered model)</font>", craEggCount) or (isHoldingEgg and "<font color='#FFD060'>YES (Tool)</font>" or "<font color='#A0A0A0'>NO</font>")

    local strikeTag = (now - lastStrikeTime < 6.0)
        and string.format("<font color='#FF4444'><b>%s (%.1fs ago)</b></font>", lastStrikeInfo, now - lastStrikeTime)
        or string.format("<font color='#A0A0A0'>%s</font>", lastStrikeInfo)

    local ragText = string.format("<b>Ragdoll Timer:</b> %s\n<b>Carrying Egg:</b> %s\n<b>Equipped Tool:</b> %s\n<b>Last Guard Hit:</b> %s",
        ragTag, craTag, toolDesc, strikeTag)
    cardRagdoll.Text = ragText

    if heldTool and heldTool.Name ~= lastToolName then
        logEvent(string.format("🎒 Tool equipped: %s", heldTool.Name), Color3.fromRGB(240, 220, 140))
        lastToolName = heldTool.Name
    elseif not heldTool and lastToolName ~= "" then
        logEvent(string.format("🎒 Tool unequipped (was: %s)", lastToolName), Color3.fromRGB(180, 180, 200))
        lastToolName = ""
    end

    -- Update state for next tick
    lastPos = pos
    lastVel = vel
    lastTime = now
end

-- ========================================================================
-- LOG TEXT RENDERER
-- ========================================================================
local logDirty = true
local lastRenderedLogCount = 0

local function renderEventLog()
    if #eventLog == lastRenderedLogCount and not logDirty then return end
    lastRenderedLogCount = #eventLog
    logDirty = false

    local lines = {}
    for _, entry in ipairs(eventLog) do
        table.insert(lines, entry.text)
    end
    logBox.Text = table.concat(lines, "\n")

    if autoScroll then
        task.defer(function()
            logScroll.CanvasPosition = Vector2.new(0, math.max(0, logScroll.AbsoluteCanvasSize.Y))
        end)
    end
end

-- ========================================================================
-- BUTTON HOOKS
-- ========================================================================
liveBtn.MouseButton1Click:Connect(function()
    isLiveActive = not isLiveActive
    if isLiveActive then
        liveBtn.Text = "⏸ PAUSE STREAM"
        liveBtn.BackgroundColor3 = Color3.fromRGB(30, 130, 75)
        liveIndicator.Text = "● LIVE"
        liveIndicator.TextColor3 = Color3.fromRGB(100, 255, 150)
        liveIndicator.BackgroundColor3 = Color3.fromRGB(25, 60, 40)
        logEvent("▶ Stream resumed.", Color3.fromRGB(100, 255, 150))
    else
        liveBtn.Text = "▶ RESUME STREAM"
        liveBtn.BackgroundColor3 = Color3.fromRGB(140, 95, 30)
        liveIndicator.Text = "■ PAUSED"
        liveIndicator.TextColor3 = Color3.fromRGB(255, 150, 100)
        liveIndicator.BackgroundColor3 = Color3.fromRGB(60, 35, 25)
        logEvent("⏸ Stream paused.", Color3.fromRGB(255, 150, 100))
    end
end)

resetPeakBtn.MouseButton1Click:Connect(function()
    peakSpeed = 0.0
    logEvent("🔄 Session peak speed reset to 0.", Color3.fromRGB(180, 200, 230))
end)

autoScrollBtn.MouseButton1Click:Connect(function()
    autoScroll = not autoScroll
    autoScrollBtn.Text = autoScroll and "AUTO-SCROLL: ON" or "AUTO-SCROLL: OFF"
    autoScrollBtn.BackgroundColor3 = autoScroll and Color3.fromRGB(35, 75, 115) or Color3.fromRGB(50, 55, 70)
end)

clearBtn.MouseButton1Click:Connect(function()
    eventLog = {}
    logDirty = true
    logBox.Text = "-- Cleared --"
    logEvent("🧹 Log cleared.", Color3.fromRGB(160, 180, 210))
end)

copyBtn.MouseButton1Click:Connect(function()
    local text = logBox.Text
    local clipOk = false
    if typeof(setclipboard) == "function" then
        clipOk = pcall(setclipboard, text)
    end
    if clipOk then
        logEvent("📋 Event log copied to clipboard!", Color3.fromRGB(120, 255, 160))
    else
        logBox.TextEditable = true
        logBox:CaptureFocus()
        logEvent("📋 setclipboard unavailable. Log text focused for Ctrl+C.", Color3.fromRGB(255, 220, 100))
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    local cleanName = currentTargetName:gsub("%W+", "_"):lower()
    local fileName = string.format("active-%s-scan.log", cleanName)
    local text = logBox.Text

    if typeof(writefile) == "function" then
        local ok, err = pcall(writefile, fileName, text)
        if ok then
            logEvent("💾 Saved log to " .. fileName .. "!", Color3.fromRGB(120, 255, 160))
        else
            logEvent("❌ writefile failed: " .. tostring(err), Color3.fromRGB(255, 100, 100))
        end
    else
        logEvent("❌ writefile() is not supported in this executor.", Color3.fromRGB(255, 160, 100))
    end
end)

-- Minimize Behavior
local isMinimized = false
local contentWidgets = { targetBar, actBar, logScroll }
minBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        minBtn.Text = "+"
        main.Size = UDim2.new(0, W, 0, 34)
        for _, card in ipairs({ cardLocation.Parent, cardVelocity.Parent, cardMotors.Parent, cardRagdoll.Parent }) do
            card.Visible = false
        end
        for _, w in ipairs(contentWidgets) do w.Visible = false end
    else
        minBtn.Text = "—"
        main.Size = UDim2.new(0, W, 0, H)
        for _, card in ipairs({ cardLocation.Parent, cardVelocity.Parent, cardMotors.Parent, cardRagdoll.Parent }) do
            card.Visible = true
        end
        for _, w in ipairs(contentWidgets) do w.Visible = true end
    end
end)

closeBtn.MouseButton1Click:Connect(function()
    isLiveActive = false
    gui:Destroy()
end)

-- ========================================================================
-- HEARTBEAT TICK
-- ========================================================================
local heartbeatConn = RunService.Heartbeat:Connect(function()
    pcall(updateTelemetry)
    if frameCount % 3 == 0 then
        pcall(renderEventLog)
    end
end)

gui.Destroying:Connect(function()
    isLiveActive = false
    pcall(function() heartbeatConn:Disconnect() end)
end)

logEvent(string.format("🚀 Active Character Scanner initialized for target: %s", currentTargetName), Color3.fromRGB(120, 255, 180))
print("[Active Character Scanner] Initialized. Monitoring: " .. currentTargetName)
