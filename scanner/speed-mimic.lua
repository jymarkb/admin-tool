--[[
    STEAL AN EGG - VELOCITY CONTROLLER, DYNAMIC MICRO-PULSE & EGG MASS NEUTRALIZER (v4.1)
    Target: 350 - 2,500+ Speed via Dynamic Physics Scaling & Featherweight Carry System
    
    Why Eggs Cause Slowdown / Debuff (Dual Mechanics Solved):
      1. Physical Mass & Collision Drag:
         Equipped egg tools (e.g. Workspace.Player["Red Panda Egg"]) add non-massless parts
         and CanCollide=true geometry. Scraping the ground produces massive friction & physics drag.
         -> v4.1 applies PhysicalProperties(0.0001, 0, 0, 0, 0), Massless=true, CanCollide=false,
            CanTouch=false, and CanQuery=false across all tool parts.
      2. Game Client WalkSpeed Debuff Script:
         Game scripts intercept RF/EggWorld/AskFieldEggCarry and calculate an encumbrance penalty
         proportional to egg Weight (dropping WalkSpeed from ~237 to ~218 or lower).
         -> v4.1 uses a metatable __newindex hook to block WalkSpeed debuff writes.
      3. Server Carry Distance Budget:
         The server enforces a stricter displacement limit per tick while carrying an egg.
         -> v4.1 provides dedicated Carry Speed controls (default 260) with Match Travel toggle,
            plus Carry-Tuned Dynamic Micro-Pulse (32-stud carry burst budget).
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- Guaranteed visible UI mount
local function getGuiParent()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local uiParent = getGuiParent()

-- Destroy previous instance if open
local existingGui = uiParent:FindFirstChild("SpeedMimicControllerGui")
if existingGui then
    pcall(function() existingGui:Destroy() end)
end

-- ============================================================
-- STATE & CONFIG
-- ============================================================

local mimicActive         = false
local targetPlayerName    = "Kaihii"
local targetVelocity      = 300.0      -- Default travel velocity (when empty-handed)
local effectiveVelocity   = 300.0
local fallbackSpeed       = 240.0
local savedOriginalSpeed  = nil

-- Dedicated Egg Carry Speed & Physics Neutralization
local carryVelocity       = 260.0      -- Dedicated carry speed (safe against server carry anti-cheat)
local matchTravelSpeed    = false      -- If true, enforces targetVelocity (e.g. 300) even when carrying
local isCurrentlyCarrying = false
local travelBurstDistance = 100      -- Stud budget per burst when travel/empty-handed
local carryBurstDistance  = 32.0       -- Stud budget per burst when carrying egg (tighter server threshold)

-- Dynamic Micro-Pulse Auto-Timing Configuration
local pulseModeActive     = false      -- Toggled via UI
local pulseBurstSpeed     = 400.0      -- Default burst speed (supports up to 2500+)
local pulseGlideSpeed     = 235.0      -- Safe recovery glide velocity
local targetBurstDistance = 100.0       -- Active max studs per burst before server snap (auto-tunes)
local targetAverageSpeed  = 280.0      -- Target average speed across the cycle

local pulseBurstDuration  = 0.105      -- Auto-calculated dynamically
local pulseGlideDuration  = 0.280      -- Auto-calculated dynamically
local pulseCycleStart     = 0
local isCurrentlyBursting = false

local autoTuneRubberband  = true
local rubberCount         = 0
local lastRubberReason    = "None"
local rbCooldownUntil     = 0
local rbLastPos           = nil
local rbLastT             = nil

-- Recovery & Anti-Death State
local recoveryActive      = false
local lastRecoveryTime    = 0
local wasRagdolled        = false

local oldNewIndex         = nil
local hookActive          = false
local originalProperties  = {}
local heartbeatConn       = nil
local toolAddedConn       = nil
local toolRemovedConn     = nil

local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)
local featherweightProps = PhysicalProperties.new(0.0001, 0, 0, 0, 0) -- Near-zero density & zero friction for eggs

-- Forward declarations
local updateUiMetrics     = nil
local recalculatePulseTimings = nil

-- Clean up any residual constraints from previous script versions
local function cleanResidualConstraints()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        for _, child in ipairs(root:GetChildren()) do
            if child.Name == "SpeedMimicAttachment"
               or child.Name == "SpeedMimicMover"
               or child.Name == "SpeedMimicLinearVelocity"
               or child.Name == "SpeedMimicBodyVelocity"
               or child:IsA("BodyVelocity")
               or child:IsA("LinearVelocity") then
                pcall(function() child:Destroy() end)
            end
        end
    end
end
pcall(cleanResidualConstraints)

-- ============================================================
-- DYNAMIC TIMING FORMULA ENGINE (CARRY-AWARE)
-- ============================================================

recalculatePulseTimings = function()
    -- 1. Determine active burst distance cap based on carrying state
    local activeCap = isCurrentlyCarrying and carryBurstDistance or targetBurstDistance

    -- 2. Burst Duration: Distance / Speed (clamped between 20ms and 200ms)
    pulseBurstDuration = math.clamp(activeCap / math.max(50, pulseBurstSpeed), 0.020, 0.200)

    -- 3. Glide Duration: Time needed at glide speed to keep average speed within budget
    local targetAvg = isCurrentlyCarrying and math.min(targetAverageSpeed, 260.0) or targetAverageSpeed
    local excessSpeed = math.max(0, pulseBurstSpeed - targetAvg)
    local rechargeRate = math.max(15, targetAvg - pulseGlideSpeed)
    local neededGlide = pulseBurstDuration * (excessSpeed / rechargeRate)

    -- Clamped between 80ms and 1.5s
    pulseGlideDuration = math.clamp(neededGlide, 0.080, 1.500)
end
recalculatePulseTimings()

-- ============================================================
-- TARGET RESOLVER
-- ============================================================

local function resolveTarget(nameQuery)
    nameQuery = (nameQuery or "Kaihii"):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local targetPlr, targetChar

    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == nameQuery or p.DisplayName:lower() == nameQuery then
            targetPlr = p
            targetChar = p.Character
            break
        end
    end

    if not targetPlr then
        for _, p in ipairs(Players:GetPlayers()) do
            if string.find(p.Name:lower(), nameQuery, 1, true) or string.find(p.DisplayName:lower(), nameQuery, 1, true) then
                targetPlr = p
                targetChar = p.Character
                break
            end
        end
    end

    if not targetChar then
        for _, obj in ipairs(Workspace:GetChildren()) do
            if obj:IsA("Model") and (obj:FindFirstChildOfClass("Humanoid") or obj:FindFirstChild("HumanoidRootPart")) then
                if obj.Name:lower() == nameQuery or string.find(obj.Name:lower(), nameQuery, 1, true) then
                    targetChar = obj
                    break
                end
            end
        end
    end

    return targetPlr, targetChar
end

local function getLiveTargetSpeed()
    local _, char = resolveTarget(targetPlayerName)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed and hum.WalkSpeed > 20 then
        return hum.WalkSpeed
    end
    return 339.3234
end

-- ============================================================
-- MODEL FRICTION & EGG MASS NEUTRALIZATION
-- ============================================================

local function setFrictionless(enable)
    local char = LocalPlayer.Character
    if not char then return end

    for _, desc in ipairs(char:GetDescendants()) do
        if desc:IsA("BasePart") then
            if enable then
                if originalProperties[desc] == nil then
                    pcall(function() originalProperties[desc] = desc.CustomPhysicalProperties end)
                end
                pcall(function() desc.CustomPhysicalProperties = zeroFriction end)
            else
                if originalProperties[desc] ~= nil then
                    pcall(function() desc.CustomPhysicalProperties = originalProperties[desc] end)
                else
                    pcall(function() desc.CustomPhysicalProperties = nil end)
                end
            end
        end
    end

    if not enable then
        table.clear(originalProperties)
    end
end

local function isHoldingEgg()
    local char = LocalPlayer.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") then
                return true
            end
            if child:IsA("Model") and string.find(string.lower(child.Name), "egg", 1, true) then
                return true
            end
        end
    end
    -- Check player carry attributes
    local carryAttr = LocalPlayer:GetAttribute("IsCarrying")
        or LocalPlayer:GetAttribute("HoldingEgg")
        or LocalPlayer:GetAttribute("CarryingEgg")
        or LocalPlayer:GetAttribute("CarryUid")
    if carryAttr ~= nil and carryAttr ~= false and carryAttr ~= "" then
        return true
    end
    return false
end

local function neutralizeEggPhysics(char)
    if not char then return end

    -- 1. Neutralize all parts in Character and equipped Tools
    for _, desc in ipairs(char:GetDescendants()) do
        if desc:IsA("BasePart") then
            pcall(function()
                if desc.Name ~= "HumanoidRootPart" then
                    desc.CanCollide = false
                    desc.Massless = true
                    desc.CustomPhysicalProperties = featherweightProps
                end
                -- If inside a Tool or accessory, strip collision queries and touch drag
                if desc:FindFirstAncestorOfClass("Tool") or desc.Parent ~= char then
                    desc.CanTouch = false
                    desc.CanQuery = false
                end
            end)
        end
    end

    -- 2. Neutralize ClientRenderedAssets models belonging to user
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        local userPrefix = tostring(LocalPlayer.UserId)
        for _, model in ipairs(cra:GetChildren()) do
            if string.find(model.Name, userPrefix, 1, true) then
                for _, part in ipairs(model:GetDescendants()) do
                    if part:IsA("BasePart") then
                        pcall(function()
                            part.Massless = true
                            part.CanCollide = false
                            part.CanTouch = false
                            part.CanQuery = false
                            part.CustomPhysicalProperties = featherweightProps
                        end)
                    end
                end
            end
        end
    end
end

local function setupCharToolListener(char)
    if toolAddedConn then toolAddedConn:Disconnect(); toolAddedConn = nil end
    if toolRemovedConn then toolRemovedConn:Disconnect(); toolRemovedConn = nil end
    if not char then return end

    toolAddedConn = char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") or (child:IsA("Model") and string.find(string.lower(child.Name), "egg", 1, true)) then
            task.defer(function()
                neutralizeEggPhysics(char)
                isCurrentlyCarrying = true
                if pulseModeActive then recalculatePulseTimings() end
                if updateUiMetrics then updateUiMetrics() end
            end)
        end
    end)

    toolRemovedConn = char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") or (child:IsA("Model") and string.find(string.lower(child.Name), "egg", 1, true)) then
            task.defer(function()
                isCurrentlyCarrying = isHoldingEgg()
                if pulseModeActive then recalculatePulseTimings() end
                if updateUiMetrics then updateUiMetrics() end
            end)
        end
    end)
