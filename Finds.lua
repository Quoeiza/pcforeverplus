-- ProfitCrafter: recipes players find, shared with everyone
--   When you loot a recipe (from a creature, a treasure, a container or fishing), get one as a quest
--   reward, or read a trainer's list, ProfitCrafter notes where, and tells every other ProfitCrafter
--   user through the hidden MostlyNotBrokenAddons channel. What they find comes to you the same way.
--   It all goes on the Learn tab: recipes the data has no spot for, and new ones it doesn't know at all.
--   (Vendors are already shared with what they sell: Places and Share do that.)

local ADDON, ns = ...
local PC = ns.PC

local Finds = {}
PC.Finds = Finds

Finds.MAX = 3000         -- recipes remembered
Finds.SPOTS = 6          -- spots per recipe
Finds.GOSSIP_EVERY = 20 * 60
Finds.GOSSIP_N = 5       -- finds passed on each time (so everyone gets them, even if they weren't on)
Finds.MAX_LEN = 240

---------------------------------------------------------------------------
-- Storage (account-wide): db.recipeFinds["Tailoring:runecloth belt"] = { name, prof, skill, level, item,
--   t, spots = { { source, where, map, x, y, zone, cost, fac, t, who, n } } }
-- db.trainerLists[faction][prof][norm] = { name, skill, level, cost, trainer = place key, heard }
---------------------------------------------------------------------------
function Finds:Table()
    PC.db.recipeFinds = PC.db.recipeFinds or {}
    local t = PC.db.recipeFinds
    -- finds heard before this check: ones named in another alphabet dropped, their places in this
    -- client's language (once a session)
    if not self.localised then
        self.localised = true
        for k, e in pairs(t) do
            if PC.Foreign(e.name) or PC.Foreign(e.prof) then t[k] = nil
            else for _, sp in ipairs(e.spots or {}) do self:LocaliseSpot(sp) end end
        end
    end
    return t
end

-- A spot another player sent: the zone from its map, a name in another alphabet left out
function Finds:LocaliseSpot(sp)
    local z = sp.map and PC.Places and PC.Places.MapName and PC.Places.MapName(sp.map)
    if z and (sp.zone == nil or PC.Foreign(sp.zone)) then sp.zone = z end
    if PC.Foreign(sp.zone) then sp.zone = nil end
    if PC.Foreign(sp.where) then sp.where = "" end
    return sp
end

function Finds:Trainers()
    PC.db.trainerLists = PC.db.trainerLists or {}
    local f = PC:Faction()
    PC.db.trainerLists[f] = PC.db.trainerLists[f] or {}
    return PC.db.trainerLists[f]
end

local function Clean(s)
    if s == nil then return "" end
    return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[|^~]", ""))
end

-- "Pattern: Runecloth Belt" -> "Runecloth Belt"
function Finds:RecipeName(itemName)
    local n = Clean(itemName)
    for _, p in ipairs({ "Pattern", "Plans", "Recipe", "Formula", "Schematic", "Manual", "Design", "Technique", "Book" }) do
        local rest = n:match("^" .. p .. ":%s*(.+)$")
        if rest then return rest end
    end
    return n
end

-- Note a find. heard = it came from someone else (who). Returns true when it's something new to us.
function Finds:Add(f, heard, who)
    if not f or not f.prof or not f.name or f.name == "" or not f.source then return false end
    local T = PC.ToLearn
    local key = f.prof .. ":" .. (T and T:Norm(f.name) or f.name:lower())
    local t = self:Table()
    local e = t[key]
    local new = false
    if not e then
        e = { name = f.name, prof = f.prof, spots = {} }
        t[key] = e
        new = true
        self:Trim()
    end
    e.skill = e.skill or tonumber(f.skill)
    e.level = e.level or tonumber(f.level)
    e.item = e.item or tonumber(f.item)
    e.t = time()
    local where = f.where or ""
    local sp
    for _, s in ipairs(e.spots) do
        if s.source == f.source and s.where == where and (s.map or 0) == (tonumber(f.map) or 0) then sp = s break end
    end
    if sp then
        sp.t = time()
        -- someone else saw it there too: confirmed
        if heard and who ~= sp.who then sp.n = (sp.n or 1) + 1 end
        if not sp.x and f.x then sp.x, sp.y, sp.zone = tonumber(f.x), tonumber(f.y), f.zone end
    else
        sp = { source = f.source, where = where, map = tonumber(f.map), x = tonumber(f.x), y = tonumber(f.y), zone = f.zone,
            cost = tonumber(f.cost), fac = f.fac, t = time(), who = heard and who or nil, n = 1 }
        table.insert(e.spots, 1, sp)
        while #e.spots > self.SPOTS do table.remove(e.spots) end
        new = true
    end
    if new and T then T:Changed() end
    if not heard then
        self:Send(e, sp)
        if new then PC:Note("Recipe found", { ("%s: %s, %s. Shared with other ProfitCrafter users."):format(e.name, sp.source, sp.where ~= "" and sp.where or (sp.zone or "")) }) end
    end
    return new
end

-- keep the list to MAX recipes (the ones heard of longest ago go first)
function Finds:Trim()
    local t = self:Table()
    local n, oldest, oldKey = 0, nil, nil
    for k, e in pairs(t) do
        n = n + 1
        if not oldest or (e.t or 0) < oldest then oldest, oldKey = e.t or 0, k end
    end
    if n > self.MAX and oldKey then t[oldKey] = nil end
end

-- The spot to show: your faction's (or anyone's for drops), confirmed and recent first
function Finds:BestSpot(e)
    local mine = PC:Faction()
    local best
    for _, sp in ipairs(e.spots or {}) do
        local usable = sp.source ~= "Quest" or not sp.fac or sp.fac == "" or sp.fac == mine
        if usable and (not best or (sp.map and not best.map) or ((sp.n or 1) > (best.n or 1))) then best = sp end
    end
    return best or (e.spots and e.spots[1])
