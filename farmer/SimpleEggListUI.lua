--[[
    Simple Egg List UI (Grouped per Biome)
    ===========================================================================
    A lightweight, standalone UI displaying live field eggs grouped by biome.
    - Single-domain isolation: Egg list viewer only (no bot/travel/velocity bloat).
    - Live World Eggs: Synchronized via AreaEggSlotsClient + Push RemoteEvents.
    - Clean presentation: Egg names only, grouped under canonical biome headers.
    - One-click Swap Action:
      1. TP towards Forest egg.
      2. Fast pick up (identical to EggGoToUI_v12.lua).
      3. TP towards the clicked target egg.
    - Zero-allocation UI recycling & clean connection teardown.
    ===========================================================================
]]

local ok, err = pcall(function()

-- Terminate any previous running instance of this script
if _G.SimpleEggListUI_Cleanup then
    pcall(_G.SimpleEggListUI_Cleanup)
end
_G.SimpleEggListUI_Stop = false

local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting          = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local t0 = os.clock()
    while not LocalPlayer and (os.clock() - t0 < 3) do
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    end
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

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

-- Forward declaration of modular tables
local Config  = {}
local State   = {}
local Helpers = {}
local UI      = {}
local Engine  = {}

-- ============================================================================
-- SECTION 1: CONFIG DEFAULT
-- ============================================================================

-- 13 Canonical Farmable World Biomes in standard travel order
Config.BiomeOrder = {
    "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
    "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest"
}

-- Canonical Nest & Spawn coordinates per biome
Config.BiomeNestFallbacks = {
    ["Forest"]           = Vector3.new(596.7, 71.4, -327.8),
    ["Lake"]             = Vector3.new(735.9, 71.0, -410.7),
    ["Desert"]           = Vector3.new(943.2, 71.0, -321.4),
    ["Jungle"]           = Vector3.new(1193.2, 71.0, -405.3),
    ["Snow"]             = Vector3.new(1488.2, 75.0, -318.8),
    ["Volcano"]          = Vector3.new(1883.4, 71.0, -393.8),
    ["Abyss Ocean"]      = Vector3.new(2281.6, 71.0, -323.1),
    ["Prehistoric"]      = Vector3.new(2813.6, 71.0, -402.2),
    ["Cosmic"]           = Vector3.new(3395.0, 71.0, -329.2),
    ["Cherry Blossom"]   = Vector3.new(4031.5, 71.0, -392.4),
    ["Titan Temple"]     = Vector3.new(4790.8, 71.5, -326.7),
    ["Light & Dark"]     = Vector3.new(5662.2, 71.5, -324.7),
    ["Light Dark"]       = Vector3.new(5662.2, 71.5, -324.7),
    ["Enchanted Forest"] = Vector3.new(6700.8, 71.5, -353.8),
}

Config.SampleGuardCFrame = CFrame.new(
    605.572266, 69.3371735, -325.887329,
    0.70000118, 0, -0.714141667,
    0, 1, 0,
    0.714141667, 0, 0.70000118
)

Config.BiomeCatalog = {
    {
        Biome = "Forest",
        EggNames = { "Egg", "Forest Egg" },
        Species = {
            { Name = "Chicken" },
            { Name = "Dog" },
            { Name = "Bird", Aliases = { "DesertLark" } },
            { Name = "Owl", Aliases = { "Burrowing Owl" } },
            { Name = "Raccoon" },
            { Name = "Bear" },
            { Name = "Fox", Aliases = { "Mire Fox" } },
            { Name = "Brr", Aliases = { "Brr Brr Patapim" } },
        }
    },
    {
        Biome = "Lake",
        EggNames = { "Lake Egg" },
        Species = {
            { Name = "Frog" },
            { Name = "Duckling" },
            { Name = "Catfish" },
            { Name = "Turtle" },
            { Name = "Trulimero", Aliases = { "Trulimero Trulicina" } },
            { Name = "Swan" },
            { Name = "Axolotl", Aliases = { "Dream Axolotl" } },
            { Name = "Leviathan" },
        }
    },
    {
        Biome = "Desert",
        EggNames = { "Desert Egg" },
        Species = {
            { Name = "Jerboa" },
            { Name = "Fennec", Aliases = { "FennecFox", "Fennec Fox" } },
            { Name = "Camel" },
            { Name = "Tob Tobi", Aliases = { "Tob Tobi Tob Tob", "TobTobi" } },
            { Name = "Snake", Aliases = { "Rattlesnake" } },
            { Name = "Sand Spider" },
            { Name = "Scorpion", Aliases = { "DeathstalkerScorpion" } },
            { Name = "Royal Sphinx", Aliases = { "Irihorus" } },
        }
    },
    {
        Biome = "Jungle",
        EggNames = { "Jungle Egg" },
        Species = {
            { Name = "Toucan" },
            { Name = "Chimpanzee" },
            { Name = "Crocodile" },
            { Name = "Gorilla" },
            { Name = "Orangutini", Aliases = { "Orangutini Ananassini" } },
            { Name = "Spider" },
            { Name = "Tiger" },
            { Name = "King Snake", Aliases = { "Warden" } },
        }
    },
    {
        Biome = "Snow",
        EggNames = { "Snow Egg" },
        Species = {
            { Name = "Penguin" },
            { Name = "Walrus" },
            { Name = "Polar Bear" },
            { Name = "Sabertooth Tiger", Aliases = { "Sabertooth" } },
            { Name = "Mammoth" },
            { Name = "King Mammoth", Aliases = { "Colossal Mammoth" } },
            { Name = "Yeti" },
            { Name = "Ice Dragon" },
        }
    },
    {
        Biome = "Volcano",
        EggNames = { "Volcano Egg", "Lava Egg" },
        Species = {
            { Name = "Lava Gecko", Aliases = { "Ash Gecko" } },
            { Name = "Lava Frog", Aliases = { "Lava frog" } },
            { Name = "Flaming Bull" },
            { Name = "Lava Iguana" },
            { Name = "Chillin Chilli" },
            { Name = "Cerberus" },
            { Name = "Phoenix" },
            { Name = "Lava Dragon", Aliases = { "Dragon" } },
        }
    },
    {
        Biome = "Abyss Ocean",
        EggNames = { "Abyss Ocean Egg", "Ocean Egg", "Depths Egg" },
        Species = {
            { Name = "Parrotfish" },
            { Name = "Swordfish" },
            { Name = "Shark", Aliases = { "Finned Thresher" } },
            { Name = "Orca" },
            { Name = "Whale Shark" },
            { Name = "Beluga Whale", Aliases = { "Alabaster Whale" } },
            { Name = "Kraken" },
            { Name = "El Maja" },
        }
    },
    {
        Biome = "Prehistoric",
        EggNames = { "Prehistoric Egg" },
        Species = {
            { Name = "Dodo" },
            { Name = "Ptero", Aliases = { "Pterodactyl" } },
            { Name = "Anky", Aliases = { "Ankylosaurus" } },
            { Name = "Tri", Aliases = { "Triceratops" } },
            { Name = "Bronto" },
            { Name = "Trala", Aliases = { "Tralaledon" } },
            { Name = "TRex", Aliases = { "TyrannosaurusRex", "T-Rex" } },
            { Name = "Mosas", Aliases = { "Mosasaurus" } },
        }
    },
    {
        Biome = "Cosmic",
        EggNames = { "Cosmic Egg" },
        Species = {
            { Name = "Centapede" },
            { Name = "Cosmic Gecko", Aliases = { "Galaxy Gecko" } },
            { Name = "Cosmic Gorilla", Aliases = { "Cyclops Gorilla" } },
            { Name = "La Vacca", Aliases = { "La Vacca Saturno Saturnita" } },
            { Name = "Cosmic Dragon", Aliases = { "Cave Dragon" } },
            { Name = "Skeleton Boss", Aliases = { "Alien Skeleton Boss", "Cosmic Skeleton Boss" } },
            { Name = "Lunar Dragon", Aliases = { "Eternal Lunar Dragon" } },
            { Name = "Unicorn" },
        }
    },
    {
        Biome = "Cherry Blossom",
        EggNames = { "Cherry Blossom Egg" },
        Species = {
            { Name = "Crane" },
            { Name = "Salamander" },
            { Name = "Red Panda" },
            { Name = "Koi" },
            { Name = "Snowy Owl" },
            { Name = "Stag" },
            { Name = "Oni Tiger" },
            { Name = "Kitsune" },
        }
    },
    {
        Biome = "Titan Temple",
        EggNames = { "Titan Temple Egg" },
        Species = {
            { Name = "Crustcia", Aliases = { "Crustacia", "Crab" } },
            { Name = "Spiderod", Aliases = { "Spideron", "Kaiju Spider", "Kaiju" } },
            { Name = "Bladehide", Aliases = { "Blade Head" } },
            { Name = "Mantaris", Aliases = { "Mantis" } },
            { Name = "Rhinotaur", Aliases = { "Rhino" } },
            { Name = "Mutant Shark", Aliases = { "Shark" } },
            { Name = "Gorilla King", Aliases = { "King Kong" } },
            { Name = "Nightflame", Aliases = { "Godzilla" } },
        }
    },
    {
        Biome = "Light & Dark",
        EggNames = { "Angels & Demons Egg", "Angels Egg", "Demons Egg", "Light Egg", "Dark Egg", "Angel Eggs", "Demon Eggs" },
        Species = {
            { Name = "Light Dove", Aliases = { "Dove" } },
            { Name = "Winged Lamb", Aliases = { "Lamb" } },
            { Name = "Sacred Moth", Aliases = { "Moth" } },
            { Name = "Holy Peacock", Aliases = { "Peacock" } },
            { Name = "Pure Jellyfish", Aliases = { "Jellyfish" } },
            { Name = "Centaur" },
            { Name = "Pegasus" },
            { Name = "ArchAngel" },
            { Name = "Flame Sprite" },
            { Name = "Toro" },
            { Name = "Demon Hound" },
            { Name = "Imp" },
            { Name = "Gargoyle", Aliases = { "Dark Gargoyle" } },
            { Name = "Razor Fang", Aliases = { "RazorFang" } },
            { Name = "Skeleton Horse" },
            { Name = "World Burner" },
        }
    },
    {
        Biome = "Enchanted Forest",
        EggNames = { "Enchanted Forest Egg" },
        Species = {
            { Name = "Prism Gecko" },
            { Name = "Petal Beetle", Aliases = { "Cosmic Beetle Blue", "Cosmic Beetle" } },
            { Name = "Enchanted Bluejay" },
            { Name = "Astral Jackalope", Aliases = { "Spirit Hare", "Jackalope" } },
            { Name = "Spirit Panda" },
            { Name = "Starry Fox", Aliases = { "Cosmic Fox" } },
            { Name = "Celestial Sunlion", Aliases = { "Sunlion" } },
            { Name = "Royal Skywhale", Aliases = { "Skywhale" } },
        }
    },
    {
        Biome = "Halloween Dimension",
        EggNames = {
            "Halloween Dimension Egg", "Halloween Egg", "HalloweenEgg", "Halloween Royal Mimic Egg",
            "Whiskers Egg", "Jesterpop Egg", "Candlefang Egg", "Hooded Gerbil Egg", "Toadstool Egg",
            "Candy Corn Egg", "Halloween Boss Egg", "Zombified Halloween Egg", "Pumpkin Golem Egg",
            "Voidseer Pumpkin Egg", "Abomination Kong Egg", "Gorillastein Egg", "Shelltide Voyager Egg", "Werewolf Egg",
            "Mimic Chest", "Mimic Chest Egg"
        },
        Species = {
            { Name = "Voidseer Pumpkin Egg", Aliases = { "Voidseer Pumpkin" } },
            { Name = "Gorillastein Egg", Aliases = { "Gorillastein", "Abomination Kong" } },
            { Name = "Abomination Kong Egg", Aliases = { "Abomination Kong", "Gorillastein" } },
            { Name = "Ghost Reaper Egg", Aliases = { "Ghost Reaper" } },
            { Name = "Shelltide Voyager Egg", Aliases = { "Shelltide Voyager" } },
            { Name = "Halloween Dimension Egg", Aliases = { "Dimension Egg" } },
            { Name = "BloodBloom Egg", Aliases = { "BloodBloom" } },
            { Name = "Graveyard Brute Egg", Aliases = { "Graveyard Brute" } },
            { Name = "Phantom Dragon Egg", Aliases = { "Phantom Dragon" } },
            { Name = "Pumpkin Golem Egg", Aliases = { "Pumpkin Golem" } },
            { Name = "Soul Phantom Egg", Aliases = { "Soul Phantom" } },
            { Name = "Werewolf Egg", Aliases = { "Werewolf" } },
            { Name = "Halloween Boss Egg", Aliases = { "Halloween Boss" } },
            { Name = "Haunted Scorpio Egg", Aliases = { "Haunted Scorpio" } },
            { Name = "Hexed Pumpkin Egg", Aliases = { "Hexed Pumpkin" } },
            { Name = "Patchwork Imp Egg", Aliases = { "Patchwork Imp" } },
            { Name = "Spirit Knight Egg", Aliases = { "Spirit Knight" } },
            { Name = "Witch Crow Egg", Aliases = { "Witch Crow" } },
            { Name = "Candlefang Egg", Aliases = { "Candlefang" } },
            { Name = "Crowshade Egg", Aliases = { "Crowshade" } },
            { Name = "Toadstool Egg", Aliases = { "Toadstool", "Rotshroom" } },
            { Name = "Zombified Halloween Egg", Aliases = { "Zombified Halloween" } },
            { Name = "Candy Corn Egg", Aliases = { "Candy Corn" } },
            { Name = "Halloween Royal Mimic Egg", Aliases = { "Royal Mimic" } },
            { Name = "Hooded Gerbil Egg", Aliases = { "Hooded Gerbil" } },
            { Name = "Jester Egg", Aliases = { "Jester" } },
            { Name = "Jesterpop Egg", Aliases = { "Jesterpop" } },
            { Name = "Witch Pumpkin Egg", Aliases = { "Witch Pumpkin" } },
            { Name = "Ghost Fish Egg", Aliases = { "Ghost Fish" } },
            { Name = "Mummy Egg", Aliases = { "Mummy" } },
            { Name = "Whiskers Egg", Aliases = { "Whiskers" } },
            { Name = "Hollow Bat Egg", Aliases = { "Hollow Bat" } },
            { Name = "Scarecrow Egg", Aliases = { "Scarecrow" } },
        }
    },
}

Config.HopDistance  = 850
Config.HopInterval  = 0.25

Config.UI = {
    WindowSize     = UDim2.new(0, 280, 0, 390),
    TitleBarHeight = 32,
    Theme = {
        BgDark     = Color3.fromRGB(22, 24, 30),
        TitleBg    = Color3.fromRGB(30, 36, 50),
        Border     = Color3.fromRGB(60, 90, 150),
        HeaderBg   = Color3.fromRGB(28, 36, 54),
        HeaderBar  = Color3.fromRGB(65, 125, 215),
        ItemBg     = Color3.fromRGB(25, 28, 38),
        TextPrimary= Color3.fromRGB(235, 240, 255),
        TextMuted  = Color3.fromRGB(150, 165, 190),
        BtnDefault = Color3.fromRGB(45, 110, 195),
        BtnSuccess = Color3.fromRGB(35, 145, 75),
        BtnActive  = Color3.fromRGB(210, 150, 35),
        BtnHop     = Color3.fromRGB(38, 128, 155),
    }
}

-- ============================================================================
-- SECTION 2: STATE & NORMALIZERS
-- ============================================================================

State.EggCacheByUid = {}
State.ListDirty     = false
State.IsSwapping    = false
State.IsHopping     = false
State.IsCarrying    = false
State.CarriedUid    = nil
State.ForestEggUid  = nil
State.Logs          = {}

local SPECIES_BY_NORM  = {}
local SPECIES_BY_BIOME = {}
local EGG_ALIASES      = {}

Helpers.normalizeSpecies = function(name)
    if not name or type(name) ~= "string" then return "" end
    local str = name:lower():gsub("^%b[]%s*", "")
    str = str:gsub("%s*%(x%d+%)%s*$", ""):gsub("%s*%(%d+%%%)%s*$", ""):gsub("%s*%(%+%d+%)%s*$", "")
    for _, prefix in ipairs({ "rainbow", "golden", "silver", "gold", "shiny" }) do
        str = str:gsub("^" .. prefix .. "%s+", "")
    end
    str = str:gsub("%s*egg%s*$", ""):gsub("^%s*", ""):gsub("%s*$", "")
    return str
end

Helpers.isGenericEggName = function(name)
    if not name or type(name) ~= "string" then return true end
    local clean = Helpers.normalizeSpecies(name)
    if clean == "" or clean == "egg" or clean == "field" or clean == "field egg" or clean == "forest egg"
        or clean == "unknown" or clean == "slot" or clean:find("^field%s*egg") or clean:find("^forest%s*egg") then
        return true
    end
    return false
end

-- Index catalog taxonomy
for _, biomeData in ipairs(Config.BiomeCatalog) do
    if not SPECIES_BY_BIOME[biomeData.Biome] then
        SPECIES_BY_BIOME[biomeData.Biome] = {}
    end
    for _, spec in ipairs(biomeData.Species) do
        local canonicalNorm = Helpers.normalizeSpecies(spec.Name)
        local record = {
            DisplayName = spec.Name,
            Biome       = biomeData.Biome,
        }
        if canonicalNorm ~= "" then
            if not SPECIES_BY_NORM[canonicalNorm] then
                SPECIES_BY_NORM[canonicalNorm] = record
            end
            SPECIES_BY_BIOME[biomeData.Biome][canonicalNorm] = record
        end

        local inner = spec.Name:match("%((.-)%)")
        if inner then
            local innerNorm = Helpers.normalizeSpecies(inner)
            if innerNorm ~= "" then
                if not SPECIES_BY_NORM[innerNorm] then
                    SPECIES_BY_NORM[innerNorm] = record
                end
                SPECIES_BY_BIOME[biomeData.Biome][innerNorm] = record
                EGG_ALIASES[innerNorm] = canonicalNorm
            end
        end

        if spec.Aliases then
            for _, al in ipairs(spec.Aliases) do
                local aNorm = Helpers.normalizeSpecies(al)
                if aNorm ~= "" then
                    EGG_ALIASES[aNorm] = canonicalNorm
                    SPECIES_BY_BIOME[biomeData.Biome][aNorm] = record
                    if not SPECIES_BY_NORM[aNorm] then
                        SPECIES_BY_NORM[aNorm] = record
                    end
                end
            end
        end
    end
end

Helpers.getSpeciesInfo = function(rawName, searchArea)
    if not rawName or type(rawName) ~= "string" or rawName == "" then return nil end
    local clean = Helpers.normalizeSpecies(rawName)
    if clean == "" then return nil end

    if searchArea and searchArea ~= "" and searchArea ~= "Unknown" and SPECIES_BY_BIOME[searchArea] then
        local bRec = SPECIES_BY_BIOME[searchArea][clean]
        if bRec then return bRec end
    end

    if clean == "shark" and (searchArea == "Titan Temple" or searchArea == "Temple") then
        local bTable = SPECIES_BY_BIOME["Titan Temple"]
        if bTable and bTable["mutant shark"] then return bTable["mutant shark"] end
    end

    if SPECIES_BY_NORM[clean] then return SPECIES_BY_NORM[clean] end
    local canonical = EGG_ALIASES[clean]
    if canonical and SPECIES_BY_NORM[canonical] then
        return SPECIES_BY_NORM[canonical]
    end

    for _, bTable in pairs(SPECIES_BY_BIOME) do
        if bTable[clean] then return bTable[clean] end
    end

    return nil
end

Helpers.getSafeUiParent = function()
    if typeof(gethui) == "function" then
        local okHui, h = pcall(gethui)
        if okHui and h then return h end
    end
    local okCore, core = pcall(function() return game:GetService("CoreGui") end)
    if okCore and core then
        local okTest = pcall(function() local f = Instance.new("Folder", core); f:Destroy() end)
        if okTest then return core end
    end
    local pg = LocalPlayer and (LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5))
    return pg or (okCore and core or nil)
