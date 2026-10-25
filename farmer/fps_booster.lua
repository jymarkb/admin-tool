-- ============================================================================
-- FPS BOOSTER & OPTIMIZATION UTILITY
-- Standalone Client Performance Optimizer for Extended Overnight Farming
-- Features:
--   1. SFX Mute & Auto-Interception (mutes all existing & newly spawned sounds)
--   2. VFX / Particle Disabler (ParticleEmitter, Trail, Beam, Smoke, Fire, Sparkles)
--   3. Lighting & Shadows Optimizer (GlobalShadows, PostProcess, Fog, Atmosphere)
--   4. Smooth Plastic & Texture Stripping (Sliced non-blocking material swap)
--   5. 3D Rendering Toggle (RunService:Set3dRenderingEnabled for AFK 0% GPU draw)
--   6. FPS Cap Selector (30 FPS, 60 FPS, Uncapped)
-- ============================================================================

-- Clean up any prior running instance cleanly
if typeof(_G.FPSBooster_Cleanup) == "function" then
    pcall(_G.FPSBooster_Cleanup)
end

-- ============================================================================
-- SERVICES & LOCALS
-- ============================================================================
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local connections = {}

local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

-- ============================================================================
-- STATE & RESTORATION LEDGERS (Weak tables to prevent memory leaks)
-- ============================================================================
local State = {
    MuteSFX           = true,
    DisableVFX        = true,
    DisableLighting   = true,
    SmoothPlastic     = false,
    No3DRendering     = false,
    TargetFps         = 60,
    Active            = true,
}

local originalSoundVolumes = setmetatable({}, { __mode = "k" })
local originalVfxStates    = setmetatable({}, { __mode = "k" })
local originalPartProps    = setmetatable({}, { __mode = "k" })
local originalLighting     = {}

-- Backup initial lighting properties once
pcall(function()
    originalLighting.GlobalShadows = Lighting.GlobalShadows
    originalLighting.FogEnd        = Lighting.FogEnd
    originalLighting.Brightness    = Lighting.Brightness
    originalLighting.Technology    = Lighting.Technology
end)

-- VFX class lookup
local VFX_CLASSES = {
    ["ParticleEmitter"] = true,
    ["Trail"]           = true,
    ["Beam"]            = true,
    ["Smoke"]           = true,
    ["Fire"]            = true,
    ["Sparkles"]        = true,
}

local POST_PROCESS_CLASSES = {
    ["BloomEffect"]            = true,
    ["BlurEffect"]             = true,
    ["ColorCorrectionEffect"]  = true,
    ["SunRaysEffect"]          = true,
    ["DepthOfFieldEffect"]     = true,
    ["Atmosphere"]             = true,
}

-- ============================================================================
-- 1. SFX MUTE & INTERCEPTION ENGINE
-- ============================================================================
local function muteSound(sound)
    if not (sound and sound:IsA("Sound")) then return end
    pcall(function()
        if originalSoundVolumes[sound] == nil then
            originalSoundVolumes[sound] = sound.Volume
        end
        sound.Volume = 0
    end)
end

local function restoreSound(sound)
    if not (sound and sound:IsA("Sound")) then return end
    pcall(function()
        local orig = originalSoundVolumes[sound]
        if orig ~= nil then
            sound.Volume = orig
            originalSoundVolumes[sound] = nil
        end
    end)
end

local function applySfxOptimization(enable)
    if enable then
        -- Mute SoundService descendants
        for _, desc in ipairs(SoundService:GetDescendants()) do
            if desc:IsA("Sound") then muteSound(desc) end
        end
        -- Mute Workspace sounds
        for _, desc in ipairs(Workspace:GetDescendants()) do
            if desc:IsA("Sound") then muteSound(desc) end
        end
    else
        for sound in pairs(originalSoundVolumes) do
            restoreSound(sound)
        end
    end
end

-- ============================================================================
-- 2. VFX & PARTICLE ENGINE
-- ============================================================================
local function disableVfxInst(inst)
    local cls = inst and inst.ClassName
    if not (cls and VFX_CLASSES[cls]) then return end
    pcall(function()
        if originalVfxStates[inst] == nil then
            originalVfxStates[inst] = inst.Enabled
        end
        inst.Enabled = false
    end)
end

local function restoreVfxInst(inst)
    if not inst then return end
    pcall(function()
        local orig = originalVfxStates[inst]
        if orig ~= nil then
            inst.Enabled = orig
            originalVfxStates[inst] = nil
        end
    end)
