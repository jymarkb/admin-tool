local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

--==================================================
-- SETTINGS
--==================================================

local INITIAL_FREEFALL_TIME = 0.12
local INITIAL_VERTICAL_SPEED = -13
local FALL_ACCELERATION = -200

local ENTRY_HEIGHT = 3.8
local FINAL_VERTICAL_SPEED = -5

local MAX_DESCENT_TIME = 1.5

local TRACE_INTERVAL = 0.05

local EGG_DROP_SPAM_COUNT = 8
local EGG_DROP_SPAM_INTERVAL = 0.03

local POSITION_SETTLE_TIME = 0.30

local SAMPLE_GUARD_CFRAME = CFrame.new(
    605.572266, 69.3371735, -325.887329,
    0.70000118, 0, -0.714141667,
    0, 1, 0,
    0.714141667, 0, 0.70000118
)

--==================================================
-- CHARACTER
--==================================================

local Character
local Humanoid
local Root

local function refreshCharacter()
    Character = Player.Character or Player.CharacterAdded:Wait()
    Humanoid = Character:WaitForChild("Humanoid")
    Root = Character:WaitForChild("HumanoidRootPart")
end

refreshCharacter()

Player.CharacterAdded:Connect(function()
    task.wait(0.25)
    refreshCharacter()
end)

--==================================================
-- BIOMES & LOCATION
--==================================================

local BIOMES = {
    { Name = "Forest", Pos = Vector3.new(596.7, 71.4, -327.8) },
    { Name = "Lake", Pos = Vector3.new(735.9, 71.0, -410.7) },
    { Name = "Desert", Pos = Vector3.new(943.2, 71.0, -321.4) },
    { Name = "Jungle", Pos = Vector3.new(1193.2, 71.0, -405.3) },
    { Name = "Snow", Pos = Vector3.new(1488.2, 75.0, -318.8) },
    { Name = "Volcano", Pos = Vector3.new(1883.4, 71.0, -393.8) },
    { Name = "Abyss Ocean", Pos = Vector3.new(2281.6, 71.0, -323.1) },
    { Name = "Prehistoric", Pos = Vector3.new(2813.6, 71.0, -402.2) },
    { Name = "Cosmic", Pos = Vector3.new(3395.0, 71.0, -329.2) },
    { Name = "Cherry Blossom", Pos = Vector3.new(4031.5, 71.0, -392.4) },
    { Name = "Titan Temple", Pos = Vector3.new(4790.8, 71.5, -326.7) },
    { Name = "Light Dark", Pos = Vector3.new(5662.2, 71.5, -324.7) },
    { Name = "Enchanted Forest", Pos = Vector3.new(6700.8, 71.5, -353.8) },
}

local function getBiomeName(pos)
    if not pos then return "Unknown" end
    local closest, minDist = "Unknown", math.huge
    for _, b in ipairs(BIOMES) do
        local d = (pos - b.Pos).Magnitude
        if d < minDist then
            minDist = d
            closest = b.Name
        end
    end
    if minDist <= 250 then
        return closest
    else
        return string.format("%s (~%dm)", closest, math.floor(minDist))
    end
end

local SavedLocation = Vector3.new(949.147, 70.724, -412.289)

-- Start is captured automatically when RUN is pressed.
local StartLocation = nil

--==================================================
-- STATE
--==================================================

local Running = false
local Phase = "IDLE"
local RunToken = 0
local pinConn = nil
local isCarryingEgg = false
local carriedEggUid = nil

local cachedEggUid = nil
local cachedEggSource = nil
local isRefreshingEggUid = false

local TestStartTime = 0
local LastTrace = 0

--==================================================
-- LOGGING
--==================================================

local Logs = {}

local function log(message)
    local line = string.format(
        "[%s] %s",
        os.date("%H:%M:%S"),
        tostring(message)
    )

    table.insert(Logs, line)

    while #Logs > 400 do
        table.remove(Logs, 1)
    end

    print(line)
end

local function vec(v)
    if not v then
        return "nil"
    end

    return string.format(
        "(%.3f, %.3f, %.3f)",
        v.X,
        v.Y,
        v.Z
    )
end

local function logCharacterPosition(label)
    if not Root or not Root.Parent or not Humanoid then
        log(string.format("POSITION [%s]: Character unavailable", tostring(label or "snapshot")))
        return nil
    end

    local p = Root.Position
    local v = Root.AssemblyLinearVelocity
    local stateName = Humanoid:GetState().Name
    local biome = getBiomeName(p)
    log(string.format(
        "POSITION [%s]: %s (%s) | vel=%s (speed=%.2f) | state=%s",
        tostring(label or "snapshot"),
        biome,
        vec(p),
        vec(v),
        v.Magnitude,
        stateName
    ))
    return p
end

local function copyLog()
    local text = table.concat(Logs, "\n")
    local success = false

    if type(setclipboard) == "function" then
        success = pcall(function()
            setclipboard(text)
        end)
    elseif type(toclipboard) == "function" then
        success = pcall(function()
            toclipboard(text)
        end)
    end

    if success then
        log("LOG COPIED")
    else
        log("Clipboard unavailable")
    end
end

--==================================================
-- GUI
--==================================================

local Gui = Instance.new("ScreenGui")
Gui.Name = "DropTesterOneLocation"
Gui.ResetOnSpawn = false
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.Parent = PlayerGui

local Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(285, 235)
Main.Position = UDim2.new(0.5, -142, 0.5, -117)

Main.BackgroundColor3 = Color3.fromRGB(24, 24, 24)
Main.BorderSizePixel = 0

Main.Parent = Gui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0, 8)
Corner.Parent = Main

--==================================================
-- TITLE BAR
--==================================================

local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 32)

TitleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
TitleBar.BorderSizePixel = 0

TitleBar.Parent = Main

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 8)
TitleCorner.Parent = TitleBar

local TitleFix = Instance.new("Frame")
TitleFix.Size = UDim2.new(1, 0, 0, 12)
TitleFix.Position = UDim2.new(0, 0, 1, -12)

TitleFix.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
TitleFix.BorderSizePixel = 0

TitleFix.Parent = TitleBar

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -42, 1, 0)
Title.Position = UDim2.fromOffset(10, 0)

Title.BackgroundTransparency = 1
Title.Text = "Drop / Freefall Tester"

Title.TextColor3 = Color3.new(1, 1, 1)
Title.TextSize = 15
Title.Font = Enum.Font.SourceSansBold

Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = TitleBar

--==================================================
-- CLOSE
--==================================================

local Close = Instance.new("TextButton")
Close.Size = UDim2.fromOffset(24, 24)
Close.Position = UDim2.new(1, -28, 0, 4)

Close.BackgroundColor3 = Color3.fromRGB(170, 50, 50)
Close.BorderSizePixel = 0

Close.Text = "X"
Close.TextColor3 = Color3.new(1, 1, 1)
Close.TextSize = 14
Close.Font = Enum.Font.SourceSansBold

Close.Parent = TitleBar

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 6)
CloseCorner.Parent = Close

Close.MouseButton1Click:Connect(function()
    Running = false
    RunToken += 1

    if Root and Root.Parent then
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
    end

    Gui:Destroy()
end)

--==================================================
-- DRAGGING
--==================================================

local dragging = false
local dragStart
local startPos

TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        dragging = true
        dragStart = input.Position
        startPos = Main.Position
    end
end)

TitleBar.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then

        dragging = false
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not dragging then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then

        local delta = input.Position - dragStart

        Main.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,

            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

--==================================================
-- LOCATION LABEL
--==================================================

local LocationLabel = Instance.new("TextLabel")
LocationLabel.Size = UDim2.new(1, -16, 0, 26)
LocationLabel.Position = UDim2.fromOffset(8, 38)
LocationLabel.BackgroundTransparency = 1
LocationLabel.Text = "Drop/Landing: " .. (SavedLocation and vec(SavedLocation) or "NOT SET")
LocationLabel.TextColor3 = Color3.fromRGB(215, 215, 215)
LocationLabel.TextSize = 12
LocationLabel.Font = Enum.Font.SourceSans
LocationLabel.TextWrapped = true
LocationLabel.TextXAlignment = Enum.TextXAlignment.Left
LocationLabel.TextYAlignment = Enum.TextYAlignment.Top
LocationLabel.Parent = Main

--==================================================
-- EGG UID LABEL
--==================================================

local EggUidLabel = Instance.new("TextLabel")
EggUidLabel.Size = UDim2.new(1, -16, 0, 22)
EggUidLabel.Position = UDim2.fromOffset(8, 64)
EggUidLabel.BackgroundTransparency = 1
EggUidLabel.Text = "Egg UID: loading..."
EggUidLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
EggUidLabel.TextSize = 11
EggUidLabel.Font = Enum.Font.SourceSans
EggUidLabel.TextWrapped = true
EggUidLabel.TextXAlignment = Enum.TextXAlignment.Left
EggUidLabel.Parent = Main

--==================================================
-- STATUS
--==================================================

local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, -16, 0, 22)
Status.Position = UDim2.fromOffset(8, 88)
Status.BackgroundTransparency = 1
Status.Text = "Status: Idle"
Status.TextColor3 = Color3.fromRGB(150, 220, 150)
Status.TextSize = 12
Status.Font = Enum.Font.SourceSans
Status.TextWrapped = true
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.Parent = Main

--==================================================
-- BUTTON CREATOR
--==================================================

local function makeButton(text, x, y, width, height, color)
    local button = Instance.new("TextButton")
    button.Size = width or UDim2.new(1, -16, 0, 30)
    button.Position = UDim2.new(0, x or 8, 0, y)
    button.BackgroundColor3 = color or Color3.fromRGB(55, 55, 55)
    button.BorderSizePixel = 0
    button.Text = text
    button.TextColor3 = Color3.new(1, 1, 1)
    button.TextSize = 12
    button.Font = Enum.Font.SourceSansBold
    button.Parent = Main

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = button

    return button
end

local SetLocationButton =
    makeButton(
        "SET LANDING",
        8,
        114,
        UDim2.new(0.58, -10, 0, 30),
        30,
        Color3.fromRGB(65, 90, 135)
    )

local RefreshIdButton =
    makeButton(
        "REFRESH ID",
        0,
        114,
        UDim2.new(0.42, -6, 0, 30),
        30,
        Color3.fromRGB(40, 85, 130)
    )
RefreshIdButton.Position = UDim2.new(0.58, 2, 0, 114)

local RunButton =
    makeButton(
        "RUN: STRIKE → DROP → LAND",
        8,
        150,
        UDim2.new(1, -16, 0, 32),
        32,
        Color3.fromRGB(45, 125, 65)
    )

local CopyButton =
    makeButton(
        "COPY LOG",
        8,
        188,
        UDim2.new(1, -16, 0, 28),
        28,
        Color3.fromRGB(50, 90, 160)
    )

--==================================================
-- SET LOCATION
--==================================================

SetLocationButton.MouseButton1Click:Connect(function()
    if Running then
        Status.Text =
            "Status: Stop the current test first"
        return
    end

    refreshCharacter()

    if not Root or not Root.Parent then
        Status.Text =
            "Status: Character unavailable"
        return
    end

    SavedLocation = Root.Position

    LocationLabel.Text =
        "Drop/Landing: " .. vec(SavedLocation)

    Status.Text =
        "Status: Location saved"

    log(
        "DROP / LANDING LOCATION = "
        .. vec(SavedLocation)
    )
end)

