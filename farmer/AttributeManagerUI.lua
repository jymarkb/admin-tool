local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

if _G.AttributeManager_Cleanup then
    pcall(_G.AttributeManager_Cleanup)
    _G.AttributeManager_Cleanup = nil
end

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer and LocalPlayer.Character

local TARGET_RAGDOLL_ATTRS = {
    "IsRagdoll",
    "RagdollEndTime",
    "RagdollTime",
    "Ragdolled",
}

local State = {
    Alive = true,
    RagdollCleaner = true,
    InHalloweenDimension = false,
}

local Connections = {}
local charConns = {}

local function deleteRagdollAttributes()
    local targets = { LocalPlayer, Character }
    for _, obj in ipairs(targets) do
        if obj and obj.Parent then
            for _, name in ipairs(TARGET_RAGDOLL_ATTRS) do
                if obj:GetAttribute(name) ~= nil then
                    obj:SetAttribute(name, nil)
                end
            end
        end
    end
end

local function setHalloweenDimension(enabled)
    State.InHalloweenDimension = enabled
    local targets = { LocalPlayer, Character }
    for _, obj in ipairs(targets) do
        if obj and obj.Parent then
            obj:SetAttribute("InHalloweenDimension", enabled)
        end
    end
end

local function toggleHalloweenDimension()
    setHalloweenDimension(not State.InHalloweenDimension)
end

-- Resolve GUI parent
local function getSafeUiParent()
    if typeof(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local okCore, core = pcall(function() return CoreGui end)
    if okCore and core then
        local okTest = pcall(function()
            local f = Instance.new("Folder", core)
            f:Destroy()
        end)
        if okTest then return core end
    end
    local pg = LocalPlayer and (LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5))
    return pg or (okCore and core or nil)
end

local parent = getSafeUiParent()
if not parent then return end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SimpleAttributeUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = parent

-- Frame (210 x 120)
local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(210, 118)
frame.Position = UDim2.new(0.5, -105, 0.4, -59)
frame.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
frame.BorderSizePixel = 0
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(55, 65, 85)
stroke.Thickness = 1
stroke.Parent = frame

-- Header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 28)
header.BackgroundColor3 = Color3.fromRGB(32, 35, 48)
header.BorderSizePixel = 0
header.Parent = frame

local hCorner = Instance.new("UICorner")
hCorner.CornerRadius = UDim.new(0, 8)
hCorner.Parent = header

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -34, 1, 0)
title.Position = UDim2.fromOffset(8, 0)
title.BackgroundTransparency = 1
title.Text = "Attributes"
title.TextColor3 = Color3.fromRGB(240, 245, 255)
title.TextSize = 12
title.Font = Enum.Font.SourceSansBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

-- Close (X) Button
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(20, 20)
closeBtn.Position = UDim2.new(1, -24, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
closeBtn.BorderSizePixel = 0
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 11
closeBtn.Font = Enum.Font.SourceSansBold
closeBtn.Parent = header

local cCorner = Instance.new("UICorner")
cCorner.CornerRadius = UDim.new(0, 5)
cCorner.Parent = closeBtn

closeBtn.MouseButton1Click:Connect(function()
    if _G.AttributeManager_Cleanup then
        _G.AttributeManager_Cleanup()
    end
end)

-- Draggable
local dragging, dragStart, startPos = false, nil, nil
table.insert(Connections, header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = frame.Position
    end
end))
table.insert(Connections, header.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end))
table.insert(Connections, UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end))

-- Ragdoll Cleaner Toggle Button
local ragdollBtn = Instance.new("TextButton")
ragdollBtn.Name = "RagdollToggleBtn"
ragdollBtn.Size = UDim2.new(1, -16, 0, 34)
ragdollBtn.Position = UDim2.fromOffset(8, 36)
ragdollBtn.BorderSizePixel = 0
ragdollBtn.Font = Enum.Font.SourceSansBold
ragdollBtn.TextSize = 12
ragdollBtn.Parent = frame

local rCorner = Instance.new("UICorner")
rCorner.CornerRadius = UDim.new(0, 6)
rCorner.Parent = ragdollBtn

