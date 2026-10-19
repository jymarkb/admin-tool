--[[
    Egg Go-To UI v11 (Clean Modular UI Scaffold)
    ===========================================================================================
    Phase 1: Pure UI Skeleton
    - Minimal, clean UI containing exactly 1 sidebar button ("Eggs") and 1 active panel.
    - Zero legacy logic / background loops to ensure maximum performance and clean slate.
    - Draggable menu toggle button and draggable main window.
    - Fully managed connection tracking and safe cleanup (_G.EggGoToUI_Cleanup).
]]

local ok, err = pcall(function()

-- Terminate any previous running instance of this script
if _G.EggGoToUI_Cleanup then
    pcall(_G.EggGoToUI_Cleanup)
end
_G.EggGoToUI_Stop = false

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local t0 = os.clock()
    while not LocalPlayer and (os.clock() - t0 < 3) do
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    end
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

local function getSafeUiParent()
    if typeof(gethui) == "function" then
        local okHui, h = pcall(gethui)
        if okHui and h then return h end
    end
    local okCore, core = pcall(function() return game:GetService("CoreGui") end)
    if okCore and core then
        local okTest = pcall(function() local f = Instance.new("Folder", core); f:Destroy() end)
        if okTest then return core end
    end
    return (LocalPlayer and (LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5))) or game:GetService("CoreGui")
end

local PlayerGui = getSafeUiParent()

-- Connection management
local connections = {}
local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

local function disconnectAll()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)
end

-- ============================================================================
-- 1. BIOME & EGG CATALOG TAXONOMY (Phase 1, Step 1.1)
-- ============================================================================

local RARITY_COLORS = {
    ["Common"]    = Color3.fromRGB(170, 170, 170),
    ["Uncommon"]  = Color3.fromRGB(90,  200, 100),
    ["Rare"]      = Color3.fromRGB(50,  120, 220),
    ["Epic"]      = Color3.fromRGB(140, 60,  220),
    ["Legendary"] = Color3.fromRGB(230, 140, 20),
    ["Mythic"]    = Color3.fromRGB(230, 70,  130),
    ["Cosmic"]    = Color3.fromRGB(70,  170, 255),
    ["Secret"]    = Color3.fromRGB(220, 50,  50),
    ["Eternal"]   = Color3.fromRGB(180, 90,  255),
    ["Divine"]    = Color3.fromRGB(255, 190, 70),
}

local RARITY_RANK = {
    ["Common"] = 1, ["Uncommon"] = 2, ["Rare"] = 3, ["Epic"] = 4, ["Legendary"] = 5,
    ["Mythic"] = 6, ["Cosmic"] = 7, ["Secret"] = 8, ["Eternal"] = 9, ["Divine"] = 10,
}

