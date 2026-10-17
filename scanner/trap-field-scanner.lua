--[[
    TRAP & HAZARD FIELD SCANNER (MAP DETECTOR + REMOTE SNIFFER + 3D ESP)
    =====================================================================
    Empirically detects, tracks, and visualizes placed traps on the map/field.

    Capabilities:
      1. REAL-TIME MAP DETECTION (Workspace Scanner):
         - Scans Workspace and sub-containers (Workspace.World, Sentries, Build,
           ClientRenderedAssets, Debris, Map) for active placed traps and hazards.
         - Real-time DescendantAdded / DescendantRemoving hooks for instant (0ms)
           alert when a trap is placed or triggered.
         - Distinguishes between Held Tools (in player hands/Backpack) vs
           Active Field Traps (placed on the ground).

      2. NETWORK REMOTE SNIFFER (Event Hooks):
         - Intercepts and logs trap-related network calls:
           • RE/ToolTrigger/Trigger (when tool activates placement)
           • RE/MineTrap/TrapSet (server confirming trap armed)
           • RE/MineTrap/AttachOutline (outline/render event)
           • RE/MineTrap/AskPlace & RE/TrapPlacement/AskPlace
           • TrapRemote (game root trap events)

      3. 3D VISUAL ESP & PROXIMITY RADAR:
         - Visual Highlights (red glow) & BillboardGui over all traps on field.
         - Real-time distance tracker and danger warning (< 15 studs).

      4. SAFE & COMPATIBLE:
         - Zero lag: throttled updates (2 Hz), no per-frame Workspace loops.
         - Clean destruction: one-click close removes all ESP and event listeners.
--]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    pcall(function() LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer end)
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

-- ============================================================================
-- CLEANUP PREVIOUS INSTANCES
-- ============================================================================
local GUI_NAME = "TrapFieldScannerUI"
local ESP_FOLDER_NAME = "TrapScanner_ESP"

if _G.TrapScanner_Cleanup then
    pcall(_G.TrapScanner_Cleanup)
end
_G.TrapScanner_Cleanup = nil

pcall(function()
    if CoreGui:FindFirstChild(GUI_NAME) then CoreGui[GUI_NAME]:Destroy() end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg and pg:FindFirstChild(GUI_NAME) then pg[GUI_NAME]:Destroy() end
    if CoreGui:FindFirstChild(ESP_FOLDER_NAME) then CoreGui[ESP_FOLDER_NAME]:Destroy() end
end)

-- ============================================================================
-- CONFIGURATION & STATE
-- ============================================================================
local CONFIG = {
    DangerRadius = 16.0,        -- Studs to consider a trap a critical danger (expanded evasion area)
    EspEnabled   = true,        -- Visual Highlights & BillboardGuis
    ScanInterval = 1.0,         -- Seconds between background sweeps
}

local activeTraps = {}          -- [Instance] = { Name, Position, Distance, IsHeld, Path, FirstSeen }
local remoteLogs  = {}          -- Array of recent remote event strings
local connections = {}
local espInstances = {}

local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

-- ============================================================================
-- HELPER UTILITIES
-- ============================================================================
local function getGuiParent()
    if typeof(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local okCore, core = pcall(function() return CoreGui end)
    if okCore and core then return core end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function getInstancePos(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Model") then
        local okPivot, pv = pcall(function() return inst:GetPivot().Position end)
        if okPivot and pv then return pv end
        local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
        if prim then return prim.Position end
    end
    return nil
end

local function isPlayerCharacter(inst)
    if not inst then return false end
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character and (inst == pl.Character or inst:IsDescendantOf(pl.Character)) then
            return true, pl.Name
        end
        local bp = pl:FindFirstChildOfClass("Backpack")
        if bp and inst:IsDescendantOf(bp) then
            return true, pl.Name
        end
    end
    return false, nil
end

-- Check if instance matches trap keywords or structure
local function isTrapCandidate(inst)
    if not inst or not inst.Parent then return false end
    if inst:IsA("Terrain") or inst == Workspace.CurrentCamera then return false end

    local name = string.lower(inst.Name)
    local isMatch = false

    -- 1. Explicit keyword matching
    local keywords = { "trap", "minetrap", "beartrap", "snare", "hazard", "sentry" }
    for _, kw in ipairs(keywords) do
        if string.find(name, kw, 1, true) then
            isMatch = true
            break
        end
    end

    -- 2. Attribute matching
    if not isMatch then
        local attrs = inst:GetAttributes()
        for k in pairs(attrs) do
            local lk = string.lower(k)
            if string.find(lk, "trap", 1, true) or string.find(lk, "mine", 1, true) then
                isMatch = true
                break
            end
        end
    end

    if not isMatch then return false end

    -- Only consider Models, Tools, or distinct Parts (not individual sub-meshes inside a trap)
    if inst:IsA("Model") or inst:IsA("Tool") then
        return true
    end

    if inst:IsA("BasePart") then
        -- If it is part of a Model that is already a trap, let the Model represent it
        local p = inst.Parent
        if p and (p:IsA("Model") or p:IsA("Tool")) then
            local pName = string.lower(p.Name)
            for _, kw in ipairs(keywords) do
                if string.find(pName, kw, 1, true) then
                    return false -- Handled by parent model
                end
            end
        end
        return true
    end

    return false
end

-- ============================================================================
-- 3D ESP SYSTEM
-- ============================================================================
local espFolder = Instance.new("Folder")
espFolder.Name = ESP_FOLDER_NAME
pcall(function() espFolder.Parent = getGuiParent() end)

local function removeEsp(inst)
    if espInstances[inst] then
        for _, obj in pairs(espInstances[inst]) do
            pcall(function() obj:Destroy() end)
        end
        espInstances[inst] = nil
    end
end

local function updateOrCreateEsp(inst, trapData)
    if not CONFIG.EspEnabled then
        removeEsp(inst)
        return
    end

    if trapData.IsHeld then
        removeEsp(inst) -- Do not draw field ESP on tools held in backpacks/hands
        return
    end

    local existing = espInstances[inst]
    if not existing then
        local highlight = Instance.new("Highlight")
        highlight.Name = "TrapHighlight_" .. inst.Name
        highlight.Adornee = inst
        highlight.FillColor = Color3.fromRGB(255, 50, 50)
        highlight.OutlineColor = Color3.fromRGB(255, 230, 80)
        highlight.FillTransparency = 0.5
        highlight.OutlineTransparency = 0
        pcall(function() highlight.Parent = espFolder end)

        local bb = Instance.new("BillboardGui")
        bb.Name = "TrapBillboard_" .. inst.Name
        bb.Adornee = inst:IsA("BasePart") and inst or (inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true))
        bb.Size = UDim2.new(0, 160, 0, 42)
        bb.StudsOffset = Vector3.new(0, 3.2, 0)
        bb.AlwaysOnTop = true
        pcall(function() bb.Parent = espFolder end)

        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(1, 0, 1, 0)
        frame.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
        frame.BackgroundTransparency = 0.2
        frame.BorderSizePixel = 0
        frame.Parent = bb
        Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 5)
        local stroke = Instance.new("UIStroke", frame)
        stroke.Color = Color3.fromRGB(255, 75, 75)
        stroke.Thickness = 1.2

        local lblTitle = Instance.new("TextLabel")
        lblTitle.Name = "Title"
        lblTitle.Size = UDim2.new(1, 0, 0, 20)
        lblTitle.BackgroundTransparency = 1
        lblTitle.Text = "⚠️ TRAP: " .. inst.Name
        lblTitle.TextColor3 = Color3.fromRGB(255, 120, 120)
        lblTitle.Font = Enum.Font.GothamBold
        lblTitle.TextSize = 11
        lblTitle.Parent = frame

        local lblDist = Instance.new("TextLabel")
        lblDist.Name = "Dist"
        lblDist.Size = UDim2.new(1, 0, 0, 18)
        lblDist.Position = UDim2.new(0, 0, 0, 20)
        lblDist.BackgroundTransparency = 1
        lblDist.Text = "..."
        lblDist.TextColor3 = Color3.fromRGB(255, 240, 150)
        lblDist.Font = Enum.Font.GothamMedium
        lblDist.TextSize = 10
        lblDist.Parent = frame

        existing = { Highlight = highlight, Billboard = bb, LabelDist = lblDist, Frame = frame }
        espInstances[inst] = existing
    end

    if existing.LabelDist then
        local d = trapData.Distance or 0
        existing.LabelDist.Text = string.format("%.1f studs", d)
        if d <= CONFIG.DangerRadius then
            existing.LabelDist.TextColor3 = Color3.fromRGB(255, 60, 60)
            existing.Frame.BackgroundColor3 = Color3.fromRGB(50, 15, 20)
        else
            existing.LabelDist.TextColor3 = Color3.fromRGB(255, 240, 150)
            existing.Frame.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
        end
    end
end

-- ============================================================================
-- ============================================================================
-- MAP DETECTOR CORE
-- ============================================================================
local function getTrapOwner(inst)
    if not inst then return nil end
    local attrs = {}
    pcall(function() attrs = inst:GetAttributes() end)
    for _, k in ipairs({"Owner", "OwnerUserId", "Creator", "PlacedBy", "UserId", "Player", "Placer"}) do
        if attrs[k] ~= nil then
            return tostring(attrs[k])
        end
    end
    for _, childName in ipairs({"Owner", "Creator", "PlacedBy", "Player"}) do
        local c = inst:FindFirstChild(childName)
        if c then
            if c:IsA("ObjectValue") and c.Value then
                return c.Value.Name
            elseif (c:IsA("StringValue") or c:IsA("IntValue")) and c.Value then
                return tostring(c.Value)
            end
        end
    end
    return nil
end

local function unregisterTrap(inst)
    if activeTraps[inst] then
        local data = activeTraps[inst]
        if data.Connections then
            for _, c in ipairs(data.Connections) do
                pcall(function() c:Disconnect() end)
            end
        end
        activeTraps[inst] = nil
        removeEsp(inst)
    end
end

local function registerTrap(inst)
    if not inst or activeTraps[inst] then return end
    if not isTrapCandidate(inst) then return end

    local isHeld, holderName = isPlayerCharacter(inst)
    local pos = getInstancePos(inst)
    local owner = getTrapOwner(inst)

    local trapConns = {}
    pcall(function()
        table.insert(trapConns, inst.AncestryChanged:Connect(function(_, parent)
            if not parent or not inst:IsDescendantOf(Workspace) then
                unregisterTrap(inst)
            end
        end))
    end)
    pcall(function()
        table.insert(trapConns, inst.Destroying:Connect(function()
            unregisterTrap(inst)
        end))
    end)

    activeTraps[inst] = {
        Instance    = inst,
        Name        = inst.Name,
        ClassName   = inst.ClassName,
        Position    = pos,
        Distance    = 0,
        IsHeld      = isHeld,
        Holder      = holderName,
        Owner       = owner,
        Path        = inst:GetFullName(),
        FirstSeen   = os.clock(),
        Connections = trapConns
    }
end

-- Deep scan across Workspace
local function scanMapForTraps()
    -- 1. High-priority targeted scan: Workspace.Transient (authoritative field trap container)
    local transient = Workspace:FindFirstChild("Transient")
    if transient then
        for _, ch in ipairs(transient:GetChildren()) do
            if isTrapCandidate(ch) or string.find(string.lower(ch.Name), "trap", 1, true) then
                registerTrap(ch)
            end
        end
    end

    -- 2. Scan direct Workspace & World areas
    local rootsToScan = {
        Workspace:FindFirstChild("World"),
        Workspace:FindFirstChild("ClientRenderedAssets"),
        Workspace:FindFirstChild("Debris"),
        Workspace:FindFirstChild("Map")
    }

    for _, root in ipairs(rootsToScan) do
        if root then
            for _, desc in ipairs(root:GetDescendants()) do
                if isTrapCandidate(desc) then
                    registerTrap(desc)
                end
            end
        end
    end

    -- Direct children of Workspace (in case placed outside Transient)
    for _, ch in ipairs(Workspace:GetChildren()) do
        if ch ~= transient and isTrapCandidate(ch) then
            registerTrap(ch)
        end
    end

    -- 3. Scan Player Characters (for held traps)
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then
            for _, ch in ipairs(pl.Character:GetChildren()) do
                if isTrapCandidate(ch) then registerTrap(ch) end
            end
        end
        local bp = pl:FindFirstChildOfClass("Backpack")
        if bp then
            for _, ch in ipairs(bp:GetChildren()) do
                if isTrapCandidate(ch) then registerTrap(ch) end
            end
        end
    end
end

-- Real-time targeted listeners for Workspace.Transient (0ms latency, zero polling lag)
local function attachTransientListeners(transient)
    if not transient then return end
    addConnection(transient.ChildAdded:Connect(function(child)
        if isTrapCandidate(child) or string.find(string.lower(child.Name), "trap", 1, true) then
            registerTrap(child)
        end
    end))
    addConnection(transient.ChildRemoved:Connect(function(child)
        if activeTraps[child] then
            unregisterTrap(child)
        end
    end))
end

local transientFolder = Workspace:FindFirstChild("Transient")
if transientFolder then
    attachTransientListeners(transientFolder)
end

addConnection(Workspace.ChildAdded:Connect(function(child)
    if child.Name == "Transient" then
        attachTransientListeners(child)
    elseif isTrapCandidate(child) then
        registerTrap(child)
    end
end))

-- General Workspace fallback listeners
addConnection(Workspace.DescendantAdded:Connect(function(desc)
    if isTrapCandidate(desc) then
        registerTrap(desc)
    end
end))

addConnection(Workspace.DescendantRemoving:Connect(function(desc)
    unregisterTrap(desc)
end))

-- Player leaving listener: cleans up player traps & held tools if player disconnects
addConnection(Players.PlayerRemoving:Connect(function(player)
    local pName = player.Name
    local pUserId = tostring(player.UserId)
    for inst, data in pairs(activeTraps) do
        if data.Holder == pName then
            unregisterTrap(inst)
        elseif data.Owner and (data.Owner == pName or data.Owner == pUserId) then
            unregisterTrap(inst)
        end
    end
end))

-- ============================================================================
-- NETWORK REMOTE SNIFFER
-- ============================================================================
local function logRemoteEvent(name, details)
    local timestamp = os.date("%X")
    local entry = string.format("[%s] %s: %s", timestamp, name, tostring(details))
    table.insert(remoteLogs, 1, entry)
    if #remoteLogs > 40 then table.remove(remoteLogs) end
end

local function hookRemote(name, onCall)
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    local rem = nil
    if net then rem = net:FindFirstChild(name) end
    if not rem then rem = ReplicatedStorage:FindFirstChild(name, true) end

    if rem and rem:IsA("RemoteEvent") then
        addConnection(rem.OnClientEvent:Connect(function(...)
            pcall(onCall, ...)
        end))
        logRemoteEvent("Hooked", rem.Name)
    end
end

-- Hook game trap events discovered in latest.log
pcall(function()
    hookRemote("RE/MineTrap/TrapSet", function(data)
        logRemoteEvent("MineTrap/TrapSet", typeof(data) == "table" and "Table Payload" or tostring(data))
        scanMapForTraps() -- Trigger immediate map refresh
    end)

    hookRemote("RE/MineTrap/AttachOutline", function(data)
        logRemoteEvent("MineTrap/AttachOutline", tostring(data))
    end)

    hookRemote("RE/MineTrap/AskPlace", function(data)
        logRemoteEvent("MineTrap/AskPlace", tostring(data))
    end)

    hookRemote("RE/TrapPlacement/AskPlace", function(data)
        logRemoteEvent("TrapPlacement/AskPlace", tostring(data))
    end)

    hookRemote("TrapRemote", function(data)
        logRemoteEvent("TrapRemote", tostring(data))
    end)

    hookRemote("RE/ToolTrigger/Trigger", function(toolInst)
        local tName = (toolInst and toolInst.Name) or "Unknown"
        logRemoteEvent("ToolTrigger/Trigger", "Tool: " .. tName)
        if toolInst and string.find(string.lower(tName), "trap") then
            registerTrap(toolInst)
        end
    end)
end)

-- Initial sweep
scanMapForTraps()

-- ============================================================================
-- GUI INTERFACE (MODERN DRAGGABLE DASHBOARD)
-- ============================================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = GUI_NAME
screenGui.ResetOnSpawn = false
screenGui.Parent = getGuiParent()

local W, H = 460, 360
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.4, -H/2)
main.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(60, 75, 105)
stroke.Thickness = 1.2

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 34)
titleBar.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -70, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🪤 TRAP & HAZARD FIELD DETECTOR"
titleLbl.TextColor3 = Color3.fromRGB(225, 235, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 12
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = titleBar

-- Close button
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -30, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(160, 45, 55)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 11
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

-- Draggable logic
local dragging, dragStart, startPos = false, nil, nil
titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = main.Position
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

-- Summary Metric Bar
local metricBar = Instance.new("Frame")
metricBar.Size = UDim2.new(1, -20, 0, 36)
metricBar.Position = UDim2.new(0, 10, 0, 40)
metricBar.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
metricBar.Parent = main
Instance.new("UICorner", metricBar).CornerRadius = UDim.new(0, 6)

local statsLbl = Instance.new("TextLabel")
statsLbl.Size = UDim2.new(1, -16, 1, 0)
statsLbl.Position = UDim2.new(0, 8, 0, 0)
statsLbl.BackgroundTransparency = 1
statsLbl.Text = "Field Traps: 0 | Held Tools: 0 | Closest: N/A"
statsLbl.TextColor3 = Color3.fromRGB(170, 215, 255)
statsLbl.Font = Enum.Font.GothamBold
statsLbl.TextSize = 11
statsLbl.TextXAlignment = Enum.TextXAlignment.Left
statsLbl.Parent = metricBar

-- Control Action Buttons
local btnContainer = Instance.new("Frame")
btnContainer.Size = UDim2.new(1, -20, 0, 26)
btnContainer.Position = UDim2.new(0, 10, 0, 82)
btnContainer.BackgroundTransparency = 1
btnContainer.Parent = main

local function createBtn(text, posX, width, bgCol, onClick)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, width, 1, 0)
    b.Position = UDim2.new(0, posX, 0, 0)
    b.BackgroundColor3 = bgCol
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 10.5
    b.Parent = btnContainer
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    b.MouseButton1Click:Connect(onClick)
    return b
