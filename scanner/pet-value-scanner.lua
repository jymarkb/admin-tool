--[[
    ===========================================================================
    STEAL AN EGG - PET VALUE & EARN/S DEEP SCANNER (v3.0 - UPVALUE 3 ENGINE)
    ===========================================================================
    Diagnostic tool to resolve the true Earn/s and Sell Price formula in
    "Steal an Egg", matching the "Sell Pets" GUI and ReplicatedStorage modules.

    Why this v3.0 update:
      1. DIRECT ACCESS TO UPVALUE 3:
         ProfileIncomePerSecond and SalePrice are not exported directly on
         EggScaling; they live inside EggRecords.SellPrice's Upvalue 3!
         v3.0 directly binds to Upvalue 3 (scalingFunctions).

      2. SCHEMA VALIDATION CRACKING:
         EggRecords:169 asserts SchemaValidation.SavedEgg.
         v3.0 inspects SchemaValidation.SavedEgg's constants, reconstructs
         valid SavedEgg and ItemData tables from Tool attributes, and calls
         EggRecords.ToAssetItemData, EggRecords.SellPrice, and ProfileIncomePerSecond.

      3. COMPREHENSIVE CALL SIGNATURE TESTING:
         Tests 12 distinct signatures across Upvalue 3 ProfileIncomePerSecond,
         SalePrice, FuseKernel.PriceFor, and EggRecords.SellPrice.

      4. INVENTORY-WIDE VALUE COMPUTATION:
         Once working signature is confirmed, computes Earn/s and Price for
         ALL 200+ pets in your Backpack, logging the complete inventory table.

      5. LIVE GUI DEEP AUDIT:
         Dumps SellPrompt structure, BackpackGui, and cross-references live cards.
    ===========================================================================
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    pcall(function()
        LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
    end)
    LocalPlayer = LocalPlayer or Players.LocalPlayer
end

-- ============================================================================
-- UI PARENT & CLEANUP
-- ============================================================================
local GUI_NAME = "PetValueScannerGui_v3"

local function getSafeUiParent()
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    local pg = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then return pg end
    return CoreGui
end

local uiParent = getSafeUiParent()

if _G.PetValueScanner_Cleanup then
    pcall(_G.PetValueScanner_Cleanup)
end
_G.PetValueScanner_Cleanup = nil

pcall(function()
    local old = uiParent:FindFirstChild(GUI_NAME) or CoreGui:FindFirstChild(GUI_NAME)
    if old then old:Destroy() end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg and pg:FindFirstChild(GUI_NAME) then pg[GUI_NAME]:Destroy() end
end)

-- ============================================================================
-- FORMATTING HELPERS
-- ============================================================================
local function formatStatNumber(val)
    if typeof(val) == "string" then return val end
    if typeof(val) ~= "number" then return "0" end
    local absVal = math.abs(val)
    if absVal >= 1e12 then
        return string.format("%.1fT", val / 1e12):gsub("%.0T", "T")
    elseif absVal >= 1e9 then
        return string.format("%.1fB", val / 1e9):gsub("%.0B", "B")
    elseif absVal >= 1e6 then
        return string.format("%.1fM", val / 1e6):gsub("%.0M", "M")
    elseif absVal >= 1e3 then
        return string.format("%.1fK", val / 1e3):gsub("%.0K", "K")
    elseif absVal >= 10 then
        return string.format("%.1f", val):gsub("%.0$", "")
    else
        return string.format("%.2f", val):gsub("%.00$", "")
    end
end

local function parseWeight(str)
    if not str or typeof(str) ~= "string" then return nil end
    local clean = str:gsub("[^%d%.]", "")
    return tonumber(clean)
end

local function parseCurrency(str)
    if not str or typeof(str) ~= "string" then return nil end
    local mult = 1
    local upper = str:upper()
    if upper:find("T") then mult = 1e12
    elseif upper:find("B") then mult = 1e9
    elseif upper:find("M") then mult = 1e6
    elseif upper:find("K") then mult = 1e3
    end
    local clean = str:gsub("[^%d%.]", "")
    local num = tonumber(clean)
    return num and (num * mult) or nil
end

local function safeDumpTable(tbl, maxDepth, depth, visited)
    depth = depth or 0
    maxDepth = maxDepth or 2
    visited = visited or {}
    if tbl == nil then return "nil" end
    local t = typeof(tbl)
    if t == "string" then return string.format("%q", tbl) end
    if t == "number" or t == "boolean" then return tostring(tbl) end
    if t == "Instance" then
        return string.format("<%s [%s]>", tbl.Name, tbl.ClassName)
    end
    if t == "function" then
        return "<function>"
    end
    if t == "table" then
        if depth >= maxDepth then return "{...}" end
        if visited[tbl] then return "<circular>" end
        visited[tbl] = true
        local parts = {}
        local count = 0
        local keys = {}
        for k in pairs(tbl) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            count = count + 1
            if count > 35 then
                table.insert(parts, string.rep("  ", depth + 1) .. string.format("... (%d more keys)", #keys - 35))
                break
            end
            local kStr = type(k) == "string" and string.format("[%q]", k) or string.format("[%s]", tostring(k))
            table.insert(parts, string.rep("  ", depth + 1) .. kStr .. " = " .. safeDumpTable(tbl[k], maxDepth, depth + 1, visited))
        end
        visited[tbl] = nil
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
    end
    return "<" .. t .. ">"
end

-- ============================================================================
-- MAIN SCANNER LOGIC
-- ============================================================================
local scanLogs = {}
local scannedPetsData = {}

local function log(fmt, ...)
    local str = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    table.insert(scanLogs, str)
    print("[PetValueScanner] " .. str)
end

local function runFullScan()
    table.clear(scanLogs)
    table.clear(scannedPetsData)

    log("================================================================================")
    log("PET VALUE & EARN/S DEEP SCANNER (v3.0 - UPVALUE 3 ENGINE)")
    log("Player: %s (UserId: %d)", LocalPlayer.Name, LocalPlayer.UserId)
    log("Time: %s", os.date("!%Y-%m-%d %H:%M:%SZ"))
    log("================================================================================")
    log("")

    -- Debug reflection helpers
    local getConsts = (typeof(debug) == "table" and typeof(debug.getconstants) == "function" and debug.getconstants)
        or (typeof(getconstants) == "function" and getconstants)
    local getUpvals = (typeof(debug) == "table" and typeof(debug.getupvalues) == "function" and debug.getupvalues)
        or (typeof(getupvalues) == "function" and getupvalues)
    local getInfo = (typeof(debug) == "table" and typeof(debug.getinfo) == "function" and debug.getinfo)
    local decompiler = (typeof(decompile) == "function" and decompile)
        or (typeof(disassemble) == "function" and disassemble)

    -- -------------------------------------------------------------------------
    -- 1. EXTRACT UPVALUE 3 & UPVALUE 4 FROM EGGRECORDS.SELLPRICE
    -- -------------------------------------------------------------------------
    log("================================================================================")
    log("SECTION 1: EGGRECORDS UPVALUES EXTRACTION (UPVALUE 3 SCALING ENGINE)")
    log("================================================================================")

    local eggRecordsMod = nil
    local fuseKernelMod = nil
    pcall(function() eggRecordsMod = require(ReplicatedStorage.Shared.Util.EggRecords) end)
    pcall(function() fuseKernelMod = require(ReplicatedStorage.Shared.Util.FuseKernel) end)

    local sellPriceUpvals = nil
    if eggRecordsMod and type(eggRecordsMod.SellPrice) == "function" and getUpvals then
        local okU, u = pcall(getUpvals, eggRecordsMod.SellPrice)
        if okU and type(u) == "table" then sellPriceUpvals = u end
    end

    local schemaValidation = sellPriceUpvals and type(sellPriceUpvals[1]) == "table" and sellPriceUpvals[1].SchemaValidation
    local scalingFunctions = sellPriceUpvals and type(sellPriceUpvals[3]) == "table" and sellPriceUpvals[3]
    local growthConstants  = sellPriceUpvals and type(sellPriceUpvals[4]) == "table" and sellPriceUpvals[4]

    if scalingFunctions then
        log(">>> [SUCCESS] Extracted Upvalue 3 Scaling Functions from EggRecords.SellPrice! <<<")
        local fnKeys = {}
        for k, v in pairs(scalingFunctions) do
            table.insert(fnKeys, string.format("%s (%s)", tostring(k), typeof(v)))
        end
        table.sort(fnKeys)
        log("  Upvalue 3 Keys: %s", table.concat(fnKeys, ", "))

        -- 1a. Introspect ProfileIncomePerSecond
        if type(scalingFunctions.ProfileIncomePerSecond) == "function" then
            log("\n--- [INSPECT] Upvalue 3: ProfileIncomePerSecond ---")
            if getInfo then
                local okI, info = pcall(getInfo, scalingFunctions.ProfileIncomePerSecond)
                if okI and info then log("  debug.getinfo: %s", safeDumpTable(info, 1)) end
            end
            if getConsts then
                local okC, consts = pcall(getConsts, scalingFunctions.ProfileIncomePerSecond)
                if okC and consts then log("  constants: %s", safeDumpTable(consts, 1)) end
            end
            if getUpvals then
                local okU, upv = pcall(getUpvals, scalingFunctions.ProfileIncomePerSecond)
                if okU and upv then log("  upvalues: %s", safeDumpTable(upv, 2)) end
            end
            if decompiler then
                local okD, dSrc = pcall(decompiler, scalingFunctions.ProfileIncomePerSecond)
                if okD and type(dSrc) == "string" and #dSrc > 10 then
                    log("  decompile(ProfileIncomePerSecond): \n%s", dSrc)
                end
            end
        else
            log("  ⚠️ ProfileIncomePerSecond is missing from Upvalue 3!")
        end

        -- 1b. Introspect SalePrice
        if type(scalingFunctions.SalePrice) == "function" then
            log("\n--- [INSPECT] Upvalue 3: SalePrice ---")
            if getInfo then
                local okI, info = pcall(getInfo, scalingFunctions.SalePrice)
                if okI and info then log("  debug.getinfo: %s", safeDumpTable(info, 1)) end
            end
            if getConsts then
                local okC, consts = pcall(getConsts, scalingFunctions.SalePrice)
                if okC and consts then log("  constants: %s", safeDumpTable(consts, 1)) end
            end
            if getUpvals then
                local okU, upv = pcall(getUpvals, scalingFunctions.SalePrice)
                if okU and upv then log("  upvalues: %s", safeDumpTable(upv, 2)) end
            end
            if decompiler then
                local okD, dSrc = pcall(decompiler, scalingFunctions.SalePrice)
                if okD and type(dSrc) == "string" and #dSrc > 10 then
                    log("  decompile(SalePrice): \n%s", dSrc)
                end
            end
        end

        -- 1c. Introspect WeightKg
        if type(scalingFunctions.WeightKg) == "function" and getConsts then
            local okC, consts = pcall(getConsts, scalingFunctions.WeightKg)
            if okC and consts then log("  WeightKg constants: %s", safeDumpTable(consts, 1)) end
        end
    else
        log("  ⚠️ Failed to extract Upvalue 3 from EggRecords.SellPrice")
    end

    -- 1d. Introspect SchemaValidation.SavedEgg
    if schemaValidation and type(schemaValidation.SavedEgg) == "function" then
        log("\n--- [INSPECT] SchemaValidation.SavedEgg ---")
        if getInfo then
            local okI, info = pcall(getInfo, schemaValidation.SavedEgg)
            if okI and info then log("  debug.getinfo: %s", safeDumpTable(info, 1)) end
        end
        if getConsts then
            local okC, consts = pcall(getConsts, schemaValidation.SavedEgg)
            if okC and consts then log("  constants: %s", safeDumpTable(consts, 1)) end
        end
        if getUpvals then
            local okU, upv = pcall(getUpvals, schemaValidation.SavedEgg)
            if okU and upv then log("  upvalues: %s", safeDumpTable(upv, 2)) end
        end
        if decompiler then
            local okD, dSrc = pcall(decompiler, schemaValidation.SavedEgg)
            if okD and type(dSrc) == "string" and #dSrc > 10 then
                log("  decompile(SavedEgg): \n%s", dSrc)
            end
        end
    end

    -- 1e. Introspect FuseKernel.PriceFor
    if fuseKernelMod and type(fuseKernelMod.PriceFor) == "function" then
        log("\n--- [INSPECT] FuseKernel.PriceFor ---")
        if getInfo then
            local okI, info = pcall(getInfo, fuseKernelMod.PriceFor)
            if okI and info then log("  debug.getinfo: %s", safeDumpTable(info, 1)) end
        end
        if getConsts then
            local okC, consts = pcall(getConsts, fuseKernelMod.PriceFor)
            if okC and consts then log("  constants: %s", safeDumpTable(consts, 1)) end
        end
    end

    -- 1f. Load species configs from ReplicatedStorage.Data.Assets.Configs
    local configsFolder = ReplicatedStorage:FindFirstChild("Data")
        and ReplicatedStorage.Data:FindFirstChild("Assets")
        and ReplicatedStorage.Data.Assets:FindFirstChild("Configs")
    local speciesConfigs = {}
    local confCount = 0
    if configsFolder then
        for _, child in ipairs(configsFolder:GetChildren()) do
            if child:IsA("ModuleScript") then
                local okC, conf = pcall(require, child)
                if okC and type(conf) == "table" then
                    speciesConfigs[child.Name] = conf
                    confCount = confCount + 1
                end
            end
        end
    end
    log("Loaded %d species config modules from ReplicatedStorage.", confCount)
    log("")

    -- -------------------------------------------------------------------------
    -- 2. OWNED INVENTORY COMPREHENSIVE SCAN (BACKPACK & CHARACTER)
    -- -------------------------------------------------------------------------
    log("================================================================================")
    log("SECTION 2: OWNED PET TOOLS SCAN (Backpack & Character)")
    log("================================================================================")

    local toolContainers = {
        { Container = LocalPlayer:FindFirstChild("Backpack"), Name = "Backpack" },
        { Container = LocalPlayer.Character, Name = "Character" },
    }

    local ownedPets = {}

    for _, entry in ipairs(toolContainers) do
        local container = entry.Container
        if container then
            for _, item in ipairs(container:GetChildren()) do
                if item:IsA("Tool") then
                    local attrs = item:GetAttributes() or {}
                    local itemType = attrs.ItemType or ""
                    local isGear = attrs.GearName ~= nil or itemType == "Gear" or attrs.IsBat == true
                    local isEgg = string.find(item.Name:lower(), "egg") ~= nil or attrs.Category == "Egg" or attrs.ItemType == "Egg"

                    if not isGear and not isEgg then
                        local uid = attrs.UID or attrs.Uid or attrs.Id or attrs.UUID or item.Name
                        local rawWeight = tonumber(attrs.Weight) or 0
                        local scale = tonumber(attrs.Scale) or 1
                        local calcWeight = math.round(rawWeight * (scale * scale))
                        local mut = attrs.BaseMutation or attrs.Mutations
                        if not mut or mut == "" then mut = "Normal" end

                        table.insert(ownedPets, {
                            ToolInstance = item,
                            ToolName = item.Name,
                            Container = entry.Name,
                            Uid = tostring(uid),
                            DisplayName = attrs.DisplayName or item.Name,
                            Category = attrs.Category or attrs.DisplayName or item.Name,
                            Species = attrs.DisplayName or attrs.Category or item.Name,
                            Rarity = attrs.Rarity or "Unknown",
                            Mutation = mut,
                            RawWeight = rawWeight,
                            Scale = scale,
                            CalcDisplayWeight = calcWeight,
                            Attributes = attrs,
                        })
                    end
                end
            end
        end
    end

    log("Found %d owned pet tools in inventory.", #ownedPets)
    for i, p in ipairs(ownedPets) do
        if i <= 20 then
            log("  [%d] '%s' (Cat: %s, Mut: %s): RawW=%.2f, Scale=%.3f -> CalcW=%d Kg | UID=%s",
                i, p.DisplayName, p.Category, p.Mutation, p.RawWeight, p.Scale, p.CalcDisplayWeight, p.Uid)
        end
    end
    if #ownedPets > 20 then
        log("  ... and %d more tools.", #ownedPets - 20)
    end
    log("")

    -- -------------------------------------------------------------------------
    -- 3. SYNTHESIZE SAVED EGG & ITEM DATA HELPERS
    -- -------------------------------------------------------------------------
    local function makeSavedEgg(pet)
        local attrs = pet.Attributes or {}
        local mut = (pet.Mutation and pet.Mutation ~= "Normal" and pet.Mutation ~= "") and pet.Mutation or nil
        local mutArr = mut and { mut } or {}
        return {
            Category = pet.Category or attrs.Category or pet.Species,
            Scale = pet.Scale or tonumber(attrs.Scale) or 1,
            EyeColor = tostring(attrs.EyeColor or "ffffff"),
            ColorSeed = tonumber(attrs.ColorSeed) or 0,
            ColorIndex = tonumber(attrs.ColorIndex) or 1,
            Mutations = mutArr,
            BaseMutation = mut or "",
            Gender = tostring(attrs.Gender or "Male"),
            Personality = tostring(attrs.Personality or "Default"),
            IsStolenDNA = (attrs.IsStolenDNA == true),
            CreatorTemporary = (attrs.CreatorTemporary == true),
        }
    end

    local function makeItemData(pet)
        local attrs = pet.Attributes or {}
        local scale = pet.Scale or tonumber(attrs.Scale) or 1
        local rawWeight = pet.RawWeight or tonumber(attrs.Weight) or 0
        local cat = pet.Category or attrs.Category or pet.Species
        local mut = (pet.Mutation and pet.Mutation ~= "Normal" and pet.Mutation ~= "") and pet.Mutation or nil
        local mutArr = mut and { mut } or {}
        return {
            AssetCategory = cat,
            Category = cat,
            AssetScale = scale,
            Scale = scale,
            Weight = rawWeight,
            AssetWeight = rawWeight,
            AssetEyeColor = tostring(attrs.EyeColor or "ffffff"),
            EyeColor = tostring(attrs.EyeColor or "ffffff"),
            AssetColorSeed = tonumber(attrs.ColorSeed) or 0,
            ColorSeed = tonumber(attrs.ColorSeed) or 0,
            AssetColorIndex = tonumber(attrs.ColorIndex) or 1,
            ColorIndex = tonumber(attrs.ColorIndex) or 1,
            Mutations = mutArr,
            BaseMutation = mut,
            AssetGender = tostring(attrs.Gender or "Male"),
            Gender = tostring(attrs.Gender or "Male"),
            AssetPersonality = tostring(attrs.Personality or "Default"),
            Personality = tostring(attrs.Personality or "Default"),
        }
    end

    -- -------------------------------------------------------------------------
    -- 4. SYSTEMATIC FUNCTION CALL SIGNATURE TESTING
    -- -------------------------------------------------------------------------
    log("================================================================================")
    log("SECTION 3: SYSTEMATIC LIVE FUNCTION BENCHMARKS & SIGNATURE DISCOVERY")
    log("================================================================================")

    local samplePet = ownedPets[1]
    local workingIncomeFn = nil
    local workingIncomeSigName = nil
    local workingIncomeCaller = nil

    local workingSalePriceFn = nil
    local workingSalePriceCaller = nil

    if samplePet and scalingFunctions then
        log("Testing signatures on sample pet: '%s' (Cat: '%s', Scale: %.3f, Mut: '%s', CalcW: %d Kg)",
            samplePet.DisplayName, samplePet.Category, samplePet.Scale, samplePet.Mutation, samplePet.CalcDisplayWeight)

        local savedEgg = makeSavedEgg(samplePet)
        local itemData = makeItemData(samplePet)

        -- 4a. Test SchemaValidation.SavedEgg
        if schemaValidation and type(schemaValidation.SavedEgg) == "function" then
            local okS, resS = pcall(schemaValidation.SavedEgg, savedEgg)
            log("  [TEST] SchemaValidation.SavedEgg(synthesizedSavedEgg): ok=%s, result=%s", tostring(okS), tostring(resS))
            if not okS or resS == false then
                log("    Synthesized SavedEgg content: %s", safeDumpTable(savedEgg, 2))
            end
        end

        -- 4b. Test EggRecords.ToAssetItemData
        local liveItemData = nil
        if eggRecordsMod and type(eggRecordsMod.ToAssetItemData) == "function" then
            local okD, resD = pcall(eggRecordsMod.ToAssetItemData, savedEgg)
            log("  [TEST] EggRecords.ToAssetItemData(savedEgg): ok=%s", tostring(okD))
            if okD and type(resD) == "table" then
                liveItemData = resD
                log("    ✓ Returned Live ItemData: %s", safeDumpTable(resD, 2))
            else
                log("    Error: %s", tostring(resD))
            end
        end

        -- 4c. Test Upvalue 3 ProfileIncomePerSecond
        if type(scalingFunctions.ProfileIncomePerSecond) == "function" then
            local pipFn = scalingFunctions.ProfileIncomePerSecond
            log("\n--- Testing Upvalue 3: ProfileIncomePerSecond Signatures ---")

            local candidateSigs = {
                {
                    Name = "Sig 1: Live itemData from ToAssetItemData",
                    Call = function() return pipFn(liveItemData) end,
                    Valid = (liveItemData ~= nil)
                },
                {
                    Name = "Sig 2: Synthesized itemData",
                    Call = function() return pipFn(itemData) end,
                    Valid = true
                },
                {
                    Name = "Sig 3: Synthesized savedEgg",
                    Call = function() return pipFn(savedEgg) end,
                    Valid = true
                },
                {
                    Name = "Sig 4: Tool Attributes table",
                    Call = function() return pipFn(samplePet.Attributes) end,
                    Valid = true
                },
                {
                    Name = "Sig 5: Tool Instance",
                    Call = function() return pipFn(samplePet.ToolInstance) end,
                    Valid = (samplePet.ToolInstance ~= nil)
                },
                {
                    Name = "Sig 6: (Category, Scale, Mutations)",
                    Call = function() return pipFn(samplePet.Category, samplePet.Scale, samplePet.Mutation) end,
                    Valid = true
                },
                {
                    Name = "Sig 7: (Category, RawWeight, Scale, Mutations)",
                    Call = function() return pipFn(samplePet.Category, samplePet.RawWeight, samplePet.Scale, samplePet.Mutation) end,
                    Valid = true
                },
                {
                    Name = "Sig 8: (Category, Scale)",
                    Call = function() return pipFn(samplePet.Category, samplePet.Scale) end,
                    Valid = true
                },
                {
                    Name = "Sig 9: (Category)",
                    Call = function() return pipFn(samplePet.Category) end,
                    Valid = true
                },
                {
                    Name = "Sig 10: { AssetCategory = cat, AssetScale = scale }",
                    Call = function() return pipFn({ AssetCategory = samplePet.Category, AssetScale = samplePet.Scale, Mutations = samplePet.Mutation }) end,
                    Valid = true
                },
            }

            for _, sig in ipairs(candidateSigs) do
                if sig.Valid then
                    local ok, res = pcall(sig.Call)
                    if ok and typeof(res) == "number" then
                        log("  ✓ [SUCCESS] %s -> Earn/s = %s ($%s/s)", sig.Name, tostring(res), formatStatNumber(res))
                        if not workingIncomeCaller then
                            workingIncomeFn = pipFn
                            workingIncomeSigName = sig.Name
                            workingIncomeCaller = sig.Call
                        end
                    else
                        log("  ✗ [FAIL]    %s -> ok=%s, res=%s", sig.Name, tostring(ok), tostring(res))
                    end
                end
            end
        end

        -- 4c2. Test AssetItems Upvalue 2: RatePerSecond
        local liveRatePerSecondFn = nil
        if type(scalingFunctions.SalePrice) == "function" and getUpvals then
            local spUpv = getUpvals(scalingFunctions.SalePrice)
            if spUpv and type(spUpv[2]) == "table" and type(spUpv[2].RatePerSecond) == "function" then
                liveRatePerSecondFn = spUpv[2].RatePerSecond
            end
        end

        if liveRatePerSecondFn then
            log("\n--- Testing AssetItems Upvalue 2: RatePerSecond Signatures ---")
            local rateSigs = {
                {
                    Name = "RateSig 1: Synthesized itemData (Mutations array)",
                    Call = function() return liveRatePerSecondFn(itemData) end,
                    Valid = true
                },
                {
                    Name = "RateSig 2: Live itemData from ToAssetItemData",
                    Call = function() return liveRatePerSecondFn(liveItemData) end,
                    Valid = (liveItemData ~= nil)
                },
            }
            for _, sig in ipairs(rateSigs) do
                if sig.Valid then
                    local ok, res = pcall(sig.Call)
                    if ok and typeof(res) == "number" then
                        log("  ✓ [SUCCESS] %s -> RatePerSecond = %s ($%s/s)", sig.Name, tostring(res), formatStatNumber(res))
                        if not workingIncomeCaller then
                            workingIncomeFn = liveRatePerSecondFn
                            workingIncomeSigName = sig.Name
                            workingIncomeCaller = sig.Call
                        end
                    else
                        log("  ✗ [FAIL]    %s -> ok=%s, res=%s", sig.Name, tostring(ok), tostring(res))
                    end
                end
            end
        end

        -- 4d. Test Upvalue 3 SalePrice
        if type(scalingFunctions.SalePrice) == "function" then
            local spFn = scalingFunctions.SalePrice
            log("\n--- Testing Upvalue 3: SalePrice Signatures ---")

            local saleSigs = {
                {
                    Name = "SaleSig 1: Live itemData",
                    Call = function() return spFn(liveItemData) end,
                    Valid = (liveItemData ~= nil)
                },
                {
                    Name = "SaleSig 2: Synthesized itemData",
                    Call = function() return spFn(itemData) end,
                    Valid = true
                },
                {
                    Name = "SaleSig 3: Synthesized savedEgg",
                    Call = function() return spFn(savedEgg) end,
                    Valid = true
                },
                {
                    Name = "SaleSig 4: (Category, Scale, Mutations)",
                    Call = function() return spFn(samplePet.Category, samplePet.Scale, samplePet.Mutation) end,
                    Valid = true
                },
            }

            for _, sig in ipairs(saleSigs) do
                if sig.Valid then
                    local ok, res = pcall(sig.Call)
                    if ok and typeof(res) == "number" then
                        log("  ✓ [SUCCESS] %s -> SalePrice = %s (💵 $%s)", sig.Name, tostring(res), formatStatNumber(res))
                        if not workingSalePriceCaller then
                            workingSalePriceFn = spFn
                            workingSalePriceCaller = sig.Call
                        end
                    else
                        log("  ✗ [FAIL]    %s -> ok=%s, res=%s", sig.Name, tostring(ok), tostring(res))
                    end
                end
            end
        end

        -- 4e. Test EggRecords.SellPrice
        if eggRecordsMod and type(eggRecordsMod.SellPrice) == "function" then
            log("\n--- Testing EggRecords.SellPrice Signatures ---")
            local okS1, resS1 = pcall(function() return eggRecordsMod.SellPrice(savedEgg) end)
            log("  SellPrice(savedEgg): ok=%s, result=%s (💵 $%s)", tostring(okS1), tostring(resS1), formatStatNumber(resS1))
            if itemData then
                local okS2, resS2 = pcall(function() return eggRecordsMod.SellPrice(itemData) end)
                log("  SellPrice(itemData): ok=%s, result=%s", tostring(okS2), tostring(resS2))
            end
        end

        -- 4f. Test FuseKernel.PriceFor
        if fuseKernelMod and type(fuseKernelMod.PriceFor) == "function" then
            log("\n--- Testing FuseKernel.PriceFor Signatures ---")
            local okF1, resF1 = pcall(function() return fuseKernelMod.PriceFor(samplePet.ToolInstance) end)
            log("  PriceFor(tool):     ok=%s, result=%s", tostring(okF1), tostring(resF1))
            local okF2, resF2 = pcall(function() return fuseKernelMod.PriceFor(savedEgg) end)
            log("  PriceFor(savedEgg): ok=%s, result=%s", tostring(okF2), tostring(resF2))
            local okF3, resF3 = pcall(function() return fuseKernelMod.PriceFor(itemData) end)
            log("  PriceFor(itemData): ok=%s, result=%s", tostring(okF3), tostring(resF3))
        end
    end
    log("")

    -- -------------------------------------------------------------------------
    -- 5. COMPUTE EARN/S & SELL PRICE FOR ALL OWNED PETS
    -- -------------------------------------------------------------------------
    log("================================================================================")
    log("SECTION 4: FULL INVENTORY EARN/S & SELL PRICE CALCULATION")
    log("================================================================================")

    local function computePetIncomeAndPrice(pet)
        local rate = nil
        local price = nil

        -- Strategy A: Upvalue 3 ProfileIncomePerSecond
        if workingIncomeFn then
            pcall(function()
                local sEgg = makeSavedEgg(pet)
                local iData = makeItemData(pet)
                local ok, r = pcall(workingIncomeFn, iData)
                if ok and typeof(r) == "number" then rate = r end
                if not rate then
                    local ok2, r2 = pcall(workingIncomeFn, sEgg)
                    if ok2 and typeof(r2) == "number" then rate = r2 end
                end
                if not rate then
                    local ok3, r3 = pcall(workingIncomeFn, pet.Category, pet.Scale, pet.Mutation)
                    if ok3 and typeof(r3) == "number" then rate = r3 end
                end
            end)
        end

        -- Strategy B: Upvalue 3 SalePrice
        if workingSalePriceFn then
            pcall(function()
                local iData = makeItemData(pet)
                local ok, p = pcall(workingSalePriceFn, iData)
                if ok and typeof(p) == "number" then price = p end
                if not price then
                    local ok2, p2 = pcall(workingSalePriceFn, pet.Category, pet.Scale, pet.Mutation)
                    if ok2 and typeof(p2) == "number" then price = p2 end
                end
            end)
        end

        -- Strategy C: SellPrice = SalePrice * 0.8
        -- And Sell Price = Rate * 100
        if rate and not price then
            price = rate * 100
        elseif price and not rate then
            rate = price / 100
        end

        -- Strategy D: Empirical Species Base EarningRate * GrowthMultiplier * MutationMultiplier
        if not rate then
            local conf = speciesConfigs[pet.Category] or speciesConfigs[pet.DisplayName] or speciesConfigs[pet.Species]
            if conf and tonumber(conf.EarningRate) then
                local base = tonumber(conf.EarningRate)
                local scale = pet.Scale or 1
                local growthMult = 1
                if scale <= 2.0 then
                    growthMult = scale
                elseif scale <= 6.0 then
                    growthMult = scale ^ 1.389
                else
                    growthMult = 4.6 * (scale ^ 0.72)
                end
                local mutMult = 1
                local mLower = (pet.Mutation or ""):lower()
                if mLower:find("rainbow") then mutMult = 2.0
                elseif mLower:find("golden") or mLower:find("gold") then mutMult = 1.25
                elseif mLower:find("scramble") then mutMult = 1.5
                elseif mLower:find("silver") then mutMult = 1.1
                end
                rate = math.round(base * growthMult * mutMult)
                price = rate * 100
            end
        end

        return rate, price
    end

    if #ownedPets > 0 then
        log("%-4s | %-20s | %-12s | %-8s | %-12s | %-12s | %-12s",
            "#", "Species", "Category", "Mut", "Weight(Kg)", "Earn/s", "Sell Price")
        log(string.rep("-", 95))

        for idx, pet in ipairs(ownedPets) do
            local rate, price = computePetIncomeAndPrice(pet)
            local rateStr = rate and ("+$" .. formatStatNumber(rate) .. "/s") or "--/s"
            local priceStr = price and ("💵 $" .. formatStatNumber(price)) or "--"

            if idx <= 35 or idx % 10 == 0 then
                log("%-4d | %-20s | %-12s | %-8s | %-12s | %-12s | %-12s",
                    idx, pet.DisplayName:sub(1, 20), pet.Category:sub(1, 12), pet.Mutation:sub(1, 8),
                    tostring(pet.CalcDisplayWeight) .. " Kg", rateStr, priceStr)
            end

            table.insert(scannedPetsData, {
                Index = idx,
                Species = pet.DisplayName,
                Category = pet.Category,
                Mutation = pet.Mutation,
                Scale = pet.Scale,
                RawWeight = pet.RawWeight,
                DisplayWeight = pet.CalcDisplayWeight,
                EarnPerSec = rate,
                EarnFormatted = rateStr,
                SellPrice = price,
                PriceFormatted = priceStr,
                Uid = pet.Uid,
            })
        end
        log(string.rep("-", 95))
        log("Computed values for all %d owned pets!", #ownedPets)
    end
    log("")

    -- -------------------------------------------------------------------------
    -- 6. INSPECT LIVE PLAYERGUI CARDS IF OPEN
    -- -------------------------------------------------------------------------
    log("================================================================================")
    log("SECTION 5: LIVE PLAYERGUI SELLPROMPT & BACKPACK AUDIT")
    log("================================================================================")

    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local sellPrompt = pg and pg:FindFirstChild("SellPrompt")
    if sellPrompt then
        log("SellPrompt ScreenGui: Enabled=%s, Visible=%s",
            tostring(sellPrompt.Enabled), tostring(sellPrompt:IsA("ScreenGui") and sellPrompt.Enabled))
        local countLabels = 0
        for _, desc in ipairs(sellPrompt:GetDescendants()) do
            if desc:IsA("TextLabel") and desc.Text ~= "" then
                countLabels = countLabels + 1
                if countLabels <= 15 then
                    log("  Label [%d] %s: %q", countLabels, desc.Name, desc.Text)
                end
            end
        end
        if countLabels > 15 then log("  ... and %d more text labels in SellPrompt", countLabels - 15) end
    else
        log("SellPrompt ScreenGui not found in PlayerGui.")
    end
    log("")

    -- -------------------------------------------------------------------------
    -- 7. SYNTHESIZED READY-TO-USE LUAU CODE FOR EGGGOTOUIV10
    -- -------------------------------------------------------------------------
    log("================================================================================")
    log("SECTION 6: READY-TO-USE CODE SNIPPET FOR EGGGOTOUIV10")
    log("================================================================================")

    if workingIncomeFn then
        log([[
-- AUTHORITATIVE FORMULA USING EGGRECORDS UPVALUE 3 ENGINE:
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EggRecords = require(ReplicatedStorage.Shared.Util.EggRecords)

local getUpvals = (typeof(debug) == "table" and typeof(debug.getupvalues) == "function" and debug.getupvalues)
    or (typeof(getupvalues) == "function" and getupvalues)
local scalingUpvals = getUpvals and select(2, pcall(getUpvals, EggRecords.SellPrice))
local internalScaling = scalingUpvals and scalingUpvals[3]

local function getPetEarnPerSecond(tool)
    if not tool then return 0 end
    local attrs = tool:GetAttributes() or {}
    local scale = tonumber(attrs.Scale) or 1
    local cat = attrs.Category or attrs.DisplayName or tool.Name
    local mut = attrs.BaseMutation or attrs.Mutations or ""

    if internalScaling and type(internalScaling.ProfileIncomePerSecond) == "function" then
        local itemData = {
            AssetCategory = cat,
            Category = cat,
            AssetScale = scale,
            Scale = scale,
            Mutations = mut,
            BaseMutation = mut,
        }
        local ok, rate = pcall(internalScaling.ProfileIncomePerSecond, itemData)
        if ok and typeof(rate) == "number" then return rate end
    end
    return 0
end
]])
    else
        log([[
-- PIECEWISE FORMULA DEDUCED FROM SCALE_BANDS:
-- STEEP_GROWTH_POWER = 1.389, FLAT_GROWTH_MAX_SCALE = 2, TAIL_GROWTH_POWER = 0.72
local function getPetGrowthMultiplier(scale)
    if scale <= 2.0 then
        return scale
    elseif scale <= 6.0 then
        return scale ^ 1.389
    else
        return 4.6 * (scale ^ 0.72)
    end
end
]])
    end

    log("================================================================================")
    log("SCAN COMPLETE. Click [COPY REPORT] to copy output!")
    log("================================================================================")

    return table.concat(scanLogs, "\n")
end

-- ============================================================================
-- INTERACTIVE SCANNER GUI
-- ============================================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = GUI_NAME
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = uiParent

local W, H = 640, 560
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(60, 120, 230)
mainStroke.Thickness = 1.5

-- Top Draggable Bar
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 38)
topBar.BackgroundColor3 = Color3.fromRGB(26, 32, 48)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🐾 PET VALUE & EARN/S DEEP SCANNER v3.0 (UPVALUE 3 ENGINE)"
titleLbl.TextColor3 = Color3.fromRGB(235, 245, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 12
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -34, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(190, 45, 45)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- Dragging
do
    local dragging, dragStart, startPos
    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    topBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            if dragging then
                local delta = input.Position - dragStart
                main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end
    end)
end

-- Control Buttons
local BTN_Y = 44
local BTN_H = 30
local BTN_W = 140
local GAP = 8

local function makeBtn(txt, xOff, bgCol)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, BTN_W, 0, BTN_H)
    b.Position = UDim2.new(0, xOff, 0, BTN_Y)
    b.BackgroundColor3 = bgCol
    b.Text = txt
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 11
    b.Parent = main
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local scanBtn = makeBtn("🔄 RUN SCAN", 12, Color3.fromRGB(35, 140, 75))
local copyBtn = makeBtn("📋 COPY REPORT", 12 + BTN_W + GAP, Color3.fromRGB(45, 105, 180))
local saveBtn = makeBtn("💾 SAVE FILE", 12 + (BTN_W + GAP)*2, Color3.fromRGB(95, 65, 150))
local jsonBtn = makeBtn("📦 EXPORT JSON", 12 + (BTN_W + GAP)*3, Color3.fromRGB(150, 85, 35))

-- Console Log Box
local BOX_Y = BTN_Y + BTN_H + 10
local BOX_H = H - BOX_Y - 12
local boxFrame = Instance.new("Frame")
boxFrame.Size = UDim2.new(1, -24, 0, BOX_H)
boxFrame.Position = UDim2.new(0, 12, 0, BOX_Y)
boxFrame.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
boxFrame.BorderSizePixel = 0
boxFrame.Parent = main
Instance.new("UICorner", boxFrame).CornerRadius = UDim.new(0, 8)
local boxStroke = Instance.new("UIStroke", boxFrame)
boxStroke.Color = Color3.fromRGB(42, 54, 78)
boxStroke.Thickness = 1

local textBox = Instance.new("TextBox")
textBox.Size = UDim2.new(1, -12, 1, -12)
textBox.Position = UDim2.new(0, 6, 0, 6)
textBox.BackgroundTransparency = 1
textBox.MultiLine = true
textBox.ClearTextOnFocus = false
textBox.TextEditable = false
textBox.TextXAlignment = Enum.TextXAlignment.Left
textBox.TextYAlignment = Enum.TextYAlignment.Top
textBox.Font = Enum.Font.Code
textBox.TextSize = 10
textBox.TextColor3 = Color3.fromRGB(200, 235, 255)
textBox.Text = "-- Initializing scan... --"
textBox.Parent = boxFrame

local lastReport = ""

local function executeAndRender()
    scanBtn.Text = "⏳ SCANNING..."
    task.defer(function()
        local report = runFullScan()
        lastReport = report
        textBox.Text = report
        scanBtn.Text = "🔄 RUN SCAN"
    end)
end

scanBtn.MouseButton1Click:Connect(executeAndRender)

copyBtn.MouseButton1Click:Connect(function()
    if lastReport ~= "" and typeof(setclipboard) == "function" then
        setclipboard(lastReport)
        copyBtn.Text = "✓ COPIED!"
        task.delay(1.5, function() copyBtn.Text = "📋 COPY REPORT" end)
    else
        copyBtn.Text = "Select All in Box"
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    if lastReport ~= "" and typeof(writefile) == "function" then
        pcall(function() writefile("pet-value-scan-v3.txt", lastReport) end)
        saveBtn.Text = "✓ SAVED!"
        task.delay(1.5, function() saveBtn.Text = "💾 SAVE FILE" end)
    else
        saveBtn.Text = "No writefile"
    end
end)

jsonBtn.MouseButton1Click:Connect(function()
    if #scannedPetsData > 0 then
        local ok, json = pcall(function() return HttpService:JSONEncode(scannedPetsData) end)
        if ok and json then
            if typeof(setclipboard) == "function" then
                setclipboard(json)
                jsonBtn.Text = "✓ JSON COPIED!"
                task.delay(1.5, function() jsonBtn.Text = "📦 EXPORT JSON" end)
            end
            if typeof(writefile) == "function" then
                pcall(function() writefile("pet-value-data-v3.json", json) end)
            end
        end
    end
end)

closeBtn.MouseButton1Click:Connect(function()
    screenGui:Destroy()
end)

_G.PetValueScanner_Cleanup = function()
    pcall(function() screenGui:Destroy() end)
end

-- Run once automatically on launch
task.defer(executeAndRender)
print("[PetValueScanner] Loaded and active.")
