-- ============================================================================
-- CustomWaypoints - Phase 5B (patched UI + safer deep fallback)
--
-- PURPOSE
--   This addon extends Carbonite with:
--   - custom waypoint capture from the displayed Carbonite map
--   - a waypoint queue
--   - route sync into Carbonite
--   - a prototype intercontinental routing layer
--   - auto-advance when the player reaches the current waypoint
--
-- IMPORTANT ARCHITECTURAL NOTE
--   Carbonite remains the rendering / map / HUD / travel-guidance layer.
--   This addon adds a custom capture / queue / sync layer and, when needed,
--   builds explicit intermediate route nodes to feed into Carbonite.
--
-- NOTES ABOUT THIS PATCH
--   - safer /cw UI with visible background and extra toggle buttons
--   - UI is created lazily (only when opened) to reduce Carbonite-side UI risk
--   - deep mode keeps current behavior, but cross-continent graph no-path now
--     falls back to an explicit direct destination target instead of failing
--     the whole rebuild
--   - simplified routing still does not use flight masters
-- ============================================================================

local tinsert = table.insert
local tremove = table.remove
local wipe = wipe
local format = string.format
local gsub = string.gsub
local sqrt = math.sqrt
local huge = math.huge
local lower = string.lower
local match = string.match
local band = bit.band
local ShowWaypointMetadataPopup
local ShowKnownLocationEditorPopup
local SaveQueueAsKnownRoute
local AddLabeledCurrentCursorWaypoint
local AddCurrentLocationWaypoint
local AddCurrentLocationWithMetadataPopup
local EnsureCarboniteMapButtons
local routeSelectedBtn

CustomWaypoints = CustomWaypoints or {}
local CW = CustomWaypoints

local TARGET_TYPE_GOTO = "Goto"
local TARGET_TYPE_STRAIGHT = "CW_STRAIGHT"

local STRAIGHT_EDGE_TYPES = {
    boat = true,
    zeppelin = true,
    tram = true,
    portal = true,
    transport = true,
    taxi = true,
}

local TRANSIT_EDGE_TYPES = {
    boat = true,
    zeppelin = true,
    tram = true,
    portal = true,
    taxi = true,
}

BINDING_HEADER_CUSTOMWAYPOINTS = "CustomWaypoints"
BINDING_NAME_CW_TOGGLE_KNOWN_LOCATIONS = "Toggle Known Locations"
BINDING_NAME_CW_SAVE_HERE = "Save Here"

local DEFAULTS = {
    destinations = {},
    bindingModifier = "SHIFT",
    bindingButton = "LeftButton",
    fallbackModifier = "CTRL",
    fallbackButton = "RightButton",
    reachDistanceYards = 10,
    debug = false,
    autoSyncToCarbonite = true,
    autoAdvance = true,
    walkYardsPerSecond = 7,
    useIntercontinentalRouting = true,
    useFlightMasters = true,
    hasFlyingMount = false,
    simplifyTransitWaypoints = true,
    showUi = true,
    uiScale = 1,
    transportDiscoveryEnabled = true,
    transportLogEnabled = false,
    transportConfirmationEnabled = true,
    learnedTransports = {},
    knownLocations = {},

    -- table to override routing tuning parameters per profile; when a field is missing
    -- the value from ROUTING_TUNING_DEFAULTS below will be used.
    routingTuning = {},
}

local ROUTING_TUNING_DEFAULTS = {
    -- Preference bonuses (higher = more preferred)
    learnedPortalBonus = 10,
    portalBonus = 10,
    tramBonus = 80,
    boatBonus = 35,
    zeppelinBonus = 35,
    taxiBonus = 70,
    -- Maximum post-portal walk distance without switching to taxi
    maxPostPortalWalkWithoutTaxi = 700,
}

-- Merge routing tuning overrides from the saved profile with the defaults.
-- Returns a table containing all tuning parameters, ensuring that missing
-- entries in STATE.db.routingTuning fall back to the defaults. This
-- function is used throughout the routing logic to read tunable
-- parameters.
local STATE
local EnsureDb

local function IsAutoDiscoveryEnabled()
    return STATE.db and STATE.db.transportDiscoveryEnabled == true
end

local function ClearPendingTransport()
    STATE.pendingTransport = nil
    STATE.pendingTransportKey = nil
end

local function RefreshUiHeader()
    local db = STATE.db or {}
    if STATE.ui and STATE.ui.header then
        STATE.ui.header:SetText("CW options")
        if STATE.ui.legend then
            STATE.ui.legend:Hide()
        end
        if STATE.ui.checks then
            if STATE.ui.checks.flying and STATE.ui.checks.flying.SetChecked then STATE.ui.checks.flying:SetChecked(not db.hasFlyingMount and true or false) end
            if STATE.ui.checks.autosync and STATE.ui.checks.autosync.SetChecked then STATE.ui.checks.autosync:SetChecked(db.autoSyncToCarbonite and true or false) end
            if STATE.ui.checks.autoadvance and STATE.ui.checks.autoadvance.SetChecked then STATE.ui.checks.autoadvance:SetChecked(db.autoAdvance and true or false) end
            if STATE.ui.checks.flightmasters and STATE.ui.checks.flightmasters.SetChecked then STATE.ui.checks.flightmasters:SetChecked(db.useFlightMasters and true or false) end
            if STATE.ui.checks.deep and STATE.ui.checks.deep.SetChecked then STATE.ui.checks.deep:SetChecked((not db.simplifyTransitWaypoints) and true or false) end
            if STATE.ui.checks.debug and STATE.ui.checks.debug.SetChecked then STATE.ui.checks.debug:SetChecked(db.debug and true or false) end
            if STATE.interfaceChecks.debug and STATE.interfaceChecks.debug.SetChecked then STATE.interfaceChecks.debug:SetChecked(db.debug and true or false) end
            if STATE.ui.checks.autodiscovery and STATE.ui.checks.autodiscovery.SetChecked then
                STATE.ui.checks.autodiscovery:SetChecked(IsAutoDiscoveryEnabled())
            end
            if STATE.ui.checks.transportconfirmation and STATE.ui.checks.transportconfirmation.SetChecked then STATE.ui.checks.transportconfirmation:SetChecked(db.transportConfirmationEnabled and true or false) end
        end
    end
    if STATE.interfaceChecks then
        if STATE.interfaceChecks.autosync and STATE.interfaceChecks.autosync.SetChecked then STATE.interfaceChecks.autosync:SetChecked(db.autoSyncToCarbonite and true or false) end
        if STATE.interfaceChecks.autoadvance and STATE.interfaceChecks.autoadvance.SetChecked then STATE.interfaceChecks.autoadvance:SetChecked(db.autoAdvance and true or false) end
        if STATE.interfaceChecks.flying and STATE.interfaceChecks.flying.SetChecked then STATE.interfaceChecks.flying:SetChecked(not db.hasFlyingMount and true or false) end
        if STATE.interfaceChecks.flightmasters and STATE.interfaceChecks.flightmasters.SetChecked then STATE.interfaceChecks.flightmasters:SetChecked(db.useFlightMasters and true or false) end
        if STATE.interfaceChecks.deep and STATE.interfaceChecks.deep.SetChecked then STATE.interfaceChecks.deep:SetChecked((not db.simplifyTransitWaypoints) and true or false) end
        if STATE.interfaceChecks.debug and STATE.interfaceChecks.debug.SetChecked then STATE.interfaceChecks.debug:SetChecked(db.debug and true or false) end
        if STATE.interfaceChecks.portaldiscovery and STATE.interfaceChecks.portaldiscovery.SetChecked then STATE.interfaceChecks.portaldiscovery:SetChecked(db.transportDiscoveryEnabled and true or false) end
        if STATE.interfaceChecks.transportconfirmation and STATE.interfaceChecks.transportconfirmation.SetChecked then STATE.interfaceChecks.transportconfirmation:SetChecked(db.transportConfirmationEnabled and true or false) end
        if STATE.interfaceChecks.autorouteinstanceondeath and STATE.interfaceChecks.autorouteinstanceondeath.SetChecked then STATE.interfaceChecks.autorouteinstanceondeath:SetChecked(db.autoRouteSavedInstanceOnDeath and true or false) end
    end
end

-- Grow log EditBox with content; optionally scroll frame to bottom and move caret to end (addon log lines).
local function ResizeLogOutputEditor(scrollToEnd)
    local ui = STATE.ui
    if not ui or not ui.output or not ui.scroll then return end
    local edit, scroll = ui.output, ui.scroll
    local text = edit:GetText() or ""
    local _, fh = edit:GetFont()
    if not fh or fh < 8 then fh = 14 end
    local _, n = string.gsub(text, "\n", "\n")
    local lines = n + 1
    local viewH = scroll:GetHeight() or 200
    local minH = math.max(viewH, lines * fh + fh * 2)
    edit:SetHeight(minH)
    if scroll.UpdateScrollChildRect then
        pcall(function() scroll:UpdateScrollChildRect() end)
    end
    if scrollToEnd and scroll.GetVerticalScrollRange and scroll.SetVerticalScroll then
        local ok, range = pcall(function() return scroll:GetVerticalScrollRange() end)
        if ok and type(range) == "number" and range >= 0 then
            pcall(function() scroll:SetVerticalScroll(range) end)
        end
        local len = string.len(text)
        if edit.SetCursorPosition then
            pcall(function() edit:SetCursorPosition(len) end)
        end
    end
end

