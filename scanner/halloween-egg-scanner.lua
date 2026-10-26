--[[
    ===========================================================================================
    HALLOWEEN EGG SPAWN & LIFECYCLE DIAGNOSTIC SCANNER
    ===========================================================================================
    Target Environment: Halloween Dimension & Halloween Event World
    Purpose:
      1. Live Spawn Tracking:
         - Detects when, where, and how Halloween eggs spawn in:
           • Workspace.HalloweenDimension.WorldEggs
           • Workspace.HalloweenDimension.EggSpawns
           • Workspace.HalloweenDimension.EggNests
           • Workspace.HalloweenEggHolders
           • Workspace["Halloween Eggs PT2"]
         - Logs exact CFrame/Position, model structure, Hitbox, glowing lights, welds, and attributes.
         - Correlates each spawned egg to the nearest EggSpawn part or EggNest (distance, offset).

      2. ProximityPrompt & Interaction Spy:
         - Detects CarryHalloweenEgg, HalloweenEggPrompt, and EggShopPrompt creation/triggers.
         - Inspects HoldDuration, MaxActivationDistance, ObjectText, and prompt parents.

      3. Network & Remote Spy:
         - Captures outgoing calls:
           • RF/HalloweenDimension/AskCarryEgg
           • RF/HalloweenDimension/AskDropEgg
           • RF/HalloweenDimension/AskBuyEgg
           • RF/HalloweenDimension/AskTutorialSeen
           • RF/HalloweenManor/Talk
           • RE/HalloweenDimension/MonsterHit
         - Listens to incoming OnClientEvent notifications.

      4. Interactive Probe Suite:
         - [PROBE NOW]: Full diagnostic snapshot of all live eggs, spawn parts, nests, and player attributes.
         - [SCAN SPAWNS]: Checks every spawn part to determine if it is currently OCCUPIED or EMPTY.
         - [COPY LOG]: Copies formatted text to clipboard (setclipboard) for easy sharing and analysis.
         - [CLEAR]: Clears the console log.
         - [PAUSE / RESUME]: Toggles live event capturing.

      Safe & Non-intrusive:
         - Does not alter game arguments or block server calls.
         - All formatters and observers are wrapped in pcalls.
    ===========================================================================================
]]

local Workspace          = game:GetService("Workspace")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local CollectionService  = game:GetService("CollectionService")
local CoreGui            = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local t0 = os.clock()
    while not LocalPlayer and (os.clock() - t0 < 3) do
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    end
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

-- ============================================================================
-- GUI HOSTING
-- ============================================================================
local function getSafeGuiParent()
    local okHui, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if okHui and h then return h end
    local pg = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    return CoreGui
end

local guiParent = getSafeGuiParent()
local oldScanner = guiParent:FindFirstChild("HalloweenEggScannerUI")
if oldScanner then pcall(function() oldScanner:Destroy() end) end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "HalloweenEggScannerUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = guiParent

-- ============================================================================
-- STATE
-- ============================================================================
local isMonitoring = true
local logHistory = {}
local MAX_LOG_LINES = 2000
local connections = {}
local trackedEggs = {} -- [instance] = { SpawnTime = os.clock(), Pos = Vector3, NearestSpawn = name }

local function addConn(conn)
    if conn then table.insert(connections, conn) end
    return conn
end

-- Forward declaration of UI updater
local appendLog
local updateCounters