end

-- ============================================================
-- WALKSPEED METAMETHOD HOOK (ANTI-DEBUFF ENGINE)
-- ============================================================

local function installWalkSpeedHook()
    if hookActive then return end
    if typeof(hookmetamethod) ~= "function" then return end

    local ok, res = pcall(function()
        oldNewIndex = hookmetamethod(game, "__newindex", function(self, key, value)
            if key == "WalkSpeed" and mimicActive then
                local isHum = false
                pcall(function() isHum = self:IsA("Humanoid") and self.Parent == LocalPlayer.Character end)
                if isHum then
                    local baseSpeed = (isCurrentlyCarrying and not matchTravelSpeed) and carryVelocity or effectiveVelocity
                    local targetToLock = pulseModeActive and (isCurrentlyBursting and pulseBurstSpeed or pulseGlideSpeed) or baseSpeed
                    return oldNewIndex(self, key, targetToLock)
                end
            end
            return oldNewIndex(self, key, value)
        end)
    end)

    if ok then
        hookActive = true
    end
end

-- ============================================================
-- RAGDOLL DETECTION & RECOVERY ENGINE (ANTI-DEATH)
-- ============================================================

local function getRagdollReason(hum)
    if not hum then return nil end

    local ragdollEnd = LocalPlayer:GetAttribute("RagdollEndTime")
    if typeof(ragdollEnd) == "number" and ragdollEnd > Workspace:GetServerTimeNow() then
        return "RagdollEndTime"
    end

    local state = hum:GetState()
    if state == Enum.HumanoidStateType.Ragdoll then return "Ragdoll" end
    if state == Enum.HumanoidStateType.FallingDown then return "FallingDown" end
    if state == Enum.HumanoidStateType.Physics then return "Physics" end
    if hum.PlatformStand then return "PlatformStand" end

    local char = hum.Parent
    if char then
        local disabledMotors = 0
        local totalMotors = 0
        for _, obj in ipairs(char:GetDescendants()) do
            if obj:IsA("Motor6D") then
                totalMotors = totalMotors + 1
                if not obj.Enabled then
                    disabledMotors = disabledMotors + 1
                end
            end
        end
        if totalMotors > 0 and disabledMotors >= 2 then
            return string.format("Motor6D:%d disabled", disabledMotors)
        end
    end

    return nil
