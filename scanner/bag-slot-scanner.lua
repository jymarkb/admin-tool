--[[
    BAG & INVENTORY SLOT SCANNER
    Purpose:
      1. Discover where eggs enter/reside in the client backpack, hotbar, and inventory GUI.
      2. Pinpoint the specific 10 slots/locations (e.g., Hotbar 1-10 vs ScrollingFrame slots 11-20).
      3. Live-monitor slot changes when picking up or receiving an egg so you can immediately
         see which slots update.
      4. Dump all detected slots, hotbars, and backpack tools with copy-to-clipboard support.
]]

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- Clean up any previous scanner instance
if _G.BagSlotScanner_Cleanup then
    pcall(_G.BagSlotScanner_Cleanup)
end

local function getGuiParent()
    if typeof(gethui) == "function" then
        local ok, parent = pcall(gethui)
        if ok and parent then return parent end
    end
    return PlayerGui or CoreGui
end

local state = {
    alive = true,
    liveMonitoring = true,
    connections = {},
    monitoredSlots = {},
}

local logLines = {}
local MAX_LOG_LINES = 250

local function appendLog(text)
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] %s", timestamp, tostring(text))
    table.insert(logLines, line)
    if #logLines > MAX_LOG_LINES then
        table.remove(logLines, 1)
    end
    print("[BagSlotScanner] " .. tostring(text))
end

-- ============================================================
-- INSPECTION HELPERS
-- ============================================================

local function safeValStr(v)
    local t = typeof(v)
    if t == "Instance" then
        return string.format("<%s [%s]>", v.Name, v.ClassName)
    elseif t == "string" then
        return string.format("%q", v)
    else
        return tostring(v)
    end
end

local function formatAttributes(inst)
    local attrs = inst:GetAttributes()
    local parts = {}
    for k, v in pairs(attrs) do
        table.insert(parts, string.format("%s=%s", k, safeValStr(v)))
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function getSlotLabelTexts(inst)
    local texts = {}
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("TextLabel") and d.Text and d.Text ~= "" then
            table.insert(texts, string.format("%s=%q", d.Name, d.Text))
        end
    end
    return #texts > 0 and table.concat(texts, ", ") or ""
end

-- Search for inventory containers in PlayerGui (strictly bag / inventory GUI)
local function locateInventoryContainers()
    local containers = {
        scrollingFrame = nil,
        categoryFrame = nil,
        backpackGui = nil,
    }

    local bpGui = PlayerGui:FindFirstChild("BackpackGui")
    if not bpGui then
        for _, g in ipairs(PlayerGui:GetChildren()) do
            if g:IsA("ScreenGui") and g.Name:lower():find("backpack") then
                bpGui = g
                break
            end
        end
    end
    containers.backpackGui = bpGui

    if bpGui then
        -- Look for ScrollingFrame (Bag Inventory)
        for _, desc in ipairs(bpGui:GetDescendants()) do
            if desc:IsA("ScrollingFrame") and (desc.Name == "ScrollingFrame" or desc.Name:lower():find("inv")) then
                containers.scrollingFrame = desc
                break
            end
        end

        -- Look for CategoryFrame
        for _, desc in ipairs(bpGui:GetDescendants()) do
            if desc.Name == "CategoryFrame" and desc:IsA("Frame") then
                containers.categoryFrame = desc
                break
            end
        end
    end

    return containers
end

-- ============================================================
-- FULL SNAPSHOT DUMP
-- ============================================================

