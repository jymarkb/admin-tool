--[[
    STEAL AN EGG - FUSERY DIAGNOSTIC & REMOTE PARAMETER PROBE (V2 - FAIL-SAFE)
    
    Features:
      1. GUI mounts IMMEDIATELY so you see it instantly (no freezing)
      2. Asynchronous execution in task.spawn()
      3. Strict 1.5s timeout on every remote invocation
      4. Deep inspection of PlayerGui, Character, LocalPlayer, and Workspace for Pets and Equipped status
      5. Safe module inspection of FuseMachine, FuseKernel, and Fuse Controllers
      6. On-screen real-time log with COPY REPORT and SAVE FILE buttons
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ============================================================
-- 1. INSTANT UI CREATION (MOUNTED BEFORE ANY WORK STARTS)
-- ============================================================
local getHui = gethui or function() return CoreGui end
local uiParent = nil
pcall(function() uiParent = getHui() end)
if not uiParent then
    uiParent = LocalPlayer:FindFirstChild("PlayerGui") or CoreGui
end

-- Destroy existing probe gui if present
local oldGui = uiParent:FindFirstChild("FuseryProbeGui")
if oldGui then pcall(function() oldGui:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = "FuseryProbeGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 99999
pcall(function() gui.Parent = uiParent end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 560, 0, 500)
frame.Position = UDim2.new(0.5, -280, 0.5, -250)
frame.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(80, 110, 170)
stroke.Thickness = 1.5

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 38)
titleBar.BackgroundColor3 = Color3.fromRGB(28, 34, 50)
titleBar.BorderSizePixel = 0
titleBar.Parent = frame
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🧪 Fusery Diagnostic & Pet Inventory Probe (Live)"
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
closeBtn.TextSize = 12
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -16, 1, -92)
scroll.Position = UDim2.new(0, 8, 0, 44)
scroll.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = frame
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

local txt = Instance.new("TextBox")
txt.Size = UDim2.new(1, -12, 1, 0)
txt.Position = UDim2.new(0, 6, 0, 6)
txt.BackgroundTransparency = 1
txt.Text = "Starting diagnostic probe...\n"
txt.TextColor3 = Color3.fromRGB(210, 225, 250)
txt.Font = Enum.Font.Code
txt.TextSize = 10
txt.TextXAlignment = Enum.TextXAlignment.Left
txt.TextYAlignment = Enum.TextYAlignment.Top
txt.ClearTextOnFocus = false
txt.MultiLine = true
txt.TextEditable = false
txt.Parent = scroll

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0.5, -12, 0, 34)
copyBtn.Position = UDim2.new(0, 8, 1, -42)
copyBtn.BackgroundColor3 = Color3.fromRGB(45, 110, 180)
copyBtn.Text = "📋 COPY REPORT"
copyBtn.TextColor3 = Color3.new(1, 1, 1)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 11
copyBtn.Parent = frame
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

local saveBtn = Instance.new("TextButton")
saveBtn.Size = UDim2.new(0.5, -12, 0, 34)
saveBtn.Position = UDim2.new(0.5, 4, 1, -42)
saveBtn.BackgroundColor3 = Color3.fromRGB(38, 130, 75)
saveBtn.Text = "💾 SAVE TO FILE"
saveBtn.TextColor3 = Color3.new(1, 1, 1)
saveBtn.Font = Enum.Font.GothamBold
saveBtn.TextSize = 11
saveBtn.Parent = frame
Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 6)

local logs = {}
local function log(fmt, ...)
    local str = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    table.insert(logs, str)
    local combined = table.concat(logs, "\n")
    txt.Text = combined
    print("[FuseryProbe] " .. str)
end

