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

local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

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

local RARITY_ORDER = {
    "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine"
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
            { Name = "Mutant Shark", Rarity = "Secret", Aliases = { "Shark" } },
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
        Biome = "Halloween",
        EggNames = { "Halloween Egg", "Hooded Gerbil Egg", "Toadstool Egg", "Patchwork Imp Egg", "Halloween Dimension Egg", "Candy Corn Egg" },
        Species = {
            { Name = "Mummy Egg", Rarity = "Epic", Aliases = { "Mummy" } },
            { Name = "Ghost Fish Egg", Rarity = "Epic", Aliases = { "Ghost Fish" } },
            { Name = "Witch Pumpkin Egg", Rarity = "Legendary", Aliases = { "Witch Pumpkin" } },
            { Name = "Zombified Halloween Egg", Rarity = "Mythic", Aliases = { "Zombified Halloween" } },
            { Name = "Halloween Dimension Egg", Rarity = "Cosmic", Aliases = { "Halloween Dimension" } },
            { Name = "Halloween Boss Egg", Rarity = "Cosmic", Aliases = { "Halloween Boss" } },

            { Name = "Candy Corn Egg", Rarity = "Legendary", Aliases = { "Candy Corn" } },
            { Name = "Whiskers Egg", Rarity = "Epic", Aliases = { "Whiskers" } },
            { Name = "Jester Egg", Rarity = "Legendary", Aliases = { "Jester" } },
            { Name = "Jesterpop Egg", Rarity = "Legendary", Aliases = { "Jesterpop" } },
            { Name = "Candlefang Egg", Rarity = "Mythic", Aliases = { "Candlefang" } },
            { Name = "Spirit Knight Egg", Rarity = "Cosmic", Aliases = { "Spirit Knight", "SpiritKnight" } },
            { Name = "Witch Crow Egg", Rarity = "Cosmic", Aliases = { "Witch Crow" } },
            { Name = "Graveyard Brute Egg", Rarity = "Secret", Aliases = { "Graveyard Brute" } },
            { Name = "Ghost Reaper Egg", Rarity = "Eternal", Aliases = { "Ghost Reaper" } },

            { Name = "Hooded Gerbil Egg", Rarity = "Legendary", Aliases = { "Hooded Gerbil", "Halloween Egg", "Halloween" } },
            { Name = "Toadstool Egg", Rarity = "Mythic", Aliases = { "Toadstool", "Rotshroom", "Rotshroom Egg" } },
            { Name = "Patchwork Imp Egg", Rarity = "Cosmic", Aliases = { "Quilted Imp Egg", "Quilted Imp", "Patchwork Imp" } },
            { Name = "Haunted Scorpio Egg", Rarity = "Cosmic", Aliases = { "Haunted Scorpio" } },
            { Name = "BloodBloom Egg", Rarity = "Secret", Aliases = { "BloodBloom" } },
            { Name = "Shelltide Voyager Egg", Rarity = "Eternal", Aliases = { "Shelltide Voyager" } },

            { Name = "Halloween Royal Mimic Egg", Rarity = "Legendary", Aliases = { "Halloween Royal Mimic", "Royal Mimic" } },
            { Name = "Crowshade Egg", Rarity = "Mythic", Aliases = { "Crowshade" } },
            { Name = "Hexed Pumpkin Egg", Rarity = "Cosmic", Aliases = { "Hexed Pumpkin" } },
            { Name = "Werewolf Egg", Rarity = "Secret", Aliases = { "Werewolf" } },
            { Name = "Abomination Kong Egg", Rarity = "Eternal", Aliases = { "Abomination Kong" } },
            { Name = "Voidseer Pumpkin Egg", Rarity = "Divine", Aliases = { "Voidseer Pumpkin" } }
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
            -- Machine / Fusion / Laboratory Event
            { Name = "Biohazard Egg", Rarity = "Secret", Aliases = { "Biohazard" } },
            { Name = "Experiment Egg", Rarity = "Secret" },
            { Name = "LimitedExperimentEgg", Rarity = "Secret", Aliases = { "Limited Experiment Egg" } },
            { Name = "LimitedTimeExperimentPet", Rarity = "Secret" },
            { Name = "Pink Dragon Experiment", Rarity = "Eternal" },
            { Name = "Extinction Egg", Rarity = "Eternal", Aliases = { "Extinction" } },
            { Name = "Boss Egg", Rarity = "Cosmic" },
            { Name = "Crystal Egg", Rarity = "Rare" },
            { Name = "Depths Egg", Rarity = "Rare" },
            { Name = "Depths Reroll Egg", Rarity = "Mythic" },
            { Name = "Shattered Rift Egg", Rarity = "Cosmic" },
            { Name = "Riftborn Egg", Rarity = "Mythic" },
            { Name = "Riftbeasts Egg", Rarity = "Legendary" },
            { Name = "Shelltide Voyager Egg", Rarity = "Cosmic", Aliases = { "Shelltide Voyager" } },
            { Name = "Skeletal Egg", Rarity = "Rare", Aliases = { "Skeletal" } },
            { Name = "Unstable", Rarity = "Secret" },
            -- Scramble / Mecha / Meme Event Additions
            { Name = "Mecha Egg", Rarity = "Legendary" },
            { Name = "Mecha Scrambler", Rarity = "Cosmic" },
            { Name = "67", Rarity = "Rare" },
            { Name = "67 OP", Rarity = "Epic" },
            { Name = "Amethyst Runebear", Rarity = "Legendary" },
            { Name = "Amethyst Runebear OP", Rarity = "Mythic" },
            { Name = "Toxic Hedgehog OP", Rarity = "Legendary" },
            -- Mount / Race Rally Event
            { Name = "Race Bird", Rarity = "Uncommon" },
            { Name = "Race Cheetah", Rarity = "Rare" },
            { Name = "Race Lizard", Rarity = "Uncommon" },
            { Name = "Race Seahorse", Rarity = "Rare" },
            { Name = "Ostrich", Rarity = "Rare" },
            { Name = "Ostrich OP", Rarity = "Epic" },
            -- World / Special / Boss Additions
            { Name = "Mushroom Egg", Rarity = "Rare", Aliases = { "Mushroom" } },
            { Name = "Banjo Firefly", Rarity = "Rare" },
            { Name = "Engine Snail", Rarity = "Epic" },
            { Name = "Monster Egg", Rarity = "Mythic" },
            { Name = "Monstrous Egg", Rarity = "Secret" },
            { Name = "Ring Guard", Rarity = "Secret" },
            { Name = "Irihorus", Rarity = "Cosmic" },
            { Name = "Starry Wolf", Rarity = "Secret" },
            { Name = "World Spirit", Rarity = "Divine" },
            { Name = "Drill Monster", Rarity = "Cosmic" },
            { Name = "Demon Imp", Rarity = "Cosmic" },
        }
    }
}

-- Fast lookup indexes
local SPECIES_INFO = {}
local SPECIES_INFO_BY_BIOME = {}
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
    if not SPECIES_INFO_BY_BIOME[biomeData.Biome] then
        SPECIES_INFO_BY_BIOME[biomeData.Biome] = {}
    end
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
            IsCataloged = true,
        }
        if not SPECIES_INFO[canonicalNorm] then
            SPECIES_INFO[canonicalNorm] = record
        end
        SPECIES_INFO_BY_BIOME[biomeData.Biome][canonicalNorm] = record

        if spec.Aliases then
            for _, alias in ipairs(spec.Aliases) do
                local aliasNorm = normalizeSpecies(alias)
                if aliasNorm ~= "" then
                    SPECIES_INFO_BY_BIOME[biomeData.Biome][aliasNorm] = record
                    EGG_ALIASES[aliasNorm] = canonicalNorm
                end
            end
        end
    end
end

-- Species lookup and matching helpers
local function getSpeciesInfo(name, biomeFilter)
    local clean = normalizeSpecies(name)
    if clean == "" then return nil end
    if biomeFilter and SPECIES_INFO_BY_BIOME[biomeFilter] then
        local bRec = SPECIES_INFO_BY_BIOME[biomeFilter][clean]
        if bRec then return bRec end
    end
    if clean == "shark" and (biomeFilter == "Titan Temple" or biomeFilter == "Temple") then
        local bTable = SPECIES_INFO_BY_BIOME["Titan Temple"]
        if bTable and bTable["mutant shark"] then return bTable["mutant shark"] end
    end
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
do
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
end

-- Main Window Frame
local main = Instance.new("Frame")
main.Name = "MainFrame"
main.Size = UDim2.new(0, 380, 0, 520)
main.Position = UDim2.new(0.5, -190, 0.5, -260)
main.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
main.BorderSizePixel = 0
main.Parent = screenGui

local closeBtn = Instance.new("TextButton")

do
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
end

-- Sidebar Navigation Rail (Width: 46px)
local SIDEBAR_W = 46
local sidebar = Instance.new("Frame")
sidebar.Name = "Sidebar"
sidebar.Size = UDim2.new(0, SIDEBAR_W, 1, -36)
sidebar.Position = UDim2.new(0, 0, 0, 36)
sidebar.BackgroundColor3 = Color3.fromRGB(26, 32, 46)
sidebar.BorderSizePixel = 0
sidebar.Parent = main

do
    local sidebarDivider = Instance.new("Frame")
    sidebarDivider.Name = "SidebarDivider"
    sidebarDivider.Size = UDim2.new(0, 1, 1, 0)
    sidebarDivider.Position = UDim2.new(1, -1, 0, 0)
    sidebarDivider.BackgroundColor3 = Color3.fromRGB(50, 70, 105)
    sidebarDivider.BorderSizePixel = 0
    sidebarDivider.Parent = sidebar
end

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

-- Sidebar Button 2: Utility & Fast Pickup
local tabBtnUtility = Instance.new("TextButton")
tabBtnUtility.Name = "TabBtnUtility"
tabBtnUtility.Size = UDim2.new(0, 34, 0, 34)
tabBtnUtility.Position = UDim2.new(0.5, -17, 0, 52)
tabBtnUtility.BackgroundColor3 = Color3.fromRGB(35, 42, 60)
tabBtnUtility.Text = "⚡"
tabBtnUtility.TextColor3 = Color3.fromRGB(150, 170, 200)
tabBtnUtility.TextSize = 18
tabBtnUtility.Font = Enum.Font.GothamBold
tabBtnUtility.Parent = sidebar
Instance.new("UICorner", tabBtnUtility).CornerRadius = UDim.new(0, 6)

-- Sidebar Button 3: Halloween Dimension
local tabBtnHalloween = Instance.new("TextButton")
tabBtnHalloween.Name = "TabBtnHalloween"
tabBtnHalloween.Size = UDim2.new(0, 34, 0, 34)
tabBtnHalloween.Position = UDim2.new(0.5, -17, 0, 94)
tabBtnHalloween.BackgroundColor3 = Color3.fromRGB(35, 42, 60)
tabBtnHalloween.Text = "🎃"
tabBtnHalloween.TextColor3 = Color3.fromRGB(150, 170, 200)
tabBtnHalloween.TextSize = 18
tabBtnHalloween.Font = Enum.Font.GothamBold
tabBtnHalloween.Parent = sidebar
Instance.new("UICorner", tabBtnHalloween).CornerRadius = UDim.new(0, 6)

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

-- Panel 2: Utility Panel
local tabUtility = Instance.new("Frame")
tabUtility.Name = "TabUtility"
tabUtility.Size = UDim2.new(1, 0, 1, 0)
tabUtility.Position = UDim2.new(0, 0, 0, 0)
tabUtility.BackgroundTransparency = 1
tabUtility.BorderSizePixel = 0
tabUtility.ClipsDescendants = false
tabUtility.Visible = false
tabUtility.Parent = contentContainer

-- Panel 3: Halloween Panel (Isolated Module)
local tabHalloween = Instance.new("Frame")
tabHalloween.Name = "TabHalloween"
tabHalloween.Size = UDim2.new(1, 0, 1, 0)
tabHalloween.Position = UDim2.new(0, 0, 0, 0)
tabHalloween.BackgroundTransparency = 1
tabHalloween.BorderSizePixel = 0
tabHalloween.ClipsDescendants = false
tabHalloween.Visible = false
tabHalloween.Parent = contentContainer

local hwStatusLabel = nil
local hwEggListScroll
local hwEmptyNotice
local hwRarityBtn
local hwRarityDropList
local hwRarityDd
local selectedHwRarities = { ["All"] = true }
local renderHalloweenEggs
local hwAutoPickBtn
local hwAutoPickEnabled = false
local togglePickupBtn
local setHwAutoPick
local setUtilityAutoPick
local startHalloweenAutoPickup

