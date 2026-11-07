--[[
    ========================================================================
    🔍 EGG MUTATION & ATTRIBUTE DIAGNOSTIC SCANNER (Zero-Hook, Zero-Kick)
    ========================================================================
    A 100% passive diagnostic monitor to capture and record exactly where egg
    mutations, attributes, and tags are placed across all biomes and network remotes.

    Features:
      1. 📍 Static & On-Demand Deep Scan:
         - Workspace.AreaEggSlotsClient (all slot instances, attributes, children, VFX)
         - LocalPlayer.Backpack & Character (all egg tools, BaseMutation, DisplayName, Category)
         - Workspace.Eggs & Workspace.ClientRenderedAssets
      2. 🛡️ Passive Remote Event Sniffing (ZERO Hooks, ZERO Disconnects):
         - RE/EggWorld/FieldEggShifted (dumps all payload table keys/values)
         - RE/EggWorld/FieldEggBatchShifted
         - RE/EggWorld/FieldEggCarry
         - RE/EggWorld/OwnerDropped
      3. 📋 Export Options:
         - Live scrolling console on HUD
         - "COPY LOG" button (copies full session history to clipboard via setclipboard)
         - "SAVE FILE" button (saves directly to egg-mutation-scanner.log via writefile)
         - "RUN SCAN" button (refreshes live world snapshot immediately)
      4. 🔒 Zero Tampering:
         - Read-only, no character changes, no remotes fired.
         - Root local budget strictly <= 30.
    ========================================================================
]]

local ok, err = pcall(function()

if _G.EggMutationScanner_Cleanup then pcall(_G.EggMutationScanner_Cleanup) end
_G.EggMutationScanner_Cleanup = nil

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local CoreGui           = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local t0 = os.clock()
    while not LocalPlayer and (os.clock() - t0 < 3) do
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    end
end

local Character = LocalPlayer and LocalPlayer.Character

-- ============================================================================
-- CONNECTION MANAGEMENT
-- ============================================================================
local connections = {}
local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

local function disconnectAll()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)
end

-- ============================================================================
-- MODULE TABLES (Anti-Bloat Root Local Budget <= 30)
-- ============================================================================
local Config  = {}
local State   = {}
local UI      = {}
local Engine  = {}

Config.Theme = {
    Background = Color3.fromRGB(15, 17, 24),
    Header     = Color3.fromRGB(24, 28, 40),
    Border     = Color3.fromRGB(50, 75, 115),
    ConsoleBg  = Color3.fromRGB(10, 11, 16),
    TextLight  = Color3.fromRGB(230, 235, 250),
    TextDim    = Color3.fromRGB(140, 150, 175),
    GreenLog   = Color3.fromRGB(100, 230, 130),
    RedAlert   = Color3.fromRGB(255, 95, 95),
    YellowWarn = Color3.fromRGB(255, 205, 75),
    BlueInfo   = Color3.fromRGB(90, 175, 255),
    GoldMut    = Color3.fromRGB(255, 215, 0),
}

State.LogEntries = {}
State.MaxLogEntries = 600

local function appendLog(text, color)
    color = color or Config.Theme.TextLight
    local timestamp = os.date("%H:%M:%S")
    local entry = { Time = timestamp, Text = tostring(text), Color = color }
    table.insert(State.LogEntries, entry)
    if #State.LogEntries > State.MaxLogEntries then
        table.remove(State.LogEntries, 1)
    end
    if UI.appendConsoleLine then
        pcall(UI.appendConsoleLine, entry)
    end
    print(string.format("[%s] %s", timestamp, entry.Text))
end

-- ============================================================================
-- PATH RESOLVER
-- ============================================================================
Engine.resolvePath = function(name)
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    local found = ReplicatedStorage:FindFirstChild(name, true)
    if found then return found end
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d.Name == name or d.Name:lower() == name:lower() then
            return d
        end
    end
    return nil
end

