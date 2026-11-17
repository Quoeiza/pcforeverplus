-- ProfitCrafter: release notes window and the standard pop-up
-- The notes window opens by itself when News.AUTO is on; its notes match the CurseForge changelog.

local ADDON, ns = ...
local PC = ns.PC
local UI = PC.UI
local P = UI.Parts
local HasTemplate, Text = P.HasTemplate, P.Text

local News = {}
PC.News = News

-- What's in this release (edit for each version)
-- Each build has its own notes: ProfitCrafter Forever (WoW Forever) and ProfitCrafter (Retail)
-- The same as the CurseForge changelog for this release, word for word
News.NOTES_FOREVER = {
    top = "Local build: profit guards, safer buying and selling, sortable tables, less stutter.",
    new = {
        "Auction Profit and Vendor Profit wherever a profit is shown.",
        "Craftable at Profit, Total Auction Profit and Total Vendor Profit columns, the whole batch priced at live listings. Sells at auction and Sells to vendor for side by side.",
        "Recipe tooltips list each ingredient and its price. The \"how many?\" pop-up has Max profitable.",
        "Minimum profit (Settings, default 10%). Recipes below it are hidden and buying stops before a craft drops below it. The plan is then amended to match (/pc undo reverts it).",
        "Separate Only N%+ Auction profit and Only N%+ Vendor profit boxes on the recipe tables and Scout recipes. Tick both and a recipe must meet both.",
        "Every table sorts on every column.",
        "Best bets and Make me gold favour what sells: an auction craft needs today's sales to be at least half its listings. Hot sellers come first, then the rest by profit potential.",
        "Quick Buy (the coin on each recipe): plans the crafts that clear your minimum profit, buys the main auction material and opens the plan.",
        "One-click auction buying: the price is checked and confirmed at once if it still pays (Settings).",
        "Faster auction scans: 100 items a search (was 25), and listings that haven't changed are skipped.",
        "Use what's in my bank (Settings, on by default). Off: the bank is ignored entirely.",
        "Scout recipes read the prices of what learnable recipes make and use. Prices over 6 hours old are marked ~.",
        "Craft tasks give the item count when a recipe makes several (\"34 Seasoned Wolf Kabob (makes 102)\").",
        "Selling to a vendor splits stacks to sell an exact amount.",
        "Auction listings cheaper than a vendor are bought up to what the vendor charges.",
        "Your own fresh scan beats other players' prices for a minute.",
        "No auction craft suggestions when none sold today.",
        "The flight line is back (Settings), hidden while EllesmereUI's flight bar shows. Junk is left to Scrap when it's installed.",
        "Clearer wording: what a vendor pays you and what a vendor charges you are told apart everywhere, and Auction and Vendor are spelled out instead of AH and V.",
        "A price held over 10 seconds is checked again before buying.",
    },
    fixed = {
        "Much less stutter in the Learn list, routes, the Task Button, the task list and the window.",
        "Buying could go over the plan when the Auction House answered slowly.",
        "Vendor purchases go one at a time, each checked in your bags. Anything that doesn't arrive is reported, never bought again.",
        "Vendor buying missed plan changes made at the vendor.",
        "Typing a plan count could change the wrong recipe.",
        "The bank could crash with an item on the cursor.",
        "Secret messages in combat no longer cause errors.",
        "One auction purchase no longer prints several \"Bought\" lines.",
        "No Hearthstone or teleport within the zone you're in, and no travel to a stop you're already at.",
        "Vendor materials and crafts came in smaller batches than your bags allowed.",
        "The Materials table says \"buying N\" while a purchase is on its way, and Have shows what's in the bank, the mail or on its way.",
        "Scout recipes showed a profit for recipes with no known source or cost.",
        "Place, NPC and recipe names shared in another alphabet (e.g. Russian) are translated or left out.",
        "Clicking Buy on a second item before the first item's price arrived could confirm it at a price never checked.",
        "A refused or blocked purchase could later be taken as bought, so the plan bought too little.",
        "A halved retry the game blocked started over at the full amount on the next click.",
        "One refused purchase limited the size of every later purchase, not just that item's.",
        "Old live listings were still used after an item sold out or its price changed.",
        "Finishing crafts whose scarce materials you hold could cost more than the craft brings in.",
        "A short market was taken as a profit stop and cut the plan.",
        "Turning off Use what's in my bank forgot purchases waiting in the mail.",
        "The plan's bag check ignored the reagent bag, and batches counted room that reagent bag materials don't free.",
        "Make me gold's Your materials list skipped the half-of-listed sales rule.",
        "Routes could Hearthstone out and walk back for a stop in your own zone.",
        "\"Stopped buying\" could get stuck on the Task Button away from the Auction House.",
        "A Keep number typed on the Sell page could land on another item.",
        "The empty recipe list blamed the profit boxes when Can afford had hidden the rows.",
        "Gear upgrades now rechecks items after you learn a weapon skill.",
    },
    wip = {
        "More performance updates.",
        "Fishing and cooking enhancements.",
        "Additional themes: Classic, Retail and Modern.",
    },
}