-- Halloween Panel: Auto-Pickup, Rarity Filter & Live List Scrolling Container
do
    -- Auto Pick Toggle Bar (Above Rarity Filter)
    local hwAutoPickFrame = Instance.new("Frame")
    hwAutoPickFrame.Name = "HwAutoPickFrame"
    hwAutoPickFrame.Size = UDim2.new(1, -16, 0, 24)
    hwAutoPickFrame.Position = UDim2.new(0, 8, 0, 6)
    hwAutoPickFrame.BackgroundTransparency = 1
    hwAutoPickFrame.BorderSizePixel = 0
    hwAutoPickFrame.Parent = tabHalloween

    hwAutoPickBtn = Instance.new("TextButton")
    hwAutoPickBtn.Name = "HwAutoPickBtn"
    hwAutoPickBtn.Size = UDim2.new(1, 0, 1, 0)
    hwAutoPickBtn.Position = UDim2.new(0, 0, 0, 0)
    hwAutoPickBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
    hwAutoPickBtn.Text = "[OFF] Auto Pick [E]"
    hwAutoPickBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    hwAutoPickBtn.TextSize = 11
    hwAutoPickBtn.Font = Enum.Font.GothamBold
    hwAutoPickBtn.Parent = hwAutoPickFrame
    Instance.new("UICorner", hwAutoPickBtn).CornerRadius = UDim.new(0, 5)

    setHwAutoPick = function(enabled, syncOther)
        hwAutoPickEnabled = enabled
        if hwAutoPickBtn then
            hwAutoPickBtn.Text = hwAutoPickEnabled and "[ON] Auto Pick [E]" or "[OFF] Auto Pick [E]"
            hwAutoPickBtn.BackgroundColor3 = hwAutoPickEnabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(36, 44, 62)
            hwAutoPickBtn.TextColor3 = hwAutoPickEnabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
        end

        -- Reciprocal synchronization: if Halloween auto pick turns ON, utility turns OFF; if Halloween turns OFF, utility turns ON
        if syncOther ~= false and setUtilityAutoPick then
            setUtilityAutoPick(not hwAutoPickEnabled, false)
        end
    end

    hwAutoPickBtn.MouseButton1Click:Connect(function()
        setHwAutoPick(not hwAutoPickEnabled)
    end)

    -- Rarity Filter Bar (Only Rarity Dropdown - Positioned below Auto Pick)
    local hwFilterFrame = Instance.new("Frame")
    hwFilterFrame.Name = "HwFilterFrame"
    hwFilterFrame.Size = UDim2.new(1, -16, 0, 24)
    hwFilterFrame.Position = UDim2.new(0, 8, 0, 34)
    hwFilterFrame.BackgroundTransparency = 1
    hwFilterFrame.BorderSizePixel = 0
    hwFilterFrame.ClipsDescendants = false
    hwFilterFrame.ZIndex = 30
    hwFilterFrame.Parent = tabHalloween

    hwRarityBtn = Instance.new("TextButton")
    hwRarityBtn.Name = "HwRarityFilterBtn"
    hwRarityBtn.Size = UDim2.new(1, 0, 1, 0)
    hwRarityBtn.Position = UDim2.new(0, 0, 0, 0)
    hwRarityBtn.BackgroundColor3 = Color3.fromRGB(36, 44, 62)
    hwRarityBtn.Text = "Rarity: All ▼"
    hwRarityBtn.TextColor3 = Color3.fromRGB(220, 230, 255)
    hwRarityBtn.TextSize = 11
    hwRarityBtn.Font = Enum.Font.GothamBold
    hwRarityBtn.ZIndex = 31
    hwRarityBtn.Parent = hwFilterFrame
    Instance.new("UICorner", hwRarityBtn).CornerRadius = UDim.new(0, 5)

    -- Halloween Rarity Dropdown List
    hwRarityDropList = Instance.new("Frame")
    hwRarityDropList.Name = "HwRarityDropList"
    hwRarityDropList.Size = UDim2.new(1, 0, 0, 256)
    hwRarityDropList.Position = UDim2.new(0, 0, 0, 26)
    hwRarityDropList.BackgroundColor3 = Color3.fromRGB(24, 20, 34)
    hwRarityDropList.BorderSizePixel = 0
    hwRarityDropList.ZIndex = 50
    hwRarityDropList.ClipsDescendants = true
    hwRarityDropList.Visible = false
    hwRarityDropList.Parent = hwFilterFrame
    Instance.new("UICorner", hwRarityDropList).CornerRadius = UDim.new(0, 6)
    local hwRStroke = Instance.new("UIStroke", hwRarityDropList)
    hwRStroke.Color = Color3.fromRGB(90, 55, 120)
    hwRStroke.Thickness = 1

    local hwRarityQuickRow = Instance.new("Frame")
    hwRarityQuickRow.Size = UDim2.new(1, -6, 0, 22)
    hwRarityQuickRow.Position = UDim2.new(0, 3, 0, 3)
    hwRarityQuickRow.BackgroundTransparency = 1
    hwRarityQuickRow.ZIndex = 51
    hwRarityQuickRow.Parent = hwRarityDropList

    local hwRarityAllBtn = Instance.new("TextButton")
    hwRarityAllBtn.Size = UDim2.new(0.5, -2, 1, 0)
    hwRarityAllBtn.Position = UDim2.new(0, 0, 0, 0)
    hwRarityAllBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 150)
    hwRarityAllBtn.Text = "All"
    hwRarityAllBtn.TextColor3 = Color3.new(1, 1, 1)
    hwRarityAllBtn.TextSize = 11
    hwRarityAllBtn.Font = Enum.Font.GothamBold
    hwRarityAllBtn.ZIndex = 52
    hwRarityAllBtn.Parent = hwRarityQuickRow
    Instance.new("UICorner", hwRarityAllBtn).CornerRadius = UDim.new(0, 4)

    local hwRarityNoneBtn = Instance.new("TextButton")
    hwRarityNoneBtn.Size = UDim2.new(0.5, -2, 1, 0)
    hwRarityNoneBtn.Position = UDim2.new(0.5, 2, 0, 0)
    hwRarityNoneBtn.BackgroundColor3 = Color3.fromRGB(110, 45, 45)
    hwRarityNoneBtn.Text = "None"
    hwRarityNoneBtn.TextColor3 = Color3.new(1, 1, 1)
    hwRarityNoneBtn.TextSize = 11
    hwRarityNoneBtn.Font = Enum.Font.GothamBold
    hwRarityNoneBtn.ZIndex = 52
    hwRarityNoneBtn.Parent = hwRarityQuickRow
    Instance.new("UICorner", hwRarityNoneBtn).CornerRadius = UDim.new(0, 4)

    local hwRarityItemsContainer = Instance.new("Frame")
    hwRarityItemsContainer.Size = UDim2.new(1, -6, 1, -29)
    hwRarityItemsContainer.Position = UDim2.new(0, 3, 0, 27)
    hwRarityItemsContainer.BackgroundTransparency = 1
    hwRarityItemsContainer.ZIndex = 51
    hwRarityItemsContainer.Parent = hwRarityDropList

    local hwRLayout = Instance.new("UIListLayout")
    hwRLayout.Padding = UDim.new(0, 2)
    hwRLayout.SortOrder = Enum.SortOrder.LayoutOrder
    hwRLayout.Parent = hwRarityItemsContainer

    local hwRarityBtns = {}
    local refreshHwRarityButtons
    local updateHwRarityBtnText

    updateHwRarityBtnText = function(isOpen)
        local arrow = isOpen and "▲" or "▼"
        if selectedHwRarities["All"] then
            hwRarityBtn.Text = "Rarity: All " .. arrow
            return
        end
        local list = {}
        for _, r in ipairs(RARITY_ORDER) do
            if selectedHwRarities[r] then table.insert(list, r) end
        end
        if #list == 0 then
            hwRarityBtn.Text = "Rarity: None " .. arrow
        elseif #list == 1 then
            hwRarityBtn.Text = "Rarity: " .. list[1] .. " " .. arrow
        else
            hwRarityBtn.Text = string.format("Rarity: %s +%d %s", list[1], #list - 1, arrow)
        end
    end

    refreshHwRarityButtons = function()
        for _, r in ipairs(RARITY_ORDER) do
            local on = selectedHwRarities["All"] == true or selectedHwRarities[r] == true
            local b = hwRarityBtns[r]
            if b then
                b.BackgroundColor3 = on and Color3.fromRGB(48, 80, 125) or Color3.fromRGB(32, 28, 44)
                b.Text = (on and "[X] " or "[ ] ") .. r
            end
        end
    end

    for i, r in ipairs(RARITY_ORDER) do
        local b = Instance.new("TextButton")
        b.Name = "HwRarity_" .. r
        b.Size = UDim2.new(1, 0, 0, 20)
        b.LayoutOrder = i
        b.BackgroundColor3 = Color3.fromRGB(32, 28, 44)
        b.Text = "[X] " .. r
        b.TextColor3 = RARITY_COLORS[r] or Color3.fromRGB(220, 230, 255)
        b.TextSize = 11
        b.Font = Enum.Font.GothamBold
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.ZIndex = 52
        b.Parent = hwRarityItemsContainer
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 6)
        pad.Parent = b
        hwRarityBtns[r] = b

        b.MouseButton1Click:Connect(function()
            if selectedHwRarities["All"] then
                selectedHwRarities = {}
            end
            if selectedHwRarities[r] then
                selectedHwRarities[r] = nil
            else
                selectedHwRarities[r] = true
            end
            local totalChecked = 0
            for _, checkR in ipairs(RARITY_ORDER) do
                if selectedHwRarities[checkR] then totalChecked = totalChecked + 1 end
            end
            if totalChecked == #RARITY_ORDER then
                selectedHwRarities = { ["All"] = true }
            end
            updateHwRarityBtnText(true)
            refreshHwRarityButtons()
            if renderHalloweenEggs then pcall(renderHalloweenEggs) end
        end)
    end

    hwRarityAllBtn.MouseButton1Click:Connect(function()
        selectedHwRarities = { ["All"] = true }
        updateHwRarityBtnText(true)
        refreshHwRarityButtons()
        if renderHalloweenEggs then pcall(renderHalloweenEggs) end
    end)

    hwRarityNoneBtn.MouseButton1Click:Connect(function()
        selectedHwRarities = {}
        updateHwRarityBtnText(true)
        refreshHwRarityButtons()
        if renderHalloweenEggs then pcall(renderHalloweenEggs) end
    end)

    hwRarityDd = {
        btn = hwRarityBtn,
        list = hwRarityDropList,
        onOpen = function() refreshHwRarityButtons() end,
        updateBtnText = updateHwRarityBtnText,
    }

    -- Scrolling Frame for detected Halloween eggs (Directly below rarity filter)
    hwEggListScroll = Instance.new("ScrollingFrame")
    hwEggListScroll.Name = "HwEggListScroll"
    hwEggListScroll.Size = UDim2.new(1, -16, 1, -70)
    hwEggListScroll.Position = UDim2.new(0, 8, 0, 64)
    hwEggListScroll.BackgroundTransparency = 1
    hwEggListScroll.BorderSizePixel = 0
    hwEggListScroll.ScrollBarThickness = 4
    hwEggListScroll.ScrollBarImageColor3 = Color3.fromRGB(200, 95, 25)
    hwEggListScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    hwEggListScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    hwEggListScroll.ZIndex = 1
    hwEggListScroll.Parent = tabHalloween

    local hwListLayout = Instance.new("UIListLayout")
    hwListLayout.Padding = UDim.new(0, 3)
    hwListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    hwListLayout.Parent = hwEggListScroll

    local hwListPadding = Instance.new("UIPadding")
    hwListPadding.PaddingTop = UDim.new(0, 2)
    hwListPadding.PaddingBottom = UDim.new(0, 12)
    hwListPadding.PaddingLeft = UDim.new(0, 2)
    hwListPadding.PaddingRight = UDim.new(0, 6)
    hwListPadding.Parent = hwEggListScroll

    hwEmptyNotice = Instance.new("TextLabel")
    hwEmptyNotice.Name = "EmptyNotice"
    hwEmptyNotice.Size = UDim2.new(1, -20, 0, 80)
    hwEmptyNotice.Position = UDim2.new(0, 10, 0, 30)
    hwEmptyNotice.BackgroundTransparency = 1
    hwEmptyNotice.Text = "🎃 No Halloween eggs detected in current world.\nEnter the Halloween Portal to view eggs."
    hwEmptyNotice.TextColor3 = Color3.fromRGB(180, 165, 190)
    hwEmptyNotice.TextSize = 11.5
    hwEmptyNotice.Font = Enum.Font.Gotham
    hwEmptyNotice.TextWrapped = true
    hwEmptyNotice.Visible = true
    hwEmptyNotice.LayoutOrder = 1
    hwEmptyNotice.Parent = hwEggListScroll
end

-- Forward declarations
local renderFarmableEggs
local requestListUpdate
local updateActivityStatus
local activityStatusLabel
local velLiveLabel
local copyJsonBtn
local startReturnTrip
local handleEggDropped
local handleEggDelivered
local executePickupSpam
local startAutoPickupSpam

-- Auto-Return & Drop Recovery State
local autoReturnActive = false
local autoReturnTargetUid = nil
local returnTripInProgress = false

-- Fast Pickup Configuration & State
local PICKUP_CONFIG = {
    Enabled          = true,
    ReachAssist      = true,
    MaxReachDistance = 35,
    SpamBurstCount   = 8,
}
local autoPickupToken = 0

-- Instant Recovery Configuration
local RECOVERY_CONFIG = {
    Enabled   = true,
    AntiFling = true,
}

-- Velocity & Speed State (Default: Disabled)
local velocityEnabled = false
local weAreCarrying = false
local carryUid = nil
local baseGoSpeed = 330
local baseCarrySpeed = 280
local savedWalkSpeed = 16.0
pcall(function()
    local ch = LocalPlayer and LocalPlayer.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed > 0 then savedWalkSpeed = hum.WalkSpeed end
end)

-- Filter Selection State
local BIOME_ORDER = {
    "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean",
    "Prehistoric", "Cosmic", "Cherry Blossom", "Titan Temple", "Light & Dark", "Enchanted Forest", "Ungrouped"
}

local ALL_SPECIES_LIST = {}
local seenSpecies = {}

local function registerDynamicSpecies(rawName, defaultBiome, defaultRarity)
    if not rawName or type(rawName) ~= "string" or rawName == "" then return false end
    local clean = normalizeSpecies(rawName)
    if clean == "" then return false end

    local existing = SPECIES_INFO[clean]
    local disp = (existing and existing.DisplayName) or rawName
    local biome = (existing and existing.Biome) or defaultBiome
    if not biome or biome == "" or biome == "Unknown" then
        if clean:find("halloween") or clean:find("pumpkin") or clean:find("witch") or clean:find("ghost") then
            biome = "Halloween"
        else
            biome = "Ungrouped"
        end
    end
    local isCataloged = (existing and existing.IsCataloged == true)
    local rarity = (isCataloged and existing.Rarity) or defaultRarity or (biome == "Halloween" and "New Update" or "Common")
    local rank = (isCataloged and existing.Rank) or (RARITY_RANK[rarity] or (rarity == "New Update" and 99 or 1))

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
    end

    local cleanDisp = normalizeSpecies(disp)
    if not seenSpecies[cleanDisp] then
        seenSpecies[cleanDisp] = true
        table.insert(ALL_SPECIES_LIST, {
            Name      = disp,
            Biome     = biome,
            Rarity    = rarity,
            Rank      = rank,
            SearchKey = (disp .. " " .. biome .. " " .. rarity):lower(),
        })
        return true
    end
    return false
end

-- Pre-populate catalog species
do
    for _, biomeData in ipairs(BIOME_EGG_CATALOG) do
        for _, spec in ipairs(biomeData.Species) do
            local cleanDisp = normalizeSpecies(spec.Name)
            if not seenSpecies[cleanDisp] then
                seenSpecies[cleanDisp] = true
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
end

-- Dynamic Game Discovery for Egg Species (ReplicatedStorage.Assets.Models.Eggs)
do
    local eggsFolder = nil
    pcall(function()
        eggsFolder = ReplicatedStorage:FindFirstChild("Assets")
            and ReplicatedStorage.Assets:FindFirstChild("Models")
            and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
    end)
    if eggsFolder then
        local added = false
        for _, child in ipairs(eggsFolder:GetChildren()) do
            if registerDynamicSpecies(child.Name) then
                added = true
            end
        end
        if added then
            table.sort(ALL_SPECIES_LIST, function(a, b)
                return a.Name:lower() < b.Name:lower()
            end)
        end
    end
end
table.sort(ALL_SPECIES_LIST, function(a, b)
    return a.Name:lower() < b.Name:lower()
end)

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

-- 1. Activity / Carrying Status Readout (Above Velocity Engine)
activityStatusLabel = Instance.new("TextLabel")
activityStatusLabel.Name = "ActivityStatusLabel"
activityStatusLabel.Size = UDim2.new(1, -16, 0, 16)
activityStatusLabel.Position = UDim2.new(0, 8, 0, 4)
activityStatusLabel.BackgroundTransparency = 1
activityStatusLabel.Text = "Status: Not Carrying | Free Movement (330 studs/s)"
activityStatusLabel.TextColor3 = Color3.fromRGB(150, 185, 230)
activityStatusLabel.TextSize = 11
activityStatusLabel.Font = Enum.Font.GothamBold
activityStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
activityStatusLabel.Parent = tabEggs

