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
local ShowKnownLocationEditorPopup
local SaveQueueAsKnownRoute
local AddLabeledCurrentCursorWaypoint
local AddCurrentLocationWithMetadataPopup
local EnsureCarboniteMapButtons
local routeSelectedBtn
local BuildKnownLocationSignature
local FindDuplicateKnownLocationIndex
local GetPlayerWorldPos
local NormalizeSignatureNumber

CustomWaypoints = CustomWaypoints or {}
local CW = CustomWaypoints

local TARGET_TYPE_GOTO = "Goto"
local TARGET_TYPE_STRAIGHT = "CW_STRAIGHT"

local STRAIGHT_EDGE_TYPES = {
    flying = true,
    boat = true,
    zeppelin = true,
    tram = true,
    portal = true,
    transport = true,
    taxi = true,
    flight_master = true,
    route = true,
}

local TRANSIT_EDGE_TYPES = {
    boat = true,
    zeppelin = true,
    tram = true,
    portal = true,
    taxi = true,
    flight_master = true,
    route = true,
}

BINDING_HEADER_CUSTOMWAYPOINTS = "CustomWaypoints"
BINDING_NAME_CW_TOGGLE_KNOWN_LOCATIONS = "Toggle Known Locations"
BINDING_NAME_CW_SAVE_HERE = "Save Here"
BINDING_NAME_CW_DELETE_SELECTED_KNOWN_LOCATION = "Delete Selected Known Location"

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
    simplifyTransitWaypoints = false,
    showUi = true,
    uiScale = 1,
    transportDiscoveryEnabled = false,
    transportLogEnabled = false,
    transportConfirmationEnabled = true,
    autoRouteSavedInstanceOnDeath = true,
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
    flightMasterBoardingSeconds = 20,
    flightMasterSpeedYardsPerSecond = 15,
    flightMasterLandingSeconds = 12,
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
    if not STATE.db and EnsureDb then
        EnsureDb()
    end
    local db = STATE.db or {}
    if STATE.ui and STATE.ui.header then
        STATE.ui.header:SetText("CW options")
        if STATE.ui.legend then
            STATE.ui.legend:Hide()
        end
        if STATE.ui.checks then
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
        if STATE.interfaceChecks.flightmasters and STATE.interfaceChecks.flightmasters.SetChecked then STATE.interfaceChecks.flightmasters:SetChecked(db.useFlightMasters and true or false) end
        if STATE.interfaceChecks.deep and STATE.interfaceChecks.deep.SetChecked then STATE.interfaceChecks.deep:SetChecked((not db.simplifyTransitWaypoints) and true or false) end
        if STATE.interfaceChecks.debug and STATE.interfaceChecks.debug.SetChecked then STATE.interfaceChecks.debug:SetChecked(db.debug and true or false) end
        if STATE.interfaceChecks.portaldiscovery and STATE.interfaceChecks.portaldiscovery.SetChecked then STATE.interfaceChecks.portaldiscovery:SetChecked(db.transportDiscoveryEnabled and true or false) end
        if STATE.interfaceChecks.transportconfirmation and STATE.interfaceChecks.transportconfirmation.SetChecked then STATE.interfaceChecks.transportconfirmation:SetChecked(db.transportConfirmationEnabled and true or false) end
        if STATE.interfaceChecks.autorouteinstanceondeath and STATE.interfaceChecks.autorouteinstanceondeath.SetChecked then STATE.interfaceChecks.autorouteinstanceondeath:SetChecked(db.autoRouteSavedInstanceOnDeath and true or false) end
    end
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
    local line = "CW: " .. tostring(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff80ff80CW:|r " .. tostring(msg))
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

local function IsTransitSimplifiedEffective()
    if STATE and STATE.taxiForceSimplifyTransitWaypoints then
        return true
    end
    return STATE.db and STATE.db.simplifyTransitWaypoints == true
end

local function SpellKnownCompat(spellId)
    if type(IsSpellKnown) ~= "function" then return false end
    local known = IsSpellKnown(spellId)
    return known ~= nil and known ~= false
end

local function AchievementCompleteCompat(achievementId)
    if type(GetAchievementInfo) ~= "function" then return false end
    local _, _, _, completed = GetAchievementInfo(achievementId)
    return completed ~= nil and completed ~= false
end

function CW.IsWotlk335a()
    if type(GetBuildInfo) ~= "function" then return false end

    local version, build, _, tocVersion = GetBuildInfo()
    version = tostring(version or "")
    build = tostring(build or "")

    if build == "12340" then
        return true
    end
    if version == "3.3.5a" then
        return true
    end
    return version == "3.3.5" and tonumber(tocVersion) == 30300
end

function CW.ShouldUseSpellFlyingDetection()
    return CW.IsWotlk335a() and type(IsSpellKnown) == "function"
end

function CW.GetFlyableExpansionRegion(mapId)
    local maI = tonumber(type(mapId) == "table" and mapId.maI or mapId)
    if not maI then return nil end

    if maI >= 3000 and maI < 4000 then
        return "outland"
    end
    if maI >= 4000 and maI < 5000 then
        return "northrend"
    end
    return nil
end

function CW.PlayerCanFlyInRegion(mapId)
    if not CW.ShouldUseSpellFlyingDetection() then return false end

    local hasExpert = SpellKnownCompat(34090) -- Expert Riding (150%)
    local hasArtisan = SpellKnownCompat(34091) -- Artisan Riding (280%)
    local hasColdWeather = SpellKnownCompat(54197) -- Cold Weather Flying
    local hasExpertAchievement = AchievementCompleteCompat(890) -- Into The Wild Blue Yonder
    local hasArtisanAchievement = AchievementCompleteCompat(892) -- The Right Stuff
    local hasFlying = hasExpert or hasArtisan or hasExpertAchievement or hasArtisanAchievement

    local region = CW.GetFlyableExpansionRegion(mapId)
    if region == "outland" then
        return hasFlying == true
    end
    if region == "northrend" then
        return hasFlying == true and hasColdWeather == true
    end

    return false
end

function CW.LegacyDirectFlyingEnabled()
    -- Compatibility fallback for non-3.3.5a/API-mismatch clients that may
    -- still have the old saved value. 3.3.5a uses spell capability instead.
    return STATE and STATE.db and STATE.db.hasFlyingMount == true and IsTransitSimplifiedEffective()
end

function CW.CanUseCapabilityDirectFlyingLeg(startPoint, destPoint)
    if not (startPoint and destPoint and startPoint.wx and startPoint.wy and destPoint.wx and destPoint.wy) then
        return false
    end

    local startRegion = CW.GetFlyableExpansionRegion(startPoint)
    local destRegion = CW.GetFlyableExpansionRegion(destPoint)
    if not (startRegion and startRegion == destRegion) then
        return false
    end

    if CW.ShouldUseSpellFlyingDetection() then
        local canFly = CW.PlayerCanFlyInRegion(startPoint.maI)
        if STATE.db and STATE.db.debug == true then
            pr(format("fly capability: startMaI=%s destMaI=%s region=%s expert=%s artisan=%s expertAch=%s artisanAch=%s coldWeather=%s canFly=%s",
                tostring(startPoint.maI), tostring(destPoint.maI), tostring(startRegion),
                tostring(SpellKnownCompat(34090)), tostring(SpellKnownCompat(34091)),
                tostring(AchievementCompleteCompat(890)), tostring(AchievementCompleteCompat(892)), tostring(SpellKnownCompat(54197)), tostring(canFly)))
        end
        return canFly
    end

    return CW.LegacyDirectFlyingEnabled()
end

-- Direct-flying capable legs return before graph expansion, so FM/taxi graph
-- candidates stay available whenever the graph path is actually used. On
-- non-3.3.5a/API-mismatch clients, preserve the old saved-setting fallback.
local function ShouldSuppressFlightMasterRouting()
    if CW.ShouldUseSpellFlyingDetection() then return false end
    return CW.LegacyDirectFlyingEnabled()
end
local function GetEdgeTransportKind(edge)
    if not edge then return nil end
    local kind = edge.transportKind or edge.kind or edge.type
    if kind == "taxi" then
        return "flight_master"
    end
    if kind and kind ~= "" then
        return kind
    end
    return nil
end

local function IsFlightMasterKind(kind)
    return kind == "flight_master" or kind == "taxi"
end

local function IsBidirectionalTransportRecord(edge)
    if not edge then return false end
    if edge.bidirectional ~= nil then
        return edge.bidirectional == true
    end
    return IsFlightMasterKind(GetEdgeTransportKind(edge))
end

local function CanonicalTransportKind(kind)
    if IsFlightMasterKind(kind) then
        return "flight_master"
    end
    if kind == nil or kind == "" then
        return "transport"
    end
    return kind
end

local function NormalizeTransportRecord(edge)
    if type(edge) ~= "table" then return edge end
    edge.transportKind = CanonicalTransportKind(GetEdgeTransportKind(edge))
    if IsFlightMasterKind(edge.transportKind) then
        edge.transportKind = "flight_master"
        edge.bidirectional = true
    elseif edge.bidirectional == nil then
        edge.bidirectional = false
    else
        edge.bidirectional = edge.bidirectional and true or false
    end
    return edge
end

local function CloneTransportEdgeWithEndpoints(edge)
    if not edge then return nil end
    local copy = {}
    for k, v in pairs(edge) do copy[k] = v end
    return NormalizeTransportRecord(copy)
end

CW.TRANSPORT_ENDPOINT_SWAP_SUFFIXES = {
    "MaI",
    "MapName",
    "Zx",
    "Zy",
    "Wx",
    "Wy",
    "Instance",
    "InstanceType",
    "ZoneName",
    "ZoneText",
    "SubZoneText",
}

function CW.BuildTransportEndpointLookupAliases(edge, prefix)
    local out, seen = {}, {}

    local function add(value)
        local key = CW.NormalizeZoneLookupKey(value)
        if key ~= "" and not seen[key] then
            seen[key] = true
            out[#out + 1] = value
        end
    end

    add(edge and edge[prefix .. "SubZoneText"])
    add(edge and edge[prefix .. "ZoneText"])
    add(edge and edge[prefix .. "ZoneName"])
    add(edge and edge[prefix .. "MapName"])

    return out
end

function CW.ReverseTransportEdgeDirection(edge)
    local copy = CloneTransportEdgeWithEndpoints(edge)
    if not copy then return nil end

    for _, suffix in ipairs(CW.TRANSPORT_ENDPOINT_SWAP_SUFFIXES) do
        copy["from" .. suffix], copy["to" .. suffix] = copy["to" .. suffix], copy["from" .. suffix]
    end

    return NormalizeTransportRecord(copy)
end

function CW.OrientTransportEdgeTowardDestination(edge, name)
    local copy = CloneTransportEdgeWithEndpoints(edge)
    if not copy then return nil end
    if not IsBidirectionalTransportRecord(copy) then
        return copy
    end

    local targetKey = CW.NormalizeZoneLookupKey(name)
    if targetKey == "" then
        return copy
    end

    local function endpointMatches(prefix)
        for _, value in ipairs(CW.BuildTransportEndpointLookupAliases(copy, prefix)) do
            if CW.ZoneLookupKeysMatchLoosely(value, targetKey) then
                return true
            end
        end
        return false
    end

    local fromMatches = endpointMatches("from")
    local toMatches = endpointMatches("to")

    if fromMatches and not toMatches then
        return CW.ReverseTransportEdgeDirection(copy)
    end

    return copy
end

function CW.BuildManualTransportFromRoutePoints(routePoints, opts)
    if type(routePoints) ~= "table" or #routePoints ~= 2 then
        return nil, "need-exactly-2-points"
    end

    local first = routePoints[1]
    local last = routePoints[#routePoints]
    if not first or not last then
        return nil, "missing-endpoints"
    end
    if not (first.maI and first.wx and first.wy and last.maI and last.wx and last.wy) then
        return nil, "missing-endpoint-coords"
    end

    local fromZoneName = first.userName or first.userLabel or first.mapName
    if first.subZoneText and first.subZoneText ~= "" then
        fromZoneName = first.subZoneText
    elseif first.zoneText and first.zoneText ~= "" then
        fromZoneName = first.zoneText
    end

    local toZoneName = last.userName or last.userLabel or last.mapName
    if last.subZoneText and last.subZoneText ~= "" then
        toZoneName = last.subZoneText
    elseif last.zoneText and last.zoneText ~= "" then
        toZoneName = last.zoneText
    end

    local edge = {
        fromMaI = first.maI,
        fromMapName = first.mapName,
        fromZx = first.zx,
        fromZy = first.zy,
        fromWx = first.wx,
        fromWy = first.wy,
        fromInstance = first.instance,
        fromInstanceType = first.instanceType,
        fromZoneName = fromZoneName,
        fromZoneText = first.zoneText,
        fromSubZoneText = first.subZoneText,

        toMaI = last.maI,
        toMapName = last.mapName,
        toZx = last.zx,
        toZy = last.zy,
        toWx = last.wx,
        toWy = last.wy,
        toInstance = last.instance,
        toInstanceType = last.instanceType,
        toZoneName = toZoneName,
        toZoneText = last.zoneText,
        toSubZoneText = last.subZoneText,

        label = opts and opts.label or nil,
        description = opts and opts.description or nil,
        transportKind = opts and opts.transportKind or "passage",
        bidirectional = opts and opts.bidirectional == true or false,
        discoveredBy = opts and opts.discoveredBy or "manual-saveroute",
    }

    return NormalizeTransportRecord(edge), nil
end

local function BuildTransportRecordKey(edge)
    if not edge or not edge.fromMaI or not edge.toMaI then return nil end
    edge = NormalizeTransportRecord(edge)
    local kind = CanonicalTransportKind(edge.transportKind)
    local a = table.concat({
        tostring(edge.fromMaI or "?"),
        NormalizeSignatureNumber(edge.fromWx, 5),
        NormalizeSignatureNumber(edge.fromWy, 5),
        tostring(edge.toMaI or "?"),
        NormalizeSignatureNumber(edge.toWx, 5),
        NormalizeSignatureNumber(edge.toWy, 5),
    }, "|")
    if IsBidirectionalTransportRecord(edge) then
        local b = table.concat({
            tostring(edge.toMaI or "?"),
            NormalizeSignatureNumber(edge.toWx, 5),
            NormalizeSignatureNumber(edge.toWy, 5),
            tostring(edge.fromMaI or "?"),
            NormalizeSignatureNumber(edge.fromWx, 5),
            NormalizeSignatureNumber(edge.fromWy, 5),
        }, "|")
        if b < a then a = b end
    end
    return kind .. "|" .. a .. "|b=" .. tostring(IsBidirectionalTransportRecord(edge) and 1 or 0)
end

function CW.BuildTransportLookupAliases(edge)
    local out, seen = {}, {}

    local function add(value)
        local key = CW.NormalizeZoneLookupKey(value)
        if key ~= "" and not seen[key] then
            seen[key] = true
            out[#out + 1] = value
        end
    end

    add(edge and edge.toSubZoneText)
    add(edge and edge.toZoneText)
    add(edge and edge.toZoneName)
    add(edge and edge.toMapName)
    add(edge and edge.name)
    add(edge and edge.label)
    add(edge and edge.trackerLabel)

    return out
end

function CW.TransportDestinationAliasMatches(edge, name)
    local targetKey = CW.NormalizeZoneLookupKey(name)
    if targetKey == "" then return false end

    for _, value in ipairs(CW.BuildTransportLookupAliases(edge)) do
        if CW.ZoneLookupKeysMatchLoosely(value, targetKey) then
            return true
        end
    end
    return false
end

function CW.IsSingleNodeManualTransportEdge(edge)
    return edge and not (edge.fromMaI and edge.fromWx and edge.fromWy)
end

function CW.ResolveBestMapIdFromTransportAliases(edge)
    if not edge then return nil end

    local candidates, seen = {}, {}
    for _, value in ipairs(CW.BuildTransportLookupAliases(edge)) do
        local maI = select(1, CW.ResolveMapIdBySmartName(value))
        if maI and not seen[maI] then
            seen[maI] = true
            candidates[#candidates + 1] = maI
        end
    end

    local transportMaI = tonumber(edge.toMaI)
    for _, maI in ipairs(candidates) do
        if tonumber(maI) ~= transportMaI then
            return maI
        end
    end
    return candidates[1]
end

function CW.BuildPointFromTransportEndpoint(edge, prefix, label)
    if not edge then return nil end

    local maI = edge[prefix .. "MaI"]
    local wx = edge[prefix .. "Wx"]
    local wy = edge[prefix .. "Wy"]
    if not (maI and wx and wy) then return nil end

    return {
        maI = maI,
        wx = wx,
        wy = wy,
        zx = edge[prefix .. "Zx"],
        zy = edge[prefix .. "Zy"],
        mapName = edge[prefix .. "MapName"],
        zoneText = edge[prefix .. "ZoneText"],
        subZoneText = edge[prefix .. "SubZoneText"],
        instance = edge[prefix .. "Instance"],
        instanceType = edge[prefix .. "InstanceType"],
        label = label,
        forceStraight = true,
    }
end

function CW.ArePointsNearSameLocation(a, b)
    if not (a and b and a.maI and b.maI) then return false end
    if a.maI ~= b.maI then return false end

    local ax, ay = tonumber(a.wx), tonumber(a.wy)
    local bx, by = tonumber(b.wx), tonumber(b.wy)
    if not (ax and ay and bx and by) then return false end

    return math.abs(ax - bx) <= 0.0001 and math.abs(ay - by) <= 0.0001
end

function CW.DoesPlayerAlreadyMatchZoneName(name)
    local wanted = CW.NormalizeZoneLookupKey(name)
    if wanted == "" then return false end

    local pos = GetPlayerWorldPos()
    if not pos then return false end

    local function matches(value)
        return CW.NormalizeZoneLookupKey(value) == wanted
    end

    return matches(pos.subZoneText) or matches(pos.zoneText) or matches(pos.mapName)
end

function CW.DoesPlayerAlreadyMatchZoneNameLoosely(name)
    local wanted = CW.NormalizeZoneLookupKey(name)
    if wanted == "" then return false end

    local pos = GetPlayerWorldPos()
    if not pos then return false end

    local function matches(value)
        return CW.ZoneLookupKeysMatchLoosely(value, wanted)
    end

    return matches(pos.subZoneText) or matches(pos.zoneText) or matches(pos.mapName)
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

function CW.IsPlayerNearTransportEndpoint(edge, prefix, maxYards)
    if not edge then return false end
    local pos = GetPlayerWorldPos()
    if not pos then return false end

    local maI = edge[prefix .. "MaI"]
    local wx = edge[prefix .. "Wx"]
    local wy = edge[prefix .. "Wy"]
    if not (pos.maI and maI and pos.wx and pos.wy and wx and wy) then
        return false
    end
    if tonumber(pos.maI) ~= tonumber(maI) then
        return false
    end

    return IsNearWorldPoint(pos.wx, pos.wy, wx, wy, maxYards or 140)
end

function CW.DoesPointMatchCurrentZoneContext(pt)
    if not pt then return false end
    return CW.DoesPlayerAlreadyMatchZoneNameLoosely(pt.subZoneText)
        or CW.DoesPlayerAlreadyMatchZoneNameLoosely(pt.zoneText)
        or CW.DoesPlayerAlreadyMatchZoneNameLoosely(pt.userName)
        or CW.DoesPlayerAlreadyMatchZoneNameLoosely(pt.mapName)
end

local function InferStoredTransportKind(loc)
    if not loc then return nil end
    if loc.transportKind and loc.transportKind ~= "" then
        return CanonicalTransportKind(loc.transportKind)
    end
    if loc.kind == "transport" and loc.label and string.find(lower(tostring(loc.label)), "flight master", 1, true) then
        return "flight_master"
    end
    return nil
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
    transportType = CanonicalTransportKind(transportType)

    if learnedHop then
        if transportType == "portal" then
            -- Learned portals are still portal paths: when portal bonus is zero,
            -- do not keep hidden learned-portal preference active.
            if (tuning.portalBonus or 0) <= 0 then
                return 0
            end
            return TuningBonusToSeconds(tuning.learnedPortalBonus, 0.15, 18)
        end
        return 0
    end

    if transportType == "portal" then
        return TuningBonusToSeconds(tuning.portalBonus, 0.15, 18)
    elseif transportType == "tram" then
        return TuningBonusToSeconds(tuning.tramBonus, 0.12, 16)
    elseif transportType == "boat" then
        return TuningBonusToSeconds(tuning.boatBonus, 0.10, 14)
    elseif transportType == "zeppelin" then
        return TuningBonusToSeconds(tuning.zeppelinBonus, 0.10, 14)
    elseif transportType == "flight_master" then
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

    -- Keep attach ranking source-neutral. Only transport-kind tuning may affect
    -- the attach score; learned/manual/saved provenance must not add hidden preference.
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
    lastNonInstanceStablePlayerPos = nil,
    lastInstanceStablePlayerPos = nil,
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
    recentInstanceEntryKey = nil,
    recentInstanceEntryUntil = 0,
    cwModalStack = {},
    pendingDeathAutoRoute = nil,
    deathAutoRouteContext = nil,
    lastDeathAutoRouteKey = nil,
    mapSaveRouteButtonHooksInstalled = false,
    deepSyncSkipCount = 0,
    lastGroundPlayerPos = nil,
    wasOnTaxi = false,
    pendingTaxiRouteRefresh = false,
    taxiTransitRoutingWasSimplified = nil,
    taxiNextRefreshAt = 0,
    taxiRefreshInterval = 4,
    sessionKnownTaxis = {},
    taxiInjectedKey = nil,
    taxiInjectedDest = nil,
    taxiForceSimplifyTransitWaypoints = false,
}

-- NOTE:
-- Removed top-level forward local declarations here to stay below the
-- Lua 5.1 main-chunk local-variable limit. The corresponding symbols are
-- assigned later in the file before runtime use.

-- Lexical: must be above InstallUndoRedoBindings if that helper ever calls GetMap at install time.
local function GetMap()
    if not Nx or not Nx.Map or not Nx.Map.GeM then return nil end
    return Nx.Map:GeM(1)
end

local function IsPlayerOnTaxi()
    return UnitOnTaxi and UnitOnTaxi("player") and true or false
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

local function GetRouteBuildStartPoint()
    local current = GetPlayerWorldPos()

    if IsPlayerOnTaxi() and current then
        local airborne = CloneWorldPoint(current)
        if airborne then
            airborne.isSyntheticStart = true
            airborne.label = airborne.label or "Taxi current"
            return airborne
        end
    end

    if IsPlayerOnTaxi() and STATE.lastGroundPlayerPos then
        local frozen = CloneWorldPoint(STATE.lastGroundPlayerPos)
        if frozen then
            frozen.isSyntheticStart = true
            frozen.label = frozen.label or "Taxi origin"
            return frozen
        end
    end

    if not current then return nil end
    return current
end

local function dbg(msg)
    if STATE.db and STATE.db.debug == true then
        pr(msg)
    end
end

CW.CleanupTransientTaxiDestinations = function(silent)
    EnsureDb()
    if not (STATE.db and type(STATE.db.destinations) == "table") then
        STATE.taxiInjectedKey = nil
        STATE.taxiInjectedDest = nil
        return false
    end

    local removed = false
    for i = #STATE.db.destinations, 1, -1 do
        local dest = STATE.db.destinations[i]
        if type(dest) == "table" and dest.cwTaxiInjected then
            tremove(STATE.db.destinations, i)
            removed = true
        end
    end

    if removed then
        STATE.taxiInjectedKey = nil
        STATE.taxiInjectedDest = nil
        InvalidateRoute("cleanup transient taxi destination")
        if not silent and STATE.db.autoSyncToCarbonite then
            SyncQueueToCarbonite()
        end
        dbg("taxi: cleaned up transient queue head")
    else
        STATE.taxiInjectedKey = nil
        STATE.taxiInjectedDest = nil
    end

    return removed
end

CW.ResolveTaxiNodeByName = function(name, targetWx, targetWy)
    if not (name and name ~= "" and Nx and Nx.Tra and type(Nx.Tra.Tra) == "table") then
        return nil
    end

    local requestedKeys = CW.BuildTaxiKeyVariants(name)
    local best = nil
    local bestScore = nil

    local function ConsiderCandidate(nod, displayName)
        if type(nod) ~= "table" or not nod.LoN or not nod.MaI or not nod.WX or not nod.WY then
            return
        end

        local candidateName = displayName or nod.LoN
        local matched = false
        for key in pairs(requestedKeys) do
            if key and key ~= "" then
                for nodeKey in pairs(CW.BuildTaxiKeyVariants(candidateName)) do
                    if nodeKey == key then
                        matched = true
                        break
                    end
                end
                if matched then break end
            end
        end

        if not matched then
            return
        end

        local distPenalty = 0
        if targetWx and targetWy then
            distPenalty =
                math.abs((tonumber(nod.WX) or 0) - (tonumber(targetWx) or 0)) +
                math.abs((tonumber(nod.WY) or 0) - (tonumber(targetWy) or 0))
        end

        if bestScore == nil or distPenalty < bestScore then
            bestScore = distPenalty
            best = {
                maI = nod.MaI,
                wx = nod.WX,
                wy = nod.WY,
                mapName = nod.LoN,
                userName = candidateName,
                userLabel = "taxi",
                description = "Transient taxi destination",
            }
        end
    end

    for _, list in pairs(Nx.Tra.Tra) do
        if type(list) == "table" then
            for _, nod in ipairs(list) do
                ConsiderCandidate(nod, nod.LoN)
                ConsiderCandidate(nod, nod.Nam)
            end
        end
    end

    return best
end

CW.GetActiveTaxiDestination = function()
    if not IsPlayerOnTaxi() then return nil, "not-on-taxi" end
    local map = GetMap()
    if not map then return nil, "no-map" end
    if not (Nx and Nx.Map) then return nil, "no-carbonite" end

    local taxiName = map.TaN
    local wx = map.TaX
    local wy = map.TaY
    if not (taxiName and taxiName ~= "" and wx and wy) then
        return nil, "no-active-taxi-target"
    end

    local dest = CW.ResolveTaxiNodeByName(taxiName, wx, wy) or {
        mapName = taxiName,
        userName = taxiName,
        userLabel = "taxi",
        description = "Transient taxi destination",
    }

    dest.wx = wx
    dest.wy = wy
    dest.ts = date("%Y-%m-%d %H:%M:%S")
    dest.cwTaxiInjected = true

    if not dest.maI then
        return nil, "active-taxi-target-without-maI"
    end

    dest.mapName = dest.mapName or (map.ITN and map:ITN(dest.maI)) or taxiName
    return dest, nil
end

CW.EnsureTaxiDestinationQueueHead = function()
    EnsureDb()
    if not (STATE.db and type(STATE.db.destinations) == "table") then return false end

    local hasRealQueueStop = false
    for _, queued in ipairs(STATE.db.destinations) do
        if type(queued) == "table" and not queued.cwTaxiInjected then
            hasRealQueueStop = true
            break
        end
    end
    if not hasRealQueueStop then
        return false
    end

    local dest, why = CW.GetActiveTaxiDestination()
    if not dest then
        return false
    end

    local key = table.concat({ tostring(dest.maI or "?"), string.format("%.3f", tonumber(dest.wx) or -1), string.format("%.3f", tonumber(dest.wy) or -1), tostring(dest.userName or dest.mapName or "?") }, "|")
    local first = STATE.db.destinations[1]

    if type(first) == "table" and not first.cwTaxiInjected then
        local firstKey = table.concat({ tostring(first.maI or "?"), string.format("%.3f", tonumber(first.wx) or -1), string.format("%.3f", tonumber(first.wy) or -1), tostring(first.userName or first.mapName or "?") }, "|")
        if firstKey == key then
            STATE.taxiInjectedKey = key
            STATE.taxiInjectedDest = CloneWorldPoint(dest)
            return false
        end
    end

    if type(first) == "table" and first.cwTaxiInjected then
        local existingKey = table.concat({ tostring(first.maI or "?"), string.format("%.3f", tonumber(first.wx) or -1), string.format("%.3f", tonumber(first.wy) or -1), tostring(first.userName or first.mapName or "?") }, "|")
        if existingKey == key then
            STATE.taxiInjectedKey = key
            STATE.taxiInjectedDest = CloneWorldPoint(dest)
            return false
        end
        tremove(STATE.db.destinations, 1)
    else
        CW.CleanupTransientTaxiDestinations(true)
    end

    tinsert(STATE.db.destinations, 1, dest)
    STATE.taxiInjectedKey = key
    STATE.taxiInjectedDest = CloneWorldPoint(dest)
    InvalidateRoute("taxi destination queue head inserted")
    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end
    dbg("taxi: inserted transient queue head => " .. tostring(dest.userName or dest.mapName or dest.maI))
    return true
end

CW.RemoveTaxiDestinationQueueHead = function(syncAfter)
    EnsureDb()
    if not (STATE.db and type(STATE.db.destinations) == "table") then
        STATE.taxiInjectedKey = nil
        STATE.taxiInjectedDest = nil
        return false
    end

    local first = STATE.db.destinations[1]
    if not (type(first) == "table" and first.cwTaxiInjected) then
        CW.CleanupTransientTaxiDestinations(true)
        return false
    end

    tremove(STATE.db.destinations, 1)
    STATE.taxiInjectedKey = nil
    STATE.taxiInjectedDest = nil
    InvalidateRoute("taxi destination queue head removed")
    if syncAfter and STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end
    dbg("taxi: removed transient queue head")
    return true
end

CW.EnterTaxiTransitRoutingOverride = function()
    EnsureDb()
    if not STATE.db then return end
    if STATE.taxiForceSimplifyTransitWaypoints then return end

    STATE.taxiTransitRoutingWasSimplified = STATE.db.simplifyTransitWaypoints and true or false
    STATE.taxiForceSimplifyTransitWaypoints = true
    STATE.taxiNextRefreshAt = 0

    InvalidateRoute("taxi transit routing override")
    RefreshUiHeader()
    dbg("taxi: temporary transit routing override enabled")
end

CW.LeaveTaxiTransitRoutingOverride = function()
    EnsureDb()
    if not STATE.db then return end
    if not STATE.taxiForceSimplifyTransitWaypoints then
        STATE.taxiTransitRoutingWasSimplified = nil
        STATE.taxiNextRefreshAt = 0
        return
    end

    STATE.taxiForceSimplifyTransitWaypoints = false
    STATE.taxiTransitRoutingWasSimplified = nil
    STATE.taxiNextRefreshAt = 0

    InvalidateRoute("taxi transit routing restored")
    RefreshUiHeader()
    dbg("taxi: transit routing restored")
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

function CW.DirectFlyingCostSeconds(wx1, wy1, wx2, wy2)
    local yardsPerSecond = ((STATE.db and STATE.db.walkYardsPerSecond) or 7) * 2.8
    if yardsPerSecond <= 0 then yardsPerSecond = 19.6 end
    local d = Dist(wx1, wy1, wx2, wy2)
    if not d then
        return huge
    end
    return WorldToYards(d) / yardsPerSecond
end

function CW.CanFlyBetweenMapIds(fromMaI, toMaI)
    local fromRegion = CW.GetFlyableExpansionRegion(fromMaI)
    local toRegion = CW.GetFlyableExpansionRegion(toMaI)
    return fromRegion ~= nil and fromRegion == toRegion and CW.PlayerCanFlyInRegion(fromMaI) == true
end

local function MovementCostTypeLabel(fromMaI, wx1, wy1, toMaI, wx2, wy2, walkLabel, flyLabel)
    if CW.CanFlyBetweenMapIds(fromMaI, toMaI) then
        return CW.DirectFlyingCostSeconds(wx1, wy1, wx2, wy2), "flying", flyLabel or "fly"
    end
    return WalkCostSeconds(wx1, wy1, wx2, wy2), "walk", walkLabel or "walk"
end

local function IsRealTransportType(edgeType)
    return edgeType and STRAIGHT_EDGE_TYPES[edgeType] or false
end

local function IsTransitEdgeType(edgeType)
    return edgeType and TRANSIT_EDGE_TYPES[edgeType] or false
end

local function InferTransportType(name1, name2)
    local s = lower((name1 or "") .. " " .. (name2 or ""))
    if match(s, "flight master") or match(s, "taxi") or match(s, "gryphon") or match(s, "wind rider") then return "flight_master" end
    if match(s, "zeppelin") then return "zeppelin" end
    if match(s, "boat") then return "boat" end
    if match(s, "tram") then return "tram" end
    if match(s, "portal") then return "portal" end
    return "transport"
end

local function InferConnectorEdgeType(coT, name1, name2)
    if coT == 1 then
        return "connector"
    end
    return InferTransportType(name1, name2)
end

local function TransportCostSeconds(transportType, wx1, wy1, wx2, wy2)
    transportType = CanonicalTransportKind(transportType)
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
    elseif transportType == "flight_master" then
        local yards = WorldToYards(Dist(wx1, wy1, wx2, wy2))
        local speed = tonumber(tuning.flightMasterSpeedYardsPerSecond) or 15
        if speed < 1 then speed = 1 end
        base = (tonumber(tuning.flightMasterBoardingSeconds) or 20)
            + (yards / speed)
            + (tonumber(tuning.flightMasterLandingSeconds) or 12)
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
    elseif transportType == "flight_master" then
        if adjusted < 20 then adjusted = 20 end
    else
        if adjusted < 10 then adjusted = 10 end
    end

    return adjusted
end

local function LearnedTransportKey(edge)
    return BuildTransportRecordKey(edge)
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
        NormalizeTransportRecord(edge)
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
            NormalizeTransportRecord(copy)
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

local function TransportLabel(edge)
    edge = NormalizeTransportRecord(edge)
    local kind = CanonicalTransportKind(GetEdgeTransportKind(edge))
    local prefix = "Learned transport"
    if kind == "portal" then
        prefix = "Learned Portal"
    elseif kind == "passage" then
        prefix = "Passage"
    elseif kind == "zeppelin" then
        prefix = "Zeppelin"
    elseif kind == "boat" then
        prefix = "Boat"
    elseif kind == "tram" then
        prefix = "Tram"
    elseif kind == "flight_master" then
        prefix = "Flight Master"
    end
    return tostring(edge.label or (prefix .. ": " .. tostring(edge.fromMapName or edge.fromMaI or "?") .. " -> " .. tostring(edge.toMapName or edge.toMaI or "?")))
end

local function InjectLearnedTransportEdges(addNode, addEdge, graph)
    local learned = EnsureTransportDb()
    if not learned or #learned == 0 then return end
    for _, edge in ipairs(learned) do
        if edge.fromMaI and edge.toMaI and edge.fromWx and edge.fromWy and edge.toWx and edge.toWy then
            NormalizeTransportRecord(edge)
            local edgeType = CanonicalTransportKind(edge.transportKind or edge.type or "transport")
            if not (ShouldSuppressFlightMasterRouting() and IsFlightMasterKind(edgeType)) then
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
                local hopCost = TransportCostSeconds(edgeType, edge.fromWx, edge.fromWy, edge.toWx, edge.toWy)
                addEdge(n1, n2, hopCost, edgeType, TransportLabel(edge), IsBidirectionalTransportRecord(edge), { learnedHop = (edgeType == "portal") })
                graph.links[#graph.links + 1] = { a = n1, b = n2, type = edgeType, learned = true, bidirectional = IsBidirectionalTransportRecord(edge) }
            end
        end
    end
end

-- Known-route hops are intentional user-authored shortcuts. Keep them in the
-- deep graph with a strongly preferred synthetic hop cost so the pathfinder
-- will choose a saved route when it actually lines up with the requested trip.
local function GetKnownRouteHopCostSeconds(loc, a, b)
    local transportKind = CanonicalTransportKind(InferStoredTransportKind(loc) or "route")
    if transportKind == "route" then
        return math.max(6, WalkCostSeconds(a.wx, a.wy, b.wx, b.wy))
    end
    return TransportCostSeconds(transportKind, a.wx, a.wy, b.wx, b.wy)
end

local function InjectKnownTransportEdges(addNode, addEdge, graph, map)
    local known = STATE.db and STATE.db.knownLocations or nil
    if type(known) ~= "table" or #known == 0 then return end
    if not (map and map.GZP) then return end

    local function validMapPoint(maI, wx, wy)
        local ok, zx, zy = pcall(map.GZP, map, maI, wx, wy)
        return ok and zx and zy and zx >= 0 and zx <= 100 and zy >= 0 and zy <= 100
    end

    for _, loc in ipairs(known) do
        if loc and tostring(loc.kind or "") == "transport" then
            local edge = CW.BuildManualTransportLikeEdgeFromKnownLocation(loc)
            if edge and edge.toMaI and edge.toWx and edge.toWy then
                local transportKind = CanonicalTransportKind(edge.transportKind or "transport")
                if ShouldSuppressFlightMasterRouting() and IsFlightMasterKind(transportKind) then
                    -- In flying-mount mode, manual FM/taxi transports must not be graph candidates.
                else
                    local label = tostring(edge.label or edge.name or edge.toZoneName or edge.toMapName or "Known transport")
                    local bidirectional = IsBidirectionalTransportRecord(edge)
                    local toNode = addNode(edge.toMaI, edge.toWx, edge.toWy, edge.toMapName or tostring(edge.toMaI), "transport")
                    if graph.nodes[toNode] then
                        graph.nodes[toNode].knownTransport = true
                        graph.nodes[toNode].knownTransportLabel = label
                    end

                    if CW.IsSingleNodeManualTransportEdge(edge) then
                        local aliasMaI = CW.ResolveBestMapIdFromTransportAliases(edge)
                        if aliasMaI and tonumber(aliasMaI) and tonumber(aliasMaI) ~= tonumber(edge.toMaI) and validMapPoint(aliasMaI, edge.toWx, edge.toWy) then
                            local aliasLabel = tostring(edge.toZoneName or edge.toSubZoneText or edge.toZoneText or label)
                            local fromNode = addNode(aliasMaI, edge.toWx, edge.toWy, aliasLabel, "transport")
                            if graph.nodes[fromNode] then
                                graph.nodes[fromNode].knownTransport = true
                                graph.nodes[fromNode].knownTransportLabel = label
                            end
                            addEdge(fromNode, toNode, TransportCostSeconds(transportKind, edge.toWx, edge.toWy, edge.toWx, edge.toWy), transportKind, label, bidirectional)
                            graph.links[#graph.links + 1] = { a = fromNode, b = toNode, type = transportKind, knownTransport = true, bidirectional = bidirectional }
                        end
                    elseif edge.fromMaI and edge.fromWx and edge.fromWy then
                        local fromNode = addNode(edge.fromMaI, edge.fromWx, edge.fromWy, edge.fromMapName or tostring(edge.fromMaI), "transport")
                        if graph.nodes[fromNode] then
                            graph.nodes[fromNode].knownTransport = true
                            graph.nodes[fromNode].knownTransportLabel = label
                        end
                        addEdge(fromNode, toNode, TransportCostSeconds(transportKind, edge.fromWx, edge.fromWy, edge.toWx, edge.toWy), transportKind, label, bidirectional)
                        graph.links[#graph.links + 1] = { a = fromNode, b = toNode, type = transportKind, knownTransport = true, bidirectional = bidirectional }
                    end
                end
            end
        end
    end
end

local function InjectKnownRouteEdges(addNode, addEdge, graph)
    local known = STATE.db and STATE.db.knownLocations or nil
    if type(known) ~= "table" or #known == 0 then return end

    for _, loc in ipairs(known) do
        if loc and loc.kind == "route" and type(loc.routePoints) == "table" and #loc.routePoints >= 2 then
            local routeKind = CanonicalTransportKind(InferStoredTransportKind(loc) or "route")
            if ShouldSuppressFlightMasterRouting() and IsFlightMasterKind(routeKind) then
                -- Saved FM routes are intentionally ignored in flying-mount mode.
            else
                local routeName = tostring(loc.name or loc.label or "Known route")
                local lastSegmentIndex = #loc.routePoints - 1

                for i = 1, lastSegmentIndex do
                    local a = loc.routePoints[i]
                    local b = loc.routePoints[i + 1]

                    if a and b and a.maI and b.maI and a.wx and a.wy and b.wx and b.wy then
                        local n1 = addNode(a.maI, a.wx, a.wy, a.mapName or tostring(a.maI), "route")
                        local n2 = addNode(b.maI, b.wx, b.wy, b.mapName or tostring(b.maI), "route")

                        if graph.nodes[n1] then
                            graph.nodes[n1].knownRoute = true
                            graph.nodes[n1].knownRouteName = routeName
                            if i == 1 then
                                graph.nodes[n1].knownRouteTerminal = true
                            end
                        end
                        if graph.nodes[n2] then
                            graph.nodes[n2].knownRoute = true
                            graph.nodes[n2].knownRouteName = routeName
                            if i == lastSegmentIndex then
                                graph.nodes[n2].knownRouteTerminal = true
                            end
                        end

                        local isBidirectional = (loc.bidirectional == true) or routeKind == "flight_master"
                        addEdge(n1, n2, GetKnownRouteHopCostSeconds(loc, a, b), routeKind, "Known route: " .. routeName, isBidirectional, {
                            routeTransportKind = routeKind,
                        })
                        graph.links[#graph.links + 1] = { a = n1, b = n2, type = routeKind, knownRoute = true, bidirectional = isBidirectional }
                    end
                end
            end
        end
    end
end

local function ConnectorCostSeconds(edgeType, wx1, wy1, wx2, wy2)
    if edgeType == "connector" then
        return WalkCostSeconds(wx1, wy1, wx2, wy2)
    end
    return TransportCostSeconds(edgeType, wx1, wy1, wx2, wy2)
end

local function BuildKnownTaxiLookup()
    local out = {}

    if NxCData and type(NxCData["Taxi"]) == "table" then
        for taxiName, known in pairs(NxCData["Taxi"]) do
            if known then
                for key in pairs(CW.BuildTaxiKeyVariants(taxiName)) do
                    out[key] = taxiName
                end
            end
        end
    end

    if type(STATE.sessionKnownTaxis) == "table" then
        for key, taxiName in pairs(STATE.sessionKnownTaxis) do
            if key and taxiName and out[key] == nil then
                out[key] = taxiName
            end
        end
    end

    return out
end

local function NormalizeTaxiKey(name)
    if not name then return nil end
    name = tostring(name)
    name = gsub(name, "^%s+", "")
    name = gsub(name, "%s+$", "")
    name = gsub(name, "[%(%)]", " ")
    name = gsub(name, "[,:%-%./']", " ")
    name = gsub(name, "%s+", " ")
    name = gsub(name, "^%s+", "")
    name = gsub(name, "%s+$", "")
    return lower(name)
end

local function BuildKnownTaxiNodes(map)
    if not (STATE.db and STATE.db.useFlightMasters) then return {} end
    if ShouldSuppressFlightMasterRouting() then return {} end
    if STATE.db and IsTransitSimplifiedEffective() then return {} end
    if not Nx or not Nx.Tra then
        return {}
    end

    local knownLookup = BuildKnownTaxiLookup()
    if not next(knownLookup) then
        return {}
    end

    local out = {}
    local seen = {}
    local rawCandidates = {}

    local function FindKnownTaxiName(nameA, nameB)
        for key in pairs(CW.BuildTaxiKeyVariants(nameA)) do
            if knownLookup[key] then
                return knownLookup[key], key
            end
        end
        for key in pairs(CW.BuildTaxiKeyVariants(nameB)) do
            if knownLookup[key] then
                return knownLookup[key], key
            end
        end
        return nil, nil
    end

    local function pushTaxiAny(taxiName, npcName, maI, wx, wy, knownTaxiName)
        local canonicalName = knownTaxiName or taxiName
        local canonicalKey = NormalizeTaxiKey(canonicalName)
        if not canonicalKey or seen[canonicalKey] then return end
        if not (maI and wx and wy) then return end

        local ok, zx, zy = pcall(map.GZP, map, maI, wx, wy)
        if not (ok and zx and zy and zx >= 0 and zx <= 100 and zy >= 0 and zy <= 100) then return end

        seen[canonicalKey] = true
        out[#out + 1] = {
            taxiName = canonicalName,
            npcName = npcName or canonicalName,
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
                        rawCandidates[#rawCandidates + 1] = {
                            taxiName = nod.LoN,
                            npcName = nod.Nam or nod.LoN,
                            maI = nod.MaI,
                            wx = nod.WX,
                            wy = nod.WY,
                        }
                    end
                end
            end
        end
    end

    for _, cand in ipairs(rawCandidates) do
        local knownTaxiName = FindKnownTaxiName(cand.taxiName, cand.npcName)
        if knownTaxiName then
            pushTaxiAny(cand.taxiName, cand.npcName, cand.maI, cand.wx, cand.wy, knownTaxiName)
        end
    end

    if Nx.Map and Nx.Map.Gui and type(Nx.Map.Gui.FiT2) == "function" then
        for _, knownTaxiName in pairs(knownLookup) do
            local canonicalKey = NormalizeTaxiKey(knownTaxiName)
            if canonicalKey and not seen[canonicalKey] then
                local npcName, wx, wy = Nx.Map.Gui:FiT2(knownTaxiName)
                if wx and wy then
                    local bestMapId, bestDist2 = nil, nil

                    for _, cand in ipairs(rawCandidates) do
                        local matchedName = FindKnownTaxiName(cand.taxiName, cand.npcName)
                        if matchedName == knownTaxiName and cand.maI then
                            local ok, zx, zy = pcall(map.GZP, map, cand.maI, wx, wy)
                            if ok and zx and zy and zx >= 0 and zx <= 100 and zy >= 0 and zy <= 100 then
                                local dx = zx - 50
                                local dy = zy - 50
                                local dist2 = dx * dx + dy * dy
                                if not bestDist2 or dist2 < bestDist2 then
                                    bestMapId, bestDist2 = cand.maI, dist2
                                end
                            end
                        end
                    end

                    if not bestMapId then
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
                    end

                    if bestMapId then
                        pushTaxiAny(knownTaxiName, npcName or knownTaxiName, bestMapId, wx, wy, knownTaxiName)
                    end
                end
            end
        end
    end

    return out
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

local function GetMapContinentForMaI(maI)
    if not (maI and Nx and Nx.Map and Nx.Map.CZ2I) then return nil end
    for continent, zoneMap in pairs(Nx.Map.CZ2I) do
        if type(zoneMap) == "table" then
            for _, candidateMaI in pairs(zoneMap) do
                if candidateMaI == maI then
                    return continent
                end
            end
        end
    end
    return nil
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
            continent = GetMapContinentForMaI(maI),
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
            routeTransportKind = opts.routeTransportKind,
        })
        graph.edgeCount = graph.edgeCount + 1
        if bidirectional then
            tinsert(graph.nodes[b].edges, {
                to = a,
                cost = cost,
                type = edgeType,
                label = label,
                learnedHop = opts.learnedHop,
                routeTransportKind = opts.routeTransportKind,
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
            if not (ShouldSuppressFlightMasterRouting() and IsFlightMasterKind(edgeType)) then
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
    end

    InjectLearnedTransportEdges(addNode, addEdge, graph)
    InjectKnownTransportEdges(addNode, addEdge, graph, map)
    InjectKnownRouteEdges(addNode, addEdge, graph)

    local taxiNodes = BuildKnownTaxiNodes(map)
    local taxiNodeIds = {}
    if #taxiNodes > 0 and Nx and Nx.Tra and type(Nx.Tra.TFCT) == "function" then
        for _, taxi in ipairs(taxiNodes) do
            local nodeId = addNode(taxi.maI, taxi.wx, taxi.wy, taxi.taxiName, "transport")
            taxiNodeIds[#taxiNodeIds + 1] = { id = nodeId, taxiName = taxi.taxiName, npcName = taxi.npcName, maI = taxi.maI, wx = taxi.wx, wy = taxi.wy }
        end

        for i = 1, #taxiNodeIds do
            local a = taxiNodeIds[i]
            for j = i + 1, #taxiNodeIds do
                local b = taxiNodeIds[j]
                local ok, directCost = pcall(Nx.Tra.TFCT, Nx.Tra, a.taxiName, b.taxiName)
                if ok and directCost and directCost > 0 then
                    addEdge(a.id, b.id, TransportCostSeconds("flight_master", a.wx, a.wy, b.wx, b.wy), "flight_master", format("Flight Master: %s -> %s", tostring(a.taxiName), tostring(b.taxiName)), true)
                    graph.links[#graph.links + 1] = {a = a.id, b = b.id, type = "flight_master"}
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
        return t == "connector" or t == "transport" or t == "route"
    end
    for i = 1, graph.nodeCount do
        local ni = graph.nodes[i]
        local sameMap = {}
        for j = 1, graph.nodeCount do
            if i ~= j then
                local nj = graph.nodes[j]
                if ni.maI == nj.maI or CW.CanFlyBetweenMapIds(ni.maI, nj.maI) then
                    local baseCost, moveType, moveLabel = MovementCostTypeLabel(ni.maI, ni.wx, ni.wy, nj.maI, nj.wx, nj.wy, "walk", "fly")
                    if baseCost <= walkRadius or moveType == "flying" then
                        sameMap[#sameMap + 1] = { id = j, cost = math.max(1, baseCost), forced = false, moveType = moveType, moveLabel = moveLabel }
                    elseif IsTravelNodeType(ni.type) and IsTravelNodeType(nj.type) then
                        sameMap[#sameMap + 1] = { id = j, cost = baseCost + forcedWalkPenalty, forced = true, moveType = moveType, moveLabel = moveLabel == "fly" and "fly-penalized" or "walk-penalized" }
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
                    addEdge(i, cand.id, cand.cost, cand.moveType or "walk", cand.moveLabel or "walk", false)
                    added = added + 1
                end
            elseif added == 0 and forcedAdded < 1 then
                addEdge(i, cand.id, cand.cost, cand.moveType or "walk", cand.moveLabel or "walk-penalized", false)
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

local function CollapseDeepTaxiChains(points)
    if type(points) ~= "table" or #points <= 2 then
        return points
    end

    local out = {}
    local i = 1
    local maxConnectorCost = 35
    local maxConnectorYards = 180
    local compressibleConnectorTypes = {
        ["walk-to-transport"] = true,
        walk = true,
        connector = true,
        walklink = true,
    }

    local function ClonePoint(pt)
        local copy = {}
        for k, v in pairs(pt or {}) do
            copy[k] = v
        end
        return copy
    end

    local function IsFlightMasterRoutePoint(pt)
        if not pt then return false end
        local kind = CanonicalTransportKind(pt.transportKind or pt.edgeType)
        return kind == "flight_master"
    end

    local function GetFlightMasterChainStartName(pt)
        if not pt then return nil end
        local label = tostring(pt.label or "")
        local fromName = match(label, "^Flight Master:%s*(.-)%s*%-%>")
        if fromName and fromName ~= "" then
            return fromName
        end
        return pt.mapName or tostring(pt.maI or "?")
    end

    local function GetFlightMasterChainEndName(pt)
        if not pt then return nil end
        local label = tostring(pt.label or "")
        local toName = match(label, "%-%>%s*(.-)%s*$")
        if toName and toName ~= "" then
            return toName
        end
        return pt.mapName or tostring(pt.maI or "?")
    end

    local function IsMinorFlightMasterConnector(pt)
        if not pt then return false end
        if pt.edgeType ~= "walk-to-transport" then return false end
        local cost = tonumber(pt.cost) or huge
        return cost <= 3
    end

    local function IsCompressibleFlightMasterConnector(prevFlightPt, connectorPt, nextFlightPt)
        if not (prevFlightPt and connectorPt and nextFlightPt) then return false end
        if not compressibleConnectorTypes[connectorPt.edgeType] then return false end
        if not IsFlightMasterRoutePoint(nextFlightPt) then return false end
        if prevFlightPt.maI ~= connectorPt.maI then return false end

        local cost = tonumber(connectorPt.cost) or huge
        if cost <= 0 then
            return true
        end
        if cost <= 3 and IsMinorFlightMasterConnector(connectorPt) then
            return true
        end
        if cost > maxConnectorCost then
            return false
        end
        return IsNearWorldPoint(prevFlightPt.wx, prevFlightPt.wy, connectorPt.wx, connectorPt.wy, maxConnectorYards)
    end

    while i <= #points do
        local pt = points[i]

        if IsFlightMasterRoutePoint(pt) then
            local chainStart = i
            local chainEnd = i
            local totalTaxiCost = tonumber(pt.cost) or 0
            local lastFlightIndex = i
            local collapsedConnector = false

            while chainEnd < #points do
                local nextPt = points[chainEnd + 1]
                if IsFlightMasterRoutePoint(nextPt) then
                    chainEnd = chainEnd + 1
                    lastFlightIndex = chainEnd
                    totalTaxiCost = totalTaxiCost + (tonumber(nextPt.cost) or 0)
                elseif chainEnd + 2 <= #points and IsCompressibleFlightMasterConnector(points[lastFlightIndex], nextPt, points[chainEnd + 2]) then
                    chainEnd = chainEnd + 1
                    totalTaxiCost = totalTaxiCost + (tonumber(nextPt.cost) or 0)
                    collapsedConnector = true
                else
                    break
                end
            end

            if lastFlightIndex > chainStart then
                local firstTaxiPoint = points[chainStart]
                local lastTaxiPoint = points[lastFlightIndex]
                local collapsed = ClonePoint(lastTaxiPoint)

                collapsed.edgeType = "flight_master"
                collapsed.transportKind = "flight_master"
                collapsed.cost = totalTaxiCost
                collapsed.transportChainStart = chainStart
                collapsed.transportChainEnd = lastFlightIndex
                collapsed.collapsedMinorConnector = collapsedConnector

                local fromName = GetFlightMasterChainStartName(firstTaxiPoint)
                local toName = GetFlightMasterChainEndName(lastTaxiPoint)
                collapsed.label = "Flight Master: " .. tostring(fromName) .. " -> " .. tostring(toName)

                out[#out + 1] = collapsed
                i = chainEnd + 1
            else
                local single = ClonePoint(pt)
                single.edgeType = "flight_master"
                single.transportKind = "flight_master"
                out[#out + 1] = single
                i = i + 1
            end
        else
            out[#out + 1] = ClonePoint(pt)
            i = i + 1
        end
    end

    return out
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
                local edgeKind = CanonicalTransportKind(e.routeTransportKind or e.type)
                if not (ShouldSuppressFlightMasterRouting() and IsFlightMasterKind(edgeKind)) then
                    copyEdges[#copyEdges + 1] = {
                        to = e.to,
                        cost = e.cost,
                        type = e.type,
                        label = e.label,
                        learnedHop = e.learnedHop,
                        routeTransportKind = e.routeTransportKind,
                    }
                end
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
                knownRoute = n.knownRoute and true or false,
                                knownRouteName = n.knownRouteName,
                knownRouteTerminal = n.knownRouteTerminal and true or false,
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
            continent = pt.continent or GetMapContinentForMaI(pt.maI),
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
        local allowContinentFallback = not isGoal
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
            if type(id) == "number"
                and id ~= queryId
                and (n.maI == preferMapId or CW.CanFlyBetweenMapIds(preferMapId, n.maI))
                and n.type ~= "start"
                and n.type ~= "goal" then

                local raw, moveType, moveLabel = MovementCostTypeLabel(preferMapId, nodes[queryId].wx, nodes[queryId].wy, n.maI, n.wx, n.wy, outwardLabel, isStart and "fly-to-node" or "fly-to-goal")
                local yards = WorldToYards(Dist(nodes[queryId].wx, nodes[queryId].wy, n.wx, n.wy))
                local pe, te = countPortalTaxi(n)

                local candidate = {
                    moveType = moveType,
                    moveLabel = moveLabel,
                    id = id,
                    rawCost = raw,
                    yards = yards,
                    learnedS = n.learnedPortalSource and true or false,
                    learnedD = n.learnedPortalDest and true or false,
                    taxiHub = n.taxiHub and true or false,
                    knownRoute = n.knownRoute and true or false,
                    knownRouteName = n.knownRouteName,
                    knownRouteTerminal = n.knownRouteTerminal and true or false,
                    portalEdges = pe,
                    taxiEdges = te,
                }
                candidate.score = GetAttachCandidateScoreSeconds(raw, candidate, isStart, isGoal)
                sameMap[#sameMap + 1] = candidate
            end
        end

        -- Same-continent fallback is only safe for the start side.
        -- For the goal side, attaching to an arbitrary continent node when the
        -- destination map has no real graph node creates bogus anchors (for
        -- example Dalaran -> Underbelly without a learned transport/passsage).
        -- In that case we want the caller to fall back to a direct destination
        -- leg instead of inventing a transport-adjacent anchor.
        if #sameMap == 0 and preferContinent and allowContinentFallback then
            for id, n in pairs(nodes) do
                if type(id) == "number"
                    and id ~= queryId
                    and n.continent == preferContinent
                    and n.type ~= "start"
                    and n.type ~= "goal" then

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
                    knownRoute = n.knownRoute and true or false,
                    knownRouteName = n.knownRouteName,
                    knownRouteTerminal = n.knownRouteTerminal and true or false,
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
                connectBidirectional(queryId, c.id, c.rawCost, c.moveType or "walk", c.moveLabel or outwardLabel)
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
                    connectBidirectional(queryId, c.id, c.rawCost, c.moveType or "walk", c.moveLabel or outwardLabel)
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
            transportKind = edge and (edge.routeTransportKind or edge.type) or nil,
            label = edge and edge.label or n.label or n.type,
            cost = edge and edge.cost or 0,
        })
    end

    if STATE.db and STATE.db.simplifyTransitWaypoints then
        route.points = CollapseMinimalTransitNoise(CollapseDeepTaxiChains(route.points))
    else
        route.points = CollapseDeepTaxiChains(route.points)
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

    local useDirectFlying = CW.CanUseCapabilityDirectFlyingLeg(startPoint, destPoint)
    local directCost = useDirectFlying
        and CW.DirectFlyingCostSeconds(startPoint.wx, startPoint.wy, destPoint.wx, destPoint.wy)
        or WalkCostSeconds(startPoint.wx, startPoint.wy, destPoint.wx, destPoint.wy)
    if IsPlayerOnTaxi() and destPoint and destPoint.cwTaxiInjected then
        local directTaxiCost = WalkCostSeconds(startPoint.wx, startPoint.wy, destPoint.wx, destPoint.wy)
        return {
            totalCost = directTaxiCost,
            explored = 1,
            fallbackDirect = true,
            activeTaxiLeg = true,
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
                    edgeType = "flight_master",
                    transportKind = "flight_master",
                    label = destPoint.userName or destPoint.mapName or "Taxi destination",
                    cost = directTaxiCost,
                    forceStraight = true,
                }
            },
        }
    end

    local directLeg = {
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
                edgeType = useDirectFlying and "flying" or "walk",
                label = useDirectFlying and "Direct flight" or (startPoint.maI ~= destPoint.maI and "Direct destination" or "Walk"),
                cost = directCost,
                forceStraight = useDirectFlying or startPoint.maI ~= destPoint.maI,
            }
        },
    }

    if useDirectFlying then
        return directLeg
    end

    if STATE.db and STATE.db.useIntercontinentalRouting then
        local route, why = BuildTransportLeg(startPoint, destPoint)
        if route then
            -- Same-map legs must still be allowed to use FM/transport when cheaper.
            if startPoint.maI == destPoint.maI then
                local routeCost = tonumber(route.totalCost) or huge
                if route.transportUsed and not CW.DoesPointMatchCurrentZoneContext(destPoint) and routeCost <= directCost + 10 then
                    return route
                end
                return directLeg
            end

            return route
        end

        local startCont = startPoint.continent or nil
        local destCont = destPoint.continent or nil
        local crossContinent = startCont and destCont and startCont ~= destCont

        if crossContinent then
            return BuildDirectFallbackLeg(startPoint, destPoint, why, true)
        end

        local forcedSouthKalimdor = BuildSouthKalimdorFallbackLeg(startPoint, destPoint, why)
        if forcedSouthKalimdor then
            return forcedSouthKalimdor
        end

        if STATE.db and not STATE.db.simplifyTransitWaypoints then
            dbg("deep graph fallback to direct destination: " .. tostring(why))
        else
            dbg("graph leg fallback to direct walk: " .. tostring(why))
        end
    end

    return directLeg
end

local function BuildExpandedRoute()
    local map = GetMap()
    if not map then return nil, "no-map" end

    if #STATE.db.destinations == 0 then
        STATE.expandedRoute = nil
        return {points = {}, summary = "empty"}
    end

    local current = GetRouteBuildStartPoint()
    if not current then return nil, "no-player-pos" end

    local route = {
        totalCost = 0,
        explored = 0,
        points = {},
        -- Cached route origin used by lightweight world-context refresh guards.
        -- Zone/subzone changes should not rebuild deep routes unless the player
        -- has actually left the cached first-leg context.
        startPoint = CloneWorldPoint(current),
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
            local skipStart = (q > 1 and i == 1)
            local skipSyntheticStart = (q == 1 and i == 1 and current and current.isSyntheticStart)

            if not skipStart and not skipSyntheticStart then
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
    if not pt or pt.edgeType == "start" or pt.isSyntheticStart then return false end

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

    out = CollapseConsecutiveSyncPoints(out)

    if STATE.db then
        local skip = tonumber(STATE.deepSyncSkipCount) or 0
        while skip > 0 and #out > 0 do
            tremove(out, 1)
            skip = skip - 1
        end
    end

    return out
end

function CW.ShouldRefreshRouteForWorldContextChange(event)
    EnsureDb()
    local destinations = STATE.db and STATE.db.destinations or {}
    if #destinations == 0 then return false, "empty-queue" end

    local route = STATE.expandedRoute
    if not (route and type(route.points) == "table" and #route.points > 0) then
        return true, "no-cached-route"
    end

    local player = GetPlayerWorldPos()
    if not player then
        -- A rebuild would likely fail with no-player-pos; keep the existing targets.
        return false, "no-player-position"
    end

    local start = route.startPoint
    if not start then
        return true, "missing-cached-start"
    end

    if (player.instance and not start.instance) or (start.instance and not player.instance) then
        return true, "instance-context-changed"
    end

    local playerMaI = tonumber(player.maI)
    local startMaI = tonumber(start.maI)
    if playerMaI and startMaI and playerMaI ~= startMaI then
        return true, format("carbonite-map-id-changed: %s -> %s", tostring(startMaI), tostring(playerMaI))
    end

    -- Intentional: do not treat walking direction, first-leg deviation, or
    -- waypoint progress as reroute signals. Zone/subzone events are cheap UI
    -- context changes unless Carbonite reports a different map id / instance
    -- context. This keeps deep mode from rebuilding while the user simply moves.
    return false, "same Carbonite map id/context"
end

function CW.RefreshRouteForWorldContextChange(event, reason)
    local shouldRefresh, why = CW.ShouldRefreshRouteForWorldContextChange(event)
    if not shouldRefresh then
        dbg("world-context route refresh skipped (" .. tostring(event) .. "): " .. tostring(why))
        return false
    end

    InvalidateRoute(reason or tostring(event or "world context changed"))
    if STATE.db and STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite(true)
    end
    dbg("world-context route refresh ran (" .. tostring(event) .. "): " .. tostring(why))
    return true
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

    if STATE.db and not IsTransitSimplifiedEffective() then
        return TARGET_TYPE_STRAIGHT
    end

    if UseStraightLineForEdge(pt.edgeType) then
        return TARGET_TYPE_STRAIGHT
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
    elseif edgeType == "flying" then
        detail = "Fly"
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

local function BuildRouteSignature(points)
    if type(points) ~= "table" or #points == 0 then
        return ""
    end

    local parts = {}
    for i = 1, #points do
        local pt = points[i]
        if pt then
            local label = BuildSyncLabel(i, pt) or ""
            local targetType = GetTargetTypeForRoutePoint(pt) or ""
            parts[#parts + 1] = table.concat({
                tostring(i),
                tostring(pt.maI or ""),
                string.format("%.3f", tonumber(pt.wx) or 0),
                string.format("%.3f", tonumber(pt.wy) or 0),
                tostring(pt.edgeType or ""),
                tostring(label),
                tostring(targetType),
            }, "|")
        end
    end

    return table.concat(parts, "||")
end

CW.TryTaxiPeriodicRefresh = function(now)
    EnsureDb()
    if not STATE.db or #(STATE.db.destinations or {}) == 0 then return end
    now = tonumber(now) or 0

    local interval = tonumber(STATE.taxiRefreshInterval) or 4
    if interval < 2 then interval = 2 end

    if now < (STATE.taxiNextRefreshAt or 0) then
        return
    end

    STATE.taxiNextRefreshAt = now + interval

    local oldSignature = nil
    do
        local oldRoute = STATE.expandedRoute
        if oldRoute and type(oldRoute.points) == "table" then
            local oldSyncPoints = BuildSyncPoints(oldRoute.points or {})
            oldSignature = BuildRouteSignature(oldSyncPoints)
        end
    end

    STATE.expandedRoute = nil
    STATE.deepSyncSkipCount = 0

    local newRoute, why = BuildExpandedRoute()
    if not newRoute then
        pr("route rebuild failed: " .. tostring(why))
        return
    end

    local newSyncPoints = BuildSyncPoints(newRoute.points or {})
    local newSignature = BuildRouteSignature(newSyncPoints)

    if oldSignature ~= newSignature then
        if STATE.db.autoSyncToCarbonite then
            SyncQueueToCarbonite()
        end
        dbg("taxi: periodic route refresh (path changed)")
    else
        dbg("taxi: periodic route refresh skipped sync (path unchanged)")
    end
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
    flight_master = "|cffffdd55",
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
        -- Instance entry confirmations must stay stable even when the outdoor
        -- entrance coords wobble or are unavailable on manual entries.
        return table.concat({
            "instance",
            tostring(fromPos.maI or "?"),
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

function CW.BuildInstanceEntryDedupeKey(fromPos, toPos)
    if not fromPos or not toPos or not toPos.instance then return nil end
    return table.concat({
        "instance-entry",
        tostring(fromPos.maI or "?"),
        tostring(toPos.maI or "?"),
        NormalizeKnownInstanceName(toPos),
        tostring(toPos.instanceType or "instance"),
    }, "|")
end

function CW.IsRecentInstanceEntryDuplicate(fromPos, toPos)
    local key = CW.BuildInstanceEntryDedupeKey(fromPos, toPos)
    if not key then return false end

    local now = GetTime and GetTime() or 0
    if now > (STATE.recentInstanceEntryUntil or 0) then
        STATE.recentInstanceEntryKey = nil
        STATE.recentInstanceEntryUntil = 0
        return false
    end

    return STATE.recentInstanceEntryKey == key
end

function CW.RememberRecentInstanceEntry(fromPos, toPos, seconds)
    local key = CW.BuildInstanceEntryDedupeKey(fromPos, toPos)
    if not key then return end
    STATE.recentInstanceEntryKey = key
    STATE.recentInstanceEntryUntil = (GetTime and GetTime() or 0) + (seconds or 4)
end


local CW_ESC_OVERRIDE_BUTTON_NAME = "CustomWaypointsEscOverrideButton"
local CW_DELETE_OVERRIDE_BUTTON_NAME = "CustomWaypointsDeleteOverrideButton"

local EnsureCwEscOverrideButton
local RefreshCwEscOverride
local HideTopCwModalFrame

ShouldEnableKnownLocationsDeleteOverride = function()
    local ui = STATE.knownLocationsUi
    if not ui or not ui.frame or not ui.frame.IsShown or not ui.frame:IsShown() then
        return false
    end

    local searchBox = ui.searchBox
    if not searchBox then
        return true
    end

    if GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus() == searchBox then
        return false
    end

    return true
end

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

    -- During combat, let WoW handle bindings normally.
    if InCombatLockdown and InCombatLockdown() then
        return
    end

    if not SetOverrideBindingClick then
        return
    end

    if hasShown then
        EnsureCwEscOverrideButton()
        SetOverrideBindingClick(owner, true, "ESCAPE", CW_ESC_OVERRIDE_BUTTON_NAME, "LeftButton")
    end

    if ShouldEnableKnownLocationsDeleteOverride and ShouldEnableKnownLocationsDeleteOverride() then
        EnsureCwDeleteOverrideButton()
        SetOverrideBindingClick(owner, true, "SHIFT-DELETE", CW_DELETE_OVERRIDE_BUTTON_NAME, "LeftButton")
    end
end

HideTopCwModalFrame = function()
    local stack = STATE.cwModalStack or {}
    for i = #stack, 1, -1 do
        local f = stack[i]
        if f and f.IsShown and f:IsShown() then
            if f.cwEscAction then
                f.cwEscAction(f)
            else
                f:Hide()
            end
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

EnsureCwDeleteOverrideButton = function()
    local btn = _G[CW_DELETE_OVERRIDE_BUTTON_NAME]
    if btn then return btn end

    btn = CreateFrame("Button", CW_DELETE_OVERRIDE_BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
    btn:SetWidth(1)
    btn:SetHeight(1)
    btn:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 998)
    btn:Hide()
    btn:SetScript("OnClick", function()
        CustomWaypoints_DeleteSelectedKnownLocation()
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
    f:SetHeight(435)
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
        { key = 'flightMasterBoardingSeconds', label = 'Flight master boarding seconds', min = 0, max = 180, step = 1 },
        { key = 'flightMasterSpeedYardsPerSecond', label = 'Flight master speed (yd/s)', min = 1, max = 60, step = 1 },
        { key = 'flightMasterLandingSeconds', label = 'Flight master landing seconds', min = 0, max = 120, step = 1 },
    }

    local sliders = {}
    local topY = -54
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

local function EscapePortableField(value)
    return gsub(tostring(value or ""), "|", "/")
end

NormalizeSignatureNumber = function(value, decimals)
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
BuildKnownLocationSignature = function(loc)
    if not loc then return nil end
    if loc.kind == "route" and type(loc.routePoints) == "table" and #loc.routePoints > 0 then
        local parts = {}
        for i, pt in ipairs(loc.routePoints) do
            parts[i] = BuildWaypointSignature(pt)
        end
        local chain = table.concat(parts, ">")
        local transportKind = CanonicalTransportKind(InferStoredTransportKind(loc) or "route")
        local bidirectional = (loc.bidirectional == true) or (transportKind == "flight_master")
        if bidirectional and #parts >= 2 then
            local rev = {}
            for i = #parts, 1, -1 do
                rev[#rev + 1] = parts[i]
            end
            local revChain = table.concat(rev, ">")
            if revChain < chain then
                chain = revChain
            end
        end
        return "route|" .. transportKind .. "|b=" .. tostring(bidirectional and 1 or 0) .. "|" .. tostring(#parts) .. "|" .. chain
    end

    local dest = loc.destination or loc.lastTarget or loc.previousTarget
    if not dest then return nil end
    return table.concat({
        tostring(loc.kind or "known"),
        tostring(loc.instanceType or ""),
        tostring(CanonicalTransportKind(InferStoredTransportKind(loc) or "")),
        tostring(((loc.bidirectional == true) or CanonicalTransportKind(InferStoredTransportKind(loc)) == "flight_master") and 1 or 0),
        BuildWaypointSignature(dest),
    }, "|")
end

CW.BuildKnownLocationSignature = BuildKnownLocationSignature

FindDuplicateKnownLocationIndex = function(candidate, skipIndex)
    local wanted = CustomWaypoints.BuildKnownLocationSignature and CustomWaypoints.BuildKnownLocationSignature(candidate) or nil
    if not wanted then return nil end
    for i, loc in ipairs(STATE.db and STATE.db.knownLocations or {}) do
        if i ~= skipIndex and CustomWaypoints.BuildKnownLocationSignature and CustomWaypoints.BuildKnownLocationSignature(loc) == wanted then
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

local function TrimField(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
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

local function BuildKnownLocationExportHeader(loc)
    return table.concat({
        "CWKNOWN",
        EscapePortableField(loc.kind or "known"),
        EscapePortableField(loc.name or ""),
        EscapePortableField(loc.label or ""),
        EscapePortableField(loc.description or ""),
        EscapePortableField(loc.instanceType or ""),
        EscapePortableField(CanonicalTransportKind(InferStoredTransportKind(loc) or "")),
        tostring(((loc.bidirectional == true) or CanonicalTransportKind(InferStoredTransportKind(loc)) == "flight_master") and 1 or 0),
        EscapePortableField(loc.zoneNameHint or ""),
        EscapePortableField(loc.trackerLabel or ""),
    }, "|")
end

local function BuildLearnedTransportExportHeader(edge)
    edge = NormalizeTransportRecord(edge)
    return table.concat({
        "CWKNOWN",
        "transport",
        EscapePortableField(edge.label or TransportLabel(edge) or ""),
        "",
        "",
        EscapePortableField(edge.toInstanceType or edge.fromInstanceType or ""),
        EscapePortableField(CanonicalTransportKind(edge.transportKind or "transport")),
        tostring(IsBidirectionalTransportRecord(edge) and 1 or 0),
    }, "|")
end

local function SerializeLearnedTransportLine(edge)
    edge = NormalizeTransportRecord(edge)
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
        EscapePortableField(CanonicalTransportKind(edge.transportKind or "transport")),
        tostring(IsBidirectionalTransportRecord(edge) and 1 or 0),
    }, "|")
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

    return NormalizeTransportRecord({
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
        transportKind = (#parts >= 21 and parts[21] ~= "" and parts[21] ~= "?" and parts[21]) or nil,
        bidirectional = (#parts >= 22 and parts[22] == "1") and true or nil,
    }), nil
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
        transportKind = parts[7] ~= "" and parts[7] or nil,
        bidirectional = parts[8] == "1" and true or nil,
        zoneNameHint = (#parts >= 9 and parts[9] ~= "" and parts[9]) or nil,
        trackerLabel = (#parts >= 10 and parts[10] ~= "" and parts[10]) or nil,
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
            transportKind = CanonicalTransportKind(header.transportKind or "route"),
            bidirectional = (header.bidirectional == true) or CanonicalTransportKind(header.transportKind) == "flight_master",
            zoneNameHint = header.zoneNameHint,
            trackerLabel = header.trackerLabel,
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
        transportKind = CanonicalTransportKind(header.transportKind or ""),
        bidirectional = (header.bidirectional == true) or CanonicalTransportKind(header.transportKind) == "flight_master",
        zoneNameHint = header.zoneNameHint,
        trackerLabel = header.trackerLabel,
        discoveredBy = "import-known-locations",
    }, nil
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

local function BuildSingleKnownLocationImportBlock(loc)
    if not loc then return "" end

    local lines = {}

    if loc.sourceType == "learnedTransport" then
        local edge = nil
        local learned = EnsureTransportDb() or {}
        if loc.sourceIndex and learned[loc.sourceIndex] then
            edge = learned[loc.sourceIndex]
        end
        if not edge and loc.previousTarget and loc.lastTarget then
            edge = {
                fromMaI = loc.previousTarget.maI,
                fromMapName = loc.previousTarget.mapName,
                fromZx = loc.previousTarget.zx,
                fromZy = loc.previousTarget.zy,
                fromWx = loc.previousTarget.wx,
                fromWy = loc.previousTarget.wy,
                toMaI = loc.lastTarget.maI,
                toMapName = loc.lastTarget.mapName,
                toZx = loc.lastTarget.zx,
                toZy = loc.lastTarget.zy,
                toWx = loc.lastTarget.wx,
                toWy = loc.lastTarget.wy,
                label = loc.name,
                fromInstance = loc.previousTarget.instance,
                fromInstanceType = loc.previousTarget.instanceType,
                toInstance = loc.lastTarget.instance,
                toInstanceType = loc.lastTarget.instanceType,
            }
        end
        if not edge then return "" end

        lines[#lines + 1] = BuildLearnedTransportExportHeader(edge)
        lines[#lines + 1] = SerializeLearnedTransportLine(edge)
        return table.concat(lines, "\n")
    end

    lines[#lines + 1] = BuildKnownLocationExportHeader(loc)

    if loc.kind == "route" then
        lines[#lines + 1] = SerializeRoutePointsBlock(loc.routePoints or {})
    else
        local dest = loc.destination or loc.lastTarget or loc.previousTarget
        if dest then
            lines[#lines + 1] = SerializeWaypointLine(1, SanitizeRoutePointForEditing(dest))
        end
    end

    return table.concat(lines, "\n")
end

local function DeduplicateKnownLocationsPreserveOrder(list)
    local out = {}
    local seen = {}
    for _, loc in ipairs(list or {}) do
        local sig = CustomWaypoints.BuildKnownLocationSignature and CustomWaypoints.BuildKnownLocationSignature(loc) or nil
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
                transportKind = CanonicalTransportKind(InferStoredTransportKind(loc) or "route"),
                bidirectional = (loc.bidirectional == true) or CanonicalTransportKind(InferStoredTransportKind(loc)) == "flight_master",
            })
        else
            local dest = CloneKnownLocationDestination(loc)
            if dest then
                local transportHintPoint = nil
                if tostring(loc.kind or "") == "transport" and tostring(loc.zoneNameHint or "") ~= "" then
                    transportHintPoint = {
                        userName = tostring(loc.zoneNameHint),
                        zoneText = tostring(loc.zoneNameHint),
                        subZoneText = tostring(loc.zoneNameHint),
                        mapName = dest.mapName,
                        maI = dest.maI,
                    }
                end
                addEntry({
                    key = tostring(loc.key or ("known|" .. tostring(i))),
                    kind = tostring(loc.kind or "known"),
                    name = tostring((tostring(loc.kind or "") == "transport" and loc.zoneNameHint) or loc.name or dest.mapName or ("Map " .. tostring(dest.maI or "?"))),
                    label = loc.label,
                    description = loc.description,
                    mapName = dest.mapName,
                    destination = dest,
                    previousTarget = loc.previousTarget or loc.entrance,
                    lastTarget = transportHintPoint or loc.lastTarget or loc.destination,
                    instance = (loc.instance == true)
                        or (loc.instanceType and loc.instanceType ~= "" and loc.instanceType ~= "none")
                        or (dest.instance == true)
                        or ((dest.instanceType and dest.instanceType ~= "" and dest.instanceType ~= "none") and true or false),
                    instanceType = loc.instanceType or dest.instanceType,
                    sourceType = "knownLocation",
                    sourceIndex = i,
                    transportKind = CanonicalTransportKind(InferStoredTransportKind(loc) or ""),
                    bidirectional = (loc.bidirectional == true) or CanonicalTransportKind(InferStoredTransportKind(loc)) == "flight_master",
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

        NormalizeTransportRecord(edge)
        addEntry({
            key = "transport|" .. tostring(i) .. "|" .. tostring(BuildTransportRecordKey(edge) or (tostring(edge.fromMaI or "?") .. ">" .. tostring(edge.toMaI or "?"))),
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
            transportKind = CanonicalTransportKind(edge.transportKind or "transport"),
            bidirectional = IsBidirectionalTransportRecord(edge),
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
    if ui and ui.transportsOnly and entry.sourceType ~= "learnedTransport" then
        return false
    end
    if ui and ui.instancesOnly and not entry.instance then
        return false
    end
    if ui and ui.flightMastersOnly and CanonicalTransportKind(entry.transportKind or "") ~= "flight_master" then
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
        dbg(format("loaded known route: %s (%d stop(s))", tostring(entry.name or index), #cloned))
    else
        local dest = CloneKnownLocationDestination(entry)
        if not dest then
            pr("known location has no destination: " .. tostring(entry.name or index))
            return
        end
        tinsert(STATE.db.destinations, dest)
        HandleQueueBecameNonEmpty("route-known-location", wasEmpty)
        dbg(format("routing to known location: %s", tostring(entry.name or dest.mapName or dest.maI)))
    end

    InvalidateRoute("known location selected")
    RefreshUiHeader()

    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end
end

SaveQueueAsKnownRoute = function()
    local function SafePr(msg)
        if type(pr) == "function" then
            pr(msg)
            return
        end
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cff80ff80CW:|r " .. tostring(msg))
        end
    end

    EnsureDb()
    if not STATE.db or #(STATE.db.destinations or {}) == 0 then
        SafePr("saveroute: queue empty")
        return
    end

    local queued = STATE.db.destinations or {}
    local lastQueued = queued[#queued]

    CustomWaypoints.ShowWaypointMetadataPopup({
        title = "Save queue as known route",
        defaultName = "Route " .. date("%Y-%m-%d %H:%M"),
        defaultLabel = "route",
        defaultDescription = "",
        showZoneField = true,
        defaultZoneName = (lastQueued and (lastQueued.subZoneText or lastQueued.zoneText or lastQueued.mapName)) or "",
        extraCheckboxes = {
            { key = "flightMaster", label = "Flight Master", checked = false },
            { key = "passage", label = "Transport", checked = false },
            { key = "bidirectional", label = "Bidirectional", checked = false },
        },
        onRefreshExtraCheckboxes = function(checkboxByKey, setZoneFieldEnabled)
            local fm = checkboxByKey.flightMaster
            local transport = checkboxByKey.passage
            local bidir = checkboxByKey.bidirectional
            if not (fm and transport and bidir) then return end

            local fmChecked = fm.check:GetChecked() and true or false
            local transportChecked = transport.check:GetChecked() and true or false

            if fmChecked and transportChecked then
                transport.check:SetChecked(false)
                transportChecked = false
            end

            if fmChecked then
                bidir.check:SetChecked(true)
                if bidir.check.EnableMouse then bidir.check:EnableMouse(false) end
                if bidir.check.SetAlpha then bidir.check:SetAlpha(0.5) end
            else
                if bidir.check.EnableMouse then bidir.check:EnableMouse(true) end
                if bidir.check.SetAlpha then bidir.check:SetAlpha(1) end
            end

            setZoneFieldEnabled(fmChecked or transportChecked)
        end,
        onSave = function(meta)
            local routePoints = CloneDestinations(STATE.db.destinations)
            local isFlightMaster = meta.extraValues and meta.extraValues.flightMaster == true
            local isTransport = meta.extraValues and meta.extraValues.passage == true
            local isBidirectional = meta.extraValues and meta.extraValues.bidirectional == true
            local isTransportLike = isTransport or isFlightMaster
            local zoneHint = tostring(meta.zoneName or ""):gsub("^%s+", ""):gsub("%s+$", "")

            meta._cwSavedTransportName = nil
            meta._cwSavedTransportOnly = nil

            if isTransportLike then
                if #routePoints ~= 1 and #routePoints ~= 2 then
                    SafePr("save transport failed: use 1 queue point (destination anchor) or 2 queue points (entry -> destination)")
                    return
                end

                STATE.db.knownLocations = STATE.db.knownLocations or {}
                local transportKind = isFlightMaster and "flight_master" or "passage"
                local transportName = (meta.name ~= "" and meta.name) or (meta.label ~= "" and meta.label) or (zoneHint ~= "" and zoneHint) or (routePoints[#routePoints] and routePoints[#routePoints].mapName) or "Transport"

                if #routePoints == 2 then
                    local learned = EnsureTransportDb()
                    local edge, why = CW.BuildManualTransportFromRoutePoints(routePoints, {
                        label = meta.label ~= "" and meta.label or meta.name,
                        description = meta.description ~= "" and meta.description or nil,
                        transportKind = transportKind,
                        bidirectional = isFlightMaster and true or isBidirectional,
                        discoveredBy = "manual-saveroute",
                    })
                    if not edge then
                        SafePr("save transport failed: " .. tostring(why))
                        return
                    end

                    if zoneHint ~= "" then
                        edge.toZoneName = zoneHint
                        edge.toZoneText = zoneHint
                        edge.toSubZoneText = zoneHint
                    end

                    local dupKey = BuildTransportRecordKey(edge)
                    meta._cwSavedTransportName = tostring(transportName)

                    for _, existing in ipairs(learned or {}) do
                        if BuildTransportRecordKey(existing) == dupKey then
                            meta._cwSavedTransportOnly = true
                            break
                        end
                    end

                    if not meta._cwSavedTransportOnly then
                        learned[#learned + 1] = edge
                    end

                    InvalidateRoute("saved manual transport")
                    RefreshKnownLocationsFrame()
                    if meta._cwSavedTransportOnly then
                        SafePr("saved known transport skipped: duplicate of existing transport " .. tostring(meta._cwSavedTransportName))
                    else
                        SafePr("saved known transport: " .. tostring(meta._cwSavedTransportName))
                    end
                    return
                end

                local singleDest = CloneDestination(routePoints[1])
                if not singleDest then
                    SafePr("save transport failed: missing destination anchor")
                    return
                end

                local effectiveZoneHint = zoneHint ~= "" and zoneHint or singleDest.subZoneText or singleDest.zoneText or singleDest.mapName or transportName
                local candidate = {
                    key = "transport|" .. tostring(time and time() or GetTime() or math.random(100000, 999999)),
                    kind = "transport",
                    name = effectiveZoneHint,
                    label = effectiveZoneHint,
                    trackerLabel = (meta.label ~= "" and meta.label) or (meta.name ~= "" and meta.name) or nil,
                    description = meta.description ~= "" and meta.description or nil,
                    destination = singleDest,
                    mapName = singleDest.mapName,
                    transportKind = transportKind,
                    bidirectional = isFlightMaster and true or isBidirectional,
                    zoneNameHint = effectiveZoneHint,
                    discoveredBy = "manual-saveroute",
                }

                local duplicateIndex = FindDuplicateKnownLocationIndex(candidate)
                if duplicateIndex then
                    SafePr("saved known transport skipped: duplicate of existing known location #" .. tostring(duplicateIndex))
                    return
                end

                STATE.db.knownLocations[#STATE.db.knownLocations + 1] = candidate
                InvalidateRoute("saved manual transport anchor")
                RefreshKnownLocationsFrame()
                dbg("saved known transport: " .. tostring(candidate.name or candidate.key))
                return
            end

            local key = "route|" .. tostring(time and time() or GetTime() or math.random(100000, 999999))
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
                transportKind = "route",
                bidirectional = false,
                discoveredBy = "manual-saveroute",
            }

            local duplicateIndex = FindDuplicateKnownLocationIndex(candidate)
            if duplicateIndex then
                SafePr("saved known route skipped: duplicate of existing known location #" .. tostring(duplicateIndex))
                return
            end

            STATE.db.knownLocations[#STATE.db.knownLocations + 1] = candidate
            SafePr("saved known route: " .. tostring(meta.name ~= "" and meta.name or key))
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
        local transportIndex = entry.sourceIndex
        if (not transportIndex or not learned[transportIndex]) and entry.key then
            for i, candidate in ipairs(BuildKnownLocationEntries()) do
                if candidate.key == entry.key and candidate.sourceType == "learnedTransport" then
                    transportIndex = candidate.sourceIndex
                    break
                end
            end
        end
        if not transportIndex or not learned[transportIndex] then
            pr("delete failed: learned transport not found")
            return false
        end
        table.remove(learned, transportIndex)
        InvalidateRoute("deleted learned transport from known locations")
        dbg("deleted learned transport: " .. tostring(entry.name or transportIndex))
        return true
    end

    local known = STATE.db.knownLocations or {}
    local sourceIndex = ResolveKnownLocationStoredSourceIndex(entry)
    if (not sourceIndex or not known[sourceIndex]) and entry.key then
        local wantedSignature = CustomWaypoints.BuildKnownLocationSignature and CustomWaypoints.BuildKnownLocationSignature(entry) or nil
        for i, candidate in ipairs(known) do
            if tostring(candidate.key or "") == tostring(entry.key or "") then
                sourceIndex = i
                break
            end
            if wantedSignature and CustomWaypoints.BuildKnownLocationSignature and CustomWaypoints.BuildKnownLocationSignature(candidate) == wantedSignature then
                sourceIndex = i
                break
            end
        end
    end
    if not sourceIndex or not known[sourceIndex] then
        pr("delete failed: known location not found")
        return false
    end

    local removed = known[sourceIndex]
    table.remove(known, sourceIndex)

    InvalidateRoute("deleted known location entry")
    dbg("deleted known location: " .. tostring((removed and removed.name) or entry.name or sourceIndex))
    return true
end

local function TrimEditorMetadataValue(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

CloneLearnedTransport = function(edge)
    local copy = {}
    for k, v in pairs(edge or {}) do
        copy[k] = v
    end
    return copy
end

local function ShowKnownPointEditorPopup(sourceIndex, loc, titleText)
    local frameName = "CustomWaypointsKnownPointEditorPopup"

    if STATE.knownPointEditorPopup and STATE.knownPointEditorPopup.frame then
        STATE.knownPointEditorPopup.frame:Hide()
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
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText(titleText or "Edit known location")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    subtitle:SetWidth(520)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Edit metadata plus the full saved import block for this entry. One exported line per line; order is preserved.")

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

    local function BuildCycleButton(parent, width, height, values, initialValue, formatValue)
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetWidth(width)
        btn:SetHeight(height)
        btn._values = values or {}
        btn._index = 1
        btn._formatValue = formatValue

        local function applyIndex(idx)
            if #btn._values == 0 then return end
            if idx < 1 then idx = #btn._values end
            if idx > #btn._values then idx = 1 end
            btn._index = idx
            local value = btn._values[idx]
            local textValue = formatValue and formatValue(value) or tostring(value or "")
            btn:SetText(textValue)
        end

        function btn:GetSelectedValue()
            return self._values[self._index]
        end

        function btn:SetSelectedValue(value)
            for idx, candidate in ipairs(self._values) do
                if tostring(candidate) == tostring(value) then
                    applyIndex(idx)
                    return
                end
            end
            applyIndex(1)
        end

        btn:SetScript("OnClick", function(self)
            if self.IsEnabled and not self:IsEnabled() then return end
            applyIndex(self._index + 1)
            if self._afterChange then
                self:_afterChange()
            end
        end)

        btn:SetSelectedValue(initialValue)
        return btn
    end

    local isLearnedTransportEntry = loc.sourceType == "learnedTransport"
    local entryTypeValues = isLearnedTransportEntry and { "transport" } or { "route", "instance", "known" }
    local initialEntryType = isLearnedTransportEntry and "transport" or tostring(loc.kind or "known")
    if initialEntryType ~= "route" and initialEntryType ~= "instance" and initialEntryType ~= "known" then
        initialEntryType = "known"
    end

    local typeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    typeLabel:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -18)
    typeLabel:SetText("Entry type")

    local typeButton = BuildCycleButton(f, 150, 22, entryTypeValues, initialEntryType, function(value)
        if value == "route" then return "Route" end
        if value == "instance" then return "Instance" end
        if value == "transport" then return "Transport" end
        return "Known"
    end)
    typeButton:SetPoint("LEFT", typeLabel, "RIGHT", 10, 0)

    local transportKindValues = { "route", "portal", "tram", "boat", "zeppelin", "flight_master" }
    local initialTransportKind = CanonicalTransportKind(loc.transportKind or (isLearnedTransportEntry and "route" or "route"))
    if initialTransportKind == "transport" then
        initialTransportKind = "route"
    end

    local transportKindLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    transportKindLabel:SetPoint("LEFT", typeButton, "RIGHT", 16, 0)
    transportKindLabel:SetText("Transport kind")

    local transportKindButton = BuildCycleButton(f, 170, 22, transportKindValues, initialTransportKind, function(value)
        if value == "flight_master" then return "Flight Master" end
        if value == "route" then return "Route" end
        return tostring(value or "")
    end)
    transportKindButton:SetPoint("LEFT", transportKindLabel, "RIGHT", 10, 0)

    local bidirectionalCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    bidirectionalCheck:SetPoint("TOPLEFT", typeLabel, "BOTTOMLEFT", 0, -18)
    bidirectionalCheck:SetChecked((loc.bidirectional == true) or CanonicalTransportKind(loc.transportKind or "") == "flight_master")

    local function SetEditorCheckboxEnabled(checkbox, enabled)
        if not checkbox then return end
        if checkbox.EnableMouse then checkbox:EnableMouse(enabled and true or false) end
        if checkbox.SetAlpha then checkbox:SetAlpha(enabled and 1 or 0.5) end
        checkbox._cwDisabled = not enabled
    end

    local function RefreshEditorTypeState()
        local selectedEntryType = tostring(typeButton:GetSelectedValue() or initialEntryType or "known")
        local selectedTransportKind = CanonicalTransportKind(transportKindButton:GetSelectedValue() or initialTransportKind or "route")
        local transportActive = isLearnedTransportEntry or selectedEntryType == "route"
        local forceBidirectional = transportActive and selectedTransportKind == "flight_master"
        local bidirectionalActive = transportActive and not forceBidirectional

        if transportKindButton.Disable and transportKindButton.Enable then
            if transportActive then
                transportKindButton:Enable()
            else
                transportKindButton:Disable()
            end
        end
        if transportKindButton.SetAlpha then
            transportKindButton:SetAlpha(transportActive and 1 or 0.5)
        end

        if forceBidirectional then
            bidirectionalCheck:SetChecked(true)
        elseif not transportActive then
            bidirectionalCheck:SetChecked(false)
        end
        SetEditorCheckboxEnabled(bidirectionalCheck, bidirectionalActive)
    end

    local bidirectionalLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bidirectionalLabel:SetPoint("LEFT", bidirectionalCheck, "RIGHT", 2, 0)
    bidirectionalLabel:SetText("Bidirectional")

    typeButton._afterChange = RefreshEditorTypeState
    transportKindButton._afterChange = RefreshEditorTypeState
    if typeButton.Disable and typeButton.Enable and isLearnedTransportEntry then
        typeButton:Disable()
        if typeButton.SetAlpha then typeButton:SetAlpha(0.5) end
    end
    RefreshEditorTypeState()

    local pointLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pointLabel:SetPoint("TOPLEFT", bidirectionalCheck, "BOTTOMLEFT", 0, -18)
    pointLabel:SetText("Import block")

    local scroll = CreateFrame("ScrollFrame", frameName .. "Scroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", pointLabel, "BOTTOMLEFT", 0, -8)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -40, 48)

    local editor = CreateFrame("EditBox", nil, scroll)
    editor:SetAutoFocus(false)
    editor:SetMultiLine(true)
    editor:SetFontObject(GameFontHighlightSmall)
    editor:SetWidth(500)
    editor:SetTextInsets(4, 4, 4, 4)
    editor:SetJustifyH("LEFT")
    editor:SetText(EscapeForDisplay(BuildSingleKnownLocationImportBlock(loc)))
    editor:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editor:SetScript("OnCursorChanged", function(self)
        if scroll.SetHorizontalScroll then scroll:SetHorizontalScroll(0) end
    end)
    editor:SetScript("OnTextChanged", function(self)
        local editorText = self:GetText() or ""
        local _, newlineCount = string.gsub(editorText, "\n", "\n")
        local lines = newlineCount + 1
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
        local text = UnescapeFromDisplay(editor:GetText() or "")
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
                end
            else
                local parsedLoc, why = FinalizeImportedKnownLocation(pendingHeader, pendingRoutePoints)
                if parsedLoc then
                    imported[#imported + 1] = parsedLoc
                else
                    bad = bad + 1
                    dbg("known location edit parse rejected: " .. tostring(why or "?"))
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

        if bad > 0 then
            pr("known location edit failed: remove invalid line(s) first")
            return
        end

        local parsedLoc = imported[1]
        local parsedTransport = importedTransports[1]

        if loc.sourceType == "learnedTransport" then
            if #importedTransports ~= 1 or #imported ~= 0 then
                pr("known location edit failed: paste exactly one valid transport block")
                return
            end

            local learned = EnsureTransportDb() or {}
            local storedIndex = sourceIndex
            local edge = learned[storedIndex]
            if not edge then
                pr("known location edit failed: learned transport not found")
                return
            end

            edge.label = TrimEditorMetadataValue(labelBox:GetText())
            if edge.label == "" then
                edge.label = nil
            end

            edge.fromMaI = parsedTransport.fromMaI
            edge.fromMapName = parsedTransport.fromMapName
            edge.fromZx = parsedTransport.fromZx
            edge.fromZy = parsedTransport.fromZy
            edge.fromWx = parsedTransport.fromWx
            edge.fromWy = parsedTransport.fromWy
            edge.toMaI = parsedTransport.toMaI
            edge.toMapName = parsedTransport.toMapName
            edge.toZx = parsedTransport.toZx
            edge.toZy = parsedTransport.toZy
            edge.toWx = parsedTransport.toWx
            edge.toWy = parsedTransport.toWy
            edge.fromInstance = parsedTransport.fromInstance
            edge.fromInstanceType = parsedTransport.fromInstanceType
            edge.toInstance = parsedTransport.toInstance
            edge.toInstanceType = parsedTransport.toInstanceType
            edge.transportKind = CanonicalTransportKind(transportKindButton:GetSelectedValue() or parsedTransport.transportKind or "route")
            if edge.transportKind == "transport" then
                edge.transportKind = "route"
            end
            edge.bidirectional = (edge.transportKind == "flight_master") and true or (bidirectionalCheck:GetChecked() and true or false)
            if parsedTransport.label and parsedTransport.label ~= "" then
                edge.label = parsedTransport.label
            end
            NormalizeTransportRecord(edge)

            RefreshKnownLocationsFrame()
            InvalidateRoute("edited known transport from unified editor")
            dbg("updated known transport: " .. tostring(edge.label or loc.name or sourceIndex))
            f:Hide()
            return
        end

        if #imported ~= 1 or #importedTransports ~= 0 then
            pr("known location edit failed: paste exactly one valid known-location block")
            return
        end

        local candidate = CloneDestination(parsedLoc)
        candidate.name = TrimEditorMetadataValue(nameBox:GetText())
        candidate.label = TrimEditorMetadataValue(labelBox:GetText())
        candidate.description = descBox:GetText() or ""
        NormalizeKnownLocationAfterEdit(candidate)

        local duplicateIndex = FindDuplicateKnownLocationIndex(candidate, sourceIndex)
        if duplicateIndex then
            pr("known location edit skipped: duplicate of existing known location #" .. tostring(duplicateIndex))
            return
        end

        local known = STATE.db.knownLocations or {}
        local stored = known[sourceIndex]
        if not stored then
            pr("known route edit failed: stored known location not found")
            return
        end

        local selectedEntryType = tostring(typeButton:GetSelectedValue() or candidate.kind or stored.kind or "known")
        local selectedTransportKind = CanonicalTransportKind(transportKindButton:GetSelectedValue() or candidate.transportKind or stored.transportKind or "route")
        if selectedTransportKind == "transport" then
            selectedTransportKind = "route"
        end
        local selectedBidirectional = (selectedTransportKind == "flight_master") and true or (bidirectionalCheck:GetChecked() and true or false)

        stored.name = candidate.name ~= "" and candidate.name or stored.name
        stored.label = candidate.label ~= "" and candidate.label or nil
        stored.description = candidate.description ~= "" and candidate.description or nil
        stored.transportKind = selectedTransportKind
        stored.bidirectional = selectedBidirectional

        if selectedEntryType == "route" then
            if type(candidate.routePoints) ~= "table" or #(candidate.routePoints or {}) == 0 then
                pr("known location edit failed: route type needs a route block with at least one waypoint")
                return
            end
            stored.kind = "route"
            stored.routePoints = CloneDestinations(candidate.routePoints)
            stored.destination = CloneDestination(candidate.destination)
            stored.mapName = candidate.mapName
            stored.instance = nil
            stored.instanceType = nil
        else
            if stored.kind == "route" then
                pr("known location edit failed: route -> single-point conversion is blocked to avoid losing route waypoints")
                return
            end
            local singleDest = CloneKnownLocationDestination(candidate) or CloneDestination(candidate.destination)
            if not singleDest then
                pr("known location edit failed: selected type needs one destination point")
                return
            end
            stored.kind = selectedEntryType
            stored.routePoints = nil
            stored.destination = CloneDestination(singleDest)
            stored.mapName = singleDest.mapName or candidate.mapName
            stored.instance = (selectedEntryType == "instance") and true or nil
            stored.instanceType = (selectedEntryType == "instance") and (candidate.instanceType or stored.instanceType or "instance") or nil
        end

        NormalizeKnownLocationAfterEdit(stored)
        InvalidateRoute("edited known route")

        RefreshKnownLocationsFrame()
        dbg("updated known route: " .. tostring(stored.name or sourceIndex) .. " (" .. tostring(#(stored.routePoints or {})) .. " waypoint(s))")
        f:Hide()
    end)

    f:SetScript("OnHide", function(self)
        if nameBox and nameBox.ClearFocus then nameBox:ClearFocus() end
        if labelBox and labelBox.ClearFocus then labelBox:ClearFocus() end
        if descBox and descBox.ClearFocus then descBox:ClearFocus() end
        if editor and editor.ClearFocus then editor:ClearFocus() end
        if self.EnableKeyboard then self:EnableKeyboard(false) end
        if STATE.knownPointEditorPopup and STATE.knownPointEditorPopup.frame == self then
            STATE.knownPointEditorPopup = nil
        end
    end)

    
    STATE.knownPointEditorPopup = { frame = f, editor = editor }
    ArmKeyboardModalFrame(f)
    f:Show()
    if nameBox.SetFocus then nameBox:SetFocus() end
end

ShowKnownLocationEditorPopup = function(sourceIndex)
    EnsureDb()

    local function BuildTransportEditorEntry(storedIndex, edge)
        if not edge then return nil end
        return {
            sourceType = "learnedTransport",
            sourceIndex = storedIndex,
            kind = "transport",
            name = TransportLabel(edge),
            label = edge.label,
            previousTarget = {
                maI = edge.fromMaI, mapName = edge.fromMapName, zx = edge.fromZx, zy = edge.fromZy, wx = edge.fromWx, wy = edge.fromWy,
                instance = edge.fromInstance, instanceType = edge.fromInstanceType,
            },
            lastTarget = {
                maI = edge.toMaI, mapName = edge.toMapName, zx = edge.toZx, zy = edge.toZy, wx = edge.toWx, wy = edge.toWy,
                instance = edge.toInstance, instanceType = edge.toInstanceType,
            },
            transportKind = CanonicalTransportKind(edge.transportKind or "transport"),
            bidirectional = IsBidirectionalTransportRecord(edge),
        }
    end

    local function OpenUnifiedEditor(storedIndex, entry)
        if not entry then
            pr("edit failed: known location not found")
            return
        end
        local titleText = "Edit known location"
        if entry.sourceType == "learnedTransport" or entry.kind == "transport" then
            titleText = "Edit known transport"
        elseif entry.kind == "route" then
            titleText = "Edit known route"
        elseif entry.kind == "instance" then
            titleText = "Edit known instance"
        end
        ShowKnownPointEditorPopup(storedIndex, entry, titleText)
    end

    if type(sourceIndex) == "table" then
        if sourceIndex.sourceType == "learnedTransport" then
            local learned = EnsureTransportDb()
            local edge = sourceIndex.sourceIndex and learned[sourceIndex.sourceIndex] or nil
            if not edge then
                pr("edit failed: learned transport not found")
                return
            end
            OpenUnifiedEditor(sourceIndex.sourceIndex, BuildTransportEditorEntry(sourceIndex.sourceIndex, edge))
            return
        end

        local resolvedSourceIndex = ResolveKnownLocationStoredSourceIndex(sourceIndex)
        local loc = resolvedSourceIndex and STATE.db.knownLocations and STATE.db.knownLocations[resolvedSourceIndex] or nil
        OpenUnifiedEditor(resolvedSourceIndex, loc)
        return
    end

    local resolvedSourceIndex = tonumber(sourceIndex)
    local visibleEntry = nil

    if resolvedSourceIndex and STATE.knownLocationsUi and STATE.knownLocationsUi.visibleEntries then
        visibleEntry = STATE.knownLocationsUi.visibleEntries[resolvedSourceIndex]
    end

    if visibleEntry and visibleEntry.sourceType == "learnedTransport" then
        local learned = EnsureTransportDb()
        local edge = visibleEntry.sourceIndex and learned[visibleEntry.sourceIndex] or nil
        if not edge then
            pr("edit failed: learned transport not found")
            return
        end
        OpenUnifiedEditor(visibleEntry.sourceIndex, BuildTransportEditorEntry(visibleEntry.sourceIndex, edge))
        return
    end

    local direct = resolvedSourceIndex and STATE.db.knownLocations and STATE.db.knownLocations[resolvedSourceIndex] or nil
    if not direct and visibleEntry then
        local mapped = ResolveKnownLocationStoredSourceIndex(visibleEntry)
        if mapped then
            resolvedSourceIndex = mapped
            direct = STATE.db.knownLocations and STATE.db.knownLocations[resolvedSourceIndex] or nil
        end
    end

    OpenUnifiedEditor(resolvedSourceIndex, direct)
end

ImportWaypointsFromText = function(text)
    EnsureDb()
    if not STATE.db then return end
    text = gsub(tostring(text or ""), "\0", "")
    text = UnescapeFromDisplay(text)
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

ShowWaypointImportPopup = function()
    local frameName = "CustomWaypointsQueueImportPopup"

    if STATE.waypointImportPopup and STATE.waypointImportPopup.frame then
        STATE.waypointImportPopup.frame:Hide()
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
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("Import waypoints")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    subtitle:SetWidth(520)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Paste a queue export block here. Markers are optional, and copied CW log text with doubled pipes is accepted.")

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
        local txt = self:GetText() or ""
        local _, lineCount = string.gsub(txt, "", "")
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
        ImportWaypointsFromText(editor:GetText() or "")
        f:Hide()
        RefreshUiHeader()
    end)

    f:SetScript("OnHide", function(self)
        if editor and editor.ClearFocus then editor:ClearFocus() end
        if editor and editor.Hide then editor:Hide() end
        if self.EnableKeyboard then self:EnableKeyboard(false) end
    end)

    ArmKeyboardModalFrame(f)
    STATE.waypointImportPopup = { frame = f, editor = editor }
    f:Show()
    if editor.SetFocus then editor:SetFocus() end
    ArmKeyboardModalFrame(f)
end

ShowKnownLocationExportPopup = function(textBlob)
    local frameName = "CustomWaypointsKnownLocationsExportPopup"

    if STATE.knownLocationExportPopup and STATE.knownLocationExportPopup.frame then
        STATE.knownLocationExportPopup.frame:Hide()
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
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("Export known locations")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    subtitle:SetWidth(520)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Copy the full block from here. This export is shown only in this popup and is not written to the CW chat log.")

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
        local content = self:GetText() or ""
        local _, lineCount = string.gsub(content, "\n", "")
        local lines = lineCount + 1
        local _, fontHeight = self:GetFont()
        fontHeight = fontHeight or 14
        self:SetHeight(math.max(220, lines * fontHeight + fontHeight * 2))
        if scroll.UpdateScrollChildRect then
            scroll:UpdateScrollChildRect()
        end
    end)
    scroll:SetScrollChild(editor)
    editor:SetText(textBlob or "")
    editor:GetScript("OnTextChanged")(editor)
    if editor.HighlightText then
        editor:HighlightText()
    end

    local selectAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    selectAllBtn:SetWidth(90)
    selectAllBtn:SetHeight(24)
    selectAllBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 16)
    selectAllBtn:SetText("Select all")
    selectAllBtn:SetScript("OnClick", function()
        if editor.SetFocus then editor:SetFocus() end
        if editor.HighlightText then editor:HighlightText() end
    end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn:SetWidth(90)
    closeBtn:SetHeight(24)
    closeBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 16)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function(self)
        if editor and editor.ClearFocus then editor:ClearFocus() end
        if editor and editor.Hide then editor:Hide() end
        if self.EnableKeyboard then self:EnableKeyboard(false) end
    end)

    ArmKeyboardModalFrame(f)
    STATE.knownLocationExportPopup = { frame = f, editor = editor }
    f:Show()
    if editor.SetFocus then editor:SetFocus() end
    if editor.HighlightText then editor:HighlightText() end
    ArmKeyboardModalFrame(f)
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
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
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

    ArmKeyboardModalFrame(f)
    STATE.knownLocationImportPopup = { frame = f, editor = editor }
    ArmKeyboardModalFrame(f)
    f:Show()
    if editor.SetFocus then editor:SetFocus() end
end

local function ReleaseKnownLocationsSearchFocus()
    local ui = STATE.knownLocationsUi
    if not ui then return end

    local searchBox = ui.searchBox
    if not searchBox then return end

    if searchBox.ClearFocus then
        searchBox:ClearFocus()
    end
    if searchBox.HighlightText then
        searchBox:HighlightText(0, 0)
    end

    RefreshCwEscOverride()
end

local function GetDisplayNameForPoint(pt)
    if not pt then return "?" end
    return pt.userName or pt.zoneText or pt.subZoneText or pt.mapName or pt.maI or "?"
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
        row:SetSize(730, 42)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function()
            ReleaseKnownLocationsSearchFocus()
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
        meta:SetWidth(420)
        meta:SetJustifyH("LEFT")
        meta:SetText(format("kind=%s | entrance=%s | destination=%s%s",
            tostring(entry.kind or "?"),
            tostring(GetDisplayNameForPoint(entry.previousTarget)),
            tostring(GetDisplayNameForPoint(entry.lastTarget or entry.destination)),
            entry.instance and format(" | instance=%s", tostring(entry.instanceType or "yes")) or ""
        ))

        local routeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        routeBtn:SetWidth(74)
        routeBtn:SetHeight(22)
        routeBtn:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        routeBtn:SetText("Route")
        routeBtn:SetScript("OnClick", function()
            ReleaseKnownLocationsSearchFocus()
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
            ReleaseKnownLocationsSearchFocus()
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
        local selected = ui.selectedIndex and visibleEntries[ui.selectedIndex] or nil
        if selected then
            ui.deleteSelectedBtn:Enable()
        else
            ui.deleteSelectedBtn:Disable()
        end
    end

    content:SetHeight(math.max(60, -yOffset + 10))
end

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
    ShowKnownLocationExportPopup(blob)
end

local function RestoreKnownLocationsSelectionAfterDelete(previousIndex)
    local ui = STATE.knownLocationsUi
    if not ui then return end

    local visible = ui.visibleEntries or {}
    if type(previousIndex) ~= "number" or previousIndex < 1 or previousIndex > #visible then
        ui.selectedIndex = nil
        ui.lastClickKey = nil
        ui.lastClickTime = nil
        return
    end

    ui.selectedIndex = previousIndex
    ui.lastClickKey = nil
    ui.lastClickTime = nil
end

local function QueueKnownLocationsSearchFocus()
    local ui = STATE.knownLocationsUi
    if not ui then return end

    local focusBox = ui.searchBox
    if not focusBox or not focusBox.SetFocus then return end

    local focusDriver = ui.focusDriver
    if not focusDriver then
        focusDriver = CreateFrame("Frame", nil, ui.frame)
        ui.focusDriver = focusDriver
    end

    local remainingDelay = 0
    focusDriver:SetScript("OnUpdate", function(self, elapsed)
        remainingDelay = remainingDelay + (elapsed or 0)
        if remainingDelay < 0.01 then
            return
        end

        self:SetScript("OnUpdate", nil)

        if not STATE.knownLocationsUi or not STATE.knownLocationsUi.frame or not STATE.knownLocationsUi.frame:IsShown() then
            return
        end

        local searchBox = STATE.knownLocationsUi.searchBox
        if searchBox and searchBox.SetFocus then
            searchBox:SetFocus()
            if searchBox.HighlightText then
                searchBox:HighlightText()
            end
            RefreshCwEscOverride()
        end
    end)
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
            RefreshCwEscOverride()
            QueueKnownLocationsSearchFocus()
        end
        return
    end

    local f = CreateFrame("Frame", "CustomWaypointsKnownLocationsFrame", UIParent)
    f:SetWidth(800)
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
        ReleaseKnownLocationsSearchFocus()
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
    subtitle:SetText("Left click selects, double click routes.")

    local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -59)
    searchLabel:SetText("Search")

    local searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    searchBox:SetAutoFocus(false)
    searchBox:SetWidth(180)
    searchBox:SetHeight(20)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        RefreshCwEscOverride()
    end)
    searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        RefreshCwEscOverride()
    end)
    searchBox:SetScript("OnEditFocusGained", function()
        RefreshCwEscOverride()
    end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        if self.HighlightText then
            self:HighlightText(0, 0)
        end
        RefreshCwEscOverride()
    end)
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
        ReleaseKnownLocationsSearchFocus()
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
        ReleaseKnownLocationsSearchFocus()
        if STATE.knownLocationsUi then
            STATE.knownLocationsUi.routesOnly = self:GetChecked() and true or false
            STATE.knownLocationsUi.selectedIndex = nil
            RefreshKnownLocationsFrame()
        end
    end)

    local routesLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    routesLabel:SetPoint("LEFT", routesCheck, "RIGHT", 2, 0)
    routesLabel:SetText("Routes only")

    local flightMastersCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    flightMastersCheck:SetPoint("LEFT", routesLabel, "RIGHT", 18, 0)
    flightMastersCheck:SetChecked(false)
    flightMastersCheck:SetScript("OnClick", function(self)
        ReleaseKnownLocationsSearchFocus()
        if STATE.knownLocationsUi then
            STATE.knownLocationsUi.flightMastersOnly = self:GetChecked() and true or false
            STATE.knownLocationsUi.selectedIndex = nil
            RefreshKnownLocationsFrame()
        end
    end)

    local flightMastersLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    flightMastersLabel:SetPoint("LEFT", flightMastersCheck, "RIGHT", 2, 0)
    flightMastersLabel:SetText("Flight Masters only")

    local transportsCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    transportsCheck:SetPoint("LEFT", flightMastersLabel, "RIGHT", 18, 0)
    transportsCheck:SetChecked(false)
    transportsCheck:SetScript("OnClick", function(self)
        ReleaseKnownLocationsSearchFocus()
        if STATE.knownLocationsUi then
            STATE.knownLocationsUi.transportsOnly = self:GetChecked() and true or false
            STATE.knownLocationsUi.selectedIndex = nil
            RefreshKnownLocationsFrame()
        end
    end)

    local transportsLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    transportsLabel:SetPoint("LEFT", transportsCheck, "RIGHT", 2, 0)
    transportsLabel:SetText("Transports only")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetWidth(90)
    refreshBtn:SetHeight(22)
    refreshBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function() ReleaseKnownLocationsSearchFocus() RefreshKnownLocationsFrame() end)

    local scrollFrame = CreateFrame("ScrollFrame", "CustomWaypointsKnownLocationsScrollFrame", f, "UIPanelScrollFrameTemplate")
    local content = CreateFrame("Frame", nil, scrollFrame)
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -88)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 42)

    content:SetSize(500, 1)
    scrollFrame:SetScrollChild(content)

    routeSelectedBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    routeSelectedBtn:SetWidth(120)
    routeSelectedBtn:SetHeight(22)
    routeSelectedBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 8, 0)
    routeSelectedBtn:SetText("Route Selected")
    routeSelectedBtn:SetScript("OnClick", function()
        ReleaseKnownLocationsSearchFocus()
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
    exportBtn:SetScript("OnClick", function() ReleaseKnownLocationsSearchFocus() ExportKnownLocations() end)

    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetWidth(70)
    importBtn:SetHeight(22)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function() ReleaseKnownLocationsSearchFocus() ShowKnownLocationImportPopup() end)
    
    local deleteSelectedBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    deleteSelectedBtn:SetWidth(120)
    deleteSelectedBtn:SetHeight(22)
    deleteSelectedBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
    deleteSelectedBtn:SetText("Delete Selected")
    deleteSelectedBtn:SetScript("OnClick", function()
        ReleaseKnownLocationsSearchFocus()
        local ui = STATE.knownLocationsUi
        if not ui or not ui.selectedIndex or not ui.visibleEntries or not ui.visibleEntries[ui.selectedIndex] then
            pr("delete failed: no known location selected")
            return
        end

        local previousIndex = ui.selectedIndex
        local chosen = ui.visibleEntries[previousIndex]

        if DeleteKnownLocationEntry(chosen) then
            RefreshKnownLocationsFrame()
            RestoreKnownLocationsSelectionAfterDelete(previousIndex)
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
        routesCheck = routesCheck,
        transportsCheck = transportsCheck,
        deleteSelectedBtn = deleteSelectedBtn,
        searchText = "",
        instancesOnly = false,
        routesOnly = false,
        transportsOnly = false,
        selectedIndex = nil,
        visibleEntries = {},
    }

    RefreshKnownLocationsFrame()
    ArmKeyboardModalFrame(f)
    f:Show()
    RefreshCwEscOverride()
    QueueKnownLocationsSearchFocus()
end

function CustomWaypoints_ToggleKnownLocations()
    ShowKnownLocationsFrame()
end

function CustomWaypoints_SaveHere()
    AddCurrentLocationWithMetadataPopup()
end

function CW_DELETE_SELECTED_KNOWN_LOCATION()
    CustomWaypoints_DeleteSelectedKnownLocation()
end

function CustomWaypoints_DeleteSelectedKnownLocation()
    local ui = STATE.knownLocationsUi
    if not ui or not ui.frame or not ui.frame:IsShown() then
        pr("delete failed: known locations window is not open")
        return
    end

    local previousIndex = ui.selectedIndex
    local chosen = previousIndex and ui.visibleEntries and ui.visibleEntries[previousIndex] or nil
    if not chosen then
        pr("delete failed: no known location selected")
        return
    end

    if DeleteKnownLocationEntry(chosen) then
        RefreshKnownLocationsFrame()
        RestoreKnownLocationsSelectionAfterDelete(previousIndex)
        RefreshKnownLocationsFrame()
    end
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

EnsureDeleteSelectedKnownLocationBinding = function()
    if STATE.deleteSelectedKnownLocationBindingInitialized then
        return
    end

    STATE.deleteSelectedKnownLocationBindingInitialized = true

    if not (SetBinding and SaveBindings and GetCurrentBindingSet and GetBindingKey and GetBindingAction) then
        return
    end

    local old1, old2 = GetBindingKey("CW_DELETE_SELECTED_KNOWN_LOCATION")
    if old1 then SetBinding(old1, nil) end
    if old2 then SetBinding(old2, nil) end

    local currentShiftDelete = GetBindingAction("SHIFT-DELETE")
    if currentShiftDelete and currentShiftDelete ~= "" then
        SetBinding("SHIFT-DELETE", nil)
    end

    SetBinding("SHIFT-DELETE", "CW_DELETE_SELECTED_KNOWN_LOCATION")
    SaveBindings(GetCurrentBindingSet())

    dbg("delete selected known location binding hard-forced to SHIFT-DELETE")
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
        ShowWaypointImportPopup()
    end)

    local knownBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    knownBtn:SetWidth(120)
    knownBtn:SetHeight(22)
    knownBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 340, -98)
    knownBtn:SetText("Known Locations")
    knownBtn:SetScript("OnClick", function() ShowKnownLocationsFrame() end)

    local saveRouteBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveRouteBtn:SetWidth(100)
    saveRouteBtn:SetHeight(22)
    saveRouteBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 467, -98)
    saveRouteBtn:SetText("Save Route")
    saveRouteBtn:SetScript("OnClick", function() SaveQueueAsKnownRoute() end)

    local searchBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    searchBtn:SetWidth(78)
    searchBtn:SetHeight(22)
    searchBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 574, -98)
    searchBtn:SetText("Search")
    searchBtn:SetScript("OnClick", function()
        if CW.ShowDestinationSearchFrame then
            CW.ShowDestinationSearchFrame("")
        end
    end)

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
    checks.autosync = MakeCheckbox("AutoSync", 0, -122, function() SlashHandler("autosync") end)
    checks.autoadvance = MakeCheckbox("AutoAdvance", 100, -122, function() SlashHandler("autoadvance") end)
    checks.flightmasters = MakeCheckbox("FlightMasters", 200, -122, function() SlashHandler("flightmasters") end)
    checks.deep = MakeCheckbox("Deep", 300, -122, function(self)
        if self:GetChecked() then SlashHandler("deep") else SlashHandler("minimal") end
    end)
    checks.debug = MakeCheckbox("Debug", 400, -122, function() SlashHandler("debug") end)
    
    checks.autodiscovery = MakeCheckbox("AutoDiscovery", 500, -122, function() SlashHandler("autodiscovery") end)
    checks.portaldiscovery = checks.autodiscovery

    local commands = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    commands:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -142)
    commands:SetWidth(720)
    commands:SetJustifyH("LEFT")
    commands:SetText("\n/cw help | ui | tuning | options | probe | add | list | export | import | sync | route | graph | clear | pop | undo | redo | autosync | autoadvance | flightmasters | deep | minimal | debug | simplify | legend | transports | cleartransports | transportlog | autodiscovery | transportconfirmation | knownlocations | routeknown <index> | saveroute | savehere | search")

    local scroll = CreateFrame("ScrollFrame", "CustomWaypointsScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -250)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 12)

    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() end)

    local output = CreateFrame("EditBox", "CustomWaypointsScrollChild", scroll)
    output:SetMultiLine(true)
    output:SetAutoFocus(false)
    output:EnableMouse(true)
    -- Allow typing notes, selection, Ctrl+C copy when focused (chat log still refreshed by addon).
    -- if output.EnableKeyboard then output:EnableKeyboard(true) end
    output:SetFontObject(ChatFontNormal)
    local scrollW = (f:GetWidth() or 760) - 20 - 32
    output:SetWidth(scrollW)    output:SetHeight(200)
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
        checks = checks,
    }

    RefreshUiHeader()
    AppendUiLogLine("CW UI ready. Undo steps back add/clear/pop (snapshot stack). Redo: /cw redo or Ctrl+Shift+Y if unbound.")
    f:Hide()
    return STATE.ui
end

local function ResetDeathAutoRouteCycle()
    STATE.lastDeathAutoRouteKey = nil
    STATE.pendingDeathAutoRoute = nil
    STATE.deathAutoRouteContext = nil
end

local function ClonePersistentInstanceContext(pt)
    if not pt then return nil end
    local copy = CloneWorldPoint(pt) or {}
    copy.instance = true
    copy.instanceType = copy.instanceType or "instance"
    return copy
end

local function CaptureDeathInstanceContext()
    local pos = GetPlayerWorldPos()
    if pos and pos.instance then
        return ClonePersistentInstanceContext(pos)
    end

    local stable = STATE.lastStablePlayerPos
    if stable and stable.instance then
        return ClonePersistentInstanceContext(stable)
    end

    return nil
end

local function ClearCorpseInstanceContext()
    EnsureDb()
    if STATE.db then
        STATE.db.corpseInstanceContext = nil
    end
end

local function EnsureInterfaceOptionsPanel()
    if STATE.interfacePanel then
        RefreshUiHeader()
        return STATE.interfacePanel
    end
    if not InterfaceOptions_AddCategory then return nil end

    local panel = CreateFrame("Frame", "CWInterfaceOptions", UIParent)
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
    checks.autoadvance = MakePanelCheckbox("Auto advance on reach (false for recording/debugging)", 16, -100, function() SlashHandler("autoadvance") end)
    checks.flightmasters = MakePanelCheckbox("Use flight masters in deep mode", 16, -130, function() SlashHandler("flightmasters") end)
    checks.deep = MakePanelCheckbox("Deep routing mode", 16, -160, function(self)
        if self:GetChecked() then SlashHandler("deep") else SlashHandler("minimal") end
    end)
    checks.autorouteinstanceondeath = MakePanelCheckbox("Auto route to instance on death", 16, -190, function(self)
        EnsureDb()
        local enabled = self:GetChecked() and true or false
        STATE.db.autoRouteSavedInstanceOnDeath = enabled

        if not enabled then
            ClearPendingDeathAutoRoute()
            ResetDeathAutoRouteCycle()
            ClearCorpseInstanceContext()
        else
            local deadOrGhost = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")
            if deadOrGhost then
                local deathContext = CaptureDeathInstanceContext()
                if deathContext then
                    RememberCorpseInstanceContext(deathContext)
                    StartPendingDeathAutoRoute(0.20, deathContext)
                end
            end
        end
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

    if not _G.CWUndoHotkeyButton then
        local b = CreateFrame("Button", "CWUndoHotkeyButton", UIParent)
        b:SetScript("OnClick", function()
            UndoHistory()
        end)
        b:Hide()
    end
    if not _G.CWRedoHotkeyButton then
        local b = CreateFrame("Button", "CWRedoHotkeyButton", UIParent)
        b:SetScript("OnClick", function()
            RedoHistory()
        end)
        b:Hide()
    end

    local b = _G.CWClearHotkeyButton
    if not b then
        b = CreateFrame("Button", "CWClearHotkeyButton", UIParent)
        b:Hide()
    end

    b:SetScript("OnClick", function()
        EnsureDb()

        local map = GetMap()
        ClearCarboniteTargets(map)

        local d = STATE.db and STATE.db.destinations or nil
        if not d or #d == 0 then
            dbg("clear: queue already empty")
            return
        end

        PushHistorySnapshot("hotkey-clear")
        wipe(d)
        InvalidateRoute("hotkey-clear")

        if STATE.db.autoSyncToCarbonite then
            SyncQueueToCarbonite()
        else
            ClearCarboniteTargets()
        end

        dbg("queue cleared (Ctrl+Shift+C)")
        RefreshUiHeader()
    end)

    local undoClick = "CLICK CWUndoHotkeyButton:LeftButton"
    local redoClick = "CLICK CWRedoHotkeyButton:LeftButton"
    local clearClick = "CLICK CWClearHotkeyButton:LeftButton"
    local bindChanged = false

    local function CanAssignKey(key, boundTo)
        if not GetBindingAction then return true end
        local a = GetBindingAction(key)
        return (not a or a == "" or a == boundTo)
    end

    if CanAssignKey("CTRL-SHIFT-Z", undoClick) then
        if SetBindingClick then
            SetBindingClick("CTRL-SHIFT-Z", "CWUndoHotkeyButton", "LeftButton")
            bindChanged = true
        elseif SetBinding then
            SetBinding("CTRL-SHIFT-Z", undoClick)
            bindChanged = true
        end
    end

    if CanAssignKey("CTRL-SHIFT-Y", redoClick) then
        if SetBindingClick then
            SetBindingClick("CTRL-SHIFT-Y", "CWRedoHotkeyButton", "LeftButton")
            bindChanged = true
        elseif SetBinding then
            SetBinding("CTRL-SHIFT-Y", redoClick)
            bindChanged = true
        end
    end

    if CanAssignKey("CTRL-SHIFT-C", clearClick) then
        if SetBindingClick then
            SetBindingClick("CTRL-SHIFT-C", "CWClearHotkeyButton", "LeftButton")
            bindChanged = true
        elseif SetBinding then
            SetBinding("CTRL-SHIFT-C", clearClick)
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

function StartPendingDeathAutoRoute(delay, deathContext)
    EnsureDb()
    if not (STATE.db and STATE.db.autoRouteSavedInstanceOnDeath) then return false end
    if not (deathContext and deathContext.instance) then return false end

    local now = GetTime and GetTime() or 0
    STATE.deathAutoRouteContext = ClonePersistentInstanceContext(deathContext)
    STATE.pendingDeathAutoRoute = {
        startedAt = now,
        nextAttemptAt = now + (tonumber(delay) or 0.35),
        attempts = 0,
        sourceContext = ClonePersistentInstanceContext(deathContext),
    }

    dbg("death auto-route queued")
    return true
end

GetPlayerWorldPos = function()
    local map = GetMap()

    local inInstance, instanceType = false, "none"
    if IsInInstance then
        local a, b = IsInInstance()
        inInstance = a and true or false
        instanceType = b or "none"
    end

    local zoneText = GetRealZoneText and GetRealZoneText() or nil
    local subZoneText = GetSubZoneText and GetSubZoneText() or nil

    -- Instance-position invariant:
    -- keep real world coordinates for instances that expose them, but still
    -- return a synthetic instance position for Stockade-style/manual entries
    -- when Warmane/WotLK or Carbonite cannot provide usable world coordinates.
    -- Do not require a Carbonite map object for strict instance detection.
    local function BuildSyntheticInstancePos(maI)
        local resolvedMaI = tonumber(maI)
        if not resolvedMaI or resolvedMaI <= 0 then
            resolvedMaI = -1
        end
        local resolvedName = (zoneText and zoneText ~= "" and zoneText)
            or (subZoneText and subZoneText ~= "" and subZoneText)
            or (map and resolvedMaI > 0 and map.ITN and map:ITN(resolvedMaI))
            or "Instance"
        return {
            maI = resolvedMaI,
            wx = nil,
            wy = nil,
            zx = nil,
            zy = nil,
            mapName = resolvedName,
            instance = true,
            instanceType = instanceType,
            zoneText = zoneText,
            subZoneText = subZoneText,
        }
    end

    local explicitInstanceMaI = nil
    if inInstance and map and map.GCMI then
        explicitInstanceMaI = map:GCMI() or nil
    end

    if map and Nx and Nx.Map and Nx.Map.CZ2I then
        local oldCont = GetCurrentMapContinent and GetCurrentMapContinent() or nil
        local oldZone = GetCurrentMapZone and GetCurrentMapZone() or nil

        SetMapToCurrentZone()
        local continent = GetCurrentMapContinent()
        local zone = GetCurrentMapZone()

        if continent and continent > 0 and zone and zone > 0 and Nx.Map.CZ2I[continent] and Nx.Map.CZ2I[continent][zone] then
            local maI = Nx.Map.CZ2I[continent][zone]
            if map.GRMI then
            local ok, resolvedMaI = pcall(map.GRMI, map)
            if ok and tonumber(resolvedMaI) and tonumber(resolvedMaI) > 0 then
                maI = tonumber(resolvedMaI)
            end
        end

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

    if inInstance then
        return BuildSyntheticInstancePos(explicitInstanceMaI)
    end

    return nil
end

local function RememberPersistentInstanceContext(pt)
    EnsureDb()
    if not (STATE.db and pt and pt.instance) then return end
    STATE.db.lastInstanceContext = ClonePersistentInstanceContext(pt)
end

local function RememberCorpseInstanceContext(pt)
    EnsureDb()
    if not (STATE.db and pt and pt.instance) then return end
    STATE.db.corpseInstanceContext = ClonePersistentInstanceContext(pt)
end

local function GetBestInstanceContextForDeathRouting()
    local pending = STATE.pendingDeathAutoRoute
    if pending and pending.sourceContext and pending.sourceContext.instance then
        return pending.sourceContext
    end
    if STATE.deathAutoRouteContext and STATE.deathAutoRouteContext.instance then
        return STATE.deathAutoRouteContext
    end
    if STATE.db and STATE.db.corpseInstanceContext and STATE.db.corpseInstanceContext.instance then
        return STATE.db.corpseInstanceContext
    end
    return nil
end

function TryAutoRouteSavedInstanceOnDeath()
    EnsureDb()
    if not (STATE.db and STATE.db.autoRouteSavedInstanceOnDeath) then return false, "disabled" end

    local pos = GetBestInstanceContextForDeathRouting()
    if not pos then
        return false, "no-instance-context-yet"
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

    local deadOrGhost = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")
    if not deadOrGhost then
        ClearPendingDeathAutoRoute()
        return
    end

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
        zoneText = name,
        subZoneText = name,
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
        if keySeedTo.instance and CW.IsRecentInstanceEntryDuplicate(fromPos, keySeedTo) then
            dbg("pending transport suppressed: duplicate recent instance entry")
            return
        end
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

    -- Instance discovery invariant:
    -- show the known-instance confirmation only on strict entry into an instance.
    -- Teleports/leaves back to world space must never be treated as a discoverable
    -- instance hop, even when PLAYER_ENTERING_WORLD fires during the transition.
    -- Some Warmane/WotLK dungeons may not expose a usable Carbonite map id, so
    -- strict instance entry must be recognized even without a normal toPos.maI.
    if toPos.instance then
        if not fromPos.instance then
            return true, reason or "entered instance"
        end
        return false, "instance-to-instance transition"
    end

    if fromPos.instance then
        return false, "left instance"
    end

    if not fromPos.maI or not toPos.maI then
        return false, "missing map ids"
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

local function IsLikelyLfgTeleportIntoInstance(fromPos, toPos, reason)
    if not (fromPos and toPos and toPos.instance and not fromPos.instance) then
        return false
    end

    -- Only care about world -> instance transitions.
    if reason ~= "PLAYER_ENTERING_WORLD" then
        return false
    end

    -- Being in LFG mode alone must NOT suppress discovery.
    -- Suppress only likely RDF/LFG teleports.
    local lfgMode = nil
    if GetLFGMode then
        local ok, mode = pcall(GetLFGMode)
        if ok then lfgMode = mode end
    end

    if not lfgMode or lfgMode == "" or lfgMode == "none" then
        return false
    end

    -- If we have outdoor world coords and they jump very far on PLAYER_ENTERING_WORLD,
    -- treat it as a likely teleport. Manual walking entry should not look like this.
    if fromPos.wx and fromPos.wy and toPos.wx and toPos.wy then
        local dx = fromPos.wx - toPos.wx
        local dy = fromPos.wy - toPos.wy
        local dist = (dx * dx + dy * dy) ^ 0.5
        if dist > 2000 then
            return true
        end
    end

    -- Missing usable destination coords on an LFG PEW instance entry is also a strong hint
    -- that this was a teleport sequence, not a walked portal crossing.
    if not toPos.maI or not toPos.wx or not toPos.wy then
        return true
    end

    return false
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

    local function ApplyPopupToggle()
        if disableDiscovery:GetChecked() then
            SetAutoDiscoveryEnabled(false)
        end
    end

    local function RejectTransportConfirmation(self)
        local p2 = STATE.pendingConfirmationTransport
        if p2 then
            local suppressSeconds = (p2.toPos and p2.toPos.instance) and 3600 or 30
            DismissConfirmationCandidate(p2.fromPos, p2.toPos, suppressSeconds)
            MarkConfirmationRecentlyHandled(p2.fromPos, p2.toPos, suppressSeconds)
            if p2.toPos and p2.toPos.instance and p2.toPos.maI then
                STATE.lastStablePlayerPos = CloneWorldPoint(p2.toPos)
            end
        end

        ApplyPopupToggle()
        STATE.pendingConfirmationTransport = nil
        ClearPendingTransport()
        self:Hide()
    end
    f.cwEscAction = RejectTransportConfirmation

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", disableDiscovery, "RIGHT", 2, 1)
    label:SetText("Don't ask again (disable AutoDiscovery)")

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
        RejectTransportConfirmation(f)
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
            -- Instance / zone transitions can briefly hide this popup while the
            -- entry sequence is still settling. Do not mark it as fully handled here,
            -- otherwise later zone events suppress the real confirmation too
            -- aggressively. Use only a short dismiss window to absorb immediate spam.
            DismissConfirmationCandidate(p2.fromPos, p2.toPos, p2.toPos and p2.toPos.instance and 2 or 6)
            STATE.pendingConfirmationTransport = nil
        end
        RemoveCwModalFrame(self)
        STATE.activeConfirmationKey = nil
        ClearPendingTransport()
        if oldOnHide then oldOnHide(self) end
    end)

    STATE.confirmationFrame = f
    ArmKeyboardModalFrame(f)
    f:Show()
end

local function RequestLearnedTransportConfirmation(fromPos, toPos, reason)
    if not fromPos or not toPos then return end
    EnsureDb()

    if IsLikelyLfgTeleportIntoInstance(fromPos, toPos, reason) then
        dbg("confirmation suppressed: likely LFG teleport into instance")
        return
    end

    if toPos.instance and CW.IsRecentInstanceEntryDuplicate(fromPos, toPos) and reason == "implicit-map-change" then
        dbg("confirmation suppressed: duplicate implicit instance entry")
        return
    end

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
                    if current.instance then
                    CW.RememberRecentInstanceEntry(STATE.pendingTransport.from, current, 4)
                end
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
        local implicitFrom = STATE.lastStablePlayerPos
        if current.instance and implicitFrom and implicitFrom.instance and STATE.lastNonInstanceStablePlayerPos then
            implicitFrom = STATE.lastNonInstanceStablePlayerPos
        end

        local implicitMapChanged = implicitFrom and current.maI ~= implicitFrom.maI
        local implicitEnteredInstance = implicitFrom and current.instance and not implicitFrom.instance

        -- Warmane/WotLK invariant:
        -- some manual dungeon entries (for example Stockade-style entrances) may
        -- not expose a distinct Carbonite map id, so the implicit fallback must
        -- also react to a strict world -> instance state change.
        -- Keep the last non-instance position around so late zone events still
        -- compare against the outdoor entrance instead of a synthetic instance pos.
        if implicitFrom and not STATE.pendingTransport and (implicitMapChanged or implicitEnteredInstance) then
            if current and current.instance and CW.IsRecentInstanceEntryDuplicate(implicitFrom, current) then
                dbg("implicit map-change suppressed: duplicate recent instance entry")
            else
                BeginPendingTransport("implicit-map-change", implicitFrom)
                if STATE.pendingTransport then
                    STATE.pendingTransport.wait = 0.1
                    STATE.pendingTransport.seenDifferentMap = true

                    if current and (current.maI ~= STATE.pendingTransport.from.maI or (current.instance and not STATE.pendingTransport.from.instance)) then
                        local shouldLearn, why = ShouldTreatAsTransportTransition(STATE.pendingTransport.from, current, STATE.pendingTransport.reason)
                        if shouldLearn then
                            if current.instance then
                                CW.RememberRecentInstanceEntry(STATE.pendingTransport.from, current, 4)
                            end
                            RequestLearnedTransportConfirmation(STATE.pendingTransport.from, current, STATE.pendingTransport.reason)
                        else
                            dbg("ignored implicit map hop: " .. tostring(why) .. " from=" .. tostring(STATE.pendingTransport.from.mapName) .. " to=" .. tostring(current.mapName))
                        end
                        ClearPendingTransport()
                    end
                end
            end
        end
        if current and (current.maI or (current.wx and current.wy)) then
            STATE.lastStablePlayerPos = CloneWorldPoint(current)
            if current.instance then
                STATE.lastInstanceStablePlayerPos = CloneWorldPoint(current)
                RememberPersistentInstanceContext(current)
            else
                STATE.lastNonInstanceStablePlayerPos = CloneWorldPoint(current)
            end
        end
    end
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
            dbg("undo: nothing to undo")
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
        dbg("undo: cleared queue (no session history — e.g. after /reload); use redo to restore")
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
    dbg(format("undo: restored queue (%d stop(s))", #(STATE.db.destinations or {})))
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
    STATE.deepSyncSkipCount = 0
    if reason then
        dbg("route invalidated: " .. tostring(reason))
    end
end

function CW.BuildTaxiKeyVariants(name)
    local out = {}
    local function addVariant(v)
        v = NormalizeTaxiKey(v)
        if v and v ~= "" then
            out[v] = true
        end
    end

    addVariant(name)

    local raw = tostring(name or "")
    if raw ~= "" then
        addVariant((gsub(raw, "%b()", " ")))
        addVariant((gsub(raw, "%s+[Tt]he%s+.*$", "")))
        addVariant((gsub(raw, "%s*[,%-:].*$", "")))
    end

    return out
end

function CW.MarkSessionKnownTaxi(name)
    if not name or name == "" then return false end
    STATE.sessionKnownTaxis = STATE.sessionKnownTaxis or {}

    local changed = false
    for key in pairs(CW.BuildTaxiKeyVariants(name)) do
        if not STATE.sessionKnownTaxis[key] then
            STATE.sessionKnownTaxis[key] = name
            changed = true
        end
    end
    return changed
end

function CW.RefreshSessionKnownTaxisFromTaxiMap()
    if not NumTaxiNodes or not TaxiNodeName or not TaxiNodeGetType then
        return false
    end

    local changedAny = false
    local count = tonumber(NumTaxiNodes()) or 0
    for i = 1, count do
        local nodeType = TaxiNodeGetType(i)
        if nodeType == "CURRENT" or nodeType == "REACHABLE" then
            local taxiName = TaxiNodeName(i)
            if taxiName and taxiName ~= "" and taxiName ~= "INVALID" then
                if CW.MarkSessionKnownTaxi(taxiName) then
                    changedAny = true
                    dbg("session-known taxi added: " .. tostring(taxiName) .. " (" .. tostring(nodeType) .. ")")
                end
            end
        end
    end

    return changedAny
end

function ResolveMapIdByName(name)
    local map = GetMap()
    if not (map and name and map.ITN) then return nil end
    local target = tostring(name):lower()
    for maI = 1, 5000 do
        local mapName = map:ITN(maI)
        if mapName and tostring(mapName):lower() == target then
            return maI
        end
    end
    return nil
end

function BuildPointFromAnchor(maI, zx, zy, label, edgeType)
    local map = GetMap()
    if not (map and maI and zx and zy) then return nil end
    local wx, wy = map:GWP(maI, zx, zy)
    if not (wx and wy) then return nil end
    return {
        maI = maI,
        wx = wx,
        wy = wy,
        zx = zx,
        zy = zy,
        mapName = map.ITN and map:ITN(maI) or ("Map " .. tostring(maI)),
        edgeType = edgeType or "connector",
        label = label,
        forceStraight = true,
    }
end

function CW.NormalizeZoneLookupKey(name)
    local s = tostring(name or "")
    if s == "" then return "" end
    s = lower(s)
    s = gsub(s, "%b()", " ")
    s = gsub(s, "['`´’]", "")
    s = gsub(s, "[%-_,:/.]", " ")
    s = gsub(s, "[^%w%s]", " ")
    s = gsub(s, "^the%s+", "")
    s = gsub(s, "%s+the%s+", " ")
    s = gsub(s, "%s+", " ")
    s = gsub(s, "^%s+", "")
    s = gsub(s, "%s+$", "")
    return s
end

function CW.ZoneLookupKeysMatchLoosely(a, b)
    local ka = CW.NormalizeZoneLookupKey(a)
    local kb = CW.NormalizeZoneLookupKey(b)
    if ka == "" or kb == "" then return false end
    return ka == kb or string.find(ka, kb, 1, true) ~= nil or string.find(kb, ka, 1, true) ~= nil
end

function CW.BuildManualTransportLikeEdgeFromKnownLocation(loc)
    if not (loc and tostring(loc.kind or "") == "transport") then return nil end

    local dest = CloneKnownLocationDestination(loc)
    if not dest then return nil end

    local kind = CanonicalTransportKind(InferStoredTransportKind(loc) or loc.transportKind or "transport")
    local zoneHint = tostring(loc.zoneNameHint or loc.name or loc.label or dest.subZoneText or dest.zoneText or dest.mapName or "")
    local trackerLabel = loc.trackerLabel or loc.label or nil

    return NormalizeTransportRecord({
        toMaI = dest.maI,
        toWx = dest.wx,
        toWy = dest.wy,
        toZx = dest.zx,
        toZy = dest.zy,
        toMapName = dest.mapName,
        toZoneText = zoneHint ~= "" and zoneHint or (dest.zoneText or dest.mapName),
        toSubZoneText = zoneHint ~= "" and zoneHint or (dest.subZoneText or dest.zoneText or dest.mapName),
        toZoneName = zoneHint ~= "" and zoneHint or (dest.subZoneText or dest.zoneText or dest.mapName),
        toInstance = dest.instance,
        toInstanceType = dest.instanceType,
        label = zoneHint ~= "" and zoneHint or (dest.subZoneText or dest.zoneText or dest.mapName),
        name = loc.name,
        trackerLabel = trackerLabel,
        transportKind = kind,
        bidirectional = (loc.bidirectional == true) or kind == "flight_master",
        discoveredBy = loc.discoveredBy or "manual-saveroute",
    })
end

function CW.ResolveMapIdBySmartName(name)
    local map = GetMap()
    if not (map and name and map.ITN) then return nil, "no-map" end

    local rawTarget = lower(tostring(name or ""))
    rawTarget = gsub(rawTarget, "^%s+", "")
    rawTarget = gsub(rawTarget, "%s+$", "")
    local normalizedTarget = CW.NormalizeZoneLookupKey(name)
    if normalizedTarget == "" then
        return nil, "empty-zone"
    end

    local normalizedMatches = nil
    local containsMatches = nil

    for maI = 1, 5000 do
        local mapName = map:ITN(maI)
        if mapName and mapName ~= "" then
            local rawCandidate = lower(tostring(mapName))
            if rawCandidate == rawTarget then
                return maI, nil
            end

            local normalizedCandidate = CW.NormalizeZoneLookupKey(mapName)
            if normalizedCandidate ~= "" then
                if normalizedCandidate == normalizedTarget then
                    normalizedMatches = normalizedMatches or {}
                    normalizedMatches[#normalizedMatches + 1] = { maI = maI, mapName = mapName }
                elseif string.find(normalizedCandidate, normalizedTarget, 1, true) or string.find(normalizedTarget, normalizedCandidate, 1, true) then
                    containsMatches = containsMatches or {}
                    containsMatches[#containsMatches + 1] = { maI = maI, mapName = mapName }
                end
            end
        end
    end

    if normalizedMatches and #normalizedMatches == 1 then
        return normalizedMatches[1].maI, nil
    end
    if normalizedMatches and #normalizedMatches > 1 then
        return nil, "ambiguous-normalized", normalizedMatches
    end

    if containsMatches and #containsMatches == 1 then
        return containsMatches[1].maI, nil
    end
    if containsMatches and #containsMatches > 1 then
        return nil, "ambiguous-contains", containsMatches
    end

    return nil, "not-found"
end

function CW.ParseZoneCoordinateNumber(token)
    token = tostring(token or "")
    token = gsub(token, ",", ".")
    if not match(token, "^%-?%d+%.?%d*$") and not match(token, "^%-?%d*%.%d+$") then
        return nil
    end
    return tonumber(token)
end

function CW.ParseZoneAndCoordsFromSlashArgs(rawMsg)
    local zonePart, xToken, yToken = tostring(rawMsg or ""):match("^(.-)%s+([^%s]+)%s+([^%s]+)$")
    if not zonePart then return nil end

    zonePart = gsub(zonePart, "^%s+", "")
    zonePart = gsub(zonePart, "%s+$", "")
    if zonePart == "" then return nil end

    local zx = CW.ParseZoneCoordinateNumber(xToken)
    local zy = CW.ParseZoneCoordinateNumber(yToken)
    if not (zx and zy) then return nil end
    if zx < 0 or zx > 100 or zy < 0 or zy > 100 then
        return nil, "coords-out-of-range"
    end

    return {
        zoneName = zonePart,
        zx = zx,
        zy = zy,
    }
end

function CW.ParseCurrentMapCoordsFromSlashArgs(rawMsg)
    local xToken, yToken = tostring(rawMsg or ""):match("^%s*([^%s]+)%s+([^%s]+)%s*$")
    if not xToken then return nil end

    local zx = CW.ParseZoneCoordinateNumber(xToken)
    local zy = CW.ParseZoneCoordinateNumber(yToken)
    if not (zx and zy) then return nil end
    if zx < 0 or zx > 100 or zy < 0 or zy > 100 then
        return nil, "coords-out-of-range"
    end

    return {
        zx = zx,
        zy = zy,
    }
end

function CW.AddWaypointOnCurrentMapCoords(zx, zy)
    if not zx or not zy then
        pr("usage: /cw <x> <y>")
        return
    end

    zx = tonumber(zx)
    zy = tonumber(zy)

    if not zx or not zy then
        pr("invalid coordinates")
        return
    end

    if zx < 0 or zx > 100 or zy < 0 or zy > 100 then
        pr("zone coordinates out of range: expected 0-100 values")
        return
    end

    local map = GetMap(1)
    if not map then
        pr("current map unavailable")
        return
    end

    local mapId = map.GCMI and map:GCMI()
    if not mapId then
        pr("failed to resolve current map")
        return
    end

    local wx, wy = map:GWP(zx / 100, zy / 100)
    if not wx or not wy then
        pr("failed to convert coords")
        return
    end

    local dest = BuildPointFromAnchor(mapId, zx, zy, nil, "connector")
    if not dest then
        pr("failed to build destination")
        return
    end

    dest.ts = date("%Y-%m-%d %H:%M:%S")
    dest.zoneText = dest.zoneText or dest.mapName
    dest.subZoneText = dest.subZoneText or dest.mapName

    local wasEmpty = #(STATE.db.destinations or {}) == 0
    PushHistorySnapshot("add-waypoint")
    STATE.lastCaptureTime = GetTime() or 0
    tinsert(STATE.db.destinations, dest)
    HandleQueueBecameNonEmpty("add-waypoint", wasEmpty)

    dbg(format("saved #%d => GCMI=%d (%s) zx=%.1f zy=%.1f wx=%.3f wy=%.3f",
        #STATE.db.destinations,
        dest.maI or -1,
        dest.mapName or "?",
        dest.zx or -1,
        dest.zy or -1,
        dest.wx or -1,
        dest.wy or -1))

    InvalidateRoute("waypoint added")
    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end

    if EnsureQueueButtons then
        EnsureQueueButtons()
    elseif RefreshUiHeader then
        RefreshUiHeader()
    end
end

function CW.FormatZoneResolveMatches(matches)
    if type(matches) ~= "table" or #matches == 0 then return nil end
    local out = {}
    local limit = math.min(#matches, 3)
    for i = 1, limit do
        out[#out + 1] = tostring(matches[i].mapName or matches[i].maI or "?")
    end
    if #matches > limit then
        out[#out + 1] = "+" .. tostring(#matches - limit) .. " more"
    end
    return table.concat(out, ", ")
end


function CW.ResolveManualTransportDestinationByName(name)
    local targetKey = CW.NormalizeZoneLookupKey(name)
    if not targetKey or targetKey == "" then
        return nil, "empty-name"
    end

    local exactMatches = {}
    local looseMatches = {}

    local function tryEdge(edge)
        local kind = CanonicalTransportKind(edge and (edge.transportKind or edge.type) or "transport")
        if not (kind == "passage" or kind == "portal" or kind == "transport" or kind == "flight_master" or kind == "route") then
            return
        end

        local matchedExactly = false
        local matchedLoosely = false
        for _, value in ipairs(CW.BuildTransportLookupAliases(edge)) do
            local aliasKey = CW.NormalizeZoneLookupKey(value)
            if aliasKey ~= "" then
                if aliasKey == targetKey then
                    matchedExactly = true
                    break
                elseif string.find(aliasKey, targetKey, 1, true) or string.find(targetKey, aliasKey, 1, true) then
                    matchedLoosely = true
                end
            end
        end

        if matchedExactly then
            exactMatches[#exactMatches + 1] = edge
        elseif matchedLoosely then
            looseMatches[#looseMatches + 1] = edge
        end
    end

    for _, edge in ipairs(EnsureTransportDb() or {}) do
        tryEdge(edge)
    end

    for _, loc in ipairs(STATE.db and STATE.db.knownLocations or {}) do
        local edge = CW.BuildManualTransportLikeEdgeFromKnownLocation(loc)
        if edge then
            tryEdge(edge)
        end
    end

    if #exactMatches == 1 then
        return CW.OrientTransportEdgeTowardDestination(exactMatches[1], name), nil
    end
    if #exactMatches > 1 then
        return nil, "ambiguous"
    end
    if #looseMatches == 1 then
        return CW.OrientTransportEdgeTowardDestination(looseMatches[1], name), nil
    end
    if #looseMatches > 1 then
        return nil, "ambiguous"
    end
    return nil, "not-found"
end

local function DestinationMatchesResolvedTransportAlias(dest, resolvedTransport)
    if not (dest and resolvedTransport) then return false end
    for _, value in ipairs(CW.BuildTransportLookupAliases(resolvedTransport)) do
        if CW.ZoneLookupKeysMatchLoosely(dest.subZoneText, value)
            or CW.ZoneLookupKeysMatchLoosely(dest.zoneText, value)
            or CW.ZoneLookupKeysMatchLoosely(dest.userName, value)
            or CW.ZoneLookupKeysMatchLoosely(dest.mapName, value) then
            return true
        end
    end
    return false
end

function CW.AddWaypointFromZoneCoords(zoneName, zx, zy)
    EnsureDb()

    local maI, why, matches = CW.ResolveMapIdBySmartName(zoneName)
    local resolvedTransport, transportWhy = CW.ResolveManualTransportDestinationByName(zoneName)
    local singleNodeTransport = CW.IsSingleNodeManualTransportEdge(resolvedTransport)
    local transportResolvedMaI = CW.ResolveBestMapIdFromTransportAliases(resolvedTransport)

    local preferTransport =
        resolvedTransport
        and resolvedTransport.toMaI
        and CW.TransportDestinationAliasMatches(resolvedTransport, zoneName)

    if preferTransport then
        if singleNodeTransport then
            maI = transportResolvedMaI or resolvedTransport.toMaI
        else
            maI = resolvedTransport.toMaI
        end
        why = nil
        matches = nil
    elseif not maI then
        if resolvedTransport and resolvedTransport.toMaI then
            if singleNodeTransport then
                maI = transportResolvedMaI or resolvedTransport.toMaI
            else
                maI = resolvedTransport.toMaI
            end
            why = nil
        else
            why = transportWhy or why
        end
    end

    if not maI then
        if why == "ambiguous-normalized" or why == "ambiguous-contains" then
            pr("zone match ambiguous: " .. tostring(zoneName) .. " → " .. tostring(CW.FormatZoneResolveMatches(matches) or "multiple matches"))
        elseif why == "ambiguous" then
            pr("zone match ambiguous: " .. tostring(zoneName))
        elseif why == "not-found" then
            pr("zone not found: " .. tostring(zoneName))
        else
            pr("zone resolve failed: " .. tostring(zoneName) .. " (" .. tostring(why) .. ")")
        end
        return false, why
    end

    local dest = BuildPointFromAnchor(maI, zx, zy, nil, "connector")
    if not dest then
        pr("coordinate conversion failed: " .. tostring(zoneName) .. " " .. tostring(zx) .. " " .. tostring(zy))
        return false, "point-build-failed"
    end

    local resolvedMapName = nil
    do
        local map = GetMap()
        if map and map.ITN and (transportResolvedMaI or maI) then
            resolvedMapName = map:ITN(transportResolvedMaI or maI)
        end
    end

    local zoneHint = tostring((resolvedMapName and resolvedMapName ~= "" and resolvedMapName) or (resolvedTransport and (resolvedTransport.toSubZoneText or resolvedTransport.toZoneText or resolvedTransport.toZoneName)) or zoneName or "")
    if zoneHint ~= "" then
        dest.userName = dest.userName or zoneHint
        dest.zoneText = dest.zoneText or zoneHint
        dest.subZoneText = dest.subZoneText or zoneHint
    end

    local wasEmpty = #(STATE.db.destinations or {}) == 0
    PushHistorySnapshot("add-zone-coordinate-waypoint")
    STATE.lastCaptureTime = GetTime() or 0

    local shouldInjectTransportPath = preferTransport
    if shouldInjectTransportPath then
        local transportTargetName =
            (resolvedTransport and resolvedTransport.toSubZoneText and resolvedTransport.toSubZoneText ~= "" and resolvedTransport.toSubZoneText)
            or (resolvedTransport and resolvedTransport.toZoneName and resolvedTransport.toZoneName ~= "" and resolvedTransport.toZoneName)
            or zoneName

        local alreadyThere = CW.DoesPlayerAlreadyMatchZoneNameLoosely(transportTargetName)
        if not alreadyThere and not singleNodeTransport then
            alreadyThere = CW.IsPlayerNearTransportEndpoint(resolvedTransport, "to", 140)
        end

        shouldInjectTransportPath = not alreadyThere
    end

    if shouldInjectTransportPath then
        local transportLabel = tostring((resolvedTransport and (resolvedTransport.trackerLabel or resolvedTransport.label)) or resolvedTransport.toZoneName or zoneName)

        local transportEntry = CW.BuildPointFromTransportEndpoint(
            resolvedTransport,
            "from",
            "Transport entry: " .. transportLabel
        )
        local transportExit = CW.BuildPointFromTransportEndpoint(
            resolvedTransport,
            "to",
            transportLabel
        )

        if transportEntry then
            transportEntry.ts = date("%Y-%m-%d %H:%M:%S")
            tinsert(STATE.db.destinations, transportEntry)
        end

        if transportExit and not CW.ArePointsNearSameLocation(transportExit, dest) then
            transportExit.ts = date("%Y-%m-%d %H:%M:%S")
            tinsert(STATE.db.destinations, transportExit)
        end
    end

    dest.userLabel = dest.userLabel or "wp"
    dest.ts = date("%Y-%m-%d %H:%M:%S")

    local lastQueued = STATE.db.destinations[#STATE.db.destinations]
    if not CW.ArePointsNearSameLocation(lastQueued, dest) then
        tinsert(STATE.db.destinations, dest)
    end

    HandleQueueBecameNonEmpty("add-zone-coordinate-waypoint", wasEmpty)
    InvalidateRoute("zone coordinate waypoint added")
    RefreshUiHeader()
    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end
    pr(format("saved zone waypoint: %s %.1f %.1f", tostring(dest.mapName or zoneName or maI), dest.zx or -1, dest.zy or -1))
    return true, nil, dest
end

function ResolveSouthKalimdorFallbackIds()
    local tanarisMaI = ResolveMapIdByName("Tanaris")
    local ungoroMaI = ResolveMapIdByName("Un'Goro Crater")
    local silithusMaI = ResolveMapIdByName("Silithus")
    local thousandNeedlesMaI = ResolveMapIdByName("Thousand Needles")
    if not tanarisMaI or not ungoroMaI or not thousandNeedlesMaI then
        return nil
    end
    return {
        tanaris = {
            maI = tanarisMaI,
            north = { zx = 50.0, zy = 26.0, label = "Forced Kalimdor south connector: Tanaris north" },
            south = { zx = 27.0, zy = 57.0, label = "Forced Kalimdor south connector: Tanaris south" },
        },
        ungoro = {
            maI = ungoroMaI,
            west = { zx = 30.0, zy = 24.0, label = "Forced Kalimdor south connector: Un'Goro west" },
        },
        silithus = silithusMaI and { maI = silithusMaI } or nil,
        thousand_needles = {
            maI = thousandNeedlesMaI,
            gate = { zx = 33.0, zy = 13.0, label = "Forced Kalimdor south connector: Thousand Needles" },
        },
    }
end

function BuildPointFromResolvedAnchor(resolved, regionKey, pointKey, edgeType)
    if not (resolved and resolved[regionKey] and resolved[regionKey][pointKey]) then
        return nil
    end
    local region = resolved[regionKey]
    local point = region[pointKey]
    return BuildPointFromAnchor(region.maI, point.zx, point.zy, point.label, edgeType or "connector")
end

function BuildSouthKalimdorFallbackLeg(startPoint, destPoint, why)
    if not (startPoint and destPoint and startPoint.wx and startPoint.wy and destPoint.wx and destPoint.wy) then
        return nil
    end

    local resolved = ResolveSouthKalimdorFallbackIds()
    if not resolved then
        return nil
    end

    local tanarisMaI = resolved.tanaris and resolved.tanaris.maI
    local ungoroMaI = resolved.ungoro and resolved.ungoro.maI
    local silithusMaI = resolved.silithus and resolved.silithus.maI
    local startMaI = tonumber(startPoint.maI)
    local destMaI = tonumber(destPoint.maI)

    if destMaI ~= tanarisMaI and destMaI ~= ungoroMaI and (not silithusMaI or destMaI ~= silithusMaI) then
        return nil
    end

    local routePoints = {
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
        }
    }

    local anchors = {}
    local function addResolved(regionKey, pointKey)
        local pt = BuildPointFromResolvedAnchor(resolved, regionKey, pointKey, "connector")
        if not pt then return end
        local prev = anchors[#anchors]
        if prev and prev.maI == pt.maI and math.abs((prev.zx or 0) - (pt.zx or 0)) < 0.01 and math.abs((prev.zy or 0) - (pt.zy or 0)) < 0.01 then
            return
        end
        anchors[#anchors + 1] = pt
    end

    if startMaI ~= tanarisMaI and startMaI ~= ungoroMaI and (not silithusMaI or startMaI ~= silithusMaI) then
        addResolved("thousand_needles", "gate")
        addResolved("tanaris", "north")
        if destMaI == ungoroMaI or (silithusMaI and destMaI == silithusMaI) then
            addResolved("tanaris", "south")
        end
        if silithusMaI and destMaI == silithusMaI then
            addResolved("ungoro", "west")
        end
    elseif startMaI == tanarisMaI then
        if destMaI == ungoroMaI then
            addResolved("tanaris", "south")
        elseif silithusMaI and destMaI == silithusMaI then
            addResolved("tanaris", "south")
            addResolved("ungoro", "west")
        end
    elseif startMaI == ungoroMaI then
        if destMaI == tanarisMaI then
            addResolved("tanaris", "north")
        elseif silithusMaI and destMaI == silithusMaI then
            addResolved("ungoro", "west")
        end
    elseif silithusMaI and startMaI == silithusMaI then
        if destMaI == ungoroMaI then
            addResolved("ungoro", "west")
        elseif destMaI == tanarisMaI then
            addResolved("ungoro", "west")
            addResolved("tanaris", "north")
        end
    end

    local totalCost = 0
    local previous = routePoints[1]
    local added = 0
    for _, pt in ipairs(anchors) do
        if pt and previous.wx and previous.wy and pt.wx and pt.wy then
            pt.cost = WalkCostSeconds(previous.wx, previous.wy, pt.wx, pt.wy)
            totalCost = totalCost + (pt.cost or 0)
            routePoints[#routePoints + 1] = pt
            previous = pt
            added = added + 1
        end
    end

    if added <= 0 then
        return nil
    end

    local finalPoint = {
        maI = destPoint.maI,
        wx = destPoint.wx,
        wy = destPoint.wy,
        zx = destPoint.zx,
        zy = destPoint.zy,
        mapName = destPoint.mapName,
        edgeType = "walk",
        label = "Forced Kalimdor south destination",
        forceStraight = true,
    }
    finalPoint.cost = WalkCostSeconds(previous.wx, previous.wy, finalPoint.wx, finalPoint.wy)
    totalCost = totalCost + (finalPoint.cost or 0)
    routePoints[#routePoints + 1] = finalPoint

    dbg("using forced Kalimdor south fallback chain: " .. tostring(why))
    return {
        totalCost = totalCost,
        explored = 1 + added,
        fallbackDirect = true,
        forcedSouthKalimdor = true,
        points = routePoints,
    }
end

SyncQueueToCarbonite = function(skipIfUnchanged, routeOverride)
    local map = GetMap()
    if not map then
        pr("sync failed: Carbonite map not ready")
        return false
    end

    local function BuildSyncSignature(points)
        local parts = {}
        for i, pt in ipairs(points or {}) do
            parts[#parts + 1] = table.concat({
                tostring(i),
                tostring(pt.maI or ""),
                tostring(pt.wx or ""),
                tostring(pt.wy or ""),
                tostring(pt.edgeType or ""),
                tostring(BuildSyncLabel(i, pt) or ""),
                tostring(GetTargetTypeForRoutePoint(pt) or ""),
            }, "|")
        end
        return table.concat(parts, "||")
    end

    local previousSignature = nil
    if skipIfUnchanged then
        previousSignature = tostring(STATE.lastCarboniteSyncSignature or "")
    end

    local route, why = routeOverride, nil
    if not route then
        route, why = BuildExpandedRoute()
    end
    if not route then
        pr("route rebuild failed: " .. tostring(why))
        return false
    end

    local syncPoints = BuildSyncPoints(route.points or {})
    local newSignature = BuildSyncSignature(syncPoints)
    if skipIfUnchanged and previousSignature == newSignature then
        dbg("sync skipped: unchanged route")
        return true
    end

    InstallCarboniteTravelHook()
    ClearCarboniteTargets(map)

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
    STATE.lastCarboniteSyncSignature = newSignature

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

local function ShowWaypointMetadataPopup(opts)
    if not opts then return end

    if STATE.waypointMetadataPopup and STATE.waypointMetadataPopup.frame then
        STATE.waypointMetadataPopup.frame:Hide()
    end

    local frameName = "CustomWaypointsWaypointMetadataPopup"
    local f = CreateFrame("Frame", frameName, UIParent)
    f:SetWidth(520)
    f:SetHeight(260)
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
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local FocusMetadataBox
    local FocusNextMetadataBox
    local metadataBoxes
    local CommitWaypointMetadata
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText(opts.title or "Waypoint metadata")

    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -48)
    nameLabel:SetText("Name")

    local nameBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    nameBox:SetAutoFocus(false)
    nameBox:SetWidth(360)
    nameBox:SetHeight(20)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
    nameBox:SetText(opts.defaultName or "")
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        CommitWaypointMetadata()
    end)
    nameBox:SetScript("OnTabPressed", function(self)
        self:ClearFocus()
        FocusNextMetadataBox(self, IsShiftKeyDown and IsShiftKeyDown())
    end)

    local labelLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    labelLabel:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -22)
    labelLabel:SetText("Label")

    local labelBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    labelBox:SetAutoFocus(false)
    labelBox:SetWidth(360)
    labelBox:SetHeight(20)
    labelBox:SetPoint("LEFT", labelLabel, "RIGHT", 10, 0)
    labelBox:SetText(opts.defaultLabel or "")
    labelBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    labelBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        CommitWaypointMetadata()
    end)
    labelBox:SetScript("OnTabPressed", function(self)
        self:ClearFocus()
        FocusNextMetadataBox(self, IsShiftKeyDown and IsShiftKeyDown())
    end)

    local descLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    descLabel:SetPoint("TOPLEFT", labelLabel, "BOTTOMLEFT", 0, -22)
    descLabel:SetText("Description")

    local descBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    descBox:SetAutoFocus(false)
    descBox:SetWidth(360)
    descBox:SetHeight(20)
    descBox:SetPoint("LEFT", descLabel, "RIGHT", 10, 0)
    descBox:SetText(opts.defaultDescription or "")
    descBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    descBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        CommitWaypointMetadata()
    end)
    descBox:SetScript("OnTabPressed", function(self)
        self:ClearFocus()
        FocusNextMetadataBox(self, IsShiftKeyDown and IsShiftKeyDown())
    end)

    local zoneLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    zoneLabel:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -26)
    zoneLabel:SetText("Zone/Subzone")

    local zoneBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    zoneBox:SetAutoFocus(false)
    zoneBox:SetWidth(360)
    zoneBox:SetHeight(20)
    zoneBox:SetPoint("LEFT", zoneLabel, "RIGHT", 10, 0)
    zoneBox:SetText(opts.defaultZoneName or "")
    zoneBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    zoneBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        CommitWaypointMetadata()
    end)
    zoneBox:SetScript("OnTabPressed", function(self)
        self:ClearFocus()
        FocusNextMetadataBox(self, IsShiftKeyDown and IsShiftKeyDown())
    end)

    local showZoneField = opts.showZoneField == true
    if not showZoneField then
        zoneLabel:Hide()
        zoneBox:Hide()
    end

    local extraCheckboxes = {}
    local lastAnchor = showZoneField and zoneLabel or descLabel
    if type(opts.extraCheckboxes) == "table" and #opts.extraCheckboxes > 0 then
        for i, def in ipairs(opts.extraCheckboxes) do
            local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
            if i == 1 then
                cb:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -22)
            else
                cb:SetPoint("LEFT", lastAnchor, "RIGHT", 80, 0)
            end            
            cb:SetChecked(def.checked and true or false)

            local cbLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cbLabel:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            cbLabel:SetText(def.label or tostring(def.key or i))

            extraCheckboxes[#extraCheckboxes + 1] = {
                key = def.key or tostring(i),
                check = cb,
                label = cbLabel,
            }
            lastAnchor = cb
        end
    end

    local checkboxByKey = {}
    for _, info in ipairs(extraCheckboxes) do
        checkboxByKey[info.key] = info
    end

    local function SetPopupZoneFieldEnabled(enabled)
        if not zoneBox then return end
        if zoneBox.EnableMouse then zoneBox:EnableMouse(enabled and true or false) end
        if zoneBox.SetAlpha then zoneBox:SetAlpha(enabled and 1 or 0.5) end
        if zoneLabel and zoneLabel.SetAlpha then zoneLabel:SetAlpha(enabled and 1 or 0.5) end
        if not enabled and zoneBox.ClearFocus then zoneBox:ClearFocus() end
    end

    local function RefreshPopupExtraState()
        if opts.onRefreshExtraCheckboxes then
            opts.onRefreshExtraCheckboxes(checkboxByKey, SetPopupZoneFieldEnabled)
        end
    end

    for _, info in ipairs(extraCheckboxes) do
        info.check:SetScript("OnClick", function(self)
            if info.key == "flightMaster" and self:GetChecked() and checkboxByKey.passage and checkboxByKey.passage.check then
                checkboxByKey.passage.check:SetChecked(false)
            elseif info.key == "passage" and self:GetChecked() and checkboxByKey.flightMaster and checkboxByKey.flightMaster.check then
                checkboxByKey.flightMaster.check:SetChecked(false)
            end
            RefreshPopupExtraState()
        end)
    end

    FocusMetadataBox = function(box)
        if box and box.SetFocus then
            box:SetFocus()
            if box.HighlightText then
                box:HighlightText()
            end
        end
    end

    metadataBoxes = { nameBox, labelBox, descBox }
    if showZoneField and zoneBox then
        metadataBoxes[#metadataBoxes + 1] = zoneBox
    end

    FocusNextMetadataBox = function(current, backwards)
        local currentIndex = 1
        for i, box in ipairs(metadataBoxes) do
            if box == current then
                currentIndex = i
                break
            end
        end

        local nextIndex
        if backwards then
            nextIndex = currentIndex - 1
            if nextIndex < 1 then
                nextIndex = #metadataBoxes
            end
        else
            nextIndex = currentIndex + 1
            if nextIndex > #metadataBoxes then
                nextIndex = 1
            end
        end

        FocusMetadataBox(metadataBoxes[nextIndex])
    end

    CommitWaypointMetadata = function()
        if opts.onSave then
            local extraValues = {}
            for _, info in ipairs(extraCheckboxes) do
                extraValues[info.key] = info.check:GetChecked() and true or false
            end
            opts.onSave({
                name = TrimEditorMetadataValue(nameBox:GetText()),
                label = TrimEditorMetadataValue(labelBox:GetText()),
                description = TrimEditorMetadataValue(descBox:GetText()),
                zoneName = zoneBox and TrimEditorMetadataValue(zoneBox:GetText()) or "",
                extraValues = extraValues,
            })
        end
        f:Hide()
    end
    
    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetWidth(80)
    saveBtn:SetHeight(22)
    saveBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 16)
    saveBtn:SetText("Save")
    saveBtn:SetScript("OnClick", CommitWaypointMetadata)

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetWidth(80)
    cancelBtn:SetHeight(22)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() f:Hide() end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function(self)
        if nameBox and nameBox.ClearFocus then nameBox:ClearFocus() end
        if labelBox and labelBox.ClearFocus then labelBox:ClearFocus() end
        if descBox and descBox.ClearFocus then descBox:ClearFocus() end
        if zoneBox and zoneBox.ClearFocus then zoneBox:ClearFocus() end
        if STATE.waypointMetadataPopup and STATE.waypointMetadataPopup.frame == self then
            STATE.waypointMetadataPopup = nil
        end
    end)

    STATE.waypointMetadataPopup = {
        frame = f,
        nameBox = nameBox,
        labelBox = labelBox,
        descBox = descBox,
        zoneBox = zoneBox,
    }

    RefreshPopupExtraState()
    ArmKeyboardModalFrame(f)
    f:Show()
    FocusMetadataBox(nameBox)
end

CW.ShowWaypointMetadataPopup = ShowWaypointMetadataPopup

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

AddLabeledCurrentCursorWaypoint = function()
    local map = GetMap()
    local dest, why = GetDisplayedCapture(map)
    if not dest then
        pr("capture failed: " .. tostring(why))
        return
    end

    CustomWaypoints.ShowWaypointMetadataPopup({
        title = "Save captured waypoint",
        defaultName = BuildDefaultWaypointName(dest),
        defaultLabel = "wp",
        defaultDescription = "",
        showZoneField = false,
        onSave = function(meta)
            local wasEmpty = #(STATE.db.destinations or {}) == 0
            PushHistorySnapshot("add-labeled-waypoint")
            STATE.lastCaptureTime = GetTime() or 0
            dest.userName = meta.name ~= "" and meta.name or nil
            dest.userLabel = meta.label ~= "" and meta.label or nil
            dest.description = meta.description ~= "" and meta.description or nil
            if meta.zoneName ~= "" then
                dest.subZoneText = meta.zoneName
                dest.zoneText = meta.zoneName
            end
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
    EnsureDb()
    local dest = GetPlayerWorldPos()
    if not dest and STATE.lastStablePlayerPos then
        dest = CloneWorldPoint(STATE.lastStablePlayerPos)
    end
    if not dest then
        pr("savehere failed: no player position")
        return
    end

    CustomWaypoints.ShowWaypointMetadataPopup({
        title = "Save current location as waypoint",
        defaultName = BuildDefaultWaypointName(dest),
        defaultLabel = "wp",
        defaultDescription = "",
        showZoneField = false,
        onSave = function(meta)
            local wasEmpty = #(STATE.db.destinations or {}) == 0
            PushHistorySnapshot("add-current-location-waypoint")
            STATE.lastCaptureTime = GetTime() or 0
            dest.userName = meta.name ~= "" and meta.name or nil
            dest.userLabel = meta.label ~= "" and meta.label or nil
            dest.description = meta.description ~= "" and meta.description or nil
            dest.ts = date("%Y-%m-%d %H:%M:%S")
            tinsert(STATE.db.destinations, dest)
            -- if STATE.db.autoAdvance then
            --     SlashHandler("autoadvance")
            -- end
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
    dbg(format("completed #1 => %s (reason=%s)", first.mapName or ("Map " .. tostring(first.maI)), reason or "reach"))
    InvalidateRoute("advanced queue")
    SyncQueueToCarbonite()
end

-- Seconds to wait after adding a waypoint before AutoAdvance may remove #1 (avoids "vanished" right after click).
local GRACE_AFTER_CAPTURE_SEC = 4

local function GetCurrentSyncedRoutePoint()
    if not STATE.db or #(STATE.db.destinations or {}) == 0 then return nil end

    local route = STATE.expandedRoute
    if not route or type(route.points) ~= "table" then
        route = BuildExpandedRoute()
    end
    if not route or type(route.points) ~= "table" then
        return nil
    end

    local syncPoints = BuildSyncPoints(route.points or {})
    return syncPoints[1] or STATE.db.destinations[1]
end

local function AdvanceCurrentRouteTarget(reason)
    if not STATE.db or #(STATE.db.destinations or {}) == 0 then return false end

    local current = GetCurrentSyncedRoutePoint()
    if not current then
        RemoveFirstWaypoint(reason)
        return true
    end

    if current.isQueueStop then
        RemoveFirstWaypoint(reason)
        return true
    end

    local cachedRoute = STATE.expandedRoute
    STATE.deepSyncSkipCount = (tonumber(STATE.deepSyncSkipCount) or 0) + 1

    if reason == "manual-pop" or reason == "undoable-pop" then
        pr(format("advanced current route node => %s (reason=%s)",
            current.label or current.mapName or ("Map " .. tostring(current.maI)),
            reason or "manual-pop"))
    else
        dbg(format("advanced current route node => %s (reason=%s)",
            current.label or current.mapName or ("Map " .. tostring(current.maI)),
            reason or "reach"))
    end

    if STATE.db.autoSyncToCarbonite then
        if cachedRoute and type(cachedRoute.points) == "table" then
            SyncQueueToCarbonite(nil, cachedRoute)
        else
            SyncQueueToCarbonite()
        end
    end
    return true
end

local function GetReachedFirstWaypointDistanceYards()
    if not STATE.db or #STATE.db.destinations == 0 then return nil end

    local player = GetPlayerWorldPos()
    if not player then return nil end

    local first = GetCurrentSyncedRoutePoint()
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
        AdvanceCurrentRouteTarget(format("%.1f yards", yards))
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
    pr(format("queue=%d carboniteTargets=%d expandedRoute=%d syncPoints=%d totalCost=%.1f sec explored=%d spellFlyingDetection=%s simplifyTransit=%s useFlightMasters=%s",
        #STATE.db.destinations, #tar, #route.points, #syncPoints, route.totalCost or -1, route.explored or -1, tostring(CW.ShouldUseSpellFlyingDetection()), tostring(STATE.db.simplifyTransitWaypoints), tostring(STATE.db.useFlightMasters)))

    pr(format("route: %d queue stop(s), %d point(s), ~%.0fs", #STATE.db.destinations, #route.points, route.totalCost or 0))

    for i, pt in ipairs(route.points) do
        pr(format("route %d: maI=%d (%s) zx=%.1f zy=%.1f wx=%.3f wy=%.3f edge=%s cost=%.1f label=%s",
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

GraphSummary = function()
    local graph, why = EnsureGraph()
    if not graph then
        pr("graph build failed: " .. tostring(why))
        return
    end
    pr(format("graph: %d nodes, %d edges", graph.nodeCount or 0, graph.edgeCount or 0))
    dbg(format("graph nodes=%d edges=%d transportLinks=%d", graph.nodeCount or 0, graph.edgeCount or 0, #(graph.links or {})))
end

EnsureCarboniteMapButtons = function()
    local map = GetMap()
    if not map or not map.Frm then return end

    local parent = map.Frm
    local b = STATE.mapSaveRouteButton

    if not b or (b.IsObjectType and not b:IsObjectType("Button")) then
        b = CreateFrame("Button", "CWSaveRouteMapButton", parent, "UIPanelButtonTemplate")
        b:SetWidth(88)
        b:SetHeight(20)
        b:SetText("Save Route")
        b:SetFrameStrata("DIALOG")
        b:SetScript("OnClick", function()
            SaveQueueAsKnownRoute()
        end)
        STATE.mapSaveRouteButton = b
    end

    if b.GetParent and b:GetParent() ~= parent and b.SetParent then
        b:SetParent(parent)
    end

    if b.ClearAllPoints then
        b:ClearAllPoints()
    end
    b:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -5, 25)

    if b.SetFrameStrata and parent.GetFrameStrata then
        b:SetFrameStrata(parent:GetFrameStrata())
    end
    if b.SetFrameLevel and parent.GetFrameLevel then
        b:SetFrameLevel((parent:GetFrameLevel() or 1) + 10)
    end

    if b.EnableMouse then
        b:EnableMouse(true)
    end
    if b.Enable then
        b:Enable()
    end
    if b.SetAlpha then
        b:SetAlpha(1)
    end
    if b.Show then
        b:Show()
    end

    if not STATE.mapSaveRouteButtonHooksInstalled then
        local function RefreshMapSaveRouteButton()
            if not STATE.mapSaveRouteButton then return end
            local currentMap = GetMap()
            if not currentMap or not currentMap.Frm then return end
            local btn = STATE.mapSaveRouteButton
            local currentParent = currentMap.Frm

            if btn.GetParent and btn:GetParent() ~= currentParent and btn.SetParent then
                btn:SetParent(currentParent)
            end
            if btn.ClearAllPoints then
                btn:ClearAllPoints()
            end
            btn:SetPoint("BOTTOMRIGHT", currentParent, "BOTTOMRIGHT", -5, 25)

            if btn.SetFrameStrata and currentParent.GetFrameStrata then
                btn:SetFrameStrata(currentParent:GetFrameStrata())
            end
            if btn.SetFrameLevel and currentParent.GetFrameLevel then
                btn:SetFrameLevel((currentParent:GetFrameLevel() or 1) + 10)
            end

            if btn.EnableMouse then btn:EnableMouse(true) end
            if btn.Enable then btn:Enable() end
            if btn.SetAlpha then btn:SetAlpha(1) end
            if currentParent.IsShown and currentParent:IsShown() then
                btn:Show()
            else
                btn:Hide()
            end
        end

        parent:HookScript("OnShow", RefreshMapSaveRouteButton)
        parent:HookScript("OnHide", function()
            if STATE.mapSaveRouteButton and STATE.mapSaveRouteButton.Hide then
                STATE.mapSaveRouteButton:Hide()
            end
        end)
        parent:HookScript("OnSizeChanged", RefreshMapSaveRouteButton)

        STATE.mapSaveRouteButtonHooksInstalled = true
    end
end

function CW.HookMapClicks()
    EnsureCarboniteMapButtons()
    if STATE.hookInstalled then return end
    local map = GetMap()
    if not map or not map.Frm then return end

    map.Frm:HookScript("OnMouseDown", function(_, button)
        if STATE.syncing then return end

        if button == "RightButton" and STATE.mapSaveRouteButton and STATE.mapSaveRouteButton.Hide then
            local btn = STATE.mapSaveRouteButton
            btn:Hide()
            STATE.mapSaveRouteButtonRestoreAt = (GetTime and GetTime() or 0) + 0.35
        end

        local labeled = (button == "LeftButton" and IsShiftKeyDown() and IsControlKeyDown())
        local primary = (button == (STATE.db.bindingButton or "LeftButton") and IsModifierDown(STATE.db.bindingModifier or "SHIFT") and not IsControlKeyDown())
        local fallback = (button == (STATE.db.fallbackButton or "RightButton") and IsModifierDown(STATE.db.fallbackModifier or "CTRL"))

        if labeled then
            AddLabeledCurrentCursorWaypoint()
        elseif primary or fallback then
            AddCurrentCursorWaypoint()
        end
    end)

    map.Frm:HookScript("OnUpdate", function()
        local btn = STATE.mapSaveRouteButton
        local restoreAt = STATE.mapSaveRouteButtonRestoreAt
        if not (btn and restoreAt) then return end
        local now = GetTime and GetTime() or 0
        if now < restoreAt then return end
        STATE.mapSaveRouteButtonRestoreAt = nil

        local currentMap = GetMap()
        local parent = currentMap and currentMap.Frm
        if not (parent and parent.IsShown and parent:IsShown()) then return end

        if btn.GetParent and btn:GetParent() ~= parent and btn.SetParent then
            btn:SetParent(parent)
        end
        if btn.ClearAllPoints then
            btn:ClearAllPoints()
        end
        btn:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -5, 25)
        if btn.SetFrameStrata and parent.GetFrameStrata then
            btn:SetFrameStrata(parent:GetFrameStrata())
        end
        if btn.SetFrameLevel and parent.GetFrameLevel then
            btn:SetFrameLevel((parent:GetFrameLevel() or 1) + 10)
        end
        if btn.EnableMouse then btn:EnableMouse(true) end
        if btn.Enable then btn:Enable() end
        if btn.SetAlpha then btn:SetAlpha(1) end
        if btn.Show then btn:Show() end
    end)

    STATE.hookInstalled = true
    dbg("mouse hook installed (Shift+LeftClick primary, Ctrl+RightClick fallback)")
end

function CW.HookCarboniteClear()
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

        local reachedYards = GetReachedFirstWaypointDistanceYards()
        if STATE.db.autoAdvance and reachedYards then
            dbg(format("Carbonite clear near reached waypoint; advancing current route target instead of clearing all (%.1f yards)", reachedYards))
            AdvanceCurrentRouteTarget(format("Carbonite clear %.1f yards", reachedYards))
            return
        end

        wipe(STATE.db.destinations)
        InvalidateRoute("Carbonite clear")
        dbg("queue cleared because Carbonite ClT1 cleared active targets")
    end)

    STATE.clearHookInstalled = true
    dbg("Carbonite clear hook installed")
end

function CW.ExportWaypoints()
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
    pr(format("export: %d waypoint(s) in block (%d data lines). Select all in CW log, copy, paste into Import.", n, n))
end

function CW.DebugFlightMaster(name)
    dbg("---- FM DEBUG START ----")

    if not name or name == "" then
        dbg("usage: /cw debugfm <name>")
        return
    end

    local function norm(n)
        if not n then return nil end
        n = tostring(n)
        n = gsub(n, "^%s+", "")
        n = gsub(n, "%s+$", "")
        return lower(n)
    end

    local inputNorm = norm(name)
    dbg("input=" .. tostring(name))
    dbg("inputNorm=" .. tostring(inputNorm))

    local foundTaxi = false
    if NxCData and type(NxCData["Taxi"]) == "table" then
        for k, v in pairs(NxCData["Taxi"]) do
            if v then
                local nk = norm(k)
                if nk == inputNorm then
                    dbg("NxCData exact known match: " .. tostring(k))
                    foundTaxi = true
                elseif nk and inputNorm and string.find(nk, inputNorm, 1, true) then
                    dbg("NxCData partial known match: " .. tostring(k))
                end
            end
        end
    else
        dbg("NxCData Taxi table unavailable")
    end

    if not foundTaxi then
        dbg("NxCData exact known match: none")
    end

    local foundNode = false
    if Nx and Nx.Tra and type(Nx.Tra.Tra) == "table" then
        for _, list in pairs(Nx.Tra.Tra) do
            if type(list) == "table" then
                for _, nod in ipairs(list) do
                    if type(nod) == "table" and nod.LoN then
                        local nk = norm(nod.LoN)
                        if nk == inputNorm then
                            dbg("Nx.Tra exact node: " .. tostring(nod.LoN) .. " maI=" .. tostring(nod.MaI) .. " wx=" .. tostring(nod.WX) .. " wy=" .. tostring(nod.WY))
                            foundNode = true
                        elseif nk and inputNorm and string.find(nk, inputNorm, 1, true) then
                            dbg("Nx.Tra partial node: " .. tostring(nod.LoN))
                        end
                    end
                end
            end
        end
    else
        dbg("Nx.Tra.Tra unavailable")
    end

    if not foundNode then
        dbg("Nx.Tra exact node: none")
    end

    if Nx and Nx.Map and Nx.Map.Gui and type(Nx.Map.Gui.FiT2) == "function" then
        local npcName, wx, wy = Nx.Map.Gui:FiT2(name)
        dbg("FiT2 => npcName=" .. tostring(npcName) .. " wx=" .. tostring(wx) .. " wy=" .. tostring(wy))
    else
        dbg("FiT2 unavailable")
    end

    dbg("---- FM DEBUG END ----")
end

function CW.TrimDestinationSearchText(value)
    local s = tostring(value or "")
    s = gsub(s, "^%s+", "")
    s = gsub(s, "%s+$", "")
    return s
end

function CW.DestinationSearchMatchScore(query, ...)
    local q = CW.NormalizeZoneLookupKey(query)
    if not q or q == "" or #q < 2 then return nil end

    local best = nil
    for i = 1, select("#", ...) do
        local raw = select(i, ...)
        local key = CW.NormalizeZoneLookupKey(raw)
        if key and key ~= "" then
            local score = nil
            if key == q then
                score = 1000
            elseif string.find(key, "^" .. q) ~= nil then
                score = 850
            elseif string.find(key, q, 1, true) ~= nil then
                score = 700
            elseif #key >= 4 and string.find(q, key, 1, true) ~= nil then
                score = 560
            else
                local allTokens = true
                for token in string.gmatch(q, "%S+") do
                    if not string.find(key, token, 1, true) then
                        allTokens = false
                        break
                    end
                end
                if allTokens then
                    score = 620
                end
            end

            if score and (not best or score > best) then
                best = score
            end
        end
    end

    return best
end

function CW.AddDestinationSearchCandidate(candidates, query, sourcePriority, candidate, ...)
    if not (type(candidates) == "table" and candidate and candidate.destination) then return end
    local score = CW.DestinationSearchMatchScore(query, ...)
    if not score then return end

    candidate.score = score + (sourcePriority or 0)
    candidate.sourcePriority = sourcePriority or 0
    candidates[#candidates + 1] = candidate
end

function CW.FormatDestinationSearchCandidate(candidate)
    if not candidate then return "?" end
    local dest = candidate.destination or {}
    local loc = tostring(dest.mapName or candidate.mapName or "?")
    if dest.zx and dest.zy then
        loc = format("%s %.1f %.1f", loc, dest.zx or -1, dest.zy or -1)
    end
    return format("%s (%s)",
        tostring(candidate.kind or "?"),
        loc)
end

function CW.PrintDestinationSearchAmbiguity(query, candidates)
    local parts = {}
    local limit = math.min(#candidates, 5)
    for i = 1, limit do
        parts[#parts + 1] = CW.FormatDestinationSearchCandidate(candidates[i])
    end
    if #candidates > limit then
        parts[#parts + 1] = "+" .. tostring(#candidates - limit) .. " more"
    end
    dbg("destination match ambiguous: " .. tostring(query) .. " -> " .. table.concat(parts, "; "))
end

function CW.CollectKnownDestinationSearchCandidates(candidates, query)
    EnsureDb()

    local entries = BuildKnownLocationEntries()
    for _, entry in ipairs(entries or {}) do
        local dest = nil
        local pointCount = 0
        local kind = tostring(entry.kind or "known")

        if kind == "route" and type(entry.routePoints) == "table" and #entry.routePoints > 0 then
            pointCount = #entry.routePoints
            dest = CloneDestination(entry.routePoints[1])
            if dest then
                dest.label = dest.label or ("Start of route: " .. tostring(entry.name or "known route"))
                dest.userName = dest.userName or tostring(entry.name or "known route")
                dest.userLabel = dest.userLabel or "route-start"
            end
        else
            dest = CloneDestination(entry.destination or entry.lastTarget or entry.previousTarget)
            if dest then
                dest.label = dest.label or tostring(entry.name or entry.label or "known location")
                dest.userName = dest.userName or tostring(entry.name or entry.label or "known location")
                dest.userLabel = dest.userLabel or tostring(entry.transportKind or kind)
            end
        end

        if dest then
            CW.AddDestinationSearchCandidate(candidates, query, kind == "route" and 80 or 70, {
                sourceType = kind == "route" and "knownRoute" or "knownLocation",
                kind = kind,
                name = tostring(entry.name or entry.label or dest.userName or dest.mapName or "Known location"),
                mapName = dest.mapName or entry.mapName,
                destination = dest,
                routePointCount = pointCount,
                routePoints = (kind == "route" and type(entry.routePoints) == "table") and entry.routePoints or nil,
            },
                entry.name,
                entry.label,
                entry.description,
                entry.mapName,
                entry.transportKind,
                dest.userName,
                dest.userLabel,
                dest.zoneText,
                dest.subZoneText,
                dest.mapName)
        end
    end
end

function CW.DecodeCarboniteFavoriteDestination(typ, dat)
    if not (Nx and Nx.Fav and dat) then return nil end

    local maI, zx, zy
    if typ == "N" and type(Nx.Fav.PIN) == "function" then
        local ok, _, id, x, y = pcall(function() return Nx.Fav:PIN(dat) end)
        if ok then
            maI, zx, zy = id, x, y
        end
    elseif (typ == "T" or typ == "t") and type(Nx.Fav.PIT) == "function" then
        local ok, id, x, y = pcall(function() return Nx.Fav:PIT(dat) end)
        if ok then
            maI, zx, zy = id, x, y
        end
    end

    if not (maI and zx and zy) then return nil end
    return BuildPointFromAnchor(maI, zx, zy, nil, "connector")
end

function CW.CollectCarboniteFavoriteCandidates(candidates, query)
    if not (NxData and type(NxData.NXFav) == "table" and Nx and Nx.Fav and type(Nx.Fav.PaI1) == "function") then
        return
    end

    local function scanFolder(folder, folderPath)
        if type(folder) ~= "table" then return end
        for _, item in ipairs(folder) do
            if type(item) == "table" then
                scanFolder(item, tostring(folderPath or "") .. " " .. tostring(item.Name or ""))
            elseif type(item) == "string" then
                local ok, typ, _, nam, dat = pcall(function() return Nx.Fav:PaI1(item) end)
                if ok and (typ == "N" or typ == "T" or typ == "t") then
                    local dest = CW.DecodeCarboniteFavoriteDestination(typ, dat)
                    if dest then
                        dest.label = dest.label or tostring(nam or "Carbonite favorite")
                        dest.userName = dest.userName or tostring(nam or "Carbonite favorite")
                        dest.userLabel = dest.userLabel or (typ == "N" and "carbonite-note" or "carbonite-target")
                        CW.AddDestinationSearchCandidate(candidates, query, 55, {
                            sourceType = "carboniteFavorite",
                            kind = typ == "N" and "note" or "target",
                            name = tostring(nam or "Carbonite favorite"),
                            mapName = dest.mapName,
                            destination = dest,
                        }, nam, folderPath, dest.mapName, dest.zoneText, dest.subZoneText)
                    end
                end
            end
        end
    end

    scanFolder(NxData.NXFav, "")
end

function CW.AddCarboniteGuidePointCandidate(candidates, query, guideType, name, maI, zx, zy, extraText)
    if not (maI and zx and zy) then return end

    local dest = BuildPointFromAnchor(maI, zx, zy, tostring(name or guideType), "connector")
    if not dest then return end

    dest.userName = dest.userName or tostring(name or guideType or "Carbonite guide")
    dest.userLabel = dest.userLabel or tostring(guideType or "guide")
    dest.zoneText = dest.zoneText or dest.mapName
    dest.subZoneText = dest.subZoneText or dest.mapName

    CW.AddDestinationSearchCandidate(candidates, query, 25, {
        sourceType = "carboniteGuide",
        kind = tostring(guideType or "guide"),
        name = tostring(name or guideType or "Carbonite guide"),
        mapName = dest.mapName,
        destination = dest,
    }, name, guideType, extraText, dest.mapName, dest.zoneText, dest.subZoneText)
end

function CW.CollectCarboniteGuideCandidates(candidates, query)
    if not (Nx and Nx.GuD and Nx.Map and Nx.Que and type(Nx.GuD) == "table") then
        return
    end

    local mapObject = GetMap()
    local mapApi = Nx.Map
    local que = Nx.Que
    local hiF = UnitFactionGroup and UnitFactionGroup("player") == "Horde" and 1 or 2

    for guideType, byContinent in pairs(Nx.GuD) do
        if type(byContinent) == "table" then
            for _, daS in pairs(byContinent) do
                if type(daS) == "string" and #daS > 0 then
                    local mod1 = string.byte(daS, 1)
                    if mod1 == 32 then
                        local n = 2
                        while n + 5 <= #daS do
                            local fac2 = (string.byte(daS, n) or 35) - 35
                            if fac2 ~= hiF then
                                local zon = (string.byte(daS, n + 1) or 35) - 35
                                local maI = (mapApi.NTMI and mapApi.NTMI[zon]) or (Nx.NTMI and Nx.NTMI[zon])
                                local loc = string.sub(daS, n + 2, n + 5)
                                local ok, zx, zy = pcall(function() return que:UnL(loc, true) end)
                                if ok and maI and zx and zy then
                                    local mapName = (mapObject and mapObject.ITN and mapObject:ITN(maI)) or (Nx.MITN and Nx.MITN[maI])
                                    CW.AddCarboniteGuidePointCandidate(candidates, query, guideType, tostring(guideType), maI, zx, zy, mapName)
                                end
                            end
                            n = n + 6
                        end
                    elseif mod1 ~= 33 then
                        local n = 1
                        while n + 1 <= #daS do
                            local b1 = string.byte(daS, n)
                            local b2 = string.byte(daS, n + 1)
                            if b1 and b2 then
                                local npI = (b1 - 35) * 221 + (b2 - 35)
                                local npS = Nx.NPCD and Nx.NPCD[npI]
                                if type(npS) == "string" and #npS > 1 then
                                    local fac2 = (string.byte(npS, 1) or 35) - 35
                                    if fac2 ~= hiF then
                                        local oSt = string.sub(npS, 2)
                                        local ok, des1, zon, loc = pcall(function() return que:UnO(oSt) end)
                                        if ok and des1 and zon and loc then
                                            local maI = (mapApi.NTMI and mapApi.NTMI[zon]) or (Nx.NTMI and Nx.NTMI[zon])
                                            if maI and string.byte(oSt, loc) == 32 then
                                                loc = loc + 1
                                                local cnt = math.floor((#oSt - loc + 1) / 4)
                                                local cleanName = gsub(tostring(des1), "!", ", ")
                                                local compactName = gsub(tostring(des1), "!", " ")
                                                local loN1 = loc
                                                while loN1 <= loc + cnt * 4 - 1 do
                                                    local lo1 = string.sub(oSt, loN1, loN1 + 3)
                                                    local ok2, zx, zy = pcall(function() return que:UnL(lo1, true) end)
                                                    if ok2 and zx and zy then
                                                        CW.AddCarboniteGuidePointCandidate(candidates, query, guideType, cleanName, maI, zx, zy, compactName)
                                                    end
                                                    loN1 = loN1 + 4
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            n = n + 2
                        end
                    end
                end
            end
        end
    end
end

function CW.SearchDestinationKeyword(query)
    local clean = CW.TrimDestinationSearchText(query)
    if clean == "" or #CW.NormalizeZoneLookupKey(clean) < 2 then
        return {}
    end

    local candidates = {}
    CW.CollectKnownDestinationSearchCandidates(candidates, clean)
    CW.CollectCarboniteFavoriteCandidates(candidates, clean)
    CW.CollectCarboniteGuideCandidates(candidates, clean)

    table.sort(candidates, function(a, b)
        if (a.score or 0) ~= (b.score or 0) then
            return (a.score or 0) > (b.score or 0)
        end
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    return candidates
end

function CW.RouteToDestinationSearchCandidate(candidate, query)
    if not (candidate and candidate.destination) then return false end

    EnsureDb()
    local dest = CloneDestination(candidate.destination)
    if not dest then
        pr("destination match has no usable point: " .. tostring(candidate.name or query))
        return false
    end

    dest.ts = date("%Y-%m-%d %H:%M:%S")
    dest.userName = dest.userName or tostring(candidate.name or query)
    dest.userLabel = dest.userLabel or tostring(candidate.kind or "search")
    dest.label = dest.label or tostring(candidate.name or query)

    local routePoints = nil
    if candidate.kind == "route" and type(candidate.routePoints) == "table" and #candidate.routePoints > 0 then
        routePoints = CloneDestinations(candidate.routePoints)
        if routePoints and routePoints[1] then
            routePoints[1].ts = routePoints[1].ts or dest.ts
            routePoints[1].userName = routePoints[1].userName or dest.userName
            routePoints[1].userLabel = routePoints[1].userLabel or dest.userLabel or "route-start"
            routePoints[1].label = routePoints[1].label or dest.label
        end
    end

    local wasEmpty = #(STATE.db.destinations or {}) == 0
    PushHistorySnapshot("route-destination-search")
    wipe(STATE.db.destinations)

    if routePoints and #routePoints > 0 then
        for i = 1, #routePoints do
            tinsert(STATE.db.destinations, routePoints[i])
        end
    else
        tinsert(STATE.db.destinations, dest)
    end

    HandleQueueBecameNonEmpty("route-destination-search", wasEmpty)

    InvalidateRoute("destination search")
    RefreshUiHeader()
    if STATE.db.autoSyncToCarbonite then
        SyncQueueToCarbonite()
    end

    if routePoints and #routePoints > 1 then
        dbg(format("routing to matched known route: %s (%d stop(s), starting at stop 1)", tostring(candidate.name or query), #routePoints))
    else
        dbg(format("routing to destination match: %s", CW.FormatDestinationSearchCandidate(candidate)))
    end


    return true
end

function CW.SelectDestinationSearchCandidate(index)
    local ui = STATE.destinationSearchUi
    if not ui then return end

    ui.selectedIndex = index
    CW.RefreshDestinationSearchFrame()
end

function CW.SetDestinationSearchPage(page)
    local ui = STATE.destinationSearchUi
    if not ui then return end

    local candidates = ui.candidates or {}
    local pageSize = ui.pageSize or 20
    local maxPage = math.max(1, math.ceil(#candidates / pageSize))

    page = tonumber(page) or 1
    if page < 1 then page = 1 end
    if page > maxPage then page = maxPage end

    ui.page = page
    ui.selectedIndex = nil
    ui.lastClickKey = nil
    ui.lastClickTime = nil

    if ui.scroll and ui.scroll.SetVerticalScroll then
        ui.scroll:SetVerticalScroll(0)
    end

    CW.RefreshDestinationSearchFrame()
end

function CW.RefreshDestinationSearchFrame()
    local ui = STATE.destinationSearchUi
    if not (ui and ui.content) then return end

    local content = ui.content
    for _, child in ipairs({content:GetChildren()}) do
        child:Hide()
    end

    local candidates = ui.candidates or {}
    local query = ui.query or ""
    local pageSize = ui.pageSize or 20
    ui.pageSize = pageSize

    local total = #candidates
    local maxPage = math.max(1, math.ceil(total / pageSize))
    local page = tonumber(ui.page) or 1
    if page < 1 then page = 1 end
    if page > maxPage then page = maxPage end
    ui.page = page

    local startOffset = (page - 1) * pageSize
    local endOffset = math.min(total, startOffset + pageSize)
    local startIndex = startOffset + 1
    local endIndex = endOffset

    if total == 0 then
        ui.selectedIndex = nil
    elseif not ui.selectedIndex or not candidates[ui.selectedIndex] or ui.selectedIndex < startIndex or ui.selectedIndex > endIndex then
        ui.selectedIndex = startIndex
    end

    if ui.summaryText then
        if query == "" then
            ui.summaryText:SetText("Enter a search and press Search. Results include known locations, known routes, Carbonite favorites, and Carbonite guide POIs.")
        elseif total == 0 then
            ui.summaryText:SetText("No destination matches for: " .. tostring(query))
        else
            ui.summaryText:SetText(format("%d result(s) for: %s  (%d-%d of %d)", total, tostring(query), startOffset, endOffset, total))
        end
    end

    if ui.pageText then
        if total > pageSize then
            ui.pageText:SetText(format("Page %d/%d", page, maxPage))
            ui.pageText:Show()
        else
            ui.pageText:SetText("")
            ui.pageText:Hide()
        end
    end

    if ui.prevPageBtn then
        if total > pageSize then
            ui.prevPageBtn:Show()
            if page > 1 then ui.prevPageBtn:Enable() else ui.prevPageBtn:Disable() end
        else
            ui.prevPageBtn:Hide()
        end
    end

    if ui.nextPageBtn then
        if total > pageSize then
            ui.nextPageBtn:Show()
            if page < maxPage then ui.nextPageBtn:Enable() else ui.nextPageBtn:Disable() end
        else
            ui.nextPageBtn:Hide()
        end
    end

    local yOffset = -8
    if total == 0 then
        content:SetHeight(44)
        return
    end

    local visibleCount = endIndex - startIndex + 1
    for candidateIndex = startIndex, endIndex do
        local idx = candidateIndex
        local candidate = candidates[idx]
        local row = CreateFrame("Button", nil, content)
        row:SetWidth(650)
        row:SetHeight(48)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
        row:RegisterForClicks("LeftButtonUp")

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        if idx == ui.selectedIndex then
            bg:SetTexture(0.2, 0.45, 0.9, 0.28)
        else
            bg:SetTexture(1, 1, 1, 0.04)
        end

        local routeCandidate = candidate
        row:SetScript("OnClick", function()
            local now = GetTime and GetTime() or 0
            local uiState = STATE.destinationSearchUi
            local chosenBeforeRefresh = uiState and uiState.candidates and uiState.candidates[idx] or nil
            local chosenDest = chosenBeforeRefresh and chosenBeforeRefresh.destination or nil
            local chosenKey = chosenBeforeRefresh and (
                tostring(chosenBeforeRefresh.sourceType or "?") .. ":" ..
                tostring(chosenBeforeRefresh.kind or "?") .. ":" ..
                tostring(chosenBeforeRefresh.name or "?") .. ":" ..
                tostring(chosenDest and chosenDest.maI or "?") .. ":" ..
                tostring(chosenDest and chosenDest.zx or "?") .. ":" ..
                tostring(chosenDest and chosenDest.zy or "?")
            ) or nil

            local isDouble =
                chosenKey
                and uiState
                and uiState.lastClickKey == chosenKey
                and uiState.lastClickTime
                and (now - uiState.lastClickTime) <= 0.35

            if uiState then
                uiState.lastClickKey = chosenKey
                uiState.lastClickTime = now
            end

            CW.SelectDestinationSearchCandidate(idx)

            if isDouble and chosenBeforeRefresh then
                if CW.RouteToDestinationSearchCandidate(chosenBeforeRefresh, ui.query) then
                    if STATE.destinationSearchUi and STATE.destinationSearchUi.frame then
                        STATE.destinationSearchUi.frame:Hide()
                    end
                end
            end
        end)

        local title = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        title:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -7)
        title:SetWidth(500)
        title:SetJustifyH("LEFT")
        title:SetText(format("%d) %s", idx, tostring(candidate.name or "?")))

        local meta = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        meta:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
        meta:SetWidth(510)
        meta:SetJustifyH("LEFT")
        meta:SetText(format("%s", CW.FormatDestinationSearchCandidate(candidate)))

        local routeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        routeBtn:SetWidth(82)
        routeBtn:SetHeight(22)
        routeBtn:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        routeBtn:SetText("Route")
        routeBtn:SetScript("OnClick", function()
            CW.SelectDestinationSearchCandidate(idx)
            if CW.RouteToDestinationSearchCandidate(routeCandidate, ui.query) then
                if ui.frame then ui.frame:Hide() end
            end
        end)

        yOffset = yOffset - 52
    end

    content:SetHeight(math.max(44, visibleCount * 52 + 12))
end

function CW.SubmitDestinationSearchFrame()
    local ui = STATE.destinationSearchUi
    if not ui then return end

    local query = ui.searchBox and ui.searchBox:GetText() or ""
    query = CW.TrimDestinationSearchText(query)
    ui.query = query
    ui.candidates = CW.SearchDestinationKeyword(query)
    ui.page = 1
    ui.selectedIndex = nil
    ui.lastClickKey = nil
    ui.lastClickTime = nil
    CW.RefreshDestinationSearchFrame()
end

function CW.ShowDestinationSearchFrame(initialQuery, initialCandidates)
    local query = CW.TrimDestinationSearchText(initialQuery or "")

    if STATE.destinationSearchUi and STATE.destinationSearchUi.frame then
        local ui = STATE.destinationSearchUi
        ui.query = query
        ui.candidates = initialCandidates or CW.SearchDestinationKeyword(query)
        ui.page = 1
        ui.selectedIndex = nil
        ui.lastClickKey = nil
        ui.lastClickTime = nil
        if ui.searchBox then
            ui.searchBox:SetText(query)
        end
        CW.RefreshDestinationSearchFrame()
        ArmKeyboardModalFrame(ui.frame)
        ui.frame:Show()
        RefreshCwEscOverride()
        return ui
    end

    local f = CreateFrame("Frame", "CustomWaypointsDestinationSearchFrame", UIParent)
    f:SetWidth(720)
    f:SetHeight(390)
    f:SetPoint("CENTER", UIParent, "CENTER", 40, -20)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(94)
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
        if STATE.destinationSearchUi and STATE.destinationSearchUi.searchBox then
            STATE.destinationSearchUi.searchBox:ClearFocus()
        end
        if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(true) end
        if self.EnableKeyboard then self:EnableKeyboard(false) end
    end)
    f:SetScript("OnMouseDown", function(self)
        PushCwModalFrame(self)
    end)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.90)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("CustomWaypoints - Destination Search")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -8)
    subtitle:SetWidth(660)
    subtitle:SetJustifyH("CENTER")
    subtitle:SetText("Used for ambiguous /cw <dest> matches. Edit the search, press Search, then Route the desired result.")

    local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -64)
    searchLabel:SetText("Search")

    local searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    searchBox:SetAutoFocus(false)
    searchBox:SetWidth(430)
    searchBox:SetHeight(20)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        RefreshCwEscOverride()
    end)
    searchBox:SetScript("OnEnterPressed", function(self)
        CW.SubmitDestinationSearchFrame()
        self:SetFocus()
        if self.HighlightText then self:HighlightText() end
        RefreshCwEscOverride()
    end)
    searchBox:SetScript("OnEditFocusGained", function()
        RefreshCwEscOverride()
    end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        if self.HighlightText then self:HighlightText(0, 0) end
        RefreshCwEscOverride()
    end)

    local submitBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    submitBtn:SetWidth(82)
    submitBtn:SetHeight(22)
    submitBtn:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
    submitBtn:SetText("Search")
    submitBtn:SetScript("OnClick", function()
        CW.SubmitDestinationSearchFrame()
    end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local summaryText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summaryText:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -94)
    summaryText:SetWidth(430)
    summaryText:SetJustifyH("LEFT")

    local prevPageBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prevPageBtn:SetWidth(52)
    prevPageBtn:SetHeight(20)
    prevPageBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -190, -90)
    prevPageBtn:SetText("Prev")
    prevPageBtn:SetScript("OnClick", function()
        local ui = STATE.destinationSearchUi
        CW.SetDestinationSearchPage((ui and ui.page or 1) - 1)
    end)

    local pageText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pageText:SetPoint("LEFT", prevPageBtn, "RIGHT", 8, 0)
    pageText:SetWidth(70)
    pageText:SetJustifyH("CENTER")

    local nextPageBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    nextPageBtn:SetWidth(52)
    nextPageBtn:SetHeight(20)
    nextPageBtn:SetPoint("LEFT", pageText, "RIGHT", 8, 0)
    nextPageBtn:SetText("Next")
    nextPageBtn:SetScript("OnClick", function()
        local ui = STATE.destinationSearchUi
        CW.SetDestinationSearchPage((ui and ui.page or 1) + 1)
    end)

    local scroll = CreateFrame("ScrollFrame", "CustomWaypointsDestinationSearchScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -120)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 18)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(650)
    content:SetHeight(44)
    scroll:SetScrollChild(content)

    STATE.destinationSearchUi = {
        frame = f,
        searchBox = searchBox,
        submitBtn = submitBtn,
        scroll = scroll,
        content = content,
        summaryText = summaryText,
        prevPageBtn = prevPageBtn,
        nextPageBtn = nextPageBtn,
        pageText = pageText,
        query = query,
        candidates = initialCandidates or CW.SearchDestinationKeyword(query),
        page = 1,
        pageSize = 20,
        selectedIndex = nil,
        lastClickKey = nil,
        lastClickTime = nil,
    }

    searchBox:SetText(query)
    CW.RefreshDestinationSearchFrame()
    ArmKeyboardModalFrame(f)
    f:Show()
    RefreshCwEscOverride()
    return STATE.destinationSearchUi
end

function CW.TryRouteByDestinationKeyword(query)
    local candidates = CW.SearchDestinationKeyword(query)
    if not candidates or #candidates == 0 then
        return false, "not-found"
    end

    local best = candidates[1]
    local second = candidates[2]
    if second and (second.score or 0) == (best.score or 0) then
        CW.PrintDestinationSearchAmbiguity(query, candidates)
        if CW.ShowDestinationSearchFrame then
            CW.ShowDestinationSearchFrame(query, candidates)
        end
        return true, "ambiguous"
    end

    CW.RouteToDestinationSearchCandidate(best, query)
    return true, nil
end

SlashHandler = function(msg)
    local rawMsg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local debugFmArg = rawMsg:match("^[Dd][Ee][Bb][Uu][Gg][Ff][Mm]%s+(.+)$")
    if debugFmArg then
        CW.DebugFlightMaster(debugFmArg)
        return
    end

    msg = string.lower(rawMsg)

    if msg == "" or msg == "help" then
        pr("commands: /cw ui | tuning | options | help | probe | add | list | export | import | sync | route | graph | clear | pop | undo | redo | autosync | autoadvance | autodiscovery | flightmasters | deep | minimal | debug | debugfm <name> | simplify | legend | transports | cleartransports | transportlog | transportconfirmation | knownlocations | search | saveroute | savehere")
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
        CW.ExportWaypoints()
    elseif msg:match("^import%s+") then
        local payload = msg:match("^import%s+(.+)$")
        ImportWaypointsFromText(payload or "")
    elseif msg == "import" then
        ShowWaypointImportPopup()
        pr("import: paste export lines into the waypoint import popup (or /cw import <single line>).")
    elseif msg == "sync" then
        SyncQueueToCarbonite()
    elseif msg == "route" then
        RouteSummary()
    elseif msg == "graph" then
        GraphSummary()
    elseif msg == "clear" then
        ClearWaypoints()
    elseif msg == "pop" then
        AdvanceCurrentRouteTarget("manual-pop")
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
        ShowKnownLocationsFrame()
    elseif msg == "knownlocations" or msg == "known" then
        ShowKnownLocationsFrame()
    elseif msg == "search" or msg == "find" then
        if CW.ShowDestinationSearchFrame then
            CW.ShowDestinationSearchFrame("")
        end
    elseif msg:match("^routeknown%s+%d+$") then
        local idx = tonumber(msg:match("^routeknown%s+(%d+)$"))
        RouteToKnownLocation(idx)
    else
        local currentMapParsed, currentMapWhy = CW.ParseCurrentMapCoordsFromSlashArgs(rawMsg)
        if currentMapParsed then
            CW.AddWaypointOnCurrentMapCoords(currentMapParsed.zx, currentMapParsed.zy)
        else
            local parsed, parseWhy = CW.ParseZoneAndCoordsFromSlashArgs(rawMsg)
            if parsed then
                CW.AddWaypointFromZoneCoords(parsed.zoneName, parsed.zx, parsed.zy)
            elseif currentMapWhy == "coords-out-of-range" or parseWhy == "coords-out-of-range" then
                pr("zone coordinates out of range: expected 0-100 values")
            else
                local handled = CW.TryRouteByDestinationKeyword(rawMsg)
                if not handled then
                    pr("No matches: " .. tostring(msg))
                end
            end
        end
    end
end

ScheduleLoginQueueSyncIfNeeded = function()
    EnsureDb()
    if not STATE.db or #(STATE.db.destinations or {}) == 0 then return end
    STATE.needLoginQueueSync = true
end

TryPendingLoginQueueSync = function()
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

function OnEvent(_, event)
    if event == "PLAYER_LOGIN" then
        EnsureDb()
        CW.CleanupTransientTaxiDestinations(true)
        CW.HookMapClicks()
        CW.HookCarboniteClear()
        InstallCarboniteTravelHook()
        InstallCarboniteSclGuard()
        InstallUndoRedoBindings()
        EnsureKnownLocationsBinding()
        EnsureSaveHereBinding()
        EnsureDeleteSelectedKnownLocationBinding()
        EnsureInterfaceOptionsPanel()
        ScheduleLoginQueueSyncIfNeeded()
        EnsureCarboniteMapButtons()
        dbg("loaded (Phase 5B patched: UI/options/bindings + safer deep fallback + SCL guard)")
    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsureDb()
        CW.CleanupTransientTaxiDestinations(true)
        CW.HookMapClicks()
        CW.HookCarboniteClear()
        InstallCarboniteTravelHook()
        InstallCarboniteSclGuard()
        InstallUndoRedoBindings()
        EnsureKnownLocationsBinding()
        EnsureSaveHereBinding()
        EnsureInterfaceOptionsPanel()
        ScheduleLoginQueueSyncIfNeeded()
        EnsureCarboniteMapButtons()
        if STATE.db and #(STATE.db.destinations or {}) > 0 then
            CW.RefreshRouteForWorldContextChange(event, "player entering world")
        end
        local eventFrom = STATE.lastStablePlayerPos
        local eventCurrent = GetPlayerWorldPos()
        if eventCurrent and eventCurrent.instance and eventFrom and eventFrom.instance and STATE.lastNonInstanceStablePlayerPos then
            eventFrom = STATE.lastNonInstanceStablePlayerPos
        end
        if eventFrom then
            BeginPendingTransport("PLAYER_ENTERING_WORLD", eventFrom)
        end
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED_INDOORS" then
        EnsureDb()

        local onTaxi = IsPlayerOnTaxi()
        if onTaxi then
            STATE.wasOnTaxi = true
            STATE.pendingTaxiRouteRefresh = true
            dbg("zone-change autoroute suppressed: player on taxi (" .. tostring(event) .. ")")
        else
            if STATE.db and #(STATE.db.destinations or {}) > 0 then
                CW.RefreshRouteForWorldContextChange(event, "zone changed")
            end

            local eventFrom = STATE.lastStablePlayerPos
            local eventCurrent = GetPlayerWorldPos()
            if eventCurrent and eventCurrent.instance and eventFrom and eventFrom.instance and STATE.lastNonInstanceStablePlayerPos then
                eventFrom = STATE.lastNonInstanceStablePlayerPos
            end
            if eventFrom then
                BeginPendingTransport(event, eventFrom)
            end
        end
    elseif event == "TAXIMAP_OPENED" then
        EnsureDb()
        if CW.RefreshSessionKnownTaxisFromTaxiMap() then
            STATE.graph = nil
            InvalidateRoute("taxi map opened: refreshed session-known taxis")
            if STATE.db and STATE.db.autoSyncToCarbonite and #(STATE.db.destinations or {}) > 0 then
                SyncQueueToCarbonite()
            end
        end
    elseif event == "PLAYER_DEAD" then
        EnsureDb()
        ResetDeathAutoRouteCycle()

        local deathContext = CaptureDeathInstanceContext()
        if deathContext then
            RememberCorpseInstanceContext(deathContext)
            StartPendingDeathAutoRoute(0.20, deathContext)
        else
            ClearCorpseInstanceContext()
            dbg("death auto-route skipped: death did not occur in known instance context")
        end
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        EnsureDb()
        ResetDeathAutoRouteCycle()
        ClearCorpseInstanceContext()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        RefreshCwEscOverride()
    end
end

function OnUpdate(_, elapsed)
    EnsureCarboniteMapButtons()
    TryPendingLoginQueueSync()
    PulseTransportDiscovery(elapsed)
    PulsePendingDeathAutoRoute()
    PulseAutoAdvance()

    local onTaxi = IsPlayerOnTaxi()
    local current = GetPlayerWorldPos()
    local now = GetTime and GetTime() or 0

    if onTaxi then
        CW.EnterTaxiTransitRoutingOverride()
        CW.EnsureTaxiDestinationQueueHead()
        if STATE.db and #(STATE.db.destinations or {}) > 0 then
            STATE.pendingTaxiRouteRefresh = true
            CW.TryTaxiPeriodicRefresh(now)
        end
    end

    -- === POSITION TRACKING ===
    if current and (current.maI or (current.wx and current.wy)) then
        STATE.lastStablePlayerPos = CloneWorldPoint(current)

        -- Freeze the ground anchor while on taxi so route planning stays stable in flight.
        if not onTaxi then
            STATE.lastGroundPlayerPos = CloneWorldPoint(current)
        end

        if current.instance then
            STATE.lastInstanceStablePlayerPos = CloneWorldPoint(current)
            RememberPersistentInstanceContext(current)
        else
            STATE.lastNonInstanceStablePlayerPos = CloneWorldPoint(current)
        end
    end

    -- === TAXI STATE TRANSITIONS ===
    if onTaxi then
        STATE.wasOnTaxi = true
    elseif STATE.wasOnTaxi then
        STATE.wasOnTaxi = false
        CW.LeaveTaxiTransitRoutingOverride()
        CW.RemoveTaxiDestinationQueueHead(false)

        if STATE.pendingTaxiRouteRefresh and current and (current.maI or (current.wx and current.wy)) then
            STATE.pendingTaxiRouteRefresh = false
            EnsureDb()

            if STATE.db and #(STATE.db.destinations or {}) > 0 then
                InvalidateRoute("taxi ended")
                if STATE.db.autoSyncToCarbonite then
                    SyncQueueToCarbonite()
                end
            end

            local eventFrom = STATE.lastStablePlayerPos
            local eventCurrent = current

            if eventCurrent and eventFrom and eventFrom.instance and STATE.lastNonInstanceStablePlayerPos then
                eventFrom = STATE.lastNonInstanceStablePlayerPos
            end

            if eventFrom then
                BeginPendingTransport("TAXI_ENDED", eventFrom)
            end

            dbg("taxi ended: deferred route refresh resumed")
        end
    elseif not onTaxi then
        CW.LeaveTaxiTransitRoutingOverride()
        CW.RemoveTaxiDestinationQueueHead(false)
    end

    -- === HOOKS (unchanged) ===
    if not STATE.hookInstalled then
        CW.HookMapClicks()
    end
    if not STATE.clearHookInstalled then
        CW.HookCarboniteClear()
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

STATE.frame = CreateFrame("Frame")
STATE.frame:RegisterEvent("PLAYER_LOGIN")
STATE.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
STATE.frame:RegisterEvent("ZONE_CHANGED")
STATE.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
STATE.frame:RegisterEvent("ZONE_CHANGED_INDOORS")
STATE.frame:RegisterEvent("TAXIMAP_OPENED")
STATE.frame:RegisterEvent("PLAYER_DEAD")
STATE.frame:RegisterEvent("PLAYER_ALIVE")
STATE.frame:RegisterEvent("PLAYER_UNGHOST")
STATE.frame:RegisterEvent("PLAYER_REGEN_DISABLED")
STATE.frame:RegisterEvent("PLAYER_REGEN_ENABLED")
STATE.frame:SetScript("OnEvent", OnEvent)
STATE.frame:SetScript("OnUpdate", OnUpdate)

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