end

local function recoveryPulse(hum)
    if not hum then return end
    local now = os.clock()
    if now - lastRecoveryTime < 0.20 or recoveryActive then return end

    recoveryActive = true
    lastRecoveryTime = now

    local char = hum.Parent
    if not char then
        recoveryActive = false
        return
    end

    -- Halt velocity immediately
    local root = char:FindFirstChild("HumanoidRootPart")
    if root then
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.new(0, math.clamp(root.AssemblyLinearVelocity.Y, -30, 10), 0)
        end)
    end

    -- Re-enable joints
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA("Motor6D") and not obj.Enabled then
            pcall(function() obj.Enabled = true end)
        end
    end

    -- Restore Humanoid controls
    pcall(function()
        hum.PlatformStand = false
        hum.Sit = false
        hum.AutoRotate = true
        hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    end)

    task.wait(0.05)
    if hum.Parent then
        pcall(function()
            hum:ChangeState(Enum.HumanoidStateType.Running)
        end)
    end

    recoveryActive = false
end

-- ============================================================
-- ANTI-RUBBERBAND REAL-TIME DETECTION & DYNAMIC ADAPTATION
-- ============================================================

local function detectRubberband(char, hum, root)
    local now = os.clock()
    local pos = root.Position
    local last = rbLastPos
    local lastT = rbLastT
    rbLastPos = pos
    rbLastT = now

    if not last or not lastT then return end
    local dt = now - lastT
    if dt <= 0 or dt > 0.25 then return end

    if hum.MoveDirection.Magnitude < 0.1 then return end
    local md = hum.MoveDirection.Unit

    local disp = Vector3.new(pos.X - last.X, 0, pos.Z - last.Z)
    local back = -(disp:Dot(md))

    if back >= 4.5 and now >= rbCooldownUntil then
        rbCooldownUntil = now + 0.6
        rubberCount = rubberCount + 1
        lastRubberReason = string.format("%.1f studs back snap", back)

        root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)

        if pulseModeActive and autoTuneRubberband then
            -- Server rejected this distance! Auto-tune burst distance cap down by 2 studs
            if isCurrentlyCarrying then
                carryBurstDistance = math.max(16.0, carryBurstDistance - 2.0)
                recalculatePulseTimings()
                print(string.format("[Carry Pulse Auto-Tune] ⚠️ Server Snap #%d! Micro-tuned carry burst cap to %.1f studs (Burst: %.0fms, Glide: %.0fms)!", rubberCount, carryBurstDistance, pulseBurstDuration * 1000, pulseGlideDuration * 1000))
            else
                targetBurstDistance = math.max(18.0, targetBurstDistance - 2.0)
                recalculatePulseTimings()
                print(string.format("[Travel Pulse Auto-Tune] ⚠️ Server Snap #%d! Micro-tuned burst cap to %.1f studs (Burst: %.0fms, Glide: %.0fms)!", rubberCount, targetBurstDistance, pulseBurstDuration * 1000, pulseGlideDuration * 1000))
            end
        elseif autoTuneRubberband then
            if isCurrentlyCarrying and not matchTravelSpeed then
                local prev = carryVelocity
                carryVelocity = math.max(100, carryVelocity - 10)
                print(string.format("[Carry Speed Auto-Tune] ⚠️ Server Snap #%d! Stepping carry speed down: %.1f -> %.1f", rubberCount, prev, carryVelocity))
            else
                local prev = effectiveVelocity
                effectiveVelocity = math.max(120, effectiveVelocity - 10)
                print(string.format("[Travel Speed Auto-Tune] ⚠️ Server Snap #%d! Stepping speed down: %.1f -> %.1f", rubberCount, prev, effectiveVelocity))
            end
        end

        if updateUiMetrics then updateUiMetrics() end
    end
end

-- Dynamic Animation Playback Scaling
local function scaleAnimations(hum, curSpeed)
    local animator = hum:FindFirstChildOfClass("Animator")
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            if track.WeightCurrent > 0.2 and track.Length > 0 then
                local animName = track.Name:lower()
                local isMoveAnim = animName:find("run") or animName:find("walk") or animName:find("sprint")
                if isMoveAnim or track.Speed > 0.5 then
                    local desiredSpeed = math.clamp(curSpeed / 16, 1, 25)
                    if math.abs(track.Speed - desiredSpeed) > 0.5 then
                        pcall(function() track:AdjustSpeed(desiredSpeed) end)
                    end
                end
            end
        end
    end
end

-- ============================================================
-- MAIN HEARTBEAT VELOCITY & PULSE ENGINE
-- ============================================================

local function onHeartbeat(dt)
    if not mimicActive then return end

    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not hum or not root then return end

    -- Safe Ragdoll / Joint Death Prevention
    local ragdollReason = getRagdollReason(hum)
    if ragdollReason then
        wasRagdolled = true
        task.spawn(function()
            recoveryPulse(hum)
        end)
        return
    end

    -- Egg Detection & Re-calibration
    local holdingNow = isHoldingEgg()
    if holdingNow ~= isCurrentlyCarrying then
        isCurrentlyCarrying = holdingNow
        if pulseModeActive then
            recalculatePulseTimings()
        end
        if updateUiMetrics then updateUiMetrics() end
    end

    -- Egg mass & collision neutralization
    if isCurrentlyCarrying then
        neutralizeEggPhysics(char)
    end

    -- Determine Base Speed to Apply
    local baseSpeed = (isCurrentlyCarrying and not matchTravelSpeed) and carryVelocity or effectiveVelocity

    if wasRagdolled then
        wasRagdolled = false
        pcall(function() hum.WalkSpeed = baseSpeed end)
    end

    -- Real-time rubberband detection
    detectRubberband(char, hum, root)

    -- Determine Velocity to Apply (Pulse Mode vs Steady Mode)
    local currentSpeedToApply = baseSpeed

    if pulseModeActive then
        if hum.MoveDirection.Magnitude > 0.05 then
            local now = os.clock()
            if pulseCycleStart == 0 then pulseCycleStart = now end
            local cycleDuration = pulseBurstDuration + pulseGlideDuration
            local elapsed = (now - pulseCycleStart) % cycleDuration

            if elapsed < pulseBurstDuration then
                currentSpeedToApply = pulseBurstSpeed
                isCurrentlyBursting = true
            else
                currentSpeedToApply = pulseGlideSpeed
                isCurrentlyBursting = false
            end
        else
            pulseCycleStart = 0
            isCurrentlyBursting = false
            currentSpeedToApply = pulseGlideSpeed
        end
    else
        isCurrentlyBursting = false
    end

    -- Force Humanoid WalkSpeed (Anti-Debuff enforcement)
    if hum.WalkSpeed ~= currentSpeedToApply then
        pcall(function() hum.WalkSpeed = currentSpeedToApply end)
    end

    -- Safe Vector Velocity Injection (XZ plane only, preserves Y for 100% natural gravity)
    if hum.MoveDirection.Magnitude > 0.05 then
        local dir = hum.MoveDirection.Unit
        root.AssemblyLinearVelocity = Vector3.new(
            dir.X * currentSpeedToApply,
            root.AssemblyLinearVelocity.Y,
            dir.Z * currentSpeedToApply
        )
    end

    -- Animation scaling
    scaleAnimations(hum, currentSpeedToApply)
