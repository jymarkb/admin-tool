--[[
    Egg Go-To UI v12 (Modular Clean Architecture)
    ===========================================================================================
    Phase 2: Grouped Modular Architecture
    Eliminates monolithic bloat by cleanly separating into 4 distinct architectural layers:

    1. CONFIG DEFAULT
       - Taxonomy, Rarity colors & ranks (Common up to Divine)
       - 13 Canonical farmable world biomes catalog & species aliases
       - Dual-speed velocity defaults (Go: 360, Carry: 300)
       - Instant recovery physics parameters (AntiFling, BrakeVelocity, GroundDist)
       - Fast pickup configuration (Burst count, interval, reach distance)
       - UI theme styling & dimensions

    2. UI CODES (Per Panel & Row)
       - Root containers: ScreenGui, Draggable toggle button, Main frame, Topbar
       - Navigation bar: Tab buttons (Eggs, Utility)
       - Panel 1: TabEggs
           Row 1: Activity Status Label (live carrying & velocity info)
           Row 2: Velocity Control Bar (toggle, Go speed box, Carry speed box)
           Row 3: Filter Bar (Biome Dropdown [13 biomes], Rarity Dropdown [up to Divine])
           Row 4: Live Egg List (ScrollFrame, pooled card template, empty notice)
       - Panel 2: TabUtility
           Row 1: Fast Pickup [E] Row (toggle, status)
           Row 2: Instant Recovery Row (test button, status)
           Row 3: No-Clip Row (toggle, status)
           Row 4: Diagnostic Export Row (copy JSON button, status)

    3. HELPER CODE
       - Network remote resolution (getNetRemote)
       - Player, character, and control utilities (getSafeUiParent, enableControls)
       - Proximity prompt filtering & activation (isCarryPrompt, triggerPrompt)
       - Taxonomy & metadata normalizers (normalizeSpecies, getSpeciesInfo, dynamic catalog)
       - Safe JSON serialization (exportEggListJson)

    4. ENGINE (Core & Loop Logic)
       - State management (weAreCarrying, carryUid, velocityEnabled, noclipActive)
       - Dual-speed velocity physics & auto-walk engine
       - Zero-wait instant ragdoll recovery engine
       - Fast pickup [E] burst engine
       - Auto-return to SafeZone engine & midway drop watchdog
       - Server push monitor & Workspace ESP discovery
       - Background throttled loops (Stepped, Heartbeat, 0.3s DOM, 30s Safety)
       - Full cleanup teardown routine
]]

local ok, err = pcall(function()

-- Terminate any previous running instance of this script
if _G.EggGoToUI_Cleanup then
    pcall(_G.EggGoToUI_Cleanup)
end
_G.EggGoToUI_Stop = false

local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local GuiService        = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local t0 = os.clock()
    while not LocalPlayer and (os.clock() - t0 < 3) do
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    end
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

local myUidStr = tostring(LocalPlayer and LocalPlayer.UserId or "")
local Character = LocalPlayer and LocalPlayer.Character
local Humanoid  = Character and Character:FindFirstChildOfClass("Humanoid")
local RootPart  = Character and Character:FindFirstChild("HumanoidRootPart")
local hum = Humanoid
local hrp = RootPart

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
    if Engine and Engine.State and Engine.State.HwFolderConns then
        for _, conn in ipairs(Engine.State.HwFolderConns) do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(Engine.State.HwFolderConns)
    end
end

-- Forward declaration of modular tables
local Config  = {}
local UI      = {}
local Helpers = {}
local Engine  = {}

-- ============================================================================
-- SECTION 1: CONFIG DEFAULT
-- ============================================================================

-- 1.1 Rarity Taxonomy, Colors & Ranks (Common to Divine)
Config.Taxonomy = {
    RarityColors = {
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
        ["Brainrot"]  = Color3.fromRGB(240, 60,  180),
        ["1%"]        = Color3.fromRGB(255, 105, 180),
    },

    RarityRank = {
        ["Common"] = 1, ["Uncommon"] = 2, ["Rare"] = 3, ["Epic"] = 4, ["Legendary"] = 5,
        ["Mythic"] = 6, ["Cosmic"] = 7, ["Secret"] = 8, ["Eternal"] = 9, ["Divine"] = 10,
        ["Brainrot"] = 11, ["1%"] = 12,
    },

    -- Farmable rarities: Strictly capped up to Divine (no excess event rarities)
    FarmableRarities = {
        "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine"
    },

    DefaultSelectedRarities = {
        ["Divine"] = true,
        ["Eternal"] = true,
        ["Secret"] = true,
    },

    -- 13 Canonical Farmable World Biomes
    BiomeOrder = {
        "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
        "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest"
    },

    BiomeCatalog = {
    {
        Biome = "Forest",
        EggNames = { "Egg", "Forest Egg" },
        Species = {
            { Name = "Chicken", Rarity = "Common" },
            { Name = "Dog", Rarity = "Common" },
            { Name = "Bird", Rarity = "Uncommon", Aliases = { "DesertLark" } },
            { Name = "Owl", Rarity = "Rare", Aliases = { "Burrowing Owl" } },
            { Name = "Raccoon", Rarity = "Rare" },
            { Name = "Bear", Rarity = "Epic" },
            { Name = "Fox", Rarity = "Epic", Aliases = { "Mire Fox" } },
            { Name = "Brr", Rarity = "Legendary", Aliases = { "Brr Brr Patapim" } },
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
            { Name = "Trulimero", Rarity = "Epic", Aliases = { "Trulimero Trulicina" } },
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
            { Name = "Fennec", Rarity = "Uncommon", Aliases = { "FennecFox", "Fennec Fox" } },
            { Name = "Camel", Rarity = "Rare" },
            { Name = "Tob Tobi", Rarity = "Epic", Aliases = { "Tob Tobi Tob Tob", "TobTobi" } },
            { Name = "Snake", Rarity = "Legendary", Aliases = { "Rattlesnake" } },
            { Name = "Sand Spider", Rarity = "Mythic" },
            { Name = "Scorpion", Rarity = "Mythic", Aliases = { "DeathstalkerScorpion" } },
            { Name = "Royal Sphinx", Rarity = "Cosmic", Aliases = { "Irihorus" } },
        }
    },
    {
        Biome = "Jungle",
        EggNames = { "Jungle Egg" },
        Species = {
            { Name = "Toucan", Rarity = "Rare" },
            { Name = "Chimpanzee", Rarity = "Rare" },
            { Name = "Crocodile", Rarity = "Epic" },
            { Name = "Gorilla", Rarity = "Legendary" },
            { Name = "Orangutini", Rarity = "Legendary", Aliases = { "Orangutini Ananassini" } },
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
            { Name = "Lava Iguana", Rarity = "Legendary" },
            { Name = "Chillin Chilli", Rarity = "Mythic" },
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
            { Name = "Ptero", Rarity = "Legendary", Aliases = { "Pterodactyl" } },
            { Name = "Anky", Rarity = "Mythic", Aliases = { "Ankylosaurus" } },
            { Name = "Tri", Rarity = "Cosmic", Aliases = { "Triceratops" } },
            { Name = "Bronto", Rarity = "Cosmic" },
            { Name = "Trala", Rarity = "Secret", Aliases = { "Tralaledon" } },
            { Name = "TRex", Rarity = "Secret", Aliases = { "TyrannosaurusRex", "T-Rex" } },
            { Name = "Mosas", Rarity = "Eternal", Aliases = { "Mosasaurus" } },
        }
    },
    {
        Biome = "Cosmic",
        EggNames = { "Cosmic Egg" },
        Species = {
            { Name = "Centapede", Rarity = "Epic" },
            { Name = "Cosmic Gecko", Rarity = "Legendary", Aliases = { "Galaxy Gecko" } },
            { Name = "Cosmic Gorilla", Rarity = "Mythic", Aliases = { "Cyclops Gorilla" } },
            { Name = "La Vacca", Rarity = "Cosmic", Aliases = { "La Vacca Saturno Saturnita" } },
            { Name = "Cosmic Dragon", Rarity = "Secret", Aliases = { "Cave Dragon" } },
            { Name = "Skeleton Boss", Rarity = "Secret", Aliases = { "Alien Skeleton Boss", "Cosmic Skeleton Boss" } },
            { Name = "Lunar Dragon", Rarity = "Eternal", Aliases = { "Eternal Lunar Dragon" } },
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
            { Name = "Koi", Rarity = "Cosmic" },
            { Name = "Snowy Owl", Rarity = "Cosmic" },
            { Name = "Stag", Rarity = "Secret" },
            { Name = "Oni Tiger", Rarity = "Eternal" },
            { Name = "Kitsune", Rarity = "Divine" },
        }
    },
    {
        Biome = "Brainrot Event",
        EggNames = { "Brainrot Egg" },
        Species = {
            { Name = "Tung Tung Sahur", Rarity = "Brainrot" },
            { Name = "Bananita Dolphinita", Rarity = "Brainrot" },
            { Name = "Belula Beluga", Rarity = "Brainrot" },
            { Name = "Mangolini Parrochini", Rarity = "Brainrot" },
            { Name = "Bomboclat Crocolat", Rarity = "Brainrot" },
            { Name = "Strawberry Elephant", Rarity = "Brainrot" },
        }
    },
    {
        Biome = "Titan Temple",
        EggNames = { "Titan Temple Egg" },
        Species = {
            { Name = "Crustcia", Rarity = "Legendary", Aliases = { "Crustacia", "Crab" } },
            { Name = "Spiderod", Rarity = "Legendary", Aliases = { "Spideron", "Kaiju Spider", "Kaiju" } },
            { Name = "Bladehide", Rarity = "Mythic", Aliases = { "Blade Head" } },
            { Name = "Mantaris", Rarity = "Cosmic", Aliases = { "Mantis" } },
            { Name = "Rhinotaur", Rarity = "Cosmic", Aliases = { "Rhino" } },
            { Name = "Mutant Shark", Rarity = "Secret", Aliases = { "Shark" } },
            { Name = "Gorilla King", Rarity = "Eternal", Aliases = { "King Kong" } },
            { Name = "Nightflame", Rarity = "Divine", Aliases = { "Godzilla" } },
        }
    },
    {
        Biome = "Light & Dark",
        EggNames = { "Angels & Demons Egg", "Angels Egg", "Demons Egg", "Light Egg", "Dark Egg", "Angel Eggs", "Demon Eggs" },
        Species = {
            { Name = "Light Dove", Rarity = "Legendary", Aliases = { "Dove" } },
            { Name = "Winged Lamb", Rarity = "Mythic", Aliases = { "Lamb" } },
            { Name = "Sacred Moth", Rarity = "Cosmic", Aliases = { "Moth" } },
            { Name = "Holy Peacock", Rarity = "Cosmic", Aliases = { "Peacock" } },
            { Name = "Pure Jellyfish", Rarity = "Secret", Aliases = { "Jellyfish" } },
            { Name = "Centaur", Rarity = "Secret" },
            { Name = "Pegasus", Rarity = "Eternal" },
            { Name = "ArchAngel", Rarity = "Divine" },
            { Name = "Flame Sprite", Rarity = "Legendary" },
            { Name = "Toro", Rarity = "Mythic" },
            { Name = "Demon Hound", Rarity = "Cosmic" },
            { Name = "Imp", Rarity = "Cosmic" },
            { Name = "Gargoyle", Rarity = "Secret", Aliases = { "Dark Gargoyle" } },
            { Name = "Razor Fang", Rarity = "Secret", Aliases = { "RazorFang" } },
            { Name = "Skeleton Horse", Rarity = "Eternal" },
            { Name = "World Burner", Rarity = "Divine" },
        }
    },
    {
        Biome = "Enchanted Forest",
        EggNames = { "Enchanted Forest Egg" },
        Species = {
            { Name = "Prism Gecko", Rarity = "Legendary" },
            { Name = "Petal Beetle", Rarity = "Mythic", Aliases = { "Cosmic Beetle Blue", "Cosmic Beetle" } },
            { Name = "Enchanted Bluejay", Rarity = "Mythic" },
            { Name = "Astral Jackalope", Rarity = "Cosmic", Aliases = { "Spirit Hare", "Jackalope" } },
            { Name = "Spirit Panda", Rarity = "Cosmic" },
            { Name = "Starry Fox", Rarity = "Secret", Aliases = { "Cosmic Fox" } },
            { Name = "Celestial Sunlion", Rarity = "Eternal", Aliases = { "Sunlion" } },
            { Name = "Royal Skywhale", Rarity = "Divine", Aliases = { "Skywhale" } },
        }
    },
    {
        Biome = "Monster Eggs",
        EggNames = { "Monster Egg" },
        Species = {
            { Name = "Monster Egg (Scorpio)", Rarity = "Legendary", Aliases = { "Scorpio" } },
            { Name = "Monster Egg (Froggo)", Rarity = "Mythic", Aliases = { "Froggo" } },
            { Name = "Monster Egg (Crawler)", Rarity = "Cosmic", Aliases = { "Crawler" } },
            { Name = "Monster Egg (Crocodon)", Rarity = "Secret", Aliases = { "Crocodon" } },
            { Name = "Monster Egg (Krakenoid)", Rarity = "Eternal", Aliases = { "Krakenoid" } },
            { Name = "Monster Egg (Dreadscale)", Rarity = "Divine", Aliases = { "Dreadscale" } },
            { Name = "Monster Egg (Mecha Scorpio)", Rarity = "1%", Aliases = { "Mecha Scorpio" } },
            { Name = "Monster Egg (Mecha Froggo)", Rarity = "1%", Aliases = { "Mecha Froggo" } },
            { Name = "Monster Egg (Mecha Crawler)", Rarity = "1%", Aliases = { "Mecha Crawler" } },
            { Name = "Monster Egg (Mecha Crocodon)", Rarity = "1%", Aliases = { "Mecha Crocodon" } },
            { Name = "Monster Egg (Mecha Krakenoid)", Rarity = "1%", Aliases = { "Mecha Krakenoid" } },
            { Name = "Monster Egg (Mecha Dreadscale)", Rarity = "1%", Aliases = { "Mecha Dreadscale" } },
        }
    },
    {
        Biome = "Void Eggs",
        EggNames = { "Void Egg", "Riftborn Egg", "Riftbeasts Egg", "Shattered Rift Egg" },
        Species = {
            { Name = "Riftborn Egg (Rift Eye)", Rarity = "Legendary", Aliases = { "Rift Eye" } },
            { Name = "Riftborn Egg (Voidmaw)", Rarity = "Mythic", Aliases = { "Voidmaw" } },
            { Name = "Riftborn Egg (Ventinal)", Rarity = "Cosmic", Aliases = { "Ventinal" } },
            { Name = "Riftborn Egg (Wendigo)", Rarity = "Secret", Aliases = { "Wendigo" } },
            { Name = "Riftborn Egg (World Eater)", Rarity = "Eternal", Aliases = { "World Eater" } },
            { Name = "Riftbeasts Egg (Void Angler)", Rarity = "Legendary", Aliases = { "Void Angler" } },
            { Name = "Riftbeasts Egg (Riftwing)", Rarity = "Mythic", Aliases = { "Riftwing" } },
            { Name = "Riftbeasts Egg (Dreadclaw)", Rarity = "Cosmic", Aliases = { "Dreadclaw" } },
            { Name = "Riftbeasts Egg (Mawbreaker)", Rarity = "Secret", Aliases = { "Mawbreaker" } },
            { Name = "Riftbeasts Egg (Void Serpent)", Rarity = "Eternal", Aliases = { "Void Serpent" } },
            { Name = "Shattered Rift Egg (Shardling)", Rarity = "Mythic", Aliases = { "Shardling" } },
            { Name = "Shattered Rift Egg (Shattered Ram)", Rarity = "Cosmic", Aliases = { "Shattered Ram" } },
            { Name = "Shattered Rift Egg (Shardwing)", Rarity = "Secret", Aliases = { "Shardwing" } },
            { Name = "Shattered Rift Egg (Shattered Drake)", Rarity = "Eternal", Aliases = { "Shattered Drake" } },
            { Name = "Shattered Rift Egg (Shattered Colossus)", Rarity = "Divine", Aliases = { "Shattered Colossus" } },
        }
    },
    {
        Biome = "Luminous Eggs",
        EggNames = { "Luminous Egg" },
        Species = {
            { Name = "Luminous Egg (Spike)", Rarity = "Legendary", Aliases = { "Spike" } },
            { Name = "Luminous Egg (Spirit Manta)", Rarity = "Mythic", Aliases = { "Spirit Manta" } },
            { Name = "Luminous Egg (Abyss Shark)", Rarity = "Cosmic", Aliases = { "Abyss Shark" } },
            { Name = "Luminous Egg (Electric Eel)", Rarity = "Secret", Aliases = { "Electric Eel" } },
            { Name = "Luminous Egg (Terra Snapper)", Rarity = "Eternal", Aliases = { "Terra Snapper" } },
            { Name = "Luminous Egg (Cthulhu)", Rarity = "Divine", Aliases = { "Cthulhu" } },
            { Name = "Luminous Egg (Luminous Spike)", Rarity = "1%", Aliases = { "Luminous Spike" } },
            { Name = "Luminous Egg (Luminous Spirit Manta)", Rarity = "1%", Aliases = { "Luminous Spirit Manta" } },
            { Name = "Luminous Egg (Luminous Abyss Shark)", Rarity = "1%", Aliases = { "Luminous Abyss Shark" } },
            { Name = "Luminous Egg (Luminous Electric Eel)", Rarity = "1%", Aliases = { "Luminous Electric Eel" } },
            { Name = "Luminous Egg (Luminous Terra Snapper)", Rarity = "1%", Aliases = { "Luminous Terra Snapper" } },
            { Name = "Luminous Egg (Luminous Cthulhu)", Rarity = "1%", Aliases = { "Luminous Cthulhu" } },
        }
    },
    {
        Biome = "Dr. Scramble's Laboratory",
        EggNames = { "Biohazard Egg", "Experimental Pets Egg", "Unstable DNA Egg" },
        Species = {
            { Name = "Biohazard Egg (Toxic Rat)", Rarity = "Mythic", Aliases = { "Toxic Rat" } },
            { Name = "Experimental Pets Egg (Wheel Hamster)", Rarity = "Mythic", Aliases = { "Wheel Hamster" } },
            { Name = "Unstable DNA Egg (Frogfly)", Rarity = "Mythic", Aliases = { "Frogfly" } },
            { Name = "Biohazard Egg (Radcoon)", Rarity = "Cosmic", Aliases = { "Radcoon" } },
            { Name = "Experimental Pets Egg (Stacked Turtle)", Rarity = "Cosmic", Aliases = { "Stacked Turtle" } },
            { Name = "Unstable DNA Egg (Spiderpig)", Rarity = "Cosmic", Aliases = { "Spiderpig" } },
            { Name = "Biohazard Egg (Toucax)", Rarity = "Cosmic", Aliases = { "Toucax" } },
            { Name = "Experimental Pets Egg (Three Headed Chicken)", Rarity = "Cosmic", Aliases = { "Three Headed Chicken" } },
            { Name = "Unstable DNA Egg (Sharkodile)", Rarity = "Secret", Aliases = { "Sharkodile" } },
            { Name = "Biohazard Egg (Nuceodile)", Rarity = "Secret", Aliases = { "Nuceodile" } },
            { Name = "Experimental Pets Egg (Eyeball Crab)", Rarity = "Secret", Aliases = { "Eyeball Crab" } },
            { Name = "Unstable DNA Egg (Rhinobear)", Rarity = "Eternal", Aliases = { "Rhinobear" } },
            { Name = "Biohazard Egg (Nuclear Mantis)", Rarity = "Eternal", Aliases = { "Nuclear Mantis" } },
            { Name = "Experimental Pets Egg (Deadstinger)", Rarity = "Eternal", Aliases = { "Deadstinger" } },
            { Name = "Unstable DNA Egg (Octophant)", Rarity = "Divine", Aliases = { "Octophant" } },
        }
    },
    {
        Biome = "Dr. Scramble's Experiments",
        EggNames = { "Experiment #001 Egg", "Nibbles Egg" },
        Species = {
            { Name = "Experiment #001", Rarity = "Secret" },
            { Name = "Nibbles", Rarity = "Cosmic" },
        }
    },
    {
        Biome = "Extinction Eggs",
        EggNames = { "Extinction Egg" },
        Species = {
            { Name = "Extinction Egg (Glyptodon)", Rarity = "Legendary", Aliases = { "Glyptodon" } },
            { Name = "Extinction Egg (Terrorbird)", Rarity = "Mythic", Aliases = { "Terrorbird" } },
            { Name = "Extinction Egg (Giant Sloth)", Rarity = "Cosmic", Aliases = { "Giant Sloth" } },
            { Name = "Extinction Egg (Dunkleosteus)", Rarity = "Secret", Aliases = { "Dunkleosteus" } },
            { Name = "Extinction Egg (Skeletal Glyptodon)", Rarity = "Secret", Aliases = { "Skeletal Glyptodon" } },
            { Name = "Extinction Egg (Skeletal Terrorbird)", Rarity = "Secret", Aliases = { "Skeletal Terrorbird" } },
            { Name = "Extinction Egg (Skeletal Giant Sloth)", Rarity = "Secret", Aliases = { "Skeletal Giant Sloth" } },
            { Name = "Extinction Egg (Gigantus)", Rarity = "Eternal", Aliases = { "Gigantus" } },
            { Name = "Extinction Egg (Skeletal Dunkleosteus)", Rarity = "Eternal", Aliases = { "Skeletal Dunkleosteus" } },
            { Name = "Extinction Egg (Skeletal Gigantus)", Rarity = "Eternal", Aliases = { "Skeletal Gigantus" } },
            { Name = "Extinction Egg (Sabertooth)", Rarity = "Divine", Aliases = { "Sabertooth" } },
            { Name = "Extinction Egg (Skeletal Sabertooth)", Rarity = "Divine", Aliases = { "Skeletal Sabertooth" } },
        }
    },
    {
        Biome = "Racing Event Eggs",
        EggNames = { "Racing Egg", "Race Egg", "Seahorse Egg" },
        Species = {
            { Name = "Seahorse", Rarity = "Legendary", Aliases = { "Race Seahorse" } },
            { Name = "Race Lizard", Rarity = "Rare" },
            { Name = "Race Bird", Rarity = "Cosmic" },
            { Name = "Race Cheetah", Rarity = "Secret" },
            { Name = "Engine Snail", Rarity = "Eternal" },
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
            -- Divine
            { Name = "Voidseer Pumpkin Egg", Rarity = "Divine", Aliases = { "Voidseer Pumpkin" } },

            -- Eternal
            { Name = "Gorillastein Egg", Rarity = "Eternal", Aliases = { "Gorillastein", "Gorillastine", "Gorillastines", "Gorillastein Egg", "Gorillastine Egg", "Gorillastines Egg", "Gorilla Stein", "Gorilla Stein Egg", "Abomination Kong", "Abomination Kong Egg" } },
            { Name = "Abomination Kong Egg", Rarity = "Eternal", Aliases = { "Abomination Kong", "Gorillastein", "Gorillastine", "Gorillastines", "Gorillastein Egg", "Gorillastine Egg", "Gorillastines Egg", "Gorilla Stein" } },
            { Name = "Ghost Reaper Egg", Rarity = "Eternal", Aliases = { "Ghost Reaper" } },
            { Name = "Shelltide Voyager Egg", Rarity = "Eternal", Aliases = { "Shelltide Voyager" } },
            { Name = "Halloween Dimension Egg", Rarity = "Eternal", Aliases = { "Dimension Egg", "Halloween Dimension" } },

            -- Secret
            { Name = "BloodBloom Egg", Rarity = "Secret", Aliases = { "BloodBloom" } },
            { Name = "Graveyard Brute Egg", Rarity = "Secret", Aliases = { "Graveyard Brute" } },
            { Name = "Phantom Dragon Egg", Rarity = "Secret", Aliases = { "Phantom Dragon" } },
            { Name = "Pumpkin Golem Egg", Rarity = "Secret", Aliases = { "Pumpkin Golem" } },
            { Name = "Soul Phantom Egg", Rarity = "Secret", Aliases = { "Soul Phantom" } },
            { Name = "Werewolf Egg", Rarity = "Secret", Aliases = { "Werewolf" } },

            -- Cosmic
            { Name = "Halloween Boss Egg", Rarity = "Cosmic", Aliases = { "Halloween Boss" } },
            { Name = "Haunted Scorpio Egg", Rarity = "Cosmic", Aliases = { "Haunted Scorpio" } },
            { Name = "Hexed Pumpkin Egg", Rarity = "Cosmic", Aliases = { "Hexed Pumpkin" } },
            { Name = "Patchwork Imp Egg", Rarity = "Cosmic", Aliases = { "Patchwork Imp", "Quilted Imp", "Quilted Imp Egg", "Patchwork", "Quilted" } },
            { Name = "Spirit Knight Egg", Rarity = "Cosmic", Aliases = { "Spirit Knight", "SpiritKnight" } },
            { Name = "Witch Crow Egg", Rarity = "Cosmic", Aliases = { "Witch Crow" } },

            -- Mythic
            { Name = "Candlefang Egg", Rarity = "Mythic", Aliases = { "Candlefang" } },
            { Name = "Crowshade Egg", Rarity = "Mythic", Aliases = { "Crowshade" } },
            { Name = "Toadstool Egg", Rarity = "Mythic", Aliases = { "Toadstool", "Rotshroom", "Rotshroom Egg" } },
            { Name = "Zombified Halloween Egg", Rarity = "Mythic", Aliases = { "Zombified Halloween" } },

            -- Legendary
            { Name = "Candy Corn Egg", Rarity = "Legendary", Aliases = { "Candy Corn" } },
            { Name = "Halloween Royal Mimic Egg", Rarity = "Legendary", Aliases = { "Halloween Royal Mimic", "Royal Mimic", "Royal Mimic Egg", "Mimic Chest", "Mimic Chest Egg" } },
            { Name = "Hooded Gerbil Egg", Rarity = "Legendary", Aliases = { "HalloweenEgg", "Halloween Egg", "Halloween", "Hooded Gerbil" } },
            { Name = "Jester Egg", Rarity = "Legendary", Aliases = { "Jester" } },
            { Name = "Jesterpop Egg", Rarity = "Legendary", Aliases = { "Jesterpop" } },
            { Name = "Witch Pumpkin Egg", Rarity = "Legendary", Aliases = { "Witch Pumpkin" } },

            -- Epic
            { Name = "Ghost Fish Egg", Rarity = "Epic", Aliases = { "Ghost Fish" } },
            { Name = "Mummy Egg", Rarity = "Epic", Aliases = { "Mummy" } },
            { Name = "Whiskers Egg", Rarity = "Epic", Aliases = { "Whiskers" } },

            -- Rare
            { Name = "Hollow Bat Egg", Rarity = "Rare", Aliases = { "Hollow Bat" } },
            { Name = "Scarecrow Egg", Rarity = "Rare", Aliases = { "Scarecrow" } },
        }
    },
    {
        Biome = "Ungrouped",
        EggNames = { "Event Egg", "Special Egg" },
        Species = {
        }
    },
    },
}

-- 1.2 Velocity & Dual-Speed Defaults
Config.Velocity = {
    DefaultGoSpeed    = 360,
    DefaultCarrySpeed = 300,
    MinSpeed          = 16,
    MaxSpeed          = 500,
    DefaultWalkSpeed  = 16.0,
    TargetSnapDist    = 60.0,
    SafeZonePosition  = Vector3.new(530.332, 70.724, -399.111),
}

-- 1.3 Instant Recovery Configuration (Zero-Wait Anti-Ragdoll & Anti-Fling)
Config.Recovery = {
    Enabled         = true,
    AntiFling       = true,
    BrakeVelocity   = true,
    GroundDistance  = 2.5,
    MaxFlingSpeed   = 100,
    DebounceWindow  = 0.05,
    BodyJointNames  = {
        ["RootJoint"]     = true,
        ["Root"]          = true,
        ["Neck"]          = true,
        ["Waist"]         = true,
        ["Left Shoulder"] = true,
        ["Right Shoulder"]= true,
        ["Left Hip"]      = true,
        ["Right Hip"]     = true,
        ["LeftShoulder"]  = true,
        ["RightShoulder"] = true,
        ["LeftElbow"]     = true,
        ["RightElbow"]    = true,
        ["LeftWrist"]     = true,
        ["RightWrist"]    = true,
    },
}

-- 1.4 Fast Pickup Configuration
Config.Pickup = {
    Enabled           = true,
    SpamBurstCount    = 8,
    PickupInterval    = 0.035,
    BurstMaxDuration  = 1.5,
    FastPickupMaxDist = 35.0,
    DirectPickupDist  = 7.0,
}

-- 1.4.1 Halloween Fast Pickup Configuration
Config.HwPickup = {
    Enabled           = false,
    SpamBurstCount    = 8,
    PickupInterval    = 0.035,
    BurstMaxDuration  = 1.5,
    FastPickupMaxDist = 45.0,
    DirectPickupDist  = 7.0,
}

-- 1.5 Trap Evade Configuration (Complete Trap Neutralization)
Config.TrapEvade = {
    Enabled          = true,
    NeutralizeHitbox = true,
}

-- 1.6 Treadmill Configuration
Config.Treadmill = {
    Enabled = false,
}

-- 1.7 Auto Butterfly Configuration
Config.Butterfly = {
    Enabled      = false,
    ZonePosition = Vector3.new(6697.747, 70.724, -376.004),
}

-- 1.8 UI Theme & Window Dimensions
Config.UI = {
    WindowSize     = UDim2.new(0, 380, 0, 520),
    TitleBarHeight = 36,
    SidebarWidth   = 46,
    CardHeight     = 48,
    Theme = {
        BgDark     = Color3.fromRGB(22, 24, 30),
        TitleBg    = Color3.fromRGB(32, 40, 60),
        Border     = Color3.fromRGB(70, 110, 180),
        CardBg     = Color3.fromRGB(28, 32, 44),
        CardStroke = Color3.fromRGB(45, 55, 75),
        TabActive  = Color3.fromRGB(45, 100, 160),
        TabIdle    = Color3.fromRGB(35, 42, 60),
        GreenOn    = Color3.fromRGB(35, 135, 75),
        GrayOff    = Color3.fromRGB(45, 50, 65),
        AccentBlue = Color3.fromRGB(50, 120, 220),
    }
}

-- ============================================================================
-- SECTION 2: UI CODES (Per Panel & Row)
-- ============================================================================

-- Root UI references table
UI.Elements = {
    ScreenGui          = nil,
    MenuToggleBtn      = nil,
    MainFrame          = nil,
    TitleBar           = nil,
    CloseBtn           = nil,
    Sidebar            = nil,
    TabBtnEggs         = nil,
    TabBtnUtility      = nil,
    TabBtnHalloween    = nil,
    ContentContainer   = nil,
    TabEggs            = nil,
    TabUtility         = nil,
    TabHalloween       = nil,
    HwEggListScroll    = nil,
    HwEmptyNotice      = nil,
    HwRarityDropdownBtn= nil,
    HwFilterPickupBtn  = nil,

    -- TabEggs Elements
    ActivityStatus     = nil,
    VelToggleBtn       = nil,
    GoBox              = nil,
    CarryBox           = nil,
    BiomeDropdownBtn   = nil,
    RarityDropdownBtn  = nil,
    EggListScroll      = nil,
    EmptyNotice        = nil,

    -- TabUtility Elements
    TogglePickupBtn    = nil,
    ToggleRecoveryBtn  = nil,
    ToggleNoclipBtn    = nil,
    ToggleTrapEvadeBtn = nil,
    ToggleTreadmillBtn = nil,
    TriggerDismountBtn = nil,
    ToggleButterflyBtn = nil,
    UtilityCopyJsonBtn = nil,
}

UI.CardPool = {}
UI.HwCardPool = {}
UI.ActiveTab = "Eggs"
UI.OpenDropdown = nil

UI.closeCurrentDropdown = function()
    if UI.OpenDropdown then
        UI.OpenDropdown.list.Visible = false
        if UI.OpenDropdown.updateBtnText then
            UI.OpenDropdown.updateBtnText(false)
        end
        UI.OpenDropdown = nil
    end
end

UI.syncPickupToggles = function()
    local w1En = Config.Pickup and Config.Pickup.Enabled == true
    local hwEn = Config.HwPickup and Config.HwPickup.Enabled == true

    if UI.Elements.TogglePickupBtn then
        UI.Elements.TogglePickupBtn.Text = w1En and "ON" or "OFF"
        UI.Elements.TogglePickupBtn.BackgroundColor3 = w1En and Config.UI.Theme.GreenOn or Config.UI.Theme.GrayOff
        UI.Elements.TogglePickupBtn.TextColor3 = w1En and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end

    if UI.Elements.HwFilterPickupBtn then
        UI.Elements.HwFilterPickupBtn.Text = hwEn and "⚡ Fast Pick: ON" or "⚡ Fast Pick: OFF"
        UI.Elements.HwFilterPickupBtn.BackgroundColor3 = hwEn and Config.UI.Theme.GreenOn or Config.UI.Theme.GrayOff
        UI.Elements.HwFilterPickupBtn.TextColor3 = hwEn and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end
end

UI.createFilterDropdown = function(cfg)
    local dropList = Instance.new("Frame")
    dropList.Name = (cfg.title or "Filter") .. "DropList"
    dropList.Size = cfg.size or UDim2.new(0.5, -4, 0, 240)
    dropList.Position = cfg.pos or UDim2.new(0, 0, 0, 28)
    dropList.BackgroundColor3 = Color3.fromRGB(24, 29, 42)
    dropList.BorderSizePixel = 0
    dropList.ZIndex = cfg.zIndex or 60
    dropList.ClipsDescendants = true
    dropList.Visible = false
    dropList.Parent = cfg.parent
    Instance.new("UICorner", dropList).CornerRadius = UDim.new(0, 6)

    local stroke = Instance.new("UIStroke", dropList)
    stroke.Color = Color3.fromRGB(60, 85, 130)
    stroke.Thickness = 1

    local quickRow = Instance.new("Frame")
    quickRow.Size = UDim2.new(1, -6, 0, 22)
    quickRow.Position = UDim2.new(0, 3, 0, 3)
    quickRow.BackgroundTransparency = 1
    quickRow.ZIndex = (cfg.zIndex or 60) + 1
    quickRow.Parent = dropList

    local allBtn = Instance.new("TextButton")
    allBtn.Size = UDim2.new(0.5, -2, 1, 0)
    allBtn.Position = UDim2.new(0, 0, 0, 0)
    allBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 150)
    allBtn.Text = "All"
    allBtn.TextColor3 = Color3.new(1, 1, 1)
    allBtn.TextSize = 11
    allBtn.Font = Enum.Font.GothamBold
    allBtn.ZIndex = (cfg.zIndex or 60) + 2
    allBtn.Parent = quickRow
    Instance.new("UICorner", allBtn).CornerRadius = UDim.new(0, 4)

    local noneBtn = Instance.new("TextButton")
    noneBtn.Size = UDim2.new(0.5, -2, 1, 0)
    noneBtn.Position = UDim2.new(0.5, 2, 0, 0)
    noneBtn.BackgroundColor3 = Color3.fromRGB(110, 45, 45)
    noneBtn.Text = "None"
    noneBtn.TextColor3 = Color3.new(1, 1, 1)
    noneBtn.TextSize = 11
    noneBtn.Font = Enum.Font.GothamBold
    noneBtn.ZIndex = (cfg.zIndex or 60) + 2
    noneBtn.Parent = quickRow
    Instance.new("UICorner", noneBtn).CornerRadius = UDim.new(0, 4)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -6, 1, -29)
    scroll.Position = UDim2.new(0, 3, 0, 27)
    scroll.BackgroundTransparency = 1
    scroll.ScrollBarThickness = 3
    scroll.CanvasSize = UDim2.new(0, 0, 0, #cfg.items * 22 + 4)
    scroll.ZIndex = (cfg.zIndex or 60) + 1
    scroll.Parent = dropList

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 2)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = scroll

    local itemBtns = {}

    local function updateBtnText(isOpen)
        local arrow = isOpen and "▲" or "▼"
        local sel = cfg.getSelected()
        if sel["All"] then
            cfg.btn.Text = cfg.title .. ": All " .. arrow
            return
        end
        local list = {}
        for _, it in ipairs(cfg.items) do
            if sel[it] then table.insert(list, it) end
        end
        if #list == 0 then
            cfg.btn.Text = cfg.title .. ": None " .. arrow
        elseif #list == 1 then
            cfg.btn.Text = cfg.title .. ": " .. list[1] .. " " .. arrow
        else
            cfg.btn.Text = string.format("%s: %s +%d %s", cfg.title, list[1], #list - 1, arrow)
        end
    end

    local function refreshButtons()
        local sel = cfg.getSelected()
        for _, it in ipairs(cfg.items) do
            local on = sel["All"] == true or sel[it] == true
            local b = itemBtns[it]
            if b then
                b.BackgroundColor3 = on and Color3.fromRGB(48, 80, 125) or Color3.fromRGB(32, 38, 52)
                b.Text = (on and "[X] " or "[ ] ") .. it
            end
        end
    end

    for i, it in ipairs(cfg.items) do
        local b = Instance.new("TextButton")
        b.Name = (cfg.title or "Item") .. "_" .. it
        b.Size = UDim2.new(1, -4, 0, 20)
        b.LayoutOrder = i
        b.BackgroundColor3 = Color3.fromRGB(32, 38, 52)
        b.Text = "[X] " .. it
        local col = (cfg.colorMap and cfg.colorMap[it]) or Color3.fromRGB(220, 230, 255)
        b.TextColor3 = col
        b.TextSize = 11
        b.Font = Enum.Font.GothamBold
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.ZIndex = (cfg.zIndex or 60) + 2
        b.Parent = scroll
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 6)
        pad.Parent = b
        itemBtns[it] = b

        addConnection(b.MouseButton1Click:Connect(function()
            local sel = cfg.getSelected()
            if sel["All"] then
                sel = {}
            end
            if sel[it] then
                sel[it] = nil
            else
                sel[it] = true
            end

            local totalChecked = 0
            for _, checkIt in ipairs(cfg.items) do
                if sel[checkIt] then totalChecked = totalChecked + 1 end
            end
            if totalChecked == #cfg.items then
                sel = { ["All"] = true }
            end

            cfg.setSelected(sel)
            updateBtnText(true)
            refreshButtons()
            if cfg.onChanged then cfg.onChanged() end
        end))
    end

    addConnection(allBtn.MouseButton1Click:Connect(function()
        cfg.setSelected({ ["All"] = true })
        updateBtnText(true)
        refreshButtons()
        if cfg.onChanged then cfg.onChanged() end
    end))

    addConnection(noneBtn.MouseButton1Click:Connect(function()
        cfg.setSelected({})
        updateBtnText(true)
        refreshButtons()
        if cfg.onChanged then cfg.onChanged() end
    end))

    local dd = {
        btn = cfg.btn,
        list = dropList,
        onOpen = refreshButtons,
        updateBtnText = updateBtnText,
    }

    local function toggleDropdown()
        if UI.OpenDropdown == dd then
            UI.closeCurrentDropdown()
        else
            UI.closeCurrentDropdown()
            UI.OpenDropdown = dd
            dd.list.Visible = true
            dd.onOpen()
            dd.updateBtnText(true)
        end
    end

    addConnection(cfg.btn.MouseButton1Click:Connect(toggleDropdown))
    updateBtnText(false)
    refreshButtons()

    return dd
