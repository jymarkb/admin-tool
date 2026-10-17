--[[
    STEAL AN EGG - PET INVENTORY & PROFILE DEEP PROBE
    Mounts directly to PlayerGui (100% visible, matching event-test.lua)
    Inspects:
      1. RF/ProfileMirror/FetchProfile (all keys, recursive search for pet tables & 32-hex UUIDs)
      2. RF/PenRoster/AskLiveSnapshot & AskWearLimit
      3. RF/Haul/FetchWearBestStatus
      4. LocalPlayer attributes, folders, and satchel containers
      5. PlayerGui ScreenGuis and pet UI cards
      6. PlayerScripts modules and controllers
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

local pg = LocalPlayer:WaitForChild("PlayerGui")

-- Destroy previous instance if already open
local existing = pg:FindFirstChild("PetProbeGui")
if existing then pcall(function() existing:Destroy() end) end

-- ============================================================
-- UI SETUP (Guaranteed visible in PlayerGui)
-- ============================================================
local gui = Instance.new("ScreenGui")
gui.Name = "PetProbeGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 99999
gui.Parent = pg

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 520, 0, 480)
main.Position = UDim2.new(0.5, -260, 0.5, -240)
main.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(70, 120, 220)
stroke.Thickness = 1.5

-- Title Bar (Draggable)
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 38)
titleBar.BackgroundColor3 = Color3.fromRGB(26, 32, 48)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🐾 PET INVENTORY & PROFILE PROBE"
titleLbl.TextColor3 = Color3.fromRGB(220, 235, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 13
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -34, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 13
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

-- Dragging logic
local dragging, dragStart, startPos = false, nil, nil
titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
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

-- Console Output Area
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -16, 1, -95)
scroll.Position = UDim2.new(0, 8, 0, 46)
scroll.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = main
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

local txt = Instance.new("TextBox")
txt.Size = UDim2.new(1, -12, 1, 0)
txt.Position = UDim2.new(0, 6, 0, 6)
txt.BackgroundTransparency = 1
txt.Text = "Probe initialized. Click [RUN SCAN] to begin...\n"
txt.TextColor3 = Color3.fromRGB(210, 225, 250)
txt.Font = Enum.Font.Code
txt.TextSize = 11
txt.TextXAlignment = Enum.TextXAlignment.Left
txt.TextYAlignment = Enum.TextYAlignment.Top
txt.ClearTextOnFocus = false
txt.MultiLine = true
txt.TextEditable = false
txt.Parent = scroll

-- Bottom Buttons
local function makeBtn(name, text, xPos, width, col)
    local btn = Instance.new("TextButton")
    btn.Name = name
    btn.Size = UDim2.new(0, width, 0, 36)
    btn.Position = UDim2.new(0, xPos, 1, -44)
    btn.BackgroundColor3 = col
    btn.Text = text
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.Parent = main
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    return btn
end

local scanBtn = makeBtn("ScanBtn", "🔄 RUN SCAN", 8, 160, Color3.fromRGB(40, 150, 80))
local copyBtn = makeBtn("CopyBtn", "📋 COPY REPORT", 176, 160, Color3.fromRGB(50, 110, 190))
local saveBtn = makeBtn("SaveBtn", "💾 SAVE FILE", 344, 168, Color3.fromRGB(90, 80, 150))

