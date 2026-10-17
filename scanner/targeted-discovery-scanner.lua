--[[
    STEAL A EGG - TARGETED DISCOVERY SCANNER
    Mode: READ-ONLY (No remotes invoked)
    
    Generates structured discovery data identical to 1.8-data-support.txt:
      - Local Player & Attributes
      - Character & Humanoid Properties
      - Leaderstats & Values
      - Current State Flags
      - Full Networking Overview (RemoteEvents & RemoteFunctions)
      - Targeted EggWorld / BossEvent / BossMastery Remote breakdown
      - Known ReplicatedStorage Roots (Assets, Models, Eggs, Packages, etc.)
      - Workspace Targeted Roots (Plots, Eggs, Map, ClientRenderedAssets, etc.)
      - Deep Egg / Nest / Boss Object Discovery in Workspace & ReplicatedStorage
    
    Features:
      - Interactive draggable UI with scrollable preview
      - One-click "Copy to Clipboard" (setclipboard support)
      - One-click "Save to File" (writefile support)
      - Non-intrusive / 100% read-only
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

local getHui = gethui or function() return CoreGui end
local uiParent = (pcall(function() return getHui() end) and getHui()) or LocalPlayer:WaitForChild("PlayerGui")

-- ==================================================
-- DISCOVERY SCANNER CORE LOGIC
-- ==================================================

local function runFullDiscoveryScan(onProgress)
    local lines = {}
    local function log(s)
        table.insert(lines, tostring(s or ""))
    end

    local function updateStatus(txt)
        if onProgress then pcall(onProgress, txt) end
    end

    updateStatus("Scanning local player...")
    log("==================================================")
    log("STEAL A EGG - TARGETED DISCOVERY SCANNER")
    log("MODE: READ-ONLY")
    log("NO REMOTES INVOKED")
    log("TIMESTAMP: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
    log("==================================================")
    log("")

    -- 1. LOCAL PLAYER
    log("===== LOCAL PLAYER =====")
    log("Player: " .. tostring(LocalPlayer.Name))
    log("UserId: " .. tostring(LocalPlayer.UserId))
    local char = LocalPlayer.Character
    log("Character: " .. (char and char.Name or "(none)"))
    log("")

    -- 2. PLAYER ATTRIBUTES
    log("===== PLAYER ATTRIBUTES =====")
    local playerAttrs = LocalPlayer:GetAttributes()
    local attrKeys = {}
    for k in pairs(playerAttrs) do table.insert(attrKeys, k) end
    table.sort(attrKeys)
    if #attrKeys == 0 then
        log("(none)")
    else
        for _, k in ipairs(attrKeys) do
            log(string.format("%s = %s", k, tostring(playerAttrs[k])))
        end
    end
    log("")

    -- 3. CHARACTER
    updateStatus("Scanning character & humanoid...")
    log("===== CHARACTER =====")
    if char then
        log("Character: " .. char:GetFullName())
        local charAttrs = char:GetAttributes()
        local charAttrKeys = {}
        for k in pairs(charAttrs) do table.insert(charAttrKeys, k) end
        table.sort(charAttrKeys)
        if #charAttrKeys == 0 then
            log("Character attributes: (none)")
        else
            log("Character attributes:")
            for _, k in ipairs(charAttrKeys) do
                log(string.format("    %s = %s", k, tostring(charAttrs[k])))
            end
        end

        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            log("Humanoid properties:")
            log("    WalkSpeed = " .. tostring(hum.WalkSpeed))
            log("    JumpPower = " .. tostring(hum.JumpPower))
            log("    JumpHeight = " .. tostring(hum.JumpHeight))
            log("    Health = " .. tostring(hum.Health) .. " / " .. tostring(hum.MaxHealth))
            log("    HipHeight = " .. tostring(hum.HipHeight))
            log("    PlatformStand = " .. tostring(hum.PlatformStand))
            log("    Sit = " .. tostring(hum.Sit))
        end
    else
        log("Character: (none)")
    end
    log("")

    -- 4. LEADERSTATS
    log("===== LEADERSTATS =====")
    local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
    if leaderstats then
        local statList = leaderstats:GetChildren()
        table.sort(statList, function(a, b) return a.Name < b.Name end)
        for _, s in ipairs(statList) do
            local val = "nil"
            if s:IsA("ValueBase") then val = tostring(s.Value) end
            log(string.format("%s = %s [%s]", s.Name, val, s.ClassName))
        end
    else
        log("leaderstats not found")
    end
    log("")

    -- 5. IMPORTANT PLAYER VALUES
    log("===== IMPORTANT PLAYER VALUES =====")
    if leaderstats then
        for _, s in ipairs(leaderstats:GetChildren()) do
            local val = s:IsA("ValueBase") and tostring(s.Value) or tostring(s)
            log(string.format("Players.%s.leaderstats.%s = %s", LocalPlayer.Name, s.Name, val))
        end
    end
    for _, ch in ipairs(LocalPlayer:GetChildren()) do
        if ch ~= leaderstats and ch:IsA("ValueBase") then
            log(string.format("Players.%s.%s = %s [%s]", LocalPlayer.Name, ch.Name, tostring(ch.Value), ch.ClassName))
        end
    end
    log("")

    -- 6. CURRENT STATE
    log("===== CURRENT STATE =====")
    local areaId = LocalPlayer:GetAttribute("AreaId") or (char and char:GetAttribute("AreaId"))
    log("AreaId = " .. (areaId and tostring(areaId) or "not found"))
    local profReady = LocalPlayer:GetAttribute("ProfileReady")
    log("ProfileReady = " .. (profReady ~= nil and tostring(profReady) or "not found"))
    local onTreadmill = LocalPlayer:GetAttribute("IsOnTreadmill") or (char and char:GetAttribute("IsOnTreadmill"))
    log("IsOnTreadmill " .. (onTreadmill ~= nil and ("= " .. tostring(onTreadmill)) or "not found"))
    local ragEndTime = LocalPlayer:GetAttribute("RagdollEndTime") or (char and char:GetAttribute("RagdollEndTime"))
    if ragEndTime then log("RagdollEndTime = " .. tostring(ragEndTime)) end
    log("")

    -- 7. NETWORKING OVERVIEW
    updateStatus("Scanning networking remotes...")
    log("===== NETWORKING OVERVIEW =====")
    local allRemotes = {}
    local function collectRemotes(parent)
        if not parent then return end
        for _, obj in ipairs(parent:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                table.insert(allRemotes, obj)
            end
        end
    end

    pcall(function() collectRemotes(ReplicatedStorage) end)

    table.sort(allRemotes, function(a, b) return a.Name < b.Name end)
    for _, r in ipairs(allRemotes) do
        log(string.format("%s [%s]", r.Name, r.ClassName))
    end
    log("")

    -- 8. EGGWORLD NETWORKING SPECIFIC
    updateStatus("Scanning EggWorld & Boss remotes...")
    log("===== EGGWORLD NETWORKING =====")
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    log("Packages found: " .. (pkg and pkg:GetFullName() or "nil"))
    local net = pkg and pkg:FindFirstChild("Networking")
    log("Networking found: " .. (net and net:GetFullName() or "nil"))

    local eggworldREs, eggworldRFs = {}, {}
    local bossREs, bossRFs = {}, {}
    local bossMasteryRFs = {}

    for _, r in ipairs(allRemotes) do
        local nm = r.Name
        if string.find(nm, "EggWorld") then
            if r:IsA("RemoteEvent") then table.insert(eggworldREs, r) else table.insert(eggworldRFs, r) end
        end
        if string.find(nm, "BossEvent") then
            if r:IsA("RemoteEvent") then table.insert(bossREs, r) else table.insert(bossRFs, r) end
        end
        if string.find(nm, "BossMastery") and r:IsA("RemoteFunction") then
            table.insert(bossMasteryRFs, r)
        end
    end

    log("RE: " .. (#eggworldREs > 0 and tostring(#eggworldREs) .. " found" or "nil"))
    log("RF: " .. (#eggworldRFs > 0 and tostring(#eggworldRFs) .. " found" or "nil"))
    log("")

    log("===== EGGWORLD RE =====")
    if #eggworldREs == 0 then
        log("EggWorld RE folder not found")
    else
        for _, r in ipairs(eggworldREs) do log(string.format("%s [%s]", r.Name, r.ClassName)) end
    end
    log("")

    log("===== EGGWORLD RF =====")
    if #eggworldRFs == 0 then
        log("EggWorld RF folder not found")
    else
        for _, r in ipairs(eggworldRFs) do log(string.format("%s [%s]", r.Name, r.ClassName)) end
    end
    log("")

    log("===== BOSS EVENT NETWORKING =====")
    log("")

    log("===== BOSSEVENT RE =====")
    if #bossREs == 0 then
        log("BossEvent RE folder not found")
    else
        for _, r in ipairs(bossREs) do log(string.format("%s [%s]", r.Name, r.ClassName)) end
    end
    log("")

    log("===== BOSSEVENT RF =====")
    if #bossRFs == 0 then
        log("BossEvent RF folder not found")
    else
        for _, r in ipairs(bossRFs) do log(string.format("%s [%s]", r.Name, r.ClassName)) end
    end
    log("")

    log("===== BOSS MASTERY RF =====")
    if #bossMasteryRFs == 0 then
        log("BossMastery RF folder not found")
    else
        for _, r in ipairs(bossMasteryRFs) do log(string.format("%s [%s]", r.Name, r.ClassName)) end
    end
    log("")

    -- 9. KNOWN EGG ROOTS (ReplicatedStorage)
    updateStatus("Scanning ReplicatedStorage roots...")
    log("===== KNOWN EGG ROOTS =====")
    local function dumpRootChildren(inst)
        if not inst then return end
        log(string.format("[FOUND] %s -> %s", inst:GetFullName(), inst.ClassName))
        local kids = inst:GetChildren()
        table.sort(kids, function(a, b) return a.Name < b.Name end)
        if #kids == 0 then
            log("    (empty)")
        else
            for _, k in ipairs(kids) do
                log(string.format("    %s [%s]", k.Name, k.ClassName))
            end
        end
        log("") -- blank line separating roots
    end

    local candidateRoots = {
        ReplicatedStorage:FindFirstChild("Assets"),
        ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Models"),
        ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Models") and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs"),
        ReplicatedStorage:FindFirstChild("Packages"),
        ReplicatedStorage:FindFirstChild("Configs"),
        ReplicatedStorage:FindFirstChild("Eggs"),
        ReplicatedStorage:FindFirstChild("World"),
        ReplicatedStorage:FindFirstChild("Modules"),
    }
    for _, root in ipairs(candidateRoots) do
        if root then dumpRootChildren(root) end
    end

    -- 10. WORKSPACE TARGETED ROOTS
    updateStatus("Scanning Workspace targeted roots...")
    log("===== WORKSPACE TARGETED ROOTS =====")
    local wsCandidateRoots = {
        Workspace:FindFirstChild("Plots"),
        Workspace:FindFirstChild("Eggs"),
        Workspace:FindFirstChild("Map"),
        Workspace:FindFirstChild("__ClientTreadmillRenders"),
        Workspace:FindFirstChild("ClientRenderedAssets"),
        Workspace:FindFirstChild("World"),
    }
    for _, root in ipairs(wsCandidateRoots) do
        if root then
            log(string.format("[FOUND] %s [%s]", root:GetFullName(), root.ClassName))
            local kids = root:GetChildren()
            table.sort(kids, function(a, b) return a.Name < b.Name end)
            if #kids == 0 then
                log("    (empty)")
            else
                for _, k in ipairs(kids) do
                    local entry = string.format("    %s [%s]", k.Name, k.ClassName)
                    -- If inside ClientRenderedAssets, decompose UserId_EggUid
                    if root.Name == "ClientRenderedAssets" then
                        local uid, eggUid = string.match(k.Name, "^(%d+)_(%w+)$")
                        if uid and eggUid then
                            entry = string.format("    %s [%s]  -->  (Player UserId: %s | EggUid: %s)", k.Name, k.ClassName, uid, eggUid)
                        end
                    end
                    log(entry)
                end
            end
            log("") -- blank line separating roots
        end
    end

    -- 11. EGG OBJECT DISCOVERY
    updateStatus("Discovering Egg & Boss objects in Workspace & ReplicatedStorage...")
    log("===== EGG OBJECT DISCOVERY =====")

    local function matchEggKeyword(name)
        local ln = string.lower(name)
        return string.find(ln, "egg")
            or string.find(ln, "nest")
            or string.find(ln, "boss")
            or string.find(ln, "fuse")
            or string.find(ln, "guard")
            or string.find(ln, "fitbounds")
            or string.find(ln, "eggspot")
            or string.find(ln, "eggpoint")
    end

    local function scanDiscovery(rootObj, limit)
        log("Scanning root: " .. rootObj.Name)
        local matches = 0
        for _, desc in ipairs(rootObj:GetDescendants()) do
            -- Match by object's own name to avoid dumping hundreds of generic subparts
            if matchEggKeyword(desc.Name) then
                matches = matches + 1
                if not limit or matches <= limit then
                    log(string.format("[%s] %s", desc.ClassName, desc:GetFullName()))
                end
            end
        end
        log(string.format("Egg/Boss matching objects: %d", matches))
        if limit and matches > limit then
            log(string.format("Result limit reached: %d", limit))
        end
        log("")
    end

    -- Full scan with no truncation
    scanDiscovery(Workspace)
    scanDiscovery(ReplicatedStorage)

    log("==================================================")
    log("SCAN COMPLETE")
    log("==================================================")

    updateStatus("Done!")
    return table.concat(lines, "\n")
end

-- ==================================================
-- USER INTERFACE
-- ==================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TargetedDiscoveryScannerUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

pcall(function()
    local old = uiParent:FindFirstChild("TargetedDiscoveryScannerUI")
    if old then old:Destroy() end
end)
screenGui.Parent = uiParent

local W, H = 500, 480
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(50, 75, 110)
mainStroke.Thickness = 1.5

-- Draggable header
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = Color3.fromRGB(22, 28, 40)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

-- flatten bottom corners of topBar
local topBarCover = Instance.new("Frame")
topBarCover.Size = UDim2.new(1, 0, 0, 8)
topBarCover.Position = UDim2.new(0, 0, 1, -8)
topBarCover.BackgroundColor3 = Color3.fromRGB(22, 28, 40)
topBarCover.BorderSizePixel = 0
topBarCover.Parent = topBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -70, 1, 0)
titleLabel.Position = UDim2.new(0, 12, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "🔍 TARGETED DISCOVERY SCANNER (1.8)"
titleLabel.TextColor3 = Color3.fromRGB(120, 200, 255)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 13
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -32, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 45)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function()
    screenGui:Destroy()
end)

-- Dragging logic
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

-- Control Buttons Row
local BTN_Y = 44
local BTN_H = 28
local BTN_W = 110
local GAP = 8

local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.new(0, BTN_W, 0, BTN_H)
scanBtn.Position = UDim2.new(0, 12, 0, BTN_Y)
scanBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
scanBtn.Text = "▶ RUN SCAN"
scanBtn.TextColor3 = Color3.new(1, 1, 1)
scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextSize = 12
scanBtn.Parent = main
Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0, 6)

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0, BTN_W, 0, BTN_H)
copyBtn.Position = UDim2.new(0, 12 + (BTN_W + GAP), 0, BTN_Y)
copyBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 160)
copyBtn.Text = "📋 COPY"
copyBtn.TextColor3 = Color3.new(1, 1, 1)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 12
copyBtn.Parent = main
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

local saveBtn = Instance.new("TextButton")
saveBtn.Size = UDim2.new(0, BTN_W, 0, BTN_H)
saveBtn.Position = UDim2.new(0, 12 + (BTN_W + GAP)*2, 0, BTN_Y)
saveBtn.BackgroundColor3 = Color3.fromRGB(90, 60, 140)
saveBtn.Text = "💾 SAVE FILE"
saveBtn.TextColor3 = Color3.new(1, 1, 1)
saveBtn.Font = Enum.Font.GothamBold
saveBtn.TextSize = 12
saveBtn.Parent = main
Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 6)

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, BTN_W - 8, 0, BTN_H)
clearBtn.Position = UDim2.new(0, 12 + (BTN_W + GAP)*3, 0, BTN_Y)
clearBtn.BackgroundColor3 = Color3.fromRGB(50, 56, 72)
clearBtn.Text = "CLEAR"
clearBtn.TextColor3 = Color3.fromRGB(200, 210, 230)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 12
clearBtn.Parent = main
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

