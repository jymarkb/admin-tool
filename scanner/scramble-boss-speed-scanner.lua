--[[
    ========================================================================
    DR. SCRAMBLE BOSS & LIVE SPEED CEILING DIAGNOSTIC SCANNER
    ========================================================================
    Purpose:
      1. Live Event & Remote Spy:
         Hooks incoming & outgoing network events for ScrambleBoss and BossEvent
         to capture exact timing, phase transitions, and hazard parameters.
      2. WalkSpeed Modifier & Caller Tracker:
         Intercepts all writes to Humanoid.WalkSpeed and logs:
         - New vs. Old speed
         - Exact script caller & stack trace (identifying which event controller changed it!)
      3. Stepped Velocity Benchmark (Speed Ceiling Tester):
         Step-by-step velocity probe (250 -> 650 studs/s) that tests real-time
         displacement against the server to find the EXACT speed cap accepted
         without rubberbanding during the active boss event!
      4. Boss Arena & Attribute Snapshot:
         Dumps live boss models, health, arena coordinates, and player attributes.
    ========================================================================
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ========================================================================
-- 1. GUI MOUNT
-- ========================================================================

local function getGuiParent()
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    return CoreGui
end

local uiParent = getGuiParent()
local existing = uiParent:FindFirstChild("ScrambleBossSpeedScannerGui")
if existing then pcall(function() existing:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = "ScrambleBossSpeedScannerGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 99999
pcall(function() gui.Parent = uiParent end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local W, H = 460, 290
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(220, 100, 60)
mainStroke.Thickness = 1.5

-- Title Bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = Color3.fromRGB(32, 22, 26)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -60, 1, 0); titleLbl.Position = UDim2.new(0, 10, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🔥 SCRAMBLE BOSS SPEED SCANNER"
titleLbl.TextColor3 = Color3.fromRGB(255, 210, 180)
titleLbl.Font = Enum.Font.GothamBold; titleLbl.TextSize = 10.5
titleLbl.TextXAlignment = Enum.TextXAlignment.Left; titleLbl.Parent = titleBar

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 22, 0, 22); minBtn.Position = UDim2.new(1, -52, 0, 4)
minBtn.BackgroundColor3 = Color3.fromRGB(45, 48, 65)
minBtn.Text = "—"; minBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
minBtn.Font = Enum.Font.GothamBold; minBtn.TextSize = 11; minBtn.Parent = titleBar
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 5)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 22, 0, 22); closeBtn.Position = UDim2.new(1, -26, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 60)
closeBtn.Text = "✕"; closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold; closeBtn.TextSize = 11; closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

-- Status Bar
local statusBar = Instance.new("TextLabel")
statusBar.Size = UDim2.new(1, -20, 0, 16); statusBar.Position = UDim2.new(0, 10, 0, 32)
statusBar.BackgroundTransparency = 1
statusBar.Text = "STATUS: Ready · Click [▶ SPY] or [⚡ TEST CAP]"
statusBar.TextColor3 = Color3.fromRGB(255, 200, 120)
statusBar.Font = Enum.Font.GothamBold; statusBar.TextSize = 9
statusBar.TextXAlignment = Enum.TextXAlignment.Left; statusBar.Parent = main

-- Live Telemetry Mini-Card (Speed & Area readout)
local miniCard = Instance.new("Frame")
miniCard.Size = UDim2.new(1, -20, 0, 24); miniCard.Position = UDim2.new(0, 10, 0, 50)
miniCard.BackgroundColor3 = Color3.fromRGB(22, 24, 34); miniCard.BorderSizePixel = 0
miniCard.Parent = main
Instance.new("UICorner", miniCard).CornerRadius = UDim.new(0, 5)
local cardStroke = Instance.new("UIStroke", miniCard)
cardStroke.Color = Color3.fromRGB(60, 50, 75)

local liveSpeedLbl = Instance.new("TextLabel")
liveSpeedLbl.Size = UDim2.new(0.5, -8, 1, 0); liveSpeedLbl.Position = UDim2.new(0, 8, 0, 0)
liveSpeedLbl.BackgroundTransparency = 1
liveSpeedLbl.Text = "WalkSpeed: -- | Vel: --"
liveSpeedLbl.TextColor3 = Color3.fromRGB(140, 255, 180)
liveSpeedLbl.Font = Enum.Font.GothamBold; liveSpeedLbl.TextSize = 9.5
liveSpeedLbl.TextXAlignment = Enum.TextXAlignment.Left; liveSpeedLbl.Parent = miniCard

local liveBossLbl = Instance.new("TextLabel")
liveBossLbl.Size = UDim2.new(0.5, -8, 1, 0); liveBossLbl.Position = UDim2.new(0.5, 4, 0, 0)
liveBossLbl.BackgroundTransparency = 1
liveBossLbl.Text = "Area: -- | Boss: --"
liveBossLbl.TextColor3 = Color3.fromRGB(255, 190, 140)
liveBossLbl.Font = Enum.Font.Gotham; liveBossLbl.TextSize = 9.5
liveBossLbl.TextXAlignment = Enum.TextXAlignment.Left; liveBossLbl.Parent = miniCard

-- Console Log ScrollingFrame
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -20, 1, -116); scroll.Position = UDim2.new(0, 10, 0, 78)
scroll.BackgroundColor3 = Color3.fromRGB(10, 11, 16); scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 5; scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new(0, 0, 0, 0); scroll.Parent = main
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 5)
local scrollStroke = Instance.new("UIStroke", scroll)
scrollStroke.Color = Color3.fromRGB(45, 42, 65); scrollStroke.Thickness = 1

