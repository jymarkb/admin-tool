--[[
    Speed Velocity UI (Standalone)
    ===========================================================================
    A simple, lightweight, standalone UI for controlling player speed velocity.
    - Single unified speed input (no dual go/carry speeds).
    - Instant ON/OFF velocity toggle.
    - Direct AssemblyLinearVelocity physics + Humanoid.WalkSpeed sync.
    - Draggable clean mini-interface.
    - Connection tracking and safe cleanup (_G.SpeedVelocityUI_Cleanup).
    ===========================================================================
]]

-- Safe cleanup of any previous running instance
if _G.SpeedVelocityUI_Cleanup then
    pcall(_G.SpeedVelocityUI_Cleanup)
end

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local t0 = os.clock()
    while not LocalPlayer and (os.clock() - t0 < 3) do
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    end
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

-- Resolve safe UI Parent (gethui -> CoreGui -> PlayerGui)
local PlayerGui
do
    local function getSafeUiParent()
        if typeof(gethui) == "function" then
            local okHui, h = pcall(gethui)
            if okHui and h then return h end
        end
        local okCore, core = pcall(function() return game:GetService("CoreGui") end)
        if okCore and core then
            local okTest = pcall(function() local f = Instance.new("Folder", core); f:Destroy() end)
            if okTest then return core end
        end
        return (LocalPlayer and (LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5))) or game:GetService("CoreGui")
    end
    PlayerGui = getSafeUiParent()
end

-- Connection management
local connections = {}
local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

local function disconnectAll()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)
end

-- State variables
local velocityEnabled = false
local baseSpeed = 350
local savedWalkSpeed = 16.0

pcall(function()
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed > 0 and hum.WalkSpeed < 100 then
        savedWalkSpeed = hum.WalkSpeed
    end
end)

-- ============================================================================
-- UI CREATION
-- ============================================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SpeedVelocityUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

-- Main Card Frame
local main = Instance.new("Frame")
main.Name = "MainFrame"
main.Size = UDim2.new(0, 230, 0, 116)
main.Position = UDim2.new(0.5, -115, 0.25, 0)
main.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
main.BorderSizePixel = 0
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(60, 95, 155)
mainStroke.Thickness = 1.5

-- Title Bar (Draggable)
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 28)
titleBar.BackgroundColor3 = Color3.fromRGB(30, 38, 56)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleCornerFix = Instance.new("Frame")
titleCornerFix.Name = "CornerFix"
titleCornerFix.Size = UDim2.new(1, 0, 0, 8)
titleCornerFix.Position = UDim2.new(0, 0, 1, -8)
titleCornerFix.BackgroundColor3 = Color3.fromRGB(30, 38, 56)
titleCornerFix.BorderSizePixel = 0
titleCornerFix.Parent = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "TitleLabel"
titleLabel.Size = UDim2.new(1, -36, 1, 0)
titleLabel.Position = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "⚡ Speed Velocity"
titleLabel.TextColor3 = Color3.fromRGB(220, 235, 255)
titleLabel.TextSize = 12
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = titleBar

-- Close Button
local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseBtn"
closeBtn.Size = UDim2.new(0, 20, 0, 20)
closeBtn.Position = UDim2.new(1, -24, 0.5, -10)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 11
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

-- Draggable title bar
do
    local dragging, dragStart, startPos = false, nil, nil
    addConnection(titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
        end
    end))

    addConnection(titleBar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    addConnection(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))
end

-- Row 1: On/Off Toggle Button
local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "ToggleBtn"
toggleBtn.Size = UDim2.new(1, -16, 0, 26)
toggleBtn.Position = UDim2.new(0, 8, 0, 34)
toggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
toggleBtn.Text = "[OFF] Velocity Disabled"
toggleBtn.TextColor3 = Color3.fromRGB(200, 215, 240)
toggleBtn.TextSize = 11
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.Parent = main
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 5)

-- Row 2: Speed Input Field
local speedFrame = Instance.new("Frame")
speedFrame.Name = "SpeedFrame"
speedFrame.Size = UDim2.new(1, -16, 0, 24)
speedFrame.Position = UDim2.new(0, 8, 0, 65)
speedFrame.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
speedFrame.BorderSizePixel = 0
speedFrame.Parent = main
Instance.new("UICorner", speedFrame).CornerRadius = UDim.new(0, 5)

local speedStroke = Instance.new("UIStroke", speedFrame)
speedStroke.Color = Color3.fromRGB(50, 70, 100)
speedStroke.Thickness = 1

local speedLabel = Instance.new("TextLabel")
speedLabel.Name = "SpeedLabel"
speedLabel.Size = UDim2.new(0, 55, 1, 0)
speedLabel.Position = UDim2.new(0, 8, 0, 0)
speedLabel.BackgroundTransparency = 1
speedLabel.Text = "Speed:"
speedLabel.TextColor3 = Color3.fromRGB(160, 185, 220)
speedLabel.TextSize = 11
speedLabel.Font = Enum.Font.GothamBold
speedLabel.TextXAlignment = Enum.TextXAlignment.Left
speedLabel.Parent = speedFrame