RefreshIdButton.MouseButton1Click:Connect(function()
    refreshEggUid()
end)

--==================================================
-- TRACE
--==================================================

local function trace(label)
    if not Root or not Root.Parent then
        return
    end

    local now = os.clock()

    if now - LastTrace < TRACE_INTERVAL then
        return
    end

    LastTrace = now

    log(
        label
        .. " | pos="
        .. vec(Root.Position)
        .. " | vel="
        .. vec(Root.AssemblyLinearVelocity)
    )
end

--==================================================
-- REMOTE RESOLVER & EGG UID HELPERS
--==================================================

local function getRemote(subPath)
    local packages = ReplicatedStorage:FindFirstChild("Packages")
        or ReplicatedStorage:WaitForChild("Packages", 5)
    local networking = packages and (
        packages:FindFirstChild("Networking")
        or packages:WaitForChild("Networking", 5)
    )
    if not networking then
        return nil
    end

    local flattened = networking:FindFirstChild(subPath)
    if flattened then
        return flattened
    end

    local current = networking
    for segment in string.gmatch(subPath, "[^/]+") do
        current = current and current:FindFirstChild(segment)
    end
    if current then
        return current
    end

    local leaf = string.match(subPath, "[^/]+$")
    for _, item in ipairs(networking:GetDescendants()) do
        if item.Name == subPath or item.Name == leaf then
            return item
        end
    end
    return nil
end

task.defer(function()
    local carryRemote = getRemote("RE/EggWorld/FieldEggCarry")
    if carryRemote and carryRemote:IsA("RemoteEvent") then
        carryRemote.OnClientEvent:Connect(function(payload)
            if typeof(payload) == "table" then
                if payload.IsCarrying ~= nil then
                    isCarryingEgg = payload.IsCarrying
                    log(string.format("[CARRY EVENT] IsCarrying = %s, SpeedMultiplier = %s", tostring(payload.IsCarrying), tostring(payload.SpeedMultiplier or 1)))
                end
                local uid = payload.Uid or payload.EggUid or payload.uid or payload.UID
                if uid and tostring(uid) ~= "" then
                    carriedEggUid = tostring(uid)
                    log(string.format("[CARRY EVENT] Updated carried Egg UID: %s", carriedEggUid))
                    if EggUidLabel and EggUidLabel.Parent then
                        EggUidLabel.Text = "Egg UID: " .. carriedEggUid
                        EggUidLabel.TextColor3 = Color3.fromRGB(170, 255, 200)
                    end
                end
                if payload.IsCarrying == false then
                    isCarryingEgg = false
                    carriedEggUid = nil
                end
            end
        end)
    end

    local ownerDroppedRemote = getRemote("RE/EggWorld/OwnerDropped")
    if ownerDroppedRemote and ownerDroppedRemote:IsA("RemoteEvent") then
        ownerDroppedRemote.OnClientEvent:Connect(function(payload)
            isCarryingEgg = false
            carriedEggUid = nil
            if typeof(payload) == "table" then
                local u = tostring(payload.Uid or payload.EggUid or "unknown")
                local cf = payload.BoundsCFrame or payload.BottomCFrame or payload.Position
                local pos = (typeof(cf) == "CFrame" and cf.Position) or (typeof(cf) == "Vector3" and cf)
                if pos then
                    log(string.format("[AUTHORITATIVE DROP EVENT] Server dropped egg Uid=%s at %s %s", u, getBiomeName(pos), vec(pos)))
                else
                    log(string.format("[AUTHORITATIVE DROP EVENT] Server dropped egg Uid=%s", u))
                end
            end
        end)
    end

    local eggShiftedRemote = getRemote("RE/EggWorld/FieldEggShifted")
    if eggShiftedRemote and eggShiftedRemote:IsA("RemoteEvent") then
        eggShiftedRemote.OnClientEvent:Connect(function(payload)
            if typeof(payload) == "table" then
                local u = tostring(payload.Uid or payload.EggUid or "unknown")
                local st = tostring(payload.State or "")
                local cf = payload.BoundsCFrame or payload.BottomCFrame or payload.Position
                local pos = (typeof(cf) == "CFrame" and cf.Position) or (typeof(cf) == "Vector3" and cf)
                if st == "Dropped" and pos then
                    log(string.format("[AUTHORITATIVE SHIFT EVENT] Server dropped egg Uid=%s at %s %s", u, getBiomeName(pos), vec(pos)))
                elseif st == "Slot" then
                    local area = payload.AreaId and tostring(payload.AreaId) or (pos and getBiomeName(pos)) or "Nest"
                    log(string.format("[AUTHORITATIVE SHIFT EVENT] Egg Uid=%s returned to %s nest slot!", u, area))
                end
            end
        end)
    end

    local eggGoneRemote = getRemote("RE/EggWorld/FieldEggGone")
    if eggGoneRemote and eggGoneRemote:IsA("RemoteEvent") then
        eggGoneRemote.OnClientEvent:Connect(function(payload)
            local u = typeof(payload) == "table" and tostring(payload.Uid or payload.EggUid or "unknown") or tostring(payload or "unknown")
            log(string.format("[AUTHORITATIVE GONE EVENT] Egg Uid=%s despawned/removed", u))
        end)
    end
end)

local function isHoldingEgg()
    if isCarryingEgg then return true end
    if Character then
        for _, child in ipairs(Character:GetChildren()) do
            if child:IsA("Tool") or (child:IsA("Model") and string.find(string.lower(child.Name), "egg", 1, true)) then
                return true
            end
        end
    end
    local attr = Player and (Player:GetAttribute("IsCarrying") or Player:GetAttribute("HoldingEgg") or Player:GetAttribute("CarryingEgg"))
    if attr ~= nil and attr ~= false and attr ~= "" then
        return true
    end
    return false
