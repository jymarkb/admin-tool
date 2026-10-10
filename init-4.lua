--[[
    Egg Go-To UI v4 — Snapshot-Powered (Biome Dropdown + Carry)
    ----------------------------------------
    Changes from v3:
      - Reads eggs via RF/EggWorld/AskFieldEggSnapshot (authoritative server data)
        instead of scanning AreaEggSlotsClient geometry.
        This gives us: AssetCategory (species), Mutations, AssetScale, AreaId, Uid.
      - Passively listens to RE/EggWorld/FieldEggRaritiesShown to detect Secret/rare
        eggs and highlights them in the list.
      - Each card shows: species name, slot, mutation badge, scale, rarity badge.
      - Rarity detection: only from FieldEggRaritiesShown event payloads (RarityId field).
        Scale is cosmetic only — not treated as rarity evidence.
      - "Go To + Carry" logic unchanged from v3.
]]

local Players          = game:GetService("Players")
local Workspace        = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- ====================== CONFIG ======================

local BIOMES = {
	"Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano",
	"Abyss Ocean", "Prehistoric", "Cosmic", "Cherry Blossom",
	"Titan Temple", "Light Dark", "Enchanted Forest"
}

-- Safe zone to return to after picking up an egg.
-- Change this to match your nest / drop-off point in the game.
local SAFE_ZONE = Vector3.new(536.731, 70, -368.698)

-- Mutation badge colors
local MUTATION_COLORS = {
	["Golden"]  = Color3.fromRGB(220, 180, 30),
	["Rainbow"] = Color3.fromRGB(180, 80, 220),
	["Silver"]  = Color3.fromRGB(160, 180, 210),
}
local MUTATION_DEFAULT_COLOR = Color3.fromRGB(100, 200, 255)

-- Rarity badge colors (from FieldEggRaritiesShown RarityId)
local RARITY_COLORS = {
	["Secret"]    = Color3.fromRGB(220, 50,  50),
	["Legendary"] = Color3.fromRGB(230, 140, 20),
	["Epic"]      = Color3.fromRGB(140, 60,  220),
	["Rare"]      = Color3.fromRGB(50,  120, 220),
}
local RARITY_DEFAULT_COLOR = Color3.fromRGB(200, 200, 200)

-- ====================== RARITY MONITOR ======================
-- Passively listens for FieldEggRaritiesShown.
-- From the scan: rarity data only exists here, not in snapshot records
-- or static models. We store EggUid -> RarityId.

local rarityByUid = {}  -- [uid] = "Secret" / "Legendary" / etc.

local function startRarityMonitor()
	local ok, remote = pcall(function()
		return ReplicatedStorage.Packages.Networking["RE/EggWorld/FieldEggRaritiesShown"]
	end)

	if not ok or not remote then
		return
	end

	remote.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then return end

		local spawns = payload.RareSpawns
		if typeof(spawns) ~= "table" then return end

		for _, entry in pairs(spawns) do
			if typeof(entry) == "table" and entry.EggUid and entry.RarityId then
				rarityByUid[tostring(entry.EggUid)] = tostring(entry.RarityId)
			end
		end
	end)
end

startRarityMonitor()

-- ====================== SNAPSHOT ======================
-- Uses the same RF the scanner used: AskFieldEggSnapshot.
-- Returns a list of records filtered to the selected biome.

local function fetchSnapshotRecords(biome)
	local ok, remote = pcall(function()
		return ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggSnapshot"]
	end)

	if not ok or not remote then
		return nil, "RF not found"
	end

	local callOk, result = pcall(function()
		return remote:InvokeServer()
	end)

	if not callOk then
		return nil, tostring(result)
	end

	if typeof(result) ~= "table" then
		return nil, "Unexpected return type: " .. typeof(result)
	end

	local records = result.Records
	if typeof(records) ~= "table" then
		return nil, "No Records field in snapshot"
	end

	local filtered = {}
	for _, record in pairs(records) do
		if typeof(record) == "table" and tostring(record.AreaId) == biome then
			table.insert(filtered, record)
		end
	end

	-- Sort by NestId (Slot_001 → Slot_005)
	table.sort(filtered, function(a, b)
		return tostring(a.NestId) < tostring(b.NestId)
	end)

	return filtered, nil
