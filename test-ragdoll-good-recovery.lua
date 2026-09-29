--[[
    Steal an Egg — Velocity Changer + Recovery Assist
    =================================================

    BASED ON YOUR WORKING SPEED SCRIPT.

    Normal movement:
      - Humanoid.WalkSpeed = targetVelocity
      - AssemblyLinearVelocity controls X/Z
      - Y velocity is preserved
      - Zero friction
      - Egg weight neutralization

    Recovery Assist:
      - Detects actual ragdoll state
      - Temporarily stops the normal velocity writer
      - Attempts a single local recovery
      - Re-enables disabled Motor6D joints
      - Restores Humanoid control
      - Resumes normal speed controller

    IMPORTANT:
      Recovery Assist does NOT run during normal movement.
      It only activates when a ragdoll/physics state is detected.
]]

--==================================================
-- SERVICES
--==================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

if not LocalPlayer then
    pcall(function()
        LocalPlayer =
            Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    end)

    LocalPlayer =
        Players.LocalPlayer
        or Players.PlayerAdded:Wait()
end

--==================================================
-- STATE & CONFIG
--==================================================

local velocityEnabled = false
local targetVelocity = 240.0
local savedWalkSpeed = 16.0

local scriptAlive = true

-- Prevent recovery from being spammed.
local recoveryActive = false
local lastRecoveryTime = 0

-- Set this false if you want pure original behavior.
local recoveryAssistEnabled = true

local zeroFriction =
    PhysicalProperties.new(
        0.7,
        0,
        0,
        100,
        100
    )

--==================================================
-- ORIGINAL PHYSICAL PROPERTIES
--==================================================

local originalPhysicalProperties = {}

--==================================================
-- CONNECTIONS
--==================================================

local connections = {}

local function addConnection(connection)

    table.insert(
        connections,
        connection
    )

    return connection
end

local function disconnectAll()

    for _, connection in ipairs(
        connections
    ) do

        pcall(function()
            connection:Disconnect()
        end)
    end

    table.clear(connections)
end

--==================================================
-- FRICTION
--==================================================

local function setFrictionless(enable)

    local char =
        LocalPlayer.Character

    if not char then
        return
    end

    for _, desc in ipairs(
        char:GetDescendants()
    ) do

        if desc:IsA("BasePart") then

            if enable then

                if originalPhysicalProperties[
                    desc
                ] == nil then

                    originalPhysicalProperties[
                        desc
                    ] =
                        desc.CustomPhysicalProperties
                end

                pcall(function()

                    desc.CustomPhysicalProperties =
                        zeroFriction

                end)

            else

                local original =
                    originalPhysicalProperties[
                        desc
                    ]

                pcall(function()

                    desc.CustomPhysicalProperties =
                        original

                end)

                originalPhysicalProperties[
                    desc
                ] = nil
            end
        end
    end
end

--==================================================
-- EGG DETECTION
--==================================================

local function isHoldingEgg()

    local char =
        LocalPlayer.Character

    if char then

        for _, child in ipairs(
            char:GetChildren()
        ) do

            if child:IsA("Tool")
                or string.find(
                    string.lower(
                        child.Name
                    ),
                    "egg"
                ) then

                return true
            end
        end
    end

    local backpack =
        LocalPlayer:FindFirstChildOfClass(
            "Backpack"
        )

    if backpack then

        for _, child in ipairs(
            backpack:GetChildren()
        ) do

            if child:IsA("Tool")
                or string.find(
                    string.lower(
                        child.Name
                    ),
                    "egg"
                ) then

                return true
            end
        end
    end

    local cra =
        Workspace:FindFirstChild(
            "ClientRenderedAssets"
        )

    if cra then

        for _, child in ipairs(
            cra:GetChildren()
        ) do

            if string.find(
                child.Name,
                tostring(
                    LocalPlayer.UserId
                )
            ) then

                return true
            end
        end
    end

    return false
end

--==================================================
-- EGG PHYSICS
--==================================================

