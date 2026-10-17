--[[
    ========================================================================
    DR. SCRAMBLE AUTOTRADE & INVENTORY MATCHER (STANDALONE SUITE)
    ========================================================================
    Purpose:
      1. Live Recipe Inspection: Queries RF/ScrambleTradeIn/AskState and displays
         the 3 required egg slots and rotation countdown timer.
      2. Strict Inventory Scanning (Eggs ONLY, NO Pets):
         - Authoritatively scans ProfileMirror (EggInventory where Placement == nil)
         - Scans in-game trade GUI (PlayerGui.DrScrambleTradeIn.DrScrambleTradeInInventory)
         - Scans physical tools ONLY if strictly recognized as an Egg model
         - Excludes all 200+ pets in Backpack so pet UIDs are NEVER sacrificed!
      3. Live Matching & Display:
         - Requirement list with [✓ OWNED: 1/1] or [⚠️ MISSING: 0/1] badges
         - List of all unplaced matching inventory eggs with weights and 32-hex UIDs
         - Automatically selects lightest copies for sacrifice
      4. Auto-Trade Engine:
         - Automatically executes AskTradeIn -> AskFinishReveal when all 3 slots
           have matching unplaced eggs in inventory
         - Manual 1-click trade button
         - Auto-claims any pending rewards to unlock next recipe
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
-- 1. UTILITIES & NETWORKING
-- ========================================================================

local function getGuiParent()
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    return CoreGui
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

local function formatCommas(num)
    local n = math.round(tonumber(num) or 0)
    local s = tostring(math.abs(n))
    local k
    while true do
        s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return (n < 0 and "-" or "") .. s
end

local function formatPetWeight(weightVal, scaleVal)
    if type(weightVal) == "string" then
        local kgStr = weightVal:match("([%d,]+)%s*[Kk][Gg]")
        if kgStr then
            local numOnly = kgStr:gsub(",", "")
            local n = tonumber(numOnly)
            if n then return formatCommas(n) .. " KG", n end
        end
    end
    local w = tonumber(weightVal) or 0
    local s = tonumber(scaleVal) or 1
    local totalKg = math.round(w * (s * s))
    return formatCommas(totalKg) .. " KG", totalKg
end

local function dumpTbl(tbl, maxDepth, indent)
    maxDepth = maxDepth or 2
    indent = indent or "  "
    if type(tbl) ~= "table" then return tostring(tbl) end
    if maxDepth <= 0 then return "{...}" end
    local lines = {}
    local count = 0
    for k, v in pairs(tbl) do
        count = count + 1
        if count > 20 then
            table.insert(lines, indent .. "... (truncated)")
            break
        end
        if type(v) == "table" then
            table.insert(lines, indent .. tostring(k) .. " = " .. dumpTbl(v, maxDepth - 1, indent .. "  "))
        else
            table.insert(lines, indent .. tostring(k) .. " = " .. tostring(v))
        end
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.sub(indent, 1, math.max(0, #indent - 2)) .. "}"
end

-- ========================================================================
-- 2. SPECIES NORMALIZATION & EXACT ALIASING
-- ========================================================================

local EGG_SPECIES_ALIASES = {
    ["galaxy gecko"] = "cosmic gecko",
    ["cosmic gecko"] = "galaxy gecko",
    ["cyclops gorilla"] = "cosmic gorilla",
    ["cosmic gorilla"] = "cyclops gorilla",
    ["dream axolotl"] = "axolotl",
    ["axolotl"] = "dream axolotl",
    ["holy peacock"] = "peacock",
    ["peacock"] = "holy peacock",
    ["sacred moth"] = "moth",
    ["moth"] = "sacred moth",
    ["winged lamb"] = "lamb",
    ["lamb"] = "winged lamb",
    ["warden"] = "king snake",
    ["king snake"] = "warden",
    ["alien skeleton boss"] = "cosmic skeleton boss",
    ["cosmic skeleton boss"] = "alien skeleton boss",
    ["dark gargoyle"] = "gargoyle",
    ["gargoyle"] = "dark gargoyle",
    ["tyrannosaurusrex"] = "trex",
    ["trex"] = "tyrannosaurusrex",
    ["t-rex"] = "tyrannosaurusrex",
    ["dragon"] = "lava dragon",
    ["lava dragon"] = "dragon",
    ["jellyfish"] = "pure jellyfish",
    ["pure jellyfish"] = "jellyfish",
    ["shark"] = "mutant shark",
    ["mutant shark"] = "shark",
    ["godzilla"] = "kaiju",
    ["kaiju"] = "godzilla",
    ["king kong"] = "gorilla king",
    ["gorilla king"] = "king kong",
    ["fennecfox"] = "fennec",
    ["fennec"] = "fennecfox",
}

local CATEGORY_TO_DISPLAY = {
    ["Galaxy Gecko"] = "Cosmic Gecko",
    ["Cyclops Gorilla"] = "Cosmic Gorilla",
    ["Lamb"] = "Winged Lamb",
    ["Moth"] = "Sacred Moth",
    ["Peacock"] = "Holy Peacock",
    ["Dragon"] = "Lava Dragon",
    ["TyrannosaurusRex"] = "TRex",
    ["Alien Skeleton Boss"] = "Cosmic Skeleton Boss",
    ["Dark Gargoyle"] = "Gargoyle",
    ["Dream Axolotl"] = "Axolotl",
    ["Warden"] = "King Snake",
    ["Jellyfish"] = "Pure Jellyfish",
    ["Shark"] = "Mutant Shark",
}

local function normalizeEggSpecies(s)
    if not s or type(s) ~= "string" then return "" end
    local str = s:lower():gsub("^%b[]%s*", ""):gsub("%s*%b()%s*$", "")
    for _, mWord in ipairs({"rainbow", "golden", "silver", "gold"}) do
        str = str:gsub("^" .. mWord .. "%s+", "")
    end
    str = str:gsub("%s*egg%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    return str
end

local function matchEggSpecies(nameA, nameB)
    local a = normalizeEggSpecies(nameA)
    local b = normalizeEggSpecies(nameB)
    if a == "" or b == "" then return false end
    if a == b then return true end
    if EGG_SPECIES_ALIASES[a] == b or EGG_SPECIES_ALIASES[b] == a then return true end
    return false
end

local function getDisplayEggName(rawName)
    local s = tostring(rawName or "")
    if CATEGORY_TO_DISPLAY[s] then return CATEGORY_TO_DISPLAY[s] end
    local clean = normalizeEggSpecies(s)
    for cat, disp in pairs(CATEGORY_TO_DISPLAY) do
        if normalizeEggSpecies(cat) == clean then return disp end
    end
    return s
end

-- ========================================================================
-- 3. STATE & DATA STORES
-- ========================================================================

local scrambleRequirements = {} -- { { slot="1", species="Galaxy Gecko", rawName="Galaxy Gecko", count=1 }, ... }
local ownedMatchingEggs    = {} -- list of all unplaced inventory eggs matching any active requirement
local allInventoryEggs     = {} -- all unplaced eggs found in player satchel
local isAutoTradeEnabled   = true
local isTradingIn          = false
local serverExpiresAt      = nil
local scrambleBannerName   = "Dr. Scramble"
local lastTradeAttempt     = 0
local lastInventoryScan    = 0

local rfAskState   = getNetRemote("RF/ScrambleTradeIn/AskState")
local rfTradeIn    = getNetRemote("RF/ScrambleTradeIn/AskTradeIn") or getNetRemote("RF/ScrambleTradeIn/TradeIn")
local rfReveal     = getNetRemote("RF/ScrambleTradeIn/AskFinishReveal")
local reRotated    = getNetRemote("RE/ScrambleTradeIn/BannerRotated")
local rfProfile    = getNetRemote("RF/ProfileMirror/FetchProfile")

-- Forward declarations
local updateUI
local queryScrambleState
local scanInventoryEggs
local executeTradeIn
local checkAndAutoTrade

-- ========================================================================
-- 4. GUI CONSTRUCTION
-- ========================================================================

local uiParent = getGuiParent()
local existing = uiParent:FindFirstChild("ScrambleAutoTradeGui")
if existing then pcall(function() existing:Destroy() end) end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ScrambleAutoTradeGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
pcall(function() screenGui.Parent = uiParent end)
if not screenGui.Parent then screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 560, 0, 580)
main.Position = UDim2.new(0.5, -280, 0.5, -290)
main.BackgroundColor3 = Color3.fromRGB(15, 17, 24)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(130, 80, 220)
mainStroke.Thickness = 1.5

-- Title Bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 38)
titleBar.BackgroundColor3 = Color3.fromRGB(24, 22, 36)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -70, 1, 0); titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🌀 Dr. Scramble Auto-Trade & Inventory Matcher"
titleLbl.TextColor3 = Color3.fromRGB(235, 220, 255)
titleLbl.Font = Enum.Font.GothamBold; titleLbl.TextSize = 13
titleLbl.TextXAlignment = Enum.TextXAlignment.Left; titleLbl.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26); closeBtn.Position = UDim2.new(1, -32, 0, 6)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 60)
closeBtn.Text = "X"; closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold; closeBtn.TextSize = 12; closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function() screenGui:Destroy() end)

