--[[
    STEAL AN EGG - BACKPACK & FUSE SELECTION DEEP PROBE
    Inspects:
      1. LocalPlayer.Backpack:GetChildren() (Tools, Attributes, Values)
      2. PlayerGui.BackpackGui.Backpack.Main.Inventory structure & individual pet slots
      3. PlayerGui.PetFuse.FusePetInventory.Frame contents & selection cards
      4. ReplicatedStorage.Controllers.GUI.FuseMachineController.FuseMachineBackpackSelection module
      5. RF/ProfileMirror/FetchProfile with alternate argument signatures
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
local existing = uiParent:FindFirstChild("ProbeBackpackGui")
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
            table.insert(lines, indent .. tostring(k) .. " = " .. safeValStr(v))
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

local function runBackpackProbe()
    local out = {}
    local function log(s) table.insert(out, tostring(s or "")) end

    log("==================================================")
    log("STEAL AN EGG - BACKPACK & FUSE SELECTION PROBE")
    log("TIMESTAMP: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
    log("==================================================")
    log("")

    -- 1. LocalPlayer.Backpack Children
    pcall(function()
        log("===== 1. LocalPlayer.Backpack Children =====")
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if bp then
            local bpChildren = bp:GetChildren()
            log(string.format("Backpack has %d items:", #bpChildren))
            for i, item in ipairs(bpChildren) do
                if i <= 30 then
                    local attrs = item:GetAttributes()
                    local attrParts = {}
                    for ak, av in pairs(attrs) do
                        table.insert(attrParts, string.format("%s=%s", ak, safeValStr(av)))
                    end
                    local attrStr = #attrParts > 0 and (" | Attrs: " .. table.concat(attrParts, ", ")) or ""
                    log(string.format("  [%d] [%s] %s%s", i, item.ClassName, item.Name, attrStr))
                end
            end
            if #bpChildren > 30 then
                log(string.format("  ... (%d more items in Backpack)", #bpChildren - 30))
            end
        else
            log("LocalPlayer.Backpack NOT found!")
        end
        log("")
    end)

    -- 2. PlayerGui.BackpackGui.Backpack.Main.Inventory
    pcall(function()
        log("===== 2. PlayerGui.BackpackGui Slots =====")
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local bpGui = pg and pg:FindFirstChild("BackpackGui")
        if bpGui then
            local inv = bpGui:FindFirstChild("Backpack", true)
            local invMain = inv and inv:FindFirstChild("Main", true)
            local invFrame = invMain and invMain:FindFirstChild("Inventory", true)

            if invFrame then
                log("Found Inventory Frame: " .. invFrame:GetFullName())
                local directChildren = invFrame:GetChildren()
                log(string.format("Inventory direct children count: %d", #directChildren))

                local candidateFrames = {}
                for _, c in ipairs(directChildren) do
                    log(string.format("  - [%s] %s", c.ClassName, c.Name))
                    if c:IsA("ScrollingFrame") or c:IsA("Frame") then
                        table.insert(candidateFrames, c)
                    end
                end

                for _, sf in ipairs(candidateFrames) do
                    local slots = sf:GetChildren()
                    local slotCount = 0
                    for _, s in ipairs(slots) do
                        if not s:IsA("UIComponent") and not s:IsA("UILayout") then
                            slotCount = slotCount + 1
                        end
                    end
                    log(string.format("\n  Container: %s (%d slots):", sf.Name, slotCount))

                    local sample = 0
                    for _, s in ipairs(slots) do
                        if not s:IsA("UIComponent") and not s:IsA("UILayout") then
                            sample = sample + 1
                            if sample <= 20 then
                                local sAttrs = s:GetAttributes()
                                local attrParts = {}
                                for ak, av in pairs(sAttrs) do
                                    table.insert(attrParts, string.format("%s=%s", ak, safeValStr(av)))
                                end
                                local texts = {}
                                for _, d in ipairs(s:GetDescendants()) do
                                    if d:IsA("TextLabel") and d.Text ~= "" then
                                        table.insert(texts, string.format("%s: %q", d.Name, d.Text))
                                    end
                                end
                                local txtStr = #texts > 0 and (" | Texts: " .. table.concat(texts, ", ")) or ""
                                local attrStr = #attrParts > 0 and (" | Attrs: " .. table.concat(attrParts, ", ")) or ""
                                log(string.format("    - [%s] %s%s%s", s.ClassName, s.Name, attrStr, txtStr))
                            end
                        end
                    end
                    if slotCount > 20 then
                        log(string.format("    ... (%d more slots in %s)", slotCount - 20, sf.Name))
                    end
                end
            else
                log("Inventory Frame not found under BackpackGui.Backpack.Main")
            end
        else
            log("PlayerGui.BackpackGui NOT found!")
        end
        log("")
    end)

    -- 3. PlayerGui.PetFuse
    pcall(function()
        log("===== 3. PlayerGui.PetFuse Slots =====")
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local petFuse = pg and pg:FindFirstChild("PetFuse")
        if petFuse then
            log("Found PetFuse: " .. petFuse:GetFullName() .. " (Enabled: " .. tostring(petFuse.Enabled) .. ")")
            local fuseInv = petFuse:FindFirstChild("FusePetInventory", true)
            if fuseInv then
                log("Found FusePetInventory: " .. fuseInv:GetFullName())
                local descendants = fuseInv:GetDescendants()
                log(string.format("FusePetInventory descendants count: %d", #descendants))
                local sample = 0
                for _, d in ipairs(descendants) do
                    if d:IsA("Frame") or d:IsA("ImageButton") or d:IsA("TextButton") then
                        sample = sample + 1
                        if sample <= 20 then
                            local dAttrs = d:GetAttributes()
                            local attrParts = {}
                            for ak, av in pairs(dAttrs) do
                                table.insert(attrParts, string.format("%s=%s", ak, safeValStr(av)))
                            end
                            local texts = {}
                            for _, sub in ipairs(d:GetDescendants()) do
                                if sub:IsA("TextLabel") and sub.Text ~= "" then
                                    table.insert(texts, string.format("%s: %q", sub.Name, sub.Text))
                                end
                            end
                            local txtStr = #texts > 0 and (" | Texts: " .. table.concat(texts, ", ")) or ""
                            local attrStr = #attrParts > 0 and (" | Attrs: " .. table.concat(attrParts, ", ")) or ""
                            log(string.format("  - [%s] %s%s%s", d.ClassName, d.Name, attrStr, txtStr))
                        end
                    end
                end
            end
        else
            log("PlayerGui.PetFuse NOT found!")
        end
        log("")
    end)

    -- 4. ReplicatedStorage FuseMachine Controllers
    pcall(function()
        log("===== 4. ReplicatedStorage FuseMachine Controllers =====")
        local fuseCtrlMod = ReplicatedStorage:FindFirstChild("Controllers", true)
        local fuseModule = fuseCtrlMod and fuseCtrlMod:FindFirstChild("FuseMachineBackpackSelection", true)
        if fuseModule and fuseModule:IsA("ModuleScript") then
            log("Found FuseMachineBackpackSelection: " .. fuseModule:GetFullName())
            local ok, res = pcall(function() return require(fuseModule) end)
            if ok then
                log("require(FuseMachineBackpackSelection) succeeded! Type: " .. typeof(res))
                if type(res) == "table" then
                    log(dumpTbl(res, 2, "  "))
                    -- If it has functions, test calling safe getters
                    for fnName, fnVal in pairs(res) do
                        if type(fnVal) == "function" and (fnName:sub(1, 3):lower() == "get" or fnName:sub(1, 4):lower() == "read") then
                            local callOk, callRes = pcall(fnVal)
                            if callOk and callRes ~= nil then
                                log(string.format("  invoked %s() -> %s", fnName, dumpTbl(callRes, 2, "    ")))
                            end
                        end
                    end
                end
            else
                log("require(FuseMachineBackpackSelection) failed: " .. tostring(res))
            end
        else
            log("FuseMachineBackpackSelection ModuleScript not found in ReplicatedStorage.")
        end

        local fuseMainMod = fuseCtrlMod and fuseCtrlMod:FindFirstChild("FuseMachineController", true)
        if fuseMainMod and fuseMainMod:IsA("ModuleScript") then
            log("\nFound FuseMachineController: " .. fuseMainMod:GetFullName())
            local ok, res = pcall(function() return require(fuseMainMod) end)
            if ok and type(res) == "table" then
                log("require(FuseMachineController) succeeded! Keys:")
                local keys = {}
                for k, v in pairs(res) do
                    table.insert(keys, string.format("%s (%s)", tostring(k), typeof(v)))
                end
                table.sort(keys)
                log("  " .. table.concat(keys, ", "))
            end
        end
        log("")
    end)

    -- 5. RF/ProfileMirror/FetchProfile alternate arguments
    pcall(function()
        log("===== 5. ProfileMirror FetchProfile Arguments Test =====")
        local rfProfile = getNetRemote("RF/ProfileMirror/FetchProfile")
        if rfProfile then
            local tests = {
                { "no_args", {} },
                { "userId", { LocalPlayer.UserId } },
                { "player", { LocalPlayer } },
                { "str_userId", { tostring(LocalPlayer.UserId) } },
                { "satchel_str", { "Satchel" } },
                { "pets_str", { "Pets" } }
            }
            for _, t in ipairs(tests) do
                local ok, res = pcall(function() return rfProfile:InvokeServer(unpack(t[2])) end)
                local resSummary = "nil"
                if res ~= nil then
                    if type(res) == "table" then
                        local count = 0
                        for _ in pairs(res) do count = count + 1 end
                        resSummary = string.format("Table (%d entries)", count)
                    else
                        resSummary = tostring(res) .. " [" .. typeof(res) .. "]"
                    end
                end
                log(string.format("  InvokeServer(%s): ok=%s, return=%s", t[1], tostring(ok), resSummary))
            end
        else
            log("RF/ProfileMirror/FetchProfile remote not found.")
        end
        log("")
    end)

    log("==================================================")
    log("BACKPACK PROBE COMPLETE")
    log("==================================================")

    return table.concat(out, "\n")
end

-- ============================================================
-- GUI
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ProbeBackpackGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = uiParent

local W, H = 560, 500
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(80, 130, 230)
mainStroke.Thickness = 1.5

local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 38)
topBar.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "BACKPACK & FUSE SELECTION PROBE"
titleLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
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
scanBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
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
statusLabel.TextColor3 = Color3.fromRGB(150, 190, 240)
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
textBox.Text = "-- Output will appear here --"
textBox.Parent = boxFrame

local cachedOutput = ""

local function performProbe()
    scanBtn.Text = "⏳ PROBING..."
    statusLabel.Text = "Status: Probing backpack & fuse selection..."
    task.defer(function()
        local ok, result = pcall(runBackpackProbe)
        if ok and result then
            cachedOutput = result
            textBox.Text = result
            if typeof(setclipboard) == "function" then pcall(setclipboard, result) end
            statusLabel.Text = "Status: Probe complete! Copied to clipboard."
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
        pcall(writefile, "probe-backpack-output.log", cachedOutput)
        statusLabel.Text = "Status: Saved to probe-backpack-output.log!"
    end
end)

clearBtn.MouseButton1Click:Connect(function()
    cachedOutput = ""
    textBox.Text = "-- Cleared --"
    statusLabel.Text = "Status: Cleared."
end)

task.defer(performProbe)
print("[Backpack Probe] Loaded.")