-- ============================================================================
-- DATA FORMATTER
-- ============================================================================
local function formatVal(v, depth, visited)
    depth = depth or 0
    visited = visited or {}
    if depth > 4 then return "<depth limit>" end
    if v == nil then return "nil" end

    local t = typeof(v)
    if t == "string" then
        return '"' .. v .. '"'
    elseif t == "number" or t == "boolean" or t == "EnumItem" then
        return tostring(v)
    elseif t == "Vector3" then
        return string.format("V3(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
    elseif t == "CFrame" then
        local p = v.Position
        return string.format("CF(pos=%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
    elseif t == "Color3" then
        return string.format("RGB(%d, %d, %d)", math.floor(v.R * 255), math.floor(v.G * 255), math.floor(v.B * 255))
    elseif t == "Instance" then
        local ok, n = pcall(function() return v:GetFullName() end)
        return ok and ("<" .. v.ClassName .. ": " .. n .. ">") or ("<" .. v.ClassName .. ": " .. tostring(v) .. ">")
    elseif t == "table" then
        if visited[v] then return "<circular table>" end
        visited[v] = true
        local parts = {}
        local isArr = true
        local count = 0
        for k in pairs(v) do
            count = count + 1
            if typeof(k) ~= "number" then isArr = false end
        end
        if count == 0 then return "{}" end
        if count > 25 then return string.format("{ ... (%d entries) ... }", count) end

        if isArr then
            for i = 1, #v do
                table.insert(parts, formatVal(v[i], depth + 1, visited))
            end
            return "[ " .. table.concat(parts, ", ") .. " ]"
        else
            for k, val in pairs(v) do
                table.insert(parts, tostring(k) .. " = " .. formatVal(val, depth + 1, visited))
            end
            return "{ " .. table.concat(parts, ", ") .. " }"
        end
    end
    return "<" .. t .. ": " .. tostring(v) .. ">"
end

-- ============================================================================
-- UI CONSTRUCTION
-- ============================================================================
local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 640, 0, 490)
mainFrame.Position = UDim2.new(0.5, -320, 0.5, -245)
mainFrame.BackgroundColor3 = Color3.fromRGB(20, 16, 26)
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.Parent = screenGui
Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", mainFrame)
mainStroke.Color = Color3.fromRGB(200, 95, 25)
mainStroke.Thickness = 1.6

-- Title Bar & Dragging
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(32, 22, 38)
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

do
    local fix = Instance.new("Frame")
    fix.Size = UDim2.new(1, 0, 0, 10)
    fix.Position = UDim2.new(0, 0, 1, -10)
    fix.BackgroundColor3 = Color3.fromRGB(32, 22, 38)
    fix.BorderSizePixel = 0
    fix.Parent = titleBar

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -70, 1, 0)
    titleLbl.Position = UDim2.new(0, 12, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "🎃 HALLOWEEN EGG SPAWN SCANNER & SPY"
    titleLbl.TextColor3 = Color3.fromRGB(255, 185, 75)
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 13
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 26, 0, 24)
    closeBtn.Position = UDim2.new(1, -34, 0.5, -12)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 45)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 13
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

    closeBtn.MouseButton1Click:Connect(function()
        for _, conn in ipairs(connections) do
            pcall(function() conn:Disconnect() end)
        end
        if screenGui and screenGui.Parent then
            screenGui:Destroy()
        end
    end)

    -- Dragging
    local dragging, dragStart, startPos = false, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = mainFrame.Position
        end
    end)
    titleBar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- Stats Header Bar
local statsBar = Instance.new("Frame")
statsBar.Size = UDim2.new(1, -16, 0, 24)
statsBar.Position = UDim2.new(0, 8, 0, 42)
statsBar.BackgroundColor3 = Color3.fromRGB(28, 22, 34)
statsBar.BorderSizePixel = 0
statsBar.Parent = mainFrame
Instance.new("UICorner", statsBar).CornerRadius = UDim.new(0, 6)
local statsStroke = Instance.new("UIStroke", statsBar)
statsStroke.Color = Color3.fromRGB(75, 50, 90)
statsStroke.Thickness = 1

local statsLabel = Instance.new("TextLabel")
statsLabel.Size = UDim2.new(1, -12, 1, 0)
statsLabel.Position = UDim2.new(0, 8, 0, 0)
statsLabel.BackgroundTransparency = 1
statsLabel.Text = "Status: ACTIVE | WorldEggs: 0 | Spawns: 0 | Nests: 0 | Dimension: Unknown"
statsLabel.TextColor3 = Color3.fromRGB(220, 210, 240)
statsLabel.Font = Enum.Font.GothamMedium
statsLabel.TextSize = 11
statsLabel.TextXAlignment = Enum.TextXAlignment.Left
statsLabel.Parent = statsBar

-- Console Log Display
local consoleScroll = Instance.new("ScrollingFrame")
consoleScroll.Size = UDim2.new(1, -16, 1, -120)
consoleScroll.Position = UDim2.new(0, 8, 0, 72)
consoleScroll.BackgroundColor3 = Color3.fromRGB(12, 10, 18)
consoleScroll.BorderSizePixel = 0
consoleScroll.ScrollBarThickness = 5
consoleScroll.ScrollBarImageColor3 = Color3.fromRGB(200, 95, 25)
consoleScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
consoleScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
consoleScroll.Parent = mainFrame
Instance.new("UICorner", consoleScroll).CornerRadius = UDim.new(0, 6)
local conStroke = Instance.new("UIStroke", consoleScroll)
conStroke.Color = Color3.fromRGB(50, 40, 65)
conStroke.Thickness = 1