local function neutraliseEggPhysics(char)

    if not char then
        return
    end

    for _, desc in ipairs(
        char:GetDescendants()
    ) do

        if desc:IsA("BasePart")
            and desc.Name ~=
                "HumanoidRootPart"
            and desc.Parent ~= char then

            pcall(function()

                desc.Massless = true
                desc.CanCollide = false

            end)
        end
    end

    local cra =
        Workspace:FindFirstChild(
            "ClientRenderedAssets"
        )

    if cra then

        for _, model in ipairs(
            cra:GetChildren()
        ) do

            if string.find(
                model.Name,
                tostring(
                    LocalPlayer.UserId
                )
            ) then

                for _, part in ipairs(
                    model:GetDescendants()
                ) do

                    if part:IsA(
                        "BasePart"
                    ) then

                        pcall(function()

                            part.Massless =
                                true

                            part.CanCollide =
                                false

                        end)
                    end
                end
            end
        end
    end
end

--==================================================
-- RAGDOLL DETECTION
--==================================================

local function getRagdollReason(hum)

    if not hum then
        return nil
    end

    -- Game-specific timer.
    local ragdollEnd =
        LocalPlayer:GetAttribute(
            "RagdollEndTime"
        )

    if typeof(ragdollEnd) == "number" then

        if ragdollEnd >
            Workspace:GetServerTimeNow() then

            return "RagdollEndTime"
        end
    end

    -- Humanoid states.
    local state =
        hum:GetState()

    if state ==
        Enum.HumanoidStateType.Ragdoll then

        return "Ragdoll"
    end

    if state ==
        Enum.HumanoidStateType.FallingDown then

        return "FallingDown"
    end

    if state ==
        Enum.HumanoidStateType.Physics then

        return "Physics"
    end

    if hum.PlatformStand then
        return "PlatformStand"
    end

    -- Detect custom ragdolls that disable joints.
    local char =
        hum.Parent

    if char then

        local disabledMotors = 0
        local totalMotors = 0

        for _, obj in ipairs(
            char:GetDescendants()
        ) do

            if obj:IsA("Motor6D") then

                totalMotors += 1

                if not obj.Enabled then
                    disabledMotors += 1
                end
            end
        end

        if totalMotors > 0
            and disabledMotors >= 2 then

            return string.format(
                "Motor6D:%d disabled",
                disabledMotors
            )
        end
    end

    return nil
end

--==================================================
-- RECOVERY
--==================================================

local function recoveryPulse(hum)

    if not hum then
        return
    end

    local now =
        os.clock()

    -- Don't repeatedly fire recovery.
    if now - lastRecoveryTime < 0.20 then
        return
    end

    if recoveryActive then
        return
    end

    recoveryActive = true
    lastRecoveryTime = now

    local char =
        hum.Parent

    if not char then

        recoveryActive = false
        return
    end

    print(
        "[Recovery Assist] Ragdoll detected."
    )

    --================================================
    -- 1. Stop normal velocity control temporarily
    --================================================

    -- Do not write AssemblyLinearVelocity here.

    --================================================
    -- 2. Restore Motor6D joints
    --================================================

    local motorsRestored = 0

    for _, obj in ipairs(
        char:GetDescendants()
    ) do

        if obj:IsA("Motor6D")
            and not obj.Enabled then

            pcall(function()

                obj.Enabled = true

                motorsRestored += 1

            end)
        end
    end

    --================================================
    -- 3. Restore Humanoid control
    --================================================

    pcall(function()
        hum.PlatformStand = false
    end)

    pcall(function()
        hum.Sit = false
    end)

    pcall(function()
        hum.AutoRotate = true
    end)

    --================================================
    -- 4. Re-enable humanoid states
    --================================================

    pcall(function()

        hum:SetStateEnabled(
            Enum.HumanoidStateType.Ragdoll,
            true
        )

        hum:SetStateEnabled(
            Enum.HumanoidStateType.FallingDown,
            true
        )

        hum:SetStateEnabled(
            Enum.HumanoidStateType.Physics,
            true
        )

    end)

    --================================================
    -- 5. Ask Humanoid to recover
    --================================================

    pcall(function()

        hum:ChangeState(
            Enum.HumanoidStateType.GettingUp
        )

    end)

    task.wait()

    if hum.Parent then

        pcall(function()

            hum:ChangeState(
                Enum.HumanoidStateType.Running
            )

        end)
    end

    print(
        "[Recovery Assist] Motors restored:",
        motorsRestored
    )

    --================================================
    -- 6. Give physics a brief moment to settle
    --================================================

    task.wait(0.05)

    recoveryActive = false