end

local function applyVfxOptimization(enable)
    if enable then
        for _, desc in ipairs(Workspace:GetDescendants()) do
            local cls = desc.ClassName
            if VFX_CLASSES[cls] then
                disableVfxInst(desc)
            end
        end
    else
        for inst in pairs(originalVfxStates) do
            restoreVfxInst(inst)
        end
    end
end

-- ============================================================================
-- 3. LIGHTING & SHADOWS OPTIMIZER
-- ============================================================================
local function applyLightingOptimization(enable)
    pcall(function()
        if enable then
            Lighting.GlobalShadows = false
            Lighting.FogEnd = 9e9
            for _, child in ipairs(Lighting:GetChildren()) do
                if POST_PROCESS_CLASSES[child.ClassName] then
                    if originalLighting[child] == nil then
                        originalLighting[child] = child.Enabled
                    end
                    child.Enabled = false
                end
            end
            pcall(function() Workspace.Terrain.Decoration = false end)
        else
            if originalLighting.GlobalShadows ~= nil then
                Lighting.GlobalShadows = originalLighting.GlobalShadows
            end
            if originalLighting.FogEnd ~= nil then
                Lighting.FogEnd = originalLighting.FogEnd
            end
            for child, origEnabled in pairs(originalLighting) do
                if typeof(child) == "Instance" and child.Parent then
                    pcall(function() child.Enabled = origEnabled end)
                end
            end
        end
    end)
end

-- ============================================================================
-- 4. SMOOTH PLASTIC & TEXTURE STRIPPING (Sliced, Non-Blocking)
-- ============================================================================
local isPlasticWorking = false

local function applySmoothPlastic(enable)
    if isPlasticWorking then return end
    isPlasticWorking = true

    task.spawn(function()
        local descendants = Workspace:GetDescendants()
        local count = 0
        local BATCH = 150

        if enable then
            for i = 1, #descendants do
                local desc = descendants[i]
                if desc and desc:IsA("BasePart") then
                    pcall(function()
                        if originalPartProps[desc] == nil then
                            originalPartProps[desc] = {
                                Material   = desc.Material,
                                CastShadow = desc.CastShadow,
                            }
                        end
                        desc.Material = Enum.Material.SmoothPlastic
                        desc.CastShadow = false
                    end)
                elseif desc and (desc:IsA("Decal") or desc:IsA("Texture")) then
                    pcall(function()
                        if originalPartProps[desc] == nil then
                            originalPartProps[desc] = { Transparency = desc.Transparency }
                        end
                        desc.Transparency = 1
                    end)
                end

                count = count + 1
                if count >= BATCH then
                    count = 0
                    task.wait()
                    if not State.Active or not State.SmoothPlastic then break end
                end
            end
        else
            for desc, orig in pairs(originalPartProps) do
                if desc and desc.Parent then
                    pcall(function()
                        if orig.Material ~= nil then desc.Material = orig.Material end
                        if orig.CastShadow ~= nil then desc.CastShadow = orig.CastShadow end
                        if orig.Transparency ~= nil then desc.Transparency = orig.Transparency end
                    end)
                end
                originalPartProps[desc] = nil
                count = count + 1
                if count >= BATCH then
                    count = 0
                    task.wait()
                    if not State.Active then break end
                end
            end
        end

        isPlasticWorking = false
    end)
end

-- ============================================================================
-- 5. 3D RENDERING TOGGLE (AFK Mode: 0% GPU draw, full background Lua execution)
-- ============================================================================
local afkOverlay = nil

local function set3dRenderingDisabled(disabled)
    State.No3DRendering = disabled
    pcall(function()
        RunService:Set3dRenderingEnabled(not disabled)
    end)

    if afkOverlay and afkOverlay.Parent then
        afkOverlay.Visible = disabled
    end
end

-- ============================================================================
-- 6. FPS CAP
-- ============================================================================
local function applyFpsCap(fps)
    State.TargetFps = fps
    pcall(function()
        if typeof(setfpscap) == "function" then
            setfpscap(fps)
        end
    end)
end