end

-- ====================== CARRY ======================

local function getCarryRemote()
	local ok, remote = pcall(function()
		return ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggCarry"]
	end)
	return ok and remote or nil
end

-- Returns true on success, false on failure.
local function carryEgg(uid, statusLabel)
	statusLabel.Text = "Sending carry request..."
	statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

	local remote = getCarryRemote()
	if not remote then
		statusLabel.Text = "Carry remote not found"
		statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
		return false
	end

	local success, err = pcall(function()
		remote:InvokeServer({ Uid = uid })
	end)

	if success then
		statusLabel.Text = "Carry request sent!"
		statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
		return true
	else
		statusLabel.Text = "Carry failed: " .. tostring(err)
		statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
		return false
	end
end

-- ====================== MOVEMENT ======================

local walkToken = 0

-- Walks the player to `destination`. Stops when within `arriveRadius` studs.
-- Respects walkToken so a new Get press cancels this walk.
--
-- Two-phase movement:
--   FAR  (>SLOW_ZONE studs): humanoid:MoveTo() for efficient long-range travel.
--   CLOSE (≤SLOW_ZONE studs): humanoid:Move(direction) instead — this has NO
--     committed target, so Move(zero) stops the character instantly with no
--     overshoot. MoveTo() keeps the character walking to the exact point even
--     after we stop calling it, which is what caused the pass-over.
--
-- Distance is measured XZ-only (horizontal plane). Egg BoundsCFrame Y and the
-- character's HumanoidRootPart Y differ by 1-3 studs, inflating 3D magnitude
-- and causing late arrival detection.
local SLOW_ZONE      = 50  -- studs: switch from MoveTo to Move() within this range
local TELEPORT_ZONE  = 50  -- studs: teleport directly when within this range (test)

local function walkTo(destination, arriveRadius, myToken, onArrived)
	task.spawn(function()
		while walkToken == myToken do
			local character = LocalPlayer.Character
			if not character then task.wait(0.05) continue end

			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root     = character:FindFirstChild("HumanoidRootPart")
			if not humanoid or not root then task.wait(0.05) continue end

			local rootPos = root.Position

			-- XZ-only distance: ignore vertical difference between egg and character
			local xzDist = Vector3.new(
				destination.X - rootPos.X,
				0,
				destination.Z - rootPos.Z
			).Magnitude

			-- Arrived: stop immediately and fire callback
			if xzDist <= arriveRadius then
				humanoid:Move(Vector3.zero)
				humanoid.WalkToPoint = rootPos  -- clear any pending MoveTo target
				if onArrived then onArrived() end
				return
			end

			if xzDist <= TELEPORT_ZONE then
				-- Within teleport zone: snap directly to destination.
				-- Preserve the character's current Y to avoid going underground.
				humanoid:Move(Vector3.zero)
				root.CFrame = CFrame.new(destination.X, rootPos.Y, destination.Z)
				-- One tick so physics settles, then arrival fires on next loop pass
				task.wait(0.05)
			elseif xzDist > SLOW_ZONE then
				-- Far range: MoveTo for efficient travel, poll slowly
				humanoid:MoveTo(destination)
				task.wait(0.2)
			else
				-- Close range: Move(dir) — no committed target, stops instantly
				local dir = Vector3.new(
					destination.X - rootPos.X,
					0,
					destination.Z - rootPos.Z
				).Unit
				humanoid:Move(dir, false)
				task.wait(0.05)  -- fast poll so we catch arrival precisely
			end
		end
	end)
end

local function returnToSafeZone(myToken, statusLabel)
	statusLabel.Text = "Returning to safe zone..."
	statusLabel.TextColor3 = Color3.fromRGB(100, 180, 255)

	walkTo(SAFE_ZONE, 6, myToken, function()
		if walkToken == myToken then
			statusLabel.Text = "Safe zone reached ✓"
			statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
		end
	end)
end

-- ====================== CARRY CONFIRMATION ======================
-- Waits up to `timeout` seconds for the server to confirm pickup.
-- Confirmation sources (first to fire wins):
--   1. RE/EggWorld/FieldEggGone or FieldEggCarry event containing our uid
--   2. The egg's UUID container disappearing from AreaEggSlotsClient