-- 2. Velocity Engine Control Bar (Default: Disabled)
local velToggleBtn, goBox, carryBox

do
    local velocityFrame = Instance.new("Frame")
    velocityFrame.Name = "VelocityFrame"
    velocityFrame.Size = UDim2.new(1, -16, 0, 26)
    velocityFrame.Position = UDim2.new(0, 8, 0, 22)
    velocityFrame.BackgroundTransparency = 1
    velocityFrame.BorderSizePixel = 0
    velocityFrame.Parent = tabEggs

    velToggleBtn = Instance.new("TextButton")
    velToggleBtn.Name = "VelToggleBtn"
    velToggleBtn.Size = UDim2.new(0, 104, 1, 0)
    velToggleBtn.Position = UDim2.new(0, 0, 0, 0)
    velToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
    velToggleBtn.Text = "[OFF] Velocity"
    velToggleBtn.TextColor3 = Color3.fromRGB(210, 220, 240)
    velToggleBtn.TextSize = 11
    velToggleBtn.Font = Enum.Font.GothamBold
    velToggleBtn.Parent = velocityFrame
    Instance.new("UICorner", velToggleBtn).CornerRadius = UDim.new(0, 4)

    local goFrame = Instance.new("Frame")
    goFrame.Name = "GoSpeedFrame"
    goFrame.Size = UDim2.new(0, 70, 1, 0)
    goFrame.Position = UDim2.new(0, 108, 0, 0)
    goFrame.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
    goFrame.BorderSizePixel = 0
    goFrame.Parent = velocityFrame
    Instance.new("UICorner", goFrame).CornerRadius = UDim.new(0, 4)
    local goStroke = Instance.new("UIStroke", goFrame)
    goStroke.Color = Color3.fromRGB(50, 68, 98); goStroke.Thickness = 1

    local goLabel = Instance.new("TextLabel")
    goLabel.Size = UDim2.new(0, 20, 1, 0)
    goLabel.Position = UDim2.new(0, 4, 0, 0)
    goLabel.BackgroundTransparency = 1
    goLabel.Text = "Go:"
    goLabel.TextColor3 = Color3.fromRGB(160, 185, 220)
    goLabel.TextSize = 10.5
    goLabel.Font = Enum.Font.GothamBold
    goLabel.TextXAlignment = Enum.TextXAlignment.Left
    goLabel.Parent = goFrame

    goBox = Instance.new("TextBox")
    goBox.Name = "GoSpeedBox"
    goBox.Size = UDim2.new(1, -26, 1, 0)
    goBox.Position = UDim2.new(0, 24, 0, 0)
    goBox.BackgroundTransparency = 1
    goBox.Text = tostring(baseGoSpeed)
    goBox.PlaceholderText = "330"
    goBox.TextColor3 = Color3.new(1, 1, 1)
    goBox.TextSize = 11
    goBox.Font = Enum.Font.GothamBold
    goBox.ClearTextOnFocus = false
    goBox.TextXAlignment = Enum.TextXAlignment.Center
    goBox.Parent = goFrame

    local carryFrame = Instance.new("Frame")
    carryFrame.Name = "CarrySpeedFrame"
    carryFrame.Size = UDim2.new(0, 80, 1, 0)
    carryFrame.Position = UDim2.new(0, 182, 0, 0)
    carryFrame.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
    carryFrame.BorderSizePixel = 0
    carryFrame.Parent = velocityFrame
    Instance.new("UICorner", carryFrame).CornerRadius = UDim.new(0, 4)
    local carryStroke = Instance.new("UIStroke", carryFrame)
    carryStroke.Color = Color3.fromRGB(50, 68, 98); carryStroke.Thickness = 1

    local carryLabel = Instance.new("TextLabel")
    carryLabel.Size = UDim2.new(0, 32, 1, 0)
    carryLabel.Position = UDim2.new(0, 4, 0, 0)
    carryLabel.BackgroundTransparency = 1
    carryLabel.Text = "Carry:"
    carryLabel.TextColor3 = Color3.fromRGB(160, 185, 220)
    carryLabel.TextSize = 10.5
    carryLabel.Font = Enum.Font.GothamBold
    carryLabel.TextXAlignment = Enum.TextXAlignment.Left
    carryLabel.Parent = carryFrame

    carryBox = Instance.new("TextBox")
    carryBox.Name = "CarrySpeedBox"
    carryBox.Size = UDim2.new(1, -38, 1, 0)
    carryBox.Position = UDim2.new(0, 36, 0, 0)
    carryBox.BackgroundTransparency = 1
    carryBox.Text = tostring(baseCarrySpeed)
    carryBox.PlaceholderText = "280"
    carryBox.TextColor3 = Color3.new(1, 1, 1)
    carryBox.TextSize = 11
    carryBox.Font = Enum.Font.GothamBold
    carryBox.ClearTextOnFocus = false
    carryBox.TextXAlignment = Enum.TextXAlignment.Center
    carryBox.Parent = carryFrame

    velLiveLabel = Instance.new("TextLabel")
    velLiveLabel.Name = "VelLiveLabel"
    velLiveLabel.Size = UDim2.new(1, -266, 1, 0)
    velLiveLabel.Position = UDim2.new(0, 266, 0, 0)
    velLiveLabel.BackgroundColor3 = Color3.fromRGB(24, 29, 40)
    velLiveLabel.BorderSizePixel = 0
    velLiveLabel.Text = "Vel: OFF"
    velLiveLabel.TextColor3 = Color3.fromRGB(130, 140, 160)
    velLiveLabel.TextSize = 10
    velLiveLabel.Font = Enum.Font.GothamBold
    velLiveLabel.TextXAlignment = Enum.TextXAlignment.Center
    velLiveLabel.Parent = velocityFrame
    Instance.new("UICorner", velLiveLabel).CornerRadius = UDim.new(0, 4)

    -- 2b. Instant Recovery Control Bar (Row below Velocity Engine)
    local recoveryFrame = Instance.new("Frame")
    recoveryFrame.Name = "RecoveryFrame"
    recoveryFrame.Size = UDim2.new(1, -16, 0, 26)
    recoveryFrame.Position = UDim2.new(0, 8, 0, 52)
    recoveryFrame.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    recoveryFrame.BorderSizePixel = 0
    recoveryFrame.Parent = tabEggs
    Instance.new("UICorner", recoveryFrame).CornerRadius = UDim.new(0, 4)
    local strokeRecovery = Instance.new("UIStroke", recoveryFrame)
    strokeRecovery.Color = Color3.fromRGB(45, 55, 75)
    strokeRecovery.Thickness = 1

    local lblRecoveryTitle = Instance.new("TextLabel")
    lblRecoveryTitle.Name = "RecoveryTitle"
    lblRecoveryTitle.Size = UDim2.new(1, -74, 1, 0)
    lblRecoveryTitle.Position = UDim2.new(0, 10, 0, 0)
    lblRecoveryTitle.BackgroundTransparency = 1
    lblRecoveryTitle.Text = "Instant Recovery"
    lblRecoveryTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblRecoveryTitle.Font = Enum.Font.GothamBold
    lblRecoveryTitle.TextSize = 11.5
    lblRecoveryTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblRecoveryTitle.Parent = recoveryFrame

    local toggleRecoveryBtn = Instance.new("TextButton")
    toggleRecoveryBtn.Name = "ToggleRecoveryBtn"
    toggleRecoveryBtn.Size = UDim2.new(0, 56, 0, 20)
    toggleRecoveryBtn.Position = UDim2.new(1, -62, 0.5, -10)
    toggleRecoveryBtn.BackgroundColor3 = RECOVERY_CONFIG.Enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
    toggleRecoveryBtn.Text = RECOVERY_CONFIG.Enabled and "ON" or "OFF"
    toggleRecoveryBtn.TextColor3 = RECOVERY_CONFIG.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    toggleRecoveryBtn.Font = Enum.Font.GothamBold
    toggleRecoveryBtn.TextSize = 11
    toggleRecoveryBtn.Parent = recoveryFrame
    Instance.new("UICorner", toggleRecoveryBtn).CornerRadius = UDim.new(0, 4)

    addConnection(toggleRecoveryBtn.MouseButton1Click:Connect(function()
        RECOVERY_CONFIG.Enabled = not RECOVERY_CONFIG.Enabled
        toggleRecoveryBtn.Text = RECOVERY_CONFIG.Enabled and "ON" or "OFF"
        toggleRecoveryBtn.BackgroundColor3 = RECOVERY_CONFIG.Enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        toggleRecoveryBtn.TextColor3 = RECOVERY_CONFIG.Enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
    end))
end

-- 3. World Egg Catalog List View
local filterFrame = Instance.new("Frame")
local rarityBtn = Instance.new("TextButton")
local biomeBtn = Instance.new("TextButton")
local eggBtn = Instance.new("TextButton")

do
    local listHeader = Instance.new("Frame")
    listHeader.Name = "ListHeader"
    listHeader.Size = UDim2.new(1, -16, 0, 26)
    listHeader.Position = UDim2.new(0, 8, 0, 82)
    listHeader.BackgroundColor3 = Color3.fromRGB(26, 32, 46)
    listHeader.BorderSizePixel = 0
    listHeader.Parent = tabEggs
    Instance.new("UICorner", listHeader).CornerRadius = UDim.new(0, 6)

    local listHeaderTitle = Instance.new("TextLabel")
    listHeaderTitle.Name = "HeaderTitle"
    listHeaderTitle.Size = UDim2.new(1, -20, 1, 0)
    listHeaderTitle.Position = UDim2.new(0, 10, 0, 0)
    listHeaderTitle.BackgroundTransparency = 1
    listHeaderTitle.Text = "Farmable Eggs"
    listHeaderTitle.TextColor3 = Color3.fromRGB(220, 230, 255)
    listHeaderTitle.TextSize = 12
    listHeaderTitle.Font = Enum.Font.GothamBold
    listHeaderTitle.TextXAlignment = Enum.TextXAlignment.Left
    listHeaderTitle.Parent = listHeader

    -- 4. Dropdown Filter Bar
    filterFrame.Name = "FilterFrame"
    filterFrame.Size = UDim2.new(1, -16, 0, 58)
    filterFrame.Position = UDim2.new(0, 8, 0, 112)
    filterFrame.BackgroundTransparency = 1
    filterFrame.BorderSizePixel = 0
    filterFrame.ClipsDescendants = false
    filterFrame.ZIndex = 30
    filterFrame.Parent = tabEggs

    -- 1. Rarity Filter Button
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
end

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