end

-- 2.1 Build UI Structure (Per Panel & Row)
UI.build = function()
    local theme = Config.UI.Theme
    local safeParent = Helpers.getSafeUiParent()

    -- Ensure any orphan instance is destroyed
    if safeParent then
        local oldGui = safeParent:FindFirstChild("EggGoToUI_v12")
        if oldGui then pcall(function() oldGui:Destroy() end) end
    end

    -- ScreenGui
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "EggGoToUI_v12"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = safeParent
    UI.Elements.ScreenGui = screenGui

    -- Draggable Menu Toggle Button
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Name = "MenuToggleBtn"
    toggleBtn.Size = UDim2.new(0, 48, 0, 48)
    toggleBtn.Position = UDim2.new(0, 15, 0.5, -24)
    toggleBtn.BackgroundColor3 = theme.TitleBg
    toggleBtn.Text = "🥚"
    toggleBtn.TextSize = 22
    toggleBtn.TextColor3 = Color3.new(1, 1, 1)
    toggleBtn.Parent = screenGui
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 24)
    local tStroke = Instance.new("UIStroke", toggleBtn)
    tStroke.Color = theme.Border
    tStroke.Thickness = 1.5
    UI.Elements.MenuToggleBtn = toggleBtn

    -- Toggle Button Dragging
    Helpers.makeDraggable(toggleBtn, toggleBtn)

    -- Main Window Frame
    local main = Instance.new("Frame")
    main.Name = "MainFrame"
    main.Size = Config.UI.WindowSize
    main.Position = UDim2.new(0.5, -190, 0.5, -260)
    main.BackgroundColor3 = theme.BgDark
    main.BorderSizePixel = 0
    main.Parent = screenGui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local mainStroke = Instance.new("UIStroke", main)
    mainStroke.Color = theme.Border
    mainStroke.Thickness = 1.5
    UI.Elements.MainFrame = main

    -- 2.1.1 Topbar
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, Config.UI.TitleBarHeight)
    titleBar.BackgroundColor3 = theme.TitleBg
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    local cornerFix = Instance.new("Frame")
    cornerFix.Name = "CornerFix"
    cornerFix.Size = UDim2.new(1, 0, 0, 10)
    cornerFix.Position = UDim2.new(0, 0, 1, -10)
    cornerFix.BackgroundColor3 = theme.TitleBg
    cornerFix.BorderSizePixel = 0
    cornerFix.Parent = titleBar

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "TitleLabel"
    titleLabel.Size = UDim2.new(1, -60, 1, 0)
    titleLabel.Position = UDim2.new(0, 12, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "Egg Go-To v12 (Modular Clean)"
    titleLabel.TextColor3 = Color3.fromRGB(220, 235, 255)
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 13
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseBtn"
    closeBtn.Size = UDim2.new(0, 26, 0, 26)
    closeBtn.Position = UDim2.new(1, -32, 0.5, -13)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 55)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.TextSize = 12
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
    UI.Elements.CloseBtn = closeBtn

    -- Window Dragging
    Helpers.makeDraggable(main, titleBar)

    -- 2.2 Vertical Sidebar Navigation Rail
    local sidebarW = Config.UI.SidebarWidth or 46
    local sidebar = Instance.new("Frame")
    sidebar.Name = "Sidebar"
    sidebar.Size = UDim2.new(0, sidebarW, 1, -Config.UI.TitleBarHeight)
    sidebar.Position = UDim2.new(0, 0, 0, Config.UI.TitleBarHeight)
    sidebar.BackgroundColor3 = Color3.fromRGB(26, 32, 46)
    sidebar.BorderSizePixel = 0
    sidebar.Parent = main
    UI.Elements.Sidebar = sidebar

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
    tabBtnEggs.BackgroundColor3 = theme.TabActive
    tabBtnEggs.Text = "🥚"
    tabBtnEggs.TextColor3 = Color3.new(1, 1, 1)
    tabBtnEggs.TextSize = 18
    tabBtnEggs.Font = Enum.Font.GothamBold
    tabBtnEggs.Parent = sidebar
    Instance.new("UICorner", tabBtnEggs).CornerRadius = UDim.new(0, 6)
    UI.Elements.TabBtnEggs = tabBtnEggs

    -- Sidebar Button 2: Utility
    local tabBtnUtility = Instance.new("TextButton")
    tabBtnUtility.Name = "TabBtnUtility"
    tabBtnUtility.Size = UDim2.new(0, 34, 0, 34)
    tabBtnUtility.Position = UDim2.new(0.5, -17, 0, 52)
    tabBtnUtility.BackgroundColor3 = theme.TabIdle
    tabBtnUtility.Text = "⚡"
    tabBtnUtility.TextColor3 = Color3.fromRGB(150, 170, 200)
    tabBtnUtility.TextSize = 18
    tabBtnUtility.Font = Enum.Font.GothamBold
    tabBtnUtility.Parent = sidebar
    Instance.new("UICorner", tabBtnUtility).CornerRadius = UDim.new(0, 6)
    UI.Elements.TabBtnUtility = tabBtnUtility

    -- Sidebar Button 3: Halloween
    local tabBtnHalloween = Instance.new("TextButton")
    tabBtnHalloween.Name = "TabBtnHalloween"
    tabBtnHalloween.Size = UDim2.new(0, 34, 0, 34)
    tabBtnHalloween.Position = UDim2.new(0.5, -17, 0, 94)
    tabBtnHalloween.BackgroundColor3 = theme.TabIdle
    tabBtnHalloween.Text = "🎃"
    tabBtnHalloween.TextColor3 = Color3.fromRGB(150, 170, 200)
    tabBtnHalloween.TextSize = 18
    tabBtnHalloween.Font = Enum.Font.GothamBold
    tabBtnHalloween.Parent = sidebar
    Instance.new("UICorner", tabBtnHalloween).CornerRadius = UDim.new(0, 6)
    UI.Elements.TabBtnHalloween = tabBtnHalloween

    -- Content Area Container (Right of Sidebar)
    local contentContainer = Instance.new("Frame")
    contentContainer.Name = "ContentContainer"
    contentContainer.Size = UDim2.new(1, -sidebarW, 1, -Config.UI.TitleBarHeight)
    contentContainer.Position = UDim2.new(0, sidebarW, 0, Config.UI.TitleBarHeight)
    contentContainer.BackgroundTransparency = 1
    contentContainer.BorderSizePixel = 0
    contentContainer.ClipsDescendants = false
    contentContainer.Parent = main
    UI.Elements.ContentContainer = contentContainer

    -- 2.3 Panel 1: TabEggs
    local tabEggs = Instance.new("Frame")
    tabEggs.Name = "TabEggs"
    tabEggs.Size = UDim2.new(1, 0, 1, 0)
    tabEggs.Position = UDim2.new(0, 0, 0, 0)
    tabEggs.BackgroundTransparency = 1
    tabEggs.BorderSizePixel = 0
    tabEggs.ClipsDescendants = false
    tabEggs.Visible = true
    tabEggs.Parent = contentContainer
    UI.Elements.TabEggs = tabEggs

    -- Row 2.3.1: Activity Status Label
    local actLabel = Instance.new("TextLabel")
    actLabel.Name = "ActivityStatusLabel"
    actLabel.Size = UDim2.new(1, -16, 0, 16)
    actLabel.Position = UDim2.new(0, 8, 0, 4)
    actLabel.BackgroundTransparency = 1
    actLabel.Text = "Status: Velocity Disabled (Normal WalkSpeed)"
    actLabel.TextColor3 = Color3.fromRGB(160, 170, 190)
    actLabel.TextSize = 11
    actLabel.Font = Enum.Font.GothamBold
    actLabel.TextXAlignment = Enum.TextXAlignment.Left
    actLabel.Parent = tabEggs
    UI.Elements.ActivityStatus = actLabel

    -- Row 2.3.2: Velocity Control Bar
    local velFrame = Instance.new("Frame")
    velFrame.Name = "VelocityFrame"
    velFrame.Size = UDim2.new(1, -16, 0, 26)
    velFrame.Position = UDim2.new(0, 8, 0, 22)
    velFrame.BackgroundTransparency = 1
    velFrame.Parent = tabEggs

    local velBtn = Instance.new("TextButton")
    velBtn.Name = "VelToggleBtn"
    velBtn.Size = UDim2.new(0, 90, 1, 0)
    velBtn.BackgroundColor3 = theme.GrayOff
    velBtn.Text = "Velocity: OFF"
    velBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    velBtn.TextSize = 10.5
    velBtn.Font = Enum.Font.GothamBold
    velBtn.Parent = velFrame
    Instance.new("UICorner", velBtn).CornerRadius = UDim.new(0, 4)
    UI.Elements.VelToggleBtn = velBtn

    local goFrame = Instance.new("Frame")
    goFrame.Name = "GoSpeedFrame"
    goFrame.Size = UDim2.new(0, 78, 1, 0)
    goFrame.Position = UDim2.new(0, 96, 0, 0)
    goFrame.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
    goFrame.Parent = velFrame
    Instance.new("UICorner", goFrame).CornerRadius = UDim.new(0, 4)

    local goLbl = Instance.new("TextLabel")
    goLbl.Size = UDim2.new(0, 24, 1, 0)
    goLbl.Position = UDim2.new(0, 4, 0, 0)
    goLbl.BackgroundTransparency = 1
    goLbl.Text = "Go:"
    goLbl.TextColor3 = Color3.fromRGB(160, 185, 220)
    goLbl.TextSize = 10.5
    goLbl.Font = Enum.Font.GothamBold
    goLbl.Parent = goFrame

    local goBox = Instance.new("TextBox")
    goBox.Name = "GoSpeedBox"
    goBox.Size = UDim2.new(1, -28, 1, 0)
    goBox.Position = UDim2.new(0, 26, 0, 0)
    goBox.BackgroundTransparency = 1
    goBox.Text = tostring(Config.Velocity.DefaultGoSpeed)
    goBox.PlaceholderText = "360"
    goBox.TextColor3 = Color3.new(1, 1, 1)
    goBox.TextSize = 11
    goBox.Font = Enum.Font.GothamBold
    goBox.ClearTextOnFocus = false
    goBox.Parent = goFrame
    UI.Elements.GoBox = goBox

    local carryFrame = Instance.new("Frame")
    carryFrame.Name = "CarrySpeedFrame"
    carryFrame.Size = UDim2.new(0, 88, 1, 0)
    carryFrame.Position = UDim2.new(0, 178, 0, 0)
    carryFrame.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
    carryFrame.Parent = velFrame
    Instance.new("UICorner", carryFrame).CornerRadius = UDim.new(0, 4)

    local cLbl = Instance.new("TextLabel")
    cLbl.Size = UDim2.new(0, 34, 1, 0)
    cLbl.Position = UDim2.new(0, 4, 0, 0)
    cLbl.BackgroundTransparency = 1
    cLbl.Text = "Carry:"
    cLbl.TextColor3 = Color3.fromRGB(160, 185, 220)
    cLbl.TextSize = 10.5
    cLbl.Font = Enum.Font.GothamBold
    cLbl.Parent = carryFrame

    local carryBox = Instance.new("TextBox")
    carryBox.Name = "CarrySpeedBox"
    carryBox.Size = UDim2.new(1, -38, 1, 0)
    carryBox.Position = UDim2.new(0, 36, 0, 0)
    carryBox.BackgroundTransparency = 1
    carryBox.Text = tostring(Config.Velocity.DefaultCarrySpeed)
    carryBox.PlaceholderText = "300"
    carryBox.TextColor3 = Color3.new(1, 1, 1)
    carryBox.TextSize = 11
    carryBox.Font = Enum.Font.GothamBold
    carryBox.ClearTextOnFocus = false
    carryBox.Parent = carryFrame
    UI.Elements.CarryBox = carryBox

    -- Row 2.3.3: Filter Bar (Biome Dropdown & Rarity Dropdown)
    local filterBar = Instance.new("Frame")
    filterBar.Name = "FilterBar"
    filterBar.Size = UDim2.new(1, -16, 0, 26)
    filterBar.Position = UDim2.new(0, 8, 0, 52)
    filterBar.BackgroundTransparency = 1
    filterBar.BorderSizePixel = 0
    filterBar.ClipsDescendants = false
    filterBar.ZIndex = 40
    filterBar.Parent = tabEggs

    local biomeBtn = Instance.new("TextButton")
    biomeBtn.Name = "BiomeDropdownBtn"
    biomeBtn.Size = UDim2.new(0.5, -4, 1, 0)
    biomeBtn.Position = UDim2.new(0, 0, 0, 0)
    biomeBtn.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
    biomeBtn.Text = "Biome: All ▼"
    biomeBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
    biomeBtn.TextSize = 10.5
    biomeBtn.Font = Enum.Font.GothamBold
    biomeBtn.Parent = filterBar
    Instance.new("UICorner", biomeBtn).CornerRadius = UDim.new(0, 4)
    UI.Elements.BiomeDropdownBtn = biomeBtn

    local rarityBtn = Instance.new("TextButton")
    rarityBtn.Name = "RarityDropdownBtn"
    rarityBtn.Size = UDim2.new(0.5, -4, 1, 0)
    rarityBtn.Position = UDim2.new(0.5, 4, 0, 0)
    rarityBtn.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
    rarityBtn.Text = "Rarity: All ▼"
    rarityBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
    rarityBtn.TextSize = 10.5
    rarityBtn.Font = Enum.Font.GothamBold
    rarityBtn.Parent = filterBar
    Instance.new("UICorner", rarityBtn).CornerRadius = UDim.new(0, 4)
    UI.Elements.RarityDropdownBtn = rarityBtn

    -- Wire Dropdowns
    UI.createFilterDropdown({
        parent = filterBar,
        btn = biomeBtn,
        title = "Biome",
        items = Config.Taxonomy.BiomeOrder,
        getSelected = function() return Engine.State.SelectedBiomes end,
        setSelected = function(v) Engine.State.SelectedBiomes = v end,
        onChanged = function()
            Engine.State.ListDirty = true
            if UI.renderFarmableEggs then pcall(UI.renderFarmableEggs) end
            if UI.renderHalloweenEggs then pcall(UI.renderHalloweenEggs) end
        end,
        size = UDim2.new(0.5, -4, 0, 240),
        pos = UDim2.new(0, 0, 0, 28),
        scrollable = true,
    })

    UI.createFilterDropdown({
        parent = filterBar,
        btn = rarityBtn,
        title = "Rarity",
        items = Config.Taxonomy.FarmableRarities,
        colorMap = Config.Taxonomy.RarityColors,
        getSelected = function() return Engine.State.SelectedRarities end,
        setSelected = function(v) Engine.State.SelectedRarities = v end,
        onChanged = function()
            Engine.State.ListDirty = true
            if UI.renderFarmableEggs then pcall(UI.renderFarmableEggs) end
            if UI.renderHalloweenEggs then pcall(UI.renderHalloweenEggs) end
        end,
        size = UDim2.new(0.5, -4, 0, 240),
        pos = UDim2.new(0.5, 4, 0, 28),
        scrollable = true,
    })

    -- Row 2.3.4: Egg List Scroll Frame & Card Pool (Full Height to Bottom)
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "EggListScroll"
    scroll.Size = UDim2.new(1, -16, 1, -88)
    scroll.Position = UDim2.new(0, 8, 0, 82)
    scroll.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = Color3.fromRGB(50, 80, 140)
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.ZIndex = 1
    scroll.Parent = tabEggs
    Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

    local listLayout = Instance.new("UIListLayout")
    listLayout.Padding = UDim.new(0, 4)
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Parent = scroll
    UI.Elements.EggListScroll = scroll

    -- Empty Notice
    local emptyNotice = Instance.new("TextLabel")
    emptyNotice.Name = "EmptyNotice"
    emptyNotice.Size = UDim2.new(1, -20, 0, 70)
    emptyNotice.Position = UDim2.new(0, 10, 0, 20)
    emptyNotice.BackgroundTransparency = 1
    emptyNotice.Text = "No farmable eggs match current filter criteria.\n(Adjust Rarity or Biome filters, or wait for 5m cycle)"
    emptyNotice.TextColor3 = Color3.fromRGB(140, 160, 190)
    emptyNotice.TextSize = 11.5
    emptyNotice.Font = Enum.Font.Gotham
    emptyNotice.TextWrapped = true
    emptyNotice.Visible = false
    emptyNotice.Parent = scroll
    UI.Elements.EmptyNotice = emptyNotice

    -- 2.4 Panel 2: TabUtility (Clean, Compact, Even Toggles)
    local tabUtility = Instance.new("Frame")
    tabUtility.Name = "TabUtility"
    tabUtility.Size = UDim2.new(1, 0, 1, 0)
    tabUtility.Position = UDim2.new(0, 0, 0, 0)
    tabUtility.BackgroundTransparency = 1
    tabUtility.BorderSizePixel = 0
    tabUtility.ClipsDescendants = false
    tabUtility.Visible = false
    tabUtility.Parent = contentContainer
    UI.Elements.TabUtility = tabUtility

    -- Row 2.4.1: Fast Pickup [E] Row
    local rowPickup = Instance.new("Frame")
    rowPickup.Name = "RowPickup"
    rowPickup.Size = UDim2.new(1, -16, 0, 36)
    rowPickup.Position = UDim2.new(0, 8, 0, 10)
    rowPickup.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    rowPickup.Parent = tabUtility
    Instance.new("UICorner", rowPickup).CornerRadius = UDim.new(0, 6)

    local lblPTitle = Instance.new("TextLabel")
    lblPTitle.Size = UDim2.new(1, -80, 1, 0)
    lblPTitle.Position = UDim2.new(0, 12, 0, 0)
    lblPTitle.BackgroundTransparency = 1
    lblPTitle.Text = "Fast Pickup [E]"
    lblPTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblPTitle.Font = Enum.Font.GothamBold
    lblPTitle.TextSize = 12
    lblPTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblPTitle.Parent = rowPickup

    local togglePickBtn = Instance.new("TextButton")
    togglePickBtn.Name = "TogglePickupBtn"
    togglePickBtn.Size = UDim2.new(0, 56, 0, 24)
    togglePickBtn.Position = UDim2.new(1, -66, 0.5, -12)
    togglePickBtn.BackgroundColor3 = theme.GreenOn
    togglePickBtn.Text = "ON"
    togglePickBtn.TextColor3 = Color3.new(1, 1, 1)
    togglePickBtn.Font = Enum.Font.GothamBold
    togglePickBtn.TextSize = 11
    togglePickBtn.Parent = rowPickup
    Instance.new("UICorner", togglePickBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.TogglePickupBtn = togglePickBtn

    -- Row 2.4.2: Instant Recovery Row
    local rowRec = Instance.new("Frame")
    rowRec.Name = "RowRecovery"
    rowRec.Size = UDim2.new(1, -16, 0, 36)
    rowRec.Position = UDim2.new(0, 8, 0, 52)
    rowRec.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    rowRec.Parent = tabUtility
    Instance.new("UICorner", rowRec).CornerRadius = UDim.new(0, 6)

    local lblRTitle = Instance.new("TextLabel")
    lblRTitle.Size = UDim2.new(1, -80, 1, 0)
    lblRTitle.Position = UDim2.new(0, 12, 0, 0)
    lblRTitle.BackgroundTransparency = 1
    lblRTitle.Text = "Instant Recovery"
    lblRTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblRTitle.Font = Enum.Font.GothamBold
    lblRTitle.TextSize = 12
    lblRTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblRTitle.Parent = rowRec

    local testRecBtn = Instance.new("TextButton")
    testRecBtn.Name = "TestRecoveryBtn"
    testRecBtn.Size = UDim2.new(0, 56, 0, 24)
    testRecBtn.Position = UDim2.new(1, -66, 0.5, -12)
    testRecBtn.BackgroundColor3 = Config.Recovery.Enabled and theme.GreenOn or theme.GrayOff
    testRecBtn.Text = Config.Recovery.Enabled and "ON" or "OFF"
    testRecBtn.TextColor3 = Config.Recovery.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    testRecBtn.Font = Enum.Font.GothamBold
    testRecBtn.TextSize = 11
    testRecBtn.Parent = rowRec
    Instance.new("UICorner", testRecBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.ToggleRecoveryBtn = testRecBtn

    -- Row 2.4.3: No-Clip Row
    local rowNc = Instance.new("Frame")
    rowNc.Name = "RowNoclip"
    rowNc.Size = UDim2.new(1, -16, 0, 36)
    rowNc.Position = UDim2.new(0, 8, 0, 94)
    rowNc.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    rowNc.Parent = tabUtility
    Instance.new("UICorner", rowNc).CornerRadius = UDim.new(0, 6)

    local lblNcTitle = Instance.new("TextLabel")
    lblNcTitle.Size = UDim2.new(1, -80, 1, 0)
    lblNcTitle.Position = UDim2.new(0, 12, 0, 0)
    lblNcTitle.BackgroundTransparency = 1
    lblNcTitle.Text = "No-Clip"
    lblNcTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblNcTitle.Font = Enum.Font.GothamBold
    lblNcTitle.TextSize = 12
    lblNcTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblNcTitle.Parent = rowNc

    local toggleNcBtn = Instance.new("TextButton")
    toggleNcBtn.Name = "ToggleNoclipBtn"
    toggleNcBtn.Size = UDim2.new(0, 56, 0, 24)
    toggleNcBtn.Position = UDim2.new(1, -66, 0.5, -12)
    toggleNcBtn.BackgroundColor3 = theme.GrayOff
    toggleNcBtn.Text = "OFF"
    toggleNcBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    toggleNcBtn.Font = Enum.Font.GothamBold
    toggleNcBtn.TextSize = 11
    toggleNcBtn.Parent = rowNc
    Instance.new("UICorner", toggleNcBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.ToggleNoclipBtn = toggleNcBtn

    -- Row 2.4.4: Trap Evade Row
    local rowTrap = Instance.new("Frame")
    rowTrap.Name = "RowTrapEvade"
    rowTrap.Size = UDim2.new(1, -16, 0, 36)
    rowTrap.Position = UDim2.new(0, 8, 0, 136)
    rowTrap.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    rowTrap.Parent = tabUtility
    Instance.new("UICorner", rowTrap).CornerRadius = UDim.new(0, 6)

    local lblTT = Instance.new("TextLabel")
    lblTT.Size = UDim2.new(1, -80, 1, 0)
    lblTT.Position = UDim2.new(0, 12, 0, 0)
    lblTT.BackgroundTransparency = 1
    lblTT.Text = "Trap Evade"
    lblTT.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblTT.Font = Enum.Font.GothamBold
    lblTT.TextSize = 12
    lblTT.TextXAlignment = Enum.TextXAlignment.Left
    lblTT.Parent = rowTrap

    local toggleTrapBtn = Instance.new("TextButton")
    toggleTrapBtn.Name = "ToggleTrapEvadeBtn"
    toggleTrapBtn.Size = UDim2.new(0, 56, 0, 24)
    toggleTrapBtn.Position = UDim2.new(1, -66, 0.5, -12)
    toggleTrapBtn.BackgroundColor3 = Config.TrapEvade.Enabled and theme.GreenOn or theme.GrayOff
    toggleTrapBtn.Text = Config.TrapEvade.Enabled and "ON" or "OFF"
    toggleTrapBtn.TextColor3 = Config.TrapEvade.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    toggleTrapBtn.Font = Enum.Font.GothamBold
    toggleTrapBtn.TextSize = 11
    toggleTrapBtn.Parent = rowTrap
    Instance.new("UICorner", toggleTrapBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.ToggleTrapEvadeBtn = toggleTrapBtn

    -- Row 2.4.5: Auto Treadmill Row
    local rowTm = Instance.new("Frame")
    rowTm.Name = "RowAutoTreadmill"
    rowTm.Size = UDim2.new(1, -16, 0, 36)
    rowTm.Position = UDim2.new(0, 8, 0, 178)
    rowTm.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    rowTm.Parent = tabUtility
    Instance.new("UICorner", rowTm).CornerRadius = UDim.new(0, 6)

    local lblTm = Instance.new("TextLabel")
    lblTm.Size = UDim2.new(1, -80, 1, 0)
    lblTm.Position = UDim2.new(0, 12, 0, 0)
    lblTm.BackgroundTransparency = 1
    lblTm.Text = "Auto Treadmill"
    lblTm.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblTm.Font = Enum.Font.GothamBold
    lblTm.TextSize = 12
    lblTm.TextXAlignment = Enum.TextXAlignment.Left
    lblTm.Parent = rowTm

    local toggleTmBtn = Instance.new("TextButton")
    toggleTmBtn.Name = "ToggleTreadmillBtn"
    toggleTmBtn.Size = UDim2.new(0, 56, 0, 24)
    toggleTmBtn.Position = UDim2.new(1, -66, 0.5, -12)
    toggleTmBtn.BackgroundColor3 = Config.Treadmill.Enabled and theme.GreenOn or theme.GrayOff
    toggleTmBtn.Text = Config.Treadmill.Enabled and "ON" or "OFF"
    toggleTmBtn.TextColor3 = Config.Treadmill.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    toggleTmBtn.Font = Enum.Font.GothamBold
    toggleTmBtn.TextSize = 11
    toggleTmBtn.Parent = rowTm
    Instance.new("UICorner", toggleTmBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.ToggleTreadmillBtn = toggleTmBtn

    -- Row 2.4.6: Auto Dismount Row
    local rowDm = Instance.new("Frame")
    rowDm.Name = "RowAutoDismount"
    rowDm.Size = UDim2.new(1, -16, 0, 36)
    rowDm.Position = UDim2.new(0, 8, 0, 220)
    rowDm.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    rowDm.Parent = tabUtility
    Instance.new("UICorner", rowDm).CornerRadius = UDim.new(0, 6)

    local lblDm = Instance.new("TextLabel")
    lblDm.Size = UDim2.new(1, -80, 1, 0)
    lblDm.Position = UDim2.new(0, 12, 0, 0)
    lblDm.BackgroundTransparency = 1
    lblDm.Text = "Auto Dismount"
    lblDm.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblDm.Font = Enum.Font.GothamBold
    lblDm.TextSize = 12
    lblDm.TextXAlignment = Enum.TextXAlignment.Left
    lblDm.Parent = rowDm

    local triggerDmBtn = Instance.new("TextButton")
    triggerDmBtn.Name = "TriggerDismountBtn"
    triggerDmBtn.Size = UDim2.new(0, 56, 0, 24)
    triggerDmBtn.Position = UDim2.new(1, -66, 0.5, -12)
    triggerDmBtn.BackgroundColor3 = Color3.fromRGB(180, 75, 45)
    triggerDmBtn.Text = "Jump"
    triggerDmBtn.TextColor3 = Color3.new(1, 1, 1)
    triggerDmBtn.Font = Enum.Font.GothamBold
    triggerDmBtn.TextSize = 11
    triggerDmBtn.Parent = rowDm
    Instance.new("UICorner", triggerDmBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.TriggerDismountBtn = triggerDmBtn

    -- Row 2.4.7: Diagnostic Export Row
    local rowExp = Instance.new("Frame")
    rowExp.Name = "RowExportJson"
    rowExp.Size = UDim2.new(1, -16, 0, 36)
    rowExp.Position = UDim2.new(0, 8, 0, 262)
    rowExp.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    rowExp.Parent = tabUtility
    Instance.new("UICorner", rowExp).CornerRadius = UDim.new(0, 6)

    local lblETitle = Instance.new("TextLabel")
    lblETitle.Size = UDim2.new(1, -100, 1, 0)
    lblETitle.Position = UDim2.new(0, 12, 0, 0)
    lblETitle.BackgroundTransparency = 1
    lblETitle.Text = "Export Egg Data (JSON)"
    lblETitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblETitle.Font = Enum.Font.GothamBold
    lblETitle.TextSize = 12
    lblETitle.TextXAlignment = Enum.TextXAlignment.Left
    lblETitle.Parent = rowExp

    local uCopyBtn = Instance.new("TextButton")
    uCopyBtn.Name = "UtilityCopyJsonBtn"
    uCopyBtn.Size = UDim2.new(0, 76, 0, 24)
    uCopyBtn.Position = UDim2.new(1, -86, 0.5, -12)
    uCopyBtn.BackgroundColor3 = Color3.fromRGB(45, 65, 100)
    uCopyBtn.Text = "Copy JSON"
    uCopyBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
    uCopyBtn.TextSize = 11
    uCopyBtn.Font = Enum.Font.GothamBold
    uCopyBtn.Parent = rowExp
    Instance.new("UICorner", uCopyBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.UtilityCopyJsonBtn = uCopyBtn

    -- Row 2.4.8: Auto Butterfly Row
    local rowBf = Instance.new("Frame")
    rowBf.Name = "RowAutoButterfly"
    rowBf.Size = UDim2.new(1, -16, 0, 36)
    rowBf.Position = UDim2.new(0, 8, 0, 304)
    rowBf.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    rowBf.Parent = tabUtility
    Instance.new("UICorner", rowBf).CornerRadius = UDim.new(0, 6)

    local lblBf = Instance.new("TextLabel")
    lblBf.Size = UDim2.new(1, -80, 1, 0)
    lblBf.Position = UDim2.new(0, 12, 0, 0)
    lblBf.BackgroundTransparency = 1
    lblBf.Text = "Auto Butterfly"
    lblBf.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblBf.Font = Enum.Font.GothamBold
    lblBf.TextSize = 12
    lblBf.TextXAlignment = Enum.TextXAlignment.Left
    lblBf.Parent = rowBf

    local toggleBfBtn = Instance.new("TextButton")
    toggleBfBtn.Name = "ToggleButterflyBtn"
    toggleBfBtn.Size = UDim2.new(0, 56, 0, 24)
    toggleBfBtn.Position = UDim2.new(1, -66, 0.5, -12)
    toggleBfBtn.BackgroundColor3 = Config.Butterfly.Enabled and theme.GreenOn or theme.GrayOff
    toggleBfBtn.Text = Config.Butterfly.Enabled and "ON" or "OFF"
    toggleBfBtn.TextColor3 = Config.Butterfly.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    toggleBfBtn.Font = Enum.Font.GothamBold
    toggleBfBtn.TextSize = 11
    toggleBfBtn.Parent = rowBf
    Instance.new("UICorner", toggleBfBtn).CornerRadius = UDim.new(0, 5)
    UI.Elements.ToggleButterflyBtn = toggleBfBtn

    -- 2.5 Panel 3: TabHalloween (Halloween Dimension Egg List)
    local tabHalloween = Instance.new("Frame")
    tabHalloween.Name = "TabHalloween"
    tabHalloween.Size = UDim2.new(1, 0, 1, 0)
    tabHalloween.Position = UDim2.new(0, 0, 0, 0)
    tabHalloween.BackgroundTransparency = 1
    tabHalloween.BorderSizePixel = 0
    tabHalloween.Visible = false
    tabHalloween.Parent = contentContainer
    UI.Elements.TabHalloween = tabHalloween

    -- Row 2.5.1: Halloween Filter Bar (Rarity Dropdown)
    local hwFilterBar = Instance.new("Frame")
    hwFilterBar.Name = "HwFilterBar"
    hwFilterBar.Size = UDim2.new(1, -16, 0, 26)
    hwFilterBar.Position = UDim2.new(0, 8, 0, 8)
    hwFilterBar.BackgroundTransparency = 1
    hwFilterBar.BorderSizePixel = 0
    hwFilterBar.ClipsDescendants = false
    hwFilterBar.ZIndex = 40
    hwFilterBar.Parent = tabHalloween

    local hwRarityBtn = Instance.new("TextButton")
    hwRarityBtn.Name = "HwRarityDropdownBtn"
    hwRarityBtn.Size = UDim2.new(1, -114, 1, 0)
    hwRarityBtn.Position = UDim2.new(0, 0, 0, 0)
    hwRarityBtn.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
    hwRarityBtn.Text = "Rarity: All ▼"
    hwRarityBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
    hwRarityBtn.TextSize = 10.5
    hwRarityBtn.Font = Enum.Font.GothamBold
    hwRarityBtn.Parent = hwFilterBar
    Instance.new("UICorner", hwRarityBtn).CornerRadius = UDim.new(0, 4)
    UI.Elements.HwRarityDropdownBtn = hwRarityBtn

    local hwFilterPickupBtn = Instance.new("TextButton")
    hwFilterPickupBtn.Name = "HwFilterPickupBtn"
    hwFilterPickupBtn.Size = UDim2.new(0, 110, 1, 0)
    hwFilterPickupBtn.Position = UDim2.new(1, -110, 0, 0)
    hwFilterPickupBtn.BackgroundColor3 = (Config.HwPickup and Config.HwPickup.Enabled) and theme.GreenOn or theme.GrayOff
    hwFilterPickupBtn.Text = (Config.HwPickup and Config.HwPickup.Enabled) and "⚡ Fast Pick: ON" or "⚡ Fast Pick: OFF"
    hwFilterPickupBtn.TextColor3 = (Config.HwPickup and Config.HwPickup.Enabled) and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    hwFilterPickupBtn.TextSize = 10.5
    hwFilterPickupBtn.Font = Enum.Font.GothamBold
    hwFilterPickupBtn.Parent = hwFilterBar
    Instance.new("UICorner", hwFilterPickupBtn).CornerRadius = UDim.new(0, 4)
    UI.Elements.HwFilterPickupBtn = hwFilterPickupBtn

    UI.createFilterDropdown({
        parent = hwFilterBar,
        btn = hwRarityBtn,
        title = "Rarity",
        items = Config.Taxonomy.FarmableRarities,
        colorMap = Config.Taxonomy.RarityColors,
        getSelected = function() return Engine.State.SelectedHwRarities end,
        setSelected = function(v) Engine.State.SelectedHwRarities = v end,
        onChanged = function()
            if UI.renderHalloweenEggs then pcall(UI.renderHalloweenEggs) end
        end,
        size = UDim2.new(1, -114, 0, 240),
        pos = UDim2.new(0, 0, 0, 28),
        scrollable = true,
        zIndex = 50,
    })

    -- Scroll Frame for Halloween eggs
    local hwScroll = Instance.new("ScrollingFrame")
    hwScroll.Name = "HwEggListScroll"
    hwScroll.Size = UDim2.new(1, -16, 1, -46)
    hwScroll.Position = UDim2.new(0, 8, 0, 38)
    hwScroll.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
    hwScroll.BorderSizePixel = 0
    hwScroll.ScrollBarThickness = 4
    hwScroll.ScrollBarImageColor3 = Color3.fromRGB(200, 95, 25)
    hwScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    hwScroll.ZIndex = 1
    hwScroll.Parent = tabHalloween
    Instance.new("UICorner", hwScroll).CornerRadius = UDim.new(0, 6)

    local hwListLayout = Instance.new("UIListLayout")
    hwListLayout.Padding = UDim.new(0, 4)
    hwListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    hwListLayout.Parent = hwScroll
    UI.Elements.HwEggListScroll = hwScroll

    -- Empty Notice
    local hwEmptyNotice = Instance.new("TextLabel")
    hwEmptyNotice.Name = "HwEmptyNotice"
    hwEmptyNotice.Size = UDim2.new(1, -20, 0, 70)
    hwEmptyNotice.Position = UDim2.new(0, 10, 0, 20)
    hwEmptyNotice.BackgroundTransparency = 1
    hwEmptyNotice.Text = "No Halloween eggs currently detected.\n(Waiting for WorldEggs in Halloween Dimension)"
    hwEmptyNotice.TextColor3 = Color3.fromRGB(180, 150, 130)
    hwEmptyNotice.TextSize = 11.5
    hwEmptyNotice.Font = Enum.Font.Gotham
    hwEmptyNotice.TextWrapped = true
    hwEmptyNotice.Visible = true
    hwEmptyNotice.Parent = hwScroll
    UI.Elements.HwEmptyNotice = hwEmptyNotice
end

-- Card Pool Factory (Zero-Allocation DOM Recycling)
UI.getOrCreateCard = function(idx)
    if UI.CardPool[idx] then return UI.CardPool[idx] end

    local scroll = UI.Elements.EggListScroll
    local card = Instance.new("Frame")
    card.Name = "EggCard_" .. idx
    card.Size = UDim2.new(1, 0, 0, Config.UI.CardHeight)
    card.BackgroundColor3 = Config.UI.Theme.CardBg
    card.Parent = scroll
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)
    local stroke = Instance.new("UIStroke", card)
    stroke.Color = Config.UI.Theme.CardStroke
    stroke.Thickness = 1

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Name = "Title"
    titleLbl.Size = UDim2.new(1, -135, 0, 20)
    titleLbl.Position = UDim2.new(0, 10, 0, 4)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 12
    titleLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = card

    local tagBiome = Instance.new("TextLabel")
    tagBiome.Name = "TagBiome"
    tagBiome.Size = UDim2.new(0, 70, 0, 16)
    tagBiome.Position = UDim2.new(0, 10, 0, 26)
    tagBiome.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
    tagBiome.Font = Enum.Font.GothamBold
    tagBiome.TextSize = 9.5
    tagBiome.TextColor3 = Color3.fromRGB(180, 205, 245)
    tagBiome.Parent = card
    Instance.new("UICorner", tagBiome).CornerRadius = UDim.new(0, 3)

    local tagRarity = Instance.new("TextLabel")
    tagRarity.Name = "TagRarity"
    tagRarity.Size = UDim2.new(0, 65, 0, 16)
    tagRarity.Position = UDim2.new(0, 84, 0, 26)
    tagRarity.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
    tagRarity.Font = Enum.Font.GothamBold
    tagRarity.TextSize = 9.5
    tagRarity.TextColor3 = Color3.fromRGB(255, 255, 255)
    tagRarity.Parent = card
    Instance.new("UICorner", tagRarity).CornerRadius = UDim.new(0, 3)

    local tpBtn = Instance.new("TextButton")
    tpBtn.Name = "TpBtn"
    tpBtn.Size = UDim2.new(0, 52, 0, 26)
    tpBtn.Position = UDim2.new(1, -114, 0.5, -13)
    tpBtn.BackgroundColor3 = Color3.fromRGB(45, 105, 175)
    tpBtn.Text = "TP"
    tpBtn.TextColor3 = Color3.new(1, 1, 1)
    tpBtn.Font = Enum.Font.GothamBold
    tpBtn.TextSize = 11
    tpBtn.Parent = card
    Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)

    local walkBtn = Instance.new("TextButton")
    walkBtn.Name = "WalkBtn"
    walkBtn.Size = UDim2.new(0, 52, 0, 26)
    walkBtn.Position = UDim2.new(1, -58, 0.5, -13)
    walkBtn.BackgroundColor3 = Color3.fromRGB(35, 130, 80)
    walkBtn.Text = "WALK"
    walkBtn.TextColor3 = Color3.new(1, 1, 1)
    walkBtn.Font = Enum.Font.GothamBold
    walkBtn.TextSize = 11
    walkBtn.Parent = card
    Instance.new("UICorner", walkBtn).CornerRadius = UDim.new(0, 4)

    local item = {
        card      = card,
        titleLbl  = titleLbl,
        tagBiome  = tagBiome,
        tagRarity = tagRarity,
        tpBtn     = tpBtn,
        walkBtn   = walkBtn,
        data      = nil,
    }

    addConnection(tpBtn.MouseButton1Click:Connect(function()
        if item.data and Engine.Travel then
            Engine.Travel.teleportToEgg(item.data)
        end
    end))

    addConnection(walkBtn.MouseButton1Click:Connect(function()
        if item.data and Engine.Travel then
            Engine.Travel.walkToEgg(item.data)
        end
    end))

    UI.CardPool[idx] = item
    return item
end

UI.getOrCreateHwCard = function(idx)
    if UI.HwCardPool[idx] then return UI.HwCardPool[idx] end

    local scroll = UI.Elements.HwEggListScroll
    local card = Instance.new("Frame")
    card.Name = "HwEggCard_" .. idx
    card.Size = UDim2.new(1, 0, 0, Config.UI.CardHeight)
    card.BackgroundColor3 = Config.UI.Theme.CardBg
    card.Parent = scroll
    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)
    local stroke = Instance.new("UIStroke", card)
    stroke.Color = Config.UI.Theme.CardStroke
    stroke.Thickness = 1

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Name = "Title"
    titleLbl.Size = UDim2.new(1, -135, 0, 20)
    titleLbl.Position = UDim2.new(0, 10, 0, 4)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 12
    titleLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = card

    local tagZone = Instance.new("TextLabel")
    tagZone.Name = "TagZone"
    tagZone.Size = UDim2.new(0, 70, 0, 16)
    tagZone.Position = UDim2.new(0, 10, 0, 26)
    tagZone.BackgroundColor3 = Color3.fromRGB(45, 35, 25)
    tagZone.Font = Enum.Font.GothamBold
    tagZone.TextSize = 9.5
    tagZone.TextColor3 = Color3.fromRGB(245, 180, 120)
    tagZone.Parent = card
    Instance.new("UICorner", tagZone).CornerRadius = UDim.new(0, 3)

    local tagRarity = Instance.new("TextLabel")
    tagRarity.Name = "TagRarity"
    tagRarity.Size = UDim2.new(0, 65, 0, 16)
    tagRarity.Position = UDim2.new(0, 84, 0, 26)
    tagRarity.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
    tagRarity.Font = Enum.Font.GothamBold
    tagRarity.TextSize = 9.5
    tagRarity.TextColor3 = Color3.fromRGB(255, 255, 255)
    tagRarity.Parent = card
    Instance.new("UICorner", tagRarity).CornerRadius = UDim.new(0, 3)

    local tpBtn = Instance.new("TextButton")
    tpBtn.Name = "TpBtn"
    tpBtn.Size = UDim2.new(0, 52, 0, 26)
    tpBtn.Position = UDim2.new(1, -114, 0.5, -13)
    tpBtn.BackgroundColor3 = Color3.fromRGB(175, 85, 35)
    tpBtn.Text = "TP"
    tpBtn.TextColor3 = Color3.new(1, 1, 1)
    tpBtn.Font = Enum.Font.GothamBold
    tpBtn.TextSize = 11
    tpBtn.Parent = card
    Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)

    local walkBtn = Instance.new("TextButton")
    walkBtn.Name = "WalkBtn"
    walkBtn.Size = UDim2.new(0, 52, 0, 26)
    walkBtn.Position = UDim2.new(1, -58, 0.5, -13)
    walkBtn.BackgroundColor3 = Color3.fromRGB(35, 130, 80)
    walkBtn.Text = "WALK"
    walkBtn.TextColor3 = Color3.new(1, 1, 1)
    walkBtn.Font = Enum.Font.GothamBold
    walkBtn.TextSize = 11
    walkBtn.Parent = card
    Instance.new("UICorner", walkBtn).CornerRadius = UDim.new(0, 4)

    local item = {
        card      = card,
        titleLbl  = titleLbl,
        tagZone   = tagZone,
        tagRarity = tagRarity,
        tpBtn     = tpBtn,
        walkBtn   = walkBtn,
        data      = nil,
    }

    addConnection(tpBtn.MouseButton1Click:Connect(function()
        if item.data and item.data.Position then
            Engine.Travel.teleportTo(item.data.Position, true)
        end
    end))

    addConnection(walkBtn.MouseButton1Click:Connect(function()
        if item.data and item.data.Position then
            Engine.Travel.walkToTarget(item.data.Position, 2.5, nil, item.data.Uid)
        end
    end))

    UI.HwCardPool[idx] = item
    return item
end

-- ============================================================================
-- SECTION 3: HELPER CODE
-- ============================================================================

-- 3.1 Network Remote Resolution
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

-- 3.2 Safe UI Parenting & Dragging
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

-- 3.3 Player Controls & Character Utilities
Helpers.enablePlayerControls = function()
    if Engine.State and Engine.State.CachedControls and Engine.State.CachedControls.Enable then
        pcall(function() Engine.State.CachedControls:Enable() end)
        return
    end
    pcall(function()
        local ps = LocalPlayer and (LocalPlayer:FindFirstChildOfClass("PlayerScripts") or LocalPlayer:FindFirstChild("PlayerScripts"))
        local pm = ps and ps:FindFirstChild("PlayerModule")
        if pm then
            local c = require(pm)
            if c and c.GetControls then
                local ctrl = c:GetControls()
                if ctrl and ctrl.Enable then
                    if Engine.State then Engine.State.CachedControls = ctrl end
                    ctrl:Enable()
                end
            end
        end
    end)
end

Helpers.isAlive = function()
    return hrp ~= nil and hrp.Parent ~= nil and hum ~= nil and hum.Parent ~= nil and hum.Health > 0 and hum:GetState() ~= Enum.HumanoidStateType.Dead
end

Helpers.applyReachAssist = function(targetPos)
    if not (hrp and hrp.Parent and targetPos) then return false end
    local dist = (hrp.Position - targetPos).Magnitude
    if dist <= 35.0 then
        if Engine.Travel and Engine.Travel.teleportTo then
            return Engine.Travel.teleportTo(targetPos)
        end
        pcall(function()
            hrp.CFrame = CFrame.new(targetPos + Vector3.new(0, 2.5, 0))
            Engine.State.LastGoodCFrame = hrp.CFrame
        end)
        return true
    end
    return false
end

-- 3.4 String & Taxonomy Normalizers
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

-- Indexed Taxonomy tables
local SPECIES_INFO, SPECIES_INFO_BY_BIOME, EGG_ALIASES = {}, {}, {}
Helpers.SpeciesInfo = SPECIES_INFO
Helpers.SpeciesInfoByBiome = SPECIES_INFO_BY_BIOME
Helpers.EggAliases = EGG_ALIASES

-- EGG_ALIASES populated dynamically from BiomeCatalog

for _, biomeData in ipairs(Config.Taxonomy.BiomeCatalog) do
    if not SPECIES_INFO_BY_BIOME[biomeData.Biome] then
        SPECIES_INFO_BY_BIOME[biomeData.Biome] = {}
    end
    for _, spec in ipairs(biomeData.Species) do
        local canonicalNorm = Helpers.normalizeSpecies(spec.Name)
        local record = {
            DisplayName = spec.Name,
            Rarity      = spec.Rarity,
            Rank        = Config.Taxonomy.RarityRank[spec.Rarity] or 0,
            Biome       = biomeData.Biome,
            IsCataloged = true,
        }
        if canonicalNorm ~= "" and not SPECIES_INFO[canonicalNorm] then
            SPECIES_INFO[canonicalNorm] = record
        end
        if canonicalNorm ~= "" then
            SPECIES_INFO_BY_BIOME[biomeData.Biome][canonicalNorm] = record
        end

        local inner = spec.Name:match("%((.-)%)")
        if inner then
            local innerNorm = Helpers.normalizeSpecies(inner)
            if innerNorm ~= "" then
                if not SPECIES_INFO[innerNorm] then
                    SPECIES_INFO[innerNorm] = record
                end
                SPECIES_INFO_BY_BIOME[biomeData.Biome][innerNorm] = record
                EGG_ALIASES[innerNorm] = canonicalNorm
            end
        end

        if spec.Aliases then
            for _, al in ipairs(spec.Aliases) do
                local aNorm = Helpers.normalizeSpecies(al)
                if aNorm ~= "" then
                    EGG_ALIASES[aNorm] = canonicalNorm
                    SPECIES_INFO_BY_BIOME[biomeData.Biome][aNorm] = record
                    if not SPECIES_INFO[aNorm] then
                        SPECIES_INFO[aNorm] = record
                    end
                end
            end
        end
    end

    if biomeData.Biome == "Light & Dark" then
        if not SPECIES_INFO_BY_BIOME["Angel Eggs"] then SPECIES_INFO_BY_BIOME["Angel Eggs"] = {} end
        if not SPECIES_INFO_BY_BIOME["Demon Eggs"] then SPECIES_INFO_BY_BIOME["Demon Eggs"] = {} end
        for k, v in pairs(SPECIES_INFO_BY_BIOME["Light & Dark"]) do
            if v.DisplayName:find("Dove") or v.DisplayName:find("Lamb") or v.DisplayName:find("Moth") or v.DisplayName:find("Peacock") or v.DisplayName:find("Jellyfish") or v.DisplayName:find("Centaur") or v.DisplayName:find("Pegasus") or v.DisplayName:find("ArchAngel") then
                SPECIES_INFO_BY_BIOME["Angel Eggs"][k] = v
            else
                SPECIES_INFO_BY_BIOME["Demon Eggs"][k] = v
            end
        end
    end

    if biomeData.Biome == "Halloween Dimension" then
        SPECIES_INFO_BY_BIOME["Halloween"] = SPECIES_INFO_BY_BIOME["Halloween Dimension"]
    end
end

Helpers.getSpeciesInfo = function(rawName, searchArea)
    if not rawName or type(rawName) ~= "string" or rawName == "" then return nil end
    local clean = Helpers.normalizeSpecies(rawName)
    if clean == "" then return nil end

    if searchArea and searchArea ~= "" and searchArea ~= "Unknown" and SPECIES_INFO_BY_BIOME[searchArea] then
        local bRec = SPECIES_INFO_BY_BIOME[searchArea][clean]
        if bRec then return bRec end
    end

    if clean == "shark" and (searchArea == "Titan Temple" or searchArea == "Temple") then
        local bTable = SPECIES_INFO_BY_BIOME["Titan Temple"]
        if bTable and bTable["mutant shark"] then return bTable["mutant shark"] end
    end

    if SPECIES_INFO[clean] then return SPECIES_INFO[clean] end
    local canonical = EGG_ALIASES[clean]
    if canonical and SPECIES_INFO[canonical] then
        return SPECIES_INFO[canonical]
    end

    for _, bTable in pairs(SPECIES_INFO_BY_BIOME) do
        if bTable[clean] then return bTable[clean] end
    end

    return nil
end

Helpers.registerDynamicSpecies = function(rawName, defaultBiome, defaultRarity)
    if not rawName or type(rawName) ~= "string" or rawName == "" then return false end
    if Helpers.isGenericEggName(rawName) then return false end
    local clean = Helpers.normalizeSpecies(rawName)
    if clean == "" then return false end

    local existing = Helpers.getSpeciesInfo(rawName, defaultBiome) or SPECIES_INFO[clean]
    if existing and existing.IsCataloged then
        return false
    end

    local disp = (existing and existing.DisplayName) or rawName
    local biome = (existing and existing.Biome) or defaultBiome
    if not biome or biome == "" or biome == "Unknown" then
        biome = "Ungrouped"
    end
    local isCataloged = (existing and existing.IsCataloged == true)
    local rarity = (isCataloged and existing.Rarity) or defaultRarity or "Unknown"
    local rank = (isCataloged and existing.Rank) or (Config.Taxonomy.RarityRank[rarity] or 1)

    local record = existing or {
        DisplayName = disp,
        Rarity      = rarity,
        Rank        = rank,
        Biome       = biome,
        IsCataloged = false,
    }
    if not SPECIES_INFO[clean] then
        SPECIES_INFO[clean] = record
        if not SPECIES_INFO_BY_BIOME[biome] then
            SPECIES_INFO_BY_BIOME[biome] = {}
        end
        SPECIES_INFO_BY_BIOME[biome][clean] = record
        return true
    end
    return false
end

-- Dynamic Game Discovery for Egg Species & Template Signatures (ReplicatedStorage.Assets.Models.Eggs)
Helpers.GenericPartNames = {
    hitbox = true, part = true, meshpart = true, model = true,
    basepart = true, weld = true, weldconstraint = true,
    pointlight = true, attachment = true, eggradius = true,
    egggrip = true, eggglow = true, eggrootweld = true
}

Helpers.TemplateSignatures = nil
Helpers.getTemplateSignatures = function()
    if Helpers.TemplateSignatures then return Helpers.TemplateSignatures end
    pcall(function()
        local eggsFolder = ReplicatedStorage:FindFirstChild("Assets")
            and ReplicatedStorage.Assets:FindFirstChild("Models")
            and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
        if not eggsFolder then return end
        local sigs = {}
        for _, tModel in ipairs(eggsFolder:GetChildren()) do
            if tModel:IsA("Model") then
                local childrenSet = {}
                for _, tc in ipairs(tModel:GetChildren()) do
                    local tcLower = tc.Name:lower()
                    if not Helpers.GenericPartNames[tcLower] then
                        childrenSet[tcLower] = true
                    end
                end
                table.insert(sigs, { Name = tModel.Name, Children = childrenSet })
            end
        end
        if #sigs > 0 then
            Helpers.TemplateSignatures = sigs
        end
    end)
    return Helpers.TemplateSignatures
end

pcall(function()
    local eggsFolder = ReplicatedStorage:FindFirstChild("Assets")
        and ReplicatedStorage.Assets:FindFirstChild("Models")
        and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
    if eggsFolder then
        for _, child in ipairs(eggsFolder:GetChildren()) do
            Helpers.registerDynamicSpecies(child.Name)
        end
        Helpers.getTemplateSignatures()
    end
end)

Helpers.matchTemplateEgg = function(model)
    if not model then return nil end
    local sigs = Helpers.getTemplateSignatures()
    if not sigs or #sigs == 0 then return nil end
    local liveChildren = {}
    for _, c in ipairs(model:GetChildren()) do
        local cLower = c.Name:lower()
        if not Helpers.GenericPartNames[cLower] then
            liveChildren[cLower] = true
        end
    end
    local nonGenericCount = 0
    for _ in pairs(liveChildren) do nonGenericCount = nonGenericCount + 1 end
    if nonGenericCount == 0 then return nil end

    local bestName, bestCount = nil, 0
    for _, sig in ipairs(sigs) do
        local matchCount = 0
        for childName in pairs(sig.Children) do
            if liveChildren[childName] then matchCount = matchCount + 1 end
        end
        if matchCount > bestCount then
            bestCount = matchCount
            bestName = sig.Name
        end
    end
    if bestCount >= 2 and bestName then
        local sInfo = Helpers.getSpeciesInfo(bestName, "Halloween Dimension") or Helpers.getSpeciesInfo(bestName)
        return (sInfo and sInfo.DisplayName) or bestName
    end
    return nil
end

Helpers.resolveHalloweenEggName = function(model)
    if not model then return "Hooded Gerbil Egg" end

    -- 1. Direct attributes on model
    local rawName = model:GetAttribute("PreparedSourceName")
        or model:GetAttribute("DisplayName")
        or model:GetAttribute("EggName")
        or model:GetAttribute("EggType")
        or model:GetAttribute("Species")
        or model:GetAttribute("Name")

    if rawName and tostring(rawName) ~= "" and not Helpers.isGenericEggName(tostring(rawName)) and tostring(rawName):lower() ~= "halloweenegg" and tostring(rawName):lower() ~= "halloween egg" then
        local sInfo = Helpers.getSpeciesInfo(tostring(rawName), "Halloween Dimension") or Helpers.getSpeciesInfo(tostring(rawName))
        if sInfo and sInfo.DisplayName then
            return sInfo.DisplayName
        end
    end

    -- 2. Direct attributes on Hitbox
    local hitbox = model:FindFirstChild("Hitbox")
    if hitbox then
        local hbAttr = hitbox:GetAttribute("PreparedSourceName")
            or hitbox:GetAttribute("DisplayName")
            or hitbox:GetAttribute("EggName")
            or hitbox:GetAttribute("EggType")
            or hitbox:GetAttribute("Species")
        if hbAttr and tostring(hbAttr) ~= "" and not Helpers.isGenericEggName(tostring(hbAttr)) and tostring(hbAttr):lower() ~= "halloweenegg" and tostring(hbAttr):lower() ~= "halloween egg" then
            local sInfo = Helpers.getSpeciesInfo(tostring(hbAttr), "Halloween Dimension") or Helpers.getSpeciesInfo(tostring(hbAttr))
            if sInfo and sInfo.DisplayName then
                return sInfo.DisplayName
            end
        end
    end

    -- 3. Child StringValues or child Models
    for _, ch in ipairs(model:GetChildren()) do
        if ch:IsA("StringValue") and ch.Value ~= "" and not Helpers.isGenericEggName(ch.Value) and ch.Value:lower() ~= "halloweenegg" and ch.Value:lower() ~= "halloween egg" then
            local sInfo = Helpers.getSpeciesInfo(ch.Value, "Halloween Dimension") or Helpers.getSpeciesInfo(ch.Value)
            if sInfo and sInfo.DisplayName then
                return sInfo.DisplayName
            end
        elseif ch:IsA("Model") and ch.Name ~= "Model" and ch.Name ~= "Hitbox" and not Helpers.isGenericEggName(ch.Name) and ch.Name:lower() ~= "halloweenegg" and ch.Name:lower() ~= "halloween egg" then
            local sInfo = Helpers.getSpeciesInfo(ch.Name, "Halloween Dimension") or Helpers.getSpeciesInfo(ch.Name)
            if sInfo and sInfo.DisplayName then
                return sInfo.DisplayName
            end
        end
    end

    -- 4. ProximityPrompt inspection: exact lookups and keyword substring matches
    local prMatch = nil
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local objTxt = d.ObjectText or ""
            local actTxt = d.ActionText or ""

            if objTxt ~= "" and not Helpers.isGenericEggName(objTxt) and objTxt:lower() ~= "halloweenegg" and objTxt:lower() ~= "halloween egg" then
                local pInfo = Helpers.getSpeciesInfo(objTxt, "Halloween Dimension") or Helpers.getSpeciesInfo(objTxt)
                if pInfo and pInfo.DisplayName then
                    prMatch = pInfo.DisplayName
                    break
                end
            end
            if actTxt ~= "" and not Helpers.isGenericEggName(actTxt) and actTxt:lower() ~= "halloweenegg" and actTxt:lower() ~= "halloween egg" then
                local pInfo = Helpers.getSpeciesInfo(actTxt, "Halloween Dimension") or Helpers.getSpeciesInfo(actTxt)
                if pInfo and pInfo.DisplayName then
                    prMatch = pInfo.DisplayName
                    break
                end
            end

            local fullTxt = (objTxt .. " " .. actTxt):lower()
            if fullTxt ~= "" then
                local bestMatch, bestLen = nil, 0
                local hwSpecies = SPECIES_INFO_BY_BIOME["Halloween Dimension"]
                if hwSpecies then
                    for cleanName, rec in pairs(hwSpecies) do
                        if cleanName ~= "egg" and cleanName ~= "halloween" and cleanName ~= "halloweenegg" and #cleanName >= 3 then
                            if fullTxt:find(cleanName, 1, true) and #cleanName > bestLen then
                                bestMatch = rec.DisplayName
                                bestLen = #cleanName
                            end
                        end
                    end
                end
                if not bestMatch then
                    for cleanName, rec in pairs(SPECIES_INFO) do
                        if cleanName ~= "egg" and cleanName ~= "halloween" and cleanName ~= "halloweenegg" and #cleanName >= 3 then
                            if rec.DisplayName and fullTxt:find(cleanName, 1, true) and #cleanName > bestLen then
                                bestMatch = rec.DisplayName
                                bestLen = #cleanName
                            end
                        end
                    end
                end
                if bestMatch then
                    prMatch = bestMatch
                    break
                end
            end
        end
    end
    if prMatch then return prMatch end

    -- 5. Standard HalloweenEgg / Halloween Egg model represents Hooded Gerbil Egg
    if model.Name == "HalloweenEgg" or model.Name == "Halloween Egg" then
        return "Hooded Gerbil Egg"
    end

    -- 6. Speculative template match against ReplicatedStorage.Assets.Models.Eggs (for unnamed models like "Egg")
    local tplMatch = Helpers.matchTemplateEgg(model)
    if tplMatch then return tplMatch end

    -- 7. Model name lookup if not generic
    if model.Name ~= "Egg" and not Helpers.isGenericEggName(model.Name) then
        local mInfo = Helpers.getSpeciesInfo(model.Name, "Halloween Dimension") or Helpers.getSpeciesInfo(model.Name)
        if mInfo and mInfo.DisplayName then
            return mInfo.DisplayName
        end
    end

    -- 8. Fallback for generic egg model
    return "Hooded Gerbil Egg"
end

-- 3.5 Proximity Prompt Filtering
Helpers.isCarryPrompt = function(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    if not prompt.Enabled then return false end
    local n = prompt.Name:lower()
    local a = prompt.ActionText:lower()
    local o = prompt.ObjectText:lower()
    for _, bl in ipairs({ "shop", "hatch", "buy", "purchase", "open", "talk", "manor" }) do
        if n:find(bl, 1, true) or a:find(bl, 1, true) or o:find(bl, 1, true) then
            return false
        end
    end
    if n:find("carry", 1, true) or n:find("steal", 1, true) or n:find("pickup", 1, true) or n:find("eggprompt", 1, true) then
        return true
    end
    if a:find("steal", 1, true) or a:find("carry", 1, true) or a:find("pick", 1, true) or a:find("take", 1, true) or a:find("grab", 1, true) then
        return true
    end
    return false
end

Helpers.triggerProximityPrompt = function(prompt)
    if not prompt then return false end
    local okFire = pcall(function()
        if fireproximityprompt then
            fireproximityprompt(prompt, 1)
        elseif prompt.InputHoldBegin then
            prompt:InputHoldBegin()
            task.wait(prompt.HoldDuration or 0)
            prompt:InputHoldEnd()
        end
    end)
    return okFire
end

-- 3.6 Diagnostic JSON Exporter
Helpers.exportEggListJson = function()
    local exportData = {
        exportedAt    = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        totalCached   = 0,
        totalFarmable = 0,
        farmableEggs  = {},
        allEggs       = {},
    }

    local charPos = nil
    if hrp and hrp.Parent then
        charPos = hrp.Position
    end

    for uid, r in pairs(Engine.State.EggCacheByUid) do
        exportData.totalCached = exportData.totalCached + 1
        local rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist = Engine.Travel.resolveEggFields(r, uid, charPos)
        local item = {
            uid        = tostring(uid),
            rawName    = rawName,
            species    = disp,
            rarity     = rarity,
            rank       = rank,
            biome      = biome,
            state      = r.State or "Slot",
            distance   = dist and math.floor(dist * 10 + 0.5) / 10 or nil,
            isFarmable = Engine.Travel.isFarmableEgg(r),
        }
        table.insert(exportData.allEggs, item)
        if item.isFarmable then
            table.insert(exportData.farmableEggs, item)
        end
    end

    exportData.totalFarmable = #exportData.farmableEggs
    table.sort(exportData.farmableEggs, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return (a.distance or 99999) < (b.distance or 99999)
    end)

    local okJson, jsonStr = pcall(function() return HttpService:JSONEncode(exportData) end)
    if okJson and jsonStr then
        if setclipboard then
            pcall(setclipboard, jsonStr)
            return true, #exportData.farmableEggs
        end
    end
    return false, 0
end

-- ============================================================================
-- SECTION 4: ENGINE (Core & Loop Logic)
-- ============================================================================

-- 4.1 State Management
Engine.State = {
    VelocityEnabled       = false,
    IsCarry               = false,
    WeAreCarrying         = false,
    IsCarrying            = false,
    CarryUid              = nil,
    ActiveWalkToken       = 0,
    ActiveWalkTarget      = nil,
    AutoReturnActive      = false,
    ReturnTripInProgress  = false,
    AutoReturnTargetUid   = nil,
    NoclipActive          = false,
    NoclipParts           = {},
    AutoPickupToken       = 0,
    HwPickupToken         = 0,
    EggCacheByUid         = {},
    RarityByUid           = {},
    SelectedBiomes        = { ["All"] = true },
    SelectedRarities      = {},
    SelectedHwRarities    = { ["Divine"] = true, ["Eternal"] = true, ["Secret"] = true },
    BaseGoSpeed           = Config.Velocity.DefaultGoSpeed,
    BaseCarrySpeed        = Config.Velocity.DefaultCarrySpeed,
    ListDirty             = false,
    IsRecovering          = false,
    LastRecoveryTime      = 0,
    SavedWalkSpeed        = 16.0,
    CachedControls        = nil,
    LastGoodCFrame        = nil,
}

-- Initialize default selected rarities
for r, sel in pairs(Config.Taxonomy.DefaultSelectedRarities) do
    Engine.State.SelectedRarities[r] = sel
end

-- 4.2 Velocity Engine (Continuous Speed with isCarry true/false param)
Engine.Velocity = {}

Engine.Velocity.setCarry = function(isCarry)
    local carryBool = (isCarry == true)
    Engine.State.IsCarry = carryBool
    Engine.State.WeAreCarrying = carryBool
    Engine.State.IsCarrying = carryBool
    if not carryBool then
        Engine.State.CarryUid = nil
    end

    if hum and hum.Parent and hum.Health > 0 then
        if Engine.State.VelocityEnabled then
            local spd = carryBool and Engine.State.BaseCarrySpeed or Engine.State.BaseGoSpeed
            pcall(function() hum.WalkSpeed = spd end)
        else
            pcall(function() hum.WalkSpeed = math.max(Engine.State.SavedWalkSpeed or 16.0, 16.0) end)
        end
    end

    if UI.updateActivityStatus then
        pcall(UI.updateActivityStatus)
    end

    if carryBool and Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
        if Engine.Travel and Engine.Travel.startReturnTrip then
            task.spawn(Engine.Travel.startReturnTrip)
        end
    end
end

Engine.Velocity.setCarryingState = function(carrying)
    Engine.Velocity.setCarry(carrying)
end

Engine.Velocity.setSpeed = function(isCarry)
    Engine.Velocity.setCarry(isCarry)
end

Engine.Velocity.getCarryingStatus = function()
    return Engine.State.IsCarry == true
end

Engine.Velocity.isHoldingFieldEgg = function()
    return Engine.State.IsCarry == true
end

Engine.Velocity.isHoldingEgg = function()
    return Engine.State.IsCarry == true
end

Engine.Velocity.updatePhysics = function(isCarry)
    if isCarry ~= nil then
        Engine.Velocity.setCarry(isCarry)
    end
    if not Engine.State.VelocityEnabled then return end
    if not (hrp and hrp.Parent and hum and hum.Parent and hum.Health > 0) then return end

    -- Void death check: if falling into void below Y = -400, cancel auto-walk & velocity
    if hrp.Position.Y < -400 then
        Engine.Travel.stopWalking()
        Engine.Velocity.setCarry(false)
        return
    end

    local isMoving = (hum.MoveDirection.Magnitude > 0.05)
    local targetSpeed = Engine.State.IsCarry and Engine.State.BaseCarrySpeed or Engine.State.BaseGoSpeed
    if hum.WalkSpeed ~= targetSpeed then
        pcall(function() hum.WalkSpeed = targetSpeed end)
    end

    if not Engine.State.ActiveWalkTarget and not isMoving then
        return
    end

    -- Active Auto-Walk to target (walking to egg or safezone)
    if Engine.State.ActiveWalkTarget then
        local curPos = hrp.Position
        local diff = Vector3.new(Engine.State.ActiveWalkTarget.X - curPos.X, 0, Engine.State.ActiveWalkTarget.Z - curPos.Z)
        local targetDir = diff.Magnitude > 0.1 and diff.Unit or Vector3.zero
        hum:Move(targetDir, false)
        if targetDir.Magnitude > 0.05 then
            hrp.AssemblyLinearVelocity = Vector3.new(
                targetDir.X * targetSpeed,
                hrp.AssemblyLinearVelocity.Y,
                targetDir.Z * targetSpeed
            )
        end
        return
    end

    -- Manual WASD free-roam
    if hum.MoveDirection.Magnitude > 0.05 then
        local dir = hum.MoveDirection.Unit
        hrp.AssemblyLinearVelocity = Vector3.new(
            dir.X * targetSpeed,
            hrp.AssemblyLinearVelocity.Y,
            dir.Z * targetSpeed
        )
    end
end

-- 4.3 Zero-Wait Instant Ragdoll Recovery Engine
Engine.Recovery = {
    Joints = {},
    Connections = {},
    HooksInstalled = false,
}

Engine.Recovery.clearRagdollAttributes = function()
    pcall(function()
        if LocalPlayer then
            LocalPlayer:SetAttribute("RagdollEndTime", 0)
            LocalPlayer:SetAttribute("RagdollTime", 0)
            LocalPlayer:SetAttribute("IsRagdoll", false)
            LocalPlayer:SetAttribute("Ragdolled", false)
        end
        if Character then
            Character:SetAttribute("RagdollEndTime", 0)
            Character:SetAttribute("RagdollTime", 0)
            Character:SetAttribute("IsRagdoll", false)
            Character:SetAttribute("Ragdolled", false)
        end
    end)
end

Engine.Recovery.breakJointFallbacks = function(char, hum, hrp)
    if not (char and hum and hrp) then return end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("Motor6D") and not d:FindFirstAncestorWhichIsA("Tool") and not d:FindFirstAncestorWhichIsA("Accessory") then
            if not d.Enabled then
                pcall(function() d.Enabled = true end)
            end
            pcall(function() d.Transform = CFrame.identity end)
        elseif d:IsA("BallSocketConstraint") or d:IsA("HingeConstraint") then
            pcall(function() d.Enabled = false end)
        end
    end
end

Engine.Recovery.neutraliseCarriedEggMass = function(char)
    if not char then return end
    for _, desc in ipairs(char:GetDescendants()) do
        if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" and desc.Parent ~= char then
            pcall(function()
                desc.Massless = true
                desc.CanCollide = false
            end)
        end
    end
end

Engine.Recovery.execute = function(reason)
    if not Config.Recovery.Enabled then return end
    local now = os.clock()
    if Engine.State.IsRecovering or (now - Engine.State.LastRecoveryTime < Config.Recovery.DebounceWindow) then
        return
    end
    Engine.State.IsRecovering = true
    Engine.State.LastRecoveryTime = now

    pcall(function()
        if not (hrp and hrp.Parent and hum and hum.Parent and hum.Health > 0) then return end

        Engine.Recovery.clearRagdollAttributes()
        Engine.Recovery.breakJointFallbacks(Character, hum, hrp)

        hum.PlatformStand = false
        hum.Sit = false
        hum.AutoRotate = true

        pcall(function()
            hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
            hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
            hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
            hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            hum:ChangeState(Enum.HumanoidStateType.Running)
            hum.Jump = true

            local animator = hum:FindFirstChildOfClass("Animator")
            if animator then
                for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                    local animName = track.Name:lower()
                    if animName:find("getup") or animName:find("fall") or animName:find("ragdoll") or animName:find("sit") then
                        pcall(function() track:Stop(0.05) end)
                    end
                end
            end
        end)

        Helpers.enablePlayerControls()

        -- Instant Recovery on bump/hit/trap: field egg is dropped on stun/hit/trap!
        if Engine.State.WeAreCarrying then
            Engine.Velocity.setCarryingState(false, nil)
        end
        Engine.Velocity.setCarry(false)

        if Engine.Travel and Engine.Travel.stopWalking then
            Engine.Travel.stopWalking()
        end

        -- Immediately restore Humanoid WalkSpeed so player never gets stuck frozen at 0 speed!
        local targetSpeed = Engine.State.IsCarry and Engine.State.BaseCarrySpeed or Engine.State.BaseGoSpeed
        if Engine.State.VelocityEnabled then
            pcall(function() hum.WalkSpeed = targetSpeed end)
        else
            pcall(function() hum.WalkSpeed = math.max(Engine.State.SavedWalkSpeed or 16.0, 16.0) end)
        end

        -- Anti-Fling Braking & Bump Location Anchoring (from v10 & v11)
        if Config.Recovery.AntiFling and hrp and hrp.Parent then
            local lastGood = Engine.State.LastGoodCFrame
            if lastGood then
                local dist = (hrp.Position - lastGood.Position).Magnitude
                if dist > 2.0 and dist < 150.0 then
                    pcall(function()
                        hrp.CFrame = lastGood + Vector3.new(0, 0.2, 0)
                    end)
                end
            end

            local curVel = hrp.AssemblyLinearVelocity
            local fastY = 0
            if hum and hum.Parent and hum.FloorMaterial == Enum.Material.Air then
                fastY = (curVel.Y > -20) and -35 or curVel.Y
            end
            hrp.AssemblyLinearVelocity = Vector3.new(0, fastY, 0)
            hrp.AssemblyAngularVelocity = Vector3.zero
        end

        if Config.Recovery.BrakeVelocity and hrp and hrp.Parent then
            hrp.AssemblyAngularVelocity = Vector3.zero
        end

        Engine.Recovery.neutraliseCarriedEggMass(Character)
    end)

    Engine.State.IsRecovering = false
end

Engine.Recovery.installHooks = function()
    if typeof(hookmetamethod) ~= "function" or Engine.Recovery.HooksInstalled then return end
    Engine.Recovery.HooksInstalled = true
    pcall(function()
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if Config.Recovery.Enabled and not (checkcaller and checkcaller()) then
                if method == "GetAttribute" then
                    local attrName = ...
                    if attrName == "RagdollEndTime" or attrName == "RagdollTime" then
                        return 0
                    end
                end
            end
            return oldNamecall(self, ...)
        end))

        local oldNewIndex
        oldNewIndex = hookmetamethod(game, "__newindex", newcclosure(function(self, key, value)
            if Config.Recovery.Enabled and not (checkcaller and checkcaller()) and typeof(self) == "Instance" then
                if key == "Enabled" and self:IsA("Motor6D") and value == false then
                    if Config.Recovery.BodyJointNames[self.Name] then
                        if Character and self:IsDescendantOf(Character) then
                            return oldNewIndex(self, key, true)
                        end
                    end
                elseif key == "PlatformStand" and self:IsA("Humanoid") and value == true then
                    if Character and self:IsDescendantOf(Character) then
                        return oldNewIndex(self, key, false)
                    end
                elseif key == "WalkSpeed" and self:IsA("Humanoid") and value == 0 then
                    if Character and self:IsDescendantOf(Character) then
                        local spd = Engine.State.VelocityEnabled and (Engine.State.IsCarry and Engine.State.BaseCarrySpeed or Engine.State.BaseGoSpeed) or 16.0
                        return oldNewIndex(self, key, spd)
                    end
                end
            end
            return oldNewIndex(self, key, value)
        end))
    end)
end

Engine.Recovery.bindCharacter = function(char)
    for _, conn in ipairs(Engine.Recovery.Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Engine.Recovery.Connections)
    table.clear(Engine.Recovery.Joints)

    if not char then return end
    local hum = char:WaitForChild("Humanoid", 5)
    local hrp = char:WaitForChild("HumanoidRootPart", 5)
    if not (hum and hrp) then return end

    if hum.WalkSpeed >= 16.0 and not Engine.State.VelocityEnabled then
        Engine.State.SavedWalkSpeed = hum.WalkSpeed
    end

    local function registerMotor(obj)
        if obj:IsA("Motor6D") and Config.Recovery.BodyJointNames[obj.Name] then
            table.insert(Engine.Recovery.Joints, obj)
            local conn = obj:GetPropertyChangedSignal("Enabled"):Connect(function()
                if Config.Recovery.Enabled and not obj.Enabled then
                    obj.Enabled = true
                    Engine.Recovery.execute("JointLock")
                end
            end)
            table.insert(Engine.Recovery.Connections, conn)
        end
    end

    for _, d in ipairs(char:GetDescendants()) do registerMotor(d) end

    local stateConn = hum.StateChanged:Connect(function(_, newState)
        if not Config.Recovery.Enabled then return end
        if newState == Enum.HumanoidStateType.Ragdoll
            or newState == Enum.HumanoidStateType.FallingDown
            or newState == Enum.HumanoidStateType.Physics then
            Engine.Recovery.execute(newState.Name)
        end
    end)
    table.insert(Engine.Recovery.Connections, stateConn)

    local platConn = hum:GetPropertyChangedSignal("PlatformStand"):Connect(function()
        if Config.Recovery.Enabled and hum.PlatformStand then
            hum.PlatformStand = false
            Engine.Recovery.execute("PlatformStand")
        end
    end)
    table.insert(Engine.Recovery.Connections, platConn)

    local sitConn = hum:GetPropertyChangedSignal("Sit"):Connect(function()
        if Config.Recovery.Enabled and hum.Sit then
            hum.Sit = false
            Engine.Recovery.execute("Sit")
        end
    end)
    table.insert(Engine.Recovery.Connections, sitConn)

    if LocalPlayer then
        local attrConn1 = LocalPlayer:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
            if Config.Recovery.Enabled then
                local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
                if typeof(rEnd) == "number" and rEnd > 0 then
                    Engine.Recovery.execute("RagdollTimer")
                end
            end
        end)
        table.insert(Engine.Recovery.Connections, attrConn1)
    end

    local attrConn2 = char:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
        if Config.Recovery.Enabled then
            local rEnd = char:GetAttribute("RagdollEndTime")
            if typeof(rEnd) == "number" and rEnd > 0 then
                Engine.Recovery.execute("CharRagdollTimer")
            end
        end
    end)
    table.insert(Engine.Recovery.Connections, attrConn2)
