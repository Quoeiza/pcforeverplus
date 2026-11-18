-- ProfitCrafter: recipes to get
--   Patterns, plans, recipes, formulas and schematics you don't know yet, for professions you have:
--   where to get them (vendor, trainer, drop, quest, dungeon, reputation...), whether you can get
--   them now or within 10 levels (greyed), what they'd earn, and a trip to go and get them.
--   Gathered from:
--     * the profession window (newer clients list recipes you haven't learned, with where they come from)
--     * trainers you visit (what they teach, at what skill and level, for how much)
--     * vendors you (or other ProfitCrafter users) visit: recipe items in their stock, with the spot
--       they stand on, so the route can take you right there

local ADDON, ns = ...
local PC = ns.PC

local ToLearn = {}
PC.ToLearn = ToLearn

-- a required material slot (the same test Core.lua uses when it reads your recipes)
local BASIC_REAGENT = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1

ToLearn.SOON_LEVELS = 10   -- "soon": within this many character levels
ToLearn.SOON_SKILL = 40    -- ...and within this much profession skill
ToLearn.ALL_DB = true      -- WoW Forever: list every classic recipe for your professions, seen or not
ToLearn.AUTO_TIPS = true   -- the holiday and trainer pop-ups on their own (login, skill-ups, level-ups)

-- recipe item subclasses -> profession
ToLearn.SUBCLASS = { [1] = "Leatherworking", [2] = "Tailoring", [3] = "Engineering", [4] = "Blacksmithing", [5] = "Cooking",
    [6] = "Alchemy", [7] = "First Aid", [8] = "Enchanting", [9] = "Fishing", [10] = "Jewelcrafting", [11] = "Inscription" }
-- what a recipe item's name starts with
local PREFIXES = { "Pattern", "Plans", "Recipe", "Formula", "Schematic", "Manual", "Design", "Technique", "Book" }

-- "Pattern: Red Linen Robe" -> "red linen robe"
-- (asked thousands of times for every list: each name is worked out once and kept)
local normCache, normN = {}, 0
function ToLearn:Norm(name)
    name = name or ""
    local n = normCache[name]
    if n then return n end
    n = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    for _, p in ipairs(PREFIXES) do
        local rest = n:match("^" .. p .. ":%s*(.+)$")
        if rest then n = rest break end
    end
    n = n:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if normN >= 20000 then wipe(normCache); normN = 0 end
    normCache[name], normN = n, normN + 1
    return n
end

-- Corrections to the generated recipe data, from WoW Forever sources (Icy Veins' Forever cooking guide)
local DB_FIX = {
    -- taught by Henry Stern in Razorfen Downs, not by the city cooking trainers
    ["Cooking:goldthorn tea"] = { 175, 0, nil, "Trainer", nil, { { "Henry Stern", "Razorfen Downs", nil, nil, "" } } },
    -- the reward for Sharing the Knowledge, from Calandrath in Cenarion Hold (not a trainer)
    ["Cooking:smoked desert dumplings"] = { 285, 0, nil, "Quest", nil, { { "Sharing the Knowledge", "Silithus", 51.9, 39.2, "", { giver = "Calandrath" } } } },
}
for k, v in pairs(DB_FIX) do if PC.RecipeDB then PC.RecipeDB[k] = v end end

local function Data()
    local cdb = PC.cdb
    cdb.toLearn = cdb.toLearn or {}
    local d = cdb.toLearn
    d.unlearned = d.unlearned or {}  -- [recipeID] = { name, prof, output, reagents, qty, src = {type, where, zone, cost, text} }
    d.trainer = d.trainer or {}      -- [prof] = { [norm] = { name, skill, level, cost, trainer = place key } }
    d.taught = d.taught or {}        -- [trainer name, lower case] = { [norm] = true }: everything its window listed
    d.trip = d.trip or {}            -- { key, ... } in order
    d.skip = d.skip or {}            -- [key] = true: hidden by you
    return d
end
ToLearn.Data = Data

---------------------------------------------------------------------------
-- Learning what's out there
---------------------------------------------------------------------------
-- The game's "where it comes from" text: "Vendor: Name\nZone: Elwynn Forest\nCost: 50s"
function ToLearn:ParseSource(text)
    if type(text) ~= "string" or text == "" then return nil end
    local clean = text:gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", "\n")
    local src = { text = clean }
    for line in (clean .. "\n"):gmatch("(.-)\n") do
        local k, v = line:match("^%s*([^:]+):%s*(.-)%s*$")
        if k and v then
            local key = k:lower()
            if not src.type then
                if key:find("vendor") then src.type = "Vendor"
                elseif key:find("trainer") then src.type = "Trainer"
                elseif key:find("quest") then src.type = "Quest"
                elseif key:find("drop") then src.type = "Drop"
                elseif key:find("reputation") or key:find("faction") then src.type = "Reputation"
                elseif key:find("discover") then src.type = "Discovery"
                elseif key:find("event") or key:find("holiday") then src.type = "World event"
                end
                if src.type and v ~= "" then src.where = v end
            end
            if key == "zone" or key:find("location") then src.zone = v
            elseif key == "cost" or key:find("price") then src.cost = v
            elseif key:find("requires") or key:find("reputation") then src.req = v
            elseif key:find("dungeon") or key:find("instance") or key:find("raid") then src.type = "Dungeon"; src.where = src.where or v end
        elseif line:lower():find("world drop") then
            src.type = src.type or "Drop"; src.where = src.where or "World drop"
        elseif line:lower():find("discover") then
            src.type = src.type or "Discovery"
        end
    end
    src.type = src.type or "Other"
    return src
end

-- From the profession window (newer clients): a recipe you haven't learned
function ToLearn:NoteUnlearned(recipeID, info, prof)
    local T = C_TradeSkillUI
    local d = Data()
    local e = d.unlearned[recipeID] or {}
    e.name, e.prof = info.name, prof
    if T.GetRecipeSourceText then
        local ok, text = pcall(T.GetRecipeSourceText, recipeID)
        if ok then e.src = self:ParseSource(text) or e.src end
    end
    if not e.output and T.GetRecipeSchematic then
        local ok, s = pcall(T.GetRecipeSchematic, recipeID, false)
        if ok and s then
            e.output = s.outputItemID
            e.qty = ((s.quantityMin or 1) + (s.quantityMax or s.quantityMin or 1)) / 2
            local rg = {}
            for _, slot in ipairs(s.reagentSlotSchematics or {}) do
                if slot.required == true or (slot.required ~= false and slot.reagentType == BASIC_REAGENT) then
                    local first = slot.reagents and slot.reagents[1]
                    if first and first.itemID then rg[#rg + 1] = { id = first.itemID, n = slot.quantityRequired or 1 } end
                end
            end
            e.reagents = rg
        end
    end
    e.seen = time()
    d.unlearned[recipeID] = e
end

-- A trainer's list: everything it teaches (including what you can't learn yet), skill, level, cost
function ToLearn:ReadTrainer(trainerKey, npcName)
    if not GetNumTrainerServices or not GetTrainerServiceInfo then return end
    -- (WoW Forever gives no skill line for a recipe: the trainer's own profession then)
    local trainerProf = PC.Travel and PC.Travel.TrainerProf and PC.Travel.TrainerProf() or nil
    local taught = {}
    -- show everything for a moment (some filters hide what you can't learn yet), then put them back
    local filters = {}
    if GetTrainerServiceTypeFilter and SetTrainerServiceTypeFilter then
        for _, f in ipairs({ "available", "unavailable", "used" }) do
            local ok, on = pcall(GetTrainerServiceTypeFilter, f)
            filters[f] = ok and on
            pcall(SetTrainerServiceTypeFilter, f, 1)
        end
    end
    local d = Data()
    local n = GetNumTrainerServices() or 0
    for i = 1, n do
        local ok, name, _, kind = pcall(GetTrainerServiceInfo, i)
        if ok and name and kind ~= "header" then
            local line = GetTrainerServiceSkillLine and select(2, pcall(GetTrainerServiceSkillLine, i)) or nil
            local prof = (type(line) == "string" and line ~= "") and line or trainerProf
            if prof then
                local skill = GetTrainerServiceSkillReq and select(3, pcall(GetTrainerServiceSkillReq, i)) or nil
                local level = GetTrainerServiceLevelReq and select(2, pcall(GetTrainerServiceLevelReq, i)) or nil
                local cost = GetTrainerServiceCost and select(2, pcall(GetTrainerServiceCost, i)) or nil
                d.trainer[prof] = d.trainer[prof] or {}
                local key = self:Norm(name)
                local t = d.trainer[prof][key] or {}
                t.name, t.skill, t.level, t.cost, t.trainer = name, tonumber(skill), tonumber(level), tonumber(cost), trainerKey
                t.used = kind == "used" or nil
                d.trainer[prof][key] = t
                taught[key] = true
            end
        end
    end
    if npcName and next(taught) then d.taught[npcName:lower()] = taught; self:Changed() end
    if SetTrainerServiceTypeFilter then
        for f, on in pairs(filters) do pcall(SetTrainerServiceTypeFilter, f, on and 1 or 0) end
    end
end

---------------------------------------------------------------------------
-- Recipe items: what profession, what skill and level they need, already known?
---------------------------------------------------------------------------
local scanTip
local function TipLines(itemID)
    local out = {}
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then
        local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
        if ok and data and data.lines then
            for _, l in ipairs(data.lines) do if l.leftText then out[#out + 1] = l.leftText end end
            return out
        end
    end
    if not scanTip and CreateFrame then
        local ok, t = pcall(CreateFrame, "GameTooltip", "ProfitCrafterScanTip", nil, "GameTooltipTemplate")
        if ok then scanTip = t end
    end
    if scanTip and scanTip.SetItemByID then
        scanTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
        pcall(scanTip.SetItemByID, scanTip, itemID)
        for i = 1, (scanTip.NumLines and scanTip:NumLines() or 0) do
            local fs = _G["ProfitCrafterScanTipTextLeft" .. i]
            local t = fs and fs.GetText and fs:GetText()
            if t then out[#out + 1] = t end
        end
        scanTip:Hide()
    end
    return out
end

-- { prof, skill, level, known, name } for a recipe item, or nil (not a recipe / not loaded yet)
-- Every item every vendor sells is asked about each time the Learn list is made: the answers are kept.
-- Not a recipe: kept for good. A recipe: kept until something is learned (only learning changes "Already
-- known"). fresh = read its tooltip again (buying, and checking the trip for recipes learned meanwhile).
ToLearn.riNot, ToLearn.riAll = {}, {}
function ToLearn:RecipeItem(itemID, fresh)
    if itemID == nil then return self:RecipeItemRaw(itemID) end
    if self.riNot[itemID] then return nil end
    local c = not fresh and self.riAll[itemID]
    if c then return c end
    local r, final = self:RecipeItemRaw(itemID)
    if r then self.riAll[itemID] = r elseif final then self.riNot[itemID] = true end
    return r
end
-- something was learned: the recipes are read again (what isn't a recipe stays known)
function ToLearn:ForgetRecipeItems() self.riAll = {} end

function ToLearn:RecipeItemRaw(itemID)
    -- not a recipe at all: the game says so without loading the item (no load asked for)
    local inst = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if inst and itemID then
        local ok, _, _, _, _, _, cls = pcall(inst, itemID)
        if ok and cls and cls ~= 9 then return nil, true end
    end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return nil end
    local name, _, _, _, minLevel, _, _, _, _, _, _, classID, subclassID = getInfo(itemID)
    if not name then
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
        return nil
    end
    if classID ~= 9 then return nil, true end
    local r = { name = name, level = (minLevel and minLevel > 1) and minLevel or nil, prof = self.SUBCLASS[subclassID] }
    local known = ITEM_SPELL_KNOWN or "Already known"
    for _, line in ipairs(TipLines(itemID)) do
        local p, n = line:match("^Requires (.-) %((%d+)%)")
        if p and n then r.prof = r.prof or p; r.skill = tonumber(n) end
        if line == known then r.known = true end
    end
    if r.prof == "Book" then r.prof = nil end
    return r, true
end

---------------------------------------------------------------------------
-- Everything to get, for your professions
---------------------------------------------------------------------------
local function KnownNames()
    local k = {}
    -- learned just now (the game said so), before the profession window has been opened again
    for n in pairs(PC.cdb.learnedNames or {}) do k[n] = true end
    for _, r in pairs(PC.cdb.recipes or {}) do if r.name then k[r.name:lower()] = true end end
    for _, list in pairs(PC.cdb.skipped or {}) do for _, s in ipairs(list) do if s.name then k[s.name:lower()] = true end end end
    return k
end

-- A spell you know by name (Disenchant, Smelting...: taught by trainers, but not crafts the profession window lists)
local function SpellKnown(name)
    if not name or name == "" then return false end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, name)
        if ok and type(info) == "table" and info.spellID then
            if IsPlayerSpell then local ok2, yes = pcall(IsPlayerSpell, info.spellID); if ok2 then return yes and true or false end end
            return true
        end
        return false
    end
    if GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, name)
        return ok and n ~= nil
    end
    return false
end
ToLearn.SpellKnown = SpellKnown

local function MyProfs()
    local out = {}
    for _, pr in pairs(PC.cdb.professions or {}) do if pr.name then out[pr.name] = pr end end
    if out.Mining then out.Smelting = out.Mining end
    return out
end

-- Profit per craft for a recipe we know the parts of: the way it's sold, the cost, AH Profit, V Profit
local function ProfitOf(e)
    if not e.output or not e.reagents or #e.reagents == 0 or not PC.Evaluate then return nil end
    local r = { name = e.name, output = e.output, qty = e.qty or 1, reagents = e.reagents }
    local ok, ev = pcall(PC.Evaluate, PC, r, "low")
    if ok and ev then return ev.profit, ev.cost, ev.ahProfit, ev.vendorProfit end
    return nil
end

-- The list: { key, name, prof, skill, level, source, where, zone, cost, costText, place, itemID, profit, status }
-- status: "now", "soon" (within 10 levels / the next stretch of skill), "later"
-- The list is costly (hundreds of recipes, each looked up in the recipe data): kept for a few seconds,
-- and worked out again straight away when something changes (the trip, a skip, something learned)
ToLearn.LIST_KEEP = 5
function ToLearn:Changed() self.listCache = nil end
function ToLearn:List()
    local now = GetTime and GetTime() or 0
    -- anything that changes the list: gold, level, skill, what you know, the trip
    local nRec, ranks = 0, 0
    for _ in pairs(PC.cdb.recipes or {}) do nRec = nRec + 1 end
    for _, pr in pairs(PC.cdb.professions or {}) do ranks = ranks + (pr.rank or 0) end
    local d = Data()
    local sig = table.concat({ GetMoney and GetMoney() or 0, UnitLevel and UnitLevel("player") or 0, nRec, ranks, #d.trip }, ":")
    local c = self.listCache
    if c and c.sig == sig and now - c.t < self.LIST_KEEP then return c.list end
    -- places by name, once per list (not a search of every place for every recipe)
    self.placeByName = {}
    if PC.Places then
        for _, p in pairs(PC.Places:All()) do
            local n = (p.name or ""):lower()
            if n ~= "" and p.map and not self.placeByName[n] then self.placeByName[n] = p end
        end
    end
    -- (prices, bags and the plan can't change while it's made: what each recipe's profit asks for, like the
    -- cheapest way to make dust, is worked out once for the whole list, inside a refresh or not)
    local list = PC:WithMemo(self.ListRaw, self)
    self.listCache = { t = now, list = list, sig = sig }
    return list
end

-- Where you are, worked out once for a whole list (it was asked of the game for every recipe):
-- { map, zone, mine = your faction's letter }
function ToLearn:Where()
    local at = {}
    if PC.Places and PC.Places.Here then
        local m, _, _, z = PC.Places:Here()
        at.map, at.zone = m, z
    end
    at.mine = UnitFactionGroup and ({ Alliance = "A", Horde = "H" })[UnitFactionGroup("player") or ""] or nil
    return at
end

-- The recipe data's keys split once ("Tailoring:runecloth belt" -> profession, name), in the data's own order
local dbKeys
local function DBKeys()
    if not dbKeys then
        dbKeys = {}
        for key in pairs(PC.RecipeDB or {}) do
            local prof, norm = key:match("^([^:]+):(.+)$")
            if prof then dbKeys[#dbKeys + 1] = { key, prof, norm } end
        end
    end
    return dbKeys
end

function ToLearn:ListRaw()
    self.trainerCache = {}
    local d = Data()
    local profs = MyProfs()
    local known = KnownNames()
    local level = UnitLevel and UnitLevel("player") or 1
    local at = self:Where()
    local byKey, out = {}, {}
    local function add(prof, name, fields)
        if not prof or not profs[prof] then return end
        local norm = self:Norm(name)
        local key = prof .. ":" .. norm
        if known[norm] or d.skip[key] then return end
        -- a spell you already have (Disenchant)
        if not byKey[key] and fields.source == "Trainer" and SpellKnown(name) then known[norm] = true return end
        local e = byKey[key]
        if not e then
            e = { key = key, name = name, prof = prof }
            byKey[key] = e
            out[#out + 1] = e
        end
        for k, v in pairs(fields) do if e[k] == nil then e[k] = v end end
    end
    -- 1) vendors we know (and what they stock): exact spots
    if PC.Places then
        for _, p in ipairs(PC.Places:OfKind("vendor")) do
            if p.stock then
                for id in pairs(p.stock) do
                    local ri = self:RecipeItem(id)
                    if ri and not ri.known and ri.prof then
                        add(ri.prof, ri.name, { itemID = id, skill = ri.skill, level = ri.level, source = "Vendor",
                            where = p.name, zone = p.zone, place = p, cost = PC.db.vendor and PC:VendorCost(id) or nil })
                    end
                end
            end
        end
    end
    -- 2) trainers: what they teach (and at what skill); yours first, then lists other players shared
    -- (every city's trainers teach the same: a trainer of that profession where you are now beats
    -- the one the list was read from, so you're never sent to another city to train)
    local hereMap, hereZone = at.map, at.zone
    local function isHere(p) return p and ((hereMap and p.map == hereMap) or (hereZone and hereZone ~= "" and p.zone == hereZone)) end
    local hereTrainer = {}
    local function trainerHere(prof)
        if hereTrainer[prof] == nil then
            hereTrainer[prof] = false
            if (hereMap or hereZone) and PC.Places then
                for _, p in ipairs(PC.Places:OfKind("trainer")) do
                    if ToLearn.TeachesProf(p, prof) and isHere(p) then hereTrainer[prof] = p break end
                end
            end
        end
        return hereTrainer[prof] or nil
    end
    local function trainers(all)
        for prof, list in pairs(all) do
            for _, t in pairs(list) do
                if not t.used then
                    local place = t.trainer and PC.Places and PC.Places:Table()[t.trainer]
                    local near = trainerHere(prof)
                    if near and not isHere(place) and self:MayTeach(near.name, self:Norm(t.name)) then place = near end
                    add(prof, t.name, { skill = t.skill, level = t.level, source = "Trainer", cost = t.cost,
                        where = place and place.name or "Your trainer", zone = place and place.zone, place = place })
                end
            end
        end
    end
    trainers(d.trainer)
    if PC.Finds then trainers(PC.Finds:Trainers()) end
    -- 3) the profession window's own list of what you haven't learned (newer clients): the game's own
    --    "where it comes from" first
    for recipeID, u in pairs(d.unlearned) do
        local src = u.src or {}
        if src.type and src.type ~= "Other" then
            local place
            if src.type == "Vendor" and src.where and PC.Places then place = PC.Places:Nearest("vendor", nil, src.where) end
            if src.type == "Trainer" then place = self:NearestTrainer(u.prof, u.name and self:Norm(u.name)) end
            add(u.prof, u.name, { recipeID = recipeID, source = src.type, where = src.where, zone = src.zone or (place and place.zone),
                costText = src.cost, req = src.req, place = place, output = u.output, reagents = u.reagents, qty = u.qty, srcText = src.text })
        end
    end
    -- 4) what players found (drops, quests, treasures, new recipes): the spot someone stood on
    if PC.Finds then
        for _, f in pairs(PC.Finds:Table()) do
            if f.prof and f.name and profs[f.prof] then
                local sp = PC.Finds:BestSpot(f)
                if sp then
                    add(f.prof, f.name, { source = sp.source, where = sp.where, zone = sp.zone, skill = f.skill, level = f.level,
                        cost = sp.cost, itemID = f.item, place = PC.Finds:Place(sp), srcText = PC.Finds:Text(f, sp), found = true })
                end
            end
        end
    end
    -- 5) the recipe data: Retail (by recipe) or classic (by name, WoW Forever)
    for recipeID, u in pairs(d.unlearned) do
        local src = u.src or {}
        local f = PC.RecipeDBRetail and self:FromRetailDB(recipeID, src.where) or (u.prof and u.name and self:FromDB(u.prof, u.name, at))
        if f then
            add(u.prof, u.name, { recipeID = recipeID, source = f.source, where = f.where, zone = f.zone, skill = f.skill,
                level = f.level, cost = f.cost, costText = f.costText, costx = f.costx, req = f.req, rep = f.rep, place = f.place, itemID = f.itemID, output = u.output,
                reagents = u.reagents, qty = u.qty, srcText = f.text, seasonOff = f.seasonOff })
        end
        add(u.prof, u.name, { recipeID = recipeID, source = src.type or "Other", where = src.where, zone = src.zone,
            costText = src.cost, req = src.req, output = u.output, reagents = u.reagents, qty = u.qty, srcText = src.text })
    end
    -- 6) WoW Forever: every classic recipe for your professions, seen or not (the game doesn't list them)
    if self.ALL_DB and PC.RecipeDB and not PC.RecipeDBRetail then
        for _, k in ipairs(DBKeys()) do
            local key, prof, norm = k[1], k[2], k[3]
            if profs[prof] and not known[norm] and not byKey[key] and not d.skip[key] then
                local f = self:FromDB(prof, norm, at)
                if f then
                    add(prof, self:Title(norm), { source = f.source, where = f.where, zone = f.zone, skill = f.skill, level = f.level,
                        cost = f.cost, req = f.req, rep = f.rep, place = f.place, itemID = f.itemID, srcText = f.text, seasonOff = f.seasonOff })
                end
            end
        end
    end
    -- profit, status, can you afford it
    local money = GetMoney and GetMoney() or 0
    local unlearnedByName -- [prof][name] = the first unlearned entry with that name (looked through once, not per row)
    for _, e in ipairs(out) do
        if not e.cost and e.costText then e.cost = self:ParseMoney(e.costText) end
        e.cantAfford = e.cost and e.cost > money or nil
        -- the unlearned list knows what it makes: borrow that for a vendor/trainer row with the same name
        if not e.output then
            if not unlearnedByName then
                unlearnedByName = {}
                for _, u in pairs(d.unlearned) do
                    if u.prof ~= nil then
                        local t = unlearnedByName[u.prof]
                        if not t then t = {}; unlearnedByName[u.prof] = t end
                        local n = self:Norm(u.name)
                        if t[n] == nil then t[n] = u end
                    end
                end
            end
            local u = unlearnedByName[e.prof] and unlearnedByName[e.prof][self:Norm(e.name)]
            if u then e.output, e.reagents, e.qty = u.output, u.reagents, u.qty end
        end
        -- (matsCost: what one craft's materials cost; e.cost stays what the recipe itself costs to buy)
        e.profit, e.matsCost, e.ahProfit, e.vendorProfit = ProfitOf(e)
        -- nobody known to sell, teach or drop it and no price for it: too little known for a profit
        if not (e.where and e.where ~= "") and not e.cost and not e.costText and not e.currency then
            e.profit, e.matsCost, e.ahProfit, e.vendorProfit, e.noSource = nil, nil, nil, nil, true
        end
        -- an AH price it's worked out from that's more than OLD_PRICE old (not seen in recent scans): marked ~
        e.ahAge, e.vAge = nil, nil
        if e.ahProfit or e.vendorProfit then
            local mats = 0
            for _, rg in ipairs(e.reagents or {}) do
                local id, _, src = PC:ReagentFor(rg, "low")
                if src == "AH" then mats = math.max(mats, PC:PriceAge(id) or 0) end
            end
            local ah = math.max(mats, PC:PriceAge(e.output) or 0)
            if e.ahProfit and ah > PC.OLD_PRICE then e.ahAge = ah end
            if e.vendorProfit and mats > PC.OLD_PRICE then e.vAge = mats end
        end
        -- bought with something other than gold (badges, tokens, marks...): how much, and do you have it
        local need = self:SpecialCost(e)
        if need then
            e.currency, e.short = need, false
            local parts = {}
            for _, c in ipairs(need) do
                if c.have < c.n then e.short = true end
                parts[#parts + 1] = ("%d %s"):format(c.n, c.name or "?") .. (c.have < c.n and (" |cffff5555(you have %d)|r"):format(c.have) or "")
            end
            e.costText = table.concat(parts, ", ")
            if e.cost == 0 then e.cost = nil end
            e.cantAfford = (e.cost and e.cost > money) or nil
        end
        -- a holiday's recipe: which one
        if PC.RecipeEvents then
            self.eventOf = self.eventOf or self:EventIndex()
            local ev = self.eventOf[e.key] or (e.recipeID and self.eventOf[e.recipeID])
            if ev then e.event = (PC.EventNames and PC.EventNames[ev]) or "a holiday"; e.eventID = ev end
        end
        local rank = profs[e.prof] and profs[e.prof].rank or 0
        local skillOK = not e.skill or e.skill <= rank
        local levelOK = not e.level or e.level <= level
        if e.rep and not self:RepMet(e.rep) then
            -- a reputation vendor you can't buy from yet: not a Get now (nor a trip stop)
            e.status, e.repShort = "later", true
        elseif e.short then e.status = "currency" -- not enough of what it costs: only on the Special currency list
        elseif skillOK and levelOK then e.status = "now"
        elseif (not e.level or e.level <= level + self.SOON_LEVELS) and (not e.skill or e.skill <= rank + self.SOON_SKILL) then e.status = "soon"
        else e.status = "later" end
        e.why = (e.repShort and e.req and ("needs " .. e.req))
            or (not skillOK and e.skill and ("needs %s %d (you're %d)"):format(e.prof, e.skill, rank))
            or (not levelOK and e.level and ("needs level %d (you're %d)"):format(e.level, level)) or nil
    end
    -- now first, then soon; best profit first; then lowest skill
    local rankOf = { now = 0, soon = 1, currency = 2, later = 3 }
    table.sort(out, function(a, b)
        if a.status ~= b.status then return rankOf[a.status] < rankOf[b.status] end
        local pa, pb = a.profit or -1e12, b.profit or -1e12
        if pa ~= pb then return pa > pb end
        if (a.skill or 0) ~= (b.skill or 0) then return (a.skill or 0) < (b.skill or 0) end
        return a.name < b.name
    end)
    return out
end

---------------------------------------------------------------------------
-- Classic recipe data (WoW Forever): where a recipe comes from when the game doesn't say
--   PC.RecipeDB["Tailoring:runecloth belt"] = { skill, level, recipe item, source, cost, { spots } }
--   a spot: { name, zone, x, y, faction ("A", "H", "AH" or "" for both), { chance, limited, lvl } }
---------------------------------------------------------------------------
-- The game's map number for a zone name ("Stranglethorn Vale" -> its map), worked out once from the world map
function ToLearn:ZoneMap(zone)
    if not zone or zone == "" then return nil end
    if self.zoneMaps then return self.zoneMaps[zone:lower()] end
    if not C_Map or not C_Map.GetMapChildrenInfo or not C_Map.GetMapInfo then return nil end
    if not self.zoneMaps then
        local maps = {}
        local m = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
        local top, guard = m, 0
        while top and guard < 10 do
            guard = guard + 1
            local info = C_Map.GetMapInfo(top)
            if not info or not info.parentMapID or info.parentMapID == 0 then break end
            top = info.parentMapID
        end
        if not top then return nil end
        local ok, kids = pcall(C_Map.GetMapChildrenInfo, top, nil, true)
        local n = 0
        for _, k in ipairs(ok and kids or {}) do
            local key = (k.name or ""):lower()
            -- a zone or city wins over a dungeon or floor with the same name
            if key ~= "" and (not maps[key] or k.mapType == 3) then maps[key] = k.mapID; n = n + 1 end
        end
        if n == 0 then return nil end
        self.zoneMaps = maps
    end
    return self.zoneMaps[zone:lower()]
end

-- Could this trainer teach it? Not when you've read its list and the recipe isn't on it.
function ToLearn:MayTeach(trainerName, norm)
    local t = norm and trainerName and Data().taught[trainerName:lower()]
    return not t or t[norm] == true
end

-- The nearest trainer of a profession you (or other players) have been to, one that may teach `norm`
function ToLearn:NearestTrainer(prof, norm)
    if not PC.Places or not prof then return nil end
    -- (asked for hundreds of recipes at once: once per profession while the list is worked out)
    local c = self.trainerCache
    local p
    if c and c[prof] ~= nil then p = c[prof] or nil
    else
        local best, _, other = PC.Places:Nearest("trainer", nil, nil, function(q) return ToLearn.TeachesProf(q, prof) end)
        p = best or other
        if c then c[prof] = p or false end
    end
    if not p or self:MayTeach(p.name, norm) then return p end
    -- its list doesn't have it: the nearest one that may
    local best, _, other = PC.Places:Nearest("trainer", nil, nil, function(q)
        return ToLearn.TeachesProf(q, prof) and ToLearn:MayTeach(q.name, norm)
    end)
    return best or other
end

-- A trainer of this profession whose list you've read, without the recipe on it (`at`: only where you are)
function ToLearn:Lacks(prof, norm, at)
    if not PC.Places then return false end
    for _, p in ipairs(PC.Places:OfKind("trainer")) do
        if ToLearn.TeachesProf(p, prof) and not self:MayTeach(p.name, norm)
            and (not at or (at.map and p.map == at.map) or (at.zone and p.zone == at.zone)) then
            return true
        end
    end
    return false
end

-- Does the data list a trainer in a capital city? (a recipe listed only outside the cities, such as
-- Henry Stern's in Razorfen Downs or a master trainer's, is taught only there)
function ToLearn:CitySpot(spots)
    local cities = PC.Travel and PC.Travel.CITIES
    for _, sp in ipairs(spots) do
        local map = sp[2] and sp[2] ~= "" and self:ZoneMap(sp[2])
        if map and cities and cities[map] then return true end
    end
    return false
end

-- "runecloth belt" -> "Runecloth Belt" (small words stay small: "Elixir of the Sages")
local SMALL = { ["of"] = true, ["the"] = true, ["and"] = true, ["a"] = true, ["an"] = true, ["to"] = true, ["in"] = true, ["on"] = true }
function ToLearn:Title(norm)
    local i = 0
    return ((norm or ""):gsub("(%S+)", function(w)
        i = i + 1
        if i > 1 and SMALL[w] then return w end
        return w:sub(1, 1):upper() .. w:sub(2)
    end))
end

-- A spot from the data as a place the map pin and the Task Button can go to (your own visit wins)
function ToLearn:DBPlace(spot, kind)
    local name, zone, x, y = spot[1], spot[2], spot[3], spot[4]
    if name ~= "" then
        local p = self.placeByName and self.placeByName[name:lower()]
        if p then return p end
    end
    if not x or not y then return nil end
    local map = self:ZoneMap(zone)
    if not map then return nil end
    return { kind = kind or "vendor", name = name, zone = zone, map = map, x = x / 100, y = y / 100, db = true, confirmed = true }
end

-- Holiday vendors: only there while their event runs (by the calendar date)
ToLearn.EVENTS = {
    winterveil = { name = "Feast of Winter Veil", when = "Dec 15 to Jan 2", from = { 12, 15 }, to = { 1, 2 } },
}
function ToLearn:EventOn(key)
    local ev = self.EVENTS[key]
    if not ev then return true end
    local t = date and date("*t") or nil
    if type(t) ~= "table" or not t.month or not t.day then return false end
    local md, a, b = t.month * 100 + t.day, ev.from[1] * 100 + ev.from[2], ev.to[1] * 100 + ev.to[2]
    if a <= b then return md >= a and md <= b end
    return md >= a or md <= b -- runs over the new year
end

-- Which profession a trainer teaches, by name, from the data (trainers learned without it)
function ToLearn:TrainerProfOf(name)
    if not name then return nil end
    if not self.profByTrainer then
        local m = {}
        for key, r in pairs(PC.RecipeDB or {}) do
            if r[4] == "Trainer" then
                local prof = key:match("^(.-):")
                for _, sp in ipairs(r[6] or {}) do
                    if sp[1] and sp[1] ~= "" and prof then m[sp[1]:lower()] = prof end
                end
            end
        end
        self.profByTrainer = m
    end
    return self.profByTrainer[name:lower()]
end
local function TeachesProf(p, prof)
    return p and (p.prof == prof or p.t == prof or ToLearn:TrainerProfOf(p.name) == prof)
end
ToLearn.TeachesProf = TeachesProf

-- Every trainer of a profession the data knows (your faction's), once per profession: any of them
-- teaches what the others do, so the one in the city you're in can stand in for the one listed
function ToLearn:TrainerSpots(prof)
    self.trainerSpots = self.trainerSpots or {}
    if self.trainerSpots[prof] then return self.trainerSpots[prof] end
    local out, seen = {}, {}
    local mine = UnitFactionGroup and ({ Alliance = "A", Horde = "H" })[UnitFactionGroup("player") or ""] or nil
    local pre = prof .. ":"
    for key, r in pairs(PC.RecipeDB or {}) do
        if r[4] == "Trainer" and key:sub(1, #pre) == pre then
            for _, sp in ipairs(r[6] or {}) do
                local fac = sp[5] or ""
                if (fac == "" or not mine or fac:find(mine, 1, true)) and sp[2] and sp[2] ~= "" then
                    local k = (sp[1] or "") .. "|" .. sp[2]
                    if not seen[k] then seen[k] = true; out[#out + 1] = sp end
                end
            end
        end
    end
    self.trainerSpots[prof] = out
    return out
end

-- Where the data says a recipe comes from: { source, where, zone, skill, level, cost, place, itemID, text } or nil
function ToLearn:FromDB(prof, name, at)
    local db = PC.RecipeDB
    local r = db and db[prof .. ":" .. self:Norm(name)]
    if not r then return nil end
    at = at or self:Where()
    local skill, level, item, kind, cost, spots = r[1], r[2], r[3], r[4], r[5], r[6] or {}
    local mine = at.mine
    -- spots your faction can use (a neutral one counts for both), and holiday vendors only during the holiday
    local ok, offSeason = {}, nil
    for _, sp in ipairs(spots) do
        local fac = sp[5] or ""
        local ev = sp[6] and sp[6].event
        if ev and not self:EventOn(ev) then offSeason = offSeason or ev
        elseif fac == "" or not mine or fac:find(mine, 1, true) then ok[#ok + 1] = sp end
    end
    if kind == "Vendor" and #ok == 0 and offSeason then
        local ev = self.EVENTS[offSeason]
        return { source = "Vendor", where = (ev and ev.name or "A holiday") .. " only", skill = skill,
            level = (level or 0) > 0 and level or nil, cost = cost, itemID = item, seasonOff = true,
            text = ("Only sold during the %s (%s): no trips there until then."):format(ev and ev.name or "holiday", ev and ev.when or "") }
    end
    if kind == "Vendor" and #ok == 0 and #spots > 0 then
        -- only the other faction sells it: say so (the AH may still have one)
        return { source = "Vendor", where = (spots[1][1] or "?") .. " (other faction)", zone = spots[1][2], skill = skill,
            level = level > 0 and level or nil, cost = cost, itemID = item, text = "Only the other faction's vendors sell it." }
    end
    local f = { source = kind, skill = skill, level = (level or 0) > 0 and level or nil, cost = cost, itemID = item }
    local first = ok[1]
    -- the nearest one you can reach: one in the zone you're in first
    local here = at.zone
    if here then for _, sp in ipairs(ok) do if sp[2] == here then first = sp break end end end
    local function Name(sp)
        if sp[1] ~= "" then return sp[1] end
        local npc = sp[6] and sp[6].npc
        return npc and self:NPCName(npc) or nil
    end
    if kind == "Trainer" then
        -- a trainer you've been to, or the nearest one the data knows (one where you are first)
        f.where = prof .. " trainer"
        local norm = self:Norm(name)
        local p
        -- the city trainers of a profession teach the same; one listed only outside the cities teaches
        -- it alone (and a trainer whose list you've read teaches only what's on it)
        if #spots == 0 or self:CitySpot(spots) then
            -- not one listed in the city you're in: any trainer of that profession there teaches it too
            -- (never sent to another city to train when there's a trainer right where you are)
            if here and not (first and first[2] == here) then
                for _, sp in ipairs(self:TrainerSpots(prof)) do
                    if sp[2] == here and self:MayTeach(sp[1], norm) then first = sp break end
                end
            end
            p = self:NearestTrainer(prof, norm)
            if first and here and first[2] == here then p = nil end -- the one here wins
            local hereMap = at.map
            if at.inCity == nil then
                at.inCity = (hereMap and PC.Travel and ((PC.Travel.CITIES and PC.Travel.CITIES[hereMap])
                    or (PC.Travel.IsCityMap and PC.Travel:IsCityMap(hereMap)))) and true or false
            end
            local hereOK = at.inCity and not (first and first[2] == here) and not self:Lacks(prof, norm, at)
            if hereOK and (not p or (here and p.map ~= hereMap and p.zone ~= here)) then
                -- every city has every trainer: the one here (no arrow until you've been to it once)
                f.where, f.zone = ("%s trainer here in %s"):format(prof, here), here
                return f
            end
            if not p and not first and self:Lacks(prof, norm) then
                -- the trainers you've read don't teach it, and the data names none
                f.where = "Unknown trainer"
                f.text = "Not taught by the trainers you've visited, and the data names no other."
            end
        end
        if p then f.place, f.zone, f.where = p, p.zone, p.name or f.where
        elseif first then
            f.where = Name(first) or f.where
            f.zone = first[2] ~= "" and first[2] or nil
            f.place = self:DBPlace({ f.where, first[2], first[3], first[4] }, "npc")
        end
    elseif kind == "World drop" then
        f.where = "World drop"
    elseif first then
        local extra = first[6] or {}
        f.where = Name(first) or (kind == "Vendor" and "Vendor") or nil
        if kind == "Drop" and extra.chance then f.where = ("%s (%s%%)"):format(f.where or "?", tostring(extra.chance)) end
        if kind == "Drop" and extra.lvl then f.where = f.where .. ", level " .. extra.lvl end
        f.zone = first[2] ~= "" and first[2] or nil
        if kind == "Vendor" or kind == "Drop" or kind == "Quest" then
            f.place = self:DBPlace({ f.where or "", first[2], first[3], first[4] }, kind == "Vendor" and "vendor" or "npc")
        end
        -- a reputation it needs: "Needs Friendly with the Earthen Ring"
        if extra.rep then
            local fid, val = extra.rep:match("^(%d+):(%d+)$")
            local standing = ({ [3000] = "Friendly", [9000] = "Honored", [21000] = "Revered", [42000] = "Exalted" })[tonumber(val) or 0] or "a standing"
            local fname
            if GetFactionInfoByID then
                local okF, n = pcall(GetFactionInfoByID, tonumber(fid))
                if okF and type(n) == "string" and n ~= "" then fname = n end
            end
            f.req = ("%s%s"):format(standing, fname and (" with " .. fname) or " reputation")
            f.rep = extra.rep
        end
        -- a quest: who gives it (the spot is theirs)
        if kind == "Quest" and extra.giver then
            f.text = "From " .. extra.giver
            if f.place then f.place.name = extra.giver end
        end
        local others = {}
        for i, sp in ipairs(ok) do
            local n = sp ~= first and i <= 4 and Name(sp)
            if n then others[#others + 1] = n .. (sp[2] ~= "" and (" (" .. sp[2] .. ")") or "") end
        end
        if #others > 0 then f.text = (f.text and (f.text .. "\n") or "") .. "Also: " .. table.concat(others, ", ") end
        if kind == "Vendor" and extra.limited then f.text = (f.text and (f.text .. "\n") or "") .. "Limited stock: it may be sold out." end
    end
    return f
end

---------------------------------------------------------------------------
-- Retail recipe data: where a recipe comes from, by its recipe number
--   PC.RecipeDBRetail[recipe] = { skill line, skill needed, recipe item, { spots } }
--   a spot: { source, cost, npc, map, x, y, faction, quest/dungeon/object }
-- Names come from the game: vendors (asked once and kept), quests, dungeons and zones.
---------------------------------------------------------------------------
ToLearn.SRC = { V = "Vendor", T = "Trainer", Q = "Quest", D = "Drop", I = "Dungeon", O = "Treasure", W = "World drop", X = "Other" }

function ToLearn:NPCName(id)
    if not id then return nil end
    PC.db.npcNames = PC.db.npcNames or {}
    local n = PC.db.npcNames[id]
    if n then return n end
    self.npcAsked = self.npcAsked or {}
    if self.npcAsked[id] then return nil end -- (asked already this session: the game didn't know it)
    self.npcAsked[id] = true
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, ("unit:Creature-0-0-0-0-%d-0000000000"):format(id))
        local line = ok and data and data.lines and data.lines[1]
        if line and line.leftText and line.leftText ~= "" then
            PC.db.npcNames[id] = line.leftText
            self.npcAsked[id] = nil
            return line.leftText
        end
    end
    return nil
end

function ToLearn:MapName(map)
    if not map or not C_Map or not C_Map.GetMapInfo then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, map)
    return ok and info and info.name or nil
end

function ToLearn:QuestName(id)
    if not id or not C_QuestLog then return nil end
    local name = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
    if not name and C_QuestLog.RequestLoadQuestByID then pcall(C_QuestLog.RequestLoadQuestByID, id) end
    return name
end

function ToLearn:InstanceName(id)
    if not id or not EJ_GetInstanceInfo then return nil end
    local ok, name = pcall(EJ_GetInstanceInfo, id)
    return ok and name or nil
end

-- "c:361:2" -> "2 Illustrious Jewelcrafter's Token", "i:38425:3" -> "3 Heavy Borean Leather"
function ToLearn:CostText(cost)
    if type(cost) ~= "string" then return nil end
    local out = {}
    for kind, id, n in cost:gmatch("(%a):(%d+):(%d+)") do
        id, n = tonumber(id), tonumber(n)
        local name
        if kind == "c" and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
            name = ok and info and info.name
        elseif kind == "i" then
            name = PC:ItemName(id)
        end
        out[#out + 1] = ("%d %s"):format(n, name or (kind == "c" and "currency" or "items"))
    end
    return #out > 0 and table.concat(out, ", ") or nil
end

-- Where the Retail data says a recipe comes from: { source, where, zone, skill, cost, costText, place, itemID, text } or nil
--   (srcWhere: the vendor the game itself names, so the spot is that vendor)
ToLearn.RETAIL_KEEP = 60 -- seconds a looked-up recipe is kept (names the game hadn't loaded get another go)
function ToLearn:FromRetailDB(recipeID, srcWhere)
    self.retailCache = self.retailCache or {}
    local now = GetTime and GetTime() or 0
    local c = self.retailCache[recipeID]
    if c and c.where == srcWhere and now - c.t < self.RETAIL_KEEP then return c.f end
    local f = self:FromRetailDBRaw(recipeID, srcWhere)
    self.retailCache[recipeID] = { t = now, where = srcWhere, f = f }
    return f
end

function ToLearn:FromRetailDBRaw(recipeID, srcWhere)
    local db = PC.RecipeDBRetail
    local r = db and recipeID and db[recipeID]
    if not r then return nil end
    local skill, item, spots = r[2], r[3], r[4] or {}
    local mine = UnitFactionGroup and ({ Alliance = "A", Horde = "H" })[UnitFactionGroup("player") or ""] or nil
    local ok = {}
    for _, sp in ipairs(spots) do
        local fac = sp[7] or ""
        if fac == "" or not mine or fac == mine then ok[#ok + 1] = sp end
    end
    if #ok == 0 then ok = spots end
    local function name(sp)
        local code = sp[1]
        if code == "Q" then return self:QuestName(sp[8]) end
        if code == "I" then return self:InstanceName(sp[8]) end
        if code == "O" then return "Treasure" end
        if code == "W" then return "World drop" end
        return self:NPCName(sp[3])
    end
    -- the vendor the game names, then one on the map you're on, then one with a spot, then the first
    local here = PC.Places and PC.Places:Here() or nil
    local first
    if srcWhere then for _, sp in ipairs(ok) do if name(sp) == srcWhere then first = sp break end end end
    if not first and here then for _, sp in ipairs(ok) do if sp[4] == here then first = sp break end end end
    if not first then for _, sp in ipairs(ok) do if sp[5] then first = sp break end end end
    first = first or ok[1]
    if not skill and item then
        local ri = self:RecipeItem(item)
        skill = ri and ri.skill
    end
    local f = { skill = skill, itemID = item }
    if not first then return f end
    local code = first[1]
    f.source = self.SRC[code] or "Other"
    f.where = name(first) or (code == "T" and "Trainer") or nil
    if code == "Q" and first[3] then
        local giver = self:NPCName(first[3])
        if giver then f.text = "From " .. giver end
    end
    f.zone = self:MapName(first[4])
    if type(first[2]) == "number" then f.cost = first[2] else f.costText = self:CostText(first[2]); f.costx = first[2] end
    if first[4] and first[5] and first[6] then
        f.place = { kind = code == "V" and "vendor" or "npc", name = f.where or f.zone or "Recipe", zone = f.zone or "",
            map = first[4], x = first[5] / 100, y = first[6] / 100, db = true, confirmed = true }
    end
    local others = {}
    for _, sp in ipairs(ok) do
        if sp ~= first and #others < 3 then
            local n = name(sp)
            local z = self:MapName(sp[4])
            if n or z then others[#others + 1] = (n or self.SRC[sp[1]] or "?") .. (z and (" (" .. z .. ")") or "") end
        end
    end
    if #others > 0 then f.text = (f.text and (f.text .. "\n") or "") .. "Also: " .. table.concat(others, ", ") end
    return f
end

-- A reputation need ("2758:3000" = Friendly with faction 2758): met? (and your standing, the faction's name)
function ToLearn:RepMet(rep)
    local fid, val = tostring(rep or ""):match("^(%d+):(%d+)$")
    fid, val = tonumber(fid), tonumber(val)
    if not fid then return true end
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, data = pcall(C_Reputation.GetFactionDataByID, fid)
        if ok and type(data) == "table" and data.currentStanding then return data.currentStanding >= val, data.name end
    end
    if GetFactionInfoByID then
        local ok, name, _, _, _, _, barValue = pcall(GetFactionInfoByID, fid)
        if ok and name and barValue then return barValue >= val, name end
    end
    return false -- (a faction you haven't met yet)
end

---------------------------------------------------------------------------
-- Special currency: recipes a vendor sells for badges, tokens, marks or other items, not gold
--   db.specialCost[recipe item] = { { kind = "c" (currency) or "i" (item), id, n, name }, ... }
--   (read at the vendor; Retail's recipe data has them too)
---------------------------------------------------------------------------
local function IsRecipeItem(id)
    local inst = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not inst or not id then return false end
    local ok, _, _, _, _, _, classID = pcall(inst, id)
    return ok and classID == 9
end

function ToLearn:ReadSpecialCosts()
    if not (GetMerchantNumItems and GetMerchantItemCostInfo and GetMerchantItemCostItem and GetMerchantItemID) then return end
    PC.db.specialCost = PC.db.specialCost or {}
    for i = 1, GetMerchantNumItems() or 0 do
        local id = GetMerchantItemID(i)
        local ok, n = pcall(GetMerchantItemCostInfo, i)
        if id and ok and (n or 0) > 0 and IsRecipeItem(id) then
            local list = {}
            for c = 1, n do
                local _, value, link, name = GetMerchantItemCostItem(i, c)
                local kind, cid
                if type(link) == "string" then
                    cid = tonumber(link:match("currency:(%d+)"))
                    if cid then kind = "c" else cid = tonumber(link:match("item:(%d+)")); kind = cid and "i" end
                end
                if kind and value and value > 0 then list[#list + 1] = { kind = kind, id = cid, n = value, name = name } end
            end
            PC.db.specialCost[id] = #list > 0 and list or nil
        end
    end
    self:Changed()
end

-- How many of a currency or item you have (items: bags and bank)
function ToLearn:HaveOf(kind, id)
    if kind == "c" then
        if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
            if ok and info then return info.quantity or 0, info.name end
        end
        if GetCurrencyInfo then
            local ok, name, amount = pcall(GetCurrencyInfo, id)
            if ok then return amount or 0, name end
        end
        return 0
    end
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    local n = count and count(id, true) or 0
    return n or 0, PC:ItemName(id)
end

-- What a recipe costs besides gold, with how much you have: { { kind, id, n, name, have } } or nil
function ToLearn:SpecialCost(e)
    local list = e.itemID and PC.db.specialCost and PC.db.specialCost[e.itemID]
    if not list and type(e.costx) == "string" then
        list = {}
        for kind, id, n in e.costx:gmatch("(%a):(%d+):(%d+)") do list[#list + 1] = { kind = kind, id = tonumber(id), n = tonumber(n) } end
        if #list == 0 then list = nil end
    end
    if not list then return nil end
    local out = {}
    for _, c in ipairs(list) do
        local have, name = self:HaveOf(c.kind, c.id)
        out[#out + 1] = { kind = c.kind, id = c.id, n = c.n, name = c.name or name or (c.kind == "c" and "currency" or "items"), have = have or 0 }
    end
    return out
end

---------------------------------------------------------------------------
-- Holidays: their recipes, and a tip (once a year each) when one is on and you're missing some
---------------------------------------------------------------------------
-- recipe (key or number) -> holiday number
function ToLearn:EventIndex()
    local idx = {}
    for ev, list in pairs(PC.RecipeEvents or {}) do
        for _, k in ipairs(list) do idx[k] = ev end
    end
    return idx
end

-- Holiday windows for when the game's calendar can't say (by the date)
ToLearn.EVENT_DATES = { [14] = { from = { 12, 15 }, to = { 1, 2 } } }

-- The holidays on right now: { [holiday number] = its name }
function ToLearn:ActiveEvents()
    local now = GetTime and GetTime() or 0
    if self.activeEvents and now - self.activeEvents.t < 600 then return self.activeEvents.list end
    local out = {}
    local C = C_Calendar
    local today = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
    if C and C.GetNumDayEvents and C.GetDayEvent and today and today.monthDay then
        -- (the calendar counts months from the one it's showing)
        local offset = 0
        if C.GetMonthInfo then
            local ok, info = pcall(C.GetMonthInfo, 0)
            if ok and info and info.month and info.year then offset = (today.year - info.year) * 12 + (today.month - info.month) end
        end
        local ok, n = pcall(C.GetNumDayEvents, offset, today.monthDay)
        for i = 1, (ok and n or 0) do
            local ok2, ev = pcall(C.GetDayEvent, offset, today.monthDay, i)
            if ok2 and type(ev) == "table" and ev.eventID and (ev.calendarType == "HOLIDAY" or ev.calendarType == nil) then
                local e = (PC.EventRemap and PC.EventRemap[ev.eventID]) or ev.eventID
                out[e] = ev.title or (PC.EventNames and PC.EventNames[e]) or "A holiday"
            end
        end
    end
    if not next(out) then
        local t = date and date("*t") or nil
        if type(t) == "table" and t.month then
            local md = t.month * 100 + t.day
            for e, w in pairs(self.EVENT_DATES) do
                local a, b = w.from[1] * 100 + w.from[2], w.to[1] * 100 + w.to[2]
                if (a <= b and md >= a and md <= b) or (a > b and (md >= a or md <= b)) then out[e] = PC.EventNames and PC.EventNames[e] or "A holiday" end
            end
        end
    end
    self.activeEvents = { t = now, list = out }
    return out
end

-- A holiday's recipes you don't have yet (your professions), from the Learn list
function ToLearn:EventRecipes(ev)
    local set = {}
    for _, k in ipairs(PC.RecipeEvents and PC.RecipeEvents[ev] or {}) do set[k] = true end
    local out = {}
    for _, e in ipairs(self:List()) do
        if set[e.key] or (e.recipeID and set[e.recipeID]) then out[#out + 1] = e end
    end
    return out
end

-- Once a year per holiday: "these recipes are out now", with Add to plan / Save for later
function ToLearn:CheckHolidays()
    if not PC.RecipeEvents or not PC.cdb then return end
    PC.cdb.eventTips = PC.cdb.eventTips or {}
    local year = date and date("%Y") or "?"
    for ev, name in pairs(self:ActiveEvents()) do
        local key = ev .. ":" .. year
        if PC.RecipeEvents[ev] and not PC.cdb.eventTips[key] then
            local list = self:EventRecipes(ev)
            if #list > 0 then
                PC.cdb.eventTips[key] = time()
                self:HolidayTip(name, list)
                return true
            end
        end
    end
    return false
end

function ToLearn:AddAll(list, go, what)
    local n = 0
    for _, e in ipairs(list) do
        if not e.seasonOff then self:AddToTrip(e, false, true); n = n + 1 end
    end
    self:Changed()
    self:OrderTrip()
    self:SyncRunPlan()
    if go and n > 0 then self:StartRun() end
    what = what or "holiday recipe"
    PC.Buy:Say(go and ("|cff40ff40%d %s%s on your Recipe Run: the Task Button takes you there.|r"):format(n, what, n == 1 and "" or "s")
        or ("|cff40ff40%d %s%s saved on your Recipe Run. Pick Recipe Run in your plans when you're ready (it goes away once they're learned).|r"):format(n, what, n == 1 and "" or "s"))
    PC:RefreshUI()
end

function ToLearn:HolidayTip(name, list)
    if not PC.UI or not PC.UI.Ask then return end
    local lines = {}
    for i, e in ipairs(list) do
        if i > 12 then lines[#lines + 1] = ("and %d more (see the Learn tab)"):format(#list - 12) break end
        lines[#lines + 1] = ("%s |cff888888(%s%s)|r"):format(e.name, e.prof, e.where and (", " .. e.where) or "")
    end
    PC.UI:Ask("ProfitCrafterHolidayRecipes", {
        title = name .. " recipes", sub = "Only while the holiday is on", subColor = { 1, 0.82, 0 },
        sections = { { lines = { ("%s is on, and you don't have %s yet:"):format(name, #list == 1 and "this recipe" or ("these %d recipes"):format(#list)) }, bullets = false },
            { lines = lines } },
        buttons = {
            { text = "Add to plan", onClick = function() ToLearn:AddAll(list, true) end },
            { text = "Save for later", onClick = function() ToLearn:AddAll(list, false) end },
            { text = "No thanks" },
        },
        fit = true,
    })
end

---------------------------------------------------------------------------
-- New at the trainer: when recipes you can train now appear (a skill-up, a level), a pop-up says
-- so: Go train, Save for later (on your Recipe Run, which goes away once they're learned) or Close.
-- Each recipe is only told about once.
---------------------------------------------------------------------------
function ToLearn:CheckTrainer(force)
    if not PC.cdb then return false end
    local now = GetTime and GetTime() or 0
    if not force and self.trainCheckedAt and now - self.trainCheckedAt < 60 then return false end
    self.trainCheckedAt = now
    if (InCombatLockdown and InCombatLockdown()) or (UnitOnTaxi and UnitOnTaxi("player")) then return false end
    PC.cdb.trainTipped = PC.cdb.trainTipped or {}
    -- only professions whose window you've opened (before that, everything looks unlearned)
    local read = {}
    for _, r in pairs(PC.cdb.recipes or {}) do if r.prof then read[r.prof == "Smelting" and "Mining" or r.prof] = true end end
    local list, fresh = {}, false
    for _, e in ipairs(self:List()) do
        if e.source == "Trainer" and e.status == "now" and not e.cantAfford and read[e.prof] and not self:InTrip(e.key) then
            list[#list + 1] = e
            if not PC.cdb.trainTipped[e.key] then fresh = true end
        end
    end
    if not fresh then return false end
    for _, e in ipairs(list) do PC.cdb.trainTipped[e.key] = true end
    self:TrainerTip(list)
    return true
end

function ToLearn:TrainerTip(list)
    if not PC.UI or not PC.UI.Ask then return end
    local lines, total, profs, seen = {}, 0, {}, {}
    for i, e in ipairs(list) do
        if e.cost then total = total + e.cost end
        if not seen[e.prof] then seen[e.prof] = true; profs[#profs + 1] = e.prof end
        if i <= 12 then
            lines[#lines + 1] = ("%s |cff888888(%s%s)|r"):format(e.name, e.prof, e.cost and (", " .. PC:Money(e.cost, false, true)) or "")
        elseif i == 13 then
            lines[#lines + 1] = ("and %d more (see the Learn tab)"):format(#list - 12)
        end
    end
    local where = list[1] and list[1].where
    PC.UI:Ask("ProfitCrafterTrainerNew", {
        title = "New recipes to train", sub = table.concat(profs, ", "), subColor = { 1, 0.82, 0 },
        sections = { { lines = { ("You can train %s now%s%s."):format(#list == 1 and "1 new recipe" or (#list .. " new recipes"),
                where and (" at " .. where) or "", total > 0 and (" for " .. PC:Money(total, false, true)) or "") }, bullets = false },
            { lines = lines } },
        buttons = {
            { text = "Go train", onClick = function() ToLearn:AddAll(list, true, "recipe to train") end },
            { text = "Save for later", onClick = function() ToLearn:AddAll(list, false, "recipe to train") end },
            { text = "Close" },
        },
        fit = true,
    })
end

-- "1g 50s", "50 s", "75c", or the coin icons the game uses: copper (nil if it isn't money)
function ToLearn:ParseMoney(text)
    if type(text) ~= "string" then return nil end
    local t = text:gsub("|T[^|]-GoldIcon[^|]-|t", "g"):gsub("|T[^|]-SilverIcon[^|]-|t", "s"):gsub("|T[^|]-CopperIcon[^|]-|t", "c")
        :gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):lower()
    local total, found = 0, false
    for n, unit in t:gmatch("(%d+)%s*([gsc])") do
        found = true
        total = total + tonumber(n) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
    end
    return found and total or nil
end

-- Text for the "how to get it" line
function ToLearn:HowText(e)
    local parts = { e.source or "?" }
    if e.where then parts[#parts + 1] = e.where end
    if e.zone and e.zone ~= "" then parts[#parts + 1] = e.zone end
    return table.concat(parts, ": ", 1, math.min(#parts, 2)) .. (#parts > 2 and (", " .. parts[3]) or "")
end

---------------------------------------------------------------------------
-- The trip: go and get them (one step at a time on the Next step button)
---------------------------------------------------------------------------
function ToLearn:InTrip(key)
    for _, k in ipairs(Data().trip) do if k == key then return true end end
    return false
end

function ToLearn:AddToTrip(e, first, quiet)
    if e and e.seasonOff then
        if quiet then return end
        return PC.Buy:Say("|cffff8040" .. (e.name or "That recipe") .. ": " .. (e.srcText or "only sold during a holiday.") .. "|r")
    end
    self:Changed()
    local d = Data()
    local trip = d.trip
    for i = #trip, 1, -1 do if trip[i] == e.key then table.remove(trip, i) end end
    if first then table.insert(trip, 1, e.key) else trip[#trip + 1] = e.key end
    -- Go: this one first, whatever the route says; +: wherever it fits best on the way
    d.tripFirst = first and e.key or (d.tripFirst ~= e.key and d.tripFirst or nil)
    if quiet then return end
    self:OrderTrip()
    self:SyncRunPlan()
    PC.Buy:Say(("|cff40ff40%s added to your Recipe Run (%d stop%s). Pick Recipe Run in your plans, or Start trip, to go.|r"):format(e.name, #trip, #trip == 1 and "" or "s"))
    PC:RefreshUI()
end

-- The trip in the quickest order from where you are: the closest stop (by travel time: walking,
-- flights to flight paths you know, boats and zeppelins, your hearthstone) first, then the closest
-- to that, and so on. Stops with no spot to go to (drops, quests) come last.
ToLearn.ORDER_EVERY = 15 -- seconds between working the order out again as you move
function ToLearn:OrderTrip(list)
    local d = Data()
    local trip = d.trip
    self.orderedAt = GetTime and GetTime() or 0
    if #trip < 2 then return end
    list = list or self:List()
    local byKey = {}
    for _, e in ipairs(list) do byKey[e.key] = e end
    local go, later, pinned = {}, {}, nil
    for _, k in ipairs(trip) do
        local e = byKey[k]
        if k == d.tripFirst and e then pinned = k
        elseif e and e.place and e.place.map then go[#go + 1] = k
        else later[#later + 1] = k end
    end
    if #go > 1 and PC.Travel and PC.Travel.Order and PC:RouteOn() then
        local stops = {}
        for i, k in ipairs(go) do stops[i] = byKey[k].place end
        local ok, order = pcall(PC.Travel.Order, PC.Travel, stops)
        if ok and type(order) == "table" and #order == #go then
            local sorted = {}
            for _, i in ipairs(order) do sorted[#sorted + 1] = go[i] end
            go = sorted
        end
    end
    wipe(trip)
    if pinned then trip[1] = pinned end
    for _, k in ipairs(go) do trip[#trip + 1] = k end
    for _, k in ipairs(later) do trip[#trip + 1] = k end
end

function ToLearn:RemoveFromTrip(key)
    self:Changed()
    local trip = Data().trip
    for i = #trip, 1, -1 do if trip[i] == key then table.remove(trip, i) end end
    self:SyncRunPlan()
    PC:RefreshUI()
end

function ToLearn:ClearTrip() wipe(Data().trip); self:Changed(); self:SyncRunPlan(); PC:RefreshUI() end

---------------------------------------------------------------------------
-- The Recipe Run: the trip as a plan of its own. It's in the plan list while the trip has stops;
-- pick it (or Start trip) and the Task Button runs it like any plan. When the last stop is done,
-- it goes back to the plan you were on.
---------------------------------------------------------------------------
ToLearn.RUN = "Recipe Run"
function ToLearn:IsRun(name) return (name or (PC.PlanName and PC:PlanName())) == self.RUN end

function ToLearn:SyncRunPlan()
    local plans = PC:Plans()
    local trip = Data().trip
    if #trip > 0 then
        plans[self.RUN] = plans[self.RUN] or {}
    elseif plans[self.RUN] then
        local wasOn = PC.cdb.planCurrent == self.RUN
        plans[self.RUN] = nil
        if wasOn then
            local back = PC.cdb.runReturnPlan
            PC.cdb.planCurrent = (back and plans[back]) and back or nil
            PC:PlanName()
            PC.Buy:Say("|cff40ff40Recipe Run done: back to your plan \"" .. PC:PlanName() .. "\".|r")
        end
        PC.cdb.runReturnPlan = nil
    end
end

-- Start the Recipe Run (Start trip, or picking it in the plan list)
function ToLearn:StartRun()
    self:SyncRunPlan()
    if #Data().trip == 0 then return false end
    local cur = PC:PlanName()
    if cur ~= self.RUN then PC.cdb.runReturnPlan = cur end
    PC.cdb.planCurrent = self.RUN
    if PC.Steps then PC.Steps.planShown, PC.Steps.planFresh = nil, true end -- its task list rolls out
    self:OrderTrip()
    return true
end

-- The Recipe Run's stops for the tasks list, in order: { cat, text }
ToLearn.STOP_CAT = { Vendor = "Vendor", Trainer = "Trainer", Drop = "Drop", ["World drop"] = "Drop", Quest = "Quest" }
function ToLearn:StopRows()
    local out = {}
    local trip = Data().trip
    if #trip == 0 then return out end
    local byKey = {}
    for _, e in ipairs(self:List()) do byKey[e.key] = e end
    for i, k in ipairs(trip) do
        local e = byKey[k]
        if e then
            local where = (e.where and e.where ~= "") and e.where or "?"
            local zone = (e.zone and e.zone ~= "") and (" (" .. e.zone .. ")") or ""
            local text
            if e.source == "Vendor" then text = ("buy %s from %s%s"):format(e.name, where, zone)
            elseif e.source == "Trainer" then text = ("train %s at %s%s"):format(e.name, where, zone)
            elseif e.source == "Quest" then text = ("%s: quest %s%s"):format(e.name, where, zone)
            elseif e.source == "Drop" or e.source == "World drop" then text = ("%s: drops from %s%s"):format(e.name, where, zone)
            else text = ("get %s%s"):format(e.name, zone) end
            out[#out + 1] = { cat = self.STOP_CAT[e.source or ""] or "Vendor", text = ("stop %d: %s"):format(i, text), key = k }
        end
    end
    return out
end

-- The trip's next stop: the entry, nearest-first among what's left (and what can be reached)
-- Trip recipes you've learned meanwhile (their recipe item says "Already known"): marked known.
-- Returns true when one was found.
function ToLearn:CheckTripKnown(byKey)
    -- (a tooltip look per trip stop: every few seconds is plenty)
    local now = GetTime and GetTime() or 0
    if self.knownAt and now - self.knownAt < 3 and self.listCache then return false end
    self.knownAt = now
    local found = false
    for _, k in ipairs(Data().trip) do
        local e = byKey[k]
        if e and e.itemID then
            local ri = self:RecipeItem(e.itemID, true)
            if ri and ri.known then
                PC.cdb.learnedNames = PC.cdb.learnedNames or {}
                PC.cdb.learnedNames[self:Norm(e.name)] = true
                found = true
            end
        end
    end
    if found then self:Changed() end
    return found
end

-- Sold out: this stop waits an hour (vendors restock limited items), the rest of the trip goes on
ToLearn.RESTOCK = 3600
function ToLearn:WaitStock(key)
    local d = Data()
    d.waitStock = d.waitStock or {}
    d.waitStock[key] = time() + self.RESTOCK
    self:Changed()
    PC.Buy:Say("|cffffd100Sold out: trying again in an hour. It stays on your Recipe Run.|r")
    PC:RefreshUI()
end

-- A stop that waits: sold out (an hour), or a reputation vendor you can't buy from yet (it stays on
-- the trip, and the Task Button goes on to the others until you have the standing)
function ToLearn:Waiting(key, e)
    if e and e.repShort then return true end
    local w = Data().waitStock
    local t = w and w[key]
    if t and t <= time() then w[key] = nil; return false end
    return t ~= nil
end

function ToLearn:NextStop()
    local trip = Data().trip
    if #trip == 0 then return nil end
    local list = self:List()
    local byKey = {}
    for _, e in ipairs(list) do byKey[e.key] = e end
    -- learned some other way (by hand, at a trainer): the recipe item's tooltip says "Already known"
    if self:CheckTripKnown(byKey) then
        list = self:List()
        byKey = {}
        for _, e in ipairs(list) do byKey[e.key] = e end
    end
    -- learned (or gone) meanwhile, or bought (it's in your bags or bank): off the trip
    for i = #trip, 1, -1 do
        local e = byKey[trip[i]]
        if not e or e.seasonOff or (e.itemID and PC:OwnedCount(e.itemID) > 0) then table.remove(trip, i) end
    end
    if #trip == 0 then self:SyncRunPlan(); return nil end
    -- the trip is kept in the quickest order (worked out again every few seconds as you move)
    local now = GetTime and GetTime() or 0
    if not self.orderedAt or now - self.orderedAt > self.ORDER_EVERY then self:OrderTrip(list) end
    -- a stop reached (learned): Go's pick is done with
    local d = Data()
    if d.tripFirst and not byKey[d.tripFirst] then d.tripFirst = nil end
    for _, k in ipairs(trip) do
        local e = byKey[k]
        if e and e.place and PC:RouteOn() and not self:Waiting(k, e) then return e end
    end
    -- nowhere to send you (a drop, a quest, an unknown source): those stay on the Learn tab's trip
    -- list, but the Task Button doesn't stop on them
    for _, k in ipairs(trip) do
        local e = byKey[k]
        if e and (e.place or e.source == "Vendor" or e.source == "Trainer") and not self:Waiting(k, e) then return e end
    end
    return nil
end

-- The Next step for the trip (nil when there's no trip)
-- A pattern, plan or formula in your bags that you can learn now: learn it straight away (no
-- carrying it around). The Task Button's click uses it (a real click: the game requires one).
function ToLearn:LearnStep()
    if InCombatLockdown and InCombatLockdown() then return nil end
    if not PC.BagSlots then return nil end
    local profs = MyProfs()
    local level = UnitLevel and UnitLevel("player") or 1
    self.riCache = self.riCache or {}
    local now = GetTime and GetTime() or 0
    for _, b in ipairs(PC.BagSlots()) do
        local c = self.riCache[b.id]
        if not c or now - c.t > 30 then c = { t = now, r = self:RecipeItem(b.id, true) or false }; self.riCache[b.id] = c end
        local ri = c.r
        if ri and not ri.known and ri.prof and profs[ri.prof] and not b.locked then
            local rank = profs[ri.prof].rank or 0
            if (not ri.skill or ri.skill <= rank) and (not ri.level or ri.level <= level) then
                local taught = ri.name:gsub("^%a+:%s*", "")
                -- with a vendor, bank, mailbox or AH window open, "using" it would sell it, store it or
                -- attach it: close that window first (the click does it), then learn
                local function shown(n) local f = _G[n]; return f and f.IsShown and f:IsShown() end
                -- ask the game who you're really talking to (a flag left over from a window that closed
                -- without telling us would otherwise say "close the mailbox" miles from any mailbox)
                local PIT = Enum and Enum.PlayerInteractionType
                local function talking(kind)
                    local m = C_PlayerInteractionManager
                    if not (m and m.IsInteractingWithNpcOfType and PIT and PIT[kind]) then return nil end
                    local ok, v = pcall(m.IsInteractingWithNpcOfType, PIT[kind])
                    if ok then return v and true or false end
                end
                local function open(kind, flag, ...)
                    local real = talking(kind)
                    if real ~= nil then return real end
                    if flag then return true end
                    for _, n in ipairs({ ... }) do if shown(n) then return true end end
                    return false
                end
                local mailOpen = open("MailInfo", PC.Mail and PC.Mail.open, "MailFrame")
                local bankOpen = open("Banker", PC.Bank and PC.Bank.open, "BankFrame")
                local vendorOpen = open("Merchant", PC.merchantOpen, "MerchantFrame")
                local ahOpen = open("Auctioneer", PC.ahOpen, "AuctionHouseFrame", "AuctionFrame")
                -- the game says it's closed: clear the leftover flag too
                if not mailOpen and PC.Mail and PC.Mail.open then PC.Mail.open, PC.Mail.busy = false, false end
                if not bankOpen and PC.Bank and PC.Bank.open then PC.Bank.open = false end
                if not vendorOpen and PC.merchantOpen then PC.merchantOpen = false end
                if not ahOpen and PC.ahOpen then PC.ahOpen = false end
                local window, close
                if vendorOpen then window, close = "vendor", CloseMerchant
                elseif bankOpen then window, close = "bank", CloseBankFrame
                elseif mailOpen then window, close = "mailbox", CloseMail
                elseif ahOpen then
                    window, close = "Auction House", (C_AuctionHouse and C_AuctionHouse.CloseAuctionHouse) or CloseAuctionHouse
                elseif shown("TradeFrame") then window, close = "trade", CloseTrade end
                if window then
                    return { text = ("Close the %s to learn %s"):format(window, taught), cat = "Craft",
                        items = { "learn " .. taught },
                        tip = ("With the %s open, using the recipe would %s it. The click closes it; the next click learns it."):format(window,
                            window == "vendor" and "sell" or window == "bank" and "store" or "put away"),
                        run = function() if close then pcall(close) end; C_Timer.After(0.3, function() PC:RefreshUI() end) end }
                end
                return { text = "Learn " .. taught, cat = "Craft",
                    useItem = { use = true, bag = b.bag, slot = b.slot, id = b.id, name = taught },
                    items = { "learn " .. taught },
                    tip = ("%s is in your bags: click to learn it now, so you don't carry it around."):format(ri.name) }
            end
        end
    end
    return nil
end

-- Can you learn this recipe item right now? (skill and level)
function ToLearn:CanLearnNow(ri)
    if not ri or ri.known or not ri.prof then return false end
    local pr = MyProfs()[ri.prof]
    if not pr then return false end
    local level = UnitLevel and UnitLevel("player") or 1
    return (not ri.skill or ri.skill <= (pr.rank or 0)) and (not ri.level or ri.level <= level)
end

---------------------------------------------------------------------------
-- At a vendor: other recipes it sells for your professions that you don't know yet and can afford.
-- Asked one at a time ("Buy Formula: X for 1g 2s?"). Ones you can learn now are learned straight
-- away; the rest wait in the bank (stored on your next bank visit). A "no" isn't asked again.
---------------------------------------------------------------------------
local function MerchantPrice(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if ok and type(info) == "table" then return info.price, info.numAvailable or -1, info.hasExtendedCost end
    end
    if GetMerchantItemInfo then
        local _, _, price, _, avail, _, _, ext = GetMerchantItemInfo(i)
        return price, avail or -1, ext
    end
end

local function MerchantIndex(itemID)
    for i = 1, (GetMerchantNumItems and GetMerchantNumItems() or 0) do
        local id = GetMerchantItemID and GetMerchantItemID(i)
        if id == itemID then return i end
    end
end

function ToLearn:OfferRecipes()
    if not PC.merchantOpen or not GetMerchantNumItems or not GetMerchantItemID then return end
    local d = Data()
    d.declined = d.declined or {}
    local profs = MyProfs()
    -- the trip's own stop here is bought by the Task Button, not asked about
    local onTrip = {}
    for _, k in ipairs(d.trip) do onTrip[k] = true end
    local money = GetMoney and GetMoney() or 0
    local asked, missing = 0, 0
    for i = 1, GetMerchantNumItems() or 0 do
        local id = GetMerchantItemID(i)
        local ri = id and self:RecipeItem(id, true)
        -- item details not loaded yet: look again in a moment
        if id and not ri then
            local inst = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
            local ok, _, _, _, _, _, classID = pcall(inst or function() end, id)
            if ok and classID == 9 then missing = missing + 1 end
        end
        -- on your trip: bought straight away (you chose it when you added it)
        if ri and not ri.known and PC:OwnedCount(id) == 0 and onTrip[ri.prof and (ri.prof .. ":" .. self:Norm(ri.name)) or ""] then
            local price, avail, ext = MerchantPrice(i)
            if price and price <= money and avail ~= 0 and not ext then
                money = money - price
                self:BuyRecipe(id, ri, price)
            end
        end
        if ri and not ri.known and ri.prof and profs[ri.prof] and not d.declined[id] and PC:OwnedCount(id) == 0 then
            local price, avail, ext = MerchantPrice(i)
            local key = ri.prof .. ":" .. self:Norm(ri.name)
            if price and price > 0 and price <= money and avail ~= 0 and not ext and not onTrip[key] then
                money = money - price
                asked = asked + 1
                self:AskRecipe(id, ri, price)
            end
        end
    end
    -- some recipes' details were still loading: one more look shortly
    if missing > 0 and not self.offerRetry then
        self.offerRetry = true
        C_Timer.After(1.5, function() ToLearn.offerRetry = nil; PC:Safe("recipe offers", ToLearn.OfferRecipes, ToLearn) end)
    end
    return asked
end

function ToLearn:AskRecipe(id, ri, price)
    self.askedNow = self.askedNow or {}
    if self.askedNow[id] then return end -- once per vendor visit
    self.askedNow[id] = true
    local now = self:CanLearnNow(ri)
    local pr = MyProfs()[ri.prof]
    local note = now and "You can learn it right away." or
        ((ri.skill and ("Needs %s %d (you're %d). It will go to the bank until you can learn it."):format(ri.prof, ri.skill, pr and pr.rank or 0))
            or ("Needs level %d. It will go to the bank until you can learn it."):format(ri.level or 0))
    PC.UI:Ask("ProfitCrafterRecipeOffer" .. id, {
        title = "Buy this recipe?", sub = "This vendor sells it",
        sections = { { lines = { ("%s for %s"):format(ri.name, PC:Money(price)) }, bullets = false },
            { lines = { note }, bullets = false } },
        buttons = {
            { text = "Buy", onClick = function() ToLearn:BuyRecipe(id, ri, price) end },
            { text = "No", onClick = function() Data().declined[id] = true end },
        },
        fit = true,
    })
end

function ToLearn:BuyRecipe(id, ri, price)
    if not PC.merchantOpen then return PC.Buy:Say("|cffff8040The vendor window closed: talk to the vendor again to buy it.|r") end
    local i = MerchantIndex(id)
    if not i then return PC.Buy:Say("|cffff8040" .. ri.name .. " isn't for sale here any more.|r") end
    if (GetMoney and GetMoney() or 0) < price then return PC.Buy:Say("|cffff5555Not enough gold for " .. ri.name .. ".|r") end
    BuyMerchantItem(i, 1)
    -- can't learn it yet: it waits in the bank
    if not self:CanLearnNow(ri) then
        PC.cdb.bankRecipes = PC.cdb.bankRecipes or {}
        PC.cdb.bankRecipes[id] = true
    end
    self:Changed()
    PC.Buy:Say(("|cff40ff40Bought %s for %s.|r%s"):format(ri.name, PC:Money(price),
        self:CanLearnNow(ri) and "" or " It will go to the bank until you can learn it."))
    C_Timer.After(1, function() PC:RefreshUI() end)
end

function ToLearn:Step()
    -- bought it: learn it before anything else
    local learn = self:LearnStep()
    if learn then return learn end
    local e = self:NextStop()
    if not e then return nil end
    local s = { cat = e.source == "Trainer" and "Vendor" or "Vendor" }
    local npc = UnitName and UnitName("npc") or nil
    local atIt = e.place and npc and npc == e.place.name
    if atIt and e.source == "Vendor" and PC.merchantOpen and GetMerchantNumItems then
        -- standing at the vendor: buy it
        for i = 1, GetMerchantNumItems() or 0 do
            local id = GetMerchantItemID and GetMerchantItemID(i)
            if id == e.itemID then
                s.text = "Buy " .. e.name
                s.tip = "Then the Task Button learns it (or it goes to the bank until you can)."
                s.run = function()
                    -- bought the same way as the vendor offers: one you can't learn yet waits in the bank
                    local ri = ToLearn:RecipeItem(e.itemID, true)
                    local price = MerchantPrice(i)
                    if ri and price then ToLearn:BuyRecipe(e.itemID, ri, price) else BuyMerchantItem(i, 1) end
                end
                s.items = { "buy " .. e.name }
                return s
            end
        end
        s.text = e.name .. " isn't in stock"
        s.tip = "Limited stock: the vendor gets more later.\nClick: try again in an hour (it stays on your trip; the next stop comes first).\n|cff888888Skip (or right-click): take it off the trip.|r"
        s.run = function() ToLearn:WaitStock(e.key) end
        s.skip = function() self:RemoveFromTrip(e.key) end
        return s
    end
    if atIt and e.source == "Trainer" and GetNumTrainerServices then
        for i = 1, GetNumTrainerServices() or 0 do
            local name = GetTrainerServiceInfo(i)
            if name and self:Norm(name) == self:Norm(e.name) then
                s.text = "Train " .. e.name
                s.run = function() if BuyTrainerService then BuyTrainerService(i) end end
                s.items = { "train " .. e.name }
                return s
            end
        end
    end
    -- go there
    if e.place then
        local p = e.place
        s.text = "Go to " .. (p.name or "the vendor")
        s.dest = p
        s.items = { ("get %s (%s)"):format(e.name, e.source or "?") }
        -- who and where, in words too: "Vayn Moongaze, Zephras Isle (63.8, 36.0)"
        local spot = (p.zone and p.zone ~= "" and p.zone or "") .. ((p.x and p.y) and (" (%.1f, %.1f)"):format(p.x * 100, p.y * 100) or "")
        s.tip = ("Recipe trip: %s from %s."):format(e.name, self:HowText(e))
            .. (spot ~= "" and ("\n%s is at %s on the map."):format(p.name or "It", spot) or "")
            .. (e.req and ("\nNeeds " .. e.req .. ".") or "")
            .. "\n|cff888888Skip (or right-click): take it off the trip.|r"
    else
        -- a drop, quest, dungeon...: no spot to walk to; say where it comes from
        s.text = "Get " .. e.name
        s.items = { ("%s: %s"):format(e.source or "?", e.where or e.zone or "see tooltip") }
        s.tip = ("%s. ProfitCrafter can't route there yet: %s"):format(self:HowText(e), e.srcText or "")
            .. "\n|cff888888Skip (or right-click): take it off the trip.|r"
    end
    s.skip = function() self:RemoveFromTrip(e.key) end
    return s
end

---------------------------------------------------------------------------
-- Events: trainers as you visit them; a toast when new ones come within reach
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "TRAINER_SHOW", "PLAYER_LEVEL_UP", "MERCHANT_SHOW", "MERCHANT_UPDATE", "CHAT_MSG_SYSTEM", "NEW_RECIPE_LEARNED",
    "LEARNED_SPELL_IN_TAB", "SPELLS_CHANGED", "SKILL_LINES_CHANGED" }) do pcall(ev.RegisterEvent, ev, e) end
-- "You have learned how to create a new item: Red Linen Bag." -> "red linen bag"
function ToLearn:LearnedFromMessage(msg)
    if PC.IsSecret(msg) or type(msg) ~= "string" then return nil end -- (kept secret by the game at times: can't be read)
    for _, fmt in ipairs({ ERR_LEARN_RECIPE_S or "You have learned how to create a new item: %s.", ERR_LEARN_SPELL_S or "You have learned a new spell: %s.",
        ERR_LEARN_ABILITY_S or "You have learned a new ability: %s." }) do
        local pat = "^" .. fmt:gsub("%%s", "\001"):gsub("([%%%.%(%)%-%+%*%?%[%]%^%$])", "%%%1"):gsub("\001", "(.+)") .. "$"
        local name = msg:match(pat)
        if name then return (name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h%[?(.-)%]?|h", "%1")) end
    end
    return nil
end

function ToLearn:NoteLearned(name)
    if not name or name == "" then return end
    PC.cdb.learnedNames = PC.cdb.learnedNames or {}
    PC.cdb.learnedNames[self:Norm(name)] = true
    self:ForgetRecipeItems()
    self:Changed()
    PC:RefreshUI()
end

ev:SetScript("OnEvent", function(_, event, a1)
    PC:Safe("recipes to get", function()
        if event == "LEARNED_SPELL_IN_TAB" or event == "SPELLS_CHANGED" or event == "SKILL_LINES_CHANGED" then
            -- something learned: the list and the trip are worked out again (tooltips say "Already known")
            ToLearn:Changed()
            ToLearn.riCache = nil
            ToLearn:ForgetRecipeItems()
            -- a skill-up: anything new at the trainer? (a moment later, once the list has caught up)
            if event == "SKILL_LINES_CHANGED" then
                C_Timer.After(3, function() if ToLearn.AUTO_TIPS then PC:Safe("trainer tip", ToLearn.CheckTrainer, ToLearn) end end)
            end
            return
        end
        if event == "CHAT_MSG_SYSTEM" then
            local name = ToLearn:LearnedFromMessage(a1)
            if name then ToLearn:NoteLearned(name) end
            return
        end
        if event == "NEW_RECIPE_LEARNED" then
            ToLearn:ForgetRecipeItems() -- (something was learned, whatever it's called)
            local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(a1)
            local name = (info and info.name) or (GetSpellInfo and GetSpellInfo(a1))
            if name then ToLearn:NoteLearned(name) end
            return
        end
        if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
            -- prices in tokens, badges...: now, and again once the vendor's list has finished loading
            pcall(ToLearn.ReadSpecialCosts, ToLearn)
            C_Timer.After(1, function() if PC.merchantOpen then pcall(ToLearn.ReadSpecialCosts, ToLearn) end end)
            if event == "MERCHANT_UPDATE" then return end
            ToLearn.askedNow = nil -- a new visit: ask again about the ones you haven't answered
            -- after the vendor's list has loaded (and the trip's own buy is lined up)
            C_Timer.After(0.8, function() PC:Safe("recipe offers", ToLearn.OfferRecipes, ToLearn) end)
            return
        end
        if event == "TRAINER_SHOW" then
            local key
            local npc = UnitName and UnitName("npc") or nil
            if PC.Places then
                local map = PC.Places:Here()
                key = PC.Places.Key and PC.Places.Key("trainer", map, 0, 0, npc or "Trainer") or nil
            end
            ToLearn:ReadTrainer(key, npc)
            -- again once its list has surely loaded (it can still be empty as the window opens)
            C_Timer.After(0.5, function() PC:Safe("trainer list", ToLearn.ReadTrainer, ToLearn, key, npc) end)
        elseif event == "PLAYER_LOGIN" then
            -- holidays: the calendar loads its events, then a look (and every half hour: one may start)
            if C_Calendar and C_Calendar.OpenCalendar then pcall(C_Calendar.OpenCalendar) end
            C_Timer.After(30, function() if ToLearn.AUTO_TIPS then PC:Safe("holiday recipes", ToLearn.CheckHolidays, ToLearn) end end)
            C_Timer.After(45, function() if ToLearn.AUTO_TIPS then PC:Safe("trainer tip", ToLearn.CheckTrainer, ToLearn, true) end end)
            if C_Timer.NewTicker then
                C_Timer.NewTicker(1800, function() if ToLearn.AUTO_TIPS then ToLearn.activeEvents = nil; PC:Safe("holiday recipes", ToLearn.CheckHolidays, ToLearn) end end)
            end
        elseif event == "PLAYER_LEVEL_UP" then
            C_Timer.After(2, function()
                local n = 0
                for _, e in ipairs(ToLearn:List()) do if e.status == "now" then n = n + 1 end end
                if n > 0 then PC:Note("Scout recipes", { ("%d recipe%s you can get now (see Scout recipes)."):format(n, n == 1 and "" or "s") }) end
                if ToLearn.AUTO_TIPS then PC:Safe("trainer tip", ToLearn.CheckTrainer, ToLearn, true) end
            end)
        end
    end)
end)