end

--==================================================
-- V12 FAST PICKUP ENGINE
--==================================================

local function isCarryPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") or not prompt.Enabled then return false end
    local n = prompt.Name:lower()
    local a = prompt.ActionText:lower()
    local o = prompt.ObjectText:lower()
    for _, bl in ipairs({ "shop", "hatch", "buy", "purchase", "open", "talk", "dialog", "manor" }) do
        if n:find(bl, 1, true) or a:find(bl, 1, true) or o:find(bl, 1, true) then
            return false
        end
    end
    if n:find("carry", 1, true) or n:find("steal", 1, true) or n:find("pickup", 1, true) or n:find("egg", 1, true) then
        return true
    end
    if a:find("steal", 1, true) or a:find("carry", 1, true) or a:find("pick", 1, true) or a:find("take", 1, true) or a:find("grab", 1, true) then
        return true
    end
    if o:find("egg", 1, true) or o:find("steal", 1, true) or o:find("carry", 1, true) then
        return true
    end
    local pName = prompt.Parent and prompt.Parent.Name:lower() or ""
    if pName:find("smartprompt", 1, true) or pName:find("egg", 1, true) or pName:find("slot", 1, true) then
        return true
    end
    return false
end

local function triggerPrompt(prompt)
    if not prompt then return false end
    pcall(function()
        if typeof(fireproximityprompt) == "function" then
            fireproximityprompt(prompt, 0)
            fireproximityprompt(prompt, 1)
        elseif typeof(prompt.InputHoldBegin) == "function" then
            prompt:InputHoldBegin()
            task.delay(0.02, function()
                pcall(function() prompt:InputHoldEnd() end)
            end)
        end
    end)
end

