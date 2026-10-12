--[[
    INSTANT RAGDOLL RECOVERY & ANTI-SLAM SHIELD (v2.0 - ZERO WAIT)
    ===============================================================
    A dedicated standalone recovery utility for Steal an Egg.
    
    Why v1.0 had a delay / "wait on ragdoll time":
      - When hit, the server sets LocalPlayer attribute "RagdollEndTime" = os.time() + 2~3s.
      - Game client scripts check GetAttribute("RagdollEndTime") every frame.
      - While RagdollEndTime > now, the game:
          1. Calls PlayerModule:GetControls():Disable() (locks keyboard/joystick)
          2. Sets Humanoid.WalkSpeed = 0
          3. Forces Humanoid into Physics/Ragdoll
      - Even if joints were restored, the player was stuck waiting for the 3s timer!

    v2.0 Zero-Wait Upgrades:
      1. Attribute Zeroing & Metamethod Spoof:
         - Wipes RagdollEndTime to 0 locally the microsecond it changes.
         - Hooks GetAttribute("RagdollEndTime") to always return 0 to game scripts,
           so the game's internal ragdoll loop exits instantly.
      2. Player Controls Restorer:
         - Calls PlayerModule:GetControls():Enable() immediately so WASD works without waiting.
      3. WalkSpeed Preservation & Restoration:
         - Remembers your active running speed (e.g. 260-300) and restores it if the
           game tries to zero it to 0.
      4. Metamethod Motor & PlatformStand Protection:
         - Blocks game scripts from writing Motor6D.Enabled = false and PlatformStand = true.
      5. Slam Downward Impulse Neutralizer:
         - Dampens heavy negative Y velocity so you don't faceplant into the floor.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait(0.1)
    LocalPlayer = Players.LocalPlayer
end

-- Fallback utilities
local checkcaller = checkcaller or function() return false end
local newcclosure = newcclosure or function(f) return f end

-- ========================================================================
-- CONFIG & STATE
-- ========================================================================

local isRecoveryEnabled = true
local isSlamDampenerEnabled = true
local isAttributeSpoofEnabled = true
local recoveryCount = 0
local running = true
local savedWalkSpeed = 16.0

local characterConnections = {}
local jointsTable = {}

-- ========================================================================
-- UI SETUP
-- ========================================================================

local GUI_NAME = "InstantRagdollRecoveryGui"
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

local W, H = 270, 160
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.4, -H/2)
main.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(70, 140, 220)
mainStroke.Thickness = 1.5

-- Title Bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -60, 1, 0)
titleLbl.Position = UDim2.new(0, 10, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "⚡ ZERO-WAIT RECOVERY SHIELD"
titleLbl.TextColor3 = Color3.fromRGB(200, 230, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 10.5
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = titleBar

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 22, 0, 22)
minBtn.Position = UDim2.new(1, -52, 0, 4)
minBtn.BackgroundColor3 = Color3.fromRGB(45, 52, 70)
minBtn.Text = "—"
minBtn.TextColor3 = Color3.fromRGB(210, 225, 255)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 11
minBtn.Parent = titleBar
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 5)

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
toggleBtn.Size = UDim2.new(1, -20, 0, 40)
toggleBtn.Position = UDim2.new(0, 10, 0, 38)
toggleBtn.BackgroundColor3 = Color3.fromRGB(30, 160, 95)
toggleBtn.Text = "🛡️ ZERO-WAIT RECOVERY: ACTIVE"
toggleBtn.TextColor3 = Color3.new(1, 1, 1)
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 11.5
toggleBtn.Parent = main
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 6)

local toggleStroke = Instance.new("UIStroke", toggleBtn)
toggleStroke.Color = Color3.fromRGB(60, 230, 140)
toggleStroke.Thickness = 1.5

-- Secondary Toggle: Slam Dampener
local dampBtn = Instance.new("TextButton")
dampBtn.Size = UDim2.new(1, -20, 0, 24)
dampBtn.Position = UDim2.new(0, 10, 0, 84)
dampBtn.BackgroundColor3 = Color3.fromRGB(32, 38, 54)
dampBtn.Text = "Slam Velocity Absorber: ON"
dampBtn.TextColor3 = Color3.fromRGB(140, 220, 255)
dampBtn.Font = Enum.Font.GothamBold
dampBtn.TextSize = 10
dampBtn.Parent = main
Instance.new("UICorner", dampBtn).CornerRadius = UDim.new(0, 5)

-- Live Status Label
local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1, -20, 0, 20)
statusLbl.Position = UDim2.new(0, 10, 0, 112)
statusLbl.BackgroundTransparency = 1
statusLbl.Text = "Motors: 0/0 OK · Recoveries: 0"
statusLbl.TextColor3 = Color3.fromRGB(160, 180, 210)
statusLbl.Font = Enum.Font.Gotham
statusLbl.TextSize = 9.5
statusLbl.TextXAlignment = Enum.TextXAlignment.Center
statusLbl.Parent = main

