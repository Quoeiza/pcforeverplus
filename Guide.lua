-- ProfitCrafter: SnuggleUp Forever's quest guide as a plan ("Cozy Sleeping Bag Guide")
--   With SnuggleUp installed, ProfitCrafter is its host: the guide runs as one of your plans, on the
--   same Task Button, task list, arrows and waypoint. Only one plan runs at a time, so the guide and a
--   ProfitCrafter plan never fight over them. SnuggleUp keeps working out the steps; ProfitCrafter
--   only shows them. Nothing of SnuggleUp's is changed: only its Guide calls are used (each in a pcall).

local ADDON, ns = ...
local PC = ns.PC

local Guide = {}
PC.Guide = Guide

Guide.HOST = "ProfitCrafter Forever"
Guide.DEFAULT_NAME = "Cozy Sleeping Bag Guide"

-- SnuggleUp with the guide calls (nil when it isn't installed, or too old)
function Guide:SU()
    local su = _G.SnuggleUp
    if type(su) ~= "table" then return nil end
    if (tonumber(su.GUIDE_API) or 0) < 1 then return nil end
    return su
end

local function Call(fn, ...)
    local su = Guide:SU()
    if not su or type(su[fn]) ~= "function" then return nil end
    local ok, a = pcall(su[fn], su, ...)
    if ok then return a end
    return nil
end

function Guide:On() return self.registered == true end
function Guide:Name() return self.name or self.DEFAULT_NAME end
function Guide:IsName(name) return self:On() and name ~= nil and name == self:Name() end
-- the guide is the running plan
function Guide:Active() return self:On() and PC.PlanName and PC:PlanName() == self:Name() end

-- At login: register as SnuggleUp's host (it then hides its own button, list, arrows and pins)
function Guide:Register()
    if self.registered then return true end
    local su = self:SU()
    if not su then return false end
    local bar = PC.Next and PC.Next.CreateBar and PC.Next:CreateBar()
    local btn = bar and bar.btn
    local r = Call("GuideRegister", self.HOST, { button = btn, binding = "PROFITCRAFTER_NEXT" })
    if r ~= 1 and r ~= true then return false end
    self.registered = true
    local name = Call("GuideName")
    self.name = (type(name) == "string" and name ~= "") and name or self.DEFAULT_NAME
    -- the plan entry (only while registered)
    if PC.cdb then
        local plans = PC:Plans()
        plans[self.name] = plans[self.name] or {}
        PC.cdb.guideName = self.name
    end
    Call("GuideListen", "ProfitCrafter", function() Guide:Changed() end)
    self.told = nil
    self:Sync()
    return true
end

-- The guide's state may have changed: redraw the button and list (SnuggleUp calls this at most 4 times a second)
function Guide:Changed()
    self.stateCache = nil
    if not self:Active() then return end
    if PC.Pending and PC:Pending("ui") then return end -- the refresh on its way does it
    PC:Safe("guide", function()
        if PC.Next then PC.Next:UpdateBar() end
        if PC.Steps and PC.Steps.Refresh then PC.Steps:Refresh() end
    end)
end

-- Tell SnuggleUp whether it's the running plan; switching clears the old plan's waypoint first
function Guide:Sync()
    if not self:On() then return end
    local want = self:Active() and true or false
    if self.told == want then return end
    self.told = want
    if PC.Places and PC.Places.ClearPin then pcall(PC.Places.ClearPin, PC.Places) end
    Call("GuideActive", want)
    self.stateCache = nil
end

-- (asked once for the button, the list and the title together: kept a fifth of a second)
function Guide:State()
    local now = GetTime and GetTime() or 0
    local c = self.stateCache
    if c and now - c.t < 0.2 then return c.st end
    local st = Call("GuideState")
    if type(st) ~= "table" then st = nil end
    self.stateCache = { t = now, st = st }
    return st
end

-- The Task Button's step while the guide runs
function Guide:Step()
    local st = self:State() or {}
    local now = type(st.now) == "table" and st.now or {}
    local s = { guide = true, cat = now.cat or "Quest", text = now.text or "", label = now.label, tip = now.tip,
        travel = now.travel and true or false, hearth = now.hearth, flying = now.flying and true or nil,
        doneN = tonumber(st.doneN) or 0, total = tonumber(st.total) or 0, finished = st.finished and true or false }
    local d = now.dest
    if type(d) == "table" and d.map and d.x and d.y then
        s.dest = { map = d.map, x = d.x, y = d.y, name = d.name, kind = "guide" }
    end
    if s.finished then
        if s.text == "" then s.text = self:Name() .. ": all done!" end
        s.left = 0
    else
        s.left = 1
        s.run = function() Call("GuideClick"); Guide.stateCache = nil end
        if now.canSkip then
            s.skip = function() Call("GuideSkip"); Guide.stateCache = nil end
            s.skipTip = now.skipTip
        end
    end
    if s.text == "" then s.text = s.label or self:Name() end
    return s
end

-- The task list while the guide runs: { cat, text } rows, item 1 is what the button does now
function Guide:Rows()
    local st = self:State() or {}
    local out = {}
    for _, r in ipairs(type(st.list) == "table" and st.list or {}) do
        if type(r) == "table" then
            local text = tostring(r.text or "")
            if r.optional then text = text .. " (optional)" end
            out[#out + 1] = { cat = r.cat or "Quest", text = text, skipped = r.skipped and true or nil, plain = false, guide = true,
                note = r.note and true or nil } -- (a warning or a tip, right by the NOW line: "!" for its number)
        end
    end
    if #out == 0 then out[1] = { cat = "Done", text = st.finished and "the guide is done" or "nothing to show yet" } end
    return out
end

-- "Cozy Sleeping Bag Guide  (3 of 12 done)"
function Guide:Title()
    local st = self:State() or {}
    local done, total = tonumber(st.doneN) or 0, tonumber(st.total) or 0
    local left = type(st.timeLeft) == "string" and st.timeLeft or nil
    return self:Name() .. (total > 0 and ("  |cff888888(%d of %d done)%s|r"):format(done, total, left and ("  ·  " .. left) or "") or "")
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    -- (after ProfitCrafter's own login setup, so the Task Button and your plans are there)
    C_Timer.After(1, function() PC:Safe("guide", function()
        if Guide:Register() then PC:RefreshUI() return end
        -- SnuggleUp gone (or too old): the guide leaves your plans (picking the plan you'd had otherwise)
        local cdb = PC.cdb
        local name = cdb and cdb.guideName
        if name and PC:Plans()[name] and not next(PC:Plans()[name]) then
            PC:Plans()[name] = nil
            if cdb.planCurrent == name then cdb.planCurrent = nil; PC:PlanName() end
            PC:RefreshUI()
        end
    end) end)
end)
