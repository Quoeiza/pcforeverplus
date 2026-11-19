-- ProfitCrafter: learning from your own results
--   Keeps a small record per character of what happens to your auctions and your choices, and
--   nudges the addon with it:
--     1. Sell-through: items that keep coming back unsold get a smaller share of the market when
--        planning; items that always sell get a little more.
--     2. Prices: an item that came back unsold is undercut a little deeper next time (up to 5%);
--        one that sold within 4 hours eases back.
--     3. Your habits: skip the undercut check 3 times in a row and it's offered less often (2h, then
--        4h). Untick the same recipe 3 times and Make me gold leaves it out.
--     4. Bad bets: items you purged, or that came back unsold twice in a row, rank lower in Make me
--        gold until they sell again.
--   /pc learned shows it; /pc learned reset forgets it; Settings > "Learn from my results" turns it off.

local ADDON, ns = ...
local PC = ns.PC

local Learn = {}
PC.Learn = Learn

Learn.MAX_CUT = 0.05       -- deepest extra undercut it will learn (5%)
Learn.FAST = 4 * 3600      -- "sold quickly"

function Learn:On() return PC.db and PC.db.learn ~= false end

function Learn:Data()
    PC.cdb.learn = PC.cdb.learn or { items = {}, recipes = {}, undercutSkips = 0 }
    local d = PC.cdb.learn
    d.items, d.recipes = d.items or {}, d.recipes or {}
    return d
end

function Learn:Item(itemID)
    local items = self:Data().items
    items[itemID] = items[itemID] or { posted = 0, sold = 0, returned = 0, hours = 0, sales = 0, cut = 0, penalty = 0, streak = 0 }
    return items[itemID]
end

---------------------------------------------------------------------------
-- What happened (called from posting, the mail, purges, the steps list)
---------------------------------------------------------------------------
function Learn:Posted(itemID, n)
    if not itemID then return end
    local it = self:Item(itemID)
    it.posted = it.posted + (n or 1)
    it.lastPost = time()
end

function Learn:Sold(itemID, n)
    if not itemID then return end
    local it = self:Item(itemID)
    it.sold = it.sold + (n or 1)
    local took = it.lastPost and (time() - it.lastPost) or nil
    if took then it.hours, it.sales = it.hours + took / 3600, it.sales + 1 end
    if took and took <= self.FAST then it.cut = math.max(it.cut - 0.005, 0) end -- sold fast: ease off
    it.streak = 0
    it.penalty = math.max(it.penalty - 0.1, 0) -- it sells after all
end

function Learn:Returned(itemID, n)
    if not itemID then return end
    local it = self:Item(itemID)
    it.returned = it.returned + (n or 1)
    it.cut = math.min(it.cut + 0.01, self.MAX_CUT) -- came back: undercut a bit deeper next time
    it.streak = it.streak + 1
    if it.streak >= 2 then it.penalty = math.min(it.penalty + 0.2, 0.8) end
end

function Learn:Purged(itemID)
    if not itemID then return end
    local it = self:Item(itemID)
    it.penalty = math.min(it.penalty + 0.2, 0.8)
end

function Learn:SkippedUndercut()
    local d = self:Data()
    d.undercutSkips = (d.undercutSkips or 0) + 1
end

function Learn:UsedUndercut()
    self:Data().undercutSkips = 0
end

function Learn:Unticked(recipeID)
    local r = self:Data().recipes
    r[recipeID] = (r[recipeID] or 0) + 1
end

function Learn:Ticked(recipeID)
    self:Data().recipes[recipeID] = nil
end

---------------------------------------------------------------------------
-- What it means (read by planning, pricing and the Next step)
---------------------------------------------------------------------------
-- share of sales that actually sold (nil until there's enough to go on)
function Learn:Ratio(itemID)
    local it = self:Data().items[itemID]
    if not it or it.posted < 5 or it.sold + it.returned < 3 then return nil end
    return it.sold / (it.sold + it.returned)
end

-- multiply the planned market share by this
function Learn:ShareFactor(itemID)
    if not self:On() then return 1 end
    local r = self:Ratio(itemID)
    if not r then return 1 end
    if r < 0.5 then return math.max(r * 2, 0.25) end
    if r > 0.9 then return 1.25 end
    return 1
end

-- extra undercut (fraction of the price)
function Learn:Cut(itemID)
    if not self:On() then return 0 end
    local it = self:Data().items[itemID]
    return it and it.cut or 0
end

-- how much lower to rank it in Make me gold (0 = not at all)
function Learn:Penalty(itemID)
    if not self:On() then return 0 end
    local it = self:Data().items[itemID]
    return it and it.penalty or 0
end

-- seconds between undercut checks: 1h, 2h after 3 skips in a row, 4h after 6
function Learn:UndercutEvery(base)
    if not self:On() then return base end
    local skips = self:Data().undercutSkips or 0
    return base * math.min(2 ^ math.floor(skips / 3), 4)
end

-- unticked 3 times: Make me gold leaves it out
function Learn:Avoided(recipeID)
    if not self:On() then return false end
    return (self:Data().recipes[recipeID] or 0) >= 3
end

---------------------------------------------------------------------------
-- /pc learned
---------------------------------------------------------------------------
function Learn:Report()
    local Print = PC.Print
    if not self:On() then Print("Learning is off (Settings > Learn from my results).") end
    local d = self:Data()
    local rows = {}
    for id, it in pairs(d.items) do
        if it.posted > 0 or it.penalty > 0 then rows[#rows + 1] = { id = id, it = it } end
    end
    table.sort(rows, function(a, b) return a.it.posted > b.it.posted end)
    if #rows == 0 then Print("Nothing learned yet: it starts with your first posts and sales.") end
    for i = 1, math.min(#rows, 10) do
        local id, it = rows[i].id, rows[i].it
        local r = self:Ratio(id)
        local parts = { ("%d posted, %d sold, %d back"):format(it.posted, it.sold, it.returned) }
        if r then parts[#parts + 1] = ("sells %d%%"):format(math.floor(r * 100 + 0.5)) end
        if it.sales > 0 then parts[#parts + 1] = ("~%.1fh to sell"):format(it.hours / it.sales) end
        if it.penalty > 0 then parts[#parts + 1] = ("ranked %d%% lower"):format(math.floor(it.penalty * 100 + 0.5)) end
        Print(("  %s: %s"):format(PC:ItemName(id) or ("item " .. id), table.concat(parts, ", ")))
    end
    local avoided = {}
    for id, n in pairs(d.recipes) do
        if n >= 3 and PC.cdb.recipes[id] then avoided[#avoided + 1] = PC.cdb.recipes[id].name end
    end
    if #avoided > 0 then Print("  Left out of Make me gold (you kept unticking them): " .. table.concat(avoided, ", ")) end
    if (d.undercutSkips or 0) >= 3 then
        Print(("  Undercut check: every %dh (you've skipped it %d times in a row)."):format(self:UndercutEvery(3600) / 3600, d.undercutSkips))
    end
end

function Learn:Reset()
    PC.cdb.learn = nil
    PC.Print("Forgot everything ProfitCrafter had learned for this character.")
    PC:RefreshUI()
end