-- 13 Canonical World Biomes (Structured hierarchy for easy tracking and manual updates)
-- Comprehensive Biome & Egg Catalog Taxonomy (Ground Truth + Server Discovered Assets)
local BIOME_EGG_CATALOG = {
    {
        Biome = "Forest",
        EggNames = { "Egg", "Forest Egg" },
        Species = {
            { Name = "Chicken", Rarity = "Common" },
            { Name = "Dog", Rarity = "Common" },
            { Name = "Bird", Rarity = "Uncommon" },
            { Name = "Burrowing Owl", Rarity = "Rare", Aliases = { "Owl" } },
            { Name = "Raccoon", Rarity = "Rare" },
            { Name = "Fox", Rarity = "Epic", Aliases = { "Mire Fox" } },
            { Name = "Bear", Rarity = "Epic" },
            { Name = "Brr Brr Patapim", Rarity = "Legendary" },
        }
    },
    {
        Biome = "Lake",
        EggNames = { "Lake Egg" },
        Species = {
            { Name = "Frog", Rarity = "Common" },
            { Name = "Duckling", Rarity = "Common" },
            { Name = "Catfish", Rarity = "Uncommon" },
            { Name = "Turtle", Rarity = "Rare" },
            { Name = "Trulimero Trulicina", Rarity = "Epic" },
            { Name = "Swan", Rarity = "Epic" },
            { Name = "Axolotl", Rarity = "Legendary", Aliases = { "Dream Axolotl" } },
            { Name = "Leviathan", Rarity = "Cosmic" },
        }
    },
    {
        Biome = "Desert",
        EggNames = { "Desert Egg" },
        Species = {
            { Name = "Jerboa", Rarity = "Common" },
            { Name = "Fennec", Rarity = "Uncommon", Aliases = { "FennecFox" } },
            { Name = "Camel", Rarity = "Rare" },
            { Name = "Tob Tobi Tob Tob", Rarity = "Epic", Aliases = { "Tob Tobi", "TobTobi" } },
            { Name = "Snake", Rarity = "Legendary", Aliases = { "Rattlesnake" } },
            { Name = "Sand Spider", Rarity = "Mythic" },
            { Name = "Scorpion", Rarity = "Mythic", Aliases = { "DeathstalkerScorpion" } },
            { Name = "Royal Sphinx", Rarity = "Cosmic" },
        }
    },
    {
        Biome = "Jungle",
        EggNames = { "Jungle Egg" },
        Species = {
            { Name = "Chimpanzee", Rarity = "Rare" },
            { Name = "Toucan", Rarity = "Rare" },
            { Name = "Crocodile", Rarity = "Epic" },
            { Name = "Gorilla", Rarity = "Legendary" },
            { Name = "Orangutini Ananassini", Rarity = "Legendary" },
            { Name = "Spider", Rarity = "Mythic" },
            { Name = "Tiger", Rarity = "Mythic" },
            { Name = "King Snake", Rarity = "Secret", Aliases = { "Warden" } },
        }
    },
    {
        Biome = "Snow",
        EggNames = { "Snow Egg" },
        Species = {
            { Name = "Penguin", Rarity = "Rare" },
            { Name = "Walrus", Rarity = "Epic" },
            { Name = "Polar Bear", Rarity = "Legendary" },
            { Name = "Sabertooth Tiger", Rarity = "Mythic", Aliases = { "Sabertooth" } },
            { Name = "Mammoth", Rarity = "Mythic" },
            { Name = "King Mammoth", Rarity = "Cosmic", Aliases = { "Colossal Mammoth" } },
            { Name = "Yeti", Rarity = "Secret" },
            { Name = "Ice Dragon", Rarity = "Eternal" },
        }
    },
    {
        Biome = "Volcano",
        EggNames = { "Volcano Egg", "Lava Egg" },
        Species = {
            { Name = "Lava Gecko", Rarity = "Rare", Aliases = { "Ash Gecko" } },
            { Name = "Lava Frog", Rarity = "Epic", Aliases = { "Lava frog" } },
            { Name = "Flaming Bull", Rarity = "Legendary" },
            { Name = "Chillin Chilli", Rarity = "Mythic" },
            { Name = "Lava Iguana", Rarity = "Legendary" },
            { Name = "Cerberus", Rarity = "Secret" },
            { Name = "Phoenix", Rarity = "Eternal" },
            { Name = "Lava Dragon", Rarity = "Eternal", Aliases = { "Dragon" } },
        }
    },
    {
        Biome = "Abyss Ocean",
        EggNames = { "Abyss Ocean Egg", "Ocean Egg", "Depths Egg" },
        Species = {
            { Name = "Parrotfish", Rarity = "Rare" },
            { Name = "Swordfish", Rarity = "Epic" },
            { Name = "Shark", Rarity = "Legendary", Aliases = { "Finned Thresher" } },
            { Name = "Orca", Rarity = "Mythic" },
            { Name = "Whale Shark", Rarity = "Cosmic" },
            { Name = "Beluga Whale", Rarity = "Cosmic", Aliases = { "Alabaster Whale" } },
            { Name = "Kraken", Rarity = "Secret" },
            { Name = "El Maja", Rarity = "Eternal" },
        }
    },
    {
        Biome = "Prehistoric",
        EggNames = { "Prehistoric Egg" },
        Species = {
            { Name = "Dodo", Rarity = "Rare" },
            { Name = "Pterodactyl", Rarity = "Legendary" },
            { Name = "Ankylosaurus", Rarity = "Mythic" },
            { Name = "Bronto", Rarity = "Cosmic" },
            { Name = "Triceratops", Rarity = "Cosmic" },
            { Name = "TRex", Rarity = "Secret", Aliases = { "TyrannosaurusRex", "T-Rex" } },
            { Name = "Tralaledon", Rarity = "Secret" },
            { Name = "Mosasaurus", Rarity = "Eternal" },
        }
    },
    {
        Biome = "Cosmic",
        EggNames = { "Cosmic Egg" },
        Species = {
            { Name = "Centapede", Rarity = "Epic" },
            { Name = "Cosmic Gecko", Rarity = "Legendary", Aliases = { "Galaxy Gecko" } },
            { Name = "Cosmic Gorilla", Rarity = "Mythic", Aliases = { "Cyclops Gorilla" } },
            { Name = "La Vacca Saturno Saturnita", Rarity = "Cosmic" },
            { Name = "Cosmic Dragon", Rarity = "Secret", Aliases = { "Cave Dragon" } },
            { Name = "Cosmic Skeleton Boss", Rarity = "Secret", Aliases = { "Alien Skeleton Boss" } },
            { Name = "Eternal Lunar Dragon", Rarity = "Eternal" },
            { Name = "Unicorn", Rarity = "Divine" },
        }
    },
    {
        Biome = "Cherry Blossom",
        EggNames = { "Cherry Blossom Egg" },
        Species = {
            { Name = "Crane", Rarity = "Epic" },
            { Name = "Salamander", Rarity = "Legendary" },
            { Name = "Red Panda", Rarity = "Mythic" },
            { Name = "Snowy Owl", Rarity = "Cosmic" },
            { Name = "Koi", Rarity = "Cosmic" },
            { Name = "Stag", Rarity = "Secret" },
            { Name = "Oni Tiger", Rarity = "Eternal" },
            { Name = "Kitsune", Rarity = "Divine" },
        }
    },
    {
        Biome = "Titan Temple",
        EggNames = { "Titan Temple Egg" },
        Species = {
            { Name = "Spideron", Rarity = "Legendary", Aliases = { "Kaiju Spider", "Kaiju" } },
            { Name = "Crustacia", Rarity = "Legendary", Aliases = { "Crab" } },
            { Name = "Bladehide", Rarity = "Mythic", Aliases = { "Blade Head" } },
            { Name = "Mantaris", Rarity = "Cosmic", Aliases = { "Mantis" } },
            { Name = "Rhinotaur", Rarity = "Cosmic", Aliases = { "Rhino" } },
            { Name = "Mutant Shark", Rarity = "Secret" },
            { Name = "Gorilla King", Rarity = "Eternal", Aliases = { "King Kong" } },
            { Name = "Nightflame", Rarity = "Divine", Aliases = { "Godzilla" } },
        }
    },
    {
        Biome = "Light & Dark",
        EggNames = { "Angels & Demons Egg", "Angels Egg", "Demons Egg", "Light Egg", "Dark Egg" },
        Species = {
            -- Light / Angels
            { Name = "Light Dove", Rarity = "Legendary", Aliases = { "Dove" } },
            { Name = "Winged Lamb", Rarity = "Mythic", Aliases = { "Lamb" } },
            { Name = "Sacred Moth", Rarity = "Cosmic", Aliases = { "Moth" } },
            { Name = "Holy Peacock", Rarity = "Cosmic", Aliases = { "Peacock" } },
            { Name = "Pure Jellyfish", Rarity = "Secret", Aliases = { "Jellyfish" } },
            { Name = "Centaur", Rarity = "Secret" },
            { Name = "Pegasus", Rarity = "Eternal" },
            { Name = "ArchAngel", Rarity = "Divine" },
            -- Dark / Demons
            { Name = "Flame Sprite", Rarity = "Legendary" },
            { Name = "Toro", Rarity = "Mythic" },
            { Name = "Imp", Rarity = "Cosmic" },
            { Name = "Demon Hound", Rarity = "Cosmic" },
            { Name = "Gargoyle", Rarity = "Secret", Aliases = { "Dark Gargoyle" } },
            { Name = "RazorFang", Rarity = "Secret" },
            { Name = "Skeleton Horse", Rarity = "Eternal" },
            { Name = "World Burner", Rarity = "Divine" },
        }
    },
    {
        Biome = "Enchanted Forest",
        EggNames = { "Enchanted Forest Egg" },
        Species = {
            { Name = "Prism Gecko", Rarity = "Legendary" },
            { Name = "Petal Beetle", Rarity = "Mythic", Aliases = { "Cosmic Beetle Blue" } },
            { Name = "Enchanted Bluejay", Rarity = "Mythic" },
            { Name = "Astral Jackalope", Rarity = "Cosmic", Aliases = { "Jackalope", "Spirit Hare" } },
            { Name = "Spirit Panda", Rarity = "Cosmic" },
            { Name = "Starry Fox", Rarity = "Secret", Aliases = { "Cosmic Fox" } },
            { Name = "Celestial Sunlion", Rarity = "Eternal", Aliases = { "Sunlion" } },
            { Name = "Royal Skywhale", Rarity = "Divine", Aliases = { "Skywhale" } },
        }
    },
    {
        Biome = "Ungrouped",
        EggNames = { "Event Egg", "Special Egg" },
        Species = {
            -- Toxic Wasteland Event
            { Name = "Toxic Rat", Rarity = "Common" },
            { Name = "Radcoon", Rarity = "Common" },
            { Name = "Toxic Hedgehog", Rarity = "Rare" },
            { Name = "Toxic Crocodile", Rarity = "Epic" },
            { Name = "Sharkodile", Rarity = "Legendary" },
            { Name = "Rhinobear", Rarity = "Mythic" },
            { Name = "Toucax", Rarity = "Mythic" },
            { Name = "Nuceodille", Rarity = "Eternal" },
            { Name = "Nuclear Mantis", Rarity = "Divine" },
            -- Void & Rift Event
            { Name = "Rift Eye", Rarity = "Legendary" },
            { Name = "Void Angler", Rarity = "Legendary" },
            { Name = "Riftwing", Rarity = "Mythic" },
            { Name = "Shardling", Rarity = "Mythic" },
            { Name = "Voidmaw", Rarity = "Mythic" },
            { Name = "Dreadclaw", Rarity = "Cosmic" },
            { Name = "Shattered Ram", Rarity = "Cosmic" },
            { Name = "Ventinal", Rarity = "Cosmic" },
            { Name = "Nibbles #013", Rarity = "Cosmic" },
            { Name = "Mawbreaker", Rarity = "Secret" },
            { Name = "Shardwing", Rarity = "Secret" },
            { Name = "Wendigo", Rarity = "Secret" },
            { Name = "Abyss Overlord", Rarity = "Secret" },
            { Name = "Experiment #001", Rarity = "Secret" },
            { Name = "Ember Dragon", Rarity = "Secret" },
            { Name = "Scorched Dragon", Rarity = "Secret", Aliases = { "ScorchedDragon" } },
            { Name = "Shattered Drake", Rarity = "Eternal" },
            { Name = "Void Serpent", Rarity = "Eternal" },
            { Name = "Void Dragon", Rarity = "Eternal" },
            { Name = "World Eater", Rarity = "Eternal" },
            { Name = "Shattered Colossus", Rarity = "Divine" },
            { Name = "Aetheron", Rarity = "Divine" },
            { Name = "Equinox", Rarity = "Eternal" },
            { Name = "Baby Aurora Dragon", Rarity = "Legendary" },
            { Name = "Shadow Dragon", Rarity = "Mythic" },
            { Name = "Drilla", Rarity = "Cosmic" },
            { Name = "Basilisk", Rarity = "Cosmic" },
            -- Mecha Event
            { Name = "Scorpio", Rarity = "Legendary", Aliases = { "Mecha Scorpio" } },
            { Name = "Froggo", Rarity = "Mythic", Aliases = { "Mecha Froggo" } },
            { Name = "Crawler", Rarity = "Cosmic", Aliases = { "Mecha Crawler" } },
            { Name = "Crocodon", Rarity = "Secret", Aliases = { "Mecha Crocodon" } },
            { Name = "Krakenoid", Rarity = "Eternal", Aliases = { "Mecha Krakenoid" } },
            { Name = "Dreadscale", Rarity = "Divine", Aliases = { "Mecha Dreadscale" } },
            -- Luminous Depths Event
            { Name = "Spike", Rarity = "Legendary", Aliases = { "Luminous Spike" } },
            { Name = "Spirit Manta", Rarity = "Mythic", Aliases = { "Luminous Spirit Manta" } },
            { Name = "Abyss Shark", Rarity = "Cosmic", Aliases = { "Luminous Abyss Shark" } },
            { Name = "Electric Eel", Rarity = "Secret", Aliases = { "Luminous Electric Eel" } },
            { Name = "Terra Snapper", Rarity = "Eternal", Aliases = { "Luminous Terra Snapper" } },
            { Name = "Cthulhu", Rarity = "Divine", Aliases = { "Luminous Cthulhu" } },
            -- Meme & Special Event
            { Name = "Tung Tung Sahur", Rarity = "Rare" },
            { Name = "Bananita Dolphinita", Rarity = "Epic" },
            { Name = "Belula Beluga", Rarity = "Mythic" },
            { Name = "Mangolini Parrochini", Rarity = "Cosmic" },
            { Name = "Bomboclat Crocolat", Rarity = "Secret" },
            { Name = "Strawberry Elephant", Rarity = "Eternal" },
            -- Other Discovered / Legacy Event Species
            { Name = "Stacked Turtle", Rarity = "Rare" },
            { Name = "DesertLark", Rarity = "Rare" },
            { Name = "Uncoiled Armadillo", Rarity = "Epic" },
            { Name = "Ringlord", Rarity = "Secret" },
            { Name = "Eye Bat", Rarity = "Rare" },
            { Name = "Citadel Snail", Rarity = "Epic" },
            { Name = "Ascended Vermilion Phoenix", Rarity = "Divine" },
            { Name = "Hellhound", Rarity = "Legendary" },
            { Name = "Balrog", Rarity = "Eternal" },
            { Name = "Archdemon Dragon", Rarity = "Divine" },
            { Name = "Riptide Octopus", Rarity = "Eternal" },
            { Name = "Depths Riptide Octopus", Rarity = "Divine" },
            { Name = "Frogfly", Rarity = "Rare" },
            { Name = "Wheel Hamster", Rarity = "Rare" },
        }
    }
}

-- Fast lookup indexes
local SPECIES_INFO = {}
local EGG_ALIASES  = {}
local EGG_TO_BIOME = {}

