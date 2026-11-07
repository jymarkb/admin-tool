-- ====================================================================
-- EGG DROP CODE TESTER (STANDALONE)
-- Simple UI to test ONLY the drop remote code without teleport or toll.
-- ====================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui", 5) or Player:FindFirstChild("PlayerGui")

-- Determine GUI parent (CoreGui / gethui / PlayerGui)
local guiParent = PlayerGui
pcall(function()
    if typeof(gethui) == "function" then
        guiParent = gethui()
    elseif CoreGui then
        guiParent = CoreGui
    end
end)

-- Clean up any existing instance
local existing = guiParent:FindFirstChild("SimpleEggDropTestGui")
if existing then
    existing:Destroy()
end

-- ====================================================================
-- STATE & LOGGING
-- ====================================================================

local isCarryingEgg = false
local carriedEggUid = nil
local isInvoking = false

local function getRemote(subPath)
    local packages = ReplicatedStorage:FindFirstChild("Packages")
        or ReplicatedStorage:WaitForChild("Packages", 5)
    local networking = packages and (
        packages:FindFirstChild("Networking")
        or packages:WaitForChild("Networking", 5)
    )
    if not networking then return nil end

    local flattened = networking:FindFirstChild(subPath)
    if flattened then return flattened end

    local current = networking
    for segment in string.gmatch(subPath, "[^/]+") do
        current = current and current:FindFirstChild(segment)
    end
    if current then return current end

    local leaf = string.match(subPath, "[^/]+$")
    for _, item in ipairs(networking:GetDescendants()) do
        if item.Name == subPath or item.Name == leaf then
            return item
        end
    end
    return nil
end

-- ====================================================================
-- UI CREATION
-- ====================================================================

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "SimpleEggDropTestGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = guiParent

local Frame = Instance.new("Frame")
Frame.Size = UDim2.fromOffset(280, 240)
Frame.Position = UDim2.new(0.5, -140, 0.4, -120)
Frame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
Frame.BorderSizePixel = 0
Frame.Parent = ScreenGui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0, 8)
Corner.Parent = Frame

-- Title Bar
local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 32)
TitleBar.BackgroundColor3 = Color3.fromRGB(38, 38, 48)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = Frame

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 8)
TitleCorner.Parent = TitleBar

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -40, 1, 0)
Title.Position = UDim2.fromOffset(10, 0)
Title.BackgroundTransparency = 1
Title.Text = "Egg Drop Remote Tester"
Title.TextColor3 = Color3.fromRGB(240, 240, 240)
Title.TextSize = 14
Title.Font = Enum.Font.SourceSansBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = TitleBar

-- Close Button
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.fromOffset(24, 24)
CloseBtn.Position = UDim2.new(1, -28, 0, 4)
CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "X"
CloseBtn.TextColor3 = Color3.new(1, 1, 1)
CloseBtn.TextSize = 13
CloseBtn.Font = Enum.Font.SourceSansBold
CloseBtn.Parent = TitleBar

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 6)
CloseCorner.Parent = CloseBtn

CloseBtn.MouseButton1Click:Connect(function()
    ScreenGui:Destroy()
end)

-- Draggable
local dragging, dragStart, startPos = false, nil, nil
TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = Frame.Position
    end
end)
TitleBar.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        Frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

-- Status Label
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -16, 0, 24)
StatusLabel.Position = UDim2.fromOffset(8, 38)
StatusLabel.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
StatusLabel.BorderSizePixel = 0
StatusLabel.Text = "Carrying: NO"
StatusLabel.TextColor3 = Color3.fromRGB(220, 100, 100)
StatusLabel.TextSize = 13
StatusLabel.Font = Enum.Font.SourceSansBold
StatusLabel.Parent = Frame

local StatusCorner = Instance.new("UICorner")
StatusCorner.CornerRadius = UDim.new(0, 6)
StatusCorner.Parent = StatusLabel

-- Single Drop Button
local SingleBtn = Instance.new("TextButton")
SingleBtn.Size = UDim2.new(1, -16, 0, 32)
SingleBtn.Position = UDim2.fromOffset(8, 68)
SingleBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 200)
SingleBtn.BorderSizePixel = 0
SingleBtn.Text = "TRIGGER DROP (1x)"
SingleBtn.TextColor3 = Color3.new(1, 1, 1)
SingleBtn.TextSize = 13
SingleBtn.Font = Enum.Font.SourceSansBold
SingleBtn.Parent = Frame

local SingleCorner = Instance.new("UICorner")
SingleCorner.CornerRadius = UDim.new(0, 6)
SingleCorner.Parent = SingleBtn

-- Spam Drop Button (5x)
local SpamBtn = Instance.new("TextButton")
SpamBtn.Size = UDim2.new(1, -16, 0, 32)
SpamBtn.Position = UDim2.fromOffset(8, 106)
SpamBtn.BackgroundColor3 = Color3.fromRGB(160, 90, 30)
SpamBtn.BorderSizePixel = 0
SpamBtn.Text = "TRIGGER DROP SPAM (5x)"
SpamBtn.TextColor3 = Color3.new(1, 1, 1)
SpamBtn.TextSize = 13
SpamBtn.Font = Enum.Font.SourceSansBold
SpamBtn.Parent = Frame

local SpamCorner = Instance.new("UICorner")
SpamCorner.CornerRadius = UDim.new(0, 6)
SpamCorner.Parent = SpamBtn