local function confirmCarry(uid, timeout)
	local confirmed = false
	local conns = {}

	for _, path in ipairs({ "RE/EggWorld/FieldEggGone", "RE/EggWorld/FieldEggCarry" }) do
		local ok, remote = pcall(function()
			return ReplicatedStorage.Packages.Networking[path]
		end)
		if ok and remote and remote:IsA("RemoteEvent") then
			table.insert(conns, remote.OnClientEvent:Connect(function(payload)
				if confirmed then return end
				if typeof(payload) == "table" then
					local payloadUid = tostring(payload.Uid or payload.EggUid or "")
					if payloadUid == uid then
						confirmed = true
					end
				end
			end))
		end
	end

	local elapsed = 0
	while not confirmed and elapsed < timeout do
		-- Also watch for the UUID container vanishing from AreaEggSlotsClient
		local area = Workspace:FindFirstChild("AreaEggSlotsClient")
		if area and not area:FindFirstChild(uid) then
			confirmed = true
			break
		end
		task.wait(0.15)
		elapsed += 0.15
	end

	for _, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
	end

	return confirmed
end

-- ====================== GET EGG (with retry) ======================

local MAX_CARRY_RETRIES = 3

local function getEgg(position, uid, statusLabel)
	if typeof(position) ~= "Vector3" then return end

	walkToken = walkToken + 1
	local myToken = walkToken

	-- Recursive attempt function — retries up to MAX_CARRY_RETRIES times.
	local function attempt(n)
		if walkToken ~= myToken then return end  -- cancelled by a newer Get press

		statusLabel.Text = n == 1
			and "Going to egg..."
			or  string.format("Retry %d/%d — going to egg...", n, MAX_CARRY_RETRIES)
		statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

		walkTo(position, 6, myToken, function()
			if walkToken ~= myToken then return end

			-- We just stopped at the egg — no drift re-check needed.
			-- The "moved too far" error was a false positive from checking
			-- after a 0.1s settle; removing it fixes the issue.
			statusLabel.Text = "Picking up egg..."
			statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

			local carried = carryEgg(uid, statusLabel)

			if not carried then
				-- RF itself errored — retry walk+carry
				if n < MAX_CARRY_RETRIES then
					task.wait(0.5)
					attempt(n + 1)
				else
					statusLabel.Text = string.format("Carry RF failed after %d tries", MAX_CARRY_RETRIES)
					statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
				end
				return
			end

			-- RF succeeded — wait for server confirmation before returning
			statusLabel.Text = "Confirming pickup..."
			statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

			local confirmed = confirmCarry(uid, 2.5)

			if confirmed then
				task.wait(0.2)
				returnToSafeZone(myToken, statusLabel)
			else
				-- Server didn't acknowledge — retry
				if n < MAX_CARRY_RETRIES then
					statusLabel.Text = string.format(
						"Not confirmed — retry %d/%d...", n + 1, MAX_CARRY_RETRIES)
					statusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
					task.wait(0.5)
					attempt(n + 1)
				else
					statusLabel.Text = string.format(
						"Pickup not confirmed after %d tries", MAX_CARRY_RETRIES)
					statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
				end
			end
		end)
	end

	attempt(1)
end

-- ====================== HELPERS ======================

local function extractPosition(record)
	-- BoundsCFrame is the center of the egg bounding box (used by scanner)
	local cf = record.BoundsCFrame
	if typeof(cf) == "CFrame" then
		return cf.Position
	end
	-- Fallback: BottomCFrame
	local bf = record.BottomCFrame
	if typeof(bf) == "CFrame" then
		return bf.Position
	end
	return nil
end

local function mutationLabel(record)
	if typeof(record.Mutations) ~= "table" then return nil end
	local names = {}
	for _, name in pairs(record.Mutations) do
		if typeof(name) == "string" then
			table.insert(names, name)
		end
	end
	if #names == 0 then return nil end
	table.sort(names)
	return table.concat(names, "+")
end

-- ====================== UI SETUP ======================