-- Controls Bar (Row below Title)
local controlsBar = Instance.new("Frame")
controlsBar.Size = UDim2.new(1, -24, 0, 32); controlsBar.Position = UDim2.new(0, 12, 0, 44)
controlsBar.BackgroundTransparency = 1; controlsBar.Parent = main

local timerBadge = Instance.new("TextLabel")
timerBadge.Size = UDim2.new(0, 220, 1, 0); timerBadge.Position = UDim2.new(0, 0, 0, 0)
timerBadge.BackgroundColor3 = Color3.fromRGB(25, 29, 44); timerBadge.BorderSizePixel = 0
timerBadge.Text = "⏳ Syncing server timer..."
timerBadge.TextColor3 = Color3.fromRGB(255, 215, 120); timerBadge.Font = Enum.Font.GothamBold; timerBadge.TextSize = 11
timerBadge.Parent = controlsBar
Instance.new("UICorner", timerBadge).CornerRadius = UDim.new(0, 6)
local tbStroke = Instance.new("UIStroke", timerBadge)
tbStroke.Color = Color3.fromRGB(60, 70, 100); tbStroke.Thickness = 1

local autoTradeToggleBtn = Instance.new("TextButton")
autoTradeToggleBtn.Size = UDim2.new(0, 115, 1, 0); autoTradeToggleBtn.Position = UDim2.new(0, 228, 0, 0)
autoTradeToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 115, 70)
autoTradeToggleBtn.Text = "[ON] Auto-Trade"
autoTradeToggleBtn.TextColor3 = Color3.fromRGB(160, 255, 190)
autoTradeToggleBtn.Font = Enum.Font.GothamBold; autoTradeToggleBtn.TextSize = 10
autoTradeToggleBtn.Parent = controlsBar
Instance.new("UICorner", autoTradeToggleBtn).CornerRadius = UDim.new(0, 6)

local refreshBtn = Instance.new("TextButton")
refreshBtn.Size = UDim2.new(0, 36, 1, 0); refreshBtn.Position = UDim2.new(0, 350, 0, 0)
refreshBtn.BackgroundColor3 = Color3.fromRGB(38, 55, 85)
refreshBtn.Text = "🔄"; refreshBtn.TextColor3 = Color3.new(1, 1, 1)
refreshBtn.Font = Enum.Font.GothamBold; refreshBtn.TextSize = 13
refreshBtn.Parent = controlsBar
Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 6)

local manualTradeBtn = Instance.new("TextButton")
manualTradeBtn.Size = UDim2.new(1, -394, 1, 0); manualTradeBtn.Position = UDim2.new(0, 394, 0, 0)
manualTradeBtn.BackgroundColor3 = Color3.fromRGB(50, 48, 65)
manualTradeBtn.Text = "⚡ Trade (0/3)"
manualTradeBtn.TextColor3 = Color3.fromRGB(160, 165, 185)
manualTradeBtn.Font = Enum.Font.GothamBold; manualTradeBtn.TextSize = 10
manualTradeBtn.Parent = controlsBar
Instance.new("UICorner", manualTradeBtn).CornerRadius = UDim.new(0, 6)
local mtStroke = Instance.new("UIStroke", manualTradeBtn)
mtStroke.Color = Color3.fromRGB(65, 60, 85); mtStroke.Thickness = 1

-- Body Container (Vertical Cards Layout)
local body = Instance.new("ScrollingFrame")
body.Size = UDim2.new(1, -24, 1, -88); body.Position = UDim2.new(0, 12, 0, 80)
body.BackgroundColor3 = Color3.fromRGB(12, 13, 19); body.BorderSizePixel = 0
body.ScrollBarThickness = 5; body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.CanvasSize = UDim2.new(0, 0, 0, 0); body.Parent = main
Instance.new("UICorner", body).CornerRadius = UDim.new(0, 8)
local bodyStroke = Instance.new("UIStroke", body)
bodyStroke.Color = Color3.fromRGB(38, 42, 60); bodyStroke.Thickness = 1