end

-- ============================================================
-- ACTIVATION / TEARDOWN CONTROLLER
-- ============================================================

local function startMimic()
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return false end

    cleanResidualConstraints()

    if not savedOriginalSpeed then
        savedOriginalSpeed = (hum.WalkSpeed > 0) and hum.WalkSpeed or 16
    end

    effectiveVelocity = targetVelocity
    isCurrentlyCarrying = isHoldingEgg()
    rubberCount = 0
    lastRubberReason = "None"
    rbLastPos = nil
    rbLastT = nil
    pulseCycleStart = 0
    mimicActive = true

    recalculatePulseTimings()
    setFrictionless(true)
    setupCharToolListener(char)
    if isCurrentlyCarrying then
        neutralizeEggPhysics(char)
    end
    installWalkSpeedHook()

    local activeSpeed = (isCurrentlyCarrying and not matchTravelSpeed) and carryVelocity or effectiveVelocity
    pcall(function() hum.WalkSpeed = activeSpeed end)

    if heartbeatConn then heartbeatConn:Disconnect() end
    heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)

    return true
end

local function stopMimic()
    mimicActive = false

    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end

    setupCharToolListener(nil)
    cleanResidualConstraints()

    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if hum and savedOriginalSpeed then
        pcall(function() hum.WalkSpeed = savedOriginalSpeed end)
    end
    if root then
        pcall(function() root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0) end)
    end

    setFrictionless(false)
    isCurrentlyCarrying = false
end

-- ============================================================
-- USER INTERFACE
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SpeedMimicControllerGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = uiParent

local W, H = 460, 332
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(80, 120, 220)
mainStroke.Thickness = 1.5

-- Top Bar
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 34)
topBar.BackgroundColor3 = Color3.fromRGB(26, 32, 48)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "⚡ DYNAMIC PULSE & EGG CARRY CONTROLLER v4.1"
titleLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 11.5
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -30, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function()
    stopMimic()
    screenGui:Destroy()
end)

-- Draggable Logic
do
    local dragging, dragInput, dragStart, startPos
    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    topBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- ============================================================
-- CONTROLS & METRICS
-- ============================================================

-- Forward declarations for inputs
local carryValBox = nil
local matchToggleBtn = nil

-- Row 1: Travel Speed Controls (-50, -10, box, +10, +50, Badge)
local r1 = Instance.new("Frame")
r1.Size = UDim2.new(1, -24, 0, 24)
r1.Position = UDim2.new(0, 12, 0, 39)
r1.BackgroundTransparency = 1
r1.Parent = main

local sLbl = Instance.new("TextLabel")
sLbl.Size = UDim2.new(0, 78, 1, 0)
sLbl.BackgroundTransparency = 1
sLbl.Text = "Travel Spd:"
sLbl.TextColor3 = Color3.fromRGB(180, 210, 255)
sLbl.Font = Enum.Font.GothamBold
sLbl.TextSize = 10.5
sLbl.TextXAlignment = Enum.TextXAlignment.Left
sLbl.Parent = r1

local btnMinus50 = Instance.new("TextButton")
btnMinus50.Size = UDim2.new(0, 28, 1, 0); btnMinus50.Position = UDim2.new(0, 80, 0, 0)
btnMinus50.BackgroundColor3 = Color3.fromRGB(35, 40, 58); btnMinus50.Text = "-50"
btnMinus50.TextColor3 = Color3.fromRGB(200, 220, 255); btnMinus50.Font = Enum.Font.GothamBold; btnMinus50.TextSize = 9
btnMinus50.Parent = r1
Instance.new("UICorner", btnMinus50).CornerRadius = UDim.new(0, 5)

local btnMinus10 = Instance.new("TextButton")
btnMinus10.Size = UDim2.new(0, 28, 1, 0); btnMinus10.Position = UDim2.new(0, 112, 0, 0)
btnMinus10.BackgroundColor3 = Color3.fromRGB(35, 40, 58); btnMinus10.Text = "-10"
btnMinus10.TextColor3 = Color3.fromRGB(220, 230, 255); btnMinus10.Font = Enum.Font.GothamBold; btnMinus10.TextSize = 9
btnMinus10.Parent = r1
Instance.new("UICorner", btnMinus10).CornerRadius = UDim.new(0, 5)

local speedValBox = Instance.new("TextBox")
speedValBox.Size = UDim2.new(0, 62, 1, 0); speedValBox.Position = UDim2.new(0, 144, 0, 0)
speedValBox.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
speedValBox.Text = tostring(math.floor(pulseModeActive and pulseBurstSpeed or targetVelocity))
speedValBox.TextColor3 = Color3.fromRGB(255, 220, 100); speedValBox.Font = Enum.Font.GothamBold; speedValBox.TextSize = 11.5
speedValBox.Parent = r1
Instance.new("UICorner", speedValBox).CornerRadius = UDim.new(0, 5)

local btnPlus10 = Instance.new("TextButton")
btnPlus10.Size = UDim2.new(0, 28, 1, 0); btnPlus10.Position = UDim2.new(0, 210, 0, 0)
btnPlus10.BackgroundColor3 = Color3.fromRGB(35, 40, 58); btnPlus10.Text = "+10"
btnPlus10.TextColor3 = Color3.fromRGB(220, 230, 255); btnPlus10.Font = Enum.Font.GothamBold; btnPlus10.TextSize = 9
btnPlus10.Parent = r1
Instance.new("UICorner", btnPlus10).CornerRadius = UDim.new(0, 5)

