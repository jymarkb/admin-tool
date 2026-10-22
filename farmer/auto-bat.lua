--[[
    AUTO MULTI-BAT / TOOL SWING  (Faster)
    Cycles & equips the tools in the list, then fires ToolTrigger
]]

local ok, err = pcall(function()

if _G.AutoMultiSwing_Cleanup then pcall(_G.AutoMultiSwing_Cleanup) end
_G.AutoMultiSwing_Cleanup = nil

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

-- ======================
-- EASY EDIT LIST
-- ======================
local TOOLS = {
    "Titan Axe [X1]",
    "The Scrambler [X1]",
    "Cricket's Banjo [X1]",
    "Scramble Sword [X1]",
}

local SWING_DELAY = 0.03          -- very fast (was 0.15)
local EQUIP_DELAY = 0.02          -- tiny delay after equip

-- ======================
-- REMOTE
-- ======================
local function getNet(name)
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

local RE_ToolTrigger = getNet("RE/ToolTrigger/Trigger")
if not RE_ToolTrigger then
    error("RE/ToolTrigger/Trigger not found")
end

-- ======================
-- STATE
-- ======================
local enabled = false
local swinging = false
local swingCount = 0
local currentIndex = 1

-- ======================
-- HELPERS
-- ======================
local function findTool(name)
    local char = lp.Character
    if char then
        local t = char:FindFirstChild(name)
        if t and t:IsA("Tool") then return t end
    end
    local bp = lp:FindFirstChild("Backpack")
    if bp then
        local t = bp:FindFirstChild(name)
        if t and t:IsA("Tool") then return t end
    end
    return nil
end

local function equipTool(tool)
    if not tool then return false end
    local humanoid = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    pcall(function()
        humanoid:EquipTool(tool)
    end)
    return true
end

-- ======================
-- UI
-- ======================
local function getSafeParent()
    if typeof(gethui) == "function" then
        local a, b = pcall(gethui)
        if a and b then return b end
    end
    local a, b = pcall(function() return game:GetService("CoreGui") end)
    if a and b then return b end
    return pg
end

local gui = Instance.new("ScreenGui")
gui.Name = "AutoMultiSwing"
gui.ResetOnSpawn = false
gui.Parent = getSafeParent()

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 280, 0, 150)
frame.Position = UDim2.new(1, -300, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(220, 140, 60)
stroke.Thickness = 1.5
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -50, 0, 26)
title.Position = UDim2.new(0, 10, 0, 4)
title.BackgroundTransparency = 1
title.Text = "🏏 Multi-Bat Swing"
title.TextColor3 = Color3.fromRGB(255, 190, 100)
title.TextSize = 14
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 22)
closeBtn.Position = UDim2.new(1, -34, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(150, 45, 45)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 18)
status.Position = UDim2.new(0, 8, 0, 34)
status.BackgroundTransparency = 1
status.Text = "Ready"
status.TextColor3 = Color3.fromRGB(200, 200, 160)
status.TextSize = 12
status.Font = Enum.Font.Gotham
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame

local toolLabel = Instance.new("TextLabel")
toolLabel.Size = UDim2.new(1, -16, 0, 16)
toolLabel.Position = UDim2.new(0, 8, 0, 54)
toolLabel.BackgroundTransparency = 1
toolLabel.Text = "Current: -"
toolLabel.TextColor3 = Color3.fromRGB(180, 200, 220)
toolLabel.TextSize = 11
toolLabel.Font = Enum.Font.Code
toolLabel.TextXAlignment = Enum.TextXAlignment.Left
toolLabel.Parent = frame

local countLabel = Instance.new("TextLabel")
countLabel.Size = UDim2.new(1, -16, 0, 16)
countLabel.Position = UDim2.new(0, 8, 0, 72)
countLabel.BackgroundTransparency = 1
countLabel.Text = "Swings: 0"
countLabel.TextColor3 = Color3.fromRGB(180, 200, 160)
countLabel.TextSize = 11
countLabel.Font = Enum.Font.Gotham
countLabel.TextXAlignment = Enum.TextXAlignment.Left
countLabel.Parent = frame

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(0, 120, 0, 28)
startBtn.Position = UDim2.new(0, 12, 1, -40)
startBtn.BackgroundColor3 = Color3.fromRGB(180, 110, 40)
startBtn.Text = "START"
startBtn.TextColor3 = Color3.new(1,1,1)
startBtn.TextSize = 13
startBtn.Font = Enum.Font.GothamBold
startBtn.Parent = frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 6)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0, 120, 0, 28)
stopBtn.Position = UDim2.new(1, -132, 1, -40)
stopBtn.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
stopBtn.Text = "STOP"
stopBtn.TextColor3 = Color3.new(1,1,1)
stopBtn.TextSize = 13
stopBtn.Font = Enum.Font.GothamBold
stopBtn.Parent = frame
Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 6)

local function setStatus(t, col)
    status.Text = t
    status.TextColor3 = col or Color3.fromRGB(200, 200, 160)
end

-- ======================
-- SWING LOOP (fast)
-- ======================
local function startSwinging()
    if swinging then return end
    swinging = true
    enabled = true

    task.spawn(function()
        while enabled do
            local toolName = TOOLS[currentIndex]
            local tool = findTool(toolName)

            if tool then
                equipTool(tool)
                task.wait(EQUIP_DELAY)

                local fireOk = pcall(function()
                    RE_ToolTrigger:FireServer(tool)
                end)

                if fireOk then
                    swingCount += 1
                    countLabel.Text = "Swings: " .. swingCount
                    toolLabel.Text = "Current: " .. toolName
                    setStatus("Swinging: " .. toolName, Color3.fromRGB(255, 200, 100))
                else
                    setStatus("Fire failed: " .. toolName, Color3.fromRGB(255, 120, 80))
                end
            else
                setStatus("Missing: " .. toolName, Color3.fromRGB(255, 140, 80))
                toolLabel.Text = "Current: " .. toolName .. " (not found)"
            end

            currentIndex = currentIndex + 1
            if currentIndex > #TOOLS then
                currentIndex = 1
            end

            task.wait(SWING_DELAY)
        end
        swinging = false
        setStatus("Stopped", Color3.fromRGB(200, 180, 100))
    end)
end

-- ======================
-- BUTTONS
-- ======================
startBtn.MouseButton1Click:Connect(function()
    enabled = true
    stroke.Color = Color3.fromRGB(220, 160, 60)
    startSwinging()
end)

stopBtn.MouseButton1Click:Connect(function()
    enabled = false
    stroke.Color = Color3.fromRGB(120, 90, 50)
    setStatus("Stopping...", Color3.fromRGB(200, 180, 100))
end)

local function cleanup()
    enabled = false
    if gui then pcall(function() gui:Destroy() end) end
end
_G.AutoMultiSwing_Cleanup = cleanup
closeBtn.MouseButton1Click:Connect(cleanup)

setStatus("Ready – press START", Color3.fromRGB(200, 200, 160))
toolLabel.Text = "Tools: " .. #TOOLS

end)

if not ok then
    warn("[AutoMultiSwing] " .. tostring(err))
end