local function normalizeSpecies(name)
    if not name or type(name) ~= "string" then return "" end
    local str = name:lower():gsub("^%b[]%s*", ""):gsub("%s*%b()%s*$", "")
    for _, prefix in ipairs({ "rainbow", "golden", "silver", "gold", "shiny" }) do
        str = str:gsub("^" .. prefix .. "%s+", "")
    end
    str = str:gsub("%s*egg%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    return str
end

-- Populate indexes
for _, biomeData in ipairs(BIOME_EGG_CATALOG) do
    if biomeData.EggNames then
        for _, eggName in ipairs(biomeData.EggNames) do
            EGG_TO_BIOME[normalizeSpecies(eggName)] = biomeData.Biome
        end
    end

    for _, spec in ipairs(biomeData.Species) do
        local canonicalNorm = normalizeSpecies(spec.Name)
        local record = {
            DisplayName = spec.Name,
            Rarity      = spec.Rarity,
            Rank        = RARITY_RANK[spec.Rarity] or 0,
            Biome       = biomeData.Biome,
        }
        SPECIES_INFO[canonicalNorm] = record

        if spec.Aliases then
            for _, alias in ipairs(spec.Aliases) do
                local aliasNorm = normalizeSpecies(alias)
                if aliasNorm ~= "" then
                    SPECIES_INFO[aliasNorm] = record
                    EGG_ALIASES[aliasNorm] = canonicalNorm
                end
            end
        end
    end
end

-- Species lookup and matching helpers
local function getSpeciesInfo(name)
    local clean = normalizeSpecies(name)
    if clean == "" then return nil end
    return SPECIES_INFO[clean]
end

local function getSpeciesRarity(name)
    local info = getSpeciesInfo(name)
    return info and info.Rarity or "Common"
end

local function getSpeciesBiome(name)
    local info = getSpeciesInfo(name)
    return info and info.Biome or nil
end

local function matchSpecies(nameA, nameB)
    local a = normalizeSpecies(nameA)
    local b = normalizeSpecies(nameB)
    if a == "" or b == "" then return false end
    if a == b then return true end
    local aliasA = EGG_ALIASES[a]
    local aliasB = EGG_ALIASES[b]
    if aliasA and aliasA == b then return true end
    if aliasB and aliasB == a then return true end
    if aliasA and aliasB and aliasA == aliasB then return true end
    return false
end

-- ============================================================================
-- UI CONSTRUCTION
-- ============================================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggGoToUI_v11"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

-- Floating Toggle Button
local menuToggleBtn = Instance.new("TextButton")
menuToggleBtn.Name = "MenuToggleBtn"
menuToggleBtn.Size = UDim2.new(0, 40, 0, 40)
menuToggleBtn.Position = UDim2.new(0, 8, 0, 50)
menuToggleBtn.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
menuToggleBtn.Text = "☰"
menuToggleBtn.TextColor3 = Color3.fromRGB(200, 215, 255)
menuToggleBtn.TextSize = 22
menuToggleBtn.Font = Enum.Font.GothamBold
menuToggleBtn.ZIndex = 200
menuToggleBtn.Parent = screenGui

Instance.new("UICorner", menuToggleBtn).CornerRadius = UDim.new(0, 8)
local toggleStroke = Instance.new("UIStroke", menuToggleBtn)
toggleStroke.Color = Color3.fromRGB(70, 110, 180)
toggleStroke.Thickness = 1.5

-- Drag handling for floating toggle button
local tDragging, tDragStart, tStartPos = false, nil, nil
addConnection(menuToggleBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        tDragging = true
        tDragStart = input.Position
        tStartPos = menuToggleBtn.Position
    end
end))

addConnection(menuToggleBtn.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        tDragging = false
    end
end))

addConnection(UserInputService.InputChanged:Connect(function(input)
    if tDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - tDragStart
        menuToggleBtn.Position = UDim2.new(
            tStartPos.X.Scale, tStartPos.X.Offset + delta.X,
            tStartPos.Y.Scale, tStartPos.Y.Offset + delta.Y
        )
    end
end))

-- Main Window Frame
local main = Instance.new("Frame")
main.Name = "MainFrame"
main.Size = UDim2.new(0, 380, 0, 520)
main.Position = UDim2.new(0.5, -190, 0.5, -260)
main.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
main.BorderSizePixel = 0
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(70, 110, 180)
mainStroke.Thickness = 1.5

-- Title Bar
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
titleBar.BorderSizePixel = 0
titleBar.Parent = main

Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

-- Bottom filler for TitleBar corners
local titleCornerFix = Instance.new("Frame")
titleCornerFix.Name = "CornerFix"
titleCornerFix.Size = UDim2.new(1, 0, 0, 12)
titleCornerFix.Position = UDim2.new(0, 0, 1, -12)
titleCornerFix.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
titleCornerFix.BorderSizePixel = 0
titleCornerFix.Parent = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "TitleLabel"
titleLabel.Size = UDim2.new(1, -80, 1, 0)
titleLabel.Position = UDim2.new(0, 12, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Egg Go-To v11"
titleLabel.TextColor3 = Color3.fromRGB(220, 230, 255)
titleLabel.TextSize = 13
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseBtn"
closeBtn.Size = UDim2.new(0, 30, 0, 24)
closeBtn.Position = UDim2.new(1, -38, 0.5, -12)
closeBtn.BackgroundColor3 = Color3.fromRGB(170, 50, 50)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 13
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- Drag handling for Main Frame
local dragging, dragStart, startPos = false, nil, nil
addConnection(titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
    end
end))

addConnection(titleBar.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end))

addConnection(UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end))

-- Sidebar Navigation Rail (Width: 46px)
local SIDEBAR_W = 46
local sidebar = Instance.new("Frame")
sidebar.Name = "Sidebar"
sidebar.Size = UDim2.new(0, SIDEBAR_W, 1, -36)
sidebar.Position = UDim2.new(0, 0, 0, 36)
sidebar.BackgroundColor3 = Color3.fromRGB(26, 32, 46)
sidebar.BorderSizePixel = 0
sidebar.Parent = main

local sidebarDivider = Instance.new("Frame")
sidebarDivider.Name = "SidebarDivider"
sidebarDivider.Size = UDim2.new(0, 1, 1, 0)
sidebarDivider.Position = UDim2.new(1, -1, 0, 0)
sidebarDivider.BackgroundColor3 = Color3.fromRGB(50, 70, 105)
sidebarDivider.BorderSizePixel = 0
sidebarDivider.Parent = sidebar

-- Sidebar Button 1: Eggs
local tabBtnEggs = Instance.new("TextButton")
tabBtnEggs.Name = "TabBtnEggs"
tabBtnEggs.Size = UDim2.new(0, 34, 0, 34)
tabBtnEggs.Position = UDim2.new(0.5, -17, 0, 10)
tabBtnEggs.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
tabBtnEggs.Text = "🥚"
tabBtnEggs.TextColor3 = Color3.new(1, 1, 1)
tabBtnEggs.TextSize = 18
tabBtnEggs.Font = Enum.Font.GothamBold
tabBtnEggs.Parent = sidebar
Instance.new("UICorner", tabBtnEggs).CornerRadius = UDim.new(0, 6)

-- Content Area Container
local contentContainer = Instance.new("Frame")
contentContainer.Name = "ContentContainer"
contentContainer.Size = UDim2.new(1, -SIDEBAR_W, 1, -36)
contentContainer.Position = UDim2.new(0, SIDEBAR_W, 0, 36)
contentContainer.BackgroundTransparency = 1
contentContainer.BorderSizePixel = 0
contentContainer.ClipsDescendants = true
contentContainer.Parent = main

-- Panel 1: Eggs Panel
local tabEggs = Instance.new("Frame")
tabEggs.Name = "TabEggs"
tabEggs.Size = UDim2.new(1, 0, 1, 0)
tabEggs.Position = UDim2.new(0, 0, 0, 0)
tabEggs.BackgroundTransparency = 1
tabEggs.BorderSizePixel = 0
tabEggs.ClipsDescendants = false
tabEggs.Visible = true
tabEggs.Parent = contentContainer

-- Forward declarations
local renderFarmableEggs
local requestListUpdate

-- Filter Selection State
local RARITY_ORDER = {
    "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine"
}

local BIOME_ORDER = {
    "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
    "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest", "Ungrouped"
}

local ALL_SPECIES_LIST = {}
do
    local seen = {}
    for _, biomeData in ipairs(BIOME_EGG_CATALOG) do
        for _, spec in ipairs(biomeData.Species) do
            if not seen[spec.Name] then
                seen[spec.Name] = true
                table.insert(ALL_SPECIES_LIST, {
                    Name      = spec.Name,
                    Biome     = biomeData.Biome,
                    Rarity    = spec.Rarity,
                    Rank      = RARITY_RANK[spec.Rarity] or 0,
                    SearchKey = (spec.Name .. " " .. biomeData.Biome .. " " .. spec.Rarity):lower(),
                })
            end
        end
    end
    table.sort(ALL_SPECIES_LIST, function(a, b)
        return a.Name:lower() < b.Name:lower()
    end)
end

local selectedRarities = { ["All"] = true }
local selectedBiomes   = { ["All"] = true }
local selectedEggs     = { ["All"] = true }

local function isRarityAllowed(r)
    if selectedRarities["All"] then return true end
    if next(selectedRarities) == nil then return false end
    return selectedRarities[r] == true
end

local function isBiomeAllowed(b)
    if selectedBiomes["All"] then return true end
    if next(selectedBiomes) == nil then return false end
    return selectedBiomes[b] == true
end

local function isEggAllowed(disp, raw, info)
    if selectedEggs["All"] then return true end
    if next(selectedEggs) == nil then return false end
    if selectedEggs[disp] then return true end
    if raw and selectedEggs[raw] then return true end
    local specInfo = info or getSpeciesInfo(disp) or (raw and getSpeciesInfo(raw))
    if specInfo and selectedEggs[specInfo.DisplayName] then return true end
    return false
end

-- World Egg Catalog List View
local listHeader = Instance.new("Frame")
listHeader.Name = "ListHeader"
listHeader.Size = UDim2.new(1, -16, 0, 28)
listHeader.Position = UDim2.new(0, 8, 0, 6)
listHeader.BackgroundColor3 = Color3.fromRGB(26, 32, 46)
listHeader.BorderSizePixel = 0
listHeader.Parent = tabEggs
Instance.new("UICorner", listHeader).CornerRadius = UDim.new(0, 6)

local listHeaderTitle = Instance.new("TextLabel")
listHeaderTitle.Name = "HeaderTitle"
listHeaderTitle.Size = UDim2.new(1, -95, 1, 0)
listHeaderTitle.Position = UDim2.new(0, 10, 0, 0)
listHeaderTitle.BackgroundTransparency = 1
listHeaderTitle.Text = "Farmable Eggs"
listHeaderTitle.TextColor3 = Color3.fromRGB(220, 230, 255)
listHeaderTitle.TextSize = 12
listHeaderTitle.Font = Enum.Font.GothamBold
listHeaderTitle.TextXAlignment = Enum.TextXAlignment.Left
listHeaderTitle.Parent = listHeader