end

Helpers.makeDraggable = function(guiObject, dragHandle)
    local dragging, dragStart, startPos = false, nil, nil
    addConnection(dragHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = guiObject.Position
        end
    end))

    addConnection(dragHandle.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    addConnection(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            guiObject.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))
end

-- Logging System & Clipboard Support
Helpers.log = function(msg, tag)
    tag = tag or "INFO"
    local timestamp = os.date("%H:%M:%S")
    local entry = string.format("[%s] [%s] %s", timestamp, tag, tostring(msg))
    table.insert(State.Logs, entry)
    if #State.Logs > 300 then
        table.remove(State.Logs, 1)
    end
    print(string.format("[SimpleEggList] %s", entry))
end

Helpers.copyLogs = function()
    local text = table.concat(State.Logs, "\n")
    if #text == 0 then
        text = string.format("[%s] [INFO] Log is empty.", os.date("%H:%M:%S"))
    end
    local ok = false
    if typeof(setclipboard) == "function" then
        ok = pcall(setclipboard, text)
    elseif typeof(toclipboard) == "function" then
        ok = pcall(toclipboard, text)
    elseif typeof(syn) == "table" and syn.write_clipboard then
        ok = pcall(syn.write_clipboard, text)
    end
    if not ok then
        pcall(function() print(text) end)
    end
    return ok, #State.Logs
end