-- ============================================================================
-- DYNAMIC DESCENDANT INTERCEPTION
-- ============================================================================
local function hookNewDescendant(desc)
    if not (desc and desc.Parent) then return end
    local cls = desc.ClassName

    if State.MuteSFX and cls == "Sound" then
        muteSound(desc)
    end

    if State.DisableVFX and VFX_CLASSES[cls] then
        disableVfxInst(desc)
    end

    if State.SmoothPlastic then
        if desc:IsA("BasePart") then
            pcall(function()
                if originalPartProps[desc] == nil then
                    originalPartProps[desc] = {
                        Material   = desc.Material,
                        CastShadow = desc.CastShadow,
                    }
                end
                desc.Material = Enum.Material.SmoothPlastic
                desc.CastShadow = false
            end)
        elseif cls == "Decal" or cls == "Texture" then
            pcall(function()
                if originalPartProps[desc] == nil then
                    originalPartProps[desc] = { Transparency = desc.Transparency }
                end
                desc.Transparency = 1
            end)
        end
    end
end

addConnection(Workspace.DescendantAdded:Connect(hookNewDescendant))
addConnection(SoundService.DescendantAdded:Connect(function(desc)
    if State.MuteSFX and desc:IsA("Sound") then
        muteSound(desc)
    end
end))

-- ============================================================================
-- USER INTERFACE (Modern Dark Floating HUD)
-- ============================================================================
local guiParent = nil
pcall(function()
    if typeof(gethui) == "function" then
        guiParent = gethui()
    elseif CoreGui:FindFirstChild("RobloxGui") then
        guiParent = CoreGui.RobloxGui
    else
        guiParent = CoreGui
    end
end)
if not guiParent then
    guiParent = LocalPlayer:WaitForChild("PlayerGui", 5)
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "FPSBoosterUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = guiParent

-- AFK Screen Overlay (shown when 3D rendering is disabled)
afkOverlay = Instance.new("Frame")
afkOverlay.Name = "AfkOverlay"
afkOverlay.Size = UDim2.new(1, 0, 1, 0)
afkOverlay.Position = UDim2.new(0, 0, 0, 0)
afkOverlay.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
afkOverlay.BackgroundTransparency = 0.1
afkOverlay.ZIndex = 9999
afkOverlay.Visible = false
afkOverlay.Parent = screenGui

local afkCard = Instance.new("Frame")
afkCard.Size = UDim2.new(0, 360, 0, 140)
afkCard.Position = UDim2.new(0.5, -180, 0.5, -70)
afkCard.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
afkCard.BorderSizePixel = 0
afkCard.Parent = afkOverlay
Instance.new("UICorner", afkCard).CornerRadius = UDim.new(0, 10)

local afkStroke = Instance.new("UIStroke", afkCard)
afkStroke.Color = Color3.fromRGB(45, 120, 220)
afkStroke.Thickness = 1.5

local afkTitle = Instance.new("TextLabel")
afkTitle.Size = UDim2.new(1, -20, 0, 30)
afkTitle.Position = UDim2.new(0, 10, 0, 12)
afkTitle.BackgroundTransparency = 1
afkTitle.Text = "3D RENDERING PAUSED (AFK)"
afkTitle.TextColor3 = Color3.fromRGB(100, 200, 255)
afkTitle.Font = Enum.Font.GothamBold
afkTitle.TextSize = 15
afkTitle.Parent = afkCard

local afkSub = Instance.new("TextLabel")
afkSub.Size = UDim2.new(1, -20, 0, 36)
afkSub.Position = UDim2.new(0, 10, 0, 46)
afkSub.BackgroundTransparency = 1
afkSub.Text = "GPU draw is 0%. All scripts (Auto Farm, Fishing, Auto Sell) run at full speed in the background."
afkSub.TextColor3 = Color3.fromRGB(170, 185, 210)
afkSub.Font = Enum.Font.Gotham
afkSub.TextSize = 11
afkSub.TextWrapped = true
afkSub.Parent = afkCard

local resumeBtn = Instance.new("TextButton")
resumeBtn.Size = UDim2.new(1, -30, 0, 32)
resumeBtn.Position = UDim2.new(0, 15, 0, 92)
resumeBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
resumeBtn.Text = "RESUME 3D RENDERING (or press F3)"
resumeBtn.TextColor3 = Color3.new(1, 1, 1)
resumeBtn.Font = Enum.Font.GothamBold
resumeBtn.TextSize = 12
resumeBtn.Parent = afkCard
Instance.new("UICorner", resumeBtn).CornerRadius = UDim.new(0, 6)

resumeBtn.MouseButton1Click:Connect(function()
    set3dRenderingDisabled(false)
end)

-- Main Floating Control Window
local mainFrame = Instance.new("Frame")
mainFrame.Name = "FPSBoosterMain"
mainFrame.Size = UDim2.new(0, 240, 0, 255)
mainFrame.Position = UDim2.new(0, 20, 0.45, 0)
mainFrame.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui
Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 8)