local bodyLayout = Instance.new("UIListLayout")
bodyLayout.Padding = UDim.new(0, 8)
bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
bodyLayout.Parent = body
local bodyPad = Instance.new("UIPadding", body)
bodyPad.PaddingTop = UDim.new(0, 6); bodyPad.PaddingBottom = UDim.new(0, 8)
bodyPad.PaddingLeft = UDim.new(0, 6); bodyPad.PaddingRight = UDim.new(0, 6)

-- Helper to make section cards
local function createCard(titleText, defaultHeight, layoutOrder)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 0, defaultHeight)
    card.BackgroundColor3 = Color3.fromRGB(20, 23, 34)
    card.BorderSizePixel = 0
    card.LayoutOrder = layoutOrder
    card.Parent = body
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 7)
    local cStroke = Instance.new("UIStroke", card)
    cStroke.Color = Color3.fromRGB(42, 48, 70); cStroke.Thickness = 1

    local hFrame = Instance.new("Frame")
    hFrame.Size = UDim2.new(1, 0, 0, 24); hFrame.BackgroundColor3 = Color3.fromRGB(28, 32, 48)
    hFrame.BorderSizePixel = 0; hFrame.Parent = card
    Instance.new("UICorner", hFrame).CornerRadius = UDim.new(0, 7)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -16, 1, 0); lbl.Position = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1; lbl.Text = titleText
    lbl.TextColor3 = Color3.fromRGB(215, 230, 255); lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 10
    lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = hFrame

    return card
end

-- CARD 1: ACTIVE RECIPE REQUIREMENTS
local cardReqs = createCard("📋 DR. SCRAMBLE RECIPE REQUIREMENTS", 140, 1)
local reqsContainer = Instance.new("Frame")
reqsContainer.Size = UDim2.new(1, -12, 1, -30); reqsContainer.Position = UDim2.new(0, 6, 0, 26)
reqsContainer.BackgroundTransparency = 1; reqsContainer.Parent = cardReqs
local reqsLayout = Instance.new("UIListLayout")
reqsLayout.Padding = UDim.new(0, 4)
reqsLayout.SortOrder = Enum.SortOrder.LayoutOrder
reqsLayout.Parent = reqsContainer

-- CARD 2: MATCHING INVENTORY EGGS
local cardInv = createCard("🎒 MATCHING UNPLACED EGGS IN INVENTORY (ELIGIBLE FOR SACRIFICE)", 150, 2)
local invScroll = Instance.new("ScrollingFrame")
invScroll.Size = UDim2.new(1, -12, 1, -30); invScroll.Position = UDim2.new(0, 6, 0, 26)
invScroll.BackgroundColor3 = Color3.fromRGB(14, 16, 24); invScroll.BorderSizePixel = 0
invScroll.ScrollBarThickness = 4; invScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
invScroll.CanvasSize = UDim2.new(0, 0, 0, 0); invScroll.Parent = cardInv
Instance.new("UICorner", invScroll).CornerRadius = UDim.new(0, 5)
local invLayout = Instance.new("UIListLayout")
invLayout.Padding = UDim.new(0, 3)
invLayout.SortOrder = Enum.SortOrder.LayoutOrder
invLayout.Parent = invScroll
local invPad = Instance.new("UIPadding", invScroll)
invPad.PaddingTop = UDim.new(0, 4); invPad.PaddingBottom = UDim.new(0, 4)
invPad.PaddingLeft = UDim.new(0, 4); invPad.PaddingRight = UDim.new(0, 4)

-- CARD 3: ACTIVITY & LOG TERMINAL
local cardLog = createCard("📜 LIVE TELEMETRY & NETWORK LOG", 140, 3)

local copyLogBtn = Instance.new("TextButton")
copyLogBtn.Size = UDim2.new(0, 50, 0, 18); copyLogBtn.Position = UDim2.new(1, -114, 0, 3)
copyLogBtn.BackgroundColor3 = Color3.fromRGB(45, 75, 115)
copyLogBtn.Text = "Copy"; copyLogBtn.TextColor3 = Color3.fromRGB(220, 240, 255)
copyLogBtn.Font = Enum.Font.GothamBold; copyLogBtn.TextSize = 9; copyLogBtn.Parent = cardLog
Instance.new("UICorner", copyLogBtn).CornerRadius = UDim.new(0, 4)

local clearLogBtn = Instance.new("TextButton")
clearLogBtn.Size = UDim2.new(0, 50, 0, 18); clearLogBtn.Position = UDim2.new(1, -58, 0, 3)
clearLogBtn.BackgroundColor3 = Color3.fromRGB(55, 60, 75)
clearLogBtn.Text = "Clear"; clearLogBtn.TextColor3 = Color3.fromRGB(200, 215, 235)
clearLogBtn.Font = Enum.Font.GothamBold; clearLogBtn.TextSize = 9; clearLogBtn.Parent = cardLog
Instance.new("UICorner", clearLogBtn).CornerRadius = UDim.new(0, 4)

local logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -12, 1, -30); logScroll.Position = UDim2.new(0, 6, 0, 26)
logScroll.BackgroundColor3 = Color3.fromRGB(10, 11, 16); logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 4; logScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0); logScroll.Parent = cardLog
Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 5)

local logTextLabel = Instance.new("TextLabel")
logTextLabel.Size = UDim2.new(1, -8, 0, 0); logTextLabel.Position = UDim2.new(0, 4, 0, 2)
logTextLabel.BackgroundTransparency = 1
logTextLabel.TextColor3 = Color3.fromRGB(195, 215, 245)
logTextLabel.Font = Enum.Font.Code; logTextLabel.TextSize = 10
logTextLabel.TextXAlignment = Enum.TextXAlignment.Left; logTextLabel.TextYAlignment = Enum.TextYAlignment.Top
logTextLabel.AutomaticSize = Enum.AutomaticSize.Y; logTextLabel.Parent = logScroll

local logEntries = {}
local MAX_LOGS = 180

local function logMsg(msg, color)
    local ts = os.date("%H:%M:%S")
    local line = ("[%s] %s"):format(ts, tostring(msg))
    print("[ScrambleAutoTrade] " .. line)
    table.insert(logEntries, line)
    if #logEntries > MAX_LOGS then table.remove(logEntries, 1) end
    logTextLabel.Text = table.concat(logEntries, "\n")
    pcall(function() logScroll.CanvasPosition = Vector2.new(0, 99999) end)
end

