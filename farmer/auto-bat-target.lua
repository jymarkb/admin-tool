--[[
    Simple Player Bat Swing UI
    + Distance check
]]

local ok, err = pcall(function()

if _G.PlayerBatUI_Cleanup then pcall(_G.PlayerBatUI_Cleanup) end
_G.PlayerBatUI_Cleanup = nil

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

local MAX_RANGE = 32   -- studs – trigger always

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

local RE_BatSwing = getNet("RE/BatSwing/Trigger")
if not RE_BatSwing then
    error("RE/BatSwing/Trigger not found")
end

-- ======================
-- TOKEN
-- ======================
local seq = 0
local function makeToken()
    seq += 1
    local ts = math.floor(os.clock() * 1000)
    return string.format("%d:%d:%d", lp.UserId, seq, ts)
end

-- ======================
-- HELPERS
-- ======================
local function getRoot(player)
    local char = player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getDistance(player)
    local myRoot = getRoot(lp)
    local theirRoot = getRoot(player)
    if not myRoot or not theirRoot then return nil end
    return (myRoot.Position - theirRoot.Position).Magnitude
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
gui.Name = "PlayerBatUI"
gui.ResetOnSpawn = false
gui.Parent = getSafeParent()

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 300, 0, 380)
frame.Position = UDim2.new(1, -320, 0, 20)
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
title.Size = UDim2.new(1, -50, 0, 28)
title.Position = UDim2.new(0, 10, 0, 4)
title.BackgroundTransparency = 1
title.Text = "🏏 Player Bat Swing"
title.TextColor3 = Color3.fromRGB(255, 190, 100)
title.TextSize = 14
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 22)
closeBtn.Position = UDim2.new(1, -34, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(150, 45, 45)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

local refreshBtn = Instance.new("TextButton")
refreshBtn.Size = UDim2.new(0, 70, 0, 22)
refreshBtn.Position = UDim2.new(1, -110, 0, 5)
refreshBtn.BackgroundColor3 = Color3.fromRGB(50, 90, 140)
refreshBtn.Text = "Refresh"
refreshBtn.TextColor3 = Color3.new(1,1,1)
refreshBtn.TextSize = 11
refreshBtn.Font = Enum.Font.GothamBold
refreshBtn.Parent = frame
Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 4)

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -16, 1, -50)
scroll.Position = UDim2.new(0, 8, 0, 40)
scroll.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = frame
Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.Name
listLayout.Parent = scroll

local playerRows = {}  -- [player] = {row, distLabel, batBtn}

local function clearList()
    for _, data in pairs(playerRows) do
        if data.row then data.row:Destroy() end
    end
    table.clear(playerRows)
end

local function createPlayerRow(player)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -8, 0, 36)
    row.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
    row.BorderSizePixel = 0
    row.Parent = scroll
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -120, 0, 18)
    nameLabel.Position = UDim2.new(0, 8, 0, 2)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = player.Name
    nameLabel.TextColor3 = player == lp and Color3.fromRGB(120, 220, 140) or Color3.fromRGB(220, 220, 230)
    nameLabel.TextSize = 12
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Parent = row

    local distLabel = Instance.new("TextLabel")
    distLabel.Size = UDim2.new(1, -120, 0, 14)
    distLabel.Position = UDim2.new(0, 8, 0, 18)
    distLabel.BackgroundTransparency = 1
    distLabel.Text = "..."
    distLabel.TextColor3 = Color3.fromRGB(160, 170, 190)
    distLabel.TextSize = 10
    distLabel.Font = Enum.Font.Code
    distLabel.TextXAlignment = Enum.TextXAlignment.Left
    distLabel.Parent = row

    local batBtn = Instance.new("TextButton")
    batBtn.Size = UDim2.new(0, 55, 0, 26)
    batBtn.Position = UDim2.new(1, -62, 0.5, -13)
    batBtn.BackgroundColor3 = Color3.fromRGB(100, 100, 110)
    batBtn.Text = "Bat"
    batBtn.TextColor3 = Color3.new(1,1,1)
    batBtn.TextSize = 12
    batBtn.Font = Enum.Font.GothamBold
    batBtn.Parent = row
    Instance.new("UICorner", batBtn).CornerRadius = UDim.new(0, 4)

    batBtn.MouseButton1Click:Connect(function()
        local token = makeToken()
        local okCall = pcall(function()
            RE_BatSwing:FireServer(player, token)
        end)
        if okCall then
            batBtn.Text = "OK"
            task.delay(0.5, function()
                if batBtn and batBtn.Parent then batBtn.Text = "Bat" end
            end)
        else
            batBtn.Text = "ERR"
            task.delay(0.7, function()
                if batBtn and batBtn.Parent then batBtn.Text = "Bat" end
            end)
        end
    end)

    playerRows[player] = {
        row = row,
        distLabel = distLabel,
        batBtn = batBtn
    }
end

local function rebuildList()
    clearList()
    for _, player in ipairs(Players:GetPlayers()) do
        createPlayerRow(player)
    end
    task.defer(function()
        scroll.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 8)
    end)
end

local function updateDistances()
    for player, data in pairs(playerRows) do
        if not player.Parent then continue end
        local dist = getDistance(player)
        if dist then
            data.distLabel.Text = string.format("%.1f studs", dist)
            if dist <= MAX_RANGE then
                data.distLabel.TextColor3 = Color3.fromRGB(120, 220, 140)
                data.batBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 70)  -- green = in range
            else
                data.distLabel.TextColor3 = Color3.fromRGB(220, 140, 80)
                data.batBtn.BackgroundColor3 = Color3.fromRGB(140, 90, 40)  -- orange = far
            end
        else
            data.distLabel.Text = "no char"
            data.distLabel.TextColor3 = Color3.fromRGB(140, 140, 150)
            data.batBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
        end
    end
end

refreshBtn.MouseButton1Click:Connect(rebuildList)

Players.PlayerAdded:Connect(function()
    task.defer(rebuildList)
end)
Players.PlayerRemoving:Connect(function(player)
    if playerRows[player] then
        playerRows[player].row:Destroy()
        playerRows[player] = nil
    end
end)

-- live distance update
local conn
conn = RunService.Heartbeat:Connect(function()
    updateDistances()
end)

rebuildList()

local function cleanup()
    if conn then conn:Disconnect() end
    if gui then pcall(function() gui:Destroy() end) end
end
_G.PlayerBatUI_Cleanup = cleanup
closeBtn.MouseButton1Click:Connect(cleanup)

print("[PlayerBatUI] Loaded – green button = in range")

end)

if not ok then
    warn("[PlayerBatUI] " .. tostring(err))
end