local consoleBox = Instance.new("TextBox")
consoleBox.Size = UDim2.new(1, -8, 1, -8); consoleBox.Position = UDim2.new(0, 4, 0, 4)
consoleBox.BackgroundTransparency = 1
consoleBox.TextColor3 = Color3.fromRGB(220, 230, 250)
consoleBox.Font = Enum.Font.Code; consoleBox.TextSize = 9.5
consoleBox.TextXAlignment = Enum.TextXAlignment.Left; consoleBox.TextYAlignment = Enum.TextYAlignment.Top
consoleBox.ClearTextOnFocus = false; consoleBox.MultiLine = true; consoleBox.TextEditable = false
consoleBox.Text = "=== SCRAMBLE BOSS SPEED SCANNER INITIALIZED ===\n"
consoleBox.Parent = scroll

-- Controls Bar (Bottom)
local btnContainer = Instance.new("Frame")
btnContainer.Size = UDim2.new(1, -20, 0, 26); btnContainer.Position = UDim2.new(0, 10, 1, -32)
btnContainer.BackgroundTransparency = 1; btnContainer.Parent = main
local btnLayout = Instance.new("UIListLayout")
btnLayout.FillDirection = Enum.FillDirection.Horizontal
btnLayout.Padding = UDim.new(0, 4); btnLayout.Parent = btnContainer

local function makeBtn(text, width, bgColor)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, width, 1, 0); b.BackgroundColor3 = bgColor
    b.Text = text; b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold; b.TextSize = 9.5; b.Parent = btnContainer
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    return b
end

local spyBtn   = makeBtn("▶ SPY", 68, Color3.fromRGB(40, 150, 75))
local benchBtn = makeBtn("⚡ TEST CAP", 86, Color3.fromRGB(215, 90, 45))
local dumpBtn  = makeBtn("🔍 SNAP", 64, Color3.fromRGB(115, 60, 185))
local copyBtn  = makeBtn("📋 COPY", 64, Color3.fromRGB(50, 100, 175))
local saveBtn  = makeBtn("💾 SAVE", 64, Color3.fromRGB(160, 95, 40))
local clearBtn = makeBtn("🧹 CLR", 52, Color3.fromRGB(60, 62, 75))