end

--==================================================
-- MAIN VELOCITY ENGINE
--==================================================

local function applyVelocity()

    if not scriptAlive then
        return
    end

    if not velocityEnabled then
        return
    end

    local char =
        LocalPlayer.Character

    local hum =
        char
        and char:FindFirstChildOfClass(
            "Humanoid"
        )

    local root =
        char
        and char:FindFirstChild(
            "HumanoidRootPart"
        )

    if not hum or not root then
        return
    end

    --================================================
    -- RAGDOLL / BOSS HIT
    --================================================

    local ragdollReason =
        getRagdollReason(hum)

    if ragdollReason then

        if recoveryAssistEnabled then

            -- Recovery runs asynchronously so it
            -- doesn't block the physics update.
            task.spawn(function()

                recoveryPulse(
                    hum
                )

            end)
        end

        return
    end

    --================================================
    -- NORMAL EGG PHYSICS
    --================================================

    if isHoldingEgg() then

        neutraliseEggPhysics(
            char
        )
    end

    --================================================
    -- WALK SPEED
    --================================================

    if hum.WalkSpeed ~=
        targetVelocity then

        pcall(function()

            hum.WalkSpeed =
                targetVelocity

        end)
    end

    --================================================
    -- DIRECT VELOCITY
    --================================================

    if hum.MoveDirection.Magnitude >
        0.05 then

        local dir =
            hum.MoveDirection.Unit

        root.AssemblyLinearVelocity =
            Vector3.new(

                dir.X *
                    targetVelocity,

                root.AssemblyLinearVelocity.Y,

                dir.Z *
                    targetVelocity
            )
    end
end

--==================================================
-- GUI PARENT
--==================================================

local function getGuiParent()

    local parent

    pcall(function()

        if gethui then
            parent = gethui()
        end

    end)

    if not parent then

        pcall(function()

            parent =
                game:GetService("CoreGui")

        end)
    end

    return
        parent
        or LocalPlayer:FindFirstChildOfClass(
            "PlayerGui"
        )
end

local guiParent =
    getGuiParent()

if not guiParent then
    return
end

--==================================================
-- GUI
--==================================================

local GUI_NAME =
    "StealAnEgg_VelocityRecoveryAssist"

local oldGui =
    guiParent:FindFirstChild(
        GUI_NAME
    )

if oldGui then
    oldGui:Destroy()
end

local screenGui =
    Instance.new("ScreenGui")

screenGui.Name =
    GUI_NAME

screenGui.ResetOnSpawn =
    false

screenGui.ZIndexBehavior =
    Enum.ZIndexBehavior.Sibling

pcall(function()

    screenGui.Parent =
        guiParent

end)

if not screenGui.Parent then

    screenGui.Parent =
        LocalPlayer:FindFirstChildOfClass(
            "PlayerGui"
        )
end

--==================================================
-- MAIN WINDOW
--==================================================

local main =
    Instance.new("Frame")

main.Size =
    UDim2.new(
        0,
        300,
        0,
        185
    )

main.Position =
    UDim2.new(
        0.5,
        -150,
        0.45,
        -92
    )

main.BackgroundColor3 =
    Color3.fromRGB(
        18,
        22,
        30
    )

main.BorderSizePixel = 0
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius =
    UDim.new(0, 10)

local mainStroke =
    Instance.new("UIStroke", main)

mainStroke.Color =
    Color3.fromRGB(
        70,
        130,
        230
    )

mainStroke.Thickness = 1.5

--==================================================
-- TITLE
--==================================================

local titleBar =
    Instance.new("Frame")

titleBar.Size =
    UDim2.new(
        1,
        0,
        0,
        32
    )

titleBar.BackgroundColor3 =
    Color3.fromRGB(
        26,
        34,
        48
    )

titleBar.BorderSizePixel = 0
titleBar.Parent = main

Instance.new("UICorner", titleBar).CornerRadius =
    UDim.new(0, 10)

local titleFix =
    Instance.new("Frame")

titleFix.Size =
    UDim2.new(
        1,
        0,
        0,
        8
    )

titleFix.Position =
    UDim2.new(
        0,
        0,
        1,
        -8
    )

titleFix.BackgroundColor3 =
    Color3.fromRGB(
        26,
        34,
        48
    )