local btnPlus50 = Instance.new("TextButton")
btnPlus50.Size = UDim2.new(0, 28, 1, 0); btnPlus50.Position = UDim2.new(0, 242, 0, 0)
btnPlus50.BackgroundColor3 = Color3.fromRGB(35, 40, 58); btnPlus50.Text = "+50"
btnPlus50.TextColor3 = Color3.fromRGB(200, 220, 255); btnPlus50.Font = Enum.Font.GothamBold; btnPlus50.TextSize = 9
btnPlus50.Parent = r1
Instance.new("UICorner", btnPlus50).CornerRadius = UDim.new(0, 5)

local statusBadge = Instance.new("TextLabel")
statusBadge.Size = UDim2.new(1, -276, 1, 0); statusBadge.Position = UDim2.new(0, 276, 0, 0)
statusBadge.BackgroundColor3 = Color3.fromRGB(25, 45, 35); statusBadge.Text = "ACCOUNT SAFE"
statusBadge.TextColor3 = Color3.fromRGB(130, 255, 170); statusBadge.Font = Enum.Font.GothamBold; statusBadge.TextSize = 9.5
statusBadge.Parent = r1
Instance.new("UICorner", statusBadge).CornerRadius = UDim.new(0, 5)

-- Row 2: Egg Carry Speed Controls (-20, -10, box, +10, +20, Match Toggle)
local r2 = Instance.new("Frame")
r2.Size = UDim2.new(1, -24, 0, 24)
r2.Position = UDim2.new(0, 12, 0, 67)
r2.BackgroundTransparency = 1
r2.Parent = main

local cLbl = Instance.new("TextLabel")
cLbl.Size = UDim2.new(0, 78, 1, 0)
cLbl.BackgroundTransparency = 1
cLbl.Text = "Carry Spd:"
cLbl.TextColor3 = Color3.fromRGB(160, 255, 200)
cLbl.Font = Enum.Font.GothamBold
cLbl.TextSize = 10.5
cLbl.TextXAlignment = Enum.TextXAlignment.Left
cLbl.Parent = r2

local btnCMinus20 = Instance.new("TextButton")
btnCMinus20.Size = UDim2.new(0, 28, 1, 0); btnCMinus20.Position = UDim2.new(0, 80, 0, 0)
btnCMinus20.BackgroundColor3 = Color3.fromRGB(30, 48, 45); btnCMinus20.Text = "-20"
btnCMinus20.TextColor3 = Color3.fromRGB(180, 240, 220); btnCMinus20.Font = Enum.Font.GothamBold; btnCMinus20.TextSize = 9
btnCMinus20.Parent = r2
Instance.new("UICorner", btnCMinus20).CornerRadius = UDim.new(0, 5)

local btnCMinus10 = Instance.new("TextButton")
btnCMinus10.Size = UDim2.new(0, 28, 1, 0); btnCMinus10.Position = UDim2.new(0, 112, 0, 0)
btnCMinus10.BackgroundColor3 = Color3.fromRGB(30, 48, 45); btnCMinus10.Text = "-10"
btnCMinus10.TextColor3 = Color3.fromRGB(200, 250, 230); btnCMinus10.Font = Enum.Font.GothamBold; btnCMinus10.TextSize = 9
btnCMinus10.Parent = r2
Instance.new("UICorner", btnCMinus10).CornerRadius = UDim.new(0, 5)

carryValBox = Instance.new("TextBox")
carryValBox.Size = UDim2.new(0, 62, 1, 0); carryValBox.Position = UDim2.new(0, 144, 0, 0)
carryValBox.BackgroundColor3 = Color3.fromRGB(20, 35, 32)
carryValBox.Text = tostring(math.floor(carryVelocity))
carryValBox.TextColor3 = Color3.fromRGB(140, 255, 200); carryValBox.Font = Enum.Font.GothamBold; carryValBox.TextSize = 11.5
carryValBox.Parent = r2
Instance.new("UICorner", carryValBox).CornerRadius = UDim.new(0, 5)

local btnCPlus10 = Instance.new("TextButton")
btnCPlus10.Size = UDim2.new(0, 28, 1, 0); btnCPlus10.Position = UDim2.new(0, 210, 0, 0)
btnCPlus10.BackgroundColor3 = Color3.fromRGB(30, 48, 45); btnCPlus10.Text = "+10"
btnCPlus10.TextColor3 = Color3.fromRGB(200, 250, 230); btnCPlus10.Font = Enum.Font.GothamBold; btnCPlus10.TextSize = 9
btnCPlus10.Parent = r2
Instance.new("UICorner", btnCPlus10).CornerRadius = UDim.new(0, 5)

local btnCPlus20 = Instance.new("TextButton")
btnCPlus20.Size = UDim2.new(0, 28, 1, 0); btnCPlus20.Position = UDim2.new(0, 242, 0, 0)
btnCPlus20.BackgroundColor3 = Color3.fromRGB(30, 48, 45); btnCPlus20.Text = "+20"
btnCPlus20.TextColor3 = Color3.fromRGB(180, 240, 220); btnCPlus20.Font = Enum.Font.GothamBold; btnCPlus20.TextSize = 9
btnCPlus20.Parent = r2
Instance.new("UICorner", btnCPlus20).CornerRadius = UDim.new(0, 5)

matchToggleBtn = Instance.new("TextButton")
matchToggleBtn.Size = UDim2.new(1, -276, 1, 0); matchToggleBtn.Position = UDim2.new(0, 276, 0, 0)
matchToggleBtn.BackgroundColor3 = matchTravelSpeed and Color3.fromRGB(35, 125, 75) or Color3.fromRGB(45, 48, 60)
matchToggleBtn.Text = matchTravelSpeed and "MATCH: ON" or "MATCH: OFF"
matchToggleBtn.TextColor3 = matchTravelSpeed and Color3.fromRGB(200, 255, 210) or Color3.fromRGB(180, 190, 210)
matchToggleBtn.Font = Enum.Font.GothamBold; matchToggleBtn.TextSize = 9.5
matchToggleBtn.Parent = r2
Instance.new("UICorner", matchToggleBtn).CornerRadius = UDim.new(0, 5)

