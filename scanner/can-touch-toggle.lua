--[[
    CAN TOUCH TOGGLE CONTROLLER
    ===========================
    Allows toggling CanTouch on local character parts.
    
    Why:
      - CanTouch = false prevents physics .Touched events from firing.
      - Protects against server/client guard hitboxes (Guard.Collider),
        damage zones, and touch-based traps without breaking floor collisions.
      - Can be toggled back ON whenever you need to touch base deposit pads or buttons.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait(0.1)
    LocalPlayer = Players.LocalPlayer
end

-- ========================================================================
-- UI CREATION
-- ========================================================================

local GUI_NAME = "CanTouchToggleUI"
pcall(function()
    if CoreGui:FindFirstChild(GUI_NAME) then CoreGui[GUI_NAME]:Destroy() end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg and pg:FindFirstChild(GUI_NAME) then pg[GUI_NAME]:Destroy() end
end)

local uiParent = CoreGui
pcall(function() local _ = CoreGui.Name end)
local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.DisplayOrder = 99999

local parented = pcall(function() gui.Parent = uiParent end)
if not parented or not gui.Parent then
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local W, H = 280, 160
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.35, -H/2)
main.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(65, 75, 110)
mainStroke.Thickness = 1.5

-- Title Bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = Color3.fromRGB(26, 30, 42)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -36, 1, 0)
titleLbl.Position = UDim2.new(0, 10, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🛡️ CAN TOUCH CONTROLLER"
titleLbl.TextColor3 = Color3.fromRGB(220, 230, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 11.5
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 22, 0, 22)
closeBtn.Position = UDim2.new(1, -26, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 60)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 11
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

-- Main Toggle Button
local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(1, -20, 0, 44)
toggleBtn.Position = UDim2.new(0, 10, 0, 40)
toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 75)
toggleBtn.Text = "✅ CAN TOUCH: ON (NORMAL)"
toggleBtn.TextColor3 = Color3.new(1, 1, 1)
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 12.5
toggleBtn.Parent = main
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 6)

local toggleStroke = Instance.new("UIStroke", toggleBtn)
toggleStroke.Color = Color3.fromRGB(80, 220, 120)
toggleStroke.Thickness = 1.5

-- Mode Switcher (All Parts vs Root/Torso Only)
local modeBtn = Instance.new("TextButton")
modeBtn.Size = UDim2.new(1, -20, 0, 26)
modeBtn.Position = UDim2.new(0, 10, 0, 92)
modeBtn.BackgroundColor3 = Color3.fromRGB(35, 38, 52)
modeBtn.Text = "Scope: ALL CHARACTER PARTS"
modeBtn.TextColor3 = Color3.fromRGB(180, 200, 240)
modeBtn.Font = Enum.Font.GothamBold
modeBtn.TextSize = 10
modeBtn.Parent = main
Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0, 5)

-- Status Info Label
local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1, -20, 0, 22)
statusLbl.Position = UDim2.new(0, 10, 1, -28)
statusLbl.BackgroundTransparency = 1
statusLbl.Text = "Status: 16 parts active · Touch enabled"
statusLbl.TextColor3 = Color3.fromRGB(150, 160, 185)
statusLbl.Font = Enum.Font.Gotham
statusLbl.TextSize = 9.5
statusLbl.TextXAlignment = Enum.TextXAlignment.Center
statusLbl.Parent = main

-- ========================================================================
-- LOGIC & ENFORCEMENT
-- ========================================================================

local canTouchState = true -- true = normal, false = disabled (no touch)
local scopeAllParts = true -- true = all BaseParts, false = Root & Torso only
local running = true

local function shouldAffectPart(p)
    if not p:IsA("BasePart") then return false end
    if scopeAllParts then return true end
    
    local nm = p.Name:lower()
    return nm:find("root") or nm:find("torso") or nm == "head"
end

local function applyCanTouch()
    local char = LocalPlayer.Character
    if not char then
        statusLbl.Text = "Status: Waiting for character..."
        return
    end

    local count = 0
    local total = 0
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA("BasePart") then
            total = total + 1
            if shouldAffectPart(obj) then
                if obj.CanTouch ~= canTouchState then
                    pcall(function() obj.CanTouch = canTouchState end)
                end
                count = count + 1
            end
        end
    end

    if canTouchState then
        statusLbl.Text = string.format("Status: %d/%d parts CAN TOUCH [ON]", count, total)
        statusLbl.TextColor3 = Color3.fromRGB(140, 230, 160)
    else
        statusLbl.Text = string.format("Status: %d/%d parts PROTECTED [OFF]", count, total)
        statusLbl.TextColor3 = Color3.fromRGB(255, 170, 120)
    end
end

local function updateUI()
    if canTouchState then
        toggleBtn.Text = "✅ CAN TOUCH: ON (NORMAL)"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 75)
        toggleStroke.Color = Color3.fromRGB(80, 220, 120)
    else
        toggleBtn.Text = "🛡️ CAN TOUCH: OFF (PROTECTED)"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(195, 60, 45)
        toggleStroke.Color = Color3.fromRGB(255, 110, 90)
    end

    if scopeAllParts then
        modeBtn.Text = "Scope: ALL CHARACTER PARTS"
        modeBtn.TextColor3 = Color3.fromRGB(180, 210, 255)
    else
        modeBtn.Text = "Scope: ROOT & TORSO ONLY"
        modeBtn.TextColor3 = Color3.fromRGB(255, 215, 140)
    end

    applyCanTouch()
end

-- Button Listeners
toggleBtn.MouseButton1Click:Connect(function()
    canTouchState = not canTouchState
    updateUI()
end)

modeBtn.MouseButton1Click:Connect(function()
    scopeAllParts = not scopeAllParts
    updateUI()
end)

closeBtn.MouseButton1Click:Connect(function()
    running = false
    -- Restore CanTouch to true before closing
    canTouchState = true
    pcall(applyCanTouch)
    if gui then gui:Destroy() end
end)

-- Continuous Enforcer:
-- Games often reset CanTouch when equipping tools, ragdolling, or reloading animations.
task.spawn(function()
    while running do
        task.wait(0.25)
        if not canTouchState then
            pcall(applyCanTouch)
        end
    end
end)

-- Re-apply on Character Respawn
LocalPlayer.CharacterAdded:Connect(function(newChar)
    task.wait(0.3)
    if running then
        pcall(applyCanTouch)
    end
end)

-- Initial run
updateUI()
print("[CanTouchToggle] UI Loaded successfully.")