local function AppendUiLogLine(line)
    if STATE.outputRecursing then return end
    local log = STATE.uiLog
    log[#log + 1] = tostring(line)
    local maxLines = STATE.maxUiLog or 400
    while #log > maxLines do
        tremove(log, 1)
    end

    if STATE.ui and STATE.ui.output then
        STATE.outputRecursing = true
        STATE.ui.output:SetText(table.concat(log, "\n"))
        ResizeLogOutputEditor(true)
        STATE.outputRecursing = false
    end
end

local function pr(msg)
    local line = "CWPhase5B: " .. tostring(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff80ff80CWPhase5B:|r " .. tostring(msg))
    AppendUiLogLine(line)
end

local function SetAutoDiscoveryEnabled(enabled, quiet)
    EnsureDb()
    enabled = enabled and true or false
    STATE.db.transportDiscoveryEnabled = enabled

    if not enabled then
        STATE.pendingConfirmationTransport = nil
        STATE.activeConfirmationKey = nil
        if STATE.confirmationFrame and STATE.confirmationFrame.Hide and STATE.confirmationFrame:IsShown() then
            STATE.confirmationFrame:Hide()
        end
        ClearPendingTransport()
    end

    RefreshUiHeader()

    if not quiet then
        pr("autodiscovery=" .. tostring(enabled))
    end
end

local function ToggleAutoDiscovery()
    SetAutoDiscoveryEnabled(not IsAutoDiscoveryEnabled())
end

local function GetRoutingTuning()
    local out = {}
    local overrides = (STATE.db and STATE.db.routingTuning) or {}
    for k, v in pairs(ROUTING_TUNING_DEFAULTS) do
        if overrides[k] ~= nil then
            out[k] = overrides[k]
        else
            out[k] = v
        end
    end
    return out
end

local function TuningBonusToSeconds(bonus, scale, maxReduction)
    bonus = tonumber(bonus) or 0
    if bonus < 0 then bonus = 0 end
    local reduction = bonus * (scale or 0)
    if maxReduction and reduction > maxReduction then
        reduction = maxReduction
    end
    return reduction
end

local function GetTransportPreferenceReductionSeconds(transportType, learnedHop)
    local tuning = GetRoutingTuning()

    if learnedHop then
        -- Learned portals are still portal paths: when portal bonus is zero,
        -- do not keep hidden learned-portal preference active.
        if (tuning.portalBonus or 0) <= 0 then
            return 0
        end
        return TuningBonusToSeconds(tuning.learnedPortalBonus, 0.15, 18)
    end

    if transportType == "portal" then
        return TuningBonusToSeconds(tuning.portalBonus, 0.15, 18)
    elseif transportType == "tram" then
        return TuningBonusToSeconds(tuning.tramBonus, 0.12, 16)
    elseif transportType == "boat" then
        return TuningBonusToSeconds(tuning.boatBonus, 0.10, 14)
    elseif transportType == "zeppelin" then
        return TuningBonusToSeconds(tuning.zeppelinBonus, 0.10, 14)
    elseif transportType == "taxi" then
        return TuningBonusToSeconds(tuning.taxiBonus, 0.12, 18)
    end

    return 0
end

-- Minimal-mode invariant:
-- keep Carbonite-led behavior by collapsing any non-transport chain into a
-- single direct walk anchor (to transport entry or to final destination).
local function CollapseMinimalTransitNoise(points)
    if type(points) ~= "table" or #points <= 2 then
        return points
    end

    local out = { points[1] }
    local runLast = nil

    local function ClonePoint(pt)
        local copy = {}
        for k, v in pairs(pt or {}) do copy[k] = v end
        return copy
    end

    for i = 2, #points do
        local pt = points[i]
        local isTransport = pt and pt.edgeType and STRAIGHT_EDGE_TYPES[pt.edgeType]
        if isTransport then
            if runLast then
                local walkAnchor = ClonePoint(runLast)
                walkAnchor.edgeType = "walk-to-transport"
                walkAnchor.label = "walk-to-transport"
                out[#out + 1] = walkAnchor
                runLast = nil
            end
            out[#out + 1] = pt
        else
            runLast = pt
        end
    end

    if runLast then
        local goalAnchor = ClonePoint(runLast)
        goalAnchor.edgeType = "node-to-goal"
        goalAnchor.label = "node-to-goal"
        out[#out + 1] = goalAnchor
    end

    return out
end

local function GetAttachCandidateScoreSeconds(rawWalkSeconds, candidate, isStart, isGoal)
    local tuning = GetRoutingTuning()
    local score = tonumber(rawWalkSeconds) or huge

    if isStart and candidate.learnedS then
        score = score - TuningBonusToSeconds(tuning.learnedPortalBonus, 0.12, 14)
    end
    if isGoal and candidate.learnedD then
        score = score - TuningBonusToSeconds(tuning.learnedPortalBonus, 0.12, 14)
    end
    if (candidate.portalEdges or 0) > 0 then
        score = score - TuningBonusToSeconds(tuning.portalBonus, 0.08, 10)
    end
    if candidate.taxiHub or (candidate.taxiEdges or 0) > 0 then
        score = score - TuningBonusToSeconds(tuning.taxiBonus, 0.10, 12)
    end

    if score < 1 then score = 1 end
    return score
end

STATE = {
    db = nil,
    frame = nil,
    hookInstalled = false,
    clearHookInstalled = false,
    lastPulse = 0,
    syncing = false,
    graph = nil,
    expandedRoute = nil,
    suppressClearUntil = 0,
    travelHookInstalled = false,
    originalTravelMap = nil,
    history = {},
    future = {},
    ui = nil,
    uiLog = {},
    maxUiLog = 400,
    outputRecursing = false,
    sclGuardInstalled = false,
    originalSCL = nil,
    bindingsInstalled = false,
    interfacePanel = nil,
    interfaceChecks = nil,
    uiSpecialRegistered = false,
    needLoginQueueSync = false,
    -- Skip auto-advance for a few seconds after capture so nearby clicks / bad coords don't instantly pop.
    lastCaptureTime = 0,
    lastStablePlayerPos = nil,
    pendingTransport = nil,
    lastTransportScan = 0,
    confirmationFrame = nil,
    pendingConfirmationTransport = nil,
    transportManagementFrame = nil,
    knownLocationsSpecialRegistered = false,
    dismissedConfirmation = nil,
    recentConfirmation = nil,
    activeConfirmationKey = nil,
    pendingTransportKey = nil,
    cwModalStack = {},
    pendingDeathAutoRoute = nil,
    lastDeathAutoRouteKey = nil,
}

local InvalidateRoute
local ClearCarboniteTargets
local SyncQueueToCarbonite
local SlashHandler
local InstallCarboniteSclGuard
local EnsureInterfaceOptionsPanel
local EnsureRoutingTuningUi
local RefreshRoutingTuningUi
local ShowKnownLocationsFrame
local RefreshKnownLocationsFrame
local RouteToKnownLocation
local SelectKnownLocation
local ShowKnownLocationImportPopup
local ExportKnownLocations
local ImportKnownLocationsFromText
local EnsureKnownLocationsBinding
local EnsureSaveHereBinding
local InstallUndoRedoBindings

-- Lua 5.1: closures in InstallUndoRedoBindings must capture these locals, not a later global.
local UndoHistory, RedoHistory
-- EnsureUi Import button closes over this local (WoW Lua resolves nested refs like globals otherwise).
local ImportWaypointsFromText
local SplitLines
local NormalizeImportLine
local ParseExportLine
local SplitExportFields

-- Lexical: must be above InstallUndoRedoBindings if that helper ever calls GetMap at install time.
local function GetMap()
    if not Nx or not Nx.Map or not Nx.Map.GeM then return nil end
    return Nx.Map:GeM(1)
end

local EDGE_COLORS = {
    walk = "|cffffffff",
    connector = "|cffc0c0c0",
    walklink = "|cffc0c0c0",
    boat = "|cff66ccff",
    zeppelin = "|cffff9933",
    tram = "|cffcc66ff",
    portal = "|cff66ffcc",
    transport = "|cffffff66",
    taxi = "|cffffdd55",
    flying = "|cff88ff88",
}

local function EscapeForDisplay(text)
    return tostring(text or ""):gsub("|", "||")
end

local function UnescapeFromDisplay(text)
    return tostring(text or ""):gsub("||", "|")
end

local function NormalizeKnownInstanceName(pt)
    local name = tostring(
        (pt and (pt.zoneText or pt.subZoneText or pt.mapName))
        or ("Instance " .. tostring(pt and pt.maI or "?"))
    )
    return lower(name)
end

function BuildTransportConfirmationKey(fromPos, toPos)
    if not fromPos or not toPos then return nil end

    if toPos.instance then
        return table.concat({
            "instance",
            tostring(toPos.maI or "?"),
            NormalizeKnownInstanceName(toPos),
            tostring(toPos.instanceType or "instance"),
        }, "|")
    end

    return table.concat({
        "transport",
        tostring(fromPos.maI or "?"),
        tostring(toPos.maI or "?"),
        tostring(math.floor((fromPos.wx or 0) * 10 + 0.5)),
        tostring(math.floor((fromPos.wy or 0) * 10 + 0.5)),
        tostring(math.floor((toPos.wx or 0) * 10 + 0.5)),
        tostring(math.floor((toPos.wy or 0) * 10 + 0.5)),
    }, "|")
end

function IsConfirmationDismissed(fromPos, toPos)
    local d = STATE.dismissedConfirmation
    if not d or not d.key then return false end
    local now = GetTime and GetTime() or 0
    if now > (d.untilTime or 0) then
        STATE.dismissedConfirmation = nil
        return false
    end
    return d.key == BuildTransportConfirmationKey(fromPos, toPos)
end

function DismissConfirmationCandidate(fromPos, toPos, seconds)
    STATE.dismissedConfirmation = {
        key = BuildTransportConfirmationKey(fromPos, toPos),
        untilTime = (GetTime and GetTime() or 0) + (seconds or 8),
    }
end

local function MarkConfirmationRecentlyHandled(fromPos, toPos, seconds)
    STATE.recentConfirmation = {
        key = BuildTransportConfirmationKey(fromPos, toPos),
        untilTime = (GetTime and GetTime() or 0) + (seconds or 10),
    }
end

local function WasConfirmationRecentlyHandled(fromPos, toPos)
    local r = STATE.recentConfirmation
    if not r or not r.key then return false end
    local now = GetTime and GetTime() or 0
    if now > (r.untilTime or 0) then
        STATE.recentConfirmation = nil
        return false
    end
    return r.key == BuildTransportConfirmationKey(fromPos, toPos)
end


local CW_ESC_OVERRIDE_BUTTON_NAME = "CustomWaypointsEscOverrideButton"

local EnsureCwEscOverrideButton
local RefreshCwEscOverride
local HideTopCwModalFrame

RefreshCwEscOverride = function()
    local owner = STATE.frame or UIParent
    local stack = STATE.cwModalStack or {}
    local hasShown = false

    for i = #stack, 1, -1 do
        local f = stack[i]
        if f and f.IsShown and f:IsShown() then
            hasShown = true
            break
        end
    end

    if ClearOverrideBindings then
        ClearOverrideBindings(owner)
    end

    -- During combat, let WoW handle ESC normally (game menu / default close chain).
    if InCombatLockdown and InCombatLockdown() then
        return
    end

    if hasShown and SetOverrideBindingClick then
        EnsureCwEscOverrideButton()
        SetOverrideBindingClick(owner, true, "ESCAPE", CW_ESC_OVERRIDE_BUTTON_NAME, "LeftButton")
    end
end

HideTopCwModalFrame = function()
    local stack = STATE.cwModalStack or {}
    for i = #stack, 1, -1 do
        local f = stack[i]
        if f and f.IsShown and f:IsShown() then
            f:Hide()
            RefreshCwEscOverride()
            return true
        end
    end
    RefreshCwEscOverride()
    return false
end

EnsureCwEscOverrideButton = function()
    local btn = _G[CW_ESC_OVERRIDE_BUTTON_NAME]
    if btn then return btn end

    btn = CreateFrame("Button", CW_ESC_OVERRIDE_BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
    btn:SetWidth(1)
    btn:SetHeight(1)
    btn:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
    btn:Hide()
    btn:SetScript("OnClick", function()
        HideTopCwModalFrame()
    end)

    return btn
end

local function PushCwModalFrame(frame)
    if not frame then return end
    STATE.cwModalStack = STATE.cwModalStack or {}
    for i = #STATE.cwModalStack, 1, -1 do
        if STATE.cwModalStack[i] == frame then
            table.remove(STATE.cwModalStack, i)
        end
    end
    STATE.cwModalStack[#STATE.cwModalStack + 1] = frame
    RefreshCwEscOverride()
end

local function RemoveCwModalFrame(frame)
    if not frame or not STATE.cwModalStack then return end
    for i = #STATE.cwModalStack, 1, -1 do
        if STATE.cwModalStack[i] == frame then
            table.remove(STATE.cwModalStack, i)
            break
        end
    end
    RefreshCwEscOverride()
end

local function ArmKeyboardModalFrame(frame)
    if not frame then return end
    PushCwModalFrame(frame)
    -- Keep CW windows on the modal stack without forcing frame-level keyboard capture.
    -- On WoW 3.3.5a, EnableKeyboard(true) on parent frames can steal movement keys
    -- even when no edit box is focused, so ESC close falls back to UISpecialFrames.
    if frame.EnableKeyboard then
        pcall(function() frame:EnableKeyboard(false) end)
    end
    if frame.SetPropagateKeyboardInput then
        pcall(function() frame:SetPropagateKeyboardInput(true) end)
    end
end

local function ColorizeEdgeName(edgeType, textLabel)
    local color = EDGE_COLORS[edgeType or ""] or "|cffdddddd"
    return color .. tostring(textLabel or edgeType or "route") .. "|r"
end

local function BuildLegendText()
    return ""
end

local function ApplyRoutingTuningChange(key, value, skipUiRefresh, skipSync)
    EnsureDb()
    if not key then return end
    STATE.db.routingTuning = STATE.db.routingTuning or {}
    local defaultValue = ROUTING_TUNING_DEFAULTS[key]
    if defaultValue == nil then return end

    value = tonumber(value) or defaultValue
    if value < 0 then value = 0 end
    value = math.floor(value + 0.5)

    if value == defaultValue then
        STATE.db.routingTuning[key] = nil
    else
        STATE.db.routingTuning[key] = value
    end

    InvalidateRoute('routing tuning: ' .. tostring(key))
    RefreshUiHeader()
    if not skipUiRefresh then
        RefreshRoutingTuningUi()
    end
    if STATE.db.autoSyncToCarbonite and not skipSync then
        SyncQueueToCarbonite()
    end
end

RefreshRoutingTuningUi = function()
    if not STATE.tuningUi or not STATE.tuningUi.frame then return end
    local ui = STATE.tuningUi
    local tuning = GetRoutingTuning()
    ui.updating = true
    for _, item in ipairs(ui.sliders or {}) do
        local value = tuning[item.key]
        if item.slider and item.slider.SetValue and value ~= nil then
            item.slider:SetValue(value)
        end
        if item.valueText and item.valueText.SetText then
            local total = item.max or ''
            item.valueText:SetText(tostring(value or '') .. "/" .. tostring(total))
        end
        if item.reset and item.reset.Enable then
            if value == ROUTING_TUNING_DEFAULTS[item.key] then
                item.reset:Disable()
            else
                item.reset:Enable()
            end
        end
    end
    ui.updating = false
end

EnsureRoutingTuningUi = function()
    if STATE.tuningUi and STATE.tuningUi.frame then
        RefreshRoutingTuningUi()
        return STATE.tuningUi
    end

    local pendingValues = {}
    local function FlushPendingRoutingTuningChanges()
        if not STATE.tuningUi or STATE.tuningUi.applyingPending then return end
        STATE.tuningUi.applyingPending = true

        local changedAny = false
        for key, pendingValue in pairs(pendingValues) do
            local before = GetRoutingTuning()[key]
            ApplyRoutingTuningChange(key, pendingValue, true, true)
            local after = GetRoutingTuning()[key]
            if before ~= after then
                changedAny = true
            end
            pendingValues[key] = nil
        end

        if changedAny then
            InvalidateRoute('routing tuning deferred flush')
            RefreshUiHeader()
            RefreshRoutingTuningUi()
            if STATE.db and STATE.db.autoSyncToCarbonite then
                SyncQueueToCarbonite()
            end
        end

        STATE.tuningUi.applyingPending = false
    end

    local f = CreateFrame('Frame', 'CustomWaypointsRoutingTuningFrame', UIParent)
    f:SetWidth(520)
    f:SetHeight(430)
    f:SetPoint('CENTER', UIParent, 'CENTER', 40, -20)
    -- Keep tuning above CW main UI to prevent visual mixing.
    f:SetFrameStrata('TOOLTIP')
    f:SetScale((STATE.db and STATE.db.uiScale) or 1)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag('LeftButton')
    f:SetScript('OnDragStart', function(self) self:StartMoving() end)
    f:SetScript('OnDragStop', function(self) self:StopMovingOrSizing() end)
    f:SetScript('OnShow', function(self)
        if STATE.ui and STATE.ui.frame and self.SetFrameLevel then
            local baseLevel = (STATE.ui.frame.GetFrameLevel and STATE.ui.frame:GetFrameLevel()) or 1
            self:SetFrameLevel(baseLevel + 30)
        end
        if self.EnableKeyboard then
            pcall(function() self:EnableKeyboard(false) end)
        end
        if self.SetPropagateKeyboardInput then
            pcall(function() self:SetPropagateKeyboardInput(true) end)
        end
        RefreshRoutingTuningUi()
    end)
    f:SetScript('OnHide', function(self)
        RemoveCwModalFrame(self)
        if self.SetPropagateKeyboardInput then
            pcall(function() self:SetPropagateKeyboardInput(true) end)
        end
        if self.EnableKeyboard then
            pcall(function() self:EnableKeyboard(false) end)
        end
        -- Delay heavy route recalculation until slider release or tuning close.
        FlushPendingRoutingTuningChanges()
    end)
    f:SetScript('OnMouseDown', function(self)
        PushCwModalFrame(self)
    end)

    local bg = f:CreateTexture(nil, 'BACKGROUND')
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.82)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = 'Interface\\DialogFrame\\UI-DialogBox-Background',
            edgeFile = 'Interface\\Tooltips\\UI-Tooltip-Border',
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
    title:SetPoint('TOPLEFT', f, 'TOPLEFT', 12, -10)
    title:SetText('Routing tuning')

    local subtitle = f:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
    subtitle:SetPoint('TOPLEFT', title, 'BOTTOMLEFT', 0, -8)
    subtitle:SetWidth(488)
    subtitle:SetJustifyH('LEFT')
    subtitle:SetText('Sliders apply on release/close to reduce lag. Reset returns a slider to default.')

    local close = CreateFrame('Button', nil, f, 'UIPanelCloseButton')
    close:SetPoint('TOPRIGHT', f, 'TOPRIGHT', -2, -2)
    close:SetScript('OnClick', function() f:Hide() end)

    local sliderDefs = {
        { key = 'learnedPortalBonus', label = 'Learned portal preference', min = 0, max = 300, step = 5 },
        { key = 'portalBonus', label = 'Portal preference', min = 0, max = 300, step = 5 },
        { key = 'tramBonus', label = 'Tram preference', min = 0, max = 300, step = 5 },
        { key = 'boatBonus', label = 'Boat preference', min = 0, max = 300, step = 5 },
        { key = 'zeppelinBonus', label = 'Zeppelin preference', min = 0, max = 300, step = 5 },
        { key = 'taxiBonus', label = 'Flight master preference', min = 0, max = 300, step = 5 },
        { key = 'maxPostPortalWalkWithoutTaxi', label = 'Max post-portal walk w/o taxi (yards)', min = 0, max = 700, step = 5 },
    }

    local sliders = {}
    local topY = -76
    for i, def in ipairs(sliderDefs) do
        local y = topY - (i - 1) * 34
        local label = f:CreateFontString(nil, 'OVERLAY', 'GameFontNormalSmall')
        label:SetPoint('TOPLEFT', f, 'TOPLEFT', 24, y)
        label:SetText(def.label)

        local sliderName = 'CWRouteTuneSlider' .. def.key
        local slider = CreateFrame('Slider', sliderName, f, 'OptionsSliderTemplate')
        slider:SetWidth(290)
        slider:SetHeight(16)
        slider:SetPoint('TOPLEFT', label, 'BOTTOMLEFT', 4, -8)
        slider:SetMinMaxValues(def.min, def.max)
        slider:SetValueStep(def.step)
        if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end

        local low = _G[sliderName .. 'Low']
        local high = _G[sliderName .. 'High']
        local textFs = _G[sliderName .. 'Text']
        if low and low.Hide then low:Hide() end
        if high and high.Hide then high:Hide() end
        if textFs and textFs.SetText then textFs:SetText('') end

        local minText = f:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
        minText:SetPoint('RIGHT', slider, 'LEFT', -8, 0)
        minText:SetWidth(26)
        minText:SetJustifyH('RIGHT')
        minText:SetText(tostring(def.min))

        local maxText = f:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
        maxText:SetPoint('LEFT', slider, 'RIGHT', 6, 0)
        maxText:SetWidth(34)
        maxText:SetJustifyH('LEFT')
        maxText:SetText(tostring(def.max))

        local valueText = f:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
        valueText:SetPoint('LEFT', maxText, 'RIGHT', 6, 0)
        valueText:SetWidth(64)
        valueText:SetJustifyH('LEFT')

        local reset = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
        reset:SetWidth(52)
        reset:SetHeight(20)
        reset:SetPoint('LEFT', valueText, 'RIGHT', 4, 0)
        reset:SetText('Reset')
        reset:SetScript('OnClick', function()
            ApplyRoutingTuningChange(def.key, ROUTING_TUNING_DEFAULTS[def.key])
        end)

        slider:SetScript('OnValueChanged', function(self, value)
            if STATE.tuningUi and STATE.tuningUi.updating then return end
            value = math.floor((tonumber(value) or 0) + 0.5)
            if valueText and valueText.SetText then
                valueText:SetText(tostring(value) .. "/" .. tostring(def.max))
            end
            pendingValues[def.key] = value
            if reset and reset.Enable then
                if value == ROUTING_TUNING_DEFAULTS[def.key] then reset:Disable() else reset:Enable() end
            end
        end)

        slider:SetScript('OnMouseUp', function()
            if pendingValues[def.key] ~= nil then
                ApplyRoutingTuningChange(def.key, pendingValues[def.key], true)
                pendingValues[def.key] = nil
            end
        end)

        sliders[#sliders + 1] = {
            key = def.key,
            max = def.max,
            slider = slider,
            minText = minText,
            maxText = maxText,
            valueText = valueText,
            reset = reset,
        }
    end

    local resetAll = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
    resetAll:SetWidth(110)
    resetAll:SetHeight(24)
    resetAll:SetPoint('BOTTOMLEFT', f, 'BOTTOMLEFT', 16, 14)
    resetAll:SetText('Reset all')
    resetAll:SetScript('OnClick', function()
        EnsureDb()
        STATE.db.routingTuning = {}
        InvalidateRoute('routing tuning reset all')
        RefreshUiHeader()
        RefreshRoutingTuningUi()
        if STATE.db.autoSyncToCarbonite then
            SyncQueueToCarbonite()
        end
    end)

    local closeBtn = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
    closeBtn:SetWidth(110)
    closeBtn:SetHeight(24)
    closeBtn:SetPoint('LEFT', resetAll, 'RIGHT', 8, 0)
    closeBtn:SetText('Close')
    closeBtn:SetScript('OnClick', function() f:Hide() end)

    STATE.tuningUi = {
        frame = f,
        sliders = sliders,
        resetAll = resetAll,
        closeBtn = closeBtn,
        subtitle = subtitle,
        updating = false,
        applyingPending = false,
    }

    RefreshRoutingTuningUi()
    f:Hide()
    return STATE.tuningUi
end

local function ToggleRoutingTuningUi()
    EnsureRoutingTuningUi()
    if STATE.tuningUi.frame:IsShown() then
        STATE.tuningUi.frame:Hide()
    else
        RefreshRoutingTuningUi()
        STATE.tuningUi.frame:Show()
        ArmKeyboardModalFrame(STATE.tuningUi.frame)
    end
end

local function TransportLabel(edge)
    return tostring(edge.label or ("Learned Portal: " .. tostring(edge.fromMapName or edge.fromMaI or "?") .. " -> " .. tostring(edge.toMapName or edge.toMaI or "?")))
end

local function LearnedTransportKey(edge)
    if not edge or not edge.fromMaI or not edge.toMaI then return nil end
    return tostring(edge.fromMaI) .. ">" .. tostring(edge.toMaI)
end

local function HasLearnedTransportCoords(edge)
    return edge
        and edge.fromWx and edge.fromWy
        and edge.toWx and edge.toWy
end

-- Keep learned transport DB compact and stable across sessions:
-- for portal discovery we treat same from-map -> to-map as one learned route.
local function CompactLearnedTransports()
    EnsureDb()
    local learned = STATE.db.learnedTransports
    if type(learned) ~= "table" or #learned <= 1 then return end

    local merged = {}
    local byKey = {}
    for _, edge in ipairs(learned) do
        local key = LearnedTransportKey(edge)
        if key and byKey[key] then
            local dst = byKey[key]
            -- If existing record is incomplete but a newer duplicate has full
            -- coordinates, upgrade the stored edge so routing stays usable.
            if not HasLearnedTransportCoords(dst) and HasLearnedTransportCoords(edge) then
                dst.fromWx = edge.fromWx
                dst.fromWy = edge.fromWy
                dst.fromZx = edge.fromZx
                dst.fromZy = edge.fromZy
                dst.toWx = edge.toWx
                dst.toWy = edge.toWy
                dst.toZx = edge.toZx
                dst.toZy = edge.toZy
                dst.fromMapName = edge.fromMapName or dst.fromMapName
                dst.toMapName = edge.toMapName or dst.toMapName
                dst.label = edge.label or dst.label
            end
            
            edge.uses = tonumber(edge.uses) or 1
            if edge.lastSeen ~= nil then
                local n = tonumber(edge.lastSeen)
                if n ~= nil then
                    edge.lastSeen = n
                end
            end

            dst.uses = tonumber(dst.uses) or 1
            if dst.lastSeen ~= nil then
                local n = tonumber(dst.lastSeen)
                if n ~= nil then
                    dst.lastSeen = n
                end
            end

            dst.uses = (tonumber(dst.uses) or 1) + (tonumber(edge.uses) or 1)

            local edgeLastSeenNum = tonumber(edge.lastSeen)
            local dstLastSeenNum = tonumber(dst.lastSeen)

            if edgeLastSeenNum and (not dstLastSeenNum or edgeLastSeenNum > dstLastSeenNum) then
                dst.lastSeen = edgeLastSeenNum
            elseif edge.lastSeen and not dst.lastSeen then
                dst.lastSeen = edge.lastSeen
            end
        else
            local copy = {}
            for k, v in pairs(edge) do copy[k] = v end
            merged[#merged + 1] = copy
            if key then
                byKey[key] = copy
            end
        end
    end

    wipe(learned)
    for i = 1, #merged do
        learned[i] = merged[i]
    end
end

local function EnsureTransportDb()
    EnsureDb()
    STATE.db.learnedTransports = STATE.db.learnedTransports or {}
    CompactLearnedTransports()
    return STATE.db.learnedTransports
end

local function CloneWorldPoint(pt)
    if not pt then return nil end
    return {
        maI = pt.maI,
        wx = pt.wx,
        wy = pt.wy,
        zx = pt.zx,
        zy = pt.zy,
        mapName = pt.mapName,
        continent = pt.continent,
        instance = pt.instance,
        instanceType = pt.instanceType,
        zoneText = pt.zoneText,
        subZoneText = pt.subZoneText,
    }
end


local function EscapePortableField(value)
    return gsub(tostring(value or ""), "|", "/")
end

local function NormalizeSignatureNumber(value, decimals)
    value = tonumber(value)
    if value == nil then return "?" end
    local fmt = "%0." .. tostring(decimals or 3) .. "f"
    return format(fmt, value)
end

-- Build a stable waypoint signature for route/known-location dedup.
local function BuildWaypointSignature(dest)
    if not dest then return "nil" end
    return table.concat({
        tostring(dest.maI or "?"),
        NormalizeSignatureNumber(dest.zx, 2),
        NormalizeSignatureNumber(dest.zy, 2),
        NormalizeSignatureNumber(dest.wx, 5),
        NormalizeSignatureNumber(dest.wy, 5),
    }, "|")
end

-- Build a stable known-location signature; routes are deduped by the full ordered waypoint chain.
local function BuildKnownLocationSignature(loc)
    if not loc then return nil end
    if loc.kind == "route" and type(loc.routePoints) == "table" and #loc.routePoints > 0 then
        local parts = {}
        for i, pt in ipairs(loc.routePoints) do
            parts[i] = BuildWaypointSignature(pt)
        end
        return "route|" .. tostring(#parts) .. "|" .. table.concat(parts, ">")
    end

    local dest = loc.destination or loc.lastTarget or loc.previousTarget
    if not dest then return nil end
    return table.concat({
        tostring(loc.kind or "known"),
        tostring(loc.instanceType or ""),
        BuildWaypointSignature(dest),
    }, "|")
end

local function FindDuplicateKnownLocationIndex(candidate, skipIndex)
    local wanted = BuildKnownLocationSignature(candidate)
    if not wanted then return nil end
    for i, loc in ipairs(STATE.db and STATE.db.knownLocations or {}) do
        if i ~= skipIndex and BuildKnownLocationSignature(loc) == wanted then
            return i
        end
    end
    return nil
end

local CloneDestination

-- Clone a waypoint list while preserving ordered route structure.
local function CloneDestinations(src, seen)
    if not src then return {} end
    seen = seen or {}

    if seen[src] then
        return seen[src]
    end

    local out = {}
    seen[src] = out

    for i, dest in ipairs(src) do
        out[i] = CloneDestination(dest, seen)
    end
    return out
end

-- Clone one destination/route point, including nested routePoints, without recursing forever on cycles.
CloneDestination = function(dest, seen)
    if not dest then return nil end
    seen = seen or {}

    if seen[dest] then
        return seen[dest]
    end

    local copy = {}
    seen[dest] = copy

    for k, v in pairs(dest) do
        if k == "routePoints" and type(v) == "table" then
            copy[k] = CloneDestinations(v, seen)
        else
            copy[k] = v
        end
    end
    return copy
end

local function NormalizeKnownLocationAfterEdit(loc)
    if not loc then return end
    if loc.kind == "route" then
        local routePoints = loc.routePoints or {}
        loc.destination = CloneDestination(routePoints[#routePoints])
        loc.mapName = routePoints[#routePoints] and routePoints[#routePoints].mapName or nil
    else
        local dest = loc.destination or loc.lastTarget or loc.previousTarget
        if dest then
            loc.destination = CloneDestination(dest)
            loc.mapName = dest.mapName or loc.mapName
        end
    end
end

local function SerializeWaypointLine(index, dest)
    local pname = EscapePortableField(dest.mapName or "?")
    return format("%d|%d|%s|%.3f|%.3f|%.6f|%.6f|%s|%s|%s",
        index,
        dest.maI or -1,
        pname,
        dest.zx or -1,
        dest.zy or -1,
        dest.wx or -1,
        dest.wy or -1,
        dest.ts or "?",
        EscapePortableField(dest.userName or "?"),
        EscapePortableField(dest.userLabel or "?")
    )
end

local function SerializeRoutePointsBlock(routePoints)
    local lines = {}
    for i, dest in ipairs(routePoints or {}) do
        lines[#lines + 1] = SerializeWaypointLine(i, dest)
    end
    return table.concat(lines, "\n")
end


local function ParseRoutePointsBlock(text)
    local parsed = {}
    local bad = 0
    for _, line in ipairs(SplitLines(text or "")) do
        local dest, why = ParseExportLine(line)
        if dest then
            parsed[#parsed + 1] = dest
        elseif why and why ~= "empty" and why ~= "marker" then
            bad = bad + 1
        end
    end
    table.sort(parsed, function(a, b)
        return (a._importOrder or 0) < (b._importOrder or 0)
    end)
    for _, dest in ipairs(parsed) do
        dest._importOrder = nil
    end
    return parsed, bad
end

local function BuildKnownLocationExportHeader(loc)
    return table.concat({
        "CWKNOWN",
        EscapePortableField(loc.kind or "known"),
        EscapePortableField(loc.name or ""),
        EscapePortableField(loc.label or ""),
        EscapePortableField(loc.description or ""),
        EscapePortableField(loc.instanceType or ""),
    }, "|")
end

local function BuildLearnedTransportExportHeader(edge)
    return table.concat({
        "CWKNOWN",
        "transport",
        EscapePortableField(edge.label or TransportLabel(edge) or ""),
        "",
        "",
        EscapePortableField(edge.toInstanceType or edge.fromInstanceType or ""),
    }, "|")
end

local function SerializeLearnedTransportLine(edge)
    return table.concat({
        "T",
        tostring(edge.fromMaI or "?"),
        EscapePortableField(edge.fromMapName or "?"),
        NormalizeSignatureNumber(edge.fromZx, 3),
        NormalizeSignatureNumber(edge.fromZy, 3),
        NormalizeSignatureNumber(edge.fromWx, 6),
        NormalizeSignatureNumber(edge.fromWy, 6),
        tostring(edge.toMaI or "?"),
        EscapePortableField(edge.toMapName or "?"),
        NormalizeSignatureNumber(edge.toZx, 3),
        NormalizeSignatureNumber(edge.toZy, 3),
        NormalizeSignatureNumber(edge.toWx, 6),
        NormalizeSignatureNumber(edge.toWy, 6),
        EscapePortableField(edge.label or ""),
        tostring(edge.uses or 1),
        EscapePortableField(edge.lastSeen or "?"),
        tostring(edge.fromInstance and 1 or 0),
        EscapePortableField(edge.fromInstanceType or ""),
        tostring(edge.toInstance and 1 or 0),
        EscapePortableField(edge.toInstanceType or ""),
    }, "|")
end

local function ParseLearnedTransportLine(line)
    local parts = SplitExportFields(NormalizeImportLine(line))
    if #parts < 20 or parts[1] ~= "T" then
        return nil, "bad-transport-line"
    end

    local fromMaI = tonumber(parts[2])
    local fromMapName = parts[3] ~= "" and parts[3] ~= "?" and parts[3] or nil
    local fromZx = tonumber(parts[4])
    local fromZy = tonumber(parts[5])
    local fromWx = tonumber(parts[6])
    local fromWy = tonumber(parts[7])

    local toMaI = tonumber(parts[8])
    local toMapName = parts[9] ~= "" and parts[9] ~= "?" and parts[9] or nil
    local toZx = tonumber(parts[10])
    local toZy = tonumber(parts[11])
    local toWx = tonumber(parts[12])
    local toWy = tonumber(parts[13])

    if not fromMaI or not toMaI or not fromWx or not fromWy or not toWx or not toWy then
        return nil, "bad-transport-coords"
    end

    return {
        fromMaI = fromMaI,
        fromMapName = fromMapName,
        fromZx = fromZx,
        fromZy = fromZy,
        fromWx = fromWx,
        fromWy = fromWy,
        toMaI = toMaI,
        toMapName = toMapName,
        toZx = toZx,
        toZy = toZy,
        toWx = toWx,
        toWy = toWy,
        label = parts[14] ~= "" and parts[14] ~= "?" and parts[14] or nil,
        uses = tonumber(parts[15]) or 1,
        lastSeen = (parts[16] ~= "" and parts[16] ~= "?") and parts[16] or nil,
        fromInstance = parts[17] == "1" and true or nil,
        fromInstanceType = parts[18] ~= "" and parts[18] or nil,
        toInstance = parts[19] == "1" and true or nil,
        toInstanceType = parts[20] ~= "" and parts[20] or nil,
    }, nil
end

local function ParseKnownLocationHeader(line)
    line = NormalizeImportLine(line)
    if not string.match(line or "", "^CWKNOWN|") then
        return nil
    end

    local parts = SplitExportFields(line)
    if parts[1] ~= "CWKNOWN" or #parts < 2 then
        return nil
    end

    return {
        kind = parts[2] ~= "" and parts[2] or "known",
        name = parts[3] ~= "" and parts[3] or nil,
        label = parts[4] ~= "" and parts[4] or nil,
        description = parts[5] ~= "" and parts[5] or nil,
        instanceType = parts[6] ~= "" and parts[6] or nil,
    }
end

local function FinalizeImportedKnownLocation(header, routePoints)
    routePoints = routePoints or {}
    if header.kind == "route" then
        if #routePoints == 0 then return nil, "route-empty" end
        return {
            key = "route|" .. tostring(time and time() or GetTime() or math.random(100000, 999999)) .. "|" .. tostring(math.random(1000, 9999)),
            kind = "route",
            name = header.name,
            label = header.label,
            description = header.description,
            routePoints = CloneDestinations(routePoints),
            destination = CloneDestination(routePoints[#routePoints]),
            mapName = routePoints[#routePoints] and routePoints[#routePoints].mapName or nil,
            discoveredBy = "import-known-locations",
        }, nil
    end

    if #routePoints == 0 then return nil, "point-empty" end
    local dest = CloneDestination(routePoints[1])
    return {
        key = tostring(header.kind or "known") .. "|" .. tostring(time and time() or GetTime() or math.random(100000, 999999)) .. "|" .. tostring(math.random(1000, 9999)),
        kind = header.kind or "known",
        name = header.name,
        label = header.label,
        description = header.description,
        destination = dest,
        mapName = dest and dest.mapName or nil,
        instance = (header.kind == "instance") and true or nil,
        instanceType = header.instanceType,
        discoveredBy = "import-known-locations",
    }, nil
end

local function DeduplicateKnownLocationsPreserveOrder(list)
    local out = {}
    local seen = {}
    for _, loc in ipairs(list or {}) do
        local sig = BuildKnownLocationSignature(loc)
        if sig and not seen[sig] then
            seen[sig] = true
            out[#out + 1] = loc
        end
    end
    return out
end

-- Save an instance as a known location (routes to entrance only)
local function SaveInstanceKnownLocation(fromPos, toPos)
    if not fromPos or not fromPos.maI or not toPos then return end
    EnsureDb()
    STATE.db.knownLocations = STATE.db.knownLocations or {}

    local instanceName = tostring(
        toPos.zoneText
        or toPos.subZoneText
        or toPos.mapName
        or ("Instance " .. tostring(toPos.maI or "?"))
    )

    local key = "instance|" .. tostring(fromPos.maI) .. "|" .. string.lower(instanceName)
    local entrance = CloneWorldPoint(fromPos)

    for _, loc in ipairs(STATE.db.knownLocations) do
        if loc.key == key then
            loc.destination = entrance
            loc.instance = true
            loc.kind = "instance"
            loc.instanceType = toPos.instanceType or "instance"
            return
        end
    end

    STATE.db.knownLocations[#STATE.db.knownLocations + 1] = {
        key = key,
        name = instanceName,
        kind = "instance",
        instance = true,
        instanceType = toPos.instanceType or "instance",
        destination = entrance,
        mapName = entrance.mapName,
        discoveredBy = "transport-discovery-instance",
    }
end

local function dbg(msg)
    if STATE.db and STATE.db.debug == true then
        pr(msg)
    end
end

local function CloneKnownLocationDestination(loc)
    if not loc then return nil end
    local pt = loc.destination or loc.lastTarget or loc
    if not pt then return nil end
    local copy = CloneWorldPoint(pt)
    copy.label = loc.name or loc.mapName or pt.mapName or ("Map " .. tostring(pt.maI or "?"))
    copy.sourceKnownLocationKey = loc.key
    copy.sourceKnownLocationKind = loc.kind
    return copy
end

local function BuildKnownLocationEntries()
    EnsureDb()

    local entries = {}
    local map = GetMap()

    local function addEntry(entry)
        entries[#entries + 1] = entry
    end

    for i, loc in ipairs(STATE.db.knownLocations or {}) do
        if loc and loc.kind == "route" and type(loc.routePoints) == "table" and #loc.routePoints > 0 then
            local finalDest = CloneDestination(loc.routePoints[#loc.routePoints])
            addEntry({
                key = tostring(loc.key or ("route|" .. tostring(i))),
                kind = "route",
                name = tostring(loc.name or ("Route " .. tostring(i))),
                label = loc.label,
                description = loc.description,
                mapName = finalDest and finalDest.mapName or nil,
                destination = finalDest,
                routePoints = CloneDestinations(loc.routePoints),
                previousTarget = loc.routePoints[1],
                lastTarget = finalDest,
                instance = false,
                instanceType = nil,
                sourceType = "knownRoute",
                sourceIndex = i,
            })
        else
            local dest = CloneKnownLocationDestination(loc)
            if dest then
                addEntry({
                    key = tostring(loc.key or ("known|" .. tostring(i))),
                    kind = tostring(loc.kind or "known"),
                    name = tostring(loc.name or dest.mapName or ("Map " .. tostring(dest.maI or "?"))),
                    label = loc.label,
                    description = loc.description,
                    mapName = dest.mapName,
                    destination = dest,
                    previousTarget = loc.previousTarget or loc.entrance,
                    lastTarget = loc.lastTarget or loc.destination,
                    instance = (loc.instance == true)
                        or (loc.instanceType and loc.instanceType ~= "" and loc.instanceType ~= "none")
                        or (dest.instance == true)
                        or ((dest.instanceType and dest.instanceType ~= "" and dest.instanceType ~= "none") and true or false),
                    instanceType = loc.instanceType or dest.instanceType,
                    sourceType = "knownLocation",
                    sourceIndex = i,
                })
            end
        end
    end

    for i, edge in ipairs(EnsureTransportDb() or {}) do
        local fromPt = {
            maI = edge.fromMaI,
            wx = edge.fromWx,
            wy = edge.fromWy,
            zx = edge.fromZx,
            zy = edge.fromZy,
            mapName = edge.fromMapName,
            instance = edge.fromInstance,
            instanceType = edge.fromInstanceType,
        }

        local destPt = {
            maI = edge.toMaI,
            wx = edge.toWx,
            wy = edge.toWy,
            zx = edge.toZx,
            zy = edge.toZy,
            mapName = edge.toMapName,
            instance = edge.toInstance,
            instanceType = edge.toInstanceType,
        }

        addEntry({
            key = "transport|" .. tostring(i) .. "|" .. tostring(edge.fromMaI or "?") .. ">" .. tostring(edge.toMaI or "?"),
            kind = "transport",
            name = TransportLabel(edge),
            mapName = destPt.mapName,
            destination = destPt,
            previousTarget = fromPt,
            lastTarget = destPt,
            instance = destPt.instance == true or ((destPt.instanceType and destPt.instanceType ~= "" and destPt.instanceType ~= "none") and true or false),
            instanceType = destPt.instanceType,
            sourceType = "learnedTransport",
            sourceIndex = i,
        })
    end

    table.sort(entries, function(a, b)
        local an = lower(tostring(a.name or ""))
        local bn = lower(tostring(b.name or ""))
        if an == bn then
            return tostring(a.key or "") < tostring(b.key or "")
        end
        return an < bn
    end)

    return entries
end

local function EntryContainsQuery(entry, query)
    if not query or query == "" then return true end
    local q = lower(tostring(query or ""))

    local haystack = lower(table.concat({
        tostring(entry.name or ""),
        tostring(entry.kind or ""),
        tostring(entry.instanceType or ""),
        tostring((entry.previousTarget and (entry.previousTarget.mapName or entry.previousTarget.maI)) or ""),
        tostring((entry.lastTarget and (entry.lastTarget.mapName or entry.lastTarget.maI)) or ""),
        tostring((entry.destination and (entry.destination.mapName or entry.destination.maI)) or "")
    }, " | "))

    return string.find(haystack, q, 1, true) ~= nil
end

local function EntryMatchesFilters(entry, ui)
    if not entry then return false end
    if ui and ui.routesOnly and not (entry.kind == "route" and entry.sourceType == "knownRoute") then
        return false
    end
    if ui and ui.instancesOnly and not entry.instance then
        return false
    end
    if ui and ui.searchText and ui.searchText ~= "" and not EntryContainsQuery(entry, ui.searchText) then
        return false
    end
    return true
end

local function ResolveKnownLocationAbsoluteIndex(entry)
    if not entry or not entry.key then return nil end
    local all = BuildKnownLocationEntries()
    for absoluteIndex = 1, #all do
        if all[absoluteIndex].key == entry.key then
            return absoluteIndex
        end
    end
    return nil
end

local function ResolveKnownLocationStoredSourceIndex(entry)
    if not entry then return nil end

    if (entry.sourceType == "knownLocation" or entry.sourceType == "knownRoute") and entry.sourceIndex then
        return entry.sourceIndex
    end

    if not entry.key then return nil end

    local all = BuildKnownLocationEntries()
    for i = 1, #all do
        local candidate = all[i]
        if candidate.key == entry.key and (candidate.sourceType == "knownLocation" or candidate.sourceType == "knownRoute") then
            return candidate.sourceIndex
        end
    end

    return nil
end

local function NormalizeOptionalMetadataField(value)
    if value == nil then return nil end
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" or value == "?" then
        return nil
    end
    return value
end

local function SanitizeRoutePointForEditing(pt)
    local copy = CloneDestination(pt) or {}

    copy.userName = NormalizeOptionalMetadataField(copy.userName)
    copy.userLabel = NormalizeOptionalMetadataField(copy.userLabel)

    local rawTs = tostring(copy.ts or "?")
    local baseTs, trailing = rawTs:match("^(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)(.+)$")
    if baseTs then
        copy.ts = baseTs
        trailing = NormalizeOptionalMetadataField(trailing)
        if trailing then
            if not copy.userName then
                copy.userName = trailing
            elseif not copy.userLabel then
                copy.userLabel = trailing
            end
        end
    else
        local normalizedTs = NormalizeOptionalMetadataField(rawTs)
        copy.ts = normalizedTs or "?"
    end

    return copy
end

local function SanitizeRoutePointsForEditing(routePoints)
    local out = {}
    for i, pt in ipairs(routePoints or {}) do
        out[i] = SanitizeRoutePointForEditing(pt)
    end
    return out
end

local function PushHistorySnapshot(reason)
    STATE.history = STATE.history or {}
    STATE.future = STATE.future or {}
    STATE.history[#STATE.history + 1] = {
        reason = reason or "snapshot",
        destinations = CloneDestinations(STATE.db and STATE.db.destinations or {}),
    }
    while #STATE.history > 100 do
        tremove(STATE.history, 1)
    end
    wipe(STATE.future)
end

-- When the manual CW queue transitions from empty -> non-empty, stop Carbonite's
-- quest auto-tracking so the HUD arrow / route focus stays on the manual waypoint.
local function DisableCarboniteQuestAutoTrack(reason)
    local que = Nx and Nx.Que
    local wat = que and que.Wat
    local didAnything = false

    if wat and wat.CAT and wat.BAT1 then
        local ok = pcall(function() wat:CAT() end)
        if ok then
            didAnything = true
        end
    end

    if que and que.Tra1 then
        local hadTracked = false
        for _ in pairs(que.Tra1) do
            hadTracked = true
            break
        end
        que.Tra1 = {}
        didAnything = didAnything or hadTracked
    end

    if wat and wat.BAT1 and wat.BAT1.SeP2 then
        pcall(function() wat.BAT1:SeP2(false) end)
    end
    if wat and wat.Upd then
        pcall(function() wat:Upd() end)
    end

    if didAnything then
        dbg("Carbonite quest auto-track disabled" .. (reason and (": " .. tostring(reason)) or ""))
    end

    return didAnything
end

local function HandleQueueBecameNonEmpty(reason, wasEmpty)
    if wasEmpty and STATE.db and #(STATE.db.destinations or {}) > 0 then
        DisableCarboniteQuestAutoTrack(reason)
    end
end

RouteToKnownLocation = function(index)
    EnsureDb()
    local allEntries = BuildKnownLocationEntries()
    local entry = allEntries and allEntries[index] or nil
    if not entry then
        pr("known location not found: " .. tostring(index))
        return
    end

    local wasEmpty = #(STATE.db.destinations or {}) == 0
    PushHistorySnapshot("route-known-location")
    wipe(STATE.db.destinations)

    if entry.kind == "route" and type(entry.routePoints) == "table" and #entry.routePoints > 0 then
        local cloned = CloneDestinations(entry.routePoints)
        for i = 1, #cloned do
            tinsert(STATE.db.destinations, cloned[i])
        end
        HandleQueueBecameNonEmpty("route-known-location", wasEmpty)
        pr(format("loaded known route: %s (%d stop(s))", tostring(entry.name or index), #cloned))
    else
        local dest = CloneKnownLocationDestination(entry)
        if not dest then
            pr("known location has no destination: " .. tostring(entry.name or index))
            return
        end
        tinsert(STATE.db.destinations, dest)
        HandleQueueBecameNonEmpty("route-known-location", wasEmpty)
        pr(format("routing to known location: %s", tostring(entry.name or dest.mapName or dest.maI)))
    end

    InvalidateRoute("known location selected")
    RefreshUiHeader()

    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end
end

SaveQueueAsKnownRoute = function()
    EnsureDb()
    if not STATE.db or #(STATE.db.destinations or {}) == 0 then
        pr("saveroute: queue empty")
        return
    end

    ShowWaypointMetadataPopup({
        title = "Save queue as known route",
        defaultName = "Route " .. date("%Y-%m-%d %H:%M"),
        defaultLabel = "route",
        defaultDescription = "",
        onSave = function(meta)
            local key = "route|" .. tostring(time and time() or GetTime() or math.random(100000, 999999))
            local routePoints = CloneDestinations(STATE.db.destinations)
            STATE.db.knownLocations = STATE.db.knownLocations or {}

            local candidate = {
                key = key,
                kind = "route",
                name = (meta.name ~= "" and meta.name) or ("Route " .. tostring(#STATE.db.knownLocations + 1)),
                label = meta.label ~= "" and meta.label or nil,
                description = meta.description ~= "" and meta.description or nil,
                routePoints = routePoints,
                destination = CloneDestination(routePoints[#routePoints]),
                mapName = routePoints[#routePoints] and routePoints[#routePoints].mapName or nil,
                discoveredBy = "manual-saveroute",
            }

            local duplicateIndex = FindDuplicateKnownLocationIndex(candidate)
            if duplicateIndex then
                pr("saved known route skipped: duplicate of existing known location #" .. tostring(duplicateIndex))
                return
            end

            STATE.db.knownLocations[#STATE.db.knownLocations + 1] = candidate

            pr("saved known route: " .. tostring(meta.name ~= "" and meta.name or key))
            RefreshKnownLocationsFrame()
        end
    })
end

SelectKnownLocation = function(index)
    if not (STATE.knownLocationsUi and STATE.knownLocationsUi.frame) then return end
    STATE.knownLocationsUi.selectedIndex = index
    RefreshKnownLocationsFrame()
end

local function DeleteKnownLocationEntry(entry)
    EnsureDb()
    if not entry then
        pr("delete failed: no known location selected")
        return false
    end

    if entry.sourceType == "learnedTransport" then
        local learned = EnsureTransportDb()
        if not learned[entry.sourceIndex] then
            pr("delete failed: learned transport not found")
            return false
        end
        table.remove(learned, entry.sourceIndex)
        InvalidateRoute("deleted learned transport from known locations")
        pr("deleted learned transport: " .. tostring(entry.name or entry.sourceIndex))
        return true
    end

    local known = STATE.db.knownLocations or {}
    if not entry.sourceIndex or not known[entry.sourceIndex] then
        pr("delete failed: known location not found")
        return false
    end

    local removed = known[entry.sourceIndex]
    table.remove(known, entry.sourceIndex)
    InvalidateRoute("deleted known location entry")
    pr("deleted known location: " .. tostring((removed and removed.name) or entry.name or entry.sourceIndex))
    return true
end

local function EnsurePopupEsc(frameName)
    if UISpecialFrames then
        local exists = false
        for _, v in ipairs(UISpecialFrames) do
            if v == frameName then
                exists = true
                break
            end
        end
        if not exists then
            tinsert(UISpecialFrames, frameName)
        end
    end
end

local function ShowKnownRouteEditorPopup(sourceIndex, loc)
    local frameName = "CustomWaypointsKnownRouteEditorPopup"

    if STATE.knownRouteEditorPopup and STATE.knownRouteEditorPopup.frame then
        STATE.knownRouteEditorPopup.frame:Hide()
    end

    local f = CreateFrame("Frame", frameName, UIParent)
    f:SetWidth(560)
    f:SetHeight(420)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(96)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    if f.EnableKeyboard then f:EnableKeyboard(false) end
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.92)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\DialogFrame\UI-DialogBox-Background",
            edgeFile = "Interface\Tooltips\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("Edit known route")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    subtitle:SetWidth(520)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Edit metadata plus all saved waypoint lines for this route. One exported waypoint per line; order is preserved.")

    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -64)
    nameLabel:SetText("Name")

    local nameBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    nameBox:SetAutoFocus(false)
    nameBox:SetWidth(330)
    nameBox:SetHeight(20)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
    nameBox:SetText(loc.name or "")

    local labelLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    labelLabel:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -18)
    labelLabel:SetText("Label")

    local labelBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    labelBox:SetAutoFocus(false)
    labelBox:SetWidth(330)
    labelBox:SetHeight(20)
    labelBox:SetPoint("LEFT", labelLabel, "RIGHT", 10, 0)
    labelBox:SetText(loc.label or "")

    local descLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    descLabel:SetPoint("TOPLEFT", labelLabel, "BOTTOMLEFT", 0, -18)
    descLabel:SetText("Description")

    local descBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    descBox:SetAutoFocus(false)
    descBox:SetWidth(330)
    descBox:SetHeight(20)
    descBox:SetPoint("LEFT", descLabel, "RIGHT", 10, 0)
    descBox:SetText(loc.description or "")

    local routesLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    routesLabel:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -22)
    routesLabel:SetText("Route waypoint lines")

    local scroll = CreateFrame("ScrollFrame", frameName .. "Scroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", routesLabel, "BOTTOMLEFT", 0, -8)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 48)

    local editor = CreateFrame("EditBox", nil, scroll)
    editor:SetMultiLine(true)
    editor:SetAutoFocus(false)
    editor:SetFontObject(GameFontHighlightSmall)
    editor:SetWidth(490)
    editor:SetTextInsets(4, 4, 4, 4)
    editor:SetJustifyH("LEFT")
    editor:SetText(EscapeForDisplay(SerializeRoutePointsBlock(SanitizeRoutePointsForEditing(loc.routePoints or {}))))
    editor:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editor:SetScript("OnCursorChanged", function(self, x, y, w, h)
        if scroll.SetHorizontalScroll then scroll:SetHorizontalScroll(0) end
    end)
    editor:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        local _, lineCount = string.gsub(text, "", "")
        local lines = lineCount + 1
        local _, fontHeight = self:GetFont()
        fontHeight = fontHeight or 14
        self:SetHeight(math.max(220, lines * fontHeight + fontHeight * 2))
        if scroll.UpdateScrollChildRect then
            scroll:UpdateScrollChildRect()
        end
    end)
    scroll:SetScrollChild(editor)
    editor:GetScript("OnTextChanged")(editor)

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetWidth(90)
    saveBtn:SetHeight(24)
    saveBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    saveBtn:SetText("Save")

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetWidth(90)
    cancelBtn:SetHeight(24)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 16)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() f:Hide() end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    saveBtn:SetScript("OnClick", function()
        local parsed, bad = ParseRoutePointsBlock(UnescapeFromDisplay(editor:GetText() or ""))
        if #parsed == 0 then
            pr("known route edit failed: no valid waypoint lines")
            return
        end
        if bad > 0 then
            pr("known route edit failed: remove invalid waypoint line(s) first")
            return
        end

        parsed = SanitizeRoutePointsForEditing(parsed)

        local candidate = CloneDestination(loc)
        candidate.name = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        candidate.label = (labelBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        candidate.description = descBox:GetText() or ""
        candidate.routePoints = CloneDestinations(parsed)
        NormalizeKnownLocationAfterEdit(candidate)

        local duplicateIndex = FindDuplicateKnownLocationIndex(candidate, sourceIndex)
        if duplicateIndex then
            pr("known route edit skipped: duplicate of existing known location #" .. tostring(duplicateIndex))
            return
        end

        loc.name = candidate.name ~= "" and candidate.name or loc.name
        loc.label = candidate.label ~= "" and candidate.label or nil
        loc.description = candidate.description ~= "" and candidate.description or nil
        loc.routePoints = candidate.routePoints
        loc.destination = candidate.destination
        loc.mapName = candidate.mapName
        RefreshKnownLocationsFrame()
        pr("updated known route: " .. tostring(loc.name or sourceIndex) .. " (" .. tostring(#loc.routePoints or 0) .. " waypoint(s))")
        f:Hide()
    end)

    f:SetScript("OnHide", function(self)
        if nameBox and nameBox.ClearFocus then nameBox:ClearFocus() end
        if labelBox and labelBox.ClearFocus then labelBox:ClearFocus() end
        if descBox and descBox.ClearFocus then descBox:ClearFocus() end
        if editor and editor.ClearFocus then editor:ClearFocus() end

        if nameBox and nameBox.Hide then nameBox:Hide() end
        if labelBox and labelBox.Hide then labelBox:Hide() end
        if descBox and descBox.Hide then descBox:Hide() end
        if editor and editor.Hide then editor:Hide() end

        if self.EnableKeyboard then self:EnableKeyboard(false) end
        if STATE.knownRouteEditorPopup and STATE.knownRouteEditorPopup.frame == self then
            STATE.knownRouteEditorPopup = nil
        end
    end)

    EnsurePopupEsc(frameName)
    STATE.knownRouteEditorPopup = { frame = f, editor = editor }
    f:Show()
    if nameBox.SetFocus then nameBox:SetFocus() end
end

ShowKnownLocationEditorPopup = function(sourceIndex)
    EnsureDb()

    if type(sourceIndex) == "table" and sourceIndex.sourceType == "learnedTransport" then
        pr("edit skipped: discovered portals are not editable yet")
        return
    end

    local resolvedSourceIndex = nil

    if type(sourceIndex) == "table" then
        resolvedSourceIndex = ResolveKnownLocationStoredSourceIndex(sourceIndex)
    else
        resolvedSourceIndex = tonumber(sourceIndex)

        local direct = resolvedSourceIndex and STATE.db.knownLocations and STATE.db.knownLocations[resolvedSourceIndex] or nil
        if not direct and resolvedSourceIndex and STATE.knownLocationsUi and STATE.knownLocationsUi.visibleEntries then
            local visibleEntry = STATE.knownLocationsUi.visibleEntries[resolvedSourceIndex]
            if visibleEntry and visibleEntry.sourceType == "learnedTransport" then
                pr("edit skipped: discovered portals are not editable yet")
                return
            end
            if visibleEntry then
                local mapped = ResolveKnownLocationStoredSourceIndex(visibleEntry)
                if mapped then
                    resolvedSourceIndex = mapped
                end
            end
        end

        direct = resolvedSourceIndex and STATE.db.knownLocations and STATE.db.knownLocations[resolvedSourceIndex] or nil
        if not direct and resolvedSourceIndex and STATE.knownLocationsUi and STATE.knownLocationsUi.visibleEntries then
            local visibleEntry = STATE.knownLocationsUi.visibleEntries[resolvedSourceIndex]
            if visibleEntry and visibleEntry.sourceType == "learnedTransport" then
                pr("edit skipped: discovered portals are not editable yet")
                return
            end
            if visibleEntry then
                resolvedSourceIndex = ResolveKnownLocationStoredSourceIndex(visibleEntry)
            end
        end
    end

    local loc = resolvedSourceIndex and STATE.db.knownLocations and STATE.db.knownLocations[resolvedSourceIndex] or nil
    if not loc then
        pr("edit failed: known location not found")
        return
    end

    if loc.kind == "route" then
        ShowKnownRouteEditorPopup(resolvedSourceIndex, loc)
        return
    end

    ShowWaypointMetadataPopup({
        title = "Edit known location",
        defaultName = loc.name or "",
        defaultLabel = loc.label or "",
        defaultDescription = loc.description or "",
        onSave = function(meta)
            local candidate = CloneDestination(loc)
            candidate.name = meta.name ~= "" and meta.name or loc.name
            candidate.label = meta.label ~= "" and meta.label or nil
            candidate.description = meta.description ~= "" and meta.description or nil
            NormalizeKnownLocationAfterEdit(candidate)

            local duplicateIndex = FindDuplicateKnownLocationIndex(candidate, resolvedSourceIndex)
            if duplicateIndex then
                pr("known location edit skipped: duplicate of existing known location #" .. tostring(duplicateIndex))
                return
            end

            loc.name = candidate.name
            loc.label = candidate.label
            loc.description = candidate.description
            loc.destination = candidate.destination
            loc.mapName = candidate.mapName
            RefreshKnownLocationsFrame()
            pr("updated known location: " .. tostring(loc.name or resolvedSourceIndex))
        end
    })
end

ShowKnownLocationImportPopup = function()
    local frameName = "CustomWaypointsKnownLocationsImportPopup"

    if STATE.knownLocationImportPopup and STATE.knownLocationImportPopup.frame then
        STATE.knownLocationImportPopup.frame:Hide()
    end

    local f = CreateFrame("Frame", frameName, UIParent)
    f:SetWidth(560)
    f:SetHeight(360)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(96)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    if f.EnableKeyboard then f:EnableKeyboard(false) end
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.92)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\DialogFrame\UI-DialogBox-Background",
            edgeFile = "Interface\Tooltips\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("Import known locations")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    subtitle:SetWidth(520)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Paste a Known Locations export block here. Import does union + dedup; existing entries stay in place.")

    local scroll = CreateFrame("ScrollFrame", frameName .. "Scroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -62)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 48)

    local editor = CreateFrame("EditBox", nil, scroll)
    editor:SetMultiLine(true)
    editor:SetAutoFocus(false)
    editor:SetFontObject(GameFontHighlightSmall)
    editor:SetWidth(490)
    editor:SetTextInsets(4, 4, 4, 4)
    editor:SetJustifyH("LEFT")
    editor:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editor:SetScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        local _, lineCount = string.gsub(text, "", "")
        local lines = lineCount + 1
        local _, fontHeight = self:GetFont()
        fontHeight = fontHeight or 14
        self:SetHeight(math.max(220, lines * fontHeight + fontHeight * 2))
        if scroll.UpdateScrollChildRect then
            scroll:UpdateScrollChildRect()
        end
    end)
    scroll:SetScrollChild(editor)
    editor:SetText("")
    editor:GetScript("OnTextChanged")(editor)

    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetWidth(90)
    importBtn:SetHeight(24)
    importBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    importBtn:SetText("Import")

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetWidth(90)
    cancelBtn:SetHeight(24)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 16)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() f:Hide() end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    importBtn:SetScript("OnClick", function()
        ImportKnownLocationsFromText(editor:GetText() or "")
        f:Hide()
    end)

    f:SetScript("OnHide", function(self)
        if editor and editor.ClearFocus then editor:ClearFocus() end
        if editor and editor.Hide then editor:Hide() end
        if self.EnableKeyboard then self:EnableKeyboard(false) end
    end)

    EnsurePopupEsc(frameName)
    STATE.knownLocationImportPopup = { frame = f, editor = editor }
    f:Show()
    if editor.SetFocus then editor:SetFocus() end
end

RefreshKnownLocationsFrame = function()
    if not (STATE.knownLocationsUi and STATE.knownLocationsUi.frame) then return end

    local ui = STATE.knownLocationsUi
    local content = ui.content
    local allEntries = BuildKnownLocationEntries()
    local visibleEntries = {}

    for i = 1, #allEntries do
        local entry = allEntries[i]
        if EntryMatchesFilters(entry, ui) then
            visibleEntries[#visibleEntries + 1] = entry
        end
    end

    ui.visibleEntries = visibleEntries

    for _, child in ipairs({content:GetChildren()}) do
        child:Hide()
    end

    if ui.emptyText then
        ui.emptyText:Hide()
        ui.emptyText:SetText("")
    end

    if #visibleEntries == 0 then
        ui.selectedIndex = nil
    elseif not ui.selectedIndex or not visibleEntries[ui.selectedIndex] then
        ui.selectedIndex = 1
    end

    local yOffset = -10
    if #visibleEntries == 0 then
        if not ui.emptyText then
            ui.emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            ui.emptyText:SetPoint("TOPLEFT", content, "TOPLEFT", 10, yOffset)
        end
        ui.emptyText:SetText("No matching known locations")
        if ui.routeSelectedBtn then
            ui.routeSelectedBtn:Disable()
        end
        if ui.deleteSelectedBtn then
            ui.deleteSelectedBtn:Disable()
        end
        content:SetHeight(40)
        return
    end

    for i, entry in ipairs(visibleEntries) do
        local row = CreateFrame("Button", nil, content)
        row:SetSize(500, 42)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function()
            local now = GetTime and GetTime() or 0
            local uiState = STATE.knownLocationsUi
            local chosenBeforeRefresh = uiState and uiState.visibleEntries and uiState.visibleEntries[i] or nil

            local isDouble =
                chosenBeforeRefresh
                and uiState
                and uiState.lastClickKey == chosenBeforeRefresh.key
                and uiState.lastClickTime
                and (now - uiState.lastClickTime) <= 0.35

            if uiState then
                uiState.lastClickKey = chosenBeforeRefresh and chosenBeforeRefresh.key or nil
                uiState.lastClickTime = now
            end

            SelectKnownLocation(i)

            if not isDouble or not chosenBeforeRefresh then
                return
            end

            local absoluteIndex = ResolveKnownLocationAbsoluteIndex(chosenBeforeRefresh)
            if absoluteIndex then
                RouteToKnownLocation(absoluteIndex)
            end

            if STATE.knownLocationsUi and STATE.knownLocationsUi.frame then
                STATE.knownLocationsUi.frame:Hide()
            end
        end)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        if i == ui.selectedIndex then
            bg:SetTexture(0.2, 0.45, 0.9, 0.28)
        else
            bg:SetTexture(1, 1, 1, 0.04)
        end

        local title = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        title:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -8)
        title:SetWidth(390)
        title:SetJustifyH("LEFT")
        title:SetText(format("%d) %s", i, tostring(entry.name or entry.mapName or ("Map " .. tostring((entry.destination and entry.destination.maI) or "?")))))

        local meta = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        meta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
        meta:SetWidth(390)
        meta:SetJustifyH("LEFT")
        meta:SetText(format("kind=%s | entrance=%s | destination=%s%s",
            tostring(entry.kind or "?"),
            tostring((entry.previousTarget and (entry.previousTarget.mapName or entry.previousTarget.maI)) or "?"),
            tostring((entry.lastTarget and (entry.lastTarget.mapName or entry.lastTarget.maI)) or (entry.destination and (entry.destination.mapName or entry.destination.maI)) or "?"),
            entry.instance and format(" | instance=%s", tostring(entry.instanceType or "yes")) or ""
        ))

        local routeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        routeBtn:SetWidth(74)
        routeBtn:SetHeight(22)
        routeBtn:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        routeBtn:SetText("Route")
        routeBtn:SetScript("OnClick", function()
            SelectKnownLocation(i)
            local chosen = STATE.knownLocationsUi and STATE.knownLocationsUi.visibleEntries and STATE.knownLocationsUi.visibleEntries[i] or nil
            local absoluteIndex = ResolveKnownLocationAbsoluteIndex(chosen)
            if absoluteIndex then
                RouteToKnownLocation(absoluteIndex)
            end
            if STATE.knownLocationsUi and STATE.knownLocationsUi.frame then
                STATE.knownLocationsUi.frame:Hide()
            end
        end)
        local editBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        editBtn:SetWidth(54)
        editBtn:SetHeight(22)
        editBtn:SetPoint("RIGHT", routeBtn, "LEFT", -6, 0)
        editBtn:SetText("Edit")
        editBtn:SetScript("OnClick", function()
            local chosen = STATE.knownLocationsUi and STATE.knownLocationsUi.visibleEntries and STATE.knownLocationsUi.visibleEntries[i] or nil
            if chosen then
                ShowKnownLocationEditorPopup(chosen)
            end
        end)

        yOffset = yOffset - 44
    end

    if ui.routeSelectedBtn then
        if ui.selectedIndex and visibleEntries[ui.selectedIndex] then
            ui.routeSelectedBtn:Enable()
        else
            ui.routeSelectedBtn:Disable()
        end
    end

    if ui.deleteSelectedBtn then
        if ui.selectedIndex and visibleEntries[ui.selectedIndex] then
            ui.deleteSelectedBtn:Enable()
        else
            ui.deleteSelectedBtn:Disable()
        end
    end

    content:SetHeight(math.max(60, -yOffset + 10))
end

ShowKnownLocationsFrame = function()
    if STATE.knownLocationsUi and STATE.knownLocationsUi.frame then
        local f = STATE.knownLocationsUi.frame
        if f:IsShown() then
            f:Hide()
        else
            ArmKeyboardModalFrame(f)
            RefreshKnownLocationsFrame()
            f:Show()
        end
        return
    end

    local f = CreateFrame("Frame", "CustomWaypointsKnownLocationsFrame", UIParent)
    f:SetWidth(560)
    f:SetHeight(390)
    f:SetPoint("CENTER", UIParent, "CENTER", 30, -10)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(92)
        f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    if f.EnableKeyboard then f:EnableKeyboard(false) end
    if f.SetPropagateKeyboardInput then f:SetPropagateKeyboardInput(true) end
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetScript("OnShow", function(self)
        PushCwModalFrame(self)
    end)
    f:SetScript("OnHide", function(self)
        RemoveCwModalFrame(self)
        if self.SetPropagateKeyboardInput then
            self:SetPropagateKeyboardInput(true)
        end
        if self.EnableKeyboard then
            self:EnableKeyboard(false)
        end
    end)
    f:SetScript("OnMouseDown", function(self)
        PushCwModalFrame(self)
    end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.88)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("CustomWaypoints - Known Locations")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -8)
    subtitle:SetWidth(510)
    subtitle:SetJustifyH("CENTER")
    subtitle:SetText("Known locations + learned transports. Left click selects, double click routes.")

    local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -59)
    searchLabel:SetText("Search")

    local searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    searchBox:SetAutoFocus(false)
    searchBox:SetWidth(180)
    searchBox:SetHeight(20)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(self)
        if STATE.knownLocationsUi then
            STATE.knownLocationsUi.searchText = self:GetText() or ""
            STATE.knownLocationsUi.selectedIndex = nil
            RefreshKnownLocationsFrame()
        end
    end)

    local instanceCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    instanceCheck:SetPoint("LEFT", searchBox, "RIGHT", 18, 0)
    instanceCheck:SetChecked(false)
    instanceCheck:SetScript("OnClick", function(self)
        if STATE.knownLocationsUi then
            STATE.knownLocationsUi.instancesOnly = self:GetChecked() and true or false
            STATE.knownLocationsUi.selectedIndex = nil
            RefreshKnownLocationsFrame()
        end
    end)

    local instanceLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instanceLabel:SetPoint("LEFT", instanceCheck, "RIGHT", 2, 0)
    instanceLabel:SetText("Instances only")

    local routesCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    routesCheck:SetPoint("LEFT", instanceLabel, "RIGHT", 18, 0)
    routesCheck:SetChecked(false)
    routesCheck:SetScript("OnClick", function(self)
        if STATE.knownLocationsUi then
            STATE.knownLocationsUi.routesOnly = self:GetChecked() and true or false
            STATE.knownLocationsUi.selectedIndex = nil
            RefreshKnownLocationsFrame()
        end
    end)

    local routesLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    routesLabel:SetPoint("LEFT", routesCheck, "RIGHT", 2, 0)
    routesLabel:SetText("Routes only")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetWidth(90)
    refreshBtn:SetHeight(22)
    refreshBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function() RefreshKnownLocationsFrame() end)

    local scrollFrame = CreateFrame("ScrollFrame", "CustomWaypointsKnownLocationsScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -88)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 42)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(500, 1)
    scrollFrame:SetScrollChild(content)

    routeSelectedBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    routeSelectedBtn:SetWidth(120)
    routeSelectedBtn:SetHeight(22)
    routeSelectedBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 8, 0)
    routeSelectedBtn:SetText("Route Selected")
    routeSelectedBtn:SetScript("OnClick", function()
        local ui = STATE.knownLocationsUi
        if not ui or not ui.selectedIndex or not ui.visibleEntries or not ui.visibleEntries[ui.selectedIndex] then
            return
        end
        local chosen = ui.visibleEntries[ui.selectedIndex]
        local absoluteIndex = ResolveKnownLocationAbsoluteIndex(chosen)
        if absoluteIndex then
            RouteToKnownLocation(absoluteIndex)
        end
    end)
    routeSelectedBtn:Disable()

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetWidth(70)
    exportBtn:SetHeight(22)
    exportBtn:SetPoint("LEFT", routeSelectedBtn, "RIGHT", 8, 0)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function() ExportKnownLocations() end)

    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetWidth(70)
    importBtn:SetHeight(22)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function() ShowKnownLocationImportPopup() end)
    
    local deleteSelectedBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    deleteSelectedBtn:SetWidth(120)
    deleteSelectedBtn:SetHeight(22)
    deleteSelectedBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
    deleteSelectedBtn:SetText("Delete Selected")
    deleteSelectedBtn:SetScript("OnClick", function()
        local ui = STATE.knownLocationsUi
        if not ui or not ui.selectedIndex or not ui.visibleEntries or not ui.visibleEntries[ui.selectedIndex] then
            pr("delete failed: no known location selected")
            return
        end
        local chosen = ui.visibleEntries[ui.selectedIndex]
        if DeleteKnownLocationEntry(chosen) then
            ui.selectedIndex = nil
            RefreshKnownLocationsFrame()
        end
    end)
    
    STATE.knownLocationsUi = {
        frame = f,
        content = content,
        scrollFrame = scrollFrame,
        routeSelectedBtn = routeSelectedBtn,
        exportBtn = exportBtn,
        importBtn = importBtn,
        searchBox = searchBox,
        instanceCheck = instanceCheck,
        searchText = "",
        instancesOnly = false,
        selectedIndex = nil,
        visibleEntries = {},
    }

    RefreshKnownLocationsFrame()
    ArmKeyboardModalFrame(f)
    f:Show()
end

local function ShowTransportManagementFrame()
    if STATE.transportManagementFrame then
        if STATE.transportManagementFrame:IsShown() then
            STATE.transportManagementFrame:Hide()
        else
            STATE.transportManagementFrame:Show()
            ArmKeyboardModalFrame(STATE.transportManagementFrame)
        end
        return
    end

    local f = CreateFrame("Frame", "CustomWaypointsTransportManagement", UIParent)
    f:SetWidth(640)
    f:SetHeight(440)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(90)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.9)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -20)
    title:SetText("CustomWaypoints - Transport / Instance Management")

    local instructions = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instructions:SetPoint("TOP", title, "BOTTOM", 0, -10)
    instructions:SetWidth(590)
    instructions:SetJustifyH("CENTER")
    instructions:SetText("Delete learned transports and saved instance entrances")

    local scrollFrame = CreateFrame("ScrollFrame", "TransportManagementScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -60)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -40, 50)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(560, 1)
    scrollFrame:SetScrollChild(content)

    local function RefreshTransportList()
        for _, child in ipairs({content:GetChildren()}) do
            child:Hide()
            child:SetParent(nil)
        end
        content.checkboxes = nil

        EnsureDb()
        local learned = EnsureTransportDb()
        local known = STATE.db.knownLocations or {}

        local rows = {}

        for i, edge in ipairs(learned or {}) do
            rows[#rows + 1] = {
                entryType = "transport",
                index = i,
                label = format("%s (uses: %d)", TransportLabel(edge), edge.uses or 1),
                meta = format(
                    "type=transport | from=%s | to=%s",
                    tostring(edge.fromMapName or edge.fromMaI or "?"),
                    tostring(edge.toMapName or edge.toMaI or "?")
                ),
            }
        end

        for i, loc in ipairs(known or {}) do
            if loc and loc.kind == "instance" then
                rows[#rows + 1] = {
                    entryType = "instance",
                    index = i,
                    label = tostring(loc.name or ("Instance " .. tostring(i))),
                    meta = format(
                        "type=instance | entrance=%s | key=%s",
                        tostring((loc.destination and (loc.destination.mapName or loc.destination.maI)) or loc.mapName or "?"),
                        tostring(loc.key or "?")
                    ),
                }
            end
        end

        if #rows == 0 then
            local empty = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            empty:SetPoint("TOP", content, "TOP", 0, -10)
            empty:SetText("No saved transports or instance entrances found")
            content:SetHeight(40)
            return
        end

        table.sort(rows, function(a, b)
            local at = tostring(a.entryType or "")
            local bt = tostring(b.entryType or "")
            if at ~= bt then
                return at < bt
            end
            return lower(tostring(a.label or "")) < lower(tostring(b.label or ""))
        end)

        local yOffset = -10
        local checkboxes = {}

        for i, rowData in ipairs(rows) do
            local entry = CreateFrame("Frame", nil, content)
            entry:SetSize(540, 38)
            entry:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)

            local cb = CreateFrame("CheckButton", nil, entry, "UICheckButtonTemplate")
            cb:SetPoint("TOPLEFT", entry, "TOPLEFT", 4, -4)
            cb.entryType = rowData.entryType
            cb.entryIndex = rowData.index
            checkboxes[i] = cb

            local label = entry:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("TOPLEFT", cb, "TOPRIGHT", 8, -2)
            label:SetWidth(470)
            label:SetJustifyH("LEFT")
            label:SetText(rowData.label)

            local meta = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            meta:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
            meta:SetWidth(470)
            meta:SetJustifyH("LEFT")
            meta:SetText(rowData.meta)

            yOffset = yOffset - 40
        end

        content.checkboxes = checkboxes
        content:SetHeight(-yOffset + 20)
    end

    local deleteBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    deleteBtn:SetWidth(140)
    deleteBtn:SetHeight(25)
    deleteBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 15)
    deleteBtn:SetText("Delete Selected")
    deleteBtn:SetScript("OnClick", function()
        local transportsToDelete = {}
        local instancesToDelete = {}

        if content.checkboxes then
            for _, cb in pairs(content.checkboxes) do
                if cb:GetChecked() then
                    if cb.entryType == "transport" then
                        tinsert(transportsToDelete, cb.entryIndex)
                    elseif cb.entryType == "instance" then
                        tinsert(instancesToDelete, cb.entryIndex)
                    end
                end
            end
        end

        if #transportsToDelete == 0 and #instancesToDelete == 0 then
            pr("No transports or instance entrances selected for deletion")
            return
        end

        table.sort(transportsToDelete, function(a, b) return a > b end)
        table.sort(instancesToDelete, function(a, b) return a > b end)

        local learned = EnsureTransportDb()
        local known = STATE.db.knownLocations or {}

        for _, index in ipairs(transportsToDelete) do
            table.remove(learned, index)
        end

        for _, index in ipairs(instancesToDelete) do
            table.remove(known, index)
        end

        InvalidateRoute("deleted saved transport/instance entries")
        RefreshTransportList()

        pr(format(
            "Deleted %d transport(s) and %d instance entrance(s)",
            #transportsToDelete,
            #instancesToDelete
        ))
    end)

    local function ShowClearAllConfirmation(onConfirm)
        local cf = CreateFrame("Frame", "CustomWaypointsTransportManagement", UIParent)
        cf:SetWidth(360)
        cf:SetHeight(150)
        cf:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        cf:SetFrameStrata("DIALOG")
        cf:SetFrameLevel((f:GetFrameLevel() or 90) + 20)
        cf:SetClampedToScreen(true)
        cf:EnableMouse(true)
        cf:SetMovable(true)
        cf:RegisterForDrag("LeftButton")
        cf:SetScript("OnDragStart", function(self) self:StartMoving() end)
        cf:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

        -- ESC closes only. No keyboard confirm.
        if cf.EnableKeyboard then cf:EnableKeyboard(false) end
        cf:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:Hide()
            end
        end)

        local bg = cf:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(cf)
        bg:SetTexture(0, 0, 0, 0.92)

        if cf.SetBackdrop then
            cf:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 }
            })
        end

        local title = cf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", cf, "TOP", 0, -14)
        title:SetText("Confirm Clear All")

        local msg = cf:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        msg:SetPoint("TOPLEFT", cf, "TOPLEFT", 20, -42)
        msg:SetPoint("RIGHT", cf, "RIGHT", -20, 0)
        msg:SetJustifyH("LEFT")
        msg:SetJustifyV("TOP")
        msg:SetText("This will delete all learned transports and all saved instance entrances.")

        local cancelBtn = CreateFrame("Button", nil, cf, "UIPanelButtonTemplate")
        cancelBtn:SetWidth(100)
        cancelBtn:SetHeight(24)
        cancelBtn:SetPoint("BOTTOMLEFT", cf, "BOTTOMLEFT", 24, 18)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function()
            cf:Hide()
        end)

        local confirmBtn = CreateFrame("Button", nil, cf, "UIPanelButtonTemplate")
        confirmBtn:SetWidth(120)
        confirmBtn:SetHeight(24)
        confirmBtn:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -24, 18)
        confirmBtn:SetText("Clear All")
        confirmBtn:SetScript("OnClick", function()
            if onConfirm then
                onConfirm()
            end
            cf:Hide()
        end)

        cf:SetScript("OnHide", function(self)
            if self.EnableKeyboard then self:EnableKeyboard(false) end
            self:SetParent(nil)
        end)

        cf:SetScript("OnShow", function(self)
            PushCwModalFrame(self)
            if self.EnableKeyboard then self:EnableKeyboard(false) end
            if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(true) end
        end)

        cf:SetScript("OnHide", function(self)
            RemoveCwModalFrame(self)
            if self.EnableKeyboard then self:EnableKeyboard(false) end
            if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(true) end
            self:SetParent(nil)
        end)

        cf:SetScript("OnMouseDown", function(self)
            PushCwModalFrame(self)
        end)

        cf:Show()
    end

    local clearAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearAllBtn:SetWidth(120)
    clearAllBtn:SetHeight(25)
    clearAllBtn:SetPoint("LEFT", deleteBtn, "RIGHT", 10, 0)
    clearAllBtn:SetText("Clear All")
    clearAllBtn:SetScript("OnClick", function()
        ShowClearAllConfirmation(function()
            local learned = EnsureTransportDb()
            local known = STATE.db.knownLocations or {}

            local removedInstances = 0
            for i = #known, 1, -1 do
                if known[i] and known[i].kind == "instance" then
                    table.remove(known, i)
                    removedInstances = removedInstances + 1
                end
            end

            local removedTransports = #learned
            wipe(learned)

            InvalidateRoute("cleared all transports and instances")
            RefreshTransportList()

            pr(format(
                "Cleared %d transport(s) and %d instance entrance(s)",
                removedTransports,
                removedInstances
            ))
        end)
    end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        f:Hide()
    end)

    f:SetScript("OnShow", function(self)
        PushCwModalFrame(self)
        if self.EnableKeyboard then self:EnableKeyboard(false) end
        if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(true) end
    end)

    f:SetScript("OnHide", function(self)
        RemoveCwModalFrame(self)
        if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(true) end
        if self.EnableKeyboard then self:EnableKeyboard(false) end
    end)
    f:SetScript("OnMouseDown", function(self)
        PushCwModalFrame(self)
    end)

    STATE.transportManagementFrame = f
    RefreshTransportList()
    f:Show()
    ArmKeyboardModalFrame(f)
end

function CustomWaypoints_ToggleKnownLocations()
    ShowKnownLocationsFrame()
end

function CustomWaypoints_SaveHere()
    if STATE.db.autoAdvance then
        SlashHandler("autoadvance")
    end
    AddCurrentLocationWithMetadataPopup()
end

local function TryAutoBindCommand(bindingName, desiredKeys, debugName)
    if not (SetBinding and SaveBindings and GetCurrentBindingSet and GetBindingKey and GetBindingAction) then
        return
    end

    local existing1, existing2 = GetBindingKey(bindingName)
    if existing1 or existing2 then
        return
    end

    for _, desired in ipairs(desiredKeys or {}) do
        local action = GetBindingAction(desired)
        if not action or action == "" or action == bindingName then
            SetBinding(desired, bindingName)
            SaveBindings(GetCurrentBindingSet())
            dbg(tostring(debugName or bindingName) .. " binding set to " .. tostring(desired))
            return
        end
    end

    dbg("no free preferred key found for " .. tostring(debugName or bindingName))
end

EnsureKnownLocationsBinding = function()
    if STATE.knownLocationsBindingInitialized then
        return
    end

    STATE.knownLocationsBindingInitialized = true
    TryAutoBindCommand("CW_TOGGLE_KNOWN_LOCATIONS", { "SHIFT-G" }, "known locations")
end

EnsureSaveHereBinding = function()
    if STATE.saveHereBindingInitialized then
        return
    end

    STATE.saveHereBindingInitialized = true

    if not (SetBinding and SaveBindings and GetCurrentBindingSet and GetBindingKey and GetBindingAction) then
        return
    end

    -- Clear any old/native bindings already attached to this command.
    local old1, old2 = GetBindingKey("CW_SAVE_HERE")
    if old1 then SetBinding(old1, nil) end
    if old2 then SetBinding(old2, nil) end

    -- Hard-normalize SHIFT-R itself, even if it was stale or previously occupied.
    local currentShiftR = GetBindingAction("SHIFT-R")
    if currentShiftR and currentShiftR ~= "" then
        SetBinding("SHIFT-R", nil)
    end

    SetBinding("SHIFT-R", "CW_SAVE_HERE")
    SaveBindings(GetCurrentBindingSet())

    dbg("savehere binding hard-forced to SHIFT-R")
end

local function EnsureUi()
    if STATE.ui and STATE.ui.frame then
        RefreshUiHeader()
        return STATE.ui
    end

    local f = CreateFrame("Frame", "CustomWaypointsMainFrame", UIParent)
    f:SetWidth(760)
    f:SetHeight(508)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetScale((STATE.db and STATE.db.uiScale) or 1)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if UISpecialFrames and not STATE.uiSpecialRegistered then
        tinsert(UISpecialFrames, "CustomWaypointsMainFrame")
        STATE.uiSpecialRegistered = true
    end

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.78)

    local borderTop = f:CreateTexture(nil, "BORDER")
    borderTop:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    borderTop:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    borderTop:SetHeight(1)
    borderTop:SetTexture(1, 1, 1, 0.20)

    local borderBottom = f:CreateTexture(nil, "BORDER")
    borderBottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    borderBottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    borderBottom:SetHeight(1)
    borderBottom:SetTexture(1, 1, 1, 0.20)

    local borderLeft = f:CreateTexture(nil, "BORDER")
    borderLeft:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    borderLeft:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    borderLeft:SetWidth(1)
    borderLeft:SetTexture(1, 1, 1, 0.20)

    local borderRight = f:CreateTexture(nil, "BORDER")
    borderRight:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    borderRight:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    borderRight:SetWidth(1)
    borderRight:SetTexture(1, 1, 1, 0.20)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    title:SetText("CustomWaypoints")

    local header = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    header:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    header:SetWidth(720)
    header:SetJustifyH("LEFT")


    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        f:Hide()
    end)

    local function MakeButton(textLabel, x, y, command)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetWidth(78)
        b:SetHeight(22)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        b:SetText(textLabel)
        b:SetScript("OnClick", function()
            SlashHandler(command)
            RefreshUiHeader()
        end)
        return b
    end

    MakeButton("Help",     12, -72,  "help")
    MakeButton("Sync",     94, -72,  "sync")
    MakeButton("Route",   176, -72,  "route")
    MakeButton("Graph",   258, -72,  "graph")
    MakeButton("List",    340, -72,  "list")
    MakeButton("Undo",    422, -72,  "undo")
    MakeButton("Redo",    504, -72,  "redo")
    MakeButton("Clear",   586, -72,  "clear")
    MakeButton("Pop",     668, -72,  "pop")

    MakeButton("Probe",    12, -98,  "probe")
    MakeButton("Export",   94, -98,  "export")
    MakeButton("Tuning",  176, -98,  "tuning")
    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetWidth(78)
    importBtn:SetHeight(22)
    importBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 258, -98)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function()
        local box = STATE.ui and STATE.ui.importBox
        if box then
            box:ClearFocus()
        end
        local raw = box and box:GetText()
        ImportWaypointsFromText(raw ~= nil and tostring(raw) or "")
        RefreshUiHeader()
    end)

    local manageBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    manageBtn:SetWidth(120)
    manageBtn:SetHeight(22)
    manageBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 340, -98)
    manageBtn:SetText("Manage Transports")
    manageBtn:SetScript("OnClick", function() ShowTransportManagementFrame() end)

    local knownBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    knownBtn:SetWidth(120)
    knownBtn:SetHeight(22)
    knownBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 460, -98)
    knownBtn:SetText("Known Locations")
    knownBtn:SetScript("OnClick", function() ShowKnownLocationsFrame() end)

    local saveRouteBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveRouteBtn:SetWidth(100)
    saveRouteBtn:SetHeight(22)
    saveRouteBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 586, -98)
    saveRouteBtn:SetText("Save Route")
    saveRouteBtn:SetScript("OnClick", function() SaveQueueAsKnownRoute() end)

    local function MakeCheckbox(textLabel, x, y, onClick)
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
        fs:SetText(textLabel)
        cb:SetHitRectInsets(0, -80, 0, 0)
        cb:SetScript("OnClick", function(self)
            onClick(self)
            RefreshUiHeader()
        end)
        return cb
    end

    local checks = {}
    checks.flying = MakeCheckbox("Micro Routing", 0, -122, function() SlashHandler("hasflying") end)
    checks.autosync = MakeCheckbox("AutoSync", 100, -122, function() SlashHandler("autosync") end)
    checks.autoadvance = MakeCheckbox("AutoAdvance", 200, -122, function() SlashHandler("autoadvance") end)
    checks.flightmasters = MakeCheckbox("FlightMasters", 300, -122, function() SlashHandler("flightmasters") end)
    checks.deep = MakeCheckbox("Deep", 400, -122, function(self)
        if self:GetChecked() then SlashHandler("deep") else SlashHandler("minimal") end
    end)
    checks.debug = MakeCheckbox("Debug", 500, -122, function() SlashHandler("debug") end)
    
    checks.autodiscovery = MakeCheckbox("AutoDiscovery", 600, -122, function() SlashHandler("autodiscovery") end)
    checks.portaldiscovery = checks.autodiscovery

    local commands = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    commands:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -142)
    commands:SetWidth(720)
    commands:SetJustifyH("LEFT")
    commands:SetText("\n/cw help | ui | tuning | options | probe | add | list | export | import | sync | route | graph | clear | pop | undo | redo | autosync | autoadvance | hasflying | flightmasters | deep | minimal | debug | simplify | legend | transports | cleartransports | transportlog | autodiscovery | transportconfirmation | managetransports | knownlocations | routeknown <index> | saveroute | savehere")

    local importLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importLabel:SetPoint("TOPLEFT", commands, "BOTTOMLEFT", 0, -6)
    importLabel:SetText("Import — paste lines from export (markers optional), then click Import:")

    local importBox = CreateFrame("EditBox", "CustomWaypointsImportBox", f)
    importBox:SetMultiLine(true)
    importBox:SetPoint("TOPLEFT", importLabel, "BOTTOMLEFT", 0, -4)
    importBox:SetSize(686, 86)
    importBox:SetFontObject(GameFontHighlightSmall)
    importBox:SetAutoFocus(false)
    importBox:EnableMouse(true)
    -- if importBox.EnableKeyboard then importBox:EnableKeyboard(true) end
    importBox:SetTextInsets(4, 4, 4, 4)
    importBox:SetJustifyH("LEFT")
    if importBox.SetMaxLetters then importBox:SetMaxLetters(16384) end
    importBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local ibg = importBox:CreateTexture(nil, "BACKGROUND")
    ibg:SetTexture(0.08, 0.08, 0.1, 0.9)
    ibg:SetPoint("TOPLEFT", -3, 3)
    ibg:SetPoint("BOTTOMRIGHT", 3, -3)

    local scroll = CreateFrame("ScrollFrame", "CustomWaypointsScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -266)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 12)

    local output = CreateFrame("EditBox", "CustomWaypointsScrollChild", scroll)
    output:SetMultiLine(true)
    output:SetAutoFocus(false)
    output:EnableMouse(true)
    -- Allow typing notes, selection, Ctrl+C copy when focused (chat log still refreshed by addon).
    -- if output.EnableKeyboard then output:EnableKeyboard(true) end
    output:SetFontObject(ChatFontNormal)
    output:SetWidth(690)
    output:SetHeight(200)
    output:SetJustifyH("LEFT")
    if output.SetMaxLetters then output:SetMaxLetters(120000) end
    output:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    output:SetScript("OnTextChanged", function(self)
        if STATE.outputRecursing then
            local parent = self:GetParent()
            if parent and parent.UpdateScrollChildRect then
                pcall(function() parent:UpdateScrollChildRect() end)
            end
            return
        end
        -- Typing / paste: expand height; keep scroll position (addon path uses outputRecursing + ResizeLogOutputEditor(true)).
        ResizeLogOutputEditor(false)
    end)
    scroll:SetScrollChild(output)

    STATE.ui = {
        frame = f,
        title = title,
        header = header,
        scroll = scroll,
        output = output,
        commands = commands,
        importBox = importBox,
        checks = checks,
    }

    RefreshUiHeader()
    AppendUiLogLine("CW UI ready. Undo steps back add/clear/pop (snapshot stack). Redo: /cw redo or Ctrl+Shift+Y if unbound.")
    f:Hide()
    return STATE.ui
end

local function EnsureInterfaceOptionsPanel()
    if STATE.interfacePanel then
        RefreshUiHeader()
        return STATE.interfacePanel
    end
    if not InterfaceOptions_AddCategory then return nil end

    local panel = CreateFrame("Frame", "CWPhase5BInterfaceOptions", UIParent)
    panel.name = "CustomWaypoints"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("CustomWaypoints")

    -- local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    -- subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    -- subtitle:SetWidth(500)
    -- subtitle:SetJustifyH("LEFT")
    -- subtitle:SetJustifyV("TOP")
    -- if subtitle.SetNonSpaceWrap then subtitle:SetNonSpaceWrap(true) end
    -- subtitle:SetText("Deep routing + flight masters (defaults). Undo/redo = step through queue history\n (add/clear/pop). /cw undo | redo; Ctrl+Shift+Z | Y if free.")

    local function MakePanelCheckbox(textLabel, x, y, onClick)
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
        local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
        fs:SetText(textLabel)
        cb:SetHitRectInsets(0, -200, 0, 0)
        cb:SetScript("OnClick", function(self)
            onClick(self)
            RefreshUiHeader()
        end)
        return cb
    end

    local checks = {}
    checks.autosync = MakePanelCheckbox("Auto sync to Carbonite", 16, -70, function() SlashHandler("autosync") end)
    checks.autoadvance = MakePanelCheckbox("Auto advance on reach (recording/debugging)", 16, -100, function() SlashHandler("autoadvance") end)
    checks.flying = MakePanelCheckbox("Micro routing", 16, -130, function() SlashHandler("hasflying") end)
    checks.flightmasters = MakePanelCheckbox("Use flight masters in deep mode", 16, -160, function() SlashHandler("flightmasters") end)
    checks.deep = MakePanelCheckbox("Deep routing mode", 16, -190, function(self)
        if self:GetChecked() then SlashHandler("deep") else SlashHandler("minimal") end
    end)
    
    local openBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openBtn:SetWidth(160)
    openBtn:SetHeight(24)
    openBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -250)
    openBtn:SetText("Open CW Window")
    openBtn:SetScript("OnClick", function()
        if SlashCmdList and SlashCmdList.CUSTOMWAYPOINTS then
            SlashCmdList.CUSTOMWAYPOINTS("ui")
        end
    end)

    local tuningBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    tuningBtn:SetWidth(160)
    tuningBtn:SetHeight(24)
    tuningBtn:SetPoint("LEFT", openBtn, "RIGHT", 10, 0)
    tuningBtn:SetText("Open routing tuning")
    tuningBtn:SetScript("OnClick", function()
        ToggleRoutingTuningUi()
    end)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -12)
    note:SetWidth(500)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    if note.SetNonSpaceWrap then note:SetNonSpaceWrap(true) end
    note:SetText("This panel controls CustomWaypoints planning, sync, \ndeep/minimal routing, flight-master usage, and flying-mount behavior.")

    InterfaceOptions_AddCategory(panel)
    STATE.interfacePanel = panel
    STATE.interfaceChecks = checks
    RefreshUiHeader()
    return panel