-- Status Label
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 0, 20)
statusLabel.Position = UDim2.new(0, 12, 0, BTN_Y + BTN_H + 6)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Status: Ready to scan (Click ▶ RUN SCAN)"
statusLabel.TextColor3 = Color3.fromRGB(150, 190, 240)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = main

-- Scrollable Text Preview Box
local BOX_Y = BTN_Y + BTN_H + 30
local BOX_H = H - BOX_Y - 12
local boxFrame = Instance.new("Frame")
boxFrame.Size = UDim2.new(1, -24, 0, BOX_H)
boxFrame.Position = UDim2.new(0, 12, 0, BOX_Y)
boxFrame.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
boxFrame.BorderSizePixel = 0
boxFrame.Parent = main
Instance.new("UICorner", boxFrame).CornerRadius = UDim.new(0, 8)
local boxStroke = Instance.new("UIStroke", boxFrame)
boxStroke.Color = Color3.fromRGB(38, 48, 68)
boxStroke.Thickness = 1

local textBox = Instance.new("TextBox")
textBox.Size = UDim2.new(1, -12, 1, -12)
textBox.Position = UDim2.new(0, 6, 0, 6)
textBox.BackgroundTransparency = 1
textBox.MultiLine = true
textBox.ClearTextOnFocus = false
textBox.TextEditable = false
textBox.TextXAlignment = Enum.TextXAlignment.Left
textBox.TextYAlignment = Enum.TextYAlignment.Top
textBox.Font = Enum.Font.Code
textBox.TextSize = 10
textBox.TextColor3 = Color3.fromRGB(180, 230, 200)
textBox.Text = "-- Discovery output will appear here --\n-- Click [RUN SCAN] to begin."
textBox.Parent = boxFrame