local function pickupNearbyEgg(radius, maxAttempts)
    radius = radius or 45.0
    maxAttempts = maxAttempts or 5
    if not Root or not Root.Parent then return false end
    if isHoldingEgg() then return true end

    local carryRemote = getRemote("RF/EggWorld/AskFieldEggCarry")

    for attempt = 1, maxAttempts do
        if isHoldingEgg() then return true end
        local charPos = Root and Root.Parent and Root.Position
        if not charPos then break end

        -- 1. Find the SINGLE closest egg candidate (preventing multi-slot prompt spam)
        local bestPrompt = nil
        local bestUid = nil
        local bestDist = radius

        -- Check SmartPromptPart (game dynamic prompt)
        local spp = workspace:FindFirstChild("SmartPromptPart")
        if spp then
            for _, pr in ipairs(spp:GetDescendants()) do
                if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                    local part = pr.Parent and (pr.Parent:IsA("BasePart") and pr.Parent or pr.Parent:FindFirstChildWhichIsA("BasePart"))
                    local d = part and (part.Position - charPos).Magnitude or 0
                    if d <= radius then
                        bestPrompt = pr
                        break
                    end
                end
            end
        end

        -- Check AreaEggSlotsClient for closest slot (primary egg container)
        local slots = workspace:FindFirstChild("AreaEggSlotsClient")
            or (workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Areas") and workspace.World.Areas:FindFirstChild("EggSlotsClient"))
        if slots then
            for _, sl in ipairs(slots:GetChildren()) do
                local p = (sl:IsA("BasePart") and sl.Position)
                    or (sl:IsA("Model") and (sl.PrimaryPart and sl.PrimaryPart.Position or sl:GetPivot().Position))
                if p then
                    local d = (p - charPos).Magnitude
                    if d <= bestDist then
                        bestDist = d
                        local uid = sl:GetAttribute("Uid") or sl:GetAttribute("EggUid")
                        if not uid and #sl.Name == 32 and sl.Name:match("^%x+$") then
                            uid = sl.Name
                        elseif not uid then
                            uid = sl.Name
                        end
                        bestUid = uid

                        local pr = sl:FindFirstChildWhichIsA("ProximityPrompt", true)
                        if pr and isCarryPrompt(pr) then
                            bestPrompt = pr
                        end
                    end
                end
            end
        end

        -- Check Workspace.Eggs as secondary container
        if not bestUid then
            local eggsFolder = workspace:FindFirstChild("Eggs")
            if eggsFolder then
                for _, egg in ipairs(eggsFolder:GetChildren()) do
                    local p = (egg:IsA("BasePart") and egg.Position)
                        or (egg:IsA("Model") and (egg.PrimaryPart and egg.PrimaryPart.Position or egg:GetPivot().Position))
                    if p then
                        local d = (p - charPos).Magnitude
                        if d <= bestDist then
                            bestDist = d
                            bestUid = egg:GetAttribute("Uid") or egg:GetAttribute("EggUid") or egg.Name
                            local pr = egg:FindFirstChildWhichIsA("ProximityPrompt", true)
                            if pr and isCarryPrompt(pr) then
                                bestPrompt = pr
                            end
                        end
                    end
                end
            end
        end

        -- Check AskFieldEggSnapshot as authoritative server fallback
        if not bestUid then
            local snapshotRemote = getRemote("RF/EggWorld/AskFieldEggSnapshot")
            if snapshotRemote and snapshotRemote:IsA("RemoteFunction") then
                local ok, res = pcall(function() return snapshotRemote:InvokeServer() end)
                if ok and typeof(res) == "table" then
                    local records = res.Records or res.records
                    if typeof(records) == "table" then
                        for _, r in pairs(records) do
                            if typeof(r) == "table" and isEggAvailable(r) then
                                local cf = r.BoundsCFrame or r.BottomCFrame or r.Position
                                local pos = (typeof(cf) == "CFrame" and cf.Position) or (typeof(cf) == "Vector3" and cf)
                                if pos then
                                    local d = (pos - charPos).Magnitude
                                    if d <= bestDist then
                                        bestDist = d
                                        bestUid = tostring(r.Uid or r.EggUid or "")
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if not bestPrompt and not bestUid then
            break -- No egg in range
        end

        log(string.format("Fast pickup (attempt %d): targeting uid=%s (dist=%.1f studs, prompt=%s)", attempt, tostring(bestUid or "none"), bestDist, bestPrompt and bestPrompt.Name or "none"))

        -- 2. Trigger ONLY the single best egg candidate
        if bestPrompt then
            triggerPrompt(bestPrompt)
        end
        if bestUid and carryRemote then
            pcall(function()
                carryRemote:InvokeServer({ Uid = bestUid })
            end)
        end

        -- 3. Wait up to 0.15s for server carry confirmation before retrying
        local pollStart = os.clock()
        while (os.clock() - pollStart < 0.15) and not isHoldingEgg() do
            RunService.Heartbeat:Wait()
        end

        if isHoldingEgg() then
            return true
        end
    end
    return isHoldingEgg()
end

local function nullifyRagdoll()
    if Root and Root.Parent then
        pcall(function()
            Root.AssemblyLinearVelocity = Vector3.zero
            Root.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    if Character then
        pcall(function()
            Character:SetAttribute("RagdollEndTime", 0)
            Character:SetAttribute("RagdollTime", 0)
            Character:SetAttribute("IsRagdoll", false)
            Character:SetAttribute("Ragdolled", false)
        end)
    end
    if Humanoid and Humanoid.Parent and Humanoid.Health > 0 then
        pcall(function()
            Humanoid.PlatformStand = false
            Humanoid.Sit = false
            Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end
end

local function getPivotPos(inst)
    if not inst then return nil end
    local ok, p = pcall(function() return inst:GetPivot() end)
    if ok and p then return p end
    if inst:IsA("Model") and inst.PrimaryPart then return inst.PrimaryPart.CFrame end
    if inst:IsA("BasePart") then return inst.CFrame end
    return nil
end

local function isEggAvailable(record)
    local carrier = record.CarrierUserId or record.carrierUserId
    return carrier == nil or carrier == 0 or carrier == "" or carrier == "0"
end

local function findAnyEggUid()
    log("Looking for available Egg UID...")
    local snapshotRemote = getRemote("RF/EggWorld/AskFieldEggSnapshot")

    if snapshotRemote and snapshotRemote:IsA("RemoteFunction") then
        local ok, result = pcall(function()
            return snapshotRemote:InvokeServer()
        end)

        if ok and typeof(result) == "table" then
            local records = result.Records or result.records
            if typeof(records) == "table" then
                local fallbackUid = nil
                local fallbackSource = nil

                for _, record in pairs(records) do
                    if typeof(record) == "table" then
                        local uid = record.Uid or record.uid or record.UID or record.Id or record.id
                        local area = record.AreaId or record.areaId or record.Area or record.Biome or record.biome
                        local uidText = tostring(uid or "")
                        local areaText = string.lower(tostring(area or ""))
                        local uidLower = string.lower(uidText)
                        local isForest = areaText == "forest"
                            or string.find(uidLower, "_forest:slot_", 1, true) ~= nil

                        if uid and uidText ~= "" and isEggAvailable(record) then
                            if isForest then
                                log("Selected Forest UID from AskFieldEggSnapshot: " .. uidText)
                                return uidText, "AskFieldEggSnapshot (Forest)"
                            elseif not fallbackUid then
                                fallbackUid = uidText
                                fallbackSource = "AskFieldEggSnapshot (" .. (areaText ~= "" and areaText or "Any") .. ")"
                            end
                        end
                    end
                end

                if fallbackUid then
                    log("Selected available UID from AskFieldEggSnapshot: " .. fallbackUid)
                    return fallbackUid, fallbackSource
                end
            end
        end
    end

    -- Fallback: AreaEggSlotsClient in workspace (from latest.log)
    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        local fallbackSlot = nil
        for _, slot in ipairs(slots:GetChildren()) do
            local nameLower = string.lower(slot.Name)
            if string.find(nameLower, "_forest:slot_", 1, true) then
                log("Selected Forest UID from AreaEggSlotsClient: " .. slot.Name)
                return slot.Name, "Workspace.AreaEggSlotsClient (Forest)"
            elseif not fallbackSlot then
                fallbackSlot = slot.Name
            end
        end

        if fallbackSlot then
            log("Selected UID from AreaEggSlotsClient: " .. fallbackSlot)
            return fallbackSlot, "Workspace.AreaEggSlotsClient"
        end
    end

    return nil, "No available Egg UID found"
end

local function refreshEggUid(sync)
    if isRefreshingEggUid then
        log("UID refresh already in progress...")
        return
    end

    local function doRefresh()
        isRefreshingEggUid = true
        if RefreshIdButton and RefreshIdButton.Parent then
            RefreshIdButton.Text = "LOADING..."
        end
        log("Refreshing cached Egg UID...")

        local ok, uid, source = pcall(findAnyEggUid)
        if ok and uid and tostring(uid) ~= "" then
            cachedEggUid = tostring(uid)
            cachedEggSource = tostring(source or "unknown")
            log(string.format("Cached Egg UID loaded: %s (%s)", cachedEggUid, cachedEggSource))
            if EggUidLabel and EggUidLabel.Parent then
                EggUidLabel.Text = "Egg UID: " .. cachedEggUid
                EggUidLabel.TextColor3 = Color3.fromRGB(170, 225, 255)
            end
        else
            local reason = ok and tostring(source or "none found") or tostring(uid)
            log("UID refresh failed: " .. reason)
            if not cachedEggUid then
                if EggUidLabel and EggUidLabel.Parent then
                    EggUidLabel.Text = "Egg UID: NOT LOADED (Press Refresh)"
                    EggUidLabel.TextColor3 = Color3.fromRGB(255, 185, 130)
                end
            end
        end

        isRefreshingEggUid = false
        if RefreshIdButton and RefreshIdButton.Parent then
            RefreshIdButton.Text = "REFRESH ID"
        end
    end

    if sync then
        doRefresh()
    else
        task.spawn(doRefresh)
    end
end

--==================================================
-- FOREST STRIKE
--==================================================

local function fireForestStrike()
    log("----------------------------------------")
    log("FOREST STRIKE TRIGGERED")

    local remote = getRemote("RE/GuardPatrol/ForestStrike")
    if not remote then
        log("ERROR: ForestStrike remote (RE/GuardPatrol/ForestStrike) not found")
        return false
    end
    if not remote:IsA("RemoteEvent") then
        log("ERROR: ForestStrike has unexpected class: " .. remote.ClassName)
        return false
    end

    local forestEggUid = nil
    -- When at or near Forest, dynamically query active slot eggs from workspace
    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        for _, sl in ipairs(slots:GetChildren()) do
            if string.find(string.lower(sl.Name), "_forest:slot_", 1, true) then
                forestEggUid = sl.Name
                break
            end
        end
    end

    if not forestEggUid then
        forestEggUid = cachedEggUid
    end

    if not forestEggUid or forestEggUid == "" then
        log("No cached Egg UID. Performing immediate lookup...")
        refreshEggUid(true)
        forestEggUid = cachedEggUid
    end

    if not forestEggUid or forestEggUid == "" then
        forestEggUid = "FirstAreaEgg_11924439055_5979147_Forest:Slot_001"
    end

    -- Guard CFrame: Forest guard CFrame (SAMPLE_GUARD_CFRAME or ForestGuardAuthored)
    local guardCFrame = SAMPLE_GUARD_CFRAME
    pcall(function()
        local wsGuard = workspace:FindFirstChild("World", true)
        if wsGuard then
            local forestGuard = wsGuard:FindFirstChild("ForestGuardAuthored", true)
                or wsGuard:FindFirstChild("Forest", true)
            if forestGuard then
                local pivot = getPivotPos(forestGuard)
                if pivot then guardCFrame = pivot end
            end
        end
    end)

    local payload = {
        GuardCFrame = guardCFrame,
        EggUid = forestEggUid,
    }

    log(string.format("Calling ForestStrike:FireServer with Forest EggUid=%s...", forestEggUid))

    local ok, err = pcall(function()
        remote:FireServer(payload)
    end)

    if not ok then
        log("ERROR: ForestStrike FireServer failed: " .. tostring(err))
        return false
    end

    log("ForestStrike FireServer sent OK!")
    return true
end

--==================================================
-- EGG DROP REMOTE & INVOCATION
--==================================================

local function findEggDropRemote()
    local remote = getRemote("RF/EggWorld/AskFieldEggDrop")
    if remote and remote:IsA("RemoteFunction") then
        return remote, remote:GetFullName()
    end
    return nil, "RF/EggWorld/AskFieldEggDrop not found"
end

local function invokeEggDropSpam(runToken, count)
    count = count or EGG_DROP_SPAM_COUNT

    if runToken ~= nil and runToken ~= RunToken then
        log("AskFieldEggDrop cancelled because this run was stopped or superseded.")
        return false
    end

    log(string.format("Looking for RemoteFunction RF/EggWorld/AskFieldEggDrop (Max %dx)...", count))

    local remote, detail = findEggDropRemote()
    if not remote then
        local message = "AskFieldEggDrop RemoteFunction not found: " .. tostring(detail)
        log(message)
        warn("[EggDrop Diagnostic] " .. message)
        return false
    end

    if not remote:IsA("RemoteFunction") then
        local message = "AskFieldEggDrop has unexpected class: " .. remote.ClassName
        log(message)
        return false
    end

    logCharacterPosition("before AskFieldEggDrop sequence")
    log(string.format("Starting AskFieldEggDrop sequence (%dx, %.2fs interval)...", count, EGG_DROP_SPAM_INTERVAL))

    local dropped = false
    for i = 1, count do
        if runToken ~= nil and runToken ~= RunToken then
            log(string.format("AskFieldEggDrop [#%d/%d] cancelled (run superseded)", i, count))
            break
        end
        if not Running or dropped or not isCarryingEgg then
            if not isCarryingEgg and not dropped then
                if i > 1 then
                    dropped = true
                    log("✓ Confirmed egg dropped via FieldEggCarry event!")
                else
                    log("⚠️ AskFieldEggDrop aborted: Not carrying egg at start of drop sequence.")
                end
            end
            break
        end

        -- Hold character at SavedLocation immediately prior to remote call
        if Root and Root.Parent then
            Root.CFrame = CFrame.new(SavedLocation)
            Root.AssemblyLinearVelocity = Vector3.zero
            Root.AssemblyAngularVelocity = Vector3.zero
        end

        local sendPos = Root and Root.Parent and Root.Position
        local ok, result = pcall(function()
            return remote:InvokeServer({ Reason = "PlayerRequest" })
        end)
        if not ok or result == false then
            pcall(function()
                remote:InvokeServer()
            end)
        end

        local statusStr = ok and tostring(result) or ("ERROR: " .. tostring(result))
        local biomeAtSend = getBiomeName(sendPos)
        log(string.format(
            "AskFieldEggDrop [#%d/%d] returned: %s | pos=%s (%s)",
            i,
            count,
            statusStr,
            vec(sendPos),
            biomeAtSend
        ))

        -- Wait up to 0.15s for server to fire FieldEggCarry { IsCarrying = false }
        local pollStart = os.clock()
        while (os.clock() - pollStart < 0.15) and isCarryingEgg do
            RunService.Heartbeat:Wait()
        end

        if not isCarryingEgg or (ok and result == true) then
            dropped = true
            isCarryingEgg = false
            carriedEggUid = nil
            log(string.format("✓ Egg dropped successfully in %s at %s on attempt #%d!", biomeAtSend, vec(sendPos), i))
            break
        end

        if i < count and not dropped then
            task.wait(EGG_DROP_SPAM_INTERVAL)
        end
    end

    logCharacterPosition("after AskFieldEggDrop sequence")
    return dropped or not isCarryingEgg
end

--==================================================
-- STOP SAFELY ON CHARACTER LOSS
--==================================================

local function stopTest()
    Running = false
    RunToken += 1

    if pinConn then
        pcall(function() pinConn:Disconnect() end)
        pinConn = nil
    end

    if Root and Root.Parent then
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
    end

    Status.Text =
        "Status: Stopped"
end

--==================================================
-- CHUNK TRAVEL (Hops <= 800 studs to prevent server position clamp)
--==================================================

local CHUNK_MAX_DIST = 550.0
local CHUNK_HOP_WAIT = 0.12
local CHUNK_AIR_HEIGHT = 65.0 -- Elevate hops +65 studs above ground to avoid all guard detection zones

local function travelInChunks(startPos, targetPos)
    local totalDist = (targetPos - startPos).Magnitude
    if totalDist <= CHUNK_MAX_DIST then
        Root.CFrame = CFrame.new(targetPos)
        Root.AssemblyLinearVelocity = Vector3.zero
        nullifyRagdoll()
        return isHoldingEgg()
    end

    local hops = math.ceil(totalDist / CHUNK_MAX_DIST)
    log(string.format("CHUNK TRAVEL: Splitting %.0f studs into %d hops (<=%.0f studs each, +%.0f air Y)...", totalDist, hops, CHUNK_MAX_DIST, CHUNK_AIR_HEIGHT))

    for h = 1, hops do
        if not Running then break end
        local alpha = h / hops
        local hopPos = startPos:Lerp(targetPos, alpha)

        -- Keep intermediate hops airborne so ground guards cannot intercept
        if h < hops then
            hopPos = Vector3.new(hopPos.X, math.max(startPos.Y, targetPos.Y) + CHUNK_AIR_HEIGHT, hopPos.Z)
        end

        Root.CFrame = CFrame.new(hopPos)
        Root.AssemblyLinearVelocity = Vector3.zero
        nullifyRagdoll()

        local currentBiome = getBiomeName(hopPos)
        log(string.format("  [HOP %d/%d] -> %s %s", h, hops, currentBiome, vec(hopPos)))

        if not isHoldingEgg() then
            log(string.format("⚠️ WARNING: Egg lost or stripped at HOP %d/%d in %s!", h, hops, currentBiome))
            return false
        end

        if h < hops then
            local hopStart = os.clock()
            while Running and (os.clock() - hopStart < CHUNK_HOP_WAIT) do
                if Root and Root.Parent then
                    Root.CFrame = CFrame.new(hopPos)
                    Root.AssemblyLinearVelocity = Vector3.zero
                    Root.AssemblyAngularVelocity = Vector3.zero
                end
                RunService.Heartbeat:Wait()
            end
        end
    end
    return isHoldingEgg()
end

--==================================================
-- RUN
--==================================================

local function runTest()

    if Running then
        return
    end

    if not SavedLocation then
        Status.Text =
            "Status: Set Drop/Landing Location first"
        return
    end

    refreshCharacter()

    if not Root or not Humanoid then
        Status.Text =
            "Status: Character unavailable"
        return
    end

    if not isHoldingEgg() then
        Status.Text = "Status: Fast picking up egg..."
        log("No egg carried. Executing fast pickup (targeting closest egg within 45 studs)...")
        pickupNearbyEgg(45.0, 5)
        if not isHoldingEgg() then
            Status.Text = "Status: No nearby egg found!"
            log("⚠️ Aborted: No nearby egg found within 45 studs! Stand closer to an egg or pick one up.")
            return
        end
        log("✓ Successfully picked up egg via fast pickup spam!")
    end

    Running = true
    RunToken += 1
    local currentRunToken = RunToken
    TestStartTime = os.clock()
    LastTrace = 0

    --------------------------------------------------
    -- START
    --------------------------------------------------

    StartLocation = Root.Position

    log("----------------------------------------")
    log("TEST START")

    local startBiome = getBiomeName(StartLocation)
    local dropBiome = getBiomeName(SavedLocation)
    local distToDrop = (StartLocation - SavedLocation).Magnitude

    log(string.format("START = %s %s", startBiome, vec(StartLocation)))
    log(string.format("DROP / LANDING = %s %s", dropBiome, vec(SavedLocation)))
    log(string.format("ROUTE: Carrying egg from %s -> traveling to %s (dist=%.0f studs)", startBiome, dropBiome, distToDrop))

    --------------------------------------------------
    -- FOREST STRIKE (FIRST TRIGGER ON RUN)
    --------------------------------------------------

    Phase = "FOREST STRIKE"
    Status.Text =
        "Status: Forest Strike"

    log("PHASE = FOREST STRIKE")

    fireForestStrike()

    -- For biomes above Snow (dist > 900), allow 0.10s for server strike authority replication across the map
    local dispatchWait = (distToDrop > 900) and 0.10 or 0.05
    log(string.format("Strike dispatched. Waiting %.2fs for authority before travel...", dispatchWait))
    task.wait(dispatchWait)

    nullifyRagdoll()

    --------------------------------------------------
    -- POSITION AT DROP (Chunked travel <= 800 studs per hop)
    --------------------------------------------------

    Phase = "DROP POSITION"
    Status.Text =
        "Status: Traveling to dropzone..."

    log(string.format("PHASE = DROP POSITION (Traveling to %s)", dropBiome))

    if pinConn then
        pcall(function() pinConn:Disconnect() end)
        pinConn = nil
    end

    -- Travel in hops <= 800 studs so server physics replication accepts every jump
    local travelOk = travelInChunks(StartLocation, SavedLocation)
    if not travelOk or not isHoldingEgg() then
        Status.Text = "Status: Egg lost during travel!"
        log("❌ Aborted: Egg was confiscated or dropped during travel. Step aborted.")
        stopTest()
        return
    end

    -- Pin Root to SavedLocation continuously on Heartbeat so server physics
    -- cannot rubberband the character back to origin during the drop sequence
    pinConn = RunService.Heartbeat:Connect(function()
        if Root and Root.Parent then
            Root.CFrame = CFrame.new(SavedLocation)
            Root.AssemblyLinearVelocity = Vector3.zero
            Root.AssemblyAngularVelocity = Vector3.zero
        end
    end)

    Root.CFrame =
        CFrame.new(SavedLocation)

    Root.AssemblyLinearVelocity =
        Vector3.zero

    Root.AssemblyAngularVelocity =
        Vector3.zero

    nullifyRagdoll()

    log(string.format("DROP POSITIONED | biome=%s | pos=%s", getBiomeName(Root.Position), vec(Root.Position)))

    -- Refresh ForestStrike authority directly at destination dropzone
    -- Ensures server has fresh active strike authority (<0.50s old) upon drop invocation,
    -- preventing cross-biome server trip validation from resetting the egg to its origin nest.
    log("Refreshing ForestStrike authority at destination dropzone...")
    fireForestStrike()

    -- Settle at final dropzone: 0.35s - 0.50s ensures server position replication
    -- while keeping fresh strike authority well within the server's 2.0s validity window.
    local distToDrop = (StartLocation - SavedLocation).Magnitude
    local settleDuration = 0.35
    if distToDrop > 5500 then
        settleDuration = 0.50 -- Enchanted Forest (~6,100 studs)
    elseif distToDrop > 4500 then
        settleDuration = 0.45 -- Light Dark (~5,100 studs)
    elseif distToDrop > 3500 then
        settleDuration = 0.40 -- Titan Temple (~4,200 studs - proven working 1-shot)
    elseif distToDrop > 2500 then
        settleDuration = 0.35 -- Cosmic (~2,800 studs - proven working 1-shot)
    elseif distToDrop > 1500 then
        settleDuration = 0.35 -- Abyss Ocean (~1,700 studs - proven working 1-shot)
    end

    Status.Text = "Status: Replicating position..."
    log(string.format("HOLD / REPLICATING POSITION (%.2fs for %.0f studs)...", settleDuration, distToDrop))

    local settleStart = os.clock()
    while Running and (os.clock() - settleStart < settleDuration) do
        RunService.Heartbeat:Wait()
    end

    --------------------------------------------------
    -- DROP EGG (Directly at location while pinned on Heartbeat!)
    --------------------------------------------------

    Phase = "DROP"
    Status.Text =
        "Status: Dropping egg..."

    log("PHASE = DROP")

    -- Set Freefall state (Step 4 from dropper-1.lua) so humanoid releases carried item
    if Humanoid and Humanoid.Parent then
        pcall(function()
            Humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
        end)
    end

    local dropped = invokeEggDropSpam(currentRunToken, EGG_DROP_SPAM_COUNT)

    -- Disconnect pin once drop sequence finishes
    if pinConn then
        pcall(function() pinConn:Disconnect() end)
        pinConn = nil
    end

    --------------------------------------------------
    -- LANDED
    --------------------------------------------------

    Phase = "LANDED"

    if Root and Root.Parent then
        Root.CFrame = CFrame.new(SavedLocation)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
    end

    nullifyRagdoll()

    if Humanoid and Humanoid.Parent and Humanoid.Health > 0 then
        pcall(function()
            Humanoid:ChangeState(Enum.HumanoidStateType.Running)
        end)
    end

    if dropped or not isCarryingEgg then
        Status.Text = "Status: Egg Dropped Successfully!"
        log("SUCCESS: Egg dropped at landing location!")
    else
        Status.Text = "Status: Drop Finished"
        log("Egg drop sequence finished.")
    end

    log(
        "LANDED | final="
        .. vec(Root.Position)
    )

    log(
        "START="
        .. vec(StartLocation)
    )

    log(
        "DROP/LANDING="
        .. vec(SavedLocation)
    )

    log(
        "TOTAL TIME="
        .. string.format(
            "%.4f",
            os.clock() - TestStartTime
        )
    )

    Running = false
    log("TEST END")
    log("----------------------------------------")
end

RunButton.MouseButton1Click:Connect(runTest)

CopyButton.MouseButton1Click:Connect(copyLog)

--==================================================
-- INIT
--==================================================

log("One-location Direct Drop Tester loaded")
log("Landing location preset to " .. vec(SavedLocation))
log("RUN automatically captures START location")
log("Strike confirms Hit Authority -> direct set to location -> settle -> drop")
log(string.format("Position settles (%.2fs) then EggDrop (%dx)", POSITION_SETTLE_TIME, EGG_DROP_SPAM_COUNT))

-- Automatically query egg UID on script startup
task.defer(function()
    refreshEggUid()
end)