end

local function InstallSaveHereHotkey()
    -- Intentionally no legacy click-binding path here.
    -- Save Here must use the same native binding path as Shift+G:
    -- Bindings.xml + EnsureSaveHereBinding() + TryAutoBindCommand().
    STATE.saveHereHotkeyInstalled = true
end

local function InstallUndoRedoBindings()
    if STATE.bindingsInstalled then return end

    if not _G.CWPhase5BUndoHotkeyButton then
        local b = CreateFrame("Button", "CWPhase5BUndoHotkeyButton", UIParent)
        b:SetScript("OnClick", function()
            UndoHistory()
        end)
        b:Hide()
    end
    if not _G.CWPhase5BRedoHotkeyButton then
        local b = CreateFrame("Button", "CWPhase5BRedoHotkeyButton", UIParent)
        b:SetScript("OnClick", function()
            RedoHistory()
        end)
        b:Hide()
    end

    local undoClick = "CLICK CWPhase5BUndoHotkeyButton:LeftButton"
    local redoClick = "CLICK CWPhase5BRedoHotkeyButton:LeftButton"
    local bindChanged = false

    local function CanAssignKey(key, boundTo)
        if not GetBindingAction then return true end
        local a = GetBindingAction(key)
        return (not a or a == "" or a == boundTo)
    end

    if CanAssignKey("CTRL-SHIFT-Z", undoClick) then
        if SetBindingClick then
            SetBindingClick("CTRL-SHIFT-Z", "CWPhase5BUndoHotkeyButton", "LeftButton")
            bindChanged = true
        elseif SetBinding then
            SetBinding("CTRL-SHIFT-Z", undoClick)
            bindChanged = true
        end
    end

    if CanAssignKey("CTRL-SHIFT-Y", redoClick) then
        if SetBindingClick then
            SetBindingClick("CTRL-SHIFT-Y", "CWPhase5BRedoHotkeyButton", "LeftButton")
            bindChanged = true
        elseif SetBinding then
            SetBinding("CTRL-SHIFT-Y", redoClick)
            bindChanged = true
        end
    end

    if bindChanged and SaveBindings and GetCurrentBindingSet then
        pcall(SaveBindings, GetCurrentBindingSet())
    end

    STATE.bindingsInstalled = true
