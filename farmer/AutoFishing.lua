--[[
    SIMPLE AUTO FISHING + LOG
    - Default Halloween fishing spot & reel target
    - Auto-walks to fishing location before fishing if away
    - Equips "Haunted Rod [X1]" automatically when at fishing location
    - Safer wait + reel retry on failure
    - Logs live character position and detailed reel rewards (Name, Rarity, OneIn, Id)
]]

local ok, err = pcall(function()

if _G.SimpleAutoFish_Cleanup then pcall(_G.SimpleAutoFish_Cleanup) end
_G.SimpleAutoFish_Cleanup = nil

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

-- ======================
-- CONFIG
-- ======================
local DEFAULT_CHAR_POS = Vector3.new(-5695.6, -203.7, -7370.9)  -- Halloween Fishing Bank Stand Position
local DEFAULT_CAST_POS = Vector3.new(-5668.5, -206.5, -7368.9)  -- Water Reel Target Coordinates
local ROD_NAME         = "Haunted Rod [X1]"                      -- Rod to auto-equip

local CLICKS           = 13
local HOLD_DELAY       = 0.45
local CAST_POWER_MIN   = 0.70
local CAST_POWER_MAX   = 0.92
local EXTRA_WAIT       = 1.15
local CYCLE_PAUSE      = 0.85
local MAX_REEL_RETRIES = 2

-- ======================
-- REMOTES
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

local RE_Hold = getNet("RE/Fishing/Hold")
local RF_Cast = getNet("RF/Fishing/Cast")
local RF_Reel = getNet("RF/Fishing/Reel")

if not (RE_Hold and RF_Cast and RF_Reel) then
    error("Fishing remotes not found")
end

-- ======================
-- STATE & HELPERS
-- ======================
local enabled         = false
local lastPos         = DEFAULT_CAST_POS
local running         = false
local catchCount      = 0
local logLines        = {}
local logBox          = nil
local charLabel       = nil
local isScriptActive  = true

local function log(msg)
    local line = os.date("%H:%M:%S") .. " " .. tostring(msg)
    table.insert(logLines, line)
    if #logLines > 60 then table.remove(logLines, 1) end
    if logBox and logBox.Parent then
        pcall(function() logBox.Text = table.concat(logLines, "\n") end)
    end
end

local function getCharPos()
    local ch = lp and lp.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position or nil
end

local function distXZ(a, b)
    if not (a and b) then return 99999 end
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function getAutoCastPos()
    local ch = lp and lp.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not hrp then return DEFAULT_CAST_POS end
    local look = hrp.CFrame.LookVector
    -- Cast ~22 studs forward in the direction the character is facing
    local forwardDist = 22
    local targetX = hrp.Position.X + look.X * forwardDist
    local targetZ = hrp.Position.Z + look.Z * forwardDist
    local targetY = hrp.Position.Y - 2.8

    pcall(function()
        local rayOrigin = Vector3.new(targetX, hrp.Position.Y + 10, targetZ)
        local rayDirection = Vector3.new(0, -35, 0)
        local raycastParams = RaycastParams.new()
        raycastParams.FilterDescendantsInstances = {ch}
        raycastParams.FilterType = Enum.RaycastFilterType.Exclude
        local result = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
        if result and result.Position then
            targetY = result.Position.Y
        end
    end)
    return Vector3.new(targetX, targetY, targetZ)
end

-- ======================
-- TOOL EQUIP LOGIC (from auto-bat.lua)
-- ======================
local function findRod()
    local char = lp.Character
    if char then
        for _, t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") then
                if t.Name == ROD_NAME or string.find(t.Name:lower(), "haunted rod", 1, true) then
                    return t, true -- already in hand
                end
            end
        end
    end
    local bp = lp:FindFirstChild("Backpack")
    if bp then
        for _, t in ipairs(bp:GetChildren()) do
            if t:IsA("Tool") then
                if t.Name == ROD_NAME or string.find(t.Name:lower(), "haunted rod", 1, true) then
                    return t, false -- in backpack
                end
            end
        end
    end
    return nil, false
end

local function ensureRodEquipped()
    local rod, alreadyInHand = findRod()
    if not rod then
        log("Notice: '" .. ROD_NAME .. "' not found in Backpack or Character")
        return false
    end
    if alreadyInHand then
        return true
    end
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function() hum:EquipTool(rod) end)
        task.wait(0.2)
        log("Equipped tool: " .. rod.Name)
        return true
    end
    return false
end

