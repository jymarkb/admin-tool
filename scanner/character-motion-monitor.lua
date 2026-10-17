--[[
    CHARACTER MOTION MONITOR
    Similar to: targeted-character-scanner.lua
    Mode: READ-ONLY | ACTIVE LIVE POLLING

    Focus Areas:
      1. Motor6D Joints     — C0/C1 offsets, CurrentAngle, MaxVelocity, DesiredAngle
      2. Speed & Velocity   — WalkSpeed, JumpPower, Velocity (LinearVelocity / HRP.AssemblyLinearVelocity), MoveDirection
      3. Active Animations  — Playing tracks, AnimationId, Speed, Weight, TimePosition, Looped
      4. Humanoid State     — Health, HumanoidStateType, FloorMaterial, Sit, PlatformStand
      5. RootPart Physics   — AssemblyLinearVelocity, AssemblyAngularVelocity, NetworkOwner (pcall)
      6. Character Tags & Attributes — CollectionService tags, all model/humanoid attributes
      7. Constraints & Springs — AlignPosition, AlignOrientation, LinearVelocity constraints

    Features:
      - Draggable dark-mode UI with live status indicator
      - Active auto-refresh loop (configurable interval, default 1.5s)
      - Per-section collapsible headers with color-coded categories
      - Dynamic player chip row with auto-update on join/leave
      - COPY, SAVE FILE, CLEAR, PAUSE/RESUME controls
      - Target Input Box (defaults to "Kaihii")
      - Highlights changed values between refreshes (delta markers)
      - pcall sandboxing on every section
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ============================================================
-- UI PARENT RESOLVER
-- ============================================================
local function getGuiParent()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local uiParent = getGuiParent()

-- Destroy previous instance if open
local existingGui = uiParent:FindFirstChild("CharacterMotionMonitorGui")
if existingGui then pcall(function() existingGui:Destroy() end) end

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function safeValStr(v)
    local t = typeof(v)
    if t == "Instance" then
        return string.format("<Instance: %s [%s]>", v:GetFullName(), v.ClassName)
    elseif t == "Vector3" then
        return string.format("(%.3f, %.3f, %.3f)", v.X, v.Y, v.Z)
    elseif t == "CFrame" then
        local p = v.Position
        local rx, ry, rz = v:ToEulerAnglesXYZ()
        return string.format("CF pos=(%.2f,%.2f,%.2f) rot=(%.2f°,%.2f°,%.2f°)",
            p.X, p.Y, p.Z,
            math.deg(rx), math.deg(ry), math.deg(rz))
    elseif t == "Color3" then
        return string.format("Color3(%.2f, %.2f, %.2f)", v.R, v.G, v.B)
    elseif t == "string" then
        return string.format("%q", v)
    else
        return tostring(v)
    end
end

local function fmtVec3(v)
    if typeof(v) ~= "Vector3" then return "nil" end
    return string.format("(%.3f, %.3f, %.3f) |mag=%.3f|", v.X, v.Y, v.Z, v.Magnitude)
end

-- ============================================================
-- TARGET RESOLVER (same robust multi-pass approach)
-- ============================================================
local function resolveTarget(queryName)
    queryName = (queryName or "Kaihii"):gsub("^%s+", ""):gsub("%s+$", "")
    local qLower = queryName:lower()
    local targetPlr, targetChar

    -- 1. Exact Username / DisplayName
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == qLower or p.DisplayName:lower() == qLower then
            targetPlr = p
            targetChar = p.Character
            break
        end
    end

    -- 2. Substring match on Players
    if not targetPlr then
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name:lower():find(qLower, 1, true) or p.DisplayName:lower():find(qLower, 1, true) then
                targetPlr = p
                targetChar = p.Character
                break
            end
        end
    end

    -- 3. Search Workspace for Character Model
    if not targetChar then
        for _, obj in ipairs(Workspace:GetChildren()) do
            if obj:IsA("Model") and (obj:FindFirstChildOfClass("Humanoid") or obj:FindFirstChild("HumanoidRootPart")) then
                if obj.Name:lower() == qLower or obj.Name:lower():find(qLower, 1, true) then
                    targetChar = obj
                    break
                end
            end
        end
    end

    -- 4. Common sub-containers
    if not targetChar then
        local containers = {
            Workspace:FindFirstChild("Characters"),
            Workspace:FindFirstChild("Entities"),
            Workspace:FindFirstChild("Players"),
            Workspace:FindFirstChild("Rigs"),
            Workspace:FindFirstChild("NPCs"),
        }
        for _, c in ipairs(containers) do
            if c then
                for _, obj in ipairs(c:GetChildren()) do
                    if obj:IsA("Model") and (obj.Name:lower() == qLower or obj.Name:lower():find(qLower, 1, true)) then
                        targetChar = obj
                        break
                    end
                end
            end
            if targetChar then break end
        end
    end

    return targetPlr, targetChar
end

-- ============================================================
-- CORE MONITOR SCAN (Motor, Speed, Animations, Char Focus)
-- ============================================================

local prevSnapshot = {}  -- Stores previous values for delta detection

local function buildDelta(key, newVal)
    local prev = prevSnapshot[key]
    prevSnapshot[key] = newVal
    if prev ~= nil and tostring(prev) ~= tostring(newVal) then
        return string.format(" [CHANGED from: %s]", tostring(prev))
    end
    return ""
end

local function runMotionScan(targetQuery)
    local out = {}
    local function log(s) table.insert(out, tostring(s or "")) end

    targetQuery = (targetQuery or "Kaihii"):gsub("^%s+", ""):gsub("%s+$", "")

    local targetPlr, targetChar = resolveTarget(targetQuery)
    local myChar = LocalPlayer.Character
    local myHrp = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar.PrimaryPart)
    local myPos = myHrp and myHrp.Position

    -- ──────────────────────────────────────────────────────
    -- HEADER
    -- ──────────────────────────────────────────────────────
    log("══════════════════════════════════════════════════")
    log("  CHARACTER MOTION MONITOR — " .. os.date("!%H:%M:%S") .. " UTC")
    log("  Target: " .. targetQuery .. " | Runner: " .. LocalPlayer.Name)
    log("══════════════════════════════════════════════════")
    log("")

    -- ──────────────────────────────────────────────────────
    -- 0. RESOLUTION STATUS
    -- ──────────────────────────────────────────────────────
    log("▶ [0] RESOLUTION STATUS")
    if targetPlr then
        log(string.format("  Player   : %s (@%s) UserId=%d", targetPlr.DisplayName, targetPlr.Name, targetPlr.UserId))
    else
        log("  Player   : NOT FOUND in game.Players")
        log("  Online Players:")
        for _, p in ipairs(Players:GetPlayers()) do
            log(string.format("    • %s (@%s) [%d]", p.DisplayName, p.Name, p.UserId))
        end
    end

    if targetChar then
        log("  Character: SPAWNED → " .. targetChar:GetFullName())
        local hrp = targetChar:FindFirstChild("HumanoidRootPart") or targetChar.PrimaryPart
        if hrp and myPos then
            local dist = (hrp.Position - myPos).Magnitude
            log(string.format("  Position : %s  | Dist from you: %.1f studs", fmtVec3(hrp.Position), dist))
        end
    else
        log("  Character: NOT FOUND in Workspace")
    end
    log("")

    if not targetChar then
        log("  [!] No character found — waiting for spawn. Will retry on next tick.")
        log("")
        return table.concat(out, "\n")
    end

    local hum = targetChar:FindFirstChildOfClass("Humanoid")
    local hrp = targetChar:FindFirstChild("HumanoidRootPart") or targetChar.PrimaryPart

    -- ──────────────────────────────────────────────────────
    -- 1. HUMANOID STATE & CORE STATS
    -- ──────────────────────────────────────────────────────
    log("▶ [1] HUMANOID STATE & CORE STATS")
    if hum then
        local health   = hum.Health
        local maxHp    = hum.MaxHealth
        local walkspd  = hum.WalkSpeed
        local jumpPow  = hum.JumpPower
        local jumpH    = hum.JumpHeight
        local hipH     = hum.HipHeight
        local moveDir  = hum.MoveDirection
        local sit      = hum.Sit
        local platStnd = hum.PlatformStand
        local floorMat = hum.FloorMaterial
        local rigType  = hum.RigType

        local stateStr = "Unknown"
        pcall(function() stateStr = tostring(hum:GetState()) end)

        log(string.format("  RigType      : %s", tostring(rigType)))
        log(string.format("  HumanoidState: %s%s", stateStr,                     buildDelta("hum.State", stateStr)))
        log(string.format("  Health       : %.1f / %.1f%s",   health, maxHp,     buildDelta("hum.Health", health)))
        log(string.format("  WalkSpeed    : %.3f%s",           walkspd,           buildDelta("hum.WalkSpeed", walkspd)))
        log(string.format("  JumpPower    : %.3f%s",           jumpPow,           buildDelta("hum.JumpPower", jumpPow)))
        log(string.format("  JumpHeight   : %.3f%s",           jumpH,             buildDelta("hum.JumpHeight", jumpH)))
        log(string.format("  HipHeight    : %.3f%s",           hipH,              buildDelta("hum.HipHeight", hipH)))
        log(string.format("  Sit          : %s%s",             tostring(sit),     buildDelta("hum.Sit", sit)))
        log(string.format("  PlatformStand: %s%s",             tostring(platStnd),buildDelta("hum.PlatformStand", platStnd)))
        log(string.format("  FloorMaterial: %s%s",             tostring(floorMat),buildDelta("hum.FloorMat", tostring(floorMat))))
        log(string.format("  MoveDirection: %s%s",             fmtVec3(moveDir),  buildDelta("hum.MoveDir", tostring(moveDir))))

        -- Humanoid attributes
        local hAttrs = hum:GetAttributes()
        local hAttrKeys = {}
        for k in pairs(hAttrs) do table.insert(hAttrKeys, k) end
        table.sort(hAttrKeys)
        if #hAttrKeys > 0 then
            log("  Humanoid Attributes:")
            for _, k in ipairs(hAttrKeys) do
                local v = hAttrs[k]
                log(string.format("    %s = %s [%s]%s", k, safeValStr(v), typeof(v), buildDelta("hAttr."..k, v)))
            end
        end
    else
        log("  [!] No Humanoid found in character.")
    end
    log("")

    -- ──────────────────────────────────────────────────────
    -- 2. SPEED & PHYSICS — HRP Velocity Breakdown
    -- ──────────────────────────────────────────────────────
    log("▶ [2] SPEED & PHYSICS (HumanoidRootPart)")
    if hrp then
        -- AssemblyLinearVelocity (R15/R6 both support this)
        local linVel   = hrp.AssemblyLinearVelocity
        local angVel   = hrp.AssemblyAngularVelocity
        local hSpeed   = Vector3.new(linVel.X, 0, linVel.Z).Magnitude   -- horizontal speed
        local vSpeed   = linVel.Y                                         -- vertical speed

        log(string.format("  AssemblyLinearVelocity  : %s%s", fmtVec3(linVel),  buildDelta("hrp.LinVel", tostring(linVel))))
        log(string.format("  AssemblyAngularVelocity : %s%s", fmtVec3(angVel),  buildDelta("hrp.AngVel", tostring(angVel))))
        log(string.format("  Horizontal Speed (XZ)   : %.3f studs/s%s",  hSpeed, buildDelta("hrp.HSpeed", hSpeed)))
        log(string.format("  Vertical Speed  (Y)     : %.3f studs/s%s",  vSpeed, buildDelta("hrp.VSpeed", vSpeed)))
        log(string.format("  CFrame Position         : %s", safeValStr(hrp.CFrame)))
        log(string.format("  NetworkOwner            : %s", (function()
            local ok, owner = pcall(function() return hrp:GetNetworkOwner() end)
            if ok then
                return owner and string.format("%s [%d]", owner.Name, owner.UserId) or "Server"
            else
                return "pcall blocked"
            end
        end)()))

        -- Legacy Velocity property fallback
        pcall(function()
            local legVel = hrp.Velocity
            log(string.format("  Velocity (legacy prop)  : %s", fmtVec3(legVel)))
        end)

        -- LinearVelocity constraint if present
        local lvc = hrp:FindFirstChildOfClass("LinearVelocity")
        if lvc then
            log(string.format("  LinearVelocity constraint: VectorVelocity=%s", safeValStr(lvc.VectorVelocity)))
        end
    else
        log("  [!] HumanoidRootPart not found.")
    end
    log("")

    -- ──────────────────────────────────────────────────────
    -- 3. ACTIVE ANIMATIONS (Animator tracks)
    -- ──────────────────────────────────────────────────────
    log("▶ [3] ACTIVE ANIMATION TRACKS")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if animator then
        local tracks = {}
        pcall(function() tracks = animator:GetPlayingAnimationTracks() end)
        log(string.format("  Playing Tracks: %d", #tracks))
        if #tracks == 0 then
            log("    (none playing)")
        else
            for i, trk in ipairs(tracks) do
                local animId = (trk.Animation and trk.Animation.AnimationId) or "unknown"
                local speed   = trk.Speed
                local weight  = trk.WeightCurrent
                local timPos  = trk.TimePosition
                local looped  = trk.Looped
                local length  = trk.Length
                local priority = tostring(trk.Priority)

                log(string.format("  [%d] %-30s Priority: %-10s Looped: %s",
                    i, trk.Name, priority, tostring(looped)))
                log(string.format("       AnimId   : %s%s",       animId, buildDelta("anim."..i..".id", animId)))
                log(string.format("       Speed    : %.4f%s",      speed,  buildDelta("anim."..i..".speed", speed)))
                log(string.format("       Weight   : %.4f%s",      weight, buildDelta("anim."..i..".weight", weight)))
                log(string.format("       TimePos  : %.4f / %.4f", timPos, length))
            end
        end

        -- All loaded (but possibly paused) tracks
        local allTracks = {}
        pcall(function() allTracks = animator:GetAnimationTracks() end)
        local pausedCount = 0
        for _, trk in ipairs(allTracks) do
            if not trk.IsPlaying then pausedCount = pausedCount + 1 end
        end
        if pausedCount > 0 then
            log(string.format("  Paused/Stopped Tracks: %d (loaded but not playing)", pausedCount))
        end
    else
        log("  [!] No Animator found under Humanoid.")
    end
    log("")

    -- ──────────────────────────────────────────────────────
    -- 4. MOTOR6D JOINTS — Full rotation & angle data
    -- ──────────────────────────────────────────────────────
    log("▶ [4] MOTOR6D JOINTS")
    local motors = {}
    for _, d in ipairs(targetChar:GetDescendants()) do
        if d:IsA("Motor6D") then table.insert(motors, d) end
    end
    log(string.format("  Motor6D Count: %d", #motors))
    if #motors == 0 then
        log("  [!] No Motor6D joints found (might be a non-standard rig).")
    else
        for _, m in ipairs(motors) do
            local p0 = m.Part0 and m.Part0.Name or "nil"
            local p1 = m.Part1 and m.Part1.Name or "nil"
            local curAngle   = m.CurrentAngle
            local maxVel     = m.MaxVelocity
            local desiredAngle = m.DesiredAngle

            local c0pos = m.C0.Position
            local c1pos = m.C1.Position
            local c0rx, c0ry, c0rz = m.C0:ToEulerAnglesXYZ()
            local c1rx, c1ry, c1rz = m.C1:ToEulerAnglesXYZ()

            log(string.format("  [Motor6D] %-20s  %s → %s", m.Name, p0, p1))
            log(string.format("    CurrentAngle  : %.4f°%s",  math.deg(curAngle),    buildDelta("m6d."..m.Name..".curAngle", curAngle)))
            log(string.format("    DesiredAngle  : %.4f°%s",  math.deg(desiredAngle),buildDelta("m6d."..m.Name..".desAngle", desiredAngle)))
            log(string.format("    MaxVelocity   : %.4f",     maxVel))
            log(string.format("    C0 offset     : pos=(%.3f,%.3f,%.3f) rot=(%.2f°,%.2f°,%.2f°)",
                c0pos.X, c0pos.Y, c0pos.Z, math.deg(c0rx), math.deg(c0ry), math.deg(c0rz)))
            log(string.format("    C1 offset     : pos=(%.3f,%.3f,%.3f) rot=(%.2f°,%.2f°,%.2f°)",
                c1pos.X, c1pos.Y, c1pos.Z, math.deg(c1rx), math.deg(c1ry), math.deg(c1rz)))
        end
    end
    log("")

    -- ──────────────────────────────────────────────────────
    -- 5. CONSTRAINTS & FORCE OBJECTS
    -- ──────────────────────────────────────────────────────
    log("▶ [5] CONSTRAINTS & FORCE OBJECTS")
    local constraintTypes = {
        "AlignPosition", "AlignOrientation", "LinearVelocity",
        "AngularVelocity", "VectorForce", "BodyVelocity",
        "BodyGyro", "BodyPosition", "BodyForce", "RigidConstraint",
        "BallSocketConstraint", "HingeConstraint", "SliderConstraint",
    }
    local foundConstraints = {}
    for _, d in ipairs(targetChar:GetDescendants()) do
        for _, ct in ipairs(constraintTypes) do
            if d:IsA(ct) then
                table.insert(foundConstraints, { obj = d, ctype = ct })
                break
            end
        end
    end

    log(string.format("  Found: %d constraint/force objects", #foundConstraints))
    if #foundConstraints == 0 then
        log("  (none)")
    else
        for _, entry in ipairs(foundConstraints) do
            local d = entry.obj
            log(string.format("  [%s] %s (in %s)", entry.ctype, d.Name, d.Parent and d.Parent.Name or "?"))

            -- Dump relevant properties per constraint type
            pcall(function()
                if d:IsA("AlignPosition") then
                    log(string.format("    RigidityEnabled: %s  Responsiveness: %.2f  MaxForce: %.2f",
                        tostring(d.RigidityEnabled), d.Responsiveness, d.MaxForce))
                elseif d:IsA("AlignOrientation") then
                    log(string.format("    RigidityEnabled: %s  Responsiveness: %.2f  MaxTorque: %.2f",
                        tostring(d.RigidityEnabled), d.Responsiveness, d.MaxTorque))
                elseif d:IsA("LinearVelocity") then
                    log(string.format("    VectorVelocity: %s  MaxForce: %.2f",
                        fmtVec3(d.VectorVelocity), d.MaxForce))
                elseif d:IsA("AngularVelocity") then
                    log(string.format("    AngularVelocity: %s  MaxTorque: %.2f",
                        fmtVec3(d.AngularVelocity), d.MaxTorque))
                elseif d:IsA("BodyVelocity") then
                    log(string.format("    Velocity: %s  MaxForce: %s",
                        fmtVec3(d.Velocity), fmtVec3(d.MaxForce)))
                elseif d:IsA("BodyGyro") then
                    log(string.format("    MaxTorque: %s  D: %.2f  P: %.2f",
                        fmtVec3(d.MaxTorque), d.D, d.P))
                elseif d:IsA("BodyPosition") then
                    log(string.format("    Position: %s  MaxForce: %s",
                        fmtVec3(d.Position), fmtVec3(d.MaxForce)))
                end
            end)
        end
    end
    log("")

    -- ──────────────────────────────────────────────────────
    -- 6. CHARACTER ATTRIBUTES & COLLECTION TAGS
    -- ──────────────────────────────────────────────────────
    log("▶ [6] CHARACTER MODEL ATTRIBUTES & TAGS")
    local cAttrs = targetChar:GetAttributes()
    local cAttrKeys = {}
    for k in pairs(cAttrs) do table.insert(cAttrKeys, k) end
    table.sort(cAttrKeys)
    if #cAttrKeys == 0 then
        log("  Character Attributes: (none)")
    else
        for _, k in ipairs(cAttrKeys) do
            local v = cAttrs[k]
            log(string.format("  %s = %s [%s]%s", k, safeValStr(v), typeof(v), buildDelta("cAttr."..k, v)))
        end
    end

    local cTags = CollectionService:GetTags(targetChar)
    if #cTags > 0 then
        log("  CollectionService Tags: " .. table.concat(cTags, ", "))
    else
        log("  CollectionService Tags: (none)")
    end
    log("")

    -- ──────────────────────────────────────────────────────
    -- 7. ALL CHARACTER PARTS — Physics Snapshot
    -- ──────────────────────────────────────────────────────
    log("▶ [7] ALL BASEPARTS — PHYSICS SNAPSHOT")
    local parts = {}
    for _, p in ipairs(targetChar:GetDescendants()) do
        if p:IsA("BasePart") then table.insert(parts, p) end
    end
    log(string.format("  Total BaseParts: %d", #parts))
    for _, p in ipairs(parts) do
        local pLin = p.AssemblyLinearVelocity
        local pAng = p.AssemblyAngularVelocity
        local pSpd = Vector3.new(pLin.X, 0, pLin.Z).Magnitude
        -- Only log parts that are actually moving (optimization)
        if pSpd > 0.05 or pLin.Y > 0.05 or pAng.Magnitude > 0.05 then
            log(string.format("  [%s] %-22s LinVel=%s AngVel=%s",
                p.ClassName, p.Name, fmtVec3(pLin), fmtVec3(pAng)))
        end
    end
    -- If all parts are still, note it
    local movingCount = 0
    for _, p in ipairs(parts) do
        local pLin = p.AssemblyLinearVelocity
        local pAng = p.AssemblyAngularVelocity
        if Vector3.new(pLin.X,0,pLin.Z).Magnitude > 0.05 or pLin.Y > 0.05 or pAng.Magnitude > 0.05 then
            movingCount = movingCount + 1
        end
    end
    if movingCount == 0 then
        log("  (All parts stationary — no significant velocity detected)")
    end
    log("")

    -- ──────────────────────────────────────────────────────
    -- 8. PLAYER-LEVEL QUICK STATS (if player exists)
    -- ──────────────────────────────────────────────────────
    if targetPlr then
        log("▶ [8] PLAYER QUICK STATS")
        log(string.format("  AccountAge   : %d days", targetPlr.AccountAge))
        log(string.format("  Membership   : %s", tostring(targetPlr.MembershipType)))
        log(string.format("  Ping         : %s ms", (function()
            local ok, v = pcall(function()
                return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
            end)
            return ok and string.format("%.0f", v) or "unavailable"
        end)()))

        local leaderstats = targetPlr:FindFirstChild("leaderstats")
        if leaderstats then
            log("  Leaderstats:")
            for _, s in ipairs(leaderstats:GetChildren()) do
                if s:IsA("ValueBase") then
                    log(string.format("    %s = %s%s", s.Name, tostring(s.Value), buildDelta("ls."..s.Name, s.Value)))
                end
            end
        end

        local pAttrs = targetPlr:GetAttributes()
        local pAttrKeys = {}
        for k in pairs(pAttrs) do table.insert(pAttrKeys, k) end
        table.sort(pAttrKeys)
        if #pAttrKeys > 0 then
            log("  Player Attributes:")
            for _, k in ipairs(pAttrKeys) do
                local v = pAttrs[k]
                log(string.format("    %s = %s [%s]%s", k, safeValStr(v), typeof(v), buildDelta("pAttr."..k, v)))
            end
        end
        log("")
    end

    -- ──────────────────────────────────────────────────────
    -- FOOTER
    -- ──────────────────────────────────────────────────────
    log("══════════════════════════════════════════════════")
    log("  END OF SCAN — " .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
    log("══════════════════════════════════════════════════")

    return table.concat(out, "\n")
end

-- ============================================================
-- UI BUILDER
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CharacterMotionMonitorGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = uiParent

local W, H = 620, 600
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(13, 17, 25)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(80, 160, 255)
mainStroke.Thickness = 1.5

-- ── TOP BAR ──
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 38)
topBar.BackgroundColor3 = Color3.fromRGB(18, 24, 38)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "⚡ CHARACTER MOTION MONITOR"
titleLbl.TextColor3 = Color3.fromRGB(120, 200, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 13
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -34, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function() screenGui:Destroy() end)

-- ── DRAGGABLE ──
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

-- ── ROW 1: Target Input ──
local ROW1_Y = 44
local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(0, 54, 0, 28)
targetLabel.Position = UDim2.new(0, 12, 0, ROW1_Y)
targetLabel.BackgroundTransparency = 1
targetLabel.Text = "Target:"
targetLabel.TextColor3 = Color3.fromRGB(160, 200, 255)
targetLabel.Font = Enum.Font.GothamBold
targetLabel.TextSize = 12
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Parent = main

local targetInput = Instance.new("TextBox")
targetInput.Size = UDim2.new(0, 210, 0, 28)
targetInput.Position = UDim2.new(0, 68, 0, ROW1_Y)
targetInput.BackgroundColor3 = Color3.fromRGB(20, 25, 38)
targetInput.Text = "Kaihii"
targetInput.PlaceholderText = "Player or character name..."
targetInput.TextColor3 = Color3.fromRGB(255, 230, 80)
targetInput.Font = Enum.Font.GothamBold
targetInput.TextSize = 12
targetInput.ClearTextOnFocus = false
targetInput.Parent = main
Instance.new("UICorner", targetInput).CornerRadius = UDim.new(0, 6)
local tiStroke = Instance.new("UIStroke", targetInput)
tiStroke.Color = Color3.fromRGB(55, 90, 150)
tiStroke.Thickness = 1

-- Interval selector
local intervalLabel = Instance.new("TextLabel")
intervalLabel.Size = UDim2.new(0, 62, 0, 28)
intervalLabel.Position = UDim2.new(0, 284, 0, ROW1_Y)
intervalLabel.BackgroundTransparency = 1
intervalLabel.Text = "Interval:"
intervalLabel.TextColor3 = Color3.fromRGB(160, 200, 255)
intervalLabel.Font = Enum.Font.Gotham
intervalLabel.TextSize = 11
intervalLabel.TextXAlignment = Enum.TextXAlignment.Left
intervalLabel.Parent = main

local intervalInput = Instance.new("TextBox")
intervalInput.Size = UDim2.new(0, 52, 0, 28)
intervalInput.Position = UDim2.new(0, 350, 0, ROW1_Y)
intervalInput.BackgroundColor3 = Color3.fromRGB(20, 25, 38)
intervalInput.Text = "1.5"
intervalInput.TextColor3 = Color3.fromRGB(180, 240, 200)
intervalInput.Font = Enum.Font.Code
intervalInput.TextSize = 12
intervalInput.ClearTextOnFocus = false
intervalInput.Parent = main
Instance.new("UICorner", intervalInput).CornerRadius = UDim.new(0, 6)
local iStroke = Instance.new("UIStroke", intervalInput)
iStroke.Color = Color3.fromRGB(55, 90, 150)
iStroke.Thickness = 1

local sLabel = Instance.new("TextLabel")
sLabel.Size = UDim2.new(0, 12, 0, 28)
sLabel.Position = UDim2.new(0, 406, 0, ROW1_Y)
sLabel.BackgroundTransparency = 1
sLabel.Text = "s"
sLabel.TextColor3 = Color3.fromRGB(130, 160, 200)
sLabel.Font = Enum.Font.Gotham
sLabel.TextSize = 11
sLabel.Parent = main

-- Self chip
local selfBtn = Instance.new("TextButton")
selfBtn.Size = UDim2.new(0, 110, 0, 28)
selfBtn.Position = UDim2.new(0, 423, 0, ROW1_Y)
selfBtn.BackgroundColor3 = Color3.fromRGB(38, 46, 62)
selfBtn.Text = "Me (" .. LocalPlayer.Name:sub(1, 8) .. ")"
selfBtn.TextColor3 = Color3.fromRGB(170, 205, 240)
selfBtn.Font = Enum.Font.Gotham
selfBtn.TextSize = 11
selfBtn.Parent = main
Instance.new("UICorner", selfBtn).CornerRadius = UDim.new(0, 6)
selfBtn.MouseButton1Click:Connect(function() targetInput.Text = LocalPlayer.Name end)

-- ── ROW 2: Player Chips ──
local ROW2_Y = 78
local chipsScroll = Instance.new("ScrollingFrame")
chipsScroll.Size = UDim2.new(1, -24, 0, 26)
chipsScroll.Position = UDim2.new(0, 12, 0, ROW2_Y)
chipsScroll.BackgroundTransparency = 1
chipsScroll.BorderSizePixel = 0
chipsScroll.ScrollBarThickness = 2
chipsScroll.ScrollBarImageColor3 = Color3.fromRGB(70, 120, 190)
chipsScroll.ScrollingDirection = Enum.ScrollingDirection.X
chipsScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
chipsScroll.Parent = main

local chipsLayout = Instance.new("UIListLayout")
chipsLayout.FillDirection = Enum.FillDirection.Horizontal
chipsLayout.Padding = UDim.new(0, 6)
chipsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
chipsLayout.Parent = chipsScroll

local function populatePlayerChips()
    for _, ch in ipairs(chipsScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end
    for _, p in ipairs(Players:GetPlayers()) do
        local chip = Instance.new("TextButton")
        chip.Size = UDim2.new(0, 0, 0, 22)
        chip.AutomaticSize = Enum.AutomaticSize.X
        chip.BackgroundColor3 = Color3.fromRGB(28, 35, 52)
        chip.Text = string.format(" %s (@%s) ", p.DisplayName, p.Name)
        chip.TextColor3 = Color3.fromRGB(175, 210, 240)
        chip.Font = Enum.Font.Gotham
        chip.TextSize = 10
        chip.Parent = chipsScroll
        Instance.new("UICorner", chip).CornerRadius = UDim.new(0, 5)
        local cpS = Instance.new("UIStroke", chip)
        cpS.Color = Color3.fromRGB(50, 70, 100)
        cpS.Thickness = 1
        chip.MouseButton1Click:Connect(function() targetInput.Text = p.Name end)
    end
end
pcall(populatePlayerChips)

-- ── ROW 3: Action Buttons ──
local ROW3_Y = 110
local BTN_H, BTN_W, GAP = 26, 110, 8

local function mkBtn(label, color, xOff)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, BTN_W, 0, BTN_H)
    b.Position = UDim2.new(0, xOff, 0, ROW3_Y)
    b.BackgroundColor3 = color
    b.Text = label
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 11
    b.Parent = main
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local pauseBtn = mkBtn("⏸ PAUSE",    Color3.fromRGB(160, 100, 20),  12)
local copyBtn  = mkBtn("📋 COPY",    Color3.fromRGB(40,  90,  160), 12 + (BTN_W + GAP))
local saveBtn  = mkBtn("💾 SAVE",    Color3.fromRGB(80,  55,  135), 12 + (BTN_W + GAP)*2)
local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 70, 0, BTN_H)
clearBtn.Position = UDim2.new(0, 12 + (BTN_W + GAP)*3, 0, ROW3_Y)
clearBtn.BackgroundColor3 = Color3.fromRGB(46, 52, 68)
clearBtn.Text = "CLEAR"
clearBtn.TextColor3 = Color3.fromRGB(195, 210, 230)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 11
clearBtn.Parent = main
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

-- Status label
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 0, 18)
statusLabel.Position = UDim2.new(0, 12, 0, ROW3_Y + BTN_H + 6)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Status: Starting live monitor..."
statusLabel.TextColor3 = Color3.fromRGB(140, 185, 235)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = main

-- ── SCROLLABLE OUTPUT ──
local BOX_Y = ROW3_Y + BTN_H + 28
local BOX_H = H - BOX_Y - 12

local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Size = UDim2.new(1, -24, 0, BOX_H)
scrollFrame.Position = UDim2.new(0, 12, 0, BOX_Y)
scrollFrame.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 6
scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(60, 120, 200)
scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
scrollFrame.Parent = main
Instance.new("UICorner", scrollFrame).CornerRadius = UDim.new(0, 8)
local boxStroke = Instance.new("UIStroke", scrollFrame)
boxStroke.Color = Color3.fromRGB(32, 44, 66)
boxStroke.Thickness = 1

local textBox = Instance.new("TextBox")
textBox.Size = UDim2.new(1, -16, 0, 0)
textBox.Position = UDim2.new(0, 8, 0, 8)
textBox.AutomaticSize = Enum.AutomaticSize.Y
textBox.BackgroundTransparency = 1
textBox.MultiLine = true
textBox.ClearTextOnFocus = false
textBox.TextEditable = false
textBox.TextXAlignment = Enum.TextXAlignment.Left
textBox.TextYAlignment = Enum.TextYAlignment.Top
textBox.Font = Enum.Font.Code
textBox.TextSize = 10
textBox.TextColor3 = Color3.fromRGB(170, 230, 200)
textBox.Text = "-- Character Motion Monitor Ready --\n-- Set target and wait for live refresh."
textBox.Parent = scrollFrame

-- ============================================================
-- LIVE POLLING LOOP
-- ============================================================

local cachedOutput = ""
local isPaused = false
local refreshCount = 0

local function doRefresh()
    if isPaused then return end
    local targetName = targetInput.Text
    if targetName == "" then targetName = "Kaihii" end

    local interval = tonumber(intervalInput.Text) or 1.5
    interval = math.clamp(interval, 0.25, 60)

    local ok, result = pcall(function()
        return runMotionScan(targetName)
    end)

    refreshCount = refreshCount + 1

    if ok and result then
        cachedOutput = result
        textBox.Text = result
        statusLabel.Text = string.format(
            "Status: LIVE [#%d] target='%s' | interval=%.1fs | %s UTC",
            refreshCount, targetName, interval, os.date("!%H:%M:%S")
        )
        statusLabel.TextColor3 = Color3.fromRGB(100, 230, 140)
    else
        statusLabel.Text = "Status: Scan error — " .. tostring(result)
        statusLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
        warn("[CharacterMotionMonitor] Error:", tostring(result))
    end
end

-- Auto-scroll to top on each refresh (keeps latest reading visible)
local function startLiveLoop()
    while screenGui and screenGui.Parent do
        local interval = tonumber(intervalInput.Text) or 1.5
        interval = math.clamp(interval, 0.25, 60)
        doRefresh()
        task.wait(interval)
    end
end

-- ── PAUSE / RESUME ──
pauseBtn.MouseButton1Click:Connect(function()
    isPaused = not isPaused
    if isPaused then
        pauseBtn.Text = "▶ RESUME"
        pauseBtn.BackgroundColor3 = Color3.fromRGB(30, 130, 60)
        statusLabel.Text = "Status: PAUSED — click RESUME to continue."
        statusLabel.TextColor3 = Color3.fromRGB(255, 180, 60)
    else
        pauseBtn.Text = "⏸ PAUSE"
        pauseBtn.BackgroundColor3 = Color3.fromRGB(160, 100, 20)
        statusLabel.Text = "Status: Resuming live monitor..."
        statusLabel.TextColor3 = Color3.fromRGB(140, 185, 235)
    end
end)

-- ── COPY ──
copyBtn.MouseButton1Click:Connect(function()
    if cachedOutput == "" then
        statusLabel.Text = "Status: No output yet. Wait for first scan."
        statusLabel.TextColor3 = Color3.fromRGB(255, 160, 80)
        return
    end
    if typeof(setclipboard) == "function" then
        local ok = pcall(setclipboard, cachedOutput)
        statusLabel.Text = ok
            and ("Status: Copied " .. tostring(#cachedOutput) .. " chars!")
            or  "Status: setclipboard failed."
        statusLabel.TextColor3 = ok and Color3.fromRGB(100, 230, 140) or Color3.fromRGB(255, 100, 100)
    else
        textBox.TextEditable = true
        textBox:CaptureFocus()
        statusLabel.Text = "Status: setclipboard unavailable — text focused for Ctrl+C."
        statusLabel.TextColor3 = Color3.fromRGB(255, 210, 80)
    end
end)

-- ── SAVE (append, never overwrite) ──
saveBtn.MouseButton1Click:Connect(function()
    if cachedOutput == "" then
        statusLabel.Text = "Status: No output to save yet."
        statusLabel.TextColor3 = Color3.fromRGB(255, 160, 80)
        return
    end

    local cleanName = targetInput.Text:gsub("%W+", "_"):lower()
    if cleanName == "" then cleanName = "target" end
    local fileName = string.format("motion-monitor-%s.log", cleanName)

    -- Add a clear separator + timestamp so each save is easy to find
    local separator = string.format(
        "\n\n========== SAVED %s UTC ==========\n\n",
        os.date("!%Y-%m-%d %H:%M:%S")
    )
    local contentToWrite = separator .. cachedOutput

    local ok, err

    if typeof(appendfile) == "function" then
        -- Preferred: pure append (never overwrites)
        ok, err = pcall(appendfile, fileName, contentToWrite)
    elseif typeof(writefile) == "function" then
        -- Fallback: read existing file + append + write
        local existing = ""
        if typeof(isfile) == "function" and typeof(readfile) == "function" then
            if isfile(fileName) then
                local readOk, data = pcall(readfile, fileName)
                if readOk and type(data) == "string" then
                    existing = data
                end
            end
        end
        ok, err = pcall(writefile, fileName, existing .. contentToWrite)
    else
        statusLabel.Text = "Status: writefile/appendfile not available in this executor."
        statusLabel.TextColor3 = Color3.fromRGB(255, 175, 80)
        return
    end

    if ok then
        statusLabel.Text = "Status: Appended → " .. fileName
        statusLabel.TextColor3 = Color3.fromRGB(100, 230, 140)
    else
        statusLabel.Text = "Status: Save error — " .. tostring(err)
        statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
    end
end)
-- ── CLEAR ──
clearBtn.MouseButton1Click:Connect(function()
    cachedOutput = ""
    prevSnapshot = {}  -- Reset delta tracking
    refreshCount = 0
    textBox.Text = "-- Cleared & delta reset --"
    statusLabel.Text = "Status: Cleared."
    statusLabel.TextColor3 = Color3.fromRGB(170, 185, 215)
end)

-- ── PLAYER CHIPS AUTO-UPDATE ──
pcall(function()
    Players.PlayerAdded:Connect(function() pcall(populatePlayerChips) end)
    Players.PlayerRemoving:Connect(function() pcall(populatePlayerChips) end)
end)

-- ── LAUNCH LOOP ──
task.spawn(startLiveLoop)

print("[CharacterMotionMonitor] Initialized. Actively monitoring target: Kaihii")