-- State Info Label
local infoLbl = Instance.new("TextLabel")
infoLbl.Size = UDim2.new(1, -20, 0, 16)
infoLbl.Position = UDim2.new(0, 10, 1, -22)
infoLbl.BackgroundTransparency = 1
infoLbl.Text = "State: Normal · Zero-Wait Ready"
infoLbl.TextColor3 = Color3.fromRGB(120, 230, 150)
infoLbl.Font = Enum.Font.GothamBold
infoLbl.TextSize = 9
infoLbl.TextXAlignment = Enum.TextXAlignment.Center
infoLbl.Parent = main

-- Minimize Behavior
local isMinimized = false
local contentWidgets = { toggleBtn, dampBtn, statusLbl, infoLbl }
minBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        minBtn.Text = "+"
        for _, w in ipairs(contentWidgets) do w.Visible = false end
        main.Size = UDim2.new(0, W, 0, 30)
    else
        minBtn.Text = "—"
        main.Size = UDim2.new(0, W, 0, H)
        for _, w in ipairs(contentWidgets) do w.Visible = true end
    end
end)

-- ========================================================================
-- RECOVERY CORE LOGIC
-- ========================================================================

-- Immediately enable player keyboard/touch controls if game disabled them
local function enablePlayerControls()
    pcall(function()
        local ps = LocalPlayer:FindFirstChildOfClass("PlayerScripts")
        if ps then
            local pm = ps:FindFirstChild("PlayerModule")
            if pm then
                local controls = require(pm):GetControls()
                if controls and controls.Enable then
                    controls:Enable()
                end
            end
        end
    end)
end

-- Zero out RagdollEndTime attribute so client scripts exit ragdoll loop
local function clearRagdollAttributes()
    pcall(function()
        LocalPlayer:SetAttribute("RagdollEndTime", 0)
        LocalPlayer:SetAttribute("RagdollTime", 0)
        LocalPlayer:SetAttribute("IsRagdoll", false)
        LocalPlayer:SetAttribute("Ragdolled", false)
    end)
    local char = LocalPlayer.Character
    if char then
        pcall(function()
            char:SetAttribute("RagdollEndTime", 0)
            char:SetAttribute("RagdollTime", 0)
            char:SetAttribute("IsRagdoll", false)
            char:SetAttribute("Ragdolled", false)
        end)
    end
end

-- Neutralize carried egg physics mass
local function neutraliseCarriedEggMass(char)
    if not char then return end
    for _, desc in ipairs(char:GetDescendants()) do
        if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" and desc.Parent ~= char then
            pcall(function()
                desc.Massless = true
                desc.CanCollide = false
            end)
        end
    end

    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        local uidStr = tostring(LocalPlayer.UserId)
        for _, model in ipairs(cra:GetChildren()) do
            if string.find(model.Name, uidStr) then
                for _, part in ipairs(model:GetDescendants()) do
                    if part:IsA("BasePart") then
                        pcall(function()
                            part.Massless = true
                            part.CanCollide = false
                        end)
                    end
                end
            end
        end
    end
end

-- Execute Zero-Wait Instant Recovery
local function executeInstantRecovery(reason)
    if not isRecoveryEnabled then return end

    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hum or hum.Health <= 0 then return end

    recoveryCount = recoveryCount + 1

    -- 1. Wipe RagdollEndTime to 0 so game scripts NEVER wait
    clearRagdollAttributes()

    -- 2. Zero-Frame Motor6D Joint Restoration
    local restored = 0
    for _, motor in ipairs(jointsTable) do
        if motor and motor.Parent and not motor.Enabled then
            motor.Enabled = true
            restored = restored + 1
        end
    end

    -- 3. Clear PlatformStand and Sit immediately
    hum.PlatformStand = false
    hum.Sit = false
    hum.AutoRotate = true

    -- 4. Re-enable humanoid recovery states & force Running
    hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
    hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
    hum:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
    hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
    hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)

    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    hum:ChangeState(Enum.HumanoidStateType.Running)

    -- 5. Restore WalkSpeed if the game zeroed it
    if hum.WalkSpeed < 16.0 then
        hum.WalkSpeed = math.max(savedWalkSpeed, 16.0)
    end

    -- 6. Immediately re-enable PlayerModule controls (WASD)
    enablePlayerControls()

    -- 7. Downward Slam Velocity Absorber
    if isSlamDampenerEnabled and hrp then
        local curVel = hrp.AssemblyLinearVelocity
        if curVel.Y < -25 then
            -- Clamp heavy downward plunge, preserve horizontal momentum
            hrp.AssemblyLinearVelocity = Vector3.new(curVel.X, math.clamp(curVel.Y, -5, 50), curVel.Z)
        end
    end

    -- 8. Neutralize any carried egg weight
    neutraliseCarriedEggMass(char)

    -- UI Feedback
    infoLbl.Text = string.format("ZERO-WAIT: %s (+%d motors)", reason or "Hit", restored)
    infoLbl.TextColor3 = Color3.fromRGB(255, 215, 100)

    task.delay(0.3, function()
        if running then
            infoLbl.Text = "State: Normal · Zero-Wait Ready"
            infoLbl.TextColor3 = Color3.fromRGB(120, 230, 150)
        end
    end)