local function applySpeedInput(newSpeed)
    newSpeed = math.clamp(tonumber(newSpeed) or 300, 16, 2500)
    targetVelocity = newSpeed
    effectiveVelocity = newSpeed
    if matchTravelSpeed then
        carryVelocity = newSpeed
        if carryValBox then carryValBox.Text = tostring(math.floor(newSpeed)) end
    end
    if pulseModeActive then
        pulseBurstSpeed = newSpeed
        recalculatePulseTimings()
    end
    speedValBox.Text = tostring(math.floor(newSpeed))

    if pulseModeActive then
        statusBadge.Text = string.format("⚡ PULSE %.0f", pulseBurstSpeed)
        statusBadge.BackgroundColor3 = Color3.fromRGB(60, 35, 80)
        statusBadge.TextColor3 = Color3.fromRGB(230, 190, 255)
    elseif targetVelocity <= 255 then
        statusBadge.Text = "ACCOUNT SAFE"
        statusBadge.BackgroundColor3 = Color3.fromRGB(25, 45, 35)
        statusBadge.TextColor3 = Color3.fromRGB(130, 255, 170)
    elseif targetVelocity <= 300 then
        statusBadge.Text = "PUSH SPRINT"
        statusBadge.BackgroundColor3 = Color3.fromRGB(60, 50, 25)
        statusBadge.TextColor3 = Color3.fromRGB(255, 210, 100)
    else
        statusBadge.Text = "⚠️ TEST OVERCAP"
        statusBadge.BackgroundColor3 = Color3.fromRGB(65, 25, 25)
        statusBadge.TextColor3 = Color3.fromRGB(255, 130, 130)
    end

    if updateUiMetrics then updateUiMetrics() end
end

local function applyCarrySpeedInput(newSpeed)
    newSpeed = math.clamp(tonumber(newSpeed) or 260, 16, 2500)
    carryVelocity = newSpeed
    if carryValBox then carryValBox.Text = tostring(math.floor(newSpeed)) end
    if isCurrentlyCarrying and pulseModeActive then
        recalculatePulseTimings()
    end
    if updateUiMetrics then updateUiMetrics() end
end

btnMinus50.MouseButton1Click:Connect(function()
    local cur = pulseModeActive and pulseBurstSpeed or targetVelocity
    applySpeedInput(cur - 50)
end)
btnMinus10.MouseButton1Click:Connect(function()
    local cur = pulseModeActive and pulseBurstSpeed or targetVelocity
    applySpeedInput(cur - 10)
end)
btnPlus10.MouseButton1Click:Connect(function()
    local cur = pulseModeActive and pulseBurstSpeed or targetVelocity
    applySpeedInput(cur + 10)
end)
btnPlus50.MouseButton1Click:Connect(function()
    local cur = pulseModeActive and pulseBurstSpeed or targetVelocity
    applySpeedInput(cur + 50)
end)
speedValBox.FocusLost:Connect(function()
    applySpeedInput(speedValBox.Text)
end)

btnCMinus20.MouseButton1Click:Connect(function()
    applyCarrySpeedInput(carryVelocity - 20)
end)
btnCMinus10.MouseButton1Click:Connect(function()
    applyCarrySpeedInput(carryVelocity - 10)
end)
btnCPlus10.MouseButton1Click:Connect(function()
    applyCarrySpeedInput(carryVelocity + 10)
end)
btnCPlus20.MouseButton1Click:Connect(function()
    applyCarrySpeedInput(carryVelocity + 20)
end)
carryValBox.FocusLost:Connect(function()
    applyCarrySpeedInput(carryValBox.Text)
end)

matchToggleBtn.MouseButton1Click:Connect(function()
    matchTravelSpeed = not matchTravelSpeed
    matchToggleBtn.BackgroundColor3 = matchTravelSpeed and Color3.fromRGB(35, 125, 75) or Color3.fromRGB(45, 48, 60)
    matchToggleBtn.Text = matchTravelSpeed and "MATCH: ON" or "MATCH: OFF"
    matchToggleBtn.TextColor3 = matchTravelSpeed and Color3.fromRGB(200, 255, 210) or Color3.fromRGB(180, 190, 210)
    if matchTravelSpeed then
        applyCarrySpeedInput(targetVelocity)
    end
    if updateUiMetrics then updateUiMetrics() end
end)

-- Row 3: Live Metrics & Safety Card
local card = Instance.new("Frame")
card.Size = UDim2.new(1, -24, 0, 84)
card.Position = UDim2.new(0, 12, 0, 96)
card.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
card.BorderSizePixel = 0
card.Parent = main
Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)
local cardStroke = Instance.new("UIStroke", card)
cardStroke.Color = Color3.fromRGB(40, 50, 75)

local metricEffective = Instance.new("TextLabel")
metricEffective.Size = UDim2.new(1, -16, 0, 18)
metricEffective.Position = UDim2.new(0, 10, 0, 4)
metricEffective.BackgroundTransparency = 1
metricEffective.Text = "• Running Speed: 300 studs/s"
metricEffective.TextColor3 = Color3.fromRGB(140, 255, 180)
metricEffective.Font = Enum.Font.GothamBold; metricEffective.TextSize = 10.5
metricEffective.TextXAlignment = Enum.TextXAlignment.Left
metricEffective.Parent = card

local metricEggStatus = Instance.new("TextLabel")
metricEggStatus.Size = UDim2.new(1, -16, 0, 18)
metricEggStatus.Position = UDim2.new(0, 10, 0, 22)
metricEggStatus.BackgroundTransparency = 1
metricEggStatus.Text = "• Egg State: EMPTY HANDED (Travel Velocity Active)"
metricEggStatus.TextColor3 = Color3.fromRGB(170, 205, 255)
metricEggStatus.Font = Enum.Font.GothamBold; metricEggStatus.TextSize = 10
metricEggStatus.TextXAlignment = Enum.TextXAlignment.Left
metricEggStatus.Parent = card

local metricSync = Instance.new("TextLabel")
metricSync.Size = UDim2.new(1, -16, 0, 18)
metricSync.Position = UDim2.new(0, 10, 0, 42)
metricSync.BackgroundTransparency = 1
metricSync.Text = "• Server Rollbacks: 0 (100% Stable)"
metricSync.TextColor3 = Color3.fromRGB(140, 230, 180)
metricSync.Font = Enum.Font.GothamBold; metricSync.TextSize = 10
metricSync.TextXAlignment = Enum.TextXAlignment.Left
metricSync.Parent = card