local copyJsonBtn = Instance.new("TextButton")
copyJsonBtn.Name = "CopyJsonBtn"
copyJsonBtn.Size = UDim2.new(0, 76, 0, 20)
copyJsonBtn.Position = UDim2.new(1, -82, 0.5, -10)
copyJsonBtn.BackgroundColor3 = Color3.fromRGB(45, 65, 100)
copyJsonBtn.Text = "Copy JSON"
copyJsonBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
copyJsonBtn.TextSize = 10
copyJsonBtn.Font = Enum.Font.GothamBold
copyJsonBtn.Parent = listHeader
Instance.new("UICorner", copyJsonBtn).CornerRadius = UDim.new(0, 4)

-- Dropdown Filter Bar
local filterFrame = Instance.new("Frame")
filterFrame.Name = "FilterFrame"
filterFrame.Size = UDim2.new(1, -16, 0, 56)
filterFrame.Position = UDim2.new(0, 8, 0, 38)
filterFrame.BackgroundTransparency = 1
filterFrame.BorderSizePixel = 0
filterFrame.ClipsDescendants = false
filterFrame.ZIndex = 30
filterFrame.Parent = tabEggs

-- 1. Rarity Filter Button
local rarityBtn = Instance.new("TextButton")
rarityBtn.Name = "RarityFilterBtn"
rarityBtn.Size = UDim2.new(0.5, -3, 0, 26)
rarityBtn.Position = UDim2.new(0, 0, 0, 0)
rarityBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
rarityBtn.Text = "Rarity: All ▼"
rarityBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
rarityBtn.TextSize = 11
rarityBtn.Font = Enum.Font.GothamBold
rarityBtn.ZIndex = 31
rarityBtn.Parent = filterFrame
Instance.new("UICorner", rarityBtn).CornerRadius = UDim.new(0, 6)

-- 2. Biome Filter Button
local biomeBtn = Instance.new("TextButton")
biomeBtn.Name = "BiomeFilterBtn"
biomeBtn.Size = UDim2.new(0.5, -3, 0, 26)
biomeBtn.Position = UDim2.new(0.5, 3, 0, 0)
biomeBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
biomeBtn.Text = "Biome: All ▼"
biomeBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
biomeBtn.TextSize = 11
biomeBtn.Font = Enum.Font.GothamBold
biomeBtn.ZIndex = 31
biomeBtn.Parent = filterFrame
Instance.new("UICorner", biomeBtn).CornerRadius = UDim.new(0, 6)

-- Row 2: Farm Label & Egg Filter Button
local farmLabel = Instance.new("TextLabel")
farmLabel.Name = "FarmLabel"
farmLabel.Size = UDim2.new(0, 42, 0, 26)
farmLabel.Position = UDim2.new(0, 2, 0, 30)
farmLabel.BackgroundTransparency = 1
farmLabel.Text = "Farm:"
farmLabel.TextColor3 = Color3.fromRGB(180, 195, 220)
farmLabel.TextSize = 11.5
farmLabel.Font = Enum.Font.GothamBold
farmLabel.TextXAlignment = Enum.TextXAlignment.Left
farmLabel.ZIndex = 31
farmLabel.Parent = filterFrame

local eggBtn = Instance.new("TextButton")
eggBtn.Name = "EggFilterBtn"
eggBtn.Size = UDim2.new(1, -46, 0, 26)
eggBtn.Position = UDim2.new(0, 46, 0, 30)
eggBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
eggBtn.Text = "All ▼"
eggBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
eggBtn.TextSize = 11.5
eggBtn.Font = Enum.Font.GothamBold
eggBtn.TextTruncate = Enum.TextTruncate.AtEnd
eggBtn.ZIndex = 31
eggBtn.Parent = filterFrame
Instance.new("UICorner", eggBtn).CornerRadius = UDim.new(0, 6)

-- Dropdown Lists Container
local rarityList = Instance.new("Frame")
rarityList.Name = "RarityDropList"
rarityList.Size = UDim2.new(0.5, -3, 0, 256)
rarityList.Position = UDim2.new(0, 0, 0, 28)
rarityList.BackgroundColor3 = Color3.fromRGB(24, 29, 42)
rarityList.BorderSizePixel = 0
rarityList.ZIndex = 50
rarityList.ClipsDescendants = true
rarityList.Visible = false
rarityList.Parent = filterFrame
Instance.new("UICorner", rarityList).CornerRadius = UDim.new(0, 6)
local rStroke = Instance.new("UIStroke", rarityList)
rStroke.Color = Color3.fromRGB(60, 85, 130); rStroke.Thickness = 1

local rarityQuickRow = Instance.new("Frame")
rarityQuickRow.Size = UDim2.new(1, -6, 0, 22)
rarityQuickRow.Position = UDim2.new(0, 3, 0, 3)
rarityQuickRow.BackgroundTransparency = 1
rarityQuickRow.ZIndex = 51
rarityQuickRow.Parent = rarityList

local rarityAllBtn = Instance.new("TextButton")
rarityAllBtn.Size = UDim2.new(0.5, -2, 1, 0)
rarityAllBtn.Position = UDim2.new(0, 0, 0, 0)
rarityAllBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 150)
rarityAllBtn.Text = "All"
rarityAllBtn.TextColor3 = Color3.new(1, 1, 1)
rarityAllBtn.TextSize = 11; rarityAllBtn.Font = Enum.Font.GothamBold
rarityAllBtn.ZIndex = 52; rarityAllBtn.Parent = rarityQuickRow
Instance.new("UICorner", rarityAllBtn).CornerRadius = UDim.new(0, 4)

local rarityNoneBtn = Instance.new("TextButton")
rarityNoneBtn.Size = UDim2.new(0.5, -2, 1, 0)
rarityNoneBtn.Position = UDim2.new(0.5, 2, 0, 0)
rarityNoneBtn.BackgroundColor3 = Color3.fromRGB(110, 45, 45)
rarityNoneBtn.Text = "None"
rarityNoneBtn.TextColor3 = Color3.new(1, 1, 1)
rarityNoneBtn.TextSize = 11; rarityNoneBtn.Font = Enum.Font.GothamBold
rarityNoneBtn.ZIndex = 52; rarityNoneBtn.Parent = rarityQuickRow
Instance.new("UICorner", rarityNoneBtn).CornerRadius = UDim.new(0, 4)

local rarityItemsContainer = Instance.new("Frame")
rarityItemsContainer.Size = UDim2.new(1, -6, 1, -29)
rarityItemsContainer.Position = UDim2.new(0, 3, 0, 27)
rarityItemsContainer.BackgroundTransparency = 1
rarityItemsContainer.ZIndex = 51
rarityItemsContainer.Parent = rarityList

local rLayout = Instance.new("UIListLayout")
rLayout.Padding = UDim.new(0, 2); rLayout.SortOrder = Enum.SortOrder.LayoutOrder
rLayout.Parent = rarityItemsContainer

local rarityBtns = {}
local refreshRarityButtons
local updateRarityBtnText

updateRarityBtnText = function(isOpen)
    local arrow = isOpen and "▲" or "▼"
    if selectedRarities["All"] then
        rarityBtn.Text = "Rarity: All " .. arrow
        return
    end
    local list = {}
    for _, r in ipairs(RARITY_ORDER) do
        if selectedRarities[r] then table.insert(list, r) end
    end
    if #list == 0 then
        rarityBtn.Text = "Rarity: None " .. arrow
    elseif #list == 1 then
        rarityBtn.Text = "Rarity: " .. list[1] .. " " .. arrow
    else
        rarityBtn.Text = string.format("Rarity: %s +%d %s", list[1], #list - 1, arrow)
    end
end

refreshRarityButtons = function()
    for _, r in ipairs(RARITY_ORDER) do
        local on = selectedRarities["All"] == true or selectedRarities[r] == true
        local b = rarityBtns[r]
        if b then
            b.BackgroundColor3 = on and Color3.fromRGB(48, 80, 125) or Color3.fromRGB(32, 38, 52)
            b.Text = (on and "[X] " or "[ ] ") .. r
        end
    end
end

for i, r in ipairs(RARITY_ORDER) do
    local b = Instance.new("TextButton")
    b.Name = "Rarity_" .. r
    b.Size = UDim2.new(1, 0, 0, 20)
    b.LayoutOrder = i
    b.BackgroundColor3 = Color3.fromRGB(32, 38, 52)
    b.Text = "[X] " .. r
    b.TextColor3 = RARITY_COLORS[r] or Color3.fromRGB(220, 230, 255)
    b.TextSize = 11; b.Font = Enum.Font.GothamBold
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.ZIndex = 52; b.Parent = rarityItemsContainer
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 6); pad.Parent = b
    rarityBtns[r] = b

    b.MouseButton1Click:Connect(function()
        if selectedRarities["All"] then
            selectedRarities = {}
        end
        if selectedRarities[r] then
            selectedRarities[r] = nil
        else
            selectedRarities[r] = true
        end
        local totalChecked = 0
        for _, checkR in ipairs(RARITY_ORDER) do
            if selectedRarities[checkR] then totalChecked = totalChecked + 1 end
        end
        if totalChecked == #RARITY_ORDER then
            selectedRarities = { ["All"] = true }
        end
        updateRarityBtnText(true)
        refreshRarityButtons()
        if renderFarmableEggs then renderFarmableEggs() end
    end)
end

rarityAllBtn.MouseButton1Click:Connect(function()
    selectedRarities = { ["All"] = true }
    updateRarityBtnText(true)
    refreshRarityButtons()
    if renderFarmableEggs then renderFarmableEggs() end
end)