-- ======================
-- NAVIGATION LOGIC
-- ======================
local function walkToTarget(targetPos, arrivalDist, cancelCheck)
    arrivalDist = arrivalDist or 3.5
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not (char and root and hum) then return false end

    if hum.Sit then hum.Sit = false end
    if hum.PlatformStand then hum.PlatformStand = false end

    if distXZ(root.Position, targetPos) <= arrivalDist then
        return true
    end

    local startTime = os.clock()
    local timeout = 35.0
    local lastWalkPos = nil
    local stuckFrames = 0

    while (os.clock() - startTime) < timeout do
        if not lp.Character or not root.Parent or hum.Health <= 0 then break end
        if cancelCheck and cancelCheck() then break end

        local curPos = root.Position
        local dist = distXZ(curPos, targetPos)

        if dist <= arrivalDist then
            pcall(function()
                root.AssemblyLinearVelocity = Vector3.zero
                hum:Move(Vector3.zero, false)
                hum.WalkToPoint = root.Position
            end)
            return true
        end

        pcall(function()
            hum:MoveTo(targetPos)
        end)

        if lastWalkPos and distXZ(curPos, lastWalkPos) < 0.4 then
            stuckFrames = stuckFrames + 1
            if stuckFrames >= 5 then
                stuckFrames = 0
                pcall(function() hum.Jump = true end)
            end
        else
            stuckFrames = 0
        end
        lastWalkPos = curPos

        task.wait(0.1)
    end

    pcall(function()
        if root then root.AssemblyLinearVelocity = Vector3.zero end
        if hum then hum:Move(Vector3.zero, false) end
    end)
    return (root and distXZ(root.Position, targetPos) <= arrivalDist)
end

local function formatReward(item)
    if typeof(item) ~= "table" then
        return tostring(item)
    end
    local name = item.DisplayName or item.Id or item.Name or "Fish"
    local rarity = item.Rarity or "Unknown"
    local oneIn = item.OneIn and string.format(" (1 in %s)", tostring(item.OneIn)) or ""
    local amount = item.Amount and tonumber(item.Amount) and tonumber(item.Amount) > 1 and string.format(" x%d", item.Amount) or ""
    return string.format("[%s] %s%s%s", rarity, name, amount, oneIn)
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
gui.Name = "SimpleAutoFish"
gui.ResetOnSpawn = false
gui.Parent = getSafeParent()

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 350, 0, 420)
frame.Position = UDim2.new(1, -370, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(60, 140, 220)
stroke.Thickness = 1.5
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -50, 0, 26)
title.Position = UDim2.new(0, 10, 0, 4)
title.BackgroundTransparency = 1
title.Text = "🎣 Simple Auto Fish"
title.TextColor3 = Color3.fromRGB(120, 210, 255)
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
status.Size = UDim2.new(1, -16, 0, 16)
status.Position = UDim2.new(0, 8, 0, 30)
status.BackgroundTransparency = 1
status.Text = "Ready – press START"
status.TextColor3 = Color3.fromRGB(200, 200, 160)
status.TextSize = 11
status.Font = Enum.Font.Gotham
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame

charLabel = Instance.new("TextLabel")
charLabel.Size = UDim2.new(1, -16, 0, 16)
charLabel.Position = UDim2.new(0, 8, 0, 48)
charLabel.BackgroundTransparency = 1
charLabel.Text = "Char: none"
charLabel.TextColor3 = Color3.fromRGB(160, 190, 220)
charLabel.TextSize = 10
charLabel.Font = Enum.Font.Code
charLabel.TextXAlignment = Enum.TextXAlignment.Left
charLabel.Parent = frame

local posLabel = Instance.new("TextLabel")
posLabel.Size = UDim2.new(1, -16, 0, 16)
posLabel.Position = UDim2.new(0, 8, 0, 66)
posLabel.BackgroundTransparency = 1
posLabel.Text = string.format("Pos: %.1f, %.1f, %.1f (Default)", lastPos.X, lastPos.Y, lastPos.Z)
posLabel.TextColor3 = Color3.fromRGB(150, 170, 190)
posLabel.TextSize = 10
posLabel.Font = Enum.Font.Code
posLabel.TextXAlignment = Enum.TextXAlignment.Left
posLabel.Parent = frame

local countLabel = Instance.new("TextLabel")
countLabel.Size = UDim2.new(1, -16, 0, 16)
countLabel.Position = UDim2.new(0, 8, 0, 84)
countLabel.BackgroundTransparency = 1
countLabel.Text = "Catches: 0"
countLabel.TextColor3 = Color3.fromRGB(140, 200, 140)
countLabel.TextSize = 11
countLabel.Font = Enum.Font.Gotham
countLabel.TextXAlignment = Enum.TextXAlignment.Left
countLabel.Parent = frame