local consoleBox = Instance.new("TextBox")
consoleBox.Size = UDim2.new(1, -10, 1, 0)
consoleBox.Position = UDim2.new(0, 6, 0, 4)
consoleBox.BackgroundTransparency = 1
consoleBox.TextColor3 = Color3.fromRGB(225, 230, 245)
consoleBox.Font = Enum.Font.Code
consoleBox.TextSize = 11
consoleBox.ClearTextOnFocus = false
consoleBox.MultiLine = true
consoleBox.TextEditable = false
consoleBox.TextXAlignment = Enum.TextXAlignment.Left
consoleBox.TextYAlignment = Enum.TextYAlignment.Top
consoleBox.Text = "-- [🎃 Halloween Egg Scanner initialized] --\nWaiting for egg spawn events or press [PROBE NOW]...\n"
consoleBox.AutomaticSize = Enum.AutomaticSize.Y
consoleBox.Parent = consoleScroll

-- Control Buttons Row
local buttonRow = Instance.new("Frame")
buttonRow.Size = UDim2.new(1, -16, 0, 36)
buttonRow.Position = UDim2.new(0, 8, 1, -42)
buttonRow.BackgroundTransparency = 1
buttonRow.Parent = mainFrame

local function makeBtn(text, xOffset, width, bgCol)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, width, 1, 0)
    btn.Position = UDim2.new(0, xOffset, 0, 0)
    btn.BackgroundColor3 = bgCol
    btn.Text = text
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11.5
    btn.Parent = buttonRow
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    return btn
end

local probeBtn  = makeBtn("PROBE NOW", 0, 105, Color3.fromRGB(200, 95, 25))
local spawnsBtn = makeBtn("SCAN SPAWNS", 112, 115, Color3.fromRGB(130, 50, 180))
local pauseBtn  = makeBtn("PAUSE", 234, 85, Color3.fromRGB(55, 65, 95))
local clearBtn  = makeBtn("CLEAR", 326, 80, Color3.fromRGB(80, 45, 55))
local copyBtn   = makeBtn("COPY LOG", 413, 105, Color3.fromRGB(45, 115, 80))

-- ============================================================================
-- LOGGING UTILITY
-- ============================================================================
local updatePending = false
local function scheduleLogRefresh()
    if updatePending then return end
    updatePending = true
    task.defer(function()
        updatePending = false
        pcall(function()
            consoleBox.Text = table.concat(logHistory, "\n")
            consoleScroll.CanvasPosition = Vector2.new(0, 999999)
        end)
    end)
end

appendLog = function(tag, msg, detail)
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] [%s] %s", timestamp, tag, msg)
    if detail and detail ~= "" then
        line = line .. "\n" .. detail
    end
    table.insert(logHistory, line)
    if #logHistory > MAX_LOG_LINES then
        table.remove(logHistory, 1)
    end
    scheduleLogRefresh()
end

-- ============================================================================
-- SPATIAL ANALYSIS: NEAREST SPAWN & NEST FINDER
-- ============================================================================
local function getEggPosition(eggInst)
    if not eggInst then return nil end
    if eggInst:IsA("Model") then
        local prim = eggInst.PrimaryPart or eggInst:FindFirstChild("Hitbox") or eggInst:FindFirstChildWhichIsA("BasePart")
        if prim then return prim.Position end
        local cf = eggInst:GetPivot()
        return cf.Position
    elseif eggInst:IsA("BasePart") then
        return eggInst.Position
    end
    return nil
end

local function findNearestSpawnPart(pos)
    if not pos then return nil, 9999 end
    local nearestPart = nil
    local minDist = 9999

    pcall(function()
        local hw = Workspace:FindFirstChild("HalloweenDimension")
        local spFolder = hw and hw:FindFirstChild("EggSpawns")
        if spFolder then
            for _, child in ipairs(spFolder:GetChildren()) do
                if child:IsA("BasePart") then
                    local d = (child.Position - pos).Magnitude
                    if d < minDist then
                        minDist = d
                        nearestPart = child
                    end
                end
            end
        end
    end)

    return nearestPart, minDist
end

local function findNearestEggNest(pos)
    if not pos then return nil, 9999 end
    local nearestNest = nil
    local minDist = 9999

    pcall(function()
        local hw = Workspace:FindFirstChild("HalloweenDimension")
        local nestsFolder = hw and hw:FindFirstChild("EggNests")
        if nestsFolder then
            for _, child in ipairs(nestsFolder:GetChildren()) do
                local spot = child:FindFirstChild("EggSpotBottom") or child:FindFirstChild("EggFitBounds") or child.PrimaryPart
                if spot and spot:IsA("BasePart") then
                    local d = (spot.Position - pos).Magnitude
                    if d < minDist then
                        minDist = d
                        nearestNest = child
                    end
                end
            end
        end
    end)

    return nearestNest, minDist
