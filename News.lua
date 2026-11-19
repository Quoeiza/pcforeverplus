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
        "Every recipe has a separate Auction Profit and Vendor Profit. They replace the single Profit column and appear in the tables, tooltips, sale notes, the Purge list and \"Now profitable\" alerts.",
        "New Sells at vendor column, next to Sells at auction.",
        "Profit % shows the higher of the auction and vendor percentages, and the recipe tooltip says which.",
        "\"Only profitable\" is replaced by a Minimum profit % box on the Recipes and Learn pages, 10% by default. The tables always hide recipes that make less than it both at auction and at a vendor. Skill up and Gear upgrades plans ignore it.",
        "New Craftable at Profit, Total Auction Profit and Total Vendor Profit columns. Craftable at Profit counts the crafts that make your minimum profit, at auction or at a vendor, whichever gives more. They price the whole batch against the real listings, not just the cheapest one, and allow for your gold, what is listed, your bag space and auction deposits.",
        "The \"how many?\" pop-up and the Crafting plan price batches the same way and show both profits. The pop-up has a Max profitable button and says where buying will stop.",
        "Best bets only shows recipes that make the minimum profit and, for auction, sold at least half as many in the last 24 hours as are listed. They're ranked by gold an hour for the batch Make me gold would make (Craftable at Profit, no more than your market share): its profit over the time the crafts take at the game's cast time, plus 2 minutes to buy and post, so a batch making a few silver never outranks one making gold. One that sold out over the last day, not because of a buyout, scores a quarter more. The recipe tooltip shows the gold an hour, the profit, the crafts and the time.",
        "Make me gold uses the same rules for its picks and its Your materials list.",
        "Make me gold makes each recipe in a batch the size of your market share (your share of what players typically buy in a day, at most a fifth of what's listed, half for something you haven't sold yet) instead of 2 or 3 at a time, and your own sales still raise it. Misc gets 5% more for a hot seller, instead of when 100 or more sell a day. It picks 2 to 6 recipes by gold an hour, leaving out any that make under half of the best one's.",
        "Make me gold has a \"Sell what's already in my bags & bank\" tick box: untick it to keep what you're still carrying, your spare materials, and the materials its Your materials crafts would use. The \"Only things that sell N a day\" box is gone, and the share boxes read \"Don't sell more gear (misc) than N% of what players typically buy in a day\".",
        "Make me gold shows only the profit the way each line is sold. Materials you already have count as free, and the line ends with \"(using bag materials)\". The totals are Total predicted cost (the gold you spend), returns (the gold you get back, including what's in your bags) and profit, then the bag slots used, reagent bag included.",
        "Have materials only plans recipes that make the minimum profit, and auction recipes only if they sold in the last day.",
        "New setting to only recommend auction recipes that sold in the last day, on by default. A recipe with no sales in the last day shows an orange 0 and a note in its tooltip.",
        "Auction flips fill every column, are labelled as flips and have a fuller tooltip.",
        "A sell price that has spiked well above what the item usually sells for (a buyout leaving a few overpriced listings, say) is counted at no more than 1.5 times its usual sale price, in every profit, table, Best bets and Make me gold. The Sells at auction cell turns orange and the tooltip explains. The usual price comes from the sales your scans see, needs a day of them, and follows a real price rise within a day.",
        "ProfitCrafter users share what their plans will put on the Auction House (crafts still to do, and items made but not yet posted), when a plan changes and again when it's gone. The advice allows for it but never blocks anything. The recipe tooltip says what's coming, Best bets ranks those recipes lower, and the \"how many?\" pop-up, Make me gold and Quick Buy suggest a smaller batch, never less than half. Vendor recipes aren't affected.",
        "Buying stops before a material would take its recipe below the minimum profit. The plan is then cut to what was bought and chat says so. /pc undo puts it back.",
        "A material several recipes share goes to the ones that can afford it most, and what you already have covers those first.",
        "Recipes whose rare materials you already have are still finished, as long as each one earns more than its other materials cost.",
        "One-click buying, on by default. Buy asks for the price and buys straight away if the item is still profitable. If the game won't allow it, it goes back to two clicks.",
        "Quick Buy, the coin on each recipe. It plans as many crafts as make your minimum profit, buys the main auction material and opens the plan.",
        "An auction price more than 5% above what the listings showed is refused and the listings are read again. 0.3.0 only warned, at 25%.",
        "A price that has been waiting for over 10 seconds is checked again before buying.",
        "Every auction purchase ends with a clear message, including the odd cases: paid but no answer, an answer but no gold taken, failed but gold taken, and a purchase that went through late.",
        "Auction listings are bought whenever they are cheaper than a vendor (0.3.0 needed them 10% cheaper). If the price comes back at or above the vendor's, the item switches to the vendor.",
        "Separate auctions never buy a listing bigger than the plan still needs.",
        "Vendor buying buys as many as your gold allows and then says it ran out. 0.3.0 refused the whole lot.",
        "In the Materials table, Have shows what is in the bank, in the mail and on its way. A purchase on its way shows \"buying N\" and its button can't be clicked again. The Buy tooltip says how many were left out to keep the minimum profit.",
        "The Task Button shows \"Waiting for the Auction House to confirm...\" while a purchase is unanswered, vendor buying progress, and \"Stopped buying X (under 10% profit)\".",
        "Posting never matches a spiked cheapest listing, which wouldn't sell. It posts at no more than 1.5 times the usual price and says why.",
        "Selling to a vendor sells exact amounts, splitting stacks when needed. This covers crafted items, flips, spare materials, leftovers and the Purge.",
        "Each vendor sale is checked before the next one, and anything left unsold is reported with the reason. At a vendor, buying finishes before selling starts, with one note at the end.",
        "The Sell page has Auction Profit and Vendor Profit columns.",
        "Junk is left to Scrap when Scrap is installed.",
        "Scans also price what learnable recipes make and use.",
        "On the Learn page, profits built on prices over 6 hours old are marked ~, and recipes with no known source or cost show ? instead of a profit.",
        "Your own scan of an item beats prices shared by other players for a minute.",
        "New \"Use what's in my bank\" setting, on by default. Turned off, the bank is ignored completely: nothing in it is counted, taken out or stored.",
        "Clicking a recipe while the Auction House is open opens its listings there, ready to buy. Shift-click does the same in the other tables. 0.3.0 only searched by name, and needed Shift held.",
        "A Refresh button on each recipe reads that recipe's price, listings and materials from the Auction House straight away, without a full scan. It sits at the right end of the row with Quick Buy and Add to plan.",
        "Each tab starts in the order that matters there: Total Auction Profit on All professions and each profession, Total Vendor Profit on Vendor flips, and best bet order on Best bets, which has a Best bet order button to sort again. The line under the table says how it's sorted.",
        "Auction flips on Vendor flips show their name in light blue instead of an \"(auction flip)\" tag that got cut off. Their tooltip still says what they are.",
        "The Sold today column is now Sold in 24h: sales in the last 24 hours, the figure the recommendations go by. Since midnight knew next to nothing just after it.",
        "Every table sorts on every column and remembers its sort. Each column has a two-line heading with a tooltip.",
        "Columns are sized to fit their headings and values, and the name column gets the rest. Table text is slightly smaller, and the window is wider.",
        "Money in a table is never cut off. The text shrinks, then the copper is dropped, then the silver.",
        "Recipe tooltips list every ingredient with its price, where it comes from and how many you have. They also show what a vendor pays, both profits (with the reason when one is missing), how many you can craft at a profit, what limits it, and how many make your minimum.",
        "The recipe count says how many recipes the minimum profit is hiding.",
        "Craft tasks give the item count when a recipe makes more than one, e.g. \"34 Seasoned Wolf Kabob (makes 102)\".",
        "The flight line is back, with a setting to turn it off. It hides while another flight timer is showing, such as EllesmereUI's flight bar.",
        "Sharing keeps to a budget for the whole channel. The more users are talking, the less each one sends, so traffic stays about the same with 50 users or 50,000. Price shares send the freshest prices first, within that budget.",
        "The list of users heard from is tidied once an hour instead of on every message.",
        "Faster auction scans. Each search asks for 100 items (was 25), results are read as soon as they are complete, live listings are read back to back, and listings that haven't changed in the last 2 hours aren't read again.",
        "Much less work on each refresh. Your sales and purchases are indexed, bag slots and item info are read once, and sorting, searching and filtering no longer re-analyse every recipe. Tooltips are built when you hover.",
        "The Learn list, route planning and nearest-place lookups do far less work. Routes keep their fixed part between uses and only search the current continent.",
        "The direction arrows work out their aim once per tick and not at all while you stand still.",
        "Scrolling the task list reuses the Task Button's step, and a guide change updates both in one pass.",
        "Gear upgrades remembers whether you can wear an item and what it gives, instead of re-reading tooltips.",
    },
    fixed = {
        "Buying could go over the plan when the Auction House answered slowly. A purchase with no answer after 10 to 15 seconds was dropped and could be bought again, and cancelling forgot a purchase already sent.",
        "One purchase could print two or three \"Bought\" lines.",
        "Clicking Buy on a second item before the first item's price arrived could take the first item's price for the second.",
        "A refused purchase could later be counted as bought when gold was spent on something else.",
        "When the game blocked an automatic price request, it wrongly said the Auction House sent no price. It now asks for a click.",
        "If the Auction House changed a price you were holding, the confirm click paid the new price unchecked.",
        "Vendor purchases not in your bags within a second were bought again, up to three times.",
        "Vendor buying ignored plan changes made at the vendor, and kept offering items already bought.",
        "The plan priced large auction buys up the listings past what a vendor charges, instead of buying the rest from the vendor.",
        "A recipe's material cost was the cheapest listing times the amount it takes, so one cheap listing made a recipe look profitable on every tab. Everything a craft needs is now priced up the real listings, including what goes into materials you make yourself (the 20 Silk Cloth in a vest's 5 bolts). This applies to the Materials column, both profits, Profit %, every table and tooltip, Best bets, Make me gold and the Learn page.",
        "Make me gold multiplied the cheapest price by the count while the cost climbed the listings. It overstated profit and could pick batches that lose money.",
        "What you sell of an item a day was averaged over 14 days even when you started selling it yesterday, so posting and Make me gold held back the next batch of something that had just sold out. It now counts from your first sale in those 14 days.",
        "With no sell route chosen, a craft went to a vendor whenever the vendor covered its cost, even when the Auction House paid far more. It now goes to the vendor only when that brings in at least as much.",
        "Buying a separate auction (gear, bags) could pay above the price that keeps the craft at the minimum profit. A bid below the buyout was counted as a purchase.",
        "Posting several of an item as separate auctions checked and held back the deposit for one of them.",
        "Selling spare materials offered ones you had chosen to keep.",
        "A full scan that came back empty wiped every price and counted everything as just sold. Your prices are now kept.",
        "A profession the game lists after a gap (First Aid on some clients) was missed, and its recipes forgotten.",
        "Auction flips counted every listing under the vendor price in Craftable at Profit, not only those making the minimum profit.",
        "A plan's own choices (crafts skipped, materials bought instead of made, items kept) stayed behind when it was renamed or deleted, and came back in a new plan with that name.",
        "/pc undo after skipping vendor flips undid an older removal instead.",
        "The task list showed a skipped craft as well as the same craft back in the plan, its tick boxes said \"skip this craft\" on buy and sell rows, and its Auction rows were labelled AH.",
        "Adding crafts from your bags blamed bag space when the market limit stopped them.",
        "The plan page's Spend left out the posting deposits that the Task Button counts.",
        "Greens queued for disenchanting could lose their place while the game was still loading their details.",
        "Shared place details could overwrite a place's spot or stock, and a shared listed count had no upper limit.",
        "The top row's Minimum profit %, Can afford and search showed on every page, though they only filter Recipes (and the search, History).",
        "Several tooltips showed two different click hints, a spiked price read \"Sells for 2g (counted at).\", and dates were written month first.",
        "Settings and History text still said \"today\", \"AH\" and a deeper undercut for unsold items that is never applied.",
        "Stored live listings were used indefinitely, even after the item sold out or its price changed.",
        "Vendor sales only sold whole stacks. Extras and the rest of spare materials were left unsold and forgotten.",
        "Selling back leftovers could leave a split stack on the cursor when the only empty slot was in a profession bag.",
        "During a Purge, unticked items could still be sold below cost, or drop out of the tick list.",
        "An error while building the Purge list wiped your unticked items and could leave Purge on.",
        "Posting on the newer Auction House could ask for more than you had while a stack was locked.",
        "The plan made what it could from materials you held even when buying the item was cheaper, such as linen worth 23c into a bandage you can buy for 10c. It now only does that when it saves gold. When it does, the materials row shows how many are still bought, not just \"make N\".",
        "The plan's bag check ignored free slots in the reagent bag.",
        "Vendor purchases and crafts came in smaller batches than your bags allowed, because the room freed by used-up materials wasn't counted.",
        "The bank crashed with a stack overflow whenever an item was on the cursor.",
        "Hearthstone and teleports were offered for stops in your own zone, including jumping out and walking back in.",
        "The task list said \"walk to X (3 yd)\" for a stop you were already at, and measured later stops from where you stood instead of from the stop before.",
        "A plan count typed while the rows moved could land on another recipe. Escape now cancels.",
        "A Keep number typed on the Sell page could land on another item.",
        "The empty recipe list blamed \"Only profitable\" when Can afford had hidden the rows.",
        "The \"Stock up\" alert always said \"usually n/a\".",
        "Skip only said \"This task can't be skipped\" on crafts, purchases and bank trips. It now skips them the same way as unticking them on the task list.",
        "Skipping selling at the Auction House, or the mail at the mailbox, came straight back while you were still there.",
        "Unreadable (secret) game messages caused errors in the bank, mail, loot, vendor and auction messages, learned recipes and disenchanting.",
        "Place, NPC and recipe names shared from clients in other languages showed in another alphabet. They are now translated or left out.",
        "Shared prices from a player whose clock ran fast blocked newer prices until that time passed.",
        "On newer clients, recipes read from the profession window lost their required materials, so Learn page profits came out too high.",
        "Trainer windows were never read on WoW Forever, so a trainer recipe with no named trainer sent you to the nearest trainer of that profession, whether or not it teaches it. Trainer windows are now read, and a trainer you've visited is only suggested for what its window lists. A recipe the data lists only outside the cities is no longer swapped for a city trainer.",
        "A trainer list shared by another player now names the trainer even if you've never been there (it said \"Your trainer\"). Lists are also passed on to players who were offline, and a list from a trainer outside the cities is no longer swapped for the trainer where you are.",
        "Profession ranks you already have, such as Journeyman Cook at 300 skill, were suggested as recipes to train.",
        "Goldthorn Tea is taught by Henry Stern in Razorfen Downs, and Smoked Desert Dumplings comes from the quest Sharing the Knowledge in Silithus. Both pointed to the city cooking trainers.",
        "The crafting station check errored on clients without C_TradeSkillUI, and the undercut check errored on clients without C_AuctionHouse when Auctionator was installed.",
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
