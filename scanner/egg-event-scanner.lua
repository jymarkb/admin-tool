--[[
    EGGWORLD REMOTE & EVENT LOGGER / INSPECTOR
    ===========================================
    Empirically inspects both:
      1. OUTGOING (Client -> Server):
         - RF InvokeServer & RE FireServer calls
         - Exact arguments passed
         - Exact return values from server (no guessing / assuming)

      2. INCOMING (Server -> Client):
         - OnClientEvent for all RE/EggWorld/* events:
           • RE/EggWorld/FieldEggShifted
           • RE/EggWorld/FieldEggBatchShifted
           • RE/EggWorld/FieldEggRaritiesShown
           • RE/EggWorld/FieldEggGone
           • RE/EggWorld/FieldEggCarry
           • RE/EggWorld/FieldEggCycleCountdown
           • RE/EggWorld/FieldEggRedeemVerdict
           • RE/EggWorld/OwnerShifted
           • RE/EggWorld/OwnerDropped
         - Any other RemoteEvent OnClientEvent triggers

      3. INTERACTIVE ONE-CLICK PROBE:
         - Instant test invoke buttons for:
           • AskFieldEggSnapshot
           • AskFieldEggRarityShows
           • AskLiveSnapshot
           • AskEggRecord
           • AskFieldEggDrop

    PASSIVE & SAFE:
      - Does not alter game calls or block return values.
      - Uses pcall guards around all formatters.
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

local parentGui = getGuiParent()
local oldGui = parentGui:FindFirstChild("EggRemoteLogger")
if oldGui then pcall(function() oldGui:Destroy() end) end

-- Checkcaller fallback
local checkcaller = checkcaller or function() return false end

-- ============================================================
-- SPAM FILTER / BLACKLIST
-- ============================================================
local IGNORED_REMOTES = {
    "Analytics",
    "Ping",
    "ProbeSatchel",
    "AwayEarnings",
    "Fps",
    "SubmitIdleHop",
    "AskIdleHopFlush",
    "LogTelemetry",
    "LibMP",
}

local function isIgnored(remoteName)
    for _, filter in ipairs(IGNORED_REMOTES) do
        if string.find(remoteName, filter) then
            return true
        end
    end
    return false
end

-- ============================================================
-- STATE
-- ============================================================
local loggingEnabled = true
local eggOnlyFilter = false  -- when true, only logs EggWorld remotes
local logLines = {}
local MAX_ENTRIES = 250
local updatePending = false
local eventConnections = {}

-- ============================================================
-- VALUE FORMATTER (Deep recursive inspector)
-- ============================================================
local function formatValue(value, depth, visited)
    depth = depth or 0
    visited = visited or {}

    if value == nil then return "nil" end

    local vType = typeof(value)

    if vType == "string" then
        return '"' .. value .. '"'
    elseif vType == "number" or vType == "boolean" or vType == "EnumItem" then
        return tostring(value)
    elseif vType == "Vector3" then
        return string.format("Vector3.new(%.3f, %.3f, %.3f)", value.X, value.Y, value.Z)
    elseif vType == "CFrame" then
        local p = value.Position
        return string.format("CFrame.new(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
    elseif vType == "Instance" then
        local ok, fullName = pcall(function() return value:GetFullName() end)
        return ok and ("<Instance: " .. fullName .. ">") or "<Instance: " .. tostring(value) .. ">"
    end

    if vType == "table" then
        if depth >= 5 then return "{ ... } [truncated: depth limit]" end
        if visited[value] then return "<recursive table>" end

        visited[value] = true
        local indent = string.rep("  ", depth + 1)
        local lines = {"{"}

        local count = 0
        for k, childValue in pairs(value) do
            count = count + 1
            if count > 80 then
                table.insert(lines, indent .. "... (truncated " .. tostring(count) .. "+ items)")
                break
            end

            local kStr = typeof(k) == "string" and ('["' .. k .. '"]') or ("[" .. tostring(k) .. "]")
            local ok, childText = pcall(formatValue, childValue, depth + 1, visited)
            table.insert(lines, indent .. kStr .. " = " .. (ok and childText or "<format err>"))
        end

        table.insert(lines, string.rep("  ", depth) .. "}")
        visited[value] = nil
        return table.concat(lines, "\n")
    end

    local ok, res = pcall(tostring, value)
    return ok and res or "<unknown type: " .. vType .. ">"
end

-- ============================================================
-- UI SETUP
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggRemoteLogger"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = parentGui

local W, H = 520, 520
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0, 30, 0.5, -H / 2)
main.BackgroundColor3 = Color3.fromRGB(15, 18, 26)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(50, 120, 220)
mainStroke.Thickness = 1.5

-- Header Bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(22, 28, 42)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "EGGWORLD REMOTE & EVENT LOGGER — READY"
titleLbl.TextColor3 = Color3.fromRGB(100, 200, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 12
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -32, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function()
    loggingEnabled = false
    for _, c in ipairs(eventConnections) do pcall(function() c:Disconnect() end) end
    screenGui:Destroy()
end)

-- Draggable
do
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
end

-- Quick Test Probes Bar (Below Title)
local probeBar = Instance.new("Frame")
probeBar.Size = UDim2.new(1, -20, 0, 28)
probeBar.Position = UDim2.new(0, 10, 0, 42)
probeBar.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
probeBar.BorderSizePixel = 0
probeBar.Parent = main
Instance.new("UICorner", probeBar).CornerRadius = UDim.new(0, 6)

local probeTitle = Instance.new("TextLabel")
probeTitle.Size = UDim2.new(0, 85, 1, 0)
probeTitle.Position = UDim2.new(0, 6, 0, 0)
probeTitle.BackgroundTransparency = 1
probeTitle.Text = "TEST PROBE:"
probeTitle.TextColor3 = Color3.fromRGB(255, 190, 80)
probeTitle.Font = Enum.Font.GothamBold
probeTitle.TextSize = 10
probeTitle.TextXAlignment = Enum.TextXAlignment.Left
probeTitle.Parent = probeBar

local function createProbeBtn(text, x, w, onClick)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, w, 0, 22)
    btn.Position = UDim2.new(0, x, 0, 3)
    btn.BackgroundColor3 = Color3.fromRGB(38, 55, 85)
    btn.Text = text
    btn.TextColor3 = Color3.fromRGB(220, 235, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 10
    btn.Parent = probeBar
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
    btn.MouseButton1Click:Connect(onClick)
    return btn
end

-- Console Textbox
local console = Instance.new("TextBox")
console.Size = UDim2.new(1, -20, 1, -150)
console.Position = UDim2.new(0, 10, 0, 76)
console.BackgroundColor3 = Color3.fromRGB(8, 10, 15)
console.TextColor3 = Color3.fromRGB(215, 225, 240)
console.Font = Enum.Font.Code
console.TextSize = 11
console.Text = "-- EGGWORLD REMOTE LOGGER READY --\nListening for incoming events & outgoing remote calls...\n"
console.TextWrapped = false
console.TextEditable = false
console.ClearTextOnFocus = false
console.MultiLine = true
console.TextXAlignment = Enum.TextXAlignment.Left
console.TextYAlignment = Enum.TextYAlignment.Top
console.Parent = main
Instance.new("UICorner", console).CornerRadius = UDim.new(0, 6)

local padding = Instance.new("UIPadding", console)
padding.PaddingLeft = UDim.new(0, 6)
padding.PaddingRight = UDim.new(0, 6)
padding.PaddingTop = UDim.new(0, 6)

local function setStatus(txt)
    pcall(function()
        titleLbl.Text = "EGG LOGGER — " .. tostring(txt)
    end)
end

local function queueConsoleUpdate()
    if updatePending then return end
    updatePending = true
    task.defer(function()
        updatePending = false
        if console and console.Parent then
            if #logLines == 0 then
                console.Text = "-- LOGS CLEARED --"
            else
                console.Text = table.concat(logLines, "\n\n")
            end
        end
    end)
end

local function addLog(entryText)
    table.insert(logLines, entryText)
    while #logLines > MAX_ENTRIES do
        table.remove(logLines, 1)
    end
    queueConsoleUpdate()
end

-- ============================================================
-- BOTTOM ACTION BUTTONS
-- ============================================================
local function createActionBtn(text, x, w, color, onClick)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, w, 0, 30)
    btn.Position = UDim2.new(0, x, 1, -38)
    btn.BackgroundColor3 = color
    btn.Text = text
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.Parent = main
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    btn.MouseButton1Click:Connect(onClick)
    return btn
end

local startStopBtn
startStopBtn = createActionBtn("PAUSE", 10, 80, Color3.fromRGB(160, 60, 50), function()
    loggingEnabled = not loggingEnabled
    if loggingEnabled then
        startStopBtn.Text = "PAUSE"
        startStopBtn.BackgroundColor3 = Color3.fromRGB(160, 60, 50)
        setStatus("RUNNING")
    else
        startStopBtn.Text = "RESUME"
        startStopBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 70)
        setStatus("PAUSED")
    end
end)

local filterBtn
filterBtn = createActionBtn("FILTER: ALL", 96, 95, Color3.fromRGB(50, 75, 120), function()
    eggOnlyFilter = not eggOnlyFilter
    if eggOnlyFilter then
        filterBtn.Text = "FILTER: EGG ONLY"
        filterBtn.BackgroundColor3 = Color3.fromRGB(190, 110, 20)
    else
        filterBtn.Text = "FILTER: ALL"
        filterBtn.BackgroundColor3 = Color3.fromRGB(50, 75, 120)
    end
end)

createActionBtn("COPY", 197, 75, Color3.fromRGB(70, 95, 160), function()
    local text = table.concat(logLines, "\n\n")
    if typeof(setclipboard) == "function" then
        pcall(setclipboard, text)
        setStatus("COPIED TO CLIPBOARD")
    else
        setStatus("CLIPBOARD UNAVAILABLE")
    end
end)

createActionBtn("SAVE FILE", 278, 85, Color3.fromRGB(100, 60, 150), function()
    local text = table.concat(logLines, "\n\n")
    if typeof(writefile) == "function" then
        local fn = "egg-remotes-" .. os.date("%Y%m%d_%H%M%S") .. ".log"
        pcall(writefile, fn, text)
        setStatus("SAVED: " .. fn)
    else
        setStatus("WRITEFILE UNAVAILABLE")
    end
end)

createActionBtn("CLEAR", 369, 65, Color3.fromRGB(60, 65, 80), function()
    table.clear(logLines)
    queueConsoleUpdate()
    setStatus("CLEARED")
end)

-- ============================================================
-- 1. INCOMING EVENT LISTENER (Server -> Client push events)
-- ============================================================
local function listenToRemoteEvent(reInstance, label)
    if not reInstance or not reInstance:IsA("RemoteEvent") then return end
    local conn = reInstance.OnClientEvent:Connect(function(...)
        if not loggingEnabled then return end
        local rName = reInstance:GetFullName()
        if isIgnored(rName) then return end
        if eggOnlyFilter and not string.find(rName, "Egg", 1, true) then return end

        local args = table.pack(...)
        local lines = {
            "==================================================",
            string.format("<<< INCOMING RE [OnClientEvent]  [t=%.3f]", tick()),
            "Event: " .. label .. " (" .. rName .. ")",
            "Arguments (" .. tostring(args.n) .. "):"
        }

        if args.n == 0 then
            table.insert(lines, "  none")
        else
            for i = 1, args.n do
                local ok, f = pcall(formatValue, args[i])
                table.insert(lines, "  [" .. i .. "] = " .. (ok and f or "<format error>"))
            end
        end

        addLog(table.concat(lines, "\n"))
    end)
    table.insert(eventConnections, conn)
end

-- Connect all known EggWorld RemoteEvents directly
local function bindAllEggWorldEvents()
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if not net then
        addLog("[WARN] ReplicatedStorage.Packages.Networking folder not found yet.")
        return
    end

    local eventNames = {
        "RE/EggWorld/FieldEggShifted",
        "RE/EggWorld/FieldEggBatchShifted",
        "RE/EggWorld/FieldEggRaritiesShown",
        "RE/EggWorld/FieldEggGone",
        "RE/EggWorld/FieldEggCarry",
        "RE/EggWorld/FieldEggCycleCountdown",
        "RE/EggWorld/FieldEggRedeemVerdict",
        "RE/EggWorld/OwnerShifted",
        "RE/EggWorld/OwnerDropped",
        "RE/EggCapture/CutsceneBegan",
        "RE/EggCapture/StandingsRefreshed",
        "RE/BossEvent/StateShifted",
        "RE/BossEvent/HealthShifted",
    }

    for _, ePath in ipairs(eventNames) do
        local ev = net:FindFirstChild(ePath)
        if ev and ev:IsA("RemoteEvent") then
            listenToRemoteEvent(ev, ev.Name)
        end
    end

    -- Also listen to any other RemoteEvents inside Networking that mention Egg
    for _, child in ipairs(net:GetChildren()) do
        if child:IsA("RemoteEvent") and string.find(child.Name:lower(), "egg", 1, true) then
            local already = false
            for _, name in ipairs(eventNames) do
                if child.Name == name then already = true; break end
            end
            if not already then
                listenToRemoteEvent(child, child.Name)
            end
        end
    end
end
bindAllEggWorldEvents()

-- ============================================================
-- 2. OUTGOING REMOTE HOOK (__namecall: FireServer & InvokeServer)
-- ============================================================
if typeof(hookmetamethod) == "function" then
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if method ~= "FireServer" and method ~= "InvokeServer" then
            return oldNamecall(self, ...)
        end

        local args = table.pack(...)

        -- Run original game call first to capture returns
        local results = table.pack(oldNamecall(self, ...))

        if loggingEnabled and not checkcaller() and typeof(self) == "Instance" then
            pcall(function()
                local rName = self:GetFullName()
                if isIgnored(rName) then return end
                if eggOnlyFilter and not string.find(rName, "Egg", 1, true) then return end

                local lines = {
                    "--------------------------------------------------",
                    string.format(">>> OUTGOING [%s]  [t=%.3f]", method, tick()),
                    "Remote: " .. rName,
                    "Arguments (" .. tostring(args.n) .. "):"
                }

                if args.n == 0 then
                    table.insert(lines, "  none")
                else
                    for i = 1, args.n do
                        local ok, f = pcall(formatValue, args[i])
                        table.insert(lines, "  [" .. i .. "] = " .. (ok and f or "<format error>"))
                    end
                end

                if method == "InvokeServer" then
                    table.insert(lines, "Returns (" .. tostring(results.n) .. "):")
                    if results.n == 0 then
                        table.insert(lines, "  none")
                    else
                        for i = 1, results.n do
                            local ok, f = pcall(formatValue, results[i])
                            table.insert(lines, "  [" .. i .. "] = " .. (ok and f or "<format error>"))
                        end
                    end
                end

                addLog(table.concat(lines, "\n"))
            end)
        end

        return table.unpack(results, 1, results.n)
    end)
    addLog("[HOOK] Metamethod hook (__namecall) successfully installed for FireServer & InvokeServer.")
else
    addLog("[WARN] hookmetamethod is unavailable on this executor. Outgoing calls cannot be intercepted; listening to incoming events only.")
end

-- ============================================================
-- 3. PROBE BUTTON ACTIONS (Manual Trigger & Empirical Return Check)
-- ============================================================
local function getRemote(name)
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

-- Button 1: Field Snapshot
createProbeBtn("Snapshot", 95, 75, function()
    task.spawn(function()
        addLog(">>> [MANUAL PROBE] Invoking RF/EggWorld/AskFieldEggSnapshot...")
        local rf = getRemote("RF/EggWorld/AskFieldEggSnapshot")
        if not rf then
            addLog("[-] AskFieldEggSnapshot RF not found!")
            return
        end
        local ok, res = pcall(function() return rf:InvokeServer() end)
        if ok then
            addLog("[+] AskFieldEggSnapshot RETURN:\n" .. formatValue(res))
        else
            addLog("[-] AskFieldEggSnapshot FAILED: " .. tostring(res))
        end
    end)
end)

-- Button 2: Rarities
createProbeBtn("Rarities", 175, 70, function()
    task.spawn(function()
        addLog(">>> [MANUAL PROBE] Invoking RF/EggWorld/AskFieldEggRarityShows...")
        local rf = getRemote("RF/EggWorld/AskFieldEggRarityShows")
        if not rf then
            addLog("[-] AskFieldEggRarityShows RF not found!")
            return
        end
        local ok, res = pcall(function() return rf:InvokeServer() end)
        if ok then
            addLog("[+] AskFieldEggRarityShows RETURN:\n" .. formatValue(res))
        else
            addLog("[-] AskFieldEggRarityShows FAILED: " .. tostring(res))
        end
    end)
end)

-- Button 3: LiveSnapshot (Plots/Incubators)
createProbeBtn("LiveSnap", 250, 75, function()
    task.spawn(function()
        addLog(">>> [MANUAL PROBE] Invoking RF/EggWorld/AskLiveSnapshot...")
        local rf = getRemote("RF/EggWorld/AskLiveSnapshot")
        if not rf then
            addLog("[-] AskLiveSnapshot RF not found!")
            return
        end
        local ok, res = pcall(function() return rf:InvokeServer() end)
        if ok then
            addLog("[+] AskLiveSnapshot RETURN:\n" .. formatValue(res))
        else
            addLog("[-] AskLiveSnapshot FAILED: " .. tostring(res))
        end
    end)
end)

-- Button 4: Drop Egg
createProbeBtn("DropEgg", 330, 70, function()
    task.spawn(function()
        addLog(">>> [MANUAL PROBE] Invoking RF/EggWorld/AskFieldEggDrop ({ Reason = 'PlayerRequest' })...")
        local rf = getRemote("RF/EggWorld/AskFieldEggDrop")
        if not rf then
            addLog("[-] AskFieldEggDrop RF not found!")
            return
        end
        local ok, res = pcall(function() return rf:InvokeServer({ Reason = "PlayerRequest" }) end)
        if ok then
            addLog("[+] AskFieldEggDrop RETURN:\n" .. formatValue(res))
        else
            addLog("[-] AskFieldEggDrop FAILED: " .. tostring(res))
        end
    end)
end)

-- Button 5: EggRecord
createProbeBtn("EggRec", 405, 65, function()
    task.spawn(function()
        addLog(">>> [MANUAL PROBE] Invoking RF/EggWorld/AskEggRecord...")
        local rf = getRemote("RF/EggWorld/AskEggRecord")
        if not rf then
            addLog("[-] AskEggRecord RF not found!")
            return
        end
        local ok, res = pcall(function() return rf:InvokeServer() end)
        if ok then
            addLog("[+] AskEggRecord RETURN:\n" .. formatValue(res))
        else
            addLog("[-] AskEggRecord FAILED: " .. tostring(res))
        end
    end)
end)

setStatus("RUNNING")
print("[EggRemoteLogger] Initialized.")