local oldGui = PlayerGui:FindFirstChild("EggGoToUI_v4")
if oldGui then oldGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggGoToUI_v4"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 400, 0, 500)
main.Position = UDim2.new(0.5, -200, 0.5, -250)
main.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
main.BorderSizePixel = 0
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(70, 110, 180)
stroke.Thickness = 1.5

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
titleBar.BorderSizePixel = 0
titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

local titleFix = Instance.new("Frame")
titleFix.Size = UDim2.new(1, 0, 0, 12)
titleFix.Position = UDim2.new(0, 0, 1, -12)
titleFix.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
titleFix.BorderSizePixel = 0
titleFix.Parent = titleBar

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Text = "Egg Go-To v4 (Snapshot)"
title.TextColor3 = Color3.fromRGB(220, 230, 255)
title.TextSize = 15
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 30, 0, 24)
closeBtn.Position = UDim2.new(1, -38, 0.5, -12)
closeBtn.BackgroundColor3 = Color3.fromRGB(170, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 14
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- Biome dropdown
local biomeLabel_ui = Instance.new("TextLabel")
biomeLabel_ui.Size = UDim2.new(0, 60, 0, 26)
biomeLabel_ui.Position = UDim2.new(0, 12, 0, 48)
biomeLabel_ui.BackgroundTransparency = 1
biomeLabel_ui.Text = "Biome:"
biomeLabel_ui.TextColor3 = Color3.fromRGB(180, 195, 220)
biomeLabel_ui.TextSize = 13
biomeLabel_ui.Font = Enum.Font.Gotham
biomeLabel_ui.TextXAlignment = Enum.TextXAlignment.Left
biomeLabel_ui.Parent = main

local selectedBiome = "Forest"

local dropdownBtn = Instance.new("TextButton")
dropdownBtn.Size = UDim2.new(0, 190, 0, 28)
dropdownBtn.Position = UDim2.new(0, 70, 0, 47)
dropdownBtn.BackgroundColor3 = Color3.fromRGB(40, 48, 65)
dropdownBtn.Text = "Forest ▼"
dropdownBtn.TextColor3 = Color3.new(1, 1, 1)
dropdownBtn.TextSize = 13
dropdownBtn.Font = Enum.Font.GothamBold
dropdownBtn.Parent = main
Instance.new("UICorner", dropdownBtn).CornerRadius = UDim.new(0, 6)

local dropdownList = Instance.new("Frame")
dropdownList.Size = UDim2.new(0, 190, 0, 0)
dropdownList.Position = UDim2.new(0, 70, 0, 77)
dropdownList.BackgroundColor3 = Color3.fromRGB(30, 36, 50)
dropdownList.BorderSizePixel = 0
dropdownList.ClipsDescendants = true
dropdownList.Visible = false
dropdownList.ZIndex = 10
dropdownList.Parent = main
Instance.new("UICorner", dropdownList).CornerRadius = UDim.new(0, 6)

local dropLayout = Instance.new("UIListLayout")
dropLayout.Parent = dropdownList

local dropdownOpen = false
local function toggleDropdown()
	dropdownOpen = not dropdownOpen
	dropdownList.Visible = dropdownOpen
	if dropdownOpen then
		dropdownList.Size = UDim2.new(0, 190, 0, #BIOMES * 28)
		dropdownBtn.Text = selectedBiome .. " ▲"
	else
		dropdownList.Size = UDim2.new(0, 190, 0, 0)
		dropdownBtn.Text = selectedBiome .. " ▼"
	end
end
dropdownBtn.MouseButton1Click:Connect(toggleDropdown)

-- Refresh button
local refreshBtn = Instance.new("TextButton")
refreshBtn.Size = UDim2.new(0, 88, 0, 28)
refreshBtn.Position = UDim2.new(0, 274, 0, 47)
refreshBtn.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
refreshBtn.Text = "Refresh"
refreshBtn.TextColor3 = Color3.new(1, 1, 1)
refreshBtn.TextSize = 13
refreshBtn.Font = Enum.Font.GothamBold
refreshBtn.Parent = main
Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 6)

-- Status
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 0, 22)
statusLabel.Position = UDim2.new(0, 12, 0, 84)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Select a biome and click Refresh"
statusLabel.TextColor3 = Color3.fromRGB(180, 195, 220)
statusLabel.TextSize = 12
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = main

