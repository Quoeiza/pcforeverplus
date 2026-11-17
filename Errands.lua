-- ProfitCrafter: errands (mailbox, vendors, price alerts)

local ADDON, ns = ...
local PC = ns.PC

local function Safe(name, fn, ...) return PC:Safe(name, fn, ...) end
local On = PC.AutoOn
local Bags = PC.BagSlots
local UseBagItem = PC.UseBagItem
local Sell = PC.Sell

---------------------------------------------------------------------------
-- Toast: a small note near the top of the screen (mail collected, things bought and sold); click it to
-- close, drag it to move (the spot is remembered for the next ones), it fades on its own
---------------------------------------------------------------------------
local Toast = {}
PC.Toast = Toast
Toast.TIME = 14  -- seconds on screen (twice the old 7)
Toast.FADE = 1.5 -- the last part fades out
Toast.list = {}

function Toast:Frame(i)
    local t = self.list[i]
    if t then return t end
    t = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    t:SetSize(320, 40)
    t:SetFrameStrata("DIALOG")
    if t.SetBackdrop then
        t:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        t:SetBackdropColor(0.07, 0.05, 0.03, 0.94)
        t:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
    end
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(18, 18)
    t.icon:SetPoint("TOPLEFT", 10, -9)
    t.title = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t.title:SetPoint("LEFT", t.icon, "RIGHT", 6, 0)
    t.title:SetPoint("RIGHT", -10, 0)
    t.title:SetJustifyH("LEFT")
    t.body = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.body:SetPoint("TOPLEFT", 12, -30)
    t.body:SetWidth(296)
    t.body:SetJustifyH("LEFT")
    t.body:SetSpacing(2)
    t:EnableMouse(true)
    t:SetMovable(true)
    t:SetClampedToScreen(true)
    t:RegisterForDrag("LeftButton")
    t:SetScript("OnDragStart", function(f) f.dragged = true; f:StartMoving() end)
    t:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        -- remember where its top middle sits; the next notes start there
        local l, top, w = f:GetLeft(), f:GetTop(), f:GetWidth()
        if l and top and w and PC.db then PC.db.toastPos = { x = l + w / 2, y = top } end
        Toast:Place()
    end)
    t:SetScript("OnMouseUp", function(f)
        if f.dragged then f.dragged = nil return end
        f:Hide(); Toast:Place()
    end)
    -- hover keeps it; moving off starts the time again; it fades out at the end
    t:SetScript("OnEnter", function(f) f.hover = true; f:SetAlpha(1) end)
    t:SetScript("OnLeave", function(f) f.hover = false; f.left = Toast.TIME end)
    t:SetScript("OnUpdate", function(f, dt)
        if f.hover or not f.left then return end
        f.left = f.left - (dt or 0)
        if f.left <= 0 then
            f.left = nil; f:Hide(); f:SetAlpha(1); Toast:Place()
        elseif f.left < Toast.FADE then
            f:SetAlpha(f.left / Toast.FADE)
        end
    end)
    t:Hide()
    self.list[i] = t
    return t
end

function Toast:Place()
    local pos = PC.db and PC.db.toastPos
    local y = pos and pos.y or -120
    for _, t in ipairs(self.list) do
        if t:IsShown() then
            t:ClearAllPoints()
            if pos then t:SetPoint("TOP", UIParent, "BOTTOMLEFT", pos.x, y)
            else t:SetPoint("TOP", UIParent, "TOP", 0, y) end
            y = y - (t:GetHeight() or 40) - 6
        end
    end
end