end

local function ToggleUi()
    EnsureUi()
    if STATE.ui.frame:IsShown() then
        STATE.ui.frame:Hide()
    else
        RefreshUiHeader()
        STATE.ui.frame:Show()
        ArmKeyboardModalFrame(STATE.ui.frame)
    end
end



local function CoerceSavedBoolean(v, defaultVal)
    if v == true or v == 1 then return true end
    if v == false or v == 0 then return false end
    if type(v) == "string" then
        local s = lower(v:gsub("^%s+", ""):gsub("%s+$", ""))
        if s == "true" or s == "1" or s == "yes" or s == "on" then return true end
        if s == "false" or s == "0" or s == "no" or s == "off" or s == "" then return false end
    end
    if v == nil then return defaultVal end
    return defaultVal
end

EnsureDb = function()
    CustomWaypointsDB = CustomWaypointsDB or {}
    STATE.db = CustomWaypointsDB
    for k, v in pairs(DEFAULTS) do
        if STATE.db[k] == nil then
            if type(v) == "table" then
                STATE.db[k] = {}
            else
                STATE.db[k] = v
            end
        end
    end
    STATE.db.destinations = STATE.db.destinations or {}
    STATE.db.learnedTransports = STATE.db.learnedTransports or {}
    STATE.db.knownLocations = STATE.db.knownLocations or {}
    STATE.db.debug = CoerceSavedBoolean(STATE.db.debug, DEFAULTS.debug)
    STATE.db.transportDiscoveryEnabled = CoerceSavedBoolean(STATE.db.transportDiscoveryEnabled, DEFAULTS.transportDiscoveryEnabled)
    STATE.db.transportLogEnabled = CoerceSavedBoolean(STATE.db.transportLogEnabled, DEFAULTS.transportLogEnabled)
    STATE.db.transportConfirmationEnabled = CoerceSavedBoolean(STATE.db.transportConfirmationEnabled, DEFAULTS.transportConfirmationEnabled)
    STATE.db.autoRouteSavedInstanceOnDeath = CoerceSavedBoolean(STATE.db.autoRouteSavedInstanceOnDeath, DEFAULTS.autoRouteSavedInstanceOnDeath)
end

function FindSimilarKnownInstance(toPos)
    EnsureDb()
    local wanted = NormalizeKnownInstanceName(toPos)
    for _, loc in ipairs(STATE.db.knownLocations or {}) do
        if loc and loc.kind == "instance" then
            local existing = lower(tostring(loc.name or ""))
            if existing == wanted then
                return loc
            end
        end
    end
    return nil
end

function FindFallbackKnownInstanceByNames(pos)
    EnsureDb()
    if not pos then return nil end

    local wanted = {}
    local function add(name)
        name = lower(tostring(name or "")):gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then
            wanted[name] = true
        end
    end

    add(pos.zoneText)
    add(pos.subZoneText)
    add(pos.mapName)

    for _, loc in ipairs(STATE.db.knownLocations or {}) do
        if loc and loc.kind == "instance" then
            local candidates = {
                loc.name,
                loc.mapName,
                loc.destination and loc.destination.mapName,
            }
            for _, candidate in ipairs(candidates) do
                local normalized = lower(tostring(candidate or "")):gsub("^%s+", ""):gsub("%s+$", "")
                if normalized ~= "" and wanted[normalized] then
                    return loc
                end
            end
        end
    end

    return nil