end

-- 4.4 Trap Evade & Neutralization Engine
Engine.Traps = {
    ActiveTraps = {},
}

Engine.Traps.isTrapCandidate = function(inst)
    if not (inst and inst.Parent) then return false end
    local nm = inst.Name:lower()
    return inst.Name == "PlayerTrap" or nm:find("trap", 1, true)
end

Engine.Traps.register = function(child)
    if not (child and child.Parent) then return end
    if not Engine.Traps.isTrapCandidate(child) then return end
    if Engine.Traps.ActiveTraps[child] then return end

    local pos = nil
    if child:IsA("BasePart") then
        pos = child.Position
    elseif child:IsA("Model") then
        local okP, p = pcall(function() return child:GetPivot().Position end)
        pos = (okP and p and p.Magnitude > 1) and p or (child.PrimaryPart and child.PrimaryPart.Position or nil)
    end

    local hb = child:FindFirstChild("Hitbox")
    local origCF = (hb and hb:IsA("BasePart")) and hb.CFrame or nil

    local record = {
        Instance = child,
        Hitbox = hb,
        OrigHitboxCF = origCF,
        Position = pos,
        Neutralized = false,
        Connections = {},
    }
    Engine.Traps.ActiveTraps[child] = record

    if Config.TrapEvade.Enabled and Config.TrapEvade.NeutralizeHitbox then
        Engine.Traps.neutralize(child)
    end

    local cAdd = child.ChildAdded:Connect(function(sub)
        if sub:IsA("BasePart") then
            if not record.Position or record.Position.Magnitude <= 1 then
                record.Position = sub.Position
            end
            if sub.Name == "Hitbox" or sub.Name:lower():find("hitbox", 1, true) then
                record.Hitbox = sub
                if not record.OrigHitboxCF then record.OrigHitboxCF = sub.CFrame end
            end
            if Config.TrapEvade.Enabled and Config.TrapEvade.NeutralizeHitbox then
                Engine.Traps.neutralize(child)
            end
        end
    end)

    local cAnc = child.AncestryChanged:Connect(function(_, parent)
        if not parent or not child:IsDescendantOf(Workspace) then
            Engine.Traps.unregister(child)
        end
    end)

    record.Connections = { cAdd, cAnc }