logBox = Instance.new("TextBox")
logBox.Size = UDim2.new(1, -16, 0, 220)
logBox.Position = UDim2.new(0, 8, 0, 104)
logBox.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
logBox.TextColor3 = Color3.fromRGB(170, 220, 170)
logBox.Font = Enum.Font.Code
logBox.TextSize = 11
logBox.Text = ""
logBox.TextWrapped = true
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.MultiLine = true
logBox.Parent = frame
Instance.new("UICorner", logBox).CornerRadius = UDim.new(0, 6)

local clearLogBtn = Instance.new("TextButton")
clearLogBtn.Size = UDim2.new(0, 60, 0, 18)
clearLogBtn.Position = UDim2.new(1, -70, 0, 106)
clearLogBtn.BackgroundColor3 = Color3.fromRGB(50, 55, 70)
clearLogBtn.Text = "CLEAR"
clearLogBtn.TextColor3 = Color3.fromRGB(180, 180, 200)
clearLogBtn.TextSize = 10
clearLogBtn.Font = Enum.Font.Gotham
clearLogBtn.Parent = frame
Instance.new("UICorner", clearLogBtn).CornerRadius = UDim.new(0, 4)

clearLogBtn.MouseButton1Click:Connect(function()
    table.clear(logLines)
    logBox.Text = ""
end)

local setPosBtn = Instance.new("TextButton")
setPosBtn.Size = UDim2.new(1, -20, 0, 26)
setPosBtn.Position = UDim2.new(0, 10, 1, -74)
setPosBtn.BackgroundColor3 = Color3.fromRGB(45, 75, 110)
setPosBtn.Text = "📍 RESET TO DEFAULT SPOT & REEL"
setPosBtn.TextColor3 = Color3.fromRGB(200, 230, 255)
setPosBtn.TextSize = 11
setPosBtn.Font = Enum.Font.GothamBold
setPosBtn.Parent = frame
Instance.new("UICorner", setPosBtn).CornerRadius = UDim.new(0, 6)

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(0, 155, 0, 32)
startBtn.Position = UDim2.new(0, 10, 1, -42)
startBtn.BackgroundColor3 = Color3.fromRGB(35, 130, 70)
startBtn.Text = "START"
startBtn.TextColor3 = Color3.new(1,1,1)
startBtn.TextSize = 13
startBtn.Font = Enum.Font.GothamBold
startBtn.Parent = frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 6)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0, 155, 0, 32)
stopBtn.Position = UDim2.new(1, -165, 1, -42)
stopBtn.BackgroundColor3 = Color3.fromRGB(130, 50, 50)
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

-- Live character position updater
task.spawn(function()
    while isScriptActive and gui and gui.Parent do
        local cp = getCharPos()
        if cp and charLabel and charLabel.Parent then
            pcall(function()
                charLabel.Text = string.format("Char: %.1f, %.1f, %.1f", cp.X, cp.Y, cp.Z)
            end)
        end
        task.wait(1.0)
    end
end)

-- ======================
-- HOOK – Capture Manual Cast & Reel with Character Position
-- ======================
local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    if not isScriptActive then
        return oldNamecall(self, ...)
    end

    local method = getnamecallmethod()
    if method == "InvokeServer" and not enabled then
        local name = ""
        pcall(function() name = self.Name end)

        if name == "RF/Fishing/Cast" or string.find(tostring(name), "Fishing/Cast") then
            local args = {...}
            if typeof(args[2]) == "Vector3" then
                lastPos = args[2]
                local cp = getCharPos()
                pcall(function()
                    if cp and charLabel then
                        charLabel.Text = string.format("Char: %.1f, %.1f, %.1f", cp.X, cp.Y, cp.Z)
                    end
                    posLabel.Text = string.format("Pos: %.1f, %.1f, %.1f (Manual)", lastPos.X, lastPos.Y, lastPos.Z)
                    setStatus("Position captured – press START", Color3.fromRGB(120, 220, 140))
                    local charStr = cp and string.format("Char=(%.1f, %.1f, %.1f) ", cp.X, cp.Y, cp.Z) or ""
                    log(string.format("Manual Cast Captured → %sCast=(%.1f, %.1f, %.1f) Power=%.3f",
                        charStr, lastPos.X, lastPos.Y, lastPos.Z, tonumber(args[1]) or 0))
                end)
            end
        elseif name == "RF/Fishing/Reel" or string.find(tostring(name), "Fishing/Reel") then
            local args = {...}
            local results = table.pack(oldNamecall(self, ...))
            local ret1 = results[1]
            local ret2 = results[2]
            local cp = getCharPos()
            local charStr = cp and string.format("Char=(%.1f, %.1f, %.1f) ", cp.X, cp.Y, cp.Z) or ""
            if ret1 == true then
                log(string.format("Manual Reel SUCCESS → %s%s (Id=%s)", charStr, formatReward(ret2), tostring(args[1])))
            else
                log(string.format("Manual Reel → %sret1=%s ret2=%s", charStr, tostring(ret1), tostring(ret2)))
            end
            return table.unpack(results, 1, results.n)
        end
    end
    return oldNamecall(self, ...)