rarityNoneBtn.MouseButton1Click:Connect(function()
    selectedRarities = {}
    updateRarityBtnText(true)
    refreshRarityButtons()
    if renderFarmableEggs then renderFarmableEggs() end
end)

-- Biome Dropdown List
local biomeList = Instance.new("Frame")
biomeList.Name = "BiomeDropList"
biomeList.Size = UDim2.new(0.5, -3, 0, 240)
biomeList.Position = UDim2.new(0.5, 3, 0, 28)
biomeList.BackgroundColor3 = Color3.fromRGB(24, 29, 42)
biomeList.BorderSizePixel = 0
biomeList.ZIndex = 50
biomeList.ClipsDescendants = true
biomeList.Visible = false
biomeList.Parent = filterFrame
Instance.new("UICorner", biomeList).CornerRadius = UDim.new(0, 6)
local bStroke = Instance.new("UIStroke", biomeList)
bStroke.Color = Color3.fromRGB(60, 85, 130); bStroke.Thickness = 1

local biomeQuickRow = Instance.new("Frame")
biomeQuickRow.Size = UDim2.new(1, -6, 0, 22)
biomeQuickRow.Position = UDim2.new(0, 3, 0, 3)
biomeQuickRow.BackgroundTransparency = 1
biomeQuickRow.ZIndex = 51
biomeQuickRow.Parent = biomeList

local biomeAllBtn = Instance.new("TextButton")
biomeAllBtn.Size = UDim2.new(0.5, -2, 1, 0)
biomeAllBtn.Position = UDim2.new(0, 0, 0, 0)
biomeAllBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 150)
biomeAllBtn.Text = "All"
biomeAllBtn.TextColor3 = Color3.new(1, 1, 1)
biomeAllBtn.TextSize = 11; biomeAllBtn.Font = Enum.Font.GothamBold
biomeAllBtn.ZIndex = 52; biomeAllBtn.Parent = biomeQuickRow
Instance.new("UICorner", biomeAllBtn).CornerRadius = UDim.new(0, 4)

local biomeNoneBtn = Instance.new("TextButton")
biomeNoneBtn.Size = UDim2.new(0.5, -2, 1, 0)
biomeNoneBtn.Position = UDim2.new(0.5, 2, 0, 0)
biomeNoneBtn.BackgroundColor3 = Color3.fromRGB(110, 45, 45)
biomeNoneBtn.Text = "None"
biomeNoneBtn.TextColor3 = Color3.new(1, 1, 1)
biomeNoneBtn.TextSize = 11; biomeNoneBtn.Font = Enum.Font.GothamBold
biomeNoneBtn.ZIndex = 52; biomeNoneBtn.Parent = biomeQuickRow
Instance.new("UICorner", biomeNoneBtn).CornerRadius = UDim.new(0, 4)

local biomeScroll = Instance.new("ScrollingFrame")
biomeScroll.Size = UDim2.new(1, -6, 1, -29)
biomeScroll.Position = UDim2.new(0, 3, 0, 27)
biomeScroll.BackgroundTransparency = 1
biomeScroll.ScrollBarThickness = 3
biomeScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
biomeScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
biomeScroll.ZIndex = 51
biomeScroll.Parent = biomeList

local bLayout = Instance.new("UIListLayout")
bLayout.Padding = UDim.new(0, 2); bLayout.SortOrder = Enum.SortOrder.LayoutOrder
bLayout.Parent = biomeScroll

local biomeBtns = {}
local refreshBiomeButtons
local updateBiomeBtnText

updateBiomeBtnText = function(isOpen)
    local arrow = isOpen and "▲" or "▼"
    if selectedBiomes["All"] then
        biomeBtn.Text = "Biome: All " .. arrow
        return
    end
    local list = {}
    for _, b in ipairs(BIOME_ORDER) do
        if selectedBiomes[b] then table.insert(list, b) end
    end
    if #list == 0 then
        biomeBtn.Text = "Biome: None " .. arrow
    elseif #list == 1 then
        biomeBtn.Text = "Biome: " .. list[1] .. " " .. arrow
    else
        biomeBtn.Text = string.format("Biome: %s +%d %s", list[1], #list - 1, arrow)
    end
end

refreshBiomeButtons = function()
    for _, bName in ipairs(BIOME_ORDER) do
        local on = selectedBiomes["All"] == true or selectedBiomes[bName] == true
        local b = biomeBtns[bName]
        if b then
            b.BackgroundColor3 = on and Color3.fromRGB(48, 80, 125) or Color3.fromRGB(32, 38, 52)
            b.Text = (on and "[X] " or "[ ] ") .. bName
        end
    end
end

for i, bName in ipairs(BIOME_ORDER) do
    local b = Instance.new("TextButton")
    b.Name = "Biome_" .. bName
    b.Size = UDim2.new(1, -4, 0, 20)
    b.LayoutOrder = i
    b.BackgroundColor3 = Color3.fromRGB(32, 38, 52)
    b.Text = "[X] " .. bName
    b.TextColor3 = Color3.fromRGB(220, 230, 255)
    b.TextSize = 11; b.Font = Enum.Font.GothamBold
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.ZIndex = 52; b.Parent = biomeScroll
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 6); pad.Parent = b
    biomeBtns[bName] = b

    b.MouseButton1Click:Connect(function()
        if selectedBiomes["All"] then
            selectedBiomes = {}
        end
        if selectedBiomes[bName] then
            selectedBiomes[bName] = nil
        else
            selectedBiomes[bName] = true
        end
        local totalChecked = 0
        for _, checkB in ipairs(BIOME_ORDER) do
            if selectedBiomes[checkB] then totalChecked = totalChecked + 1 end
        end
        if totalChecked == #BIOME_ORDER then
            selectedBiomes = { ["All"] = true }
        end
        updateBiomeBtnText(true)
        refreshBiomeButtons()
        if renderFarmableEggs then renderFarmableEggs() end
    end)
end

biomeAllBtn.MouseButton1Click:Connect(function()
    selectedBiomes = { ["All"] = true }
    updateBiomeBtnText(true)
    refreshBiomeButtons()
    if renderFarmableEggs then renderFarmableEggs() end
end)

biomeNoneBtn.MouseButton1Click:Connect(function()
    selectedBiomes = {}
    updateBiomeBtnText(true)
    refreshBiomeButtons()
    if renderFarmableEggs then renderFarmableEggs() end
end)

-- Egg Dropdown List
local eggDropList = Instance.new("Frame")
eggDropList.Name = "EggDropList"
eggDropList.Size = UDim2.new(1, 0, 0, 260)
eggDropList.Position = UDim2.new(0, 0, 0, 58)
eggDropList.BackgroundColor3 = Color3.fromRGB(24, 29, 42)
eggDropList.BorderSizePixel = 0
eggDropList.ZIndex = 50
eggDropList.ClipsDescendants = true
eggDropList.Visible = false
eggDropList.Parent = filterFrame
Instance.new("UICorner", eggDropList).CornerRadius = UDim.new(0, 6)
local eStroke = Instance.new("UIStroke", eggDropList)
eStroke.Color = Color3.fromRGB(60, 85, 130); eStroke.Thickness = 1

local eggQuickRow = Instance.new("Frame")
eggQuickRow.Size = UDim2.new(1, -6, 0, 22)
eggQuickRow.Position = UDim2.new(0, 3, 0, 3)
eggQuickRow.BackgroundTransparency = 1
eggQuickRow.ZIndex = 51
eggQuickRow.Parent = eggDropList

local eggAllBtn = Instance.new("TextButton")
eggAllBtn.Size = UDim2.new(0.5, -2, 1, 0)
eggAllBtn.Position = UDim2.new(0, 0, 0, 0)
eggAllBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 150)
eggAllBtn.Text = "All"
eggAllBtn.TextColor3 = Color3.new(1, 1, 1)
eggAllBtn.TextSize = 11; eggAllBtn.Font = Enum.Font.GothamBold
eggAllBtn.ZIndex = 52; eggAllBtn.Parent = eggQuickRow
Instance.new("UICorner", eggAllBtn).CornerRadius = UDim.new(0, 4)

local eggNoneBtn = Instance.new("TextButton")
eggNoneBtn.Size = UDim2.new(0.5, -2, 1, 0)
eggNoneBtn.Position = UDim2.new(0.5, 2, 0, 0)
eggNoneBtn.BackgroundColor3 = Color3.fromRGB(110, 45, 45)
eggNoneBtn.Text = "None"
eggNoneBtn.TextColor3 = Color3.new(1, 1, 1)
eggNoneBtn.TextSize = 11; eggNoneBtn.Font = Enum.Font.GothamBold
eggNoneBtn.ZIndex = 52; eggNoneBtn.Parent = eggQuickRow
Instance.new("UICorner", eggNoneBtn).CornerRadius = UDim.new(0, 4)

local eggSearchBox = Instance.new("TextBox")
eggSearchBox.Size = UDim2.new(1, -6, 0, 22)
eggSearchBox.Position = UDim2.new(0, 3, 0, 28)
eggSearchBox.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
eggSearchBox.PlaceholderText = "Search egg name or biome..."
eggSearchBox.PlaceholderColor3 = Color3.fromRGB(110, 125, 150)
eggSearchBox.Text = ""
eggSearchBox.TextColor3 = Color3.fromRGB(220, 230, 255)
eggSearchBox.TextSize = 11; eggSearchBox.Font = Enum.Font.Gotham
eggSearchBox.ClearTextOnFocus = false
eggSearchBox.TextXAlignment = Enum.TextXAlignment.Left
eggSearchBox.ZIndex = 52
eggSearchBox.Parent = eggDropList
Instance.new("UICorner", eggSearchBox).CornerRadius = UDim.new(0, 4)
local esp = Instance.new("UIPadding"); esp.PaddingLeft = UDim.new(0, 6); esp.Parent = eggSearchBox