end

Engine.Traps.unregister = function(child)
    local rec = Engine.Traps.ActiveTraps[child]
    if rec then
        if rec.Connections then
            for _, c in ipairs(rec.Connections) do
                pcall(function() c:Disconnect() end)
            end
        end
        Engine.Traps.ActiveTraps[child] = nil
    end
end

Engine.Traps.neutralize = function(child)
    if not (child and child.Parent) then return end
    local record = Engine.Traps.ActiveTraps[child]
    if record and record.Neutralized then return end
    pcall(function()
        local parts = {}
        if child:IsA("BasePart") then
            table.insert(parts, child)
        end
        for _, desc in ipairs(child:GetDescendants()) do
            if desc:IsA("BasePart") then
                table.insert(parts, desc)
            end
        end

        for _, p in ipairs(parts) do
            p.CanTouch = false
            p.CanCollide = false
            p.CanQuery = false
            local pName = p.Name:lower()
            if pName == "hitbox" or pName:find("hitbox", 1, true) or pName:find("trigger", 1, true) then
                local curCF = p.CFrame
                if curCF.Y > -100 then
                    if record and not record.OrigHitboxCF then
                        record.OrigHitboxCF = curCF
                    end
                    p.CFrame = CFrame.new(curCF.X, -500, curCF.Z)
                end
            end
        end
        if record then record.Neutralized = true end
    end)
