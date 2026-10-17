--[[
    REMOTE LOGGER / CONSOLE (OPTIMIZED BASE SCRIPT)
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")

-- Checkcaller fallback for compatibility across executors
local checkcaller = checkcaller or function() return false end

-- ==========================================
-- BLACKLIST / IGNORE FILTER
-- Add any remote names or keywords here to hide spam
-- ==========================================
local IGNORED_REMOTES = {
    "Analytics",
    "AwayEarnings",
    "ProbeSatchel",
    "Ping",
}

-- Convert array to fast lookup table & store patterns
local function isIgnored(remoteName)
    for _, filter in ipairs(IGNORED_REMOTES) do
        if string.find(remoteName, filter) then
            return true
        end
    end
    return false
end

-- ======================
-- UI SETUP
-- ======================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RemoteLogger"
screenGui.ResetOnSpawn = false
screenGui.Parent = pg

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 440, 0, 400)
main.Position = UDim2.new(0, 20, 0.25, 0)
main.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 34)
title.Position = UDim2.new(0, 10, 0, 0)
title.BackgroundTransparency = 1
title.Text = "REMOTE LOGGER - READY"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = main

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -33, 0, 3)
closeBtn.BackgroundColor3 = Color3.fromRGB(160, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.Parent = main

Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- DRAGGING
local dragging, dragStart, startPos = false, nil, nil

title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(
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

-- CONSOLE
local console = Instance.new("TextBox")
console.Size = UDim2.new(1, -16, 1, -105)
console.Position = UDim2.new(0, 8, 0, 43)
console.BackgroundColor3 = Color3.fromRGB(10, 10, 16)
console.TextColor3 = Color3.fromRGB(210, 210, 220)
console.Font = Enum.Font.Code
console.TextSize = 12
console.Text = "REMOTE LOGGER READY\nPress START to begin logging..."
console.TextWrapped = false
console.TextEditable = false
console.TextXAlignment = Enum.TextXAlignment.Left
console.TextYAlignment = Enum.TextYAlignment.Top
console.ClearTextOnFocus = false
console.MultiLine = true
console.Parent = main

Instance.new("UICorner", console).CornerRadius = UDim.new(0, 6)

local padding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 6)
padding.PaddingRight = UDim.new(0, 6)
padding.PaddingTop = UDim.new(0, 6)
padding.Parent = console

-- ======================
-- STATE & BATCHING
-- ======================

local loggingEnabled = false
local logLines = {}
local updatePending = false

local function setStatus(text)
    pcall(function()
        if title and title.Parent then
            title.Text = "REMOTE LOGGER - " .. tostring(text)
        end
    end)
end

local function queueConsoleUpdate()
    if updatePending then return end
    updatePending = true
    
    task.defer(function()
        updatePending = false
        if console and console.Parent then
            if #logLines == 0 then
                console.Text = "LOGS CLEARED"
            else
                console.Text = table.concat(logLines, "\n")
            end
        end
    end)
end

-- BUTTONS
local function createBtn(text, x, width, color)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, width, 0, 34)
    btn.Position = UDim2.new(0, x, 1, -45)
    btn.BackgroundColor3 = color
    btn.Text = text
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.Parent = main
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    return btn
end

local startBtn = createBtn("START", 8, 98, Color3.fromRGB(40, 150, 70))
local stopBtn = createBtn("STOP", 114, 98, Color3.fromRGB(160, 70, 60))
local clearBtn = createBtn("CLEAR", 220, 98, Color3.fromRGB(110, 110, 120))
local copyBtn = createBtn("COPY", 326, 98, Color3.fromRGB(70, 100, 170))

startBtn.MouseButton1Click:Connect(function()
    loggingEnabled = true
    startBtn.Text = "STARTED"
    startBtn.BackgroundColor3 = Color3.fromRGB(30, 190, 80)
    setStatus("LOGGING")
end)

stopBtn.MouseButton1Click:Connect(function()
    loggingEnabled = false
    startBtn.Text = "START"
    startBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 70)
    setStatus("STOPPED")
end)

clearBtn.MouseButton1Click:Connect(function()
    table.clear(logLines)
    queueConsoleUpdate()
    setStatus("CLEARED")
end)

copyBtn.MouseButton1Click:Connect(function()
    local text = table.concat(logLines, "\n")
    if setclipboard then
        pcall(setclipboard, text)
        setStatus("COPIED")
    else
        setStatus("COPY UNAVAILABLE")
    end
end)

closeBtn.MouseButton1Click:Connect(function()
    loggingEnabled = false
    if screenGui then screenGui:Destroy() end
end)

-- ======================
-- VALUE FORMATTER
-- ======================

local function formatValue(value, depth, visited)
    depth = depth or 0
    visited = visited or {}

    if value == nil then return "nil" end

    local valueType = typeof(value)

    if valueType == "string" then
        return '"' .. value .. '"'
    elseif valueType == "number" or valueType == "boolean" or valueType == "EnumItem" then
        return tostring(value)
    elseif valueType == "Instance" then
        local ok, fullName = pcall(function() return value:GetFullName() end)
        return ok and ("<Instance: " .. fullName .. ">") or "<Instance>"
    end

    if valueType == "table" then
        if depth >= 5 then return "{...}" end
        if visited[value] then return "<recursive table>" end

        visited[value] = true
        local indent = string.rep("  ", depth + 1)
        local lines = {"{"}

        for key, childValue in pairs(value) do
            local keyStr = typeof(key) == "string" and ('"' .. key .. '"') or tostring(key)
            local ok, childText = pcall(formatValue, childValue, depth + 1, visited)
            table.insert(lines, indent .. "[" .. keyStr .. "] = " .. (ok and childText or "<unable to read value>"))
        end

        table.insert(lines, string.rep("  ", depth) .. "}")
        visited[value] = nil
        return table.concat(lines, "\n")
    end

    local ok, result = pcall(tostring, value)
    return ok and result or "<unknown value>"
end

-- ======================
-- HOOKMETAMETHOD
-- ======================

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()

    -- Filter non-remotes and internal script calls
    if loggingEnabled and not checkcaller() and (method == "FireServer" or method == "InvokeServer") and typeof(self) == "Instance" then
        if self:IsA("RemoteEvent") or self:IsA("RemoteFunction") then
            local args = table.pack(...)
            
            pcall(function()
                local okName, remoteName = pcall(function() return self:GetFullName() end)
                if not okName or not remoteName then remoteName = tostring(self) end

                if not isIgnored(remoteName) then
                    local entry = {}
                    table.insert(entry, "==============================")
                    table.insert(entry, method .. " -> " .. remoteName)
                    table.insert(entry, "Arguments:")

                    if args.n == 0 then
                        table.insert(entry, "  none")
                    else
                        for i = 1, args.n do
                            local okVal, formatted = pcall(formatValue, args[i])
                            table.insert(entry, "  [" .. i .. "] = " .. (okVal and formatted or "<format error>"))
                        end
                    end

                    table.insert(logLines, table.concat(entry, "\n"))

                    if #logLines > 150 then
                        table.remove(logLines, 1)
                    end

                    queueConsoleUpdate()
                end
            end)
        end
    end

    return oldNamecall(self, ...)
end)

setStatus("READY")