local mainStroke = Instance.new("UIStroke", mainFrame)
mainStroke.Color = Color3.fromRGB(45, 55, 75)
mainStroke.Thickness = 1

-- Dragging support
do
    local dragging, dragStart, startPos = false, nil, nil
    mainFrame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = mainFrame.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            mainFrame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

-- Header Bar
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 32)
header.BackgroundColor3 = Color3.fromRGB(24, 29, 44)
header.BorderSizePixel = 0
header.Parent = mainFrame
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -75, 1, 0)
titleLbl.Position = UDim2.new(0, 10, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "⚡ FPS Booster"
titleLbl.TextColor3 = Color3.fromRGB(230, 240, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 13
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = header

local fpsLabel = Instance.new("TextLabel")
fpsLabel.Size = UDim2.new(0, 50, 1, 0)
fpsLabel.Position = UDim2.new(1, -70, 0, 0)
fpsLabel.BackgroundTransparency = 1
fpsLabel.Text = "60 FPS"
fpsLabel.TextColor3 = Color3.fromRGB(100, 240, 150)
fpsLabel.Font = Enum.Font.GothamBold
fpsLabel.TextSize = 11
fpsLabel.TextXAlignment = Enum.TextXAlignment.Right
fpsLabel.Parent = header

local content = Instance.new("Frame")
content.Size = UDim2.new(1, 0, 1, -32)
content.Position = UDim2.new(0, 0, 0, 32)
content.BackgroundTransparency = 1
content.Parent = mainFrame

local layout = Instance.new("UIListLayout", content)
layout.Padding = UDim.new(0, 5)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

local pad = Instance.new("UIPadding", content)
pad.PaddingTop = UDim.new(0, 6)
pad.PaddingBottom = UDim.new(0, 6)
pad.PaddingLeft = UDim.new(0, 8)
pad.PaddingRight = UDim.new(0, 8)

-- Helper to create toggle rows
local function createToggleRow(label, initialState, onToggle)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 26)
    row.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
    row.BorderSizePixel = 0
    row.Parent = content
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -55, 1, 0)
    lbl.Position = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = Color3.fromRGB(205, 220, 245)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 44, 0, 18)
    btn.Position = UDim2.new(1, -48, 0.5, -9)
    btn.BackgroundColor3 = initialState and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
    btn.Text = initialState and "ON" or "OFF"
    btn.TextColor3 = initialState and Color3.new(1, 1, 1) or Color3.fromRGB(160, 175, 195)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 10
    btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

    local current = initialState
    btn.MouseButton1Click:Connect(function()
        current = not current
        btn.Text = current and "ON" or "OFF"
        btn.BackgroundColor3 = current and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        btn.TextColor3 = current and Color3.new(1, 1, 1) or Color3.fromRGB(160, 175, 195)
        onToggle(current)
    end)
    return row, btn
end

-- Create Toggles
createToggleRow("Mute All SFX", State.MuteSFX, function(on)
    State.MuteSFX = on
    applySfxOptimization(on)
end)

createToggleRow("Disable VFX / Particles", State.DisableVFX, function(on)
    State.DisableVFX = on
    applyVfxOptimization(on)
end)

createToggleRow("Disable Shadows & PostFX", State.DisableLighting, function(on)
    State.DisableLighting = on
    applyLightingOptimization(on)
end)

createToggleRow("Smooth Plastic / No Textures", State.SmoothPlastic, function(on)
    State.SmoothPlastic = on
    applySmoothPlastic(on)
end)

local _, renderBtn = createToggleRow("AFK 0% GPU (No 3D) [F3]", State.No3DRendering, function(on)
    set3dRenderingDisabled(on)
end)

-- FPS Cap Selector Row
local fpsRow = Instance.new("Frame")
fpsRow.Size = UDim2.new(1, 0, 0, 26)
fpsRow.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
fpsRow.BorderSizePixel = 0
fpsRow.Parent = content
Instance.new("UICorner", fpsRow).CornerRadius = UDim.new(0, 5)

local fpsTitle = Instance.new("TextLabel")
fpsTitle.Size = UDim2.new(0, 60, 1, 0)
fpsTitle.Position = UDim2.new(0, 8, 0, 0)
fpsTitle.BackgroundTransparency = 1
fpsTitle.Text = "FPS Cap:"
fpsTitle.TextColor3 = Color3.fromRGB(205, 220, 245)
fpsTitle.Font = Enum.Font.Gotham
fpsTitle.TextSize = 11
fpsTitle.TextXAlignment = Enum.TextXAlignment.Left
fpsTitle.Parent = fpsRow

