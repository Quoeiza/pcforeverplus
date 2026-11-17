-- ProfitCrafter: the flight line
--   On a flight, a gold line centred on the screen by the Task Button: a little wyvern (Horde) or gryphon (Alliance) flaps along it
--   from where you took off to where you land, and the time left counts down at its end.
--   How long a flight takes: the time it took you last time (each route, each way, kept for every
--   character), or the first time, worked out from the route's hops on the flight map.
--   When another add-on's flight timer is up (EllesmereUI's flight bar, Forever++, InFlight...), this one
--   stays hidden for as long as that one shows. Settings > Travel and directions turns the line off.

local ADDON, ns = ...
local PC = ns.PC

local Fly = {}
PC.FlightLine = Fly

Fly.YELLOW = { 0.78, 0.59, 0.18 } -- the add-on's gold (the NOW bar, the arrow)
Fly.WIDTH = 510                -- the line, end to end (centred on the screen)
Fly.LINE_Y = 21                -- how far down the frame the line runs (the icon flaps above and below it)
Fly.THICK = 3                  -- the line's thickness
Fly.DOT = 8                    -- the dots at each end
Fly.ICON_SIZE = 42
Fly.FONT_SIZE = 15             -- the time, centred under the line
Fly.HEIGHT = 63
Fly.TOO_SHORT = 5              -- seconds: shorter wasn't a flight worth timing
Fly.WAIT = 10                  -- seconds to wait for a flight to start after taking it
Fly.TAKEOFF = 4                -- seconds a flight spends getting up and down (for the first-time guess)
Fly.MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
Fly.ICONS = { Horde = "Wyvern", Alliance = "Gryphon" } -- each 8 wing-beat frames side by side
Fly.FRAMES = 8
Fly.FLAPS = 16                 -- frames a second (two wing beats)
Fly.BOB_SECONDS = 4            -- one slow rise and fall
Fly.BOB = 1.5                  -- how far it rises and falls

-- Horde fly wyverns, Alliance gryphons
function Fly:Icon()
    local side = UnitFactionGroup and UnitFactionGroup("player")
    return self.MEDIA .. (self.ICONS[side] or self.ICONS.Horde)
end

-- db.flightTimes["Crossroads, The Barrens>Orgrimmar, Durotar"] = seconds
function Fly:Times()
    PC.db.flightTimes = PC.db.flightTimes or {}
    return PC.db.flightTimes
end

local function Key(from, to) return (from or "?") .. ">" .. (to or "?") end

-- "1:23"
function Fly:Clock(secs)
    secs = math.max(math.floor((secs or 0) + 0.5), 0)
    return ("%d:%02d"):format(math.floor(secs / 60), secs % 60)
end

-- The first time on a route: the hops it flies, at flight speed
function Fly:Estimate(slot)
    local T = PC.Travel
    local hops = GetNumRoutes and GetNumRoutes(slot)
    local map = GetTaxiMapID and GetTaxiMapID()
    if not T or not hops or hops < 1 or not map or not (TaxiGetSrcX and TaxiGetSrcY and TaxiGetDestX and TaxiGetDestY) then return nil end
    local yards = 0
    for hop = 1, hops do
        local a = { map = map, x = TaxiGetSrcX(slot, hop), y = TaxiGetSrcY(slot, hop) }
        local b = { map = map, x = TaxiGetDestX(slot, hop), y = TaxiGetDestY(slot, hop) }
        if not (a.x and a.y and b.x and b.y) then return nil end
        local d = T:Yards(a, b)
        if not d then return nil end
        yards = yards + d
    end
    if yards <= 0 then return nil end
    return yards / (T.FLY_SPEED or 30) + self.TAKEOFF
end

-- Taking a flight (TakeTaxiNode): where from, where to, and how long it should take
function Fly:OnTake(slot)
    local from
    if PC.Travel and PC.Travel.TaxiNodes then
        for _, n in ipairs(PC.Travel.TaxiNodes()) do if n.kind == "CURRENT" then from = n.name end end
    end
    local to = TaxiNodeName and TaxiNodeName(slot) or nil
    local known = from and to and self:Times()[Key(from, to)]
    self.flight = { from = from, to = to, total = known or self:Estimate(slot), exact = known ~= nil, asked = GetTime() }
    self:Watch(true)
