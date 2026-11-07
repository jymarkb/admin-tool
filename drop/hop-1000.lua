-- Simple 1-Hop 1,000 Studs Forward
local player = game:GetService("Players").LocalPlayer
local character = player and player.Character
local hrp = character and character:FindFirstChild("HumanoidRootPart")

if hrp then
    local look = hrp.CFrame.LookVector
    local fwd = Vector3.new(look.X, 0, look.Z).Unit
    hrp.CFrame = CFrame.new(hrp.Position + fwd * 1000, hrp.Position + fwd * 1001)
    hrp.AssemblyLinearVelocity = Vector3.zero
end