-- Log Output Label
local LogLabel = Instance.new("TextLabel")
LogLabel.Size = UDim2.new(1, -16, 0, 88)
LogLabel.Position = UDim2.fromOffset(8, 144)
LogLabel.BackgroundColor3 = Color3.fromRGB(15, 15, 18)
LogLabel.BorderSizePixel = 0
LogLabel.Text = "Logs will appear here...\nPick up an egg and click a drop button."
LogLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
LogLabel.TextSize = 11
LogLabel.Font = Enum.Font.SourceSans
LogLabel.TextXAlignment = Enum.TextXAlignment.Left
LogLabel.TextYAlignment = Enum.TextYAlignment.Top
LogLabel.TextWrapped = true
LogLabel.Parent = Frame

local LogCorner = Instance.new("UICorner")
LogCorner.CornerRadius = UDim.new(0, 6)
LogCorner.Parent = LogLabel

-- Log history helper
local logHistory = {}
local function addLog(msg)
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] %s", timestamp, msg)
    print("[DropTest] " .. line)
    table.insert(logHistory, 1, line)
    while #logHistory > 5 do
        table.remove(logHistory)
    end
    LogLabel.Text = table.concat(logHistory, "\n")
end

local function updateCarryDisplay()
    if isCarryingEgg then
        local uidStr = carriedEggUid and (" (UID: " .. tostring(carriedEggUid) .. ")") or ""
        StatusLabel.Text = "Carrying: YES" .. uidStr
        StatusLabel.TextColor3 = Color3.fromRGB(100, 230, 120)
    else
        StatusLabel.Text = "Carrying: NO"
        StatusLabel.TextColor3 = Color3.fromRGB(220, 100, 100)
    end
end

-- ====================================================================
-- EVENT LISTENERS
-- ====================================================================

task.defer(function()
    local carryRemote = getRemote("RE/EggWorld/FieldEggCarry")
    if carryRemote and carryRemote:IsA("RemoteEvent") then
        carryRemote.OnClientEvent:Connect(function(payload)
            if typeof(payload) == "table" then
                if payload.IsCarrying ~= nil then
                    isCarryingEgg = payload.IsCarrying
                    local uid = payload.Uid or payload.EggUid or payload.uid or payload.UID
                    if uid then carriedEggUid = tostring(uid) end
                    if payload.IsCarrying == false then carriedEggUid = nil end
                    updateCarryDisplay()
                    addLog(string.format("FieldEggCarry -> IsCarrying=%s", tostring(payload.IsCarrying)))
                end
            end
        end)
    end

    local ownerDroppedRemote = getRemote("RE/EggWorld/OwnerDropped")
    if ownerDroppedRemote and ownerDroppedRemote:IsA("RemoteEvent") then
        ownerDroppedRemote.OnClientEvent:Connect(function(payload)
            isCarryingEgg = false
            carriedEggUid = nil
            updateCarryDisplay()
            addLog("OwnerDropped event fired -> Egg dropped!")
        end)
    end
end)

-- Check character tool/model for initial carry state
task.defer(function()
    local char = Player.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") or (child:IsA("Model") and string.find(string.lower(child.Name), "egg", 1, true)) then
                isCarryingEgg = true
                updateCarryDisplay()
                break
            end
        end
    end
end)

-- ====================================================================
-- DROP INVOCATION LOGIC
-- ====================================================================

local function invokeDropOnce(attemptIndex, totalAttempts)
    local remote = getRemote("RF/EggWorld/AskFieldEggDrop")
    if not remote then
        addLog("ERROR: AskFieldEggDrop remote not found")
        return false, "RemoteNotFound"
    end

    local prefix = totalAttempts and string.format("[#%d/%d] ", attemptIndex, totalAttempts) or ""
    local t0 = os.clock()
    local ok, result = pcall(function()
        return remote:InvokeServer({ Reason = "PlayerRequest" })
    end)
    local elapsedMs = math.floor((os.clock() - t0) * 1000)

    if ok then
        addLog(string.format("%sInvoke(PlayerRequest) in %dms -> %s", prefix, elapsedMs, tostring(result)))
        -- Fallback attempt without arguments if server rejected PlayerRequest
        if result == false then
            local ok2, res2 = pcall(function()
                return remote:InvokeServer()
            end)
            addLog(string.format("%sFallback Invoke() -> %s", prefix, tostring(res2)))
        end
    else
        addLog(string.format("%sERROR in %dms -> %s", prefix, elapsedMs, tostring(result)))
    end

    return ok, result
end

-- Single button trigger
SingleBtn.MouseButton1Click:Connect(function()
    if isInvoking then
        addLog("Drop invocation already in progress...")
        return
    end
    isInvoking = true
    SingleBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 140)

    task.spawn(function()
        addLog("Triggering single drop...")
        invokeDropOnce(1, 1)
        task.wait(0.2)
        SingleBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 200)
        isInvoking = false
    end)
end)

-- Spam button trigger (5x)
SpamBtn.MouseButton1Click:Connect(function()
    if isInvoking then
        addLog("Drop invocation already in progress...")
        return
    end
    isInvoking = true
    SpamBtn.BackgroundColor3 = Color3.fromRGB(110, 60, 20)

    task.spawn(function()
        local count = 5
        local delaySeconds = 0.1
        addLog(string.format("Triggering spam drop (%dx, %.1fs delay)...", count, delaySeconds))

        for i = 1, count do
            invokeDropOnce(i, count)
            if not isCarryingEgg and i > 1 then
                addLog("✓ Egg dropped confirmed! Stopping spam.")
                break
            end
            if i < count then
                task.wait(delaySeconds)
            end
        end

        task.wait(0.2)
        SpamBtn.BackgroundColor3 = Color3.fromRGB(160, 90, 30)
        isInvoking = false
    end)
end)

addLog("Tester ready. Pick up egg and click Drop.")