end

local espBtn = createBtn("ESP: ON", 0, 85, Color3.fromRGB(35, 130, 75), function()
    CONFIG.EspEnabled = not CONFIG.EspEnabled
    if CONFIG.EspEnabled then
        espBtn.Text = "ESP: ON"
        espBtn.BackgroundColor3 = Color3.fromRGB(35, 130, 75)
    else
        espBtn.Text = "ESP: OFF"
        espBtn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
        for inst in pairs(espInstances) do removeEsp(inst) end
    end
end)

createBtn("Rescan Map", 92, 95, Color3.fromRGB(45, 80, 140), function()
    scanMapForTraps()
end)

createBtn("Copy Traps JSON", 194, 120, Color3.fromRGB(120, 70, 160), function()
    local list = {}
    for inst, t in pairs(activeTraps) do
        local childNames = {}
        pcall(function()
            for _, ch in ipairs(inst:GetChildren()) do
                table.insert(childNames, ch.Name .. " (" .. ch.ClassName .. ")")
            end
        end)
        local attrs = {}
        pcall(function()
            for k, v in pairs(inst:GetAttributes()) do
                attrs[k] = typeof(v) == "Instance" and v:GetFullName() or tostring(v)
            end
        end)
        table.insert(list, {
            Name = t.Name,
            ClassName = t.ClassName,
            IsHeld = t.IsHeld,
            Holder = t.Holder,
            Owner = t.Owner,
            Position = t.Position and { X = t.Position.X, Y = t.Position.Y, Z = t.Position.Z } or nil,
            Path = t.Path,
            Attributes = attrs,
            Children = childNames
        })
    end
    local json = game:GetService("HttpService"):JSONEncode(list)
    if typeof(setclipboard) == "function" then
        setclipboard(json)
        statsLbl.Text = "Copied JSON to clipboard!"
    end
end)