copyLogBtn.MouseButton1Click:Connect(function()
    local full = table.concat(logEntries, "\n")
    local ok = false
    if typeof(setclipboard) == "function" then
        ok = pcall(setclipboard, full)
    elseif typeof(toclipboard) == "function" then
        ok = pcall(toclipboard, full)
    end
    if ok then
        copyLogBtn.Text = "✓ Copied"
        logMsg("📋 Activity log copied to system clipboard!", Color3.fromRGB(140, 255, 180))
        task.delay(1.5, function() copyLogBtn.Text = "Copy" end)
    else
        logMsg("ℹ️ Clipboard not supported. Printed to developer console (F9).", Color3.fromRGB(255, 200, 100))
    end
end)

clearLogBtn.MouseButton1Click:Connect(function()
    logEntries = {}
    logTextLabel.Text = "[Log cleared]"
end)

autoTradeToggleBtn.MouseButton1Click:Connect(function()
    isAutoTradeEnabled = not isAutoTradeEnabled
    if isAutoTradeEnabled then
        autoTradeToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 115, 70)
        autoTradeToggleBtn.Text = "[ON] Auto-Trade"
        autoTradeToggleBtn.TextColor3 = Color3.fromRGB(160, 255, 190)
        logMsg("✓ Auto-Trade: ENABLED (Will auto-trade immediately when 3/3 matching eggs are in inventory)", Color3.fromRGB(140, 255, 180))
        task.defer(function()
            checkAndAutoTrade("ToggleOn")
        end)
    else
        autoTradeToggleBtn.BackgroundColor3 = Color3.fromRGB(55, 58, 70)
        autoTradeToggleBtn.Text = "[OFF] Auto-Trade"
        autoTradeToggleBtn.TextColor3 = Color3.fromRGB(180, 185, 200)
        logMsg("ℹ️ Auto-Trade: DISABLED (Manual trade button available)", Color3.fromRGB(200, 215, 235))
    end
end)

refreshBtn.MouseButton1Click:Connect(function()
    logMsg("🔄 Manual refresh requested...", Color3.fromRGB(180, 210, 255))
    queryScrambleState()
    scanInventoryEggs(true)
    updateUI()
    task.defer(function()
        checkAndAutoTrade("ManualRefresh")
    end)
end)

manualTradeBtn.MouseButton1Click:Connect(function()
    executeTradeIn(false)
end)

-- ========================================================================
-- 5. AUTHORITATIVE INVENTORY SCANNER (EGGS ONLY, STRICTLY NO PETS!)
-- ========================================================================

scanInventoryEggs = function(force)
    -- Cache check: prevent redundant FetchProfile spam within 1 second
    if not force and (os.clock() - lastInventoryScan) < 1.0 and #allInventoryEggs > 0 then
        return allInventoryEggs, ownedMatchingEggs
    end
    lastInventoryScan = os.clock()

    local eggs = {}
    local seenUids = {}

    -- 1. ProfileMirror EggInventory (Ground truth for unplaced eggs in satchel)
    if not rfProfile then rfProfile = getNetRemote("RF/ProfileMirror/FetchProfile") end
    if rfProfile then
        local okP, prof = pcall(function() return rfProfile:InvokeServer(LocalPlayer) end)
        if not okP or type(prof) ~= "table" or type(prof.EggInventory) ~= "table" then
            okP, prof = pcall(function() return rfProfile:InvokeServer() end)
        end

        if okP and type(prof) == "table" and type(prof.EggInventory) == "table" then
            for eggUid, eggData in pairs(prof.EggInventory) do
                local uidStr = tostring(eggUid)
                -- STRICT FILTER: Only unplaced eggs (Placement == nil)
                if not seenUids[uidStr] and type(eggData) == "table" and eggData.Placement == nil then
                    seenUids[uidStr] = true
                    local cat = tostring(eggData.AssetCategory or "Egg")
                    local disp = getDisplayEggName(cat)
                    local wStr, wNum = formatPetWeight(eggData.Weight or 0, eggData.AssetScale or 1)
                    table.insert(eggs, {
                        uid = uidStr,
                        species = cat,
                        category = cat,
                        displayName = disp,
                        weightStr = wStr,
                        weightNum = wNum,
                        source = "Satchel"
                    })
                end
            end
        end
    end

    -- 2. DrScrambleTradeIn In-Game GUI inspection (PlayerGui)
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local scrGui = pg and (pg:FindFirstChild("DrScrambleTradeIn") or pg:FindFirstChild("DrScrambleTradeInNEW"))
        local invFrame = scrGui and scrGui:FindFirstChild("DrScrambleTradeInInventory", true)
        local scroll = invFrame and invFrame:FindFirstChild("ScrollingFrame", true)
        if scroll then
            for _, btn in ipairs(scroll:GetChildren()) do
                if (btn:IsA("ImageButton") or btn:IsA("TextButton")) and btn.Name:match("^Egg_(%x+)") then
                    local rawUid = btn.Name:gsub("^Egg_", "")
                    if rawUid and #rawUid == 32 and not seenUids[rawUid] then
                        local spName = nil
                        for _, d in ipairs(btn:GetDescendants()) do
                            if d:IsA("TextLabel") and d.Text ~= "" and d.Text ~= "Unplaced" and not d.Text:match("^%b()") then
                                local low = d.Text:lower()
                                if not low:match("select") and not low:match("pet name") then
                                    spName = d.Text
                                    break
                                end
                            end
                        end
                        if spName then
                            seenUids[rawUid] = true
                            local cleanSp = spName:gsub("%s*Egg%s*$", "")
                            table.insert(eggs, {
                                uid = rawUid,
                                species = cleanSp,
                                category = cleanSp,
                                displayName = spName,
                                weightStr = "0 KG",
                                weightNum = 0,
                                source = "TradeGui"
                            })
                        end
                    end
                end
            end
        end
    end)

    -- 3. STRICT PHYSICAL TOOL INSPECTION (ONLY actual Egg tools, NEVER pets!)
    local function checkTool(t, src)
        if not t or not t:IsA("Tool") then return end
        local attrs = t:GetAttributes() or {}
        if attrs.GearName ~= nil or attrs.ItemType == "Gear" or attrs.IsBat == true then return end

        local dName = tostring(attrs.DisplayName or t.Name)
        local cat = tostring(attrs.Category or "")
        local lowD = dName:lower()
        local lowT = t.Name:lower()
        local lowC = cat:lower()

        -- STRICT EGG VALIDATION: Must contain the word "egg" in name/displayName or Category=="Egg"
        -- This guarantees that pets (e.g. Snowy Owl, Cosmic Gecko with ItemType="Asset") are NEVER misclassified as eggs!
        local isEgg = lowD:find("egg") ~= nil
            or lowT:find("egg") ~= nil
            or lowC == "egg"
            or attrs.ItemType == "Egg"
            or attrs.IsEgg == true

        if not isEgg then return end

        local rawUid = attrs.UID or attrs.Uid or attrs.Id or attrs.EggUID
        if not rawUid then
            local chUid = t:FindFirstChild("UID") or t:FindFirstChild("EggUID")
            if chUid and chUid:IsA("ValueBase") then rawUid = chUid.Value end
        end

        local uidStr = rawUid and tostring(rawUid) or nil
        if uidStr and #uidStr == 32 and not seenUids[uidStr] then
            seenUids[uidStr] = true
            local wStr, wNum = formatPetWeight(attrs.Weight, attrs.Scale)
            local cleanSp = dName:gsub("%s*[Ee]gg%s*$", "")
            table.insert(eggs, {
                uid = uidStr,
                species = cleanSp,
                category = cat ~= "" and cat or cleanSp,
                displayName = dName,
                weightStr = wStr,
                weightNum = wNum,
                source = src
            })
        end
    end

    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then for _, t in ipairs(bp:GetChildren()) do checkTool(t, "Backpack") end end
    if LocalPlayer.Character then for _, t in ipairs(LocalPlayer.Character:GetChildren()) do checkTool(t, "Character") end end

    -- Sort lightest to heaviest
    table.sort(eggs, function(a, b) return (a.weightNum or 0) < (b.weightNum or 0) end)
    allInventoryEggs = eggs

    -- Filter to eggs matching active requirements
    local matching = {}
    for _, egg in ipairs(allInventoryEggs) do
        for slotIdx, req in ipairs(scrambleRequirements) do
            if matchEggSpecies(egg.species, req.species)
               or (egg.category and egg.category ~= "" and matchEggSpecies(egg.category, req.species))
               or (egg.displayName and egg.displayName ~= "" and matchEggSpecies(egg.displayName, req.species)) then
                local copy = table.clone(egg)
                copy.matchedSlot = slotIdx
                copy.matchedReq = req.species
                table.insert(matching, copy)
                break
            end
        end
    end

    ownedMatchingEggs = matching
    return eggs, matching