end

Engine.Traps.restore = function(child)
    if not (child and child.Parent) then return end
    local record = Engine.Traps.ActiveTraps[child]
    pcall(function()
        local parts = {}
        if child:IsA("BasePart") then
            table.insert(parts, child)
        end
        for _, desc in ipairs(child:GetDescendants()) do
            if desc:IsA("BasePart") then
                table.insert(parts, desc)
            end
        end

        for _, p in ipairs(parts) do
            p.CanTouch = true
            p.CanCollide = true
            p.CanQuery = true
            local pName = p.Name:lower()
            if pName == "hitbox" or pName:find("hitbox", 1, true) or pName:find("trigger", 1, true) then
                if record and record.OrigHitboxCF then
                    p.CFrame = record.OrigHitboxCF
                end
            end
        end
        if record then record.Neutralized = false end
    end)
end

Engine.Traps.init = function()
    local function hookTransient(transient)
        if not transient then return end
        for _, c in ipairs(transient:GetChildren()) do
            if Engine.Traps.isTrapCandidate(c) then
                Engine.Traps.register(c)
            end
        end
        addConnection(transient.ChildAdded:Connect(function(c)
            if Engine.Traps.isTrapCandidate(c) then
                Engine.Traps.register(c)
            end
        end))
        addConnection(transient.ChildRemoved:Connect(function(c)
            Engine.Traps.unregister(c)
        end))
    end

    hookTransient(Workspace:FindFirstChild("Transient"))

    addConnection(Workspace.ChildAdded:Connect(function(c)
        if c.Name == "Transient" then
            hookTransient(c)
        end
    end))
end

-- 4.45 Decoupled Plot Discovery Engine
Engine.Plot = {
    CachedPlot      = nil,
    CachedPlotIndex = nil,
}

Engine.Plot.getPlot = function()
    if Engine.Plot.CachedPlot and Engine.Plot.CachedPlot.Parent then
        return Engine.Plot.CachedPlot, Engine.Plot.CachedPlotIndex
    end

    local plotsFolder = Workspace:FindFirstChild("Plots") or Workspace:FindFirstChild("Bases")
    if not plotsFolder then return nil, nil end

    local myName = LocalPlayer and LocalPlayer.Name or ""

    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local sign = plot:FindFirstChild("PlotSign")
        local pName = sign and sign:FindFirstChild("PlayerPlotSign")
        local frame = pName and pName:FindFirstChild("Frame")
        local label = frame and frame:FindFirstChild("PlayerName")
        if label and label:IsA("TextLabel") and label.Text == myName then
            local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
            Engine.Plot.CachedPlot = plot
            Engine.Plot.CachedPlotIndex = idx
            return plot, idx
        end
    end

    return nil, nil
end

-- 4.5 Auto Treadmill & Dismount Engine
Engine.Treadmill = {
    CachedModel    = nil,
    CachedPosition = nil,
}

Engine.Treadmill.findTreadmill = function()
    if Engine.Treadmill.CachedPosition and Engine.Treadmill.CachedModel and Engine.Treadmill.CachedModel.Parent then
        return Engine.Treadmill.CachedModel, Engine.Treadmill.CachedPosition
    end

    local plot, plotIdx = Engine.Plot.getPlot()
    local clientRenders = Workspace:FindFirstChild("__ClientTreadmillRenders")

    -- 1. Targeted TreadmillRender_<plotIdx> in __ClientTreadmillRenders
    if plotIdx and clientRenders then
        local target = clientRenders:FindFirstChild("TreadmillRender_" .. tostring(plotIdx))
        if target then
            local ok, piv = pcall(function() return target:GetPivot().Position end)
            if ok and piv then
                Engine.Treadmill.CachedModel = target
                Engine.Treadmill.CachedPosition = piv
                return target, piv
            end
        end
    end

    -- 2. Direct match inside own Plot model
    if plot then
        local tu = plot:FindFirstChild("TreadmillUpgrade")
        if tu then
            local ok, piv = pcall(function() return tu:GetPivot().Position end)
            if ok and piv then
                Engine.Treadmill.CachedModel = tu
                Engine.Treadmill.CachedPosition = piv
                return tu, piv
            end
        end
    end

    return nil, nil
end

Engine.Treadmill.isOnTreadmill = function()
    local lpAttr = LocalPlayer and LocalPlayer:GetAttribute("IsOnTreadmill")
    local chAttr = Character and Character:GetAttribute("IsOnTreadmill")
    if lpAttr == true or chAttr == true then
        return true
    end
    if hrp and Engine.Treadmill.CachedPosition then
        local flatDist = (Vector3.new(hrp.Position.X, 0, hrp.Position.Z) - Vector3.new(Engine.Treadmill.CachedPosition.X, 0, Engine.Treadmill.CachedPosition.Z)).Magnitude
        if flatDist <= 4.0 and hum and (hum:GetState() == Enum.HumanoidStateType.Running or hum.MoveDirection.Magnitude > 0.05) then
            return true
        end
    end
    return false
end