titleFix.BorderSizePixel = 0
titleFix.Parent = titleBar

local titleLabel =
    Instance.new("TextLabel")

titleLabel.Size =
    UDim2.new(
        1,
        -45,
        1,
        0
    )

titleLabel.Position =
    UDim2.new(
        0,
        12,
        0,
        0
    )

titleLabel.BackgroundTransparency =
    1

titleLabel.Text =
    "⚡ Velocity + Recovery"

titleLabel.TextColor3 =
    Color3.fromRGB(
        220,
        235,
        255
    )

titleLabel.TextSize = 13
titleLabel.Font =
    Enum.Font.GothamBold

titleLabel.TextXAlignment =
    Enum.TextXAlignment.Left

titleLabel.Parent =
    titleBar

--==================================================
-- CLOSE
--==================================================

local closeBtn =
    Instance.new("TextButton")

closeBtn.Size =
    UDim2.new(
        0,
        24,
        0,
        20
    )

closeBtn.Position =
    UDim2.new(
        1,
        -30,
        0.5,
        -10
    )

closeBtn.BackgroundColor3 =
    Color3.fromRGB(
        180,
        50,
        50
    )

closeBtn.Text =
    "X"

closeBtn.TextColor3 =
    Color3.new(
        1,
        1,
        1
    )

closeBtn.TextSize = 11
closeBtn.Font =
    Enum.Font.GothamBold

closeBtn.Parent =
    titleBar

Instance.new("UICorner", closeBtn).CornerRadius =
    UDim.new(0, 5)

--==================================================
-- DRAGGING
--==================================================

local dragging = false
local dragStart
local startPos

addConnection(
    titleBar.InputBegan:Connect(
        function(input)

            if input.UserInputType ==
                Enum.UserInputType.MouseButton1

                or input.UserInputType ==
                    Enum.UserInputType.Touch then

                dragging = true
                dragStart = input.Position
                startPos = main.Position
            end
        end
    )
)

addConnection(
    titleBar.InputEnded:Connect(
        function(input)

            if input.UserInputType ==
                Enum.UserInputType.MouseButton1

                or input.UserInputType ==
                    Enum.UserInputType.Touch then

                dragging = false
            end
        end
    )
)

addConnection(
    UserInputService.InputChanged:Connect(
        function(input)

            if dragging
                and (
                    input.UserInputType ==
                        Enum.UserInputType.MouseMovement

                    or input.UserInputType ==
                        Enum.UserInputType.Touch
                ) then

                local d =
                    input.Position -
                    dragStart

                main.Position =
                    UDim2.new(
                        startPos.X.Scale,
                        startPos.X.Offset + d.X,

                        startPos.Y.Scale,
                        startPos.Y.Offset + d.Y
                    )
            end
        end
    )
)

--==================================================
-- STATUS
--==================================================

local statusBox =
    Instance.new("Frame")

statusBox.Size =
    UDim2.new(
        1,
        -20,
        0,
        28
    )

statusBox.Position =
    UDim2.new(
        0,
        10,
        0,
        40
    )

statusBox.BackgroundColor3 =
    Color3.fromRGB(
        24,
        29,
        40
    )

statusBox.BorderSizePixel = 0
statusBox.Parent = main

Instance.new("UICorner", statusBox).CornerRadius =
    UDim.new(0, 5)

local statusText =
    Instance.new("TextLabel")

statusText.Size =
    UDim2.new(
        1,
        -12,
        1,
        0
    )

statusText.Position =
    UDim2.new(
        0,
        8,
        0,
        0
    )

statusText.BackgroundTransparency =
    1

statusText.Text =
    "Vel: 0 | Normal"

statusText.TextColor3 =
    Color3.fromRGB(
        140,
        190,
        240
    )

statusText.TextSize = 11

statusText.Font =
    Enum.Font.GothamBold

statusText.TextXAlignment =
    Enum.TextXAlignment.Left

statusText.Parent =
    statusBox

--==================================================
-- INPUT
--==================================================

local inputRow =
    Instance.new("Frame")

inputRow.Size =
    UDim2.new(
        1,
        -20,
        0,
        32
    )

inputRow.Position =
    UDim2.new(
        0,
        10,
        0,
        74
    )

inputRow.BackgroundTransparency =
    1

