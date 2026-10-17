--[[
    STEAL AN EGG - EGG INVENTORY & STATE DEEP PROBE
    Inspects:
      1. RF/ProfileMirror/FetchProfile(LocalPlayer) -> dumps all 91 keys, tables, and egg data
      2. RF/EggWorld/AskLiveSnapshot -> dumps egg live snapshot
      3. RF/EggWorld/AskEggRecord -> dumps egg record
      4. ReplicatedStorage.Client.EggState -> requires and inspects client egg state module
      5. PlayerGui.BackpackGui category tabs (Pets, Eggs, Gear) and CategoryFrame structure
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

local function getGuiParent()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local uiParent = getGuiParent()
local existing = uiParent:FindFirstChild("ProbeEggsGui")
if existing then pcall(function() existing:Destroy() end) end

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

local function dumpTbl(tbl, depth, indent)
    depth = depth or 2
    indent = indent or "  "
    if type(tbl) ~= "table" then return safeValStr(tbl) end
    local lines = {}
    local count = 0
    for k, v in pairs(tbl) do
        count = count + 1
        if count > 40 then
            table.insert(lines, indent .. "... (truncated)")
            break
        end
        if type(v) == "table" and depth > 1 then
            table.insert(lines, indent .. tostring(k) .. " = " .. dumpTbl(v, depth - 1, indent .. "  "))
        else
            table.insert(lines, indent .. tostring(k) .. " = " .. safeValStr(v) .. " [" .. typeof(v) .. "]")
        end
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.sub(indent, 1, math.max(0, #indent - 2)) .. "}"
end

local function getNetRemote(name)
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

local function runEggProbe()
    local out = {}
    local function log(s) table.insert(out, tostring(s or "")) end

    log("==================================================")
    log("STEAL AN EGG - EGG INVENTORY & STATE PROBE")
    log("TIMESTAMP: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
    log("==================================================")
    log("")

    -- 1. RF/ProfileMirror/FetchProfile(LocalPlayer) Deep Inspection
    pcall(function()
        log("===== 1. RF/ProfileMirror/FetchProfile(LocalPlayer) =====")
        local rfProfile = getNetRemote("RF/ProfileMirror/FetchProfile")
        if rfProfile then
            local ok, prof = pcall(function() return rfProfile:InvokeServer(LocalPlayer) end)
            if ok and type(prof) == "table" then
                local keys = {}
                for k in pairs(prof) do table.insert(keys, tostring(k)) end
                table.sort(keys)
                log(string.format("FetchProfile(LocalPlayer) returned table with %d keys:", #keys))
                log("Top-level keys: " .. table.concat(keys, ", "))
                log("")

                -- Search specifically for egg/pet/inventory related tables
                for _, k in ipairs(keys) do
                    local v = prof[k] or prof[tonumber(k)]
                    local kLower = k:lower()
                    if string.find(kLower, "egg") or string.find(kLower, "satchel") or string.find(kLower, "pet") or string.find(kLower, "inv") or string.find(kLower, "backpack") or string.find(kLower, "item") then
                        log(string.format(">>> Key [%s] (%s):", k, typeof(v)))
                        if type(v) == "table" then
                            local subCount = 0
                            for _ in pairs(v) do subCount = subCount + 1 end
                            log(string.format("  Entry count: %d", subCount))
                            log(dumpTbl(v, 2, "    "))
                        else
                            log("  Value: " .. safeValStr(v))
                        end
                        log("")
                    end
                end

                -- Also inspect prof.Data if it exists
                if type(prof.Data) == "table" then
                    log(">>> prof.Data Keys:")
                    local dKeys = {}
                    for dk in pairs(prof.Data) do table.insert(dKeys, tostring(dk)) end
                    table.sort(dKeys)
                    log("  " .. table.concat(dKeys, ", "))
                    for _, dk in ipairs(dKeys) do
                        local dkLow = dk:lower()
                        if string.find(dkLow, "egg") or string.find(dkLow, "satchel") or string.find(dkLow, "inv") then
                            log(string.format("  prof.Data.%s = %s", dk, dumpTbl(prof.Data[dk], 2, "    ")))
                        end
                    end
                    log("")
                end
            else
                log("FetchProfile(LocalPlayer) call failed or returned: " .. tostring(prof))
            end
        else
            log("RF/ProfileMirror/FetchProfile not found!")
        end
        log("")
    end)

    -- 2. RF/EggWorld/AskLiveSnapshot
    pcall(function()
        log("===== 2. RF/EggWorld/AskLiveSnapshot =====")
        local rfEggSnap = getNetRemote("RF/EggWorld/AskLiveSnapshot")
        if rfEggSnap then
            log("Remote found: " .. rfEggSnap:GetFullName())
            local ok, snap = pcall(function() return rfEggSnap:InvokeServer() end)
            if ok and type(snap) == "table" then
                local count = 0
                for _ in pairs(snap) do count = count + 1 end
                log(string.format("AskLiveSnapshot() succeeded (%d entries):", count))
                log(dumpTbl(snap, 3, "  "))
            else
                log("AskLiveSnapshot() return: " .. tostring(snap))
            end

            -- Test with LocalPlayer
            local ok2, snap2 = pcall(function() return rfEggSnap:InvokeServer(LocalPlayer) end)
            if ok2 and type(snap2) == "table" and snap2 ~= snap then
                log(string.format("AskLiveSnapshot(LocalPlayer) returned (%d entries):", #snap2))
                log(dumpTbl(snap2, 3, "  "))
            end
        else
            log("RF/EggWorld/AskLiveSnapshot not found!")
        end
        log("")
    end)

    -- 3. RF/EggWorld/AskEggRecord
    pcall(function()
        log("===== 3. RF/EggWorld/AskEggRecord =====")
        local rfRecord = getNetRemote("RF/EggWorld/AskEggRecord")
        if rfRecord then
            local ok, rec = pcall(function() return rfRecord:InvokeServer() end)
            log("AskEggRecord() result: " .. safeValStr(rec))
            if ok and type(rec) == "table" then
                log(dumpTbl(rec, 2, "  "))
            end
        else
            log("RF/EggWorld/AskEggRecord not found.")
        end
        log("")
    end)

    -- 4. ReplicatedStorage.Client.EggState
    pcall(function()
        log("===== 4. ReplicatedStorage.Client.EggState =====")
        local clientFolder = ReplicatedStorage:FindFirstChild("Client")
        local eggStateMod = clientFolder and clientFolder:FindFirstChild("EggState")
        if eggStateMod and eggStateMod:IsA("ModuleScript") then
            log("Found EggState: " .. eggStateMod:GetFullName())
            local ok, eggState = pcall(function() return require(eggStateMod) end)
            if ok and type(eggState) == "table" then
                log("require(EggState) succeeded! Keys:")
                local keys = {}
                for k, v in pairs(eggState) do
                    table.insert(keys, string.format("%s (%s)", tostring(k), typeof(v)))
                end
                table.sort(keys)
                log("  " .. table.concat(keys, ", "))
                log(dumpTbl(eggState, 2, "  "))

                -- Call any getter functions
                for fnName, fnVal in pairs(eggState) do
                    if type(fnVal) == "function" and (fnName:sub(1, 3):lower() == "get" or fnName:sub(1, 4):lower() == "read") then
                        local callOk, callRes = pcall(fnVal)
                        if callOk and callRes ~= nil then
                            log(string.format("  EggState.%s() -> %s", fnName, dumpTbl(callRes, 2, "    ")))
                        end
                    end
                end
            else
                log("require(EggState) failed: " .. tostring(eggState))
            end
        else
            log("EggState ModuleScript not found in ReplicatedStorage.Client")
        end
        log("")
    end)

    -- 5. BackpackGui Category & Tab Switching Inspection
    pcall(function()
        log("===== 5. BackpackGui Category Tabs & Frames =====")
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local bpGui = pg and pg:FindFirstChild("BackpackGui")
        if bpGui then
            local backpack = bpGui:FindFirstChild("Backpack", true)
            local mainFrame = backpack and backpack:FindFirstChild("Main", true)
            local inv = mainFrame and mainFrame:FindFirstChild("Inventory", true)
            local catFrame = inv and inv:FindFirstChild("CategoryFrame", true)

            if catFrame then
                log("Found CategoryFrame: " .. catFrame:GetFullName())
                for _, child in ipairs(catFrame:GetChildren()) do
                    if not child:IsA("UIComponent") and not child:IsA("UILayout") then
                        local catName = child:FindFirstChild("CategoryName")
                        local qty = child:FindFirstChild("Quantity")
                        local attrs = child:GetAttributes()
                        local attrParts = {}
                        for ak, av in pairs(attrs) do
                            table.insert(attrParts, string.format("%s=%s", ak, safeValStr(av)))
                        end
                        log(string.format("  - [%s] %s | CategoryName: %q | Quantity: %q | Attrs: %s",
                            child.ClassName, child.Name,
                            catName and catName.Text or "none",
                            qty and qty.Text or "none",
                            table.concat(attrParts, ", ")))
                    end
                end
            end

            -- Also check CategoryLabel
            local catLabel = inv and inv:FindFirstChild("CategoryLabel", true)
            if catLabel then
                log("Current CategoryLabel.Text = " .. tostring(catLabel.Text))
            end

            -- Check any TabButtons or CategoryButtons across BackpackGui
            log("\nSearch for Category/Tab Buttons in BackpackGui:")
            for _, d in ipairs(bpGui:GetDescendants()) do
                if d:IsA("TextButton") or d:IsA("ImageButton") then
                    local nm = d.Name:lower()
                    if string.find(nm, "tab") or string.find(nm, "cat") or string.find(nm, "pet") or string.find(nm, "egg") or string.find(nm, "gear") then
                        local btnTexts = {}
                        for _, sub in ipairs(d:GetDescendants()) do
                            if sub:IsA("TextLabel") and sub.Text ~= "" then
                                table.insert(btnTexts, sub.Text)
                            end
                        end
                        log(string.format("  - [%s] %s (Path: %s) | Texts: %s", d.ClassName, d.Name, d:GetFullName(), table.concat(btnTexts, ", ")))
                    end
                end
            end
        else
            log("BackpackGui not found in PlayerGui.")
        end
        log("")
    end)

    log("==================================================")
    log("EGG PROBE COMPLETE")
    log("==================================================")

    return table.concat(out, "\n")
end

-- ============================================================
-- GUI
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ProbeEggsGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = uiParent

local W, H = 560, 520
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(220, 140, 40)
mainStroke.Thickness = 1.5

local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 38)
topBar.BackgroundColor3 = Color3.fromRGB(36, 28, 20)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "EGG INVENTORY & STATE PROBE"
titleLbl.TextColor3 = Color3.fromRGB(255, 220, 140)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 13
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -34, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function() screenGui:Destroy() end)

-- Draggable
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

-- Buttons
local BTN_Y = 44
local BTN_H = 28
local BTN_W = 110
local GAP = 8

local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.new(0, BTN_W, 0, BTN_H)
scanBtn.Position = UDim2.new(0, 12, 0, BTN_Y)
scanBtn.BackgroundColor3 = Color3.fromRGB(200, 120, 25)
scanBtn.Text = "▶ RUN PROBE"
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

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 0, 20)
statusLabel.Position = UDim2.new(0, 12, 0, BTN_Y + BTN_H + 6)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Status: Ready (Click ▶ RUN PROBE)"
statusLabel.TextColor3 = Color3.fromRGB(255, 200, 120)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = main

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
boxStroke.Color = Color3.fromRGB(48, 40, 30)
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
textBox.TextColor3 = Color3.fromRGB(255, 230, 170)
textBox.Text = "-- Egg Probe output will appear here --"
textBox.Parent = boxFrame

local cachedOutput = ""

local function performProbe()
    scanBtn.Text = "⏳ PROBING..."
    statusLabel.Text = "Status: Probing egg inventory & state..."
    task.defer(function()
        local ok, result = pcall(runEggProbe)
        if ok and result then
            cachedOutput = result
            textBox.Text = result
            if typeof(setclipboard) == "function" then pcall(setclipboard, result) end
            statusLabel.Text = "Status: Egg probe complete! Copied to clipboard."
            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 160)
        else
            statusLabel.Text = "Status: Failed: " .. tostring(result)
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        end
        scanBtn.Text = "▶ RUN PROBE"
    end)
end

scanBtn.MouseButton1Click:Connect(performProbe)

copyBtn.MouseButton1Click:Connect(function()
    if cachedOutput ~= "" and typeof(setclipboard) == "function" then
        pcall(setclipboard, cachedOutput)
        statusLabel.Text = "Status: Copied to clipboard!"
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    if cachedOutput ~= "" and typeof(writefile) == "function" then
        pcall(writefile, "probe-eggs-output.log", cachedOutput)
        statusLabel.Text = "Status: Saved to probe-eggs-output.log!"
    end
end)

clearBtn.MouseButton1Click:Connect(function()
    cachedOutput = ""
    textBox.Text = "-- Cleared --"
    statusLabel.Text = "Status: Cleared."
end)

task.defer(performProbe)
print("[Egg Probe] Loaded.")