local eggPool = {}
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
        if q == "" or (spec.SearchKey and spec.SearchKey:find(q, 1, true)) or (spec.Name and spec.Name:lower():find(q, 1, true)) then
            table.insert(matchedList, spec)
        end
    end

    for idx, spec in ipairs(matchedList) do
        local item = eggPool[idx]
        if not item then
            local btn = Instance.new("TextButton")
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
            sub.ZIndex = 53
            sub.Parent = btn

            item = {
                btn  = btn,
                sub  = sub,
                spec = nil,
            }

            btn.MouseButton1Click:Connect(function()
                local s = item.spec
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

            eggPool[idx] = item
        end

        item.spec = spec
        local isChecked = selectedEggs["All"] == true or selectedEggs[spec.Name] == true
        item.btn.BackgroundColor3 = isChecked and Color3.fromRGB(48, 75, 115) or Color3.fromRGB(30, 36, 50)
        item.btn.Text = (isChecked and "[X] " or "[ ] ") .. spec.Name
        local rarCol = (spec.Rarity and RARITY_COLORS[spec.Rarity]) or Color3.fromRGB(220, 230, 255)
        item.btn.TextColor3 = isChecked and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(200, 210, 225)
        item.btn.LayoutOrder = idx

        local bName = spec.Biome or "Unknown"
        local rName = spec.Rarity or "Unknown"
        item.sub.Text = bName .. " • " .. rName
        item.sub.TextColor3 = rarCol

        item.btn.Visible = true
    end

    for idx = #matchedList + 1, #eggPool do
        eggPool[idx].btn.Visible = false
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
if hwRarityBtn and hwRarityDd then
    hwRarityBtn.MouseButton1Click:Connect(function() toggleDropdown(hwRarityDd) end)
end

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
eggListScroll.Size = UDim2.new(1, -16, 1, -180)
eggListScroll.Position = UDim2.new(0, 8, 0, 174)
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
-- ============================================================================
-- TAB 2: UTILITY PANEL UI (Only Fast Pickup [E])
-- ============================================================================

do
    local rowPickup = Instance.new("Frame")
    rowPickup.Name = "RowPickup"
    rowPickup.Size = UDim2.new(1, -16, 0, 36)
    rowPickup.Position = UDim2.new(0, 8, 0, 10)
    rowPickup.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowPickup.BorderSizePixel = 0
    rowPickup.Parent = tabUtility
    Instance.new("UICorner", rowPickup).CornerRadius = UDim.new(0, 6)
    local strokePickup = Instance.new("UIStroke", rowPickup)
    strokePickup.Color = Color3.fromRGB(45, 55, 75)
    strokePickup.Thickness = 1

    local lblPickupTitle = Instance.new("TextLabel")
    lblPickupTitle.Size = UDim2.new(1, -80, 1, 0)
    lblPickupTitle.Position = UDim2.new(0, 12, 0, 0)
    lblPickupTitle.BackgroundTransparency = 1
    lblPickupTitle.Text = "Fast Pickup [E]"
    lblPickupTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblPickupTitle.Font = Enum.Font.GothamBold
    lblPickupTitle.TextSize = 12
    lblPickupTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblPickupTitle.Parent = rowPickup

    togglePickupBtn = Instance.new("TextButton")
    togglePickupBtn.Name = "TogglePickupBtn"
    togglePickupBtn.Size = UDim2.new(0, 56, 0, 24)
    togglePickupBtn.Position = UDim2.new(1, -66, 0.5, -12)
    togglePickupBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    togglePickupBtn.Text = "ON"
    togglePickupBtn.TextColor3 = Color3.new(1, 1, 1)
    togglePickupBtn.Font = Enum.Font.GothamBold
    togglePickupBtn.TextSize = 11
    togglePickupBtn.Parent = rowPickup
    Instance.new("UICorner", togglePickupBtn).CornerRadius = UDim.new(0, 5)

    setUtilityAutoPick = function(enabled, syncOther)
        if PICKUP_CONFIG then
            PICKUP_CONFIG.Enabled = enabled
            PICKUP_CONFIG.ReachAssist = enabled
        end
        if togglePickupBtn then
            togglePickupBtn.Text = enabled and "ON" or "OFF"
            togglePickupBtn.BackgroundColor3 = enabled and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
            togglePickupBtn.TextColor3 = enabled and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
        end
        if not enabled then
            autoPickupToken = (autoPickupToken or 0) + 1
        end

        -- Reciprocal synchronization: if utility turns ON, Halloween turns OFF; if utility turns OFF, Halloween turns ON
        if syncOther ~= false and setHwAutoPick then
            setHwAutoPick(not enabled, false)
        end
    end

    addConnection(togglePickupBtn.MouseButton1Click:Connect(function()
        setUtilityAutoPick(not (PICKUP_CONFIG and PICKUP_CONFIG.Enabled))
    end))

    local rowCopyJson = Instance.new("Frame")
    rowCopyJson.Name = "RowCopyJson"
    rowCopyJson.Size = UDim2.new(1, -16, 0, 36)
    rowCopyJson.Position = UDim2.new(0, 8, 0, 52)
    rowCopyJson.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowCopyJson.BorderSizePixel = 0
    rowCopyJson.Parent = tabUtility
    Instance.new("UICorner", rowCopyJson).CornerRadius = UDim.new(0, 6)
    local strokeCopyJson = Instance.new("UIStroke", rowCopyJson)
    strokeCopyJson.Color = Color3.fromRGB(45, 55, 75)
    strokeCopyJson.Thickness = 1

    local lblCopyTitle = Instance.new("TextLabel")
    lblCopyTitle.Size = UDim2.new(1, -100, 1, 0)
    lblCopyTitle.Position = UDim2.new(0, 12, 0, 0)
    lblCopyTitle.BackgroundTransparency = 1
    lblCopyTitle.Text = "Export Egg Data"
    lblCopyTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblCopyTitle.Font = Enum.Font.GothamBold
    lblCopyTitle.TextSize = 12
    lblCopyTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblCopyTitle.Parent = rowCopyJson

    copyJsonBtn = Instance.new("TextButton")
    copyJsonBtn.Name = "CopyJsonBtn"
    copyJsonBtn.Size = UDim2.new(0, 80, 0, 24)
    copyJsonBtn.Position = UDim2.new(1, -90, 0.5, -12)
    copyJsonBtn.BackgroundColor3 = Color3.fromRGB(45, 65, 100)
    copyJsonBtn.Text = "Copy JSON"
    copyJsonBtn.TextColor3 = Color3.fromRGB(210, 230, 255)
    copyJsonBtn.TextSize = 11
    copyJsonBtn.Font = Enum.Font.GothamBold
    copyJsonBtn.Parent = rowCopyJson
    Instance.new("UICorner", copyJsonBtn).CornerRadius = UDim.new(0, 5)

    -- Row 3: NoClip Toggle
    local rowNoclip = Instance.new("Frame")
    rowNoclip.Name = "RowNoclip"
    rowNoclip.Size = UDim2.new(1, -16, 0, 36)
    rowNoclip.Position = UDim2.new(0, 8, 0, 94)
    rowNoclip.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
    rowNoclip.BorderSizePixel = 0
    rowNoclip.Parent = tabUtility
    Instance.new("UICorner", rowNoclip).CornerRadius = UDim.new(0, 6)
    local strokeNoclip = Instance.new("UIStroke", rowNoclip)
    strokeNoclip.Color = Color3.fromRGB(45, 55, 75)
    strokeNoclip.Thickness = 1

    local lblNoclipTitle = Instance.new("TextLabel")
    lblNoclipTitle.Size = UDim2.new(1, -80, 1, 0)
    lblNoclipTitle.Position = UDim2.new(0, 12, 0, 0)
    lblNoclipTitle.BackgroundTransparency = 1
    lblNoclipTitle.Text = "NoClip"
    lblNoclipTitle.TextColor3 = Color3.fromRGB(225, 235, 255)
    lblNoclipTitle.Font = Enum.Font.GothamBold
    lblNoclipTitle.TextSize = 12
    lblNoclipTitle.TextXAlignment = Enum.TextXAlignment.Left
    lblNoclipTitle.Parent = rowNoclip

    local toggleNoclipBtn = Instance.new("TextButton")
    toggleNoclipBtn.Name = "ToggleNoclipBtn"
    toggleNoclipBtn.Size = UDim2.new(0, 56, 0, 24)
    toggleNoclipBtn.Position = UDim2.new(1, -66, 0.5, -12)
    toggleNoclipBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
    toggleNoclipBtn.Text = "OFF"
    toggleNoclipBtn.TextColor3 = Color3.fromRGB(180, 190, 210)
    toggleNoclipBtn.Font = Enum.Font.GothamBold
    toggleNoclipBtn.TextSize = 11
    toggleNoclipBtn.Parent = rowNoclip
    Instance.new("UICorner", toggleNoclipBtn).CornerRadius = UDim.new(0, 5)

    local noclipActive = false

    local function setNoclip(enabled)
        noclipActive = enabled
        toggleNoclipBtn.Text = noclipActive and "ON" or "OFF"
        toggleNoclipBtn.BackgroundColor3 = noclipActive and Color3.fromRGB(35, 135, 75) or Color3.fromRGB(45, 50, 65)
        toggleNoclipBtn.TextColor3 = noclipActive and Color3.new(1, 1, 1) or Color3.fromRGB(180, 190, 210)
        if not noclipActive then
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                if ch and ch:FindFirstChild("HumanoidRootPart") then
                    ch.HumanoidRootPart.CanCollide = true
                end
            end)
        end
    end

    addConnection(toggleNoclipBtn.MouseButton1Click:Connect(function()
        setNoclip(not noclipActive)
    end))

    addConnection(RunService.Stepped:Connect(function()
        if not noclipActive then return end
        local ch = LocalPlayer and LocalPlayer.Character
        if not ch then return end
        for _, part in ipairs(ch:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
            end
        end
    end))
end

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

local function getEggPosition(r, uid)
    if typeof(r) == "table" then
        local cf = r.BoundsCFrame or r.BottomCFrame or r.Position
        if typeof(cf) == "CFrame" then return cf.Position end
        if typeof(cf) == "Vector3" then return cf end
        if typeof(cf) == "table" and cf.X and cf.Y and cf.Z then
            return Vector3.new(cf.X, cf.Y, cf.Z)
        end
    end
    local u = uid or (typeof(r) == "table" and (r.Uid or r.EggUid))
    if u and u ~= "" then
        local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
        if slots then
            local sl = slots:FindFirstChild(u)
            if sl then
                if sl:IsA("BasePart") then return sl.Position end
                if sl:IsA("Model") then return sl:GetPivot().Position end
            end
        end
        local eggs = Workspace:FindFirstChild("Eggs")
        if eggs then
            local em = eggs:FindFirstChild(u)
            if em then
                if em:IsA("BasePart") then return em.Position end
                if em:IsA("Model") then return em:GetPivot().Position end
            end
        end
    end
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
    local rawArea = r.AreaId
    if rawArea == "Light Dark" then rawArea = "Light & Dark" end
    local serverRarity = r.RarityId or r.Rarity or (r.Attributes and r.Attributes.Rarity) or rarityByUid[uid]

    local searchArea = rawArea
    if not searchArea or searchArea == "" or searchArea == "Unknown" then
        if rawName:lower() == "shark" and serverRarity == "Secret" then
            searchArea = "Titan Temple"
        end
    end

    local info = getSpeciesInfo(r.DisplayName, searchArea)
        or getSpeciesInfo(r.AssetCategory, searchArea)
        or getSpeciesInfo(r.Name, searchArea)
        or getSpeciesInfo(rawName, searchArea)
        or getSpeciesInfo(rawName)

    local disp = (info and info.DisplayName) or r.DisplayName or r.AssetCategory or rawName
    local rarity = (serverRarity and serverRarity ~= "" and serverRarity ~= "Unknown") and serverRarity or ((info and info.Rarity) or "Unknown")
    local rank = (info and info.Rank) or (RARITY_RANK[rarity] or 1)
    local biome = (searchArea and searchArea ~= "" and searchArea ~= "Unknown") and searchArea or ((info and info.Biome) or "Unknown")
    local pos = getEggPosition(r, uid)
    local dist = (pos and charPos) and (pos - charPos).Magnitude or nil
    return rawName, info, disp, serverRarity, rarity, rank, biome, pos, dist
end

-- ============================================================================
-- VELOCITY & CARRY ENGINE (Instant 0ms Physics & Dual-Speed State Machine)
-- ============================================================================

local function isHoldingEgg()
    local char = LocalPlayer and LocalPlayer.Character
    if char then
        -- 1. Equipped egg Tool in hand (NOT Model: player pets and accessories are Models)
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") and c.Name:lower():find("egg", 1, true) then
                return true, c.Name
            end
            local okAttr, isEgg = pcall(function() return c:GetAttribute("IsEgg") end)
            if okAttr and isEgg == true then
                return true, c.Name
            end
        end
    end

    -- 2. ClientRenderedAssets & Server Snapshot: ONLY match if a specific carryUid is active!
    -- (NEVER match arbitrary CRA models without carryUid, as nest eggs in player's base also live in CRA!)
    if carryUid then
        local myUidStr = tostring(LocalPlayer and LocalPlayer.UserId or "")
        local cra = Workspace:FindFirstChild("ClientRenderedAssets")
        if cra and myUidStr ~= "" then
            local expectedName = myUidStr .. "_" .. tostring(carryUid)
            local m = cra:FindFirstChild(expectedName)
            if m and (m:IsA("BasePart") or m:FindFirstChildWhichIsA("BasePart", true)) then
                return true, tostring(carryUid)
            end
        end

        if eggCacheByUid and eggCacheByUid[carryUid] then
            local rec = eggCacheByUid[carryUid]
            if typeof(rec) == "table" and rec.CarrierUserId and tostring(rec.CarrierUserId) == myUidStr and rec.State == "Carried" then
                local name = rec.DisplayName or rec.AssetCategory or rec.Name or tostring(carryUid)
                return true, name
            end
        end
    end

    return false, nil
end

local function getCarryingStatus()
    if weAreCarrying then
        local rec = carryUid and eggCacheByUid[carryUid]
        local name = rec and (rec.DisplayName or rec.AssetCategory or rec.Name) or carryUid or "Egg"
        return true, name
    end
    return isHoldingEgg()
end

updateActivityStatus = function()
    local isCarrying, eggName = getCarryingStatus()
    local activeSpeed = isCarrying and baseCarrySpeed or baseGoSpeed

    if activityStatusLabel then
        if isCarrying then
            local dispName = eggName or "Egg"
            activityStatusLabel.Text = string.format("Status: Carrying %s (%d studs/s)", dispName, activeSpeed)
            activityStatusLabel.TextColor3 = Color3.fromRGB(255, 205, 90)
        else
            activityStatusLabel.Text = string.format("Status: Not Carrying | Free Movement (%d studs/s)", activeSpeed)
            activityStatusLabel.TextColor3 = Color3.fromRGB(150, 185, 230)
        end
    end

    if velLiveLabel then
        if velocityEnabled then
            local char = LocalPlayer and LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local isMoving = hum and hum.MoveDirection.Magnitude > 0.05
            velLiveLabel.Text = string.format("Vel: %d", isMoving and activeSpeed or 0)
            velLiveLabel.TextColor3 = isMoving and Color3.fromRGB(100, 240, 255) or Color3.fromRGB(150, 200, 240)
        else
            velLiveLabel.Text = "Vel: OFF"
            velLiveLabel.TextColor3 = Color3.fromRGB(130, 140, 160)
        end
    end
end

local SAFE_ZONE = Vector3.new(530.332, 70.724, -399.111)

getSafeZonePosition = function()
    return SAFE_ZONE
end

local function getBesideOffset(targetPos, currentPos, dist)
    dist = dist or 2.8
    local diff = Vector3.new(currentPos.X - targetPos.X, 0, currentPos.Z - targetPos.Z)
    local dir = diff.Magnitude > 0.1 and diff.Unit or Vector3.new(0, 0, 1)
    local groundY = currentPos.Y
    if math.abs(groundY - targetPos.Y) > 6 then groundY = targetPos.Y end
    local besidePos = Vector3.new(targetPos.X + dir.X * dist, groundY, targetPos.Z + dir.Z * dist)
    local lookTarget = Vector3.new(targetPos.X, groundY, targetPos.Z)
    return besidePos, lookTarget
end

local activeWalkTarget = nil
local activeWalkArriveDist = 3.5
local activeWalkSnapDist = 60.0
local activeWalkUid = nil
local activeWalkCallback = nil
local activeWalkToken = 0
local walkLastPos = nil
local walkStuckFrames = 0

local cachedControls = nil
local function getPlayerInputVector()
    local inputVec = Vector3.zero
    if cachedControls and cachedControls.GetMoveVector then
        local ok, mv = pcall(function() return cachedControls:GetMoveVector() end)
        if ok and typeof(mv) == "Vector3" and mv.Magnitude > 0.05 then
            inputVec = mv
        end
    end
    if inputVec.Magnitude <= 0.05 then
        pcall(function()
            local ps = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerScripts")
            local pm = ps and ps:FindFirstChild("PlayerModule")
            if pm then
                local controls = require(pm):GetControls()
                if controls and controls.GetMoveVector then
                    cachedControls = controls
                    local mv = controls:GetMoveVector()
                    if typeof(mv) == "Vector3" and mv.Magnitude > 0.05 then
                        inputVec = mv
                    end
                end
            end
        end)
    end
    if inputVec.Magnitude <= 0.05 and UserInputService then
        local ix, iz = 0, 0
        if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then ix = ix - 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then ix = ix + 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then iz = iz - 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then iz = iz + 1 end
        if ix ~= 0 or iz ~= 0 then
            inputVec = Vector3.new(ix, 0, iz).Unit
        end
    end
    return inputVec
end

local function stopWalking()
    activeWalkToken = (activeWalkToken or 0) + 1
    activeWalkTarget = nil
    activeWalkCallback = nil
    activeWalkUid = nil
    walkLastPos = nil
    walkStuckFrames = 0
    pcall(function()
        local char = LocalPlayer and LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hum then
            hum:Move(Vector3.zero, false)
            if hrp then hum.WalkToPoint = hrp.Position end
        end
        if hrp then hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0) end
    end)
end

local function walkToTarget(targetPos, arriveDist, onArrived, uid, snapDist)
    if typeof(targetPos) == "CFrame" then
        targetPos = targetPos.Position
    elseif typeof(targetPos) == "table" and targetPos.X and targetPos.Y and targetPos.Z then
        targetPos = Vector3.new(targetPos.X, targetPos.Y, targetPos.Z)
    end
    if typeof(targetPos) ~= "Vector3" then return end

    activeWalkToken = (activeWalkToken or 0) + 1
    local myTok = activeWalkToken

    activeWalkTarget = targetPos
    activeWalkArriveDist = arriveDist or 3.5
    activeWalkSnapDist = snapDist
    activeWalkUid = uid
    activeWalkCallback = onArrived
    walkLastPos = nil
    walkStuckFrames = 0

    task.spawn(function()
        local t0 = os.clock()
        while activeWalkToken == myTok do
            -- Safety timeout (if player gets stuck or path takes > 45s)
            if os.clock() - t0 > 45.0 then
                stopWalking()
                break
            end

            local char = LocalPlayer and LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not (hum and hrp and hum.Health > 0) then
                task.wait(0.1)
            else
                -- 1. State / Target Validation checks
                -- Walking to an egg and target egg already secured: stop walking to egg
                if activeWalkUid ~= "SAFE_ZONE" and (weAreCarrying and carryUid == activeWalkUid) then
                    local cb = activeWalkCallback
                    stopWalking()
                    if cb then task.spawn(cb) end
                    return
                end

                -- Walking to SafeZone and egg dropped: immediately abort safezone walk and re-pick!
                if activeWalkUid == "SAFE_ZONE" and not (weAreCarrying or isHoldingEgg()) then
                    stopWalking()
                    if autoReturnActive and autoReturnTargetUid then
                        handleEggDropped(autoReturnTargetUid)
                    end
                    return
                end

                -- Target egg was claimed or carried by another player
                if activeWalkUid and activeWalkUid ~= "SAFE_ZONE" and eggCacheByUid and eggCacheByUid[activeWalkUid] then
                    local rec = eggCacheByUid[activeWalkUid]
                    local myId = tostring(LocalPlayer and LocalPlayer.UserId or "")
                    if rec.State == "Claimed" or (rec.CarrierUserId and tostring(rec.CarrierUserId) ~= myId) then
                        stopWalking()
                        if autoReturnActive and autoReturnTargetUid == activeWalkUid then
                            if rec.State == "Claimed" and (rec.CarrierUserId and tostring(rec.CarrierUserId) == myId) then
                                handleEggDelivered(activeWalkUid)
                            else
                                autoReturnActive = false
                                autoReturnTargetUid = nil
                                returnTripInProgress = false
                                print("[EggGoTo v11] Target egg was taken by another player.")
                            end
                        end
                        return
                    end

                    -- Live refresh target position if egg shifted
                    local liveP = getEggPosition(rec, activeWalkUid)
                    if liveP then
                        targetPos = liveP
                        activeWalkTarget = liveP
                    end
                end

                local curPos = hrp.Position
                local diff = Vector3.new(targetPos.X - curPos.X, 0, targetPos.Z - curPos.Z)
                local dist = diff.Magnitude

                -- 2. Arrival or Snap Teleport Check
                local effectiveSnap = activeWalkSnapDist or 8.0
                if dist <= activeWalkArriveDist or dist <= effectiveSnap then
                    local cb = activeWalkCallback
                    local walkUid = activeWalkUid
                    local finalTarget = targetPos
                    pcall(function()
                        hrp.AssemblyLinearVelocity = Vector3.zero
                        if walkUid == "SAFE_ZONE" then
                            local yPos = finalTarget.Y
                            if math.abs(curPos.Y - finalTarget.Y) <= 4 then yPos = curPos.Y end
                            hrp.CFrame = CFrame.new(finalTarget.X, yPos, finalTarget.Z) * (hrp.CFrame - hrp.CFrame.Position)
                        else
                            local bPos, lookTarget = getBesideOffset(finalTarget, curPos, 2.8)
                            hrp.CFrame = CFrame.lookAt(bPos, lookTarget)
                        end
                        hum:Move(Vector3.zero, false)
                        if hrp then hum.WalkToPoint = hrp.Position end
                    end)
                    stopWalking()
                    if cb then task.spawn(cb) end
                    return
                end

                -- 3. Anti-stuck watchdog: hop over small bumps if blocked
                if walkLastPos and (Vector3.new(curPos.X - walkLastPos.X, 0, curPos.Z - walkLastPos.Z)).Magnitude < 0.5 then
                    walkStuckFrames = walkStuckFrames + 1
                    if walkStuckFrames >= 3 then
                        walkStuckFrames = 0
                        pcall(function() hum.Jump = true end)
                    end
                else
                    walkStuckFrames = 0
                end
                walkLastPos = curPos

                -- 4. Fast monitor tick: physics loop handles seamless steering and velocity
                task.wait(0.08)
            end
        end
    end)
end

handleEggDelivered = function(uid)
    print(string.format("[EggGoTo v11] Egg %s successfully delivered!", tostring(uid)))
    autoReturnActive = false
    autoReturnTargetUid = nil
    returnTripInProgress = false
    weAreCarrying = false
    carryUid = nil
    stopWalking()
    pcall(function()
        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
        if hum then hum:UnequipTools() end
    end)
    updateActivityStatus()
end

handleEggDropped = function(u, payload)
    if not autoReturnActive then return end
    if activeWalkUid == u then return end
    returnTripInProgress = false
    stopWalking()

    local dropPos = nil
    if payload and typeof(payload) == "table" and payload.BoundsCFrame then
        local cf = payload.BoundsCFrame
        if typeof(cf) == "CFrame" then dropPos = cf.Position
        elseif typeof(cf) == "Vector3" then dropPos = cf
        elseif typeof(cf) == "table" and cf.X and cf.Y and cf.Z then
            dropPos = Vector3.new(cf.X, cf.Y, cf.Z)
        end
    end

    if not dropPos and eggCacheByUid and eggCacheByUid[u] then
        dropPos = getEggPosition(eggCacheByUid[u], u)
    end

    if not dropPos then
        local char = LocalPlayer and LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then dropPos = hrp.Position end
    end

    if not dropPos then return end

    print(string.format("[EggGoTo v11] Egg dropped! Turning around to re-pick (%s)...", tostring(u)))
    if activityStatusLabel then
        activityStatusLabel.Text = "Status: Egg dropped! Re-picking egg..."
        activityStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 60)
    end

    walkToTarget(dropPos, 3.5, function()
        executePickupSpam({
            Uid = u,
            Position = dropPos,
            Name = "Dropped Egg"
        })
        startAutoPickupSpam()
    end, u, 8.0)
