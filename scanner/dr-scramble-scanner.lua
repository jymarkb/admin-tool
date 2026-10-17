--[[
    ========================================================================
    DR. SCRAMBLE TRADE-IN & REMOTE SPY DIAGNOSTIC SCANNER
    ========================================================================
    Purpose:
      1. Live Network Spy: Hooks FireServer & InvokeServer to capture the EXACT
         remotes, arguments, and return values when trading/sacrificing eggs at Dr. Scramble.
      2. Automated Test Probe: Queries AskState, inspects DrScrambleTradeInNEW GUI,
         dumps current inventory eggs, and tests AskTradeIn invocation signatures.
      3. One-Click Copy & Save: Allows copying full diagnostic report to clipboard
         or saving directly to a file (dr-scramble-scan.log).
    ========================================================================
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ========================================================================
-- 1. GUI MOUNT (INSTANT ON-SCREEN DISPLAY)
-- ========================================================================
local function getGuiParent()
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    return CoreGui
end

local uiParent = getGuiParent()
local existing = uiParent:FindFirstChild("DrScrambleScannerGui")
if existing then pcall(function() existing:Destroy() end) end

local gui = Instance.new("ScreenGui")
gui.Name = "DrScrambleScannerGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 99999
pcall(function() gui.Parent = uiParent end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 620, 0, 520)
main.Position = UDim2.new(0.5, -310, 0.5, -260)
main.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(120, 70, 200)
mainStroke.Thickness = 1.5

-- Title Bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 38)
titleBar.BackgroundColor3 = Color3.fromRGB(26, 22, 38)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0); titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🌀 Dr. Scramble Trade-In & Remote Spy Scanner"
titleLbl.TextColor3 = Color3.fromRGB(230, 210, 255)
titleLbl.Font = Enum.Font.GothamBold; titleLbl.TextSize = 13
titleLbl.TextXAlignment = Enum.TextXAlignment.Left; titleLbl.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28); closeBtn.Position = UDim2.new(1, -34, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 60)
closeBtn.Text = "X"; closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold; closeBtn.TextSize = 12; closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

-- Status Bar
local statusBar = Instance.new("TextLabel")
statusBar.Size = UDim2.new(1, -24, 0, 20); statusBar.Position = UDim2.new(0, 12, 0, 42)
statusBar.BackgroundTransparency = 1
statusBar.Text = "STATUS: Ready · Click [▶ START SPY] then do a trade in-game, or click [🧪 RUN TEST PROBE]"
statusBar.TextColor3 = Color3.fromRGB(150, 210, 255)
statusBar.Font = Enum.Font.Gotham; statusBar.TextSize = 10
statusBar.TextXAlignment = Enum.TextXAlignment.Left; statusBar.Parent = main

-- Console Log ScrollingFrame
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -24, 1, -120); scroll.Position = UDim2.new(0, 12, 0, 66)
scroll.BackgroundColor3 = Color3.fromRGB(10, 11, 16); scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6; scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new(0, 0, 0, 0); scroll.Parent = main
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)
local scrollStroke = Instance.new("UIStroke", scroll)
scrollStroke.Color = Color3.fromRGB(45, 42, 65); scrollStroke.Thickness = 1

local consoleBox = Instance.new("TextBox")
consoleBox.Size = UDim2.new(1, -12, 1, -12); consoleBox.Position = UDim2.new(0, 6, 0, 6)
consoleBox.BackgroundTransparency = 1
consoleBox.TextColor3 = Color3.fromRGB(215, 225, 245)
consoleBox.Font = Enum.Font.Code; consoleBox.TextSize = 11
consoleBox.TextXAlignment = Enum.TextXAlignment.Left; consoleBox.TextYAlignment = Enum.TextYAlignment.Top
consoleBox.ClearTextOnFocus = false; consoleBox.MultiLine = true; consoleBox.TextEditable = false
consoleBox.Text = "=== DR. SCRAMBLE DIAGNOSTIC SCANNER READY ===\n"
consoleBox.Parent = scroll