Helpers.RemoteCache = {}
Helpers.getNetRemote = function(name)
    if Helpers.RemoteCache[name] then return Helpers.RemoteCache[name] end
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then
            Helpers.RemoteCache[name] = r
            return r
        end
    end
    local found = ReplicatedStorage:FindFirstChild(name, true)
    if found then
        Helpers.RemoteCache[name] = found
        return found
    end
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d.Name == name or d.Name:lower() == name:lower() then
            Helpers.RemoteCache[name] = d
            return d
        end
    end
    return nil
end

Helpers.getEggPosition = function(rec, uid)
    if not rec then return nil end
    local pos = nil
    if rec.BoundsCFrame then
        local cf = rec.BoundsCFrame
        if typeof(cf) == "CFrame" then pos = cf.Position
        elseif typeof(cf) == "Vector3" then pos = cf
        elseif typeof(cf) == "table" and cf.Position then pos = cf.Position
        elseif typeof(cf) == "table" and cf.X and cf.Y and cf.Z then
            pos = Vector3.new(cf.X, cf.Y, cf.Z)
        end
    end
    if not pos and rec.Position then pos = rec.Position end
    if pos and pos.Magnitude > 10 then return pos end

    local u = uid or (typeof(rec) == "table" and (rec.Uid or rec.EggUid))
    if u and u ~= "" then
        local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
        local sl = slots and slots:FindFirstChild(u)
        if sl then
            if sl:IsA("BasePart") and sl.Position.Magnitude > 10 then return sl.Position end
            if sl:IsA("Model") then
                if sl.PrimaryPart and sl.PrimaryPart.Position.Magnitude > 10 then return sl.PrimaryPart.Position end
                local okP, piv = pcall(sl.GetPivot, sl)
                if okP and piv and piv.Position.Magnitude > 10 then return piv.Position end
            end
        end
    end
    return nil
end

