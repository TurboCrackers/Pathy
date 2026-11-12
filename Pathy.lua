-- Pathy: pick a quest giver (to start a quest) or a turn-in NPC (to finish one) and be led there by a 3D arrow along
-- the route BV Addon Suite - Routing plans (walls, stairs, lifts, boats and zeppelins included).
--
-- Pathy finds the places in Questie's WoW: Forever database; BV.lua hands them to BV's planner and copies the leg
-- you are on; this file follows you along it and turns the arrow (drawn in HUD.lua's copy of BV's guide window, or on
-- the screen). Guiding only ends when the quest is accepted / turned in, or /pathy stop.
-- Needs Questie and BV Addon Suite (Core, Map Data, Routing). Nothing else.

local ADDON, ns = ...

local sqrt, floor = math.sqrt, math.floor

local MAX_AVAILABLE = 60

local target        -- { x, y, instance, z, name, quest, kind, uiMap }

local function Print(...) print("|cff66ccffPathy:|r", ...) end

-- Settings (PathyDB holds only what was changed; /pathy config opens the window)
local DEFAULTS = {
	arrow = true, arrowSize = 0.55, arrowAlpha = 0.45, arrowColour = { 0.75, 0.75, 0.75 }, arrowDirColour = true,
	arrowText = true, arrowX = 0.5, arrowY = 0.31, arrowAhead = 40,
	guidePanel = true, hideBVGuide = true, silenceBV = true, showLogButton = false, simpleUI = false,
	textAlpha = 0.9, textColour = { 1, 1, 1 }, textX = 0.5, textY = 0.29,
	windowAlpha = 0.92, windowColour = { 0.05, 0.05, 0.08 }, windowBorder = { 1, 1, 1 }, hudColourOn = false, hudColour = { 1, 0.82, 0 }, uiScale = 1, minimapButton = true, followTracked = true,
}
local function cfg(key)
	local v = PathyDB and PathyDB[key]
	if v == nil then return DEFAULTS[key] end
	return v
end

-- HereBeDragons, the map library: Questie's own copy (it needs no other addon)
local hbdLib
local function HBD()
	hbdLib = hbdLib or LibStub("HereBeDragonsQuestie-2.0", true) or LibStub("HereBeDragons-2.0", true)
	return hbdLib
end