inputRow.Parent =
    main

local inputLabel =
    Instance.new("TextLabel")

inputLabel.Size =
    UDim2.new(
        0,
        95,
        1,
        0
    )

inputLabel.BackgroundTransparency =
    1

inputLabel.Text =
    "Target Velocity:"

inputLabel.TextColor3 =
    Color3.fromRGB(
        200,
        215,
        235
    )

inputLabel.TextSize = 12
inputLabel.Font =
    Enum.Font.GothamBold

inputLabel.TextXAlignment =
    Enum.TextXAlignment.Left

inputLabel.Parent =
    inputRow

local inputBox =
    Instance.new("TextBox")

inputBox.Size =
    UDim2.new(
        1,
        -100,
        1,
        0
    )

inputBox.Position =
    UDim2.new(
        0,
        100,
        0,
        0
    )

inputBox.BackgroundColor3 =
    Color3.fromRGB(
        28,
        34,
        48
    )

inputBox.BorderSizePixel = 0

inputBox.Text =
    tostring(
        targetVelocity
    )

inputBox.PlaceholderText =
    "e.g. 240"

inputBox.TextColor3 =
    Color3.fromRGB(
        255,
        255,
        255
    )

inputBox.TextSize = 13
inputBox.Font =
    Enum.Font.GothamBold

inputBox.ClearTextOnFocus =
    false

inputBox.Parent =
    inputRow

Instance.new("UICorner", inputBox).CornerRadius =
    UDim.new(0, 6)

local inputStroke =
    Instance.new("UIStroke", inputBox)

inputStroke.Color =
    Color3.fromRGB(
        60,
        80,
        115
    )

inputStroke.Thickness = 1

--==================================================
-- TOGGLE
--==================================================

local toggleBtn =
    Instance.new("TextButton")

toggleBtn.Size =
    UDim2.new(
        1,
        -20,
        0,
        38
    )

toggleBtn.Position =
    UDim2.new(
        0,
        10,
        0,
        112
    )

toggleBtn.BackgroundColor3 =
    Color3.fromRGB(
        42,
        48,
        65
    )

toggleBtn.Text =
    "[OFF] Turn ON Velocity"

toggleBtn.TextColor3 =
    Color3.fromRGB(
        210,
        220,
        240
    )

toggleBtn.TextSize = 13

toggleBtn.Font =
    Enum.Font.GothamBold

toggleBtn.Parent =
    main

Instance.new("UICorner", toggleBtn).CornerRadius =
    UDim.new(0, 7)

local toggleStroke =
    Instance.new("UIStroke", toggleBtn)

toggleStroke.Color =
    Color3.fromRGB(
        65,
        80,
        110
    )

toggleStroke.Thickness = 1.2

--==================================================
-- TARGET INPUT HANDLER
--==================================================

local function updateTargetFromInput()

    local value =
        tonumber(
            inputBox.Text
        )

    if value
        and value > 0 then

        targetVelocity =
            value

        inputStroke.Color =
            Color3.fromRGB(
                60,
                140,
                240
            )

        if velocityEnabled then

            toggleBtn.Text =
                string.format(
                    "[ON] Velocity Active (%d)",
                    targetVelocity
                )
        end

    else

        inputBox.Text =
            tostring(
                targetVelocity
            )
    end
end

addConnection(
    inputBox.FocusLost:Connect(
        updateTargetFromInput
    )
)

addConnection(
    inputBox:GetPropertyChangedSignal(
        "Text"
    ):Connect(
        function()

            local value =
                tonumber(
                    inputBox.Text
                )

            if value
                and value > 0 then

                targetVelocity =
                    value
            end
        end
    )
)

--==================================================
-- TOGGLE HANDLER
--==================================================