-- Controls Bar (Bottom)
local btnContainer = Instance.new("Frame")
btnContainer.Size = UDim2.new(1, -24, 0, 36); btnContainer.Position = UDim2.new(0, 12, 1, -46)
btnContainer.BackgroundTransparency = 1; btnContainer.Parent = main
local btnLayout = Instance.new("UIListLayout")
btnLayout.FillDirection = Enum.FillDirection.Horizontal
btnLayout.Padding = UDim.new(0, 6); btnLayout.Parent = btnContainer

local function makeBtn(text, width, bgColor)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, width, 1, 0); b.BackgroundColor3 = bgColor
    b.Text = text; b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold; b.TextSize = 11; b.Parent = btnContainer
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local spyBtn   = makeBtn("▶ START SPY", 100, Color3.fromRGB(40, 150, 75))
local probeBtn = makeBtn("🧪 RUN TEST PROBE", 125, Color3.fromRGB(115, 60, 185))
local copyBtn  = makeBtn("📋 COPY LOG", 90, Color3.fromRGB(50, 100, 175))
local saveBtn  = makeBtn("💾 SAVE FILE", 90, Color3.fromRGB(160, 95, 40))
local clearBtn = makeBtn("🧹 CLEAR", 70, Color3.fromRGB(60, 62, 75))

-- ========================================================================
-- 2. LOGGING HELPER & VALUE FORMATTER
-- ========================================================================
local logEntries = {}
local isSpyActive = false

local function appendLog(text)
    table.insert(logEntries, text)
    if #logEntries > 400 then table.remove(logEntries, 1) end
    pcall(function()
        consoleBox.Text = table.concat(logEntries, "\n")
        scroll.CanvasPosition = Vector2.new(0, 99999)
    end)
end

local function formatValue(val, depth, visited)
    depth = depth or 0
    visited = visited or {}
    if val == nil then return "nil" end
    local t = typeof(val)
    if t == "string" then
        return '"' .. val .. '"'
    elseif t == "number" or t == "boolean" or t == "EnumItem" then
        return tostring(val)
    elseif t == "Instance" then
        local ok, n = pcall(function() return val:GetFullName() end)
        return "<" .. (ok and n or tostring(val)) .. ">"
    elseif t == "table" then
        if depth >= 5 then return "{...}" end
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

-- ========================================================================
-- 3. NETWORK SPY (HOOKMETAMETHOD __NAMECALL)
-- ========================================================================
local hookInstalled = false
local oldNamecall = nil

local function installSpyHook()
    if hookInstalled then return end
    if typeof(hookmetamethod) ~= "function" then
        appendLog("⚠️ [Spy Warning] hookmetamethod is not supported on this executor. Direct probes will still work!")
        return
    end

    local ok, err = pcall(function()
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if method ~= "FireServer" and method ~= "InvokeServer" then
                return oldNamecall(self, ...)
            end

            local packedArgs = table.pack(...)
            local packedRes = table.pack(oldNamecall(self, ...))

            if isSpyActive then
                pcall(function()
                    local rName = self:GetFullName()
                    -- Filter out noisy engine heartbeats
                    if rName:find("AwayEarnings") or rName:find("Analytics") or rName:find("Ping") then
                        return
                    end

                    -- Check if remote is relevant to Scramble, Trade, Fusery, Egg, or Profile
                    local low = rName:lower()
                    local isRelevant = low:find("scramble") ~= nil
                        or low:find("trade") ~= nil
                        or low:find("sacrifice") ~= nil
                        or low:find("fuse") ~= nil
                        or low:find("egg") ~= nil
                        or low:find("profile") ~= nil

                    local entry = {}
                    table.insert(entry, "--------------------------------------------------")
                    table.insert(entry, string.format("📡 [%s] %s %s", os.date("%H:%M:%S"), method, rName))
                    if isRelevant then
                        table.insert(entry, "⭐ [TARGET RELEVANT REMOTE DETECTED!]")
                    end
                    table.insert(entry, "Arguments (" .. packedArgs.n .. "):")
                    if packedArgs.n == 0 then
                        table.insert(entry, "  none")
                    else
                        for i = 1, packedArgs.n do
                            table.insert(entry, string.format("  [%d] = %s", i, formatValue(packedArgs[i], 1)))
                        end
                    end
                    if method == "InvokeServer" then
                        table.insert(entry, "Return Value:")
                        if packedRes.n == 0 then
                            table.insert(entry, "  none")
                        else
                            for i = 1, packedRes.n do
                                table.insert(entry, string.format("  [%d] = %s", i, formatValue(packedRes[i], 1)))
                            end
                        end
                    end
                    appendLog(table.concat(entry, "\n"))
                end)
            end

            return table.unpack(packedRes, 1, packedRes.n)
        end)
    end)

    if ok then
        hookInstalled = true
        appendLog("✓ Network Spy metamethod hook installed successfully!")
    else
        appendLog("⚠️ Metamethod hook error: " .. tostring(err))
    end