end

function Fly:Cancel()
    self.flight = nil
    self:Watch(false)
    if self.frame then self.frame:Hide() end
end

-- Landed: remember how long it took (not when you got off early)
function Fly:Finish()
    local f = self.flight
    if f and f.started and not f.aborted and f.from and f.to then
        local took = GetTime() - f.started
        if took >= self.TOO_SHORT then self:Times()[Key(f.from, f.to)] = math.floor(took + 0.5) end
    end
    self:Cancel()
end

---------------------------------------------------------------------------
-- The line
---------------------------------------------------------------------------
function Fly:Frame()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "ProfitCrafterFlightLine", UIParent)
    f:SetSize(self.WIDTH, self.HEIGHT)
    f:SetFrameStrata("MEDIUM")
    local Y = self.YELLOW
    -- the way still to go: faint; the way flown: full yellow
    f.rest = f:CreateTexture(nil, "ARTWORK")
    f.rest:SetHeight(self.THICK)
    f.rest:SetColorTexture(Y[1], Y[2], Y[3], 0.3)
    f.done = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.done:SetHeight(self.THICK)
    f.done:SetColorTexture(Y[1], Y[2], Y[3], 1)
    -- a dot at each end: where you took off, where you land
    f.startDot = f:CreateTexture(nil, "OVERLAY")
    f.startDot:SetSize(self.DOT, self.DOT)
    f.startDot:SetColorTexture(Y[1], Y[2], Y[3], 1)
    f.endDot = f:CreateTexture(nil, "OVERLAY")
    f.endDot:SetSize(self.DOT, self.DOT)
    f.endDot:SetColorTexture(Y[1], Y[2], Y[3], 0.6)
    f.icon = f:CreateTexture(nil, "OVERLAY", nil, 2)
    f.icon:SetSize(self.ICON_SIZE, self.ICON_SIZE)
    f.icon:SetTexture(self:Icon())
    f.icon:SetVertexColor(Y[1], Y[2], Y[3])
    f.icon:SetTexCoord(0, 1 / self.FRAMES, 0, 1)
    f.time = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.time:SetTextColor(Y[1], Y[2], Y[3])
    if f.time.GetFont and f.time.SetFont then
        local font, _, flags = f.time:GetFont()
        if font then f.time:SetFont(font, self.FONT_SIZE, flags) end
    end
    f.time:SetJustifyH("CENTER")
    f.time:SetPoint("TOP", f, "TOP", 0, -(self.LINE_Y + self.DOT / 2 + 6))
    -- the line runs the whole width, the time centred under it
    f.lineLeft, f.lineRight = self.DOT, self.DOT
    local y = -self.LINE_Y
    f.rest:SetPoint("LEFT", f, "TOPLEFT", f.lineLeft, y)
    f.rest:SetPoint("RIGHT", f, "TOPRIGHT", -f.lineRight, y)
    f.startDot:SetPoint("CENTER", f, "TOPLEFT", f.lineLeft, y)
    f.endDot:SetPoint("CENTER", f, "TOPRIGHT", -f.lineRight, y)
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(frame)
        local fl = Fly.flight
        if not fl or not PC.UI or not PC.UI.ShowTooltip then return end
        local lines = { fl.to and ("Flying to " .. fl.to) or "Flying" }
        if fl.from then lines[#lines + 1] = "From " .. fl.from end
        local left = fl.total and fl.started and (fl.total - (GetTime() - fl.started))
        if left then lines[#lines + 1] = (fl.exact and "Lands in %s" or "Lands in about %s"):format(Fly:Clock(left > 0 and left or 0)) end
        if fl.exact then
            lines[#lines + 1] = ("|cff40ff40Learned:|r this flight took %s last time."):format(Fly:Clock(fl.total))
        else
            lines[#lines + 1] = "|cffffd100First time on this flight:|r worked out from the flight map."
            lines[#lines + 1] = "The real time is learned when you land, for next time."
        end
        local n = 0
        for _ in pairs(Fly:Times()) do n = n + 1 end
        lines[#lines + 1] = ("|cff888888Flight times learned so far: %d (every route, each way). Getting off early isn't counted.|r"):format(n)
        PC.UI.ShowTooltip(frame, lines)
    end)
    f:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    f:Hide()
    self.frame = f
    return f
end

-- Centred on the screen, just past the Task Button on the side away from its task list
-- (or high in the middle if it's closed)
local function CenterX(fr)
    if not (fr and fr.GetCenter and fr.GetEffectiveScale) then return nil end
    local x = fr:GetCenter()
    return x and x * fr:GetEffectiveScale() or nil
end
function Fly:Place()
    local f = self:Frame()
    f:ClearAllPoints()
    f:SetWidth(self.WIDTH)
    local bar = PC.Next and PC.Next.bar
    if bar and bar:IsShown() then
        -- (how far the button sits from the middle of the screen: the line goes back to the middle)
        local dx = 0
        local bx, ux = CenterX(bar), CenterX(UIParent)
        if bx and ux and f.GetEffectiveScale then dx = (ux - bx) / (f:GetEffectiveScale() or 1) end
        if PC.db and PC.db.dropDown then
            f:SetPoint("BOTTOM", bar, "TOP", dx, 2)
        else
            f:SetPoint("TOP", bar, "BOTTOM", dx, -2)
        end
    else
        f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
end

-- The line is wanted (Settings > Travel and directions; flights are timed either way)
function Fly:On()
    return not (PC.db and PC.db.flightLine == false)
end

-- EllesmereUI Forever Essentials' flight bar, when it's on (nil when it isn't there or is turned off)
function Fly:EllesmereBar()
    local E = _G.EllesmereUI
    local el = type(E) == "table" and type(E._unlockRegisteredElements) == "table" and E._unlockRegisteredElements.EUI_FlightTimer
    if type(el) ~= "table" or type(el.getFrame) ~= "function" then return nil end
    local ok, f = pcall(el.getFrame) -- (nil while its flight timer is turned off)
    return ok and type(f) == "table" and f.IsShown and f or nil
end

-- Another add-on's flight timer is up: ours stays out of the way (the flight is still timed)
local function Loaded(name)
    local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if not f then return false end
    local ok, yes = pcall(f, name)
    return ok and yes and true or false
end
Fly.OTHERS = { "InFlight", "InFlight_Load", "FlightMap", "FlightHUD", "FlightTimer", "FlightTimes" }
function Fly:OtherTimer()
    -- EllesmereUI: only while its bar is really on screen (after a reload mid-flight it has none: ours shows)
    local eb = self:EllesmereBar()
    if eb and eb:IsShown() then return "EllesmereUI" end
    -- the rest don't change during a flight: worked out once per flight
    local fl = self.flight
    if fl and fl.other ~= nil then return fl.other or nil end
    local other = self:StaticTimer()
    if fl then fl.other = other or false end
    return other
end

function Fly:StaticTimer()
    -- Forever++: its Flight Timer module, with its bar on (both are on unless turned off in its settings)
    if Loaded("ForeverPlusPlus") then
        local db = type(ForeverPlusPlusDB) == "table" and ForeverPlusPlusDB
        local st = db and type(db.settings) == "table" and db.settings.FlightTimer
        if not (type(st) == "table" and (st.enabled == false or st.bar == false)) then return "Forever++" end
    end
    -- Leatrix Plus: its flight progress bar
    if Loaded("Leatrix_Plus") and type(LeaPlusDB) == "table" and LeaPlusDB.ShowFlightTimes == "On" then return "Leatrix Plus" end
    for _, name in ipairs(self.OTHERS) do if Loaded(name) then return name end end
    return nil
end

-- Where the icon is, and the time left
function Fly:Draw()
    local fl, f = self.flight, self:Frame()
    if not fl or not fl.started then return end
    local elapsed = GetTime() - fl.started
    local w = (f:GetWidth() or self.WIDTH) - f.lineLeft - f.lineRight
    local frac
    if fl.total and fl.total > 0 then
        frac = math.min(elapsed / fl.total, 1)
        local left = fl.total - elapsed
        if left > 0 then f.time:SetText(self:Clock(left))
        else f.time:SetText("landing") end
    else
        -- no way to tell how long (not even the flight map's route): the icon waits at the start
        frac = 0
        f.time:SetText("")
    end
    local x = f.lineLeft + w * frac
    -- flapping (frame by frame, like an animated picture) and bobbing up and down as it flies
    local beat = GetTime() * self.FLAPS / self.FRAMES
    local n = math.floor(beat * self.FRAMES) % self.FRAMES
    f.icon:SetTexCoord(n / self.FRAMES, (n + 1) / self.FRAMES, 0, 1)
    -- a slow, gentle rise and fall as it flies (not tied to the wing beat)
    local bob = math.sin(GetTime() * 2 * math.pi / self.BOB_SECONDS) * self.BOB
    f.icon:ClearAllPoints()
    f.icon:SetPoint("CENTER", f, "TOPLEFT", x, -self.LINE_Y + bob)
    f.done:ClearAllPoints()
    f.done:SetPoint("LEFT", f, "TOPLEFT", f.lineLeft, -self.LINE_Y)
    f.done:SetWidth(math.max(w * frac, 1))
end

---------------------------------------------------------------------------
-- Watching the flight (ten times a second, only between taking a flight and landing)
---------------------------------------------------------------------------
function Fly:Tick()
    local fl = self.flight
    if not fl then return self:Cancel() end
    local now = GetTime()
    local onTaxi = UnitOnTaxi and UnitOnTaxi("player")
    if not fl.started then
        if onTaxi then
            fl.started = now
            self:Frame().icon:SetTexture(self:Icon())
        elseif now - fl.asked > self.WAIT then
            self:Cancel() -- never took off
        end
        return
    end
    if not onTaxi then return self:Finish() end
    -- turned off, or another add-on's timer is showing this flight: hidden (looked at every tick, so
    -- the line steps aside the moment EllesmereUI's bar shows, and comes back if it goes)
    fl.quiet = (not self:On() and "off") or self:OtherTimer()
    local f = self:Frame()
    if fl.quiet then
        if f:IsShown() then f:Hide() end
        return
    end
    if not f:IsShown() then self.placedAt = now; self:Place(); f:Show() end
    -- (the Task Button may have moved or been closed)
    if (self.placedAt or 0) + 1 < now then self.placedAt = now; self:Place() end
    self:Draw()
end

function Fly:Watch(on)
    if not self.watcher then
        self.watcher = CreateFrame("Frame")
        self.watcher.wait = 0
        self.watcher:SetScript("OnUpdate", function(w, elapsed)
            w.wait = w.wait - (elapsed or 0)
            if w.wait > 0 then return end
            w.wait = 0.02 -- (often enough that the flapping and the move along the line look smooth)
            PC:Safe("flight line", Fly.Tick, Fly)
        end)
    end
    if on then self.watcher:Show() else self.watcher:Hide() end
end

if hooksecurefunc and TakeTaxiNode then
    hooksecurefunc("TakeTaxiNode", function(slot) PC:Safe("flight line", Fly.OnTake, Fly, slot) end)
end
if hooksecurefunc and TaxiRequestEarlyLanding then
    hooksecurefunc("TaxiRequestEarlyLanding", function() if Fly.flight then Fly.flight.aborted = true end end)
end
do
    local ev = CreateFrame("Frame")
    pcall(ev.RegisterEvent, ev, "PLAYER_ENTERING_WORLD")
    ev:SetScript("OnEvent", function()
        -- a loading screen: any flight is over (and none is timed)
        if Fly.flight and not (UnitOnTaxi and UnitOnTaxi("player")) then Fly:Cancel() end
    end)
end