local metricBudget = Instance.new("TextLabel")
metricBudget.Size = UDim2.new(1, -16, 0, 18)
metricBudget.Position = UDim2.new(0, 10, 0, 62)
metricBudget.BackgroundTransparency = 1
metricBudget.Text = "• Timing: Distance Cap: 42 studs | Avg: ~280 studs/s"
metricBudget.TextColor3 = Color3.fromRGB(240, 200, 110)
metricBudget.Font = Enum.Font.Gotham; metricBudget.TextSize = 9.5
metricBudget.TextXAlignment = Enum.TextXAlignment.Left
metricBudget.Parent = card

updateUiMetrics = function()
    if mimicActive then
        local isCarrying = isCurrentlyCarrying
        local activeSpeed = (isCarrying and not matchTravelSpeed) and carryVelocity or effectiveVelocity

        if pulseModeActive then
            local stateTag = isCurrentlyBursting and string.format("⚡ BURST %.0f", pulseBurstSpeed) or string.format("🛡️ GLIDE %.0f", pulseGlideSpeed)
            local stateCol = isCurrentlyBursting and Color3.fromRGB(255, 215, 100) or Color3.fromRGB(140, 240, 190)
            local cycle = pulseBurstDuration + pulseGlideDuration
            local approxAvg = ((pulseBurstSpeed * pulseBurstDuration) + (pulseGlideSpeed * pulseGlideDuration)) / math.max(0.01, cycle)

            metricEffective.Text = string.format("• Micro-Pulse Active: %s (Avg: ~%.0f studs/s)", stateTag, approxAvg)
            metricEffective.TextColor3 = stateCol

            local burstCap = isCarrying and carryBurstDistance or targetBurstDistance
            metricBudget.Text = string.format("• Dynamic Timing (%s): %.0fms Burst (%.1f st) | %.0fms Glide | Cycle: %.0fms", isCarrying and "Carry Tuned" or "Travel", pulseBurstDuration * 1000, burstCap, pulseGlideDuration * 1000, cycle * 1000)
            metricBudget.TextColor3 = Color3.fromRGB(220, 190, 255)
        else
            metricEffective.Text = string.format("• Running Speed: %.1f studs/s (Mode: %s Steady)", activeSpeed, isCarrying and "Carry" or "Travel")
            metricEffective.TextColor3 = Color3.fromRGB(140, 255, 180)
            metricBudget.Text = string.format("• Velocity Plan: Travel %.0f | Carry %.0f (Match Travel: %s)", targetVelocity, carryVelocity, matchTravelSpeed and "ON" or "OFF")
            metricBudget.TextColor3 = Color3.fromRGB(240, 200, 110)
        end

        if isCarrying then
            metricEggStatus.Text = "• Egg State: CARRYING [Massless • Zero Friction • Debuff Blocked]"
            metricEggStatus.TextColor3 = Color3.fromRGB(120, 255, 180)
        else
            metricEggStatus.Text = string.format("• Egg State: EMPTY HANDED (Travel Velocity: %.0f Active)", targetVelocity)
            metricEggStatus.TextColor3 = Color3.fromRGB(160, 210, 255)
        end

        if rubberCount > 0 then
            metricSync.Text = string.format("• Server Rollbacks: %d (Last: %s)", rubberCount, lastRubberReason)
            metricSync.TextColor3 = Color3.fromRGB(255, 140, 140)
        else
            metricSync.Text = "• Server Rollbacks: 0 (100% Stable)"
            metricSync.TextColor3 = Color3.fromRGB(140, 230, 180)
        end
    else
        metricEffective.Text = string.format("• Standby Speed: Travel %.0f | Carry %.0f (Inactive)", targetVelocity, carryVelocity)
        metricEffective.TextColor3 = Color3.fromRGB(160, 180, 210)
        metricEggStatus.Text = "• Egg State: Controller Inactive"
        metricEggStatus.TextColor3 = Color3.fromRGB(160, 170, 190)
        metricSync.Text = "• Server Rollbacks: 0 (Inactive)"
        metricSync.TextColor3 = Color3.fromRGB(150, 170, 200)
        metricBudget.Text = "• Server Budget Status: Inactive"
        metricBudget.TextColor3 = Color3.fromRGB(150, 170, 200)
    end
end

-- Row 4: Presets Bar (Including Safe, Travel 300, Carry 260, Pulses)
local pRow = Instance.new("Frame")
pRow.Size = UDim2.new(1, -24, 0, 22)
pRow.Position = UDim2.new(0, 12, 0, 186)
pRow.BackgroundTransparency = 1
pRow.Parent = main

local pLayout = Instance.new("UIListLayout")
pLayout.FillDirection = Enum.FillDirection.Horizontal
pLayout.Padding = UDim.new(0, 4)
pLayout.Parent = pRow

local function createPresetBtn(text, speedVal, isPulse, isCarry)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 58, 1, 0)
    btn.BackgroundColor3 = isPulse and Color3.fromRGB(55, 35, 75) or (isCarry and Color3.fromRGB(30, 55, 45) or Color3.fromRGB(30, 36, 50))
    btn.Text = text
    btn.TextColor3 = isPulse and Color3.fromRGB(240, 200, 255) or (isCarry and Color3.fromRGB(180, 255, 210) or Color3.fromRGB(180, 200, 230))
    btn.Font = Enum.Font.GothamBold; btn.TextSize = 8.5
    btn.Parent = pRow
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

    btn.MouseButton1Click:Connect(function()
        if isCarry then
            applyCarrySpeedInput(speedVal)
        elseif isPulse then
            pulseModeActive = true
            applySpeedInput(speedVal)
        else
            pulseModeActive = false
            applySpeedInput(speedVal)
        end
        updateUiMetrics()
    end)
end

createPresetBtn("Safe 240", 240.0, false, false)
createPresetBtn("Travel 300", 300.0, false, false)
createPresetBtn("Carry 260", 260.0, false, true)
createPresetBtn("⚡Pulse 350", 350.0, true, false)
createPresetBtn("🔥Pulse 400", 400.0, true, false)
createPresetBtn("🚀Pulse 500", 500.0, true, false)
createPresetBtn("Reset 16", 16.0, false, false)

-- Row 5: Pulse Mode Toggle & Auto-Tune Controls
local r4 = Instance.new("Frame")
r4.Size = UDim2.new(1, -24, 0, 24)
r4.Position = UDim2.new(0, 12, 0, 213)
r4.BackgroundTransparency = 1
r4.Parent = main