end

spyBtn.MouseButton1Click:Connect(function()
    isSpyActive = not isSpyActive
    if isSpyActive then
        installSpyHook()
        spyBtn.Text = "⏹ STOP SPY"
        spyBtn.BackgroundColor3 = Color3.fromRGB(190, 50, 60)
        statusBar.Text = "STATUS: 🔴 SPY ACTIVE · Go interact with Dr. Scramble in-game now!"
        statusBar.TextColor3 = Color3.fromRGB(255, 130, 130)
        appendLog("\n🔴 [SPY ACTIVATED] Monitoring all InvokeServer / FireServer calls...\nPerform a trade in Dr. Scramble now!")
    else
        spyBtn.Text = "▶ START SPY"
        spyBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 75)
        statusBar.Text = "STATUS: Spy Stopped. Logs retained."
        statusBar.TextColor3 = Color3.fromRGB(150, 210, 255)
        appendLog("\n⏹ [SPY STOPPED] You can now click [📋 COPY LOG] or [💾 SAVE FILE].")
    end
end)

-- ========================================================================
-- 4. AUTOMATED DIAGNOSTIC PROBE (RUN TEST PROBE)
-- ========================================================================
local function runDiagnosticProbe()
    appendLog("\n==================================================")
    appendLog("🧪 STARTING DR. SCRAMBLE DIAGNOSTIC PROBE")
    appendLog("TIMESTAMP: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
    appendLog("PLAYER: " .. LocalPlayer.Name .. " (" .. LocalPlayer.UserId .. ")")
    appendLog("==================================================")

    -- STEP 1: DISCOVER ALL SCRAMBLE & TRADE REMOTES
    appendLog("\n--- [STEP 1] DISCOVERING NETWORK REMOTES ---")
    local net = ReplicatedStorage:FindFirstChild("Packages")
    net = net and net:FindFirstChild("Networking")
    local remotes = {}
    for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
        if desc:IsA("RemoteFunction") or desc:IsA("RemoteEvent") then
            local nLow = desc.Name:lower()
            if nLow:find("scramble") or nLow:find("trade") or nLow:find("sacrifice") or nLow:find("fuse") then
                table.insert(remotes, desc)
            end
        end
    end
    appendLog(string.format("Found %d relevant remotes in ReplicatedStorage:", #remotes))
    for _, r in ipairs(remotes) do
        appendLog(string.format("  • [%s] %s", r.ClassName, r:GetFullName()))
    end

    local rfAskState   = (net and net:FindFirstChild("RF/ScrambleTradeIn/AskState")) or ReplicatedStorage:FindFirstChild("RF/ScrambleTradeIn/AskState", true)
    local rfTradeIn    = (net and net:FindFirstChild("RF/ScrambleTradeIn/AskTradeIn")) or ReplicatedStorage:FindFirstChild("RF/ScrambleTradeIn/AskTradeIn", true)
    local rfAskRefresh = (net and net:FindFirstChild("RF/ScrambleTradeIn/AskRefresh")) or ReplicatedStorage:FindFirstChild("RF/ScrambleTradeIn/AskRefresh", true)
    local rfReveal     = (net and net:FindFirstChild("RF/ScrambleTradeIn/AskFinishReveal")) or ReplicatedStorage:FindFirstChild("RF/ScrambleTradeIn/AskFinishReveal", true)
    local reRotated    = (net and net:FindFirstChild("RE/ScrambleTradeIn/BannerRotated")) or ReplicatedStorage:FindFirstChild("RE/ScrambleTradeIn/BannerRotated", true)

    appendLog("\nDr. Scramble Remotes Direct Check:")
    appendLog("  RF/ScrambleTradeIn/AskState:        " .. (rfAskState and "✓ FOUND" or "❌ NOT FOUND"))
    appendLog("  RF/ScrambleTradeIn/AskTradeIn:      " .. (rfTradeIn and "✓ FOUND" or "❌ NOT FOUND"))
    appendLog("  RF/ScrambleTradeIn/AskRefresh:      " .. (rfAskRefresh and "✓ FOUND" or "❌ NOT FOUND"))
    appendLog("  RF/ScrambleTradeIn/AskFinishReveal: " .. (rfReveal and "✓ FOUND" or "❌ NOT FOUND"))
    appendLog("  RE/ScrambleTradeIn/BannerRotated:   " .. (reRotated and "✓ FOUND" or "❌ NOT FOUND"))

    -- STEP 2: QUERY CURRENT TRADE STATE (AskState)
    appendLog("\n--- [STEP 2] QUERYING RF/ScrambleTradeIn/AskState ---")
    local rawState = nil
    if rfAskState then
        local ok, res = pcall(function() return rfAskState:InvokeServer() end)
        appendLog(string.format("AskState returned ok=%s", tostring(ok)))
        if ok then
            rawState = res
            appendLog("AskState Payload Dump:")
            appendLog(formatValue(res, 1))
        else
            appendLog("AskState Invoke Error: " .. tostring(res))
        end
    else
        appendLog("❌ Remote RF/ScrambleTradeIn/AskState missing!")
    end

    -- STEP 3: SCAN INVENTORY EGGS (BACKPACK + PROFILEMIRROR)
    appendLog("\n--- [STEP 3] SCANNING INVENTORY EGGS ---")
    local ownedEggs = {}
    local seenUids = {}

    local function checkTool(t, src)
        if not t or not t:IsA("Tool") then return end
        local attrs = t:GetAttributes() or {}
        local isGear = attrs.GearName ~= nil or attrs.ItemType == "Gear" or attrs.IsBat == true
        if isGear then return end
        local dName = attrs.DisplayName or t.Name
        local low = dName:lower()
        if low:find("egg") or attrs.Category == "Egg" or t.Name:lower():find("egg") then
            local uid = tostring(attrs.UID or attrs.Uid or attrs.Id or t.Name)
            if not seenUids[uid] then
                seenUids[uid] = true
                table.insert(ownedEggs, {
                    uid = uid,
                    displayName = dName,
                    species = dName,
                    source = src,
                    weight = attrs.Weight or 0,
                    scale = attrs.Scale or 1
                })
            end
        end
    end

    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then for _, t in ipairs(bp:GetChildren()) do checkTool(t, "Backpack") end end
    if LocalPlayer.Character then for _, t in ipairs(LocalPlayer.Character:GetChildren()) do checkTool(t, "Character") end end

    local rfProfile = (net and net:FindFirstChild("RF/ProfileMirror/FetchProfile")) or ReplicatedStorage:FindFirstChild("RF/ProfileMirror/FetchProfile", true)
    if rfProfile then
        local okP, prof = pcall(function() return rfProfile:InvokeServer(LocalPlayer) end)
        if okP and type(prof) == "table" and type(prof.EggInventory) == "table" then
            for eggUid, eggData in pairs(prof.EggInventory) do
                local uidStr = tostring(eggUid)
                if not seenUids[uidStr] and type(eggData) == "table" and eggData.Placement == nil then
                    seenUids[uidStr] = true
                    local sp = eggData.AssetCategory or "Egg"
                    table.insert(ownedEggs, {
                        uid = uidStr,
                        displayName = sp,
                        species = sp,
                        source = "Satchel (ProfileMirror)",
                        weight = eggData.Weight or 0,
                        scale = eggData.AssetScale or 1
                    })
                end
            end
        end
    end

    appendLog(string.format("Found %d unplaced egg(s) in player inventory:", #ownedEggs))
    for i, e in ipairs(ownedEggs) do
        appendLog(string.format("  [%d] %s (UID: %s) · Source: %s · W: %s", i, e.displayName, e.uid, e.source, tostring(e.weight)))
    end

    -- STEP 4: INSPECT DR. SCRAMBLE IN-GAME GUI (DrScrambleTradeInNEW)
    appendLog("\n--- [STEP 4] INSPECTING PLAYERGUI DR. SCRAMBLE GUI ---")
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local scrambleGuis = {}
    if pg then
        for _, c in ipairs(pg:GetChildren()) do
            local low = c.Name:lower()
            if low:find("scramble") or low:find("tradein") then
                table.insert(scrambleGuis, c)
            end
        end
    end

    appendLog(string.format("Found %d Scramble GUI(s) in PlayerGui:", #scrambleGuis))
    for _, g in ipairs(scrambleGuis) do
        appendLog(string.format("  • [%s] %s | Enabled: %s, DisplayOrder: %d", g.ClassName, g.Name, tostring(g.Enabled), g.DisplayOrder))
        for _, desc in ipairs(g:GetDescendants()) do
            if desc:IsA("GuiButton") or desc:IsA("TextLabel") or desc.Name:find("Input") or desc.Name:find("Sacrifice") or desc.Name:find("Trade") then
                local txt = (desc:IsA("TextLabel") or desc:IsA("TextButton")) and (' | Text: "' .. desc.Text .. '"') or ""
                local attrs = desc:GetAttributes() or {}
                local attrStr = ""
                for ak, av in pairs(attrs) do attrStr = attrStr .. string.format(" %s=%s", tostring(ak), tostring(av)) end
                appendLog(string.format("      - [%s] %s (Path: %s)%s%s", desc.ClassName, desc.Name, desc:GetFullName(), txt, attrStr ~= "" and (" | Attrs:" .. attrStr) or ""))
            end
        end
    end

    -- STEP 5: TEST AskTradeIn INVOCATION SIGNATURES
    appendLog("\n--- [STEP 5] TESTING AskTradeIn INVOCATION SIGNATURES ---")
    if not rfTradeIn then
        appendLog("❌ Cannot test AskTradeIn: Remote not found!")
    else
        -- Gather test UIDs (either from ownedEggs or placeholder test UIDs)
        local testUids = {}
        for i = 1, 3 do
            if ownedEggs[i] then
                table.insert(testUids, ownedEggs[i].uid)
            else
                table.insert(testUids, string.rep(tostring(i), 32))
            end
        end
        appendLog("Using Test Egg UIDs: " .. table.concat(testUids, ", "))

        -- Test Signature 1: Array of UIDs
        appendLog("\n>> Test 1: InvokeServer( { uid1, uid2, uid3 } )")
        local ok1, res1 = pcall(function() return rfTradeIn:InvokeServer(testUids) end)
        appendLog(string.format("   Result ok=%s, return: %s", tostring(ok1), formatValue(res1, 1)))

        -- Test Signature 2: Unpacked Tuple
        appendLog("\n>> Test 2: InvokeServer( uid1, uid2, uid3 )")
        local ok2, res2 = pcall(function() return rfTradeIn:InvokeServer(unpack(testUids)) end)
        appendLog(string.format("   Result ok=%s, return: %s", tostring(ok2), formatValue(res2, 1)))

        -- Test Signature 3: Numeric Dictionary
        appendLog("\n>> Test 3: InvokeServer( { [1]=uid1, [2]=uid2, [3]=uid3 } )")
        local ok3, res3 = pcall(function() return rfTradeIn:InvokeServer({ [1]=testUids[1], [2]=testUids[2], [3]=testUids[3] }) end)
        appendLog(string.format("   Result ok=%s, return: %s", tostring(ok3), formatValue(res3, 1)))

        -- Test Signature 4: Named Inputs Dictionary
        appendLog('\n>> Test 4: InvokeServer( { Input1=uid1, Input2=uid2, Input3=uid3 } )')
        local ok4, res4 = pcall(function() return rfTradeIn:InvokeServer({ Input1=testUids[1], Input2=testUids[2], Input3=testUids[3] }) end)
        appendLog(string.format("   Result ok=%s, return: %s", tostring(ok4), formatValue(res4, 1)))

        -- Test Signature 5: Parameterless Invoke
        appendLog("\n>> Test 5: InvokeServer()")
        local ok5, res5 = pcall(function() return rfTradeIn:InvokeServer() end)
        appendLog(string.format("   Result ok=%s, return: %s", tostring(ok5), formatValue(res5, 1)))
    end

    appendLog("\n==================================================")
    appendLog("DIAGNOSTIC PROBE FINISHED!")
    appendLog("Please click [📋 COPY LOG] and paste the report.")
    appendLog("==================================================")
end

probeBtn.MouseButton1Click:Connect(function()
    statusBar.Text = "STATUS: Running Test Probe..."
    statusBar.TextColor3 = Color3.fromRGB(255, 220, 100)
    task.spawn(function()
        runDiagnosticProbe()
        statusBar.Text = "STATUS: Test Probe Complete! Click [📋 COPY LOG]."
        statusBar.TextColor3 = Color3.fromRGB(130, 255, 180)
    end)
end)

-- ========================================================================
-- 5. COPY & SAVE BUTTONS
-- ========================================================================
copyBtn.MouseButton1Click:Connect(function()
    local text = table.concat(logEntries, "\n")
    if typeof(setclipboard) == "function" then
        pcall(function() setclipboard(text) end)
        statusBar.Text = "STATUS: ✓ Copied " .. #text .. " characters to clipboard!"
        statusBar.TextColor3 = Color3.fromRGB(120, 255, 180)
    elseif typeof(to_clipboard) == "function" then
        pcall(function() to_clipboard(text) end)
        statusBar.Text = "STATUS: ✓ Copied to clipboard!"
        statusBar.TextColor3 = Color3.fromRGB(120, 255, 180)
    else
        statusBar.Text = "STATUS: ⚠️ setclipboard not supported on this executor."
        statusBar.TextColor3 = Color3.fromRGB(255, 180, 80)
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    local text = table.concat(logEntries, "\n")
    if typeof(writefile) == "function" then
        local ok, err = pcall(function() writefile("dr-scramble-scan.log", text) end)
        if ok then
            statusBar.Text = "STATUS: ✓ Saved to workspace file: dr-scramble-scan.log"
            statusBar.TextColor3 = Color3.fromRGB(120, 255, 180)
        else
            statusBar.Text = "STATUS: ⚠️ writefile error: " .. tostring(err)
            statusBar.TextColor3 = Color3.fromRGB(255, 180, 80)
        end
    else
        statusBar.Text = "STATUS: ⚠️ writefile not supported on this executor."
        statusBar.TextColor3 = Color3.fromRGB(255, 180, 80)
    end
end)

clearBtn.MouseButton1Click:Connect(function()
    logEntries = {}
    consoleBox.Text = "=== LOG CLEARED ===\n"
    statusBar.Text = "STATUS: Log cleared."
    statusBar.TextColor3 = Color3.fromRGB(180, 200, 230)
end)

-- Auto-run initial discovery on mount
task.spawn(function()
    installSpyHook()
    appendLog("Dr. Scramble Diagnostic Scanner mounted and ready.")
    appendLog("Press [🧪 RUN TEST PROBE] to immediately inspect Dr. Scramble state and test remotes.")
    appendLog("Or press [▶ START SPY] to record live remote traffic while trading in-game.")
end)