local speedBox = Instance.new("TextBox")
speedBox.Name = "SpeedBox"
speedBox.Size = UDim2.new(1, -65, 1, 0)
speedBox.Position = UDim2.new(0, 60, 0, 0)
speedBox.BackgroundTransparency = 1
speedBox.Text = tostring(baseSpeed)
speedBox.PlaceholderText = "350"
speedBox.TextColor3 = Color3.new(1, 1, 1)
speedBox.TextSize = 11
speedBox.Font = Enum.Font.GothamBold
speedBox.ClearTextOnFocus = false
speedBox.TextXAlignment = Enum.TextXAlignment.Center
speedBox.Parent = speedFrame

-- Row 3: Live Status Readout
local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.Size = UDim2.new(1, -16, 0, 16)
statusLabel.Position = UDim2.new(0, 8, 0, 93)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Status: Disabled (WalkSpeed 16)"
statusLabel.TextColor3 = Color3.fromRGB(140, 155, 180)
statusLabel.TextSize = 10
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextXAlignment = Enum.TextXAlignment.Center
statusLabel.Parent = main

-- ============================================================================
-- ENGINE & EVENT HANDLERS
-- ============================================================================

local function updateStatus()
    if not statusLabel then return end
    if velocityEnabled then
        statusLabel.Text = string.format("Status: Velocity Active (%d studs/s)", baseSpeed)
        statusLabel.TextColor3 = Color3.fromRGB(100, 230, 255)
    else
        local norm = (savedWalkSpeed and savedWalkSpeed < 100) and savedWalkSpeed or 16.0
        statusLabel.Text = string.format("Status: Disabled (Normal WalkSpeed %.0f)", norm)
        statusLabel.TextColor3 = Color3.fromRGB(140, 155, 180)
    end
end

local function disableVelocity()
    velocityEnabled = false
    toggleBtn.Text = "[OFF] Velocity Disabled"
    toggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
    toggleBtn.TextColor3 = Color3.fromRGB(200, 215, 240)

    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        local normalSpeed = (savedWalkSpeed and savedWalkSpeed < 100) and savedWalkSpeed or 16.0
        pcall(function() hum.WalkSpeed = normalSpeed end)
    end
    updateStatus()
end

local function enableVelocity()
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed > 0 and hum.WalkSpeed < 100 then
        savedWalkSpeed = hum.WalkSpeed
    end
    velocityEnabled = true
    toggleBtn.Text = "[ON] Velocity Active"
    toggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    toggleBtn.TextColor3 = Color3.new(1, 1, 1)

    if hum then
        pcall(function() hum.WalkSpeed = baseSpeed end)
    end
    updateStatus()
end

-- Physics Loop
local function updateVelocityPhysics()
    if not velocityEnabled then return end
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp and hrp.Parent and hum.Health > 0) then return end

    if hum.MoveDirection.Magnitude > 0.05 then
        local dir = hum.MoveDirection.Unit
        hrp.AssemblyLinearVelocity = Vector3.new(
            dir.X * baseSpeed,
            hrp.AssemblyLinearVelocity.Y,
            dir.Z * baseSpeed
        )
        if hum.WalkSpeed ~= baseSpeed then
            pcall(function() hum.WalkSpeed = baseSpeed end)
        end
    end
end

-- Listeners
addConnection(toggleBtn.MouseButton1Click:Connect(function()
    if velocityEnabled then
        disableVelocity()
    else
        enableVelocity()
    end
end))

addConnection(speedBox.FocusLost:Connect(function()
    local val = tonumber(speedBox.Text)
    if val and val > 0 then
        baseSpeed = math.clamp(math.floor(val), 16, 500)
    end
    speedBox.Text = tostring(baseSpeed)

    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and velocityEnabled then
        pcall(function() hum.WalkSpeed = baseSpeed end)
    end
    updateStatus()
end))

addConnection(RunService.Heartbeat:Connect(updateVelocityPhysics))

addConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
    local hum = newChar:WaitForChild("Humanoid", 5)
    if hum then
        if not velocityEnabled then
            if hum.WalkSpeed > 0 and hum.WalkSpeed < 100 then
                savedWalkSpeed = hum.WalkSpeed
            else
                savedWalkSpeed = 16.0
            end
        else
            pcall(function() hum.WalkSpeed = baseSpeed end)
        end
    end
    updateStatus()
end))

-- Cleanup routine
local function cleanup()
    disconnectAll()
    disableVelocity()
    if screenGui and screenGui.Parent then
        screenGui:Destroy()
    end
    if _G.SpeedVelocityUI_Cleanup == cleanup then
        _G.SpeedVelocityUI_Cleanup = nil
    end
end

addConnection(closeBtn.MouseButton1Click:Connect(cleanup))
_G.SpeedVelocityUI_Cleanup = cleanup

updateStatus()