Engine.Treadmill.goToTreadmill = function()
    if Engine.Treadmill.isOnTreadmill() then return end

    local tmModel, tmPos = Engine.Treadmill.findTreadmill()
    if not tmPos then
        if UI.Elements.ActivityStatus then
            UI.Elements.ActivityStatus.Text = "Status: Treadmill not found"
            UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(255, 120, 120)
        end
        return
    end

    if UI.Elements.ActivityStatus then
        UI.Elements.ActivityStatus.Text = "Status: Moving to Treadmill..."
        UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(100, 200, 255)
    end

    Engine.Travel.walkToTarget(tmPos, 2.5, function()
        pcall(function()
            if hrp and hrp.Parent then hrp.AssemblyLinearVelocity = Vector3.zero end
            if hum and hum.Parent then hum:Move(Vector3.zero, false) end
        end)

        -- Fire ProximityPrompt on treadmill model if present
        if tmModel and typeof(fireproximityprompt) == "function" then
            local prompt = tmModel:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt then pcall(function() fireproximityprompt(prompt) end) end
        end

        -- Invoke Treadmill mount remotes
        local rfWear = Helpers.getNetRemote("RF/Treadmill/AskWearStill")
        if rfWear then
            pcall(function() rfWear:InvokeServer() end)
            if tmModel then pcall(function() rfWear:InvokeServer(tmModel) end) end
        end

        if UI.Elements.ActivityStatus then
            UI.Elements.ActivityStatus.Text = "Status: On Treadmill"
            UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(120, 240, 160)
        end
    end, "TREADMILL", 60.0, false)
end

Engine.Treadmill.dismount = function()
    -- Immediate jump to dismount character
    pcall(function()
        if hum and hum.Parent then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
            hum.Jump = true
        end
    end)
    task.delay(0.05, function()
        pcall(function()
            if hum and hum.Parent then
                hum.Jump = true
            end
        end)
    end)

    -- Invoke dismount remote
    local rfDoff = Helpers.getNetRemote("RF/Treadmill/AskDoff")
    if rfDoff then
        pcall(function() rfDoff:InvokeServer() end)
    end

    -- If Auto Treadmill was active, deactivate toggle so character does not re-walk back
    if Config.Treadmill and Config.Treadmill.Enabled then
        Config.Treadmill.Enabled = false
        if UI.Elements.ToggleTreadmillBtn then
            UI.Elements.ToggleTreadmillBtn.Text = "OFF"
            UI.Elements.ToggleTreadmillBtn.BackgroundColor3 = Config.UI.Theme.GrayOff
            UI.Elements.ToggleTreadmillBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
        end
    end

    if UI.Elements.ActivityStatus then
        UI.Elements.ActivityStatus.Text = "Status: Dismounted from Treadmill"
        UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(220, 220, 120)
    end
end

-- 4.55 Auto Butterfly Engine (Lean Push Architecture)
Engine.Butterfly = {
    EventActive = false,
}

Engine.Butterfly.equipNet = function()
    if Character and Character:FindFirstChild("Butterfly Net") then
        return true
    end
    local bp = LocalPlayer and LocalPlayer:FindFirstChild("Backpack")
    local net = bp and bp:FindFirstChild("Butterfly Net")
    if net and hum and hum.Parent then
        pcall(function() hum:EquipTool(net) end)
        return true
    end
    return false
end

Engine.Butterfly.goToEvent = function()
    if not Config.Butterfly.Enabled or not Engine.Butterfly.EventActive then return end

    local zone = Config.Butterfly.ZonePosition
    if UI.Elements.ActivityStatus then
        UI.Elements.ActivityStatus.Text = "Status: Moving to Butterfly Event..."
        UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(255, 180, 220)
    end

    Engine.Travel.walkToTarget(zone, 2.5, function()
        Engine.Butterfly.equipNet()
        pcall(function()
            if hrp and hrp.Parent then hrp.AssemblyLinearVelocity = Vector3.zero end
            if hum and hum.Parent then hum:Move(Vector3.zero, false) end
        end)
        if UI.Elements.ActivityStatus then
            UI.Elements.ActivityStatus.Text = "Status: At Butterfly Event"
            UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(255, 140, 240)
        end
    end, "BUTTERFLY", 60.0, false)
end

Engine.Butterfly.setEventActive = function(active)
    Engine.Butterfly.EventActive = active
    if active and Config.Butterfly.Enabled then
        task.spawn(Engine.Butterfly.goToEvent)
    end
end

Engine.Butterfly.init = function()
    local evAnnounce = Helpers.getNetRemote("RE/Butterflies/Announce")
    if evAnnounce and evAnnounce:IsA("RemoteEvent") then
        addConnection(evAnnounce.OnClientEvent:Connect(function()
            Engine.Butterfly.setEventActive(true)
        end))
    end

    local evEnded = Helpers.getNetRemote("RE/LiveEvents/Ended")
    if evEnded and evEnded:IsA("RemoteEvent") then
        addConnection(evEnded.OnClientEvent:Connect(function(eventData)
            local str = tostring(eventData)
            if typeof(eventData) == "table" then
                str = tostring(eventData.Name or eventData.Type or eventData.Id or "")
            end
            if str == "" or str:lower():find("butterfl", 1, true) then
                Engine.Butterfly.setEventActive(false)
            end
        end))
    end

    local bFolder = Workspace:FindFirstChild("Butterflies") or (Workspace:FindFirstChild("World") and Workspace.World:FindFirstChild("Butterflies"))
    if bFolder and #bFolder:GetChildren() > 0 then
        Engine.Butterfly.setEventActive(true)
    end
end

-- 4.6 Fast Pickup Engine
Engine.Pickup = {}

Engine.Pickup.carryEgg = function(uid, burstCount, onCarried)
    if not uid or uid == "" then return false end
    burstCount = burstCount or Config.Pickup.SpamBurstCount
    local rf = Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")
    if not rf then return false end

    local payload = { Uid = uid }
    task.spawn(function()
        for _ = 1, burstCount do
            if Engine.State.IsCarry then
                if onCarried then task.spawn(onCarried) end
                if Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
                    if Engine.Travel and Engine.Travel.startReturnTrip then
                        Engine.Travel.startReturnTrip()
                    end
                end
                return
            end
            local ok, res = pcall(function() return rf:InvokeServer(payload) end)
            if ok and res == true then
                Engine.Velocity.setCarry(true)
                Engine.State.CarryUid = uid
                if onCarried then task.spawn(onCarried) end
                if Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
                    if Engine.Travel and Engine.Travel.startReturnTrip then
                        Engine.Travel.startReturnTrip()
                    end
                end
                break
            end
            task.wait(0.04)
        end
    end)
    return true
end

Engine.Pickup.startAutoPickupSpam = function()
    if Engine.State.IsCarry then
        if Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
            if Engine.Travel and Engine.Travel.startReturnTrip then
                Engine.Travel.startReturnTrip()
            end
        end
        return
    end

    Engine.State.AutoPickupToken = Engine.State.AutoPickupToken + 1
    local myToken = Engine.State.AutoPickupToken

    task.spawn(function()
        local tStart = os.clock()
        while Engine.State.AutoPickupToken == myToken and Config.Pickup.Enabled and (os.clock() - tStart < Config.Pickup.BurstMaxDuration) do
            if Engine.State.IsCarry then
                if Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
                    if Engine.Travel and Engine.Travel.startReturnTrip then
                        Engine.Travel.startReturnTrip()
                    end
                end
                break
            end

            if not (hrp and hrp.Parent) then break end
            local charPos = hrp.Position

            -- 1. Trigger ProximityPrompt on SmartPromptPart
            local spp = Workspace:FindFirstChild("SmartPromptPart")
            if spp then
                for _, pr in ipairs(spp:GetDescendants()) do
                    if pr:IsA("ProximityPrompt") and Helpers.isCarryPrompt(pr) then
                        Helpers.triggerProximityPrompt(pr)
                        break
                    end
                end
            end

            -- 2. Target closest farmable egg within reach
            local bestEggUid, closestDist = nil, 999
            for uid, r in pairs(Engine.State.EggCacheByUid) do
                if Engine.Travel.isFarmableEgg(r) then
                    local pos = Engine.Travel.getEggPosition(r, uid)
                    if pos then
                        local d = (pos - charPos).Magnitude
                        if d < closestDist and d <= Config.Pickup.FastPickupMaxDist then
                            closestDist = d
                            bestEggUid = uid
                        end
                    end
                end
            end

            -- Also check AreaEggSlotsClient directly
            local slotsFolder = Workspace:FindFirstChild("AreaEggSlotsClient")
            if slotsFolder then
                for _, sl in ipairs(slotsFolder:GetChildren()) do
                    local pos = sl:IsA("BasePart") and sl.Position or (sl:IsA("Model") and sl:GetPivot().Position)
                    if pos then
                        local d = (pos - charPos).Magnitude
                        if d <= Config.Pickup.FastPickupMaxDist and d < closestDist then
                            closestDist = d
                            local u = sl:GetAttribute("Uid") or sl:GetAttribute("EggUid") or sl.Name
                            if u and u ~= "" then
                                bestEggUid = u
                            end
                            local pr = sl:FindFirstChildWhichIsA("ProximityPrompt", true)
                            if pr and Helpers.isCarryPrompt(pr) then
                                Helpers.triggerProximityPrompt(pr)
                            end
                        end
                    end
                end
            end

            if bestEggUid then
                Engine.Pickup.carryEgg(bestEggUid, 2, function()
                    if Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
                        if Engine.Travel and Engine.Travel.startReturnTrip then
                            Engine.Travel.startReturnTrip()
                        end
                    end
                end)
            end

            task.wait(0.04)
        end
    end)
end

Engine.Pickup.toggle = function(enabled)
    if enabled == nil then
        enabled = not (Config.Pickup and Config.Pickup.Enabled)
    end
    if Config.Pickup then
        Config.Pickup.Enabled = enabled
    end
    if enabled then
        -- Mutual exclusion: turn off Halloween Fast Pickup
        if Config.HwPickup then Config.HwPickup.Enabled = false end
    end
    if UI.syncPickupToggles then UI.syncPickupToggles() end
end

-- 4.6.1 Halloween Fast Pickup Engine
Engine.HwPickup = {}

Engine.HwPickup.toggle = function(enabled)
    if enabled == nil then
        enabled = not (Config.HwPickup and Config.HwPickup.Enabled)
    end
    if Config.HwPickup then
        Config.HwPickup.Enabled = enabled
    end
    if enabled then
        -- Mutual exclusion: turn off World 1 Fast Pickup
        if Config.Pickup then Config.Pickup.Enabled = false end
    else
        -- Turning OFF Halloween fast pickup turns back ON World 1 main fast pickup
        if Config.Pickup then Config.Pickup.Enabled = true end
    end
    if UI.syncPickupToggles then UI.syncPickupToggles() end
end

Engine.HwPickup.carryEgg = function(uid, burstCount)
    if not uid or uid == "" then return false end
    burstCount = burstCount or (Config.HwPickup and Config.HwPickup.SpamBurstCount) or 8
    local hwRf = Helpers.getNetRemote("RF/HalloweenDimension/AskCarryEgg")
    if not hwRf then return false end
    task.spawn(function()
        for _ = 1, burstCount do
            pcall(function() return hwRf:InvokeServer(uid) end)
            task.wait(0.04)
        end
    end)
    return true
end

Engine.HwPickup.startAutoPickupSpam = function()
    Engine.State.HwPickupToken = (Engine.State.HwPickupToken or 0) + 1
    local myToken = Engine.State.HwPickupToken

    task.spawn(function()
        local tStart = os.clock()
        local maxDur = (Config.HwPickup and Config.HwPickup.BurstMaxDuration) or 1.5
        local maxDist = (Config.HwPickup and Config.HwPickup.FastPickupMaxDist) or 45.0

        while Engine.State.HwPickupToken == myToken and (Config.HwPickup and Config.HwPickup.Enabled) and (os.clock() - tStart < maxDur) do
            if not (hrp and hrp.Parent) then break end
            local charPos = hrp.Position

            -- 1. Trigger ProximityPrompt on SmartPromptPart
            local spp = Workspace:FindFirstChild("SmartPromptPart")
            if spp then
                for _, pr in ipairs(spp:GetDescendants()) do
                    if pr:IsA("ProximityPrompt") and Helpers.isCarryPrompt(pr) then
                        Helpers.triggerProximityPrompt(pr)
                        break
                    end
                end
            end

            -- 2. Find Halloween egg candidates from HalloweenDimension.WorldEggs, Workspace.WorldEggs, or tagged
            local rawEggs = {}
            local seen = {}
            local hwDim = Workspace:FindFirstChild("HalloweenDimension")
            local wEggs = hwDim and hwDim:FindFirstChild("WorldEggs")
            if not wEggs then
                wEggs = Workspace:FindFirstChild("WorldEggs")
            end
            if wEggs then
                for _, egg in ipairs(wEggs:GetChildren()) do
                    if egg:IsA("Instance") and not seen[egg] then
                        seen[egg] = true
                        table.insert(rawEggs, egg)
                    end
                end
            end
            local tagged = CollectionService:GetTagged("HalloweenWorldEgg")
            if tagged then
                for _, egg in ipairs(tagged) do
                    if egg:IsA("Instance") and not seen[egg] then
                        seen[egg] = true
                        table.insert(rawEggs, egg)
                    end
                end
            end

            -- 3. Find closest farmable Halloween egg within reach
            local bestEgg, closestDist = nil, 999
            for _, egg in ipairs(rawEggs) do
                if egg.Parent and not egg.Name:lower():find("holder") and egg:GetAttribute("HalloweenEggCanPickUp") ~= false then
                    local pos = nil
                    local hitbox = egg:FindFirstChild("Hitbox")
                    if hitbox and hitbox:IsA("BasePart") then
                        pos = hitbox.Position
                    elseif egg.PrimaryPart then
                        pos = egg.PrimaryPart.Position
                    elseif egg:IsA("Model") then
                        local okP, p = pcall(function() return egg:GetPivot().Position end)
                        if okP and p then pos = p end
                    elseif egg:IsA("BasePart") then
                        pos = egg.Position
                    end

                    if pos then
                        local d = (pos - charPos).Magnitude
                        if d <= maxDist and d < closestDist then
                            closestDist = d
                            bestEgg = egg
                        end
                    end
                end
            end

            if bestEgg then
                -- Trigger model proximity prompt if present
                local pr = bestEgg:FindFirstChildWhichIsA("ProximityPrompt", true)
                if pr and Helpers.isCarryPrompt(pr) then
                    Helpers.triggerProximityPrompt(pr)
                end

                -- Dispatch Halloween remote RF/HalloweenDimension/AskCarryEgg
                local uid = bestEgg:GetAttribute("HalloweenEggUid") or bestEgg.Name
                if uid and uid ~= "" then
                    local hwRf = Helpers.getNetRemote("RF/HalloweenDimension/AskCarryEgg")
                    if hwRf then
                        task.spawn(function()
                            pcall(function() hwRf:InvokeServer(uid) end)
                        end)
                    end
                end

                -- Check if egg was picked up (server marked attribute false)
                if bestEgg:GetAttribute("HalloweenEggCanPickUp") == false then
                    if Engine.Velocity and Engine.Velocity.setCarry then
                        Engine.Velocity.setCarry(true)
                    end
                    break
                end
            end

            task.wait(0.04)
        end
    end)
end

-- 4.5 Auto-Travel, Navigation & SafeZone Return Engine
Engine.Travel = {}

Engine.Travel.getSafeZonePosition = function()
    return Config.Velocity.SafeZonePosition
end

Engine.Travel.stopWalking = function()
    Engine.State.ActiveWalkToken = Engine.State.ActiveWalkToken + 1
    Engine.State.ActiveWalkTarget = nil
    pcall(function()
        if hum and hum.Parent then
            hum:Move(Vector3.zero, false)
            if hrp and hrp.Parent then
                hum:MoveTo(hrp.Position)
            end
            if not Engine.State.VelocityEnabled then
                hum.WalkSpeed = math.max(Engine.State.SavedWalkSpeed or 16.0, 16.0)
            end
        end
        if hrp and hrp.Parent then
            hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
        end
    end)
end

-- Reusable Simple Teleport Logic (Admin Abuse TP, Reach Assist & 60-Stud Snap Teleport)
-- snapBeside: When true, teleports beside the egg at ground level facing it, eliminating excess freefall on large eggs
Engine.Travel.teleportTo = function(targetPos, snapBeside)
    if not (hrp and hrp.Parent and targetPos) then return false end
    local ok = pcall(function()
        local rot = hrp.CFrame - hrp.CFrame.Position
        local finalPos = targetPos

        if snapBeside then
            local diff = Vector3.new(hrp.Position.X - targetPos.X, 0, hrp.Position.Z - targetPos.Z)
            local dir = diff.Magnitude > 0.1 and diff.Unit or Vector3.new(0, 0, 1)
            local groundY = hrp.Position.Y
            if math.abs(groundY - targetPos.Y) > 8 then
                groundY = targetPos.Y
            end
            finalPos = Vector3.new(targetPos.X + dir.X * 3.2, groundY, targetPos.Z + dir.Z * 3.2)
            rot = CFrame.lookAt(finalPos, Vector3.new(targetPos.X, groundY, targetPos.Z)) - finalPos
        else
            local targetY = targetPos.Y
            if math.abs(hrp.Position.Y - targetPos.Y) <= 4 then
                targetY = hrp.Position.Y
            else
                targetY = targetPos.Y + 2.5
            end
            finalPos = Vector3.new(targetPos.X, targetY, targetPos.Z)
        end

        hrp.CFrame = CFrame.new(finalPos) * rot
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        Engine.State.LastGoodCFrame = hrp.CFrame
        if hum and hum.Parent then
            hum:Move(Vector3.zero, false)
            if hrp and hrp.Parent then
                hum:MoveTo(hrp.Position)
            end
        end
    end)
    return ok
end

Engine.Travel.walkToTarget = function(targetPos, arriveDist, onArrived, uid, snapDist, snapBeside)
    if not targetPos then return end
    arriveDist = arriveDist or 4.0
    snapDist = snapDist or Config.Velocity.TargetSnapDist or 60.0

    Engine.State.ActiveWalkToken = Engine.State.ActiveWalkToken + 1
    local myToken = Engine.State.ActiveWalkToken
    Engine.State.ActiveWalkTarget = targetPos

    task.spawn(function()
        while Engine.State.ActiveWalkToken == myToken do
            if not (hrp and hrp.Parent and hum and hum.Parent and hum.Health > 0) then break end
            if hrp.Position.Y < -400 then break end

            local currentPos = hrp.Position
            local flatDelta = Vector3.new(targetPos.X - currentPos.X, 0, targetPos.Z - currentPos.Z)
            local dist = flatDelta.Magnitude

            -- 60 studs teleport snap towards egg/location to stop and not overpass the target
            if dist <= snapDist or dist <= arriveDist then
                Engine.Travel.teleportTo(targetPos, snapBeside)
                Engine.Travel.stopWalking()
                if onArrived then task.spawn(onArrived) end
                break
            end

            -- Normal walk logic: Ensure walkspeed is valid when velocity speed is off
            if not Engine.State.VelocityEnabled and hum.WalkSpeed < 16.0 then
                hum.WalkSpeed = math.max(Engine.State.SavedWalkSpeed or 16.0, 16.0)
            end

            if flatDelta.Magnitude > 0.1 then
                hum:Move(flatDelta.Unit, false)
                hum:MoveTo(targetPos)
            end

            task.wait(0.03)
        end
    end)
end

Engine.Travel.teleportToEgg = function(itemData)
    if not itemData or not itemData.Position then return false end
    Engine.Travel.stopWalking()
    pcall(function()
        if hum and hum.Parent then
            hum:UnequipTools()
        end
    end)
    Engine.State.AutoReturnActive = true
    Engine.State.AutoReturnTargetUid = itemData.Uid
    Engine.State.ReturnTripInProgress = false

    local ok = Engine.Travel.teleportTo(itemData.Position, true)
    if ok and itemData.Uid then
        Engine.Pickup.carryEgg(itemData.Uid, 8, function()
            if Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
                Engine.Travel.startReturnTrip()
            end
        end)
        Engine.Pickup.startAutoPickupSpam()
    end
    return ok
end

Engine.Travel.walkToEgg = function(itemData)
    if not itemData then return end
    local targetPos = itemData.Position or (itemData.Record and Engine.Travel.getEggPosition(itemData.Record, itemData.Uid))
    if not targetPos then return end

    Engine.Travel.stopWalking()
    pcall(function()
        if hum and hum.Parent then
            hum:UnequipTools()
        end
    end)
    Engine.State.AutoReturnActive = true
    Engine.State.AutoReturnTargetUid = itemData.Uid
    Engine.State.ReturnTripInProgress = false

    if UI.Elements.ActivityStatus then
        UI.Elements.ActivityStatus.Text = "Status: Walking to Egg (" .. tostring(itemData.DisplayName or itemData.Uid) .. ")..."
        UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(240, 200, 80)
    end

    Engine.Travel.walkToTarget(targetPos, 4.0, function()
        if itemData.Uid then
            Engine.Pickup.carryEgg(itemData.Uid, 8, function()
                if Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
                    Engine.Travel.startReturnTrip()
                end
            end)
            Engine.Pickup.startAutoPickupSpam()
        end
    end, itemData.Uid, 60.0, true)
end

Engine.Travel.startReturnTrip = function()
    local safePos = Engine.Travel.getSafeZonePosition()
    if not safePos then return end
    if Engine.State.ReturnTripInProgress and Engine.State.ActiveWalkTarget == safePos then return end
    Engine.State.ReturnTripInProgress = true

    if UI.Elements.ActivityStatus then
        UI.Elements.ActivityStatus.Text = "Status: Returning to SafeZone with Egg..."
        UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(100, 240, 255)
    end

    Engine.Travel.walkToTarget(safePos, 6.0, function()
        pcall(function()
            if hrp and hrp.Parent then hrp.AssemblyLinearVelocity = Vector3.zero end
            if hum and hum.Parent then
                hum:UnequipTools()
                local resetSpeed = Engine.State.VelocityEnabled and Engine.State.BaseGoSpeed or math.max(Engine.State.SavedWalkSpeed or 16.0, 16.0)
                hum.WalkSpeed = resetSpeed
            end
        end)
        Engine.State.AutoReturnActive = false
        Engine.State.AutoReturnTargetUid = nil
        Engine.State.ReturnTripInProgress = false
        Engine.Velocity.setCarry(false)
        if UI.Elements.ActivityStatus then
            UI.Elements.ActivityStatus.Text = "Status: Arrived at SafeZone with Egg"
            UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(120, 240, 160)
        end
    end, "SAFE_ZONE", 60.0)
end

Engine.Travel.handleEggDropped = function(u, payload)
    Engine.Velocity.setCarry(false)
    if not Engine.State.AutoReturnActive then return end
    Engine.State.ReturnTripInProgress = false
    Engine.Travel.stopWalking()

    local dropPos = nil
    if payload and typeof(payload) == "table" and payload.BoundsCFrame then
        local cf = payload.BoundsCFrame
        if typeof(cf) == "CFrame" then dropPos = cf.Position
        elseif typeof(cf) == "Vector3" then dropPos = cf
        elseif typeof(cf) == "table" and cf.X and cf.Y and cf.Z then
            dropPos = Vector3.new(cf.X, cf.Y, cf.Z)
        end
    end

    if not dropPos and Engine.State.EggCacheByUid and Engine.State.EggCacheByUid[u] then
        dropPos = Engine.Travel.getEggPosition(Engine.State.EggCacheByUid[u], u)
    end

    if not dropPos then
        if hrp and hrp.Parent then dropPos = hrp.Position end
    end

    if not dropPos then return end

    if UI.Elements.ActivityStatus then
        UI.Elements.ActivityStatus.Text = "Status: Egg dropped! Re-picking egg..."
        UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(255, 140, 60)
    end

    Engine.Travel.walkToTarget(dropPos, 3.5, function()
        Engine.Pickup.carryEgg(u, 8)
        Engine.Pickup.startAutoPickupSpam()
    end, u, 60.0, true)
end

Engine.Travel.handleEggDelivered = function(uid)
    Engine.State.AutoReturnActive = false
    Engine.State.AutoReturnTargetUid = nil
    Engine.State.ReturnTripInProgress = false
    Engine.Velocity.setCarry(false)
    Engine.Travel.stopWalking()
    pcall(function()
        if hrp and hrp.Parent then hrp.AssemblyLinearVelocity = Vector3.zero end
        if hum and hum.Parent then
            hum:UnequipTools()
            local resetSpeed = Engine.State.VelocityEnabled and Engine.State.BaseGoSpeed or math.max(Engine.State.SavedWalkSpeed or 16.0, 16.0)
            hum.WalkSpeed = resetSpeed
        end
    end)
    if UI.Elements.ActivityStatus then
        UI.Elements.ActivityStatus.Text = "Status: Egg successfully delivered!"
        UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(120, 240, 160)
    end
end