-- Egg list
local listFrame = Instance.new("ScrollingFrame")
listFrame.Size = UDim2.new(1, -24, 1, -120)
listFrame.Position = UDim2.new(0, 12, 0, 110)
listFrame.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
listFrame.BorderSizePixel = 0
listFrame.ScrollBarThickness = 6
listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
listFrame.Parent = main
Instance.new("UICorner", listFrame).CornerRadius = UDim.new(0, 8)

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.Parent = listFrame

-- Drag
local dragging, dragStart, startPos
titleBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = true
		dragStart = input.Position
		startPos = main.Position
	end
end)
titleBar.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = input.Position - dragStart
		main.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)
closeBtn.MouseButton1Click:Connect(function()
	screenGui:Destroy()
end)

-- ====================== EGG CARD ======================
-- Card height: 76px
-- Shows: species, slot, position, scale, mutation badge, rarity badge, Get button.

local CARD_HEIGHT = 76

local function makeBadge(parent, text, color, xOffset)
	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.new(0, 0, 0, 16)
	badge.AutomaticSize = Enum.AutomaticSize.X
	badge.Position = UDim2.new(0, xOffset, 0, 54)
	badge.BackgroundColor3 = color
	badge.BackgroundTransparency = 0
	badge.Text = " " .. text .. " "
	badge.TextColor3 = Color3.new(1, 1, 1)
	badge.TextSize = 10
	badge.Font = Enum.Font.GothamBold
	badge.TextXAlignment = Enum.TextXAlignment.Center
	badge.Parent = parent
	Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 4)
	return badge
end

local function createEggCard(index, record)
	local uid      = tostring(record.Uid or "")
	local species  = tostring(record.AssetCategory or "Unknown")
	local slot     = tostring(record.NestId or "?")
	local scale    = record.AssetScale
	local position = extractPosition(record)
	local mutation = mutationLabel(record)
	local rarity   = rarityByUid[uid]  -- nil if not rare

	-- Card background: highlight if rare
	local bgColor = Color3.fromRGB(28, 32, 42)
	if rarity then
		bgColor = Color3.fromRGB(50, 20, 20)  -- dark red tint for rare eggs
	end

	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, -12, 0, CARD_HEIGHT)
	card.BackgroundColor3 = bgColor
	card.BorderSizePixel = 0
	card.Parent = listFrame
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)

	-- Rarity left-edge accent stripe
	if rarity then
		local stripe = Instance.new("Frame")
		stripe.Size = UDim2.new(0, 4, 1, 0)
		stripe.Position = UDim2.new(0, 0, 0, 0)
		stripe.BackgroundColor3 = RARITY_COLORS[rarity] or RARITY_DEFAULT_COLOR
		stripe.BorderSizePixel = 0
		stripe.Parent = card
		Instance.new("UICorner", stripe).CornerRadius = UDim.new(0, 4)
	end

	-- #index  Species name
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -96, 0, 20)
	nameLabel.Position = UDim2.new(0, 10, 0, 6)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = string.format("#%d  %s", index, species)
	nameLabel.TextColor3 = rarity and Color3.fromRGB(255, 200, 200) or Color3.fromRGB(220, 230, 255)
	nameLabel.TextSize = 13
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = card

	-- Slot + scale
	local scaleText = scale and string.format("  ×%.2f", scale) or ""
	local infoLabel = Instance.new("TextLabel")
	infoLabel.Size = UDim2.new(1, -96, 0, 16)
	infoLabel.Position = UDim2.new(0, 10, 0, 26)
	infoLabel.BackgroundTransparency = 1
	infoLabel.Text = slot .. scaleText
	infoLabel.TextColor3 = Color3.fromRGB(150, 165, 190)
	infoLabel.TextSize = 11
	infoLabel.Font = Enum.Font.Code
	infoLabel.TextXAlignment = Enum.TextXAlignment.Left
	infoLabel.Parent = card

	-- Position
	local posLabel = Instance.new("TextLabel")
	posLabel.Size = UDim2.new(1, -96, 0, 14)
	posLabel.Position = UDim2.new(0, 10, 0, 42)
	posLabel.BackgroundTransparency = 1
	posLabel.Text = position
		and string.format("(%.0f, %.0f, %.0f)", position.X, position.Y, position.Z)
		or  "pos unknown"
	posLabel.TextColor3 = Color3.fromRGB(120, 135, 160)
	posLabel.TextSize = 10
	posLabel.Font = Enum.Font.Code
	posLabel.TextXAlignment = Enum.TextXAlignment.Left
	posLabel.Parent = card

	-- Mutation badge (bottom-left)
	local badgeOffsetX = 10
	if mutation then
		local mutColor = MUTATION_COLORS[mutation] or MUTATION_DEFAULT_COLOR
		local mb = makeBadge(card, mutation, mutColor, badgeOffsetX)
		-- advance offset past the badge (approximate: ~8px per char + margins)
		badgeOffsetX = badgeOffsetX + #mutation * 7 + 18
		_ = mb  -- suppress unused warning
	end

	-- Rarity badge
	if rarity then
		makeBadge(card, rarity, RARITY_COLORS[rarity] or RARITY_DEFAULT_COLOR, badgeOffsetX)
	end

	-- Get button
	local getBtn = Instance.new("TextButton")
	getBtn.Size = UDim2.new(0, 70, 0, 34)
	getBtn.Position = UDim2.new(1, -82, 0.5, -17)
	getBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 80)
	getBtn.Text = "Get"
	getBtn.TextColor3 = Color3.new(1, 1, 1)
	getBtn.TextSize = 13
	getBtn.Font = Enum.Font.GothamBold
	getBtn.Parent = card
	Instance.new("UICorner", getBtn).CornerRadius = UDim.new(0, 6)

	getBtn.MouseButton1Click:Connect(function()
		if position then
			getEgg(position, uid, statusLabel)
		else
			statusLabel.Text = "No position for this egg"
			statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
		end
	end)