-- Minimize functionality
local isMinimized = false
local contentFrames = { statusBar, miniCard, scroll, btnContainer }
minBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        minBtn.Text = "+"
        for _, f in ipairs(contentFrames) do f.Visible = false end
        main.Size = UDim2.new(0, W, 0, 30)
    else
        minBtn.Text = "—"
        main.Size = UDim2.new(0, W, 0, H)
        for _, f in ipairs(contentFrames) do f.Visible = true end
    end
end)

-- ========================================================================
-- 2. LOGGING HELPER & VALUE FORMATTER
-- ========================================================================

local logEntries = {}
local isSpyActive = false
local isBenchmarking = false

local function formatValue(val, depth, visited)
    depth = depth or 0
    visited = visited or {}
    if val == nil then return "nil" end
    local t = typeof(val)
    if t == "string" then
        return '"' .. val .. '"'
    elseif t == "number" or t == "boolean" or t == "EnumItem" then
        return tostring(val)
    elseif t == "Vector3" then
        return string.format("Vector3(%.1f, %.1f, %.1f)", val.X, val.Y, val.Z)
    elseif t == "Instance" then
        local ok, n = pcall(function() return val:GetFullName() end)
        return "<" .. (ok and n or tostring(val)) .. ">"
    elseif t == "table" then
        if depth >= 4 then return "{...}" end
        if visited[val] then return "<cycle>" end
        visited[val] = true
        local parts = {}
        for k, v in pairs(val) do
            local kStr = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or ("[" .. formatValue(k, depth + 1, visited) .. "]")
            table.insert(parts, string.rep("  ", depth + 1) .. kStr .. " = " .. formatValue(v, depth + 1, visited))
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
    end
    return tostring(val)
end

local function appendLog(txt)
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] %s", timestamp, txt)
    table.insert(logEntries, line)
    if #logEntries > 400 then table.remove(logEntries, 1) end

    consoleBox.Text = table.concat(logEntries, "\n")
    task.defer(function()
        scroll.CanvasPosition = Vector2.new(0, math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteSize.Y + 20))
    end)
end

-- ========================================================================
-- 3. NETWORK SPY & WALKSPEED HOOKS
-- ========================================================================

local hookInstalled = false
local oldNamecall = nil
local oldNewIndex = nil

local function isTargetRemote(rName)
    local low = rName:lower()
    return low:find("scrambleboss") ~= nil
        or low:find("bossevent") ~= nil
        or low:find("scramble") ~= nil
        or low:find("enterarena") ~= nil
        or low:find("beanstalk") ~= nil
        or low:find("trexrun") ~= nil
end

local function installSpyHooks()
    if hookInstalled then return end
    if typeof(hookmetamethod) ~= "function" then
        appendLog("⚠️ [Warning] hookmetamethod is not supported on this executor. Using connection spy instead.")
        return
    end

    -- Hook 1: Outgoing & Incoming Remote Calls
    pcall(function()
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if (method == "FireServer" or method == "InvokeServer") and isSpyActive then
                local rName = ""
                pcall(function() rName = self:GetFullName() end)
                if isTargetRemote(rName) then
                    local args = table.pack(...)
                    local res = nil
                    if method == "InvokeServer" then
                        res = table.pack(oldNamecall(self, ...))
                    end

                    task.spawn(function()
                        local logMsg = string.format("📡 [OUTGOING] %s -> %s\n  Args (%d):", method, rName, args.n)
                        for i = 1, args.n do
                            logMsg = logMsg .. string.format("\n    [%d] = %s", i, formatValue(args[i], 1))
                        end
                        if res then
                            logMsg = logMsg .. string.format("\n  Return (%d):", res.n)
                            for i = 1, res.n do
                                logMsg = logMsg .. string.format("\n    [%d] = %s", i, formatValue(res[i], 1))
                            end
                        end
                        appendLog(logMsg)
                    end)

                    if res then return table.unpack(res, 1, res.n) end
                end
            end
            return oldNamecall(self, ...)
        end)
    end)

    -- Hook 2: WalkSpeed Write Interceptor (Identifies who sets your speed!)
    pcall(function()
        oldNewIndex = hookmetamethod(game, "__newindex", function(self, key, value)
            if key == "WalkSpeed" and isSpyActive then
                local isHum = false
                pcall(function() isHum = self:IsA("Humanoid") and self.Parent == LocalPlayer.Character end)
                if isHum then
                    local oldSpeed = self.WalkSpeed
                    local stack = debug.traceback()
                    task.spawn(function()
                        appendLog(string.format("⚡ [SPEED WRITE] Humanoid.WalkSpeed: %.1f -> %.1f (Delta: %+.1f)\n  Stack: %s", oldSpeed, tonumber(value) or 0, (tonumber(value) or 0) - oldSpeed, stack:sub(1, 180)))
                    end)
                end
            end
            return oldNewIndex(self, key, value)
        end)
    end)

    hookInstalled = true
    appendLog("✅ Metamethod network spy and WalkSpeed write-hooks installed successfully!")