end

startReturnTrip = function()
    if returnTripInProgress and activeWalkUid == "SAFE_ZONE" then return end
    returnTripInProgress = true

    local safePos = getSafeZonePosition()
    if not safePos then return end

    print(string.format("[EggGoTo v11] Egg secured! Automatically returning to SafeZone (%d, %d, %d)...", math.floor(safePos.X), math.floor(safePos.Y), math.floor(safePos.Z)))
    if activityStatusLabel then
        activityStatusLabel.Text = "Status: Returning to SafeZone with Egg..."
        activityStatusLabel.TextColor3 = Color3.fromRGB(100, 240, 255)
    end

    walkToTarget(safePos, 6.0, function()
        print("[EggGoTo v11] Arrived at SafeZone. Delivering egg...")
        pcall(function()
            local char = LocalPlayer and LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
            if hum then hum:UnequipTools() end
        end)
        autoReturnActive = false
        autoReturnTargetUid = nil
        returnTripInProgress = false
        weAreCarrying = false
        carryUid = nil
        if activityStatusLabel then
            activityStatusLabel.Text = "Status: Arrived at SafeZone with Egg"
            activityStatusLabel.TextColor3 = Color3.fromRGB(120, 240, 160)
        end
    end, "SAFE_ZONE", 60.0)
end

local function updateVelocityPhysics()
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp and hrp.Parent and hum.Health > 0) then return end

    local isCarrying = getCarryingStatus()
    local targetSpeed = isCarrying and baseCarrySpeed or baseGoSpeed

    -- Case 1: Active Auto-Walk (Walking to Egg or Returning to SafeZone)
    if activeWalkTarget then
        local curPos = hrp.Position
        local diff = Vector3.new(activeWalkTarget.X - curPos.X, 0, activeWalkTarget.Z - curPos.Z)
        local targetDir = diff.Magnitude > 0.1 and diff.Unit or Vector3.zero

        -- Query player manual steering input (A, D, W, S or analog thumbstick)
        local inputVec = getPlayerInputVector()
        local moveDir = targetDir

        if inputVec.Magnitude > 0.05 then
            local cam = Workspace.CurrentCamera
            local camLook = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
            local camRight = cam and cam.CFrame.RightVector or Vector3.new(1, 0, 0)
            local camFwdFlat = Vector3.new(camLook.X, 0, camLook.Z).Unit
            local camRtFlat = Vector3.new(camRight.X, 0, camRight.Z).Unit
            local worldManualDir = (camRtFlat * inputVec.X - camFwdFlat * inputVec.Z)

            if worldManualDir.Magnitude > 0.05 then
                -- Smoothly blend target direction with manual lateral steering:
                -- Retains 100% full speed while allowing agile veering around obstacles!
                moveDir = (targetDir + worldManualDir.Unit * 1.0).Unit
            end
        end

        hum:Move(moveDir, false)

        if velocityEnabled and moveDir.Magnitude > 0.05 then
            hrp.AssemblyLinearVelocity = Vector3.new(
                moveDir.X * targetSpeed,
                hrp.AssemblyLinearVelocity.Y,
                moveDir.Z * targetSpeed
            )
            if hum.WalkSpeed ~= targetSpeed then
                pcall(function() hum.WalkSpeed = targetSpeed end)
            end
        end
        return
    end

    -- Case 2: Regular Velocity Physics for manual player free-roam (WASD)
    if not velocityEnabled then return end

    if hum.MoveDirection.Magnitude > 0.05 then
        local dir = hum.MoveDirection.Unit
        hrp.AssemblyLinearVelocity = Vector3.new(
            dir.X * targetSpeed,
            hrp.AssemblyLinearVelocity.Y,
            dir.Z * targetSpeed
        )
        if hum.WalkSpeed ~= targetSpeed then
            pcall(function() hum.WalkSpeed = targetSpeed end)
        end
    end
end

local function disableVelocity()
    velocityEnabled = false
    velToggleBtn.Text = "[OFF] Velocity"
    velToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
    velToggleBtn.TextColor3 = Color3.fromRGB(210, 220, 240)

    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function() hum.WalkSpeed = savedWalkSpeed end)
    end
    updateActivityStatus()
end

local function enableVelocity()
    local char = LocalPlayer and LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed > 0 then
        savedWalkSpeed = hum.WalkSpeed
    end
    velocityEnabled = true
    velToggleBtn.Text = "[ON] Velocity"
    velToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    velToggleBtn.TextColor3 = Color3.new(1, 1, 1)
    updateActivityStatus()
end

addConnection(velToggleBtn.MouseButton1Click:Connect(function()
    if velocityEnabled then
        disableVelocity()
    else
        enableVelocity()
    end
end))

addConnection(goBox.FocusLost:Connect(function()
    local val = tonumber(goBox.Text)
    if val and val > 0 then
        baseGoSpeed = math.clamp(math.floor(val), 16, 500)
    end
    goBox.Text = tostring(baseGoSpeed)
    updateActivityStatus()
end))

addConnection(carryBox.FocusLost:Connect(function()
    local val = tonumber(carryBox.Text)
    if val and val > 0 then
        baseCarrySpeed = math.clamp(math.floor(val), 16, 500)
    end
    carryBox.Text = tostring(baseCarrySpeed)
    updateActivityStatus()
end))

addConnection(RunService.Heartbeat:Connect(updateVelocityPhysics))

addConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
    local hum = newChar:WaitForChild("Humanoid", 5)
    if hum and not velocityEnabled then
        savedWalkSpeed = hum.WalkSpeed
    end
    weAreCarrying = false
    carryUid = nil
    updateActivityStatus()
    pcall(function()
        bindRecoveryCharacter(newChar)
    end)
end))

-- ============================================================================
-- ZERO-WAIT INSTANT RAGDOLL RECOVERY ENGINE (Anti-Stun & Anti-Fling)
-- ============================================================================

local recoveryJoints = {}
local recoveryConnections = {}

local function enablePlayerControls()
    if cachedControls and cachedControls.Enable then
        pcall(function() cachedControls:Enable() end)
        return
    end
    pcall(function()
        local ps = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerScripts")
        local pm = ps and ps:FindFirstChild("PlayerModule")
        if pm then
            local controls = require(pm):GetControls()
            if controls and controls.Enable then
                cachedControls = controls
                controls:Enable()
            end
        end
    end)
end

local function clearRagdollAttributes()
    pcall(function()
        if LocalPlayer then
            LocalPlayer:SetAttribute("RagdollEndTime", 0)
            LocalPlayer:SetAttribute("RagdollTime", 0)
            LocalPlayer:SetAttribute("IsRagdoll", false)
            LocalPlayer:SetAttribute("Ragdolled", false)
        end
        local char = LocalPlayer and LocalPlayer.Character
        if char then
            char:SetAttribute("RagdollEndTime", 0)
            char:SetAttribute("RagdollTime", 0)
            char:SetAttribute("IsRagdoll", false)
            char:SetAttribute("Ragdolled", false)
        end
    end)
end

local isRecovering = false
local lastRecoveryTime = 0

executeInstantRecovery = function(reason)
    if not (RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled) then return end
    local now = os.clock()
    if isRecovering or (now - lastRecoveryTime < 0.05) then return end
    isRecovering = true
    lastRecoveryTime = now

    local char = LocalPlayer and LocalPlayer.Character
    if not char then
        isRecovering = false
        return
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp and hum.Health > 0) then
        isRecovering = false
        return
    end

    clearRagdollAttributes()

    if #recoveryJoints > 0 then
        for _, motor in ipairs(recoveryJoints) do
            if motor and motor.Parent and not motor.Enabled then
                motor.Enabled = true
            end
        end
    end

    hum.PlatformStand = false
    hum.Sit = false
    hum.AutoRotate = true

    pcall(function()
        hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        hum:ChangeState(Enum.HumanoidStateType.Running)
    end)

    local curTargetSpeed = velocityEnabled and (getCarryingStatus() and baseCarrySpeed or baseGoSpeed) or math.max(savedWalkSpeed or 16, 16)
    if hum.WalkSpeed < 16.0 then
        hum.WalkSpeed = curTargetSpeed
    end

    enablePlayerControls()

    -- Anti-Fling Braking & Fast Grounding:
    -- Cancels horizontal fling so character stays right at the bump location beside the egg,
    -- and pulls downward fast if launched into the air.
    if RECOVERY_CONFIG.AntiFling and hrp then
        local curVel = hrp.AssemblyLinearVelocity
        local fastY = curVel.Y
        if fastY > -30 then
            fastY = -45
        end
        hrp.AssemblyLinearVelocity = Vector3.new(0, fastY, 0)
        hrp.AssemblyAngularVelocity = Vector3.zero
    end

    isRecovering = false
end