copyBtn.MouseButton1Click:Connect(function()
    local textToCopy = table.concat(logs, "\n")
    if setclipboard then
        setclipboard(textToCopy)
        copyBtn.Text = "✓ COPIED TO CLIPBOARD!"
        task.delay(2, function() copyBtn.Text = "📋 COPY REPORT" end)
    else
        copyBtn.Text = "Select All in Box & Copy"
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    local textToSave = table.concat(logs, "\n")
    if writefile then
        pcall(function() writefile("fusery-probe-result.txt", textToSave) end)
        saveBtn.Text = "✓ SAVED TO fusery-probe-result.txt!"
        task.delay(2, function() saveBtn.Text = "💾 SAVE TO FILE" end)
    else
        saveBtn.Text = "writefile not supported"
    end
end)

local function describeTable(tbl, maxDepth, depth)
    maxDepth = maxDepth or 2
    depth = depth or 0
    if type(tbl) ~= "table" then return tostring(tbl) end
    if depth >= maxDepth then return "{...}" end
    local parts = {}
    local count = 0
    for k, v in pairs(tbl) do
        count = count + 1
        if count > 12 then
            table.insert(parts, string.rep("  ", depth + 1) .. "... (" .. (count) .. "+ keys)")
            break
        end
        local kStr = tostring(k)
        local vStr
        if type(v) == "table" then
            vStr = describeTable(v, maxDepth, depth + 1)
        elseif type(v) == "function" then
            vStr = "function()"
        else
            vStr = tostring(v)
        end
        table.insert(parts, string.rep("  ", depth + 1) .. "[" .. kStr .. "] = " .. vStr)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
end

-- Safe call with timeout
local function callWithTimeout(fn, timeoutSec)
    timeoutSec = timeoutSec or 1.5
    local co = coroutine.create(fn)
    local timedOut = false
    local result = nil
    local ok = false

    local delayThread = task.delay(timeoutSec, function()
        timedOut = true
    end)

    ok, result = coroutine.resume(co)
    if coroutine.status(co) == "suspended" then
        local startT = os.clock()
        while coroutine.status(co) == "suspended" and (os.clock() - startT < timeoutSec) do
            task.wait(0.05)
        end
        if coroutine.status(co) == "suspended" then
            timedOut = true
        end
    end

    if timedOut then
        return false, "TIMEOUT (> " .. tostring(timeoutSec) .. "s)"
    end
    return ok, result
end

