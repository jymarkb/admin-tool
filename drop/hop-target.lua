local player = game:GetService("Players").LocalPlayer
local character = player and player.Character
local hrp = character and character:FindFirstChild("HumanoidRootPart")

local targetPos = Vector3.new(5706.468, 70.813, -358.282)

if hrp then
    local startPos = hrp.Position
    local totalDist = (targetPos - startPos).Magnitude

    -- If close (<= 800 studs), teleport in 1 direct hop
    if totalDist <= 900 then
        hrp.CFrame = CFrame.new(targetPos)
        hrp.AssemblyLinearVelocity = Vector3.zero
    else
        -- If far away, hop in 600-stud safe chunks so the server doesn't rubberband
        local hops = math.ceil(totalDist / 850)
        for h = 1, hops do
            local alpha = h / hops
            hrp.CFrame = CFrame.new(startPos:Lerp(targetPos, alpha))
            hrp.AssemblyLinearVelocity = Vector3.zero
            if h < hops then
                task.wait(0.25)
            end
        end
        hrp.CFrame = CFrame.new(targetPos)
        hrp.AssemblyLinearVelocity = Vector3.zero
    end
end