end

-- ========================================================================
-- METAMETHOD HOOKS (SPOOF RAGDOLL TIME & PROTECT JOINTS)
-- ========================================================================

if typeof(hookmetamethod) == "function" then
    -- Hook 1: GetAttribute spoofing
    -- Whenever game client scripts ask for "RagdollEndTime", return 0 so they NEVER wait!
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if isRecoveryEnabled and isAttributeSpoofEnabled and not checkcaller() and method == "GetAttribute" then
            local attrName = ...
            if attrName == "RagdollEndTime" or attrName == "RagdollTime" then
                return 0
            end
        end
        return oldNamecall(self, ...)
    end))

    -- Hook 2: __newindex protection
    -- Blocks game scripts from setting Motor6D.Enabled = false or Humanoid.PlatformStand = true
    local oldNewIndex
    oldNewIndex = hookmetamethod(game, "__newindex", newcclosure(function(self, key, value)
        if isRecoveryEnabled and not checkcaller() and typeof(self) == "Instance" then
            if key == "Enabled" and self:IsA("Motor6D") and value == false then
                local char = LocalPlayer.Character
                if char and self:IsDescendantOf(char) then
                    return oldNewIndex(self, key, true) -- Force stay enabled
                end
            elseif key == "PlatformStand" and self:IsA("Humanoid") and value == true then
                local char = LocalPlayer.Character
                if char and self:IsDescendantOf(char) then
                    return oldNewIndex(self, key, false) -- Block PlatformStand
                end
            elseif key == "WalkSpeed" and self:IsA("Humanoid") and value == 0 then
                local char = LocalPlayer.Character
                if char and self:IsDescendantOf(char) then
                    return oldNewIndex(self, key, math.max(savedWalkSpeed, 16.0)) -- Block zeroing WalkSpeed
                end
            end
        end
        return oldNewIndex(self, key, value)
    end))

    print("[InstantRecovery] Metamethod hooks installed successfully.")
end

-- ========================================================================
-- CHARACTER BINDING & EVENT LISTENERS
-- ========================================================================

local function bindCharacter(char)
    -- Disconnect previous character listeners
    for _, conn in ipairs(characterConnections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(characterConnections)
    table.clear(jointsTable)

    if not char then return end
    local hum = char:WaitForChild("Humanoid", 5)
    local hrp = char:WaitForChild("HumanoidRootPart", 5)
    if not hum or not hrp then return end

    if hum.WalkSpeed >= 16.0 then
        savedWalkSpeed = hum.WalkSpeed
    end

    -- Index all Motor6D joints and hook Enabled property
    local function registerMotor(obj)
        if obj:IsA("Motor6D") then
            table.insert(jointsTable, obj)
            local conn = obj:GetPropertyChangedSignal("Enabled"):Connect(function()
                if isRecoveryEnabled and not obj.Enabled then
                    obj.Enabled = true
                    executeInstantRecovery("JointLock")
                end
            end)
            table.insert(characterConnections, conn)
        end
    end

    for _, desc in ipairs(char:GetDescendants()) do
        registerMotor(desc)
    end

    local descConn = char.DescendantAdded:Connect(function(desc)
        registerMotor(desc)
    end)
    table.insert(characterConnections, descConn)

    -- State Listener
    local stateConn = hum.StateChanged:Connect(function(oldState, newState)
        if not isRecoveryEnabled then return end
        if newState == Enum.HumanoidStateType.Ragdoll
            or newState == Enum.HumanoidStateType.FallingDown
            or newState == Enum.HumanoidStateType.Physics then
            executeInstantRecovery(tostring(newState.Name))
        end
    end)
    table.insert(characterConnections, stateConn)

    -- PlatformStand / Sit Watcher
    local platConn = hum:GetPropertyChangedSignal("PlatformStand"):Connect(function()
        if isRecoveryEnabled and hum.PlatformStand then
            hum.PlatformStand = false
            executeInstantRecovery("PlatformStand")
        end
    end)
    table.insert(characterConnections, platConn)

    local sitConn = hum:GetPropertyChangedSignal("Sit"):Connect(function()
        if isRecoveryEnabled and hum.Sit then
            hum.Sit = false
            executeInstantRecovery("Sit")
        end
    end)
    table.insert(characterConnections, sitConn)

    -- RagdollEndTime Attribute Watcher on Player & Character
    local attrConn1 = LocalPlayer:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
        if isRecoveryEnabled then
            local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
            if typeof(rEnd) == "number" and rEnd > 0 then
                executeInstantRecovery("RagdollTimerZeroed")
            end
        end
    end)
    table.insert(characterConnections, attrConn1)

    local attrConn2 = char:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
        if isRecoveryEnabled then
            local rEnd = char:GetAttribute("RagdollEndTime")
            if typeof(rEnd) == "number" and rEnd > 0 then
                executeInstantRecovery("CharRagdollTimerZeroed")
            end
        end
    end)
    table.insert(characterConnections, attrConn2)

    neutraliseCarriedEggMass(char)