bindRecoveryCharacter = function(char)
    for _, conn in ipairs(recoveryConnections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(recoveryConnections)
    table.clear(recoveryJoints)

    if not char then return end
    local hum = char:WaitForChild("Humanoid", 5)
    local hrp = char:WaitForChild("HumanoidRootPart", 5)
    if not (hum and hrp) then return end

    local function registerMotor(obj)
        if obj:IsA("Motor6D") then
            table.insert(recoveryJoints, obj)
            local conn = obj:GetPropertyChangedSignal("Enabled"):Connect(function()
                if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled and not obj.Enabled then
                    obj.Enabled = true
                    executeInstantRecovery("JointLock")
                end
            end)
            table.insert(recoveryConnections, conn)
        end
    end

    for _, desc in ipairs(char:GetDescendants()) do
        registerMotor(desc)
    end

    local descConn = char.DescendantAdded:Connect(function(desc)
        registerMotor(desc)
    end)
    table.insert(recoveryConnections, descConn)

    local stateConn = hum.StateChanged:Connect(function(_, newState)
        if not (RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled) then return end
        if newState == Enum.HumanoidStateType.Ragdoll
            or newState == Enum.HumanoidStateType.FallingDown
            or newState == Enum.HumanoidStateType.Physics then
            executeInstantRecovery(newState.Name)
        end
    end)
    table.insert(recoveryConnections, stateConn)

    local platConn = hum:GetPropertyChangedSignal("PlatformStand"):Connect(function()
        if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled and hum.PlatformStand then
            hum.PlatformStand = false
            executeInstantRecovery("PlatformStand")
        end
    end)
    table.insert(recoveryConnections, platConn)

    local sitConn = hum:GetPropertyChangedSignal("Sit"):Connect(function()
        if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled and hum.Sit then
            hum.Sit = false
            executeInstantRecovery("Sit")
        end
    end)
    table.insert(recoveryConnections, sitConn)

    if LocalPlayer then
        local attrConn1 = LocalPlayer:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
            if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled then
                local rEnd = LocalPlayer:GetAttribute("RagdollEndTime")
                if typeof(rEnd) == "number" and rEnd > 0 then
                    executeInstantRecovery("RagdollTimer")
                end
            end
        end)
        table.insert(recoveryConnections, attrConn1)
    end

    local attrConn2 = char:GetAttributeChangedSignal("RagdollEndTime"):Connect(function()
        if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled then
            local rEnd = char:GetAttribute("RagdollEndTime")
            if typeof(rEnd) == "number" and rEnd > 0 then
                executeInstantRecovery("CharRagdollTimer")
            end
        end
    end)
    table.insert(recoveryConnections, attrConn2)
end

if LocalPlayer and LocalPlayer.Character then
    task.spawn(function()
        bindRecoveryCharacter(LocalPlayer.Character)
    end)
end

-- ============================================================================
-- FAST PICKUP & PROXIMITY PROMPT ENGINE (Clean Port from v10)
-- ============================================================================

local function getCarryRemote()
    local ok, r = pcall(function()
        return ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggCarry"]
    end)
    return ok and r or nil
end

local function carryEgg(uid, burstCount)
    if not uid or uid == "" then return false end
    burstCount = burstCount or (PICKUP_CONFIG and PICKUP_CONFIG.SpamBurstCount) or 8
    local rf = getCarryRemote()
    if not rf then return false end
    local payload = { Uid = uid }
    for i = 1, burstCount do
        task.spawn(function()
            pcall(function() return rf:InvokeServer(payload) end)
        end)
    end
    return true
end

local function isCarryPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    local name = (prompt.Name or ""):lower()
    local action = (prompt.ActionText or ""):lower()
    local obj = (prompt.ObjectText or ""):lower()

    -- Strict blacklist: REJECT ANY hatch, open, crack, buy, purchase, shop, talk, manor prompt
    if name:find("hatch") or name:find("open") or name:find("crack") or name:find("buy") or name:find("shop") or name:find("purchase") or name:find("talk") or name:find("manor") then
        return false
    end
    if action:find("hatch") or action:find("open") or action:find("crack") or action:find("buy") or action:find("shop") or action:find("purchase") or action:find("talk") then
        return false
    end
    if obj:find("hatch") or obj:find("open") or obj:find("crack") or obj:find("buy") or obj:find("shop") or obj:find("purchase") or obj:find("talk") then
        return false
    end

    -- Strict whitelist: ONLY accept steal, carry, pick, take, grab, collect, hold
    if name:find("carry") or name:find("steal") or name:find("pickup") or name:find("pick") or name:find("halloweenegg") or name:find("eggprompt") then
        return true
    end
    if action:find("steal") or action:find("carry") or action:find("pick") or action:find("take") or action:find("grab") or action:find("collect") then
        return true
    end

    return false
end

local function triggerProximityPrompt(prompt)
    if not prompt or not prompt.Parent then return end
    if not isCarryPrompt(prompt) then return end
    pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
    end)
    if typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt, 0)
        pcall(fireproximityprompt, prompt)
    end
    pcall(function()
        if typeof(prompt.InputHoldBegin) == "function" then
            prompt:InputHoldBegin()
            prompt:InputHoldEnd()
        end
    end)
end

local function applyReachAssist(targetPos)
    if weAreCarrying then return false end
    local char = LocalPlayer and LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root or typeof(targetPos) ~= "Vector3" then return false end
    local dist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
    local maxReach = (PICKUP_CONFIG and PICKUP_CONFIG.MaxReachDistance) or 35
    if dist > 3 and dist <= maxReach then
        local bPos, lookTarget = getBesideOffset(targetPos, root.Position, 2.8)
        pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.CFrame = CFrame.lookAt(bPos, lookTarget)
        end)
        return true
    end
    return false
end

local function getBestFocusedTarget()
    if weAreCarrying then return nil end
    local char = LocalPlayer and LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end

    local charPos  = root.Position
    local charLook = root.CFrame.LookVector
    local cam = Workspace.CurrentCamera
    local camPos  = cam and cam.CFrame.Position or charPos
    local camLook = cam and cam.CFrame.LookVector or charLook

    local bestTarget, highestScore = nil, -math.huge
    local maxDist = (PICKUP_CONFIG and PICKUP_CONFIG.ReachAssist and PICKUP_CONFIG.MaxReachDistance) or 16

    local function scoreTarget(pos, dist)
        local dir = dist > 0.01 and (pos - charPos).Unit or charLook
        local charDot = charLook:Dot(dir)
        local camDir = ((pos - camPos).Magnitude > 0.01) and (pos - camPos).Unit or camLook
        local camDot = camLook:Dot(camDir)
        local score = (math.max(0, camDot) * 2.2 + math.max(0, charDot) * 1.2 + 0.3) / (dist + 0.5)
        if dist <= 6 then score = score + 3 end
        return score
    end

    -- 1. Scan from eggCacheByUid
    if eggCacheByUid then
        for uid, r in pairs(eggCacheByUid) do
            local isCarriedByOther = r.CarrierUserId and tostring(r.CarrierUserId) ~= tostring(LocalPlayer and LocalPlayer.UserId)
            if r.State ~= "Claimed" and not isCarriedByOther then
                local pos = getEggPosition(r)
                if pos then
                    local dist = (pos - charPos).Magnitude
                    if dist <= maxDist then
                        local score = scoreTarget(pos, dist)
                        if score > highestScore then
                            highestScore = score
                            local disp = r.DisplayName or r.AssetCategory or r.Name or "Egg"
                            bestTarget = {
                                Type = "EggRecord",
                                Uid = uid,
                                Name = disp,
                                Position = pos,
                                Distance = dist,
                                Prompt = nil
                            }
                        end
                    end
                end
            end
        end
    end

    -- 2. Scan AreaEggSlotsClient directly
    local slotsFolder = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slotsFolder then
        for _, ch in ipairs(slotsFolder:GetChildren()) do
            local pos = ch:IsA("BasePart") and ch.Position or (ch:IsA("Model") and ch:GetPivot().Position)
            if pos then
                local dist = (pos - charPos).Magnitude
                if dist <= maxDist then
                    local score = scoreTarget(pos, dist)
                    local uid = ch:GetAttribute("Uid") or ch:GetAttribute("EggUid")
                    if not uid and #ch.Name == 32 and ch.Name:match("^%x+$") then uid = ch.Name end
                    if not uid and eggCacheByUid then
                        for eUid, eRec in pairs(eggCacheByUid) do
                            local ePos = getEggPosition(eRec)
                            if ePos and (ePos - pos).Magnitude < 4.0 then
                                uid = eUid
                                break
                            end
                        end
                    end
                    if uid and score > highestScore then
                        highestScore = score
                        bestTarget = {
                            Type = "SlotDirect",
                            Uid = uid,
                            Name = ch.Name,
                            Position = pos,
                            Distance = dist,
                            Prompt = ch:FindFirstChildWhichIsA("ProximityPrompt", true)
                        }
                    end
                end
            end
        end
    end

    -- 3. Scan Workspace.Eggs
    local eggsFolder = Workspace:FindFirstChild("Eggs")
    if eggsFolder then
        for _, ch in ipairs(eggsFolder:GetChildren()) do
            local pos = ch:IsA("BasePart") and ch.Position or (ch:IsA("Model") and ch:GetPivot().Position)
            if pos then
                local dist = (pos - charPos).Magnitude
                if dist <= maxDist then
                    local score = scoreTarget(pos, dist)
                    local uid = ch:GetAttribute("Uid") or ch:GetAttribute("EggUid")
                    if not uid and #ch.Name == 32 and ch.Name:match("^%x+$") then uid = ch.Name end
                    if uid and score > highestScore then
                        highestScore = score
                        bestTarget = {
                            Type = "WorldEgg",
                            Uid = uid,
                            Name = ch.Name,
                            Position = pos,
                            Distance = dist,
                            Prompt = ch:FindFirstChildWhichIsA("ProximityPrompt", true)
                        }
                    end
                end
            end
        end
    end

    -- Associate ProximityPrompt if not already found
    if bestTarget and not bestTarget.Prompt and bestTarget.Uid then
        if slotsFolder then
            local slotInst = slotsFolder:FindFirstChild(bestTarget.Uid)
            if not slotInst then
                for _, ch in ipairs(slotsFolder:GetChildren()) do
                    if ch:GetAttribute("Uid") == bestTarget.Uid or ch:GetAttribute("EggUid") == bestTarget.Uid then
                        slotInst = ch; break
                    end
                end
            end
            if slotInst then
                bestTarget.Prompt = slotInst:FindFirstChildWhichIsA("ProximityPrompt", true)
            end
        end
        if not bestTarget.Prompt and eggsFolder then
            local eggInst = eggsFolder:FindFirstChild(bestTarget.Uid)
            if eggInst then
                bestTarget.Prompt = eggInst:FindFirstChildWhichIsA("ProximityPrompt", true)
            end
        end
    end

    return bestTarget
end

executePickupSpam = function(target)
    if not target then return end
    if target.Uid then
        carryUid = target.Uid
    end
    if target.Prompt then
        triggerProximityPrompt(target.Prompt)
    else
        local pr = nil
        local ar = Workspace:FindFirstChild("AreaEggSlotsClient")
        if ar and target.Uid then
            local sl = ar:FindFirstChild(target.Uid)
            if not sl then
                for _, ch in ipairs(ar:GetChildren()) do
                    if ch:GetAttribute("Uid") == target.Uid or ch:GetAttribute("EggUid") == target.Uid then
                        sl = ch; break
                    end
                end
            end
            if sl then pr = sl:FindFirstChildWhichIsA("ProximityPrompt", true) end
        end
        if not pr and target.Uid and Workspace:FindFirstChild("Eggs") then
            local em = Workspace.Eggs:FindFirstChild(target.Uid)
            if em then pr = em:FindFirstChildWhichIsA("ProximityPrompt", true) end
        end
        if pr then
            triggerProximityPrompt(pr)
        end
    end
    if target.Uid then
        carryEgg(target.Uid, (PICKUP_CONFIG and PICKUP_CONFIG.SpamBurstCount) or 8)
    end
end

startAutoPickupSpam = function()
    if weAreCarrying then return end
    autoPickupToken = (autoPickupToken or 0) + 1
    local myTok = autoPickupToken
    task.spawn(function()
        local tStart = os.clock()
        local maxDuration = 1.5
        local hasSnapped = false
        while autoPickupToken == myTok and PICKUP_CONFIG and PICKUP_CONFIG.Enabled and (os.clock() - tStart < maxDuration) do
            local target = getBestFocusedTarget()
            if target then
                if not hasSnapped and PICKUP_CONFIG.ReachAssist and target.Position then
                    local char = LocalPlayer and LocalPlayer.Character
                    local root = char and char:FindFirstChild("HumanoidRootPart")
                    local dist = root and (target.Position - root.Position).Magnitude or 999
                    if dist <= 3.5 then
                        hasSnapped = true
                    elseif dist <= (PICKUP_CONFIG.MaxReachDistance or 35) then
                        if applyReachAssist(target.Position) then
                            hasSnapped = true
                        end
                    end
                end
                executePickupSpam(target)
            end
            if isHoldingEgg() or weAreCarrying then
                if autoReturnActive and autoReturnTargetUid then
                    task.delay(0.2, function()
                        if autoReturnActive and (weAreCarrying or isHoldingEgg()) then
                            startReturnTrip()
                        end
                    end)
                end
                break
            end
            task.wait(0.035)
        end
    end)
end