News.NOTES_RETAIL = {
    new = {
        "Learn tab lists more recipes, where to get them and the skill needed.",
        "Learn tab buttons are now drop-downs.",
        "Special currency and reputation recipes added.",
        "Holiday recipes added.",
        "Customized gear upgrade plans.",
        "Flight timer.",
    },
    fixed = {
        "Various small fixes.",
    },
}

-- this build's notes
News.NOTES = PC.FOREVER and News.NOTES_FOREVER or News.NOTES_RETAIL

News.FEEDBACK_URL = "https://www.curseforge.com/wow/addons/profitcrafterforever"

local SECTIONS = { -- shown in this order
    { key = "new", title = "New enhancements", r = 0.25, g = 1, b = 0.25 },
    { key = "wip", title = "Still in work", r = 1, g = 0.82, b = 0 },
    { key = "fixed", title = "Smashed bugs", r = 1, g = 0.44, b = 0.44 },
}

function News:Title()
    return (tostring(PC.VERSION or ""):lower():find("beta") and "New beta release") or "New release"
end

-- Which notes these are: the version plus a fingerprint of the text, so notes changed within
-- the same version show again too
function News:Key()
    -- everything you'd see: the line on top, the section titles and every note
    local parts = { self.NOTES.top or "" }
    for _, sec in ipairs(SECTIONS) do
        parts[#parts + 1] = sec.title
        for _, l in ipairs(self.NOTES[sec.key] or {}) do parts[#parts + 1] = type(l) == "table" and l[1] or l end
    end
    local text, h = table.concat(parts, "|"), 0
    for i = 1, #text do h = (h * 31 + text:byte(i)) % 2147483647 end
    return tostring(PC.VERSION) .. "#" .. h
end

function News:Due()
    return PC.db ~= nil and PC.VERSION ~= nil and PC.VERSION ~= "?" and PC.db.newsSeen ~= self:Key()
end

News.HEIGHT = 470

local function Backdrop(f, r, g, b, a, er, eg, eb)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        f:SetBackdropColor(r, g, b, a)
        f:SetBackdropBorderColor(er or 0.85, eg or 0.7, eb or 0.25, 1)
    end
end

---------------------------------------------------------------------------
-- The standard pop-up (the news window's look): over the main window, which is dimmed and locked
-- while it's up; icon + title + subtitle, a scrolling body, its own buttons at the bottom.
-- Never bigger than the news window; smaller is fine (fit = true sizes it to the text).
---------------------------------------------------------------------------
local Popup = {}
Popup.__index = Popup
UI.Popup = Popup

function Popup.New(name)
    return setmetatable({ name = name, lines = {}, btns = {} }, Popup)
end

function Popup:Create(parent)
    if self.cover then
        if self.cover:GetParent() ~= parent then
            self.cover:SetParent(parent)
            self.cover:ClearAllPoints(); self.cover:SetAllPoints(parent)
        end
        return
    end
    -- covers the main window: dims it and catches clicks so only the pop-up responds
    local cover = CreateFrame("Frame", self.name, parent)
    self.cover = cover
    cover:SetAllPoints(parent)
    -- above everything in the main window (its buttons, lists, close button, menus)
    cover:SetFrameStrata("FULLSCREEN")
    cover:SetFrameLevel(100)
    cover:EnableMouse(true)
    if cover.EnableMouseWheel then cover:EnableMouseWheel(true) end
    cover:SetScript("OnMouseWheel", function() end)
    local dim = cover:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints()
    dim:SetColorTexture(0, 0, 0, 0.6)
    self.dim = dim

    local p = CreateFrame("Frame", nil, cover, "BackdropTemplate")
    self.p = p
    p:SetPoint("CENTER")
    p:SetWidth(math.min((PC.UI and PC.UI.W or 780) - 120, 560))
    p:SetHeight(News.HEIGHT)
    Backdrop(p, 0.07, 0.06, 0.08, 0.98)

    local icon = p:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("TOPLEFT", 14, -12)
    icon:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\Icon")
    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -1)
    self.title = title
    local sub = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    self.sub = sub

    local line = p:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.6, 0.48, 0.2, 0.7)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 6, -58); line:SetPoint("TOPRIGHT", -6, -58)

    -- the body scrolls between the header line and the buttons (never under them)
    local tmpl = HasTemplate("UIPanelScrollFrameTemplate") and "UIPanelScrollFrameTemplate" or nil
    local sf = CreateFrame("ScrollFrame", self.name .. "Scroll", p, tmpl)
    sf:SetPoint("TOPLEFT", 10, -64)
    sf:SetPoint("BOTTOMRIGHT", tmpl and -32 or -12, 60)
    self.sfX = tmpl and -32 or -12
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(f, delta)
        local max = f:GetVerticalScrollRange() or 0
        local v = math.max(0, math.min(max, (f:GetVerticalScroll() or 0) - delta * 40))
        f:SetVerticalScroll(v)
    end)
    local body = CreateFrame("Frame", nil, sf)
    body:SetSize(p:GetWidth() - 52, 10)
    sf:SetScrollChild(body)
    self.sf, self.body = sf, body
    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 10)
    self.hint = hint
    -- a box to type in (a plan name, a price), above the buttons; shown when the spec asks for it
    local eb = CreateFrame("EditBox", self.name .. "Input", p, HasTemplate("InputBoxTemplate") and "InputBoxTemplate" or nil)
    eb:SetSize(260, 22)
    eb:SetPoint("BOTTOM", 0, 60)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEnterPressed", function() local b = self.btns[1]; if b and b:IsShown() then b:Click() end end)
    eb:SetScript("OnEscapePressed", function() local b = self.closeBtn; if b and b:IsShown() then b:Click() end end)
    eb:Hide()
    self.input = eb