end

-- ========================================================================
-- HEARTBEAT SAFETY NET (ZERO-FRAME ENFORCEMENT)
-- ========================================================================

local heartbeatConn = RunService.Heartbeat:Connect(function()
    if not running or not isRecoveryEnabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hum or hum.Health <= 0 then return end

    -- Keep active WalkSpeed track
    if hum.WalkSpeed >= 16.0 then
        savedWalkSpeed = hum.WalkSpeed
    end

    -- 1. Check if server set RagdollEndTime > 0; if so, clear it immediately
    local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
    if typeof(rEnd) == "number" and rEnd > 0 then
        clearRagdollAttributes()
        enablePlayerControls()
    end

    -- 2. Check for disabled motors
    local total, disabled = #jointsTable, 0
    for _, m in ipairs(jointsTable) do
        if m and m.Parent and not m.Enabled then
            disabled = disabled + 1
            m.Enabled = true
        end
    end

    if disabled > 0 then
        executeInstantRecovery(string.format("%dMotorsFixed", disabled))
    end

    -- 3. Check for slam downward plunge
    if isSlamDampenerEnabled and hrp then
        local vy = hrp.AssemblyLinearVelocity.Y
        if vy < -30 then
            hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, math.clamp(vy, -5, 50), hrp.AssemblyLinearVelocity.Z)
        end
    end

    -- 4. Ensure controls and WalkSpeed are intact
    if hum.WalkSpeed < 16.0 then
        hum.WalkSpeed = math.max(savedWalkSpeed, 16.0)
        enablePlayerControls()
    end

    -- Update status display
    statusLbl.Text = string.format("Motors: %d/%d OK · Recoveries: %d", total - disabled, total, recoveryCount)
end)

-- ========================================================================
-- UI EVENT BINDINGS
-- ========================================================================

local function updateUI()
    if isRecoveryEnabled then
        toggleBtn.Text = "🛡️ ZERO-WAIT RECOVERY: ACTIVE"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(30, 160, 95)
        toggleStroke.Color = Color3.fromRGB(60, 230, 140)
    else
        toggleBtn.Text = "⏸️ RECOVERY: PAUSED"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(150, 50, 50)
        toggleStroke.Color = Color3.fromRGB(220, 80, 80)
        infoLbl.Text = "State: Paused"
        infoLbl.TextColor3 = Color3.fromRGB(220, 120, 120)
    end

    if isSlamDampenerEnabled then
        dampBtn.Text = "Slam Velocity Absorber: ON"
        dampBtn.TextColor3 = Color3.fromRGB(140, 220, 255)
    else
        dampBtn.Text = "Slam Velocity Absorber: OFF"
        dampBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
    end
end

toggleBtn.MouseButton1Click:Connect(function()
    isRecoveryEnabled = not isRecoveryEnabled
    updateUI()
end)

dampBtn.MouseButton1Click:Connect(function()
    isSlamDampenerEnabled = not isSlamDampenerEnabled
    updateUI()
end)

closeBtn.MouseButton1Click:Connect(function()
    running = false
    if heartbeatConn then heartbeatConn:Disconnect() end
    for _, conn in ipairs(characterConnections) do
        pcall(function() conn:Disconnect() end)
    end
    if gui then gui:Destroy() end
    print("[InstantRecovery] Script terminated safely.")
end)

-- Respawn listener
LocalPlayer.CharacterAdded:Connect(function(newChar)
    task.wait(0.2)
    if running then
        bindCharacter(newChar)
    end
end)

-- Initial bind
if LocalPlayer.Character then
    bindCharacter(LocalPlayer.Character)
end

updateUI()
print("[InstantRecovery] v2.0 Zero-Wait loaded and monitoring.")