local function dist(ax, ay, bx, by) return sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- What BV.lua (a file of its own: this one is close to Lua's limit of local variables) uses of this one
ns.cfg, ns.Print, ns.dist, ns.HBD = cfg, Print, dist, HBD
ns.getTarget = function() return target end

local function questie(name)
	return QuestieLoader and QuestieLoader:ImportModule(name)
end

------------------------------------------------------------------------------------------------------------
-- Questie lookups
------------------------------------------------------------------------------------------------------------

-- Every spawn of an NPC or object, as world coordinates { instance, x, y, uiMap }.
local function spawnSpots(query, id, out)
	local Z = questie("ZoneDB")
	local hbd = HBD()
	if not Z or not hbd then return out end
	for area, list in pairs(query(id, "spawns") or {}) do
		local uiMap = not Z.IsDungeonZone(area) and Z:GetUiMapIdByAreaId(area)
		for _, c in ipairs(uiMap and list or {}) do
			if c[1] and c[1] >= 0 then
				local x, y, inst = hbd:GetWorldCoordinatesFromZone(c[1] / 100, c[2] / 100, uiMap)
				if x then out[#out + 1] = { instance = inst, x = x, y = y, uiMap = uiMap } end
			end
		end
	end
	return out
end

-- Where a quest starts ("startedBy") or is turned in ("finishedBy"): its NPCs' and objects' spots, named.
local function questSpots(questId, field)
	local DB = questie("QuestieDB")
	local out = {}
	if not DB or not DB.QueryQuestSingle then return out end
	local by = DB.QueryQuestSingle(questId, field)
	if not by then return out end
	local queries = { DB.QueryNPCSingle, DB.QueryObjectSingle }
	for k = 1, 2 do
		local query = queries[k]
		for _, id in ipairs(query and by[k] or {}) do
			local n = #out
			spawnSpots(query, id, out)
			local name = query(id, "name")
			for i = n + 1, #out do out[i].name = name end
		end
	end
	return out
end

-- a quest as Questie writes it: "[level] name" in the colour of its difficulty (plain name if Questie cannot)
local function coloredQuest(questId, fallback)
	local Lib = questie("QuestieLib")
	if Lib and Lib.GetColoredQuestName then
		local ok, text = pcall(Lib.GetColoredQuestName, Lib, questId, true, false)
		if ok and text then return text end
	end
	return fallback
end

local function questName(questId)
	local DB = questie("QuestieDB")
	return DB and DB.QueryQuestSingle and DB.QueryQuestSingle(questId, "name")
end

-- The player's quest log: { id, title, complete }.
local function questLog()
	local out = {}
	if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
		for i = 1, (C_QuestLog.GetNumQuestLogEntries()) do
			local info = C_QuestLog.GetInfo(i)
			if info and not info.isHeader and info.questID and info.questID > 0 then
				local done = C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)
				out[#out + 1] = { id = info.questID, title = info.title, complete = done and true or false }
			end
		end
	elseif GetNumQuestLogEntries then
		for i = 1, (GetNumQuestLogEntries()) do
			local title, _, _, isHeader, _, isComplete, _, id = GetQuestLogTitle(i)
			if not isHeader and id and id > 0 then
				out[#out + 1] = { id = id, title = title, complete = isComplete == 1 or isComplete == true }
			end
		end
	end
	return out
end

-- Quests you can pick up now, worked out from Questie's database the way Questie itself does it (not done, not in
-- your log, not hidden, level requirement met, and Questie's IsDoable: earlier quests in the chain, class, race,
-- faction), but without Questie's map filters: low-level (grey) quests are included, marked as such. Questie only
-- draws icons for some of them, so its map alone missed quests. Recomputed when you accept, hand in or drop a
-- quest, or level up.
local availCache        -- the quest ids
local availSpots = {}   -- questId -> where its givers stand (from the database; kept)

local function availableQuestIds()
	if availCache then return availCache end
	local DB = questie("QuestieDB")
	if not DB or not DB.QuestPointers or not DB.QueryQuestSingle or not DB.IsDoable then return {} end
	local C = questie("QuestieCorrections")
	local hiddenQuests = C and C.hiddenQuests or {}
	local char = Questie and Questie.db and Questie.db.char or {}
	local complete, hidden = char.complete or {}, char.hidden or {}
	local auto = DB.autoBlacklist or {}
	local inLog = {}
	for _, q in ipairs(questLog()) do inLog[q.id] = true end
	local level = UnitLevel("player") or 1
	local out = {}
	for id in pairs(DB.QuestPointers) do
		if not complete[id] and not hiddenQuests[id] and not hidden[id] and not auto[id] and not inLog[id] then
			local req = DB.QueryQuestSingle(id, "requiredLevel") or 0
			if req <= level then
				local ok, doable = pcall(DB.IsDoable, id)
				if ok and doable then out[#out + 1] = id end
			end
		end
	end
	availCache = out
	return out
end

local function invalidateAvailable() availCache = nil end

-- { id, title, name (giver), x, y, instance, uiMap, d, low (a grey quest for you) }, nearest first, this continent
local function availableQuests(px, py, instance)
	local DB = questie("QuestieDB")
	local out = {}
	local level = UnitLevel("player") or 1
	local grey = level - ((GetQuestGreenRange and GetQuestGreenRange("player")) or 8)
	for _, id in ipairs(availableQuestIds()) do
		local spots = availSpots[id]
		if not spots then
			spots = questSpots(id, "startedBy")
			availSpots[id] = spots
		end
		local best, bestD
		for _, s in ipairs(spots) do
			if s.instance == instance then
				local d = dist(px, py, s.x, s.y)
				if not bestD or d < bestD then best, bestD = s, d end
			end
		end
		if best then
			local qLevel = DB.QueryQuestSingle(id, "questLevel") or level
			out[#out + 1] = { id = id, title = questName(id) or ("quest " .. id), name = best.name, x = best.x, y = best.y,
				instance = best.instance, uiMap = best.uiMap, d = bestD, low = qLevel > 0 and qLevel < grey }
		end
	end
	table.sort(out, function(a, b) return a.d < b.d end)
	while #out > MAX_AVAILABLE do table.remove(out) end
	return out
end

------------------------------------------------------------------------------------------------------------
-- Guiding
------------------------------------------------------------------------------------------------------------

-- The map pin you have, if any ( { map, x, y, tracked } )
local function currentPin()
	if not (C_Map.HasUserWaypoint and C_Map.HasUserWaypoint()) then return end
	local wp = C_Map.GetUserWaypoint()
	if not wp or not wp.uiMapID or not wp.position then return end
	return { wp.uiMapID, wp.position.x, wp.position.y,
		C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint() or false }
end

local function stop(msg)
	if not target then return end
	target = nil
	PathyDB.target = nil
	if msg then Print(msg) end
	if PathyFrame and PathyFrame:IsShown() then PathyFrame.Refresh() end
end

ns.stop = stop -- (for HUD.lua: the HUD's button that ends the way)

-- the name of an NPC that walks a route rather than standing still, if it does
local function walker(npcId)
	local DB = questie("QuestieDB")
	if not npcId or not DB or not DB.QueryNPCSingle then return end
	local ok, wps = pcall(DB.QueryNPCSingle, npcId, "waypoints")
	if ok and type(wps) == "table" and next(wps) then return DB.QueryNPCSingle(npcId, "name") or "that NPC" end
end

-- Starts guiding to the best of `spots`. info: { name, quest, questId, kind, what (said in chat), saved (to
-- carry the target over a /reload) }.
local function goTo(spots, info, chosen)
	local px, py, instance = HBD():GetPlayerWorldPosition()
	if not px then return Print("the game gives no position here (inside an instance?)") end
	if #spots == 0 then return Print("no location known for " .. (info.name or "that")) end
	-- Which place is quickest is BV's to say (it knows other continents, boats, zeppelins and lifts)
	if chosen == nil then return ns.BV.choose(spots, function(p) goTo(spots, info, p) end) end
	local pick, trip = chosen, nil
	if not pick then return Print("No way found to any of those places") end
	target = {
		x = pick.x, y = pick.y, instance = pick.instance, z = pick.z, uiMap = pick.uiMap,
		name = pick.name or info.name or "?", quest = info.quest or "", questId = info.questId, kind = info.kind,
	}
	PathyDB.target = info.saved
	local zone = pick.uiMap and C_Map.GetMapInfo(pick.uiMap)
	local eta = trip and trip.cost and (trip.cost < 60 and ", under a minute away" or format(", about %d min away", floor(trip.cost / 60 + 0.5))) or ""
	Print(format("heading to %s%s%s%s", target.name, info.what and (" (" .. info.what .. ")") or "",
		zone and zone.name and (" in " .. zone.name) or "", eta))
	local w = info.walker or walker(info.npcId)
	if w then Print(w .. " walks a route, so they may be a little way off from where the route ends: look around there") end
	if PathyFrame and PathyFrame:IsShown() then PathyFrame.Refresh() end
end

-- Where Questie's map shows a quest's icons of one type ("available": its giver; "complete": where it is handed
-- in). Questie leaves out the spawns that are not there for you (event, script or later-phase ones), which the
-- database's full spawn list does not.
local function questIconSpots(questId, iconType)
	local questMap = questie("QuestieMap")
	local out = {}
	local frames = questMap and questMap.questIdFrames and questMap.questIdFrames[questId]
	for _, frameName in pairs(frames or {}) do
		local fr = _G[frameName]
		local d = fr and fr.data
		if d and d.Id == questId and d.Type == iconType and not fr.miniMapIcon and fr.x and fr.UiMapID then
			local x, y, inst = HBD():GetWorldCoordinatesFromZone(fr.x / 100, fr.y / 100, fr.UiMapID)
			if x then out[#out + 1] = { x = x, y = y, instance = inst, uiMap = fr.UiMapID, name = d.Name } end
		end
	end
	return out
end

local function questWalker(questId, field)
	local DB = questie("QuestieDB")
	local by = DB and DB.QueryQuestSingle and DB.QueryQuestSingle(questId, field)
	for _, id in ipairs(by and by[1] or {}) do
		local w = walker(id)
		if w then return w end
	end
end

-- kind: "giver" (start the quest) or "turnin" (finish it). icon: optional spot from Questie's map icon.
local function go(questId, kind, icon)
	local field = kind == "giver" and "startedBy" or "finishedBy"
	local spots = questIconSpots(questId, kind == "giver" and "available" or "complete")
	if #spots == 0 then spots = questSpots(questId, field) end
	if #spots == 0 and icon then spots = { { x = icon.x, y = icon.y, instance = icon.instance, uiMap = icon.uiMap, name = icon.name } } end
	local quest = questName(questId) or ("quest " .. questId)
	if #spots == 0 then
		return Print(format("Questie has no location for the %s of %s", kind == "giver" and "quest giver" or "turn-in", quest))
	end
	goTo(spots, { quest = quest, questId = questId, kind = kind, what = (kind == "giver" and "starts " or "turn in ") .. quest,
		saved = { questId = questId, kind = kind }, walker = questWalker(questId, field) })
end

-- An in-progress quest's goal, best first:
--  1. the area the game marks for the quest on the map: its centre;
--  2. the objectives Questie shows (the mobs, objects, items still needed): the centre of each group of them;
--  3. the quest's NPC (where it is handed in).
local OBJECTIVE_GROUP = 60 -- yards: objective spots this close together count as one area

local function questAreaCentre(questId)
	if not (C_QuestLog and C_QuestLog.GetQuestsOnMap) then return end
	local map = C_Map.GetBestMapForUnit("player")
	for _ = 1, 5 do
		if not map or map == 0 then return end
		local ok, list = pcall(C_QuestLog.GetQuestsOnMap, map)
		if ok and type(list) == "table" then
			for _, q in ipairs(list) do
				if q.questID == questId and q.x and q.y then
					local x, y, inst = HBD():GetWorldCoordinatesFromZone(q.x, q.y, map)
					if x then return { x = x, y = y, instance = inst, uiMap = map, name = "the quest area" } end
				end
			end
		end
		local info = C_Map.GetMapInfo(map)
		map = info and info.parentMapID
	end
end

-- the centres of the groups of objective spots Questie draws for a quest (objectives already done left out)
local function objectiveAreas(questId)
	local questMap = questie("QuestieMap")
	local frames = questMap and questMap.questIdFrames and questMap.questIdFrames[questId]
	local pts = {}
	for _, frameName in pairs(frames or {}) do
		local fr = _G[frameName]
		local d = fr and fr.data
		if d and d.Id == questId and d.Type ~= "available" and d.Type ~= "complete" and not fr.miniMapIcon
			and fr.x and fr.UiMapID and not (d.ObjectiveData and d.ObjectiveData.Completed) then
			local x, y, inst = HBD():GetWorldCoordinatesFromZone(fr.x / 100, fr.y / 100, fr.UiMapID)
			if x then pts[#pts + 1] = { x = x, y = y, instance = inst, uiMap = fr.UiMapID, name = d.Name } end
		end
	end
	local areas, used = {}, {}
	for i, p in ipairs(pts) do
		if not used[i] then
			local sx, sy, n = 0, 0, 0
			local members = {}
			for j, q in ipairs(pts) do
				if not used[j] and q.instance == p.instance and dist(p.x, p.y, q.x, q.y) <= OBJECTIVE_GROUP then
					used[j] = true
					sx, sy, n = sx + q.x, sy + q.y, n + 1
					members[#members + 1] = q
				end
			end
			-- the group's real spawn nearest its centre (a plain average can land in rock or off the walkable ground)
			local cx, cy = sx / n, sy / n
			local best, bestD = p, math.huge
			for _, q in ipairs(members) do
				local d = dist(cx, cy, q.x, q.y)
				if d < bestD then best, bestD = q, d end
			end
			areas[#areas + 1] = { x = best.x, y = best.y, instance = best.instance, uiMap = best.uiMap, name = p.name or "the objective" }
		end
	end
	return areas
end

local function goObjective(questId)
	local quest = questName(questId) or ("quest " .. questId)
	local saved = { questId = questId, kind = "objective" }
	-- Questie's real spawn spots first (where the mob / object actually is); the game's quest-area centre is only
	-- a blob's middle, which for a "kill X" quest can be nowhere near any X.
	local areas = objectiveAreas(questId)
	if #areas > 0 then
		return goTo(areas, { quest = quest, questId = questId, kind = "objective", what = "objective for " .. quest, saved = saved })
	end
	local area = questAreaCentre(questId)
	if area then
		return goTo({ area }, { quest = quest, questId = questId, kind = "objective", what = "the area for " .. quest, saved = saved })
	end
	go(questId, "turnin")
end

-- Your map pin (the one you had, if Pathy is already steering the game's pin).
local function goPin()
	local pin = currentPin()
	if not pin then return Print("you have no map pin: Ctrl+click on the world map to place one, then |cffffff00/pathy pin|r") end
	local x, y, inst = HBD():GetWorldCoordinatesFromZone(pin[2], pin[3], pin[1])
	if not x then return Print("can't place that map pin in the world") end
	goTo({ { x = x, y = y, instance = inst, uiMap = pin[1], name = "your map pin" } },
		{ kind = "pin", what = nil, saved = { kind = "pin", pin = pin } })
end

-- An NPC by its id: every spawn Questie knows for it.
local function goNpc(npcId, name)
	local DB = questie("QuestieDB")
	if not DB or not DB.QueryNPCSingle then return Print("Questie is still loading; try again in a moment") end
	local spots = spawnSpots(DB.QueryNPCSingle, npcId, {})
	local dbName = DB.QueryNPCSingle(npcId, "name")
	for _, s in ipairs(spots) do s.name = dbName or name end
	if #spots == 0 then return Print(format("Questie has no location for %s", dbName or name or ("NPC " .. npcId))) end
	goTo(spots, { name = dbName or name, kind = "npc", npcId = npcId, saved = { kind = "npc", npcId = npcId, name = dbName or name } })
end

-- The NPC you have targeted (its id is in its GUID: Creature-0-server-instance-zone-ID-spawn).
local function goTargetNpc()
	local guid = UnitGUID("target")
	local unitType, _, _, _, _, npcId = strsplit("-", guid or "")
	if not guid or (unitType ~= "Creature" and unitType ~= "Vehicle") then
		return Print("target an NPC first, then |cffffff00/pathy target|r")
	end
	goNpc(tonumber(npcId), UnitName("target"))
end

-- There is no "arrived": guiding ends when the quest is accepted / turned in, or /pathy stop.
-- Group members: the game gives addons their positions (out in the world, not inside dungeons), so Pathy can
-- walk you to them and follow as they move. Friends outside your group: only their zone is known.
local FOLLOW_MOVE = 5  -- yards a group member moves before the route is planned again

local function unitByGuid(guid)
	if not guid then return end
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local u = "raid" .. i
			if UnitGUID(u) == guid and not UnitIsUnit(u, "player") then return u end
		end
	else
		for i = 1, 4 do
			local u = "party" .. i
			if UnitGUID(u) == guid then return u end
		end
	end
end

-- A group member's position: from their spot on their current map, as the world map draws party members
-- (reliable), else the raw unit position (which some clients leave stale or at zero for other players).
local function unitWorldPos(u)
	local map = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit(u)
	if map and C_Map.GetPlayerMapPosition then
		local pos = C_Map.GetPlayerMapPosition(map, u)
		local mx, my
		if pos then mx, my = pos:GetXY() end
		if mx and (mx ~= 0 or my ~= 0) then
			local x, y, inst = HBD():GetWorldCoordinatesFromZone(mx, my, map)
			if x then return x, y, inst end
		end
	end
	local x, y, inst = HBD():GetUnitWorldPosition(u)
	if x and (x ~= 0 or y ~= 0) then return x, y, inst end
end

-- A player's whole name as the game writes it in chat: the character's name and its realm ("Name-Realm"), the
-- realm being the player's own when the game leaves it out
local function fullName(u)
	local name, realm = UnitFullName(u)
	if not name then return end
	if not realm or realm == "" then realm = GetRealmName() end
	return (realm and realm ~= "") and (name .. "-" .. realm) or name
end

local function goUnit(guid, name)
	local u = unitByGuid(guid)
	if not u then return Print((name or "they") .. " isn't in your group: invite them to be guided to them") end
	local x, y, inst = unitWorldPos(u)
	if not x then return Print("the game gives no position for " .. (name or "them") .. " right now (inside a dungeon?)") end
	goTo({ { x = x, y = y, instance = inst, name = name } },
		{ name = name, kind = "unit", what = "group member", saved = { kind = "unit", guid = guid, name = name } })
	if target then target.guid, target.checked = guid, GetTime() end
end

-- a friend outside your group: the middle of the zone they are in
local function goZone(zoneName, who)
	local mapData = HBD().mapData or {}
	for mapID, m in pairs(mapData) do
		if m.name == zoneName and (not Enum or not Enum.UIMapType or m.mapType == Enum.UIMapType.Zone) then
			local x, y, inst = HBD():GetWorldCoordinatesFromZone(0.5, 0.5, mapID)
			if x then
				return goTo({ { x = x, y = y, instance = inst, uiMap = mapID, name = zoneName } },
					{ name = zoneName, kind = "spot", what = (who or "a friend") .. " is somewhere in this zone",
						saved = { kind = "spot", x = x, y = y, instance = inst, uiMap = mapID, name = zoneName } })
			end
		end
	end
	Print(format("can't find %s on the map%s", zoneName or "?", who and (": ask " .. who .. " to join your group to be guided to them") or ""))
end

-- Rerouting from where you are: the walking route is planned again every couple of seconds as you move, and at
-- once when you stray from it; the whole trip (walk, fly, sail...) is looked at again every so often.
local reroute = { at = 0, trip = 0, x = 0, y = 0, EVERY = 2, OFF = 6, TRIP_EVERY = 10 }

-- Riding a boat, zeppelin or other transport: the game has no check for it, but it shows in the numbers. The
-- position changes fast while the character's own speed does not (it stands on the deck). True while that holds;
-- ends when the position is still, or the character's speed accounts for the movement again.
function reroute.update(px, py)
	local b = reroute.b
	if not b then b = {}; reroute.b = b end
	if not px then return b.on end
	local now = GetTime()
	if not b.t then b.x, b.y, b.t = px, py, now; return b.on end
	if now - b.t < 0.25 then return b.on end
	local d, dt = dist(px, py, b.x, b.y), now - b.t
	b.x, b.y, b.t = px, py, now
	local measured = d / dt
	local own = GetUnitSpeed("player") or 0
	if d > 60 then
		b.since, b.on = nil, false -- a jump (teleport, loading), not a ride
	elseif measured > 3 and own < measured * 0.5 and not UnitOnTaxi("player") and not (IsFalling and IsFalling()) then
		b.since = b.since or now
		if now - b.since > 1 then b.on = true end
	elseif measured < 1.5 or own >= measured * 0.8 then
		b.since, b.on = nil, false
	end
	return b.on
end


------------------------------------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------------------------------------


-- While guiding: what BV is doing (BV.lua keeps it up to date), the one line the window and the arrow show.
local function noRouteText()
	if not target then return end
	return ns.bvText or "waiting for the route..."
end

-- The window. Its own block, so its many locals end with it (Lua allows 200 per file); f and allEntries are
-- used further on.
local f, allEntries
do
local ROW_H = 30
f = CreateFrame("Frame", "PathyFrame", UIParent, "BackdropTemplate")
f:SetSize(360, 520)
f:SetPoint("CENTER")
f:SetFrameStrata("MEDIUM")
f:SetToplevel(true) -- comes to the front when clicked, behind the game's own windows otherwise
f:SetMovable(true)
f:EnableMouse(true)
f:SetClampedToScreen(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, rel, x, y = self:GetPoint()
	PathyDB.pos = { point, rel, x, y }
end)
f:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
f:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
-- everything inside the window hangs from this: it fills the window and carries the UI scale (the window itself keeps its size)
local content = CreateFrame("Frame", nil, f)
content:SetPoint("TOPLEFT")
content:SetPoint("BOTTOMRIGHT")
-- the look the settings and saved size give it (background opacity, size)
function f.ApplyLook()
	local bg, edge = cfg("windowColour"), cfg("windowBorder")
	f:SetBackdropColor(bg[1], bg[2], bg[3], cfg("windowAlpha"))
	f:SetBackdropBorderColor(edge[1], edge[2], edge[3], cfg("windowAlpha"))
	content:SetScale(cfg("uiScale"))
	if f.Relayout then f.Relayout() end
	local size = PathyDB and PathyDB.size
	if size and size[1] and size[2] then f:SetSize(size[1], size[2]) end
end
-- resizing: a grip in the bottom right corner
f:SetResizable(true)
if f.SetResizeBounds then f:SetResizeBounds(100, 200, 800, 1000)
elseif f.SetMinResize then f:SetMinResize(100, 200) end
local grip = CreateFrame("Button", nil, f)
grip:SetSize(16, 16)
grip:SetPoint("BOTTOMRIGHT", -3, 3)
grip:SetFrameLevel(f:GetFrameLevel() + 10)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function()
	f:StopMovingOrSizing()
	PathyDB.size = { floor(f:GetWidth() + 0.5), floor(f:GetHeight() + 0.5) }
	local point, _, rel, x, y = f:GetPoint()
	PathyDB.pos = { point, rel, x, y }
end)
f:Hide()
-- (not in UISpecialFrames: Escape leaves the window open; the X, /pathy and the minimap button close it)

local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 14, -12)
title:SetText("Pathy")

local close = CreateFrame("Button", nil, content, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

local status = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", 14, -36)
status:SetPoint("RIGHT", -14, 0)
status:SetJustifyH("LEFT")

-- Icons: Questie's own for quests and townsfolk, the game's minimap tracking icons, class and profession icons.
local QUESTIE_ICONS = "Interface\\AddOns\\Questie\\Icons\\"
local ICONS = {
	turnin = QUESTIE_ICONS .. "complete", giver = QUESTIE_ICONS .. "available", progress = QUESTIE_ICONS .. "incomplete",
	group = "Interface\\Icons\\INV_Misc_GroupNeedMore", friend = "Interface\\FriendsFrame\\UI-Toast-FriendOnlineIcon",
	pin = "Interface\\Icons\\INV_Misc_Map_01", target = "Interface\\Icons\\Ability_Hunter_SniperShot",
	settings = "Interface\\Icons\\INV_Misc_Gear_01", stop = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
	npc = "Interface\\Icons\\INV_Misc_GroupNeedMore",
	["Class Trainers"] = "Interface\\Minimap\\tracking\\class",
	["Profession Trainers"] = "Interface\\Minimap\\tracking\\profession",
	["Vendors"] = "Interface\\Minimap\\tracking\\food",
	["Flight Master"] = "Interface\\Minimap\\tracking\\flightmaster",
	["Meeting Stones"] = QUESTIE_ICONS .. "mstone",
	["Class Trainer"] = "Interface\\Minimap\\tracking\\class",
	["Stable Master"] = "Interface\\Minimap\\tracking\\stablemaster",
	["Spirit Healer"] = "Interface\\raidframe\\raid-icon-rez",
	["Weapon Master"] = QUESTIE_ICONS .. "weaponmaster",
	["Mailbox"] = "Interface\\Minimap\\tracking\\mailbox",
	["Ammo"] = "Interface\\Minimap\\tracking\\ammunition",
	["Bags"] = 133634, ["Potions"] = 134831, ["Trade Goods"] = 132912, ["Drink"] = 134712, ["Food"] = 133964,
	["Pet Food"] = 132165,
	["Portal Trainer"] = "Interface\\Minimap\\vehicle-alliancemageportal",
	["Reagents"] = "Interface\\Minimap\\tracking\\reagents",
	["Poisons"] = "Interface\\Minimap\\tracking\\poisons",
	["Repair"] = "Interface\\Minimap\\tracking\\repair",
	["Innkeeper"] = "Interface\\Minimap\\tracking\\innkeeper",
	["Auctioneer"] = "Interface\\Minimap\\tracking\\auctioneer",
	["Banker"] = "Interface\\Minimap\\tracking\\banker",
	["Battlemaster"] = "Interface\\Minimap\\tracking\\battlemaster",
	["Barber"] = QUESTIE_ICONS .. "Barbershop",
	["Transmogrifier"] = "Interface\\Minimap\\tracking\\transmogrifier",
}
local PROFESSION_ICONS = {
	FIRST_AID = "Interface\\Icons\\spell_holy_sealofsacrifice", BLACKSMITHING = "Interface\\Icons\\trade_blacksmithing",
	LEATHERWORKING = "Interface\\Icons\\trade_leatherworking", ALCHEMY = "Interface\\Icons\\trade_alchemy",
	HERBALISM = "Interface\\Icons\\trade_herbalism", COOKING = "Interface\\Icons\\inv_misc_food_15",
	MINING = "Interface\\Icons\\trade_mining", TAILORING = "Interface\\Icons\\trade_tailoring",
	ENGINEERING = "Interface\\Icons\\trade_engineering", ENCHANTING = "Interface\\Icons\\trade_engraving",
	FISHING = "Interface\\Icons\\trade_fishing", SKINNING = "Interface\\Icons\\inv_misc_pelt_wolf_01",
	JEWELCRAFTING = "Interface\\Icons\\inv_misc_gem_01", ARCHAEOLOGY = "Interface\\Icons\\trade_archaeology",
	INSCRIPTION = "Interface\\Icons\\inv_inscription_tradeskill01", RIDING = "Interface\\Icons\\spell_nature_swiftness",
}
local VENDOR_TYPES = { Food = true, Drink = true, Bags = true, Potions = true, ["Trade Goods"] = true, Reagents = true,
	Poisons = true, Ammo = true, ["Pet Food"] = true, Repair = true }
local function iconFor(key) return ICONS[key] or ICONS.npc end

-- one row of buttons under the title, each with its icon
local toolButtons = {}
local function toolButton(text, icon, x, fn)
	local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	b:SetSize(80, 24)
	b:SetPoint("TOPLEFT", x, -54)
	b:SetText("     " .. text)
	b:SetScript("OnClick", fn)
	local t = b:CreateTexture(nil, "OVERLAY")
	t:SetSize(14, 14)
	t:SetPoint("LEFT", 7, 0)
	t:SetTexture(icon)
	toolButtons[#toolButtons + 1] = b
	return b
end
toolButton("Map pin", ICONS.pin, 12, function() goPin() end)
toolButton("Target", ICONS.target, 95, function() goTargetNpc() end)
toolButton("Settings", ICONS.settings, 178, function() PathySettings:SetShown(not PathySettings:IsShown()) end)
toolButton("Stop", ICONS.stop, 261, function() if target then stop("stopped") else Print("not guiding anywhere") end end)

-- the search box: filters every section, by its heading too
local search = CreateFrame("EditBox", "PathySearchBox", content, "InputBoxTemplate")
search:SetHeight(20)
search:SetPoint("TOPLEFT", 20, -86)
search:SetPoint("TOPRIGHT", -20, -86)
search:SetAutoFocus(false)
search:SetMaxLetters(60)
search.hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisable")
search.hint:SetPoint("LEFT", 2, 0)
search.hint:SetText("Search quests, NPCs and types...")
search.clear = CreateFrame("Button", nil, search, "UIPanelCloseButton")
search.clear:SetSize(20, 20)
search.clear:SetPoint("RIGHT", 2, 0)
search.clear:Hide()

local scroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 10, -140)
scroll:SetPoint("BOTTOMRIGHT", -30, 22)
local child = CreateFrame("Frame", nil, scroll)
child:SetSize(316, 10)
scroll:SetScrollChild(child)
scroll:SetScript("OnSizeChanged", function(_, w) if w and w > 0 then child:SetWidth(w) end end)

-- the tabs: Quests, Places, NPCs (a search looks in all of them)
local TABS = { { "quests", "Quests" }, { "places", "Places" }, { "npcs", "NPCs" } }
local tabButtons = {}
local function currentTab()
	local t = PathyDB and PathyDB.tab
	for _, tab in ipairs(TABS) do if tab[1] == t then return t end end
	return "quests"
end
for i, tab in ipairs(TABS) do
	local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	b:SetHeight(22)
	b:SetText(tab[2])
	b.key = tab[1]
	-- three equal buttons across the window
	local gap = 4
	b:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (i - 1) * 2, -112)
	b:SetScript("OnClick", function()
		PathyDB.tab = tab[1]
		scroll:SetVerticalScroll(0)
		f.Refresh()
	end)
	tabButtons[i] = b
end
local function layoutTabs()
	local total = f:GetWidth() / cfg("uiScale") - 24
	-- the toolbar buttons share the width too, so the window can be made as narrow as you like
	local tw = (total - 3 * 4) / math.max(1, #toolButtons)
	for i, b in ipairs(toolButtons) do
		b:SetWidth(math.max(8, tw))
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (i - 1) * (tw + 4), -54)
		b:SetShown(tw >= 20)
	end
	local w = (total - 8) / 3
	for i, b in ipairs(tabButtons) do
		b:SetWidth(w)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (i - 1) * (w + 4), -112)
	end
end
f:HookScript("OnSizeChanged", layoutTabs)
f.Relayout = layoutTabs
layoutTabs()

local rows = {}
local function row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, child)
	r:SetSize(316, ROW_H)
	r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(18, 18)
	r.top = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	r.top:SetJustifyH("LEFT")
	r.top:SetWordWrap(false)
	r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.sub:SetJustifyH("LEFT")
	r.sub:SetWordWrap(false)
	r:SetScript("OnClick", function(self)
		if self.node then
			-- a heading: open or close it
			PathyDB.collapsed = PathyDB.collapsed or {}
			PathyDB.collapsed[self.path] = not self.collapsed
			f.Refresh()
		elseif self.entry then
			self.entry.action()
		end
	end)
	rows[i] = r
	return r
end

-- lays a row out at depth `depth` (indented), with its icon
local function place(r, y, depth, icon)
	local x = 2 + depth * 14
	r:ClearAllPoints()
	r:SetPoint("TOPLEFT", 0, -y)
	r:SetPoint("TOPRIGHT", 0, -y)
	r.icon:ClearAllPoints()
	r.icon:SetPoint("TOPLEFT", x, -5)
	if icon then r.icon:SetTexture(icon); r.icon:Show() else r.icon:Hide() end
	local tx = x + (icon and 22 or 0)
	r.top:ClearAllPoints()
	r.top:SetPoint("TOPLEFT", tx, -2)
	r.top:SetPoint("RIGHT", -4, 0)
	r.sub:ClearAllPoints()
	r.sub:SetPoint("TOPLEFT", tx, -16)
	r.sub:SetPoint("RIGHT", -4, 0)
	r:Show()
end

local function yards(d) return d and format("%d yd", floor(d + 0.5)) or "" end

------------------------------------------------------------------------------------------------------------
-- Townsfolk (bankers, innkeepers, vendors, class and profession trainers, flight masters...) from Questie's
-- lists. Where each of them stands is worked out once and kept; every type is always listed, nearest first.
------------------------------------------------------------------------------------------------------------

local NPC_PER_TYPE = 10 -- at most this many of each type, nearest first
local OBJECT_TYPES = { ["Mailbox"] = true, ["Meeting Stones"] = true }
local CLASS_NAMES = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
	SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid", DEATHKNIGHT = "Death Knight",
	MONK = "Monk", DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker" }
local townCache -- { groups = { { title, icon, types = { { name, icon, spots } } } }, plain = { { name, icon, spots } } }

local function titleCase(key) return (key:sub(1, 1) .. key:sub(2):lower():gsub("_(%a)", function(c) return " " .. c:upper() end)) end

local function spotsFor(ids, object)
	local DB = questie("QuestieDB")
	local C = questie("QuestieCorrections")
	local blacklist = C and C.questNPCBlacklist or {}
	local mine = ({ Alliance = "A", Horde = "H" })[UnitFactionGroup("player")]
	local query = object and DB.QueryObjectSingle or DB.QueryNPCSingle
	local list = {}
	for _, id in ipairs(ids) do
		local friendly = not object and query(id, "friendlyToFaction")
		if not blacklist[id] and (not friendly or friendly == "AH" or friendly == mine) then
			local name = query(id, "name")
			local title = not object and query(id, "subName") or nil -- "<Skinning Trainer>"
			for _, sp in ipairs(spawnSpots(query, id, {})) do
				list[#list + 1] = { id = id, name = name or "?", title = title, x = sp.x, y = sp.y, instance = sp.instance, uiMap = sp.uiMap, object = object }
			end
		end
	end
	return list
end

local function townsfolk()
	-- Questie builds its townsfolk lists a while after login: until the trainers are in, look again every few seconds
	if townCache and (townCache.complete or GetTime() < townCache.retryAt) then return townCache end
	local DB = questie("QuestieDB")
	local T = questie("Townsfolk")
	if not DB or not DB.QueryNPCSingle or not T then return { groups = {}, plain = {} } end
	local char = Questie and Questie.db and Questie.db.char
	local groups, plain = {}, {}

	-- class trainers: one sub-section per class
	local classes = { title = "Class Trainers", icon = ICONS["Class Trainers"], types = {} }
	for class, lists in pairs(T.classSpecificTownsfolk or {}) do
		local ids = type(lists) == "table" and lists["Class Trainer"]
		if ids and #ids > 0 then
			local name = CLASS_NAMES[class] or titleCase(class)
			local icon = "Interface\\Icons\\ClassIcon_" .. name:gsub(" ", "")
			-- hunter and pet trainers share one list; each one's <title> tells them apart
			local spots = spotsFor(ids)
			if #spots > 0 then
				classes.types[#classes.types + 1] = { name = name, icon = icon, spots = spots }
			end
		end
	end
	if #classes.types > 0 then groups[#groups + 1] = classes end

	-- profession trainers: one sub-section per profession
	local profs = { title = "Profession Trainers", icon = ICONS["Profession Trainers"], types = {} }
	local P = questie("QuestieProfessions")
	for key, prof in pairs(P and P.professionKeys or {}) do
		local ids = T.professionTrainers and T.professionTrainers[prof]
		if type(key) == "string" and ids and #ids > 0 then
			local spots = spotsFor(ids)
			if #spots > 0 then
				profs.types[#profs.types + 1] = { name = titleCase(key), icon = PROFESSION_ICONS[key] or ICONS["Profession Trainers"], spots = spots }
			end
		end
	end
	if #profs.types > 0 then groups[#groups + 1] = profs end

	-- everything else: vendors grouped, the rest one section each
	local vendors = { title = "Vendors", icon = ICONS.Vendors, types = {} }
	local seen = { ["Class Trainer"] = true }
	for _, src in ipairs({ T.townsfolk, char and char.townsfolk, char and char.vendorList }) do
		for name, ids in pairs(src or {}) do
			if type(name) == "string" and type(ids) == "table" and #ids > 0 and not seen[name] then
				seen[name] = true
				local spots = spotsFor(ids, OBJECT_TYPES[name])
				if #spots > 0 then
					local t = { name = name, icon = iconFor(name), spots = spots }
					if VENDOR_TYPES[name] then vendors.types[#vendors.types + 1] = t else plain[#plain + 1] = t end
				end
			end
		end
	end
	if #vendors.types > 0 then groups[#groups + 1] = vendors end

	local byName = function(a, b) return a.name < b.name end
	for _, g in ipairs(groups) do table.sort(g.types, byName) end
	table.sort(plain, byName)
	townCache = { groups = groups, plain = plain, complete = #classes.types > 0 and #profs.types > 0, retryAt = GetTime() + 5 }
	return townCache
end

-- Walk to one spot (an NPC's spawn, a mailbox).
local function goSpot(sp, typeName)
	local spot = { x = sp.x, y = sp.y, instance = sp.instance, uiMap = sp.uiMap, name = sp.name }
	if sp.object then
		goTo({ spot }, { name = sp.name, kind = "spot", what = typeName,
			saved = { kind = "spot", x = sp.x, y = sp.y, instance = sp.instance, uiMap = sp.uiMap, name = sp.name } })
	else
		goTo({ spot }, { name = sp.name, kind = "npc", what = typeName, npcId = sp.id,
			saved = { kind = "npc", npcId = sp.id, name = sp.name } })
	end
end

-- a type's entries: nearest first (this continent), then the rest
local function typeEntries(t, px, py, instance)
	local near = {}
	for _, sp in ipairs(t.spots) do
		near[#near + 1] = { sp = sp, d = (px and sp.instance == instance) and dist(px, py, sp.x, sp.y) or nil }
	end
	table.sort(near, function(a, b)
		if (a.d ~= nil) ~= (b.d ~= nil) then return a.d ~= nil end
		if a.d then return a.d < b.d end
		return a.sp.name < b.sp.name
	end)
	local list, used = {}, {}
	for _, n in ipairs(near) do
		if #list >= NPC_PER_TYPE then break end
		local sp = n.sp
		if not used[sp.id] then -- each NPC once, at its nearest spot
			used[sp.id] = true
			list[#list + 1] = { top = sp.name .. (sp.title and sp.title ~= "" and (" |cff999999<" .. sp.title .. ">|r") or ""), sub = n.d and yards(n.d) or "other continent", icon = t.icon,
				action = function() goSpot(sp, t.name) end, key = (sp.object and "spot:" or "npc:") .. sp.id }
		end
	end
	return list
end

-- the continents (uiMap, fallback name) and their cities
local PLACES = {
	{ 1415, "Eastern Kingdoms", cities = { { 1453, "Stormwind City" }, { 1455, "Ironforge" }, { 1458, "Undercity" } } },
	{ 1414, "Kalimdor", cities = { { 1454, "Orgrimmar" }, { 1456, "Thunder Bluff" }, { 1457, "Darnassus" } } },
}

-- The lists shown in the window: nodes { title, icon, list = entries, children = nodes, closed (by default),
-- empty }; entries { top, sub, icon, action, key (what is being guided to) }.
local function buildLists()
	local px, py, instance = HBD():GetPlayerWorldPosition()
	local nodes = {}
	local turnin, progress = {}, {}
	for _, q in ipairs(questLog()) do
		local spots = questSpots(q.id, "finishedBy")
		local near, nearD
		for _, s in ipairs(spots) do
			local d = px and s.instance == instance and dist(px, py, s.x, s.y)
			if d and (not nearD or d < nearD) then near, nearD = s, d end
		end
		local who = near and near.name or spots[1] and spots[1].name or "unknown turn-in"
		local id = q.id
		local e
		if q.complete then
			e = { top = coloredQuest(id, q.title or questName(id) or ("quest " .. id)), icon = ICONS.turnin,
				sub = format("Turn in to %s  %s", who, nearD and yards(nearD) or "(other continent)"),
				action = function() go(id, "turnin") end, key = "turnin:" .. id }
		else
			-- where the objective is: the quest's area, else the nearest group of objective spots
			local goal, goalD, what = nil, nil, "Objective"
			for _, a in ipairs(objectiveAreas(id)) do
				local d = px and a.instance == instance and dist(px, py, a.x, a.y)
				if d and (not goalD or d < goalD) then goal, goalD = a, d end
			end
			if not goal then
				goal, what = questAreaCentre(id), "Quest area"
				if goal and px and goal.instance == instance then goalD = dist(px, py, goal.x, goal.y) end
			end
			local sub = goal and format("%s%s  %s", what, goal.name and goal.name ~= "the quest area" and (": " .. goal.name) or "",
				goalD and yards(goalD) or "(other continent)") or format("Turn in to %s  %s", who, nearD and yards(nearD) or "(other continent)")
			e = { top = coloredQuest(id, q.title or questName(id) or ("quest " .. id)), icon = ICONS.progress, sub = sub,
				action = function() goObjective(id) end, key = "objective:" .. id }
		end
		local list = q.complete and turnin or progress
		list[#list + 1] = e
	end
	nodes[#nodes + 1] = { title = "Ready to turn in", icon = ICONS.turnin, list = turnin }
	if px then
		local avail = {}
		for _, a in ipairs(availableQuests(px, py, instance)) do
			local icon = { x = a.x, y = a.y, instance = a.instance, uiMap = a.uiMap, name = a.name }
			local id = a.id
			avail[#avail + 1] = { top = coloredQuest(a.id, a.title), sub = format("Start with %s  %s%s", a.name or "?", yards(a.d), a.low and "  |cff999999(low level)|r" or ""), icon = ICONS.giver,
				action = function() go(id, "giver", icon) end, key = "giver:" .. id }
		end
		nodes[#nodes + 1] = { title = "Quest givers nearby", icon = ICONS.giver, list = avail,
			empty = "Questie shows no available quests on this continent" }
	end
	nodes[#nodes + 1] = { title = "In progress (go to the objective)", icon = ICONS.progress, list = progress }

	-- your group, and friends online
	local group, inGroup = {}, {}
	local count = IsInRaid() and GetNumGroupMembers() or (GetNumSubgroupMembers and GetNumSubgroupMembers() or 0)
	for i = 1, count do
		local u = IsInRaid() and ("raid" .. i) or ("party" .. i)
		local guid, name = UnitGUID(u), UnitName(u)
		if guid and name and not UnitIsUnit(u, "player") then
			local full = fullName(u) or name
			inGroup[name], inGroup[full] = true, true
			local x, y, inst = unitWorldPos(u)
			local d = x and px and inst == instance and dist(px, py, x, y)
			local _, class = UnitClass(u)
			local cname = CLASS_NAMES[class or ""]
			group[#group + 1] = { top = full, icon = cname and ("Interface\\Icons\\ClassIcon_" .. cname:gsub(" ", "")) or ICONS.group,
				sub = (not UnitIsConnected(u) and "offline") or (d and yards(d)) or (x and "other continent") or "no position (in a dungeon?)",
				action = function() goUnit(guid, full) end, key = "unit:" .. guid, d = d or 1e9 }
		end
	end
	table.sort(group, function(a, b) return a.d < b.d end)
	if #group > 0 then nodes[#nodes + 1] = { title = "Group", icon = ICONS.group, list = group } end
	local friends = {}
	if C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetFriendInfoByIndex then
		for i = 1, C_FriendList.GetNumFriends() or 0 do
			local info = C_FriendList.GetFriendInfoByIndex(i)
			if info and info.connected and info.name and not inGroup[info.name] then
				local name, area = info.name, info.area
				friends[#friends + 1] = { top = name, icon = ICONS.friend,
					sub = format("%s%s  (to their zone; invite them for exact)", area or "?", info.level and (", level " .. info.level) or ""),
					action = function() if area then goZone(area, name) end end, key = "friend:" .. name }
			end
		end
	end
	if #friends > 0 then nodes[#nodes + 1] = { title = "Friends online", icon = ICONS.friend, list = friends, closed = true } end

	-- Cities and continents, nested: each continent holds its cities, each city its sub-areas (the maps the game
	-- lists under it). Clicking one guides to the middle of its map; a trip across the sea or by flight is planned
	-- as usual.
	local function placeEntry(mapID, fallback, what)
		local x, y, inst = HBD():GetWorldCoordinatesFromZone(0.5, 0.5, mapID)
		if not x then return end
		local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
		local name = info and info.name or fallback
		local spot = { x = x, y = y, instance = inst, uiMap = mapID, name = name }
		local d = px and inst == instance and dist(px, py, x, y)
		return { top = name, icon = ICONS.pin, d = d or 1e9, key = "place:" .. mapID,
			sub = d and yards(d) or (what == "continent" and "continent" or "other continent"),
			action = function()
				goTo({ spot }, { name = name, kind = "spot", what = what,
					saved = { kind = "spot", x = x, y = y, instance = inst, uiMap = mapID, name = name } })
			end }, name
	end
	local byDistance = function(a, b) if a.d ~= b.d then return a.d < b.d end return a.top < b.top end
	local known = {}
	for _, c in ipairs(PLACES) do
		known[c[1]] = true
		for _, city in ipairs(c.cities) do known[city[1]] = true end
	end
	local continents = {}
	for _, c in ipairs(PLACES) do
		local centry, cname = placeEntry(c[1], c[2], "continent")
		if centry then
			local cities = {}
			for _, city in ipairs(c.cities) do
				local entry, name = placeEntry(city[1], city[2], "city")
				if entry then
					-- the map's own sub-areas (districts, quarters), nearest first
					local subs = {}
					for id, m in pairs(HBD().mapData or {}) do
						if m.parent == city[1] and not known[id] then
							local e = placeEntry(id, m.name or "?", "area")
							if e then subs[#subs + 1] = e end
						end
					end
					table.sort(subs, byDistance)
					local list = { entry }
					for _, e in ipairs(subs) do list[#list + 1] = e end
					cities[#cities + 1] = { title = name, icon = ICONS.pin, list = list, closed = true, d = entry.d }
				end
			end
			table.sort(cities, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.title < b.title end)
			continents[#continents + 1] = { title = cname, icon = ICONS.pin, list = { centry }, children = cities, closed = true, d = centry.d }
		end
	end
	table.sort(continents, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.title < b.title end)
	nodes[#nodes + 1] = { title = "Cities & continents", icon = ICONS.pin, children = continents, closed = true }

	-- NPCs by type: every type, always
	local town = townsfolk()
	local npcs = {}
	for _, g in ipairs(town.groups) do
		local kids = {}
		for _, t in ipairs(g.types) do
			kids[#kids + 1] = { title = t.name, icon = t.icon, list = typeEntries(t, px, py, instance), closed = true }
		end
		npcs[#npcs + 1] = { title = g.title, icon = g.icon, children = kids, closed = true }
	end
	for _, t in ipairs(town.plain) do
		npcs[#npcs + 1] = { title = t.name, icon = t.icon, list = typeEntries(t, px, py, instance), closed = true }
	end
	return nodes, npcs
end

-- what is being guided to, in the entries' terms
local function targetKey()
	if not target then return end
	if target.kind == "giver" or target.kind == "turnin" or target.kind == "objective" then return target.kind .. ":" .. tostring(target.questId) end
	local saved = PathyDB.target
	if saved and saved.kind == "npc" then return "npc:" .. tostring(saved.npcId) end
	if saved and saved.kind == "spot" then return "spot" end
	if saved and saved.kind == "unit" then return "unit:" .. tostring(saved.guid) end
end

local function plain(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local function hasAll(text, words)
	text = text:lower()
	for word in words:gmatch("%S+") do
		if not text:find(word, 1, true) then return false end
	end
	return true
end

-- How many entries of a node are shown (with a search: the ones that match, or all of them when a heading above
-- or the node's own heading matches).
local function countShown(node, words, all)
	all = all or (words and hasAll(node.title, words))
	local n = 0
	for _, e in ipairs(node.list or {}) do
		if not words or all or hasAll(plain(e.top .. " " .. e.sub), words) then n = n + 1 end
	end
	for _, c in ipairs(node.children or {}) do n = n + countShown(c, words, all) end
	return n
end

function f.Refresh()
	if not f:IsShown() then return end
	if target then
		local why = noRouteText()
		status:SetText("|cff66ff66Guiding to|r " .. target.name .. (target.quest ~= "" and ("  |cff999999(" .. target.quest .. ")|r") or "")
			.. (why and ("\n|cffff9933" .. why .. "|r") or ""))
	else
		status:SetText("|cff999999Click a quest or an NPC to walk there.|r")
	end
	local ok, nodes, npcs = pcall(buildLists)
	if not ok then
		status:SetText("|cffff6666Questie is still loading; try again in a moment.|r")
		nodes, npcs = {}, {}
	end
	local text = strtrim(search:GetText() or ""):lower()
	local words = text ~= "" and text or nil
	local collapsed = PathyDB.collapsed or {}
	local active = targetKey()
	local i, y = 0, 0

	local function heading(node, depth, path, count, isClosed)
		i = i + 1
		local r = row(i)
		r.entry, r.node, r.path, r.collapsed = nil, node, path, isClosed
		r:EnableMouse(not words)
		r.top:SetText(format("|cffffd100%s %s|r |cff888888(%d)|r", isClosed and "+" or "-", node.title, count))
		r.sub:SetText(count == 0 and node.empty and ("|cff888888" .. node.empty .. "|r") or "")
		place(r, y, depth, node.icon)
		y = y + ROW_H
	end

	local function entryRow(e, depth)
		i = i + 1
		local r = row(i)
		r.entry, r.node = e, nil
		r:EnableMouse(true)
		local on = active and e.key == active
		r.top:SetText((on and "|cff66ff66> |r" or "") .. "|cffffffff" .. e.top .. "|r")
		r.sub:SetText(e.sub)
		place(r, y, depth, e.icon)
		y = y + ROW_H
	end

	local function emit(node, depth, parentPath, all)
		local path = parentPath and (parentPath .. "/" .. node.title) or node.title
		all = all or (words and hasAll(node.title, words))
		local count = countShown(node, words, all)
		if words and count == 0 and not all then return end
		if not words and count == 0 and not node.empty and not node.children then return end
		local isClosed = collapsed[path]
		if isClosed == nil then isClosed = node.closed or false end
		if words then isClosed = false end -- searching: everything that matches is open
		heading(node, depth, path, count, isClosed)
		if isClosed then return end
		for _, e in ipairs(node.list or {}) do
			if not words or all or hasAll(plain(e.top .. " " .. e.sub), words) then entryRow(e, depth + 1) end
		end
		for _, c in ipairs(node.children or {}) do emit(c, depth + 1, path, all) end
	end

	-- one tab at a time; a search looks in all of them
	local tab = not words and currentTab() or nil
	for _, b in ipairs(tabButtons) do
		if b.key == (tab or currentTab()) and not words then b:LockHighlight() else b:UnlockHighlight() end
	end
	local PLACE_TITLES = { ["Group"] = true, ["Friends online"] = true, ["Cities & continents"] = true }
	for _, node in ipairs(nodes) do
		if not tab or (PLACE_TITLES[node.title] and "places" or "quests") == tab then emit(node, 0) end
	end
	if #npcs > 0 and (not tab or tab == "npcs") then
		local shownAny = not words
		if words then for _, n in ipairs(npcs) do if countShown(n, words) > 0 then shownAny = true break end end end
		if shownAny then
			i = i + 1
			local r = row(i)
			r.entry, r.node = nil, nil
			r:EnableMouse(false)
			r.top:SetText(tab and "|cff888888Nearest first; click a heading to open it|r" or "|cff66ccffNPCs|r")
			r.sub:SetText(tab and "" or "|cff888888nearest first; click a heading to open it|r")
			place(r, y, 0, nil)
			y = y + ROW_H
			for _, node in ipairs(npcs) do emit(node, 0) end
		end
	end
	if i == 0 and words then
		i = 1
		local r = row(1)
		r.entry, r.node = nil, nil
		r:EnableMouse(false)
		r.top:SetText("|cff888888Nothing matches \"" .. text .. "\"|r")
		r.sub:SetText("")
		place(r, 0, 0, nil)
		y = ROW_H
	end
	for j = i + 1, #rows do rows[j]:Hide() end
	child:SetHeight(math.max(10, y))
end

-- for /pathy <name>: every entry with its heading words, in the window's order
function allEntries()
	local nodes, npcs = buildLists()
	local out = {}
	local function walk(node, words)
		words = words .. " " .. node.title
		for _, e in ipairs(node.list or {}) do out[#out + 1] = { e = e, text = plain(e.top .. " " .. e.sub .. words):lower() } end
		for _, c in ipairs(node.children or {}) do walk(c, words) end
	end
	for _, n in ipairs(nodes) do walk(n, "") end
	for _, n in ipairs(npcs) do walk(n, "") end
	return out
end

search:SetScript("OnTextChanged", function(self)
	local has = (self:GetText() or "") ~= ""
	self.hint:SetShown(not has)
	self.clear:SetShown(has)
	f.Refresh()
end)
search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
search.clear:SetScript("OnClick", function() search:SetText(""); search:ClearFocus() end)

-- Open or closed is kept between reloads and logins (it comes back at PLAYER_LOGIN)
f:SetScript("OnHide", function() if PathyDB then PathyDB.shown = false end end)
f:SetScript("OnShow", function()
	if PathyDB then PathyDB.shown = true end
	if C_FriendList and C_FriendList.ShowFriends then C_FriendList.ShowFriends() end
	f.Refresh()
end)
end -- the window

------------------------------------------------------------------------------------------------------------
-- Pathy's 3D arrow, and the route it follows.
--
-- The arrow needs no camera: it is always drawn as seen from the game's default tilt, turned by which way the
-- character faces (as BV's own guide is). What it needs is the route (BV's, put here by BV.lua), where you are on
-- it, and which way to point.
------------------------------------------------------------------------------------------------------------

local sin, cos, tan, abs, max, min, rad, pi = math.sin, math.cos, math.tan, math.abs, math.max, math.min, math.rad, math.pi
local huge = math.huge

local LOOKAHEAD = 40 -- yards: the arrow points at the route this far ahead (a setting; this is the fallback)
local CLIMB = 2.5    -- yards the route ahead rises or falls before it says "up" / "down"
local TURN_RATE = 6  -- how fast the arrow catches up with the direction (higher = snappier)
local TURN_MAX = 0.34 -- the arrow never looks past a hairpin: cos of the turn (110 degrees) a leg may make against the way you start out

-- The camera's axes, for drawing the arrow (the arrow's own view: setCamera below). World axes: E = east
-- (= -x in HereBeDragons' coordinates), N = north (= y), U = up (= z).
local fx, fy, fz, rx, ry, ux, uy, uz, Cx, Cy, Cz

local function setCamera(yaw, pitch, F1, F2, F3, d)
	local cyw, syw, cp, sp = cos(yaw), sin(yaw), cos(pitch), sin(pitch)
	fx, fy, fz = -syw * cp, cyw * cp, -sp
	rx, ry = cyw, syw
	ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
	Cx, Cy, Cz = F1 - d * fx, F2 - d * fy, F3 - d * fz
end

------------------------------------------------------------------------------------------------------------
-- The 3D arrow: a thick arrow, in the HUD's medallion (HUD.lua) or at a fixed spot on the screen (66% of the way
-- up by default; move it in the settings), pointing along the route from your feet.
------------------------------------------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ARROW_PX = 90      -- pixels nose to tail at size 1
local ARROW_TILT = 20     -- degrees: the camera tilt the arrow is always drawn as seen from (the game's default)
local ARROW_DIST = 4     -- the arrow's own viewing distance, in arrow half-lengths (less = more perspective)
local UL, LL, UR, LR = UPPER_LEFT_VERTEX or 1, LOWER_LEFT_VERTEX or 2, UPPER_RIGHT_VERTEX or 3, LOWER_RIGHT_VERTEX or 4
-- outline (x right, y forward, -1..1 tail to nose), counter-clockwise seen from above; thickness
local OUTLINE = { { -0.16, -1.0 }, { 0.16, -1.0 }, { 0.16, 0.05 }, { 0.46, 0.05 }, { 0, 1.0 }, { -0.46, 0.05 }, { -0.16, 0.05 } }
local THICK = 0.2
local TOP_FACES = { { 1, 2, 3, 7 }, { 6, 4, 5, 5 } } -- the shaft and the head (a triangle: one corner twice)
local LIGHT = { -0.35, 0.75, -0.56 } -- towards the light, in the camera's axes (right, up, into the screen)

local arrow = CreateFrame("Frame", "PathyArrow", UIParent)
arrow:SetAllPoints()
arrow:SetFrameStrata("LOW")
arrow:SetFrameLevel(60) -- above the HUD (HUD.lua), in whose medallion it is drawn
arrow:Hide()
arrow.climb = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
arrow.climb:SetPoint("CENTER")
arrow.dist = arrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
arrow.dist:SetPoint("TOP", arrow.climb, "BOTTOM", 0, -1)

local quads = {}
local function quad(i)
	local t = quads[i]
	if not t then
		t = arrow:CreateTexture(nil, "ARTWORK")
		t:SetTexture(WHITE)
		if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
		quads[i] = t
	end
	return t
end

-- Stretches texture t over the screen quad a-b-c-d (corners in order around it, UIParent units from the
-- bottom left): its box spans them, and each vertex moves from the box's corner onto its corner.
local function drawQuad(t, a, b, c, d, ox, oy)
	ox, oy = ox or 0, oy or 0
	local a1, a2, b1, b2, c1, c2, d1, d2 = a[1] + ox, a[2] + oy, b[1] + ox, b[2] + oy, c[1] + ox, c[2] + oy, d[1] + ox, d[2] + oy
	local minX, maxX = min(a1, b1, c1, d1), max(a1, b1, c1, d1)
	local minY, maxY = min(a2, b2, c2, d2), max(a2, b2, c2, d2)
	if maxX - minX < 0.5 then maxX = minX + 0.5 end
	if maxY - minY < 0.5 then maxY = minY + 0.5 end
	t:ClearAllPoints()
	t:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", minX, maxY)
	t:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", maxX, minY)
	t:SetVertexOffset(UL, a1 - minX, a2 - maxY)
	t:SetVertexOffset(UR, b1 - maxX, b2 - maxY)
	t:SetVertexOffset(LR, c1 - maxX, c2 - minY)
	t:SetVertexOffset(LL, d1 - minX, d2 - minY)
	t:Show()
end

local function hideArrowShape()
	for _, t in ipairs(quads) do t:Hide() end
	arrow.climb:SetText("")
	arrow.dist:SetText("")
end

-- green while heading the right way, yellow to the side, red behind you (off: 0 ahead .. pi behind)
local function directionColour(off)
	local t = off / pi
	if t < 0.5 then return 0.25 + 1.5 * t, 1, 0.3 - 0.4 * t end
	t = (t - 0.5) * 2
	return 1, 1 - 0.78 * t, 0.1 + 0.05 * t
end

-- the arrow's spot on the screen (UIParent units from the bottom left)
local function arrowAnchor()
	return cfg("arrowX") * UIParent:GetWidth(), cfg("arrowY") * UIParent:GetHeight()
end
-- (for BV.lua's guide panel, which sits under the arrow)
ns.arrowAnchor = arrowAnchor
ns.arrowRadius = function() return ARROW_PX * cfg("arrowSize") / 2 end

-- Where the arrow is drawn, how big (nose to tail, in pixels) and in what colour: in the medallion of the HUD
-- (HUD.lua), at its size and in its accent colour, while that is shown; else where the player put it. false: the
-- HUD is showing a symbol there (a flight, a lift) and the arrow stays away.
local function arrowSpot()
	local hud = ns.HUD
	if hud and hud.arrowSpot then
		local x, y, size, r, g, b = hud.arrowSpot()
		if x == false then return false end
		if x then return x, y, size, { r, g, b } end
	end
	return cfg("arrowX") * UIParent:GetWidth(), cfg("arrowY") * UIParent:GetHeight()
end

-- Draws the arrow at screen spot (ax, ay), pointing along world direction (dE, dN, dU) as the current camera
-- sees it. sizePx and colour override the settings (the HUD's).
local function renderArrow(ax, ay, dE, dN, dU, sizePx, colour)
	local l = sqrt(dE * dE + dN * dN + dU * dU)
	if l < 1e-6 then return hideArrowShape() end
	local aF1, aF2, aF3 = dE / l, dN / l, dU / l
	-- right: level, to the right of the direction; up: square to both
	local hl = sqrt(aF1 * aF1 + aF2 * aF2)
	local aR1, aR2, aR3 = rx, ry, 0
	if hl > 1e-3 then aR1, aR2 = aF2 / hl, -aF1 / hl end
	local aU1, aU2, aU3 = aR2 * aF3 - aR3 * aF2, aR3 * aF1 - aR1 * aF3, aR1 * aF2 - aR2 * aF1
	local size = sizePx or ARROW_PX * cfg("arrowSize")
	local Fpx = size * ARROW_DIST / 2

	local function camDir(x, y, z) -- a direction of the arrow in the camera's axes (right, up, into the screen)
		local E = x * aR1 + y * aF1 + z * aU1
		local N = x * aR2 + y * aF2 + z * aU2
		local U = x * aR3 + y * aF3 + z * aU3
		return E * rx + N * ry, E * ux + N * uy + U * uz, E * fx + N * fy + U * fz
	end
	local function cam3(x, y, z)
		local cx, cy, cz = camDir(x, y, z)
		return { cx, cy, cz + ARROW_DIST }
	end
	local function screen(c)
		local z = max(0.3, c[3])
		return { ax + Fpx * c[1] / z, ay + Fpx * c[2] / z }
	end

	local n = #OUTLINE
	local top, bot, top2, bot2 = {}, {}, {}, {}
	for k = 1, n do
		top[k] = cam3(OUTLINE[k][1], OUTLINE[k][2], THICK / 2)
		bot[k] = cam3(OUTLINE[k][1], OUTLINE[k][2], -THICK / 2)
		top2[k], bot2[k] = screen(top[k]), screen(bot[k])
	end

	local faces = {}
	local function add(c3, c2, nx, ny, nz, bright)
		local cx, cy, cz = 0, 0, 0
		for i = 1, 4 do cx, cy, cz = cx + c3[i][1], cy + c3[i][2], cz + c3[i][3] end
		cx, cy, cz = cx / 4, cy / 4, cz / 4
		if nx * cx + ny * cy + nz * cz >= 0 then return end -- facing away from the viewer
		local light = max(0, nx * LIGHT[1] + ny * LIGHT[2] + nz * LIGHT[3])
		local shade = bright and (0.6 + 0.4 * light) or (0.35 + 0.5 * light)
		faces[#faces + 1] = { pts = c2, depth = cz, shade = shade }
	end
	for k = 1, n do -- the walls round the edge
		local k2 = k % n + 1
		local dx, dy = OUTLINE[k2][1] - OUTLINE[k][1], OUTLINE[k2][2] - OUTLINE[k][2]
		local ll = sqrt(dx * dx + dy * dy)
		local nx, ny, nz = camDir(dy / ll, -dx / ll, 0)
		add({ top[k], top[k2], bot[k2], bot[k] }, { top2[k], top2[k2], bot2[k2], bot2[k] }, nx, ny, nz, false)
	end
	local tx, ty, tz = camDir(0, 0, 1)
	for _, f in ipairs(TOP_FACES) do -- the top, and the underside (seen with the camera below it)
		local a, b, c, d = f[1], f[2], f[3], f[4]
		add({ top[a], top[b], top[c], top[d] }, { top2[a], top2[b], top2[c], top2[d] }, tx, ty, tz, true)
		add({ bot[d], bot[c], bot[b], bot[a] }, { bot2[d], bot2[c], bot2[b], bot2[a] }, -tx, -ty, -tz, false)
	end
	table.sort(faces, function(a, c) return a.depth > c.depth end) -- far first

	local r, g, b
	if colour then
		r, g, b = colour[1], colour[2], colour[3]
	elseif cfg("arrowDirColour") then
		local fl = sqrt(fx * fx + fy * fy)
		local off = (hl > 1e-3 and fl > 1e-3) and math.acos(max(-1, min(1, (aF1 * fx + aF2 * fy) / (hl * fl)))) or 0
		r, g, b = directionColour(off)
	else
		local c = cfg("arrowColour")
		r, g, b = c[1], c[2], c[3]
	end
	local alpha = colour and 1 or cfg("arrowAlpha")
	-- In the HUD's medallion the arrow's visible middle is put on the medallion's: perspective and the tilt move it
	-- off the arrow's own pivot as it turns
	local ox, oy = 0, 0
	if sizePx and #faces > 0 then
		local x0, x1, y0, y1 = huge, -huge, huge, -huge
		for _, f in ipairs(faces) do
			for i = 1, 4 do
				local q = f.pts[i]
				if q[1] < x0 then x0 = q[1] end
				if q[1] > x1 then x1 = q[1] end
				if q[2] < y0 then y0 = q[2] end
				if q[2] > y1 then y1 = q[2] end
			end
		end
		ox, oy = ax - (x0 + x1) / 2, ay - (y0 + y1) / 2
	end
	for i, f in ipairs(faces) do
		local t = quad(i)
		t:SetDrawLayer("ARTWORK", min(7, -8 + i))
		t:SetVertexColor(r * f.shade, g * f.shade, b * f.shade, alpha)
		drawQuad(t, f.pts[1], f.pts[2], f.pts[3], f.pts[4], ox, oy)
	end
	for i = #faces + 1, #quads do quads[i]:Hide() end

	arrow.climb:ClearAllPoints()
	arrow.climb:SetPoint("TOP", UIParent, "BOTTOMLEFT", cfg("textX") * UIParent:GetWidth(), cfg("textY") * UIParent:GetHeight())
	local tc, ta = cfg("textColour"), cfg("textAlpha")
	arrow.climb:SetTextColor(tc[1], tc[2], tc[3], ta)
	arrow.dist:SetTextColor(tc[1], tc[2], tc[3], ta)
end

-- While unlocked (settings): a box round the arrow to drag it by.
local handle = CreateFrame("Frame", "PathyArrowHandle", UIParent, "BackdropTemplate")
handle:SetSize(120, 100)
handle:SetFrameStrata("HIGH")
handle:SetMovable(true)
handle:EnableMouse(true)
handle:RegisterForDrag("LeftButton")
handle:SetClampedToScreen(true)
handle:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 } })
handle:SetBackdropColor(0.2, 0.5, 1, 0.15)
handle:SetBackdropBorderColor(0.4, 0.7, 1, 0.9)
handle.label = handle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
handle.label:SetPoint("TOP", 0, -4)
handle.label:SetText("Drag the arrow")
handle:Hide()
local onArrowMoved -- set by the settings window, to show the new position
handle:SetScript("OnDragStart", handle.StartMoving)
handle:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local x, y = self:GetCenter()
	local s = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
	PathyDB.arrowX = max(0, min(1, x * s / UIParent:GetWidth()))
	PathyDB.arrowY = max(0, min(1, y * s / UIParent:GetHeight()))
	self:ClearAllPoints()
	self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", arrowAnchor())
	if onArrowMoved then onArrowMoved() end
end)

local function setArrowUnlocked(on)
	if on then
		handle:ClearAllPoints()
		handle:SetPoint("CENTER", UIParent, "BOTTOMLEFT", arrowAnchor())
		handle:Show()
	else
		handle:Hide()
	end
end

------------------------------------------------------------------------------------------------------------
-- Every frame: where you are on BV's route, which way to point, the arrow.
------------------------------------------------------------------------------------------------------------

-- The route being followed. BV.lua puts it here (ns.setRoute): corners x[i], y[i] (HereBeDragons world coordinates),
-- z[i] when known, n of them. Followed from here: k the corner you head for, seg the leg you are on, segT how far
-- along it, off how far from it, remaining the yards to the end.
local route
local ADVANCE = 3 -- yards from a corner that count as reaching it

local function pointOnSeg(p, i, t)
	local j = min(i + 1, p.n)
	local z0 = p.z and p.z[i] or 0
	local z1 = p.z and p.z[j] or 0
	return p.x[i] + (p.x[j] - p.x[i]) * t, p.y[i] + (p.y[j] - p.y[i]) * t, z0 + (z1 - z0) * t
end

local function segDist(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local l2 = dx * dx + dy * dy
	local t = l2 > 1e-9 and max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
	return dist(px, py, ax + dx * t, ay + dy * t), t
end

-- where on the route you are: only the legs near the one you were on are looked at, so a leg is not mistaken for
-- another that lies close beside it
local function follow(p, px, py)
	local k0 = p.k or 2
	local bestI, bestD, bestT = max(1, k0 - 1), huge, 0
	for i = max(1, k0 - 2), min(p.n - 1, k0 + 4) do
		local d, t = segDist(px, py, p.x[i], p.y[i], p.x[i + 1], p.y[i + 1])
		if d <= bestD + 0.25 then bestI, bestD, bestT = i, d, t end
	end
	local k = bestI + 1
	if k < p.n and dist(px, py, p.x[k], p.y[k]) < ADVANCE then k = k + 1 end
	p.k, p.seg, p.segT, p.off = k, bestI, bestT, bestD
	p.remaining = dist(px, py, p.x[k], p.y[k]) + p.len[p.n] - p.len[k]
end

function ns.setRoute(xs, ys, zs)
	local p = { x = xs, y = ys, z = zs, n = #xs, k = 2, len = { 0 }, bv = true }
	for i = 2, p.n do p.len[i] = p.len[i - 1] + dist(xs[i - 1], ys[i - 1], xs[i], ys[i]) end
	route = p
	local px, py = HBD():GetPlayerWorldPosition()
	if px and p.n >= 2 then follow(p, px, py) end
	return p
end
function ns.clearRoute() route = nil end
function ns.getRoute() return route end

-- Yards along the route from you to its first hairpin (a leg turning more than 110 degrees against the way you
-- start out), or huge when there is none. The arrow never looks past it: a route that goes out and comes back
-- would otherwise be aimed at a point behind you. Legs under 2 yards (a jog at the start) do not set the way.
local function turnLimit(p)
	local i = p.seg
	local x, y = pointOnSeg(p, i, p.segT or 0)
	local total, hx0, hy0 = 0, nil, nil
	while i < p.n do
		local x1, y1 = p.x[i + 1], p.y[i + 1]
		local L = dist(x, y, x1, y1)
		if L > 2 then
			local hx, hy = (x1 - x) / L, (y1 - y) / L
			if not hx0 then
				hx0, hy0 = hx, hy
			elseif hx * hx0 + hy * hy0 < -TURN_MAX then
				return total
			end
		end
		total = total + L
		x, y = x1, y1
		i = i + 1
	end
	return huge
end

-- The point d yards ahead along the route's own corners, from where you are on it (x, y, z)
local function routePoint(p, d, pz)
	local i = p.seg
	local x, y, z = pointOnSeg(p, i, p.segT or 0)
	if not p.z then z = pz end
	local left = d
	while i < p.n do
		local x1, y1 = p.x[i + 1], p.y[i + 1]
		local z1 = p.z and p.z[i + 1] or pz
		local L = dist(x, y, x1, y1)
		if L >= left and L > 1e-6 then
			local u = left / L
			return x + (x1 - x) * u, y + (y1 - y) * u, z + (z1 - z) * u
		end
		left = left - L
		x, y, z = x1, y1, z1
		i = i + 1
	end
	return x, y, z
end

-- Where the arrow points: averaged over the last 30% of the look-ahead so it does not twitch, but never past the
-- first hairpin
local function routeAhead(p, d, pz)
	if not p.seg or not p.x[p.seg + 1] then return end
	d = min(d, max(3, turnLimit(p)))
	local ax, ay, az = 0, 0, 0
	for _, f in ipairs({ 0.7, 0.85, 1 }) do
		local x, y, z = routePoint(p, max(d * f, 0.3), pz)
		ax, ay, az = ax + x, ay + y, az + z
	end
	return ax / 3, ay / 3, az / 3
end

local smooth = {}

-- Returns whether there is something to point at, and how far the route ahead rises (+) or falls (-)
local function frame(dt)
	local p = route
	local px, py = HBD():GetPlayerWorldPosition()
	local onBoat = reroute.update(px, py)
	if not (target and p and px and p.n >= 2) or UnitIsGhost("player") or UnitOnTaxi("player") or onBoat then
		smooth.E = nil
		return false
	end
	follow(p, px, py)
	local _, _, rz = pointOnSeg(p, p.seg, p.segT or 0)
	local pz = (ns.height and ns.height()) or (p.z and rz) or 0
	local sx, sy, sz = routeAhead(p, cfg("arrowAhead") or LOOKAHEAD, pz)
	if not sx then return false end
	local dE, dN, dU = -sx + px, sy - py, sz - pz
	local l = sqrt(dE * dE + dN * dN + dU * dU)
	if l > 1e-3 then
		dE, dN, dU = dE / l, dN / l, dU / l
		if not smooth.E then
			smooth.E, smooth.N, smooth.U = dE, dN, dU
		else
			local k = min(1, dt * TURN_RATE)
			smooth.E = smooth.E + (dE - smooth.E) * k
			smooth.N = smooth.N + (dN - smooth.N) * k
			smooth.U = smooth.U + (dU - smooth.U) * k
		end
	end
	return true, sz - pz
end

local errors = {}
local function report(err)
	if not errors[err] then errors[err] = true; Print("|cffff4040error:|r " .. tostring(err)) end
end

-- A group member you are guided to moves: the place follows them (BV.lua plans again when it has moved)
local function followUnit()
	if target and target.guid and GetTime() - (target.checked or 0) > 0.2 then
		target.checked = GetTime()
		local u = unitByGuid(target.guid)
		local x, y, inst
		if u then x, y, inst = unitWorldPos(u) end
		if x and (inst ~= target.instance or dist(x, y, target.x, target.y) > FOLLOW_MOVE) then
			target.x, target.y, target.instance, target.z = x, y, inst, nil
		end
	end
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt)
	followUnit()
	local ok, guiding, climb = pcall(frame, dt)
	if not ok then report(guiding); guiding = false end

	local ax, ay, hudSize, hudColour = arrowSpot()
	if ax == false then return hideArrowShape() end -- the HUD shows a symbol in the medallion
	if (hudSize or cfg("simpleUI")) and not arrow:IsShown() then arrow:Show() end -- the HUD's arrow, and the simple UI's, do not depend on the arrow setting
	if not hudSize and not cfg("arrow") and not cfg("simpleUI") then
		if arrow:IsShown() then arrow:Hide(); hideArrowShape() end
		return
	end
	if not arrow:IsShown() then return end
	if guiding and smooth.E then
		-- The arrow is always drawn as seen from the default tilt, turned only by which way the character faces
		setCamera(GetPlayerFacing() or 0, rad(ARROW_TILT), 0, 0, 0, 1)
		local okA, err = pcall(renderArrow, ax, ay, smooth.E, smooth.N, smooth.U, hudSize, hudColour)
		if not okA then report(err); return hideArrowShape() end
		if hudSize then
			-- in the HUD's medallion: the HUD says the yards and what to do, the arrow's own tilt shows up and down
			arrow.climb:SetText("")
			arrow.dist:SetText("")
		elseif cfg("simpleUI") then
			-- the simple UI: what to do now (and whether it is up or down), and where to, under the arrow
			local hint = (climb and climb > CLIMB and "  ^ up") or (climb and climb < -CLIMB and "  v down") or ""
			arrow.climb:SetText((ns.simpleNow or "") .. hint)
			arrow.dist:SetText(ns.simpleTarget or "")
		elseif cfg("arrowText") then
			if climb and climb > CLIMB then
				arrow.climb:SetText("^ up")
			elseif climb and climb < -CLIMB then
				arrow.climb:SetText("v down")
			else
				arrow.climb:SetText("")
			end
			local rem = route and route.remaining
			arrow.dist:SetText(rem and format("%d yd", floor(rem + 0.5)) or "")
		else
			arrow.climb:SetText("")
			arrow.dist:SetText("")
		end
	elseif target and not handle:IsShown() then
		hideArrowShape()
		local why = noRouteText()
		if why and not hudSize and not (ns.ended and ns.ended()) then
			arrow.climb:ClearAllPoints()
			arrow.climb:SetPoint("TOP", UIParent, "BOTTOMLEFT", ax, ay)
			arrow.climb:SetText("|cffff9933Pathy: " .. why .. "|r")
		end
	elseif handle:IsShown() or (PathySettings and PathySettings:IsShown()) then
		-- a preview while moving it or changing its look: ahead and a little down, seen from behind
		setCamera(0, 0.35, 0, 0, 0, 1)
		local okA, err = pcall(renderArrow, ax, ay, 0, 1, 0)
		if not okA then report(err) end
		arrow.climb:SetText("|cff888888(preview: Pathy is not guiding)|r")
		arrow.dist:SetText(cfg("arrowText") and "^ up  42 yd" or "")
	else
		hideArrowShape()
	end
end)

local function updateArrowShown()
	if cfg("arrow") then arrow:Show() else arrow:Hide(); hideArrowShape() end
end

------------------------------------------------------------------------------------------------------------
-- Minimap button: sits on the minimap's edge (drag it round). Left-click: the quest list. Right-click: stop.
------------------------------------------------------------------------------------------------------------

local mmb = CreateFrame("Button", "PathyMinimapButton", Minimap)
mmb:SetSize(31, 31)
mmb:SetFrameStrata("MEDIUM")
mmb:SetFrameLevel(8)
mmb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mmb:RegisterForDrag("LeftButton")
mmb:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
mmb.icon = mmb:CreateTexture(nil, "BACKGROUND")
mmb.icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
mmb.icon:SetSize(20, 20)
mmb.icon:SetPoint("TOPLEFT", 7, -5)
mmb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
mmb.border = mmb:CreateTexture(nil, "OVERLAY")
mmb.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmb.border:SetSize(53, 53)
mmb.border:SetPoint("TOPLEFT")
mmb:Hide()

local function placeMinimapButton()
	local a = rad(PathyDB.minimapAngle or 200)
	local r = (Minimap:GetWidth() / 2) + 5
	mmb:ClearAllPoints()
	mmb:SetPoint("CENTER", Minimap, "CENTER", cos(a) * r, sin(a) * r)
end

mmb:SetScript("OnDragStart", function(self)
	self:SetScript("OnUpdate", function()
		local mx, my = Minimap:GetCenter()
		local cx, cy = GetCursorPosition()
		local s = Minimap:GetEffectiveScale()
		PathyDB.minimapAngle = math.deg(atan2(cy / s - my, cx / s - mx)) % 360
		placeMinimapButton()
	end)
end)
mmb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mmb:SetScript("OnClick", function(_, button)
	if IsShiftKeyDown() then
		PathySettings:SetShown(not PathySettings:IsShown())
	elseif button == "RightButton" then
		if target then stop("stopped") else Print("not guiding anywhere") end
	elseif PathyFrame:IsShown() then
		PathyFrame:Hide()
	else
		PathyFrame:Show()
	end
end)
mmb:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("Pathy")
	if target then
		GameTooltip:AddLine("Guiding to " .. target.name .. (target.quest ~= "" and (" (" .. target.quest .. ")") or ""), 1, 1, 1, true)
	else
		GameTooltip:AddLine("Not guiding", 0.7, 0.7, 0.7)
	end
	GameTooltip:AddLine("Left-click: quest list   Right-click: stop   Shift-click: settings   Drag: move", 0.6, 0.8, 1, true)
	GameTooltip:Show()
end)
mmb:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function updateMinimapButton()
	if not cfg("minimapButton") then mmb:Hide() else placeMinimapButton(); mmb:Show() end
end

------------------------------------------------------------------------------------------------------------
-- Settings window (/pathy config, the Settings button in the quest list, or shift-click the minimap button)
------------------------------------------------------------------------------------------------------------

-- its own block, so its locals end with it (Lua allows 200 per file); these three are used further on
local toggleSettings, applied, registerOptionsEntry
do
local S = CreateFrame("Frame", "PathySettings", UIParent, "BackdropTemplate")
S:SetSize(600, 600)
S:SetPoint("CENTER", 0, 40)
S:SetFrameStrata("MEDIUM")
S:SetToplevel(true)
S:SetMovable(true)
S:EnableMouse(true)
S:SetClampedToScreen(true)
S:RegisterForDrag("LeftButton")
S:SetScript("OnDragStart", S.StartMoving)
S:SetScript("OnDragStop", S.StopMovingOrSizing)
S:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
S:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
S:Hide()
tinsert(UISpecialFrames, "PathySettings")

local sTitle = S:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
sTitle:SetPoint("TOPLEFT", 14, -12)
sTitle:SetText("Pathy settings")
CreateFrame("Button", nil, S, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -2, -2)

local refreshers = {} -- each puts its widget back in line with the saved setting
local function refreshSettings() for _, fn in ipairs(refreshers) do fn() end end
onArrowMoved = refreshSettings

-- a setting changed: things that need more than being read next frame
function applied(key)
	if key == "arrow" then updateArrowShown() end
	if key == "windowAlpha" or key == "uiScale" or key == "windowColour" or key == "windowBorder" then f.ApplyLook() end
	if key == "minimapButton" then updateMinimapButton() end
	if (key == "guidePanel" or key == "hideBVGuide" or key == "silenceBV" or key == "showLogButton" or key == "simpleUI") and ns.BV then ns.BV.refresh() end

	if (key == "arrowX" or key == "arrowY") and handle:IsShown() then setArrowUnlocked(true) end
end

local function set(key, value)
	PathyDB[key] = value
	applied(key)
end

local function header(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function checkbox(parent, key, label, x, y)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	cb:SetPoint("TOPLEFT", x, y)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetWidth(500 - x) -- wraps inside the window
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(true)
	fs:SetText(label)
	cb:SetScript("OnClick", function(self) set(key, self:GetChecked() and true or false) end)
	refreshers[#refreshers + 1] = function() cb:SetChecked(cfg(key) and true or false) end
	return cb
end

-- show: how to write the value (shown x factor)
local function slider(parent, key, label, x, y, lo, hi, step, fmt, factor)
	factor = factor or 1
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetWidth(300) -- long labels wrap instead of running off the window
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(true)
	local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
	s:SetOrientation("HORIZONTAL")
	s:SetSize(240, 16)
	s:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -2) -- under the label, however many lines it takes
	s:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background", edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile = true, tileSize = 8, edgeSize = 8, insets = { left = 3, right = 3, top = 6, bottom = 6 } })
	s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	s:SetMinMaxValues(lo, hi)
	s:SetValueStep(step)
	if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
	local setting = false
	local function label_(v) fs:SetText(label .. ":  |cffffffff" .. format(fmt, v * factor) .. "|r") end
	s:SetScript("OnValueChanged", function(_, v)
		v = floor(v / step + 0.5) * step
		label_(v)
		if not setting then set(key, v) end
	end)
	refreshers[#refreshers + 1] = function()
		setting = true
		s:SetValue(cfg(key))
		setting = false
		label_(cfg(key))
	end
	return s
end

local function pickColour(key)
	local old = cfg(key)
	local r, g, b = old[1], old[2], old[3]
	local function apply()
		local nr, ng, nb = ColorPickerFrame:GetColorRGB()
		set(key, { nr, ng, nb })
		refreshSettings()
	end
	local function cancel()
		set(key, { r, g, b })
		refreshSettings()
	end
	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({ r = r, g = g, b = b, hasOpacity = false, swatchFunc = apply, cancelFunc = cancel })
	else
		ColorPickerFrame:Hide()
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.func, ColorPickerFrame.cancelFunc = apply, cancel
		ColorPickerFrame.previousValues = { r = r, g = g, b = b }
		ColorPickerFrame:SetColorRGB(r, g, b)
		ColorPickerFrame:Show()
	end
	ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
end

local function swatch(parent, key, label, x, y)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(22, 22)
	b:SetPoint("TOPLEFT", x, y)
	b:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
		insets = { left = 2, right = 2, top = 2, bottom = 2 } })
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", b, "RIGHT", 6, 0)
	fs:SetText(label)
	b:SetScript("OnClick", function() pickColour(key) end)
	refreshers[#refreshers + 1] = function()
		local c = cfg(key)
		b:SetBackdropColor(c[1], c[2], c[3], 1)
	end
	return b
end

local function button(parent, text, w, x, y, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(w, 22)
	b:SetPoint("TOPLEFT", x, y)
	b:SetText(text)
	b:SetScript("OnClick", fn)
	return b
end

-- The settings, built the same way into Pathy's own window and into the game's options (Esc > Options > AddOns >
-- Pathy): a stack of sections, each folded or opened by clicking its title. Both copies share the folded state.
local unlockBtns = {}
local function updateUnlock()
	for _, b in ipairs(unlockBtns) do b:SetText(handle:IsShown() and "Lock in place" or "Drag to move") end
end
local painters = {}
local function repaintSections() for _, p in ipairs(painters) do p() end end
local HEAD = 24

local function buildSettings(content)
	local secs, last = {}, nil
	local function relayout()
		local h = 0
		for _, sec in ipairs(secs) do h = h + sec:GetHeight() end
		content:SetHeight(h + 10)
	end
	local function section(title, foldedByDefault)
		local sec = CreateFrame("Frame", nil, content)
		sec:SetWidth(560)
		if last then sec:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, 0) else sec:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0) end
		last = sec
		secs[#secs + 1] = sec
		local head = CreateFrame("Button", nil, sec)
		head:SetPoint("TOPLEFT", 0, 0)
		head:SetSize(560, HEAD)
		local fs = head:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetPoint("LEFT", 4, 0)
		local body = CreateFrame("Frame", nil, sec)
		body:SetPoint("TOPLEFT", 0, -HEAD)
		body:SetSize(560, 10)
		local flow = { y = 4 }
		local function folded()
			local t = PathyDB and PathyDB.settingsFolded
			if t and t[title] ~= nil then return t[title] end
			return foldedByDefault and true or false
		end
		local function paint()
			local fold = folded()
			fs:SetText((fold and "[+]  " or "[-]  ") .. title)
			body:SetShown(not fold)
			sec:SetHeight(HEAD + (fold and 0 or flow.y + 6))
			relayout()
		end
		head:SetScript("OnClick", function()
			PathyDB.settingsFolded = PathyDB.settingsFolded or {}
			PathyDB.settingsFolded[title] = not folded()
			repaintSections()
		end)
		painters[#painters + 1] = paint
		function flow.check(key, label)
			checkbox(body, key, label, 16, -flow.y)
			flow.y = flow.y + (#label > 80 and 40 or 26)
		end
		function flow.slider(key, label, lo, hi, step, fmt, factor)
			slider(body, key, label, 20, -flow.y, lo, hi, step, fmt, factor)
			flow.y = flow.y + 28 + 12 * math.ceil((#label + 8) / 50)
		end
		function flow.swatch(key, label)
			swatch(body, key, label, 20, -flow.y)
			flow.y = flow.y + 30
		end
		function flow.buttons(...)
			local x = 20
			for _, b in ipairs({ ... }) do
				local btn = button(body, b[1], b[2], x, -flow.y, b[3])
				if b[4] then b[4](btn) end
				x = x + b[2] + 10
			end
			flow.y = flow.y + 30
		end
		return flow
	end

	local g = section("General")
	g.check("minimapButton", "Pathy button on the minimap")
	g.check("followTracked", "Guide to the quest I focus in Questie's tracker")
	g.slider("arrowAhead", "Arrow looks ahead (short follows bends, long is steadier)", 1, 120, 1, "%d yd")
	g.slider("windowAlpha", "Pathy window background opacity", 0, 1, 0.05, "%d%%", 100)
	g.slider("uiScale", "Pathy window size (UI scale)", 0.5, 1.5, 0.05, "%d%%", 100)
	g.buttons({ "Reset everything to defaults", 220, function()
		for k in pairs(DEFAULTS) do PathyDB[k] = nil end
		for k in pairs(DEFAULTS) do applied(k) end
		refreshSettings()
	end })

	local c = section("Colour scheme")
	c.swatch("windowColour", "Pathy window background")
	c.swatch("windowBorder", "Pathy window border")
	c.check("hudColourOn", "Use my own colour for the HUD's arrow instead of the theme's")
	c.swatch("hudColour", "HUD arrow colour")
	c.buttons({ "Reset colours", 120, function()
		PathyDB.windowColour, PathyDB.windowBorder, PathyDB.hudColourOn, PathyDB.hudColour = nil, nil, nil, nil
		applied("windowColour")
		refreshSettings()
	end })

	local h = section("HUD")
	h.check("simpleUI", "Simple path UI: only the arrow, with the instructions under it (no HUD)")
	h.check("guidePanel", "Show the HUD (drag it anywhere, right-click it for its menu)")
	h.check("hideBVGuide", "Hide the route planner's own guide window while Pathy guides (it comes back afterwards)")
	h.check("silenceBV", "Silence the route planner's chat messages (they stay in its log and in /pathy route)")
	h.check("showLogButton", "Show the log button on the HUD (what the route planner did for this way)")

	local w = section("Simple Widget Settings", true)
	w.check("arrow", "Show the arrow")
	w.slider("arrowSize", "Arrow size", 0.2, 2, 0.05, "%d%%", 100)
	w.slider("arrowAlpha", "Arrow opacity", 0.05, 1, 0.05, "%d%%", 100)
	w.swatch("arrowColour", "Arrow colour")
	w.check("arrowDirColour", "Colour by direction (green ahead, red behind)")
	w.check("arrowText", "Show up / down and the distance under it")
	w.slider("arrowX", "Arrow: across the screen", 0, 1, 0.01, "%d%%", 100)
	w.slider("arrowY", "Arrow: up the screen", 0, 1, 0.01, "%d%%", 100)
	w.buttons({ "Drag to move", 130, function()
		setArrowUnlocked(not handle:IsShown())
		updateUnlock()
	end, function(b) unlockBtns[#unlockBtns + 1] = b end }, { "Reset position", 120, function()
		PathyDB.arrowX, PathyDB.arrowY = nil, nil
		applied("arrowX")
		refreshSettings()
	end })
	w.slider("textAlpha", "Text under the arrow: opacity", 0.05, 1, 0.05, "%d%%", 100)
	w.swatch("textColour", "Text colour")
	w.slider("textX", "Text: across the screen", 0, 1, 0.01, "%d%%", 100)
	w.slider("textY", "Text: up the screen", 0, 1, 0.01, "%d%%", 100)
	w.buttons({ "Reset text position", 150, function()
		PathyDB.textX, PathyDB.textY = nil, nil
		refreshSettings()
	end })

	refreshers[#refreshers + 1] = repaintSections
end

-- in Pathy's own window
local sScroll = CreateFrame("ScrollFrame", "PathySettingsScroll", S, "UIPanelScrollFrameTemplate")
sScroll:SetPoint("TOPLEFT", 12, -40)
sScroll:SetPoint("BOTTOMRIGHT", -32, 12)
local sContent = CreateFrame("Frame", nil, sScroll)
sContent:SetSize(560, 10)
sScroll:SetScrollChild(sContent)
buildSettings(sContent)

S:SetScript("OnShow", refreshSettings)
S:SetScript("OnHide", function()
	setArrowUnlocked(false)
	updateUnlock()
end)

function toggleSettings()
	if S:IsShown() then S:Hide() else S:Show() end
end

-- the same settings in the game's own options
function registerOptionsEntry()
	local panel = CreateFrame("Frame")
	panel.name = "Pathy"
	local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	t:SetPoint("TOPLEFT", 16, -16)
	t:SetText("Pathy")
	local d = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -8)
	d:SetPoint("RIGHT", -16, 0)
	d:SetJustifyH("LEFT")
	d:SetText("A 3D arrow and a guide window that lead you to quest givers, turn-ins, your map pin or your target along a planned route (walls, stairs, lifts, boats and zeppelins included). "
		.. "The same settings open in their own window with /pathy config or a shift-click on Pathy's minimap button, where you can see the arrow change while you adjust it.")
	local scroll = CreateFrame("ScrollFrame", "PathyOptionsScroll", panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -12)
	scroll:SetPoint("BOTTOMRIGHT", -32, 12)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(560, 10)
	scroll:SetScrollChild(content)
	buildSettings(content)
	panel:SetScript("OnShow", refreshSettings)
	panel:SetScript("OnHide", function()
		setArrowUnlocked(false)
		updateUnlock()
	end)
	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, "Pathy"))
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
end
end -- the settings window

------------------------------------------------------------------------------------------------------------
-- Events and slash command
------------------------------------------------------------------------------------------------------------

-- The quest you focus in Questie's tracker (its focus button sets the game's super-tracked quest) or send to
-- TomTom from it: Pathy guides you there. An in-progress quest goes to its area or objective, a finished one to
-- its turn-in, one not taken yet to its giver.
local followReady = false -- not before a moment after login: the game reports the focused quest as it loads
local function guideToQuest(questId)
	questId = tonumber(questId)
	if not followReady or not cfg("followTracked") or not questId or questId <= 0 then return end
	local entry
	for _, q in ipairs(questLog()) do if q.id == questId then entry = q break end end
	local kind = not entry and "giver" or entry.complete and "turnin" or "objective"
	if target and target.questId == questId and target.kind == kind then return end -- already on it
	if kind == "objective" then goObjective(questId) else go(questId, kind) end
end

------------------------------------------------------------------------------------------------------------
-- Right-click menus: "Pathy: guide me there" on a quest (Questie's tracker, the quest log) and on Questie's map
-- and minimap icons.
------------------------------------------------------------------------------------------------------------
local ctx = {}

-- start guiding to a quest from wherever it stands: objective, turn-in or giver
function ctx.quest(questId)
	questId = tonumber(questId)
	if not questId or questId <= 0 then return end
	local entry
	for _, q in ipairs(questLog()) do if q.id == questId then entry = q break end end
	local kind = not entry and "giver" or entry.complete and "turnin" or "objective"
	if kind == "objective" then goObjective(questId) else go(questId, kind) end
end

ctx.TEXT = "Pathy: guide me there"

-- a one-entry menu at the cursor, in Questie's own drop-down (the same one its tracker uses)
function ctx.show(title, action)
	local TM = questie("TrackerMenu")
	local lib = LibStub and LibStub("LibUIDropDownMenuQuestie-4.0", true)
	if not (lib and TM and TM.menuFrame) then return end
	lib:EasyMenu({
		{ text = title or "?", isTitle = true, notCheckable = true },
		{ text = ctx.TEXT, notCheckable = true, func = function() lib:CloseDropDownMenus(); pcall(action) end },
	}, TM.menuFrame, "cursor", 0, 0, "MENU")
end

-- the Questie icon the mouse is on: its tooltip is showing, owned by it
function ctx.icon()
	local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
	if owner and owner.data and owner.x and owner.y and owner.UiMapID and owner.IsMouseOver and owner:IsMouseOver() then return owner end
end

-- right-clicks on an icon fall through to the map or minimap, which is where they are heard
function ctx.onMapClick(_, button)
	if button ~= "RightButton" then return end
	local icon = ctx.icon()
	if not icon then return end
	local x, y, inst = HBD():GetWorldCoordinatesFromZone(icon.x / 100, icon.y / 100, icon.UiMapID)
	if not x then return end
	local name = icon.data.Name or "that spot"
	local uiMap = icon.UiMapID
	ctx.show(name, function()
		goTo({ { x = x, y = y, instance = inst, uiMap = uiMap, name = name } }, { name = name, kind = "spot", what = "map icon",
			saved = { kind = "spot", x = x, y = y, instance = inst, uiMap = uiMap, name = name } })
	end)
end

function ctx.install()
	if ctx.installed then return end
	ctx.installed = true
	-- Questie's tracker: the entry goes in under the quest's name
	local TM = questie("TrackerMenu")
	if TM and TM.GetMenuForQuest then
		local original = TM.GetMenuForQuest
		TM.GetMenuForQuest = function(self, quest)
			local menu = original(self, quest)
			if type(menu) == "table" and quest and quest.Id then
				local id = quest.Id
				table.insert(menu, math.min(2, #menu + 1), { text = ctx.TEXT, notCheckable = true,
					func = function() pcall(ctx.quest, id) end })
			end
			return menu
		end
	end
	-- the map and the minimap
	local mapFrame = WorldMapFrame and (WorldMapFrame.ScrollContainer or WorldMapFrame)
	if mapFrame and mapFrame.HookScript then mapFrame:HookScript("OnMouseUp", ctx.onMapClick) end
	if Minimap and Minimap.HookScript then Minimap:HookScript("OnMouseUp", ctx.onMapClick) end
	-- the game's own quest log
	if QuestLogTitleButton_OnClick then
		hooksecurefunc("QuestLogTitleButton_OnClick", function(self, button)
			if button ~= "RightButton" then return end
			local index = self.questLogIndex or (self:GetID() + (FauxScrollFrame_GetOffset and QuestLogListScrollFrame
				and FauxScrollFrame_GetOffset(QuestLogListScrollFrame) or 0))
			local info = C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetInfo(index)
			local id, title
			if info and not info.isHeader then
				id, title = info.questID, info.title
			elseif GetQuestLogTitle then
				local t, _, _, isHeader, _, _, _, qid = GetQuestLogTitle(index)
				if not isHeader then id, title = qid, t end
			end
			if id and id > 0 then ctx.show(title, function() ctx.quest(id) end) end
		end)
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:RegisterEvent("QUEST_TURNED_IN")
events:RegisterEvent("QUEST_ACCEPTED")
events:RegisterEvent("QUEST_REMOVED")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("SUPER_TRACKING_CHANGED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("FRIENDLIST_UPDATE")
local pendingRefresh

-- a target carried over a /reload or relog
local function resume(saved)
	if saved.kind == "pin" and saved.pin then
		local x, y, inst = HBD():GetWorldCoordinatesFromZone(saved.pin[2], saved.pin[3], saved.pin[1])
		if x then
			goTo({ { x = x, y = y, instance = inst, uiMap = saved.pin[1], name = "your map pin" } }, { kind = "pin", saved = saved })
		end
	elseif saved.kind == "unit" and saved.guid then
		goUnit(saved.guid, saved.name)
	elseif saved.kind == "spot" and saved.x then
		goTo({ { x = saved.x, y = saved.y, instance = saved.instance, uiMap = saved.uiMap, name = saved.name } }, { name = saved.name, kind = "spot", saved = saved })
	elseif saved.kind == "npc" and saved.npcId then
		goNpc(saved.npcId, saved.name)
	elseif saved.questId and saved.kind == "objective" then
		goObjective(saved.questId)
	elseif saved.questId then
		go(saved.questId, saved.kind)
	end
end

events:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		PathyDB = PathyDB or {}
		-- what earlier versions kept for routes of their own (walked spots, flight paths, NPC heights, their switches): gone
		for _, k in ipairs({ "walk", "walk2", "walk3", "walkCell", "npcZ", "taxi", "mountSpeed", "recordWalk", "useWalked", "recordOthers", "useGrid", "gridOnly", "useGolden", "refine", "bvOnly", "restore", "savedPin" }) do PathyDB[k] = nil end
		PathyDB.arrowPos, PathyDB.fixedDots, PathyDB.arrowScale, PathyDB.tilt = nil, nil, nil, nil -- from older versions
		if type(PathyDB.textX) == "number" and (PathyDB.textX < 0 or PathyDB.textX > 1) then PathyDB.textX = nil end
		if type(PathyDB.textY) == "number" and (PathyDB.textY < 0 or PathyDB.textY > 1) then PathyDB.textY = nil end

		if PathyDB.pos then
			local p = PathyDB.pos
			f:ClearAllPoints()
			f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
		end
		updateArrowShown()
		f.ApplyLook()
		updateMinimapButton()
		pcall(registerOptionsEntry)
	elseif event == "PLAYER_LOGIN" then
		pcall(ctx.install)
		-- the window was open when you left: open it again (after Questie has had a moment to load)
		if PathyDB.shown then C_Timer.After(2, function() if not f:IsShown() then f:Show() end end) end
		C_Timer.After(6, function() followReady = true end)
		-- Questie's tracker: sending a quest to TomTom (its click binding) guides there too
		local TU = questie("TrackerUtils")
		if TU and TU.SetQuestTomTomTarget then
			hooksecurefunc(TU, "SetQuestTomTomTarget", function(questId) pcall(guideToQuest, questId) end)
		end
		local saved = PathyDB.target
		if saved then
			C_Timer.After(5, function() -- once Questie has loaded its database
				if not target and PathyDB.target == saved then pcall(resume, saved) end
			end)
		end
	elseif event == "QUEST_REMOVED" or event == "PLAYER_LEVEL_UP" then
		invalidateAvailable()
		if event == "QUEST_REMOVED" and target and target.questId and target.questId == arg1 and target.kind ~= "giver" then
			C_Timer.After(0.2, function() -- a hand-in also removes it; QUEST_TURNED_IN says so first
				if target and target.questId == arg1 then stop("the quest left your log: stopped") end
			end)
		end
	elseif event == "SUPER_TRACKING_CHANGED" then
		local id = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()
		if id and id ~= 0 then pcall(guideToQuest, id) end
	elseif event == "QUEST_LOG_UPDATE" then
		if target and target.kind == "objective" and target.questId then
			for _, q in ipairs(questLog()) do
				if q.id == target.questId and q.complete then
					Print("objectives done for " .. target.quest .. ": on to the turn-in")
					go(q.id, "turnin")
					break
				end
			end
		end
	elseif event == "QUEST_TURNED_IN" or event == "QUEST_ACCEPTED" then
		invalidateAvailable()
		-- the goal is done: accepted the quest we were walking to, or handed in the one we were turning in
		-- QUEST_ACCEPTED is (logIndex, questID) on Classic clients and (questID) on newer ones
		local id = event == "QUEST_TURNED_IN" and arg1 or arg2 or arg1
		if target and target.questId and target.questId == id then stop("done: " .. target.quest) end
	end
	if f:IsShown() and not pendingRefresh then
		pendingRefresh = true
		C_Timer.After(0.5, function() pendingRefresh = nil; f.Refresh() end)
	end
end)

local function onOff(v) return v and "|cff40ff40on|r" or "|cffff4040off|r" end

-- /pathy [stop | pin | target | <part of a quest or NPC name> | ...]
SLASH_PATHY1 = "/pathy"
SlashCmdList.PATHY = function(msg)
	msg = strtrim(msg or "")
	local lower = msg:lower()
	local num = tonumber(lower:match("^%a+ (.+)") or "")
	if msg == "" then
		if f:IsShown() then f:Hide() else f:Show() end
	elseif lower == "stop" then
		if target then stop("stopped") else Print("not guiding anywhere") end
	elseif lower == "pin" then
		goPin()
	elseif lower == "target" then
		goTargetNpc()
	elseif lower == "config" or lower == "settings" or lower == "options" then
		toggleSettings()
	elseif lower == "arrow" or lower == "minimap" then
		local key = lower == "minimap" and "minimapButton" or lower
		PathyDB[key] = not cfg(key)
		applied(key)
		Print(({ arrow = "arrow", minimapButton = "minimap button" })[key] .. " " .. onOff(cfg(key)))
	elseif lower == "route" or lower == "bv" then
		ns.BV.report()
	elseif lower == "hud" then
		PathyDB.guidePanel = not cfg("guidePanel")
		applied("guidePanel")
		Print("HUD " .. onOff(cfg("guidePanel")) .. " (drag it to move it; right-click it for its menu; |cffffff00/pathy route|r says what was planned)")
	elseif lower == "help" then
		Print("/pathy  - open the quest list (click one to walk to its NPC)")
		Print("/pathy pin  - walk to your map pin    /pathy target  - walk to the NPC you have targeted")
		Print("/pathy <name>  - walk to the first quest or NPC in the list matching that text")
		Print("/pathy stop  - stop guiding")
		Print("/pathy route  - what was planned for the current destination, and what Pathy is drawing")
		Print("/pathy hud  - show or hide the HUD")
		Print("/pathy arrow | minimap  - turn the arrow / the minimap button on or off")
		Print("/pathy config  - settings: the arrow's and dots' size, opacity, colour, position...")
	else
		local ok, entries = pcall(allEntries)
		if not ok then return Print("Questie is still loading; try again in a moment") end
		for _, it in ipairs(entries) do
			local all = true
			for word in lower:gmatch("%S+") do
				if not it.text:find(word, 1, true) then all = false break end
			end
			if all then return it.e.action() end
		end
		Print("nothing in Pathy's lists matches '" .. msg .. "'")
	end
end