local pulseToggleBtn = Instance.new("TextButton")
pulseToggleBtn.Size = UDim2.new(0.52, -4, 1, 0)
pulseToggleBtn.BackgroundColor3 = pulseModeActive and Color3.fromRGB(75, 45, 110) or Color3.fromRGB(42, 45, 58)
pulseToggleBtn.Text = pulseModeActive and string.format("⚡ Pulse (%.0f): ON", pulseBurstSpeed) or "⚡ Dynamic Pulse: OFF"
pulseToggleBtn.TextColor3 = pulseModeActive and Color3.fromRGB(240, 215, 255) or Color3.fromRGB(180, 185, 200)
pulseToggleBtn.Font = Enum.Font.GothamBold; pulseToggleBtn.TextSize = 10
pulseToggleBtn.Parent = r4
Instance.new("UICorner", pulseToggleBtn).CornerRadius = UDim.new(0, 6)

pulseToggleBtn.MouseButton1Click:Connect(function()
    pulseModeActive = not pulseModeActive
    if pulseModeActive then
        pulseToggleBtn.BackgroundColor3 = Color3.fromRGB(75, 45, 110)
        pulseToggleBtn.Text = string.format("⚡ Pulse (%.0f): ON", pulseBurstSpeed)
        pulseToggleBtn.TextColor3 = Color3.fromRGB(240, 215, 255)
        applySpeedInput(pulseBurstSpeed)
    else
        pulseToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 45, 58)
        pulseToggleBtn.Text = "⚡ Dynamic Pulse: OFF"
        pulseToggleBtn.TextColor3 = Color3.fromRGB(180, 185, 200)
        applySpeedInput(targetVelocity)
    end
end)

local autoTuneBtn = Instance.new("TextButton")
autoTuneBtn.Size = UDim2.new(0.48, 0, 1, 0)
autoTuneBtn.Position = UDim2.new(0.52, 4, 0, 0)
autoTuneBtn.BackgroundColor3 = autoTuneRubberband and Color3.fromRGB(35, 75, 125) or Color3.fromRGB(50, 52, 65)
autoTuneBtn.Text = autoTuneRubberband and "🛡️ Auto-Tune: ON" or "🛡️ Auto-Tune: OFF"
autoTuneBtn.TextColor3 = autoTuneRubberband and Color3.fromRGB(200, 230, 255) or Color3.fromRGB(170, 175, 190)
autoTuneBtn.Font = Enum.Font.GothamBold; autoTuneBtn.TextSize = 10
autoTuneBtn.Parent = r4
Instance.new("UICorner", autoTuneBtn).CornerRadius = UDim.new(0, 6)

autoTuneBtn.MouseButton1Click:Connect(function()
    autoTuneRubberband = not autoTuneRubberband
    autoTuneBtn.BackgroundColor3 = autoTuneRubberband and Color3.fromRGB(35, 75, 125) or Color3.fromRGB(50, 52, 65)
    autoTuneBtn.Text = autoTuneRubberband and "🛡️ Auto-Tune: ON" or "🛡️ Auto-Tune: OFF"
    autoTuneBtn.TextColor3 = autoTuneRubberband and Color3.fromRGB(200, 230, 255) or Color3.fromRGB(170, 175, 190)
end)

-- Row 6: Big Master Toggle Button
local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(1, -24, 0, 42)
toggleBtn.Position = UDim2.new(0, 12, 0, 243)
toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 45, 60)
toggleBtn.Text = "⚡ ENABLE SPEED & CARRY CONTROLLER [OFF]"
toggleBtn.TextColor3 = Color3.fromRGB(200, 210, 230)
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 12
toggleBtn.Parent = main
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 8)
local toggleStroke = Instance.new("UIStroke", toggleBtn)
toggleStroke.Color = Color3.fromRGB(70, 80, 100)
toggleStroke.Thickness = 1.5

local footerLbl = Instance.new("TextLabel")
footerLbl.Size = UDim2.new(1, -24, 0, 20)
footerLbl.Position = UDim2.new(0, 12, 0, 292)
footerLbl.BackgroundTransparency = 1
footerLbl.Text = "Zero-mass egg neutralization • Anti-debuff WalkSpeed hook • Server-budget carry scaling"
footerLbl.TextColor3 = Color3.fromRGB(140, 160, 190)
footerLbl.Font = Enum.Font.Gotham
footerLbl.TextSize = 9
footerLbl.Parent = main

toggleBtn.MouseButton1Click:Connect(function()
    if mimicActive then
        stopMimic()
        toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 45, 60)
        toggleBtn.Text = "⚡ ENABLE SPEED & CARRY CONTROLLER [OFF]"
        toggleBtn.TextColor3 = Color3.fromRGB(200, 210, 230)
        toggleStroke.Color = Color3.fromRGB(70, 80, 100)
        updateUiMetrics()
    else
        local success = startMimic()
        if success then
            toggleBtn.BackgroundColor3 = Color3.fromRGB(35, 140, 75)
            local tag = pulseModeActive and string.format("PULSE %.0f SPRINT", pulseBurstSpeed) or string.format("TRAVEL %.0f / CARRY %.0f", targetVelocity, carryVelocity)
            toggleBtn.Text = string.format("⚡ SPEED CONTROLLER ACTIVE: ON (%s)", tag)
            toggleBtn.TextColor3 = Color3.fromRGB(200, 255, 210)
            toggleStroke.Color = Color3.fromRGB(80, 230, 140)
            updateUiMetrics()
        else
            toggleBtn.BackgroundColor3 = Color3.fromRGB(140, 45, 45)
            toggleBtn.Text = "❌ FAILED TO ACTIVATE (Character Not Found)"
            toggleBtn.TextColor3 = Color3.fromRGB(255, 210, 210)
        end
    end
end)

-- Re-apply on character respawn
LocalPlayer.CharacterAdded:Connect(function(newChar)
    if mimicActive then
        task.wait(0.4)
        cleanResidualConstraints()
        startMimic()
        updateUiMetrics()
    end
end)

screenGui.Destroying:Connect(function()
    stopMimic()
end)

applySpeedInput(targetVelocity)
applyCarrySpeedInput(carryVelocity)
print("[Speed Controller v4.1] Initialized with Egg Mass Neutralization & Dedicated Carry Scaling.")