Engine.Travel.getEggPosition = function(rec, uid)
    if not rec then return nil end
    local pos = nil
    if rec.BoundsCFrame then
        local cf = rec.BoundsCFrame
        if typeof(cf) == "CFrame" then
            pos = cf.Position
        elseif typeof(cf) == "Vector3" then
            pos = cf
        elseif typeof(cf) == "table" and cf.Position then
            pos = cf.Position
        elseif typeof(cf) == "table" and cf.X and cf.Y and cf.Z then
            pos = Vector3.new(cf.X, cf.Y, cf.Z)
        end
    end
    if not pos and rec.Position then
        pos = rec.Position
    end
    if pos and pos.Magnitude > 10 then
        return pos
    end

    local u = uid or (typeof(rec) == "table" and (rec.Uid or rec.EggUid))
    if u and u ~= "" then
        local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
        if slots then
            local sl = slots:FindFirstChild(u)
            if sl then
                if sl:IsA("BasePart") and sl.Position.Magnitude > 10 then
                    if typeof(rec) == "table" then rec.BoundsCFrame = sl.CFrame end
                    return sl.Position
                end
                if sl:IsA("Model") then
                    local p = sl.PrimaryPart and sl.PrimaryPart.Position
                    if p and p.Magnitude > 10 then
                        if typeof(rec) == "table" then rec.BoundsCFrame = sl.PrimaryPart.CFrame end
                        return p
                    end
                    local ok, piv = pcall(sl.GetPivot, sl)
                    if ok and piv and piv.Position.Magnitude > 10 then
                        if typeof(rec) == "table" then rec.BoundsCFrame = piv end
                        return piv.Position
                    end
                end
            end
        end
        local eggs = Workspace:FindFirstChild("Eggs")
        if eggs then
            local em = eggs:FindFirstChild(u)
            if em then
                if em:IsA("BasePart") and em.Position.Magnitude > 10 then
                    if typeof(rec) == "table" then rec.BoundsCFrame = em.CFrame end
                    return em.Position
                end
                if em:IsA("Model") then
                    local p = em.PrimaryPart and em.PrimaryPart.Position
                    if p and p.Magnitude > 10 then
                        if typeof(rec) == "table" then rec.BoundsCFrame = em.PrimaryPart.CFrame end
                        return p
                    end
                    local ok, piv = pcall(em.GetPivot, em)
                    if ok and piv and piv.Position.Magnitude > 10 then
                        if typeof(rec) == "table" then rec.BoundsCFrame = piv end
                        return piv.Position
                    end
                end
            end
        end
    end

    return nil
end

Engine.Travel.isFarmableEgg = function(r)
    if not r or typeof(r) ~= "table" then return false end
    local state = tostring(r.State or "Slot")
    if state ~= "Slot" and state ~= "Dropped" and state ~= "Ground" and state ~= "Active" and state ~= "Field" and state ~= "Nest" then
        if r.PreparedSourceName and r.PreparedSourceName ~= "" then
            -- Accepted
        else
            return false
        end
    end
    if state == "Claimed" then
        return false
    end
    if state == "Carried" then
        return false
    end
    if r.CarrierUserId and tostring(r.CarrierUserId) ~= myUidStr and state ~= "Dropped" then
        return false
    end
    return true
end

Engine.Travel.resolveEggFields = function(r, uid, charPos)
    local rawName = r.DisplayName or r.AssetCategory or r.PreparedSourceName or r.Name or "Egg"
    local rawArea = r.AreaId
    if rawArea == "Light Dark" then rawArea = "Light & Dark" end
    local serverRarity = r.RarityId or r.Rarity or (r.Attributes and r.Attributes.Rarity) or Engine.State.RarityByUid[uid]
    local pos = Engine.Travel.getEggPosition(r, uid)

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
        if rawName:lower() == "shark" and serverRarity == "Secret" then
            searchArea = "Titan Temple"
        end
    end

    local info = nil
    if rawName and not Helpers.isGenericEggName(rawName) then
        info = Helpers.getSpeciesInfo(r.DisplayName, searchArea)
            or Helpers.getSpeciesInfo(r.AssetCategory, searchArea)
            or Helpers.getSpeciesInfo(r.PreparedSourceName, searchArea)
            or Helpers.getSpeciesInfo(r.Name, searchArea)
            or Helpers.getSpeciesInfo(rawName, searchArea)
            or Helpers.getSpeciesInfo(rawName)
    end

    local disp = (info and info.DisplayName) or (not Helpers.isGenericEggName(rawName) and rawName) or nil
    local rarity = (serverRarity and serverRarity ~= "" and serverRarity ~= "Unknown") and serverRarity or ((info and info.Rarity) or "Unknown")

    -- Fallback: If name is unknown/generic but rarity & area are known, deduce from catalog
    local isGeneric = (not disp or disp == "" or Helpers.isGenericEggName(disp) or not info)
    if isGeneric and rarity and rarity ~= "Unknown" then
        if searchArea and Helpers.SpeciesInfoByBiome[searchArea] then
            for _, cand in pairs(Helpers.SpeciesInfoByBiome[searchArea]) do
                if cand.Rarity == rarity then
                    info = cand
                    disp = cand.DisplayName or cand.Name
                    break
                end
            end
        else
            -- Cross-biome resolution fallback for rare/unique rarities
            for bName, bTable in pairs(Helpers.SpeciesInfoByBiome) do
                for _, cand in pairs(bTable) do
                    if cand.Rarity == rarity then
                        info = cand
                        disp = cand.DisplayName or cand.Name
                        searchArea = bName
                        break
                    end
                end
                if info then break end
            end
        end
    end

    -- If still no display name, provide clean area label without polluting record
    if not disp or disp == "" or Helpers.isGenericEggName(disp) then
        if searchArea and searchArea ~= "Unknown" and searchArea ~= "" then
            disp = searchArea .. " Egg"
        else
            disp = "Egg"
        end
    end

    local rank = (info and info.Rank) or (Config.Taxonomy.RarityRank[rarity] or 1)
    local biome = (searchArea and searchArea ~= "" and searchArea ~= "Unknown") and searchArea or ((info and info.Biome) or "Unknown")
    local dist = (pos and charPos) and (pos - charPos).Magnitude or 99999
    return rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist
end

-- 4.6 Server Push Monitor & ESP Discovery
Engine.Sync = {}