local fpsCaps = { 30, 60, 0 }
local fpsNames = { ["30"] = "30", ["60"] = "60", ["0"] = "Max" }
local capBtns = {}

for i, cap in ipairs(fpsCaps) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 46, 0, 18)
    b.Position = UDim2.new(0, 68 + (i - 1) * 50, 0.5, -9)
    b.BackgroundColor3 = (cap == State.TargetFps) and Color3.fromRGB(45, 100, 160) or Color3.fromRGB(38, 44, 60)
    b.Text = fpsNames[tostring(cap)]
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 10
    b.Parent = fpsRow
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)

    capBtns[cap] = b
    b.MouseButton1Click:Connect(function()
        applyFpsCap(cap)
        for c, btnObj in pairs(capBtns) do
            btnObj.BackgroundColor3 = (c == cap) and Color3.fromRGB(45, 100, 160) or Color3.fromRGB(38, 44, 60)
        end
    end)
end

-- Close / Minimize Button in Header
local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 20, 0, 20)
minBtn.Position = UDim2.new(1, -26, 0.5, -10)
minBtn.BackgroundColor3 = Color3.fromRGB(45, 52, 70)
minBtn.Text = "—"
minBtn.TextColor3 = Color3.fromRGB(200, 215, 235)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 11
minBtn.Parent = header
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 4)

local isMinimized = false
minBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    content.Visible = not isMinimized
    mainFrame.Size = isMinimized and UDim2.new(0, 240, 0, 32) or UDim2.new(0, 240, 0, 255)
    minBtn.Text = isMinimized and "+" or "—"
end)

-- Keyboard Shortcut: Press F3 to toggle 3D rendering
addConnection(UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.F3 then
        local nextState = not State.No3DRendering
        set3dRenderingDisabled(nextState)
        if renderBtn then
            renderBtn.Text = nextState and "ON" or "OFF"
            renderBtn.BackgroundColor3 = nextState and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        end
    end
end))

-- Live FPS Counter Loop (Throttled 1.0s update = 0 CPU cost)
task.spawn(function()
    local frameCount = 0
    local lastTime = os.clock()

    addConnection(RunService.RenderStepped:Connect(function()
        frameCount = frameCount + 1
        local now = os.clock()
        if now - lastTime >= 1.0 then
            local currentFps = math.round(frameCount / (now - lastTime))
            frameCount = 0
            lastTime = now
            if fpsLabel and fpsLabel.Parent then
                fpsLabel.Text = tostring(currentFps) .. " FPS"
                if currentFps >= 50 then
                    fpsLabel.TextColor3 = Color3.fromRGB(100, 240, 150)
                elseif currentFps >= 30 then
                    fpsLabel.TextColor3 = Color3.fromRGB(255, 215, 90)
                else
                    fpsLabel.TextColor3 = Color3.fromRGB(255, 100, 80)
                end
            end
        end
    end))
end)

-- ============================================================================
-- INITIAL ACTIVATION
-- ============================================================================
task.spawn(function()
    if State.MuteSFX then applySfxOptimization(true) end
    if State.DisableVFX then applyVfxOptimization(true) end
    if State.DisableLighting then applyLightingOptimization(true) end
    if State.SmoothPlastic then applySmoothPlastic(true) end
    applyFpsCap(State.TargetFps)
end)

-- ============================================================================
-- CLEANUP HANDLER (Exported to _G for safe re-execution & hot-reload)
-- ============================================================================
local function cleanup()
    State.Active = false

    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)

    -- Restore 3D rendering
    pcall(function() RunService:Set3dRenderingEnabled(true) end)

    -- Restore sounds
    applySfxOptimization(false)

    -- Restore VFX
    applyVfxOptimization(false)

    -- Restore lighting
    applyLightingOptimization(false)

    -- Restore parts if modified
    applySmoothPlastic(false)

    -- Destroy UI
    if screenGui and screenGui.Parent then
        pcall(function() screenGui:Destroy() end)
    end

    _G.FPSBooster_Cleanup = nil
end

_G.FPSBooster_Cleanup = cleanup
print("[FPS Booster] Loaded and active. Press F3 to toggle AFK 0% GPU 3D rendering.")
