--[[
    Treadmill & Plot Hierarchy Scanner
    Purpose: Inspect LocalPlayer, Plots, and Treadmills in the live game environment
             to discover the exact ownership hierarchy and attribute linkages.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local myUserId = LocalPlayer and LocalPlayer.UserId or 0
local myName = LocalPlayer and LocalPlayer.Name or ""
local myDisplayName = LocalPlayer and LocalPlayer.DisplayName or ""
local myUidStr = tostring(myUserId)

local lines = {}
local function log(fmt, ...)
    local str = string.format(fmt, ...)
    table.insert(lines, str)
    print("[SCANNER] " .. str)
end

local function inspectAttributes(inst, indent)
    local attrs = inst:GetAttributes()
    local count = 0
    for k, v in pairs(attrs) do
        count = count + 1
        log("%s- attr: %s = %s (%s)", indent, tostring(k), tostring(v), typeof(v))
    end
    if count == 0 then
        log("%s- attrs: (none)", indent)
    end
end

local function inspectChildrenValues(inst, indent)
    for _, ch in ipairs(inst:GetChildren()) do
        if ch:IsA("ValueBase") then
            log("%s- %s (%s) = %s", indent, ch.Name, ch.ClassName, tostring(ch.Value))
        end
    end
end

local function runScan()
    lines = {}
    log("==================================================")
    log("     TREADMILL & PLOT DISCOVERY SCAN REPORT      ")
    log("==================================================")
    log("Time: %s", os.date("!%Y-%m-%d %H:%M:%SZ"))
    log("Player: %s | Display: %s | UserId: %d", myName, myDisplayName, myUserId)

    local char = LocalPlayer and LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then
        log("Current HRP Position: (%.1f, %.1f, %.1f)", hrp.Position.X, hrp.Position.Y, hrp.Position.Z)
    else
        log("Current HRP: (Character or HRP missing)")
    end

    -- SECTION 1: LocalPlayer Hierarchy & Attributes
    log("\n--- SECTION 1: LOCALPLAYER ATTRIBUTES & VALUE CHILDREN ---")
    inspectAttributes(LocalPlayer, "  ")
    inspectChildrenValues(LocalPlayer, "  ")

    local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
    if leaderstats then
        log("  [leaderstats]:")
        inspectChildrenValues(leaderstats, "    ")
    end

    -- SECTION 2: Plot Containers
    log("\n--- SECTION 2: WORKSPACE PLOTS SEARCH ---")
    local plotsContainer = Workspace:FindFirstChild("Plots") 
        or Workspace:FindFirstChild("Bases") 
        or Workspace:FindFirstChild("PlayerPlots")

    if not plotsContainer then
        for _, child in ipairs(Workspace:GetChildren()) do
            if string.find(string.lower(child.Name), "plot") or string.find(string.lower(child.Name), "base") then
                plotsContainer = child
                log("  Found potential plot container: Workspace.%s", child.Name)
                break
            end
        end
    else
        log("  Found primary plot container: Workspace.%s", plotsContainer.Name)
    end

    if plotsContainer then
        log("  Inspecting %d children in %s:", #plotsContainer:GetChildren(), plotsContainer.Name)
        for _, plot in ipairs(plotsContainer:GetChildren()) do
            local pPos = "no-pivot"
            if plot:IsA("Model") or plot:IsA("BasePart") then
                local cf = plot:GetPivot()
                pPos = string.format("(%.1f, %.1f, %.1f)", cf.Position.X, cf.Position.Y, cf.Position.Z)
            end
            log("  > Plot: %s (Class: %s) Pivot: %s", plot.Name, plot.ClassName, pPos)
            inspectAttributes(plot, "    ")
            inspectChildrenValues(plot, "    ")

            -- Check for signs / nameplates inside the plot
            for _, desc in ipairs(plot:GetDescendants()) do
                if desc:IsA("TextLabel") or desc:IsA("TextButton") then
                    local t = desc.Text
                    if t and t ~= "" and (string.find(t, myName) or string.find(t, myDisplayName) or string.find(t, myUidStr)) then
                        log("    * MATCHING TEXT SIGN: %s -> Text = '%s'", desc:GetFullName(), t)
                    end
                end
            end
        end
    else
        log("  No plot container found in Workspace directly.")
    end

    -- SECTION 3: Treadmill Containers
    log("\n--- SECTION 3: TREADMILL CONTAINERS ---")
    local clientTreadmills = Workspace:FindFirstChild("__ClientTreadmillRenders")
    if clientTreadmills then
        log("  Found Workspace.__ClientTreadmillRenders with %d children:", #clientTreadmills:GetChildren())
        for _, tm in ipairs(clientTreadmills:GetChildren()) do
            local tmPivot = tm:GetPivot()
            local tmPos = string.format("(%.1f, %.1f, %.1f)", tmPivot.Position.X, tmPivot.Position.Y, tmPivot.Position.Z)
            log("  > %s (Class: %s) Pivot: %s", tm.Name, tm.ClassName, tmPos)
            inspectAttributes(tm, "    ")
            inspectChildrenValues(tm, "    ")

            -- Check ProximityPrompts
            for _, prompt in ipairs(tm:GetDescendants()) do
                if prompt:IsA("ProximityPrompt") then
                    log("    * ProximityPrompt in %s: Action='%s', Object='%s', Enabled=%s", 
                        prompt.Parent.Name, prompt.ActionText, prompt.ObjectText, tostring(prompt.Enabled))
                end
            end
        end
    else
        log("  Workspace.__ClientTreadmillRenders NOT found.")
    end

    local wsTreadmills = Workspace:FindFirstChild("Treadmills")
    if wsTreadmills then
        log("  Found Workspace.Treadmills with %d children:", #wsTreadmills:GetChildren())
        for _, tm in ipairs(wsTreadmills:GetChildren()) do
            local tmPivot = tm:GetPivot()
            local tmPos = string.format("(%.1f, %.1f, %.1f)", tmPivot.Position.X, tmPivot.Position.Y, tmPivot.Position.Z)
            log("  > %s (Class: %s) Pivot: %s", tm.Name, tm.ClassName, tmPos)
            inspectAttributes(tm, "    ")
        end
    end

    -- Also deep scan any model with "treadmill" in Workspace
    log("\n--- SECTION 4: GENERAL TREADMILL SEARCH IN WORKSPACE ---")
    local genericTreadmills = {}
    for _, desc in ipairs(Workspace:GetDescendants()) do
        if string.find(string.lower(desc.Name), "treadmill") and desc:IsA("Model") then
            if desc.Parent ~= clientTreadmills and desc.Parent ~= wsTreadmills then
                table.insert(genericTreadmills, desc)
            end
        end
    end
    log("  Found %d additional treadmill models across Workspace:", #genericTreadmills)
    for i = 1, math.min(#genericTreadmills, 10) do
        local tm = genericTreadmills[i]
        local cf = tm:GetPivot()
        log("  > %s | FullPath: %s | Pivot: (%.1f, %.1f, %.1f)", 
            tm.Name, tm:GetFullName(), cf.Position.X, cf.Position.Y, cf.Position.Z)
        inspectAttributes(tm, "    ")
    end

    -- SECTION 5: ReplicatedStorage Treadmill Remotes
    log("\n--- SECTION 5: REPLICATEDSTORAGE TREADMILL REMOTES ---")
    local remotes = {}
    for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
        if string.find(string.lower(desc.Name), "treadmill") and (desc:IsA("RemoteEvent") or desc:IsA("RemoteFunction")) then
            table.insert(remotes, string.format("%s (%s)", desc:GetFullName(), desc.ClassName))
        end
    end
    for _, r in ipairs(remotes) do
        log("  - %s", r)
    end

    -- SECTION 6: Cross-Correlation / Distances
    log("\n--- SECTION 6: CORRELATION SUMMARY ---")
    if clientTreadmills and plotsContainer then
        log("  Plot-to-TreadmillDistance Matrix:")
        for _, plot in ipairs(plotsContainer:GetChildren()) do
            local plotPivot = plot:GetPivot().Position
            for _, tm in ipairs(clientTreadmills:GetChildren()) do
                local tmPivot = tm:GetPivot().Position
                local dist = (plotPivot - tmPivot).Magnitude
                if dist < 60 then
                    log("    * Plot '%s' <-> '%s' Distance: %.1f studs (CLOSE MATCH)", plot.Name, tm.Name, dist)
                end
            end
        end
    end

    log("==================================================")
    log("                  SCAN COMPLETE                   ")
    log("==================================================")

    return table.concat(lines, "\n")
end

-- ==========================================
-- SCANNER UI
-- ==========================================
local function createUI()
    local existing = CoreGui:FindFirstChild("TreadmillPlotScannerUI")
    if existing then existing:Destroy() end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TreadmillPlotScannerUI"
    screenGui.ResetOnSpawn = false
    screenGui.DisplayOrder = 9999

    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "MainFrame"
    mainFrame.Size = UDim2.new(0, 560, 0, 480)
    mainFrame.Position = UDim2.new(0.5, -280, 0.5, -240)
    mainFrame.BackgroundColor3 = Color3.fromRGB(24, 25, 32)
    mainFrame.BorderSizePixel = 0
    mainFrame.Active = true
    mainFrame.Draggable = true
    mainFrame.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = mainFrame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(60, 65, 85)
    stroke.Thickness = 1.5
    stroke.Parent = mainFrame

    -- Title Bar
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -70, 0, 40)
    title.Position = UDim2.new(0, 15, 0, 0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "Treadmill & Plot Hierarchy Scanner"
    title.Parent = mainFrame

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 30, 0, 30)
    closeBtn.Position = UDim2.new(1, -38, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(40, 42, 54)
    closeBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 14
    closeBtn.Text = "X"
    local cCorner = Instance.new("UICorner")
    cCorner.CornerRadius = UDim.new(0, 6)
    cCorner.Parent = closeBtn
    closeBtn.MouseButton1Click:Connect(function()
        screenGui:Destroy()
    end)
    closeBtn.Parent = mainFrame

    -- Text Display Box
    local scrollFrame = Instance.new("ScrollingFrame")
    scrollFrame.Size = UDim2.new(1, -30, 1, -100)
    scrollFrame.Position = UDim2.new(0, 15, 0, 45)
    scrollFrame.BackgroundColor3 = Color3.fromRGB(15, 16, 20)
    scrollFrame.BorderSizePixel = 0
    scrollFrame.ScrollBarThickness = 6
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    local sfCorner = Instance.new("UICorner")
    sfCorner.CornerRadius = UDim.new(0, 6)
    sfCorner.Parent = scrollFrame
    scrollFrame.Parent = mainFrame

    local textBox = Instance.new("TextBox")
    textBox.Size = UDim2.new(1, -20, 0, 0)
    textBox.Position = UDim2.new(0, 10, 0, 10)
    textBox.BackgroundTransparency = 1
    textBox.MultiLine = true
    textBox.ClearTextOnFocus = false
    textBox.TextEditable = false
    textBox.Font = Enum.Font.Code
    textBox.TextSize = 12
    textBox.TextColor3 = Color3.fromRGB(180, 220, 180)
    textBox.TextXAlignment = Enum.TextXAlignment.Left
    textBox.TextYAlignment = Enum.TextYAlignment.Top
    textBox.AutomaticSize = Enum.AutomaticSize.Y
    textBox.Text = "Click 'RUN SCAN' to inspect the hierarchy..."
    textBox.Parent = scrollFrame

    -- Action Buttons Bar
    local buttonBar = Instance.new("Frame")
    buttonBar.Size = UDim2.new(1, -30, 0, 40)
    buttonBar.Position = UDim2.new(0, 15, 1, -48)
    buttonBar.BackgroundTransparency = 1
    buttonBar.Parent = mainFrame

    local function makeButton(name, text, xPos, color, onClick)
        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Size = UDim2.new(0, 110, 0, 34)
        btn.Position = UDim2.new(0, xPos, 0, 0)
        btn.BackgroundColor3 = color
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.Text = text
        local bCorner = Instance.new("UICorner")
        bCorner.CornerRadius = UDim.new(0, 6)
        bCorner.Parent = btn
        btn.MouseButton1Click:Connect(onClick)
        btn.Parent = buttonBar
        return btn
    end

    local scanReportText = ""

    local runBtn = makeButton("RunScanBtn", "RUN SCAN", 0, Color3.fromRGB(50, 120, 220), function()
        textBox.Text = "Scanning hierarchy..."
        task.defer(function()
            scanReportText = runScan()
            textBox.Text = scanReportText
        end)
    end)

    local copyBtn = makeButton("CopyBtn", "COPY TEXT", 120, Color3.fromRGB(40, 150, 90), function()
        if scanReportText == "" then
            scanReportText = textBox.Text
        end
        if setclipboard then
            pcall(function() setclipboard(scanReportText) end)
            copyBtn.Text = "COPIED!"
            task.delay(1.5, function() copyBtn.Text = "COPY TEXT" end)
        else
            copyBtn.Text = "NO CLIPBOARD"
            task.delay(1.5, function() copyBtn.Text = "COPY TEXT" end)
        end
    end)

    local saveBtn = makeButton("SaveBtn", "SAVE FILE", 240, Color3.fromRGB(130, 80, 180), function()
        if scanReportText == "" then
            scanReportText = textBox.Text
        end
        if writefile then
            local fn = "treadmill-plot-scan.log"
            pcall(function() writefile(fn, scanReportText) end)
            saveBtn.Text = "SAVED!"
            task.delay(1.5, function() saveBtn.Text = "SAVE FILE" end)
        else
            saveBtn.Text = "NO WRITEFILE"
            task.delay(1.5, function() saveBtn.Text = "SAVE FILE" end)
        end
    end)

    -- Auto run scan on startup
    task.defer(function()
        scanReportText = runScan()
        textBox.Text = scanReportText
    end)

    pcall(function()
        screenGui.Parent = CoreGui
    end)
    if not screenGui.Parent then
        screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end
end

createUI()
