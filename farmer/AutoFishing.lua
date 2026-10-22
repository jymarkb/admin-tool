--[[
    SIMPLE AUTO FISHING + LOG
    - Safer wait + reel retry on failure
]]

local ok, err = pcall(function()

if _G.SimpleAutoFish_Cleanup then pcall(_G.SimpleAutoFish_Cleanup) end
_G.SimpleAutoFish_Cleanup = nil

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")

-- ======================
-- CONFIG
-- ======================
local CLICKS          = 13
local HOLD_DELAY      = 0.45
local CAST_POWER_MIN  = 0.70
local CAST_POWER_MAX  = 0.92
local EXTRA_WAIT      = 1.15       -- increased
local CYCLE_PAUSE     = 0.85
local MAX_REEL_RETRIES = 2         -- retry reel if it fails

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
-- STATE
-- ======================
local enabled    = false
local lastPos    = nil
local running    = false
local catchCount = 0
local logLines   = {}
local logBox     = nil

local function log(msg)
    local line = os.date("%H:%M:%S") .. " " .. tostring(msg)
    table.insert(logLines, line)
    if #logLines > 50 then table.remove(logLines, 1) end
    if logBox and logBox.Parent then
        pcall(function() logBox.Text = table.concat(logLines, "\n") end)
    end
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
frame.Size = UDim2.new(0, 340, 0, 380)
frame.Position = UDim2.new(1, -360, 0, 20)
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
status.Size = UDim2.new(1, -16, 0, 18)
status.Position = UDim2.new(0, 8, 0, 32)
status.BackgroundTransparency = 1
status.Text = "Do ONE manual cast first"
status.TextColor3 = Color3.fromRGB(200, 200, 160)
status.TextSize = 11
status.Font = Enum.Font.Gotham
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame

local posLabel = Instance.new("TextLabel")
posLabel.Size = UDim2.new(1, -16, 0, 16)
posLabel.Position = UDim2.new(0, 8, 0, 52)
posLabel.BackgroundTransparency = 1
posLabel.Text = "Pos: none"
posLabel.TextColor3 = Color3.fromRGB(150, 170, 190)
posLabel.TextSize = 10
posLabel.Font = Enum.Font.Code
posLabel.TextXAlignment = Enum.TextXAlignment.Left
posLabel.Parent = frame

local countLabel = Instance.new("TextLabel")
countLabel.Size = UDim2.new(1, -16, 0, 16)
countLabel.Position = UDim2.new(0, 8, 0, 70)
countLabel.BackgroundTransparency = 1
countLabel.Text = "Catches: 0"
countLabel.TextColor3 = Color3.fromRGB(140, 200, 140)
countLabel.TextSize = 11
countLabel.Font = Enum.Font.Gotham
countLabel.TextXAlignment = Enum.TextXAlignment.Left
countLabel.Parent = frame

logBox = Instance.new("TextBox")
logBox.Size = UDim2.new(1, -16, 0, 200)
logBox.Position = UDim2.new(0, 8, 0, 92)
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
clearLogBtn.Position = UDim2.new(1, -70, 0, 92)
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

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(0, 140, 0, 30)
startBtn.Position = UDim2.new(0, 10, 1, -42)
startBtn.BackgroundColor3 = Color3.fromRGB(35, 130, 70)
startBtn.Text = "START"
startBtn.TextColor3 = Color3.new(1,1,1)
startBtn.TextSize = 13
startBtn.Font = Enum.Font.GothamBold
startBtn.Parent = frame
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 6)

local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(0, 140, 0, 30)
stopBtn.Position = UDim2.new(1, -150, 1, -42)
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

-- ======================
-- LIGHT HOOK – only position (ignore during auto)
-- ======================
local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    if method == "InvokeServer" and not enabled then
        local name = ""
        pcall(function() name = self.Name end)
        if name == "RF/Fishing/Cast" or string.find(tostring(name), "Fishing/Cast") then
            local args = {...}
            if typeof(args[2]) == "Vector3" then
                lastPos = args[2]
                pcall(function()
                    posLabel.Text = string.format("Pos: %.1f, %.1f, %.1f", lastPos.X, lastPos.Y, lastPos.Z)
                    log("Position captured")
                    setStatus("Position captured – press START", Color3.fromRGB(120, 220, 140))
                end)
            end
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
        while enabled and lastPos do
            log("----- CYCLE START -----")
            setStatus("Holding...", Color3.fromRGB(160, 200, 255))
            pcall(function() RE_Hold:FireServer() end)
            task.wait(HOLD_DELAY)

            local power = CAST_POWER_MIN + math.random() * (CAST_POWER_MAX - CAST_POWER_MIN)
            power = math.floor(power * 1000) / 1000
            setStatus("Casting " .. power, Color3.fromRGB(160, 200, 255))
            log("Casting power=" .. power)

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
                for attempt = 1, MAX_REEL_RETRIES + 1 do
                    setStatus("Reeling..." .. (attempt > 1 and (" retry " .. (attempt-1)) or ""), Color3.fromRGB(100, 220, 140))
                    log("Reeling Id=" .. tostring(fishId) .. " attempt=" .. attempt)

                    local reelOk, result = pcall(function()
                        return RF_Reel:InvokeServer(fishId, "Caught", CLICKS)
                    end)

                    log("Reel → ok=" .. tostring(reelOk) .. " result=" .. tostring(result))

                    if reelOk and result == true then
                        success = true
                        break
                    end

                    if attempt <= MAX_REEL_RETRIES then
                        task.wait(0.45) -- small delay before retry
                    end
                end

                if success then
                    catchCount += 1
                    countLabel.Text = "Catches: " .. catchCount
                    setStatus("Caught! #" .. catchCount, Color3.fromRGB(100, 255, 140))
                    log("SUCCESS #" .. catchCount)
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
startBtn.MouseButton1Click:Connect(function()
    if not lastPos then
        setStatus("Do a manual cast first!", Color3.fromRGB(255, 120, 80))
        log("START blocked – no position")
        return
    end
    enabled = true
    setStatus("Running...", Color3.fromRGB(120, 220, 140))
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
    enabled = false
    if gui then pcall(function() gui:Destroy() end) end
end
_G.SimpleAutoFish_Cleanup = cleanup
closeBtn.MouseButton1Click:Connect(cleanup)

log("Script loaded – do one manual cast")
setStatus("Do ONE manual cast first", Color3.fromRGB(200, 200, 160))

end)

if not ok then
    warn("[SimpleAutoFish] " .. tostring(err))
end