-- Content Scroll Frame
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -20, 1, -120)
scroll.Position = UDim2.new(0, 10, 0, 114)
scroll.BackgroundColor3 = Color3.fromRGB(15, 18, 26)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 5
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = main
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 5)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scroll

local listPad = Instance.new("UIPadding")
listPad.PaddingTop = UDim.new(0, 6)
listPad.PaddingBottom = UDim.new(0, 6)
listPad.PaddingLeft = UDim.new(0, 6)
listPad.PaddingRight = UDim.new(0, 6)
listPad.Parent = scroll

-- Card rendering pool
local cardPool = {}

local function renderTrapCards()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local myPos = root and root.Position or Vector3.zero

    local fieldCount, heldCount = 0, 0
    local minDistance = math.huge
    local sorted = {}

    for inst, data in pairs(activeTraps) do
        if inst.Parent then
            local pos = getInstancePos(inst) or data.Position
            data.Position = pos
            if pos then
                data.Distance = (pos - myPos).Magnitude
            else
                data.Distance = math.huge
            end

            if data.IsHeld then
                heldCount = heldCount + 1
            else
                fieldCount = fieldCount + 1
                if data.Distance < minDistance then minDistance = data.Distance end
                updateOrCreateEsp(inst, data)
            end
            table.insert(sorted, data)
        else
            unregisterTrap(inst)
        end
    end

    table.sort(sorted, function(a, b)
        if a.IsHeld ~= b.IsHeld then return not a.IsHeld end -- Field traps first
        return a.Distance < b.Distance
    end)

    -- Update stats bar
    local closestStr = minDistance < math.huge and string.format("%.1f st", minDistance) or "N/A"
    statsLbl.Text = string.format("Field Traps: %d | Held Tools: %d | Closest Hazard: %s", fieldCount, heldCount, closestStr)
    if minDistance <= CONFIG.DangerRadius then
        statsLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
    else
        statsLbl.TextColor3 = Color3.fromRGB(170, 215, 255)
    end

    -- Draw cards
    for idx, data in ipairs(sorted) do
        local card = cardPool[idx]
        if not card then
            card = Instance.new("Frame")
            card.Size = UDim2.new(1, 0, 0, 42)
            card.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
            card.BorderSizePixel = 0
            card.Parent = scroll
            Instance.new("UICorner", card).CornerRadius = UDim.new(0, 5)

            local title = Instance.new("TextLabel")
            title.Name = "Title"
            title.Size = UDim2.new(1, -90, 0, 18)
            title.Position = UDim2.new(0, 8, 0, 3)
            title.BackgroundTransparency = 1
            title.Font = Enum.Font.GothamBold
            title.TextSize = 11
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.Parent = card

            local sub = Instance.new("TextLabel")
            sub.Name = "Sub"
            sub.Size = UDim2.new(1, -90, 0, 16)
            sub.Position = UDim2.new(0, 8, 0, 21)
            sub.BackgroundTransparency = 1
            sub.Font = Enum.Font.Gotham
            sub.TextSize = 9.5
            sub.TextColor3 = Color3.fromRGB(160, 175, 205)
            sub.TextXAlignment = Enum.TextXAlignment.Left
            sub.Parent = card

            local badge = Instance.new("TextLabel")
            badge.Name = "Badge"
            badge.Size = UDim2.new(0, 74, 0, 22)
            badge.Position = UDim2.new(1, -80, 0.5, -11)
            badge.Font = Enum.Font.GothamBold
            badge.TextSize = 10
            badge.Parent = card
            Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 4)

            cardPool[idx] = { Frame = card, Title = title, Sub = sub, Badge = badge }
        end

        local isDanger = not data.IsHeld and (data.Distance <= CONFIG.DangerRadius)
        card.Frame.BackgroundColor3 = isDanger and Color3.fromRGB(45, 18, 22) or (data.IsHeld and Color3.fromRGB(20, 24, 34) or Color3.fromRGB(24, 28, 40))
        card.Title.Text = string.format("%s%s", isDanger and "⚠️ " or (data.IsHeld and "✋ " or "🪤 "), data.Name)
        card.Title.TextColor3 = isDanger and Color3.fromRGB(255, 90, 90) or (data.IsHeld and Color3.fromRGB(200, 210, 235) or Color3.fromRGB(240, 245, 255))

        local posStr = data.Position and string.format("(%.0f, %.0f, %.0f)", data.Position.X, data.Position.Y, data.Position.Z) or "(unknown)"
        if data.IsHeld then
            card.Sub.Text = string.format("Held by %s", data.Holder or "Player")
        elseif data.Owner then
            card.Sub.Text = string.format("At %s [Owner: %s]", posStr, data.Owner)
        else
            card.Sub.Text = string.format("At %s", posStr)
        end

        if data.IsHeld then
            card.Badge.Text = "EQUIPPED"
            card.Badge.BackgroundColor3 = Color3.fromRGB(45, 55, 75)
            card.Badge.TextColor3 = Color3.fromRGB(180, 195, 220)
        else
            card.Badge.Text = string.format("%.1f st", data.Distance)
            card.Badge.BackgroundColor3 = isDanger and Color3.fromRGB(180, 40, 50) or Color3.fromRGB(35, 110, 65)
            card.Badge.TextColor3 = Color3.new(1, 1, 1)
        end

        card.Frame.Visible = true
    end

    -- Hide unused cards
    for i = #sorted + 1, #cardPool do
        cardPool[i].Frame.Visible = false
    end
end

-- ============================================================================
-- BACKGROUND RUNNER & CLEANUP
-- ============================================================================
local running = true

task.spawn(function()
    while running do
        task.wait(CONFIG.ScanInterval)
        pcall(scanMapForTraps)
        pcall(renderTrapCards)
    end
end)

closeBtn.MouseButton1Click:Connect(function()
    running = false
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    pcall(function() screenGui:Destroy() end)
    pcall(function() espFolder:Destroy() end)
    _G.TrapScanner_Cleanup = nil
end)

_G.TrapScanner_Cleanup = function()
    running = false
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    pcall(function() screenGui:Destroy() end)
    pcall(function() espFolder:Destroy() end)
end

print("[TrapFieldScanner] Loaded successfully! Active map observer and remote sniffer running.")