end

-- Incoming Remote Listeners (Direct connection to ReplicatedStorage remotes)
local function bindIncomingListeners()
    local networking = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if not networking then return end

    for _, obj in ipairs(networking:GetChildren()) do
        if obj:IsA("RemoteEvent") and isTargetRemote(obj.Name) then
            pcall(function()
                obj.OnClientEvent:Connect(function(...)
                    if not isSpyActive then return end
                    local args = table.pack(...)
                    local msg = string.format("📥 [INCOMING EVENT] %s\n  Args (%d):", obj.Name, args.n)
                    for i = 1, args.n do
                        msg = msg .. string.format("\n    [%d] = %s", i, formatValue(args[i], 1))
                    end
                    appendLog(msg)
                end)
            end)
        end
    end
end
pcall(bindIncomingListeners)

-- ========================================================================
-- 4. REAL-TIME TELEMETRY MONITOR (Heartbeat loop)
-- ========================================================================

RunService.Heartbeat:Connect(function()
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")

    local curWs = hum and hum.WalkSpeed or 0
    local curVel = root and math.floor(Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude) or 0
    liveSpeedLbl.Text = string.format("WalkSpeed: %.1f | Velocity: %d st/s", curWs, curVel)

    local area = LocalPlayer:GetAttribute("AreaId") or "Unknown"
    local bossAttr = LocalPlayer:GetAttribute("ScrambleBossState") or LocalPlayer:GetAttribute("BossState") or "Not Stated"
    liveBossLbl.Text = string.format("Area: %s | Boss: %s", tostring(area), tostring(bossAttr))
end)

-- ========================================================================
-- 5. SPEED CEILING BENCHMARK (STEPPED VELOCITY TOLERANCE TEST)
-- ========================================================================