local cachedOutput = ""

local function performScan()
    scanBtn.Text = "⏳ SCANNING..."
    scanBtn.BackgroundColor3 = Color3.fromRGB(100, 100, 40)
    statusLabel.Text = "Status: Scanning in progress..."
    statusLabel.TextColor3 = Color3.fromRGB(255, 230, 100)

    task.defer(function()
        local ok, result = pcall(function()
            return runFullDiscoveryScan(function(stage)
                statusLabel.Text = "Status: " .. stage
            end)
        end)

        if ok and result then
            cachedOutput = result
            textBox.Text = result

            -- Attempt auto-copy to clipboard
            local clipOk = false
            if typeof(setclipboard) == "function" then
                clipOk = pcall(setclipboard, result)
            end

            statusLabel.Text = clipOk and "Status: Scan complete! Copied to clipboard." or "Status: Scan complete! Ready to copy/save."
            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 160)
        else
            statusLabel.Text = "Status: Scan failed: " .. tostring(result)
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        end

        scanBtn.Text = "▶ RUN SCAN"
        scanBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    end)
end

scanBtn.MouseButton1Click:Connect(performScan)

copyBtn.MouseButton1Click:Connect(function()
    if cachedOutput == "" then
        statusLabel.Text = "Status: No output to copy. Run scan first."
        statusLabel.TextColor3 = Color3.fromRGB(255, 160, 100)
        return
    end
    local clipOk = false
    if typeof(setclipboard) == "function" then
        clipOk = pcall(setclipboard, cachedOutput)
    end
    if clipOk then
        statusLabel.Text = "Status: Copied " .. tostring(#cachedOutput) .. " chars to clipboard!"
        statusLabel.TextColor3 = Color3.fromRGB(120, 255, 160)
    else
        textBox.TextEditable = true
        textBox:CaptureFocus()
        statusLabel.Text = "Status: setclipboard unavailable. Text focused for manual Ctrl+C."
        statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    if cachedOutput == "" then
        statusLabel.Text = "Status: No output to save. Run scan first."
        statusLabel.TextColor3 = Color3.fromRGB(255, 160, 100)
        return
    end
    local fileName = "1.8-data-support-scan.txt"
    if typeof(writefile) == "function" then
        local ok, err = pcall(writefile, fileName, cachedOutput)
        if ok then
            statusLabel.Text = "Status: Saved to " .. fileName .. "!"
            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 160)
        else
            statusLabel.Text = "Status: writefile failed: " .. tostring(err)
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        end
    else
        statusLabel.Text = "Status: writefile() not supported in this executor."
        statusLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
    end
end)

clearBtn.MouseButton1Click:Connect(function()
    cachedOutput = ""
    textBox.Text = "-- Cleared --"
    statusLabel.Text = "Status: Cleared."
    statusLabel.TextColor3 = Color3.fromRGB(180, 190, 210)
end)

-- Auto-trigger scan on start
task.defer(performScan)

print("[Targeted Discovery Scanner] Loaded. UI initialized.")