end

function FindBestSavedInstanceForDeath(pos)
    local direct = FindSimilarKnownInstance(pos)
    if direct then return direct end
    return FindFallbackKnownInstanceByNames(pos)
end

function RouteToSavedInstanceLocation(loc, reason)
    EnsureDb()
    if not loc then return false end

    local dest = CloneKnownLocationDestination(loc)
    if not dest then
        dbg("death auto-route failed: saved instance has no destination")
        return false
    end

    PushHistorySnapshot(reason or "route-saved-instance")
    wipe(STATE.db.destinations)
    tinsert(STATE.db.destinations, dest)
    InvalidateRoute(reason or "saved instance entrance selected")
    RefreshUiHeader()

    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end

    pr("routing to saved instance entrance: " .. tostring(loc.name or dest.mapName or dest.maI))
    return true
end

function ClearPendingDeathAutoRoute()
    STATE.pendingDeathAutoRoute = nil
end

function StartPendingDeathAutoRoute(delay)
    EnsureDb()
    if not (STATE.db and STATE.db.autoRouteSavedInstanceOnDeath) then return end

    local now = GetTime and GetTime() or 0
    STATE.pendingDeathAutoRoute = {
        startedAt = now,
        nextAttemptAt = now + (tonumber(delay) or 0.35),
        attempts = 0,
    }

    dbg("death auto-route queued")
end

local function GetPlayerWorldPos()
    local map = GetMap()
    if not map then return nil end

    local inInstance, instanceType = false, "none"
    if IsInInstance then
        local a, b = IsInInstance()
        inInstance = a and true or false
        instanceType = b or "none"
    end

    local zoneText = GetRealZoneText and GetRealZoneText() or nil
    local subZoneText = GetSubZoneText and GetSubZoneText() or nil

    -- Prefer explicit instance state first. Some entrances/dungeons can still
    -- produce a normal zone-map result via SetMapToCurrentZone(), which hides
    -- the fact that we are now inside an instance and prevents portal/instance
    -- discovery from firing.
    if inInstance and map.GCMI then
        local maI = map:GCMI()
        if maI and maI > 0 then
            return {
                maI = maI,
                wx = nil,
                wy = nil,
                zx = nil,
                zy = nil,
                mapName = (zoneText and zoneText ~= "" and zoneText) or (map.ITN and map:ITN(maI)) or ("Map " .. tostring(maI)),
                instance = true,
                instanceType = instanceType,
                zoneText = zoneText,
                subZoneText = subZoneText,
            }
        end
    end

    if Nx and Nx.Map and Nx.Map.CZ2I then
        local oldCont = GetCurrentMapContinent and GetCurrentMapContinent() or nil
        local oldZone = GetCurrentMapZone and GetCurrentMapZone() or nil

        SetMapToCurrentZone()
        local continent = GetCurrentMapContinent()
        local zone = GetCurrentMapZone()

        if continent and continent > 0 and zone and zone > 0 and Nx.Map.CZ2I[continent] and Nx.Map.CZ2I[continent][zone] then
            local maI = Nx.Map.CZ2I[continent][zone]
            local px, py = GetPlayerMapPosition("player")

            if oldCont and oldZone and SetMapZoom then
                pcall(SetMapZoom, oldCont, oldZone)
            end

            if px and py and not (px == 0 and py == 0) then
                local wx, wy = map:GWP(maI, px * 100, py * 100)
                return {
                    maI = maI,
                    wx = wx,
                    wy = wy,
                    zx = px * 100,
                    zy = py * 100,
                    mapName = map.ITN and map:ITN(maI) or ("Map " .. tostring(maI)),
                    instance = inInstance,
                    instanceType = instanceType,
                    zoneText = zoneText,
                    subZoneText = subZoneText,
                }
            end
        else
            if oldCont and oldZone and SetMapZoom then
                pcall(SetMapZoom, oldCont, oldZone)
            end
        end
    end

    if inInstance and map.GCMI then
        local maI = map:GCMI()
        if maI and maI > 0 then
            return {
                maI = maI,
                wx = nil,
                wy = nil,
                zx = nil,
                zy = nil,
                mapName = (zoneText and zoneText ~= "" and zoneText) or (map.ITN and map:ITN(maI)) or ("Map " .. tostring(maI)),
                instance = true,
                instanceType = instanceType,
                zoneText = zoneText,
                subZoneText = subZoneText,
            }
        end
    end

    return nil
end

function TryAutoRouteSavedInstanceOnDeath()
    EnsureDb()
    if not (STATE.db and STATE.db.autoRouteSavedInstanceOnDeath) then return false, "disabled" end

    local pos = GetPlayerWorldPos()
    if not pos then
        return false, "no-position-yet"
    end

    if not pos.instance then
        return false, "not-in-instance-yet"
    end

    local loc = FindBestSavedInstanceForDeath(pos)
    if not loc then
        return false, "no-saved-instance"
    end

    local key = tostring(loc.key or NormalizeKnownInstanceName(pos))
    if STATE.lastDeathAutoRouteKey == key then
        return true, "already-routed-this-death"
    end

    if RouteToSavedInstanceLocation(loc, "death auto-route saved instance") then
        STATE.lastDeathAutoRouteKey = key
        return true, "routed"
    end

    return false, "route-failed"
end

function PulsePendingDeathAutoRoute()
    local pending = STATE.pendingDeathAutoRoute
    if not pending then return end

    local now = GetTime and GetTime() or 0
    if now < (pending.nextAttemptAt or 0) then return end

    pending.attempts = (pending.attempts or 0) + 1

    local ok, why = TryAutoRouteSavedInstanceOnDeath()
    if ok then
        ClearPendingDeathAutoRoute()
        dbg("death auto-route complete: " .. tostring(why))
        return
    end

    if pending.attempts >= 16 or now - (pending.startedAt or now) > 10 then
        dbg("death auto-route aborted: " .. tostring(why))
        ClearPendingDeathAutoRoute()
        return
    end

    pending.nextAttemptAt = now + 0.45
    if (pending.attempts % 3) == 0 then
        dbg("death auto-route retry " .. tostring(pending.attempts) .. ": " .. tostring(why))
    end
end

local function Dist(wx1, wy1, wx2, wy2)
    if wx1 == nil or wy1 == nil or wx2 == nil or wy2 == nil then
        return nil
    end
    local dx = wx1 - wx2
    local dy = wy1 - wy2
    return sqrt(dx * dx + dy * dy)
end

local function WorldToYards(d)
    if d == nil then
        return huge
    end
    return d * 4.575
end

local function IsNearWorldPoint(wx1, wy1, wx2, wy2, maxYards)
    local yards = WorldToYards(Dist(wx1, wy1, wx2, wy2))
    return yards ~= huge and yards <= (maxYards or 80)
end

function FindSimilarLearnedTransport(fromPos, toPos)
    local learned = EnsureTransportDb()
    for _, edge in ipairs(learned or {}) do
        if edge
            and edge.fromMaI == fromPos.maI
            and edge.toMaI == toPos.maI
            and edge.fromWx and edge.fromWy and fromPos.wx and fromPos.wy
            and edge.toWx and edge.toWy and toPos.wx and toPos.wy
            and IsNearWorldPoint(edge.fromWx, edge.fromWy, fromPos.wx, fromPos.wy, 80)
            and IsNearWorldPoint(edge.toWx, edge.toWy, toPos.wx, toPos.wy, 80)
        then
            return edge
        end
    end
    return nil
end

function TouchLearnedTransport(edge, fromPos, toPos)
    if not edge then return end
    edge.uses = (edge.uses or 1) + 1
    edge.lastSeen = time and time() or nil

    if not edge.fromWx and fromPos and fromPos.wx then
        edge.fromWx = fromPos.wx
        edge.fromWy = fromPos.wy
        edge.fromZx = fromPos.zx
        edge.fromZy = fromPos.zy
    end
    if not edge.toWx and toPos and toPos.wx then
        edge.toWx = toPos.wx
        edge.toWy = toPos.wy
        edge.toZx = toPos.zx
        edge.toZy = toPos.zy
    end
end

local function WalkCostSeconds(wx1, wy1, wx2, wy2)
    local yardsPerSecond = (STATE.db and STATE.db.walkYardsPerSecond) or 7
    if yardsPerSecond <= 0 then yardsPerSecond = 7 end
    local d = Dist(wx1, wy1, wx2, wy2)
    if not d then
        return huge
    end
    return WorldToYards(d) / yardsPerSecond
end

local function IsModifierDown(name)
    name = name or "SHIFT"
    if name == "SHIFT" then return IsShiftKeyDown() end
    if name == "CTRL" then return IsControlKeyDown() end
    if name == "ALT" then return IsAltKeyDown() end
    return false
end

local function GetDisplayedCapture(map)
    map = map or GetMap()
    if not map then return nil, "no-map" end
    if not map.GCMI or not map.FPTWP or not map.GZP then
        return nil, "missing-carbonite-methods"
    end

    if map.CaC3 then
        pcall(map.CaC3, map)
    end

    if not map.CFX or not map.CFY or map.CFX == -1 or map.CFY == -1 then
        return nil, "no-cursor"
    end

    local mx, my = map.CFX, map.CFY
    local frameW, frameH, frameScale = nil, nil, nil

    if map.Frm then
        local fw = map.Frm:GetWidth() or 0
        local fh = map.Frm:GetHeight() or 0
        frameW, frameH = fw, fh
        frameScale = map.Frm.GetEffectiveScale and map.Frm:GetEffectiveScale() or nil
        if fw > 0 then
            if mx < 0 then mx = 0 elseif mx > fw then mx = fw end
        end
        if fh > 0 then
            if my < 0 then my = 0 elseif my > fh then my = fh end
        end
    end

    local maI = map:GCMI()
    if not maI or maI <= 0 then
        return nil, "bad-gcmi"
    end

    local wx, wy = map:FPTWP(mx, my)
    if not wx or not wy then
        return nil, "bad-fptwp"
    end

    local zx, zy = map:GZP(maI, wx, wy)
    -- Guard against mismatched displayed-map/world-point pairs that can produce
    -- out-of-map zone coords and poison routing with invalid same-map shortcuts.
    if not zx or not zy or zx < 0 or zx > 100 or zy < 0 or zy > 100 then
        dbg(format(
            "capture reject: reason=capture-outside-displayed-map gcmi=%s mx=%.1f my=%.1f fw=%s fh=%s scale=%s wx=%.3f wy=%.3f zx=%s zy=%s",
            tostring(maI),
            tonumber(mx or 0) or 0,
            tonumber(my or 0) or 0,
            tostring(frameW),
            tostring(frameH),
            tostring(frameScale),
            tonumber(wx or 0) or 0,
            tonumber(wy or 0) or 0,
            tostring(zx),
            tostring(zy)
        ))
        return nil, "capture-outside-displayed-map"
    end

    if STATE.db and STATE.db.debug == true then
        dbg(format(
            "capture ok: gcmi=%s mx=%.1f my=%.1f fw=%s fh=%s scale=%s wx=%.3f wy=%.3f zx=%.1f zy=%.1f",
            tostring(maI),
            tonumber(mx or 0) or 0,
            tonumber(my or 0) or 0,
            tostring(frameW),
            tostring(frameH),
            tostring(frameScale),
            tonumber(wx or 0) or 0,
            tonumber(wy or 0) or 0,
            tonumber(zx or 0) or 0,
            tonumber(zy or 0) or 0
        ))
    end
    local name = map.ITN and map:ITN(maI) or ("Map " .. tostring(maI))

    return {
        maI = maI,
        wx = wx,
        wy = wy,
        zx = zx,
        zy = zy,
        mapName = name,
        ts = date("%Y-%m-%d %H:%M:%S"),
    }
end

local function BeginPendingTransport(reason, fromPos)
    if not fromPos or not fromPos.maI then return end

    if STATE.confirmationFrame and STATE.confirmationFrame.IsShown and STATE.confirmationFrame:IsShown() then
        return
    end

    local keySeedTo = GetPlayerWorldPos and GetPlayerWorldPos() or nil
    local key = nil
    if keySeedTo then
        key = BuildTransportConfirmationKey(fromPos, keySeedTo)
    end

    if key and STATE.activeConfirmationKey and STATE.activeConfirmationKey == key then
        return
    end

    if key and STATE.pendingTransportKey and STATE.pendingTransportKey == key then
        return
    end

    STATE.pendingTransport = {
        reason = reason or "unknown",
        from = CloneWorldPoint(fromPos),
        wait = 1.0,
        seenDifferentMap = false,
        startedAt = GetTime and GetTime() or 0,
    }
    STATE.pendingTransportKey = key
end

local function ShouldTreatAsTransportTransition(fromPos, toPos, reason)
    if not fromPos or not toPos then
        return false, "missing endpoints"
    end

    if not fromPos.maI or not toPos.maI then
        return false, "missing map ids"
    end

    -- Important: instance entrances may not always produce a useful map-id change.
    -- If we moved from non-instance world space into an instance, treat it as a
    -- transport transition so the confirmation popup can appear and the entrance
    -- can be saved as a known location.
    if toPos.instance and not fromPos.instance then
        return true, reason or "entered instance"
    end

    if fromPos.maI == toPos.maI then
        return false, "same map"
    end

    -- Check distance to avoid false positives at map borders
    if fromPos.wx and fromPos.wy and toPos.wx and toPos.wy then
        local dx = fromPos.wx - toPos.wx
        local dy = fromPos.wy - toPos.wy
        local dist = (dx * dx + dy * dy) ^ 0.5
        if dist < 50 then  -- 50 yards threshold
            return false, "too close (" .. string.format("%.1f", dist) .. " yards)"
        end
    end

    return true, reason or "map changed"
end

local function ShowTransportConfirmationFrame()
    if not STATE.pendingConfirmationTransport then return end

    if STATE.confirmationFrame and STATE.confirmationFrame:IsShown() then
        return
    end

    local f = CreateFrame("Frame", "CustomWaypointsTransportConfirmationFrame", UIParent)
    f:SetWidth(430)
    f:SetHeight(175)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    if f.EnableKeyboard then f:EnableKeyboard(false) end
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            local p2 = STATE.pendingConfirmationTransport
            if p2 then
                DismissConfirmationCandidate(p2.fromPos, p2.toPos, 30)
                MarkConfirmationRecentlyHandled(p2.fromPos, p2.toPos, 30)
                if p2.toPos and p2.toPos.instance and p2.toPos.maI then
                    STATE.lastStablePlayerPos = CloneWorldPoint(p2.toPos)
                end
            end
            STATE.pendingConfirmationTransport = nil
            ClearPendingTransport()
            self:Hide()
        end
    end)
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.9)

    local border = f:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    border:SetTexture(1, 1, 1, 0.2)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("Confirm Transport Discovery")

    local msg = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    msg:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -40)
    msg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 62)
    msg:SetJustifyH("LEFT")
    msg:SetJustifyV("TOP")

    local p = STATE.pendingConfirmationTransport
    STATE.activeConfirmationKey = BuildTransportConfirmationKey(p and p.fromPos, p and p.toPos)
    local fromName = p.fromPos.mapName or p.fromPos.maI
    local toName = p.toPos.mapName or p.toPos.zoneText or p.toPos.subZoneText or p.toPos.maI
    local text = "Save transport from " .. tostring(fromName) .. " to " .. tostring(toName) .. "?"
    if p.toPos.instance then
        text = text .. "\n\n|cffffcc00Instance detected:|r this will save only the entrance as a known location.\nIgnore this if you entered through Dungeon Finder / LFG."
    end
    msg:SetText(text)

    local disableDiscovery = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    disableDiscovery:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 46)
    disableDiscovery:SetChecked(false)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", disableDiscovery, "RIGHT", 2, 1)
    label:SetText("Don't ask again (disable AutoDiscovery)")

    local function ApplyPopupToggle()
        if disableDiscovery:GetChecked() then
            SetAutoDiscoveryEnabled(false)
        end
    end

    local yesBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    yesBtn:SetWidth(80)
    yesBtn:SetHeight(22)
    yesBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)
    yesBtn:SetText("Yes")
    yesBtn:SetScript("OnClick", function()
        local p2 = STATE.pendingConfirmationTransport
        if p2 and p2.toPos and p2.toPos.instance then
            SaveInstanceKnownLocation(p2.fromPos, p2.toPos)
            pr("saved instance entrance: " .. tostring(p2.toPos.zoneText or p2.toPos.mapName or p2.toPos.maI))
                elseif p2 then
            EnsureDb()
            local existingEdge = FindSimilarLearnedTransport(p2.fromPos, p2.toPos)
            if existingEdge then
                TouchLearnedTransport(existingEdge, p2.fromPos, p2.toPos)
            else
                local learned = EnsureTransportDb()
                learned[#learned + 1] = {
                    type = "portal",
                    label = tostring(p2.fromPos.mapName or p2.fromPos.maI) .. " -> " .. tostring(p2.toPos.mapName or p2.toPos.maI),
                    fromMaI = p2.fromPos.maI,
                    toMaI = p2.toPos.maI,
                    fromMapName = p2.fromPos.mapName,
                    toMapName = p2.toPos.mapName,
                    fromWx = p2.fromPos.wx,
                    fromWy = p2.fromPos.wy,
                    fromZx = p2.fromPos.zx,
                    fromZy = p2.fromPos.zy,
                    toWx = p2.toPos.wx,
                    toWy = p2.toPos.wy,
                    toZx = p2.toPos.zx,
                    toZy = p2.toPos.zy,
                    fromInstance = p2.fromPos.instance,
                    fromInstanceType = p2.fromPos.instanceType,
                    toInstance = p2.toPos.instance,
                    toInstanceType = p2.toPos.instanceType,
                    uses = 1,
                    discoveredBy = p2.reason or "transport-discovery",
                    lastSeen = time and time() or nil,
                }
            end

            pr("learned transport: " .. tostring(p2.fromPos.mapName or p2.fromPos.maI) .. " -> " .. tostring(p2.toPos.mapName or p2.toPos.maI))
        end

        if p2 then
            MarkConfirmationRecentlyHandled(p2.fromPos, p2.toPos, 10)
        end
        ApplyPopupToggle()
        STATE.pendingConfirmationTransport = nil
        ClearPendingTransport()
        f:Hide()
    end)

    local noBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    noBtn:SetWidth(80)
    noBtn:SetHeight(22)
    noBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
    noBtn:SetText("No")
    noBtn:SetScript("OnClick", function()
        local p2 = STATE.pendingConfirmationTransport
        if p2 then
            DismissConfirmationCandidate(p2.fromPos, p2.toPos, 30)
            MarkConfirmationRecentlyHandled(p2.fromPos, p2.toPos, 30)
            if p2.toPos and p2.toPos.instance and p2.toPos.maI then
                STATE.lastStablePlayerPos = CloneWorldPoint(p2.toPos)
            end
        end
        ApplyPopupToggle()
        STATE.pendingConfirmationTransport = nil
        ClearPendingTransport()
        f:Hide()
    end)

    f:SetScript("OnHide", function(self)
        if self.EnableKeyboard then self:EnableKeyboard(false) end
        STATE.confirmationFrame = nil
    end)

    if UISpecialFrames and not STATE.transportConfirmationSpecialRegistered then
        tinsert(UISpecialFrames, "CustomWaypointsTransportConfirmationFrame")
        STATE.transportConfirmationSpecialRegistered = true
    end

    f:SetScript("OnShow", function(self)
        PushCwModalFrame(self)
        if self.EnableKeyboard then self:EnableKeyboard(false) end
    end)

    local oldOnHide = f:GetScript("OnHide")
    f:SetScript("OnHide", function(self)
        local p2 = STATE.pendingConfirmationTransport
        if p2 then
            DismissConfirmationCandidate(p2.fromPos, p2.toPos, 12)
            MarkConfirmationRecentlyHandled(p2.fromPos, p2.toPos, 12)
            STATE.pendingConfirmationTransport = nil
        end
        RemoveCwModalFrame(self)
        STATE.activeConfirmationKey = nil
        ClearPendingTransport()
        if oldOnHide then oldOnHide(self) end
    end)

    STATE.confirmationFrame = f
    f:Show()
end

local function RequestLearnedTransportConfirmation(fromPos, toPos, reason)
    if not fromPos or not toPos then return end
    EnsureDb()

    if not IsAutoDiscoveryEnabled() then
        dbg("autodiscovery disabled: skipped transport discovery")
        return
    end

    if IsConfirmationDismissed(fromPos, toPos) then
        dbg("confirmation suppressed for recently dismissed transport/instance")
        return
    end

    if WasConfirmationRecentlyHandled(fromPos, toPos) then
        dbg("confirmation suppressed for recently handled transport/instance")
        return
    end

    local confirmationKey = BuildTransportConfirmationKey(fromPos, toPos)
    if confirmationKey and STATE.activeConfirmationKey and STATE.activeConfirmationKey == confirmationKey then
        dbg("confirmation suppressed: same confirmation already active")
        return
    end

    if toPos.instance then
        local existingInstance = FindSimilarKnownInstance(toPos)
        if existingInstance then
            dbg("duplicate instance entrance ignored: " .. tostring(existingInstance.name or toPos.zoneText or toPos.mapName or toPos.maI))
            return
        end
    else
        local existingEdge = FindSimilarLearnedTransport(fromPos, toPos)
        if existingEdge then
            TouchLearnedTransport(existingEdge, fromPos, toPos)
            dbg("duplicate learned transport ignored: " .. TransportLabel(existingEdge))
            return
        end
    end

    if STATE.db.transportConfirmationEnabled then
        STATE.pendingConfirmationTransport = { fromPos = fromPos, toPos = toPos, reason = reason }
        ShowTransportConfirmationFrame()
        return
    end

    if toPos.instance then
        SaveInstanceKnownLocation(fromPos, toPos)
        pr("saved instance entrance: " .. tostring(toPos.zoneText or toPos.mapName or toPos.maI))
        return
    end

    local learned = EnsureTransportDb()
    learned[#learned + 1] = {
        type = "portal",
        label = tostring(fromPos.mapName or fromPos.maI) .. " -> " .. tostring(toPos.mapName or toPos.maI),
        fromMaI = fromPos.maI,
        toMaI = toPos.maI,
        fromMapName = fromPos.mapName,
        toMapName = toPos.mapName,
        fromWx = fromPos.wx,
        fromWy = fromPos.wy,
        fromZx = fromPos.zx,
        fromZy = fromPos.zy,
        toWx = toPos.wx,
        toWy = toPos.wy,
        toZx = toPos.zx,
        toZy = toPos.zy,
        fromInstance = fromPos.instance,
        fromInstanceType = fromPos.instanceType,
        toInstance = toPos.instance,
        toInstanceType = toPos.instanceType,
        uses = 1,
        discoveredBy = reason or "transport-discovery",
        lastSeen = time and time() or nil,
    }

    pr("learned transport: " .. tostring(fromPos.mapName or fromPos.maI) .. " -> " .. tostring(toPos.mapName or toPos.maI))
end