end

-- ========================================================================
-- 6. SCRAMBLE STATE & REQUIREMENTS QUERY
-- ========================================================================

local function parseScrambleRequirements(state)
    local reqs = {}

    local function addReq(slotKey, speciesName, count)
        if not speciesName or type(speciesName) ~= "string" or speciesName == "" then return end
        local lowCheck = speciesName:lower():gsub("%s+", "")
        if lowCheck == "petname" or lowCheck == "eggname" or lowCheck == "rarity" then return end
        local clean = speciesName:gsub("^%b[]%s*", "")
        for _, mWord in ipairs({"Rainbow", "Golden", "Silver", "Gold"}) do
            clean = clean:gsub("^" .. mWord .. "%s+", "")
        end
        table.insert(reqs, {
            slot = tostring(slotKey),
            species = clean,
            rawName = speciesName,
            count = tonumber(count) or 1
        })
    end

    if type(state) == "table" then
        local container = state.Requirements or state.Recipe or state.Inputs or state.Slots or state.Eggs or state.CurrentTrade or state.Trade or state.SacrificeInputs or state.Banner or state
        if type(container) == "table" then
            for k, v in pairs(container) do
                if type(v) == "string" then
                    addReq(k, v, 1)
                elseif type(v) == "table" then
                    local sp = v.Species or v.Egg or v.EggType or v.Name or v.Category or v.DisplayName or v.Target or v.Type or v.EggName
                    local c = v.Count or v.Amount or v.Required or v.Quantity or 1
                    if sp then addReq(k, sp, c) end
                end
            end
        end
    end

    -- Fallback: Inspect PlayerGui DrScrambleTradeIn GUI if AskState container empty
    if #reqs == 0 then
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local gui = pg and (pg:FindFirstChild("DrScrambleTradeIn") or pg:FindFirstChild("DrScrambleTradeInNEW"))
        local inputs = gui and gui:FindFirstChild("SacrificeInputs", true)
        if inputs then
            for idx = 1, 3 do
                local inp = inputs:FindFirstChild("Input" .. idx) or inputs:FindFirstChild(tostring(idx))
                if inp then
                    local spName = nil
                    local attrs = inp:GetAttributes() or {}
                    spName = attrs.Egg or attrs.Species or attrs.DisplayName or attrs.Category
                    if not spName then
                        local emptyNode = inp:FindFirstChild("Empty", true)
                        local nameLbl = emptyNode and (emptyNode:FindFirstChild("Name") or emptyNode:FindFirstChild("Title") or emptyNode:FindFirstChild("EggName"))
                        if nameLbl and nameLbl:IsA("TextLabel") and nameLbl.Text ~= "" then
                            local nTxt = nameLbl.Text:lower():gsub("%s+", "")
                            if nTxt ~= "petname" and nTxt ~= "eggname" and nTxt ~= "rarity" then
                                spName = nameLbl.Text
                            end
                        end
                    end
                    if spName then addReq(idx, spName, 1) end
                end
            end
        end
    end

    table.sort(reqs, function(a, b)
        local numA = tonumber(a.slot) or 99
        local numB = tonumber(b.slot) or 99
        return numA < numB
    end)

    return reqs
end

