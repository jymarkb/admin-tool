--[[
    FISHING SCANNER
    Hooks RF/Fishing/Cast and RF/Fishing/Reel only.
    Logs arguments AND return values so we can see what the server expects.
]]

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local pg = Players.LocalPlayer:WaitForChild("PlayerGui")

-- ======================
-- UI
-- ======================

local screen = Instance.new("ScreenGui")
screen.Name = "FishingScanner"
screen.ResetOnSpawn = false
screen.Parent = pg

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 340, 0, 420)
frame.Position = UDim2.new(0, 20, 0.1, 0)
frame.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = screen

Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)

local titleBar = Instance.new("TextLabel")
titleBar.Size = UDim2.new(1, -10, 0, 30)
titleBar.Position = UDim2.new(0, 8, 0, 0)
titleBar.BackgroundTransparency = 1
titleBar.Text = "FISHING SCANNER"
titleBar.TextColor3 = Color3.new(1, 1, 1)
titleBar.Font = Enum.Font.GothamBold
titleBar.TextSize = 13
titleBar.TextXAlignment = Enum.TextXAlignment.Left
titleBar.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -30, 0, 2)
closeBtn.BackgroundColor3 = Color3.fromRGB(160, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

local logBox = Instance.new("TextBox")
logBox.Size = UDim2.new(1, -16, 1, -80)
logBox.Position = UDim2.new(0, 8, 0, 36)
logBox.BackgroundColor3 = Color3.fromRGB(8, 8, 16)
logBox.TextColor3 = Color3.fromRGB(200, 230, 200)
logBox.Font = Enum.Font.Code
logBox.TextSize = 11
logBox.Text = "Fish manually.\nEvery fishing remote will be logged here."
logBox.TextWrapped = false
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.ClearTextOnFocus = false
logBox.TextEditable = false
logBox.MultiLine = true
logBox.Parent = frame
Instance.new("UICorner", logBox).CornerRadius = UDim.new(0, 6)

local lp = Instance.new("UIPadding")
lp.PaddingLeft = UDim.new(0, 5)
lp.PaddingTop  = UDim.new(0, 5)
lp.Parent = logBox

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(1, -16, 0, 32)
clearBtn.Position = UDim2.new(0, 8, 1, -40)
clearBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 90)
clearBtn.Text = "CLEAR"
clearBtn.TextColor3 = Color3.new(1, 1, 1)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 13
clearBtn.Parent = frame
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

-- ======================
-- DRAG
-- ======================

local dragging, dragStart, startPos = false, nil, nil

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true; dragStart = input.Position; startPos = frame.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local d = input.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)

closeBtn.MouseButton1Click:Connect(function() screen:Destroy() end)

-- ======================
-- LOGGER
-- ======================

local logLines = {}

local function log(msg)
    table.insert(logLines, msg)
    if #logLines > 60 then table.remove(logLines, 1) end
    pcall(function() logBox.Text = table.concat(logLines, "\n") end)
end

clearBtn.MouseButton1Click:Connect(function()
    table.clear(logLines)
    logBox.Text = ""
end)

-- ======================
-- VALUE FORMATTER (inline, minimal)
-- ======================

local function fmt(v)
    local t = typeof(v)
    if v == nil then return "nil" end
    if t == "string" then return '"' .. v .. '"' end
    if t == "boolean" or t == "number" then return tostring(v) end
    if t == "Vector3" then
        return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
    end
    if t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            table.insert(parts, tostring(k) .. "=" .. fmt(val))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    local ok, s = pcall(tostring, v)
    return ok and s or "<unknown>"
end

local function fmtArgs(packed)
    if packed.n == 0 then return "  args: none" end
    local lines = {}
    for i = 1, packed.n do
        table.insert(lines, "  [" .. i .. "] " .. fmt(packed[i]))
    end
    return table.concat(lines, "\n")
end

-- ======================
-- HOOK
-- ======================

local FISHING_REMOTES = {
    ["RE/Fishing/Hold"]   = true,
    ["RE/Fishing/Cancel"] = true,
    ["RF/Fishing/Cast"]   = true,
    ["RF/Fishing/Reel"]   = true,
}

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    local args   = table.pack(...)

    -- Fast path: not a fishing remote or not a remote call
    if method ~= "FireServer" and method ~= "InvokeServer" then
        return oldNamecall(self, ...)
    end

    local isFishing = pcall(function()
        return typeof(self) == "Instance" and FISHING_REMOTES[self.Name]
    end) and typeof(self) == "Instance" and FISHING_REMOTES[self.Name]

    if not isFishing then
        return oldNamecall(self, ...)
    end

    -- Log args
    pcall(function()
        log("------------------------------")
        log(method .. " -> " .. self.Name)
        log(fmtArgs(args))
    end)

    -- Call original and capture result
    local results = table.pack(oldNamecall(self, ...))

    -- Log return
    pcall(function()
        local retParts = {}
        for i = 1, results.n do
            table.insert(retParts, fmt(results[i]))
        end
        log("  return: " .. (results.n > 0 and table.concat(retParts, ", ") or "nil"))
    end)

    return table.unpack(results, 1, results.n)
end)

-- ======================
-- SERVER -> CLIENT EVENT LISTENER
-- ======================

-- Listen for anything the server fires back on fishing remotes
local NET = nil
pcall(function()
    NET = ReplicatedStorage
        :WaitForChild("Packages", 5)
        :WaitForChild("Networking", 5)
end)

if NET then
    local function listenRE(name)
        local re = NET:FindFirstChild(name)
        if re then
            re.OnClientEvent:Connect(function(...)
                local args = table.pack(...)
                local parts = {}
                for i = 1, args.n do
                    table.insert(parts, fmt(args[i]))
                end
                log("~~~ SERVER->CLIENT: " .. name)
                log("  " .. (args.n > 0 and table.concat(parts, ", ") or "none"))
            end)
            log("Listening: " .. name)
        else
            log("NOT FOUND: " .. name)
        end
    end

    listenRE("RE/Fishing/Hold")
    listenRE("RE/Fishing/Cancel")
else
    log("Could not find Networking for listeners")
end

log("Hook active. Fish manually to capture data.")