local eggDropScroll = Instance.new("ScrollingFrame")
eggDropScroll.Size = UDim2.new(1, -6, 1, -54)
eggDropScroll.Position = UDim2.new(0, 3, 0, 52)
eggDropScroll.BackgroundTransparency = 1
eggDropScroll.ScrollBarThickness = 4
eggDropScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
eggDropScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
eggDropScroll.ZIndex = 51
eggDropScroll.Parent = eggDropList

local eggDropListLayout = Instance.new("UIListLayout")
eggDropListLayout.Padding = UDim.new(0, 2)
eggDropListLayout.SortOrder = Enum.SortOrder.LayoutOrder
eggDropListLayout.Parent = eggDropScroll

local eggButtonsPool = {}
local rebuildEggDropdownItems
local updateEggBtnText

updateEggBtnText = function(isOpen)
    local arrow = isOpen and "▲" or "▼"
    if selectedEggs["All"] then
        eggBtn.Text = "All " .. arrow
        return
    end
    local list = {}
    for _, spec in ipairs(ALL_SPECIES_LIST) do
        if selectedEggs[spec.Name] then table.insert(list, spec.Name) end
    end
    if #list == 0 then
        eggBtn.Text = "None " .. arrow
    elseif #list == 1 then
        eggBtn.Text = list[1] .. " " .. arrow
    else
        local joined = table.concat(list, ", ")
        if #joined <= 24 then
            eggBtn.Text = joined .. " " .. arrow
        else
            eggBtn.Text = string.format("%s +%d %s", list[1], #list - 1, arrow)
        end
    end
end

rebuildEggDropdownItems = function()
    local q = eggSearchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local matchedList = {}
    for _, spec in ipairs(ALL_SPECIES_LIST) do
        if q == "" or spec.SearchKey:find(q, 1, true) then
            table.insert(matchedList, spec)
        end
    end

    for idx, spec in ipairs(matchedList) do
        local btn = eggButtonsPool[idx]
        if not btn then
            btn = Instance.new("TextButton")
            btn.Name = "EggBtn_" .. tostring(idx)
            btn.Size = UDim2.new(1, -4, 0, 22)
            btn.BorderSizePixel = 0
            btn.AutoButtonColor = false
            btn.TextXAlignment = Enum.TextXAlignment.Left
            btn.TextSize = 11
            btn.Font = Enum.Font.Gotham
            btn.ZIndex = 52
            btn.Parent = eggDropScroll
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
            local pad = Instance.new("UIPadding")
            pad.PaddingLeft = UDim.new(0, 6)
            pad.PaddingRight = UDim.new(0, 6)
            pad.Parent = btn

            local sub = Instance.new("TextLabel")
            sub.Name = "SubInfo"
            sub.Size = UDim2.new(0, 120, 1, 0)
            sub.Position = UDim2.new(1, -124, 0, 0)
            sub.BackgroundTransparency = 1
            sub.TextXAlignment = Enum.TextXAlignment.Right
            sub.TextSize = 9.5
            sub.Font = Enum.Font.Gotham
            sub.ZIndex = 52
            sub.Parent = btn

            btn.MouseButton1Click:Connect(function()
                local s = btn.specRef
                if not s then return end
                if selectedEggs["All"] then
                    selectedEggs = {}
                end
                if selectedEggs[s.Name] then
                    selectedEggs[s.Name] = nil
                else
                    selectedEggs[s.Name] = true
                end
                local totalChecked = 0
                for _ in pairs(selectedEggs) do
                    totalChecked = totalChecked + 1
                end
                if totalChecked >= #ALL_SPECIES_LIST then
                    selectedEggs = { ["All"] = true }
                end
                updateEggBtnText(true)
                rebuildEggDropdownItems()
                if renderFarmableEggs then renderFarmableEggs() end
            end)

            eggButtonsPool[idx] = btn
        end

        btn.specRef = spec
        local isChecked = selectedEggs["All"] == true or selectedEggs[spec.Name] == true
        btn.BackgroundColor3 = isChecked and Color3.fromRGB(48, 75, 115) or Color3.fromRGB(30, 36, 50)
        btn.Text = (isChecked and "[X] " or "[ ] ") .. spec.Name
        local rarCol = RARITY_COLORS[spec.Rarity] or Color3.fromRGB(220, 230, 255)
        btn.TextColor3 = isChecked and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(200, 210, 225)

        local subInfo = btn:FindFirstChild("SubInfo")
        if subInfo then
            subInfo.Text = spec.Biome .. " • " .. spec.Rarity
            subInfo.TextColor3 = rarCol
        end

        btn.Visible = true
    end

    for idx = #matchedList + 1, #eggButtonsPool do
        eggButtonsPool[idx].Visible = false
    end
end

eggSearchBox:GetPropertyChangedSignal("Text"):Connect(rebuildEggDropdownItems)

eggAllBtn.MouseButton1Click:Connect(function()
    selectedEggs = { ["All"] = true }
    updateEggBtnText(true)
    rebuildEggDropdownItems()
    if renderFarmableEggs then renderFarmableEggs() end
end)

eggNoneBtn.MouseButton1Click:Connect(function()
    selectedEggs = {}
    updateEggBtnText(true)
    rebuildEggDropdownItems()
    if renderFarmableEggs then renderFarmableEggs() end
end)

-- Dropdown Open/Close Controller
local openDropdown = nil

local function closeCurrentDropdown()
    if openDropdown then
        openDropdown.list.Visible = false
        if openDropdown.updateBtnText then
            openDropdown.updateBtnText(false)
        end
        openDropdown = nil
    end
end

local function toggleDropdown(dd)
    if openDropdown == dd then
        closeCurrentDropdown()
    else
        closeCurrentDropdown()
        openDropdown = dd
        dd.list.Visible = true
        if dd.onOpen then dd.onOpen() end
        if dd.updateBtnText then dd.updateBtnText(true) end
    end
end

local rarityDd = {
    btn = rarityBtn,
    list = rarityList,
    onOpen = function() refreshRarityButtons() end,
    updateBtnText = updateRarityBtnText,
}
local biomeDd = {
    btn = biomeBtn,
    list = biomeList,
    onOpen = function() refreshBiomeButtons() end,
    updateBtnText = updateBiomeBtnText,
}
local eggDd = {
    btn = eggBtn,
    list = eggDropList,
    onOpen = function() rebuildEggDropdownItems() end,
    updateBtnText = updateEggBtnText,
}

rarityBtn.MouseButton1Click:Connect(function() toggleDropdown(rarityDd) end)
biomeBtn.MouseButton1Click:Connect(function() toggleDropdown(biomeDd) end)
eggBtn.MouseButton1Click:Connect(function() toggleDropdown(eggDd) end)

local function isInsideGui(guiObj, pos)
    if not (guiObj and guiObj.Visible) then return false end
    local ok, a = pcall(function() return guiObj.AbsolutePosition end)
    local ok2, s = pcall(function() return guiObj.AbsoluteSize end)
    if not (ok and ok2 and a and s) then return false end
    return pos.X >= a.X and pos.X <= a.X + s.X and pos.Y >= a.Y and pos.Y <= a.Y + s.Y
end

addConnection(UserInputService.InputBegan:Connect(function(input)
    if not openDropdown then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local p = input.Position
    if not isInsideGui(openDropdown.btn, p) and not isInsideGui(openDropdown.list, p) then
        closeCurrentDropdown()
    end
end))

-- Scrolling Egg List
local eggListScroll = Instance.new("ScrollingFrame")
eggListScroll.Name = "EggListScroll"
eggListScroll.Size = UDim2.new(1, -16, 1, -104)
eggListScroll.Position = UDim2.new(0, 8, 0, 98)
eggListScroll.BackgroundTransparency = 1
eggListScroll.BorderSizePixel = 0
eggListScroll.ScrollBarThickness = 4
eggListScroll.ScrollBarImageColor3 = Color3.fromRGB(70, 110, 180)
eggListScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
eggListScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
eggListScroll.ZIndex = 1
eggListScroll.Parent = tabEggs

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 3)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = eggListScroll

local listPadding = Instance.new("UIPadding")
listPadding.PaddingTop = UDim.new(0, 2)
listPadding.PaddingBottom = UDim.new(0, 12)
listPadding.PaddingLeft = UDim.new(0, 2)
listPadding.PaddingRight = UDim.new(0, 6)
listPadding.Parent = eggListScroll

-- ============================================================================
-- 2. LIVE SERVER EGG DETECTION & FARMABLE LIST (Pooled & Throttled: Zero-Freeze)
-- ============================================================================

local eggCacheByUid = {}
local rarityByUid = {}
local cardPool = {}
local emptyNoticeLabel = nil
local listDirty = false
local isFetchingSnapshot = false

local function getNetRemote(name)
    local ok, res = pcall(function()
        local net = ReplicatedStorage:FindFirstChild("Packages")
            and ReplicatedStorage.Packages:FindFirstChild("Networking")
        return net and net:FindFirstChild(name)
    end)
    return ok and res or nil
end

local function getEggPosition(r)
    if typeof(r) ~= "table" then return nil end
    if typeof(r.BoundsCFrame) == "CFrame" then return r.BoundsCFrame.Position end
    if typeof(r.BottomCFrame) == "CFrame" then return r.BottomCFrame.Position end
    return nil
end

local function isFarmableEgg(r)
    if not r or typeof(r) ~= "table" then return false end
    local state = tostring(r.State or "")
    if state ~= "Slot" and state ~= "Dropped" then
        return false
    end
    if state == "Claimed" then
        return false
    end
    -- Exclude eggs carried by another player
    if state == "Carried" or (r.CarrierUserId and tostring(r.CarrierUserId) ~= tostring(LocalPlayer and LocalPlayer.UserId)) then
        return false
    end
    return true
end