Engine.Sync.clearAllEggs = function(reason)
    local preservedCarry = nil
    if Engine.State.IsCarry and Engine.State.CarryUid and Engine.State.EggCacheByUid[Engine.State.CarryUid] then
        preservedCarry = Engine.State.EggCacheByUid[Engine.State.CarryUid]
    end
    table.clear(Engine.State.EggCacheByUid)
    table.clear(Engine.State.RarityByUid)
    if preservedCarry and Engine.State.CarryUid then
        Engine.State.EggCacheByUid[Engine.State.CarryUid] = preservedCarry
    end
    Engine.State.ListDirty = true
    if UI.renderFarmableEggs then
        pcall(UI.renderFarmableEggs)
    end
    if UI.renderHalloweenEggs then
        pcall(UI.renderHalloweenEggs)
    end
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
        if payload.CarrierUserId and tostring(payload.CarrierUserId) == myUidStr and state == "Carried" then
            Engine.Velocity.setCarry(true)
            Engine.State.CarryUid = u
            if Engine.State.AutoReturnActive and not Engine.State.ReturnTripInProgress then
                Engine.Travel.startReturnTrip()
            end
        elseif (state == "Claimed" or state == "Dropped") and (Engine.State.CarryUid == u or (payload.CarrierUserId and tostring(payload.CarrierUserId) == myUidStr) or Engine.State.IsCarry) then
            Engine.Velocity.setCarry(false)
            Engine.State.CarryUid = nil
            if Engine.State.AutoReturnActive and (Engine.State.AutoReturnTargetUid == u or state == "Claimed" or not Engine.State.AutoReturnTargetUid) then
                if state == "Dropped" then
                    Engine.Travel.handleEggDropped(u, payload)
                elseif state == "Claimed" then
                    Engine.Travel.handleEggDelivered(u)
                end
            end
        elseif state == "Carried" and payload.CarrierUserId and tostring(payload.CarrierUserId) ~= myUidStr then
            if Engine.State.AutoReturnActive and Engine.State.AutoReturnTargetUid == u then
                Engine.Travel.stopWalking()
                Engine.State.AutoReturnActive = false
                Engine.State.AutoReturnTargetUid = nil
                Engine.State.ReturnTripInProgress = false
                if UI.Elements.ActivityStatus then
                    UI.Elements.ActivityStatus.Text = "Status: Target egg taken by another player"
                    UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
                end
            end
        elseif state == "Dropped" and Engine.State.AutoReturnActive and Engine.State.AutoReturnTargetUid == u then
            Engine.Travel.handleEggDropped(u, payload)
        elseif state == "Claimed" and Engine.State.AutoReturnActive and Engine.State.AutoReturnTargetUid == u then
            Engine.Travel.handleEggDelivered(u)
        end

        if state == "Claimed" then
            Engine.State.EggCacheByUid[u] = nil
        elseif Engine.State.EggCacheByUid[u] then
            Engine.State.EggCacheByUid[u].State = state
            if state == "Carried" then
                Engine.State.EggCacheByUid[u].CarrierUserId = payload.CarrierUserId
            else
                Engine.State.EggCacheByUid[u].CarrierUserId = nil
            end
            if payload.BoundsCFrame then
                Engine.State.EggCacheByUid[u].BoundsCFrame = payload.BoundsCFrame
                local cf = payload.BoundsCFrame
                if typeof(cf) == "CFrame" then Engine.State.EggCacheByUid[u].Position = cf.Position
                elseif typeof(cf) == "Vector3" then Engine.State.EggCacheByUid[u].Position = cf
                end
            end
        else
            Engine.State.EggCacheByUid[u] = payload
            if state ~= "Carried" then
                Engine.State.EggCacheByUid[u].CarrierUserId = nil
            end
            if payload.BoundsCFrame then
                local cf = payload.BoundsCFrame
                if typeof(cf) == "CFrame" then Engine.State.EggCacheByUid[u].Position = cf.Position
                elseif typeof(cf) == "Vector3" then Engine.State.EggCacheByUid[u].Position = cf
                end
            end
        end

        local rId = payload.RarityId or payload.Rarity or (payload.Attributes and payload.Attributes.Rarity)
        if rId and rId ~= "" and rId ~= "Unknown" then
            Engine.State.RarityByUid[u] = tostring(rId)
        end
        local rawName = payload.DisplayName or payload.AssetCategory or payload.Name
        if rawName and Helpers.registerDynamicSpecies then
            Helpers.registerDynamicSpecies(rawName, payload.AreaId, rId)
        end

        Engine.State.ListDirty = true
    end)

    -- Hook AreaEggSlotsClient for native 0ms local ESP events
    local slotsContainer = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slotsContainer then
        addConnection(slotsContainer.ChildAdded:Connect(function(child)
            local uid = child.Name
            if uid and uid ~= "" then
                local cf = nil
                if child:IsA("BasePart") then
                    cf = child.CFrame
                elseif child:IsA("Model") then
                    local ok, piv = pcall(function() return child:GetPivot() end)
                    if ok and piv and piv.Position.Magnitude > 10 then cf = piv end
                    if not cf and child.PrimaryPart then cf = child.PrimaryPart.CFrame end
                end

                local rawSrc = child:GetAttribute("PreparedSourceName")
                local species = nil
                if type(rawSrc) == "string" and rawSrc ~= "" then
                    local base = rawSrc:match("([^%.]+)$") or rawSrc
                    species = base:gsub("(%l)(%u)", "%1 %2")
                else
                    local attrSpecies = child:GetAttribute("DisplayName") or child:GetAttribute("Species") or child:GetAttribute("AssetCategory")
                    if attrSpecies then species = tostring(attrSpecies) end
                end

                if species and Helpers.isGenericEggName(species) then species = nil end

                local existing = Engine.State.EggCacheByUid[uid]
                if not existing then
                    existing = {
                        Uid = uid,
                        State = "Slot",
                        BoundsCFrame = cf,
                        Position = cf and cf.Position or nil,
                        PreparedSourceName = rawSrc,
                        DisplayName = species,
                        AssetCategory = species,
                    }
                    Engine.State.EggCacheByUid[uid] = existing
                else
                    if cf and cf.Position.Magnitude > 10 then
                        existing.BoundsCFrame = cf
                        existing.Position = cf.Position
                    end
                    if rawSrc and rawSrc ~= "" then existing.PreparedSourceName = rawSrc end
                    if species then
                        existing.DisplayName = species
                        existing.AssetCategory = species
                    end
                end
                Engine.State.ListDirty = true
            end
        end))

        addConnection(slotsContainer.ChildRemoved:Connect(function(child)
            local uid = child.Name
            if uid and uid ~= "" then
                local existing = Engine.State.EggCacheByUid[uid]
                -- Do NOT delete eggs that are currently dropped or being carried!
                if existing and (existing.State == "Dropped" or existing.State == "Carried" or (Engine.State.IsCarry and Engine.State.CarryUid == uid)) then
                    return
                end
                Engine.State.EggCacheByUid[uid] = nil
                Engine.State.RarityByUid[uid] = nil
                Engine.State.ListDirty = true
            end
        end))
    end

    connectRemote("RE/EggWorld/FieldEggBatchShifted", function(batch)
        Engine.Sync.clearAllEggs("BatchShifted")
        if typeof(batch) == "table" then
            for uid, data in pairs(batch) do
                Engine.State.EggCacheByUid[tostring(uid)] = data
            end
            Engine.State.ListDirty = true
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
            if typeof(payload.RareSpawns) == "table" then
                for k, v in pairs(payload.RareSpawns) do
                    if typeof(v) == "table" and v.EggUid and v.RarityId then
                        Engine.State.RarityByUid[tostring(v.EggUid)] = tostring(v.RarityId)
                    elseif typeof(k) == "string" and typeof(v) == "string" then
                        Engine.State.RarityByUid[k] = v
                    end
                end
            else
                for k, v in pairs(payload) do
                    if typeof(k) == "string" and typeof(v) == "string" then
                        Engine.State.RarityByUid[k] = v
                    end
                end
            end
            Engine.State.ListDirty = true
            Engine.Sync.syncEggSnapshot()
        end
    end)

    connectRemote("RE/EggWorld/FieldEggGone", function(uid)
        local u = tostring(uid or "")
        if u ~= "" then
            Engine.State.EggCacheByUid[u] = nil
            Engine.State.RarityByUid[u] = nil
            Engine.State.ListDirty = true
        end
    end)

    connectRemote("RE/EggWorld/OwnerDropped", function(payload)
        local u = typeof(payload) == "table" and tostring(payload.Uid or payload.EggUid or payload.uid or "") or tostring(payload or "")
        local isOurs = (typeof(payload) == "table" and payload.UserId and tostring(payload.UserId) == myUidStr) or (u ~= "" and u == Engine.State.CarryUid) or Engine.State.IsCarry
        if isOurs then
            Engine.Velocity.setCarry(false)
            Engine.State.CarryUid = nil
        end
    end)

    -- Drop Monitor: watches Workspace.ClientRenderedAssets if an active carried field egg is dropped
    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        addConnection(cra.ChildRemoved:Connect(function(child)
            if Engine.State.IsCarry then
                local expName = myUidStr .. "_" .. tostring(Engine.State.CarryUid or "")
                local prefix = myUidStr .. "_"
                if child.Name == expName or child.Name:sub(1, #prefix) == prefix then
                    task.defer(function()
                        if Engine.State.IsCarry then
                            Engine.Velocity.setCarry(false)
                        end
                    end)
                end
            end
        end))
    end
end

Engine.Sync.syncEggSnapshot = function()
    local rf = Helpers.getNetRemote("RF/EggWorld/AskFieldEggSnapshot") or Helpers.getNetRemote("RF/EggWorld/GetEggSnapshot")
    if not rf then return end
    local okSnap, res = pcall(function() return rf:InvokeServer() end)
    if okSnap and typeof(res) == "table" then
        if typeof(res.Records) == "table" then
            if typeof(res.RareSpawns) == "table" then
                for k, v in pairs(res.RareSpawns) do
                    if typeof(v) == "table" and v.EggUid and v.RarityId then
                        Engine.State.RarityByUid[tostring(v.EggUid)] = tostring(v.RarityId)
                    elseif typeof(k) == "string" and typeof(v) == "string" then
                        Engine.State.RarityByUid[k] = v
                    end
                end
            end
            local currentUids = {}
            for _, r in pairs(res.Records) do
                if typeof(r) == "table" then
                    local u = tostring(r.Uid or r.EggUid or "")
                    if u ~= "" then
                        currentUids[u] = true
                        Engine.State.EggCacheByUid[u] = r
                        local rId = r.RarityId or r.Rarity or (r.Attributes and r.Attributes.Rarity)
                        if rId and rId ~= "" and rId ~= "Unknown" then
                            Engine.State.RarityByUid[u] = tostring(rId)
                        end
                        local rawName = r.DisplayName or r.AssetCategory or r.Name
                        if rawName and Helpers.registerDynamicSpecies then
                            Helpers.registerDynamicSpecies(rawName, r.AreaId, rId)
                        end
                    end
                end
            end
            for u in pairs(Engine.State.EggCacheByUid) do
                if not currentUids[u] and (not Engine.State.IsCarry or u ~= Engine.State.CarryUid) then
                    Engine.State.EggCacheByUid[u] = nil
                    Engine.State.RarityByUid[u] = nil
                end
            end
            Engine.State.ListDirty = true
        elseif typeof(res) == "table" then
            local currentUids = {}
            for uid, egg in pairs(res) do
                local u = tostring(uid)
                currentUids[u] = true
                Engine.State.EggCacheByUid[u] = egg
            end
            for u in pairs(Engine.State.EggCacheByUid) do
                if not currentUids[u] and (not Engine.State.IsCarry or u ~= Engine.State.CarryUid) then
                    Engine.State.EggCacheByUid[u] = nil
                    Engine.State.RarityByUid[u] = nil
                end
            end
            Engine.State.ListDirty = true
        end
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
                local ok, piv = pcall(function() return child:GetPivot() end)
                if ok and piv and piv.Position.Magnitude > 10 then cf = piv end
                if not cf and child.PrimaryPart then cf = child.PrimaryPart.CFrame end
            end

            local rawSrc = child:GetAttribute("PreparedSourceName")
            local species = nil
            if type(rawSrc) == "string" and rawSrc ~= "" then
                local base = rawSrc:match("([^%.]+)$") or rawSrc
                species = base:gsub("(%l)(%u)", "%1 %2")
            else
                local attrSpecies = child:GetAttribute("DisplayName") or child:GetAttribute("Species") or child:GetAttribute("AssetCategory")
                if attrSpecies then
                    species = tostring(attrSpecies)
                else
                    for _, ch in ipairs(child:GetChildren()) do
                        local sInfo = Helpers.getSpeciesInfo(ch.Name)
                        if sInfo then
                            species = sInfo.DisplayName
                            break
                        end
                    end
                end
            end

            if species and Helpers.isGenericEggName(species) then
                species = nil
            end

            local existing = Engine.State.EggCacheByUid[uid]
            if not existing then
                existing = {
                    Uid = uid,
                    State = "Slot",
                    BoundsCFrame = cf,
                    Position = cf and cf.Position or nil,
                    PreparedSourceName = rawSrc,
                }
                if species then
                    existing.DisplayName = species
                    existing.AssetCategory = species
                end
                Engine.State.EggCacheByUid[uid] = existing
            else
                if cf and cf.Position.Magnitude > 10 then
                    existing.BoundsCFrame = cf
                    existing.Position = cf.Position
                end
                if rawSrc and rawSrc ~= "" then
                    existing.PreparedSourceName = rawSrc
                end
                if species then
                    existing.DisplayName = species
                    existing.AssetCategory = species
                end
            end
        end
    end
    Engine.State.ListDirty = true
    return true
end

-- 4.7 Loop Logic & Background Tasks
Engine.Loops = {}

Engine.Loops.start = function()
    -- Initialize Trap Evade supervisor
    if Engine.Traps and Engine.Traps.init then
        pcall(Engine.Traps.init)
    end

    -- Install zero-wait metamethod hooks if executor supports hookmetamethod
    if Engine.Recovery.installHooks then
        pcall(Engine.Recovery.installHooks)
    end

    -- Stepped Loop: No-Clip
    local lastNoclipRefresh = 0
    addConnection(RunService.Stepped:Connect(function()
        if not Engine.State.NoclipActive then return end
        local now = os.clock()
        local firstPart = Engine.State.NoclipParts[1]
        if #Engine.State.NoclipParts == 0 or not (firstPart and firstPart.Parent) or (now - lastNoclipRefresh > 2.0) then
            lastNoclipRefresh = now
            table.clear(Engine.State.NoclipParts)
            if Character then
                for _, p in ipairs(Character:GetDescendants()) do
                    if p:IsA("BasePart") and not p:FindFirstAncestorWhichIsA("Tool") then
                        table.insert(Engine.State.NoclipParts, p)
                    end
                end
            end
        end
        for i = 1, #Engine.State.NoclipParts do
            local p = Engine.State.NoclipParts[i]
            if p and p.Parent and p.CanCollide then
                p.CanCollide = false
            end
        end
    end))

    -- Heartbeat Loop: Velocity Physics & Instant Recovery Safety Net
    addConnection(RunService.Heartbeat:Connect(function()
        if not Engine.State.IsRecovering and hrp and hrp.Parent and hum and hum.Parent and hum.Health > 0 then
            Engine.State.LastGoodCFrame = hrp.CFrame
        end

        if Config.Recovery.Enabled and Engine.Recovery.execute then
            if hum and hum.Parent and hum.Health > 0 then
                local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
                if typeof(rEnd) == "number" and rEnd > 0 then
                    Engine.Recovery.execute("RagdollTimer")
                elseif hum.PlatformStand or hum.Sit then
                    Engine.Recovery.execute("PlatSit")
                elseif hum.WalkSpeed < 16.0 then
                    local s = hum:GetState()
                    if s == Enum.HumanoidStateType.Ragdoll or s == Enum.HumanoidStateType.FallingDown or s == Enum.HumanoidStateType.Physics then
                        Engine.Recovery.execute(s.Name)
                    end
                end
            end
        end

        Engine.Velocity.updatePhysics()
    end))

    -- Throttled 0.3s Loop: DOM Updates & Safety Fallback
    local lastFullRefresh = 0
    task.spawn(function()
        while not _G.EggGoToUI_Stop do
            task.wait(0.3)
            if UI.updateActivityStatus then
                pcall(UI.updateActivityStatus)
            end
            local now = os.clock()
            if Engine.State.ListDirty or (now - lastFullRefresh >= 1.0) then
                Engine.State.ListDirty = false
                lastFullRefresh = now
                if UI.renderFarmableEggs then
                    pcall(UI.renderFarmableEggs)
                end
                if UI.renderHalloweenEggs then
                    pcall(UI.renderHalloweenEggs)
                end
            end

            -- Instant Recovery Fallback
            if Config.Recovery.Enabled and Engine.Recovery.execute then
                if hum and hum.Parent and hum.Health > 0 and (hum.PlatformStand or hum.Sit) then
                    Engine.Recovery.execute("LoopFallback")
                end
            end

            -- Auto-Return Watchdog: If carrying an egg and AutoReturnActive is true, ensure return trip is running
            if Engine.State.AutoReturnActive and (Engine.State.IsCarry or Engine.State.WeAreCarrying) and not Engine.State.ReturnTripInProgress then
                if Engine.Travel and Engine.Travel.startReturnTrip then
                    Engine.Travel.startReturnTrip()
                end
            end
        end
    end)

    -- Immediate hydration & periodic 30s overworld safety snapshot sync
    task.spawn(function()
        pcall(Engine.Sync.syncAreaEggSlotsESP)
        pcall(Engine.Sync.syncEggSnapshot)
        if UI.renderFarmableEggs then pcall(UI.renderFarmableEggs) end
        if UI.renderHalloweenEggs then pcall(UI.renderHalloweenEggs) end

        task.wait(0.2)
        Engine.Sync.startPushMonitor()
        pcall(Engine.Butterfly.init)
        pcall(Engine.Sync.syncAreaEggSlotsESP)
        pcall(Engine.Sync.syncEggSnapshot)

        while not _G.EggGoToUI_Stop do
            task.wait(30.0)
            pcall(Engine.Sync.syncEggSnapshot)
        end
    end)
end

-- 4.8 Interaction Handlers & Full Cleanup
UI.updateActivityStatus = function()
    local lbl = UI.Elements.ActivityStatus
    if not lbl then return end
    if not Engine.State.VelocityEnabled then
        lbl.Text = "Status: Velocity Disabled (Normal WalkSpeed)"
        lbl.TextColor3 = Color3.fromRGB(160, 170, 190)
        return
    end
    if Engine.State.IsCarry then
        lbl.Text = string.format("Status: Carrying (%d studs/s)", Engine.State.BaseCarrySpeed)
        lbl.TextColor3 = Color3.fromRGB(255, 200, 80)
    else
        lbl.Text = string.format("Status: Velocity Active (%d studs/s)", Engine.State.BaseGoSpeed)
        lbl.TextColor3 = Color3.fromRGB(100, 220, 140)
    end
end

UI.renderFarmableEggs = function()
    local charPos = nil
    if hrp and hrp.Parent then
        charPos = hrp.Position
    end

    local farmableList = {}
    for uid, r in pairs(Engine.State.EggCacheByUid) do
        if Engine.Travel.isFarmableEgg(r) then
            local rawName, info, disp, serverRar, rarity, rank, biome, pos, dist = Engine.Travel.resolveEggFields(r, uid, charPos)

            -- Rarity filter
            local rarityAllowed = false
            if Engine.State.SelectedRarities["All"] == true then
                rarityAllowed = true
            elseif next(Engine.State.SelectedRarities) == nil then
                rarityAllowed = false
            elseif Engine.State.SelectedRarities[rarity] == true then
                rarityAllowed = true
            end

            -- Biome filter
            local biomeAllowed = false
            if Engine.State.SelectedBiomes["All"] == true then
                biomeAllowed = true
            elseif next(Engine.State.SelectedBiomes) == nil then
                biomeAllowed = false
            elseif Engine.State.SelectedBiomes[biome] == true then
                biomeAllowed = true
            elseif biome == "Light & Dark" and (Engine.State.SelectedBiomes["Angel Eggs"] or Engine.State.SelectedBiomes["Demon Eggs"]) then
                biomeAllowed = true
            elseif (biome == "Angel Eggs" or biome == "Demon Eggs") and Engine.State.SelectedBiomes["Light & Dark"] then
                biomeAllowed = true
            end
            if rarityAllowed and biomeAllowed then
                table.insert(farmableList, {
                    Uid         = uid,
                    DisplayName = disp,
                    Rarity      = rarity,
                    Rank        = rank,
                    Biome       = biome,
                    Position    = pos,
                    Distance    = dist,
                    State       = r.State or "Field",
                })
            end
        end
    end

    table.sort(farmableList, function(a, b)
        if a.Rank ~= b.Rank then return a.Rank > b.Rank end
        return (a.Distance or 99999) < (b.Distance or 99999)
    end)

    -- Update empty notice
    if UI.Elements.EmptyNotice then
        UI.Elements.EmptyNotice.Visible = (#farmableList == 0)
    end

    -- Update cards
    for idx, itemData in ipairs(farmableList) do
        local poolItem = UI.getOrCreateCard(idx)
        poolItem.data = itemData
        poolItem.titleLbl.Text = itemData.DisplayName
        poolItem.tagBiome.Text = itemData.Biome
        poolItem.tagRarity.Text = itemData.Rarity
        local col = Config.Taxonomy.RarityColors[itemData.Rarity] or Color3.fromRGB(200, 200, 200)
        poolItem.tagRarity.BackgroundColor3 = col
        poolItem.card.Visible = true
    end

    for idx = #farmableList + 1, #UI.CardPool do
        UI.CardPool[idx].card.Visible = false
    end

    if UI.Elements.EggListScroll then
        local totalH = #farmableList * (Config.UI.CardHeight + 4)
        UI.Elements.EggListScroll.CanvasSize = UDim2.new(0, 0, 0, totalH)
    end
end

UI.renderHalloweenEggs = function()
    local charPos = nil
    if hrp and hrp.Parent then
        charPos = hrp.Position
    end

    local rawEggs = {}
    local seen = {}

    local function addEgg(model)
        if model and model:IsA("Instance") and not seen[model] then
            seen[model] = true
            table.insert(rawEggs, model)
        end
    end

    local hwDim = Workspace:FindFirstChild("HalloweenDimension")
    local wEggs = hwDim and hwDim:FindFirstChild("WorldEggs")
    if not wEggs then
        wEggs = Workspace:FindFirstChild("WorldEggs")
    end
    if wEggs then
        for _, egg in ipairs(wEggs:GetChildren()) do
            addEgg(egg)
        end

        if Engine.State.HwHookedFolder ~= wEggs then
            if Engine.State.HwFolderConns then
                for _, c in ipairs(Engine.State.HwFolderConns) do pcall(function() c:Disconnect() end) end
                table.clear(Engine.State.HwFolderConns)
            else
                Engine.State.HwFolderConns = {}
            end
            Engine.State.HwHookedFolder = wEggs
            table.insert(Engine.State.HwFolderConns, wEggs.ChildAdded:Connect(function()
                Engine.State.ListDirty = true
                if UI.renderHalloweenEggs then pcall(UI.renderHalloweenEggs) end
            end))
            table.insert(Engine.State.HwFolderConns, wEggs.ChildRemoved:Connect(function()
                Engine.State.ListDirty = true
                if UI.renderHalloweenEggs then pcall(UI.renderHalloweenEggs) end
            end))
        end
    end

    local tagged = CollectionService:GetTagged("HalloweenWorldEgg")
    if tagged then
        for _, egg in ipairs(tagged) do
            addEgg(egg)
        end
    end

    local inHw = (LocalPlayer and LocalPlayer:GetAttribute("InHalloweenDimension") == true)
        or (hwDim ~= nil)
        or (#rawEggs > 0)

    local eggList = {}
    for _, model in ipairs(rawEggs) do
        if not model.Parent then continue end
        if model.Name:lower():find("holder") then continue end
        if model:GetAttribute("HalloweenEggCanPickUp") == false then continue end

        local pos = nil
        local hitbox = model:FindFirstChild("Hitbox")
        if hitbox and hitbox:IsA("BasePart") then
            pos = hitbox.Position
        elseif model.PrimaryPart then
            pos = model.PrimaryPart.Position
        elseif model:IsA("Model") then
            local okPivot, pv = pcall(function() return model:GetPivot().Position end)
            if okPivot and pv then pos = pv end
        elseif model:IsA("BasePart") then
            pos = model.Position
        end

        if pos then
            local eggName = Helpers.resolveHalloweenEggName(model)
            local sInfo = Helpers.getSpeciesInfo(eggName, "Halloween Dimension") or Helpers.getSpeciesInfo(eggName)

            local disp = (sInfo and sInfo.DisplayName) or eggName
            local rarity = (sInfo and sInfo.Rarity) or model:GetAttribute("Rarity") or (hitbox and hitbox:GetAttribute("Rarity")) or "Legendary"
            local rank = (sInfo and sInfo.Rank) or Config.Taxonomy.RarityRank[rarity] or 5
            local zone = model:GetAttribute("Zone")
            local zoneLabel = zone and ("Zone " .. tostring(zone)) or "Halloween"
            local uid = model:GetAttribute("HalloweenEggUid") or model.Name
            local dist = charPos and (pos - charPos).Magnitude or 99999

            -- Rarity filter for Halloween eggs
            local rarityAllowed = false
            local hwRar = Engine.State.SelectedHwRarities
            if not hwRar or hwRar["All"] == true then
                rarityAllowed = true
            elseif next(hwRar) == nil then
                rarityAllowed = false
            elseif hwRar[rarity] == true then
                rarityAllowed = true
            end

            if rarityAllowed then
                table.insert(eggList, {
                    Model       = model,
                    DisplayName = disp,
                    ZoneLabel   = zoneLabel,
                    Rarity      = rarity,
                    Rank        = rank,
                    Position    = pos,
                    Distance    = dist,
                    Uid         = uid,
                })
            end
        end
    end

    table.sort(eggList, function(a, b)
        if a.Rank ~= b.Rank then return a.Rank > b.Rank end
        return a.Distance < b.Distance
    end)

    if UI.Elements.HwEmptyNotice then
        UI.Elements.HwEmptyNotice.Visible = (#eggList == 0)
    end

    for idx, itemData in ipairs(eggList) do
        local poolItem = UI.getOrCreateHwCard(idx)
        poolItem.data = itemData
        poolItem.titleLbl.Text = itemData.DisplayName
        poolItem.tagZone.Text = itemData.ZoneLabel
        poolItem.tagRarity.Text = itemData.Rarity
        local col = Config.Taxonomy.RarityColors[itemData.Rarity] or Color3.fromRGB(200, 120, 50)
        poolItem.tagRarity.BackgroundColor3 = col
        poolItem.card.Visible = true
    end

    for idx = #eggList + 1, #UI.HwCardPool do
        UI.HwCardPool[idx].card.Visible = false
    end

    if UI.Elements.HwEggListScroll then
        local totalH = #eggList * (Config.UI.CardHeight + 4)
        UI.Elements.HwEggListScroll.CanvasSize = UDim2.new(0, 0, 0, totalH)
    end
end

Engine.Cleanup = function()
    _G.EggGoToUI_Stop = true
    Engine.State.VelocityEnabled = false
    Engine.Travel.stopWalking()
    disconnectAll()

    for _, conn in ipairs(Engine.Recovery.Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Engine.Recovery.Connections)

    if Engine.Traps then
        if Engine.Traps.ActiveTraps then
            for inst in pairs(Engine.Traps.ActiveTraps) do
                if inst.Parent then Engine.Traps.restore(inst) end
            end
            for _, rec in pairs(Engine.Traps.ActiveTraps) do
                if rec.Connections then
                    for _, c in ipairs(rec.Connections) do pcall(function() c:Disconnect() end) end
                end
            end
            table.clear(Engine.Traps.ActiveTraps)
        end
    end

    if Engine.Plot then
        Engine.Plot.CachedPlot = nil
        Engine.Plot.CachedPlotIndex = nil
    end

    if Config.Treadmill then
        Config.Treadmill.Enabled = false
    end
    if Engine.Treadmill then
        Engine.Treadmill.CachedModel = nil
        Engine.Treadmill.CachedPosition = nil
    end

    if Config.Butterfly then
        Config.Butterfly.Enabled = false
    end
    if Engine.Butterfly then
        Engine.Butterfly.EventActive = false
    end

    if Config.HwPickup then
        Config.HwPickup.Enabled = false
    end
    if Engine.State then
        Engine.State.HwPickupToken = (Engine.State.HwPickupToken or 0) + 1
    end

    pcall(function()
        if hum and hum.Parent then
            hum.WalkSpeed = Config.Velocity.DefaultWalkSpeed
            hum:Move(Vector3.zero, false)
        end
    end)

    table.clear(Engine.State.EggCacheByUid)
    table.clear(Engine.State.RarityByUid)
    table.clear(Engine.State.NoclipParts)
    table.clear(UI.CardPool)
    table.clear(UI.HwCardPool)

    if UI.Elements.ScreenGui and UI.Elements.ScreenGui.Parent then
        pcall(function() UI.Elements.ScreenGui:Destroy() end)
    end

    _G.EggGoToUI_Cleanup = nil
    print("[EggGoToUI v12] Full cleanup completed cleanly.")
end

-- ============================================================================
-- SECTION 5: INITIALIZATION & LIFECYCLE BOOTSTRAP
-- ============================================================================

-- Build UI elements
UI.build()
if UI.syncPickupToggles then UI.syncPickupToggles() end

-- Wire UI Handlers
local function switchTab(tabName)
    UI.closeCurrentDropdown()
    UI.ActiveTab = tabName
    UI.Elements.TabEggs.Visible = (tabName == "Eggs")
    UI.Elements.TabUtility.Visible = (tabName == "Utility")
    if UI.Elements.TabHalloween then
        UI.Elements.TabHalloween.Visible = (tabName == "Halloween")
    end
    UI.Elements.TabBtnEggs.BackgroundColor3 = (tabName == "Eggs") and Config.UI.Theme.TabActive or Config.UI.Theme.TabIdle
    UI.Elements.TabBtnEggs.TextColor3 = (tabName == "Eggs") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)
    UI.Elements.TabBtnUtility.BackgroundColor3 = (tabName == "Utility") and Config.UI.Theme.TabActive or Config.UI.Theme.TabIdle
    UI.Elements.TabBtnUtility.TextColor3 = (tabName == "Utility") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)
    if UI.Elements.TabBtnHalloween then
        UI.Elements.TabBtnHalloween.BackgroundColor3 = (tabName == "Halloween") and Config.UI.Theme.TabActive or Config.UI.Theme.TabIdle
        UI.Elements.TabBtnHalloween.TextColor3 = (tabName == "Halloween") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)
    end
    -- Refresh both egg and halloween egg at the same time, regardless of active panel
    if UI.renderFarmableEggs then pcall(UI.renderFarmableEggs) end
    if UI.renderHalloweenEggs then pcall(UI.renderHalloweenEggs) end
end

addConnection(UI.Elements.TabBtnEggs.MouseButton1Click:Connect(function() switchTab("Eggs") end))
addConnection(UI.Elements.TabBtnUtility.MouseButton1Click:Connect(function() switchTab("Utility") end))
if UI.Elements.TabBtnHalloween then
    addConnection(UI.Elements.TabBtnHalloween.MouseButton1Click:Connect(function() switchTab("Halloween") end))
end

addConnection(UI.Elements.MenuToggleBtn.MouseButton1Click:Connect(function()
    UI.closeCurrentDropdown()
    UI.Elements.MainFrame.Visible = not UI.Elements.MainFrame.Visible
end))

addConnection(UI.Elements.CloseBtn.MouseButton1Click:Connect(function()
    Engine.Cleanup()
end))

-- Velocity Toggle Button
addConnection(UI.Elements.VelToggleBtn.MouseButton1Click:Connect(function()
    Engine.State.VelocityEnabled = not Engine.State.VelocityEnabled
    local enabled = Engine.State.VelocityEnabled
    UI.Elements.VelToggleBtn.Text = enabled and "Velocity: ON" or "Velocity: OFF"
    UI.Elements.VelToggleBtn.BackgroundColor3 = enabled and Config.UI.Theme.GreenOn or Config.UI.Theme.GrayOff
    UI.Elements.VelToggleBtn.TextColor3 = enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    if not enabled then
        pcall(function()
            if hum and hum.Parent then hum.WalkSpeed = Config.Velocity.DefaultWalkSpeed end
        end)
    end
    UI.updateActivityStatus()
end))

-- Go / Carry Speed TextBoxes
addConnection(UI.Elements.GoBox.FocusLost:Connect(function()
    local val = tonumber(UI.Elements.GoBox.Text)
    if val and val > 0 then
        Engine.State.BaseGoSpeed = math.clamp(math.floor(val), Config.Velocity.MinSpeed, Config.Velocity.MaxSpeed)
    end
    UI.Elements.GoBox.Text = tostring(Engine.State.BaseGoSpeed)
    UI.updateActivityStatus()
end))

addConnection(UI.Elements.CarryBox.FocusLost:Connect(function()
    local val = tonumber(UI.Elements.CarryBox.Text)
    if val and val > 0 then
        Engine.State.BaseCarrySpeed = math.clamp(math.floor(val), Config.Velocity.MinSpeed, Config.Velocity.MaxSpeed)
    end
    UI.Elements.CarryBox.Text = tostring(Engine.State.BaseCarrySpeed)
    UI.updateActivityStatus()
end))

-- Fast Pickup Toggle Button
addConnection(UI.Elements.TogglePickupBtn.MouseButton1Click:Connect(function()
    Engine.Pickup.toggle()
end))

-- Halloween Fast Pickup Toggle Button (on Halloween Panel)
if UI.Elements.HwFilterPickupBtn then
    addConnection(UI.Elements.HwFilterPickupBtn.MouseButton1Click:Connect(function()
        Engine.HwPickup.toggle()
    end))
end

-- Instant Recovery Toggle Button
if UI.Elements.ToggleRecoveryBtn then
    addConnection(UI.Elements.ToggleRecoveryBtn.MouseButton1Click:Connect(function()
        Config.Recovery.Enabled = not Config.Recovery.Enabled
        local en = Config.Recovery.Enabled
        UI.Elements.ToggleRecoveryBtn.Text = en and "ON" or "OFF"
        UI.Elements.ToggleRecoveryBtn.BackgroundColor3 = en and Config.UI.Theme.GreenOn or Config.UI.Theme.GrayOff
        UI.Elements.ToggleRecoveryBtn.TextColor3 = en and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end))
end

-- No-Clip Toggle Button
addConnection(UI.Elements.ToggleNoclipBtn.MouseButton1Click:Connect(function()
    Engine.State.NoclipActive = not Engine.State.NoclipActive
    local en = Engine.State.NoclipActive
    UI.Elements.ToggleNoclipBtn.Text = en and "ON" or "OFF"
    UI.Elements.ToggleNoclipBtn.BackgroundColor3 = en and Config.UI.Theme.GreenOn or Config.UI.Theme.GrayOff
    UI.Elements.ToggleNoclipBtn.TextColor3 = en and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    if en then
        table.clear(Engine.State.NoclipParts)
        if Character then
            for _, p in ipairs(Character:GetDescendants()) do
                if p:IsA("BasePart") and not p:FindFirstAncestorWhichIsA("Tool") then
                    table.insert(Engine.State.NoclipParts, p)
                end
            end
        end
    else
        table.clear(Engine.State.NoclipParts)
        pcall(function()
            if hrp and hrp.Parent then hrp.CanCollide = true end
        end)
    end
end))

-- Trap Evade Toggle Button
if UI.Elements.ToggleTrapEvadeBtn then
    local function updateTrapBtn()
        local en = Config.TrapEvade.Enabled
        UI.Elements.ToggleTrapEvadeBtn.Text = en and "ON" or "OFF"
        UI.Elements.ToggleTrapEvadeBtn.BackgroundColor3 = en and Config.UI.Theme.GreenOn or Config.UI.Theme.GrayOff
        UI.Elements.ToggleTrapEvadeBtn.TextColor3 = en and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end

    addConnection(UI.Elements.ToggleTrapEvadeBtn.MouseButton1Click:Connect(function()
        Config.TrapEvade.Enabled = not Config.TrapEvade.Enabled
        updateTrapBtn()
        if Config.TrapEvade.Enabled then
            if Engine.Traps and Engine.Traps.ActiveTraps then
                for inst in pairs(Engine.Traps.ActiveTraps) do
                    if inst.Parent then Engine.Traps.neutralize(inst) end
                end
            end
        else
            if Engine.Traps and Engine.Traps.ActiveTraps then
                for inst in pairs(Engine.Traps.ActiveTraps) do
                    if inst.Parent then Engine.Traps.restore(inst) end
                end
            end
        end
    end))
end

-- Auto Treadmill Toggle Button
if UI.Elements.ToggleTreadmillBtn then
    local function updateTmBtn()
        local en = Config.Treadmill.Enabled
        UI.Elements.ToggleTreadmillBtn.Text = en and "ON" or "OFF"
        UI.Elements.ToggleTreadmillBtn.BackgroundColor3 = en and Config.UI.Theme.GreenOn or Config.UI.Theme.GrayOff
        UI.Elements.ToggleTreadmillBtn.TextColor3 = en and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end

    addConnection(UI.Elements.ToggleTreadmillBtn.MouseButton1Click:Connect(function()
        Config.Treadmill.Enabled = not Config.Treadmill.Enabled
        updateTmBtn()
        if Config.Treadmill.Enabled then
            task.spawn(Engine.Treadmill.goToTreadmill)
        else
            Engine.Travel.stopWalking()
        end
    end))
end

-- Auto Dismount Trigger Button (Direct jump & remote dismount)
if UI.Elements.TriggerDismountBtn then
    addConnection(UI.Elements.TriggerDismountBtn.MouseButton1Click:Connect(function()
        Engine.Treadmill.dismount()
    end))
end

-- Auto Butterfly Toggle Button
if UI.Elements.ToggleButterflyBtn then
    local function updateBfBtn()
        local en = Config.Butterfly.Enabled
        UI.Elements.ToggleButterflyBtn.Text = en and "ON" or "OFF"
        UI.Elements.ToggleButterflyBtn.BackgroundColor3 = en and Config.UI.Theme.GreenOn or Config.UI.Theme.GrayOff
        UI.Elements.ToggleButterflyBtn.TextColor3 = en and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end

    addConnection(UI.Elements.ToggleButterflyBtn.MouseButton1Click:Connect(function()
        Config.Butterfly.Enabled = not Config.Butterfly.Enabled
        updateBfBtn()
        if Config.Butterfly.Enabled and Engine.Butterfly.EventActive then
            task.spawn(Engine.Butterfly.goToEvent)
        end
    end))
end

-- Copy JSON Buttons
local function handleCopyJson(btn)
    if not btn then return end
    local okExport, count = Helpers.exportEggListJson()
    if okExport then
        btn.Text = "✓ Copied!"
        btn.TextColor3 = Color3.fromRGB(120, 255, 150)
        task.delay(1.5, function()
            if btn and btn.Parent then
                btn.Text = "Copy JSON"
                btn.TextColor3 = Color3.fromRGB(210, 230, 255)
            end
        end)
    else
        btn.Text = "Failed"
        btn.TextColor3 = Color3.fromRGB(255, 120, 120)
        task.delay(1.5, function()
            if btn and btn.Parent then
                btn.Text = "Copy JSON"
                btn.TextColor3 = Color3.fromRGB(210, 230, 255)
            end
        end)
    end
end

if UI.Elements.UtilityCopyJsonBtn then
    addConnection(UI.Elements.UtilityCopyJsonBtn.MouseButton1Click:Connect(function()
        handleCopyJson(UI.Elements.UtilityCopyJsonBtn)
    end))
end

-- Fast Pickup [E] Key Listener
addConnection(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.E then
        if Config.Pickup.Enabled then
            Engine.Pickup.startAutoPickupSpam()
        elseif Config.HwPickup and Config.HwPickup.Enabled then
            Engine.HwPickup.startAutoPickupSpam()
        end
    elseif input.KeyCode == Enum.KeyCode.Q then
        Engine.Travel.stopWalking()
        Engine.State.AutoReturnActive = false
        Engine.State.AutoReturnTargetUid = nil
        Engine.State.ReturnTripInProgress = false
        if UI.Elements.ActivityStatus then
            UI.Elements.ActivityStatus.Text = "Status: Walk cancelled [Q]"
            UI.Elements.ActivityStatus.TextColor3 = Color3.fromRGB(220, 220, 100)
        end
    end
end))

-- Outside Click Listener for Dropdowns (Zero-blocking, coordinate & inset safe)
local function isInsideGui(guiObj, pos)
    if not (guiObj and guiObj.Visible) then return false end
    local ok, a = pcall(function() return guiObj.AbsolutePosition end)
    local ok2, s = pcall(function() return guiObj.AbsoluteSize end)
    if not (ok and ok2 and a and s) then return false end
    if pos.X >= a.X and pos.X <= a.X + s.X and pos.Y >= a.Y and pos.Y <= a.Y + s.Y then
        return true
    end
    local ok3, inset = pcall(function() return GuiService:GetGuiInset() end)
    if ok3 and inset then
        local adjX = pos.X - inset.X
        local adjY = pos.Y - inset.Y
        if adjX >= a.X and adjX <= a.X + s.X and adjY >= a.Y and adjY <= a.Y + s.Y then
            return true
        end
    end
    return false
end

addConnection(UserInputService.InputBegan:Connect(function(input)
    if not UI.OpenDropdown then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local p = input.Position
    if not isInsideGui(UI.OpenDropdown.btn, p) and not isInsideGui(UI.OpenDropdown.list, p) then
        UI.closeCurrentDropdown()
    end
end))

-- Character Lifecycle Listeners & Void Death Resilience
local function clearCharRefs()
    Character = nil
    Humanoid = nil
    RootPart = nil
    hum = nil
    hrp = nil
    Engine.State.LastGoodCFrame = nil
end

local function bindLifecycle(newChar)
    Character = newChar
    local h = newChar:WaitForChild("Humanoid", 5)
    local r = newChar:WaitForChild("HumanoidRootPart", 5)
    Humanoid = h
    RootPart = r
    hum = h
    hrp = r

    if h then
        addConnection(h.Died:Connect(function()
            clearCharRefs()
            Engine.Velocity.setCarry(false)
            Engine.Travel.stopWalking()
        end))
    end
    if r then
        addConnection(r.AncestryChanged:Connect(function(_, parent)
            if not parent then
                -- Void destruction / part detached from Workspace
                RootPart = nil
                hrp = nil
                Engine.Velocity.setCarry(false)
                Engine.Travel.stopWalking()
            end
        end))
    end

    task.spawn(function()
        task.wait(0.2)
        Engine.Recovery.bindCharacter(newChar)
        Engine.Velocity.setCarry(false)
    end)
end

addConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
    bindLifecycle(newChar)
end))

addConnection(LocalPlayer.CharacterRemoving:Connect(function()
    clearCharRefs()
    Engine.Velocity.setCarry(false)
    Engine.Travel.stopWalking()
end))

if Character then
    bindLifecycle(Character)
end

-- Start Background Loops & Push Monitor
Engine.Loops.start()

-- Register Cleanup Hook
_G.EggGoToUI_Cleanup = Engine.Cleanup
print("[EggGoToUI v12] Grouped Modular Architecture loaded successfully.")

end) -- end pcall

if not ok then
    warn("[EggGoToUI v12] FAILED TO LOAD: " .. tostring(err))
end