queryScrambleState = function()
    if not rfAskState then rfAskState = getNetRemote("RF/ScrambleTradeIn/AskState") end
    local ok, state = false, nil
    if rfAskState then
        ok, state = pcall(function() return rfAskState:InvokeServer() end)
    end

    if ok and type(state) == "table" then
        logMsg("✓ [AskState] Received active state from server", Color3.fromRGB(140, 255, 180))
        scrambleBannerName = state.BannerDisplayName or state.BannerId or "Dr. Scramble"

        -- Unclaimed PendingReward Auto-Claim
        if not rfReveal then rfReveal = getNetRemote("RF/ScrambleTradeIn/AskFinishReveal") end
        if state.PendingReward and type(state.PendingReward) == "table" and rfReveal then
            logMsg("🎁 Detected unclaimed reward from previous trade! Calling AskFinishReveal...", Color3.fromRGB(255, 215, 120))
            pcall(function() rfReveal:InvokeServer() end)
            task.wait(0.4)
            local ok2, state2 = pcall(function() return rfAskState:InvokeServer() end)
            if ok2 and type(state2) == "table" then state = state2 end
        end

        -- Calculate exact expiry timestamp
        local exp = state.ExpiresAt or state.NextRefresh or state.ResetTime or state.EndTime
        if tonumber(exp) and tonumber(exp) > os.time() then
            serverExpiresAt = tonumber(exp)
        elseif tonumber(state.SecondsUntilRotation) then
            serverExpiresAt = os.time() + math.floor(tonumber(state.SecondsUntilRotation))
        elseif tonumber(state.TimeLeft) or tonumber(state.Remaining) then
            serverExpiresAt = os.time() + (tonumber(state.TimeLeft) or tonumber(state.Remaining))
        else
            local secsIntoHour = os.time() % 3600
            serverExpiresAt = os.time() + (3600 - secsIntoHour)
        end
    else
        logMsg("⚠️ [AskState] Remote returned: " .. tostring(state) .. " (using fallback)", Color3.fromRGB(255, 180, 80))
        local secsIntoHour = os.time() % 3600
        serverExpiresAt = os.time() + (3600 - secsIntoHour)
    end

    scrambleRequirements = parseScrambleRequirements(state)
    logMsg(string.format("📋 Loaded %d recipe requirements for [%s]:", #scrambleRequirements, scrambleBannerName), Color3.fromRGB(180, 220, 255))
    for i, req in ipairs(scrambleRequirements) do
        local disp = getDisplayEggName(req.species)
        logMsg(string.format("  Slot #%s: %s (internal: %s)", tostring(req.slot), disp, req.species), Color3.fromRGB(200, 225, 255))
    end
end

-- ========================================================================
-- 7. UI RENDERER (REQUIREMENTS & INVENTORY LIST)
-- ========================================================================

local function getTradeCandidates()
    local finalUids = {}
    local usedUids = {}
    local readySlotsCount = 0
    local slotMatches = {}
    local totalReq = #scrambleRequirements

    if totalReq == 0 then
        return false, finalUids, 0, 0, slotMatches, usedUids
    end

    for slotIdx, req in ipairs(scrambleRequirements) do
        slotMatches[slotIdx] = {}
        for _, egg in ipairs(allInventoryEggs) do
            local matches = matchEggSpecies(egg.species, req.species)
                or (egg.category and egg.category ~= "" and matchEggSpecies(egg.category, req.species))
                or (egg.displayName and egg.displayName ~= "" and matchEggSpecies(egg.displayName, req.species))
            if matches then
                table.insert(slotMatches[slotIdx], egg)
                if not finalUids[slotIdx] and not usedUids[egg.uid] then
                    finalUids[slotIdx] = egg.uid
                    usedUids[egg.uid] = true
                end
            end
        end
        if finalUids[slotIdx] then
            readySlotsCount = readySlotsCount + 1
        end
    end

    local allReady = (readySlotsCount == totalReq and totalReq > 0)
    return allReady, finalUids, readySlotsCount, totalReq, slotMatches, usedUids
end

updateUI = function()
    -- Clear current rows
    for _, c in ipairs(reqsContainer:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
    end
    for _, c in ipairs(invScroll:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
    end

    -- Match unplaced eggs to slots (1 distinct egg per slot)
    local allReady, chosenUids, readySlotsCount, totalReq, slotMatches, usedEggUids = getTradeCandidates()

    -- 1. RENDER REQUIREMENTS
    if #scrambleRequirements == 0 then
        local emptyLbl = Instance.new("TextLabel")
        emptyLbl.Size = UDim2.new(1, 0, 0, 28); emptyLbl.BackgroundTransparency = 1
        emptyLbl.Text = "ℹ️ No requirements loaded. Click 🔄 to query server."; emptyLbl.TextColor3 = Color3.fromRGB(180, 190, 210)
        emptyLbl.Font = Enum.Font.Gotham; emptyLbl.TextSize = 10; emptyLbl.Parent = reqsContainer
    else
        for slotIdx, req in ipairs(scrambleRequirements) do
            local isOwned = (chosenUids[slotIdx] ~= nil)
            local totalCandidates = #slotMatches[slotIdx]
            local dispName = getDisplayEggName(req.species)

            local row = Instance.new("Frame")
            row.Size = UDim2.new(1, 0, 0, 32)
            row.BackgroundColor3 = isOwned and Color3.fromRGB(22, 36, 28) or Color3.fromRGB(34, 25, 30)
            row.BorderSizePixel = 0; row.LayoutOrder = slotIdx; row.Parent = reqsContainer
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
            local rStroke = Instance.new("UIStroke", row)
            rStroke.Color = isOwned and Color3.fromRGB(45, 130, 85) or Color3.fromRGB(120, 55, 65)
            rStroke.Thickness = 1

            -- Left color strip
            local strip = Instance.new("Frame")
            strip.Size = UDim2.new(0, 4, 1, -6); strip.Position = UDim2.new(0, 3, 0, 3)
            strip.BackgroundColor3 = isOwned and Color3.fromRGB(70, 230, 140) or Color3.fromRGB(255, 110, 80)
            strip.BorderSizePixel = 0; strip.Parent = row
            Instance.new("UICorner", strip).CornerRadius = UDim.new(0, 2)

            -- Text details
            local titleL = Instance.new("TextLabel")
            titleL.Size = UDim2.new(1, -110, 0, 16); titleL.Position = UDim2.new(0, 14, 0, 2)
            titleL.BackgroundTransparency = 1
            titleL.Text = string.format("Slot #%s: %s (x%d)", tostring(req.slot), dispName, req.count)
            titleL.TextColor3 = isOwned and Color3.fromRGB(220, 255, 235) or Color3.fromRGB(255, 230, 235)
            titleL.Font = Enum.Font.GothamBold; titleL.TextSize = 10
            titleL.TextXAlignment = Enum.TextXAlignment.Left; titleL.Parent = row

            local subL = Instance.new("TextLabel")
            subL.Size = UDim2.new(1, -110, 0, 12); subL.Position = UDim2.new(0, 14, 0, 17)
            subL.BackgroundTransparency = 1
            subL.Text = string.format("Internal: %s  •  Inventory: %d eligible copy/copies", req.species, totalCandidates)
            subL.TextColor3 = isOwned and Color3.fromRGB(150, 225, 185) or Color3.fromRGB(200, 160, 170)
            subL.Font = Enum.Font.Gotham; subL.TextSize = 8.5
            subL.TextXAlignment = Enum.TextXAlignment.Left; subL.Parent = row

            -- Status badge
            local badge = Instance.new("TextLabel")
            badge.Size = UDim2.new(0, 82, 0, 20); badge.Position = UDim2.new(1, -88, 0.5, -10)
            badge.BackgroundColor3 = isOwned and Color3.fromRGB(28, 75, 48) or Color3.fromRGB(75, 30, 36)
            badge.Text = isOwned and "✓ OWNED" or "⚠️ MISSING"
            badge.TextColor3 = isOwned and Color3.fromRGB(130, 255, 185) or Color3.fromRGB(255, 160, 140)
            badge.Font = Enum.Font.GothamBold; badge.TextSize = 9; badge.Parent = row
            Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 4)
        end
    end

    -- 2. RENDER MATCHING INVENTORY EGGS
    if #ownedMatchingEggs == 0 then
        local noEggs = Instance.new("TextLabel")
        noEggs.Size = UDim2.new(1, -8, 0, 32); noEggs.BackgroundTransparency = 1
        noEggs.Text = "ℹ️ No unplaced matching eggs found in inventory satchel. Farm or collect required eggs!"; noEggs.TextColor3 = Color3.fromRGB(180, 190, 210)
        noEggs.Font = Enum.Font.Gotham; noEggs.TextSize = 9.5; noEggs.Parent = invScroll
    else
        for idx, egg in ipairs(ownedMatchingEggs) do
            local isChosen = (usedEggUids[egg.uid] == true)
            local shortUid = (#egg.uid > 12) and (egg.uid:sub(1, 10) .. "...") or egg.uid

            local card = Instance.new("Frame")
            card.Size = UDim2.new(1, 0, 0, 28)
            card.BackgroundColor3 = isChosen and Color3.fromRGB(26, 42, 34) or Color3.fromRGB(20, 24, 34)
            card.BorderSizePixel = 0; card.LayoutOrder = idx; card.Parent = invScroll
            Instance.new("UICorner", card).CornerRadius = UDim.new(0, 5)
            local cStr = Instance.new("UIStroke", card)
            cStr.Color = isChosen and Color3.fromRGB(50, 150, 95) or Color3.fromRGB(36, 44, 62); cStr.Thickness = 1

            local lineLbl = Instance.new("TextLabel")
            lineLbl.Size = UDim2.new(1, -95, 1, 0); lineLbl.Position = UDim2.new(0, 8, 0, 0)
            lineLbl.BackgroundTransparency = 1
            lineLbl.Text = string.format("#%d  🥚 %s  •  ⚖️ %s  •  [%s] (%s)", idx, egg.displayName, egg.weightStr, shortUid, egg.source)
            lineLbl.TextColor3 = isChosen and Color3.fromRGB(210, 255, 230) or Color3.fromRGB(175, 195, 225)
            lineLbl.Font = Enum.Font.Gotham; lineLbl.TextSize = 9
            lineLbl.TextXAlignment = Enum.TextXAlignment.Left; lineLbl.TextTruncate = Enum.TextTruncate.AtEnd
            lineLbl.Parent = card

            local pickBadge = Instance.new("TextLabel")
            pickBadge.Size = UDim2.new(0, 82, 0, 18); pickBadge.Position = UDim2.new(1, -88, 0.5, -9)
            pickBadge.BackgroundColor3 = isChosen and Color3.fromRGB(35, 115, 65) or Color3.fromRGB(40, 44, 58)
            pickBadge.Text = isChosen and "✓ Selected" or "Available"
            pickBadge.TextColor3 = isChosen and Color3.fromRGB(160, 255, 190) or Color3.fromRGB(170, 180, 200)
            pickBadge.Font = Enum.Font.GothamBold; pickBadge.TextSize = 8.5; pickBadge.Parent = card
            Instance.new("UICorner", pickBadge).CornerRadius = UDim.new(0, 4)
        end
    end

    -- Update Manual / Auto Trade Button
    if isTradingIn then
        manualTradeBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 120)
        manualTradeBtn.Text = "⏳ Trading In..."
        manualTradeBtn.TextColor3 = Color3.new(1, 1, 1)
        mtStroke.Color = Color3.fromRGB(150, 100, 220)
    elseif allReady and totalReq > 0 then
        if isAutoTradeEnabled then
            manualTradeBtn.BackgroundColor3 = Color3.fromRGB(35, 115, 70)
            manualTradeBtn.Text = string.format("⚡ Auto-Ready (%d/%d)", readySlotsCount, totalReq)
            manualTradeBtn.TextColor3 = Color3.fromRGB(160, 255, 190)
            mtStroke.Color = Color3.fromRGB(70, 210, 130)
        else
            manualTradeBtn.BackgroundColor3 = Color3.fromRGB(115, 60, 185)
            manualTradeBtn.Text = string.format("⚡ Trade (%d/%d Ready)", readySlotsCount, totalReq)
            manualTradeBtn.TextColor3 = Color3.new(1, 1, 1)
            mtStroke.Color = Color3.fromRGB(170, 110, 255)
        end
    else
        manualTradeBtn.BackgroundColor3 = Color3.fromRGB(50, 48, 65)
        manualTradeBtn.Text = string.format("⚡ Trade (%d/%d)", readySlotsCount, totalReq)
        manualTradeBtn.TextColor3 = Color3.fromRGB(160, 165, 185)
        mtStroke.Color = Color3.fromRGB(65, 60, 85)
    end
end

-- ========================================================================
-- 8. TRADE-IN EXECUTION PIPELINE & AUTO-TRADE ENGINE
-- ========================================================================

checkAndAutoTrade = function(source)
    if not isAutoTradeEnabled then return false end
    if isTradingIn then return false end
    if os.clock() - lastTradeAttempt < 1.5 then return false end
    if not scrambleRequirements or #scrambleRequirements == 0 then return false end

    local allReady, finalUids, readyCount, totalReq = getTradeCandidates()
    if allReady and #finalUids == #scrambleRequirements and #finalUids > 0 then
        logMsg(string.format("⚡ [Auto-Trade] All slots ready (%d/%d)! Auto-executing (%s)...", readyCount, totalReq, tostring(source or "auto")), Color3.fromRGB(120, 255, 180))
        return executeTradeIn(true, finalUids)
    end
    return false
end

executeTradeIn = function(isAuto, candidateUids)
    if isTradingIn then
        if not isAuto then
            logMsg("⏳ Trade already in progress...", Color3.fromRGB(255, 180, 80))
        end
        return false
    end

    if isAuto and not isAutoTradeEnabled then return false end
    if os.clock() - lastTradeAttempt < 1.5 then return false end

    -- Select 1 distinct egg per requirement slot
    local finalUids = candidateUids
    if not finalUids then
        scanInventoryEggs(false)
        local allReady, uids = getTradeCandidates()
        if not allReady then
            if not isAuto then
                logMsg(string.format("⚠️ Missing eggs for trade (%d/%d slots ready). Cannot execute.", #uids, #scrambleRequirements), Color3.fromRGB(255, 180, 80))
            end
            return false
        end
        finalUids = uids
    end

    if not scrambleRequirements or #scrambleRequirements == 0 or #finalUids < #scrambleRequirements or #finalUids == 0 then
        if not isAuto then
            logMsg(string.format("⚠️ Missing eggs for trade (%d/%d slots ready). Cannot execute.", #finalUids, #scrambleRequirements), Color3.fromRGB(255, 180, 80))
        end
        return false
    end

    if not rfTradeIn then
        rfTradeIn = getNetRemote("RF/ScrambleTradeIn/AskTradeIn") or getNetRemote("RF/ScrambleTradeIn/TradeIn")
    end
    if not rfTradeIn then
        logMsg("❌ Remote RF/ScrambleTradeIn/AskTradeIn NOT FOUND!", Color3.fromRGB(255, 100, 100))
        return false
    end

    lastTradeAttempt = os.clock()
    isTradingIn = true
    manualTradeBtn.Text = "⏳ Trading In..."
    manualTradeBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 120)

    task.spawn(function()
        local modeTag = isAuto and "[AUTO-TRADE]" or "[MANUAL TRADE]"
        logMsg(string.format("🌀 %s Offering %d unplaced eggs to Dr. Scramble...", modeTag, #finalUids), Color3.fromRGB(190, 150, 255))
        for i, u in ipairs(finalUids) do
            local req = scrambleRequirements[i]
            local disp = req and getDisplayEggName(req.species) or "Egg"
            local shortU = (#u > 10) and (u:sub(1, 8) .. "...") or u
            logMsg(string.format("  Slot #%d [%s]: Offering UID %s", i, disp, shortU), Color3.fromRGB(170, 195, 235))
        end

        -- STEP 1: Invoke AskTradeIn({ [1]=uid1, [2]=uid2, [3]=uid3 })
        local ok, res, reward = pcall(function()
            return rfTradeIn:InvokeServer(finalUids)
        end)

        local resSummary = type(res) == "table" and dumpTbl(res, 2) or tostring(res)
        logMsg("⚡ [AskTradeIn] Result: " .. resSummary, (ok and res ~= false) and Color3.fromRGB(120, 255, 180) or Color3.fromRGB(255, 160, 90))

        if not ok or res == false then
            logMsg("❌ Server rejected trade-in. Check eggs or try again.", Color3.fromRGB(255, 110, 110))
            isTradingIn = false
            updateUI()
            return
        end

        -- STEP 2: Invoke AskFinishReveal to claim reward & unlock next recipe
        task.wait(0.5)
        if not rfReveal then rfReveal = getNetRemote("RF/ScrambleTradeIn/AskFinishReveal") end
        if rfReveal then
            logMsg("🎁 Calling AskFinishReveal to claim pet reward...", Color3.fromRGB(180, 215, 255))
            local okRev, resRev = pcall(function()
                return rfReveal:InvokeServer()
            end)
            logMsg("✨ [AskFinishReveal] Result: " .. tostring(resRev), (okRev and resRev ~= false) and Color3.fromRGB(130, 255, 180) or Color3.fromRGB(255, 180, 80))
        end

        -- Lightweight snapshot synchronization
        task.wait(0.3)
        pcall(function()
            local ccReq = ReplicatedStorage:FindFirstChild("ContentCreatorRemotes")
            if ccReq and ccReq:FindFirstChild("Request") then
                ccReq.Request:InvokeServer("snapshot", { lightweight = true })
            end
        end)

        isTradingIn = false
        logMsg("✅ Trade-In complete! Refreshing recipe...", Color3.fromRGB(140, 255, 180))

        task.wait(0.5)
        queryScrambleState()
        scanInventoryEggs(true)
        updateUI()

        -- Immediately chain next trade if eligible!
        if isAutoTradeEnabled then
            task.defer(function()
                checkAndAutoTrade("PostTradeChain")
            end)
        end
    end)

    return true
end

-- ========================================================================
-- 9. EVENT LISTENERS & BACKGROUND WORKER
-- ========================================================================

-- Server Trade Rotation Event (RE/ScrambleTradeIn/BannerRotated)
if reRotated and reRotated:IsA("RemoteEvent") then
    reRotated.OnClientEvent:Connect(function(...)
        logMsg("🔄 [RE/BannerRotated] Server rotated trade recipe! Reloading...", Color3.fromRGB(150, 220, 255))
        task.wait(0.5)
        queryScrambleState()
        scanInventoryEggs(true)
        updateUI()
        task.defer(function()
            checkAndAutoTrade("BannerRotatedEvent")
        end)
    end)
end

-- Main Background Worker Loop
task.spawn(function()
    logMsg("🌀 Dr. Scramble Standalone Auto-Trade Engine Started")
    queryScrambleState()
    scanInventoryEggs(true)
    updateUI()

    -- Trigger auto-trade immediately on launch if eligible
    task.defer(function()
        checkAndAutoTrade("Startup")
    end)

    local lastLoopScan = 0
    while screenGui.Parent do
        local now = os.time()
        local diff = 0
        if serverExpiresAt then
            diff = math.max(0, serverExpiresAt - now)
            if diff <= 0 then
                logMsg("⏰ Hourly timer expired! Querying next rotation...", Color3.fromRGB(255, 200, 100))
                queryScrambleState()
                scanInventoryEggs(true)
                updateUI()
                task.defer(function()
                    checkAndAutoTrade("TimerExpired")
                end)
                local secsIntoHour = os.time() % 3600
                serverExpiresAt = os.time() + (3600 - secsIntoHour)
                diff = 3600 - secsIntoHour
            end
        else
            local secsIntoHour = os.time() % 3600
            diff = 3600 - secsIntoHour
        end

        local m = math.floor(diff / 60)
        local s = diff % 60
        timerBadge.Text = string.format("⏳ %02dm %02ds  •  %s", m, s, scrambleBannerName)

        -- Periodic evaluation every 1.2 seconds
        if os.clock() - lastLoopScan >= 1.2 then
            lastLoopScan = os.clock()
            scanInventoryEggs(true)
            updateUI()

            if isAutoTradeEnabled and not isTradingIn then
                checkAndAutoTrade("LoopCheck")
            end
        end

        task.wait(0.5)
    end
end)