end)

-- ======================
-- AUTO CYCLE
-- ======================
local function doCycle()
    if running then return end
    running = true

    task.spawn(function()
        -- 1. Check if at fishing location; if not, walk towards DEFAULT_CHAR_POS
        local startCp = getCharPos()
        local distFromSpot = distXZ(startCp, DEFAULT_CHAR_POS)
        if distFromSpot > 4.0 then
            setStatus(string.format("Walking to spot (%.0fm)...", distFromSpot), Color3.fromRGB(255, 200, 100))
            log(string.format("Walking to fishing spot (%.1f studs away)...", distFromSpot))

            local arrived = walkToTarget(DEFAULT_CHAR_POS, 3.5, function() return not enabled end)
            if not enabled then
                running = false
                log("Stopped while walking to fishing spot")
                return
            end

            if arrived then
                log("Arrived at fishing spot")
                setStatus("Arrived at spot", Color3.fromRGB(120, 220, 140))
                pcall(function()
                    local ch = lp.Character
                    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
                    if hrp and lastPos then
                        hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(lastPos.X, hrp.Position.Y, lastPos.Z))
                    end
                end)
            else
                log("Warning: Navigation timed out, proceeding from current location")
            end
        end

        -- 2. Equip Haunted Rod [X1] once at fishing location
        ensureRodEquipped()

        -- 3. Main Fishing Loop
        while enabled and lastPos do
            -- Safety drift check: if bumped > 10 studs away from spot, walk back
            local loopCp = getCharPos()
            if loopCp and distXZ(loopCp, DEFAULT_CHAR_POS) > 10.0 then
                setStatus("Returning to spot...", Color3.fromRGB(255, 200, 100))
                log("Drifted from fishing spot, walking back...")
                walkToTarget(DEFAULT_CHAR_POS, 3.5, function() return not enabled end)
                if not enabled then break end
                pcall(function()
                    local ch = lp.Character
                    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
                    if hrp and lastPos then
                        hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(lastPos.X, hrp.Position.Y, lastPos.Z))
                    end
                end)
                ensureRodEquipped()
            end

            ensureRodEquipped()

            local cp = getCharPos()
            local charStr = cp and string.format("Char=(%.1f, %.1f, %.1f)", cp.X, cp.Y, cp.Z) or "Char=none"
            if cp and charLabel and charLabel.Parent then
                pcall(function() charLabel.Text = string.format("Char: %.1f, %.1f, %.1f", cp.X, cp.Y, cp.Z) end)
            end

            log("----- CYCLE START " .. charStr .. " -----")
            setStatus("Holding...", Color3.fromRGB(160, 200, 255))
            pcall(function() RE_Hold:FireServer() end)
            task.wait(HOLD_DELAY)

            local power = CAST_POWER_MIN + math.random() * (CAST_POWER_MAX - CAST_POWER_MIN)
            power = math.floor(power * 1000) / 1000
            setStatus("Casting " .. power, Color3.fromRGB(160, 200, 255))
            log(string.format("Casting power=%.3f Target=(%.1f, %.1f, %.1f)", power, lastPos.X, lastPos.Y, lastPos.Z))

            local castOk, castData = pcall(function()
                return RF_Cast:InvokeServer(power, lastPos)
            end)

            if type(castData) == "table" and castData.Id then
                log("Cast OK → Id=" .. tostring(castData.Id) .. " Wait=" .. tostring(castData.Wait))
            else
                log("Cast FAILED → " .. tostring(castData))
            end

            if not castOk or type(castData) ~= "table" or not castData.Id then
                setStatus("Cast failed", Color3.fromRGB(255, 160, 60))
                log("Retrying in 2s...")
                task.wait(2)
            else
                local fishId   = castData.Id
                local waitTime = (tonumber(castData.Wait) or 3) + EXTRA_WAIT

                setStatus(string.format("Waiting %.1fs", waitTime), Color3.fromRGB(180, 210, 255))
                log("Waiting " .. string.format("%.2f", waitTime) .. "s  Id=" .. tostring(fishId))
                task.wait(waitTime)

                -- Reel with retries
                local success = false
                local caughtItem = nil
                for attempt = 1, MAX_REEL_RETRIES + 1 do
                    setStatus("Reeling..." .. (attempt > 1 and (" retry " .. (attempt-1)) or ""), Color3.fromRGB(100, 220, 140))

                    local curCp = getCharPos()
                    local curCharStr = curCp and string.format("Char=(%.1f, %.1f, %.1f) ", curCp.X, curCp.Y, curCp.Z) or ""

                    local reelResults = table.pack(pcall(function()
                        return RF_Reel:InvokeServer(fishId, "Caught", CLICKS)
                    end))

                    local reelOk = reelResults[1]
                    local ret1 = reelResults[2]
                    local ret2 = reelResults[3]

                    if reelOk and ret1 == true then
                        success = true
                        caughtItem = ret2
                        log(string.format("Reel SUCCESS → %s%s (Id=%s attempt=%d)",
                            curCharStr, formatReward(ret2), tostring(fishId), attempt))
                        break
                    else
                        log(string.format("Reel attempt %d failed → %sok=%s ret1=%s",
                            attempt, curCharStr, tostring(reelOk), tostring(ret1)))
                    end

                    if attempt <= MAX_REEL_RETRIES then
                        task.wait(0.45) -- small delay before retry
                    end
                end

                if success then
                    catchCount += 1
                    countLabel.Text = "Catches: " .. catchCount
                    local displayItem = (typeof(caughtItem) == "table" and (caughtItem.DisplayName or caughtItem.Id)) or "Caught!"
                    setStatus(string.format("Caught #%d: %s", catchCount, displayItem), Color3.fromRGB(100, 255, 140))
                else
                    setStatus("REEL FAILED", Color3.fromRGB(255, 100, 80))
                    log("REEL FAILED after retries")
                end
            end

            task.wait(CYCLE_PAUSE)
        end
        running = false
        log("Loop stopped")
    end)