local function testSpeedCeiling()
    if isBenchmarking then return end
    isBenchmarking = true
    benchBtn.BackgroundColor3 = Color3.fromRGB(150, 40, 30)
    benchBtn.Text = "⏳ TESTING..."
    statusBar.Text = "STATUS: Running Stepped Speed Benchmark (Please keep walking in a straight line)..."
    appendLog("==================================================")
    appendLog("🧪 STARTING STEPPED SPEED CEILING BENCHMARK")
    appendLog("Testing server movement tolerance in 0.8s windows...")
    appendLog("==================================================")

    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")

    if not hum or not root then
        appendLog("❌ Error: Character not found. Aborting benchmark.")
        isBenchmarking = false
        benchBtn.BackgroundColor3 = Color3.fromRGB(215, 90, 45)
        benchBtn.Text = "⚡ TEST SPEED CAP"
        return
    end

    local speedsToTest = { 280, 320, 360, 400, 450, 500, 550, 600, 700 }
    local maxStableSpeed = 280
    local originalSpeed = hum.WalkSpeed

    task.spawn(function()
        for _, testSpd in ipairs(speedsToTest) do
            appendLog(string.format("👉 Testing Velocity: %d studs/s...", testSpd))
            hum.WalkSpeed = testSpd

            local startTime = os.clock()
            local testWindow = 0.8
            local hadRubberband = false
            local lastPos = root.Position
            local lastT = os.clock()

            while os.clock() - startTime < testWindow do
                task.wait(0.05)
                local now = os.clock()
                local pos = root.Position
                local md = hum.MoveDirection.Magnitude > 0.05 and hum.MoveDirection.Unit or root.CFrame.LookVector
                local dt = now - lastT
                lastT = now

                -- Apply pure horizontal vector velocity
                root.AssemblyLinearVelocity = Vector3.new(md.X * testSpd, root.AssemblyLinearVelocity.Y, md.Z * testSpd)

                -- Check backwards displacement (rubberband snap)
                local disp = Vector3.new(pos.X - lastPos.X, 0, pos.Z - lastPos.Z)
                lastPos = pos
                local backSnap = -(disp:Dot(md))

                if backSnap >= 4.5 and dt < 0.2 then
                    hadRubberband = true
                    appendLog(string.format("  ⚠️ SNAP DETECTED at %d studs/s! (Pulled back %.1f studs)", testSpd, backSnap))
                    break
                end
            end

            if hadRubberband then
                appendLog(string.format("❌ Speed %d studs/s EXCEEDED SERVER LIMIT! Max stable ceiling is %d studs/s.", testSpd, maxStableSpeed))
                break
            else
                maxStableSpeed = testSpd
                appendLog(string.format("  ✅ %d studs/s: 100%% STABLE (No rollbacks in %.1fs window)", testSpd, testWindow))
            end
        end

        hum.WalkSpeed = originalSpeed
        appendLog("==================================================")
        appendLog(string.format("🏁 BENCHMARK COMPLETE! SERVER SPEED CEILING: %d studs/s", maxStableSpeed))
        if maxStableSpeed >= 500 then
            appendLog("🔥 500+ SPEED CONFIRMED ACCEPTED! The event/zone anti-cheat is currently lifted!")
        elseif maxStableSpeed >= 350 then
            appendLog("⚡ Elevated speed permitted (~" .. maxStableSpeed .. " studs/s).")
        else
            appendLog("🛡️ Standard speed limit active (~" .. maxStableSpeed .. " studs/s). Server requires micro-pulsing above this.")
        end
        appendLog("==================================================")

        isBenchmarking = false
        benchBtn.BackgroundColor3 = Color3.fromRGB(215, 90, 45)
        benchBtn.Text = "⚡ TEST SPEED CAP"
        statusBar.Text = string.format("STATUS: Benchmark Finished · Server Speed Ceiling = %d studs/s", maxStableSpeed)
    end)
end

-- ========================================================================
-- 6. DUMP LIVE SNAPSHOT (BOSS, ARENA, ATTRIBUTES)
-- ========================================================================

