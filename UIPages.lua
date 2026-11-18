-- ProfitCrafter: window, Items, Profit & loss, Sell, Learn and History tabs

local ADDON, ns = ...
local PC = ns.PC
local UI = PC.UI
local P = UI.Parts
local HasTemplate = P.HasTemplate
local Text = P.Text
local CraftButton = P.CraftButton
local Columns, FitCell, PW, RW, LIST_Y = P.Columns, P.FitCell, P.PW, P.RW, P.LIST_Y
local HeaderStrip = P.HeaderStrip
local ItemIcon = P.ItemIcon
local Panel = P.Panel
local ROW_H = P.ROW_H
local RowText = P.RowText
local SetSkillArrows = P.SetSkillArrows
local ShowTooltip = P.ShowTooltip
local SkillArrows = P.SkillArrows
local Stripe = P.Stripe
local T = P.T
local ITEM_ROWS = P.ITEM_ROWS
local ITEM_ROW_H = P.ITEM_ROW_H
local QUESTION = P.QUESTION
local STATUS_TEXT = P.STATUS_TEXT
local RECENT_ROWS = P.RECENT_ROWS
local StatStrip = P.StatStrip
local CLICK_HINT = P.CLICK_HINT

---------------------------------------------------------------------------
-- Tab 3: Scanned items
---------------------------------------------------------------------------
local ITEMS_H = -LIST_Y + ITEM_ROWS * ITEM_ROW_H + 22 -- the table, with the count line under it

function UI:CreateItemsPage(p)
    self.itemSummary = UI.Ink(Text(p, "GameFontHighlightSmall", 16, -60, PW - 8))
    self.itemSummary:SetWordWrap(true)
    self.itemSummary:SetSpacing(3)

    local lp = Panel(p, 12, -112, PW, ITEMS_H)
    HeaderStrip(lp)
    local cols = {
        { "name", "Item", nil, "Every item your recipes make or use.", text = true },
        { "usage", "Used as", 150, "Made by your recipes (crafted), a material, or both. Materials: how many of your recipes use it." },
        { "ah", "Auction price", 100, "The cheapest price at auction at the last scan (or from Auctionator or TSM).", fit = "money" },
        { "trend", "Trend", 90, "Now against its usual price." },
        { "vendor", "Vendor charges", 100, "What a vendor charges you, after Bartering (not what a vendor pays you).", fit = "money" },
        { "status", "Status", 110, "Priced at the last scan, not at auction, or not scanned yet.", text = true },
    }
    self.itemHeaders = Columns(lp, cols, "items")
    local C = cols.by

    local list = CreateFrame("Frame", nil, lp)
    list:SetPoint("TOPLEFT", 4, LIST_Y)
    list:SetSize(RW, ITEM_ROWS * ITEM_ROW_H)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.itemOffset = UI.itemOffset - delta * 3
        UI:UpdateItemRows()
    end)
    self.itemEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.itemEmpty:SetPoint("CENTER")

    self.itemRows = {}
    for i = 1, ITEM_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetSize(RW, ITEM_ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_ROW_H)
        row:EnableMouse(true)
        Stripe(row, i)
        row.hl = row:CreateTexture(nil, "BORDER")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(unpack(T.rowHover))
        row.hl:Hide()
        -- the item drawn in the price chart below
        row.sel = row:CreateTexture(nil, "BORDER", nil, 1)
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(unpack(T.rowSel))
        row.sel:Hide()
        row.selEdge = row:CreateTexture(nil, "ARTWORK")
        row.selEdge:SetPoint("TOPLEFT"); row.selEdge:SetPoint("BOTTOMLEFT")
        row.selEdge:SetWidth(3)
        row.selEdge:SetColorTexture(1, 0.82, 0, 0.9)
        row.selEdge:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(15, 15)
        row.icon:SetPoint("LEFT", 6, 0)
        row.name = RowText(row, 26, C.name.w - 30)
        for _, k in ipairs({ "usage", "ah", "trend", "vendor", "status" }) do row[k] = RowText(row, C[k].x, C[k].w - 4, "RIGHT") end
        -- (the tooltip is put together when you point at the row, not on every redraw)
        row:SetScript("OnEnter", function(r) r.hl:Show(); ShowTooltip(r, r.data and UI:ItemTip(r.data), r.itemID) end)
        row:SetScript("OnLeave", function(r) r.hl:Hide(); GameTooltip:Hide() end)
        row:SetScript("OnClick", function(r, button)
            if UI:ClickItem(r.itemID, button) then return end
            if button == "LeftButton" and r.itemID then
                UI.itemSel = r.itemID
                UI:UpdateItemRows()
                if PC.ahOpen then PC.Depth:CheckNow(r.itemID) end -- away from the AH a click just charts it
                UI.RefreshTip(r)
            end
        end)
        self.itemRows[i] = row
    end
    self.itemCount = Text(lp, "GameFontDisableSmall", 10, LIST_Y - ITEM_ROWS * ITEM_ROW_H - 4, RW - 12) -- below the last row

    PC:Safe("price chart", self.CreateItemChart, self, p, -(112 + ITEMS_H + 6))
end

---------------------------------------------------------------------------
-- Price chart for the selected scanned item
---------------------------------------------------------------------------
local IC_W, IC_H = PW, 138
local IC_X, IC_Y = 70, 22                 -- plot's left / bottom margins
local IC_PW, IC_PH = IC_W - IC_X - 16, IC_H - IC_Y - 34

function UI:CreateItemChart(p, y)
    local c = Panel(p, 12, y, IC_W, IC_H)
    self.itemChart = c
    c.title = Text(c, "GameFontNormal", 12, -9, 360)
    c.title:SetWordWrap(false)
    c.info = Text(c, "GameFontHighlightSmall", 372, -11, IC_W - 384, "RIGHT")
    c.info:SetWordWrap(false)

    local function grid(frac, alpha)
        local t = c:CreateTexture(nil, "BACKGROUND", nil, 1)
        t:SetColorTexture(1, 1, 1, alpha)
        t:SetSize(IC_PW, 1)
        t:SetPoint("BOTTOMLEFT", IC_X, IC_Y + IC_PH * frac)
    end
    grid(0, 0.08); grid(0.5, 0.04); grid(1, 0.08)

    local function label(point, x, yy, justify)
        local fs = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint(point, c, "BOTTOMLEFT", x, yy)
        if justify then fs:SetJustifyH(justify) end
        return fs
    end
    c.yTop = label("RIGHT", IC_X - 6, IC_Y + IC_PH)
    c.yMid = label("RIGHT", IC_X - 6, IC_Y + IC_PH / 2)
    c.yBot = label("RIGHT", IC_X - 6, IC_Y)
    c.xFirst = label("TOPLEFT", IC_X, IC_Y - 4)
    c.xLast = label("TOPRIGHT", IC_X + IC_PW, IC_Y - 4)

    -- the usual (average) price as a faint line across
    c.avg = c:CreateTexture(nil, "ARTWORK")
    c.avg:SetColorTexture(0.6, 0.6, 0.6, 0.55)
    c.avg:SetSize(IC_PW, 1)
    c.avgLabel = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")

    c.empty = c:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    c.empty:SetPoint("CENTER", c, "BOTTOMLEFT", IC_X + IC_PW / 2, IC_Y + IC_PH / 2)
    c.empty:SetWidth(IC_PW - 20)

    c.lines, c.dots = {}, {}
end

function UI:ItemChartDot(i)
    local c = self.itemChart
    local d = c.dots[i]
    if not d then
        d = CreateFrame("Button", nil, c)
        d:SetSize(12, 12)
        d.tex = d:CreateTexture(nil, "OVERLAY", nil, 2)
        d.tex:SetPoint("CENTER")
        d.tex:SetSize(5, 5)
        d.tex:SetColorTexture(1, 0.82, 0, 1)
        d:SetScript("OnEnter", function(b) b.tex:SetSize(8, 8); ShowTooltip(b, b.tip) end)
        d:SetScript("OnLeave", function(b) b.tex:SetSize(5, 5); GameTooltip:Hide() end)
        c.dots[i] = d
    end
    return d
end

function UI:ItemChartLine(i)
    local c = self.itemChart
    local l = c.lines[i]
    if not l and c.CreateLine then
        l = c:CreateLine(nil, "OVERLAY")
        l:SetThickness(2)
        l:SetColorTexture(1, 0.82, 0, 1)
        c.lines[i] = l
    end
    return l
end