end

function Finds:Place(sp)
    if not sp or not sp.map or not sp.x or not sp.y then return nil end
    return { kind = "npc", name = (sp.where ~= "" and sp.where) or sp.zone or "Recipe", zone = sp.zone or "", map = sp.map,
        x = sp.x, y = sp.y, found = true, confirmed = (sp.n or 1) > 1 }
end

function Finds:Text(e, sp)
    local lines = {}
    if sp.who then lines[#lines + 1] = "Found by " .. sp.who .. ((sp.n or 1) > 1 and (" and %d more"):format(sp.n - 1) or "")
    else lines[#lines + 1] = "You found it here" end
    if #(e.spots or {}) > 1 then
        local others = {}
        for _, s in ipairs(e.spots) do
            if s ~= sp and #others < 3 then others[#others + 1] = (s.where ~= "" and s.where or s.source) .. (s.zone and s.zone ~= "" and (" (" .. s.zone .. ")") or "") end
        end
        if #others > 0 then lines[#lines + 1] = "Also: " .. table.concat(others, ", ") end
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Finding them
---------------------------------------------------------------------------
-- A recipe item: { name, prof, skill, level } (nil = not a recipe, or not loaded yet)
function Finds:Recipe(itemID)
    local ri = PC.ToLearn and PC.ToLearn:RecipeItem(itemID)
    if not ri or not ri.prof or not ri.name then return nil end
    return ri
end

local function NPCFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)")
    return kind, tonumber(id)
end

-- Who dropped it: the target or mouseover with that GUID, else the name we know for that creature
local function CreatureName(guid, npc)
    for _, u in ipairs({ "target", "mouseover" }) do
        if UnitGUID and UnitGUID(u) == guid then return UnitName(u) end
    end
    local n = npc and PC.db.npcNames and PC.db.npcNames[npc]
    if n then return n end
    if npc and PC.ToLearn and PC.ToLearn.NPCName then return PC.ToLearn:NPCName(npc) end
    return nil
end

function Finds:Spot(source, where, extra)
    local map, x, y, zone
    if PC.Places then map, x, y, zone = PC.Places:Here() end
    local f = { source = source, where = where, map = map, x = x, y = y, zone = zone, fac = PC:Faction() }
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end

function Finds:FromRecipe(ri, f)
    f.prof, f.name, f.skill, f.level = ri.prof, self:RecipeName(ri.name), ri.skill, ri.level
    return f
end

-- The loot window: a recipe in it is a find (who dropped it, or the treasure, container or fishing spot)
function Finds:OnLoot()
    if not GetNumLootItems or not GetLootSlotLink then return end
    local fishing = IsFishingLoot and IsFishingLoot()
    for slot = 1, GetNumLootItems() or 0 do
        local link = GetLootSlotLink(slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        local ri = id and self:Recipe(id)
        if ri then
            local source, where = "Drop", nil
            if fishing then
                source = "Fishing"
            elseif GetLootSourceInfo then
                local ok, guid = pcall(GetLootSourceInfo, slot)
                local kind, npc = NPCFromGUID(ok and guid or nil)
                if kind == "Creature" or kind == "Vehicle" then
                    where = CreatureName(guid, npc)
                    if where and npc then PC.db.npcNames = PC.db.npcNames or {}; PC.db.npcNames[npc] = where end
                elseif kind == "GameObject" then source = "Treasure"
                elseif type(guid) == "string" and guid:find("^Item") then source = "Container" end
            end
            local f = self:FromRecipe(ri, self:Spot(source, where or "", { item = id }))
            if source == "Drop" and where then f.where = where end
            if source ~= "Drop" or where then f.fac = "" end -- drops and treasures: either faction
            self:Add(f)
        end
    end
end

-- Quest rewards: the reward window remembers the quest; a recipe pushed into your bags right after is a find
function Finds:OnQuestComplete()
    local title = GetTitleText and GetTitleText()
    self.quest = { title = Clean(title), giver = UnitName and UnitName("npc"), t = GetTime and GetTime() or 0, spot = self:Spot("Quest", Clean(title)) }
end

function Finds:OnLootMessage(msg)
    if PC.IsSecret(msg) then return end -- (kept secret by the game at times: can't be read)
    local q = self.quest
    if not q or not msg or (GetTime() - q.t) > 15 then return end
    local fmt = LOOT_ITEM_PUSHED_SELF or "You receive item: %s."
    local pat = "^" .. fmt:gsub("%%s", "\001"):gsub("([%%%.%(%)%-%+%*%?%[%]%^%$])", "%%%1"):gsub("\001", "(.+)")
    local link = msg:match(pat)
    local id = link and tonumber(link:match("item:(%d+)"))
    local ri = id and self:Recipe(id)
    if not ri then return end
    local f = self:FromRecipe(ri, q.spot)
    f.item = id
    if q.giver then f.zone = (f.zone and f.zone ~= "" and (f.zone .. ", ") or "") .. "from " .. Clean(q.giver) end
    self:Add(f)
end

---------------------------------------------------------------------------
-- Sharing
--   F|faction|prof|name|source|where|map|x|y|zone|skill|level|cost|item
--   T|faction|trainer key|prof|name~skill~level~cost^name~skill~level~cost...
---------------------------------------------------------------------------
local function N(v, fmt) if v == nil then return "" end return fmt and fmt:format(v) or tostring(v) end

function Finds:Send(e, sp)
    if not PC.Share or not PC.Share.SendRaw then return end
    local msg = ("F|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s"):format(PC:Faction(), Clean(e.prof), Clean(e.name), Clean(sp.source),
        Clean(sp.where), N(sp.map), N(sp.x, "%.4f"), N(sp.y, "%.4f"), Clean(sp.zone), N(e.skill), N(e.level), N(sp.cost), N(e.item))
    if #msg > 250 then return end
    PC.Share:SendRaw(msg)
end

-- A trainer's list, once a day per trainer
function Finds:ShareTrainer(key)
    if not key or not PC.Share or not PC.Share.SendRaw or not PC.ToLearn then return end
    self.trainerSent = self.trainerSent or {}
    if self.trainerSent[key] and time() - self.trainerSent[key] < 86400 then return end
    self.trainerSent[key] = time()
    local d = PC.ToLearn.Data()
    for prof, list in pairs(d.trainer or {}) do
        local head = ("T|%s|%s|%s|"):format(PC:Faction(), Clean(key), Clean(prof))
        local parts, len = {}, #head
        for _, t in pairs(list) do
            if t.trainer == key and t.name then
                local piece = ("%s~%s~%s~%s"):format(Clean(t.name), N(t.skill), N(t.level), N(t.cost))
                if len + #piece + 1 > self.MAX_LEN then
                    PC.Share:SendRaw(head .. table.concat(parts, "^"))
                    parts, len = {}, #head
                end
                parts[#parts + 1] = piece
                len = len + #piece + 1
            end
        end
        if #parts > 0 then PC.Share:SendRaw(head .. table.concat(parts, "^")) end
    end
end

local function Split(s, sep)
    local out = {}
    for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = piece end
    return out
end

local function Nil(s) if s == nil or s == "" then return nil end return s end

-- kind F (any faction: a drop is a drop) or T (your faction's trainers)
function Finds:OnMessage(kind, faction, rest, who)
    if kind == "F" then
        local p = Split(rest, "|")
        local f = { prof = Nil(p[1]), name = Nil(p[2]), source = Nil(p[3]), where = p[4] or "", map = tonumber(p[5]), x = tonumber(p[6]),
            y = tonumber(p[7]), zone = Nil(p[8]), skill = tonumber(p[9]), level = tonumber(p[10]), cost = tonumber(p[11]),
            item = tonumber(p[12]), fac = faction }
        -- from a client in another language: a recipe named in another alphabet can't be matched; its place
        -- in this client's language
        if PC.Foreign(f.name) or PC.Foreign(f.prof) then return end
        self:LocaliseSpot(f)
        -- the other faction's quest or vendor isn't yours to use: keep it, it's shown as theirs
        if f.prof and f.name and f.source then self:Add(f, true, who) end
        return
    end
    if kind == "T" and faction == PC:Faction() then
        local key, prof, body = rest:match("^([^|]*)|([^|]*)|(.*)$")
        if not key or key == "" or not prof or prof == "" then return end
        local T = self:Trainers()
        T[prof] = T[prof] or {}
        for piece in (body .. "^"):gmatch("(.-)%^") do
            local name, skill, level, cost = piece:match("^([^~]*)~([^~]*)~([^~]*)~([^~]*)$")
            if name and name ~= "" and not PC.Foreign(name) then
                local norm = PC.ToLearn and PC.ToLearn:Norm(name) or name:lower()
                T[prof][norm] = { name = name, skill = tonumber(skill), level = tonumber(level), cost = tonumber(cost), trainer = key, heard = time() }
            end
        end
        if PC.ToLearn then PC.ToLearn:Changed() end
    end
end

-- Pass a few finds on now and then, so players who weren't on when they were found still get them
function Finds:Gossip()
    if not PC.Share or not PC.Share.SendRaw or not PC.db then return end
    local keys = {}
    for k in pairs(self:Table()) do keys[#keys + 1] = k end
    for _ = 1, math.min(self.GOSSIP_N, #keys) do
        local i = math.random(#keys)
        local e = self:Table()[keys[i]]
        table.remove(keys, i)
        local sp = e and self:BestSpot(e)
        if sp then self:Send(e, sp) end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "LOOT_OPENED", "QUEST_COMPLETE", "CHAT_MSG_LOOT", "TRAINER_SHOW" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event, a1)
    PC:Safe("recipe finds", function()
        if not PC.db then return end
        if event == "LOOT_OPENED" then
            Finds:OnLoot()
        elseif event == "QUEST_COMPLETE" then
            Finds:OnQuestComplete()
        elseif event == "CHAT_MSG_LOOT" then
            Finds:OnLootMessage(a1)
        elseif event == "TRAINER_SHOW" then
            -- (after the Learn tab has read the trainer's list)
            C_Timer.After(1, function() PC:Safe("recipe finds", function()
                local npc = UnitName and UnitName("npc") or "Trainer"
                local map = PC.Places and PC.Places:Here()
                local key = PC.Places and PC.Places.Key and PC.Places.Key("trainer", map, 0, 0, npc)
                Finds:ShareTrainer(key)
            end) end)
        elseif event == "PLAYER_LOGIN" then
            C_Timer.After(90, function() PC:Safe("recipe finds", Finds.Gossip, Finds) end)
            if C_Timer.NewTicker then C_Timer.NewTicker(Finds.GOSSIP_EVERY, function() PC:Safe("recipe finds", Finds.Gossip, Finds) end) end
        end
    end)
end)