local function dumpSnapshot()
    appendLog("==================================================")
    appendLog("🔍 LIVE EVENT & CHARACTER STATE SNAPSHOT")
    appendLog("==================================================")

    -- Local Player Attributes
    appendLog("--- LocalPlayer Attributes ---")
    local attrs = LocalPlayer:GetAttributes()
    local attrCount = 0
    for k, v in pairs(attrs) do
        attrCount = attrCount + 1
        appendLog(string.format("  %s = %s", k, formatValue(v)))
    end
    if attrCount == 0 then appendLog("  (No attributes set)") end

    -- Humanoid Properties
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    appendLog("\n--- Character & Humanoid ---")
    if hum and root then
        appendLog(string.format("  Position: Vector3(%.1f, %.1f, %.1f)", root.Position.X, root.Position.Y, root.Position.Z))
        appendLog(string.format("  WalkSpeed: %.1f", hum.WalkSpeed))
        appendLog(string.format("  State: %s", tostring(hum:GetState())))
        appendLog(string.format("  FloorMaterial: %s", tostring(hum.FloorMaterial)))
    end

    -- Carried Tools
    appendLog("\n--- Equipped Tools ---")
    local toolCount = 0
    if char then
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") then
                toolCount = toolCount + 1
                appendLog(string.format("  [Tool] %s", c.Name))
            end
        end
    end
    if toolCount == 0 then appendLog("  (No Tool equipped - Empty handed)") end

    -- Workspace Boss & Arena Search
    appendLog("\n--- Workspace Boss & Arena Entities ---")
    local bossFound = 0
    for _, obj in ipairs(Workspace:GetChildren()) do
        local n = obj.Name:lower()
        if n:find("scramble") or n:find("boss") or n:find("arena") or n:find("mech") then
            bossFound = bossFound + 1
            appendLog(string.format("  [%s] Workspace.%s", obj.ClassName, obj.Name))
        end
    end
    if bossFound == 0 then appendLog("  (No obvious boss models directly under Workspace root)") end

    -- ReplicatedStorage Event Modules
    appendLog("\n--- ReplicatedStorage Event Controllers ---")
    local adminAbuse = ReplicatedStorage:FindFirstChild("Controllers")
        and ReplicatedStorage.Controllers:FindFirstChild("Game")
        and ReplicatedStorage.Controllers.Game:FindFirstChild("AdminAbuseClientController")
    if adminAbuse and adminAbuse:FindFirstChild("Events") then
        for _, ev in ipairs(adminAbuse.Events:GetChildren()) do
            appendLog(string.format("  • Active Event Controller: %s (%s)", ev.Name, ev.ClassName))
        end
    end

    appendLog("==================================================")
    statusBar.Text = "STATUS: Live Snapshot Generated!"
end

-- ========================================================================
-- 7. BUTTON CONNECTIONS & ACTIONS
-- ========================================================================

spyBtn.MouseButton1Click:Connect(function()
    isSpyActive = not isSpyActive
    if isSpyActive then
        installSpyHooks()
        spyBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 45)
        spyBtn.Text = "⏹ STOP SPY"
        statusBar.Text = "STATUS: Live Network & WalkSpeed Spy ACTIVE (Logging events...)"
        appendLog("▶ LIVE SPY ACTIVATED: Monitoring ScrambleBoss/BossEvent remotes and WalkSpeed writes...")
    else
        spyBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 75)
        spyBtn.Text = "▶ START SPY"
        statusBar.Text = "STATUS: Spy Paused"
        appendLog("⏹ LIVE SPY PAUSED.")
    end
end)

benchBtn.MouseButton1Click:Connect(testSpeedCeiling)
dumpBtn.MouseButton1Click:Connect(dumpSnapshot)

copyBtn.MouseButton1Click:Connect(function()
    local fullText = table.concat(logEntries, "\n")
    local ok = pcall(function()
        if typeof(setclipboard) == "function" then
            setclipboard(fullText)
        end
    end)
    if ok then
        copyBtn.Text = "COPIED!"
        task.delay(1.5, function() copyBtn.Text = "📋 COPY LOG" end)
        statusBar.Text = "STATUS: Log copied to clipboard!"
    else
        statusBar.Text = "STATUS: Clipboard not supported. Use text selection."
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    local fullText = table.concat(logEntries, "\n")
    local fileName = "scramble-live-speed-scan.log"
    local ok = pcall(function()
        if typeof(writefile) == "function" then
            writefile(fileName, fullText)
        end
    end)
    if ok then
        saveBtn.Text = "SAVED!"
        task.delay(1.5, function() saveBtn.Text = "💾 SAVE FILE" end)
        statusBar.Text = "STATUS: Saved to " .. fileName
        appendLog("💾 Log saved to " .. fileName)
    else
        statusBar.Text = "STATUS: writefile not available on executor."
    end
end)

clearBtn.MouseButton1Click:Connect(function()
    table.clear(logEntries)
    consoleBox.Text = ""
    statusBar.Text = "STATUS: Log Cleared"
end)

-- Auto-install hooks on mount
installSpyHooks()
appendLog("⚡ Scanner Ready. Click [▶ START SPY] to record incoming boss packets or [⚡ TEST SPEED CAP] to benchmark your max allowed speed right now.")