Helpers.isCarryPrompt = function(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    local n = (prompt.Name or ""):lower()
    local a = (prompt.ActionText or ""):lower()
    local o = (prompt.ObjectText or ""):lower()

    for _, bl in ipairs({ "shop", "hatch", "buy", "purchase", "open", "talk", "dialog", "manor", "trade", "pet" }) do
        if n:find(bl, 1, true) or a:find(bl, 1, true) or o:find(bl, 1, true) then
            return false
        end
    end
    if n:find("carry", 1, true) or n:find("steal", 1, true) or n:find("pickup", 1, true) or n:find("egg", 1, true) then
        return true
    end
    if a:find("carry", 1, true) or a:find("steal", 1, true) or a:find("pick", 1, true) or a:find("take", 1, true) or a:find("grab", 1, true) then
        return true
    end
    return false
end

Helpers.triggerPrompt = function(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    if not Helpers.isCarryPrompt(prompt) then return false end
    local okFire = pcall(function()
        prompt.Enabled = true
        prompt.RequiresLineOfSight = false
        if prompt.MaxActivationDistance < 30 then
            prompt.MaxActivationDistance = 30
        end
        if typeof(fireproximityprompt) == "function" then
            pcall(function() fireproximityprompt(prompt, 1) end)
            pcall(function() fireproximityprompt(prompt, 0) end)
            pcall(function() fireproximityprompt(prompt) end)
        elseif prompt.InputHoldBegin then
            prompt:InputHoldBegin()
            if (prompt.HoldDuration or 0) > 0 then
                task.wait(prompt.HoldDuration)
            end
            prompt:InputHoldEnd()
        end
    end)
    return okFire
end

Helpers.extractSlotKey = function(uid, fallbackBiome)
    fallbackBiome = fallbackBiome or "Forest"
    if not uid then return fallbackBiome .. ":Slot_001" end
    local s = tostring(uid)
    local slot = s:match("Slot_%d+")
    if slot then
        return fallbackBiome .. ":" .. slot
    end
    return fallbackBiome .. ":Slot_001"
end

Helpers.getEggInstance = function(uid)
    if not uid or uid == "" then return nil end
    local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
    local inst = slots and slots:FindFirstChild(uid)
    if inst then return inst end
    local eggs = Workspace:FindFirstChild("Eggs")
    inst = eggs and eggs:FindFirstChild(uid)
    if inst then return inst end
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        local myUidStr = tostring(LocalPlayer and LocalPlayer.UserId or "")
        local myPat = myUidStr ~= "" and (myUidStr .. "_" .. uid) or nil
        inst = (myPat and cra:FindFirstChild(myPat)) or cra:FindFirstChild(uid)
        if inst then return inst end
    end
    return nil
end

Helpers.isHoldingEgg = function()
    local char = LocalPlayer and LocalPlayer.Character
    local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    if char then
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") then
                local low = c.Name:lower()
                local isEggTool = low:find("egg", 1, true)
                    or c:GetAttribute("IsEgg") == true
                    or c:GetAttribute("ItemType") == "Egg"
                    or c:GetAttribute("Category") == "Egg"
                    or c:GetAttribute("EggUid") ~= nil
                    or c:GetAttribute("HalloweenEggUid") ~= nil
                if isEggTool and not c:GetAttribute("IsBat") and not c:GetAttribute("ButterflyNet") and c.Name ~= "ButterflyNet" and c.Name ~= "Bat" then
                    return true
                end
            elseif (c:IsA("Model") or c:IsA("BasePart")) and c.Name ~= "HumanoidRootPart" then
                local isEggModel = c:GetAttribute("IsEgg") == true
                    or c:GetAttribute("ItemType") == "Egg"
                    or c:GetAttribute("Category") == "Egg"
                    or c:GetAttribute("EggUid") ~= nil
                    or c:GetAttribute("HalloweenEggUid") ~= nil
                if not isEggModel and c:IsA("Model") then
                    local low = c.Name:lower()
                    if (low == "egg" or low:find("^egg%s*") or low:find("%s*egg$") or low:find(" egg ")) and not low:find("leg") and not low:find("peg") then
                        isEggModel = true
                    end
                end
                if isEggModel and not c:GetAttribute("IsBat") and not c:GetAttribute("ButterflyNet") and c.Name ~= "ButterflyNet" and c.Name ~= "Bat" then
                    return true
                end
            end
        end
    end
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    local myUidStr = tostring(LocalPlayer and LocalPlayer.UserId or "")
    if cra and myUidStr ~= "" then
        local carryUid = State.CarriedUid or State.ForestEggUid
        if carryUid and carryUid ~= "" then
            local expName = myUidStr .. "_" .. tostring(carryUid)
            local m = cra:FindFirstChild(expName)
            if m then
                local part = m:IsA("BasePart") and m or (m:IsA("Model") and (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)))
                local okP, pv = pcall(function() return m:GetPivot().Position end)
                local pos = (okP and pv) or (part and part.Position)
                if pos and hrp and hrp.Parent and (pos - hrp.Position).Magnitude <= 12.0 then
                    return true
                end
            end
        end
    end
    if State.IsCarrying then
        return true
    end
    return false
end

Helpers.isFarmableEgg = function(r)
    if not r or typeof(r) ~= "table" then return false end
    local state = tostring(r.State or "Slot")
    if state ~= "Slot" and state ~= "Dropped" and state ~= "Ground" and state ~= "Active" and state ~= "Field" and state ~= "Nest" then
        if not (r.PreparedSourceName and r.PreparedSourceName ~= "") then
            return false
        end
    end
    if state == "Claimed" or state == "Carried" then
        return false
    end
    return true
end

Helpers.resolveEggInfo = function(r, uid)
    local rawName = r.DisplayName or r.AssetCategory or r.PreparedSourceName or r.Name or "Egg"
    local rawArea = r.AreaId
    if rawArea == "Light Dark" then rawArea = "Light & Dark" end

    local pos = Helpers.getEggPosition(r, uid)
    local searchArea = rawArea or (typeof(r) == "table" and r.CachedArea)
    if not searchArea or searchArea == "" or searchArea == "Unknown" then
        if pos then
            local x = pos.X
            if x >= 500 and x < 680 then searchArea = "Forest"
            elseif x >= 680 and x < 850 then searchArea = "Lake"
            elseif x >= 850 and x < 1050 then searchArea = "Desert"
            elseif x >= 1050 and x < 1300 then searchArea = "Jungle"
            elseif x >= 1300 and x < 1650 then searchArea = "Snow"
            elseif x >= 1650 and x < 2050 then searchArea = "Volcano"
            elseif x >= 2050 and x < 2500 then searchArea = "Abyss Ocean"
            elseif x >= 2500 and x < 3100 then searchArea = "Prehistoric"
            elseif x >= 3100 and x < 3700 then searchArea = "Cosmic"
            elseif x >= 3700 and x < 4400 then searchArea = "Cherry Blossom"
            elseif x >= 4400 and x < 5200 then searchArea = "Titan Temple"
            elseif x >= 5200 and x < 6100 then searchArea = "Light & Dark"
            elseif x >= 6100 and x < 7500 then searchArea = "Enchanted Forest"
            end
            if searchArea and typeof(r) == "table" then
                r.CachedArea = searchArea
            end
        end
    end

    local info = nil
    if rawName and not Helpers.isGenericEggName(rawName) then
        info = Helpers.getSpeciesInfo(rawName, searchArea)
    end

    if not info and r.PreparedSourceName and type(r.PreparedSourceName) == "string" then
        local base = r.PreparedSourceName:match("([^%.]+)$") or r.PreparedSourceName
        local spaced = base:gsub("(%l)(%u)", "%1 %2")
        info = Helpers.getSpeciesInfo(spaced, searchArea)
        if not info and not Helpers.isGenericEggName(spaced) then
            rawName = spaced
        end
    end

    local disp = (info and info.DisplayName) or (not Helpers.isGenericEggName(rawName) and rawName) or nil
    if not disp or disp == "" or Helpers.isGenericEggName(disp) then
        if searchArea and searchArea ~= "Unknown" and searchArea ~= "" then
            disp = searchArea .. " Egg"
        else
            disp = "Egg"
        end
    end

    local biome = (searchArea and searchArea ~= "" and searchArea ~= "Unknown") and searchArea or ((info and info.Biome) or "Ungrouped")
    return disp, biome
end

-- ============================================================================
-- SECTION 3: UI CREATION & RECYCLING
-- ============================================================================

UI.Elements   = {}
UI.HeaderPool = {}
UI.ItemPool   = {}

UI.build = function()
    local theme = Config.UI.Theme
    local safeParent = Helpers.getSafeUiParent()

    if safeParent then
        local oldGui = safeParent:FindFirstChild("SimpleEggListUI")
        if oldGui then pcall(function() oldGui:Destroy() end) end
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "SimpleEggListUI"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = safeParent
    UI.Elements.ScreenGui = screenGui

    -- Draggable Circular Toggle Button (Opens/Closes Window)
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Name = "MenuToggleBtn"
    toggleBtn.Size = UDim2.new(0, 42, 0, 42)
    toggleBtn.Position = UDim2.new(0, 15, 0.45, 0)
    toggleBtn.BackgroundColor3 = theme.TitleBg
    toggleBtn.Text = "🥚"
    toggleBtn.TextSize = 20
    toggleBtn.TextColor3 = Color3.new(1, 1, 1)
    toggleBtn.Parent = screenGui
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 21)
    local tStroke = Instance.new("UIStroke", toggleBtn)
    tStroke.Color = theme.Border
    tStroke.Thickness = 1.5
    UI.Elements.MenuToggleBtn = toggleBtn
    Helpers.makeDraggable(toggleBtn, toggleBtn)

    -- Main Window Frame
    local main = Instance.new("Frame")
    main.Name = "MainFrame"
    main.Size = Config.UI.WindowSize
    main.Position = UDim2.new(0.5, -140, 0.5, -190)
    main.BackgroundColor3 = theme.BgDark
    main.BorderSizePixel = 0
    main.Parent = screenGui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
    local mainStroke = Instance.new("UIStroke", main)
    mainStroke.Color = theme.Border
    mainStroke.Thickness = 1.5
    UI.Elements.MainFrame = main

    -- Title Bar
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, Config.UI.TitleBarHeight)
    titleBar.BackgroundColor3 = theme.TitleBg
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

    local cornerFix = Instance.new("Frame")
    cornerFix.Name = "CornerFix"
    cornerFix.Size = UDim2.new(1, 0, 0, 10)
    cornerFix.Position = UDim2.new(0, 0, 1, -10)
    cornerFix.BackgroundColor3 = theme.TitleBg
    cornerFix.BorderSizePixel = 0
    cornerFix.Parent = titleBar

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "TitleLabel"
    titleLabel.Size = UDim2.new(1, -115, 1, 0)
    titleLabel.Position = UDim2.new(0, 10, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "Live Eggs by Biome"
    titleLabel.TextColor3 = theme.TextPrimary
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 13
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = titleBar

    local copyLogBtn = Instance.new("TextButton")
    copyLogBtn.Name = "CopyLogBtn"
    copyLogBtn.Size = UDim2.new(0, 56, 0, 22)
    copyLogBtn.Position = UDim2.new(1, -88, 0.5, -11)
    copyLogBtn.BackgroundColor3 = Color3.fromRGB(38, 55, 85)
    copyLogBtn.Text = "📋 Log"
    copyLogBtn.TextColor3 = Color3.fromRGB(220, 235, 255)
    copyLogBtn.TextSize = 10
    copyLogBtn.Font = Enum.Font.GothamBold
    copyLogBtn.Parent = titleBar
    Instance.new("UICorner", copyLogBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.CopyLogBtn = copyLogBtn

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseBtn"
    closeBtn.Size = UDim2.new(0, 22, 0, 22)
    closeBtn.Position = UDim2.new(1, -27, 0.5, -11)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 55)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.TextSize = 11
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.CloseBtn = closeBtn

    Helpers.makeDraggable(main, titleBar)

    addConnection(copyLogBtn.MouseButton1Click:Connect(function()
        local clipOk, count = Helpers.copyLogs()
        copyLogBtn.Text = clipOk and "✓ Copied" or "⚠️ Printed"
        copyLogBtn.BackgroundColor3 = clipOk and Config.UI.Theme.BtnSuccess or Color3.fromRGB(150, 90, 30)
        task.delay(1.2, function()
            if copyLogBtn and copyLogBtn.Parent then
                copyLogBtn.Text = "📋 Log"
                copyLogBtn.BackgroundColor3 = Color3.fromRGB(38, 55, 85)
            end
        end)
    end))

    addConnection(closeBtn.MouseButton1Click:Connect(function()
        main.Visible = false
    end))

    addConnection(toggleBtn.MouseButton1Click:Connect(function()
        main.Visible = not main.Visible
    end))

    -- Hop Distance Control Bar (Adjustable Hop Distance)
    local hopBar = Instance.new("Frame")
    hopBar.Name = "HopControlBar"
    hopBar.Size = UDim2.new(1, -12, 0, 22)
    hopBar.Position = UDim2.new(0, 6, 0, Config.UI.TitleBarHeight + 4)
    hopBar.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    hopBar.BorderSizePixel = 0
    hopBar.Parent = main
    Instance.new("UICorner", hopBar).CornerRadius = UDim.new(0, 4)

    local hopBarStroke = Instance.new("UIStroke", hopBar)
    hopBarStroke.Color = Color3.fromRGB(45, 55, 80)
    hopBarStroke.Thickness = 1

    local hopLbl = Instance.new("TextLabel")
    hopLbl.Name = "HopDistLabel"
    hopLbl.Size = UDim2.new(0, 85, 1, 0)
    hopLbl.Position = UDim2.new(0, 8, 0, 0)
    hopLbl.BackgroundTransparency = 1
    hopLbl.Text = "Hop Distance:"
    hopLbl.TextColor3 = theme.TextMuted
    hopLbl.Font = Enum.Font.GothamBold
    hopLbl.TextSize = 10.5
    hopLbl.TextXAlignment = Enum.TextXAlignment.Left
    hopLbl.Parent = hopBar

    local hopBox = Instance.new("TextBox")
    hopBox.Name = "HopDistanceBox"
    hopBox.Size = UDim2.new(0, 52, 0, 16)
    hopBox.Position = UDim2.new(0, 92, 0.5, -8)
    hopBox.BackgroundColor3 = Color3.fromRGB(32, 38, 55)
    hopBox.Text = tostring(Config.HopDistance or 850)
    hopBox.PlaceholderText = "850"
    hopBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    hopBox.Font = Enum.Font.GothamBold
    hopBox.TextSize = 10.5
    hopBox.ClearTextOnFocus = false
    hopBox.Parent = hopBar
    Instance.new("UICorner", hopBox).CornerRadius = UDim.new(0, 3)
    UI.Elements.HopDistanceBox = hopBox

    local studsLbl = Instance.new("TextLabel")
    studsLbl.Name = "StudsLabel"
    studsLbl.Size = UDim2.new(1, -150, 1, 0)
    studsLbl.Position = UDim2.new(0, 148, 0, 0)
    studsLbl.BackgroundTransparency = 1
    studsLbl.Text = "studs"
    studsLbl.TextColor3 = Color3.fromRGB(130, 145, 175)
    studsLbl.Font = Enum.Font.Gotham
    studsLbl.TextSize = 10
    studsLbl.TextXAlignment = Enum.TextXAlignment.Left
    studsLbl.Parent = hopBar

    addConnection(hopBox.FocusLost:Connect(function()
        local val = tonumber(hopBox.Text)
        if val and val > 0 then
            Config.HopDistance = math.clamp(math.floor(val), 100, 5000)
        end
        hopBox.Text = tostring(Config.HopDistance)
        Helpers.log(string.format("Hop distance updated to %d studs", Config.HopDistance), "INFO")
    end))

    -- Scrolling Frame for Biome Egg List
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "EggListScroll"
    scroll.Size = UDim2.new(1, -12, 1, -Config.UI.TitleBarHeight - 34)
    scroll.Position = UDim2.new(0, 6, 0, Config.UI.TitleBarHeight + 30)
    scroll.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = Color3.fromRGB(50, 80, 140)
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = main
    Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

    local listLayout = Instance.new("UIListLayout")
    listLayout.Padding = UDim.new(0, 2)
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Parent = scroll
    UI.Elements.EggListScroll = scroll
    UI.Elements.ListLayout = listLayout

    local emptyNotice = Instance.new("TextLabel")
    emptyNotice.Name = "EmptyNotice"
    emptyNotice.Size = UDim2.new(1, -20, 0, 60)
    emptyNotice.Position = UDim2.new(0, 10, 0, 20)
    emptyNotice.BackgroundTransparency = 1
    emptyNotice.Text = "No live eggs currently detected on field."
    emptyNotice.TextColor3 = theme.TextMuted
    emptyNotice.TextSize = 11.5
    emptyNotice.Font = Enum.Font.Gotham
    emptyNotice.TextWrapped = true
    emptyNotice.Visible = true
    emptyNotice.Parent = scroll
    UI.Elements.EmptyNotice = emptyNotice
end

-- Header Pool (Zero Allocation UI Recycling)
UI.getHeader = function(idx)
    if UI.HeaderPool[idx] then return UI.HeaderPool[idx] end
    local scroll = UI.Elements.EggListScroll
    local theme = Config.UI.Theme

    local header = Instance.new("Frame")
    header.Name = "BiomeHeader_" .. idx
    header.Size = UDim2.new(1, 0, 0, 24)
    header.BackgroundColor3 = theme.HeaderBg
    header.BorderSizePixel = 0
    header.Parent = scroll
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 4)

    local accentBar = Instance.new("Frame")
    accentBar.Size = UDim2.new(0, 3, 1, -4)
    accentBar.Position = UDim2.new(0, 2, 0, 2)
    accentBar.BackgroundColor3 = theme.HeaderBar
    accentBar.BorderSizePixel = 0
    accentBar.Parent = header
    Instance.new("UICorner", accentBar).CornerRadius = UDim.new(0, 2)

    local label = Instance.new("TextLabel")
    label.Name = "Title"
    label.Size = UDim2.new(1, -14, 1, 0)
    label.Position = UDim2.new(0, 10, 0, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 11
    label.TextColor3 = Color3.fromRGB(220, 235, 255)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = header

    local item = { Frame = header, Label = label }
    UI.HeaderPool[idx] = item
    return item
end

-- Egg Item Pool (Zero Allocation UI Recycling)
UI.getItem = function(idx)
    if UI.ItemPool[idx] then return UI.ItemPool[idx] end
    local scroll = UI.Elements.EggListScroll
    local theme = Config.UI.Theme

    local row = Instance.new("Frame")
    row.Name = "EggRow_" .. idx
    row.Size = UDim2.new(1, 0, 0, 22)
    row.BackgroundColor3 = theme.ItemBg
    row.BorderSizePixel = 0
    row.Parent = scroll
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 3)

    local label = Instance.new("TextLabel")
    label.Name = "NameLabel"
    label.Size = UDim2.new(1, -92, 1, 0)
    label.Position = UDim2.new(0, 8, 0, 0)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 11
    label.TextColor3 = theme.TextPrimary
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.Parent = row

    local hopBtn = Instance.new("TextButton")
    hopBtn.Name = "HopBtn"
    hopBtn.Size = UDim2.new(0, 36, 0, 18)
    hopBtn.Position = UDim2.new(1, -80, 0.5, -9)
    hopBtn.BackgroundColor3 = theme.BtnHop
    hopBtn.Text = "HOP"
    hopBtn.TextColor3 = Color3.new(1, 1, 1)
    hopBtn.Font = Enum.Font.GothamBold
    hopBtn.TextSize = 10
    hopBtn.Parent = row
    Instance.new("UICorner", hopBtn).CornerRadius = UDim.new(0, 3)

    local goBtn = Instance.new("TextButton")
    goBtn.Name = "GoBtn"
    goBtn.Size = UDim2.new(0, 36, 0, 18)
    goBtn.Position = UDim2.new(1, -40, 0.5, -9)
    goBtn.BackgroundColor3 = theme.BtnDefault
    goBtn.Text = "GO"
    goBtn.TextColor3 = Color3.new(1, 1, 1)
    goBtn.Font = Enum.Font.GothamBold
    goBtn.TextSize = 10
    goBtn.Parent = row
    Instance.new("UICorner", goBtn).CornerRadius = UDim.new(0, 3)

    local item = { Frame = row, Label = label, Button = goBtn, HopButton = hopBtn, Data = nil }

    addConnection(hopBtn.MouseButton1Click:Connect(function()
        if item.Data and Engine.hopTowardsEgg then
            Engine.hopTowardsEgg(item.Data, hopBtn)
        end
    end))

    addConnection(goBtn.MouseButton1Click:Connect(function()
        if item.Data and Engine.executeSwapSequence then
            Engine.executeSwapSequence(item.Data, goBtn)
        end
    end))

    UI.ItemPool[idx] = item
    return item