-- Show a note: title plus a few lines
function PC:ToastNote(title, lines)
    local slot
    for i = 1, 3 do
        local t = Toast:Frame(i)
        if not t:IsShown() then slot = t break end
    end
    slot = slot or Toast:Frame(1)
    slot.icon:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\Icon") -- the PC logo
    slot.title:SetText(title)
    lines = lines or {}
    -- a long list: the toast shows the first part, the chat gets all of it
    local MAX = 16
    if #lines > MAX then
        PC.Print(title .. ":")
        for _, l in ipairs(lines) do PC.Print("  " .. l) end
        local short = {}
        for i = 1, MAX - 1 do short[i] = lines[i] end
        short[MAX] = ("|cff888888...and %d more lines (the full list is in your chat).|r"):format(#lines - (MAX - 1))
        lines = short
    end
    slot.body:SetText(table.concat(lines, "\n"))
    local h = (slot.body.GetStringHeight and slot.body:GetStringHeight()) or (#(lines or {}) * 14)
    slot:SetHeight(38 + h)
    slot:SetAlpha(1)
    slot.left, slot.hover = Toast.TIME, false
    slot:Show()
    Toast:Place()
end

-- Bought or sold something (AH, vendor): gathered for a moment, then one note for all of it
-- section: "Bought on the AH", "Bought from a vendor", "Sold to a vendor"
Toast.SECTIONS = { "Bought on the AH", "Bought from a vendor", "Sold to a vendor" }
function PC:Activity(section, item, qty, money)
    if not section or not item then return end
    local a = Toast.activity or { }
    Toast.activity = a
    a[section] = a[section] or { order = {}, rows = {} }
    local sec = a[section]
    local name = type(item) == "number" and (PC:ItemName(item) or ("item " .. item)) or tostring(item)
    local r = sec.rows[name]
    if not r then r = { n = 0, money = 0 }; sec.rows[name] = r; sec.order[#sec.order + 1] = name end
    r.n = r.n + (qty or 1)
    r.money = r.money + (money or 0)
    self:Debounce("activity toast", 1.5, function() Safe("notes", Toast.FlushActivity, Toast) end)
end

-- Crafted: one note per batch (when you stop casting), not one per item
local function Casting()
    for _, fn in ipairs({ UnitCastingInfo, UnitChannelInfo }) do
        if fn then
            local ok, name = pcall(fn, "player")
            if ok and name ~= nil then return true end
        end
    end
    return false
end

function PC:CraftedOne(r)
    if not r then return end
    local c = Toast.crafted or { order = {}, rows = {} }
    Toast.crafted = c
    local name = (r.output and PC:ItemName(r.output)) or r.name or "item"
    if not c.rows[name] then c.rows[name] = 0; c.order[#c.order + 1] = name end
    c.rows[name] = c.rows[name] + math.max(r.qty or 1, 1)
    c.gen = (c.gen or 0) + 1
    local gen = c.gen
    local function check()
        if Toast.crafted ~= c or c.gen ~= gen then return end -- another craft came in: it checks
        if Casting() then return C_Timer.After(1.2, check) end -- the next one of the batch is underway
        Toast.crafted = nil
        local lines = {}
        for _, n in ipairs(c.order) do lines[#lines + 1] = ("%d %s"):format(c.rows[n], n) end
        PC:ToastNote("Crafted", lines)
    end
    C_Timer.After(1.2, check)
end

function Toast:FlushActivity()
    local a = self.activity
    self.activity = nil
    if not a then return end
    local used = {}
    for _, name in ipairs(self.SECTIONS) do if a[name] then used[#used + 1] = name end end
    if #used == 0 then return end
    local lines = {}
    for _, name in ipairs(used) do
        local sec = a[name]
        if #used > 1 then lines[#lines + 1] = name .. ":" end
        local total = 0
        for _, item in ipairs(sec.order) do
            local r = sec.rows[item]
            total = total + r.money
            lines[#lines + 1] = ("%s%d %s%s"):format(#used > 1 and "  " or "", r.n, item,
                r.money > 0 and (": " .. PC:Money(r.money)) or "")
        end
        if #sec.order > 1 and total > 0 then
            lines[#lines + 1] = ("%s|cffa0a0a0Total: %s|r"):format(#used > 1 and "  " or "", PC:Money(total))
        end
    end
    PC:ToastNote(#used == 1 and used[1] or "Bought and sold", lines)
end

---------------------------------------------------------------------------
-- Mailbox: collect AH purchases and sale gold (leaves all other mail alone)
---------------------------------------------------------------------------
local Mail = {}
PC.Mail = Mail
Mail.GAP = 0.4

function Mail:Open() return self.open and true or false end

-- Skip on a mailbox step: not asked again for an hour (saved, so a reload doesn't bring it back)
Mail.SNOOZE = 3600
function Mail:Snooze()
    PC.cdb.mailSnooze = time() + self.SNOOZE
    PC.Buy:Say("Mailbox skipped: I'll remind you again in an hour.")
    PC:RefreshUI()
end
-- Close enough to bother with the mail: at the mailbox, or within 50 yards of one you've used
Mail.NEAR = 50
function Mail:Near()
    if self:Open() then return true end
    local P = PC.Places
    if not P then return false end
    local box, d = P:Nearest("mail")
    return box ~= nil and d ~= nil and d * 10 <= self.NEAR
end

function Mail:Snoozed()
    return PC.cdb and PC.cdb.mailSnooze and time() < PC.cdb.mailSnooze or false
end

-- Is there unread mail waiting? (the envelope icon by the minimap)
function Mail:HasNew()
    if HasNewMail and HasNewMail() then return true end
    return self.newMail and true or false
end

-- AH mails with something to take: { index, kind = "buyer"/"seller", money, items }
function Mail:List()
    local out = {}
    if not GetInboxNumItems or not GetInboxInvoiceInfo then return out end
    for i = (GetInboxNumItems() or 0), 1, -1 do
        local invoiceType = GetInboxInvoiceInfo(i)
        local _, _, _, _, money, cod, _, itemCount = GetInboxHeaderInfo(i)
        if (cod or 0) == 0 then
            if invoiceType == "buyer" and (itemCount or 0) > 0 then
                out[#out + 1] = { index = i, kind = "buyer", items = itemCount }
            elseif invoiceType == "seller" and (money or 0) > 0 then
                out[#out + 1] = { index = i, kind = "seller", money = money }
            elseif not invoiceType and (itemCount or 0) > 0 then
                -- an expired or cancelled auction coming back (the AH sends it with no invoice)
                local _, _, sender, subject = GetInboxHeaderInfo(i)
                local fromAH = (sender or ""):lower():find("auction") or (subject or ""):lower():find("auction")
                if fromAH then out[#out + 1] = { index = i, kind = "returned", items = itemCount, cancelled = (subject or ""):lower():find("cancel") and true or false } end
            end
        end
    end
    return out
end

function Mail:Count() return #self:List() end

-- any gold from sales waiting (that needs no bag room)?
function Mail:HasMoney()
    if not self.open then return false end
    for _, m in ipairs(self:List()) do if m.kind == "seller" then return true end end
    return false
end

local function FreeSlots()
    local free = 0
    local C = C_Container
    local fn = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if not fn then return 99 end
    for _, bag in ipairs(PC:PlayerBags()) do free = free + ((fn(bag)) or 0) end
    return free
end

function Mail:Collect(quiet)
    if self.busy or not self.open then return end
    self.busy = true
    self.got = { items = {}, returned = {}, money = 0, sales = {} }
    self.quiet = quiet
    self:Step()
end

function Mail:Step()
    if not self.open then self.busy = false return end
    local list = self:List()
    local m = list[1]
    if not m then return self:Done() end
    -- bags full (down to the slot crafting needs): the gold still comes out; the items wait for room
    if m.kind ~= "seller" and FreeSlots() <= (PC.BUY_RESERVE or 1) then
        m = nil
        for _, x in ipairs(list) do if x.kind == "seller" then m = x break end end
        if not m then
            local left = #list
            self.itemsWaiting = left
            PC.Print(("Bags full: %d mail%s with items left in the mailbox. I'll bring you back once there's room."):format(left, left == 1 and "" or "s"))
            return self:Done()
        end
    end
    if m.kind == "seller" then
        self.got.money = self.got.money + (m.money or 0)
        -- the sale: that many fewer of it posted
        if PC.Posted and GetInboxInvoiceInfo then
            local _, itemName, _, _, _, _, _, _, _, _, count = GetInboxInvoiceInfo(m.index)
            PC.Posted:RemoveByName(itemName, count or 1)
            -- where the gold came from, for the summary
            local k = itemName or "an auction"
            local e = self.got.sales[k] or { n = 0, money = 0 }
            e.n, e.money = e.n + (count or 1), e.money + (m.money or 0)
            self.got.sales[k] = e
        end
        TakeInboxMoney(m.index)
    else
        if FreeSlots() <= (PC.BUY_RESERVE or 1) then return self:Step() end -- (handled above: gold first, items wait)
        local name, _, _, count
        for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
            name, _, _, count = GetInboxItem(m.index, a)
            if name then
                if m.kind == "returned" then
                    self.got.returned[name] = (self.got.returned[name] or 0) + (count or 1)
                    if PC.Posted then PC.Posted:RemoveByName(name, count or 1) end
                    -- expired unsold (not one you cancelled): the learning notes it
                    if not m.cancelled and PC.Learn then PC.Learn:Returned(PC:ItemIDByName(name), count or 1) end
                else
                    self.got.items[name] = (self.got.items[name] or 0) + (count or 1)
                end
                TakeInboxItem(m.index, a)
                break
            end
        end
    end
    C_Timer.After(self.GAP, function() Safe("mail", Mail.Step, Mail) end)
end

function Mail:Done()
    self.busy = false
    if self.open and self:Count() == 0 and PC.cdb then PC:MailEmptied(); self.itemsWaiting = nil end
    local lines = {}
    local function section(header, t)
        local rows = {}
        for name, n in pairs(t) do rows[#rows + 1] = n .. " " .. name end
        table.sort(rows)
        if #rows == 0 then return end
        lines[#lines + 1] = header
        for _, r in ipairs(rows) do lines[#lines + 1] = "  " .. r end
    end
    section("Items (your AH purchases):", self.got.items)
    section("Back from the AH (unsold or cancelled):", self.got.returned)
    if self.got.money > 0 then
        lines[#lines + 1] = "Gold: " .. PC:Money(self.got.money) .. " from sales of"
        local rows = {}
        for name, e in pairs(self.got.sales or {}) do rows[#rows + 1] = { name = name, n = e.n, money = e.money } end
        table.sort(rows, function(a, b) return a.money > b.money end)
        for _, r in ipairs(rows) do lines[#lines + 1] = ("  %d %s: %s"):format(r.n, r.name, PC:Money(r.money)) end
    end
    if #lines > 0 then
        lines[#lines + 1] = "|cff888888Your other mail was left alone.|r"
        PC:ToastNote("Collected from the mail", lines)
        if (self.got.money or 0) > 0 then PC:Sound("sold") end
    end
    PC:RefreshUI()
end

---------------------------------------------------------------------------
-- Vendors: buy plan materials, sell junk, sell vendor flips
---------------------------------------------------------------------------
local VendorAuto = {}
PC.VendorAuto = VendorAuto

-- Crafted items a vendor pays more for than the AH (after its cut)
-- Everything bought from a vendor is remembered for 2 hours: none of it is sold back to a vendor in
-- that time (buying for more than a vendor pays and selling it straight back only loses gold)
VendorAuto.HOLD = 7200
local function NoteVendorBuy(index, qty)
    local id = GetMerchantItemID and GetMerchantItemID(index)
    if not id and GetMerchantItemLink then
        local link = GetMerchantItemLink(index)
        id = link and tonumber(link:match("item:(%d+)"))
    end
    if id and PC.cdb then
        PC.cdb.vendorBought = PC.cdb.vendorBought or {}
        PC.cdb.vendorBought[id] = time()
    end
    -- the note on screen: what and about how much
    if id and PC.Activity then
        local price, batch
        if GetMerchantItemInfo then
            local _, _, p, b = GetMerchantItemInfo(index)
            price, batch = PC.Num(p), math.max(PC.Num(b) or 1, 1)
        end
        local n = PC.Num(qty) or batch or 1
        PC:Activity("Bought from a vendor", id, n, price and math.floor(price / (batch or 1) * n + 0.5) or nil)
    end
end
if hooksecurefunc and BuyMerchantItem then pcall(hooksecurefunc, "BuyMerchantItem", NoteVendorBuy) end
function VendorAuto:BoughtRecently(id)
    local t = PC.cdb and PC.cdb.vendorBought and PC.cdb.vendorBought[id]
    return t and (time() - t) < self.HOLD or false
end

-- Vendor-sold materials in your bags that the plan no longer needs (Flint and Tinder, vials...),
-- worth selling back once the crafting is done: { id, name, n, value }
-- Everything that can go back to a vendor, in your bags and your bank, for the Sell page:
-- { id, name, bags, bank, each, keep }  (keep = you unticked it)
function VendorAuto:SellBackList()
    local B = PC.Bank
    local keep = B and B:KeepMats() or {}
    local byID, out = {}, {}
    local function add(id, name, bags, bank)
        local e = byID[id]
        if not e then
            e = { id = id, name = name or PC:ItemName(id) or ("item " .. id), bags = 0, bank = 0, each = PC:SellPrice(id) or 0, keep = keep[id] and true or false }
            byID[id] = e
            out[#out + 1] = e
        end
        e.bags, e.bank = e.bags + (bags or 0), e.bank + (bank or 0)
    end
    for _, lo in ipairs(self:Leftovers(nil, true)) do add(lo.id, lo.name, lo.n, 0) end
    if B and B.Leftovers then
        for _, lo in ipairs(B:Leftovers()) do
            if PC:SellLeftovers() and lo.vendor and lo.chosen ~= "craft" and PC:IsVendorItem(lo.id) and not self:BoughtRecently(lo.id) and not PC:NeverSell(lo.id) then add(lo.id, lo.name, 0, lo.n) end
        end
    end
    table.sort(out, function(a, b) return a.each * (a.bags + a.bank) > b.each * (b.bags + b.bank) end)
    return out
end

-- Skip on a "sell back leftovers" step: keep them or store them in the bank (asked once)
function VendorAuto:AskLeftovers(list)
    list = list or self:Leftovers() or {}
    local names = {}
    for _, lo in ipairs(list) do names[#names + 1] = lo.n .. " " .. lo.name end
    if not (PC.UI and PC.UI.Ask) then return self:KeepLeftovers(list) end
    PC.UI:Ask("ProfitCrafterLeftovers", {
        title = "Keep these leftovers?", sub = "They won't be sold back to a vendor",
        sections = { { lines = names }, { lines = { "Keep them in your bags, or store them in the bank?" }, bullets = false } },
        buttons = {
            { text = "Store in bank", onClick = function() VendorAuto:KeepLeftovers(list, true) end },
            { text = "Keep in bags", onClick = function() VendorAuto:KeepLeftovers(list, false) end },
            { text = "Cancel" },
        },
        fit = true,
    })
end

-- Keep leftovers for good (saved), until unticked on the Sell page; toBank: the next bank visit stores them
function VendorAuto:KeepLeftovers(list, toBank)
    local names = {}
    PC.cdb.stashMats = PC.cdb.stashMats or {}
    for _, lo in ipairs(list or self:Leftovers() or {}) do
        self:SetKeep(lo.id, true)
        PC.cdb.stashMats[lo.id] = toBank and true or nil
        names[#names + 1] = lo.name
    end
    if toBank and #names > 0 then
        PC.Buy:Say(("Storing %s in the bank on your next visit; you won't be asked to sell %s back again."):format(
            table.concat(names, ", "), #names == 1 and "it" or "them"))
        PC:RefreshUI()
        return
    end
    if #names > 0 then
        PC.Buy:Say(("Keeping %s: you won't be asked to sell %s back again (untick on the Sell page to change)."):format(
            table.concat(names, ", "), #names == 1 and "it" or "them"))
    end
    PC:RefreshUI()
end

function VendorAuto:SetKeep(itemID, keep)
    local B = PC.Bank
    if not B then return end
    B:KeepMats()[itemID] = keep and true or nil
    PC.cdb.bankSellBack = PC.cdb.bankSellBack or {}
    if keep then PC.cdb.bankSellBack[itemID] = nil end
    B._sb = nil
    PC:RefreshUI()
end

function VendorAuto:Leftovers(entries, includeKept)
    if not PC:SellLeftovers() then return {} end -- leftovers go in the bank for the next craft
    entries = entries or (PC.UI and PC.UI:PlanEntries()) or {}
    local plan = PC.UI and PC.UI.PlanTable and PC.UI:PlanTable() or {}
    local used, need = {}, {}
    for _, e in ipairs(entries) do
        local left = plan[e.id] or 0
        for _, rg in ipairs(e.r.reagents or {}) do
            for _, id in ipairs(PC:ReagentIDs(rg)) do
                used[id] = true
                need[id] = (need[id] or 0) + rg.n * left
            end
        end
    end
    -- recipes you crafted from the plan and finished: their materials count too (the plan forgot them at 0)
    local crafted = PC.cdb.planCrafted or {}
    for _, r in pairs(PC.cdb.recipes or {}) do
        local done = r.output and crafted[r.output]
        for _, o in ipairs(r.outputs or {}) do if crafted[o] then done = true end end
        if done then
            for _, rg in ipairs(r.reagents or {}) do
                for _, id in ipairs(PC:ReagentIDs(rg)) do used[id] = true; need[id] = need[id] or 0 end
            end
        end
    end
    local have = {}
    local sellBack = PC.Bank and PC.Bank:SellBack() or {}
    for id in pairs(sellBack) do used[id] = true; need[id] = 0 end
    local keepMats = PC.Bank and PC.Bank:KeepMats() or {}
    for _, s in ipairs(Bags()) do
        if used[s.id] and (PC:IsVendorItem(s.id) or sellBack[s.id]) and not s.noValue and not s.locked and not PC:IsTool(s.id) and not PC:NeverSell(s.id)
            and not self:BoughtRecently(s.id) then have[s.id] = (have[s.id] or 0) + s.n end
    end
    local out = {}
    for id, n in pairs(have) do
        local extra = n - (need[id] or 0)
        local price = PC.SellPrice and PC:SellPrice(id) or 0
        if extra > 0 and price > 0 and (includeKept or not keepMats[id]) then
            out[#out + 1] = { id = id, name = PC:ItemName(id) or ("item " .. id), n = extra, value = price * extra, kept = keepMats[id] and true or nil }
        end
    end
    table.sort(out, function(a, b) return a.value > b.value end)
    return out
end

-- Crafted goods a vendor pays more for than the AH (and still at a profit): sell them here
function VendorAuto:SellCrafted()
    if not PC.merchantOpen then return 0 end
    local go = {}
    for _, it in ipairs(Sell:Items()) do if it.vendor and it.sellN > 0 then go[it.id] = it.sellN end end
    local sold, value = 0, 0
    -- smallest stacks first so what you keep stays in whole stacks
    local slots = Bags()
    table.sort(slots, function(a, b) return a.n < b.n end)
    for _, bs in ipairs(slots) do
        local left = go[bs.id]
        if left and left >= bs.n and not bs.locked then -- never dips into what you keep
            UseBagItem(bs.bag, bs.slot)
            go[bs.id] = left - bs.n
            sold = sold + bs.n; value = value + (PC:SellPrice(bs.id) or 0) * bs.n
        end
    end
    if sold > 0 then PC.Buy:Say(("|cff40ff40Sold %d crafted to the vendor for %s.|r"):format(sold, PC:Money(value, false, true))) end
    PC:RefreshUI()
    return sold
end

-- Things in your bags the plan has no use for, cheapest per bag slot first: spare materials,
-- crafted goods that won't sell for a profit, spent tools. { id, name, n, value, slots }
function VendorAuto:SpareList()
    local B = PC.Bank
    local out = {}
    for _, it in ipairs(B and B.StoreList and B:StoreList() or {}) do
        local price = PC.SellPrice and PC:SellPrice(it.id) or 0
        local mat = it.kind == "material" or it.kind == "stash" or it.kind == "later"
        if price > 0 and not PC:IsTool(it.id) and not PC:NeverSell(it.id) and not self:BoughtRecently(it.id) and (PC:SellLeftovers() or not mat)
            and not (mat and Sell:LossToVendor(it.id)) then -- tools go in the bank, never to a vendor; materials never at a loss
            local slots = math.ceil(it.qty / PC:StackSize(it.id))
            out[#out + 1] = { id = it.id, name = it.name, n = it.qty, value = price * it.qty, slots = slots, kind = it.kind }
        end
    end
    table.sort(out, function(a, b) return a.value / a.slots < b.value / b.slots end)
    return out
end

function VendorAuto:SellSpare(maxSlots)
    if not PC.merchantOpen then return 0 end
    local want, used = {}, 0
    for _, it in ipairs(self:SpareList()) do
        if maxSlots and used >= maxSlots then break end
        want[it.id] = it.n; used = used + it.slots
    end
    local sold, value = 0, 0
    for _, bs in ipairs(Bags()) do
        local n = want[bs.id]
        if n and n > 0 and not bs.locked and bs.n <= n then
            UseBagItem(bs.bag, bs.slot)
            want[bs.id] = n - bs.n; sold = sold + bs.n
            value = value + (PC:SellPrice(bs.id) or 0) * bs.n
        end
    end
    if sold > 0 then PC.Buy:Say(("|cff40ff40Sold %d spare item%s for %s to make room.|r"):format(sold, sold == 1 and "" or "s", PC:Money(value, false, true))) end
    PC:RefreshUI()
    return sold
end

-- Bags full and nothing more fits: bank first if it has room, else sell the least useful spare
-- things at a vendor. Crafting and buying wait until there's room.
function VendorAuto:MakeRoomStep(s, forName)
    local P = PC.Places
    local tip = { forName and ("No room for %s. Crafting and buying wait until there's room."):format(forName)
        or "Your bags are full: crafting and buying wait until there's room." }
    local Bk = PC.Bank
    local bankRoom = Bk and Bk:Known() and (Bk:FreeSlots() - Bk.BANK_RESERVE) or 0
    local spare = self:SpareList()
    local roomIt
    for _, x in ipairs(Bk and Bk:Known() and Bk:StoreList() or {}) do if x.kind == "room" then roomIt = x end end
    if Bk and Bk:Known() and bankRoom > 0 and #Bk:StoreList() > 0 and not Bk:Open() then
        s.text = "Go to the bank"
        local names = {}
        for _, x in ipairs(Bk:StoreList()) do names[#names + 1] = x.qty .. " " .. (x.name or "") end
        if roomIt then
            tip[1] = "Your bags are full of the plan's materials: one bank trip makes room for several batches."
            tip[#tip + 1] = "Store: " .. table.concat(names, ", ") .. ". They come back out as the crafting uses up what you carry."
        else
            tip[#tip + 1] = "The bank can take: " .. table.concat(names, ", ")
        end
        local p = P and P:Nearest("bank")
        if p then s.dest = p; tip[#tip + 1] = P:Describe(p) end
    elseif #spare > 0 then
        local names = {}
        for i = 1, math.min(4, #spare) do names[#names + 1] = spare[i].n .. " " .. spare[i].name end
        if PC.merchantOpen then
            s.text = ("Sell spare to vendor (%d)"):format(#spare)
            s.run = function() VendorAuto:SellSpare(math.max(Bk and Bk.BAG_RESERVE or 6, 4)) end
        else
            s.text = "Vendor spare items"
            local p = P and P:Nearest("vendor")
            if p then s.dest = p; tip[#tip + 1] = P:Describe(p) end
        end
        tip[#tip + 1] = ((bankRoom <= 0) and "Your bank is full too. " or "") .. "Least useful first: " .. table.concat(names, ", ")
    elseif Sell.purge or Sell.purgeMats then
        -- a purge you said yes to is running: nothing else is offered on top of it
        s.text = "Purging: go and sell"
        tip[#tip + 1] = "The purge you chose is under way: the AH and vendor tasks sell them."
    elseif #Sell:PurgeList() > 0 and not (PC.cdb.purgeAskSkip and time() - PC.cdb.purgeAskSkip < 3600) then
        -- bags and bank full and the plan can't go on: a suggestion, never automatic
        s.text = "Bags full: purge crafted items?"
        s.run = function() Sell:AskPurge() end
        s.skip = function() PC.cdb.purgeAskSkip = time(); PC:RefreshUI() end
        s.skipTip = "Not now: I'll ask again in an hour."
        tip[#tip + 1] = "Your bags and bank are full, so the plan can't go on. Suggestion: purge your crafted items - each sells wherever pays more (AH or vendor), even below cost. You confirm first."
    elseif false then
        -- (never suggested any more: selling materials to a vendor loses what you paid for them -
        -- the Purge materials button on the Sell page is still there if you want it)
        s.text = "Bags full: purge materials?"
        s.run = function() Sell:AskPurgeMats() end
        s.skip = function() PC.cdb.purgeMatsAskSkip = time(); PC:RefreshUI() end
        s.skipTip = "Not now: I'll ask again in an hour."
        tip[#tip + 1] = "Your bags and bank are full. Suggestion: sell the spare materials your plan doesn't use to a vendor. Materials the plan needs are kept. You confirm first."
    else
        s.text = "Bags full: make space by hand"
        tip[1] = "Your bags and bank are full and there's nothing left for ProfitCrafter to clear."
        tip[#tip + 1] = "You'll have to make space yourself: sell, delete or bank something you don't need. Then click again to carry on."
        s.skip = function() PC.cdb.purgeAskSkip, PC.cdb.purgeMatsAskSkip = nil, nil; PC:RefreshUI() end
        s.skipTip = "Ask about purging again."
    end
    s.tip = table.concat(tip, "\n")
    return s
end

-- Sells those leftovers to the open vendor (whole stacks first, the remainder of a stack is split off)
function VendorAuto:SellBack(entries)
    if not PC.merchantOpen then return 0 end
    local want = {}
    for _, lo in ipairs(self:Leftovers(entries)) do want[lo.id] = lo.n end
    local slots = Bags()
    table.sort(slots, function(a, b) return a.n > b.n end)
    local sold, value = 0, 0
    local function emptySlot()
        local C, numSlots = C_Container, (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
        local full = {}
        for _, s in ipairs(Bags()) do full[s.bag * 100 + s.slot] = true end
        for _, bag in ipairs(PC:PlayerBags()) do
            for slot = 1, (numSlots and numSlots(bag) or 0) do
                if not full[bag * 100 + slot] then return bag, slot end
            end
        end
    end
    for _, s in ipairs(slots) do
        local n = want[s.id]
        if n and n > 0 and not s.locked then
            if s.n <= n then
                UseBagItem(s.bag, s.slot)
                want[s.id] = n - s.n; sold = sold + s.n
            else
                -- split just the surplus into an empty slot, then sell that stack
                local split = (C_Container and C_Container.SplitContainerItem) or SplitContainerItem
                local pick = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
                local eb, es = emptySlot()
                if split and pick and eb then
                    split(s.bag, s.slot, n)
                    pick(eb, es)
                    C_Timer.After(0.3, function() if PC.merchantOpen then UseBagItem(eb, es) end end)
                    want[s.id] = 0; sold = sold + n
                end
            end
            value = value + (PC.SellPrice and PC:SellPrice(s.id) or 0) * (n - (want[s.id] or 0))
        end
    end
    if sold > 0 then PC.Buy:Say(("|cff40ff40Sold back %d leftover material%s for %s.|r"):format(sold, sold == 1 and "" or "s", PC:Money(value, false, true))) end
    return sold
end

-- Tools the plan's recipes need that you don't have: { id, name }
function VendorAuto:MissingTools()
    local out, seen = {}, {}
    local UI = PC.UI
    if not (UI and UI.PlanEntries and PC.Craft) then return out end
    for _, e in ipairs(UI:PlanEntries()) do
        local ok, name, has, id = pcall(PC.Craft.Tool, PC.Craft, e)
        if ok and name and id and has ~= true and not seen[id] and PC:BagCount(id) == 0 then
            seen[id] = true
            out[#out + 1] = { id = id, name = name }
        end
    end
    return out
end

function VendorAuto:Run()
    local lines = {}
    if Sell.purgeMats then Sell:SellMats() end
    -- 1) buy what the plan needs from this vendor (missing tools first: one of each)
    if On("autoVendorBuy", true) and PC.VendorBuy:Open() then
        local bought = {}
        for _, t in ipairs(self:MissingTools()) do
            if PC.VendorBuy:Sells(t.id) and not bought[t.id] then
                bought[t.id] = true
                if PC.VendorBuy:Buy(t.id, 1, true) > 0 then lines[#lines + 1] = "Bought a " .. t.name .. " (a tool your plan needs)" end
            end
        end
    end
    if On("autoVendorBuy", true) and PC.VendorBuy:Open() then
        local list = PC.VendorBuy:PlanList()
        if #list > 0 then
            local before = GetMoney()
            PC.VendorBuy:BuyAll()
            local spent = before - GetMoney()
            local names = {}
            for _, it in ipairs(list) do names[#names + 1] = it.qty .. " " .. (it.name or "") end
            if spent > 0 or (PC.Buy:Message() or ""):find("Bought") then
                lines[#lines + 1] = "Bought for your plan: " .. table.concat(names, ", ")
            else
                lines[#lines + 1] = "|cffff8040" .. (PC.Buy:Message() or "Didn't buy plan materials.") .. "|r"
            end
        end
    end
    -- 2) sell junk and (optionally) vendor flips
    local junk, flips, value = 0, 0, 0
    local toSell = {}
    -- vendor flips: only what's above your Keep number, whole stacks, smallest first
    local flipLeft = {}
    if On("autoFlips", true) then
        for _, it in ipairs(Sell:Items()) do
            -- never for less than it cost you (only Purge crafted items sells at a loss)
            local each = Sell:CostEach(it.id)
            local loss = each and (PC:SellPrice(it.id) or 0) < each and not Sell.purge
            if it.vendor and it.sellN > 0 and not loss then flipLeft[it.id] = it.sellN end
        end
    end
    -- extras you chose to vendor (too many for the AH, no room to keep them)
    for id, n in pairs(PC.cdb.dumpVendor or {}) do flipLeft[id] = (flipLeft[id] or 0) + n end
    local flipSold = {} -- what each item brought in, to show it against what it cost
    local slots = Bags()
    table.sort(slots, function(a, b) return a.n < b.n end)
    for _, s in ipairs(slots) do
        if not s.locked and not s.noValue then
            local price = PC.SellPrice and PC:SellPrice(s.id)
            if price and price > 0 then
                if On("autoJunk", true) and s.quality == 0 then
                    toSell[#toSell + 1] = s; junk = junk + 1; value = value + price * s.n
                elseif flipLeft[s.id] and flipLeft[s.id] >= s.n then
                    flipLeft[s.id] = flipLeft[s.id] - s.n
                    toSell[#toSell + 1] = s; flips = flips + 1; value = value + price * s.n
                    flipSold[s.id] = flipSold[s.id] or { n = 0, gold = 0 }
                    flipSold[s.id].n = flipSold[s.id].n + s.n; flipSold[s.id].gold = flipSold[s.id].gold + price * s.n
                end
            end
        end
    end
    local i = 0
    local function sellNext()
        i = i + 1
        local s = toSell[i]
        if not s or not PC.merchantOpen then return end
        UseBagItem(s.bag, s.slot)
        PC:PlanMadeUsed(s.id, s.n)
        C_Timer.After(0.15, sellNext)
    end
    PC.cdb.dumpVendor = nil -- the extras you chose to vendor are in this sale
    if #toSell > 0 then
        sellNext()
        local parts = {}
        if junk > 0 then parts[#parts + 1] = junk .. " junk" end
        if flips > 0 then parts[#parts + 1] = flips .. " vendor flip" .. (flips == 1 and "" or "s") end
        lines[#lines + 1] = ("Sold %s · +%s"):format(table.concat(parts, " and "), PC:Money(value))
        -- each crafted item sold: what it brought in against what it cost you
        for id, f in pairs(flipSold) do
            local each = Sell:CostEach(id)
            local line = ("%d %s: %s"):format(f.n, PC:ItemName(id) or ("item " .. id), PC:Money(f.gold))
            if each then
                local diff = f.gold - each * f.n
                line = line .. (" (cost %s: %s%s)"):format(PC:Money(each * f.n), diff >= 0 and "|cff40ff40+" or "|cffff4040-",
                    PC:Money(math.abs(diff)) .. "|r")
            end
            lines[#lines + 1] = line
            PC:Print(line)
        end
    end
    -- 3) plan crafted: sell back the cheap vendor materials that are left over
    local boughtNow = #lines > 0 and (lines[1] or ""):find("^Bought")
    if PC:SellLeftovers() and PC.Next and not boughtNow then
        local pending = false
        for _, e in ipairs(PC.UI and PC.UI:PlanEntries() or {}) do if PC.Craft:Count(e) > 0 then pending = true break end end
        if not pending then
            local lo = self:Leftovers()
            if #lo > 0 then
                local names, v = {}, 0
                for _, it in ipairs(lo) do names[#names + 1] = it.n .. " " .. it.name; v = v + it.value end
                C_Timer.After(0.5, function() Safe("sell back", self.SellBack, self) end)
                lines[#lines + 1] = ("Selling back leftovers: %s · +%s"):format(table.concat(names, ", "), PC:Money(v))
            end
        end
    end
    if #lines > 0 then PC:Note("At the vendor", lines) end
end

---------------------------------------------------------------------------
-- Price alerts: tell me when an item is at or below a price
---------------------------------------------------------------------------
local Alerts = {}
PC.Alerts = Alerts

function Alerts:Table()
    local db = PC.db
    db.alerts = db.alerts or {}
    local f = PC:Faction()
    db.alerts[f] = db.alerts[f] or {}
    return db.alerts[f]
end

-- "1g 20s", "120s", "35c", "1.5" (gold) -> copper
function PC:ParseMoney(text)
    text = (text or ""):lower():gsub(",", "")
    if text == "" then return nil end
    local total, found = 0, false
    for n, unit in text:gmatch("([%d%.]+)%s*([gsc])") do
        found = true
        n = tonumber(n) or 0
        total = total + n * ((unit == "g" and 10000) or (unit == "s" and 100) or 1)
    end
    if not found then
        local n = tonumber(text)
        if not n then return nil end
        total = n * 10000
    end
    return math.floor(total + 0.5)
end

function Alerts:Set(itemID, copper)
    if copper and copper > 0 and PC:IsVendorItem(itemID) then
        PC.Print(("%s is sold by vendors for %s: no alert needed, just buy it there."):format(PC:ItemName(itemID) or "That item", PC:Money(PC:VendorCost(itemID))))
        return
    end
    self:Table()[itemID] = (copper and copper > 0) and copper or nil
    self.fired = self.fired or {}
    self.fired[itemID] = nil
    if copper and copper > 0 then
        PC.Print(("Alert set: %s at or below %s."):format(PC:ItemName(itemID) or "item", PC:Money(copper)))
    else
        PC.Print(("Alert removed for %s."):format(PC:ItemName(itemID) or "item"))
    end
    self:Check()
end

function Alerts:Ask(itemID)
    if not (PC.UI and PC.UI.Ask) then return end
    local name = PC:ItemName(itemID) or "this item"
    local cur = self:Table()[itemID]
    local txt = ""
    if cur then
        local g, sv, c = math.floor(cur / 10000), math.floor(cur / 100) % 100, cur % 100
        txt = ((g > 0 and (g .. "g ") or "") .. (sv > 0 and (sv .. "s ") or "") .. (c > 0 and (c .. "c") or "")):gsub("%s+$", "")
    end
    PC.UI:Ask("ProfitCrafterAlert", {
        title = "Price alert", sub = name,
        sections = { { lines = {
            "Tell me when it's at or below this price.",
            "|cff888888Like 1g 20s, 35s or 80c. Leave it blank to remove the alert.|r",
        }, bullets = false } },
        input = { text = txt, letters = 20 },
        buttons = {
            { text = "OK", onClick = function(typed) Alerts:Set(itemID, PC:ParseMoney(typed)) end },
            { text = "Cancel" },
        },
        fit = true,
    })
end

-- Fires once each time a price crosses below the alert (again only after it goes back above)
function Alerts:Check()
    if not PC.db or PC.db.alertsOn == false then return end
    self.fired = self.fired or {}
    for id, limit in pairs(self:Table()) do
        local p = PC:Prices()[id]
        if PC:IsVendorItem(id) then p = PC:VendorCost(id) end -- vendor items: the vendor price is the real price
        if p and p <= limit then
            if not self.fired[id] then
                self.fired[id] = true
                local name = PC:ItemName(id) or ("Item " .. id)
                PC.Print(("|cff40ff40Price alert:|r %s is %s (your alert: %s)."):format(name, PC:Money(p), PC:Money(limit)))
                if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959) end
            end
        elseif p then
            self.fired[id] = nil
        end
    end
end