-- Halloween Dimension Toggle Button
local hallowBtn = Instance.new("TextButton")
hallowBtn.Name = "HallowToggleBtn"
hallowBtn.Size = UDim2.new(1, -16, 0, 34)
hallowBtn.Position = UDim2.fromOffset(8, 76)
hallowBtn.BorderSizePixel = 0
hallowBtn.Font = Enum.Font.SourceSansBold
hallowBtn.TextSize = 12
hallowBtn.Parent = frame

local hCorner = Instance.new("UICorner")
hCorner.CornerRadius = UDim.new(0, 6)
hCorner.Parent = hallowBtn

local function updateUI()
    if State.RagdollCleaner then
        ragdollBtn.Text = "Delete Ragdoll: [ ON ]"
        ragdollBtn.BackgroundColor3 = Color3.fromRGB(46, 184, 92)
        ragdollBtn.TextColor3 = Color3.new(1, 1, 1)
    else
        ragdollBtn.Text = "Delete Ragdoll: [ OFF ]"
        ragdollBtn.BackgroundColor3 = Color3.fromRGB(45, 48, 62)
        ragdollBtn.TextColor3 = Color3.fromRGB(180, 185, 200)
    end

    if State.InHalloweenDimension then
        hallowBtn.Text = "InHalloweenDimension: [ ON ]"
        hallowBtn.BackgroundColor3 = Color3.fromRGB(255, 130, 25)
        hallowBtn.TextColor3 = Color3.new(1, 1, 1)
    else
        hallowBtn.Text = "InHalloweenDimension: [ OFF ]"
        hallowBtn.BackgroundColor3 = Color3.fromRGB(45, 48, 62)
        hallowBtn.TextColor3 = Color3.fromRGB(180, 185, 200)
    end
end

ragdollBtn.MouseButton1Click:Connect(function()
    State.RagdollCleaner = not State.RagdollCleaner
    if State.RagdollCleaner then
        deleteRagdollAttributes()
    end
    updateUI()
end)

hallowBtn.MouseButton1Click:Connect(function()
    toggleHalloweenDimension()
    updateUI()
end)

-- Reactive binding
local function bindCharacter(char)
    for _, c in ipairs(charConns) do pcall(function() c:Disconnect() end) end
    table.clear(charConns)

    if not char then return end

    table.insert(charConns, char.AttributeChanged:Connect(function(name)
        if State.RagdollCleaner then
            for _, attr in ipairs(TARGET_RAGDOLL_ATTRS) do
                if name == attr then
                    if char:GetAttribute(name) ~= nil then
                        char:SetAttribute(name, nil)
                    end
                    break
                end
            end
        end
    end))
end

if LocalPlayer then
    local initHallow = LocalPlayer:GetAttribute("InHalloweenDimension")
    if initHallow ~= nil then
        State.InHalloweenDimension = (initHallow == true)
    end

    table.insert(Connections, LocalPlayer.AttributeChanged:Connect(function(name)
        if State.RagdollCleaner then
            for _, attr in ipairs(TARGET_RAGDOLL_ATTRS) do
                if name == attr then
                    if LocalPlayer:GetAttribute(name) ~= nil then
                        LocalPlayer:SetAttribute(name, nil)
                    end
                    break
                end
            end
        end
    end))

    table.insert(Connections, LocalPlayer.CharacterAdded:Connect(function(newChar)
        Character = newChar
        bindCharacter(newChar)
        if State.RagdollCleaner then
            deleteRagdollAttributes()
        end
        if State.InHalloweenDimension ~= nil then
            newChar:SetAttribute("InHalloweenDimension", State.InHalloweenDimension)
        end
    end))
end

if Character then
    bindCharacter(Character)
end

if State.RagdollCleaner then
    deleteRagdollAttributes()
end

updateUI()

-- Background loop
task.spawn(function()
    while State.Alive do
        if State.RagdollCleaner then
            deleteRagdollAttributes()
        end
        task.wait(0.25)
    end
end)

-- Cleanup Hook
_G.AttributeManager_Cleanup = function()
    State.Alive = false
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    table.clear(Connections)
    for _, c in ipairs(charConns) do pcall(function() c:Disconnect() end) end
    table.clear(charConns)
    if screenGui and screenGui.Parent then
        screenGui:Destroy()
    end
end
