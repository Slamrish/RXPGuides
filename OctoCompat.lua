-- OctoCompat.lua
-- SuperWoW / OctoWoW (1.12-era client) compatibility shim for RXPGuides.
-- This file must be loaded FIRST (before all other addon files) so that
-- global namespace stubs are in place when the rest of the addon executes.
--
-- Strategy:
--   * Detect 1.12-era clients by the absence of modern globals (C_Timer, etc.)
--   * Provide minimal no-op or functional fallbacks so the addon loads cleanly.
--   * All guards are additive: existing values are never overwritten, so
--     behaviour on modern clients is completely unchanged.

-- ---------------------------------------------------------------------------
-- Environment detection
-- ---------------------------------------------------------------------------

-- RXPGuides detects game version via select(4, GetBuildInfo()), which returns
-- an integer like 11200 on 1.12 clients.  We expose this as a flag so other
-- shim sections can test it cheaply.
local _buildVersion = select(4, GetBuildInfo()) or 0
-- OctoWoW / SuperWoW report interface versions in the 11xxx range.
local isLegacyClient = (_buildVersion < 20000)

-- ---------------------------------------------------------------------------
-- C_Timer  (frame-OnUpdate based fallback)
-- ---------------------------------------------------------------------------
-- RXPGuides.lua references C_Timer.NewTicker at module scope (line 36), and
-- several callsites use C_Timer.After(delay, func) without nil-guards.
-- We provide a light implementation via a single shared dispatcher frame.