end

-- What's typed in the box ("" when there's no box)
function Popup:InputText()
    local eb = self.input
    if not (eb and eb:IsShown()) then return "" end
    return strtrim and strtrim(eb:GetText() or "") or (eb:GetText() or "")
end

-- spec: title, sub, subColor {r,g,b}, sections { {title, r, g, b, lines = {...}, bullets = true/false} },
--       buttons { {text, onClick} } (Close if none), hint, fit (size to the text, up to the news size),
--       input { text, letters } (a box to type in; each button's onClick gets what's typed)
function Popup:Fill(spec)
    local p, body = self.p, self.body
    self.title:SetText(spec.title or PC.NAME)
    self.sub:SetText(spec.sub or "")
    local c = spec.subColor or { 0.25, 1, 0.25 }
    self.sub:SetTextColor(c[1], c[2], c[3])
    self.hint:SetText(spec.hint or "")
    for _, fs in ipairs(self.lines) do fs:Hide() end
    local n, y = 0, -2
    local width = body:GetWidth() - 8
    local function Text(font, text, r, g, b, indent)
        n = n + 1
        local fs = self.lines[n]
        if not fs then
            fs = body:CreateFontString(nil, "OVERLAY")
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(true)
            self.lines[n] = fs
        end
        fs:SetFontObject(font)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", 8 + (indent or 0), y)
        fs:SetWidth(width - (indent or 0))
        fs:SetText(text)
        fs:SetTextColor(r, g, b)
        fs:Show()
        y = y - (fs:GetStringHeight() or 14) - 3
    end
    for _, sec in ipairs(spec.sections or {}) do
        local list = sec.lines or {}
        if #list > 0 or sec.title then
            y = y - 4
            if sec.title then Text("GameFontNormal", sec.title, sec.r or 1, sec.g or 0.82, sec.b or 0) end
            for _, t in ipairs(list) do
                if sec.bullets == false then Text("GameFontHighlight", t, 0.92, 0.92, 0.92, 0)
                else Text("GameFontHighlight", "•  " .. t, 0.92, 0.92, 0.92, 6) end
            end
        end
    end
    local contentH = math.max(-y + 6, 10)
    body:SetHeight(contentH)
    -- the typing box, between the text and the buttons
    local inputH = spec.input and 34 or 0
    self.sf:SetPoint("BOTTOMRIGHT", self.p, "BOTTOMRIGHT", self.sfX or -32, 60 + inputH)
    if spec.input then
        local eb = self.input
        if eb.SetMaxLetters then eb:SetMaxLetters(spec.input.letters or 40) end
        eb:SetWidth(spec.input.width or 260)
        eb:SetText(spec.input.text or "")
        -- a box to copy from (a web address): typing in it puts the text back
        self.fixedText = spec.input.fixed and spec.input.text or nil
        if not self.fixedHooked then
            self.fixedHooked = true
            eb:HookScript("OnTextChanged", function(b, user)
                if user and self.fixedText then b:SetText(self.fixedText); b:HighlightText() end
            end)
            eb:HookScript("OnEditFocusGained", function(b) if self.fixedText then b:HighlightText() end end)
        end
        eb:Show()
        eb:SetFocus()
        if eb.HighlightText then eb:HighlightText() end
    else
        self.fixedText = nil
        self.input:Hide()
    end
    -- the box: the news size, or smaller to fit a short message
    local h = News.HEIGHT
    if spec.fit then h = math.min(News.HEIGHT, math.max(200, 64 + contentH + 12 + 60 + inputH)) end
    p:SetHeight(h)
    self.sf:SetVerticalScroll(0)
    if self.sf.UpdateScrollChildRect then self.sf:UpdateScrollChildRect() end
    -- buttons, side by side along the bottom
    for _, b in ipairs(self.btns) do b:Hide() end
    local list = spec.buttons or { { text = "Close" } }
    local bw, gap = 130, 12
    local total = #list * bw + (#list - 1) * gap
    for k, def in ipairs(list) do
        local b = self.btns[k]
        if not b then
            b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            b:SetSize(bw, 24)
            self.btns[k] = b
        end
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", p, "BOTTOM", -total / 2 + (k - 1) * (bw + gap), 26)
        b:SetText(def.text)
        b:SetScript("OnClick", function()
            local typed = self:InputText()
            self:Close()
            if def.onClick then PC:Safe("popup", def.onClick, typed) end
        end)
        b:Show()
    end
    self.closeBtn = self.btns[#list]
end

-- One pop-up at a time: one that comes up while another is showing waits its turn, and shows
-- when that one closes (newest request wins if the same pop-up asks twice)
Popup.queue = {}

-- Another pop-up is showing: wait. Returns true when this one was put in line.
function Popup:Wait(spec, how)
    local a = Popup.active
    if not (a and a ~= self and a:IsShown()) then return false end
    for i = #Popup.queue, 1, -1 do
        if Popup.queue[i].popup == self then table.remove(Popup.queue, i) end
    end
    Popup.queue[#Popup.queue + 1] = { popup = self, spec = spec, how = how }
    return true
end

-- Show it over the main window (already there); alone = on its own in the middle of the screen
-- (the main window closed: a warning doesn't open it)
function Popup:Present(spec, alone)
    local UI = PC.UI
    local parent = alone and UIParent or (UI and UI.f)
    if not parent then return end
    if self:Wait(spec, alone and "open" or "present") then return end
    self:Create(parent)
    self.cover:ClearAllPoints()
    if alone then
        self.cover:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
        self.dim:Hide()
    else
        self.cover:SetAllPoints(parent)
        self.dim:Show()
    end
    self.alone = alone and true or nil
    self.cover:Show()
    self:Fill(spec)
    if alone then self.cover:SetSize(self.p:GetWidth() or 560, self.p:GetHeight() or News.HEIGHT) end
    Popup.active = self
end

-- Over the main window when it's open; otherwise on its own (the window stays closed)
function Popup:Open(spec)
    local UI = PC.UI
    if not UI then return end
    if self:Wait(spec, "open") then return end
    self:Present(spec, not (UI.f and UI.f:IsShown()))
end

function Popup:Close()
    if self.input then self.input:ClearFocus(); self.input:Hide() end
    if self.cover then self.cover:Hide() end
    if Popup.active == self then Popup.active = nil end
    -- the next one waiting
    local nxt = table.remove(Popup.queue, 1)
    if nxt then
        if nxt.how == "open" then nxt.popup:Open(nxt.spec) else nxt.popup:Present(nxt.spec) end
    end
end

function Popup:IsShown()
    return self.cover and self.cover:IsShown() and true or false
end

News.popup = Popup.New("ProfitCrafterNews")

-- Open a standard pop-up by name (made once, reused). Returns false when the window isn't there.
UI.popups = UI.popups or {}
function UI:Ask(name, spec)
    local p = self.popups[name]
    if not p then p = Popup.New(name); self.popups[name] = p end
    p:Open(spec)
    return p:IsShown()
end

function News:Spec()
    local sections = {}
    if self.NOTES.top then
        sections[#sections + 1] = { lines = { "|cffffd100" .. self.NOTES.top .. "|r" }, bullets = false }
    end
    for _, s in ipairs(SECTIONS) do
        local lines = {}
        for _, l in ipairs(self.NOTES[s.key] or {}) do
            if type(l) == "table" then
                if not l.forever or PC.FOREVER then lines[#lines + 1] = l[1] end
            else
                lines[#lines + 1] = l
            end
        end
        sections[#sections + 1] = { title = #lines > 0 and s.title or nil, r = s.r, g = s.g, b = s.b, lines = lines }
    end
    -- feedback: the CurseForge page, in a box to copy from
    sections[#sections + 1] = { lines = { "Feedback or ideas? Copy this link (Ctrl+C) and paste it in your browser:" }, bullets = false }
    return { title = self:Title(), sub = "v" .. tostring(PC.VERSION), sections = sections,
        input = { text = self.FEEDBACK_URL, letters = 80, width = 420, fixed = true },
        fit = true, -- (as tall as the notes: the link box right under them)
        buttons = { { text = "Close", onClick = function() News:MarkSeen() end } } }
end

-- Put the notes over the main window (already open). Seen as soon as they're shown: the next
-- time the window opens they're gone, closed or not.
function News:Present()
    local UI = PC.UI
    if not (UI and UI.f) then return end
    self.popup:Present(self:Spec())
    self.cover, self.p, self.sf, self.body = self.popup.cover, self.popup.p, self.popup.sf, self.popup.body
    self:MarkSeen()
end

-- /pc news: open the window with the notes over it
function News:Show()
    local UI = PC.UI
    if not UI then return end
    self.forced = true
    UI:Show()
    self.forced = nil
    self:Present()
end

-- The release notes window opens by itself the first time the window opens on a new version
-- (on for 0.3.0 only: turn it off again for the next version unless told otherwise)
News.AUTO = true
function News:OnWindowShown()
    if self.forced then return end
    if self.AUTO and self:Due() then
        PC:Safe("news", self.Present, self)
    else
        self:MarkSeen()
        if self.popup:IsShown() then self.popup:Close() end
    end
end

function News:MarkSeen()
    if PC.db and PC.VERSION and PC.VERSION ~= "?" then PC.db.newsSeen = News:Key() end
end

function News:Close()
    self:MarkSeen()
    self.popup:Close()
end

---------------------------------------------------------------------------
-- Buying for a plan with prices more than an hour old: suggest a scan first
---------------------------------------------------------------------------
local Stale = { popup = Popup.New("ProfitCrafterStaleScan") }
UI.StaleScan = Stale
Stale.MAX_AGE = 3600

function Stale:Age()
    local t = PC.db and PC.db.scanTime and PC.db.scanTime[PC:Faction()]
    return t and (time() - t) or nil, t
end

-- true when buying can go ahead; otherwise shows the warning (once per old scan: Close = go ahead)
function Stale:Check()
    local age, stamp = self:Age()
    if age and age <= self.MAX_AGE then return true end
    if self.okFor ~= nil and self.okFor == (stamp or 0) then return true end
    local when = age and ("Your last Auction House scan was %s ago."):format(PC:Ago(age)) or "You haven't scanned the Auction House yet."
    self.popup:Open({
        title = "Prices may be out of date", sub = "Scan before you buy", subColor = { 1, 0.69, 0.25 },
        sections = { { lines = {
            when,
            "Prices change fast. Buying with old prices can cost you more than the plan says.",
            "Scan first to get today's prices, or Close to buy anyway.",
        }, bullets = false } },
        buttons = {
            { text = "Scan", onClick = function()
                if not PC.ahOpen then return PC.Print("Open the Auction House to scan.") end
                PC:StartScan()
            end },
            { text = "Close", onClick = function() Stale.okFor = stamp or 0 end },
        },
        fit = true,
    })
    return false
end

-- WoW Forever: a soft blue glow along the inside edges of the window
UI.FOREVER_GLOW = { 0.25, 0.6, 1, 0.15 } -- r, g, b, strength at the edge
function UI:ForeverGlow(f)
    if not PC.FOREVER or not f or f.foreverGlow then return end
    local c = self.FOREVER_GLOW
    local holder = CreateFrame("Frame", nil, f)
    holder:SetPoint("TOPLEFT", 6, -24)
    holder:SetPoint("BOTTOMRIGHT", -6, 6)
    holder:SetFrameLevel((f:GetFrameLevel() or 1) + 60) -- over the pages (it adds light; clicks pass through)
    holder:EnableMouse(false)
    f.foreverGlow = holder
    local SIZE = 46
    local function edge(p1, p2, w, h, orient, startEdge)
        local t = holder:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 1)
        t:SetPoint(p1); t:SetPoint(p2)
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
        t:SetBlendMode("ADD")
        -- from the colour at the edge to nothing further in
        local a1, a2 = (startEdge and c[4] or 0), (startEdge and 0 or c[4])
        local ok = false
        if t.SetGradient and CreateColor then
            ok = pcall(t.SetGradient, t, orient, CreateColor(c[1], c[2], c[3], a1), CreateColor(c[1], c[2], c[3], a2))
        end
        if not ok and t.SetGradientAlpha then
            ok = pcall(t.SetGradientAlpha, t, orient, c[1], c[2], c[3], a1, c[1], c[2], c[3], a2)
        end
        if not ok then t:SetColorTexture(c[1], c[2], c[3], c[4] * 0.3) end
    end
    -- (a vertical gradient runs bottom to top; a horizontal one left to right)
    edge("TOPLEFT", "TOPRIGHT", nil, SIZE, "VERTICAL", false)      -- top: bright at the top
    edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, SIZE, "VERTICAL", true) -- bottom: bright at the bottom
    edge("TOPLEFT", "BOTTOMLEFT", SIZE, nil, "HORIZONTAL", true)   -- left: bright at the left
    edge("TOPRIGHT", "BOTTOMRIGHT", SIZE, nil, "HORIZONTAL", false) -- right: bright at the right
end

local origCreate = UI.Create
function UI:Create(...)
    local r = origCreate(self, ...)
    if self.f and not self.newsHooked then
        self.newsHooked = true
        self.f:HookScript("OnShow", function() News:OnWindowShown() end)
        -- window closed: a pop-up over it goes with it (one on its own stays)
        self.f:HookScript("OnHide", function()
            local a = Popup.active
            if a and not a.alone then a:Close() end
        end)
    end
    if self.f then pcall(self.ForeverGlow, self, self.f) end
    return r
end