local logLines = {}
local function log(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    table.insert(logLines, line)
    local full = table.concat(logLines, "\n")
    txt.Text = full
    print("[PetProbe] " .. line)
end

copyBtn.MouseButton1Click:Connect(function()
    local text = table.concat(logLines, "\n")
    if setclipboard then
        setclipboard(text)
        copyBtn.Text = "✓ COPIED!"
        task.delay(2, function() copyBtn.Text = "📋 COPY REPORT" end)
    else
        copyBtn.Text = "Select All in Box"
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    local text = table.concat(logLines, "\n")
    if writefile then
        pcall(function() writefile("pet-probe-result.txt", text) end)
        saveBtn.Text = "✓ SAVED!"
        task.delay(2, function() saveBtn.Text = "💾 SAVE FILE" end)
    else
        saveBtn.Text = "writefile not supported"
    end
end)

-- Safe Table Dumper
local function dumpValue(val, maxDepth, depth, visited)
    depth = depth or 0
    maxDepth = maxDepth or 2
    visited = visited or {}
    if val == nil then return "nil" end
    local t = typeof(val)
    if t == "string" then return '"' .. val .. '"' end
    if t == "number" or t == "boolean" then return tostring(val) end
    if t == "Instance" then
        local ok, n = pcall(function() return val:GetFullName() end)
        return "<Instance: " .. (ok and n or tostring(val)) .. ">"
    end
    if t == "table" then
        if depth >= maxDepth then return "{...}" end
        if visited[val] then return "<circular table>" end
        visited[val] = true
        local parts = {}
        local count = 0
        local keys = {}
        for k in pairs(val) do table.insert(keys, k) end
        table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            count = count + 1
            if count > 15 then
                table.insert(parts, string.rep("  ", depth + 1) .. string.format("... and %d more keys", #keys - 15))
                break
            end
            local v = val[k]
            local kStr = type(k) == "string" and ('"' .. k .. '"') or tostring(k)
            table.insert(parts, string.rep("  ", depth + 1) .. "[" .. kStr .. "] = " .. dumpValue(v, maxDepth, depth + 1, visited))
        end
        visited[val] = nil
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
    end
    return "<" .. t .. ">"
end

-- Networking Helper
local function findRemote(name)
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

-- ============================================================
-- MAIN PROBE PIPELINE
-- ============================================================
local function executeProbe()
    table.clear(logLines)
    log("==================================================")
    log("STEAL AN EGG - PET INVENTORY & PROFILE PROBE")
    log("Player: %s (UserId: %d)", LocalPlayer.Name, LocalPlayer.UserId)
    log("Time: %s", os.date("%Y-%m-%d %H:%M:%S"))
    log("==================================================")

    -- 1. PROBE RF/ProfileMirror/FetchProfile
    log("\n--- [1] PROBING RF/ProfileMirror/FetchProfile ---")
    local rfProfile = findRemote("RF/ProfileMirror/FetchProfile")
    if rfProfile then
        log("Found remote: %s", rfProfile:GetFullName())
        local ok, prof = pcall(function() return rfProfile:InvokeServer() end)
        log("InvokeServer() status: ok=%s, return type=%s", tostring(ok), typeof(prof))
        if ok and type(prof) == "table" then
            log("Top-level keys in Profile (%d keys):", 0)
            local keyCount = 0
            for k, v in pairs(prof) do
                keyCount = keyCount + 1
                local subCount = (type(v) == "table") and (" (table, items=" .. tostring(#v > 0 and #v or "dict") .. ")") or ""
                log("  [%s] = %s%s", tostring(k), typeof(v), subCount)
            end
            
            -- Search entire profile table for pet containers or 32-hex keys
            log("\nSearching Profile tree for Pet collections...")
            local function scanTree(tbl, path, d)
                if d > 3 or type(tbl) ~= "table" then return end
                for k, v in pairs(tbl) do
                    local curPath = path .. "." .. tostring(k)
                    if type(v) == "table" then
                        -- Check if this table has 32-hex keys (e.g. aca2ef52ac33412c93f9d08558308ad1)
                        local hexCount = 0
                        local sampleHex = nil
                        for subK in pairs(v) do
                            if type(subK) == "string" and #subK == 32 and subK:match("^%x+$") then
                                hexCount = hexCount + 1
                                sampleHex = sampleHex or subK
                            end
                        end
                        if hexCount > 0 then
                            log("  >>> FOUND 32-HEX PET CONTAINER: %s (Count: %d)", curPath, hexCount)
                            log("      Sample Key: %s", tostring(sampleHex))
                            log("      Sample Value: %s", dumpValue(v[sampleHex], 2))
                        end

                        local kLow = tostring(k):lower()
                        if string.find(kLow, "pet") or string.find(kLow, "satchel") or string.find(kLow, "inv") or string.find(kLow, "backpack") then
                            log("  -> Candidate Container: %s [%s]", curPath, typeof(v))
                            log("     Content: %s", dumpValue(v, 2))
                        else
                            scanTree(v, curPath, d + 1)
                        end
                    end
                end
            end
            scanTree(prof, "Profile", 1)
        else
            log("FetchProfile returned: %s", tostring(prof))
        end
    else
        log("RF/ProfileMirror/FetchProfile NOT FOUND")
    end

    -- 2. PROBE RF/PenRoster/AskLiveSnapshot & AskWearLimit
    log("\n--- [2] PROBING RF/PenRoster ---")
    local rfPen = findRemote("RF/PenRoster/AskLiveSnapshot")
    if rfPen then
        local ok, snap = pcall(function() return rfPen:InvokeServer() end)
        log("AskLiveSnapshot: ok=%s, return type=%s", tostring(ok), typeof(snap))
        if ok and type(snap) == "table" then
            log("PenRoster Live Snapshot: %s", dumpValue(snap, 2))
        end
    else
        log("RF/PenRoster/AskLiveSnapshot NOT FOUND")
    end

    local rfWearLimit = findRemote("RF/PenRoster/AskWearLimit")
    if rfWearLimit then
        local ok, limit = pcall(function() return rfWearLimit:InvokeServer() end)
        log("AskWearLimit: ok=%s, value=%s", tostring(ok), tostring(limit))
    end

    -- 3. PROBE RF/Haul/FetchWearBestStatus
    log("\n--- [3] PROBING RF/Haul ---")
    local rfHaul = findRemote("RF/Haul/FetchWearBestStatus")
    if rfHaul then
        local ok, res = pcall(function() return rfHaul:InvokeServer() end)
        log("FetchWearBestStatus: ok=%s, return=%s", tostring(ok), dumpValue(res, 2))
    end

    -- 4. LOCALPLAYER ATTRIBUTES & CHILDREN
    log("\n--- [4] LOCALPLAYER INTROSPECTION ---")
    local lpAttrs = LocalPlayer:GetAttributes()
    local attrCount = 0
    for k, v in pairs(lpAttrs) do
        attrCount = attrCount + 1
        log("  Attr: [%s] = %s", tostring(k), tostring(v))
    end
    if attrCount == 0 then log("  (No attributes on LocalPlayer)") end

    log("LocalPlayer Children:")
    for _, c in ipairs(LocalPlayer:GetChildren()) do
        log("  LocalPlayer.%s [%s] (#children=%d)", c.Name, c.ClassName, #c:GetChildren())
        if c:IsA("Folder") or c:IsA("Configuration") or string.find(c.Name:lower(), "pet") or string.find(c.Name:lower(), "satchel") then
            for idx, item in ipairs(c:GetChildren()) do
                if idx <= 5 then
                    log("    [%d] %s (%s) Attrs: %s", idx, item.Name, item.ClassName, dumpValue(item:GetAttributes(), 1))
                end
            end
            if #c:GetChildren() > 5 then
                log("    ... and %d more items", #c:GetChildren() - 5)
            end
        end
    end

    -- 5. CHARACTER PETS
    log("\n--- [5] CHARACTER INTROSPECTION ---")
    local char = LocalPlayer.Character
    if char then
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Model") or c:IsA("Folder") or c:IsA("Tool") or string.find(c.Name:lower(), "pet") then
                log("  Char child: %s [%s]", c.Name, c.ClassName)
                for _, sub in ipairs(c:GetChildren()) do
                    log("    Sub: %s [%s] Attrs=%s", sub.Name, sub.ClassName, dumpValue(sub:GetAttributes(), 1))
                end
            end
        end
    end

    -- 6. PLAYERGUI SCREEN GUIS & PET FRAMES
    log("\n--- [6] PLAYERGUI SCREEN GUIS & PET FRAMES ---")
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("ScreenGui") and g ~= gui and not string.find(g.Name, "EggGoToUI") then
            log("  ScreenGui: %s (Enabled=%s)", g.Name, tostring(g.Enabled))
            local foundPetFrames = 0
            for _, d in ipairs(g:GetDescendants()) do
                local dName = d.Name:lower()
                local isMatch = string.find(dName, "pet") or string.find(dName, "satchel") or string.find(dName, "backpack")
                if isMatch and (d:IsA("Frame") or d:IsA("ScrollingFrame") or d:IsA("ImageButton") or d:IsA("TextButton")) then
                    foundPetFrames = foundPetFrames + 1
                    if foundPetFrames <= 6 then
                        log("    -> %s [%s] Text='%s' Attrs=%s", d:GetFullName():sub(#g:GetFullName()+2), d.ClassName,
                            d:IsA("TextButton") and d.Text or "", dumpValue(d:GetAttributes(), 1))
                    end
                end
            end
            if foundPetFrames > 6 then
                log("    ... and %d more matching frames", foundPetFrames - 6)
            end
        end
    end

    -- 7. PLAYERSCRIPTS CONTROLLERS
    log("\n--- [7] PLAYERSCRIPTS MODULES ---")
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    if ps then
        for _, s in ipairs(ps:GetChildren()) do
            log("  PlayerScripts.%s [%s]", s.Name, s.ClassName)
            if s:IsA("Folder") then
                for _, sub in ipairs(s:GetChildren()) do
                    if string.find(sub.Name:lower(), "pet") or string.find(sub.Name:lower(), "satchel") or string.find(sub.Name:lower(), "fuse") or string.find(sub.Name:lower(), "profile") then
                        log("    -> %s [%s]", sub.Name, sub.ClassName)
                    end
                end
            end
        end
    end

    log("\n==================================================")
    log("PROBE COMPLETED! Click [COPY REPORT] to copy.")
    log("==================================================")
end

scanBtn.MouseButton1Click:Connect(executeProbe)

-- Run once automatically on launch
task.defer(executeProbe)