end

-- Render Function: Groups live field eggs per biome
UI.render = function()
    local grouped = {}
    for _, b in ipairs(Config.BiomeOrder) do
        grouped[b] = {}
    end

    local totalEggs = 0
    for uid, r in pairs(State.EggCacheByUid) do
        if Helpers.isFarmableEgg(r) then
            local eggName, biome = Helpers.resolveEggInfo(r, uid)
            local pos = Helpers.getEggPosition(r, uid)
            if not grouped[biome] then
                grouped[biome] = {}
            end
            table.insert(grouped[biome], {
                Uid      = uid,
                Name     = eggName,
                Biome    = biome,
                Position = pos,
                Record   = r,
            })
            totalEggs = totalEggs + 1
        end
    end

    if UI.Elements.EmptyNotice then
        UI.Elements.EmptyNotice.Visible = (totalEggs == 0)
    end

    local layoutOrder = 0
    local headerIdx = 0
    local itemIdx = 0

    -- Helper to render a single biome group
    local function renderBiomeGroup(biomeName)
        local eggs = grouped[biomeName]
        if not eggs or #eggs == 0 then return end

        table.sort(eggs, function(a, b) return a.Name < b.Name end)

        headerIdx = headerIdx + 1
        layoutOrder = layoutOrder + 1
        local h = UI.getHeader(headerIdx)
        h.Label.Text = string.format("%s (%d)", biomeName, #eggs)
        h.Frame.LayoutOrder = layoutOrder
        h.Frame.Visible = true

        for _, eggData in ipairs(eggs) do
            itemIdx = itemIdx + 1
            layoutOrder = layoutOrder + 1
            local it = UI.getItem(itemIdx)
            it.Data = eggData
            it.Label.Text = "• " .. eggData.Name
            it.Button.Text = "GO"
            it.Button.BackgroundColor3 = Config.UI.Theme.BtnDefault
            if it.HopButton then
                it.HopButton.Text = "HOP"
                it.HopButton.BackgroundColor3 = Config.UI.Theme.BtnHop
            end
            it.Frame.LayoutOrder = layoutOrder
            it.Frame.Visible = true
        end
    end

    -- 1. Canonical Farmable Biomes first
    for _, b in ipairs(Config.BiomeOrder) do
        renderBiomeGroup(b)
    end

    -- 2. Any additional biomes with live eggs (e.g. Halloween Dimension, Ungrouped)
    for b in pairs(grouped) do
        local isCanonical = false
        for _, cb in ipairs(Config.BiomeOrder) do
            if cb == b then
                isCanonical = true
                break
            end
        end
        if not isCanonical then
            renderBiomeGroup(b)
        end
    end

    -- Hide remaining pooled headers
    for i = headerIdx + 1, #UI.HeaderPool do
        UI.HeaderPool[i].Frame.Visible = false
    end

    -- Hide remaining pooled items
    for i = itemIdx + 1, #UI.ItemPool do
        UI.ItemPool[i].Frame.Visible = false
    end

    -- Update ScrollingFrame Canvas Size
    if UI.Elements.EggListScroll then
        local totalH = (headerIdx * 26) + (itemIdx * 24) + 10
        UI.Elements.EggListScroll.CanvasSize = UDim2.new(0, 0, 0, totalH)
    end
end

-- ============================================================================
-- SECTION 4: ENGINE & NETWORK SYNCHRONIZATION
-- ============================================================================

-- Ported Teleport Logic from EggGoToUI_v12.lua (snapBeside geometry + true ground raycast)
Engine.teleportTo = function(targetPos, snapBeside, eggModelOrSize)
    if not targetPos then return false end
    local char = LocalPlayer and LocalPlayer.Character
    local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not (hrp and hrp.Parent) then return false end

    local ok = pcall(function()
        local rot = hrp.CFrame - hrp.CFrame.Position
        local finalPos = targetPos

        if snapBeside then
            local diff = Vector3.new(hrp.Position.X - targetPos.X, 0, hrp.Position.Z - targetPos.Z)
            local dir = diff.Magnitude > 0.1 and diff.Unit or Vector3.new(0, 0, 1)

            local eggModel = eggModelOrSize
            if not eggModel and Workspace.GetPartBoundsInRadius then
                local nearby = Workspace:GetPartBoundsInRadius(targetPos, 20)
                for _, p in ipairs(nearby) do
                    local m = p:FindFirstAncestorWhichIsA("Model")
                    if m and m ~= char and not m:IsDescendantOf(char) and m ~= Workspace.Terrain then
                        local mName = m.Name:lower()
                        if mName:find("egg") or m:FindFirstChild("Hitbox") or m:GetAttribute("PreparedSourceName") or m:GetAttribute("IsEgg") then
                            eggModel = m
                            break
                        end
                    end
                end
            end

            local eggRadius = 2.8
            local eggHeight = 5.0
            if typeof(eggModel) == "Instance" then
                local hb = eggModel:FindFirstChild("Hitbox") or (eggModel:IsA("Model") and eggModel.PrimaryPart) or (eggModel:IsA("BasePart") and eggModel)
                if hb and hb:IsA("BasePart") then
                    eggRadius = math.max(hb.Size.X, hb.Size.Z) * 0.5 + 2.2
                    eggHeight = hb.Size.Y
                elseif eggModel:IsA("Model") then
                    local okExt, ext = pcall(eggModel.GetExtentsSize, eggModel)
                    if okExt and ext then
                        eggRadius = math.max(ext.X, ext.Z) * 0.5 + 2.2
                        eggHeight = ext.Y
                    end
                end
            elseif typeof(eggModel) == "number" then
                eggRadius = eggModel + 2.2
            elseif typeof(eggModel) == "Vector3" then
                eggRadius = math.max(eggModel.X, eggModel.Z) * 0.5 + 2.2
                eggHeight = eggModel.Y
            end
            eggRadius = math.clamp(eggRadius, 2.5, 4.0)
            eggHeight = math.clamp(eggHeight, 4.0, 7.0)

            local besideX = targetPos.X + dir.X * eggRadius
            local besideZ = targetPos.Z + dir.Z * eggRadius
            local eggBottomY = targetPos.Y - (eggHeight * 0.5) + 2.8

            -- Ground raycast from above egg to find true floor level beside egg
            local groundY = eggBottomY
            local rayStartY = targetPos.Y + (eggHeight * 0.5) + 12
            local rayOk, rayRes = pcall(function()
                local rParams = RaycastParams.new()
                rParams.FilterType = RaycastFilterType.Exclude
                local ign = { char }
                if typeof(eggModel) == "Instance" then table.insert(ign, eggModel) end
                local eggs = Workspace:FindFirstChild("Eggs")
                if eggs then table.insert(ign, eggs) end
                local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
                if slots then table.insert(ign, slots) end
                local cra = Workspace:FindFirstChild("ClientRenderedAssets")
                if cra then table.insert(ign, cra) end
                rParams.FilterDescendantsInstances = ign
                rParams.IgnoreWater = true
                return Workspace:Raycast(Vector3.new(besideX, rayStartY, besideZ), Vector3.new(0, -150, 0), rParams)
            end)

            if rayOk and rayRes and rayRes.Position then
                groundY = rayRes.Position.Y + 2.8
            else
                local curY = hrp.Position.Y
                if math.abs(curY - eggBottomY) <= 6.0 then
                    groundY = curY
                end
            end

            finalPos = Vector3.new(besideX, groundY, besideZ)
            rot = CFrame.lookAt(finalPos, Vector3.new(targetPos.X, groundY, targetPos.Z)) - finalPos
        else
            local groundY = targetPos.Y
            local rayOk, rayRes = pcall(function()
                local rParams = RaycastParams.new()
                rParams.FilterType = RaycastFilterType.Exclude
                rParams.FilterDescendantsInstances = { char }
                rParams.IgnoreWater = true
                return Workspace:Raycast(Vector3.new(targetPos.X, targetPos.Y + 12, targetPos.Z), Vector3.new(0, -60, 0), rParams)
            end)
            if rayOk and rayRes and rayRes.Position then
                groundY = rayRes.Position.Y + 2.8
            elseif math.abs(hrp.Position.Y - targetPos.Y) <= 4 then
                groundY = hrp.Position.Y
            else
                groundY = targetPos.Y + 2.5
            end
            finalPos = Vector3.new(targetPos.X, groundY, targetPos.Z)
        end

        if hum and hum.Parent then
            hum:UnequipTools()
            hum.PlatformStand = false
            hum.Sit = false
        end

        hrp.CFrame = CFrame.new(finalPos) * rot
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        if hum and hum.Parent then
            hum:Move(Vector3.zero, false)
            if hrp and hrp.Parent then
                hum:MoveTo(hrp.Position)
            end
        end
    end)
    return ok
end

-- Forest Guard & Hit Authority Helpers (Identical to drop/dropper-1.lua)
Helpers.getForestGuard = function()
    local ws = Workspace
    local guard = ws:FindFirstChild("World", true)
    if guard then
        local fg = guard:FindFirstChild("ForestGuardAuthored", true)
            or guard:FindFirstChild("Forest", true)
        if fg then return fg end
    end
    local areas = ws:FindFirstChild("World") and ws.World:FindFirstChild("Areas")
    local guardAreas = areas and areas:FindFirstChild("GuardAreas")
    if guardAreas then
        local fa = guardAreas:FindFirstChild("Forest")
        if fa then
            local g = fa:FindFirstChild("Guard") or fa:FindFirstChild("ForestGuardAuthored")
            if g then return g end
        end
    end
    return nil
end

Helpers.getForestGuardCFrame = function()
    local fg = Helpers.getForestGuard()
    if fg then
        local p = fg:GetPivot()
        if p then return p end
    end
    return Config.SampleGuardCFrame
end

Helpers.rouseGuard = function(guard, areaName)
    local event = Helpers.getNetRemote("RE/GuardPatrol/Rouse")
    if event and guard then
        pcall(function()
            if typeof(firesignal) == "function" then
                firesignal(event.OnClientEvent, guard, areaName)
            elseif typeof(getconnections) == "function" then
                for _, conn in ipairs(getconnections(event.OnClientEvent)) do
                    if conn.Function then
                        task.spawn(conn.Function, guard, areaName)
                    elseif conn.Fire then
                        conn:Fire(guard, areaName)
                    end
                end
            end
        end)
    end
end

Helpers.getForestEggUid = function()
    if State.ForestEggUid and string.find(tostring(State.ForestEggUid), "Forest", 1, true) and not string.find(tostring(State.ForestEggUid), "Enchanted", 1, true) then
        return State.ForestEggUid
    end
    if State.CarriedUid and string.find(tostring(State.CarriedUid), "Forest", 1, true) and not string.find(tostring(State.CarriedUid), "Enchanted", 1, true) then
        return State.CarriedUid
    end
    local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        for _, sl in ipairs(slots:GetChildren()) do
            local low = string.lower(sl.Name)
            if string.find(low, "_forest:slot_", 1, true) or (string.find(low, "forest", 1, true) and not string.find(low, "enchanted", 1, true)) then
                return sl.Name
            end
        end
    end
    return "FirstAreaEgg_11924439055_5979114_Forest:Slot_001"
end

Helpers.nullifyRagdoll = function()
    local char = LocalPlayer and LocalPlayer.Character
    local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    local hum = char and char:FindFirstChildOfClass("Humanoid")

    if hrp and hrp.Parent then
        pcall(function()
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end)
    end
    if char then
        pcall(function()
            char:SetAttribute("RagdollEndTime", 0)
            char:SetAttribute("RagdollTime", 0)
            char:SetAttribute("IsRagdoll", false)
            char:SetAttribute("Ragdolled", false)
        end)
    end
    if hum and hum.Parent and hum.Health > 0 then
        pcall(function()
            hum.PlatformStand = false
            hum.Sit = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end
end

Engine.dropEggSpam = function(count)
    count = count or 8
    local rf = Helpers.getNetRemote("RF/EggWorld/AskFieldEggDrop")
    if not rf then return false end

    for i = 1, count do
        if not Helpers.isHoldingEgg() then break end
        task.spawn(function()
            pcall(function()
                rf:InvokeServer({ Reason = "PlayerRequest" })
            end)
        end)
        task.wait(0.03)
    end
    return true
end

-- Hit Authority Teleport (Strike TP from dropper-1.lua: Prevents Server Rubberband)
Engine.strikeTeleportToTarget = function(forestEggUid, targetEggPos, targetEggInst)
    if not targetEggPos then
        Helpers.log("strikeTeleportToTarget failed: targetEggPos is nil", "ERROR")
        return false
    end

    forestEggUid = forestEggUid or Helpers.getForestEggUid()
    Helpers.log(string.format("strikeTeleportToTarget started: ForestEggUid=%s, TargetPos=%s", tostring(forestEggUid), tostring(targetEggPos)), "STRIKE")

    local char = LocalPlayer and LocalPlayer.Character
    local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    local strikeRemote = Helpers.getNetRemote("RE/GuardPatrol/ForestStrike")
    local guardCFrame = Helpers.getForestGuardCFrame()
    local guard = Helpers.getForestGuard()
    if guard then
        Helpers.rouseGuard(guard, "Forest")
        Helpers.log("Roused Forest guard", "STRIKE")
    else
        Helpers.log("Forest guard not found; using fallback CFrame", "STRIKE")
    end

    local landingPos = targetEggPos
    local strikeConfirmed = false
    local strikeConns = {}

    local function onStrikeConfirmed(source)
        if strikeConfirmed then return end
        strikeConfirmed = true
        for _, c in ipairs(strikeConns) do pcall(function() c:Disconnect() end) end
        table.clear(strikeConns)

        Helpers.log(string.format("Strike confirmed via %s! Teleporting beside target egg at %s", tostring(source or "event"), tostring(landingPos)), "STRIKE")

        -- ONLY TELEPORT AFTER STRIKE IS CONFIRMED BY SERVER!
        targetEggInst = targetEggInst or Helpers.getEggInstance and Helpers.getEggInstance(forestEggUid)
        Engine.teleportTo(landingPos, true, targetEggInst)
        Helpers.nullifyRagdoll()

        -- Drop the Forest bait egg at target location
        task.spawn(function()
            Engine.dropEggSpam(8)
        end)

        -- Position Settle (0.30s Heartbeat loop prevents rubberband)
        local settleStart = os.clock()
        while (os.clock() - settleStart < 0.30) do
            Engine.teleportTo(landingPos, true, targetEggInst)
            RunService.Heartbeat:Wait()
        end

        Helpers.nullifyRagdoll()
        Helpers.log("Position settled at target egg.", "STRIKE")
    end

    -- Listen for server strike packet (SpeedTollOffer, RigSync refresh ragdoll, RagdollEndTime attribute)
    local speedToll = Helpers.getNetRemote("RE/GuardPatrol/SpeedTollOffer")
    if speedToll then
        table.insert(strikeConns, speedToll.OnClientEvent:Connect(function(...)
            onStrikeConfirmed("SpeedTollOffer")
        end))
    end
    local rigRefresh = Helpers.getNetRemote("RE/RigSync/Refresh")
    if rigRefresh then
        table.insert(strikeConns, rigRefresh.OnClientEvent:Connect(function(json)
            if typeof(json) == "string" and string.find(json, "Ragdoll", 1, true) then
                onStrikeConfirmed("RigSync:Ragdoll")
            end
        end))
    end
    if char then
        table.insert(strikeConns, char.AttributeChanged:Connect(function(attr)
            if attr == "RagdollEndTime" and (char:GetAttribute("RagdollEndTime") or 0) > 0 then
                onStrikeConfirmed("Attr:RagdollEndTime")
            end
        end))
    end

    -- Fire ForestStrike to request server hit authority
    if strikeRemote and forestEggUid then
        Helpers.log(string.format("Firing ForestStrike for EggUid=%s", tostring(forestEggUid)), "STRIKE")
        pcall(function()
            strikeRemote:FireServer({
                GuardCFrame = guardCFrame,
                EggUid = forestEggUid,
            })
        end)
    else
        Helpers.log(string.format("Warning: strikeRemote=%s, forestEggUid=%s", tostring(strikeRemote), tostring(forestEggUid)), "WARN")
    end

    -- Await strike confirmation (up to 2.5s)
    local t0 = os.clock()
    while not strikeConfirmed and (os.clock() - t0 < 2.5) do
        task.wait(0.03)
    end

    for _, c in ipairs(strikeConns) do pcall(function() c:Disconnect() end) end
    table.clear(strikeConns)

    -- STRICT GUARD: If server did not strike, DO NOT TELEPORT!
    if not strikeConfirmed then
        Helpers.log("Strike TIMEOUT after 2.5s (Server did not confirm hit authority)", "ERROR")
        return false
    end

    return true
end

-- Find a live or fallback Forest egg
Engine.findForestEgg = function()
    -- 1. Scan cached eggs in State.EggCacheByUid where biome is Forest (ACTUAL live egg)
    for uid, r in pairs(State.EggCacheByUid) do
        if Helpers.isFarmableEgg(r) then
            local eggName, b = Helpers.resolveEggInfo(r, uid)
            if b == "Forest" then
                local pos = Helpers.getEggPosition(r, uid)
                if pos and pos.Magnitude > 10 then
                    Helpers.log(string.format("Found live Forest egg in cache: %s (%s) at %s", tostring(eggName), tostring(uid), tostring(pos)), "FOREST")
                    return uid, pos, nil
                end
            end
        end
    end

    -- 2. Scan AreaEggSlotsClient directly for any slot with "forest" in name (excluding "enchanted")
    local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        for _, sl in ipairs(slots:GetChildren()) do
            local low = sl.Name:lower()
            if low:find("forest", 1, true) and not low:find("enchanted", 1, true) then
                local p = (sl:IsA("BasePart") and sl.Position)
                    or (sl:IsA("Model") and (sl.PrimaryPart and sl.PrimaryPart.Position or sl:GetPivot().Position))
                if p and p.Magnitude > 10 then
                    Helpers.log(string.format("Found Forest slot in AreaEggSlotsClient: %s at %s", tostring(sl.Name), tostring(p)), "FOREST")
                    return sl.Name, p, sl
                end
            end
        end
    end

    -- 3. Fallback position for Forest egg nest
    local fbPos = Config.BiomeNestFallbacks["Forest"]
    Helpers.log(string.format("Using Forest fallback nest pos: %s", tostring(fbPos)), "FOREST")
    return "ForestSlotFallback", fbPos, nil
end

-- Fast pickup implementation matching EggGoToUI_v12.lua (automatic spam pickup)
Engine.fastPickup = function(eggUid, eggPos, maxDuration)
    maxDuration = maxDuration or 3.5
    local rf = Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")
    local t0 = os.clock()
    local promptCount = 0

    Helpers.log(string.format("fastPickup started for Uid=%s, Pos=%s", tostring(eggUid), tostring(eggPos)), "PICKUP")

    local eggInst = Helpers.getEggInstance(eggUid)
    if eggPos then
        Engine.teleportTo(eggPos, true, eggInst)
    end

    local slotKey = Helpers.extractSlotKey(eggUid, "Forest")

    while (os.clock() - t0 < maxDuration) do
        if Helpers.isHoldingEgg() or State.IsCarrying then
            Helpers.log(string.format("fastPickup confirmed carrying after %.2fs", os.clock() - t0), "PICKUP")
            return true
        end

        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
        if hrp and eggPos and (hrp.Position - eggPos).Magnitude > 8.0 then
            Engine.teleportTo(eggPos, true, eggInst)
        end

        -- 1. Move SmartPromptPart to player and trigger its ProximityPrompt unconditionally
        local spp = Workspace:FindFirstChild("SmartPromptPart")
        if spp then
            if hrp and spp:IsA("BasePart") then
                pcall(function() spp.CFrame = hrp.CFrame end)
            end
            for _, pr in ipairs(spp:GetDescendants()) do
                if pr:IsA("ProximityPrompt") and Helpers.isCarryPrompt(pr) then
                    Helpers.triggerPrompt(pr)
                    promptCount = promptCount + 1
                end
            end
        end

        -- 2. Trigger ProximityPrompt on targeted egg instance (if present)
        if not eggInst then
            eggInst = Helpers.getEggInstance(eggUid)
        end
        if eggInst then
            for _, pr in ipairs(eggInst:GetDescendants()) do
                if pr:IsA("ProximityPrompt") and Helpers.isCarryPrompt(pr) then
                    Helpers.triggerPrompt(pr)
                    promptCount = promptCount + 1
                end
            end
        end

        -- 3. Automatic proximity sweep on all slots in AreaEggSlotsClient in Forest
        local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
        if slots and hrp then
            for _, sl in ipairs(slots:GetChildren()) do
                local low = sl.Name:lower()
                if low:find("forest", 1, true) and not low:find("enchanted", 1, true) then
                    local p = (sl:IsA("BasePart") and sl.Position)
                        or (sl:IsA("Model") and (sl.PrimaryPart and sl.PrimaryPart.Position or sl:GetPivot().Position))
                    if p and (p - hrp.Position).Magnitude <= 35.0 then
                        for _, pr in ipairs(sl:GetDescendants()) do
                            if pr:IsA("ProximityPrompt") and Helpers.isCarryPrompt(pr) then
                                Helpers.triggerPrompt(pr)
                                promptCount = promptCount + 1
                            end
                        end
                        if rf then
                            local slKey = Helpers.extractSlotKey(sl.Name, "Forest")
                            local slUid = sl:GetAttribute("Uid") or sl:GetAttribute("EggUid") or sl.Name
                            task.spawn(function()
                                local ok, res = pcall(function()
                                    return rf:InvokeServer({
                                        FirstAreaSlotKey = slKey,
                                        Uid = slUid
                                    })
                                end)
                                if ok and res == true then
                                    State.IsCarrying = true
                                    State.CarriedUid = slUid
                                    State.ForestEggUid = slUid
                                end
                            end)
                        end
                    end
                end
            end
        end

        -- 4. Direct invoke on targeted eggUid matching forest.log
        if rf and eggUid then
            task.spawn(function()
                local ok, res = pcall(function()
                    return rf:InvokeServer({
                        FirstAreaSlotKey = slotKey,
                        Uid = eggUid
                    })
                end)
                if ok and res == true then
                    State.IsCarrying = true
                    State.CarriedUid = eggUid
                    State.ForestEggUid = eggUid
                else
                    pcall(function()
                        rf:InvokeServer({ Uid = eggUid })
                    end)
                end
            end)
        end

        task.wait(0.035)
    end

    local holding = Helpers.isHoldingEgg() or State.IsCarrying
    Helpers.log(string.format("fastPickup finished: Holding=%s, PromptsFired=%d, Elapsed=%.2fs",
        tostring(holding), promptCount, os.clock() - t0), holding and "PICKUP" or "WARN")
    return holding
end

-- 3-Step Swap Sequence Execution:
-- 1. TP towards forest egg
-- 2. Fast pick up (like on EggGoToUI_v12.lua)
-- 3. Trigger manual hit from dropper-1.lua before TP (Hit Authority so TP does not rubberband)
Engine.executeSwapSequence = function(targetEggData, button)
    if not targetEggData then return end
    if State.IsSwapping then
        Helpers.log("Swap ignored: swap already in progress", "WARN")
        return
    end
    State.IsSwapping = true

    Helpers.log(string.format(">>> SWAP CLICKED: Target '%s' in Biome '%s' (Uid=%s)",
        tostring(targetEggData.Name), tostring(targetEggData.Biome), tostring(targetEggData.Uid)), "SWAP")

    if button then
        button.Text = "..."
        button.BackgroundColor3 = Config.UI.Theme.BtnActive
    end

    task.spawn(function()
        local success = false
        pcall(function()
            local targetEggPos = targetEggData.Position
            if not targetEggPos then
                targetEggPos = Helpers.getEggPosition(targetEggData.Record, targetEggData.Uid)
            end
            if not targetEggPos and Config.BiomeNestFallbacks[targetEggData.Biome] then
                targetEggPos = Config.BiomeNestFallbacks[targetEggData.Biome]
            end

            Helpers.log(string.format("Target pos resolved: %s", tostring(targetEggPos)), "SWAP")

            -- Expose target info to dropper-1.lua
            _G.DropperTargetEggPos = targetEggPos
            _G.DropperTargetEggUid = targetEggData.Uid
            _G.DropperTargetBiome  = targetEggData.Biome

            -- Clear any held item before starting fresh swap
            if Helpers.isHoldingEgg() or State.IsCarrying then
                Helpers.log("Clearing held item before starting swap...", "SWAP")
                Engine.dropEggSpam(4)
                task.wait(0.12)
                State.IsCarrying = false
                State.CarriedUid = nil
            end

            -- Step 1: TP towards Forest egg
            local forestUid, forestPos = Engine.findForestEgg()
            local forestInst = Helpers.getEggInstance(forestUid)
            Helpers.log(string.format("Step 1: TP to Forest egg (Uid=%s, Pos=%s)", tostring(forestUid), tostring(forestPos)), "SWAP")
            if forestPos then
                Engine.teleportTo(forestPos, true, forestInst)
            end

            -- Settle (0.15s) so character physics and server position replicate
            local settleStart = os.clock()
            while (os.clock() - settleStart < 0.15) do
                RunService.Heartbeat:Wait()
            end

            -- Step 2: Automatic Fast pick up Forest egg
            Helpers.log("Step 2: Starting automatic spam pickup of Forest egg...", "SWAP")
            local picked = Engine.fastPickup(forestUid, forestPos, 3.5)

            -- Strict Guard: If egg failed to pick up, DO NOT TP!
            if not picked and not Helpers.isHoldingEgg() and not State.IsCarrying then
                Helpers.log(string.format("Step 2 FAILED: Could not pick up Forest egg (Holding=%s, IsCarrying=%s). Sequence aborted.",
                    tostring(Helpers.isHoldingEgg()), tostring(State.IsCarrying)), "ERROR")
                if button and button.Parent then
                    button.Text = "FAIL"
                    button.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
                    task.delay(1.5, function()
                        if button and button.Parent then
                            button.Text = "GO"
                            button.BackgroundColor3 = Config.UI.Theme.BtnDefault
                        end
                    end)
                end
                State.IsSwapping = false
                return
            end

            local carriedForestUid = State.CarriedUid or State.ForestEggUid or forestUid or Helpers.getForestEggUid()
            Helpers.log(string.format("Step 2 SUCCESS: Forest egg held (Uid=%s). Proceeding to Step 3 (Hit Authority & TP)...", tostring(carriedForestUid)), "SWAP")

            -- Step 3: Trigger manual hit from dropper-1.lua before TP!
            if targetEggPos then
                local targetEggInst = Helpers.getEggInstance(targetEggData.Uid)

                if _G.Dropper_Engine and typeof(_G.Dropper_Engine.handleForestPickup) == "function" and _G.Dropper_State then
                    Helpers.log(string.format("Step 3: Delegating to Dropper_Engine.handleForestPickup (Uid=%s)", tostring(carriedForestUid)), "SWAP")
                    _G.Dropper_State.IsActive = false
                    _G.Dropper_State.CurrentPhase = "IDLE"
                    _G.Dropper_State.TargetBiomeLocation = targetEggPos
                    _G.Dropper_State.TargetBiome = targetEggData.Biome
                    _G.Dropper_State.TargetEggUid = targetEggData.Uid
                    _G.Dropper_Engine.handleForestPickup(carriedForestUid)
                    success = true
                else
                    Helpers.log(string.format("Step 3: Executing internal strikeTeleportToTarget (Uid=%s)", tostring(carriedForestUid)), "SWAP")
                    success = Engine.strikeTeleportToTarget(carriedForestUid, targetEggPos, targetEggInst)
                end
            else
                Helpers.log("Step 3 FAILED: targetEggPos is nil", "ERROR")
            end
        end)

        Helpers.log(string.format("<<< SWAP FINISHED: Result=%s", success and "SUCCESS" or "FAIL"), success and "SWAP" or "ERROR")

        if button and button.Parent then
            button.Text = success and "✓" or "FAIL"
            button.BackgroundColor3 = success and Config.UI.Theme.BtnSuccess or Color3.fromRGB(200, 60, 60)
            task.delay(1.2, function()
                if button and button.Parent then
                    button.Text = "GO"
                    button.BackgroundColor3 = Config.UI.Theme.BtnDefault
                end
            end)
        end

        State.IsSwapping = false
    end)
end

-- Hop Towards Target Egg (Chunked hopping with adjustable distance, no pickup / no return)
Engine.hopTowardsEgg = function(targetEggData, button)
    if not targetEggData then return end
    if State.IsHopping or State.IsSwapping then
        Helpers.log("Cannot hop: movement or swap already in progress", "WARN")
        return
    end

    State.IsHopping = true

    Helpers.log(string.format(">>> HOP CLICKED: Target '%s' in Biome '%s' (Uid=%s)",
        tostring(targetEggData.Name), tostring(targetEggData.Biome), tostring(targetEggData.Uid)), "HOP")

    if button and button.Parent then
        button.Text = "..."
        button.BackgroundColor3 = Config.UI.Theme.BtnActive
    end

    task.spawn(function()
        local success = false
        pcall(function()
            local targetEggPos = targetEggData.Position
            if not targetEggPos then
                targetEggPos = Helpers.getEggPosition(targetEggData.Record, targetEggData.Uid)
            end
            if not targetEggPos and Config.BiomeNestFallbacks[targetEggData.Biome] then
                targetEggPos = Config.BiomeNestFallbacks[targetEggData.Biome]
            end

            if not targetEggPos then
                Helpers.log("HOP FAILED: targetEggPos is nil", "ERROR")
                return
            end

            local char = LocalPlayer and LocalPlayer.Character
            local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
            if not (hrp and hrp.Parent) then
                Helpers.log("HOP FAILED: Character/HumanoidRootPart not found", "ERROR")
                return
            end

            local startPos = hrp.Position
            local landingPos = Vector3.new(targetEggPos.X, targetEggPos.Y + 2.5, targetEggPos.Z)
            local totalDist = (landingPos - startPos).Magnitude
            local hopDist = math.clamp(Config.HopDistance or 850, 100, 5000)
            local hopInterval = Config.HopInterval or 0.25

            Helpers.log(string.format("Hopping from %s to %s (Dist: %.1f studs, Chunk: %d)",
                tostring(startPos), tostring(landingPos), totalDist, hopDist), "HOP")

            if totalDist <= (hopDist + 50) then
                hrp.CFrame = CFrame.new(landingPos)
                hrp.AssemblyLinearVelocity = Vector3.zero
                if hrp.AssemblyAngularVelocity then
                    hrp.AssemblyAngularVelocity = Vector3.zero
                end
            else
                local hops = math.ceil(totalDist / hopDist)
                for h = 1, hops do
                    local alpha = h / hops
                    hrp.CFrame = CFrame.new(startPos:Lerp(landingPos, alpha))
                    hrp.AssemblyLinearVelocity = Vector3.zero
                    if hrp.AssemblyAngularVelocity then
                        hrp.AssemblyAngularVelocity = Vector3.zero
                    end
                    if h < hops then
                        task.wait(hopInterval)
                    end
                end
                hrp.CFrame = CFrame.new(landingPos)
                hrp.AssemblyLinearVelocity = Vector3.zero
                if hrp.AssemblyAngularVelocity then
                    hrp.AssemblyAngularVelocity = Vector3.zero
                end
            end

            if Helpers.nullifyRagdoll then
                pcall(Helpers.nullifyRagdoll)
            end

            success = true
        end)

        Helpers.log(string.format("<<< HOP FINISHED: Result=%s", success and "SUCCESS" or "FAIL"), success and "HOP" or "ERROR")

        if button and button.Parent then
            button.Text = success and "✓" or "FAIL"
            button.BackgroundColor3 = success and Config.UI.Theme.BtnSuccess or Color3.fromRGB(200, 60, 60)
            task.delay(1.2, function()
                if button and button.Parent then
                    button.Text = "HOP"
                    button.BackgroundColor3 = Config.UI.Theme.BtnHop
                end
            end)
        end

        State.IsHopping = false
    end)
end

Engine.Sync = {}

Engine.Sync.clearAllEggs = function(reason)
    table.clear(State.EggCacheByUid)
    State.ListDirty = true
    if UI.render then pcall(UI.render) end
end

Engine.Sync.startPushMonitor = function()
    local function connectRemote(name, callback)
        local rem = Helpers.getNetRemote(name)
        if rem and rem:IsA("RemoteEvent") then
            addConnection(rem.OnClientEvent:Connect(callback))
        end
    end

    connectRemote("RE/EggWorld/FieldEggShifted", function(payload)
        if typeof(payload) ~= "table" then return end
        local u = tostring(payload.Uid or payload.EggUid or "")
        if u == "" then return end

        local state = payload.State
        if state == "Claimed" then
            State.EggCacheByUid[u] = nil
        elseif State.EggCacheByUid[u] then
            State.EggCacheByUid[u].State = state
            if payload.BoundsCFrame then
                State.EggCacheByUid[u].BoundsCFrame = payload.BoundsCFrame
            end
        else
            State.EggCacheByUid[u] = payload
        end
        State.ListDirty = true
    end)

    connectRemote("RE/EggWorld/FieldEggBatchShifted", function(batch)
        Engine.Sync.clearAllEggs("BatchShifted")
        if typeof(batch) == "table" then
            for uid, data in pairs(batch) do
                State.EggCacheByUid[tostring(uid)] = data
            end
            State.ListDirty = true
        end
        task.delay(0.2, function()
            pcall(Engine.Sync.syncAreaEggSlotsESP)
            pcall(Engine.Sync.syncEggSnapshot)
        end)
    end)

    connectRemote("RE/EggWorld/FieldEggCycleCountdown", function(val)
        local cd = tonumber(val) or (typeof(val) == "table" and tonumber(val.Countdown or val.Time or val.Seconds))
        if cd and cd <= 1 then
            Engine.Sync.clearAllEggs("CycleCountdown")
        end
    end)

    -- Lighting Night Transition Reset
    local okLighting, lighting = pcall(function() return game:GetService("Lighting") end)
    if okLighting and lighting then
        local lastClockTime = lighting.ClockTime
        addConnection(lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
            local cur = lighting.ClockTime
            local prev = lastClockTime or cur
            lastClockTime = cur
            local wasDay = (prev >= 6 and prev < 18)
            local isNight = (cur >= 18 or cur < 6)
            if wasDay and isNight then
                Engine.Sync.clearAllEggs("NightTransition")
                task.delay(0.5, function()
                    pcall(Engine.Sync.syncAreaEggSlotsESP)
                    pcall(Engine.Sync.syncEggSnapshot)
                end)
            end
        end))
    end

    connectRemote("RE/EggWorld/FieldEggRaritiesShown", function(payload)
        if typeof(payload) == "table" then
            State.ListDirty = true
        end
    end)

    connectRemote("RE/EggWorld/FieldEggGone", function(uid)
        local u = tostring(uid or "")
        if u ~= "" then
            State.EggCacheByUid[u] = nil
            State.ListDirty = true
        end
    end)

    connectRemote("RE/EggWorld/FieldEggCarry", function(payload)
        if typeof(payload) == "table" then
            if payload.IsCarrying == true or (payload.Uid and payload.IsCarrying ~= false) then
                State.IsCarrying = true
                local u = payload.Uid or payload.EggUid
                if u and tostring(u) ~= "" then
                    State.CarriedUid = tostring(u)
                    if string.find(tostring(u), "Forest", 1, true) and not string.find(tostring(u), "Enchanted", 1, true) then
                        State.ForestEggUid = tostring(u)
                    end
                end
                Helpers.log(string.format("FieldEggCarry: Carrying=true (Uid=%s)", tostring(u)), "EVENT")
            elseif payload.IsCarrying == false then
                State.IsCarrying = false
                State.CarriedUid = nil
                Helpers.log("FieldEggCarry: Carrying=false", "EVENT")
            end
        end
    end)

    -- Native 0ms local AreaEggSlotsClient hooks
    local slotsContainer = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slotsContainer then
        addConnection(slotsContainer.ChildAdded:Connect(function(child)
            local uid = child.Name
            if uid and uid ~= "" then
                local cf = nil
                if child:IsA("BasePart") then
                    cf = child.CFrame
                elseif child:IsA("Model") then
                    local okP, piv = pcall(function() return child:GetPivot() end)
                    if okP and piv and piv.Position.Magnitude > 10 then cf = piv end
                    if not cf and child.PrimaryPart then cf = child.PrimaryPart.CFrame end
                end

                local rawSrc = child:GetAttribute("PreparedSourceName")
                local existing = State.EggCacheByUid[uid]
                if not existing then
                    existing = {
                        Uid = uid,
                        State = "Slot",
                        BoundsCFrame = cf,
                        Position = cf and cf.Position or nil,
                        PreparedSourceName = rawSrc,
                    }
                    State.EggCacheByUid[uid] = existing
                else
                    if cf and cf.Position.Magnitude > 10 then
                        existing.BoundsCFrame = cf
                        existing.Position = cf.Position
                    end
                    if rawSrc and rawSrc ~= "" then existing.PreparedSourceName = rawSrc end
                end
                State.ListDirty = true
            end
        end))

        addConnection(slotsContainer.ChildRemoved:Connect(function(child)
            local uid = child.Name
            if uid and uid ~= "" then
                State.EggCacheByUid[uid] = nil
                State.ListDirty = true
            end
        end))
    end
end

Engine.Sync.syncAreaEggSlotsESP = function()
    local container = Workspace:FindFirstChild("AreaEggSlotsClient")
    if not container then return false end

    for _, child in ipairs(container:GetChildren()) do
        local uid = child.Name
        if uid and uid ~= "" then
            local cf = nil
            if child:IsA("BasePart") then
                cf = child.CFrame
            elseif child:IsA("Model") then
                local okP, piv = pcall(function() return child:GetPivot() end)
                if okP and piv and piv.Position.Magnitude > 10 then cf = piv end
                if not cf and child.PrimaryPart then cf = child.PrimaryPart.CFrame end
            end

            local rawSrc = child:GetAttribute("PreparedSourceName")
            local existing = State.EggCacheByUid[uid]
            if not existing then
                existing = {
                    Uid = uid,
                    State = "Slot",
                    BoundsCFrame = cf,
                    Position = cf and cf.Position or nil,
                    PreparedSourceName = rawSrc,
                }
                State.EggCacheByUid[uid] = existing
            else
                if cf and cf.Position.Magnitude > 10 then
                    existing.BoundsCFrame = cf
                    existing.Position = cf.Position
                end
                if rawSrc and rawSrc ~= "" then existing.PreparedSourceName = rawSrc end
            end
        end
    end
    State.ListDirty = true
    return true
end

Engine.Sync.syncEggSnapshot = function()
    local rf = Helpers.getNetRemote("RF/EggWorld/AskFieldEggSnapshot") or Helpers.getNetRemote("RF/EggWorld/GetEggSnapshot")
    if not rf then return end
    local okSnap, res = pcall(function() return rf:InvokeServer() end)
    if okSnap and typeof(res) == "table" then
        if typeof(res.Records) == "table" then
            local currentUids = {}
            for _, r in pairs(res.Records) do
                if typeof(r) == "table" then
                    local u = tostring(r.Uid or r.EggUid or "")
                    if u ~= "" then
                        currentUids[u] = true
                        State.EggCacheByUid[u] = r
                    end
                end
            end
            for u in pairs(State.EggCacheByUid) do
                if not currentUids[u] then
                    State.EggCacheByUid[u] = nil
                end
            end
            State.ListDirty = true
        elseif typeof(res) == "table" then
            local currentUids = {}
            for uid, egg in pairs(res) do
                local u = tostring(uid)
                currentUids[u] = true
                State.EggCacheByUid[u] = egg
            end
            for u in pairs(State.EggCacheByUid) do
                if not currentUids[u] then
                    State.EggCacheByUid[u] = nil
                end
            end
            State.ListDirty = true
        end
    end
end

-- Full Cleanup Routine
Engine.Cleanup = function()
    _G.SimpleEggListUI_Stop = true
    disconnectAll()

    if UI.Elements.ScreenGui then
        pcall(function() UI.Elements.ScreenGui:Destroy() end)
    end

    table.clear(State.EggCacheByUid)
    table.clear(State.Logs)
    table.clear(UI.HeaderPool)
    table.clear(UI.ItemPool)
    table.clear(Helpers.RemoteCache)

    _G.DropperTargetEggPos = nil
    _G.DropperTargetEggUid = nil
    _G.DropperTargetBiome  = nil
end

_G.SimpleEggListUI_Cleanup = Engine.Cleanup

-- Build UI & Start Engine
UI.build()
Helpers.log("SimpleEggListUI initialized successfully.", "INIT")

-- Immediate hydration
pcall(Engine.Sync.syncAreaEggSlotsESP)
pcall(Engine.Sync.syncEggSnapshot)
pcall(UI.render)

-- Start network listeners
Engine.Sync.startPushMonitor()

-- Throttled 0.3s DOM Loop
task.spawn(function()
    while not _G.SimpleEggListUI_Stop do
        task.wait(0.3)
        if State.ListDirty then
            State.ListDirty = false
            pcall(UI.render)
        end
    end
end)

-- Periodic 30s background safety sync
task.spawn(function()
    while not _G.SimpleEggListUI_Stop do
        task.wait(30.0)
        pcall(Engine.Sync.syncEggSnapshot)
    end
end)

end)

if not ok then
    warn("[SimpleEggListUI] Initialization error:", err)
end