end

-- ======================
-- BUTTONS
-- ======================
setPosBtn.MouseButton1Click:Connect(function()
    lastPos = DEFAULT_CAST_POS
    posLabel.Text = string.format("Pos: %.1f, %.1f, %.1f (Default)", lastPos.X, lastPos.Y, lastPos.Z)
    setStatus("Reset to default fishing spot", Color3.fromRGB(120, 220, 140))
    log(string.format("Target reset to default: (%.1f, %.1f, %.1f)", lastPos.X, lastPos.Y, lastPos.Z))
end)

startBtn.MouseButton1Click:Connect(function()
    if not lastPos then
        lastPos = DEFAULT_CAST_POS
        posLabel.Text = string.format("Pos: %.1f, %.1f, %.1f (Default)", lastPos.X, lastPos.Y, lastPos.Z)
    end
    enabled = true
    setStatus("Starting...", Color3.fromRGB(120, 220, 140))
    stroke.Color = Color3.fromRGB(60, 200, 100)
    log("START pressed")
    doCycle()
end)

stopBtn.MouseButton1Click:Connect(function()
    enabled = false
    setStatus("Stopped", Color3.fromRGB(200, 180, 100))
    stroke.Color = Color3.fromRGB(60, 140, 220)
    log("STOP pressed")
end)

local function cleanup()
    isScriptActive = false
    enabled = false
    running = false
    if gui then pcall(function() gui:Destroy() end) end
end
_G.SimpleAutoFish_Cleanup = cleanup
closeBtn.MouseButton1Click:Connect(cleanup)

-- Initialization on load
local initCp = getCharPos()
if initCp then
    charLabel.Text = string.format("Char: %.1f, %.1f, %.1f", initCp.X, initCp.Y, initCp.Z)
end
posLabel.Text = string.format("Pos: %.1f, %.1f, %.1f (Default)", lastPos.X, lastPos.Y, lastPos.Z)
setStatus("Ready – press START", Color3.fromRGB(120, 220, 140))
log(string.format("Ready! Fishing Spot: (%.1f, %.1f, %.1f) Reel Target: (%.1f, %.1f, %.1f)",
    DEFAULT_CHAR_POS.X, DEFAULT_CHAR_POS.Y, DEFAULT_CHAR_POS.Z,
    DEFAULT_CAST_POS.X, DEFAULT_CAST_POS.Y, DEFAULT_CAST_POS.Z))

end)

if not ok then
    warn("[SimpleAutoFish] " .. tostring(err))
end