-- Key Listener: Press [E] for Instant Zero-Hold Pickup Spam & WASD auto-walk cancel
addConnection(UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if UserInputService:GetFocusedTextBox() ~= nil then return end

    -- Cancel auto-walk / auto-return ONLY when [Q] is pressed (W, A, S, D will NOT cancel auto-travel)
    if input.KeyCode == Enum.KeyCode.Q then
        if activeWalkTarget then
            stopWalking()
        end
        if autoReturnActive then
            autoReturnActive = false
            autoReturnTargetUid = nil
            returnTripInProgress = false
            if activityStatusLabel then
                activityStatusLabel.Text = "Status: Auto-Travel Cancelled [Q]"
                activityStatusLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
            end
        end
    end

    -- Jump during auto-walk / auto-return: trigger jump without cancelling movement or slowing down
    if input.KeyCode == Enum.KeyCode.Space then
        if activeWalkTarget then
            local char = LocalPlayer and LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                pcall(function()
                    hum.Jump = true
                end)
            end
        end
    end

    if input.KeyCode == Enum.KeyCode.E then
        if hwAutoPickEnabled and startHalloweenAutoPickup then
            startHalloweenAutoPickup()
        elseif PICKUP_CONFIG and PICKUP_CONFIG.Enabled then
            startAutoPickupSpam()
        end
    end
end))

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
            stopWalking()
            autoReturnActive = false
            autoReturnTargetUid = nil
            returnTripInProgress = false
            local eggData = item.data
            if not eggData then return end
            local targetPos = eggData.Position or getEggPosition(eggData.Record, eggData.Uid)
            if not targetPos then return end
            if typeof(targetPos) == "CFrame" then targetPos = targetPos.Position end
            if typeof(targetPos) == "table" and targetPos.X and targetPos.Y and targetPos.Z then
                targetPos = Vector3.new(targetPos.X, targetPos.Y, targetPos.Z)
            end
            if typeof(targetPos) ~= "Vector3" then return end
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local root = ch and ch:FindFirstChild("HumanoidRootPart")
                if root then
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.CFrame = CFrame.new(targetPos + Vector3.new(0, 3, 0))
                end
            end)
        end))

        addConnection(getBtn.MouseButton1Click:Connect(function()
            local eggData = item.data
            if not eggData then return end

            -- Automatically unequip any tool so character can freely run to target
            pcall(function()
                local char = LocalPlayer and LocalPlayer.Character
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if hum then hum:UnequipTools() end
            end)
            weAreCarrying = false
            carryUid = nil
            local targetPos = eggData.Position or getEggPosition(eggData.Record, eggData.Uid)
            if not targetPos then
                warn("[EggGoTo v11] Target position could not be resolved for", eggData.DisplayName, eggData.Uid)
                return
            end
            if typeof(targetPos) == "CFrame" then targetPos = targetPos.Position end
            if typeof(targetPos) == "table" and targetPos.X and targetPos.Y and targetPos.Z then
                targetPos = Vector3.new(targetPos.X, targetPos.Y, targetPos.Z)
            end
            if typeof(targetPos) ~= "Vector3" then return end

            -- Arm Auto-Return Engine for this egg retrieval
            autoReturnActive = true
            autoReturnTargetUid = eggData.Uid
            returnTripInProgress = false

            walkToTarget(targetPos, 3.5, function()
                executePickupSpam({
                    Uid = eggData.Uid,
                    Position = targetPos,
                    Name = eggData.DisplayName
                })
                startAutoPickupSpam()
            end, eggData.Uid, 8.0)
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
-- HALLOWEEN DIMENSION LIVE EGG LIST (ISOLATED MODULE - NO PICKUP LOGIC)
-- ============================================================================

local function getHwEggPos(eggInst)
    if not eggInst then return nil end
    local hitbox = eggInst:FindFirstChild("Hitbox")
    if hitbox and hitbox:IsA("BasePart") then return hitbox.Position end
    if eggInst.PrimaryPart then return eggInst.PrimaryPart.Position end
    local ok, p = pcall(function() return eggInst:GetPivot().Position end)
    if ok and p then return p end
    local bp = eggInst:FindFirstChildWhichIsA("BasePart")
    return bp and bp.Position or nil
end

local function resolveCanonicalHwName(raw)
    if not raw or raw == "" then return nil end
    local s = tostring(raw)
    local info = (getSpeciesInfo and getSpeciesInfo(s, "Halloween")) or (getSpeciesInfo and getSpeciesInfo(s))
    if info and info.DisplayName then
        return info.DisplayName
    end
    local lower = s:lower()
    if lower == "halloween egg" or lower == "halloween" or lower == "hooded gerbil" or lower == "halloweenegg" then
        return "Hooded Gerbil Egg"
    end
    if lower == "rotshroom" or lower == "rotshroom egg" or lower == "toadstool" then
        return "Toadstool Egg"
    end
    if lower == "quilted imp" or lower == "quilted imp egg" or lower == "patchwork imp" then
        return "Patchwork Imp Egg"
    end
    if not lower:find("egg") then
        return s .. " Egg"
    end
    return s
end

local function getHwEggName(eggInst)
    if not eggInst then return "Hooded Gerbil Egg" end

    -- 1. Check direct attributes: PreparedSourceName is the primary live attribute
    local srcName = eggInst:GetAttribute("PreparedSourceName")
        or eggInst:GetAttribute("DisplayName")
        or eggInst:GetAttribute("EggName")
        or eggInst:GetAttribute("EggType")
        or eggInst:GetAttribute("Species")
        or eggInst:GetAttribute("Name")

    if srcName and tostring(srcName) ~= "" and tostring(srcName):lower() ~= "egg" then
        local resolved = resolveCanonicalHwName(srcName)
        if resolved then return resolved end
    end

    local hitbox = eggInst:FindFirstChild("Hitbox")
    if hitbox then
        local hbAttr = hitbox:GetAttribute("PreparedSourceName")
            or hitbox:GetAttribute("DisplayName")
            or hitbox:GetAttribute("EggName")
            or hitbox:GetAttribute("EggType")
            or hitbox:GetAttribute("Species")
        if hbAttr and tostring(hbAttr) ~= "" and tostring(hbAttr):lower() ~= "egg" then
            local resolved = resolveCanonicalHwName(hbAttr)
            if resolved then return resolved end
        end
    end

    -- 2. Check child string values
    for _, ch in ipairs(eggInst:GetChildren()) do
        if ch:IsA("StringValue") and ch.Value ~= "" and ch.Value:lower() ~= "egg" then
            local resolved = resolveCanonicalHwName(ch.Value)
            if resolved then return resolved end
        end
    end

    -- 3. Check child model names
    for _, ch in ipairs(eggInst:GetChildren()) do
        if ch:IsA("Model") and ch.Name ~= "Model" and ch.Name ~= "Hitbox" and ch.Name:lower() ~= "egg" then
            local resolved = resolveCanonicalHwName(ch.Name)
            if resolved then return resolved end
        end
    end

    -- 4. Check ProximityPrompt text on model for explicit species keywords
    local prMatch = nil
    pcall(function()
        for _, d in ipairs(eggInst:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                local txt = (d.ObjectText or "") .. " " .. (d.ActionText or "")
                for cleanName, rec in pairs(SPECIES_INFO) do
                    if cleanName ~= "egg" and cleanName ~= "halloween" and cleanName ~= "halloweenegg" then
                        if rec.DisplayName and txt:lower():find(cleanName, 1, true) then
                            prMatch = rec.DisplayName
                            break
                        end
                    end
                end
                if prMatch then break end
            end
        end
    end)
    if prMatch then
        return resolveCanonicalHwName(prMatch)
    end

    -- 5. If model is standard HalloweenEgg or Halloween Egg, it represents Hooded Gerbil Egg
    if eggInst.Name == "HalloweenEgg" or eggInst.Name == "Halloween Egg" then
        return "Hooded Gerbil Egg"
    end

    -- 6. Speculative template match against ReplicatedStorage.Assets.Models.Eggs ONLY for unnamed/generic models
    local okMatch, matchedName = pcall(function()
        local eggAssets = ReplicatedStorage:FindFirstChild("Assets")
            and ReplicatedStorage.Assets:FindFirstChild("Models")
            and ReplicatedStorage.Assets.Models:FindFirstChild("Eggs")
        if not eggAssets then return nil end
        local liveChildren = {}
        local genericPartNames = {
            hitbox = true, part = true, meshpart = true, model = true,
            basepart = true, weld = true, weldconstraint = true,
            pointlight = true, attachment = true, eggradius = true,
            egggrip = true, eggglow = true, eggrootweld = true
        }
        for _, c in ipairs(eggInst:GetChildren()) do
            local cLower = c.Name:lower()
            if not genericPartNames[cLower] and not cLower:find("^cube%.") then
                liveChildren[cLower] = true
            end
        end
        local nonGenericCount = 0
        for _ in pairs(liveChildren) do nonGenericCount = nonGenericCount + 1 end
        if nonGenericCount == 0 then return nil end

        local bestName, bestCount = nil, 0
        for _, tModel in ipairs(eggAssets:GetChildren()) do
            if tModel:IsA("Model") then
                local matchCount = 0
                for _, tc in ipairs(tModel:GetChildren()) do
                    if liveChildren[tc.Name:lower()] then matchCount = matchCount + 1 end
                end
                if matchCount > bestCount then
                    bestCount = matchCount
                    bestName = tModel.Name
                end
            end
        end
        return (bestCount >= 2) and bestName or nil
    end)
    if okMatch and matchedName then
        return resolveCanonicalHwName(matchedName)
    end

    return resolveCanonicalHwName(eggInst.Name) or eggInst.Name
end

local function getHwEggColor(eggInst, eggDisplayName)
    local n = eggDisplayName and eggDisplayName:lower() or eggInst.Name:lower()
    local info = SPECIES_INFO[n] or (getSpeciesInfo and getSpeciesInfo(n))
    if info and info.IsCataloged == true and info.Rarity and RARITY_COLORS[info.Rarity] then
        return RARITY_COLORS[info.Rarity]
    end
    local glow = eggInst:FindFirstChild("Hitbox", true)
    local light = glow and glow:FindFirstChildOfClass("PointLight")
    if light then return light.Color end
    return Color3.fromRGB(230, 115, 30)
end

local hwCardPool = {}

local function getOrCreateHwCard(idx)
    local item = hwCardPool[idx]
    if not item then
        local card = Instance.new("Frame")
        card.Name = "HwCard_" .. tostring(idx)
        card.Size = UDim2.new(1, -6, 0, 34)
        card.BackgroundColor3 = Color3.fromRGB(26, 22, 34)
        card.BorderSizePixel = 0
        card.LayoutOrder = idx
        card.Parent = hwEggListScroll
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)

        local accent = Instance.new("Frame")
        accent.Name = "Accent"
        accent.Size = UDim2.new(0, 3, 1, -6)
        accent.Position = UDim2.new(0, 4, 0, 3)
        accent.BackgroundColor3 = Color3.fromRGB(220, 110, 30)
        accent.BorderSizePixel = 0
        accent.Parent = card
        Instance.new("UICorner", accent).CornerRadius = UDim.new(0, 2)

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Name = "NameLabel"
        nameLabel.Size = UDim2.new(1, -95, 0, 16)
        nameLabel.Position = UDim2.new(0, 12, 0, 2)
        nameLabel.BackgroundTransparency = 1
        nameLabel.TextColor3 = Color3.fromRGB(255, 235, 210)
        nameLabel.TextSize = 11.5
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
        nameLabel.Parent = card

        local subLabel = Instance.new("TextLabel")
        subLabel.Name = "SubLabel"
        subLabel.Size = UDim2.new(1, -95, 0, 13)
        subLabel.Position = UDim2.new(0, 12, 0, 18)
        subLabel.BackgroundTransparency = 1
        subLabel.TextColor3 = Color3.fromRGB(180, 170, 195)
        subLabel.TextSize = 10
        subLabel.Font = Enum.Font.Gotham
        subLabel.TextXAlignment = Enum.TextXAlignment.Left
        subLabel.TextTruncate = Enum.TextTruncate.AtEnd
        subLabel.Parent = card

        local tpBtn = Instance.new("TextButton")
        tpBtn.Name = "TpBtn"
        tpBtn.Size = UDim2.new(0, 36, 0, 22)
        tpBtn.Position = UDim2.new(1, -84, 0.5, -11)
        tpBtn.BackgroundColor3 = Color3.fromRGB(45, 55, 85)
        tpBtn.Text = "TP"
        tpBtn.TextColor3 = Color3.fromRGB(210, 225, 255)
        tpBtn.TextSize = 10.5
        tpBtn.Font = Enum.Font.GothamBold
        tpBtn.Parent = card
        Instance.new("UICorner", tpBtn).CornerRadius = UDim.new(0, 4)

        local getBtn = Instance.new("TextButton")
        getBtn.Name = "GetBtn"
        getBtn.Size = UDim2.new(0, 40, 0, 22)
        getBtn.Position = UDim2.new(1, -44, 0.5, -11)
        getBtn.BackgroundColor3 = Color3.fromRGB(180, 85, 25)
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

        -- Placeholder TP Action: Teleport player +3 studs above egg (NO pickup)
        addConnection(tpBtn.MouseButton1Click:Connect(function()
            local eggData = item.data
            if not (eggData and eggData.Position) then return end
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local root = ch and ch:FindFirstChild("HumanoidRootPart")
                if root then
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.CFrame = CFrame.new(eggData.Position + Vector3.new(0, 3, 0))
                end
            end)
        end))

        -- Placeholder GET Action: Move toward egg (NO pickup)
        addConnection(getBtn.MouseButton1Click:Connect(function()
            local eggData = item.data
            if not (eggData and eggData.Position) then return end
            print(string.format("[Halloween Placeholder] GET clicked for %s at (%.1f, %.1f, %.1f)", tostring(eggData.Name), eggData.Position.X, eggData.Position.Y, eggData.Position.Z))
            pcall(function()
                local ch = LocalPlayer and LocalPlayer.Character
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                if hum then
                    hum:MoveTo(eggData.Position)
                end
            end)
        end))

        hwCardPool[idx] = item
    end
    return item
end

renderHalloweenEggs = function()
    if not (screenGui and screenGui.Parent and main and main.Visible and tabHalloween and tabHalloween.Visible) then
        return
    end

    local charPos = nil
    pcall(function()
        local ch = LocalPlayer and LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        if root then charPos = root.Position end
    end)

    local eggList = {}
    local rawEggModels = {}
    local seenModels = {}

    local function addEggCandidate(egg)
        if egg and not seenModels[egg] then
            seenModels[egg] = true
            table.insert(rawEggModels, egg)
        end
    end

    pcall(function()
        local hw = Workspace:FindFirstChild("HalloweenDimension")
        if not hw then
            hw = Workspace:FindFirstChild("HalloweenDimension", true)
        end
        local worldEggs = hw and (hw:FindFirstChild("WorldEggs") or hw:FindFirstChild("WorldEggs", true))
        if not worldEggs then
            worldEggs = Workspace:FindFirstChild("WorldEggs")
        end
        if worldEggs then
            for _, egg in ipairs(worldEggs:GetChildren()) do
                addEggCandidate(egg)
            end
        end

        local tagged = CollectionService:GetTagged("HalloweenWorldEgg")
        if tagged then
            for _, egg in ipairs(tagged) do
                addEggCandidate(egg)
            end
        end
    end)

    local inHw = false
    pcall(function()
        inHw = (LocalPlayer and LocalPlayer:GetAttribute("InHalloweenDimension") == true)
            or (Workspace:FindFirstChild("HalloweenDimension") ~= nil)
            or (#rawEggModels > 0)
    end)

    for _, egg in ipairs(rawEggModels) do
        if egg.Name:lower():find("holder") then
            continue
        end
        local canPick = egg:GetAttribute("HalloweenEggCanPickUp")
        if canPick == false then
            continue
        end
        local p = getHwEggPos(egg)
        if p then
            local eggName = getHwEggName(egg)
            if eggName:lower():find("holder") then
                continue
            end
            local d = charPos and (p - charPos).Magnitude or 99999
            local info = SPECIES_INFO[eggName:lower()] or (getSpeciesInfo and getSpeciesInfo(eggName:lower()))
            -- Exclude placeholder models named 'Egg' from PT2 or anywhere if they are holders/placeholders
            if (egg.Name:lower() == "egg" or eggName:lower() == "egg") and not info then
                continue
            end
            if eggName:lower() == "halloween egg" or eggName:lower() == "halloweenegg" or eggName:lower() == "halloween" then
                continue
            end

            local zone = egg:GetAttribute("Zone")
            local zoneName = zone and string.format("Zone %s", tostring(zone))
                or egg:GetAttribute("AreaId")
                or egg:GetAttribute("Biome")
                or "WorldEggs"

            local isCataloged = (info ~= nil and info.IsCataloged == true)
            local rarName = (isCataloged and info.Rarity) or egg:GetAttribute("Rarity") or "New Update"

            -- Rarity Filter:
            -- Eggs not tracked in group or listed in any of our catalog will be flagged as new update,
            -- so even if they do not match the rarity filter they should default to showing.
            local matchesRarity = false
            if selectedHwRarities and (selectedHwRarities["All"] or selectedHwRarities[rarName]) then
                matchesRarity = true
            end
            if not isCataloged then
                matchesRarity = true
            end

            if not matchesRarity then
                continue
            end

            local tagUpdate = not isCataloged and " • [New Update]" or ""
            local subLabel = string.format("%s • %s%s • %d studs", zoneName, rarName, tagUpdate, math.floor(d))

            table.insert(eggList, {
                Model     = egg,
                Name      = eggName,
                Position  = p,
                Distance  = d,
                SubLabel  = subLabel,
                Color     = getHwEggColor(egg, eggName),
                Zone      = tonumber(zone) or 99,
                Rank      = (isCataloged and info and info.Rank) or (RARITY_RANK[rarName] or 99),
                Uid       = egg:GetAttribute("HalloweenEggUid") or egg.Name,
            })
        end
    end

    -- Stable sort: Zone, then Highest Rarity Rank, then Name
    table.sort(eggList, function(a, b)
        if a.Zone ~= b.Zone then
            return a.Zone < b.Zone
        end
        if a.Rank ~= b.Rank then
            return a.Rank > b.Rank
        end
        if a.Name ~= b.Name then
            return a.Name < b.Name
        end
        return tostring(a.Uid) < tostring(b.Uid)
    end)

    local count = #eggList
    local deliv = LocalPlayer and LocalPlayer:GetAttribute("HalloweenDelivered") or 0
    if hwStatusLabel then
        if inHw or count > 0 then
            hwStatusLabel.Text = string.format("Status: In Dimension (%d Live) | Deliv: %s", count, tostring(deliv))
        else
            hwStatusLabel.Text = "Status: Outside Dimension (Portal Ready)"
        end
    end

    if count == 0 then
        if hwEmptyNotice then
            hwEmptyNotice.Visible = true
            local hasFilter = selectedHwRarities and not selectedHwRarities["All"]
            hwEmptyNotice.Text = (inHw or Workspace:FindFirstChild("HalloweenDimension"))
                and (hasFilter and "🎃 No Halloween eggs match current rarity filter.\nSelect [All] or adjust rarity filter." or "🎃 All Halloween eggs currently collected or respawning.\nWait for new spawn on pads.")
                or "🎃 No Halloween eggs detected in current world.\nEnter the Halloween Portal to view eggs."
        end
    else
        if hwEmptyNotice then hwEmptyNotice.Visible = false end
    end

    for idx, eggData in ipairs(eggList) do
        local poolItem = getOrCreateHwCard(idx)
        poolItem.data = eggData
        poolItem.nameLabel.Text = eggData.Name
        poolItem.subLabel.Text = eggData.SubLabel
        poolItem.accent.BackgroundColor3 = eggData.Color
        poolItem.card.Visible = true
    end

    for idx = count + 1, #hwCardPool do
        hwCardPool[idx].card.Visible = false
    end
end

-- ============================================================================
-- HALLOWEEN AUTO-PICKUP ENGINE (ISOLATED WORLD 2 MODULE)
-- ============================================================================

local hwPickupToken = 0

local function findBestHwPickupTarget()
    local char = LocalPlayer and LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local charPos  = root.Position
    local charLook = root.CFrame.LookVector
    local cam = Workspace.CurrentCamera
    local camPos  = cam and cam.CFrame.Position or charPos
    local camLook = cam and cam.CFrame.LookVector or charLook

    local function scoreHwTarget(pos, dist)
        local toTarget = (pos - charPos).Unit
        local charDot = charLook:Dot(toTarget)
        local camDir = ((pos - camPos).Magnitude > 0.01) and (pos - camPos).Unit or camLook
        local camDot = camLook:Dot(camDir)
        local score = (math.max(0, camDot) * 2.2 + math.max(0, charDot) * 1.2 + 0.3) / (dist + 0.5)
        if dist <= 6 then score = score + 3 end
        return score
    end

    local rawEggModels = {}
    local seen = {}
    local function addEgg(inst)
        if inst and not seen[inst] then
            seen[inst] = true
            table.insert(rawEggModels, inst)
        end
    end

    pcall(function()
        local hw = Workspace:FindFirstChild("HalloweenDimension")
        if not hw then hw = Workspace:FindFirstChild("HalloweenDimension", true) end
        local worldEggs = hw and (hw:FindFirstChild("WorldEggs") or hw:FindFirstChild("WorldEggs", true))
        if not worldEggs then worldEggs = Workspace:FindFirstChild("WorldEggs") end
        if worldEggs then
            for _, egg in ipairs(worldEggs:GetChildren()) do
                addEgg(egg)
            end
        end
        local tagged = CollectionService:GetTagged("HalloweenWorldEgg")
        if tagged then
            for _, egg in ipairs(tagged) do
                addEgg(egg)
            end
        end
    end)

    local bestTarget = nil
    local highestScore = -math.huge
    local maxPickupDist = 45

    for _, egg in ipairs(rawEggModels) do
        if egg.Name:lower():find("holder") then
            continue
        end
        if egg:GetAttribute("HalloweenEggCanPickUp") == false then
            continue
        end

        local p = getHwEggPos(egg)
        if p then
            local dist = (p - charPos).Magnitude
            if dist <= maxPickupDist then
                local score = scoreHwTarget(p, dist)
                if score > highestScore then
                    local eggName = getHwEggName(egg)
                    if not eggName:lower():find("holder") then
                        highestScore = score
                        local pr = egg:FindFirstChildWhichIsA("ProximityPrompt", true)
                        bestTarget = {
                            Model    = egg,
                            Name     = eggName,
                            Position = p,
                            Distance = dist,
                            Uid      = egg:GetAttribute("HalloweenEggUid") or egg.Name,
                            Prompt   = (pr and isCarryPrompt(pr)) and pr or nil
                        }
                    end
                end
            end
        end
    end

    if bestTarget and not bestTarget.Prompt then
        local sp = Workspace:FindFirstChild("SmartPromptPart")
        if sp then
            for _, pr in ipairs(sp:GetDescendants()) do
                if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                    bestTarget.Prompt = pr
                    break
                end
            end
        end
    end

    return bestTarget
end

local function executeHwPickupSpam(target)
    if not target then return end
    local uid = target.Uid

    -- 1. Dispatch Halloween Remote: RF/HalloweenDimension/AskCarryEgg (Parallel Burst)
    if uid and uid ~= "" then
        local net = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Networking")
        local hwRf = net and net:FindFirstChild("RF/HalloweenDimension/AskCarryEgg")
        if hwRf then
            for i = 1, 6 do
                task.spawn(function()
                    pcall(function() hwRf:InvokeServer(uid) end)
                end)
            end
        end
    end

    -- 2. Trigger ProximityPrompt ONLY if it is a validated carry prompt
    if target.Prompt and isCarryPrompt(target.Prompt) then
        triggerProximityPrompt(target.Prompt)
    end
    local sp = Workspace:FindFirstChild("SmartPromptPart")
    if sp then
        for _, pr in ipairs(sp:GetDescendants()) do
            if pr:IsA("ProximityPrompt") and isCarryPrompt(pr) then
                triggerProximityPrompt(pr)
                break
            end
        end
    end
end

startHalloweenAutoPickup = function()
    local holding, _ = isHoldingEgg()
    if holding or weAreCarrying then return end

    hwPickupToken = (hwPickupToken or 0) + 1
    local myTok = hwPickupToken

    task.spawn(function()
        local tStart = os.clock()
        local maxDuration = 1.2
        local hasSnapped = false

        while hwPickupToken == myTok and hwAutoPickEnabled and (os.clock() - tStart < maxDuration) do
            local curHolding, _ = isHoldingEgg()
            if curHolding or weAreCarrying then
                break -- Egg is secured! Stop burst immediately
            end

            local target = findBestHwPickupTarget()
            if target then
                -- Reach Assist: Instant snap to egg on first detection within 35 studs
                if not hasSnapped and target.Position then
                    local char = LocalPlayer and LocalPlayer.Character
                    local root = char and char:FindFirstChild("HumanoidRootPart")
                    local dist = root and (target.Position - root.Position).Magnitude or 999
                    if dist <= 3.5 then
                        hasSnapped = true
                    elseif dist <= 35 then
                        if applyReachAssist(target.Position) then
                            hasSnapped = true
                        end
                    end
                end

                executeHwPickupSpam(target)

                if target.Model and target.Model.Parent then
                    if target.Model:GetAttribute("HalloweenEggCanPickUp") == false then
                        break -- Server confirmed carry, stop immediately!
                    end
                end
            end

            task.wait(0.035)
        end
    end)
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
                local newSpeciesDiscovered = false
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
                            local rawName = r.DisplayName or r.AssetCategory or r.Name
                            if rawName and registerDynamicSpecies(rawName, r.AreaId, rId) then
                                newSpeciesDiscovered = true
                            end
                        end
                    end
                end

                if newSpeciesDiscovered then
                    table.sort(ALL_SPECIES_LIST, function(a, b)
                        return a.Name:lower() < b.Name:lower()
                    end)
                    if eggDropList and eggDropList.Visible and rebuildEggDropdownItems then
                        rebuildEggDropdownItems()
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
            local myUidStr = tostring(LocalPlayer and LocalPlayer.UserId or "")
            if payload.CarrierUserId and tostring(payload.CarrierUserId) == myUidStr and state == "Carried" then
                weAreCarrying = true
                carryUid = u
                updateActivityStatus()
                if autoReturnActive and autoReturnTargetUid == u then
                    startReturnTrip()
                end
            elseif (state == "Claimed" or state == "Dropped") and carryUid == u then
                weAreCarrying = false
                carryUid = nil
                updateActivityStatus()
                if autoReturnActive and autoReturnTargetUid == u then
                    if state == "Dropped" then
                        handleEggDropped(u, payload)
                    elseif state == "Claimed" then
                        handleEggDelivered(u)
                    end
                end
            elseif state == "Carried" and payload.CarrierUserId and tostring(payload.CarrierUserId) ~= myUidStr then
                if autoReturnActive and autoReturnTargetUid == u then
                    stopWalking()
                    autoReturnActive = false
                    autoReturnTargetUid = nil
                    returnTripInProgress = false
                    if activityStatusLabel then
                        activityStatusLabel.Text = "Status: Target egg taken by another player"
                        activityStatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
                    end
                end
            elseif state == "Dropped" and autoReturnActive and autoReturnTargetUid == u then
                handleEggDropped(u, payload)
            elseif state == "Claimed" and autoReturnActive and autoReturnTargetUid == u then
                handleEggDelivered(u)
            end

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

            local rawName = payload.DisplayName or payload.AssetCategory or payload.Name
            if rawName and registerDynamicSpecies(rawName, payload.AreaId, payload.RarityId) then
                table.sort(ALL_SPECIES_LIST, function(a, b)
                    return a.Name:lower() < b.Name:lower()
                end)
                if eggDropList and eggDropList.Visible and rebuildEggDropdownItems then
                    rebuildEggDropdownItems()
                end
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
                if carryUid == u then
                    weAreCarrying = false
                    carryUid = nil
                    updateActivityStatus()
                end
                if autoReturnActive and autoReturnTargetUid == u then
                    if returnTripInProgress then
                        handleEggDelivered(u)
                    else
                        stopWalking()
                        autoReturnActive = false
                        autoReturnTargetUid = nil
                        returnTripInProgress = false
                    end
                end
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
        pcall(updateActivityStatus)

        -- Auto-Return State Poller fallback (ensures drop recovery even if remote event dropped)
        if autoReturnActive and autoReturnTargetUid then
            local holdingTarget = (weAreCarrying and carryUid == autoReturnTargetUid)
            local holdingAny = isHoldingEgg() or weAreCarrying
            if returnTripInProgress and not holdingAny then
                handleEggDropped(autoReturnTargetUid)
            elseif not returnTripInProgress and holdingTarget then
                startReturnTrip()
            end
        end

        if listDirty then
            listDirty = false
            pcall(renderFarmableEggs)
        end

        if tabHalloween and tabHalloween.Visible and renderHalloweenEggs then
            pcall(renderHalloweenEggs)
        end

        -- Instant Recovery gentle safety fallback (0.3s throttled = 0 CPU cost)
        if RECOVERY_CONFIG and RECOVERY_CONFIG.Enabled and executeInstantRecovery then
            local char = LocalPlayer and LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and (hum.PlatformStand or hum.Sit) then
                executeInstantRecovery("LoopFallback")
            end
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
    closeCurrentDropdown()
    tabEggs.Visible = (tabName == "Eggs")
    tabUtility.Visible = (tabName == "Utility")
    tabHalloween.Visible = (tabName == "Halloween")

    tabBtnEggs.BackgroundColor3 = (tabName == "Eggs") and Color3.fromRGB(45, 100, 160) or Color3.fromRGB(35, 42, 60)
    tabBtnEggs.TextColor3 = (tabName == "Eggs") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)

    tabBtnUtility.BackgroundColor3 = (tabName == "Utility") and Color3.fromRGB(45, 100, 160) or Color3.fromRGB(35, 42, 60)
    tabBtnUtility.TextColor3 = (tabName == "Utility") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)

    tabBtnHalloween.BackgroundColor3 = (tabName == "Halloween") and Color3.fromRGB(200, 95, 25) or Color3.fromRGB(35, 42, 60)
    tabBtnHalloween.TextColor3 = (tabName == "Halloween") and Color3.new(1, 1, 1) or Color3.fromRGB(150, 170, 200)

    if tabName == "Eggs" then
        requestListUpdate()
    elseif tabName == "Halloween" then
        if renderHalloweenEggs then pcall(renderHalloweenEggs) end
    end
end

addConnection(tabBtnEggs.MouseButton1Click:Connect(function()
    switchTab("Eggs")
end))

addConnection(tabBtnUtility.MouseButton1Click:Connect(function()
    switchTab("Utility")
end))

addConnection(tabBtnHalloween.MouseButton1Click:Connect(function()
    switchTab("Halloween")
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
    velocityEnabled = false
    activeWalkToken = (activeWalkToken or 0) + 1
    pcall(function()
        local ch = LocalPlayer and LocalPlayer.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:Move(Vector3.zero, false)
            if savedWalkSpeed then hum.WalkSpeed = savedWalkSpeed end
        end
    end)
    disconnectAll()
    if recoveryConnections then
        for _, conn in ipairs(recoveryConnections) do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(recoveryConnections)
    end

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