end

-- Detailed Egg Inspection
local function inspectEggDetails(eggInst)
    local lines = {}
    local pos = getEggPosition(eggInst)
    if pos then
        table.insert(lines, string.format("  • Position: V3(%.2f, %.2f, %.2f)", pos.X, pos.Y, pos.Z))
        local nearSpawn, spawnDist = findNearestSpawnPart(pos)
        if nearSpawn then
            table.insert(lines, string.format("  • Nearest EggSpawn: %s (dist: %.2f studs)", nearSpawn:GetFullName(), spawnDist))
        end
        local nearNest, nestDist = findNearestEggNest(pos)
        if nearNest then
            table.insert(lines, string.format("  • Nearest EggNest: %s (dist: %.2f studs)", nearNest.Name, nestDist))
        end
    end

    -- Hitbox & Lights & Hitbox Attributes
    pcall(function()
        local hitbox = eggInst:FindFirstChild("Hitbox")
        if hitbox and hitbox:IsA("BasePart") then
            table.insert(lines, string.format("  • Hitbox: Size=%s CanCollide=%s Mass=%.1f", tostring(hitbox.Size), tostring(hitbox.CanCollide), hitbox:GetMass()))
            local glow = hitbox:FindFirstChildOfClass("PointLight")
            if glow then
                table.insert(lines, string.format("  • Glow Light: Name='%s' Color=%s Brightness=%.1f Range=%.1f", glow.Name, formatVal(glow.Color), glow.Brightness, glow.Range))
            end
            local hbAttrs = hitbox:GetAttributes()
            if next(hbAttrs) then
                table.insert(lines, "  • Hitbox Attributes: " .. formatVal(hbAttrs))
            end
        end
    end)

    -- Model Attributes
    pcall(function()
        local attrs = eggInst:GetAttributes()
        if next(attrs) then
            table.insert(lines, "  • Model Attributes: " .. formatVal(attrs))
        else
            table.insert(lines, "  • Model Attributes: { none }")
        end
    end)

    -- All Children Parts, Meshes & Values
    pcall(function()
        local chList = {}
        for _, c in ipairs(eggInst:GetChildren()) do
            local extra = ""
            if c:IsA("MeshPart") then
                extra = string.format(" (MeshId=%s, Tex=%s)", tostring(c.MeshId), tostring(c.TextureID))
            elseif c:IsA("SpecialMesh") then
                extra = string.format(" (MeshId=%s, Tex=%s)", tostring(c.MeshId), tostring(c.TextureId))
            elseif c:IsA("ValueBase") then
                extra = string.format(" (Value=%s)", tostring(c.Value))
            end
            local cAttrs = c:GetAttributes()
            if next(cAttrs) then
                extra = extra .. " [Attrs: " .. formatVal(cAttrs) .. "]"
            end
            table.insert(chList, string.format("%s [%s]%s", c.Name, c.ClassName, extra))
        end
        table.insert(lines, "  • Children (" .. #chList .. "): " .. table.concat(chList, ", "))
    end)

    -- ProximityPrompts
    pcall(function()
        for _, desc in ipairs(eggInst:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then
                local prAttrs = desc:GetAttributes()
                local attrStr = next(prAttrs) and (" Attrs=" .. formatVal(prAttrs)) or ""
                table.insert(lines, string.format("  • Attached Prompt: %s | Action='%s' Object='%s' Hold=%.2fs Dist=%.1f%s",
                    desc.Name, desc.ActionText, desc.ObjectText, desc.HoldDuration, desc.MaxActivationDistance, attrStr))
            end
        end
    end)

    -- Tags
    pcall(function()
        local tags = CollectionService:GetTags(eggInst)
        if #tags > 0 then
            table.insert(lines, "  • Collection Tags: [ " .. table.concat(tags, ", ") .. " ]")
        end
    end)

    -- Template comparison with ReplicatedStorage.Assets.Models.Eggs
    pcall(function()
        local eggModels = ReplicatedStorage:FindFirstChild("Assets")
            and ReplicatedStorage.Assets:FindFirstChild("Models")
            and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
        if eggModels then
            local liveChildrenNames = {}
            for _, ch in ipairs(eggInst:GetChildren()) do
                liveChildrenNames[ch.Name] = true
            end

            local bestMatch = nil
            local bestScore = 0
            for _, tModel in ipairs(eggModels:GetChildren()) do
                if tModel:IsA("Model") and tModel.Name:lower():find("halloween") then
                    local score = 0
                    for _, tChild in ipairs(tModel:GetChildren()) do
                        if liveChildrenNames[tChild.Name] then
                            score = score + 1
                        end
                    end
                    if score > bestScore then
                        bestScore = score
                        bestMatch = tModel.Name
                    end
                end
            end
            if bestMatch and bestScore > 0 then
                table.insert(lines, string.format("  • Template Match: '%s' (matched %d child parts)", bestMatch, bestScore))
            end
        end
    end)

    return table.concat(lines, "\n")
end

-- ============================================================================
-- REAL-TIME MONITORS
-- ============================================================================
updateCounters = function()
    pcall(function()
        local inHw = LocalPlayer and LocalPlayer:GetAttribute("InHalloweenDimension")
        local delivered = LocalPlayer and LocalPlayer:GetAttribute("HalloweenDelivered")
        local hw = Workspace:FindFirstChild("HalloweenDimension")
        local eggsFolder = hw and hw:FindFirstChild("WorldEggs")
        local spawnsFolder = hw and hw:FindFirstChild("EggSpawns")
        local nestsFolder = hw and hw:FindFirstChild("EggNests")

        local eggCount = eggsFolder and #eggsFolder:GetChildren() or 0
        local spawnCount = spawnsFolder and #spawnsFolder:GetChildren() or 0
        local nestCount = nestsFolder and #nestsFolder:GetChildren() or 0

        statsLabel.Text = string.format("Status: %s | WorldEggs: %d | Spawns: %d | Nests: %d | InHW: %s | Deliv: %s",
            isMonitoring and "ACTIVE" or "PAUSED",
            eggCount, spawnCount, nestCount,
            tostring(inHw), tostring(delivered or 0)
        )
    end)
end

local function hookEggFolder(folder, folderLabel)
    if not folder then return end

    addConn(folder.ChildAdded:Connect(function(child)
        if not isMonitoring then return end
        local t = os.clock()
        local pos = getEggPosition(child)
        trackedEggs[child] = { SpawnTime = t, Pos = pos }

        local details = inspectEggDetails(child)
        appendLog("SPAWN", string.format("Egg spawned in %s -> '%s' (Class: %s)", folderLabel, child.Name, child.ClassName), details)
        updateCounters()
    end))

    addConn(folder.ChildRemoved:Connect(function(child)
        if not isMonitoring then return end
        local rec = trackedEggs[child]
        local lifespanStr = ""
        if rec and rec.SpawnTime then
            local dur = os.clock() - rec.SpawnTime
            lifespanStr = string.format(" (Lived: %.2fs)", dur)
        end
        trackedEggs[child] = nil
        appendLog("DESPAWN", string.format("Egg removed from %s -> '%s'%s", folderLabel, child.Name, lifespanStr))
        updateCounters()
    end))
end

-- Setup all folder hooks
local function setupAllMonitors()
    pcall(function()
        local hw = Workspace:FindFirstChild("HalloweenDimension")
        if hw then
            hookEggFolder(hw:FindFirstChild("WorldEggs"), "HalloweenDimension.WorldEggs")
            hookEggFolder(hw:FindFirstChild("EggSpawns"), "HalloweenDimension.EggSpawns")
            hookEggFolder(hw:FindFirstChild("EggNests"), "HalloweenDimension.EggNests")
        end

        local pt2 = Workspace:FindFirstChild("Halloween Eggs PT2")
        if pt2 then hookEggFolder(pt2, "Halloween Eggs PT2") end

        local holders = Workspace:FindFirstChild("HalloweenEggHolders")
        if holders then hookEggFolder(holders, "HalloweenEggHolders") end
    end)

    -- Watch for HalloweenDimension being spawned/streamed into Workspace
    addConn(Workspace.ChildAdded:Connect(function(child)
        if child.Name == "HalloweenDimension" then
            appendLog("WORLD", "HalloweenDimension folder added to Workspace!")
            task.wait(0.2)
            setupAllMonitors()
            updateCounters()
        elseif child.Name == "Halloween Eggs PT2" or child.Name == "HalloweenEggHolders" then
            appendLog("WORLD", child.Name .. " added to Workspace!")
            hookEggFolder(child, child.Name)
            updateCounters()
        end
    end))

    -- Watch for ProximityPrompts created anywhere in Workspace
    addConn(Workspace.DescendantAdded:Connect(function(desc)
        if not isMonitoring then return end
        if desc:IsA("ProximityPrompt") then
            local n = desc.Name
            if n:find("Halloween") or n:find("Egg") or desc.ActionText:find("Egg") or desc.ActionText:find("Carry") then
                appendLog("PROMPT", string.format("New Prompt: '%s' on %s (Action: '%s', Object: '%s', Hold: %.2fs, MaxDist: %.1f)",
                    n, desc.Parent and desc.Parent:GetFullName() or "Unknown", desc.ActionText, desc.ObjectText, desc.HoldDuration, desc.MaxActivationDistance))
            end
        end
    end))

    -- Player Attribute Changes
    if LocalPlayer then
        addConn(LocalPlayer.AttributeChanged:Connect(function(attrName)
            if not isMonitoring then return end
            if attrName:find("Halloween") or attrName:find("Dimension") or attrName:find("Egg") then
                local val = LocalPlayer:GetAttribute(attrName)
                appendLog("ATTR", string.format("LocalPlayer AttributeChanged: '%s' = %s", attrName, formatVal(val)))
                updateCounters()
            end
        end))
    end
end

-- ============================================================================
-- REMOTE SPY (Hook __namecall for outgoing Halloween Remotes)
-- ============================================================================
local function setupRemoteSpy()
    local okHook, err = pcall(function()
        if typeof(hookmetamethod) ~= "function" then return end
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if isMonitoring and (method == "InvokeServer" or method == "FireServer") then
                local okName, rName = pcall(function() return self:GetFullName() end)
                if okName and rName and (rName:find("Halloween") or rName:find("EggWorld") or rName:find("AskFieldEgg")) then
                    local args = table.pack(...)
                    local formattedArgs = {}
                    for i = 1, args.n do
                        table.insert(formattedArgs, string.format("  [%d] = %s", i, formatVal(args[i])))
                    end
                    local argText = #formattedArgs > 0 and ("\n" .. table.concat(formattedArgs, "\n")) or " (no args)"
                    appendLog("REMOTE_OUT", string.format("%s: %s", method, rName), argText)
                end
            end
            return oldNamecall(self, ...)
        end)
    end)
    if okHook then
        appendLog("SPY", "Outgoing Remote Spy successfully hooked via hookmetamethod(__namecall)")
    else
        appendLog("SPY", "hookmetamethod not supported by executor (incoming RemoteEvents still monitored)")
    end

    -- Hook incoming OnClientEvent for Networking Halloween Remotes
    pcall(function()
        local net = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Networking")
        if net then
            for _, rem in ipairs(net:GetChildren()) do
                if rem:IsA("RemoteEvent") and (rem.Name:find("Halloween") or rem.Name:find("Egg")) then
                    addConn(rem.OnClientEvent:Connect(function(...)
                        if not isMonitoring then return end
                        local args = table.pack(...)
                        local formatted = {}
                        for i = 1, args.n do
                            table.insert(formatted, string.format("  [%d] = %s", i, formatVal(args[i])))
                        end
                        appendLog("REMOTE_IN", "OnClientEvent: " .. rem.Name, table.concat(formatted, "\n"))
                    end))
                end
            end
        end
    end)
end

-- ============================================================================
-- PROBE ACTIONS
-- ============================================================================

-- Comprehensive Probe of Halloween World
local function runComprehensiveProbe()
    appendLog("PROBE", "================= FULL HALLOWEEN PROBE SNAPSHOT =================")

    -- 1. Player & World Status
    local inHw = LocalPlayer and LocalPlayer:GetAttribute("InHalloweenDimension")
    local deliv = LocalPlayer and LocalPlayer:GetAttribute("HalloweenDelivered")
    local trans = LocalPlayer and LocalPlayer:GetAttribute("HalloweenTransition")
    appendLog("PROBE", string.format("LocalPlayer Status | InHalloweenDimension=%s | HalloweenDelivered=%s | HalloweenTransition=%s",
        tostring(inHw), tostring(deliv), tostring(trans)))

    -- 2. HalloweenDimension Hierarchy
    local hw = Workspace:FindFirstChild("HalloweenDimension")
    if not hw then
        appendLog("PROBE", "Workspace.HalloweenDimension: NOT FOUND in Workspace! (Are you in the normal world?)")
    else
        appendLog("PROBE", string.format("Workspace.HalloweenDimension: FOUND (%d top-level folders/models)", #hw:GetChildren()))
        for _, c in ipairs(hw:GetChildren()) do
            appendLog("PROBE", string.format("  Folder/Model: %s (%s, %d children)", c.Name, c.ClassName, #c:GetChildren()))
        end
    end

    -- 3. WorldEggs Snapshot
    local eggsFolder = hw and hw:FindFirstChild("WorldEggs")
    if eggsFolder then
        local children = eggsFolder:GetChildren()
                appendLog("PROBE", string.format("WorldEggs: %d active egg models currently present", #children))
        for idx, egg in ipairs(children) do
            local pos = getEggPosition(egg)
            local nearSpawn, sDist = findNearestSpawnPart(pos)
            local spawnInfo = nearSpawn and string.format("near %s (%.1f st)", nearSpawn.Name, sDist) or "no spawn near"
            appendLog("PROBE", string.format("  [%02d] Egg Model: '%s' (%s)\n%s", idx, egg.Name, spawnInfo, inspectEggDetails(egg)))
        end
    end

    -- 4. EggSpawns & EggNests Summary
    local spawnsFolder = hw and hw:FindFirstChild("EggSpawns")
    if spawnsFolder then
        appendLog("PROBE", string.format("EggSpawns: %d spawn points registered", #spawnsFolder:GetChildren()))
    end
    local nestsFolder = hw and hw:FindFirstChild("EggNests")
    if nestsFolder then
        appendLog("PROBE", string.format("EggNests: %d nests registered", #nestsFolder:GetChildren()))
    end

        -- 5. Halloween Remotes
    pcall(function()
        local net = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Networking")
        if net then
            local hwRemotes = {}
            for _, r in ipairs(net:GetChildren()) do
                if r.Name:find("Halloween") then
                    table.insert(hwRemotes, string.format("%s (%s)", r.Name, r.ClassName))
                end
            end
            appendLog("PROBE", string.format("Networking Halloween Remotes (%d): \n  • %s", #hwRemotes, table.concat(hwRemotes, "\n  • ")))
        end
    end)

    -- 6. Workspace.SmartPromptPart Prompts
    pcall(function()
        local sp = Workspace:FindFirstChild("SmartPromptPart")
        if sp then
            local prompts = {}
            for _, ch in ipairs(sp:GetChildren()) do
                if ch:IsA("ProximityPrompt") then
                    local pAttrs = ch:GetAttributes()
                    local aStr = next(pAttrs) and (" Attrs=" .. formatVal(pAttrs)) or ""
                    table.insert(prompts, string.format("  • %s | Action='%s' Object='%s' Hold=%.2fs MaxDist=%.1f%s",
                        ch.Name, ch.ActionText, ch.ObjectText, ch.HoldDuration, ch.MaxActivationDistance, aStr))
                end
            end
            appendLog("PROBE", string.format("Workspace.SmartPromptPart: %d ProximityPrompts found:\n%s",
                #prompts, #prompts > 0 and table.concat(prompts, "\n") or "  (none)"))
        end
    end)

    -- 7. ReplicatedStorage Halloween Data Modules
    pcall(function()
        local dataFolder = ReplicatedStorage:FindFirstChild("Data")
        if dataFolder then
            for _, mod in ipairs(dataFolder:GetChildren()) do
                if mod:IsA("ModuleScript") and mod.Name:lower():find("halloween") then
                    local okReq, res = pcall(require, mod)
                    if okReq then
                        appendLog("PROBE", string.format("ModuleScript '%s' (Required successfully):\n%s",
                            mod.Name, formatVal(res)))
                    else
                        appendLog("PROBE", string.format("ModuleScript '%s' (Failed to require: %s)",
                            mod.Name, tostring(res)))
                    end
                end
            end
        end
    end)

    -- 8. Egg Asset Templates in ReplicatedStorage
    pcall(function()
        local eggModels = ReplicatedStorage:FindFirstChild("Assets")
            and ReplicatedStorage.Assets:FindFirstChild("Models")
            and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
        if eggModels then
            local templates = {}
            for _, tModel in ipairs(eggModels:GetChildren()) do
                if tModel:IsA("Model") and tModel.Name:lower():find("halloween") then
                    local chNames = {}
                    for _, tc in ipairs(tModel:GetChildren()) do
                        table.insert(chNames, tc.Name)
                    end
                    table.insert(templates, string.format("  • '%s' (Children: %s)", tModel.Name, table.concat(chNames, ", ")))
                end
            end
            appendLog("PROBE", string.format("ReplicatedStorage Halloween Egg Templates (%d):\n%s",
                #templates, table.concat(templates, "\n")))
        end
    end)

    appendLog("PROBE", "================= END PROBE SNAPSHOT =================")
    updateCounters()
end

-- Scan all spawn points and check if occupied
local function scanSpawnPoints()
    appendLog("SCAN", "================= EGG SPAWNS OCCUPANCY SCAN =================")
    local hw = Workspace:FindFirstChild("HalloweenDimension")
    local spFolder = hw and hw:FindFirstChild("EggSpawns")
    local eggsFolder = hw and hw:FindFirstChild("WorldEggs")

    if not spFolder then
        appendLog("SCAN", "EggSpawns folder not found under Workspace.HalloweenDimension")
        return
    end

    local spawns = spFolder:GetChildren()
    local eggs = eggsFolder and eggsFolder:GetChildren() or {}
    appendLog("SCAN", string.format("Scanning %d EggSpawn parts against %d active WorldEggs...", #spawns, #eggs))

    local occupiedCount = 0
    for idx, sp in ipairs(spawns) do
        if sp:IsA("BasePart") then
            local spPos = sp.Position
            local sittingEgg = nil
            local minD = 9999
            for _, egg in ipairs(eggs) do
                local ePos = getEggPosition(egg)
                if ePos then
                    local d = (ePos - spPos).Magnitude
                    if d < minD then
                        minD = d
                        if d <= 5.5 then
                            sittingEgg = egg
                        end
                    end
                end
            end

            if sittingEgg then
                occupiedCount = occupiedCount + 1
                appendLog("SCAN", string.format("  [%02d] SPAWN POINT: OCCUPIED by '%s' (dist: %.2f studs, pos: %s)",
                    idx, sittingEgg.Name, minD, formatVal(spPos)))
            else
                appendLog("SCAN", string.format("  [%02d] SPAWN POINT: EMPTY (nearest egg is %.1f studs away, pos: %s)",
                    idx, minD, formatVal(spPos)))
            end
        end
    end

    appendLog("SCAN", string.format("Summary: %d / %d spawn points are OCCUPIED. %d are EMPTY.",
        occupiedCount, #spawns, #spawns - occupiedCount))
    appendLog("SCAN", "==============================================================")
end

-- ============================================================================
-- BUTTON WIRING
-- ============================================================================
probeBtn.MouseButton1Click:Connect(function()
    runComprehensiveProbe()
end)

spawnsBtn.MouseButton1Click:Connect(function()
    scanSpawnPoints()
end)

pauseBtn.MouseButton1Click:Connect(function()
    isMonitoring = not isMonitoring
    pauseBtn.Text = isMonitoring and "PAUSE" or "RESUME"
    pauseBtn.BackgroundColor3 = isMonitoring and Color3.fromRGB(55, 65, 95) or Color3.fromRGB(150, 95, 35)
    appendLog("CONTROL", isMonitoring and "Live monitoring RESUMED." or "Live monitoring PAUSED.")
    updateCounters()
end)

clearBtn.MouseButton1Click:Connect(function()
    table.clear(logHistory)
    consoleBox.Text = "-- Console Cleared --\n"
end)

copyBtn.MouseButton1Click:Connect(function()
    local fullText = table.concat(logHistory, "\n")
    local ok = false
    if typeof(setclipboard) == "function" then
        ok = pcall(function() setclipboard(fullText) end)
    end
    if not ok and typeof(toclipboard) == "function" then
        ok = pcall(function() toclipboard(fullText) end)
    end

    if ok then
        copyBtn.Text = "COPIED!"
        copyBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 90)
        task.delay(1.5, function()
            if copyBtn and copyBtn.Parent then
                copyBtn.Text = "COPY LOG"
                copyBtn.BackgroundColor3 = Color3.fromRGB(45, 115, 80)
            end
        end)
    else
        copyBtn.Text = "NO CLIPBOARD"
        copyBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
        task.delay(1.5, function()
            if copyBtn and copyBtn.Parent then
                copyBtn.Text = "COPY LOG"
                copyBtn.BackgroundColor3 = Color3.fromRGB(45, 115, 80)
            end
        end)
    end
end)

-- ============================================================================
-- INITIAL STARTUP
-- ============================================================================
setupAllMonitors()
setupRemoteSpy()
updateCounters()

appendLog("INIT", "Halloween Egg Spawn Scanner loaded successfully.")
appendLog("INIT", "Tracking: WorldEggs, EggSpawns, EggNests, ProximityPrompts & Halloween Remotes.")

-- Automatically perform initial probe after brief load delay
task.defer(function()
    task.wait(0.5)
    runComprehensiveProbe()
end)

print("[HalloweenEggScanner] Loaded and active.")