local function runFullDump()
    appendLog("--- BEGIN FULL BAG & SLOT SNAPSHOT ---")

    -- 1. LocalPlayer.Backpack tools
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        local tools = bp:GetChildren()
        appendLog(string.format("[Backpack] Total Tools: %d", #tools))
        local eggTools = {}
        for idx, tool in ipairs(tools) do
            local dName = tool:GetAttribute("DisplayName") or tool.Name
            local category = tool:GetAttribute("Category") or ""
            local uid = tool:GetAttribute("UID") or ""
            local isEgg = dName:lower():find("egg") or category:lower():find("egg")
            if isEgg then
                table.insert(eggTools, string.format("#%d: %s (UID: %s)", idx, dName, tostring(uid)))
            end
            if idx <= 10 then
                appendLog(string.format("  Slot #%d: [%s] %s | Attrs: %s", idx, tool.ClassName, tool.Name, formatAttributes(tool)))
            end
        end
        if #eggTools > 0 then
            appendLog(string.format("  -> Found %d Egg Tool(s) in Backpack: %s", #eggTools, table.concat(eggTools, "; ")))
        else
            appendLog("  -> No direct Tool eggs in Backpack (eggs are likely stored in UI slots or satchel profile).")
        end
    else
        appendLog("[Backpack] LocalPlayer.Backpack not found!")
    end

    -- 2. Containers in PlayerGui
    local containers = locateInventoryContainers()
    if containers.backpackGui then
        appendLog(string.format("[GUI] Found BackpackGui: %s", containers.backpackGui:GetFullName()))
    else
        appendLog("[GUI] BackpackGui not found in PlayerGui.")
    end

    -- 2. ScrollingFrame (Bag Inventory Slots)
    if containers.scrollingFrame then
        local sf = containers.scrollingFrame
        local allSlots = {}
        for _, c in ipairs(sf:GetChildren()) do
            if not c:IsA("UIComponent") and not c:IsA("UILayout") and c.Name ~= "Template" then
                table.insert(allSlots, c)
            end
        end

        -- Sort by numeric name if available
        table.sort(allSlots, function(a, b)
            local na, nb = tonumber(a.Name), tonumber(b.Name)
            if na and nb then return na < nb end
            return a.Name < b.Name
        end)

        appendLog(string.format("[Bag Inventory] Found %d total slots in %s", #allSlots, sf:GetFullName()))

        -- Collect all slots holding Eggs
        local eggSlots = {}
        for _, s in ipairs(allSlots) do
            if s:GetAttribute("HasEggOverlay") == true or getSlotLabelTexts(s):lower():find("egg") then
                table.insert(eggSlots, s)
            end
        end

        appendLog(string.format("[Bag Eggs] %d slots currently hold Eggs in the bag.", #eggSlots))

        -- Dump first 10 Egg Slots specifically
        appendLog("  === First 10 Egg Slots in Bag ===")
        for i = 1, math.min(10, #eggSlots) do
            local slot = eggSlots[i]
            local txt = getSlotLabelTexts(slot)
            appendLog(string.format("  Egg Slot [%d] (Name: '%s'): Texts=[%s] | Attrs=[%s]", i, slot.Name, txt, formatAttributes(slot)))
        end

        -- Dump last 5 Egg Slots
        if #eggSlots > 10 then
            appendLog(string.format("  === Last 5 Egg Slots (Total: %d) ===", #eggSlots))
            for i = math.max(11, #eggSlots - 4), #eggSlots do
                local slot = eggSlots[i]
                local txt = getSlotLabelTexts(slot)
                appendLog(string.format("  Egg Slot [%d] (Name: '%s'): Texts=[%s] | Attrs=[%s]", i, slot.Name, txt, formatAttributes(slot)))
            end
        end
    else
        appendLog("[Bag Inventory] ScrollingFrame container not found.")
    end

    -- 5. Category counters
    if containers.categoryFrame then
        for _, cat in ipairs(containers.categoryFrame:GetChildren()) do
            if cat:IsA("Frame") or cat:IsA("GuiObject") then
                local txt = getSlotLabelTexts(cat)
                if txt ~= "" then
                    appendLog(string.format("[Category] %s -> %s", cat.Name, txt))
                end
            end
        end
    end

    appendLog("--- END FULL SNAPSHOT ---")
end

-- ============================================================
-- LIVE MONITORING
-- ============================================================

local function hookSlot(slot, containerName)
    local slotKey = slot:GetDebugId() or (containerName .. "_" .. slot.Name)
    if state.monitoredSlots[slotKey] then return end
    state.monitoredSlots[slotKey] = true

    -- Hook AttributeChanged
    local connAttr = slot.AttributeChanged:Connect(function(attrName)
        if not state.alive or not state.liveMonitoring then return end
        local val = slot:GetAttribute(attrName)
        appendLog(string.format("[LIVE CHANGE] %s Slot '%s' AttributeChanged: %s = %s | Texts=[%s]",
            containerName, slot.Name, attrName, safeValStr(val), getSlotLabelTexts(slot)))
    end)
    table.insert(state.connections, connAttr)

    -- Hook TextLabel changes inside slot
    for _, d in ipairs(slot:GetDescendants()) do
        if d:IsA("TextLabel") then
            local connTxt = d:GetPropertyChangedSignal("Text"):Connect(function()
                if not state.alive or not state.liveMonitoring then return end
                appendLog(string.format("[LIVE CHANGE] %s Slot '%s' TextChanged (%s): %q | Attrs=[%s]",
                    containerName, slot.Name, d.Name, d.Text, formatAttributes(slot)))
            end)
            table.insert(state.connections, connTxt)
        end
    end

    local connDesc = slot.DescendantAdded:Connect(function(d)
        if not state.alive or not state.liveMonitoring then return end
        if d:IsA("TextLabel") then
            local connTxt = d:GetPropertyChangedSignal("Text"):Connect(function()
                if not state.alive or not state.liveMonitoring then return end
                appendLog(string.format("[LIVE CHANGE] %s Slot '%s' TextChanged (%s): %q",
                    containerName, slot.Name, d.Name, d.Text))
            end)
            table.insert(state.connections, connTxt)
        end
    end)
    table.insert(state.connections, connDesc)
end

local function startLiveMonitor()
    -- Disconnect old connections
    for _, c in ipairs(state.connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(state.connections)
    table.clear(state.monitoredSlots)

    appendLog("[LiveMonitor] Initializing real-time listeners...")

    -- 1. Hook LocalPlayer.Backpack ChildAdded / ChildRemoved
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        local cAdd = bp.ChildAdded:Connect(function(child)
            if not state.alive or not state.liveMonitoring then return end
            appendLog(string.format("[LIVE BACKPACK] Tool Added: [%s] '%s' | Attrs=[%s]",
                child.ClassName, child.Name, formatAttributes(child)))
        end)
        local cRem = bp.ChildRemoved:Connect(function(child)
            if not state.alive or not state.liveMonitoring then return end
            appendLog(string.format("[LIVE BACKPACK] Tool Removed: [%s] '%s'", child.ClassName, child.Name))
        end)
        table.insert(state.connections, cAdd)
        table.insert(state.connections, cRem)
    end

    -- 2. Hook Character ChildAdded / ChildRemoved (tools equipped)
    local function hookChar(char)
        if not char then return end
        local cAdd = char.ChildAdded:Connect(function(child)
            if not state.alive or not state.liveMonitoring then return end
            if child:IsA("Tool") then
                appendLog(string.format("[LIVE CHAR] Tool Equipped: '%s' | Attrs=[%s]",
                    child.Name, formatAttributes(child)))
            end
        end)
        local cRem = char.ChildRemoved:Connect(function(child)
            if not state.alive or not state.liveMonitoring then return end
            if child:IsA("Tool") then
                appendLog(string.format("[LIVE CHAR] Tool Unequipped: '%s'", child.Name))
            end
        end)
        table.insert(state.connections, cAdd)
        table.insert(state.connections, cRem)
    end
    if LocalPlayer.Character then hookChar(LocalPlayer.Character) end
    local charConn = LocalPlayer.CharacterAdded:Connect(hookChar)
    table.insert(state.connections, charConn)

    -- 3. Hook Bag ScrollingFrame & Category Counters
    local containers = locateInventoryContainers()

    -- Hook Category Counters (Quantity changes)
    if containers.categoryFrame then
        for _, cat in ipairs(containers.categoryFrame:GetChildren()) do
            for _, d in ipairs(cat:GetDescendants()) do
                if d:IsA("TextLabel") then
                    local conn = d:GetPropertyChangedSignal("Text"):Connect(function()
                        if not state.alive or not state.liveMonitoring then return end
                        appendLog(string.format("[LIVE BAG] Category '%s' %s = %q", cat.Name, d.Name, d.Text))
                    end)
                    table.insert(state.connections, conn)
                end
            end
        end
    end

    -- Hook ScrollingFrame (Bag Slots)
    if containers.scrollingFrame then
        local sf = containers.scrollingFrame
        for _, s in ipairs(sf:GetChildren()) do
            if not s:IsA("UIComponent") and not s:IsA("UILayout") and s.Name ~= "Template" then
                hookSlot(s, "Bag")
            end
        end
        local cAdd = sf.ChildAdded:Connect(function(s)
            if not s:IsA("UIComponent") and not s:IsA("UILayout") and s.Name ~= "Template" then
                appendLog(string.format("[LIVE BAG] Slot Added to Bag: '%s'", s.Name))
                hookSlot(s, "Bag")
            end
        end)
        table.insert(state.connections, cAdd)
    end

    appendLog("[LiveMonitor] Active! Pick up an egg now and watch the log below to see which slot updates.")
end

-- ============================================================
-- USER INTERFACE
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "BagSlotScannerUI"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = getGuiParent()

local W, H = 520, 440
local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(W, H)
frame.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
frame.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(65, 145, 235)
stroke.Thickness = 1.5

-- Title Bar
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = Color3.fromRGB(25, 34, 52)
topBar.BorderSizePixel = 0
topBar.Parent = frame
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -70, 1, 0)
titleLbl.Position = UDim2.fromOffset(12, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🎒 BAG SLOT SCANNER (EGG LOCATION PROBE)"
titleLbl.TextColor3 = Color3.fromRGB(235, 245, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 12
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(26, 26)
closeBtn.Position = UDim2.new(1, -32, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 45)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- Dragging
do
    local dragging, dragStart, startPos = false, nil, nil
    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- Action Buttons
local btnContainer = Instance.new("Frame")
btnContainer.Size = UDim2.new(1, -20, 0, 32)
btnContainer.Position = UDim2.fromOffset(10, 42)
btnContainer.BackgroundTransparency = 1
btnContainer.Parent = frame

local function createButton(text, xOffset, width, color, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(width, 30)
    btn.Position = UDim2.fromOffset(xOffset, 0)
    btn.BackgroundColor3 = color
    btn.Text = text
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.Parent = btnContainer
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    btn.MouseButton1Click:Connect(callback)
    return btn
end

-- Log Box (ScrollingFrame + TextLabel)
local logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -20, 1, -120)
logScroll.Position = UDim2.fromOffset(10, 80)
logScroll.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 6
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.Parent = frame
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 6)

local logText = Instance.new("TextLabel")
logText.Size = UDim2.new(1, -12, 0, 0)
logText.Position = UDim2.fromOffset(6, 6)
logText.BackgroundTransparency = 1
logText.TextColor3 = Color3.fromRGB(205, 240, 215)
logText.Font = Enum.Font.Code
logText.TextSize = 11
logText.TextXAlignment = Enum.TextXAlignment.Left
logText.TextYAlignment = Enum.TextYAlignment.Top
logText.TextWrapped = true
logText.Parent = logScroll

local function updateLogUI()
    local fullText = table.concat(logLines, "\n")
    logText.Text = fullText
    -- Estimate canvas height
    local linesCount = #logLines
    local estHeight = math.max(300, linesCount * 16 + 20)
    logText.Size = UDim2.new(1, -12, 0, estHeight)
    logScroll.CanvasSize = UDim2.new(0, 0, 0, estHeight + 10)
    logScroll.CanvasPosition = Vector2.new(0, estHeight)
end

-- Refresh UI periodically when new logs arrive
local logDirty = false
local oldAppendLog = appendLog
appendLog = function(t)
    oldAppendLog(t)
    logDirty = true
end

RunService.Heartbeat:Connect(function()
    if logDirty and state.alive then
        logDirty = false
        updateLogUI()
    end
end)

-- Buttons Setup
createButton("🔍 DUMP BAG SLOTS", 0, 150, Color3.fromRGB(35, 125, 65), function()
    task.spawn(runFullDump)
end)

local liveToggleBtn
liveToggleBtn = createButton("● LIVE MONITOR: ON", 158, 150, Color3.fromRGB(50, 100, 190), function()
    state.liveMonitoring = not state.liveMonitoring
    if state.liveMonitoring then
        liveToggleBtn.Text = "● LIVE MONITOR: ON"
        liveToggleBtn.BackgroundColor3 = Color3.fromRGB(50, 100, 190)
        appendLog("[LiveMonitor] Resumed live monitoring.")
    else
        liveToggleBtn.Text = "○ LIVE MONITOR: OFF"
        liveToggleBtn.BackgroundColor3 = Color3.fromRGB(90, 90, 110)
        appendLog("[LiveMonitor] Paused live monitoring.")
    end
end)

createButton("📋 COPY LOG", 316, 90, Color3.fromRGB(110, 80, 160), function()
    local full = table.concat(logLines, "\n")
    local copied = false
    if typeof(setclipboard) == "function" then
        copied = pcall(setclipboard, full)
    elseif typeof(toclipboard) == "function" then
        copied = pcall(toclipboard, full)
    end
    if copied then
        appendLog("[UI] Log copied to clipboard successfully!")
    else
        appendLog("[UI] Clipboard function unavailable in your executor.")
    end
end)

createButton("🗑 CLEAR", 414, 86, Color3.fromRGB(80, 80, 90), function()
    table.clear(logLines)
    appendLog("Log cleared.")
    updateLogUI()
end)

-- Instruction hint at bottom
local hintLbl = Instance.new("TextLabel")
hintLbl.Size = UDim2.new(1, -20, 0, 24)
hintLbl.Position = UDim2.new(0, 10, 1, -30)
hintLbl.BackgroundTransparency = 1
hintLbl.Text = "Bag-only scanner: live changes will show which slot in the bag (e.g. slots 206-215) updates."
hintLbl.TextColor3 = Color3.fromRGB(160, 180, 205)
hintLbl.Font = Enum.Font.Gotham
hintLbl.TextSize = 10
hintLbl.TextXAlignment = Enum.TextXAlignment.Left
hintLbl.Parent = frame

-- Cleanup function
local function cleanup()
    state.alive = false
    state.liveMonitoring = false
    for _, c in ipairs(state.connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(state.connections)
    table.clear(state.monitoredSlots)
    _G.BagSlotScanner_Cleanup = nil
    if screenGui and screenGui.Parent then
        pcall(function() screenGui:Destroy() end)
    end
end
_G.BagSlotScanner_Cleanup = cleanup
closeBtn.MouseButton1Click:Connect(cleanup)

-- Initial run
appendLog("Bag Slot Scanner initialized.")
task.spawn(function()
    task.wait(0.1)
    runFullDump()
    startLiveMonitor()
end)