function UI:UpdateItemChart()
    local c = self.itemChart
    if not c then return end
    for _, d in ipairs(c.dots) do d:Hide() end
    for _, l in ipairs(c.lines) do l:Hide() end
    c.avg:Hide(); c.avgLabel:SetText("")
    for _, fs in ipairs({ c.yTop, c.yMid, c.yBot, c.xFirst, c.xLast }) do fs:SetText("") end

    local id = self.itemSel
    if not id then
        c.title:SetText("Price trend")
        c.info:SetText("")
        c.empty:SetText("Click an item above to see its price over time.")
        return
    end
    local name = PC:ItemName(id) or ("Item " .. id)
    c.title:SetText("|T" .. ItemIcon(id) .. ":16:16:0:0|t " .. name .. "  |cff888888price trend|r")

    local list = PC:History()[id] or {}
    local now = PC:Prices()[id]
    local pct, usual = PC:Trend(id)
    local info = {}
    if now then info[#info + 1] = "Now " .. PC:Money(now, false, true) end
    if usual then info[#info + 1] = "|cffaaaaaaUsually|r " .. PC:Money(usual, false, true) end
    if #list > 0 then
        local lo, hi = list[1].p, list[1].p
        for _, pt in ipairs(list) do lo, hi = math.min(lo, pt.p), math.max(hi, pt.p) end
        info[#info + 1] = "|cffaaaaaaLow|r " .. PC:Money(lo, false, true) .. "  |cffaaaaaaHigh|r " .. PC:Money(hi, false, true)
    end
    if pct then
        local col = pct >= 10 and "40ff40" or (pct <= -10 and "ff5555" or "cccccc") -- market colors: up green, down red
        info[#info + 1] = ("|cff%s%s%d%%|r"):format(col, pct >= 0 and "+" or "-", math.floor(math.abs(pct) + 0.5))
    end
    c.info:SetText(table.concat(info, "    "))

    if #list < 2 then
        c.empty:SetText(#list == 1 and "Only one price so far. Each scan (30+ minutes apart) adds a point to the line."
            or "No price history yet. Scan the Auction House to start the line.")
        return
    end
    c.empty:SetText("")

    -- scale: a little room above and below so the line doesn't touch the edges
    local lo, hi = list[1].p, list[1].p
    for _, pt in ipairs(list) do lo, hi = math.min(lo, pt.p), math.max(hi, pt.p) end
    if usual then lo, hi = math.min(lo, usual), math.max(hi, usual) end
    local pad = math.max((hi - lo) * 0.12, hi * 0.02, 1)
    lo, hi = math.max(lo - pad, 0), hi + pad
    local t0, t1 = list[1].t, list[#list].t
    local span = math.max(t1 - t0, 1)
    local function Y(v) return IC_Y + (v - lo) / (hi - lo) * IC_PH end
    local function X(t) return IC_X + (t - t0) / span * IC_PW end

    c.yTop:SetText(PC:ShortMoney(hi))
    c.yMid:SetText(PC:ShortMoney((hi + lo) / 2))
    c.yBot:SetText(PC:ShortMoney(lo))
    local fmt = (span > 2 * 86400) and "%m/%d" or "%m/%d %H:%M"
    c.xFirst:SetText(date(fmt, t0))
    c.xLast:SetText(date(fmt, t1))

    if usual then
        c.avg:ClearAllPoints()
        c.avg:SetPoint("BOTTOMLEFT", IC_X, Y(usual))
        c.avg:Show()
        c.avgLabel:ClearAllPoints()
        c.avgLabel:SetPoint("BOTTOMRIGHT", c, "BOTTOMLEFT", IC_X + IC_PW, Y(usual) + 2)
        c.avgLabel:SetText("usual")
    end

    local px, py
    for i, pt in ipairs(list) do
        local x, yy = X(pt.t), Y(pt.p)
        local d = self:ItemChartDot(i)
        d:ClearAllPoints()
        d:SetPoint("CENTER", c, "BOTTOMLEFT", x, yy)
        d.tip = { date("%A, %B %d  %H:%M", pt.t), "Price: " .. PC:Money(pt.p) }
        d:Show()
        if px then
            local l = self:ItemChartLine(i - 1)
            if l then
                l:SetStartPoint("BOTTOMLEFT", c, px, py)
                l:SetEndPoint("BOTTOMLEFT", c, x, yy)
                l:Show()
            end
        end
        px, py = x, yy
    end
end

function UI:UpdateItems()
    local items = PC:RecipeItems()
    local nPriced, nNotListed, nNever = 0, 0, 0
    for _, e in ipairs(items) do
        if e.state == 1 then nNever = nNever + 1
        elseif e.state == 2 then nNotListed = nNotListed + 1
        else nPriced = nPriced + 1 end
    end
    local nRecipes = 0
    for _ in pairs(PC.cdb.recipes) do nRecipes = nRecipes + 1 end

    local skippedRows, profs = {}, {}
    for prof, list in pairs(PC.cdb.skipped or {}) do
        if #list > 0 then profs[#profs + 1] = ("%s %d"):format(prof, #list) end
        for _, sk in ipairs(list) do
            skippedRows[#skippedRows + 1] = { skipped = true, name = sk.name, prof = prof, why = sk.why }
        end
    end
    table.sort(skippedRows, function(a, b) return a.name < b.name end)
    table.sort(profs)

    local lines = {
        ("|cffffd100%d items|r from |cffffd100%d recipes|r:   |cff40ff40%d priced|r,   |cffff8040%d not at auction|r,   |cffff5555%d not scanned yet|r"):format(
            #items, nRecipes, nPriced, nNotListed, nNever),
    }
    if #skippedRows > 0 then
        lines[#lines + 1] = (UI.DIM .. "Skipped recipes (can't be priced): %s. They're at the bottom; hover one to see why.|r"):format(
            table.concat(profs, ", "))
    end
    if nNever > 0 then
        lines[#lines + 1] = "|cffff8040\"Not scanned\" items haven't been checked yet. Open the Auction House and click Scan auctions.|r"
    end
    self.itemSummary:SetText(table.concat(lines, "\n"))

    local rows = {}
    for _, e in ipairs(items) do rows[#rows + 1] = e end
    -- sorted by the column you picked; skipped recipes (nothing to price) stay at the bottom
    local s = self:SortState("items")
    UI.SortRows(rows, s.key, s.dir, function(e, k)
        if k == "name" then return (e.name or ""):lower() end
        if k == "usage" then return (e.made > 0 and 1000 or 0) + e.used end -- crafted first, then the most-used materials
        if k == "status" then return e.state end
        return e[k] -- (vendor items have no trend)
    end, function(e) return (e.name or ""):lower() end)
    self:PaintHeaders(self.itemHeaders, "items")
    for _, sk in ipairs(skippedRows) do rows[#rows + 1] = sk end
    self.itemData = rows
    self:UpdateItemRows()
end

-- An item's tooltip lines (put together on hover)
function UI:ItemTip(e)
    if e.skipped then return { e.name, ("%s recipe skipped: %s."):format(e.prof, e.why) } end
    local tip = { e.name }
    if e.made > 0 then tip[#tip + 1] = ("Made by %d of your recipes."):format(e.made) end
    if e.used > 0 then tip[#tip + 1] = ("Material in %d of your recipes."):format(e.used) end
    if e.trend then
        tip[#tip + 1] = ("Usually %s; now %s (%s%d%%)."):format(PC:Money(e.usual), PC:Money(e.ah),
            e.trend >= 0 and "+" or "-", math.floor(math.abs(e.trend) + 0.5))
    else
        tip[#tip + 1] = "Trend appears after 3 scans on different days or times."
    end
    if e.listed then tip[#tip + 1] = ("%d listed at auction."):format(e.listed) end
    if e.source == "Auctionator" then
        tip[#tip + 1] = "|cff40c0ffPrice from Auctionator's saved data.|r"
    elseif e.source == "TSM" then
        tip[#tip + 1] = "|cff40c0ffPrice from TradeSkillMaster's data.|r"
    elseif e.source and e.source ~= "own" then
        tip[#tip + 1] = ("|cff40c0ffPrice from %s.|r"):format(e.source)
    end
    tip[#tip + 1] = " "
    for _, line in ipairs(PC:SalesTooltip(e.id)) do tip[#tip + 1] = line end
    tip[#tip + 1] = " "
    if e.checked then
        tip[#tip + 1] = ("Auction House last checked %s ago."):format(PC:Ago(time() - e.checked))
    else
        tip[#tip + 1] = "Not checked on the Auction House yet."
    end
    if e.state == 2 and e.vendor then
        tip[#tip + 1] = "None at auction, but a vendor sells it."
    elseif e.state == 2 then
        tip[#tip + 1] = "None at auction at the last scan."
    end
    tip[#tip + 1] = " "
    for _, l in ipairs(PC:PriceSourceLines(e.id)) do tip[#tip + 1] = l end
    tip[#tip + 1] = " "
    for _, l in ipairs(PC:DepthLines(e.id)) do tip[#tip + 1] = l end
    return tip
end

function UI:UpdateItemRows()
    local data = self.itemData or {}
    self.itemOffset = math.min(math.max(self.itemOffset, 0), math.max(#data - ITEM_ROWS, 0))
    -- keep the charted item if it's still listed; otherwise chart the first one
    local found
    for _, e in ipairs(data) do if e.id and e.id == self.itemSel then found = true break end end
    if not found then
        self.itemSel = nil
        for _, e in ipairs(data) do if e.id and not e.skipped then self.itemSel = e.id break end end
    end

    for i, row in ipairs(self.itemRows) do
        local e = data[i + self.itemOffset]
        if not e then
            row:Hide()
        elseif e.skipped then
            row.icon:SetTexture(QUESTION)
            row.icon:SetDesaturated(true)
            row.name:SetText("|cff888888" .. e.name .. "|r")
            row.usage:SetText("|cff888888Recipe (" .. e.prof .. ")|r")
            row.ah:SetText("")
            row.trend:SetText("")
            row.vendor:SetText("")
            row.status:SetText("|cff888888Skipped|r")
            row.data, row.itemID = e, nil
            row:Show()
        else
            row.icon:SetTexture(ItemIcon(e.id))
            row.icon:SetDesaturated(false)
            local usage
            if e.made > 0 and e.used > 0 then usage = "Crafted + material"
            elseif e.made > 0 then usage = "|cffffd100Crafted|r"
            else usage = ("Material (%d)"):format(e.used) end
            row.name:SetText((e.name or "?") .. UI.QualityTag(e.quality or PC:ItemQuality(e.id), e.maxQ, e.id))
            row.usage:SetText(usage)
            row.ah:SetText(PC:Money(e.ah))
            row.vendor:SetText(e.vendor and PC:Money(e.vendor) or "")
            row.status:SetText((e.state == 4 and e.source == "TSM") and "|cff40c0ffTSM|r" or STATUS_TEXT[e.state])
            local media = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
            if PC:IsVendorItem(e.id) then
                row.trend:SetText("|cff888888vendor|r")
            elseif not e.trend then
                row.trend:SetText("|cff888888--|r")
            elseif e.trend >= 10 then
                row.trend:SetText(("|cff40ff40|T%sSortUp:12:12:0:0|t%d%%|r"):format(media, math.floor(e.trend + 0.5)))
            elseif e.trend <= -10 then
                row.trend:SetText(("|cffff5555|T%sSortDown:12:12:0:0|t%d%%|r"):format(media, math.floor(-e.trend + 0.5)))
            else
                row.trend:SetText("|cffccccccsteady|r")
            end
            row.data, row.itemID = e, e.id
            row:Show()
        end
        local on = e and e.id and not e.skipped and e.id == self.itemSel
        row.sel:SetShown(on and true or false)
        row.selEdge:SetShown(on and true or false)
    end
    PC:Safe("price chart", self.UpdateItemChart, self)

    self.itemEmpty:SetText(#data == 0 and "No recipes yet.\nOpen each of your profession windows once." or "")
    self.itemCount:SetText(#data > ITEM_ROWS and ("Showing %d-%d of %d (scroll for more)"):format(
        self.itemOffset + 1, math.min(self.itemOffset + ITEM_ROWS, #data), #data) or "")
end

---------------------------------------------------------------------------
-- Tab 4: Profit & loss
---------------------------------------------------------------------------
-- The one of a row of buttons that's picked: a gold line under it and white lettering
local function Picked(b, on)
    if on then b:LockHighlight() else b:UnlockHighlight() end
    if not b.pickLine then
        b.pickLine = b:CreateTexture(nil, "OVERLAY")
        b.pickLine:SetPoint("BOTTOMLEFT", 0, 0)
        b.pickLine:SetPoint("BOTTOMRIGHT", 0, 0)
        b.pickLine:SetHeight(2)
        b.pickLine:SetColorTexture(1, 0.82, 0, 1)
    end
    b.pickLine:SetShown(on and true or false)
    local fs = b.GetFontString and b:GetFontString()
    if fs and b.flat then
        if on then fs:SetTextColor(1, 1, 1) else fs:SetTextColor(1, 0.86, 0.42) end
    end
end
local CHART_W, CHART_H = PW, 224
local PLOT_X, PLOT_Y = 64, 26               -- left / bottom margins inside the chart
local PLOT_W = CHART_W - PLOT_X - 12
local PLOT_H = CHART_H - PLOT_Y - 30

function UI:CreatePnLPage(p)
    local ranges = { { 7, "7 days" }, { 30, "30 days" }, { 0, "All time" } }
    self.rangeButtons = {}
    for i, r in ipairs(ranges) do
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        b:SetSize(82, 22)
        b:SetPoint("TOPLEFT", 14 + (i - 1) * 86, -60)
        b:SetText(r[2])
        b.days = r[1]
        b:SetScript("OnClick", function(btn)
            UI.pnlRange = btn.days
            UI:Redraw()
        end)
        self.rangeButtons[i] = b
    end

    self.pnlSummary = StatStrip(p, 288, -56, 420, { "Sold", "Bought", "Fees", "Net" }, true)

    -- Chart
    local cp = Panel(p, 12, -90, CHART_W, CHART_H)
    self.chart = cp

    self.legend = Text(cp, "GameFontDisableSmall", 12, -10, CHART_W - 24, "RIGHT")

    -- What to count: only gold moved by ProfitCrafter's trades, or every change to your gold
    self.modeButtons = {}
    local modes = {
        { "app", "ProfitCrafter only", "Only what ProfitCrafter records: auction buys and sales, auction fees and vendor sales." },
        { "all", "All gold", "Every change to your gold: quests, loot, repairs, mail, trades, the Auction House, everything.\nCounts from the moment this was added (v0.60), while you're logged in on this character." },
    }
    for i, m in ipairs(modes) do
        local b = CreateFrame("Button", nil, cp, "UIPanelButtonTemplate")
        b:SetSize(i == 1 and 124 or 80, 20)
        b:SetPoint("TOPLEFT", 8 + (i == 1 and 0 or 128), -6)
        b:SetText(m[2])
        if b.GetFontString and b:GetFontString() then b:GetFontString():SetFontObject("GameFontHighlightSmall") end
        b.mode = m[1]
        b:SetScript("OnClick", function(btn)
            PC.db.pnlMode = btn.mode
            UI:Redraw()
        end)
        b:SetScript("OnEnter", function(btn) ShowTooltip(btn, { m[2], m[3] }) end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.modeButtons[i] = b
    end

    self.zeroLine = cp:CreateTexture(nil, "ARTWORK")
    self.zeroLine:SetColorTexture(1, 1, 1, 0.25)
    self.zeroLine:SetSize(PLOT_W, 1)

    local function gridLine(yFrac)
        local t = cp:CreateTexture(nil, "BACKGROUND", nil, 1)
        t:SetColorTexture(1, 1, 1, 0.06)
        t:SetSize(PLOT_W, 1)
        t:SetPoint("BOTTOMLEFT", PLOT_X, PLOT_Y + PLOT_H * yFrac)
    end
    gridLine(0)
    gridLine(1)

    self.yTop = cp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.yTop:SetPoint("RIGHT", cp, "BOTTOMLEFT", PLOT_X - 6, PLOT_Y + PLOT_H)
    self.yMid = cp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.yMid:SetPoint("RIGHT", cp, "BOTTOMLEFT", PLOT_X - 6, PLOT_Y + PLOT_H / 2)
    self.yBot = cp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.yBot:SetPoint("RIGHT", cp, "BOTTOMLEFT", PLOT_X - 6, PLOT_Y)

    self.xFirst = cp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.xFirst:SetPoint("TOPLEFT", cp, "BOTTOMLEFT", PLOT_X, PLOT_Y - 4)
    self.xMid = cp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.xMid:SetPoint("TOP", cp, "BOTTOMLEFT", PLOT_X + PLOT_W / 2, PLOT_Y - 4)
    self.xLast = cp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.xLast:SetPoint("TOPRIGHT", cp, "BOTTOMLEFT", PLOT_X + PLOT_W, PLOT_Y - 4)

    self.chartEmpty = cp:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.chartEmpty:SetPoint("CENTER", 0, -6)
    self.chartEmpty:SetWidth(560)
    self.chartEmpty:SetSpacing(3)

    self.bars, self.lines, self.dots = {}, {}, {}

    -- Recent activity: the last few trades (sortable like every table), under its title
    local rp = Panel(p, 12, -(90 + CHART_H + 6), PW, 154)
    Text(rp, "GameFontNormal", 12, -7):SetText("Recent Auction House activity")
    local tb = CreateFrame("Frame", nil, rp)
    tb:SetPoint("TOPLEFT", 0, -18)
    tb:SetPoint("BOTTOMRIGHT", 0, 0)
    HeaderStrip(tb)
    local cols = {
        { "t", "When", 110, "When it happened." },
        { "kind", "Type", 100, "Bought, sold at auction, sold to a vendor, or an auction fee.", text = true },
        { "item", "Item", nil, "What was bought or sold.", text = true },
        { "signed", "Amount", 150, "Gold in (green) or out.", fit = "gold" },
    }
    self.recentHeaders = Columns(tb, cols, "recent")
    local C = cols.by
    self.recentRows = {}
    for i = 1, RECENT_ROWS do
        local row = CreateFrame("Frame", nil, tb)
        row:SetSize(RW, 19)
        row:SetPoint("TOPLEFT", 4, LIST_Y - (i - 1) * 19)
        Stripe(row, i)
        row.when = RowText(row, C.t.x, C.t.w - 4, "RIGHT")
        row.kind = RowText(row, C.kind.x, C.kind.w - 4, "RIGHT")
        row.item = RowText(row, C.item.x + 6, C.item.w - 10)
        row.amount = RowText(row, C.signed.x, C.signed.w - 4, "RIGHT")
        self.recentRows[i] = row
    end
    self.recentEmpty = tb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.recentEmpty:SetPoint("CENTER", 0, -12)
end

-- Reusable chart pieces
function UI:Bar(i)
    local b = self.bars[i]
    if not b then
        b = CreateFrame("Frame", nil, self.chart)
        b:EnableMouse(true)
        b.fill = b:CreateTexture(nil, "ARTWORK")
        b.hl = b:CreateTexture(nil, "BACKGROUND")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 1, 1, 0.06)
        b.hl:Hide()
        b:SetScript("OnEnter", function(f) f.hl:Show(); ShowTooltip(f, f.tip) end)
        b:SetScript("OnLeave", function(f) f.hl:Hide(); GameTooltip:Hide() end)
        self.bars[i] = b
    end
    return b
end

function UI:Line(i)
    local l = self.lines[i]
    if not l and self.chart.CreateLine then
        l = self.chart:CreateLine(nil, "OVERLAY")
        l:SetThickness(2)
        l:SetColorTexture(1, 0.82, 0, 1)
        self.lines[i] = l
    end
    return l
end

function UI:Dot(i)
    local d = self.dots[i]
    if not d then
        d = self.chart:CreateTexture(nil, "OVERLAY", nil, 2)
        d:SetSize(5, 5)
        d:SetColorTexture(1, 0.82, 0, 1)
        self.dots[i] = d
    end
    return d
end

function UI:UpdatePnL()
    local days = self.pnlRange
    for _, b in ipairs(self.rangeButtons) do
        Picked(b, b.days == days)
    end

    local allGold = PC.db.pnlMode == "all"
    for _, b in ipairs(self.modeButtons or {}) do
        Picked(b, (b.mode == "all") == allGold)
    end
    local function M(v, color) return { PC:Money(v, color, true), PC:Money(v, color) } end

    -- Summary
    if allGold then
        local gained, spent, net = PC:GoldTotals(days)
        self.pnlSummary:SetLabels({ "Gold in", "Gold out", "Gold now", "Net" })
        self.pnlSummary:Set({ M(gained), M(spent), M(GetMoney()), M(net, true) })
        self.legend:SetText("|cff40ff40Green|r / |cffff5555red|r bars: gold up or down that day     |cffffd100Gold line|r: running total")
    else
        local sold, bought, fees, net = PC:PnLTotals(days)
        self.pnlSummary:SetLabels({ "Sold", "Bought", "Fees", "Net" })
        self.pnlSummary:Set({ M(sold), M(bought), M(fees), M(net, true) })
        self.legend:SetText("|cff40ff40Green|r / |cffff5555red|r bars: profit or loss that day     |cffffd100Gold line|r: running total")
    end

    -- Clear old chart pieces
    for _, b in ipairs(self.bars) do b:Hide() end
    for _, l in ipairs(self.lines) do l:Hide() end
    for _, d in ipairs(self.dots) do d:Hide() end

    local ledger = PC.cdb.ledger
    local now = time()

    -- Recent activity: the newest few, in the order you sorted them (newest first to start with)
    local recent = {}
    for i = #ledger, math.max(#ledger - #self.recentRows + 1, 1), -1 do recent[#recent + 1] = ledger[i] end
    local rs = self:SortState("recent")
    UI.SortRows(recent, rs.key, rs.dir, function(e, k)
        if k == "item" then return (e.item or ""):lower() end
        if k == "signed" then return (e.kind == "sell" or e.kind == "vendor") and e.amount or -(e.amount or 0) end
        return e[k]
    end, function(e) return (e.item or ""):lower() end)
    self:PaintHeaders(self.recentHeaders, "recent")
    self.recentData = recent
    for i, row in ipairs(self.recentRows) do
        local e = recent[i]
        if e then
            row.when:SetText(date("%m/%d %H:%M", e.t))
            local item = e.item or "Unknown item"
            if e.qty and e.qty > 1 then item = item .. " x" .. e.qty end
            row.item:SetText(item)
            if e.kind == "sell" then
                row.kind:SetText("|cff40ff40Sold|r")
                row.amount:SetText("|cff40ff40+|r" .. PC:Money(e.amount))
            elseif e.kind == "vendor" then
                row.kind:SetText("|cff40c0ffVendor|r")
                row.amount:SetText("|cff40ff40+|r" .. PC:Money(e.amount))
            elseif e.kind == "buy" then
                row.kind:SetText("|cffff5555Bought|r")
                row.amount:SetText(PC:Money(-e.amount))
            else
                row.kind:SetText("|cffff8040AH fee|r")
                row.amount:SetText(PC:Money(-e.amount))
            end
            row:Show()
        else
            row:Hide()
        end
    end
    self.recentEmpty:SetText(#ledger == 0 and "Nothing yet." or "")

    local goldSince = PC:GoldSince()
    if (allGold and not goldSince) or (not allGold and #ledger == 0) then
        self.chartEmpty:SetText(allGold and ("No gold changes recorded yet.\n\n" ..
            "From now on every change to your gold shows here: quests, loot, repairs,\n" ..
            "mail, the Auction House, vendors and trades.") or ("No buys or sales recorded yet.\n\n" ..
            "Buys are recorded when you take the item out of the \"Auction won\" mail,\n" ..
            "sales when you collect the gold from the \"Auction successful\" mail,\n" ..
            "fees when you post an auction, and vendor sales when you sell to a merchant."))
        self.zeroLine:Hide()
        self.yTop:SetText(""); self.yMid:SetText(""); self.yBot:SetText("")
        self.xFirst:SetText(""); self.xMid:SetText(""); self.xLast:SetText("")
        return
    end
    self.chartEmpty:SetText("")
    self.yMid:SetText("0")

    -- One bucket per day
    local nDays = days
    if nDays == 0 then
        local first = ledger[1] and ledger[1].t or now
        if allGold then
            local y, mo, d = goldSince:match("(%d+)-(%d+)-(%d+)")
            first = time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 }) or now
        end
        nDays = math.floor((now - first) / 86400) + 1
    end
    nDays = math.max(1, math.min(nDays, 60))

    local buckets, index = {}, {}
    for i = 1, nDays do
        local t = now - (nDays - i) * 86400
        local key = date("%Y-%m-%d", t)
        buckets[i] = { label = date("%m/%d", t), when = t, sold = 0, bought = 0, fees = 0 }
        index[key] = i
    end
    if allGold then
        for key, v in pairs(PC.cdb.goldDays) do
            local i = index[key]
            if i then buckets[i].sold, buckets[i].bought = v[1], v[2] end
        end
    else
        for _, e in ipairs(ledger) do
            local i = index[date("%Y-%m-%d", e.t)]
            if i then
                local b = buckets[i]
                if e.kind == "sell" or e.kind == "vendor" then b.sold = b.sold + e.amount
                elseif e.kind == "buy" then b.bought = b.bought + e.amount
                else b.fees = b.fees + e.amount end
            end
        end
    end

    local running, maxAbs = 0, 1
    for _, b in ipairs(buckets) do
        b.net = b.sold - b.bought - b.fees
        running = running + b.net
        b.running = running
        maxAbs = math.max(maxAbs, math.abs(b.net), math.abs(b.running))
    end

    -- Axes
    local zeroY = PLOT_Y + PLOT_H / 2
    self.zeroLine:ClearAllPoints()
    self.zeroLine:SetPoint("BOTTOMLEFT", PLOT_X, zeroY)
    self.zeroLine:Show()
    self.yTop:SetText(PC:ShortMoney(maxAbs))
    self.yBot:SetText(PC:ShortMoney(-maxAbs))
    self.xFirst:SetText(buckets[1].label)
    self.xLast:SetText(nDays > 1 and buckets[nDays].label or "")
    self.xMid:SetText(nDays > 2 and buckets[math.ceil(nDays / 2)].label or "")

    -- Bars and running-total line
    local slot = PLOT_W / nDays
    local barW = math.max(math.floor(slot * 0.6), 2)
    local half = PLOT_H / 2
    local prevX, prevY
    for i, b in ipairs(buckets) do
        local bar = self:Bar(i)
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", PLOT_X + (i - 1) * slot, PLOT_Y)
        bar:SetSize(slot, PLOT_H)

        local h = math.abs(b.net) / maxAbs * half
        bar.fill:ClearAllPoints()
        bar.fill:SetSize(barW, math.max(h, 1))
        if b.net >= 0 then
            bar.fill:SetPoint("BOTTOM", bar, "BOTTOM", 0, half)
            bar.fill:SetColorTexture(0.25, 0.8, 0.25, b.net == 0 and 0 or 0.9)
        else
            bar.fill:SetPoint("TOP", bar, "TOP", 0, -half)
            bar.fill:SetColorTexture(0.85, 0.25, 0.25, 0.9)
        end
        if allGold then
            bar.tip = {
                date("%A, %B %d", b.when),
                "Gold in: " .. PC:Money(b.sold),
                "Gold out: " .. PC:Money(b.bought),
                "Net that day: " .. PC:Money(b.net, true),
                "Running total: " .. PC:Money(b.running, true),
            }
        else
            bar.tip = {
                date("%A, %B %d", b.when),
                "Sold: " .. PC:Money(b.sold),
                "Bought: " .. PC:Money(b.bought),
                "Fees: " .. PC:Money(b.fees),
                "Net that day: " .. PC:Money(b.net, true),
                "Running total: " .. PC:Money(b.running, true),
            }
        end
        bar:Show()

        local x = PLOT_X + (i - 0.5) * slot
        local y = zeroY + b.running / maxAbs * half
        local dot = self:Dot(i)
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", self.chart, "BOTTOMLEFT", x, y)
        dot:Show()
        if prevX then
            local line = self:Line(i - 1)
            if line then
                line:SetStartPoint("BOTTOMLEFT", self.chart, prevX, prevY)
                line:SetEndPoint("BOTTOMLEFT", self.chart, x, y)
                line:Show()
            end
        end
        prevX, prevY = x, y
    end
end

---------------------------------------------------------------------------
-- Tab 6: Sell — crafted items in your bags, posted at a smart price
---------------------------------------------------------------------------
local SELL_ROWS = 11

local SELL_H = -LIST_Y + SELL_ROWS * ROW_H + 10

-- A crafted item's AH Profit and V Profit for all you have (Sell:Items works both out: AH after its cut
-- and the deposit); none in your bags: nothing to show
function UI:SellProfits(it)
    if not it or (it.have or 0) <= 0 then return nil, nil end
    return it.ahProfit, it.vendorProfit
end

function UI:CreateSellPage(p)
    local intro = UI.Ink(Text(p, "GameFontHighlightSmall", 16, -62, PW - 8))
    intro:SetText("What you crafted from your plan (nothing else in your bags is touched). Price = the cheapest listing (no undercut), never below your cost" ..
        " (then it says |cffff8040Hold|r). " .. UI.DIM .. "Keep: always have this many; with Keep in stock on, the plan tops itself up.|r")
    intro:SetSpacing(2)
    local lp = Panel(p, 12, -96, PW, SELL_H)
    HeaderStrip(lp)
    local cols = {
        { "name", "Crafted item", nil, "What you crafted from your plan. Below: spare materials a vendor buys back.", text = true },
        { "have", "Have", 56, "How many you have.", fit = "num" },
        { "stock", "Keep", 64, "Always keep this many (type a number). Materials: ticked goes back to a vendor." },
        { "price", "Price each", 100, "The price it's posted at: the cheapest listing, never below your cost.", fit = "money" },
        { "deposit", "Deposit", 110, "The Auction House's deposit for the best listing time." },
        { "ahProfit", "Auction Profit", 100, "Profit selling all you have at auction, after its 5% cut and the deposit.", fit = "gold" },
        { "vProfit", "Vendor Profit", 100, "Profit selling all you have to a vendor. Materials: what a vendor pays for them.", fit = "gold" },
        { nil, nil, 100 }, -- the Post button
    }
    self.sellHeaders = Columns(lp, cols, "sell")
    local C = cols.by
    self.sellRows = {}
    for i = 1, SELL_ROWS do
        local row = CreateFrame("Button", nil, lp)
        row:SetSize(RW, ROW_H)
        row:SetPoint("TOPLEFT", 4, LIST_Y - (i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        Stripe(row, i)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(unpack(T.rowHover))
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(22, 22)
        row.icon:SetPoint("LEFT", 4, 0)
        row.name = RowText(row, 30, C.name.w - 34)
        row.have = RowText(row, C.have.x, C.have.w - 4, "RIGHT")
        -- the Keep box (or the tick) against the right of its column, under the label
        local keepR = C.stock.x + C.stock.w - 4
        row.keep = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.keep:SetSize(38, 18)
        row.keep:SetPoint("LEFT", keepR - 38, 0)
        row.keep:SetAutoFocus(false)
        row.keep:SetNumeric(true)
        row.keep:SetMaxLetters(4)
        row.keep:SetJustifyH("CENTER")
        -- the number goes to the item the box was for when you started typing (the rows can move)
        row.keep:SetScript("OnEditFocusGained", function(eb) eb.editID = row.item and row.item.id end)
        row.keep:SetScript("OnEnterPressed", function(eb) eb:ClearFocus() end)
        row.keep:SetScript("OnEditFocusLost", function(eb)
            local id = eb.editID
            eb.editID = nil
            if id and (tonumber(eb:GetText()) or 0) ~= (PC.Sell:Stock()[id] or 0) then PC.Sell:SetStock(id, eb:GetText())
            else UI:UpdateSell() end
        end)
        -- materials rows: a tick instead of the Keep box (ticked = sell it back, unticked = keep it)
        row.tick = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.tick:SetSize(20, 20)
        row.tick:SetPoint("LEFT", keepR - 29, 0)
        row.tick:SetScript("OnClick", function(b)
            if row.mat then PC.VendorAuto:SetKeep(row.mat.id, not b:GetChecked()); UI:UpdateSell() end
        end)
        row.tick:SetScript("OnEnter", function(b)
            ShowTooltip(b, { "Sell back?", "Ticked: it goes back to a vendor (out of the bank first, if it's there).", "Unticked: kept, never sold back." })
        end)
        row.tick:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.tick:Hide()
        for _, k in ipairs({ "price", "deposit", "ahProfit", "vProfit" }) do row[k] = RowText(row, C[k].x, C[k].w - 4, "RIGHT") end
        row.post = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.post:SetSize(90, 18)
        row.post:SetPoint("RIGHT", -6, 0)
        row.post:SetScript("OnClick", function()
            if row.item then PC:Safe("posting", PC.Sell.Post, PC.Sell, row.item.id) end
        end)
        row:SetScript("OnEnter", function(r)
            if r.mat then
                local m = r.mat
                local tip = { m.name, ("%d in your bags, %d in your bank: the plan doesn't need them."):format(m.bags, m.bank),
                    "A vendor pays " .. PC:Money(m.each) .. " each.",
                    m.keep and "|cffff8040Kept: untick means it stays.|r" or (m.bank > 0 and "|cff888888At the bank, the button takes them out; the next vendor buys them back.|r" or "|cff888888The next vendor buys them back.|r") }
                return ShowTooltip(r, tip, m.id)
            end
            local it = r.item
            if not it then return end
            local tip = { it.name }
            if it.price then tip[#tip + 1] = "Smart price: " .. PC:Money(it.price) .. " each" end
            if it.duration then
                tip[#tip + 1] = ("Best listing: %dh, deposit %s"):format(PC.Sell:Hours()[it.duration] or 24, PC:Money(it.deposit or 0))
                tip[#tip + 1] = "|cff888888Picked by profit after the deposit, from how fast it sells and how many are listed.|r"
            end
            if it.cost then tip[#tip + 1] = "Cost you: " .. PC:Money(it.cost) .. " each (lowest you'd sell at: " .. PC:Money(it.floor or 0) .. ")" end
            if it.have > 0 then
                local ah, v = UI:SellProfits(it)
                tip[#tip + 1] = ("All %d: Auction Profit %s, Vendor Profit %s"):format(it.have, PC:Money(ah, true), PC:Money(v, true))
            end
            if it.vendor then tip[#tip + 1] = "|cff40c0ffBest: sell to any vendor. It pays more than the Auction House after its cut and deposit.|r" end
            if it.tooCheap then tip[#tip + 1] = "|cffff8040It sells for under 1s at auction: not worth posting.|r"
            elseif it.hold then tip[#tip + 1] = "|cffff8040Auction prices are below your cost right now: holding it.|r" end
            tip[#tip + 1] = "|cff888888Shift-click: open it at the Auction House   Alt-click: price alert|r"
            ShowTooltip(r, tip, it.id)
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(r, button) if r.item then UI:ClickItem(r.item.id, button) end end)
        self.sellRows[i] = row
    end
    lp:EnableMouseWheel(true)
    lp:SetScript("OnMouseWheel", function(_, d) UI.sellOffset = (UI.sellOffset or 0) - d * 3; UI:UpdateSell() end)
    self.sellEmpty = lp:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.sellEmpty:SetPoint("CENTER", 0, -10)
    self.sellEmpty:SetWidth(600)
    local by = -96 - SELL_H - 8
    self.sellSummary = UI.Ink(Text(p, "GameFontHighlightSmall", 16, by - 6, PW - 320))
    self.sellSummary:SetWordWrap(false)
    -- Purge: sell every crafted item to clear bag space, even below cost
    local purge = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    purge:SetSize(150, 22)
    purge:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, by)
    purge:SetText("Purge crafted items")
    purge:SetScript("OnClick", function()
        if PC.Sell.purge then PC.Sell:SetPurge(false) else PC.Sell:AskPurge() end
        UI:UpdateSell()
    end)
    purge:SetScript("OnEnter", function(b)
        ShowTooltip(b, { "Purge crafted items", "Clears bag space: sells every crafted item in your bags, each wherever it brings in more gold (auction or vendor), even below what it cost. Turns itself off when they're gone." })
    end)
    purge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.sellPurge = purge
    -- Purge materials: only when you choose it; plan materials are always kept
    local pm = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    pm:SetSize(140, 22)
    pm:SetPoint("RIGHT", purge, "LEFT", -6, 0)
    pm:SetText("Purge materials")
    pm:SetScript("OnClick", function()
        if PC.Sell.purgeMats then PC.Sell.purgeMats = nil; PC:RefreshUI() else PC.Sell:AskPurgeMats() end
        UI:UpdateSell()
    end)
    pm:SetScript("OnEnter", function(b)
        ShowTooltip(b, { "Purge materials", "Sells the spare materials in your bags (anything your plan doesn't need) to a vendor. Materials your plan still needs, and crafting tools, are always kept. Otherwise extra materials just go in your bank for later crafts." })
    end)
    pm:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.sellPurgeMats = pm
end

function UI:UpdateSell()
    if not self.sellRows then return end
    if self.sellPurge then self.sellPurge:SetText(PC.Sell.purge and "Stop purging" or "Purge crafted items") end
    if self.sellPurgeMats then self.sellPurgeMats:SetText(PC.Sell.purgeMats and "Stop purging" or "Purge materials") end
    local items = PC.Sell:Items()
    -- the totals of what's ready to sell, each way
    local ahT, vT, nAH, nV, n = 0, 0, 0, 0, 0
    local profits = {}
    for _, it in ipairs(items) do
        local ah, v = self:SellProfits(it)
        profits[it] = { ah, v }
        if it.have > 0 and not it.hold then
            n = n + 1
            if ah then ahT, nAH = ahT + ah, nAH + 1 end
            if v then vT, nV = vT + v, nV + 1 end
        end
    end
    -- below the crafted items: materials that can go back to a vendor (bags and bank), tick to sell.
    -- Each part sorted by the column you picked (Sell:Items comes in its own order: copied first).
    local mats = PC.VendorAuto and PC.VendorAuto:SellBackList() or {}
    local list, mlist = {}, {}
    for i, it in ipairs(items) do list[i] = { item = it } end
    for i, m in ipairs(mats) do mlist[i] = { mat = m } end
    local s = self:SortState("sell")
    local function name(r) return ((r.item or r.mat).name or ""):lower() end
    local function val(r, k)
        if k == "name" then return name(r) end
        local it, m = r.item, r.mat
        if m then
            local count = (m.bags or 0) + (m.bank or 0)
            if k == "have" then return count end
            if k == "price" then return m.each end
            if k == "vProfit" then return (not m.keep) and m.each and m.each * count or nil end
            return nil
        end
        if k == "ahProfit" then return profits[it][1] end
        if k == "vProfit" then return profits[it][2] end
        if k == "price" then return (not it.tooCheap and not it.hold) and it.price or nil end
        if k == "deposit" then return (it.duration and it.have > 0 and not it.hold) and it.deposit or nil end
        return it[k] -- have, stock
    end
    local function key(r) return r.item and r.item.id or ("m" .. tostring(r.mat.id)) end
    local editing = false
    for _, row in ipairs(self.sellRows) do if row.keep:HasFocus() then editing = true end end
    if editing and self.sellOrder then
        -- typing in a Keep box: the rows stay where they are until you're done
        local pos = self.sellOrder
        local function byPos(a, b) return (pos[key(a)] or 1e9) < (pos[key(b)] or 1e9) end
        table.sort(list, byPos)
        table.sort(mlist, byPos)
    else
        UI.SortRows(list, s.key, s.dir, val, name)
        UI.SortRows(mlist, s.key, s.dir, val, name)
    end
    self:PaintHeaders(self.sellHeaders, "sell")
    local rows = list
    if #mlist > 0 then
        rows[#rows + 1] = { header = true }
        for _, r in ipairs(mlist) do rows[#rows + 1] = r end
    end
    self.sellOrder = {}
    for i, r in ipairs(rows) do if not r.header then self.sellOrder[key(r)] = i end end
    self.sellData = rows
    self.sellOffset = math.min(math.max(self.sellOffset or 0, 0), math.max(#rows - SELL_ROWS, 0))
    for i, row in ipairs(self.sellRows) do
        local r = rows[i + self.sellOffset]
        local it = r and r.item
        row.item, row.mat = it, r and r.mat
        row.tick:Hide()
        row.keep:SetShown(it ~= nil)
        if r and r.header then
            row.icon:SetTexture(nil)
            row.name:SetText("|cffd8b060Extra materials to sell back|r |cff888888(untick to keep)|r")
            row.icon:SetDesaturated(false)
            row.have:SetText(""); row.price:SetText(""); row.deposit:SetText(""); row.ahProfit:SetText(""); row.vProfit:SetText("")
            row.post:Hide()
            row:Show()
        elseif r and r.mat then
            local m = r.mat
            row.icon:SetTexture(ItemIcon(m.id))
            row.icon:SetDesaturated(m.keep)
            row.name:SetText((m.keep and "|cff888888" or "") .. m.name .. (m.bank > 0 and (" |cff888888(" .. m.bank .. " in bank)|r") or "") .. (m.keep and "|r" or ""))
            row.have:SetText(m.bags + m.bank)
            row.tick:Show()
            row.tick:SetChecked(not m.keep)
            row.price:SetText(PC:Money(m.each, false, "silver"))
            row.deposit:SetText("|cff888888vendor|r")
            row.ahProfit:SetText("")
            row.vProfit:SetText(m.keep and "|cff888888kept|r" or PC:Money(m.each * (m.bags + m.bank), true))
            row.post:Hide()
            row:Show()
        elseif it then
            row.icon:SetTexture(ItemIcon(it.id))
            row.icon:SetDesaturated(it.have == 0)
            row.name:SetText((it.have == 0 and "|cff888888" or "") .. it.name .. (it.have == 0 and "|r" or ""))
            row.have:SetText(it.have)
            if not row.keep:HasFocus() then row.keep:SetText(it.stock and tostring(it.stock) or "") end
            if not it.price then
                row.price:SetText("|cff888888no price|r")
            elseif it.tooCheap then
                row.price:SetText("|cffff5555under 1s|r")
            elseif it.hold then
                row.price:SetText("|cffff5555below cost|r")
            else
                row.price:SetText(PC:Money(it.price, false, "silver"))
            end
            if it.duration and it.have > 0 and not it.hold then
                row.deposit:SetText(("%s |cff888888%dh|r"):format(PC:Money(it.deposit or 0, false, "silver"), PC.Sell:Hours()[it.duration] or 24))
            else
                row.deposit:SetText("")
            end
            -- (none in your bags: nothing to sell yet; held: the AH is below your cost)
            local pr = profits[it]
            if it.have == 0 then
                row.ahProfit:SetText(""); row.vProfit:SetText("")
            else
                row.ahProfit:SetText(it.hold and not it.vendor and "|cff888888hold|r" or PC:Money(pr[1], true))
                row.vProfit:SetText((it.vendor and pr[2] and pr[2] > 0) and ("|cff40c0ff" .. PC:Money(pr[2]) .. "|r") or PC:Money(pr[2], true))
            end
            local b = row.post
            if it.have == 0 then
                b:Hide()
            else
                b:Show()
                if it.hold then
                    b:SetText("Hold"); b:Disable()
                elseif (it.sellN or 0) <= 0 then
                    b:SetText("Keeping"); b:Disable() -- all of them are what you keep
                else
                    local cnt = it.sellN
                    b:SetText("Post " .. cnt)
                    b:SetEnabled(PC.Sell:CanPost(it) and true or false)
                end
            end
            row:Show()
        else
            row:Hide()
        end
    end
    self.sellEmpty:SetText(#rows == 0 and "Nothing from your plan to sell yet.\nCraft something from your plan and it shows up here, ready to post." or "")
    if #items == 0 then
        self.sellSummary:SetText("")
    else
        local ah, v = nAH > 0 and ahT or nil, nV > 0 and vT or nil
        local both = PC.Sell.ProfitText and PC.Sell:ProfitText(ah, v)
            or ("Auction Profit %s · Vendor Profit %s"):format(PC:Money(ah, true), PC:Money(v, true))
        self.sellSummary:SetText(("%d ready to sell  ·  %s %s(about)|r%s"):format(n, both, UI.DIM,
            PC.ahOpen and "" or "  ·  |cffff8040open the Auction House to post|r"))
    end
end

---------------------------------------------------------------------------
-- Tab 8: Recipes to get (the Learn tab) - patterns, plans and recipes you don't know yet
---------------------------------------------------------------------------
local LEARN_ROWS = 11
local SOURCE_COLORS = { Vendor = "ff9f40", Trainer = "d8b060", Drop = "40c040", Quest = "ffd100", Dungeon = "ff7070",
    Reputation = "7ab8ff", Discovery = "c080ff", ["World event"] = "ff80c0", Other = "b0b0b0" }
UI.LEARN_VIEWS = { { "now", "Get now at my level" }, { "soon", "Soon" }, { "all", "All" } }
local LEARN_SOURCES = { "All", "Vendor", "Trainer", "Drop", "Quest", "Dungeon", "Reputation", "Special currency", "Other" }

local LEARN_H = -LIST_Y + LEARN_ROWS * ROW_H + 10

function UI:CreateLearnPage(p)
    local intro = UI.Ink(Text(p, "GameFontHighlightSmall", 16, -62, PW - 8))
    intro:SetText("Recipes, patterns and plans you don't know yet, and where to get them. " .. UI.DIM ..
        "Greyed: within 10 levels (or a little more skill). Go sends your Task Button there by the quickest way.|r")
    -- filters
    local function Small(text, w, x)
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetPoint("TOPLEFT", x, -84)
        b:SetText(text)
        return b
    end
    -- drop-downs: which profession, what to show, which source (each opens a short list under it)
    local function Pick(w, x, choices, onPick)
        local b = Small("", w, x)
        local menu = CreateFrame("Frame", nil, p, "BackdropTemplate")
        menu:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
        menu:SetWidth(math.max(w, 150))
        menu:SetFrameStrata("DIALOG")
        if menu.SetBackdrop then
            menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            menu:SetBackdropColor(0.04, 0.035, 0.03, 0.98)
            menu:SetBackdropBorderColor(0.78, 0.6, 0.23, 1)
        end
        menu.buttons = {}
        menu:Hide()
        b.menu = menu
        b:SetScript("OnClick", function()
            if menu:IsShown() then menu:Hide() return end
            for _, other in ipairs(UI.learnPickers or {}) do other.menu:Hide() end
            local list = choices()
            for i, c in ipairs(list) do
                local mb = menu.buttons[i]
                if not mb then
                    mb = CreateFrame("Button", nil, menu)
                    mb:SetSize(menu:GetWidth() - 8, 20)
                    mb:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 20)
                    local hl = mb:CreateTexture(nil, "HIGHLIGHT")
                    hl:SetAllPoints()
                    hl:SetColorTexture(1, 1, 1, 0.12)
                    mb.text = mb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    mb.text:SetPoint("LEFT", 6, 0)
                    mb.text:SetJustifyH("LEFT")
                    mb:SetScript("OnClick", function(btn)
                        menu:Hide()
                        UI.learnOffset = 0
                        onPick(btn.value)
                        UI:UpdateLearn()
                    end)
                    menu.buttons[i] = mb
                end
                mb.value = c[1]
                mb.text:SetText(c[2])
                mb:Show()
            end
            for i = #list + 1, #menu.buttons do menu.buttons[i]:Hide() end
            menu:SetHeight(8 + #list * 20)
            menu:Show()
            if menu.Raise then menu:Raise() end
        end)
        UI.learnPickers = UI.learnPickers or {}
        UI.learnPickers[#UI.learnPickers + 1] = b
        return b
    end
    self.learnProf = Pick(140, 14, function()
        local names = {}
        for _, pr in pairs(PC.cdb.professions or {}) do if pr.name then names[#names + 1] = pr.name end end
        table.sort(names)
        local out = { { "All", "All professions" } }
        for _, n in ipairs(names) do out[#out + 1] = { n, n } end
        return out
    end, function(v) UI.learnFilterProf = v end)
    self.learnShow = Pick(150, 160, function() return UI.LEARN_VIEWS end, function(v) UI.learnView = v end)
    self.learnSource = Pick(130, 316, function()
        local out = {}
        for _, n in ipairs(LEARN_SOURCES) do out[#out + 1] = { n, n == "All" and "All sources" or n } end
        return out
    end, function(v) UI.learnFilterSource = v end)
    -- your recipe trip: over on the right
    local trip = Small("My recipe trip", 120, 648)
    trip:SetScript("OnClick", function()
        -- on the trip already: the same button takes you back to the recipes
        if UI.learnView == "trip" then
            UI.learnView = UI.learnLastView or "now"; UI.learnOffset = 0
            UI:UpdateLearn()
            return
        end
        UI.learnView = "trip"; UI.learnOffset = 0
        -- the trip in the order you'll visit it, from where you are now
        if PC.ToLearn.OrderTrip then PC.ToLearn:OrderTrip() end
        -- and it starts: the Task Button takes you to each stop
        if UI.StartTrip then UI.StartTrip() end
        UI:UpdateLearn()
    end)
    trip:SetScript("OnEnter", function(btn) ShowTooltip(btn, { "Start my trip", "Starts the trip to the recipes you picked with + or Go: the Task Button takes you", "to each one, quickest first from where you are. The list shows the stops in that order." }) end)
    trip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.learnTrip = trip
    local minBox = UI.MinProfitBox(p)
    minBox:SetPoint("TOPLEFT", 458, -84)
    self.learnMinProfit = minBox

    local lp = Panel(p, 12, -112, PW, LEARN_H)
    HeaderStrip(lp)
    local cols = {
        { "name", "Recipe", nil, "Recipes, patterns and plans you don't know yet.", text = true },
        { "skill", "Skill", 50, "The skill it needs.", fit = "num" },
        { "level", "Lvl", 44, "The level it needs.", fit = "num" },
        { "source", "Source", 84, "Where it comes from: vendor, trainer, drop, quest...", text = true },
        { "where", "Where", 170, "Who sells or teaches it, or where it drops (and the zone).", text = true },
        { "cost", "Cost", 90, "What it costs to get." },
        { "ahProfit", "Auction Profit", 90, "Auction Profit per craft once learnt, after the 5% auction cut. ~ = uses an auction price over 6 hours old. ? = no known source or cost yet.", fit = "money" },
        { "vendorProfit", "Vendor Profit", 90, "Vendor Profit per craft once learnt, selling to a vendor. ~ = a material's auction price is over 6 hours old.", fit = "money" },
        { nil, nil, 84 }, -- Go and +
    }
    self.learnHeaders = Columns(lp, cols, "learn")
    local C = cols.by
    self.learnRows = {}
    for i = 1, LEARN_ROWS do
        local row = CreateFrame("Button", nil, lp)
        row:SetSize(RW, ROW_H)
        row:SetPoint("TOPLEFT", 4, LIST_Y - (i - 1) * ROW_H)
        Stripe(row, i)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(unpack(T.rowHover))
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(22, 22)
        row.icon:SetPoint("LEFT", 4, 0)
        row.name = RowText(row, 30, C.name.w - 34)
        for _, k in ipairs({ "skill", "level", "source", "where", "cost", "ahProfit", "vendorProfit" }) do
            row[k] = RowText(row, C[k].x, C[k].w - 4, "RIGHT")
        end
        row.go = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.go:SetSize(44, 18)
        row.go:SetPoint("RIGHT", -32, 0)
        row.go:SetText("Go")
        row.go:SetScript("OnClick", function()
            if row.entry then PC.ToLearn:AddToTrip(row.entry, true) end
        end)
        row.add = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.add:SetSize(24, 18)
        row.add:SetPoint("RIGHT", -6, 0)
        row.add:SetText("+")
        row.add:SetScript("OnClick", function()
            if not row.entry then return end
            if PC.ToLearn:InTrip(row.entry.key) then PC.ToLearn:RemoveFromTrip(row.entry.key) else PC.ToLearn:AddToTrip(row.entry) end
        end)
        row.add:SetScript("OnEnter", function(b)
            ShowTooltip(b, { row.entry and PC.ToLearn:InTrip(row.entry.key) and "Take it off the trip" or "Add to the trip",
                "Collect several in one run: the Task Button visits them nearest first." })
        end)
        row.add:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnEnter", function(r)
            local e = r.entry
            if not e then return end
            local tip = { e.name, ("|cff%s%s|r  %s"):format(SOURCE_COLORS[e.source] or "ffffff", e.source or "?", PC.ToLearn:HowText(e)) }
            if e.skill then tip[#tip + 1] = ("Needs %s %d"):format(e.prof, e.skill) end
            if e.level then tip[#tip + 1] = ("Needs level %d"):format(e.level) end
            if e.req then tip[#tip + 1] = "Also needs: " .. e.req end
            if e.currency then
                for _, c in ipairs(e.currency) do
                    tip[#tip + 1] = ("Costs %d %s: you have %d"):format(c.n, c.name or "?", c.have) .. (c.have < c.n and " |cffff5555(not enough yet)|r" or "")
                end
                if e.cost then tip[#tip + 1] = "And " .. PC:Money(e.cost) end
            elseif e.cost then tip[#tip + 1] = "Costs " .. PC:Money(e.cost) elseif e.costText then tip[#tip + 1] = "Costs " .. e.costText end
            if e.event then tip[#tip + 1] = "|cffffd100Holiday recipe:|r " .. e.event end
            if e.reagents and #e.reagents > 0 then
                for _, l in ipairs(UI:IngredientLines({ reagents = e.reagents }, "low")) do tip[#tip + 1] = l end
                tip[#tip + 1] = " "
            end
            if e.profit or e.ahProfit or e.vendorProfit then
                local out, made = e.output, math.max(e.qty or 1, 1)
                local vPays, ahEach = out and PC:SellPrice(out), out and PC:Prices()[out]
                local name = (out and PC:ItemName(out)) or "What it makes"
                tip[#tip + 1] = ("%s%s: a vendor pays you %s each, at auction %s each"):format(name, made ~= 1 and (" (x%s a craft)"):format(made) or "",
                    (vPays and vPays > 0) and PC:Money(vPays) or "nothing", ahEach and PC:Money(ahEach) or "no price yet")
                if e.itemID and e.itemID ~= out then
                    tip[#tip + 1] = "|cff888888(The Sell Price above is what a vendor pays for the recipe itself.)|r"
                end
                tip[#tip + 1] = ("Per craft: Auction Profit %s, Vendor Profit %s"):format(PC:Money(e.ahProfit, true), PC:Money(e.vendorProfit, true))
                if e.ahAge then
                    tip[#tip + 1] = ("|cffffd100~ Uses an auction price from %s ago. The next scan refreshes it.|r"):format(PC:Ago(e.ahAge))
                end
                if e.cost and e.profit and e.profit > 0 then tip[#tip + 1] = ("Pays for itself after about %d crafts."):format(math.ceil(e.cost / e.profit)) end
            end
            if e.why then tip[#tip + 1] = "|cff888888Not yet: " .. e.why .. "|r" end
            if e.cantAfford then
                tip[#tip + 1] = ("|cffff5555Not enough gold: you need %s more.|r"):format(PC:Money(e.cost - (GetMoney and GetMoney() or 0), false, true))
            end
            if e.place and PC.Travel then
                local ok, way = pcall(PC.Travel.BestWay, PC.Travel, e.place)
                if ok and way then tip[#tip + 1] = "|cffffd100" .. PC.Travel:Describe(way) .. "|r" end
            elseif not e.place then
                tip[#tip + 1] = "|cff888888No exact spot known yet: it shows up once you or another ProfitCrafter user visits.|r"
            end
            if e.srcText and e.srcText ~= "" then tip[#tip + 1] = "|cff888888" .. e.srcText:gsub("\n", ", ") .. "|r" end
            ShowTooltip(r, tip, e.itemID or e.output)
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.learnRows[i] = row
    end
    lp:EnableMouseWheel(true)
    lp:SetScript("OnMouseWheel", function(_, d) UI.learnOffset = (UI.learnOffset or 0) - d * 3; UI:UpdateLearn() end)
    self.learnEmpty = lp:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.learnEmpty:SetPoint("CENTER", 0, -10)
    self.learnEmpty:SetWidth(620)
    local by = -112 - LEARN_H - 8
    self.learnSummary = UI.Ink(Text(p, "GameFontHighlightSmall", 16, by - 6, PW - 280))
    self.learnSummary:SetWordWrap(false)
    local clear = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    clear:SetSize(90, 22)
    clear:SetPoint("TOPRIGHT", p, "TOPLEFT", 12 + PW, by)
    clear:SetText("Clear trip")
    clear:SetScript("OnClick", function() PC.ToLearn:ClearTrip() end)
    self.learnClear = clear
    local start = UI.GreenButton(p, 120, 22, "Start my trip")
    start:SetPoint("RIGHT", clear, "LEFT", -6, 0)
    UI.StartTrip = function()
        -- starting a trip needs the Task Button and its task list: on, even if you'd switched them off
        PC.db.nextBar = true
        PC.Next.dismissed = nil
        PC.Next.wanted = true
        if PC.ToLearn.StartRun then PC.ToLearn:StartRun() end
        PC:RefreshUI()
        PC.Buy:Say("|cff40ff40Trip started: follow the Task Button.|r")
    end
    start:SetScript("OnClick", UI.StartTrip)
    start:SetScript("OnEnter", function(b)
        ShowTooltip(b, { "Start my trip", "Switches to your Recipe Run plan: the Task Button takes you to each recipe, quickest first,", "by the quickest way (flights, boats, zeppelins, your hearthstone). Then back to your plan." })
    end)
    start:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.learnStart = start
    -- one Start my trip button: at the bottom, looking like the other buttons (the green one is gone)
    start:Hide()
    if self.learnTrip then
        self.learnTrip:ClearAllPoints()
        self.learnTrip:SetPoint("RIGHT", clear, "LEFT", -6, 0)
        self.learnTrip:SetSize(150, 22)
    end
end

function UI:UpdateLearn()
    if not self.learnRows or not PC.ToLearn then return end
    local view = self.learnView or "now"
    -- the trip button only exists once there's a trip: nothing picked with + or Go, no button
    local okTrip, tripData = pcall(PC.ToLearn.Data, PC.ToLearn)
    local stops = okTrip and tripData and tripData.trip and #tripData.trip or 0
    if view == "trip" and stops == 0 then
        view = self.learnLastView or "now"
        self.learnView = view
    end
    local profF, srcF = self.learnFilterProf or "All", self.learnFilterSource or "All"
    local V = UI.DROP or "  |cff888888v|r"
    self.learnProf:SetText((profF == "All" and "All professions" or profF) .. V)
    self.learnSource:SetText((srcF == "All" and "All sources" or srcF) .. V)
    -- what to show (the trip is its own button: the list keeps the last choice)
    if view ~= "trip" then self.learnLastView = view end
    local shown = self.learnLastView or "now"
    for _, v in ipairs(UI.LEARN_VIEWS) do if v[1] == shown then self.learnShow:SetText(v[2] .. V) end end
    self.learnTrip:SetEnabled(true)
    self.learnTrip:SetShown(stops > 0)
    self.learnTrip:SetText(view == "trip" and "Back to recipes" or ("Start my trip (%d)"):format(stops))
    self.learnMinProfit:Refresh()
    local minPct = PC:MinProfitPct()
    local function pctOK(p, mats) return p and p > 0 and (not mats or mats <= 0 or p / mats * 100 >= minPct) end
    local all = PC.ToLearn:List()
    local list, nNow, nSoon = {}, 0, 0
    -- each trip stop's place in the order
    local trip = PC.ToLearn.Data().trip
    local stopNo = {}
    for i, k in ipairs(trip) do stopNo[k] = i end
    if view == "trip" then
        local byKey = {}
        for _, e in ipairs(all) do byKey[e.key] = e end
        for _, k in ipairs(trip) do if byKey[k] then list[#list + 1] = byKey[k] end end
    end
    for _, e in ipairs(all) do
        if e.status == "now" then nNow = nNow + 1 elseif e.status == "soon" then nSoon = nSoon + 1 end
        if view == "trip" then e = nil end
        -- Special currency and Reputation: what you need tokens or standing for, short of it or not
        -- (otherwise those wait out of Get now until you have it)
        local special = (srcF == "Special currency" and e and e.currency ~= nil)
            or (srcF == "Reputation" and e and (e.source == "Reputation" or e.rep ~= nil))
        local waiting = special and (e.status == "currency" or e.repShort)
        local ok = e and (profF == "All" or e.prof == profF or (profF == "Mining" and e.prof == "Smelting"))
            and (srcF == "All" or special or (srcF ~= "Special currency" and e.source == srcF) or (srcF == "Other" and not SOURCE_COLORS[e.source or ""]))
            and (pctOK(e.ahProfit, e.matsCost) or pctOK(e.vendorProfit, e.matsCost))
            and (view == "all" or waiting or (view == "now" and e.status == "now") or (view == "soon" and (e.status == "now" or e.status == "soon")))
        if e and ok then list[#list + 1] = e end
    end
    -- sorted by the column you picked (until then: get-now first, best profit first; the trip: in its order)
    local s = self:SortState("learn")
    local function lower(v) return v and tostring(v):lower() or nil end
    UI.SortRows(list, s.key, s.dir, function(e, k)
        if k == "name" or k == "source" then return lower(e[k]) end
        if k == "where" then return lower(e.where and (e.where .. " " .. (e.zone or ""))) end
        return tonumber(e[k]) -- skill, level, cost, ahProfit, vendorProfit
    end, function(e) return lower(e.name) or "" end)
    self:PaintHeaders(self.learnHeaders, "learn")
    self.learnData = list
    self.learnOffset = math.min(math.max(self.learnOffset or 0, 0), math.max(#list - LEARN_ROWS, 0))
    for i, row in ipairs(self.learnRows) do
        local e = list[i + self.learnOffset]
        row.entry = e
        if e then
            local grey = e.status ~= "now" or e.cantAfford
            row:SetAlpha(e.status == "later" and 0.35 or (grey and 0.55 or 1))
            row.icon:SetTexture(ItemIcon(e.itemID or e.output))
            row.icon:SetDesaturated(grey)
            -- on the trip: its stop number first ("2." = the second stop)
            local no = stopNo[e.key]
            row.name:SetText((no and ("|cffffd100%d.|r "):format(no) or "") .. (grey and "|cff9a9a9a" or "|cffffffff") .. e.name .. "|r")
            row.skill:SetText(e.skill and tostring(e.skill) or "|cff666666?|r")
            row.level:SetText(e.level and tostring(e.level) or "|cff666666-|r")
            row.source:SetText(("|cff%s%s|r"):format(SOURCE_COLORS[e.source] or "b0b0b0", e.source or "?"))
            row.where:SetText((e.where or "?") .. (e.zone and e.zone ~= "" and (" |cff888888" .. e.zone .. "|r") or ""))
            -- special currency: the amount and what (red when you're short)
            local cur
            if e.currency then
                local c = e.currency[1]
                cur = ((c.have < c.n) and "|cffff5555" or "|cffffd100") .. c.n .. " " .. (c.name or "") .. "|r"
            end
            row.cost:SetText(cur or (e.cost and ((e.cantAfford and "|cffff5555" or "") .. PC:Money(e.cost, false, true) .. (e.cantAfford and "|r" or "")))
                or (e.costText and ("|cff888888" .. e.costText .. "|r")) or "|cff666666?|r")
            row.ahProfit:SetText(e.noSource and "|cff666666?|r" or ((e.ahAge and "|cffffd100~|r" or "") .. PC:Money(e.ahProfit, true)))
            row.vendorProfit:SetText(e.noSource and "|cff666666?|r" or ((e.vAge and "|cffffd100~|r" or "") .. PC:Money(e.vendorProfit, true)))
            -- "soon" ones can go on the trip too (you choose them; they wait in the bank until you can learn them)
            local canTrip = (e.status ~= "later" or stopNo[e.key] ~= nil) and not e.seasonOff
            row.go:SetShown(canTrip)
            row.go:SetEnabled(e.place ~= nil or e.source ~= "Vendor")
            row.add:SetText(PC.ToLearn:InTrip(e.key) and "-" or "+")
            row.add:SetShown(canTrip)
            row:Show()
        else
            row:Hide()
        end
    end
    self.learnEmpty:SetText(#list == 0 and view == "trip" and "No stops on your trip yet.\nClick Back to recipes (top right), then use + on a recipe to add it (Go adds it as the first stop)." or #list == 0 and (#all == 0
        and "Nothing found yet.\nOpen your profession windows and visit trainers and vendors: what they teach and sell shows up here\n(other ProfitCrafter users' vendors show up too)."
        or "Nothing matches these filters.") or "")
    self.learnSummary:SetText(("%d you can get now  ·  %d soon%s"):format(nNow, nSoon,
        #trip > 0 and ("  ·  |cffffd100Trip: %d stop%s|r%s"):format(#trip, #trip == 1 and "" or "s",
            view ~= "trip" and " (Trip shows the order)" or s.key and " (the numbers are the order you'll visit them)"
            or " in the order you'll visit them") or ""))
    self.learnStart:Hide()
    self.learnClear:SetShown(#trip > 0)
end

---------------------------------------------------------------------------
-- History tab: every purchase and sale, newest first, filterable and sortable
---------------------------------------------------------------------------
local HISTORY_ROWS = 12
local HISTORY_KINDS = {
    { "ALL", "All" }, { "buy", "Bought" }, { "sell", "Sold at auction" }, { "vendor", "Sold to vendor" }, { "fee", "Auction fees" },
}
local KIND_LABEL = {
    buy = "|cffff5555Bought (auction)|r", sell = "|cff40ff40Sold (auction)|r", vendor = "|cff40c0ffSold (vendor)|r", fee = "|cffff8040AH fee|r",
}
UI.historyKind, UI.historyOffset = "ALL", 0

function UI:CreateHistoryPage(p)
    -- Type filter buttons
    self.historyButtons = {}
    local x = 14
    for i, k in ipairs(HISTORY_KINDS) do
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        local w = (k[1] == "vendor" and 108) or (k[1] == "sell" and 92) or 76
        b:SetSize(w, 22)
        b:SetPoint("TOPLEFT", x, -60)
        x = x + w + 4
        b:SetText(k[2])
        b.kind = k[1]
        b:SetScript("OnClick", function(btn)
            UI.historyKind = btn.kind
            UI.historyOffset = 0
            UI:Redraw()
        end)
        self.historyButtons[i] = b
    end

    local lp = Panel(p, 12, -88, PW, 384)
    HeaderStrip(lp)
    local cols = {
        { "t", "Date", 110, "When it happened." },
        { "kind", "Type", 130, "Bought at auction, sold at auction, sold to a vendor, or an auction fee.", text = true },
        { "item", "Item", nil, "What was bought or sold.", text = true },
        { "qty", "Qty", 60, "How many.", fit = "num" },
        { "each", "Each", 120, "The price of one.", fit = "money" },
        { "signed", "Amount", 130, "Gold in (green) or out (red).", fit = "gold" },
    }
    self.historyHeaders = Columns(lp, cols, "history")
    local C = cols.by

    local list = CreateFrame("Frame", nil, lp)
    list:SetPoint("TOPLEFT", 4, LIST_Y)
    list:SetSize(RW, HISTORY_ROWS * ROW_H)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.historyOffset = UI.historyOffset - delta * 3
        UI:UpdateHistoryRows()
    end)

    self.historyEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.historyEmpty:SetPoint("CENTER")
    self.historyEmpty:SetWidth(600)

    self.historyRows = {}
    for i = 1, HISTORY_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(RW, ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        Stripe(row, i)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(unpack(T.rowHover))
        row.when = RowText(row, C.t.x, C.t.w - 4, "RIGHT")
        row.kind = RowText(row, C.kind.x, C.kind.w - 4, "RIGHT")
        row.item = RowText(row, C.item.x + 8, C.item.w - 12)
        row.qty = RowText(row, C.qty.x, C.qty.w - 4, "RIGHT")
        row.each = RowText(row, C.each.x, C.each.w - 4, "RIGHT")
        row.amount = RowText(row, C.signed.x, C.signed.w - 4, "RIGHT")
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(btn, button)
            local e = btn.entry
            if not e or not e.item then return end
            local id = PC:ItemIDByName(e.item)
            if id then UI:ClickItem(id, button) return end
            -- Not one of your recipe items: shift-click can still search the AH by name
            if IsShiftKeyDown and IsShiftKeyDown() and button ~= "RightButton" and PC.ahOpen
                and AuctionHouseFrame and AuctionHouseFrame.SearchBar then
                AuctionHouseFrame.SearchBar:SetSearchText('"' .. e.item .. '"')
                if AuctionHouseFrame.SearchBar.StartSearch then AuctionHouseFrame.SearchBar:StartSearch() end
            end
        end)
        row:SetScript("OnEnter", function(btn)
            local e = btn.entry
            if not e then return end
            local tip = { e.item or "Unknown item", date("%m/%d/%Y %H:%M", e.t), KIND_LABEL[e.kind] or e.kind }
            if e.qty and e.qty > 1 then tip[#tip + 1] = ("%d for %s (%s each)"):format(e.qty, PC:Money(e.amount), PC:Money(e.each)) end
            if e.kind == "sell" then tip[#tip + 1] = "|cff888888Gold you got from the mail, after the 5% auction cut.|r" end
            tip[#tip + 1] = CLICK_HINT
            ShowTooltip(btn, tip)
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.historyRows[i] = row
    end

    self.historyTotals = StatStrip(lp, 10, LIST_Y - HISTORY_ROWS * ROW_H - 8, RW - 12, { "Entries", "Bought", "Sold at auction", "Vendor", "Fees", "Net" })
end

function UI:UpdateHistory()
    for _, b in ipairs(self.historyButtons) do
        Picked(b, b.kind == self.historyKind)
    end

    -- Filter
    local data = {}
    local bought, sold, vendor, fees = 0, 0, 0, 0
    for _, e in ipairs(PC.cdb.ledger) do
        local keep = (self.historyKind == "ALL" or e.kind == self.historyKind
            or (self.historyKind == "fee" and e.kind ~= "buy" and e.kind ~= "sell" and e.kind ~= "vendor"))
        if keep and self.search ~= "" and not (e.item or ""):lower():find(self.search, 1, true) then keep = false end
        if keep then
            local q = e.qty or 1
            local out = (e.kind == "sell" or e.kind == "vendor")
            data[#data + 1] = {
                t = e.t, kind = e.kind, item = e.item or "Unknown item", qty = q,
                amount = e.amount, each = e.amount / math.max(q, 1), signed = out and e.amount or -e.amount,
            }
            if e.kind == "buy" then bought = bought + e.amount
            elseif e.kind == "sell" then sold = sold + e.amount
            elseif e.kind == "vendor" then vendor = vendor + e.amount
            else fees = fees + e.amount end
        end
    end

    -- Sort (newest first to start with)
    local s = self:SortState("history")
    UI.SortRows(data, s.key, s.dir, function(e, k)
        if k == "item" then return e.item:lower() end
        return e[k]
    end, function(e) return e.item:lower() end)
    self.historyData = data
    self:PaintHeaders(self.historyHeaders, "history")

    local net = sold + vendor - bought - fees
    local function M(v, color) return { PC:Money(v, color, true), PC:Money(v, color) } end
    self.historyTotals:Set({ { tostring(#data) }, M(bought), M(sold), M(vendor), M(fees), M(net, true) })
    self:UpdateHistoryRows()
end

function UI:UpdateHistoryRows()
    local data = self.historyData or {}
    self.historyOffset = math.min(math.max(self.historyOffset, 0), math.max(#data - HISTORY_ROWS, 0))
    for i, row in ipairs(self.historyRows) do
        local e = data[i + self.historyOffset]
        row.entry = e
        if e then
            row.when:SetText(date("%m/%d %H:%M", e.t))
            row.kind:SetText(KIND_LABEL[e.kind] or e.kind)
            row.item:SetText(e.item)
            row.qty:SetText(e.qty)
            row.each:SetText(PC:Money(e.each, false, true))
            if e.signed >= 0 then
                row.amount:SetText("|cff40ff40+|r" .. PC:Money(e.amount, false, true))
            else
                row.amount:SetText("|cffff5555-|r" .. PC:Money(e.amount, false, true))
            end
            row:Show()
        else
            row:Hide()
        end
    end
    if #data == 0 then
        self.historyEmpty:SetText(#PC.cdb.ledger == 0 and
            "Nothing recorded yet.\n\nAH buys show up when you take the item from the \"Auction won\" mail,\nAH sales when you take the gold from the \"Auction successful\" mail,\nand vendor sales as soon as you sell to a merchant."
            or "Nothing matches this filter.")
    else
        self.historyEmpty:SetText("")
    end
end