-- ============================================================
-- 2. ASYNCHRONOUS PROBING PIPELINE
-- ============================================================
task.spawn(function()
    log("==================================================")
    log("FUSERY & PET INVENTORY DEEP PROBE (ASYNC)")
    log("Player: %s (UserId: %d)", LocalPlayer.Name, LocalPlayer.UserId)
    log("==================================================")

    -- STEP 1: DETECT LOCALPLAYER DATA & SATCHEL
    log("\n--- [STEP 1] PLAYER DATA & SATCHEL CONTAINERS ---")
    local lpChildren = LocalPlayer:GetChildren()
    log("LocalPlayer Children count: %d", #lpChildren)
    for _, c in ipairs(lpChildren) do
        log("  LocalPlayer.%s [%s] (children: %d)", c.Name, c.ClassName, #c:GetChildren())
        if c:IsA("Folder") or c:IsA("Configuration") then
            for idx, item in ipairs(c:GetChildren()) do
                if idx <= 4 then
                    local attrs = item:GetAttributes()
                    log("    -> [%d] %s (%s) Attrs: %s", idx, item.Name, item.ClassName, describeTable(attrs, 1))
                end
            end
            if #c:GetChildren() > 4 then
                log("    ... and %d more items", #c:GetChildren() - 4)
            end
        end
    end

    -- Check LocalPlayer Attributes
    log("\nLocalPlayer Attributes:")
    local lpAttrs = LocalPlayer:GetAttributes()
    local attrFound = false
    for k, v in pairs(lpAttrs) do
        attrFound = true
        log("  [%s] = %s", tostring(k), tostring(v))
    end
    if not attrFound then log("  (No attributes)") end

    -- STEP 2: CHECK EQUIPPED PETS IN CHARACTER & WORKSPACE
    log("\n--- [STEP 2] EQUIPPED PETS DETECTION ---")
    local char = LocalPlayer.Character or Workspace:FindFirstChild(LocalPlayer.Name)
    if char then
        log("Character found: %s", char:GetFullName())
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Model") or c:IsA("Folder") or c:IsA("Tool") or string.find(string.lower(c.Name), "pet") then
                log("  Char child: %s [%s]", c.Name, c.ClassName)
                for _, sub in ipairs(c:GetChildren()) do
                    log("    Sub: %s [%s]", sub.Name, sub.ClassName)
                end
            end
        end
    else
        log("Character not found")
    end

    -- Check Workspace for player pet models
    local wsPets = Workspace:FindFirstChild("Pets") or Workspace:FindFirstChild("World")
    if wsPets then
        log("Checking %s for player pets...", wsPets:GetFullName())
        for _, d in ipairs(wsPets:GetChildren()) do
            if string.find(string.lower(d.Name), string.lower(LocalPlayer.Name)) or string.find(string.lower(d.Name), "pet") then
                log("  Found: %s [%s]", d.Name, d.ClassName)
            end
        end
    end

    -- STEP 3: CHECK PLAYERGUI FOR PET SATCHEL & FUSE MACHINE
    log("\n--- [STEP 3] PLAYERGUI PET / SATCHEL INTROSPECTION ---")
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        log("Scanning PlayerGui screen elements...")
        for _, guiObj in ipairs(pg:GetChildren()) do
            if guiObj:IsA("ScreenGui") then
                local isRelevant = false
                local lowerName = string.lower(guiObj.Name)
                if string.find(lowerName, "satchel") or string.find(lowerName, "pet") or string.find(lowerName, "fuse") or string.find(lowerName, "backpack") or string.find(lowerName, "inv") then
                    isRelevant = true
                end
                if isRelevant then
                    log("  [RELEVANT GUI] %s (Enabled=%s)", guiObj.Name, tostring(guiObj.Enabled))
                    for _, desc in ipairs(guiObj:GetDescendants()) do
                        if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("ImageLabel") then
                            local txtVal = desc:IsA("TextLabel") and desc.Text or (desc:IsA("TextButton") and desc.Text or "")
                            if #txtVal > 0 and #txtVal < 35 then
                                -- sample first few labels
                                -- log("    %s.%s = '%s'", desc.Parent.Name, desc.Name, txtVal)
                            end
                        end
                    end
                end
            end
        end
    end

    -- STEP 4: INSPECT SHARED MODULES (SAFE WITH TIMEOUT)
    log("\n--- [STEP 4] FUSE MODULES INTROSPECTION ---")
    local modules = {
        "Shared.Types.FuseMachine",
        "Shared.Util.FuseKernel",
        "Shared.Flags.FuseFlags",
        "Controllers.Game.FuseMachineController",
        "Controllers.GUI.FuseMachineController"
    }

    for _, modPath in ipairs(modules) do
        local cur = ReplicatedStorage
        local found = true
        for part in string.gmatch(modPath, "[^.]+") do
            cur = cur and cur:FindFirstChild(part)
            if not cur then found = false; break end
        end
        if found and cur:IsA("ModuleScript") then
            log("Attempting require(%s)...", modPath)
            local ok, res = callWithTimeout(function()
                return require(cur)
            end, 1.0)
            if ok then
                log("  [REQUIRE OK] %s -> %s", modPath, describeTable(res, 2))
            else
                log("  [REQUIRE FAILED/TIMEOUT] %s: %s", modPath, tostring(res))
            end
        else
            log("  [NOT FOUND] %s", modPath)
        end
    end

    -- STEP 4.5: PROBE PROFILEMIRROR & PENROSTER (PET INVENTORY & EQUIPPED)
    log("\n--- [STEP 4.5] PROFILE & EQUIPPED PETS REMOTES ---")
    local rfProfile = net and net:FindFirstChild("RF/ProfileMirror/FetchProfile")
    local rfPenSnapshot = net and net:FindFirstChild("RF/PenRoster/AskLiveSnapshot")
    local rfWearLimit = net and net:FindFirstChild("RF/PenRoster/AskWearLimit")

    log("Profile / PenRoster remotes:")
    log("  FetchProfile:    %s", rfProfile and "EXISTS" or "MISSING")
    log("  AskLiveSnapshot: %s", rfPenSnapshot and "EXISTS" or "MISSING")
    log("  AskWearLimit:    %s", rfWearLimit and "EXISTS" or "MISSING")

    if rfProfile then
        log("\nTesting FetchProfile:InvokeServer()...")
        local ok, res = callWithTimeout(function()
            return rfProfile:InvokeServer()
        end, 2.0)
        log("  Result ok=%s", tostring(ok))
        if ok and type(res) == "table" then
            log("  Profile Keys:")
            for k, v in pairs(res) do
                local typeStr = type(v)
                local countStr = (typeStr == "table") and string.format(" (table, #=%d)", #v) or ""
                log("    [%s] = %s%s", tostring(k), typeStr, countStr)
            end
            if res.Satchel or res.Pets or res.PetSatchel or res.Backpack then
                local s = res.Satchel or res.Pets or res.PetSatchel or res.Backpack
                log("  Found Pet Container in Profile! Entries: %d", type(s) == "table" and #s or 0)
                if type(s) == "table" then
                    for idx, petData in ipairs(s) do
                        if idx <= 5 then
                            log("    Sample Pet [%d]: %s", idx, describeTable(petData, 2))
                        end
                    end
                end
            end
        else
            log("  FetchProfile return: %s", tostring(res))
        end
    end

    if rfPenSnapshot then
        log("\nTesting PenRoster AskLiveSnapshot:InvokeServer()...")
        local ok, res = callWithTimeout(function()
            return rfPenSnapshot:InvokeServer()
        end, 2.0)
        log("  Result ok=%s, return=%s", tostring(ok), describeTable(res, 2))
    end

    -- STEP 5: PROBE FUSERY REMOTES (SAFE PCALL WITH 1.5S TIMEOUT)
    log("\n--- [STEP 5] FUSERY REMOTES PROBING ---")
    local rfBriefing = net and net:FindFirstChild("RF/Fusery/ConfirmBriefing")
    local rfLoad     = net and net:FindFirstChild("RF/Fusery/LoadPet")
    local rfEject    = net and net:FindFirstChild("RF/Fusery/EjectPet")
    local rfBegin    = net and net:FindFirstChild("RF/Fusery/BeginFuse")
    local rfFinish   = net and net:FindFirstChild("RF/Fusery/FinishReveal")

    log("Remotes Status in ReplicatedStorage.Packages.Networking:")
    log("  ConfirmBriefing: %s", rfBriefing and "EXISTS" or "MISSING")
    log("  LoadPet:         %s", rfLoad and "EXISTS" or "MISSING")
    log("  EjectPet:        %s", rfEject and "EXISTS" or "MISSING")
    log("  BeginFuse:       %s", rfBegin and "EXISTS" or "MISSING")
    log("  FinishReveal:    %s", rfFinish and "EXISTS" or "MISSING")

    if rfBriefing then
        log("\nTesting ConfirmBriefing:InvokeServer()...")
        local ok, res = callWithTimeout(function()
            return rfBriefing:InvokeServer()
        end, 1.5)
        log("  Result ok=%s, return=%s", tostring(ok), describeTable(res, 1))
    end

    if rfLoad then
        log("\nTesting LoadPet:InvokeServer() empty args...")
        local ok, res = callWithTimeout(function()
            return rfLoad:InvokeServer()
        end, 1.5)
        log("  Result ok=%s, return=%s", tostring(ok), describeTable(res, 1))
    end

    if rfBegin then
        log("\nTesting BeginFuse:InvokeServer() empty args...")
        local ok, res = callWithTimeout(function()
            return rfBegin:InvokeServer()
        end, 1.5)
        log("  Result ok=%s, return=%s", tostring(ok), describeTable(res, 1))
    end

    log("\n==================================================")
    log("PROBE COMPLETED! Click [COPY REPORT] to paste here.")
    log("==================================================")
end)