local function resolveEggFields(r, uid, charPos)
    local rawName = r.DisplayName or r.AssetCategory or r.Name or "Egg"
    local info = getSpeciesInfo(r.DisplayName) or getSpeciesInfo(r.AssetCategory) or getSpeciesInfo(r.Name) or getSpeciesInfo(rawName)
    local disp = (info and info.DisplayName) or r.DisplayName or r.AssetCategory or rawName
    local serverRarity = r.RarityId or r.Rarity or (r.Attributes and r.Attributes.Rarity) or rarityByUid[uid]
    local rarity = (serverRarity and serverRarity ~= "" and serverRarity ~= "Unknown") and serverRarity or ((info and info.Rarity) or "Unknown")
    local rank = (info and info.Rank) or (RARITY_RANK[rarity] or 1)
    local rawArea = r.AreaId
    if rawArea == "Light Dark" then rawArea = "Light & Dark" end
    local biome = (info and info.Biome) or rawArea or "Unknown"
    local pos = getEggPosition(r)
    local dist = (pos and charPos) and (pos - charPos).Magnitude or nil
    return rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist
end

local function requestListUpdate()
    listDirty = true
end

local function getOrCreateCard(idx)
    local item = cardPool[idx]
    if not item then
        local card = Instance.new("Frame")
        card.Name = "Card_" .. tostring(idx)
        card.Size = UDim2.new(1, -8, 0, 34)
        card.BackgroundColor3 = Color3.fromRGB(26, 30, 40)
        card.BorderSizePixel = 0
        card.LayoutOrder = idx
        card.Parent = eggListScroll
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)

        local accent = Instance.new("Frame")
        accent.Name = "Accent"
        accent.Size = UDim2.new(0, 3, 1, -6)
        accent.Position = UDim2.new(0, 4, 0, 3)
        accent.BorderSizePixel = 0
        accent.Parent = card
        Instance.new("UICorner", accent).CornerRadius = UDim.new(0, 2)

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Name = "NameLabel"
        nameLabel.Size = UDim2.new(1, -90, 0, 16)
        nameLabel.Position = UDim2.new(0, 12, 0, 2)
        nameLabel.BackgroundTransparency = 1
        nameLabel.TextColor3 = Color3.fromRGB(230, 240, 255)
        nameLabel.TextSize = 11.5
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
        nameLabel.Parent = card

        local subLabel = Instance.new("TextLabel")
        subLabel.Name = "SubLabel"
        subLabel.Size = UDim2.new(1, -90, 0, 13)
        subLabel.Position = UDim2.new(0, 12, 0, 18)
        subLabel.BackgroundTransparency = 1
        subLabel.TextSize = 10
        subLabel.Font = Enum.Font.Gotham
        subLabel.TextXAlignment = Enum.TextXAlignment.Left
        subLabel.TextTruncate = Enum.TextTruncate.AtEnd
        subLabel.Parent = card

        -- TP Button: Teleports to egg coordinates
        local tpBtn = Instance.new("TextButton")
        tpBtn.Name = "TpBtn"
        tpBtn.Size = UDim2.new(0, 34, 0, 22)
        tpBtn.Position = UDim2.new(1, -78, 0.5, -11)
        tpBtn.BackgroundColor3 = Color3.fromRGB(42, 60, 95)
        tpBtn.Text = "TP"
        tpBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
        tpBtn.TextSize = 10.5
        tpBtn.Font = Enum.Font.GothamBold
        tpBtn.Parent = card
        Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)

        -- Get Button: Placeholder for egg retrieval
        local getBtn = Instance.new("TextButton")
        getBtn.Name = "GetBtn"
        getBtn.Size = UDim2.new(0, 38, 0, 22)
        getBtn.Position = UDim2.new(1, -40, 0.5, -11)
        getBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 80)
        getBtn.Text = "Get"
        getBtn.TextColor3 = Color3.new(1, 1, 1)
        getBtn.TextSize = 10.5
        getBtn.Font = Enum.Font.GothamBold
        getBtn.Parent = card
        Instance.new("UICorner", getBtn).CornerRadius = UDim.new(0, 4)

        item = {
            card      = card,
            accent    = accent,
            nameLabel = nameLabel,
            subLabel  = subLabel,
            tpBtn     = tpBtn,
            getBtn    = getBtn,
            data      = nil,
        }

        addConnection(tpBtn.MouseButton1Click:Connect(function()
            if item.data and item.data.Position then
                pcall(function()
                    local ch = LocalPlayer and LocalPlayer.Character
                    local root = ch and ch:FindFirstChild("HumanoidRootPart")
                    if root then
                        root.CFrame = CFrame.new(item.data.Position + Vector3.new(0, 3, 0))
                    end
                end)
            end
        end))

        addConnection(getBtn.MouseButton1Click:Connect(function()
            if item.data then
                print(string.format("[EggGoTo v11] Get clicked for: %s (Uid: %s)", tostring(item.data.DisplayName), tostring(item.data.Uid)))
            end
        end))

        cardPool[idx] = item
    end
    return item
end