addConnection(
    toggleBtn.MouseButton1Click:Connect(
        function()

            updateTargetFromInput()

            velocityEnabled =
                not velocityEnabled

            local char =
                LocalPlayer.Character

            local hum =
                char
                and char:FindFirstChildOfClass(
                    "Humanoid"
                )

            if velocityEnabled then

                if hum then

                    savedWalkSpeed =
                        hum.WalkSpeed
                end

                setFrictionless(true)

                toggleBtn.BackgroundColor3 =
                    Color3.fromRGB(
                        35,
                        135,
                        75
                    )

                toggleBtn.TextColor3 =
                    Color3.new(
                        1,
                        1,
                        1
                    )

                toggleBtn.Text =
                    string.format(
                        "[ON] Velocity Active (%d)",
                        targetVelocity
                    )

                toggleStroke.Color =
                    Color3.fromRGB(
                        70,
                        220,
                        120
                    )

            else

                setFrictionless(false)

                if hum then

                    pcall(function()

                        hum.WalkSpeed =
                            savedWalkSpeed

                    end)
                end

                toggleBtn.BackgroundColor3 =
                    Color3.fromRGB(
                        42,
                        48,
                        65
                    )

                toggleBtn.TextColor3 =
                    Color3.fromRGB(
                        210,
                        220,
                        240
                    )

                toggleBtn.Text =
                    "[OFF] Turn ON Velocity"

                toggleStroke.Color =
                    Color3.fromRGB(
                        65,
                        80,
                        110
                    )
            end
        end
    )
)

--==================================================
-- STATUS UPDATE
--==================================================

addConnection(
    RunService.Heartbeat:Connect(
        function()

            if not scriptAlive then
                return
            end

            local char =
                LocalPlayer.Character

            local hum =
                char
                and char:FindFirstChildOfClass(
                    "Humanoid"
                )

            local root =
                char
                and char:FindFirstChild(
                    "HumanoidRootPart"
                )

            if not hum or not root then
                return
            end

            local horizontalVelocity =
                Vector3.new(
                    root.AssemblyLinearVelocity.X,
                    0,
                    root.AssemblyLinearVelocity.Z
                )

            local velocity =
                math.floor(
                    horizontalVelocity.Magnitude
                )

            local ragdoll =
                getRagdollReason(hum)

            if ragdoll then

                statusText.Text =
                    string.format(
                        "Vel: %d | RECOVERY: %s",
                        velocity,
                        ragdoll
                    )

                statusText.TextColor3 =
                    Color3.fromRGB(
                        255,
                        180,
                        80
                    )

            else

                local egg =
                    isHoldingEgg()

                statusText.Text =
                    string.format(
                        "Vel: %d | %s%s",
                        velocity,

                        egg
                            and "🥚 Egg"
                            or "Normal",

                        recoveryActive
                            and " | Recovering"
                            or ""
                    )

                statusText.TextColor3 =
                    velocityEnabled
                        and Color3.fromRGB(
                            100,
                            240,
                            255
                        )
                        or Color3.fromRGB(
                            140,
                            190,
                            240
                        )
            end
        end
    )
)

--==================================================
-- CLOSE
--==================================================

addConnection(
    closeBtn.MouseButton1Click:Connect(
        function()

            scriptAlive = false
            velocityEnabled = false

            setFrictionless(false)

            local char =
                LocalPlayer.Character

            local hum =
                char
                and char:FindFirstChildOfClass(
                    "Humanoid"
                )

            if hum then

                pcall(function()

                    hum.WalkSpeed =
                        savedWalkSpeed

                end)
            end

            disconnectAll()

            if screenGui then
                screenGui:Destroy()
            end
        end
    )
)

--==================================================
-- RESPAWN
--==================================================

addConnection(
    LocalPlayer.CharacterAdded:Connect(
        function()

            task.wait(0.5)

            if not scriptAlive then
                return
            end

            recoveryActive = false
            lastRecoveryTime = 0

            if velocityEnabled then

                setFrictionless(true)

                local char =
                    LocalPlayer.Character

                local hum =
                    char
                    and char:FindFirstChildOfClass(
                        "Humanoid"
                    )

                if hum then

                    savedWalkSpeed =
                        hum.WalkSpeed

                end
            end
        end
    )
)

--==================================================
-- MOVEMENT CONNECTIONS
--==================================================

-- Keep the same two update points as your
-- proven speed script.

addConnection(
    RunService.Stepped:Connect(
        applyVelocity
    )
)

addConnection(
    RunService.Heartbeat:Connect(
        applyVelocity
    )
)

--==================================================
-- LOADED
--==================================================

print(
    "[Steal an Egg — Velocity + Recovery Assist] Loaded."
)

print(
    "[Recovery Assist] Enabled:",
    recoveryAssistEnabled
)

print(
    "[Velocity] Target:",
    targetVelocity
)