local function InjectLearnedTransportEdges(addNode, addEdge, graph)
    local learned = EnsureTransportDb()
    if not learned or #learned == 0 then return end
    for _, edge in ipairs(learned) do
        if edge.fromMaI and edge.toMaI and edge.fromWx and edge.fromWy and edge.toWx and edge.toWy then
            local n1 = addNode(edge.fromMaI, edge.fromWx, edge.fromWy, edge.fromMapName or tostring(edge.fromMaI), "transport")
            local n2 = addNode(edge.toMaI, edge.toWx, edge.toWy, edge.toMapName or tostring(edge.toMaI), "transport")
            if graph.nodes[n1] then
                graph.nodes[n1].learnedPortalSource = true
                graph.nodes[n1].learnedPortalLabel = TransportLabel(edge)
            end
            if graph.nodes[n2] then
                graph.nodes[n2].learnedPortalDest = true
                graph.nodes[n2].learnedPortalLabel = TransportLabel(edge)
            end
            local hopCost = 22 - GetTransportPreferenceReductionSeconds(edge.type or "portal", true)
            if hopCost < 4 then hopCost = 4 end
            addEdge(n1, n2, hopCost, edge.type or "portal", TransportLabel(edge), false, { learnedHop = true })
            graph.links[#graph.links + 1] = { a = n1, b = n2, type = edge.type or "portal", learned = true }
        end
    end
end

local function ListLearnedTransports()
    local learned = EnsureTransportDb()
    if #learned == 0 then
        pr("learned transports: none")
        return
    end
    pr("learned transports: " .. tostring(#learned))
    for i, edge in ipairs(learned) do
        pr(format("%d) %s [uses=%d]", i, TransportLabel(edge), edge.uses or 1))
    end
end

local function ClearLearnedTransports()
    local learned = EnsureTransportDb()
    wipe(learned)
    InvalidateRoute("clear learned transports")
    pr("learned transports cleared")
end

local function PulseTransportDiscovery(elapsed)
    if not IsAutoDiscoveryEnabled() then return end
    
    local now = GetTime and GetTime() or 0
    if now < (STATE.lastTransportScan or 0) then
        STATE.lastTransportScan = 0
    end
    if now - (STATE.lastTransportScan or 0) < 0.05 then return end
    STATE.lastTransportScan = now

    local current = GetPlayerWorldPos()
    if STATE.pendingTransport then
        STATE.pendingTransport.wait = (STATE.pendingTransport.wait or 0) - (elapsed or 0)

        local enteredInstance = current and current.instance and not STATE.pendingTransport.from.instance
        local changedMap = current and current.maI ~= STATE.pendingTransport.from.maI

        if current and (changedMap or enteredInstance) then
            STATE.pendingTransport.seenDifferentMap = true
            if (STATE.pendingTransport.wait or 0) <= 0 then
                local shouldLearn, why = ShouldTreatAsTransportTransition(STATE.pendingTransport.from, current, STATE.pendingTransport.reason)
                if shouldLearn then
                    RequestLearnedTransportConfirmation(STATE.pendingTransport.from, current, STATE.pendingTransport.reason)
                else
                    dbg("ignored map hop: " .. tostring(why) .. " from=" .. tostring(STATE.pendingTransport.from.mapName) .. " to=" .. tostring(current.mapName))
                end
                if current and current.wx and current.wy then
                    STATE.lastStablePlayerPos = CloneWorldPoint(current)
                end
                ClearPendingTransport()
                return
            end
        elseif current and current.maI == STATE.pendingTransport.from.maI and not (current.instance and not STATE.pendingTransport.from.instance) then
            if (STATE.pendingTransport.wait or 0) <= -1.0 then
                ClearPendingTransport()
            end
        else
            if (STATE.pendingTransport.wait or 0) <= -1.5 then
                ClearPendingTransport()
            end
        end
    end

    if current then
        if STATE.lastStablePlayerPos and current.maI ~= STATE.lastStablePlayerPos.maI and not STATE.pendingTransport then
            BeginPendingTransport("implicit-map-change", STATE.lastStablePlayerPos)
            if STATE.pendingTransport then
                STATE.pendingTransport.wait = 0.1
                STATE.pendingTransport.seenDifferentMap = true

                if current and current.maI ~= STATE.pendingTransport.from.maI then
                    local shouldLearn, why = ShouldTreatAsTransportTransition(STATE.pendingTransport.from, current, STATE.pendingTransport.reason)
                    if shouldLearn then
                        RequestLearnedTransportConfirmation(STATE.pendingTransport.from, current, STATE.pendingTransport.reason)
                    else
                        dbg("ignored implicit map hop: " .. tostring(why) .. " from=" .. tostring(STATE.pendingTransport.from.mapName) .. " to=" .. tostring(current.mapName))
                    end
                    ClearPendingTransport()
                end
            end
        end
        if current and (current.maI or (current.wx and current.wy)) then
            STATE.lastStablePlayerPos = CloneWorldPoint(current)
        end
    end
end

local function SanitizeCarboniteLabel(s)
    if not s then return "" end
    s = tostring(s)
    s = s:gsub("[%%%^%$%(%)%.%[%]%*%+%-%?]", " ")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

local function UseStraightLineForEdge(edgeType)
    return edgeType and STRAIGHT_EDGE_TYPES[edgeType] or false
end

local function GetTargetTypeForRoutePoint(pt)
    if not pt then
        return TARGET_TYPE_GOTO
    end

    if pt.forceStraight then
        return TARGET_TYPE_STRAIGHT
    end

    if STATE.db and not STATE.db.simplifyTransitWaypoints then
        return TARGET_TYPE_STRAIGHT
    end

    if UseStraightLineForEdge(pt.edgeType) then
        return TARGET_TYPE_STRAIGHT
    end

    if STATE.db and STATE.db.hasFlyingMount then
        if pt.edgeType == "walk" or pt.edgeType == "connector" or pt.edgeType == "walklink" or pt.edgeType == "transport-to-goal" or pt.edgeType == "walk-to-transport" or pt.edgeType == "goal-to-node" then
            return TARGET_TYPE_STRAIGHT
        end

        if pt.isQueueStop then
            return TARGET_TYPE_STRAIGHT
        end
    end

    return TARGET_TYPE_GOTO
end

local function BuildSyncLabel(idx, pt)
    local mapName = pt.mapName or ("Map " .. tostring(pt.maI))
    local custom = pt.userLabel or pt.userName

    if custom and custom ~= "" then
        custom = SanitizeCarboniteLabel(custom)
        return SanitizeCarboniteLabel(format("%d %s - %s", idx, mapName, tostring(custom)))
    end

    local edgeType = pt.edgeType or "node"
    local detail

    if edgeType == "walk-to-transport" then
        detail = "Walk to transport"
    elseif edgeType == "transport-to-goal" then
        detail = "Walk to destination"
    elseif edgeType == "walk" then
        detail = "Walk"
    elseif edgeType == "connector" or edgeType == "walklink" then
        detail = "Passage"
    elseif edgeType == "tram" then
        detail = "Tram"
    elseif edgeType == "zeppelin" then
        detail = "Zeppelin"
    elseif edgeType == "boat" then
        detail = "Boat"
    elseif edgeType == "portal" then
        detail = "Portal"
    elseif edgeType == "transport" then
        detail = "Transport"
    elseif edgeType == "taxi" then
        detail = "Flight Master"
    elseif edgeType == "fallback" then
        detail = "Fallback"
    else
        detail = tostring(pt.label or edgeType)
    end

    return SanitizeCarboniteLabel(format("%d %s - %s", idx, mapName, detail))
end


local function InstallCarboniteSclGuard()
    if not Nx or not Nx.Map or type(Nx.Map.SCL) ~= "function" then return end

    local function SafeSCL(self, frm, lvl, seen)
        if not frm then return end
        lvl = lvl or 1
        if lvl > 120 then return end

        seen = seen or {}
        if seen[frm] then return end
        seen[frm] = true

        local ok, children = pcall(function()
            return { frm:GetChildren() }
        end)
        if not ok or type(children) ~= "table" then return end

        for _, chf in ipairs(children) do
            if chf and not seen[chf] then
                if chf.SetFrameLevel then
                    pcall(chf.SetFrameLevel, chf, lvl)
                end
                local okKids, nKids = pcall(function() return chf.GetNumChildren and chf:GetNumChildren() or 0 end)
                if okKids and nKids and nKids > 0 then
                    SafeSCL(self, chf, lvl + 1, seen)
                end
            end
        end
    end

    if not STATE.originalSCL then
        STATE.originalSCL = Nx.Map.SCL
    end
    Nx.Map.SCL = SafeSCL
    local map = GetMap()
    if map then
        map.SCL = SafeSCL
    end

    STATE.sclGuardInstalled = true
end

local function InstallCarboniteTravelHook()
    if STATE.travelHookInstalled then return end
    if not Nx or not Nx.Tra or type(Nx.Tra.MaP) ~= "function" then return end

    STATE.originalTravelMap = Nx.Tra.MaP
    Nx.Tra.MaP = function(self, tra2, sMI, srX, srY, dMI, dsX, dsY, taT1)
        if taT1 == TARGET_TYPE_STRAIGHT then
            return
        end
        return STATE.originalTravelMap(self, tra2, sMI, srX, srY, dMI, dsX, dsY, taT1)
    end

    STATE.travelHookInstalled = true
    dbg("Carbonite travel expansion hook installed")
end


local function RestoreSnapshot(snapshot, reason)
    if not snapshot or not STATE.db then return false end
    STATE.db.destinations = CloneDestinations(snapshot.destinations or {})
    InvalidateRoute(reason or snapshot.reason or "snapshot-restored")
    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    else
        ClearCarboniteTargets()
    end
    return true
end

-- Undo / redo use the same snapshot stack as add / clear / pop:
-- each action calls PushHistorySnapshot *before* changing destinations, so undo = restore previous queue.
UndoHistory = function()
    if not STATE.db then return end
    local hist = STATE.history or {}
    if #hist == 0 then
        -- After /reload, snapshots are gone but SavedVariables may still have a queue.
        -- First "nothing to undo" with a non-empty queue = clear all stops (redo can restore).
        local d = STATE.db.destinations
        if #(d or {}) == 0 then
            pr("undo: nothing to undo")
            return
        end
        STATE.future = STATE.future or {}
        STATE.future[#STATE.future + 1] = {
            reason = "redo-after-reload-clear",
            destinations = CloneDestinations(d),
        }
        wipe(d)
        InvalidateRoute("undo-fallback-clear-no-history")
        if STATE.db.autoSyncToCarbonite then
            SyncQueueToCarbonite()
        else
            ClearCarboniteTargets()
        end
        pr("undo: cleared queue (no session history — e.g. after /reload); use redo to restore")
        RefreshUiHeader()
        return
    end
    STATE.future = STATE.future or {}
    STATE.future[#STATE.future + 1] = {
        reason = "redo",
        destinations = CloneDestinations(STATE.db.destinations),
    }
    local snapshot = tremove(hist)
    RestoreSnapshot(snapshot, "undo")
    pr(format("undo: restored queue (%d stop(s))", #(STATE.db.destinations or {})))
    RefreshUiHeader()
end

RedoHistory = function()
    if not STATE.db then return end
    local fut = STATE.future or {}
    if #fut == 0 then
        pr("redo: nothing to redo")
        return
    end
    STATE.history = STATE.history or {}
    STATE.history[#STATE.history + 1] = {
        reason = "undo-after-redo",
        destinations = CloneDestinations(STATE.db.destinations),
    }
    local snapshot = tremove(fut)
    RestoreSnapshot(snapshot, "redo")
    pr(format("redo: restored queue (%d stop(s))", #(STATE.db.destinations or {})))
    RefreshUiHeader()
end

ClearCarboniteTargets = function(map)
    map = map or GetMap()
    if not map then return end

    STATE.suppressClearUntil = (GetTime() or 0) + 0.75

    STATE.syncing = true
    if map.ClT1 then
        map:ClT1()
    else
        map.Tar = {}
        map.Tra1 = {}
    end
    STATE.syncing = false

    if map.GOp then
        map.GOp["MapRouteUse"] = true
    end
end

InvalidateRoute = function(reason)
    STATE.expandedRoute = nil
    STATE.graph = nil
    if reason then
        dbg("route invalidated: " .. tostring(reason))
    end
end

local function InferTransportType(name1, name2)
    local s = lower((name1 or "") .. " " .. (name2 or ""))
    if match(s, "zeppelin") then return "zeppelin" end
    if match(s, "boat") then return "boat" end
    if match(s, "tram") then return "tram" end
    if match(s, "portal") then return "portal" end
    return "transport"
end

local function TransportCostSeconds(transportType, wx1, wy1, wx2, wy2)
    local travel = WalkCostSeconds(wx1, wy1, wx2, wy2)
    local base
    local tuning = GetRoutingTuning()

    if transportType == "portal" then
        -- Keep portal preference tuning-controlled; when portal bonus is zero,
        -- avoid a hidden always-cheap portal base.
        if (tuning.portalBonus or 0) <= 0 then
            base = 60 + travel * 0.3
        else
            base = 25
        end
    elseif transportType == "tram" then
        base = 45 + travel * 0.2
    elseif transportType == "zeppelin" then
        base = 75 + travel * 0.2
    elseif transportType == "boat" then
        base = 90 + travel * 0.2
    elseif transportType == "taxi" then
        base = 60 + travel * 0.3
    else
        base = 60 + travel * 0.3
    end

    local adjusted = base - GetTransportPreferenceReductionSeconds(transportType, false)

    if transportType == "portal" then
        if adjusted < 7 then adjusted = 7 end
    elseif transportType == "tram" then
        if adjusted < 18 then adjusted = 18 end
    elseif transportType == "zeppelin" or transportType == "boat" then
        if adjusted < 35 then adjusted = 35 end
    elseif transportType == "taxi" then
        if adjusted < 20 then adjusted = 20 end
    else
        if adjusted < 10 then adjusted = 10 end
    end

    return adjusted
end

local function IsRealTransportType(edgeType)
    return edgeType and STRAIGHT_EDGE_TYPES[edgeType] or false
end

local function IsTransitEdgeType(edgeType)
    return edgeType and TRANSIT_EDGE_TYPES[edgeType] or false
end

local function InferConnectorEdgeType(coT, name1, name2)
    if coT == 1 then
        return "connector"
    end
    return InferTransportType(name1, name2)
end

local function ConnectorCostSeconds(edgeType, wx1, wy1, wx2, wy2)
    if edgeType == "connector" then
        return WalkCostSeconds(wx1, wy1, wx2, wy2)
    end
    return TransportCostSeconds(edgeType, wx1, wy1, wx2, wy2)
end

local function NormalizeTaxiKey(name)
    if not name then return nil end
    name = tostring(name)
    name = gsub(name, "^%s+", "")
    name = gsub(name, "%s+$", "")
    return lower(name)
end

local function BuildKnownTaxiLookup()
    if not NxCData or type(NxCData["Taxi"]) ~= "table" then return {} end
    local out = {}
    for taxiName, known in pairs(NxCData["Taxi"]) do
        if known then
            out[NormalizeTaxiKey(taxiName)] = taxiName
        end
    end
    return out
end

local function BuildKnownTaxiNodes(map)
    if not (STATE.db and STATE.db.useFlightMasters) then return {} end
    if STATE.db and STATE.db.simplifyTransitWaypoints then return {} end
    if not Nx or not Nx.Tra then
        return {}
    end

    local knownLookup = BuildKnownTaxiLookup()

    local out = {}
    local seen = {}

    local function pushTaxiAny(taxiName, npcName, maI, wx, wy)
        local key = NormalizeTaxiKey(taxiName)
        if not key or seen[key] then return end
        if not (maI and wx and wy) then return end
        local ok, zx, zy = pcall(map.GZP, map, maI, wx, wy)
        if not (ok and zx and zy and zx >= 0 and zx <= 100 and zy >= 0 and zy <= 100) then return end

        seen[key] = true
        out[#out + 1] = {
            taxiName = taxiName,
            npcName = npcName or knownLookup[key] or taxiName,
            maI = maI,
            wx = wx,
            wy = wy,
            zx = zx,
            zy = zy,
        }
    end

    if type(Nx.Tra.Tra) == "table" then
        for _, list in pairs(Nx.Tra.Tra) do
            if type(list) == "table" then
                for _, nod in ipairs(list) do
                    if type(nod) == "table" and nod.LoN and nod.MaI and nod.WX and nod.WY then
                        pushTaxiAny(nod.LoN, nod.Nam or nod.LoN, nod.MaI, nod.WX, nod.WY)
                    end
                end
            end
        end
    end

    if Nx.Map and Nx.Map.Gui and type(Nx.Map.Gui.FiT2) == "function" and next(knownLookup) then
        for taxiKey, taxiName in pairs(knownLookup) do
            if not seen[taxiKey] then
                local npcName, wx, wy = Nx.Map.Gui:FiT2(taxiName)
                if wx and wy then
                    local bestMapId, bestDist2 = nil, nil
                    for maI = 1, 5000 do
                        local ok, zx, zy = pcall(map.GZP, map, maI, wx, wy)
                        if ok and zx and zy and zx >= 0 and zx <= 100 and zy >= 0 and zy <= 100 then
                            local dx = zx - 50
                            local dy = zy - 50
                            local dist2 = dx * dx + dy * dy
                            if not bestDist2 or dist2 < bestDist2 then
                                bestMapId, bestDist2 = maI, dist2
                            end
                        end
                    end
                    if bestMapId then
                        pushTaxiAny(taxiName, npcName or taxiName, bestMapId, wx, wy)
                    end
                end
            end
        end
    end

    return out
end

local function EnsureGraph()
    if STATE.graph then return STATE.graph end

    local map = GetMap()
    if not map or not Nx or not Nx.ZoC then
        return nil, "carbonite-data-not-ready"
    end

    local graph = {
        nodes = {},
        links = {},
        nodeCount = 0,
        edgeCount = 0,
    }

    local nodeIndex = {}

    local function makeNodeKey(maI, wx, wy, nodeType, label)
        return table.concat({ tostring(maI or "?"), format("%.3f", wx or 0), format("%.3f", wy or 0), tostring(nodeType or "?"), tostring(label or "") }, "|")
    end

    local function addNode(maI, wx, wy, label, nodeType)
        local key = makeNodeKey(maI, wx, wy, nodeType, label)
        if nodeIndex[key] then
            return nodeIndex[key]
        end

        graph.nodeCount = graph.nodeCount + 1
        local id = graph.nodeCount
        graph.nodes[id] = {
            id = id,
            maI = maI,
            wx = wx,
            wy = wy,
            label = label,
            type = nodeType,
            continent = nil,
            edges = {},
        }
        nodeIndex[key] = id
        return id
    end

    local function addEdge(a, b, cost, edgeType, label, bidirectional, opts)
        opts = opts or {}
        if not graph.nodes[a] or not graph.nodes[b] then return end
        tinsert(graph.nodes[a].edges, {
            to = b,
            cost = cost,
            type = edgeType,
            label = label,
            learnedHop = opts.learnedHop,
        })
        graph.edgeCount = graph.edgeCount + 1
        if bidirectional then
            tinsert(graph.nodes[b].edges, {
                to = a,
                cost = cost,
                type = edgeType,
                label = label,
                learnedHop = opts.learnedHop,
            })
            graph.edgeCount = graph.edgeCount + 1
        end
    end

    local function addPassageEdgesFromMWI()
        if not map.MWI then return end
        for maI, win1 in pairs(map.MWI) do
            if type(win1) == "table" and type(win1.Con1) == "table" then
                for destMaI, zco1 in pairs(win1.Con1) do
                    if type(zco1) == "table" then
                        for _, con in ipairs(zco1) do
                            if type(con) == "table" and con.StX and con.StY and con.EnX and con.EnY then
                                local fromName = map.ITN and map:ITN(con.SMI or maI) or tostring(con.SMI or maI)
                                local toName = map.ITN and map:ITN(con.EMI1 or destMaI) or tostring(con.EMI1 or destMaI)
                                local n1 = addNode(con.SMI or maI, con.StX, con.StY, fromName, "connector")
                                local n2 = addNode(con.EMI1 or destMaI, con.EnX, con.EnY, toName, "connector")
                                addEdge(n1, n2, con.Dis or WalkCostSeconds(con.StX, con.StY, con.EnX, con.EnY), "connector", format("Passage: %s -> %s", tostring(fromName), tostring(toName)), true)
                                graph.links[#graph.links + 1] = { a = n1, b = n2, type = "connector" }
                            end
                        end
                    end
                end
            end
        end
    end

    addPassageEdgesFromMWI()

    for _, str in ipairs(Nx.ZoC) do
        local fla, coT, mI1, x1, y1, mI2, x2, y2, na11, na21 = map:CoU(str)
        if mI1 and mI2 and x1 and y1 and x2 and y2 and x1 ~= 0 and y1 ~= 0 and x2 ~= 0 and y2 ~= 0 then
            local wx1, wy1 = map:GWP(mI1, x1, y1)
            local wx2, wy2 = map:GWP(mI2, x2, y2)
            local edgeType = InferConnectorEdgeType(coT, na11, na21)
            local fromName = (na11 and na11 ~= "") and na11 or (map.ITN and map:ITN(mI1) or tostring(mI1))
            local toName = (na21 and na21 ~= "") and na21 or (map.ITN and map:ITN(mI2) or tostring(mI2))
            local n1 = addNode(mI1, wx1, wy1, fromName, edgeType == "connector" and "connector" or "transport")
            local n2 = addNode(mI2, wx2, wy2, toName, edgeType == "connector" and "connector" or "transport")
            local bidi = band(fla or 0, 1) == 1
            local edgeLabel
            if edgeType == "connector" then
                edgeLabel = format("Walk connection: %s -> %s", tostring(map.ITN and map:ITN(mI1) or mI1), tostring(map.ITN and map:ITN(mI2) or mI2))
            else
                edgeLabel = (edgeType:gsub("^%l", string.upper)) .. ": " .. tostring(map.ITN and map:ITN(mI1) or mI1) .. " -> " .. tostring(map.ITN and map:ITN(mI2) or mI2)
            end
            addEdge(n1, n2, ConnectorCostSeconds(edgeType, wx1, wy1, wx2, wy2), edgeType, edgeLabel, bidi)
            graph.links[#graph.links + 1] = {a = n1, b = n2, type = edgeType}
        end
    end

    InjectLearnedTransportEdges(addNode, addEdge, graph)

    local taxiNodes = BuildKnownTaxiNodes(map)
    local taxiNodeIds = {}
    if #taxiNodes > 0 and Nx and Nx.Tra and type(Nx.Tra.TFCT) == "function" then
        for _, taxi in ipairs(taxiNodes) do
            local nodeId = addNode(taxi.maI, taxi.wx, taxi.wy, taxi.taxiName, "transport")
            taxiNodeIds[#taxiNodeIds + 1] = { id = nodeId, taxiName = taxi.taxiName, npcName = taxi.npcName, maI = taxi.maI, wx = taxi.wx, wy = taxi.wy }
        end

        local taxiKnown = BuildKnownTaxiLookup()
        local anyTaxiKnown = next(taxiKnown) and true or false
        for i = 1, #taxiNodeIds do
            local a = taxiNodeIds[i]
            for j = 1, #taxiNodeIds do
                if i ~= j then
                    local b = taxiNodeIds[j]
                    if anyTaxiKnown then
                        local ka = NormalizeTaxiKey(a.taxiName)
                        local kb = NormalizeTaxiKey(b.taxiName)
                        if not (ka and kb and (taxiKnown[ka] or taxiKnown[kb])) then
                            -- skip TFCT: avoids O(n^2) UI hitch; edges still added when one end is known
                        else
                            local ok, directCost = pcall(Nx.Tra.TFCT, Nx.Tra, a.taxiName, b.taxiName)
                            if ok and directCost and directCost > 0 then
                                addEdge(a.id, b.id, directCost, "taxi", format("Flight Master: %s -> %s", tostring(a.taxiName), tostring(b.taxiName)), false)
                                graph.links[#graph.links + 1] = {a = a.id, b = b.id, type = "taxi"}
                            end
                        end
                    end
                end
            end
        end

        for _, tinfo in ipairs(taxiNodeIds) do
            local gn = graph.nodes[tinfo.id]
            if gn then
                gn.taxiHub = true
            end
        end
    end

    local walkRadius = 320
    local walkNeighbors = 4
    local forcedWalkPenalty = 900
    local function IsTravelNodeType(t)
        return t == "connector" or t == "transport"
    end
    for i = 1, graph.nodeCount do
        local ni = graph.nodes[i]
        local sameMap = {}
        for j = 1, graph.nodeCount do
            if i ~= j then
                local nj = graph.nodes[j]
                if ni.maI == nj.maI then
                    local baseCost = WalkCostSeconds(ni.wx, ni.wy, nj.wx, nj.wy)
                    if baseCost <= walkRadius then
                        sameMap[#sameMap + 1] = { id = j, cost = math.max(1, baseCost), forced = false }
                    elseif IsTravelNodeType(ni.type) and IsTravelNodeType(nj.type) then
                        sameMap[#sameMap + 1] = { id = j, cost = baseCost + forcedWalkPenalty, forced = true }
                    end
                end
            end
        end
        table.sort(sameMap, function(a, b)
            return a.cost < b.cost
        end)
        local added = 0
        local forcedAdded = 0
        for _, cand in ipairs(sameMap) do
            if not cand.forced then
                if added < walkNeighbors then
                    addEdge(i, cand.id, cand.cost, "walk", "walk", false)
                    added = added + 1
                end
            elseif added == 0 and forcedAdded < 1 then
                addEdge(i, cand.id, cand.cost, "walk", "walk-penalized", false)
                forcedAdded = forcedAdded + 1
            end
        end
    end

    local function linkLearnedPortalSourcesToNearbyCarbonitePortals()
        local function hasWalkEdge(fromId, toId)
            for _, e in ipairs(graph.nodes[fromId].edges or {}) do
                if e.to == toId and e.type == "walk" then
                    return true
                end
            end
            return false
        end
        local maxWalkSec = 680
        for i = 1, graph.nodeCount do
            local n = graph.nodes[i]
            if n and n.learnedPortalSource then
                for j = 1, graph.nodeCount do
                    if i ~= j then
                        local m = graph.nodes[j]
                        if m and m.maI == n.maI and m.type == "transport" and not m.learnedPortalSource then
                            local hasPortal = false
                            for _, e in ipairs(m.edges or {}) do
                                if e.type == "portal" then
                                    hasPortal = true
                                    break
                                end
                            end
                            if hasPortal then
                                local sec = WalkCostSeconds(n.wx, n.wy, m.wx, m.wy)
                                if sec <= maxWalkSec then
                                    local c = math.max(1, sec)
                                    if not hasWalkEdge(i, j) then
                                        addEdge(i, j, c, "walk", "walk", false)
                                    end
                                    if not hasWalkEdge(j, i) then
                                        addEdge(j, i, c, "walk", "walk", false)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    linkLearnedPortalSourcesToNearbyCarbonitePortals()

    STATE.graph = graph
    return graph
end

-- Same as origin/master: h=0 => uniform-cost search (optimal for non-negative edge weights).
local function HeuristicCost()
    return 0
end

local function FindPathAStar(nodes, startId, goalId)
    local open = {[startId] = true}
    local openList = {startId}
    local came = {}
    local cameEdge = {}
    local gScore = {[startId] = 0}
    local fScore = {[startId] = HeuristicCost(nodes[startId], nodes[goalId])}
    local explored = 0

    while #openList > 0 do
        local bestIndex, current, bestF = 1, openList[1], fScore[openList[1]] or huge
        for i = 2, #openList do
            local nid = openList[i]
            local f = fScore[nid] or huge
            if f < bestF then
                bestIndex, current, bestF = i, nid, f
            end
        end

        tremove(openList, bestIndex)
        open[current] = nil
        explored = explored + 1

        if current == goalId then
            local path = {current}
            while came[current] do
                current = came[current]
                tinsert(path, 1, current)
            end
            return path, cameEdge, gScore[goalId] or 0, explored
        end

        local node = nodes[current]
        if node and node.edges then
            for _, edge in ipairs(node.edges) do
                local tentative = (gScore[current] or huge) + (edge.cost or huge)
                if tentative < (gScore[edge.to] or huge) then
                    came[edge.to] = current
                    cameEdge[edge.to] = edge
                    gScore[edge.to] = tentative
                    fScore[edge.to] = tentative + HeuristicCost(nodes[edge.to], nodes[goalId])
                    if not open[edge.to] then
                        open[edge.to] = true
                        tinsert(openList, edge.to)
                    end
                end
            end
        end
    end

    return nil, nil, nil, explored
end

-- Compare plain start->goal A* with "walk to learned source on start map + learned portal + tail":
-- guarantees /cw transports is chosen when total time is lower (Dijkstra alone can still prefer tram first hop).
local function FindBestPathWithOptionalLearnedPrefix(nodes, startId, goalId, startPoint, baseCount)
    local path0, ce0, cost0, ex0 = FindPathAStar(nodes, startId, goalId)
    if not path0 then
        return nil, nil, nil, ex0 or 0
    end
    local tuning = GetRoutingTuning()
    if (tuning.portalBonus or 0) <= 0 and (tuning.learnedPortalBonus or 0) <= 0 then
        return path0, ce0, cost0, ex0
    end
    local bestPath, bestCame, bestCost, bestEx = path0, ce0, cost0, ex0
    local sx, sy = nodes[startId].wx, nodes[startId].wy

    for nid = 1, baseCount do
        local nn = nodes[nid]
        if nn and nn.learnedPortalSource and nn.maI == startPoint.maI then
            local w0 = WalkCostSeconds(sx, sy, nn.wx, nn.wy)
            for _, ed in ipairs(nn.edges or {}) do
                if ed.learnedHop then
                    local p2, ce2, c2, ex2 = FindPathAStar(nodes, ed.to, goalId)
                    if p2 and c2 then
                        local total = w0 + (ed.cost or huge) + c2
                        if total < bestCost then
                            bestCost = total
                            bestEx = (ex0 or 0) + (ex2 or 0)
                            local merged = { startId, nid }
                            for k = 1, #p2 do
                                merged[#merged + 1] = p2[k]
                            end
                            local mce = {}
                            mce[nid] = {
                                to = nid,
                                cost = w0,
                                type = "walk",
                                label = "walk-to-node",
                            }
                            mce[ed.to] = ed
                            for k = 2, #p2 do
                                local vx = p2[k]
                                if ce2[vx] then
                                    mce[vx] = ce2[vx]
                                end
                            end
                            bestPath = merged
                            bestCame = mce
                        end
                    end
                end
            end
        end
    end

    return bestPath, bestCame, bestCost, bestEx
end

local function BuildTransportLeg(startPoint, destPoint)
    local baseGraph, why = EnsureGraph()
    if not baseGraph then
        return nil, "graph-unavailable:" .. tostring(why)
    end

    local nodes = {}
    local baseCount = baseGraph.nodeCount or 0
    for id = 1, baseCount do
        local n = baseGraph.nodes[id]
        if n then
            local copyEdges = {}
            for _, e in ipairs(n.edges) do
                copyEdges[#copyEdges + 1] = {
                    to = e.to,
                    cost = e.cost,
                    type = e.type,
                    label = e.label,
                    learnedHop = e.learnedHop,
                }
            end
            nodes[id] = {
                id = n.id,
                maI = n.maI,
                wx = n.wx,
                wy = n.wy,
                label = n.label,
                type = n.type,
                continent = n.continent,
                edges = copyEdges,
                learnedPortalSource = n.learnedPortalSource and true or false,
                learnedPortalDest = n.learnedPortalDest and true or false,
                learnedPortalLabel = n.learnedPortalLabel,
                taxiHub = n.taxiHub and true or false,
            }
        end
    end

    local nextId = baseCount

    local function addQueryNode(pt, nodeType, label)
        nextId = nextId + 1
        nodes[nextId] = {
            id = nextId,
            maI = pt.maI,
            wx = pt.wx,
            wy = pt.wy,
            label = label,
            type = nodeType,
            edges = {},
        }
        return nextId
    end

    local function connectBidirectional(a, b, cost, edgeType, label)
        tinsert(nodes[a].edges, {to = b, cost = cost, type = edgeType, label = label})
        tinsert(nodes[b].edges, {to = a, cost = cost, type = edgeType, label = label})
    end

       local function attachQueryNode(queryId, preferMapId, preferContinent, outwardLabel)
        local isStart = outwardLabel == "walk-to-node"
        local isGoal = outwardLabel == "node-to-goal"
        local tuning = GetRoutingTuning()

        local function countPortalTaxi(node)
            local pe, te = 0, 0
            if node and node.edges then
                for _, e in ipairs(node.edges) do
                    if e.type == "portal" then
                        pe = pe + 1
                    elseif e.type == "taxi" then
                        te = te + 1
                    end
                end
            end
            return pe, te
        end

        local sameMap = {}
        for id, n in pairs(nodes) do
            if type(id) == "number" and id ~= queryId and n.maI == preferMapId then
                local raw = WalkCostSeconds(nodes[queryId].wx, nodes[queryId].wy, n.wx, n.wy)
                local yards = WorldToYards(Dist(nodes[queryId].wx, nodes[queryId].wy, n.wx, n.wy))
                local pe, te = countPortalTaxi(n)

                local candidate = {
                    id = id,
                    rawCost = raw,
                    yards = yards,
                    learnedS = n.learnedPortalSource and true or false,
                    learnedD = n.learnedPortalDest and true or false,
                    taxiHub = n.taxiHub and true or false,
                    portalEdges = pe,
                    taxiEdges = te,
                }

                candidate.score = GetAttachCandidateScoreSeconds(raw, candidate, isStart, isGoal)
                sameMap[#sameMap + 1] = candidate
            end
        end

        -- If there are no nodes on the exact map (common for destination maps),
        -- fall back to same-continent candidates so portal/taxi legs can still connect.
        if #sameMap == 0 and preferContinent then
            for id, n in pairs(nodes) do
                if type(id) == "number" and id ~= queryId and n.continent == preferContinent then
                    local raw = WalkCostSeconds(nodes[queryId].wx, nodes[queryId].wy, n.wx, n.wy)
                    local yards = WorldToYards(Dist(nodes[queryId].wx, nodes[queryId].wy, n.wx, n.wy))
                    local pe, te = countPortalTaxi(n)
                    local candidate = {
                        id = id,
                        rawCost = raw,
                        yards = yards,
                        learnedS = n.learnedPortalSource and true or false,
                        learnedD = n.learnedPortalDest and true or false,
                        taxiHub = n.taxiHub and true or false,
                        portalEdges = pe,
                        taxiEdges = te,
                    }
                    candidate.score = GetAttachCandidateScoreSeconds(raw, candidate, isStart, isGoal)
                    sameMap[#sameMap + 1] = candidate
                end
            end
        end

        table.sort(sameMap, function(a, b)
            if a.score ~= b.score then return a.score < b.score end
            return a.rawCost < b.rawCost
        end)

        local limit = 16
        local attached = 0
        local used = {}

        -- Critical invariant:
        -- query-node attachment must stay cost-driven. Hard walk-distance
        -- gates can hide valid portal/taxi routes from the pathfinder and
        -- force cross-continent fallback even when a faster transport path
        -- exists. We still cap the number of local attachments for graph
        -- size, but candidate eligibility is determined by score/cost only.
        for _, c in ipairs(sameMap) do
            if attached >= limit then break end

            if c.rawCost <= 2200 and not used[c.id] then
                connectBidirectional(queryId, c.id, c.rawCost, "walk", outwardLabel)
                used[c.id] = true
                attached = attached + 1
            end
        end

        if attached == 0 then
            table.sort(sameMap, function(a, b)
                return a.rawCost < b.rawCost
            end)
            for i = 1, math.min(12, #sameMap) do
                local c = sameMap[i]
                if c and not used[c.id] then
                    connectBidirectional(queryId, c.id, c.rawCost, "walk", outwardLabel)
                    used[c.id] = true
                    attached = attached + 1
                end
            end
        end

        return attached
    end

    local startId = addQueryNode(startPoint, "start", "start")
    local goalId = addQueryNode(destPoint, "goal", "goal")

    attachQueryNode(startId, startPoint.maI, nodes[startId].continent, "walk-to-node")
    attachQueryNode(goalId, destPoint.maI, nodes[goalId].continent, "node-to-goal")

    local path, cameEdge, totalCost, explored = FindBestPathWithOptionalLearnedPrefix(nodes, startId, goalId, startPoint, baseCount)
    if not path then
        return nil, format("no-path explored=%d", explored or -1)
    end

    local route = {
        totalCost = totalCost,
        explored = explored,
        transportUsed = false,
        points = {},
    }

    local map = GetMap()
    for idx = 1, #path do
        local nodeId = path[idx]
        local n = nodes[nodeId]
        local edge = idx > 1 and cameEdge[nodeId] or nil
        if edge and IsRealTransportType(edge.type) then
            route.transportUsed = true
        end
        local zx, zy = map:GZP(n.maI, n.wx, n.wy)
        tinsert(route.points, {
            maI = n.maI,
            wx = n.wx,
            wy = n.wy,
            zx = zx,
            zy = zy,
            mapName = map.ITN and map:ITN(n.maI) or ("Map " .. tostring(n.maI)),
            edgeType = edge and edge.type or "start",
            label = edge and edge.label or n.label or n.type,
            cost = edge and edge.cost or 0,
        })
    end

    if STATE.db and STATE.db.simplifyTransitWaypoints then
        route.points = CollapseMinimalTransitNoise(route.points)
    end

    return route
end

local function BuildDirectFallbackLeg(startPoint, destPoint, why, crossContinent)
    local directCost = WalkCostSeconds(startPoint.wx, startPoint.wy, destPoint.wx, destPoint.wy)
    dbg("using explicit fallback target: " .. tostring(why))
    return {
        totalCost = directCost,
        explored = 1,
        fallbackDirect = true,
        points = {
            {
                maI = startPoint.maI,
                wx = startPoint.wx,
                wy = startPoint.wy,
                zx = startPoint.zx,
                zy = startPoint.zy,
                mapName = startPoint.mapName,
                edgeType = "start",
                label = "Start",
                cost = 0,
            },
            {
                maI = destPoint.maI,
                wx = destPoint.wx,
                wy = destPoint.wy,
                zx = destPoint.zx,
                zy = destPoint.zy,
                mapName = destPoint.mapName,
                edgeType = crossContinent and "fallback" or "walk",
                label = crossContinent and "Cross-continent fallback" or "Direct destination",
                cost = directCost,
                forceStraight = true,
            }
        },
    }
end

local function BuildRouteLeg(startPoint, destPoint)
    if not startPoint or not destPoint then
        return nil, "missing-leg-endpoint"
    end

    local map = GetMap()
    if not map then return nil, "no-map" end

    if startPoint.maI == destPoint.maI then
        local directCost = WalkCostSeconds(startPoint.wx, startPoint.wy, destPoint.wx, destPoint.wy)
        return {
            totalCost = directCost,
            explored = 1,
            points = {
                {
                    maI = startPoint.maI,
                    wx = startPoint.wx,
                    wy = startPoint.wy,
                    zx = startPoint.zx,
                    zy = startPoint.zy,
                    mapName = startPoint.mapName,
                    edgeType = "start",
                    label = "Start",
                    cost = 0,
                },
                {
                    maI = destPoint.maI,
                    wx = destPoint.wx,
                    wy = destPoint.wy,
                    zx = destPoint.zx,
                    zy = destPoint.zy,
                    mapName = destPoint.mapName,
                    edgeType = "walk",
                    label = "Walk",
                    cost = directCost,
                }
            },
        }
    end

    if STATE.db and STATE.db.useIntercontinentalRouting then
        local route, why = BuildTransportLeg(startPoint, destPoint)
        if route then
            return route
        end

        local startCont = startPoint.continent or nil
        local destCont = destPoint.continent or nil
        local crossContinent = startCont and destCont and startCont ~= destCont

        if crossContinent then
            return BuildDirectFallbackLeg(startPoint, destPoint, why, true)
        end

        if STATE.db and not STATE.db.simplifyTransitWaypoints then
            return nil, "deep-graph-failed:" .. tostring(why)
        end

        dbg("graph leg fallback to direct walk: " .. tostring(why))
    end

    local directCost = WalkCostSeconds(startPoint.wx, startPoint.wy, destPoint.wx, destPoint.wy)
    return {
        totalCost = directCost,
        explored = 1,
        fallbackDirect = startPoint.maI ~= destPoint.maI,
        points = {
            {
                maI = startPoint.maI,
                wx = startPoint.wx,
                wy = startPoint.wy,
                zx = startPoint.zx,
                zy = startPoint.zy,
                mapName = startPoint.mapName,
                edgeType = "start",
                label = "Start",
                cost = 0,
            },
            {
                maI = destPoint.maI,
                wx = destPoint.wx,
                wy = destPoint.wy,
                zx = destPoint.zx,
                zy = destPoint.zy,
                mapName = destPoint.mapName,
                edgeType = "walk",
                label = startPoint.maI ~= destPoint.maI and "Direct destination" or "Walk",
                cost = directCost,
                forceStraight = startPoint.maI ~= destPoint.maI,
            }
        },
    }
end

local function BuildExpandedRoute()
    local map = GetMap()
    if not map then return nil, "no-map" end

    if #STATE.db.destinations == 0 then
        STATE.expandedRoute = nil
        return {points = {}, summary = "empty"}
    end

    local current = GetPlayerWorldPos()
    if not current then return nil, "no-player-pos" end

    local route = {
        totalCost = 0,
        explored = 0,
        points = {},
    }

    for q = 1, #STATE.db.destinations do
        local dest = STATE.db.destinations[q]
        local leg, why = BuildRouteLeg(current, dest)
        if not leg then
            return nil, format("leg %d failed: %s", q, tostring(why))
        end

        route.totalCost = route.totalCost + (leg.totalCost or 0)
        route.explored = route.explored + (leg.explored or 0)

        for i, pt in ipairs(leg.points or {}) do
            if not (q > 1 and i == 1) then
                local copy = {}
                for k, v in pairs(pt) do
                    copy[k] = v
                end

                if i == #leg.points then
                    copy.isQueueStop = true
                    copy.queueIndex = q

                    -- Preserve user-facing metadata from the original queue destination
                    -- so Carbonite hover/sync labels can prefer the custom label instead of
                    -- falling back to edge-type text like "Walk".
                    copy.userLabel = dest.userLabel or copy.userLabel
                    copy.userName = dest.userName or copy.userName
                    copy.description = dest.description or copy.description
                    copy.label = dest.userLabel or dest.userName or dest.label or copy.label
                end

                tinsert(route.points, copy)
            end
        end

        current = dest
    end

    STATE.expandedRoute = route
    return route
end

local function IsSyncAnchorPoint(routePoints, idx)
    local pt = routePoints[idx]
    if not pt or pt.edgeType == "start" then return false end

    local nextPt = routePoints[idx + 1]

    if idx == #routePoints then return true end
    if pt.isQueueStop then return true end
    if pt.forceStraight then return true end

    if IsTransitEdgeType(pt.edgeType) then return true end
    if nextPt and IsTransitEdgeType(nextPt.edgeType) then return true end

    return false
end

local function ShouldKeepRoutePointForSync(routePoints, idx)
    local pt = routePoints[idx]
    if not pt or pt.edgeType == "start" then return false end

    local prev = routePoints[idx - 1]
    local nextPt = routePoints[idx + 1]

    if not STATE.db or not STATE.db.simplifyTransitWaypoints then
        return true
    end

    return IsSyncAnchorPoint(routePoints, idx)
end

local function CollapseConsecutiveSyncPoints(points)
    local out = {}
    for _, pt in ipairs(points or {}) do
        local prev = out[#out]
        local keep = true
        if prev and prev.maI == pt.maI then
            local d = Dist(prev.wx or 0, prev.wy or 0, pt.wx or 0, pt.wy or 0)
            if d < 3 then
                keep = false
            elseif prev.edgeType == pt.edgeType and d < 2 then
                keep = false
            end
        end
        if keep then
            out[#out + 1] = pt
        end
    end
    return out
end

local function BuildSyncPoints(routePoints)
    local out = {}
    for i = 1, #(routePoints or {}) do
        if ShouldKeepRoutePointForSync(routePoints, i) then
            out[#out + 1] = routePoints[i]
        end
    end
    return CollapseConsecutiveSyncPoints(out)
end

SyncQueueToCarbonite = function()
    local map = GetMap()
    if not map then
        pr("sync failed: Carbonite map not ready")
        return false
    end

    local route, why = BuildExpandedRoute()
    if not route then
        pr("route rebuild failed: " .. tostring(why))
        return false
    end

    InstallCarboniteTravelHook()
    ClearCarboniteTargets(map)

    local syncPoints = BuildSyncPoints(route.points or {})
    local synced = 0
    STATE.syncing = true
    for i, pt in ipairs(syncPoints) do
        local ok, err = pcall(function()
            local label = BuildSyncLabel(i, pt)
            local targetType = GetTargetTypeForRoutePoint(pt)
            map:SeT3(targetType, pt.wx, pt.wy, pt.wx, pt.wy, nil, nil, label, true, pt.maI)
        end)
        if ok then
            synced = synced + 1
        else
            dbg("sync point failed: " .. tostring(err))
        end
    end
    STATE.syncing = false
    STATE.suppressClearUntil = (GetTime() or 0) + 0.75

    if synced == 0 then
        dbg("sync skipped: no route points")
        return true
    end

    dbg(format("synced %d expanded route node(s) into Carbonite", synced))
    return true
end

local function AddCurrentCursorWaypoint()
    local map = GetMap()
    local dest, why = GetDisplayedCapture(map)
    if not dest then
        pr("capture failed: " .. tostring(why))
        return
    end

    local wasEmpty = #(STATE.db.destinations or {}) == 0
    PushHistorySnapshot("add-waypoint")
    STATE.lastCaptureTime = GetTime() or 0
    tinsert(STATE.db.destinations, dest)
    HandleQueueBecameNonEmpty("add-waypoint", wasEmpty)
    dbg(format("saved #%d => GCMI=%d (%s) zx=%.1f zy=%.1f wx=%.3f wy=%.3f",
        #STATE.db.destinations, dest.maI, dest.mapName or "?", dest.zx or -1, dest.zy or -1, dest.wx or -1, dest.wy or -1))

    InvalidateRoute("waypoint added")
    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end
end

local function BuildDefaultWaypointName(dest)
    if not dest then return "" end
    return tostring(dest.mapName or ("Map " .. tostring(dest.maI or "?")))
end

AddLabeledCurrentCursorWaypoint = function()
    local map = GetMap()
    local dest, why = GetDisplayedCapture(map)
    if not dest then
        pr("capture failed: " .. tostring(why))
        return
    end

    ShowWaypointMetadataPopup({
        title = "Save captured waypoint",
        defaultName = BuildDefaultWaypointName(dest),
        defaultLabel = "wp",
        defaultDescription = "",
        onSave = function(meta)
            local wasEmpty = #(STATE.db.destinations or {}) == 0
            PushHistorySnapshot("add-labeled-waypoint")
            STATE.lastCaptureTime = GetTime() or 0
            dest.userName = meta.name ~= "" and meta.name or nil
            dest.userLabel = meta.label ~= "" and meta.label or nil
            dest.description = meta.description ~= "" and meta.description or nil
            tinsert(STATE.db.destinations, dest)
            HandleQueueBecameNonEmpty("add-labeled-waypoint", wasEmpty)
            InvalidateRoute("labeled waypoint added")
            RefreshUiHeader()
            if STATE.db.autoSyncToCarbonite then
                SyncQueueToCarbonite()
            end
            pr("saved labeled waypoint: " .. tostring(dest.userName or dest.mapName or dest.maI))
        end
    })
end

AddCurrentLocationWaypoint = function()
    local dest = GetPlayerWorldPos()
    if not dest then
        pr("savehere failed: no player position")
        return
    end

    if not dest.wx or not dest.wy then
        pr("savehere failed: current location has no world coordinates")
        return
    end

    local wasEmpty = #(STATE.db.destinations or {}) == 0
    PushHistorySnapshot("add-current-location-waypoint")
    STATE.lastCaptureTime = GetTime() or 0
    dest.userLabel = dest.userLabel or "wp"
    dest.ts = date("%Y-%m-%d %H:%M:%S")
    tinsert(STATE.db.destinations, dest)
    HandleQueueBecameNonEmpty("add-current-location-waypoint", wasEmpty)
    InvalidateRoute("current location waypoint added")
    RefreshUiHeader()
    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end
    pr("saved current-location waypoint: " .. tostring(dest.userName or dest.mapName or dest.maI))
end

AddCurrentLocationWithMetadataPopup = function()
    local dest = GetPlayerWorldPos()
    if not dest then
        pr("savehere failed: no player position")
        return
    end

    if not dest.wx or not dest.wy then
        pr("savehere failed: current location has no world coordinates")
        return
    end

    ShowWaypointMetadataPopup({
        title = "Save current location as waypoint",
        defaultName = BuildDefaultWaypointName(dest),
        defaultLabel = "wp",
        defaultDescription = "",
        onSave = function(meta)
            local wasEmpty = #(STATE.db.destinations or {}) == 0
            PushHistorySnapshot("add-current-location-waypoint")
            STATE.lastCaptureTime = GetTime() or 0
            dest.userName = meta.name ~= "" and meta.name or nil
            dest.userLabel = meta.label ~= "" and meta.label or nil
            dest.description = meta.description ~= "" and meta.description or nil
            dest.ts = date("%Y-%m-%d %H:%M:%S")
            tinsert(STATE.db.destinations, dest)
            HandleQueueBecameNonEmpty("add-current-location-waypoint", wasEmpty)
            InvalidateRoute("current location waypoint added")
            RefreshUiHeader()
            if STATE.db.autoSyncToCarbonite then
                SyncQueueToCarbonite()
            end
            pr("saved current-location waypoint: " .. tostring(dest.userName or dest.mapName or dest.maI))
        end
    })
end

local function ListWaypoints()
    if #STATE.db.destinations == 0 then
        pr("queue empty")
        return
    end
    for i, dest in ipairs(STATE.db.destinations) do
        pr(format("%d) %s | maI=%d | zx=%.1f zy=%.1f | wx=%.3f wy=%.3f | name=%s | label=%s | ts=%s",
            i,
            dest.mapName or ("Map " .. tostring(dest.maI)),
            dest.maI or -1,
            dest.zx or -1,
            dest.zy or -1,
            dest.wx or -1,
            dest.wy or -1,
            tostring(dest.userName or "-"),
            tostring(dest.userLabel or "-"),
            dest.ts or "?"
        ))
    end
end

local function ExportWaypoints()
    local n = #STATE.db.destinations
    if n == 0 then
        pr("export: queue empty")
        return
    end
    local lines = {}
    lines[#lines + 1] = "----- COPY FROM HERE -----"
    for i, dest in ipairs(STATE.db.destinations) do
        local pname = dest.mapName or "?"
        pname = gsub(pname, "|", "/")
        lines[#lines + 1] = format("%d|%d|%s|%.3f|%.3f|%.6f|%.6f|%s|%s|%s",
            i,
            dest.maI or -1,
            pname,
            dest.zx or -1,
            dest.zy or -1,
            dest.wx or -1,
            dest.wy or -1,
            dest.ts or "?",
            gsub(tostring(dest.userName or "?"), "|", "/"),
            gsub(tostring(dest.userLabel or "?"), "|", "/")
        )
    end
    lines[#lines + 1] = "----- COPY TO HERE -----"
    local blob = table.concat(lines, "\n")
    AppendUiLogLine(blob)
    dbg(blob)
    pr(format("export: %d waypoint(s) in block (%d data lines). Select all in CW log, copy, paste into Import.", n, n))
    for i = 1, n do
        dbg(lines[1 + i])
    end
end

-- Export persistent known locations as a portable union/dedup import block.
ExportKnownLocations = function()
    EnsureDb()
    local known = STATE.db.knownLocations or {}
    local learned = EnsureTransportDb() or {}

    if #known == 0 and #learned == 0 then
        pr("known locations export: empty")
        return
    end

    local lines = {}
    lines[#lines + 1] = "----- COPY KNOWN LOCATIONS FROM HERE -----"

    for _, loc in ipairs(known) do
        lines[#lines + 1] = BuildKnownLocationExportHeader(loc)
        if loc.kind == "route" then
            for i, pt in ipairs(loc.routePoints or {}) do
                lines[#lines + 1] = SerializeWaypointLine(i, pt)
            end
        else
            local dest = loc.destination or loc.lastTarget or loc.previousTarget
            if dest then
                lines[#lines + 1] = SerializeWaypointLine(1, dest)
            end
        end
    end

    for _, edge in ipairs(learned) do
        lines[#lines + 1] = BuildLearnedTransportExportHeader(edge)
        lines[#lines + 1] = SerializeLearnedTransportLine(edge)
    end

    lines[#lines + 1] = "----- COPY KNOWN LOCATIONS TO HERE -----"

    local blob = table.concat(lines, "\n")
    local displayBlob = EscapeForDisplay(blob)

    pr("----- COPY KNOWN LOCATIONS FROM HERE -----")
    AppendUiLogLine(displayBlob)
    pr("----- COPY KNOWN LOCATIONS TO HERE -----")
    dbg(displayBlob)
    pr(format("known locations export: %d known location(s), %d transport(s)", #known, #learned))
end

SplitExportFields = function(line)
    local parts = {}
    local s = tostring(line or "")
    local start = 1
    local len = #s

    while true do
        local bar = string.find(s, "|", start, true)
        if not bar then
            parts[#parts + 1] = string.sub(s, start)
            break
        end

        parts[#parts + 1] = string.sub(s, start, bar - 1)
        start = bar + 1

        if start > len then
            parts[#parts + 1] = ""
            break
        end
    end

    return parts
end

local function TrimField(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Paste from Notepad/browser may add UTF-8 BOM; breaks ^%d+ match and tonumber(idx/maI).
local function StripLeadingBomAndBidi(s)
    if type(s) ~= "string" or s == "" then return s end
    while true do
        if #s >= 3 and string.sub(s, 1, 3) == "\239\187\191" then
            s = string.sub(s, 4)
        else
            break
        end
    end
    return s
end

local function ToNumberField(s)
    if s == nil then return nil end
    s = StripLeadingBomAndBidi(TrimField(tostring(s)))
    if s == "" then return nil end
    s = gsub(s, "\194\160", "")
    s = gsub(s, "\226\128\139", "")
    s = gsub(s, "\226\128\140", "")
    s = gsub(s, "\226\128\141", "")
    s = gsub(s, ",", ".")
    s = gsub(gsub(s, "^%s+", ""), "%s+$", "")
    local num = tonumber(s)
    if num ~= nil then return num end
    if string.find(s, "%s") then
        return nil
    end
    local a, b = string.find(s, "%-?%d+%.?%d*")
    if a and b then
        num = tonumber(string.sub(s, a, b))
        if num ~= nil then return num end
    end
    a, b = string.find(s, "%-?%.%d+")
    if a and b then
        num = tonumber(string.sub(s, a, b))
        if num ~= nil then return num end
    end
    return nil
end

-- Split pasted blob into lines (handles missing final newline, \r, embedded NUL).
SplitLines = function(raw)
    local out = {}
    raw = gsub(gsub(gsub(tostring(raw or ""), "\r\n", "\n"), "\r", "\n"), "\0", "")
    raw = StripLeadingBomAndBidi(raw)
    local i, len = 1, #raw
    while i <= len do
        local j = string.find(raw, "\n", i, true)
        if not j then
            out[#out + 1] = string.sub(raw, i)
            break
        end
        out[#out + 1] = string.sub(raw, i, j - 1)
        i = j + 1
    end
    return out
end

NormalizeImportLine = function(line)
    if type(line) ~= "string" then return "" end
    line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
    line = StripLeadingBomAndBidi(line)
    line = line:gsub("\239\189\156", "|")
    if line == "" then return line end

    while true do
        local s, e = string.find(line, "^|c%x%x%x%x%x%x%x%x.-|r%s*", 1)
        if not s then break end
        line = string.sub(line, e + 1):gsub("^%s+", "")
    end

    if not string.match(line, "^%d+|%d+|") and not string.match(line, "^CWKNOWN|") and not string.match(line, "^T|") then
        local prefix, rest = string.match(line, "^([^|]-):%s*(.+)$")
        if prefix and rest and not string.find(prefix, "|", 1, true) and #prefix < 64 and #prefix > 0 then
            line = rest:gsub("^%s+", ""):gsub("%s+$", "")
        end
    end

    return line
end

ParseExportLine = function(line)
    if type(line) ~= "string" then return nil, "notstring" end
    line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
    line = StripLeadingBomAndBidi(line)
    if line == "" then return nil, "empty" end
    if string.find(line, "COPY FROM HERE", 1, true) or string.find(line, "COPY TO HERE", 1, true) then
        return nil, "marker"
    end
    line = NormalizeImportLine(line)
    if line == "" then return nil, "empty" end
    local parts = SplitExportFields(line)
    for i = 1, #parts do
        parts[i] = StripLeadingBomAndBidi(TrimField(parts[i]))
    end
    local n = #parts
    if n < 7 then return nil, format("short(n=%d)", n) end
    local idx = ToNumberField(parts[1])
    local maI = ToNumberField(parts[2])
    if idx == nil or maI == nil then
        return nil, format("badidx(%s,%s)", tostring(parts[1]), tostring(parts[2]))
    end

    -- 7 fields: index|maI|mapName|zx|zy|wx|wy (timestamp optional from export)
    if n == 7 then
        local mapName = parts[3]
        local zx = ToNumberField(parts[4])
        local zy = ToNumberField(parts[5])
        local wx = ToNumberField(parts[6])
        local wy = ToNumberField(parts[7])
        if zx == nil or zy == nil or wx == nil or wy == nil then
            return nil, format("badpos7 zx=%s zy=%s wx=%s wy=%s", tostring(zx), tostring(zy), tostring(wx), tostring(wy))
        end
        if mapName == "" or mapName == "?" then
            mapName = nil
        end
        return {
            _importOrder = idx,
            maI = maI,
            mapName = mapName,
            zx = zx,
            zy = zy,
            wx = wx,
            wy = wy,
            ts = nil,
        }
    end

    local ts = parts[n]
    local userLabel, userName, ts
    local wx, wy, zx, zy

    if n >= 10 then
        userLabel = parts[n]
        userName = parts[n - 1]
        ts = parts[n - 2]
        wy = ToNumberField(parts[n - 3])
        wx = ToNumberField(parts[n - 4])
        zy = ToNumberField(parts[n - 5])
        zx = ToNumberField(parts[n - 6])
    else
        ts = parts[n]
        wy = ToNumberField(parts[n - 1])
        wx = ToNumberField(parts[n - 2])
        zy = ToNumberField(parts[n - 3])
        zx = ToNumberField(parts[n - 4])
    end

    if zx == nil or zy == nil or wx == nil or wy == nil then
        return nil, format("badposN n=%d zx=%s zy=%s wx=%s wy=%s", n, tostring(zx), tostring(zy), tostring(wx), tostring(wy))
    end

    local nameEnd = (n >= 10) and (n - 7) or (n - 5)
    local nameChunks = {}
    for p = 3, nameEnd do
        nameChunks[#nameChunks + 1] = parts[p]
    end
    local mapName = table.concat(nameChunks, "|")
    if mapName == "" or mapName == "?" then
        mapName = nil
    end

    return {
        _importOrder = idx,
        maI = maI,
        mapName = mapName,
        zx = zx,
        zy = zy,
        wx = wx,
        wy = wy,
        ts = (ts and ts ~= "" and ts ~= "?") and ts or nil,
        userName = (userName and userName ~= "" and userName ~= "?") and userName or nil,
        userLabel = (userLabel and userLabel ~= "" and userLabel ~= "?") and userLabel or nil,
    }
end

ImportWaypointsFromText = function(text)
    EnsureDb()
    if not STATE.db then return end
    text = gsub(tostring(text or ""), "\0", "")
    text = StripLeadingBomAndBidi(text)
    if text:match("^%s*$") then
        pr("import: paste text from /cw export into the Import box (or /cw import <one line>).")
        return
    end
    local parsed = {}
    local bad = 0
    local lines = SplitLines(text)
    for _, line in ipairs(lines) do
        local dest, why = ParseExportLine(line)
        if dest then
            parsed[#parsed + 1] = dest
        elseif why and why ~= "empty" and why ~= "marker" then
            bad = bad + 1
        end
    end
    if #parsed == 0 then
        for _, L in ipairs(lines) do
            if string.find(L, "|", 1, true) and string.find(L, "%S")
                and not string.find(L, "COPY FROM HERE", 1, true)
                and not string.find(L, "COPY TO HERE", 1, true) then
                local _, why = ParseExportLine(L)
                local sample = string.sub(L, 1, 120)
                pr("import: rejected (" .. tostring(why or "?") .. "): " .. sample .. (#L > 120 and " …" or ""))
                dbg("import full line bytes=" .. tostring(#L) .. " : " .. L)
                break
            end
        end
        pr("import: no valid rows — paste full block from CW log (every queue row is one line).")
        return
    end
    table.sort(parsed, function(a, b)
        return (a._importOrder or 0) < (b._importOrder or 0)
    end)
    local wasEmpty = #(STATE.db.destinations or {}) == 0
    PushHistorySnapshot("import-waypoints")
    wipe(STATE.db.destinations)
    for _, d in ipairs(parsed) do
        d._importOrder = nil
        tinsert(STATE.db.destinations, d)
    end
    HandleQueueBecameNonEmpty("import-waypoints", wasEmpty)
    InvalidateRoute("import-waypoints")
    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    else
        ClearCarboniteTargets()
    end
    if bad > 0 then
        pr(format("import: loaded %d waypoint(s), skipped %d bad line(s)", #parsed, bad))
    else
        pr(format("import: loaded %d waypoint(s)", #parsed))
    end
end

local function EnsurePopupEsc(frameName)
    if UISpecialFrames then
        local exists = false
        for _, v in ipairs(UISpecialFrames) do
            if v == frameName then
                exists = true
                break
            end
        end
        if not exists then
            tinsert(UISpecialFrames, frameName)
        end
    end
end

ImportKnownLocationsFromText = function(text)
    EnsureDb()
    if not STATE.db then return end
    text = gsub(tostring(text or ""), "\0", "")
    text = UnescapeFromDisplay(text)
    text = StripLeadingBomAndBidi(text)
    if text:match("^%s*$") then
        pr("known locations import: paste a Known Locations export block first")
        return
    end

    local imported = {}
    local importedTransports = {}
    local pendingHeader = nil
    local pendingRoutePoints = {}
    local bad = 0

    local function flushPending()
        if not pendingHeader then return end
        if pendingHeader.kind == "transport" then
            if #pendingRoutePoints == 1 and pendingRoutePoints[1]._transportEdge then
                importedTransports[#importedTransports + 1] = pendingRoutePoints[1]._transportEdge
            else
                bad = bad + 1
                dbg("known locations import rejected: transport-empty")
            end
        else
            local loc, why = FinalizeImportedKnownLocation(pendingHeader, pendingRoutePoints)
            if loc then
                imported[#imported + 1] = loc
            else
                bad = bad + 1
                dbg("known locations import rejected: " .. tostring(why or "?"))
            end
        end
        pendingHeader = nil
        pendingRoutePoints = {}
    end

    for _, rawLine in ipairs(SplitLines(text)) do
        local line = NormalizeImportLine(rawLine)
        local header = ParseKnownLocationHeader(line)
        if line == "" or string.find(line, "COPY KNOWN LOCATIONS", 1, true) then
            -- skip
        elseif header then
            flushPending()
            pendingHeader = header
        elseif pendingHeader and pendingHeader.kind == "transport" then
            local edge, why = ParseLearnedTransportLine(line)
            if edge then
                pendingRoutePoints[#pendingRoutePoints + 1] = { _transportEdge = edge }
            elseif why and why ~= "empty" and why ~= "marker" then
                bad = bad + 1
            end
        else
            local dest, why = ParseExportLine(line)
            if dest and pendingHeader then
                dest._importOrder = nil
                pendingRoutePoints[#pendingRoutePoints + 1] = dest
            elseif why and why ~= "empty" and why ~= "marker" then
                bad = bad + 1
            end
        end
    end
    flushPending()

    if #imported == 0 and #importedTransports == 0 then
        pr("known locations import: no valid entries found")
        return
    end

    local merged = {}
    for _, loc in ipairs(STATE.db.knownLocations or {}) do
        merged[#merged + 1] = CloneDestination(loc)
    end
    for _, loc in ipairs(imported) do
        merged[#merged + 1] = loc
    end

    PushHistorySnapshot("import-known-locations")
    STATE.db.knownLocations = DeduplicateKnownLocationsPreserveOrder(merged)

    local learned = EnsureTransportDb()
    for _, edge in ipairs(importedTransports) do
        learned[#learned + 1] = edge
    end
    CompactLearnedTransports()

    RefreshKnownLocationsFrame()
    InvalidateRoute("known locations import")

    if bad > 0 then
        pr(format("known locations import: merged %d known location(s) and %d transport(s), skipped %d bad line(s)", #imported, #importedTransports, bad))
    else
        pr(format("known locations import: merged %d known location(s) and %d transport(s)", #imported, #importedTransports))
    end
end

ShowWaypointMetadataPopup = function(opts)
    opts = opts or {}
    local frameName = "CustomWaypointsWaypointMetadataPopup"

    local popup = STATE.waypointMetadataPopup
    if popup and popup.frame then
        local f = popup.frame
        if popup.title and popup.title.SetText then
            popup.title:SetText(opts.title or "Waypoint details")
        end
        if popup.nameBox and popup.nameBox.SetText then
            popup.nameBox:Show()
            popup.nameBox:SetText(opts.defaultName or "")
        end
        if popup.labelBox and popup.labelBox.SetText then
            popup.labelBox:Show()
            popup.labelBox:SetText(opts.defaultLabel or "")
        end
        if popup.descBox and popup.descBox.SetText then
            popup.descBox:Show()
            popup.descBox:SetText(opts.defaultDescription or "")
        end
        popup.onSave = opts.onSave
        if popup.descBg and popup.descBg.Show then popup.descBg:Show() end
        f:Show()
        if popup.nameBox and popup.nameBox.SetFocus then
            popup.nameBox:SetFocus()
        end
        return
    end

    local f = CreateFrame("Frame", frameName, UIParent)
    f:SetWidth(430)
    f:SetHeight(245)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(95)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    if f.EnableKeyboard then f:EnableKeyboard(false) end
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
        end
    end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.9)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\DialogFrame\UI-DialogBox-Background",
            edgeFile = "Interface\Tooltips\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText(opts.title or "Waypoint details")

    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -42)
    nameLabel:SetText("Name")

    local nameBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    nameBox:SetAutoFocus(false)
    nameBox:SetWidth(250)
    nameBox:SetHeight(20)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
    nameBox:SetText(opts.defaultName or "")

    local labelLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    labelLabel:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -22)
    labelLabel:SetText("Label")

    local labelBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    labelBox:SetAutoFocus(false)
    labelBox:SetWidth(250)
    labelBox:SetHeight(20)
    labelBox:SetPoint("LEFT", labelLabel, "RIGHT", 10, 0)
    labelBox:SetText(opts.defaultLabel or "")

    local descLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    descLabel:SetPoint("TOPLEFT", labelLabel, "BOTTOMLEFT", 0, -22)
    descLabel:SetText("Description")

    local descBox = CreateFrame("EditBox", nil, f)
    descBox:SetMultiLine(true)
    descBox:SetAutoFocus(false)
    descBox:SetWidth(360)
    descBox:SetHeight(70)
    descBox:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -8)
    descBox:SetFontObject(GameFontHighlightSmall)
    descBox:SetTextInsets(4, 4, 4, 4)
    descBox:SetJustifyH("LEFT")
    descBox:SetText(opts.defaultDescription or "")
    if descBox.EnableKeyboard then descBox:EnableKeyboard(true) end
    descBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local descBg = descBox:CreateTexture(nil, "BACKGROUND")
    descBg:SetTexture(0.08, 0.08, 0.1, 0.9)
    descBg:SetPoint("TOPLEFT", -3, 3)
    descBg:SetPoint("BOTTOMRIGHT", 3, -3)

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetWidth(90)
    saveBtn:SetHeight(24)
    saveBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 18)
    saveBtn:SetText("Save")

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetWidth(90)
    cancelBtn:SetHeight(24)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 18)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() f:Hide() end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    saveBtn:SetScript("OnClick", function()
        local payload = {
            name = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""),
            label = (labelBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""),
            description = descBox:GetText() or "",
        }
        local current = STATE.waypointMetadataPopup
        if current and current.onSave then
            current.onSave(payload)
        end
        f:Hide()
    end)

    f:SetScript("OnHide", function(self)
        if nameBox and nameBox.ClearFocus then nameBox:ClearFocus() end
        if labelBox and labelBox.ClearFocus then labelBox:ClearFocus() end
        if descBox and descBox.ClearFocus then descBox:ClearFocus() end
        if self.EnableKeyboard then self:EnableKeyboard(false) end
    end)

    EnsurePopupEsc(frameName)

    STATE.waypointMetadataPopup = {
        frame = f,
        title = title,
        nameBox = nameBox,
        labelBox = labelBox,
        descBox = descBox,
        descBg = descBg,
        onSave = opts.onSave,
    }

    f:Show()
    if nameBox.SetFocus then
        nameBox:SetFocus()
    end
end

local function InternalClearWaypoints(silent)
    PushHistorySnapshot("clear-waypoints")
    wipe(STATE.db.destinations)
    InvalidateRoute("queue cleared")
    ClearCarboniteTargets()
    if not silent then
        pr("cleared")
    end
end

local function ClearWaypoints()
    InternalClearWaypoints(false)
end

local function RemoveFirstWaypoint(reason)
    if #STATE.db.destinations == 0 then return end
    if reason == "manual-pop" or reason == "undoable-pop" then
        PushHistorySnapshot("pop-waypoint")
    end
    local first = tremove(STATE.db.destinations, 1)
    pr(format("completed #1 => %s (reason=%s)", first.mapName or ("Map " .. tostring(first.maI)), reason or "reach"))
    InvalidateRoute("advanced queue")
    SyncQueueToCarbonite()
end

-- Seconds to wait after adding a waypoint before AutoAdvance may remove #1 (avoids "vanished" right after click).
local GRACE_AFTER_CAPTURE_SEC = 4

local function GetReachedFirstWaypointDistanceYards()
    if not STATE.db or #STATE.db.destinations == 0 then return nil end

    local player = GetPlayerWorldPos()
    if not player then return nil end

    local first = STATE.db.destinations[1]
    if not first or not first.wx or not first.wy then return nil end
    if player.maI ~= first.maI then return nil end

    local yards = WorldToYards(Dist(player.wx, player.wy, first.wx, first.wy))
    if yards <= (STATE.db.reachDistanceYards or 10) then
        return yards
    end

    return nil
end

local function PulseAutoAdvance()
    if not STATE.db.autoAdvance then return end
    if #STATE.db.destinations == 0 then return end

    local now = GetTime()
    if now - STATE.lastPulse < 0.25 then return end
    STATE.lastPulse = now

    if STATE.lastCaptureTime > 0 and (now - STATE.lastCaptureTime) < GRACE_AFTER_CAPTURE_SEC then
        return
    end

    local yards = GetReachedFirstWaypointDistanceYards()
    if yards then
        RemoveFirstWaypoint(format("%.1f yards", yards))
    end
end

local function Probe()
    local map = GetMap()
    if not map then
        pr("probe failed: no Carbonite map")
        return
    end
    if map.CaC3 then pcall(map.CaC3, map) end

    dbg(format("CFX=%.3f CFY=%.3f", map.CFX or -1, map.CFY or -1))
    if map.GCMI then
        local g = map:GCMI()
        dbg(format("GCMI=%s (%s)", tostring(g), (map.ITN and map:ITN(g)) or "?"))
    end
    do
        local n, itn = map.MaI, map.ITN
        dbg(format("MaI=%s (%s)", tostring(n), (n and itn and map:ITN(n)) or "?"))
    end
    if map.GRMI then
        local g = map:GRMI()
        dbg(format("GRMI=%s (%s)", tostring(g), (g and map.ITN and map:ITN(g)) or "?"))
    end
    if map.RMI then
        local r = map.RMI
        dbg(format("RMI=%s (%s)", tostring(r), (r and map.ITN and map:ITN(r)) or "?"))
    end
    if map.FPTWP then
        local wx, wy = map:FPTWP(map.CFX or -1, map.CFY or -1)
        dbg(format("FPTWP=%.6f,%.6f", wx or -1, wy or -1))
    end
end

local function RouteSummary()
    local map = GetMap()
    if not map then
        pr("no Carbonite map")
        return
    end

    local route, why = BuildExpandedRoute()
    if not route then
        pr("no built route summary: " .. tostring(why))
        return
    end

    local tar = map.Tar or {}
    local syncPoints = BuildSyncPoints(route.points or {})
    dbg(format("queue=%d carboniteTargets=%d expandedRoute=%d syncPoints=%d totalCost=%.1f sec explored=%d hasFlyingMount=%s simplifyTransit=%s useFlightMasters=%s",
        #STATE.db.destinations, #tar, #route.points, #syncPoints, route.totalCost or -1, route.explored or -1, tostring(STATE.db.hasFlyingMount), tostring(STATE.db.simplifyTransitWaypoints), tostring(STATE.db.useFlightMasters)))

    pr(format("route: %d queue stop(s), %d point(s), ~%.0fs", #STATE.db.destinations, #route.points, route.totalCost or 0))

    for i, pt in ipairs(route.points) do
        dbg(format("route %d: maI=%d (%s) zx=%.1f zy=%.1f wx=%.3f wy=%.3f edge=%s cost=%.1f label=%s",
            i,
            pt.maI or -1,
            pt.mapName or "?",
            pt.zx or -1,
            pt.zy or -1,
            pt.wx or -1,
            pt.wy or -1,
            ColorizeEdgeName(pt.edgeType, tostring(pt.edgeType)),
            pt.cost or -1,
            tostring(pt.userName or pt.userLabel or pt.label)
        ))
    end
end

local function GraphSummary()
    local graph, why = EnsureGraph()
    if not graph then
        pr("graph build failed: " .. tostring(why))
        return
    end
    pr(format("graph: %d nodes, %d edges", graph.nodeCount or 0, graph.edgeCount or 0))
    dbg(format("graph nodes=%d edges=%d transportLinks=%d", graph.nodeCount or 0, graph.edgeCount or 0, #(graph.links or {})))
end

EnsureCarboniteMapButtons = function()
    if STATE.mapSaveRouteButton then return end
    local map = GetMap()
    if not map or not map.Frm then return end

    local b = CreateFrame("Button", "CWPhase5BSaveRouteMapButton", map.Frm, "UIPanelButtonTemplate")
    b:SetWidth(88)
    b:SetHeight(20)
    b:SetPoint("BOTTOMRIGHT", map.Frm, "BOTTOMRIGHT", -5, 25)
    b:SetText("Save Route")
    b:SetFrameStrata("DIALOG")
    b:SetScript("OnClick", function()
        SaveQueueAsKnownRoute()
    end)

    STATE.mapSaveRouteButton = b
end

local function HookMapClicks()
    if STATE.hookInstalled then return end
    local map = GetMap()
    if not map or not map.Frm then return end

    map.Frm:HookScript("OnMouseDown", function(_, button)
        if STATE.syncing then return end

        local labeled = (button == "LeftButton" and IsShiftKeyDown() and IsControlKeyDown())
        local primary = (button == (STATE.db.bindingButton or "LeftButton") and IsModifierDown(STATE.db.bindingModifier or "SHIFT") and not IsControlKeyDown())
        local fallback = (button == (STATE.db.fallbackButton or "RightButton") and IsModifierDown(STATE.db.fallbackModifier or "CTRL"))

        if labeled then
            AddLabeledCurrentCursorWaypoint()
        elseif primary or fallback then
            AddCurrentCursorWaypoint()
        end
    end)

    STATE.hookInstalled = true
    dbg("mouse hook installed (Shift+LeftClick primary, Ctrl+RightClick fallback)")
end

local function HookCarboniteClear()
    if STATE.clearHookInstalled then return end
    if not Nx or not Nx.Map or not Nx.Map.ClT1 then return end

    hooksecurefunc(Nx.Map, "ClT1", function(self)
        if STATE.syncing then return end
        if not STATE.db then return end
        if #STATE.db.destinations == 0 then return end

        local now = GetTime() or 0
        if now < (STATE.suppressClearUntil or 0) then
            dbg("ignored Carbonite clear during CW sync window")
            return
        end

        if not STATE.db.autoAdvance then
            dbg("ignored Carbonite clear because autoAdvance=false")
            return
        end

        local reachedYards = GetReachedFirstWaypointDistanceYards()
        if reachedYards then
            dbg(format("Carbonite clear near reached waypoint; advancing queue instead of clearing all (%.1f yards)", reachedYards))
            RemoveFirstWaypoint(format("Carbonite clear %.1f yards", reachedYards))
            return
        end

        wipe(STATE.db.destinations)
        InvalidateRoute("Carbonite clear")
        pr("queue cleared (Carbonite Goto / targets were cleared in-game)")
        dbg("queue cleared because Carbonite ClT1 ran away from the active waypoint with autoAdvance=true")
    end)

    STATE.clearHookInstalled = true
    dbg("Carbonite clear hook installed")
end

SlashHandler = function(msg)
    msg = string.lower((msg or ""):gsub("^%s+", ""):gsub("%s+$", ""))

    if msg == "" or msg == "help" then
        pr("commands: /cw ui | tuning | options | help | probe | add | list | export | import | sync | route | graph | clear | pop | undo | redo | autosync | autoadvance | autodiscovery | hasflying | flightmasters | deep | minimal | debug | simplify | legend | transports | cleartransports | transportlog | transportconfirmation | managetransports")
        return
    elseif msg == "ui" or msg == "panel" or msg == "window" then
        EnsureUi()
        ToggleUi()
    elseif msg == "tuning" or msg == "routing" or msg == "routingtuning" then
        ToggleRoutingTuningUi()
    elseif msg == "saveroute" then
        SaveQueueAsKnownRoute()
    elseif msg == "savehere" then
        AddCurrentLocationWithMetadataPopup()
    elseif msg == "options" or msg == "config" then
        EnsureInterfaceOptionsPanel()
        if STATE.interfacePanel then
            local ok = pcall(function()
                if InterfaceOptionsFrame_OpenToFrame then
                    InterfaceOptionsFrame_OpenToFrame(STATE.interfacePanel)
                elseif InterfaceOptionsFrame_OpenToCategory then
                    InterfaceOptionsFrame_OpenToCategory(STATE.interfacePanel)
                end
            end)
            if not ok then
                pr("options: open manually → Interface → AddOns → CustomWaypoints")
            end
        else
            pr("options: not available (no InterfaceOptions in this client)")
        end
    elseif msg == "probe" then
        Probe()
    elseif msg == "add" then
        AddCurrentCursorWaypoint()
    elseif msg == "list" then
        ListWaypoints()
    elseif msg == "export" then
        ExportWaypoints()
    elseif msg:match("^import%s+") then
        local payload = msg:match("^import%s+(.+)$")
        ImportWaypointsFromText(payload or "")
    elseif msg == "import" then
        EnsureUi()
        if STATE.ui and STATE.ui.frame then
            STATE.ui.frame:Show()
            if STATE.ui.importBox then
                STATE.ui.importBox:SetFocus()
            end
        end
        pr("import: paste export lines into the Import box, then click Import (or /cw import <single line>).")
    elseif msg == "sync" then
        SyncQueueToCarbonite()
    elseif msg == "route" then
        RouteSummary()
    elseif msg == "graph" then
        GraphSummary()
    elseif msg == "clear" then
        ClearWaypoints()
    elseif msg == "pop" then
        RemoveFirstWaypoint("manual-pop")
    elseif msg == "undo" then
        UndoHistory()
    elseif msg == "redo" then
        RedoHistory()
    elseif msg == "autosync" then
        STATE.db.autoSyncToCarbonite = not STATE.db.autoSyncToCarbonite
        pr("autoSyncToCarbonite=" .. tostring(STATE.db.autoSyncToCarbonite))
        RefreshUiHeader()
        if STATE.db.autoSyncToCarbonite then
            SyncQueueToCarbonite()
        end
    elseif msg == "autoadvance" then
        STATE.db.autoAdvance = not STATE.db.autoAdvance
        pr("autoAdvance=" .. tostring(STATE.db.autoAdvance))
        RefreshUiHeader()
    elseif msg == "hasflying" or msg == "toggleflying" or msg == "flymode" or "microrouting" then
        STATE.db.hasFlyingMount = not STATE.db.hasFlyingMount
        InvalidateRoute("hasFlyingMount toggled")
        pr("hasFlyingMount=" .. tostring(STATE.db.hasFlyingMount))
        RefreshUiHeader()
        if STATE.db.autoSyncToCarbonite then
            SyncQueueToCarbonite()
        end
    elseif msg == "flightmasters" or msg == "taxi" then
        STATE.db.useFlightMasters = not STATE.db.useFlightMasters
        STATE.graph = nil
        InvalidateRoute("flight masters toggled")
        pr("useFlightMasters=" .. tostring(STATE.db.useFlightMasters))
        RefreshUiHeader()
        if STATE.db.autoSyncToCarbonite then SyncQueueToCarbonite() end
    elseif msg == "deep" then
        STATE.db.simplifyTransitWaypoints = false
        InvalidateRoute("deep mode")
        pr("simplifyTransitWaypoints=false (deep critical routing mode)")
        RefreshUiHeader()
        if STATE.db.autoSyncToCarbonite then SyncQueueToCarbonite() end
    elseif msg == "minimal" then
        STATE.db.simplifyTransitWaypoints = true
        InvalidateRoute("minimal mode")
        pr("simplifyTransitWaypoints=true (minimal transition routing mode)")
        RefreshUiHeader()
        if STATE.db.autoSyncToCarbonite then SyncQueueToCarbonite() end
    elseif msg == "legend" then
        STATE.db.showLegend = not STATE.db.showLegend
        EnsureUi()
        RefreshUiHeader()
        pr("showLegend=" .. tostring(STATE.db.showLegend))
    elseif msg == "debug" then
        EnsureDb()
        STATE.db.debug = not STATE.db.debug
        pr("debug=" .. tostring(STATE.db.debug))
        RefreshUiHeader()
    elseif msg == "simplify" or msg == "simplifytransit" then
        STATE.db.simplifyTransitWaypoints = not STATE.db.simplifyTransitWaypoints
        InvalidateRoute("simplifyTransitWaypoints toggled")
        pr("simplifyTransitWaypoints=" .. tostring(STATE.db.simplifyTransitWaypoints))
        RefreshUiHeader()
        if STATE.db.autoSyncToCarbonite then
            SyncQueueToCarbonite()
        end
    elseif msg == "transports" then
        ListLearnedTransports()
    elseif msg == "cleartransports" then
        ClearLearnedTransports()
        if STATE.db.autoSyncToCarbonite then SyncQueueToCarbonite() end
    elseif msg == "transportlog" then
        STATE.db.transportLogEnabled = not STATE.db.transportLogEnabled
        pr("transportLogEnabled=" .. tostring(STATE.db.transportLogEnabled))
    elseif msg == "autodiscovery" or msg == "transportdiscovery" or msg == "portaldiscovery" then
        ToggleAutoDiscovery()
    elseif msg == "transportconfirmation" then
        STATE.db.transportConfirmationEnabled = not STATE.db.transportConfirmationEnabled
        pr("transportConfirmationEnabled=" .. tostring(STATE.db.transportConfirmationEnabled))
    elseif msg == "managetransports" then
        ShowTransportManagementFrame()
    elseif msg == "knownlocations" or msg == "known" then
        ShowKnownLocationsFrame()
    elseif msg:match("^routeknown%s+%d+$") then
        local idx = tonumber(msg:match("^routeknown%s+(%d+)$"))
        RouteToKnownLocation(idx)
    else
        pr("unknown command: " .. tostring(msg))
    end
end

local function ScheduleLoginQueueSyncIfNeeded()
    EnsureDb()
    if not STATE.db or #(STATE.db.destinations or {}) == 0 then return end
    STATE.needLoginQueueSync = true
end

local function TryPendingLoginQueueSync()
    if not STATE.needLoginQueueSync then return end
    EnsureDb()
    if not STATE.db or #(STATE.db.destinations or {}) == 0 then
        STATE.needLoginQueueSync = false
        return
    end
    if not GetMap() then return end
    STATE.needLoginQueueSync = false
    SyncQueueToCarbonite()
    dbg("login: auto-synced non-empty queue to Carbonite")
end

local function OnEvent(_, event)
    if event == "PLAYER_LOGIN" then
        EnsureDb()
        HookMapClicks()
        HookCarboniteClear()
        InstallCarboniteTravelHook()
        InstallCarboniteSclGuard()
        InstallUndoRedoBindings()
        EnsureKnownLocationsBinding()
        EnsureSaveHereBinding()
        EnsureInterfaceOptionsPanel()
        ScheduleLoginQueueSyncIfNeeded()
        EnsureCarboniteMapButtons()
        dbg("loaded (Phase 5B patched: UI/options/bindings + safer deep fallback + SCL guard)")
    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsureDb()
        HookMapClicks()
        HookCarboniteClear()
        InstallCarboniteTravelHook()
        InstallCarboniteSclGuard()
        InstallUndoRedoBindings()
        EnsureKnownLocationsBinding()
        EnsureSaveHereBinding()
        EnsureInterfaceOptionsPanel()
        ScheduleLoginQueueSyncIfNeeded()
        EnsureCarboniteMapButtons()
        if STATE.lastStablePlayerPos then
            BeginPendingTransport("PLAYER_ENTERING_WORLD", STATE.lastStablePlayerPos)
        end
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED_INDOORS" then
        EnsureDb()
        if STATE.lastStablePlayerPos then
            BeginPendingTransport(event, STATE.lastStablePlayerPos)
        end
    elseif event == "PLAYER_DEAD" then
        EnsureDb()
        StartPendingDeathAutoRoute(0.20)
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        EnsureDb()
        StartPendingDeathAutoRoute(0.35)
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        RefreshCwEscOverride()
    end
end

local function OnUpdate(_, elapsed)
    EnsureCarboniteMapButtons()
    TryPendingLoginQueueSync()
    PulseTransportDiscovery(elapsed)
    PulsePendingDeathAutoRoute()
    PulseAutoAdvance()
    if not STATE.hookInstalled then
        HookMapClicks()
    end
    if not STATE.clearHookInstalled then
        HookCarboniteClear()
    end
    if not STATE.travelHookInstalled then
        InstallCarboniteTravelHook()
    end
    if not STATE.sclGuardInstalled then
        InstallCarboniteSclGuard()
    else
        local map = GetMap()
        if map and Nx and Nx.Map and Nx.Map.SCL and map.SCL ~= Nx.Map.SCL then
            map.SCL = Nx.Map.SCL
        end
    end
    if not STATE.bindingsInstalled then
        InstallUndoRedoBindings()
    end
end

local frame = CreateFrame("Frame")
STATE.frame = frame
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_ALIVE")
frame:RegisterEvent("PLAYER_UNGHOST")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", OnEvent)
frame:SetScript("OnUpdate", OnUpdate)

SLASH_CUSTOMWAYPOINTS1 = "/cw"
SlashCmdList.CUSTOMWAYPOINTS = SlashHandler

CW._STATE = STATE
CW.STATE = STATE
CW.AddCurrentCursorWaypoint = AddCurrentCursorWaypoint
CW.SyncQueueToCarbonite = SyncQueueToCarbonite
CW.ClearWaypoints = ClearWaypoints
CW.ImportWaypointsFromText = ImportWaypointsFromText

CW.EnsureUi = EnsureUi
CW.ToggleUi = ToggleUi