local function renderFarmableEggs()
    if not (screenGui and screenGui.Parent and main and main.Visible and tabEggs and tabEggs.Visible) then
        return
    end

    local charPos = nil
    pcall(function()
        local ch = LocalPlayer and LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        if root then charPos = root.Position end
    end)

    local farmableList = {}
    for uid, r in pairs(eggCacheByUid) do
        if isFarmableEgg(r) then
            local rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist = resolveEggFields(r, uid, charPos)

            if isRarityAllowed(rarity) and isBiomeAllowed(biome) and isEggAllowed(disp, rawName, info) then
                table.insert(farmableList, {
                    Record      = r,
                    Uid         = uid,
                    RawName     = rawName,
                    DisplayName = disp,
                    Rarity      = rarity,
                    Rank        = rank,
                    Biome       = biome,
                    Position    = pos,
                    Distance    = dist or 99999,
                    State       = r.State or "Slot",
                })
            end
        end
    end

    -- Sort: Highest rarity rank first, then closest distance
    table.sort(farmableList, function(a, b)
        if a.Rank ~= b.Rank then
            return a.Rank > b.Rank
        end
        return a.Distance < b.Distance
    end)

    if listHeaderTitle then
        listHeaderTitle.Text = string.format("Farmable Eggs (%d)", #farmableList)
    end

    if #farmableList == 0 then
        if not emptyNoticeLabel then
            emptyNoticeLabel = Instance.new("TextLabel")
            emptyNoticeLabel.Name = "EmptyNotice"
            emptyNoticeLabel.Size = UDim2.new(1, -20, 0, 70)
            emptyNoticeLabel.Position = UDim2.new(0, 10, 0, 20)
            emptyNoticeLabel.BackgroundTransparency = 1
            emptyNoticeLabel.Text = "No farmable eggs match current filter criteria.\n(Adjust Rarity, Biome, or Egg filters, or wait for 5m spawn)"
            emptyNoticeLabel.TextColor3 = Color3.fromRGB(140, 160, 190)
            emptyNoticeLabel.TextSize = 12
            emptyNoticeLabel.Font = Enum.Font.Gotham
            emptyNoticeLabel.TextWrapped = true
            emptyNoticeLabel.Parent = eggListScroll
        end
        emptyNoticeLabel.Visible = true

        for _, item in ipairs(cardPool) do
            item.card.Visible = false
        end
        return
    end

    if emptyNoticeLabel then
        emptyNoticeLabel.Visible = false
    end

    -- Update pooled cards without DOM destruction
    for idx, itemData in ipairs(farmableList) do
        local poolItem = getOrCreateCard(idx)
        poolItem.data = itemData

        local stateTag = itemData.State == "Dropped" and " [DROPPED]" or ""
        local distText = itemData.Distance < 90000 and string.format(" • %dm", math.floor(itemData.Distance)) or ""
        local rarColor = RARITY_COLORS[itemData.Rarity] or Color3.fromRGB(150, 150, 150)

        poolItem.nameLabel.Text = itemData.DisplayName
        poolItem.subLabel.Text = itemData.Biome .. " • " .. itemData.Rarity .. stateTag .. distText
        poolItem.subLabel.TextColor3 = rarColor
        poolItem.accent.BackgroundColor3 = rarColor
        poolItem.card.Visible = true
    end

    -- Hide any extra pooled cards beyond active count
    for idx = #farmableList + 1, #cardPool do
        cardPool[idx].card.Visible = false
    end
end

-- ============================================================================
-- FULL EGG LIST JSON EXPORTER (For diagnostics, rarity audits & alias mapping)
-- ============================================================================

local function copyToClipboard(str)
    local ok = false
    if typeof(setclipboard) == "function" then
        ok = pcall(setclipboard, str)
    end
    if not ok and typeof(toclipboard) == "function" then
        ok = pcall(toclipboard, str)
    end
    return ok
end

local function sanitizeForJson(val, depth)
    depth = depth or 0
    if depth > 6 then return tostring(val) end
    if val == nil then return nil end

    local t = typeof(val)
    if t == "string" or t == "number" or t == "boolean" then
        return val
    elseif t == "Vector3" then
        return {
            X = math.floor(val.X * 10 + 0.5) / 10,
            Y = math.floor(val.Y * 10 + 0.5) / 10,
            Z = math.floor(val.Z * 10 + 0.5) / 10,
        }
    elseif t == "CFrame" then
        local p = val.Position
        return {
            X = math.floor(p.X * 10 + 0.5) / 10,
            Y = math.floor(p.Y * 10 + 0.5) / 10,
            Z = math.floor(p.Z * 10 + 0.5) / 10,
        }
    elseif t == "Color3" then
        return {
            R = math.floor(val.R * 255 + 0.5),
            G = math.floor(val.G * 255 + 0.5),
            B = math.floor(val.B * 255 + 0.5),
        }
    elseif t == "Instance" then
        return {
            ClassName = val.ClassName,
            Name = val.Name,
        }
    elseif t == "EnumItem" then
        return tostring(val)
    elseif t == "table" then
        local count = 0
        for _ in pairs(val) do
            count = count + 1
        end
        local isDenseArray = (count > 0)
        if isDenseArray then
            for i = 1, count do
                if val[i] == nil then
                    isDenseArray = false
                    break
                end
            end
        end

        local clean = {}
        if isDenseArray then
            for i = 1, count do
                clean[i] = sanitizeForJson(val[i], depth + 1)
            end
        else
            for k, v in pairs(val) do
                clean[tostring(k)] = sanitizeForJson(v, depth + 1)
            end
        end
        return clean
    else
        return tostring(val)
    end
end

local function exportEggListJson()
    local charPos = nil
    pcall(function()
        local ch = LocalPlayer and LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        if root then charPos = root.Position end
    end)

    local exportData = {
        exportedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        totalCached = 0,
        totalFarmable = 0,
        farmableEggs = {},
        allEggs = {},
    }

    for uid, r in pairs(eggCacheByUid) do
        exportData.totalCached = exportData.totalCached + 1

        local rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist = resolveEggFields(r, uid, charPos)

        local raritySource = "fallback_unknown"
        if serverRarity and serverRarity ~= "" and serverRarity ~= "Unknown" then
            raritySource = "server"
        elseif info and info.Rarity then
            raritySource = "catalog"
        end

        local eggItem = {
            uid = tostring(uid),
            displayName = disp,
            rawName = rawName,
            assetCategory = r.AssetCategory,
            speciesMatched = (info ~= nil),
            matchedSpeciesName = info and info.DisplayName or nil,
            serverRarityId = serverRarity,
            catalogRarity = info and info.Rarity or nil,
            finalRarity = rarity,
            raritySource = raritySource,
            rank = rank,
            biome = biome,
            state = r.State or "Slot",
            carrierUserId = r.CarrierUserId,
            isFarmable = isFarmableEgg(r),
            position = pos and {
                X = math.floor(pos.X * 10 + 0.5) / 10,
                Y = math.floor(pos.Y * 10 + 0.5) / 10,
                Z = math.floor(pos.Z * 10 + 0.5) / 10,
            } or nil,
            distance = dist and (math.floor(dist * 10 + 0.5) / 10) or nil,
            rawRecord = sanitizeForJson(r),
        }

        table.insert(exportData.allEggs, eggItem)
        if eggItem.isFarmable then
            table.insert(exportData.farmableEggs, eggItem)
        end
    end

    exportData.totalFarmable = #exportData.farmableEggs

    -- Sort farmable eggs: highest rank first, then distance
    table.sort(exportData.farmableEggs, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return (a.distance or 99999) < (b.distance or 99999)
    end)

    local okJson, jsonStr = pcall(function()
        return HttpService:JSONEncode(exportData)
    end)

    if okJson and jsonStr then
        local okClip = copyToClipboard(jsonStr)
        print(string.format("[EggGoTo v11] Exported JSON (%d total, %d farmable, %d bytes) | Clipboard: %s",
            exportData.totalCached,
            exportData.totalFarmable,
            #jsonStr,
            tostring(okClip)
        ))
        return true, exportData.totalFarmable
    else
        warn("[EggGoTo v11] JSONEncode failed: " .. tostring(jsonStr))
        return false, 0
    end
end

-- Server snapshot reconciliation (Non-blocking with re-entrancy guard)
local function syncEggSnapshot()
    if isFetchingSnapshot then return end
    isFetchingSnapshot = true

    task.spawn(function()
        pcall(function()
            local rf = getNetRemote("RF/EggWorld/AskFieldEggSnapshot")
            if not rf then return end

            local okSnapshot, res = pcall(function()
                return rf:InvokeServer()
            end)

            if okSnapshot and typeof(res) == "table" and typeof(res.Records) == "table" then
                -- Index RareSpawns from snapshot
                if typeof(res.RareSpawns) == "table" then
                    for k, v in pairs(res.RareSpawns) do
                        if typeof(v) == "table" and v.EggUid and v.RarityId then
                            rarityByUid[tostring(v.EggUid)] = tostring(v.RarityId)
                        elseif typeof(k) == "string" and typeof(v) == "string" then
                            rarityByUid[k] = v
                        end
                    end
                end

                local currentUids = {}
                for _, r in pairs(res.Records) do
                    if typeof(r) == "table" then
                        local u = tostring(r.Uid or r.EggUid or "")
                        if u ~= "" then
                            currentUids[u] = true
                            eggCacheByUid[u] = r
                            local rId = r.RarityId or r.Rarity or (r.Attributes and r.Attributes.Rarity)
                            if rId and rId ~= "" and rId ~= "Unknown" then
                                rarityByUid[u] = tostring(rId)
                            end
                        end
                    end
                end

                for u in pairs(eggCacheByUid) do
                    if not currentUids[u] then
                        eggCacheByUid[u] = nil
                    end
                end

                requestListUpdate()
            end
        end)
        isFetchingSnapshot = false
    end)
end

-- Push event listener (0ms reaction, updates cache and requests throttled UI update)
local function startPushMonitor()
    local evShift = getNetRemote("RE/EggWorld/FieldEggShifted")
    local evBatch = getNetRemote("RE/EggWorld/FieldEggBatchShifted")
    local evRarities = getNetRemote("RE/EggWorld/FieldEggRaritiesShown")
    local evGone = getNetRemote("RE/EggWorld/FieldEggGone")

    if evShift then
        addConnection(evShift.OnClientEvent:Connect(function(payload)
            if typeof(payload) ~= "table" then return end
            local u = tostring(payload.Uid or payload.EggUid or "")
            if u == "" then return end

            local state = payload.State
            if state == "Claimed" then
                eggCacheByUid[u] = nil
            elseif eggCacheByUid[u] then
                eggCacheByUid[u].State = state
                if payload.CarrierUserId then
                    eggCacheByUid[u].CarrierUserId = payload.CarrierUserId
                end
                if payload.BoundsCFrame then
                    eggCacheByUid[u].BoundsCFrame = payload.BoundsCFrame
                end
            else
                eggCacheByUid[u] = payload
            end
            requestListUpdate()
        end))
    end

    if evBatch then
        addConnection(evBatch.OnClientEvent:Connect(function()
            syncEggSnapshot()
        end))
    end

    if evRarities then
        addConnection(evRarities.OnClientEvent:Connect(function(payload)
            if typeof(payload) == "table" and typeof(payload.RareSpawns) == "table" then
                for k, v in pairs(payload.RareSpawns) do
                    if typeof(v) == "table" and v.EggUid and v.RarityId then
                        rarityByUid[tostring(v.EggUid)] = tostring(v.RarityId)
                    elseif typeof(k) == "string" and typeof(v) == "string" then
                        rarityByUid[k] = v
                    end
                end
            end
            syncEggSnapshot()
        end))
    end

    if evGone then
        addConnection(evGone.OnClientEvent:Connect(function(payload)
            local u = typeof(payload) == "table" and tostring(payload.Uid or "") or tostring(payload or "")
            if u ~= "" then
                eggCacheByUid[u] = nil
                requestListUpdate()
            end
        end))
    end
end

-- Throttled UI Render Loop (Max 3.3 FPS for DOM text updates = ZERO lag / ZERO freeze)
task.spawn(function()
    while not _G.EggGoToUI_Stop do
        task.wait(0.3)
        if listDirty then
            listDirty = false
            pcall(renderFarmableEggs)
        end
    end
end)

-- Background periodic sync (Fallback safety loop, push monitor handles 0ms live events)
task.spawn(function()
    task.wait(0.5)
    startPushMonitor()
    syncEggSnapshot()

    while not _G.EggGoToUI_Stop do
        task.wait(6.0)
        pcall(syncEggSnapshot)
    end
end)

-- ============================================================================
-- INTERACTION & CLEANUP HANDLERS
-- ============================================================================

-- Tab switching handler (ready for modular tab additions)
local function switchTab(tabName)
    if tabName == "Eggs" then
        tabEggs.Visible = true
        tabBtnEggs.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
        tabBtnEggs.TextColor3 = Color3.new(1, 1, 1)
    end
end

addConnection(tabBtnEggs.MouseButton1Click:Connect(function()
    switchTab("Eggs")
end))

-- Menu visibility toggle
local function toggleMenuVisible()
    if openDropdown then closeCurrentDropdown() end
    main.Visible = not main.Visible
end

addConnection(menuToggleBtn.MouseButton1Click:Connect(toggleMenuVisible))

-- Copy JSON handler (Exports full egg list to clipboard)
if copyJsonBtn then
    addConnection(copyJsonBtn.MouseButton1Click:Connect(function()
        local okExport, count = exportEggListJson()
        if okExport then
            copyJsonBtn.Text = "✓ Copied!"
            copyJsonBtn.TextColor3 = Color3.fromRGB(120, 255, 150)
            task.delay(1.5, function()
                if copyJsonBtn and copyJsonBtn.Parent then
                    copyJsonBtn.Text = "Copy JSON"
                    copyJsonBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
                end
            end)
        else
            copyJsonBtn.Text = "Failed"
            copyJsonBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
            task.delay(1.5, function()
                if copyJsonBtn and copyJsonBtn.Parent then
                    copyJsonBtn.Text = "Copy JSON"
                    copyJsonBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
                end
            end)
        end
    end))
end

-- Full cleanup routine
local function fullCleanup()
    if openDropdown then closeCurrentDropdown() end
    _G.EggGoToUI_Stop = true
    disconnectAll()

    if screenGui and screenGui.Parent then
        pcall(function() screenGui:Destroy() end)
    end

    if _G.EggGoToUI_Cleanup == fullCleanup then
        _G.EggGoToUI_Cleanup = nil
    end

    print("[EggGoToUI v11] Full cleanup completed.")
end

_G.EggGoToUI_Cleanup = fullCleanup
addConnection(closeBtn.MouseButton1Click:Connect(fullCleanup))

print("[EggGoToUI v11] Pure UI scaffold loaded successfully.")

end) -- end pcall

if not ok then
    warn("[EggGoToUI v11] FAILED TO LOAD: " .. tostring(err))
end