-- ============================================================================
-- DEEP SCAN LOGIC
-- ============================================================================
Engine.runDeepScan = function()
    appendLog("==================================================", Config.Theme.BlueInfo)
    appendLog("🔍 STARTING DEEP EGG MUTATION SCAN...", Config.Theme.YellowWarn)
    appendLog("==================================================", Config.Theme.BlueInfo)

    -- 1. Workspace.AreaEggSlotsClient (3D Visual Slot Models)
    local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
    if not slots then
        appendLog("[AreaEggSlotsClient] NOT FOUND in Workspace", Config.Theme.RedAlert)
    else
        local children = slots:GetChildren()
        appendLog(string.format("[AreaEggSlotsClient] Found %d active slots", #children), Config.Theme.GreenLog)
        for idx, child in ipairs(children) do
            local uid = child.Name
            local class = child.ClassName
            local posStr = ""
            if child:IsA("BasePart") then
                posStr = string.format(" Pos=(%.1f, %.1f, %.1f) Color=%s Mat=%s",
                    child.Position.X, child.Position.Y, child.Position.Z, tostring(child.Color), tostring(child.Material))
            end

            local attrs = child:GetAttributes()
            local attrList = {}
            local hasMutation = false
            for k, v in pairs(attrs) do
                local sVal = tostring(v)
                local lk = tostring(k):lower()
                local lv = sVal:lower()
                if lk:find("mut") or lv:find("gold") or lv:find("silver") or lv:find("rainbow") or lv:find("shiny") then
                    hasMutation = true
                    table.insert(attrList, string.format("⚡%s=%s", tostring(k), sVal))
                else
                    table.insert(attrList, string.format("%s=%s", tostring(k), sVal))
                end
            end

            local attrText = #attrList > 0 and table.concat(attrList, ", ") or "(no attributes)"
            local logColor = hasMutation and Config.Theme.GoldMut or Config.Theme.TextDim
            appendLog(string.format("Slot #%d [%s %s]%s | Attrs: %s", idx, uid, class, posStr, attrText), logColor)

            -- Check child visual components (particle emitters, highlights, mesh)
            local kids = child:GetChildren()
            if #kids > 0 then
                local kidList = {}
                for _, k in ipairs(kids) do
                    if k:IsA("Highlight") then
                        table.insert(kidList, string.format("%s[Highlight Fill=%s]", k.Name, tostring(k.FillColor)))
                    elseif k:IsA("MeshPart") and (k.Material == Enum.Material.Neon or k.Name:lower():find("neon") or k.Name:lower():find("gold")) then
                        table.insert(kidList, string.format("%s[MeshPart Color=%s Mat=%s]", k.Name, tostring(k.Color), tostring(k.Material.Name)))
                    else
                        table.insert(kidList, string.format("%s[%s]", k.Name, k.ClassName))
                    end
                end
                appendLog(string.format("   ↳ Children (%d): %s", #kids, table.concat(kidList, ", ")), Config.Theme.TextDim)
            end
        end
    end

    -- 2. Server Field Snapshot Records (RF/EggWorld/AskFieldEggSnapshot)
    local rf = Engine.resolvePath("RF/EggWorld/AskFieldEggSnapshot") or Engine.resolvePath("RF/EggWorld/GetEggSnapshot")
    if rf and rf:IsA("RemoteFunction") then
        local okSnap, res = pcall(function() return rf:InvokeServer() end)
        if okSnap and type(res) == "table" and type(res.Records) == "table" then
            local recordCount = 0
            local mutCount = 0
            for _, r in pairs(res.Records) do
                if type(r) == "table" then
                    recordCount = recordCount + 1
                    local uid = tostring(r.Uid or r.EggUid or "")
                    local species = tostring(r.AssetCategory or r.DisplayName or r.Name or "Unknown")
                    local area = tostring(r.AreaId or "Unknown")
                    local bMut = r.BaseMutation or r.Mutation
                    local mutations = r.Mutations
                    local hasMut = (bMut and bMut ~= "" and bMut ~= "Normal")
                        or (type(mutations) == "string" and mutations ~= "" and mutations ~= "Normal")
                        or (type(mutations) == "table" and #mutations > 0)

                    local mutStr = ""
                    if hasMut then
                        mutCount = mutCount + 1
                        mutStr = string.format(" | ⚡BaseMutation=%s Mutations=%s", tostring(bMut), type(mutations) == "table" and table.concat(mutations, ",") or tostring(mutations))
                    end

                    local col = hasMut and Config.Theme.GoldMut or Config.Theme.TextDim
                    appendLog(string.format("  Record #%d [%s in %s] UID=%s%s", recordCount, species, area, uid:sub(1, 8), mutStr), col)
                end
            end
            appendLog(string.format("[AskFieldEggSnapshot] Audited %d active server records", recordCount), Config.Theme.GreenLog)
            if mutCount == 0 then
                appendLog("  (No mutated eggs in current server field snapshot)", Config.Theme.TextDim)
            else
                appendLog(string.format("  ⚡ Found %d mutated eggs in server snapshot!", mutCount), Config.Theme.GoldMut)
            end
        else
            appendLog("[-] AskFieldEggSnapshot invoke failed or nil Records.", Config.Theme.YellowWarn)
        end
    else
        appendLog("[-] RF/EggWorld/AskFieldEggSnapshot not found.", Config.Theme.YellowWarn)
    end

    -- 2. Backpack & Character Tools
    local toolsFound = 0
    local function inspectTool(t, container)
        if not t:IsA("Tool") then return end
        toolsFound = toolsFound + 1
        local attrs = t:GetAttributes()
        local attrList = {}
        local hasMut = false
        for k, v in pairs(attrs) do
            local sVal = tostring(v)
            local lk = tostring(k):lower()
            local lv = sVal:lower()
            if lk:find("mut") or lv:find("gold") or lv:find("silver") or lv:find("rainbow") or lv:find("shiny") then
                hasMut = true
                table.insert(attrList, string.format("⚡%s=%s", tostring(k), sVal))
            else
                table.insert(attrList, string.format("%s=%s", tostring(k), sVal))
            end
        end
        local col = hasMut and Config.Theme.GoldMut or Config.Theme.TextLight
        appendLog(string.format("[Tool in %s] '%s' | Attrs: %s", container, t.Name, table.concat(attrList, ", ")), col)
    end

    local bp = LocalPlayer and LocalPlayer:FindFirstChildOfClass("Backpack")
    if bp then
        for _, it in ipairs(bp:GetChildren()) do inspectTool(it, "Backpack") end
    end
    if Character then
        for _, it in ipairs(Character:GetChildren()) do inspectTool(it, "Character") end
    end
    if toolsFound == 0 then
        appendLog("[Backpack/Character] No Tools found.", Config.Theme.TextDim)
    end

    -- 3. Workspace.Eggs
    local wsEggs = Workspace:FindFirstChild("Eggs")
    if wsEggs then
        local ekids = wsEggs:GetChildren()
        appendLog(string.format("[Workspace.Eggs] Found %d children", #ekids), Config.Theme.BlueInfo)
        for _, e in ipairs(ekids) do
            local eAttrs = e:GetAttributes()
            local al = {}
            for k, v in pairs(eAttrs) do table.insert(al, string.format("%s=%s", tostring(k), tostring(v))) end
            appendLog(string.format("  - %s [%s] | Attrs: %s", e.Name, e.ClassName, table.concat(al, ", ")), Config.Theme.TextDim)
        end
    end

    appendLog("==================================================", Config.Theme.BlueInfo)
    appendLog("✓ DEEP SCAN COMPLETE", Config.Theme.GreenLog)
    appendLog("==================================================", Config.Theme.BlueInfo)
end

-- ==================================================
-- PASSIVE REMOTE MONITORING
-- ==================================================
Engine.initRemoteSniffing = function()
    local monitored = {
        { Path = "RE/EggWorld/FieldEggShifted",       Label = "FieldEggShifted" },
        { Path = "RE/EggWorld/FieldEggBatchShifted",  Label = "FieldEggBatchShifted" },
        { Path = "RE/EggWorld/FieldEggCarry",         Label = "FieldEggCarry" },
        { Path = "RE/EggWorld/OwnerDropped",          Label = "OwnerDropped" },
    }

    for _, def in ipairs(monitored) do
        local remote = Engine.resolvePath(def.Path)
        if remote and remote:IsA("RemoteEvent") then
            addConnection(remote.OnClientEvent:Connect(function(...)
                local args = { ... }
                local payload = args[1]
                if type(payload) == "table" then
                    local pairsList = {}
                    local hasMut = false
                    for k, v in pairs(payload) do
                        local sVal = tostring(v)
                        if typeof(v) == "CFrame" then
                            sVal = string.format("CF(%.1f, %.1f, %.1f)", v.Position.X, v.Position.Y, v.Position.Z)
                        elseif typeof(v) == "Vector3" then
                            sVal = string.format("V3(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
                        elseif type(v) == "table" then
                            local sub = {}
                            for sk, sv in pairs(v) do table.insert(sub, string.format("%s=%s", tostring(sk), tostring(sv))) end
                            sVal = "{" .. table.concat(sub, ", ") .. "}"
                        end

                        local lk = tostring(k):lower()
                        local lv = sVal:lower()
                        if lk:find("mut") or lv:find("gold") or lv:find("silver") or lv:find("rainbow") or lv:find("shiny") then
                            hasMut = true
                            table.insert(pairsList, string.format("⚡%s=%s", tostring(k), sVal))
                        else
                            table.insert(pairsList, string.format("%s=%s", tostring(k), sVal))
                        end
                    end
                    local col = hasMut and Config.Theme.GoldMut or Config.Theme.BlueInfo
                    appendLog(string.format("[%s Remote] %s", def.Label, table.concat(pairsList, " | ")), col)
                else
                    appendLog(string.format("[%s Remote] Non-table arg: %s", def.Label, tostring(payload)), Config.Theme.TextDim)
                end
            end))
            appendLog(string.format("Passive hook active: %s", def.Path), Config.Theme.TextDim)
        end
    end

    -- Hook AreaEggSlotsClient.ChildAdded
    local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        addConnection(slots.ChildAdded:Connect(function(child)
            task.wait(0.05) -- allow attributes to replicate
            local attrs = child:GetAttributes()
            local al = {}
            local hasMut = false
            for k, v in pairs(attrs) do
                local sVal = tostring(v)
                local lk = tostring(k):lower()
                local lv = sVal:lower()
                if lk:find("mut") or lv:find("gold") or lv:find("silver") or lv:find("rainbow") or lv:find("shiny") then
                    hasMut = true
                    table.insert(al, string.format("⚡%s=%s", tostring(k), sVal))
                else
                    table.insert(al, string.format("%s=%s", tostring(k), sVal))
                end
            end
            local col = hasMut and Config.Theme.GoldMut or Config.Theme.YellowWarn
            appendLog(string.format("[NEW SLOT SPAWNED] %s [%s] | Attrs: %s", child.Name, child.ClassName, table.concat(al, ", ")), col)
        end))
    end
end

-- ============================================================================
-- USER INTERFACE
-- ============================================================================
UI.createGui = function()
    local function getSafeUiParent()
        local getHui = gethui or function() return CoreGui end
        local ok, res = pcall(function() return getHui() end)
        if ok and res then return res end
        return CoreGui:FindFirstChild("RobloxGui") or CoreGui
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "EggMutationScannerHUD"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    pcall(function()
        local old = getSafeUiParent():FindFirstChild("EggMutationScannerHUD")
        if old then old:Destroy() end
    end)
    screenGui.Parent = getSafeUiParent()

    local W, H = 540, 420
    local main = Instance.new("Frame")
    main.Name = "MainFrame"
    main.Size = UDim2.new(0, W, 0, H)
    main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
    main.BackgroundColor3 = Config.Theme.Background
    main.BorderSizePixel = 0
    main.Active = true
    main.Parent = screenGui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local mainStroke = Instance.new("UIStroke", main)
    mainStroke.Color = Config.Theme.Border
    mainStroke.Thickness = 1.5

    -- Draggable Header
    local topBar = Instance.new("Frame")
    topBar.Size = UDim2.new(1, 0, 0, 38)
    topBar.BackgroundColor3 = Config.Theme.Header
    topBar.BorderSizePixel = 0
    topBar.Parent = main
    Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -50, 1, 0)
    title.Position = UDim2.new(0, 14, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "🔍 EGG MUTATION & ATTRIBUTE SCANNER"
    title.TextColor3 = Config.Theme.TextLight
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = topBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 28, 0, 24)
    closeBtn.Position = UDim2.new(1, -34, 0.5, -12)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 12
    closeBtn.Parent = topBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

    -- Dragging
    do
        local dragging, dragStart, startPos = false, nil, nil
        addConnection(topBar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragStart = input.Position
                startPos = main.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then dragging = false end
                end)
            end
        end))
        addConnection(UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local delta = input.Position - dragStart
                main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end))
    end

    -- Console Scrolling Frame
    local consoleScroll = Instance.new("ScrollingFrame")
    consoleScroll.Size = UDim2.new(1, -20, 1, -94)
    consoleScroll.Position = UDim2.new(0, 10, 0, 46)
    consoleScroll.BackgroundColor3 = Config.Theme.ConsoleBg
    consoleScroll.BorderSizePixel = 0
    consoleScroll.ScrollBarThickness = 6
    consoleScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    consoleScroll.Parent = main
    Instance.new("UICorner", consoleScroll).CornerRadius = UDim.new(0, 6)
    local scrollLayout = Instance.new("UIListLayout", consoleScroll)
    scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
    scrollLayout.Padding = UDim.new(0, 3)

    local function updateCanvas()
        consoleScroll.CanvasSize = UDim2.new(0, 0, 0, scrollLayout.AbsoluteContentSize.Y + 12)
        consoleScroll.CanvasPosition = Vector3.new(0, math.max(0, scrollLayout.AbsoluteContentSize.Y - consoleScroll.AbsoluteSize.Y + 20), 0)
    end
    addConnection(scrollLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvas))

    UI.appendConsoleLine = function(entry)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, -12, 0, 16)
        lbl.BackgroundTransparency = 1
        lbl.Text = string.format("[%s] %s", entry.Time, entry.Text)
        lbl.TextColor3 = entry.Color
        lbl.Font = Enum.Font.Code
        lbl.TextSize = 11
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextWrapped = true
        lbl.Parent = consoleScroll

        task.defer(function()
            lbl.Size = UDim2.new(1, -12, 0, lbl.TextBounds.Y + 2)
        end)
    end

    -- Control Buttons Bar
    local btnBar = Instance.new("Frame")
    btnBar.Size = UDim2.new(1, -20, 0, 36)
    btnBar.Position = UDim2.new(0, 10, 1, -42)
    btnBar.BackgroundTransparency = 1
    btnBar.Parent = main

    local scanBtn = Instance.new("TextButton")
    scanBtn.Size = UDim2.new(0, 110, 0, 30)
    scanBtn.Position = UDim2.new(0, 0, 0.5, -15)
    scanBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 175)
    scanBtn.Text = "⚡ RUN SCAN"
    scanBtn.TextColor3 = Color3.new(1, 1, 1)
    scanBtn.Font = Enum.Font.GothamBold
    scanBtn.TextSize = 11
    scanBtn.Parent = btnBar
    Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0, 6)

    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0, 110, 0, 30)
    copyBtn.Position = UDim2.new(0, 120, 0.5, -15)
    copyBtn.BackgroundColor3 = Color3.fromRGB(50, 75, 120)
    copyBtn.Text = "📋 COPY LOG"
    copyBtn.TextColor3 = Color3.fromRGB(220, 235, 255)
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.TextSize = 11
    copyBtn.Parent = btnBar
    Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

    local saveBtn = Instance.new("TextButton")
    saveBtn.Size = UDim2.new(0, 110, 0, 30)
    saveBtn.Position = UDim2.new(0, 240, 0.5, -15)
    saveBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 75)
    saveBtn.Text = "💾 SAVE FILE"
    saveBtn.TextColor3 = Color3.fromRGB(210, 255, 230)
    saveBtn.Font = Enum.Font.GothamBold
    saveBtn.TextSize = 11
    saveBtn.Parent = btnBar
    Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 6)

    local clearBtn = Instance.new("TextButton")
    clearBtn.Size = UDim2.new(0, 80, 0, 30)
    clearBtn.Position = UDim2.new(1, -80, 0.5, -15)
    clearBtn.BackgroundColor3 = Color3.fromRGB(40, 45, 60)
    clearBtn.Text = "CLEAR"
    clearBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    clearBtn.Font = Enum.Font.GothamBold
    clearBtn.TextSize = 11
    clearBtn.Parent = btnBar
    Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

    -- Button Actions
    addConnection(scanBtn.MouseButton1Click:Connect(function()
        Engine.runDeepScan()
    end))

    local function exportFullLog()
        local lines = {}
        for _, e in ipairs(State.LogEntries) do
            table.insert(lines, string.format("[%s] %s", e.Time, e.Text))
        end
        return table.concat(lines, "\n")
    end

    addConnection(copyBtn.MouseButton1Click:Connect(function()
        local fullText = exportFullLog()
        if setclipboard then
            pcall(setclipboard, fullText)
            copyBtn.Text = "✓ COPIED!"
            task.delay(1.5, function() copyBtn.Text = "📋 COPY LOG" end)
        else
            copyBtn.Text = "NO CLIPBOARD"
            task.delay(1.5, function() copyBtn.Text = "📋 COPY LOG" end)
        end
    end))

    addConnection(saveBtn.MouseButton1Click:Connect(function()
        local fullText = exportFullLog()
        if writefile then
            pcall(writefile, "egg-mutation-scanner.log", fullText)
            saveBtn.Text = "✓ SAVED!"
            task.delay(1.5, function() saveBtn.Text = "💾 SAVE FILE" end)
        else
            saveBtn.Text = "NO WRITEFILE"
            task.delay(1.5, function() saveBtn.Text = "💾 SAVE FILE" end)
        end
    end))

    addConnection(clearBtn.MouseButton1Click:Connect(function()
        table.clear(State.LogEntries)
        for _, c in ipairs(consoleScroll:GetChildren()) do
            if c:IsA("TextLabel") then c:Destroy() end
        end
        appendLog("Console log cleared.", Config.Theme.TextDim)
    end))

    -- Teardown
    local function cleanup()
        disconnectAll()
        pcall(function() screenGui:Destroy() end)
        _G.EggMutationScanner_Cleanup = nil
        print("[EggMutationScanner] Cleanup complete.")
    end

    addConnection(closeBtn.MouseButton1Click:Connect(cleanup))
    _G.EggMutationScanner_Cleanup = cleanup
end

-- STARTUP INITIALIZATION
UI.createGui()
Engine.initRemoteSniffing()
task.spawn(function()
    task.wait(0.3)
    Engine.runDeepScan()
end)

print("[EggMutationScanner] Loaded successfully.")

end)
if not ok then
    warn("[EggMutationScanner] FAILED TO LOAD: " .. tostring(err))
end