end

-- ====================== SCAN ======================

local function clearList()
	for _, child in ipairs(listFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
end

local function scanEggs()
	clearList()
	statusLabel.Text = "Fetching snapshot for " .. selectedBiome .. "..."
	statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

	task.spawn(function()
		local records, err = fetchSnapshotRecords(selectedBiome)

		if not records then
			statusLabel.Text = "Error: " .. tostring(err)
			statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
			return
		end

		if #records == 0 then
			statusLabel.Text = "No eggs found in " .. selectedBiome
			statusLabel.TextColor3 = Color3.fromRGB(255, 160, 100)
			return
		end

		for i, record in ipairs(records) do
			createEggCard(i, record)
		end

		listFrame.CanvasSize = UDim2.new(0, 0, 0, #records * (CARD_HEIGHT + 6))

		-- Count mutations and rarities for summary line
		local mutCount    = 0
		local rarityCount = 0
		for _, record in ipairs(records) do
			if mutationLabel(record) then mutCount += 1 end
			if rarityByUid[tostring(record.Uid or "")] then rarityCount += 1 end
		end

		local summary = string.format(
			"%s: %d egg(s)",
			selectedBiome, #records
		)
		if mutCount > 0 then
			summary = summary .. string.format(" | %d mutated", mutCount)
		end
		if rarityCount > 0 then
			summary = summary .. string.format(" | ⚠ %d RARE", rarityCount)
		end

		statusLabel.Text = summary
		statusLabel.TextColor3 = rarityCount > 0
			and Color3.fromRGB(255, 120, 120)
			or  Color3.fromRGB(120, 255, 150)
	end)
end

-- ====================== DROPDOWN ITEMS ======================

for _, biome in ipairs(BIOMES) do
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 28)
	btn.BackgroundColor3 = Color3.fromRGB(40, 48, 65)
	btn.Text = biome
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextSize = 13
	btn.Font = Enum.Font.Gotham
	btn.Parent = dropdownList

	btn.MouseButton1Click:Connect(function()
		selectedBiome = biome
		dropdownBtn.Text = selectedBiome .. " ▼"
		dropdownOpen = false
		dropdownList.Visible = false
		dropdownList.Size = UDim2.new(0, 190, 0, 0)
		scanEggs()
	end)
end

refreshBtn.MouseButton1Click:Connect(scanEggs)

-- Auto scan on load
task.defer(scanEggs)