if not C_Timer then
    local _timerFrame = CreateFrame("Frame")
    local _pending = {}           -- {expiry, func, interval, count, cancelled}
    local _frameRunning = false

    local function _tick(_, elapsed)
        local now = GetTime()
        local anyActive = false
        for i = #_pending, 1, -1 do
            local t = _pending[i]
            if not t.cancelled then
                if now >= t.expiry then
                    -- fire
                    local ok, err = pcall(t.func)
                    if not ok then
                        -- surface error without breaking the timer loop
                        geterrorhandler()(err)
                    end
                    if t.interval and (t.count == nil or t.count > 1) then
                        -- repeating ticker
                        t.expiry = now + t.interval
                        if t.count then t.count = t.count - 1 end
                        anyActive = true
                    else
                        table.remove(_pending, i)
                    end
                else
                    anyActive = true
                end
            else
                table.remove(_pending, i)
            end
        end
        if not anyActive then
            _timerFrame:SetScript("OnUpdate", nil)
            _frameRunning = false
        end
    end

    local function _ensureRunning()
        if not _frameRunning then
            _frameRunning = true
            _timerFrame:SetScript("OnUpdate", _tick)
        end
    end

    -- Ticker handle returned by NewTicker so callers can Cancel() it
    local Ticker = {}
    Ticker.__index = Ticker
    function Ticker:Cancel() self._t.cancelled = true end
    function Ticker:IsCancelled() return self._t.cancelled end

    C_Timer = {
        After = function(delay, func)
            -- SuperWoW/OctoWoW: schedule a one-shot callback after `delay` seconds
            if type(delay) ~= "number" or type(func) ~= "function" then return end
            local entry = {expiry = GetTime() + delay, func = func}
            table.insert(_pending, entry)
            _ensureRunning()
        end,

        NewTicker = function(interval, func, iterations)
            -- SuperWoW/OctoWoW: repeating ticker, optional iteration limit
            if type(interval) ~= "number" or type(func) ~= "function" then return end
            local entry = {
                expiry   = GetTime() + interval,
                func     = func,
                interval = interval,
                count    = iterations,
            }
            table.insert(_pending, entry)
            _ensureRunning()
            return setmetatable({_t = entry}, Ticker)
        end,

        NewTimer = function(delay, func)
            -- Alias used by some Ace3 code paths
            return C_Timer.After(delay, func)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- C_QuestLog  (1.12 wrapper)
-- ---------------------------------------------------------------------------
-- QuestLog.lua accesses C_QuestLog at file scope without a nil-guard:
--   local GetNumQuests = C_QuestLog.GetNumQuestLogEntries or ...
-- We provide a table with forwarding functions to the classic 1.12 quest API.

if not C_QuestLog then
    C_QuestLog = {}
end

-- GetNumQuestLogEntries: directly available in 1.12 as a global
if not C_QuestLog.GetNumQuestLogEntries then
    C_QuestLog.GetNumQuestLogEntries = _G.GetNumQuestLogEntries
end

-- GetInfo: wraps GetQuestLogTitle (1.12) to return a table in modern format
if not C_QuestLog.GetInfo then
    C_QuestLog.GetInfo = function(index)
        -- 1.12: GetQuestLogTitle(i) → title, level, tag, isHeader, isCollapsed, isComplete
        local title, level, _, isHeader, _, isComplete, _, questID =
            GetQuestLogTitle(index)
        if not title then return nil end
        return {
            title      = title,
            level      = level or 0,
            isHeader   = isHeader,
            isComplete = isComplete == 1 or isComplete == true,
            questID    = questID or 0,
        }
    end
end

-- GetAllCompletedQuestIDs: maps to GetQuestsCompleted in 1.12
if not C_QuestLog.GetAllCompletedQuestIDs then
    C_QuestLog.GetAllCompletedQuestIDs = _G.GetQuestsCompleted
end

-- IsQuestFlaggedCompleted: not directly available in 1.12; scan quest log
if not C_QuestLog.IsQuestFlaggedCompleted then
    C_QuestLog.IsQuestFlaggedCompleted = function(questID)
        if not questID or questID == 0 then return false end
        local completed = _G.GetQuestsCompleted and _G.GetQuestsCompleted()
        return completed and completed[questID] or false
    end
end

-- IsQuestFlaggedCompletedOnAccount: not in 1.12, forward to character check
if not C_QuestLog.IsQuestFlaggedCompletedOnAccount then
    C_QuestLog.IsQuestFlaggedCompletedOnAccount =
        C_QuestLog.IsQuestFlaggedCompleted
end

-- IsOnQuest: scan the quest log for the given questID
if not C_QuestLog.IsOnQuest then
    C_QuestLog.IsOnQuest = function(questID)
        if not questID or questID == 0 then return false end
        local num = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
        for i = 1, num do
            local _, _, _, _, _, _, _, qid = GetQuestLogTitle(i)
            if qid == questID then return true end
        end
        return false
    end
end

-- GetLogIndexForQuestID: scan log for matching questID index
if not C_QuestLog.GetLogIndexForQuestID then
    C_QuestLog.GetLogIndexForQuestID = function(questID)
        if not questID or questID == 0 then return nil end
        local num = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
        for i = 1, num do
            local _, _, _, _, _, _, _, qid = GetQuestLogTitle(i)
            if qid == questID then return i end
        end
        return nil
    end
end

-- IsComplete: use the 6th return of GetQuestLogTitle
if not C_QuestLog.IsComplete then
    C_QuestLog.IsComplete = function(questID)
        local idx = C_QuestLog.GetLogIndexForQuestID(questID)
        if not idx then return false end
        local _, _, _, _, _, isComplete = GetQuestLogTitle(idx)
        return isComplete == 1
    end
end

-- IsPushableQuest: forward to global if available
if not C_QuestLog.IsPushableQuest then
    C_QuestLog.IsPushableQuest = _G.IsPushableQuest or function() return false end
end

-- SetAbandonQuest / AbandonQuest / SetSelectedQuest: forward to globals
if not C_QuestLog.SetAbandonQuest then
    C_QuestLog.SetAbandonQuest = _G.SetAbandonQuest or function() end
end
if not C_QuestLog.AbandonQuest then
    C_QuestLog.AbandonQuest = _G.AbandonQuest or function() end
end
if not C_QuestLog.SetSelectedQuest then
    -- 1.12 uses SelectQuestLogEntry(index), not questID
    C_QuestLog.SetSelectedQuest = _G.SelectQuestLogEntry or function() end
end

-- RequestLoadQuestByID / GetQuestObjectives / GetTitleForQuestID / GetQuestInfo:
-- Not available in 1.12 — provide stubs so guarded callsites short-circuit.
-- RXPGuides guards C_QuestLog.RequestLoadQuestByID with an explicit nil check,
-- so leaving it absent (nil) is intentional.
if not C_QuestLog.GetQuestObjectives then
    C_QuestLog.GetQuestObjectives = function() return nil end
end
if not C_QuestLog.GetTitleForQuestID then
    C_QuestLog.GetTitleForQuestID = function() return nil end
end
if not C_QuestLog.GetQuestInfo then
    C_QuestLog.GetQuestInfo = function() return nil end
end

-- ---------------------------------------------------------------------------
-- C_Spell  (1.12 wrapper)
-- ---------------------------------------------------------------------------
-- Several files do:  local X = C_Spell and C_Spell.Y or _G.Y
-- On 1.12, C_Spell is nil, so those fallbacks work.  However if the global
-- C_SpellBook is also missing we patch that too.

if not C_Spell then
    C_Spell = {
        GetSpellInfo        = _G.GetSpellInfo,
        GetSpellTexture     = _G.GetSpellTexture,
        GetSpellSubtext     = _G.GetSpellSubtext,
        IsCurrentSpell      = _G.IsCurrentSpell,
        IsSpellKnown        = _G.IsSpellKnown,
        IsPlayerSpell       = _G.IsPlayerSpell,
        -- GetSpellCooldown in 1.12 returns start, duration, enabled (not a table)
        GetSpellCooldown    = function(id)
            local s, d, e = GetSpellCooldown(id)
            return {startTime = s, duration = d, isEnabled = e ~= 0}
        end,
        -- Data-cache helpers not present in 1.12 — stubs prevent nil errors
        IsSpellDataCached   = function() return true end,
        RequestLoadSpellData= function() end,
    }
end

if not C_SpellBook then
    C_SpellBook = {
        IsSpellKnown = _G.IsSpellKnown or function() return false end,
    }
end

-- ---------------------------------------------------------------------------
-- C_AddOns  (1.12 wrapper)
-- ---------------------------------------------------------------------------
if not C_AddOns then
    C_AddOns = {
        GetAddOnMetadata    = _G.GetAddOnMetadata,
        IsAddOnLoadOnDemand = _G.IsAddOnLoadOnDemand,
        LoadAddOn           = _G.LoadAddOn,
        IsAddOnLoaded       = _G.IsAddOnLoaded,
    }
end

-- ---------------------------------------------------------------------------
-- C_Seasons / C_GameRules  (no seasons or HC mode in 1.12)
-- ---------------------------------------------------------------------------
if not C_Seasons then
    C_Seasons = {
        HasActiveSeason = function() return false end,
        GetActiveSeason = function() return 0 end,
    }
end

if not C_GameRules then
    C_GameRules = {
        IsHardcoreActive = function() return false end,
    }
end

-- ---------------------------------------------------------------------------
-- C_Map / C_TaxiMap  (1.12 map system does not use these namespaces)
-- ---------------------------------------------------------------------------
-- Timers.lua uses C_Map.GetBestMapForUnit and C_TaxiMap.GetAllTaxiNodes.
-- functions.lua uses C_Map.CanSetUserWaypointOnMap, C_Map.SetUserWaypoint, etc.
-- On 1.12 these aren't available; returning safe values prevents hard errors.
-- We use a metatable so any missing method returns a no-op function rather
-- than nil (which would cause "attempt to call a nil value" errors).

local function _noopStub() return nil end
local function _safeNamespace(t)
    return setmetatable(t or {}, {__index = function() return _noopStub end})
end

if not C_Map then
    C_Map = _safeNamespace({
        GetBestMapForUnit                = function() return nil end,
        CanSetUserWaypointOnMap          = function() return false end,
        SetUserWaypoint                  = _noopStub,
        GetUserWaypointPositionForMap    = function() return nil end,
        ClearUserWaypoint                = _noopStub,
        GetMapInfo                       = function() return nil end,
        GetPlayerMapPosition             = function() return nil end,
    })
end

if not C_TaxiMap then
    C_TaxiMap = _safeNamespace({
        GetAllTaxiNodes = function() return {} end,
    })
end

-- C_SuperTrack: used for waypoint quest tracking on modern clients
if not C_SuperTrack then
    C_SuperTrack = _safeNamespace()
end

-- ---------------------------------------------------------------------------
-- Enum.FlightPathState  (used in Timers.lua)
-- ---------------------------------------------------------------------------
if not Enum then
    Enum = {}
end
if not Enum.FlightPathState then
    Enum.FlightPathState = {
        Unreachable = 0,
        Reachable   = 1,
        Current     = 2,
    }
end

-- ---------------------------------------------------------------------------
-- GameTooltip.IsForbidden  (not present in 1.12)
-- ---------------------------------------------------------------------------
-- Several UI files call :IsForbidden() on frames/tooltips.  In 1.12 this
-- method doesn't exist; we add a default returning false so guards work.
if _G.GameTooltip and not _G.GameTooltip.IsForbidden then
    _G.GameTooltip.IsForbidden = function() return false end
end

-- ---------------------------------------------------------------------------
-- hooksecurefunc  (SuperWoW supports this; no-op fallback just in case)
-- ---------------------------------------------------------------------------
if not _G.hooksecurefunc then
    _G.hooksecurefunc = function(tbl, name, hook)
        -- If two-argument form: hooksecurefunc("funcname", hook)
        if type(tbl) == "string" then
            hook = name
            name = tbl
            tbl  = _G
        end
        local orig = tbl[name]
        if type(orig) == "function" then
            tbl[name] = function(...) orig(...); hook(...) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- table.wipe  (not in Lua 5.0 / 1.12 standard library)
-- ---------------------------------------------------------------------------
if not table.wipe then
    table.wipe = function(t)
        for k in pairs(t) do t[k] = nil end
        return t
    end
end

-- ---------------------------------------------------------------------------
-- string.format %q safety (no-op; standard in all Lua versions)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- C_GossipInfo  (1.12 wrapper)
-- ---------------------------------------------------------------------------
-- RXPGuides.lua accesses C_GossipInfo.* at file scope; we wrap the classic
-- global gossip functions so the `or _G.GetNum...` fallbacks still apply.

if not C_GossipInfo then
    C_GossipInfo = {
        GetNumActiveQuests    = _G.GetNumGossipActiveQuests,
        GetNumAvailableQuests = _G.GetNumGossipAvailableQuests,
        SelectAvailableQuest  = _G.SelectGossipAvailableQuest,
        GetActiveQuests       = _G.GetGossipActiveQuests,
        SelectActiveQuest     = _G.SelectGossipActiveQuest,
        GetAvailableQuests    = _G.GetGossipAvailableQuests,
        GetOptions            = _G.GetGossipOptions,
    }
end

-- ---------------------------------------------------------------------------
-- C_NamePlate  (not in 1.12)
-- ---------------------------------------------------------------------------
-- Targeting.lua does: local GetNamePlates = C_NamePlate.GetNamePlates
-- On 1.12 there is no C_NamePlate namespace; return an empty-table stub.

if not C_NamePlate then
    C_NamePlate = {
        GetNamePlates = function() return {} end,
    }
end

-- ---------------------------------------------------------------------------
-- C_ActionBar  (not in 1.12)
-- ---------------------------------------------------------------------------
-- Tips.lua does: local IsOnBarOrSpecialBar = C_ActionBar.IsOnBarOrSpecialBar
-- This function does not exist in 1.12; return a no-op stub.

if not C_ActionBar then
    C_ActionBar = {
        IsOnBarOrSpecialBar = function() return false end,
    }
end

-- ---------------------------------------------------------------------------
-- C_Container  (1.12 wrapper)
-- ---------------------------------------------------------------------------
-- Several files guard with `C_Container and C_Container.X or _G.X`, but
-- having a C_Container table prevents nil errors on partial accesses.

if not C_Container then
    C_Container = {
        PickupContainerItem      = _G.PickupContainerItem,
        GetContainerNumFreeSlots = _G.GetContainerNumFreeSlots,
        GetContainerNumSlots     = _G.GetContainerNumSlots,
        GetContainerItemID       = _G.GetContainerItemID,
        GetContainerItemInfo     = _G.GetContainerItemInfo,
    }
end

-- ---------------------------------------------------------------------------
-- C_Item  (1.12 wrapper)
-- ---------------------------------------------------------------------------
if not C_Item then
    C_Item = {
        GetItemInfo = _G.GetItemInfo,
    }
end
