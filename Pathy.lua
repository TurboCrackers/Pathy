-- Pathy: pick a quest giver (to start a quest) or a turn-in NPC (to finish one) and get walked there with
-- ground dots along the real walkable route, so a target on another level of a cave is reached by the way
-- down (or up) instead of a straight line through the rock.
--
-- Pathy finds the NPCs in Questie's WoW: Forever database and hands the target to Guidelime Pathfinder,
-- which owns the walk grid (with cave and building levels), the in-world marker and the ground dots.
-- While guiding, Pathy keeps Pathfinder's minimap trail off and stops WaypointTracker from picking up the
-- map pins Pathfinder moves from corner to corner (it called each corner "You have arrived!" and removed it,
-- which switched the dots off). Guiding only ends when the quest is accepted / turned in, or /pathy stop.

local ADDON = ...
local PF = GuidelimePathfinder -- Guidelime Pathfinder's namespace (a required dependency)

local sqrt, floor = math.sqrt, math.floor

local MAX_AVAILABLE = 60

local target        -- { x, y, instance, z, name, quest, kind, uiMap }

local function Print(...) print("|cff66ccffPathy:|r", ...) end

-- Settings (PathyDB holds only what was changed; /pathy config opens the window)
local DEFAULTS = {
	arrow = true, arrowSize = 0.55, arrowAlpha = 0.45, arrowColour = { 0.75, 0.75, 0.75 }, arrowDirColour = true,
	arrowText = true, arrowX = 0.5, arrowY = 0.31,
	textAlpha = 0.9, textColour = { 1, 1, 1 }, textX = 0.5, textY = 0.29,
	dots = false, dotSize = 0.6, dotAlpha = 1, dotColour = { 0.8, 0.8, 0.8 }, dotSpacing = 4, dotRange = 60, arrowAhead = 40, windowAlpha = 0.92, uiScale = 1,
	smooth = 60, minimapButton = true, minimapTrail = false,
	usePin = true, estimate = true, camPitch = 9, followTracked = true,
	recordWalk = true, useWalked = true, recordOthers = true,
}
local function cfg(key)
	local v = PathyDB and PathyDB[key]
	if v == nil then return DEFAULTS[key] end
	return v
end

local function HBD() return PF and PF.HBD end

local function dist(ax, ay, bx, by) return sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

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
-- Guiding (through Guidelime Pathfinder)
------------------------------------------------------------------------------------------------------------

-- Other addons' settings Pathy changes while guiding: Pathfinder's minimap trail off (Pathy draws its own),
-- Pathfinder's own ground dots off (Pathy draws its own), and WaypointTracker's "follow map pins" off (it took
-- each of the marker's corners for a new waypoint). The originals are kept in PathyDB.restore, so they come
-- back even after a /reload in the middle of a trip.
local function quietSettings()
	local list = {}
	if PF and PF.db then
		list[#list + 1] = { "minimap", PF.db, false }
		list[#list + 1] = { "marker", PF.db, cfg("usePin") } -- the marker is the game's map pin, moved about
		list[#list + 1] = { "dots", PF.db, false }
	end
	local wt = WaypointTrackerDB and WaypointTrackerDB.settings
	if wt then list[#list + 1] = { "followMapPins", wt, false } end
	return list
end

local function setQuiet(on)
	PathyDB.restore = PathyDB.restore or {}
	local restore = PathyDB.restore
	for _, s in ipairs(quietSettings()) do
		local key, db, value = s[1], s[2], s[3]
		if on then
			if restore[key] == nil then restore[key] = db[key] == nil and "default" or db[key] end
			db[key] = value
		elseif restore[key] ~= nil then
			if restore[key] == "default" then db[key] = nil else db[key] = restore[key] end
			restore[key] = nil
		end
	end
	if PF and PF.Trail and PF.Trail.Refresh then PF.Trail.Refresh() end
end

-- Your own map pin. Pathfinder steers its in-world marker (which the dots and arrow are lined up with) by
-- moving the game's map pin, so a pin you had is kept aside and put back when guiding ends; a pin you place
-- while guiding is left alone (the dots pause until you remove it; the arrow keeps going).
local function currentPin()
	if not (C_Map.HasUserWaypoint and C_Map.HasUserWaypoint()) then return end
	local wp = C_Map.GetUserWaypoint()
	if not wp or not wp.uiMapID or not wp.position then return end
	return { wp.uiMapID, wp.position.x, wp.position.y,
		C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint() or false }
end

local function savePlayerPin()
	if not cfg("usePin") or PathyDB.savedPin then return end
	if PF.Marker and PF.Marker.IsActive and PF.Marker.IsActive() then return end -- that one is Pathfinder's
	PathyDB.savedPin = currentPin()
end

local function restorePlayerPin()
	local pin = PathyDB.savedPin
	PathyDB.savedPin = nil
	if not cfg("usePin") then return end -- Pathy never touched your pin
	if not pin or (C_Map.HasUserWaypoint and C_Map.HasUserWaypoint() and not (PF.Marker and PF.Marker.IsActive())) then return end
	pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(pin[1], pin[2], pin[3]))
	if pin[4] and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
end

local stopSerial = 0
local function stop(msg)
	if not target then return end
	target = nil
	PathyDB.target = nil
	if msg then Print(msg) end
	if PathyFrame and PathyFrame:IsShown() then PathyFrame.Refresh() end
	-- once Pathfinder has let go of the marker (it looks ten times a second): your pin back, then the settings
	-- (WaypointTracker's last, so it does not take your own pin coming back for a new one)
	stopSerial = stopSerial + 1
	local serial = stopSerial
	C_Timer.After(0.4, function()
		if target or serial ~= stopSerial then return end
		restorePlayerPin()
		C_Timer.After(0.3, function()
			if not target and serial == stopSerial then setQuiet(false) end
		end)
	end)
end

-- Of several spots (an NPC with several spawns, or several NPCs), the one quickest to get to, by Pathfinder's
-- trip planner when it has a walk grid here, else the nearest in a straight line.
local function bestSpot(spots, px, py, instance)
	local G = PF.Graph
	for _, s in ipairs(spots) do
		if G and G.LikelyZ then s.z = s.z or G.LikelyZ(s.instance, s.x, s.y) end
	end
	if G and G.PlanTrip and PF.Speed and PF.KnownTaxi then
		local ok, trip = pcall(G.PlanTrip, { instance = instance, x = px, y = py, z = PF.player and PF.player.z }, spots, {
			speed = PF.Speed(),
			faction = ({ Alliance = "A", Horde = "H" })[UnitFactionGroup("player")],
			known = (PF.KnownTaxi()),
		})
		if ok and trip and trip.goal and spots[trip.goal] then return spots[trip.goal], trip end
	end
	local best, bestD
	for _, s in ipairs(spots) do
		local d = s.instance == instance and dist(px, py, s.x, s.y)
		if d and (not bestD or d < bestD) then best, bestD = s, d end
	end
	return best
end

-- the name of an NPC that walks a route rather than standing still, if it does
local function walker(npcId)
	local DB = questie("QuestieDB")
	if not npcId or not DB or not DB.QueryNPCSingle then return end
	local ok, wps = pcall(DB.QueryNPCSingle, npcId, "waypoints")
	if ok and type(wps) == "table" and next(wps) then return DB.QueryNPCSingle(npcId, "name") or "that NPC" end
end

-- Starts guiding to the best of `spots`. info: { name, quest, questId, kind, what (said in chat), saved (to
-- carry the target over a /reload) }.
local function goTo(spots, info)
	local px, py, instance = HBD():GetPlayerWorldPosition()
	if not px then return Print("the game gives no position here (inside an instance?)") end
	if #spots == 0 then return Print("no location known for " .. (info.name or "that")) end
	local pick, trip = bestSpot(spots, px, py, instance)
	if not pick then return Print("no spot for that on this continent, and no known way there") end
	if not target then savePlayerPin() end
	target = {
		x = pick.x, y = pick.y, instance = pick.instance, z = pick.z, uiMap = pick.uiMap,
		name = pick.name or info.name or "?", quest = info.quest or "", questId = info.questId, kind = info.kind,
	}
	PathyDB.target = info.saved
	if not PF.db.enabled then PF.db.enabled = true end
	setQuiet(true)
	if cfg("usePin") and PF.Marker and PF.Marker.ResetOverride then PF.Marker.ResetOverride() end
	local zone = pick.uiMap and C_Map.GetMapInfo(pick.uiMap)
	local eta = trip and trip.cost and (trip.cost < 60 and ", under a minute away" or format(", about %d min away", floor(trip.cost / 60 + 0.5))) or ""
	Print(format("heading to %s%s%s%s", target.name, info.what and (" (" .. info.what .. ")") or "",
		zone and zone.name and (" in " .. zone.name) or "", eta))
	local w = info.walker or walker(info.npcId)
	if w then Print(w .. " walks a route, so they may be a little way off from where the dots end: look around there") end
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
	local pin = (PF.Marker and PF.Marker.IsActive and PF.Marker.IsActive()) and PathyDB.savedPin or currentPin()
	if not pin then return Print("you have no map pin: Ctrl+click on the world map to place one, then |cffffff00/pathy pin|r") end
	local x, y, inst = HBD():GetWorldCoordinatesFromZone(pin[2], pin[3], pin[1])
	if cfg("usePin") then PathyDB.savedPin = pin end -- Pathfinder steers the game pin on the way there; this one comes back after
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

-- Pathfinder asks ns.GetTarget() ten times a second for where to go; while Pathy has a target, it is ours.
-- (Its own /gpath go and corpse runs still win: those are things the player asked for or needs right now.)
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

local pinNoted
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

local function rerouteFromHere()
	local p = PF.path
	if not p or not p.graph or PF.planning or PF.riding or PF.flying or not PF.Plan then return end
	if reroute.b and reroute.b.on then return end -- on a moving boat: no use planning
	if PF.trip and PF.trip.boarded then return end -- waiting at a dock or a flight master: leave the plan be
	local px, py = HBD():GetPlayerWorldPosition()
	if not px then return end
	local now = GetTime()
	local moved = (px - reroute.x) ^ 2 + (py - reroute.y) ^ 2 > 4
	local strayed = (p.off or 0) > reroute.OFF
	if not ((strayed and now - reroute.at > 1) or (moved and now - reroute.at > reroute.EVERY)) then return end
	reroute.at, reroute.x, reroute.y = now, px, py
	if now - reroute.trip > reroute.TRIP_EVERY and PF.PlanTrip then
		reroute.trip = now
		pcall(PF.PlanTrip, px, py) -- the best way there from here, flights and rides included
	end
	pcall(PF.Plan, px, py, true) -- keeps the current route on screen until the new one is ready
end
-- Flight paths you really have. The game's map list of flight masters does not say reliably which ones this
-- character has found, so Pathfinder could plan a flight you cannot take. Pathy learns them instead: each time
-- you open a flight master's map, the destinations you can fly to (and the one you are at) are written down for
-- this character, and the trip planner only gets those. Until a flight map has been opened once on a character,
-- routes use no flights at all.
local function charKey() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end

local function learnedTaxi()
	return PathyDB.taxi and PathyDB.taxi[charKey()]
end

local function learnTaxiMap()
	if not NumTaxiNodes or not TaxiNodeName or not TaxiNodeGetType then return end
	PathyDB.taxi = PathyDB.taxi or {}
	local key = charKey()
	local mine = PathyDB.taxi[key] or {}
	local added = 0
	for i = 1, NumTaxiNodes() do
		local kind, name = TaxiNodeGetType(i), TaxiNodeName(i)
		if name and (kind == "CURRENT" or kind == "REACHABLE") and not mine[name] then
			mine[name] = true
			added = added + 1
		end
	end
	local first = not PathyDB.taxi[key]
	PathyDB.taxi[key] = mine
	if first then Print("learned this character's flight paths: routes can use flights now") end
	-- plan again with them
	if (added > 0 or first) and target and PF.Plan and PF.player and PF.player.x then pcall(PF.Plan, PF.player.x, PF.player.y) end
end

local taxiNoted
-- Also how fast you travel overland: Pathfinder times walking legs at your speed right now, so on foot it took a
-- long ride for a long run and picked flights or boats a mount would beat. Pathy remembers this character's
-- mount speed (seen whenever you ride) and plans outdoor trips with it.
local function hookKnownTaxi()
	local originalSpeed = PF.Speed
	if originalSpeed then
		PF.Speed = function(...)
			local base = originalSpeed(...)
			local _, run = GetUnitSpeed("player")
			PathyDB.mountSpeed = PathyDB.mountSpeed or {}
			local key = charKey()
			if IsMounted() and run and run > base * 0.99 and run > 7.5 and run > (PathyDB.mountSpeed[key] or 0) then
				PathyDB.mountSpeed[key] = run
			end
			local mount = PathyDB.mountSpeed[key]
			if mount and not IsIndoors() then return math.max(base, mount) end
			return base
		end
	end
	local original = PF.KnownTaxi
	if not original then return end
	PF.KnownTaxi = function(...)
		local found = original(...)
		local mine = learnedTaxi()
		if not mine then
			if target and not taxiNoted then
				taxiNoted = true
				Print("Pathy doesn't know this character's flight paths yet, so routes won't use flights. Open any flight master's map once and it learns them.")
			end
			return {}, 0
		end
		local out, n = {}, 0
		for id, name in pairs(found or {}) do
			if mine[name] then out[id], n = name, n + 1 end
		end
		return out, n
	end
end

local function hookPathfinder()
	-- Pathfinder only lets a trip walk within one "piece" of the map, and takes the player's piece from the single
	-- nearest map node. When that node is a stray fragment, walking is ruled out and the plan starts with a flight
	-- (a route "to the flight master" 20 yards off for an NPC 4 yards away). For a target this near, walk.
	local originalTrip = PF.PlanTrip
	if originalTrip then
		PF.PlanTrip = function(px, py, ...)
			local r = originalTrip(px, py, ...)
			local trip, g, pl = PF.trip, PF.goal, PF.player
			local leg = trip and trip.next
			-- 400 yards: a flight never beats walking to somewhere this near
			if target and leg and leg.kind == "flight" and g and pl and px and g.instance == pl.instance
				and dist(px, py, g.x, g.y) < 400 then
				PF.trip, PF.riding = nil, nil
				PF.dest = { instance = g.instance, x = g.x, y = g.y, z = g.z }
			end
			return r
		end
	end
	local original = PF.GetTarget
	PF.GetTarget = function(...)
		if target and not PF.service and not UnitIsGhost("player") then
			-- the marker was taken away (the game clears a reached waypoint, another addon removed it): put it
			-- back. A pin the player placed themselves is theirs: Pathfinder stands back until it is gone.
			local hasPin = C_Map.HasUserWaypoint and C_Map.HasUserWaypoint()
			if not cfg("usePin") then
				-- your pin is never touched
			elseif not hasPin and PF.Marker and PF.Marker.ResetOverride then
				PF.Marker.ResetOverride()
				pinNoted = nil
			elseif hasPin and not (PF.Marker and PF.Marker.IsActive()) and not pinNoted then
				pinNoted = true
				Print("you placed a map pin, so it stays: the dots pause until you remove it (|cffffff00/pathy pin|r goes there instead)")
			end
			if target.guid and GetTime() - (target.checked or 0) > 0.2 then
				target.checked = GetTime()
				local u = unitByGuid(target.guid)
				local x, y, inst
				if u then x, y, inst = unitWorldPos(u) end
				if x and (inst ~= target.instance or dist(x, y, target.x, target.y) > FOLLOW_MOVE) then
					target.x, target.y, target.instance, target.z = x, y, inst, nil
				end
			end
			rerouteFromHere()
			PF.targetSource, PF.checkNote = "pathy", nil
			return target.x, target.y, target.instance, target.z
		end
		return original(...)
	end
end

-- The game clears a waypoint marker you walk up to ("destination reached"), which would take the marker,
-- and with it the dots, away at the last corner. While Pathy guides, the marker stays.
local function hookDestinationReached()
	if not SuperTrackedFrame or not SuperTrackedFrame.OnDestinationReached or SuperTrackedFrame.pathyHooked then return end
	SuperTrackedFrame.pathyHooked = true
	local original = SuperTrackedFrame.OnDestinationReached
	SuperTrackedFrame.OnDestinationReached = function(self, ...)
		if target and PF.Marker and PF.Marker.IsActive and PF.Marker.IsActive() then return end
		return original(self, ...)
	end
end

------------------------------------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------------------------
-- Walked paths: where you walk is remembered, and used to build routes
------------------------------------------------------------------------------------------------------------
-- PathyDB.walk[continent] = { [cell] = { x, y, neighbour cell, neighbour cell, ... } }: a spot every CELL yards
-- you walked through, joined to the spot you came from. Used when Pathfinder has no walkable route (it points
-- straight), and also when it has one, if the way you have walked is not much longer: you know it walks.
local Walked = {}
do
local CELL, OFF, ROW = 1, 20000, 40000 -- yards per remembered spot; cell numbers are offset to stay positive
local TILE = 128 -- cells per saved tile
local LINK_MAX = 45 -- yards: a bigger jump (a teleport, a loading screen) is not a walked link
local SNAP_START, SNAP_GOAL = 6, 20 -- yards from a walked line you may be; from a walked spot the goal should be
local OFFWALK = 2 -- ground nobody has walked counts this many times its length against a route
local TICK = 0.15 -- seconds: running is about 7 yd/s, so a spot about every yard
local SAVE_EVERY = 20 -- seconds between packing the changed tiles for the save file
local floor, max, min = math.floor, math.max, math.min
local byte, concat = string.byte, table.concat

-- Storage ------------------------------------------------------------------------------------------------
-- In memory: nodes[continent][cell] = { neighbouring cell, ... } (a spot is the middle of its 1-yard cell).
-- On disk, in PathyDB.walk2[continent][tile]: one packed text per 128 x 128 yard tile, so the save file holds a
-- few thousand strings however many spots there are (a table per spot would pass the 262,144 constants one
-- script may have, and the game would then not load the whole file). A record is 6 characters for the cell,
-- 1 for how many links go to a higher cell, and 3 for each of those links (their offset). No limit on spots.
local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local CH, DEC = {}, {}
for i = 1, 64 do
	local c = ALPHA:sub(i, i)
	CH[i - 1] = c
	DEC[byte(c)] = i - 1
end
local function enc6(n)
	local f = n % 64; n = floor(n / 64)
	local e = n % 64; n = floor(n / 64)
	local d = n % 64; n = floor(n / 64)
	local c = n % 64; n = floor(n / 64)
	local b = n % 64; n = floor(n / 64)
	return CH[n % 64] .. CH[b] .. CH[c] .. CH[d] .. CH[e] .. CH[f]
end
local function enc3(n)
	local c = n % 64; n = floor(n / 64)
	local b = n % 64; n = floor(n / 64)
	return CH[n % 64] .. CH[b] .. CH[c]
end
local function dec(s, i, w)
	local n = 0
	for j = i, i + w - 1 do n = n * 64 + DEC[byte(s, j)] end
	return n
end

local function keyOf(x, y) return (floor(x / CELL) + OFF) * ROW + floor(y / CELL) + OFF end
local function posOf(k) return (floor(k / ROW) - OFF + 0.5) * CELL, (k % ROW - OFF + 0.5) * CELL end
local function tileOf(k) return floor(floor(k / ROW) / TILE) * 1000 + floor((k % ROW) / TILE) end

local nodes, tiles, dirty = {}, {}, {} -- per continent
local anyDirty, total = false, 0
local loader, loaded, loadFailed, legacy
local lastSave = 0
local last = { t = 0 }
local st = { at = -10 }
local job -- the search under way

local function nodesFor(inst)
	local t = nodes[inst]
	if not t then
		t = {}
		nodes[inst], tiles[inst], dirty[inst] = t, {}, {}
	end
	return t
end

local function addNode(inst, k)
	local t = nodesFor(inst)
	local n = t[k]
	if n then return n end
	n = {}
	t[k] = n
	local id = tileOf(k)
	local set = tiles[inst][id]
	if not set then set = {}; tiles[inst][id] = set end
	set[k] = true
	total = total + 1
	return n, true
end

local function markDirty(inst, k)
	dirty[inst][tileOf(k)] = true
	anyDirty = true
end

local function link(inst, a, b, quiet)
	local t = nodes[inst]
	local na, nb = t[a], t[b]
	for i = 1, #na do
		if na[i] == b then return end
	end
	na[#na + 1] = b
	nb[#nb + 1] = a
	if not quiet then markDirty(inst, min(a, b)) end -- a link is saved with its lower spot's tile
end

local function packTile(inst, id)
	local t, set = nodes[inst], tiles[inst][id]
	local out, n = {}, 0
	for k in pairs(set) do
		local cx, cy = floor(k / ROW), k % ROW
		local up, nb = {}, t[k]
		for i = 1, #nb do
			local o = nb[i]
			if o > k and #up < 63 then
				local dx, dy = floor(o / ROW) - cx, o % ROW - cy
				if dx >= -63 and dx <= 63 and dy >= -63 and dy <= 63 then up[#up + 1] = enc3((dx + 64) * 128 + (dy + 64)) end
			end
		end
		n = n + 1
		out[n] = enc6(k) .. CH[#up] .. concat(up)
	end
	return concat(out)
end

-- Packs the changed tiles into PathyDB (what the game writes at a reload or logout); true when none are left
local function saveSome(budgetMs)
	local t0 = debugprofilestop()
	local w = PathyDB.walk2
	if not w then w = {}; PathyDB.walk2 = w end
	for inst, ds in pairs(dirty) do
		for id in pairs(ds) do
			local si = w[inst]
			if not si then si = {}; w[inst] = si end
			local set = tiles[inst][id]
			si[id] = set and next(set) and packTile(inst, id) or nil
			ds[id] = nil
			if budgetMs and debugprofilestop() - t0 > budgetMs then return false end
		end
	end
	anyDirty = false
	if legacy and PathyDB.walk then PathyDB.walk = nil end -- the older format, now saved in the new one
	return true
end

-- Reading what is saved: the older format first (converted), then the packed tiles. A few thousand records a
-- step, so a lot of saved spots do not freeze the game at login.
local function loadAll()
	local count = 0
	local old = PathyDB.walk
	if old then
		legacy = true
		for inst, t in pairs(old) do
			local map = {}
			for k, nd in pairs(t) do
				local nk = keyOf(nd[1], nd[2])
				map[k] = nk
				addNode(inst, nk)
				markDirty(inst, nk)
				count = count + 1
				if count % 3000 == 0 then coroutine.yield() end
			end
			for k, nd in pairs(t) do
				local a = map[k]
				for i = 3, #nd do
					local b = map[nd[i]]
					if b and b ~= a then link(inst, a, b) end
				end
				count = count + 1
				if count % 3000 == 0 then coroutine.yield() end
			end
		end
	end
	local w = PathyDB.walk2
	if w then
		for inst, tl in pairs(w) do
			for _, s in pairs(tl) do
				local i, len = 1, #s
				while i <= len do
					local k, c = dec(s, i, 6), dec(s, i + 6, 1)
					i = i + 7
					addNode(inst, k)
					local cx, cy = floor(k / ROW), k % ROW
					for _ = 1, c do
						local code = dec(s, i, 3)
						i = i + 3
						local o = (cx + floor(code / 128) - 64) * ROW + cy + code % 128 - 64
						addNode(inst, o)
						link(inst, k, o, true)
					end
					count = count + 1
					if count % 3000 == 0 then coroutine.yield() end
				end
			end
		end
	end
end

local function failed(err)
	loader, loadFailed = nil, true
	Print("|cffff4040could not read the saved walked spots (" .. tostring(err) .. "): they stay as they are on disk, and nothing new is saved this session|r")
end

local function stepLoad()
	local t0 = debugprofilestop()
	while loader do
		local ok, err = coroutine.resume(loader)
		if not ok then return failed(err) end
		if coroutine.status(loader) == "dead" then
			loader, loaded = nil, true
			return
		end
		if debugprofilestop() - t0 > 5 then return end
	end
end

-- Recording ----------------------------------------------------------------------------------------------
-- one step of someone's walk (l holds their last spot): the spot, joined to the one before it
local function feed(l, px, py, instance, now)
	local key = keyOf(px, py)
	if l.key == key and l.instance == instance then l.t = now return end
	local jumped = not l.key or l.instance ~= instance or now - l.t > 5 or dist(px, py, l.x, l.y) > LINK_MAX
	local _, new = addNode(instance, key)
	if new then markDirty(instance, key) end
	if not jumped then link(instance, l.key, key) end
	l.key, l.instance, l.x, l.y, l.t = key, instance, px, py, now
end

local function record(now)
	if not cfg("recordWalk") or UnitOnTaxi("player") or UnitIsDeadOrGhost("player")
		or (IsFlying and IsFlying()) or (IsSwimming and IsSwimming()) or (IsFalling and IsFalling())
		or (reroute.b and reroute.b.on) then
		last.key = nil
		return
	end
	local px, py, instance = HBD():GetPlayerWorldPosition()
	if not px or not instance then last.key = nil return end
	feed(last, px, py, instance, now)
end

-- Other players: only where they are, never who. The game gives a position only for your own group (party or
-- raid); strangers' positions are not available to addons. What is kept per member (just to join one step to the
-- next) is thrown away at once when the group changes and never saved: no name, no id, only the spots.
local others = {}
local function recordOthers(now)
	if not cfg("recordOthers") then return end
	local raid = IsInRaid and IsInRaid()
	local n = raid and GetNumGroupMembers() or (GetNumSubgroupMembers and GetNumSubgroupMembers()) or 0
	for i = 1, n do
		local unit = (raid and "raid" or "party") .. i
		local o = others[unit]
		if not o then o = {}; others[unit] = o end
		if UnitExists(unit) and not UnitIsUnit(unit, "player") and UnitIsPlayer(unit) and UnitIsConnected(unit)
			and not UnitIsDeadOrGhost(unit) and not UnitOnTaxi(unit) and not (UnitInVehicle and UnitInVehicle(unit)) then
			local x, y, inst = unitWorldPos(unit)
			if x and inst then feed(o, x, y, inst, now) else o.key = nil end
		else
			o.key = nil
		end
	end
end

local roster = CreateFrame("Frame")
roster:RegisterEvent("GROUP_ROSTER_UPDATE")
roster:SetScript("OnEvent", function() others = {} end) -- a slot may hold someone else now: no joining across

-- Routes -------------------------------------------------------------------------------------------------
-- every remembered spot within maxD yards: { { cell, distance }, ... }
local function around(t, x, y, maxD)
	local r = math.ceil(maxD / CELL) + 1
	local cx, cy = floor(x / CELL) + OFF, floor(y / CELL) + OFF
	local out = {}
	for dx = -r, r do
		local base = (cx + dx) * ROW + cy
		for dy = -r, r do
			local k = base + dy
			if t[k] then
				local nx, ny = posOf(k)
				local d = dist(x, y, nx, ny)
				if d <= maxD then out[#out + 1] = { k, d } end
			end
		end
	end
	return out
end

local function nearest(t, x, y, maxD)
	local best, bd
	for _, s in ipairs(around(t, x, y, maxD)) do
		if not bd or s[2] < bd then best, bd = s[1], s[2] end
	end
	return best, bd
end

-- Where you could step onto the walked lines: the closest point of every walked line (and every spot) within
-- maxD yards of you. Each is { spot to go on to, yards to get there (via that point), the point's x, y }. Stepping
-- sideways onto a line you have walked (a few yards) is fine; jumping to a spot further off may cross a wall.
local function startsFor(t, x, y, maxD)
	local out, at = {}, {}
	local function add(k, cost, qx, qy)
		local i = at[k]
		if not i then
			out[#out + 1] = { k, cost, qx, qy }
			at[k] = #out
		elseif cost < out[i][2] then
			out[i] = { k, cost, qx, qy }
		end
	end
	for _, s in ipairs(around(t, x, y, LINK_MAX + maxD)) do
		local u = s[1]
		local ux, uy = posOf(u)
		if s[2] <= maxD then add(u, s[2], ux, uy) end
		local nu = t[u]
		for i = 1, #nu do
			local v = nu[i]
			local vx, vy = posOf(v)
			local dx, dy = vx - ux, vy - uy
			local len2 = dx * dx + dy * dy
			local f = len2 > 1e-9 and max(0, min(1, ((x - ux) * dx + (y - uy) * dy) / len2)) or 0
			local qx, qy = ux + dx * f, uy + dy * f
			local d = dist(x, y, qx, qy)
			if d <= maxD then
				add(u, d + dist(qx, qy, ux, uy), qx, qy)
				add(v, d + dist(qx, qy, vx, vy), qx, qy)
			end
		end
	end
	return out
end

-- A* over the walked lines from the places you can step onto them. Any spot may be where the walking ends: the
-- rest of the way to the goal counts OFFWALK times its length, so the route follows your lines as far as that
-- pays and goes straight only for what nobody has walked. Returns the spots, and the start's
-- { spot, cost, x, y } (the point on the line you step onto).
local function search(t, starts, gx, gy)
	local g, from, closed, startAt = {}, {}, {}, {}
	local hf, hk, hn = {}, {}, 0
	local function push(f, k)
		hn = hn + 1
		local i = hn
		while i > 1 do
			local p = floor(i / 2)
			if hf[p] <= f then break end
			hf[i], hk[i] = hf[p], hk[p]
			i = p
		end
		hf[i], hk[i] = f, k
	end
	local function pop()
		local f, k = hf[1], hk[1]
		local lf, lk = hf[hn], hk[hn]
		hf[hn], hk[hn] = nil, nil
		hn = hn - 1
		if hn > 0 then
			local i = 1
			while true do
				local c = i * 2
				if c > hn then break end
				if c < hn and hf[c + 1] < hf[c] then c = c + 1 end
				if hf[c] >= lf then break end
				hf[i], hk[i] = hf[c], hk[c]
				i = c
			end
			hf[i], hk[i] = lf, lk
		end
		return f, k
	end
	for _, s in ipairs(starts) do
		local k, d = s[1], s[2]
		startAt[k] = s
		g[k] = d
		local x, y = posOf(k)
		push(d + dist(x, y, gx, gy), k)
	end
	local best, bestNode, expanded = nil, nil, 0
	while hn > 0 do
		local f, u = pop()
		if best and f >= best then break end
		if not closed[u] then
			closed[u] = true
			expanded = expanded + 1
			if expanded % 500 == 0 then coroutine.yield() end -- the caller carries on over the next frames
			if expanded > 400000 then break end -- the best so far is used
			local ux, uy = posOf(u)
			local whole = g[u] + OFFWALK * dist(ux, uy, gx, gy)
			if not best or whole < best then best, bestNode = whole, u end
			local nu = t[u]
			for i = 1, #nu do
				local v = nu[i]
				if t[v] and not closed[v] then
					local vx, vy = posOf(v)
					local ng = g[u] + dist(ux, uy, vx, vy)
					if not g[v] or ng < g[v] then
						g[v], from[v] = ng, u
						push(ng + dist(vx, vy, gx, gy), v)
					end
				end
			end
		end
	end
	if not bestNode then return nil end
	local path, n, k = {}, 0, bestNode
	while k do n = n + 1; path[n] = k; k = from[k] end
	for i = 1, floor(n / 2) do path[i], path[n + 1 - i] = path[n + 1 - i], path[i] end
	return path, startAt[path[1]]
end

-- Douglas-Peucker: drops only corners within tol yards of the line between their neighbours
local function simplify(xs, ys, tol)
	local n = #xs
	local keep = { [1] = true, [n] = true }
	local stack, sp = { 1, n }, 2
	while sp > 0 do
		local j, i = stack[sp], stack[sp - 1]
		sp = sp - 2
		local ax, ay, bx, by = xs[i], ys[i], xs[j], ys[j]
		local dx, dy = bx - ax, by - ay
		local len2 = dx * dx + dy * dy
		local bestD, bestK = 0, nil
		for k = i + 1, j - 1 do
			local d
			if len2 < 1e-9 then
				d = dist(xs[k], ys[k], ax, ay)
			else
				local f = max(0, min(1, ((xs[k] - ax) * dx + (ys[k] - ay) * dy) / len2))
				d = dist(xs[k], ys[k], ax + dx * f, ay + dy * f)
			end
			if d > bestD then bestD, bestK = d, k end
		end
		if bestK and bestD > tol then
			keep[bestK] = true
			stack[sp + 1], stack[sp + 2], stack[sp + 3], stack[sp + 4] = i, bestK, bestK, j
			sp = sp + 4
		end
	end
	local ox, oy = {}, {}
	for i = 1, n do
		if keep[i] then ox[#ox + 1], oy[#oy + 1] = xs[i], ys[i] end
	end
	return ox, oy
end

-- Straight lines are questioned. One is possible, but in a city (buildings, walls, stairs) it is unlikely, so a
-- straight route there is never trusted just because it is perfect.
local CITY_MAPS = { [1453] = true, [1455] = true, [1458] = true, [1454] = true, [1456] = true, [1457] = true }
local cityAt, cityIs = -10, false
local function inCity()
	local now = GetTime()
	if now - cityAt < 2 then return cityIs end
	cityAt, cityIs = now, false
	local m, guard = C_Map.GetBestMapForUnit("player"), 0
	while m and m > 0 and guard < 8 do
		if CITY_MAPS[m] then cityIs = true break end
		local info = C_Map.GetMapInfo(m)
		m, guard = info and info.parentMapID, guard + 1
	end
	if not cityIs and IsResting and IsResting() then cityIs = true end
	return cityIs
end

-- A route that is a straight line, or a walkable route that is (almost) one: within 3% of the straight distance
-- (10% in a city), for targets more than 15 yards away
local function nearStraight(p, px, py, d)
	if not p or p.walked then return false end
	if not p.graph then return true end
	local straight = dist(px, py, d.x, d.y)
	return straight > 15 and p.remaining ~= nil and p.remaining <= straight * (inCity() and 1.10 or 1.03) + 3
end

-- The search is done: use its route, or say why not
local function finish(j, ids, first)
	local p, d, px, py = PF.path, j.d, j.px, j.py
	if not target or st.key ~= j.key then return end -- the goal changed meanwhile
	local own = p and p == st.path
	if not ids then
		st.rejected = p
		st.why = "no walked line to follow from where you stand"
		return
	end
	local xs, ys = { px }, { py }
	if first and dist(px, py, first[3], first[4]) > 1 then xs[2], ys[2] = first[3], first[4] end -- step onto the line
	for _, k in ipairs(ids) do
		local x, y = posOf(k)
		xs[#xs + 1], ys[#ys + 1] = x, y
	end
	local tail = dist(xs[#xs], ys[#ys], d.x, d.y) -- the straight part at the end: ground nobody has walked
	xs[#xs + 1], ys[#ys + 1] = d.x, d.y
	xs, ys = simplify(xs, ys, 0.5) -- every real bend stays: the route is as granular as your walking was
	local L = 0
	for i = 2, #xs do L = L + dist(xs[i - 1], ys[i - 1], xs[i], ys[i]) end
	local straight = dist(px, py, d.x, d.y)
	-- the route already on screen is only replaced by a clearly shorter one (or when you have strayed from it)
	if own and (p.off or 0) < 15 and L > (p.remaining or math.huge) - 8 then st.why = "keeping the walked route in use" return end
	local use
	if p and p.graph then
		-- Pathfinder has a real route: walked beats it only when about as short and it ends where you have walked.
		-- A near-perfect straight one in a city is doubted: a longer walked route (that you know walks) wins.
		if nearStraight(p, px, py, d) and inCity() then
			use = tail <= SNAP_GOAL and L <= straight * 2.5 + 40
		else
			use = tail <= SNAP_GOAL and L <= (p.remaining or math.huge) * 1.25
		end
	else
		-- a straight line says nothing: take the walked route when it gets you clearly nearer, without absurd detours
		use = L - tail > 10 and tail < straight - 10 and L <= straight * 3 + 60
	end
	if not use then
		st.rejected = p
		st.why = format("walked route of %d yd, then %d yd of ground nobody has walked, is no better than %s", L - tail, tail,
			p and p.graph and format("Pathfinder's %d yd", p.remaining or 0) or "the straight line")
		return
	end
	PF.SetPath({ x = xs, y = ys, n = #xs, walked = true, tail = tail }, false)
	st.path = PF.path
	st.why = tail > SNAP_GOAL and format("using %d yd of your walked route, then %d yd straight (nothing walked near the destination)", L - tail, tail)
		or format("using your walked route (%d yd)", L)
end

-- A few milliseconds of the search each frame
local function step()
	if not job then return end
	local t0 = debugprofilestop()
	while true do
		local ok, a, b = coroutine.resume(job.co)
		if not ok then
			job = nil
			error(a)
		end
		if coroutine.status(job.co) == "dead" then
			local j = job
			job = nil
			return finish(j, a, b)
		end
		if debugprofilestop() - t0 > 4 then return end
	end
end

local function consider(now)
	if job or not target or not cfg("useWalked") then return end
	if not loaded then st.why = "still reading the saved walked spots" return end
	if PF.riding or PF.flying or PF.service or not PF.dest or not PF.player or not PF.player.x then return end
	local px, py, instance = HBD():GetPlayerWorldPosition()
	local d = PF.dest
	if not px or d.instance ~= instance then return end
	local p = PF.path
	local key = instance .. ":" .. floor(d.x) .. ":" .. floor(d.y)
	-- on the walked route: looked at again every few seconds as you move, in case you have come level with a
	-- later part of it (cutting the corner beats walking to the next spot and back)
	local own = p and p == st.path and st.key == key
	if own and (p.off or 0) < 15 and (now - st.at < 3 or dist(px, py, st.ox, st.oy) < 6) then return end
	if p and p == st.rejected and st.key == key and now - st.at < 8 and dist(px, py, st.ox, st.oy) < 15 then return end
	if now - st.at < 1 then return end
	st.at, st.key, st.ox, st.oy, st.rejected = now, key, px, py, nil
	local t = nodes[instance]
	if not t then st.why = "nothing remembered on this continent yet" st.rejected = p return end
	local starts = startsFor(t, px, py, SNAP_START)
	if #starts == 0 then
		st.rejected = p
		st.why = "you are more than " .. SNAP_START .. " yd from any line you have walked"
		return
	end
	local gx, gy = d.x, d.y
	st.why = "searching..."
	job = {
		co = coroutine.create(function() return search(t, starts, gx, gy) end),
		key = key, d = { x = gx, y = gy }, px = px, py = py,
	}
end

-- Why the arrow is not following a real route (nil when it is, or when only a short last stretch is straight)
function Walked.warning()
	local p = PF.path
	if not p then return end
	if p.walked then
		if p.tail and p.tail > SNAP_GOAL then
			return format("following your walked route, then a straight line for the last %d yd (nothing walked there)", p.tail)
		end
		return
	end
	if not p.graph then
		return "couldn't find a walkable path, pointing straight at it" .. (st.why and (" (walked data: " .. st.why .. ")") or "")
	end
	-- a walkable route that is a straight line anyway: fine in the open, doubtful in a city
	local px, py = HBD():GetPlayerWorldPosition()
	local d = PF.dest
	if px and d and nearStraight(p, px, py, d) and inCity() then
		return "this route is a straight line, which is unlikely in a city: it may cut through buildings" .. (st.why and (" (walked data: " .. st.why .. ")") or "")
	end
end

-- What /pathy walked says about the current trip
function Walked.explain()
	local out = {}
	local areas = 0
	for _, t in pairs(nodes) do
		if next(t) then areas = areas + 1 end
	end
	out[1] = format("%d spots remembered on %d continents%s; recording %s, routing %s; last spot saved %s",
		total, areas, loaded and "" or " so far (still reading the saved ones)", cfg("recordWalk") and "on" or "OFF", cfg("useWalked") and "on" or "OFF",
		last.key and format("%.0f s ago", GetTime() - last.t) or "never this session (or not moving right now)")
	if loadFailed then out[#out + 1] = "the saved spots could not be read: nothing new is saved" end
	if Walked.err then out[#out + 1] = "error: " .. tostring(Walked.err) end
	if not target then out[#out + 1] = "not guiding anywhere, so nothing to route"; return out end
	local px, py, instance = HBD():GetPlayerWorldPosition()
	local d = PF.dest
	if not px or not d then out[#out + 1] = "no position or no destination yet"; return out end
	if d.instance ~= instance then out[#out + 1] = "the destination is on another continent"; return out end
	local mine = nodes[instance]
	if not mine then out[#out + 1] = "nothing remembered on this continent yet"; return out end
	local _, a = nearest(mine, px, py, 150)
	local _, b = nearest(mine, d.x, d.y, 150)
	out[#out + 1] = format("nearest remembered spot to you: %s (needs %d yd or less); to the destination: %s (ground further than %d yd from one is crossed in a straight line)",
		a and format("%.0f yd", a) or "over 150 yd", SNAP_START, b and format("%.0f yd", b) or "over 150 yd", SNAP_GOAL)
	out[#out + 1] = "last decision: " .. (st.why or "none yet") .. "; route in use: " .. (PF.path and (PF.path.walked and "walked" or PF.path.graph and "Pathfinder's" or "straight line") or "none")
	return out
end

local function report(err)
	if not Walked.err then
		Walked.err = err
		Print("|cffff4040walked-path error:|r " .. tostring(err))
	end
end

local acc = 0
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt)
	if not PathyDB then return end
	if not loaded and not loader and not loadFailed then loader = coroutine.create(loadAll) end
	if loader then
		local ok, err = pcall(stepLoad)
		if not ok then report(err) end
	end
	if job then
		local ok, err = pcall(step)
		if not ok then report(err) end
	end
	if loaded and anyDirty and GetTime() - lastSave >= SAVE_EVERY then
		local ok, done = pcall(saveSome, 3)
		if not ok then report(done) elseif done then lastSave = GetTime() end
	end
	acc = acc + dt
	if acc < TICK or not HBD() then return end
	acc = 0
	local now = GetTime()
	local ok, err = pcall(record, now)
	if ok then ok, err = pcall(recordOthers, now) end
	if ok then ok, err = pcall(consider, now) end
	if not ok then report(err) end
end)

-- Before the game writes the save file (a reload or logout): everything changed goes in
local flush = CreateFrame("Frame")
flush:RegisterEvent("PLAYER_LOGOUT")
flush:SetScript("OnEvent", function()
	if not PathyDB or loadFailed then return end
	while loader do -- the saved spots are read first, so what is written has all of them
		local ok = coroutine.resume(loader)
		if not ok then loader, loadFailed = nil, true return end
		if coroutine.status(loader) == "dead" then loader, loaded = nil, true end
	end
	if loaded and anyDirty then pcall(saveSome) end
end)

function Walked.stats()
	local areas = 0
	for _, t in pairs(nodes) do
		if next(t) then areas = areas + 1 end
	end
	return total, areas
end

-- A small window (draggable) showing the remembered spots within RADIUS yards of you, north up, you in the middle:
-- gold where a spot is joined to others, red where it stands alone. For checking what has really been recorded.
local RADIUS, SCALE = 25, 4 -- yards shown, pixels per yard
local radar
local function updateRadar(r)
	local px, py, instance = HBD():GetPlayerWorldPosition()
	local t = px and nodes[instance]
	local list = t and around(t, px, py, RADIUS) or {}
	r.text:SetText(format("walked spots within %d yd: %d%s", RADIUS, #list, px and "" or " (no position here)"))
	for i, s in ipairs(list) do
		local dot = r.dots[i]
		if not dot then
			dot = r.field:CreateTexture(nil, "ARTWORK")
			dot:SetSize(2, 2)
			r.dots[i] = dot
		end
		local nx, ny = posOf(s[1])
		if #t[s[1]] > 0 then dot:SetColorTexture(1, 0.82, 0, 1) else dot:SetColorTexture(1, 0.2, 0.2, 1) end
		dot:ClearAllPoints()
		dot:SetPoint("CENTER", r.field, "CENTER", -(nx - px) * SCALE, (ny - py) * SCALE) -- world x runs west
		dot:Show()
	end
	for i = #list + 1, #r.dots do r.dots[i]:Hide() end
end

function Walked.radarShown() return radar and radar:IsShown() or false end

function Walked.radar()
	if not radar then
		local r = CreateFrame("Frame", "PathyWalkedRadar", UIParent, "BackdropTemplate")
		r:SetSize(RADIUS * 2 * SCALE + 8, RADIUS * 2 * SCALE + 26)
		r:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
		r:SetFrameStrata("MEDIUM")
		r:SetToplevel(true)
		r:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
		r:SetBackdropColor(0, 0, 0, 0.6)
		r:SetBackdropBorderColor(1, 1, 1, 0.5)
		r:SetMovable(true)
		r:EnableMouse(true)
		r:RegisterForDrag("LeftButton")
		r:SetScript("OnDragStart", r.StartMoving)
		r:SetScript("OnDragStop", r.StopMovingOrSizing)
		r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.text:SetPoint("TOP", 0, -6)
		r.field = CreateFrame("Frame", nil, r)
		r.field:SetPoint("TOPLEFT", 4, -22)
		r.field:SetSize(RADIUS * 2 * SCALE, RADIUS * 2 * SCALE)
		r.me = r.field:CreateTexture(nil, "OVERLAY")
		r.me:SetColorTexture(0.3, 1, 0.3, 1)
		r.me:SetSize(7, 7)
		r.me:SetPoint("CENTER")
		r.dots, r.since = {}, 0
		r:SetScript("OnUpdate", function(self, dt)
			self.since = self.since + dt
			if self.since < 0.3 then return end
			self.since = 0
			if PathyDB and HBD() then pcall(updateRadar, self) end
		end)
		radar = r
	end
	if radar:IsShown() then radar:Hide() else radar:Show() end
	return radar:IsShown()
end

function Walked.clear()
	nodes, tiles, dirty, total, anyDirty = {}, {}, {}, 0, false
	PathyDB.walk, PathyDB.walk2, PathyDB.walkCell = nil, nil, nil
	last.key, job = nil, nil
	st.path, st.rejected, st.key = nil, nil, nil
end
end -- walked paths

-- While guiding but with nothing to walk right now: why, and the trip's next step when Pathfinder has one.
local function noRouteText()
	if not target then return end
	if PF.trip and PF.trip.next and PF.TripText then
		local ok, txt = pcall(PF.TripText, PF.trip)
		if ok and txt then return "next: " .. txt end
	end
	if PF.flying then return "on a flight: the route goes on when you land" end
	if PF.riding then return "on the way: the route goes on when you arrive" end
	if not PF.path then
		local _, _, instance = HBD():GetPlayerWorldPosition()
		if target.instance and instance and target.instance ~= instance then
			return "the target is on another continent, and no boat or zeppelin you can take goes there"
		end
		return "no walking route from here yet"
	end
	-- a route exists but it is only the straight line: the walk graph found no way there (or has no data here)
	local warn = Walked.warning()
	if warn then return warn end
	if PF.path.walked then return "following a route you have walked before" end
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
	f:SetBackdropColor(0.05, 0.05, 0.08, cfg("windowAlpha"))
	f:SetBackdropBorderColor(1, 1, 1, cfg("windowAlpha"))
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

-- The debug view: a clickable icon in the header that shows or hides the walked-spots window
local debugBtn = CreateFrame("Button", nil, content)
debugBtn:SetSize(20, 20)
debugBtn:SetPoint("TOPRIGHT", -36, -8)
debugBtn.icon = debugBtn:CreateTexture(nil, "ARTWORK")
debugBtn.icon:SetAllPoints()
debugBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_02")
debugBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
local function paintDebug() debugBtn.icon:SetAlpha(Walked.radarShown() and 1 or 0.45) end
debugBtn:SetScript("OnClick", function() Walked.radar(); paintDebug() end)
debugBtn:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:SetText("Debug view")
	GameTooltip:AddLine("Shows or hides the spots you have walked near you", 1, 1, 1, true)
	GameTooltip:Show()
end)
debugBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
paintDebug()

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
			inGroup[name] = true
			local x, y, inst = unitWorldPos(u)
			local d = x and px and inst == instance and dist(px, py, x, y)
			local _, class = UnitClass(u)
			local cname = CLASS_NAMES[class or ""]
			group[#group + 1] = { top = name, icon = cname and ("Interface\\Icons\\ClassIcon_" .. cname:gsub(" ", "")) or ICONS.group,
				sub = (not UnitIsConnected(u) and "offline") or (d and yards(d)) or (x and "other continent") or "no position (in a dungeon?)",
				action = function() goUnit(guid, name) end, key = "unit:" .. guid, d = d or 1e9 }
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
-- Pathy's own ground dots and 3D arrow, drawn with the game's camera.
--
-- Addons are not told where the camera is, but the game does put one point of ours on screen: Pathfinder's
-- in-world marker. Knowing where that marker is in the world, where the player stands and how far out the
-- camera is zoomed, the camera's turn (yaw) and tilt (pitch) are solved so the marker lands exactly where the
-- game drew it (the same idea Pathfinder's own dots use). On top of that:
--  * the camera is steadied: the game may place the marker a frame behind the player's position, so the fit
--    is tried with this frame's and last frame's position and the one that agrees with the camera so far
--    wins; it is then lightly smoothed (/pathy smooth);
--  * the dots sit at fixed spots along the route (counted back from the route's end, which does not move), so
--    they stay still in the world: the ones you reach fade under your feet, new ones come into range ahead;
--  * the arrow points, in 3D, from the player's feet to the average of the next 8 dots, at the exact angle
--    across and up/down, drawn the way the game camera sees that direction.
------------------------------------------------------------------------------------------------------------

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local sin, cos, tan, abs, max, min, rad, pi = math.sin, math.cos, math.tan, math.abs, math.max, math.min, math.rad, math.pi
local TWO_PI = 2 * pi

local DOT_TEX = "Interface\\AddOns\\Guidelime_Pathfinder\\Media\\dot" -- Pathfinder's dot image
local DOT_COLOUR = { 0.62, 1, 0.25 }
local MAX_DOTS = 48

local LOOKAHEAD = 40 -- yards: the arrow points at the average of the route this far ahead (a setting; this is the fallback)
local VFOV_PER_FOV = 0.6   -- the game's vertical field of view is 0.6 x the cameraFov setting
local MIN_MARKER = 6       -- yards: a marker nearer than this is too close to solve the camera against
local BELOW_COST, FLOOR_SLACK = 4, 0.5
local KEEP_CAMERA = 0.75   -- seconds a solved camera is carried on (turned with you) for the arrow
local FRESH = 0.1          -- seconds the dots keep using a camera without a new solve
local SNAP = 0.035         -- radians (about 2 degrees): a camera change this big is a real move, not noise
local RECENT = 10          -- seconds a learned camera turn and tilt are still used with nothing to line up with
local CLIMB = 2.5          -- yards the next dots rise or fall before it says "up" / "down"
local TURN_RATE = 6        -- how fast the arrow catches up with the direction (higher = snappier)

local function dotSpacing() return cfg("dotSpacing") end

-- The fixed dot spot at or just behind the player on route p: a stand-in for p that starts there (seg, segT),
-- the spot itself, and how far behind the player it is (yards along the route).
local function anchor(p, spacing)
	local len = p.len
	if not len or not p.seg or not len[p.n] then return end
	local i = p.seg
	local segL = (len[i + 1] or len[i]) - len[i]
	local s = len[i] + (p.segT or 0) * segL -- the player's spot, yards from the route's start
	local total = len[p.n]
	local base = total - math.ceil((total - s) / spacing - 1e-6) * spacing
	if base < 0 then base = 0 end
	local j = i
	while j > 1 and len[j] > base do j = j - 1 end
	while j < p.n - 1 and len[j + 1] <= base do j = j + 1 end
	local L = len[j + 1] - len[j]
	local t = L > 0 and (base - len[j]) / L or 0
	local view = setmetatable({ seg = j, segT = t }, { __index = p })
	local x, y = PF.PointOnSeg(p, j, t)
	return view, x, y, s - base, base, total
end

-- The camera. World axes: E = east (= -x in HereBeDragons' coordinates), N = north (= y), U = up (= z).
local fx, fy, fz, rx, ry, ux, uy, uz, Cx, Cy, Cz, focal, scx, scy

local function setCamera(yaw, pitch, F1, F2, F3, d)
	local cyw, syw, cp, sp = cos(yaw), sin(yaw), cos(pitch), sin(pitch)
	fx, fy, fz = -syw * cp, cyw * cp, -sp
	rx, ry = cyw, syw
	ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
	Cx, Cy, Cz = F1 - d * fx, F2 - d * fy, F3 - d * fz
end

-- screen spot (UIParent units from the bottom left), distance along the view, and how steeply it is seen
local function project(E, N, U)
	local vx, vy, vz = E - Cx, N - Cy, U - Cz
	local cf = vx * fx + vy * fy + vz * fz
	if cf < 0.3 then return end
	local cr = vx * rx + vy * ry
	local cu = vx * ux + vy * uy + vz * uz
	return scx + focal * cr / cf, scy + focal * cu / cf, cf, vz / sqrt(vx * vx + vy * vy + vz * vz)
end

local function wrap(a) return (a + pi) % TWO_PI - pi end

-- Gauss-Newton on yaw and pitch: the camera that puts world point m on screen at (ox, oy).
local function solve2(a, b, F, d, ox, oy, m)
	local function res(p, q)
		setCamera(p, q, F[1], F[2], F[3], d)
		local sx, sy = project(m[1], m[2], m[3])
		if sx then return sx - ox, sy - oy end
	end
	for _ = 1, 14 do
		local r1, r2 = res(a, b)
		if not r1 then return end
		if r1 * r1 + r2 * r2 < 1e-4 then return a, b end -- to a hundredth of a pixel: a loose fit wobbles
		local e = 1e-3
		local a1, a2 = res(a + e, b)
		local b1, b2 = res(a, b + e)
		if not a1 or not b1 then return end
		local j11, j21, j12, j22 = (a1 - r1) / e, (a2 - r2) / e, (b1 - r1) / e, (b2 - r2) / e
		local det = j11 * j22 - j12 * j21
		if abs(det) < 1e-9 then return end
		local da = -(j22 * r1 - j12 * r2) / det
		local db = -(-j21 * r1 + j11 * r2) / det
		local s = max(abs(da), abs(db))
		if s > 0.4 then da, db = da * 0.4 / s, db * 0.4 / s end
		a, b = a + da, b + db
	end
	local r1, r2 = res(a, b)
	if r1 and r1 * r1 + r2 * r2 < 9 then return a, b end
end

local cam = {} -- yaw, pitch (steadied), t (when last solved), facing (the player's facing then)

-- Of the cameras that fit, the one that turns least from the camera so far (and from where the character
-- faces), and is not under the floor. A marker nearer than the camera has a mirror fit behind the player.
local function fit(facing, F, d, ox, oy, m, floorZ)
	local best, bestYaw, bestPitch
	local function try(y0, p0)
		local yaw, pitch = solve2(y0, p0, F, d, ox, oy, m)
		if not yaw or abs(pitch) >= 1.55 then return end
		local below = max(0, floorZ - FLOOR_SLACK - (F[3] + d * sin(pitch)))
		local score = 0.5 * abs(wrap(yaw - facing)) + BELOW_COST * below
		if cam.yaw and cam.pitch then score = score + abs(wrap(yaw - cam.yaw)) + abs(pitch - cam.pitch) end
		if not best or score < best then best, bestYaw, bestPitch = score, wrap(yaw), pitch end
	end
	if cam.yaw and cam.pitch then try(cam.yaw, cam.pitch) end
	for _, dy in ipairs({ 0, 0.8, -0.8, pi }) do
		for _, p0 in ipairs({ cam.pitch or 0.3, 0.9, -0.3 }) do try(facing + dy, p0) end
	end
	return bestYaw, bestPitch, best
end

local function cvarFov()
	local v = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("cameraFov") or (GetCVar and GetCVar("cameraFov"))
	return tonumber(v) or 90
end

local last = {}            -- the player's spot last frame
local smoothZ              -- the ground height under the player, steadied (the height map comes in steps)
local pairJump = { 0, 0 }  -- how much each pairing's fit jumps about while moving (running average)
local usePair = 1          -- 1: the marker matches this frame's position, 2: last frame's
-- Solves (or carries on) the camera for this frame and sets it up for project(). Returns true when the
-- camera is known (solved now or lately), false when only guessed from the player's facing.
local function updateCamera(dt, px, py, pz)
	local ui = UIParent:GetEffectiveScale()
	local wf = WorldFrame:GetEffectiveScale()
	local wcx, wcy = WorldFrame:GetCenter()
	local W, H = WorldFrame:GetWidth() * wf / ui, WorldFrame:GetHeight() * wf / ui
	scx, scy = wcx * wf / ui, wcy * wf / ui
	local fov = PF.db.fov
	if fov and fov > 0 then focal = (W / 2) / tan(rad(fov) / 2) else focal = (H / 2) / tan(rad(cvarFov() * VFOV_PER_FOV) / 2) end
	local h = (PF.db.focusHeight or 1.9) + (IsMounted() and 0.9 or 0)
	local d = GetCameraZoom() or 0
	local facing = GetPlayerFacing() or 0
	local now = GetTime()

	-- the camera follows the character's model, which moves smoothly; the height map under it comes in steps
	if not smoothZ or abs(pz - smoothZ) > 3 then smoothZ = pz else smoothZ = smoothZ + (pz - smoothZ) * min(1, dt * 6) end
	local z = smoothZ

	if cam.off then cam.yaw = wrap(facing + cam.off) end

	-- What to line the camera up with: the game's in-world marker for the map pin being tracked, wherever it is.
	-- That is your own pin, left where you put it (or, with "move my map pin" on, the one Pathfinder moves along
	-- the route, with the corner it was at a moment ago).
	local nav = C_Navigation and C_Navigation.GetFrame and C_Navigation.GetFrame()
	local fits = {}
	local marks
	if nav and not (PF.Marker and PF.Marker.probing) and C_Map.HasUserWaypoint and C_Map.HasUserWaypoint()
		and C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint()
		and C_Navigation.HasValidScreenPosition() and not C_Navigation.WasClampedToScreen() then
		if PF.Marker and PF.Marker.IsActive() then
			marks = { PF.Marker.at or false, PF.Marker.before or false }
		else
			local wp = C_Map.GetUserWaypoint()
			if wp and wp.position then
				local mx, my, minst = HBD():GetWorldCoordinatesFromZone(wp.position.x, wp.position.y, wp.uiMapID)
				if mx and minst == PF.player.instance then marks = { { mx, my } } end
			end
		end
	end
	if marks then
		local nx, ny = nav:GetCenter()
		if nx then
			local s = nav:GetEffectiveScale() / ui
			local ox, oy = nx * s, ny * s
			local gd = C_Navigation.GetDistance and C_Navigation.GetDistance()
			local spots = { { px, py, z } }
			if last.x then spots[2] = { last.x, last.y, last.z } end
			for i, spot in ipairs(spots) do
				-- the game may still show the marker at the corner before for a frame: the one at its distance
				for _, at in ipairs(marks) do
					if at then
						local d2 = sqrt((at[1] - spot[1]) ^ 2 + (at[2] - spot[2]) ^ 2)
						if not gd or abs(gd - d2) <= max(1.5, 0.05 * d2) then
							if d2 >= MIN_MARKER then
								-- the game draws a waypoint at the player's own height
								local yaw, pitch = fit(facing, { -spot[1], spot[2], spot[3] + h }, d, ox, oy,
									{ -at[1], at[2], spot[3] }, spot[3])
								if yaw then fits[i] = { yaw, pitch } end
							end
							break
						end
					end
				end
			end
		end
	end
	-- Which position the game's marker goes with (this frame's or last frame's) is a property of the game, not
	-- of the frame: learn it while moving, from which pairing jumps about less, and stick with it. Picking the
	-- better one frame by frame made the dots flicker between the two.
	local moving = last.x and ((px - last.x) ^ 2 + (py - last.y) ^ 2) > 1e-4
	if moving and cam.off then
		for i = 1, 2 do
			local fi = fits[i]
			if fi then
				local jump = abs(wrap(wrap(fi[1] - facing) - cam.off)) + abs(fi[2] - cam.pitch)
				pairJump[i] = pairJump[i] * 0.97 + jump * 0.03
			end
		end
		local other = 3 - usePair
		if pairJump[other] < pairJump[usePair] * 0.6 then usePair = other end
	end
	local chosen = fits[usePair] or fits[1]
	last.x, last.y, last.z = px, py, z

	-- The camera is kept as its turn relative to the way the character faces (cam.off) and its tilt. Walking does
	-- not change those, and the facing itself is exact every frame, so the fit's frame-to-frame noise (a fraction
	-- of a degree, several pixels on screen) is averaged away while turning with the character costs no lag.
	-- A change too big to be noise (the camera swung round with the mouse) is followed at once.
	if chosen then
		local off = wrap(chosen[1] - facing)
		if cam.off and now - cam.t <= KEEP_CAMERA then
			local dOff, dp = wrap(off - cam.off), chosen[2] - cam.pitch
			local rate = (abs(dOff) + abs(dp) > SNAP) and 30 or cfg("smooth") * 0.1
			local a = min(1, dt * rate)
			cam.off = wrap(cam.off + dOff * a)
			cam.pitch = cam.pitch + dp * a
		else
			cam.off, cam.pitch = off, chosen[2]
		end
		cam.t = now
	end
	local known = cam.off and now - cam.t <= KEEP_CAMERA
	local yaw, pitch
	if known or (cam.off and now - cam.t <= RECENT) then
		-- solved lately: the camera turns with the character, keeping its turn and tilt
		yaw, pitch = wrap(facing + cam.off), cam.pitch
	else
		-- nothing to line up with: the camera behind the character, tilted as set in the settings
		yaw, pitch = facing, rad(cfg("camPitch"))
	end
	cam.yaw = yaw
	setCamera(yaw, pitch, -px, py, z + h, d)
	-- the dots with a camera solved just now, or (when allowed) the estimated one
	return known, chosen ~= nil or (cam.t and now - cam.t <= FRESH) or (not known and cfg("estimate"))
end


------------------------------------------------------------------------------------------------------------
-- The 3D arrow: a thick arrow at a fixed spot on the screen (66% of the way up by default; move it in the
-- settings), pointing from your feet to the average of the next 8 dots. It is turned the way the game camera
-- sees that direction: look down and you see its top, tilt the camera up and you see it from underneath.
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
local function drawQuad(t, a, b, c, d)
	local minX, maxX = min(a[1], b[1], c[1], d[1]), max(a[1], b[1], c[1], d[1])
	local minY, maxY = min(a[2], b[2], c[2], d[2]), max(a[2], b[2], c[2], d[2])
	if maxX - minX < 0.5 then maxX = minX + 0.5 end
	if maxY - minY < 0.5 then maxY = minY + 0.5 end
	t:ClearAllPoints()
	t:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", minX, maxY)
	t:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", maxX, minY)
	t:SetVertexOffset(UL, a[1] - minX, a[2] - maxY)
	t:SetVertexOffset(UR, b[1] - maxX, b[2] - maxY)
	t:SetVertexOffset(LR, c[1] - maxX, c[2] - minY)
	t:SetVertexOffset(LL, d[1] - minX, d[2] - minY)
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

-- Draws the arrow at screen spot (ax, ay), pointing along world direction (dE, dN, dU) as the current camera
-- sees it.
local function renderArrow(ax, ay, dE, dN, dU)
	local l = sqrt(dE * dE + dN * dN + dU * dU)
	if l < 1e-6 then return hideArrowShape() end
	local aF1, aF2, aF3 = dE / l, dN / l, dU / l
	-- right: level, to the right of the direction; up: square to both
	local hl = sqrt(aF1 * aF1 + aF2 * aF2)
	local aR1, aR2, aR3 = rx, ry, 0
	if hl > 1e-3 then aR1, aR2 = aF2 / hl, -aF1 / hl end
	local aU1, aU2, aU3 = aR2 * aF3 - aR3 * aF2, aR3 * aF1 - aR1 * aF3, aR1 * aF2 - aR2 * aF1
	local size = ARROW_PX * cfg("arrowSize")
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
	if cfg("arrowDirColour") then
		local fl = sqrt(fx * fx + fy * fy)
		local off = (hl > 1e-3 and fl > 1e-3) and math.acos(max(-1, min(1, (aF1 * fx + aF2 * fy) / (hl * fl)))) or 0
		r, g, b = directionColour(off)
	else
		local c = cfg("arrowColour")
		r, g, b = c[1], c[2], c[3]
	end
	local alpha = cfg("arrowAlpha")
	for i, f in ipairs(faces) do
		local t = quad(i)
		t:SetDrawLayer("ARTWORK", min(7, -8 + i))
		t:SetVertexColor(r * f.shade, g * f.shade, b * f.shade, alpha)
		drawQuad(t, f.pts[1], f.pts[2], f.pts[3], f.pts[4])
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
-- Every frame: the camera, the dots, the arrow.
------------------------------------------------------------------------------------------------------------

local layer = CreateFrame("Frame", nil, UIParent)
layer:SetAllPoints()
layer:SetFrameStrata("BACKGROUND")
local pool = {}
local function dot(i)
	local t = pool[i]
	if not t then
		t = layer:CreateTexture(nil, "BACKGROUND")
		t:SetTexture(DOT_TEX)
		pool[i] = t
	end
	return t
end

-- the ground under the player: from Pathfinder's height map, else the route's own height there
local function groundZ(p, instance, px, py)
	local G = PF.Graph
	local ground = G and G.HasGround(instance) and PF.player.z
	if ground then return G.GroundZ(instance, px, py, ground, 1) or ground, true end
	return select(3, PF.PointOnSeg(p, p.seg, p.segT or 0)), false
end

------------------------------------------------------------------------------------------------------------
-- Route dots on the minimap: fixed spots every few yards along the route ahead, in the dots' colour.
------------------------------------------------------------------------------------------------------------

local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
local PIP = "Interface\\AddOns\\Guidelime_Pathfinder\\Media\\pip" -- a bright disc with a dark outline
local MINI_SPACING, MINI_RANGE = 8, 260
local miniRef, miniPool = {}, {}
local mini = { n = 0, t = 0, x = 0, y = 0 }

local function clearMinimapDots()
	if mini.n > 0 and HBDPins then HBDPins:RemoveAllMinimapIcons(miniRef) end
	mini.n, mini.id = 0, nil
end

local function miniPin(i)
	local f = miniPool[i]
	if not f then
		f = CreateFrame("Frame")
		f:SetSize(6, 6)
		f.tex = f:CreateTexture(nil, "OVERLAY")
		f.tex:SetAllPoints()
		f.tex:SetTexture(PIP)
		miniPool[i] = f
	end
	return f
end

-- redrawn when you have moved a few yards (or the route changed), not every frame
local function updateMinimapDots(p, px, py, instance)
	if not HBDPins or not p or not p.seg or not cfg("minimapTrail") then return clearMinimapDots() end
	local now = GetTime()
	if mini.id == p.id and (px - mini.x) ^ 2 + (py - mini.y) ^ 2 < 9 and now - mini.t < 1 then return end
	clearMinimapDots()
	mini.id, mini.x, mini.y, mini.t = p.id, px, py, now
	local view, ax, ay, back = anchor(p, MINI_SPACING)
	if not view then return end
	local c = cfg("dotColour")
	local n = 0
	PF.SamplePath(view, MINI_SPACING, MINI_RANGE + back, function(x, y, _, along)
		if along - back < 3 then return end
		n = n + 1
		local pin = miniPin(n)
		pin.tex:SetVertexColor(c[1], c[2], c[3], 1)
		HBDPins:AddMinimapIconWorld(miniRef, pin, instance, x, y, false)
	end, ax, ay, 0)
	mini.n = n
end

local ahead, aheadA = {}, {}
local smooth = {}
local RECHECK_EVERY = 2   -- seconds between second looks at the dots ahead
local RECHECK_DIFF = 1.5  -- yards a dot's height must be off by before it is moved
local LAYER_JUMP = 5      -- yards from the route's own height that means the ground walk took another level
local dotCache = {} -- the route's dots: id, spacing, pts[number back from the end] = { E, N, U, unsure }
-- Returns how many dots were drawn, whether guiding, and the climb ahead.
local dbg = {} -- what the last frame saw, for /pathy debug
local function frame(dt)
	local p = PF.path
	dbg.target, dbg.path, dbg.seg, dbg.service = target ~= nil, p ~= nil, p and p.seg ~= nil, PF.service ~= nil
	dbg.view, dbg.cached, dbg.unsure, dbg.offscreen, dbg.drawn, dbg.firstZ, dbg.sx, dbg.sy = nil, 0, 0, 0, 0, nil, nil, nil
	local bx, by = HBD():GetPlayerWorldPosition()
	local onBoat = reroute.update(bx, by)
	if not target or not p or not p.seg or PF.service or UnitIsGhost("player") or UnitOnTaxi("player") or onBoat then
		dbg.reason = not target and "no target (pick something in the Pathy window)"
			or onBoat and "you are on a moving boat: the route goes on when you get off"
			or not p and "Pathfinder has no route right now"
			or not p.seg and "the route has no segment yet"
			or PF.service and "Pathfinder's own /gpath go is active (/gpath go to stop it)"
			or UnitIsGhost("player") and "you are a ghost" or "you are on a flight"
		smooth.E = nil
		clearMinimapDots()
		return 0
	end
	local px, py, instance = HBD():GetPlayerWorldPosition()
	if not px then dbg.reason = "the game gives no position here"; return 0 end
	dbg.reason = nil
	local pz, hasGround = groundZ(p, instance, px, py)
	if IsMounted() then PF.Speed() end -- remembers this character's mount speed for planning
	local known, fresh = updateCamera(dt, px, py, pz)
	dbg.known, dbg.fresh, dbg.pz, dbg.ground, dbg.zoom = known, fresh, pz, hasGround, GetCameraZoom()
	dbg.pitch, dbg.off = cam.pitch, cam.off
	dbg.graph, dbg.pathZ = p.graph, p.z ~= nil

	-- The dots: each one's place in the world (and its height on the ground) is worked out once and kept for
	-- the route, numbered back from the route's end; every frame only projects them. Working them out afresh each
	-- frame let their heights follow the player's own and wobble as you walked.
	local spacing = dotSpacing()
	local view, ax, ay, back, base, total = anchor(p, spacing)
	local range, size, alpha, colour = cfg("dotRange"), cfg("dotSize"), cfg("dotAlpha"), cfg("dotColour")
	local lookahead = cfg("arrowAhead") or LOOKAHEAD
	local reach = max(range, lookahead)
	local aheadMax = math.ceil(lookahead / spacing) + 2
	local noPath = not p.graph and not p.walked -- only the straight line: no dots for a route that is not one
	local drawDots = fresh and cfg("dots") and not noPath
	local n, nAhead = 0, 0
	if view then
		if dotCache.id ~= p.id or dotCache.spacing ~= spacing or not p.graph then
			dotCache.id, dotCache.spacing, dotCache.pts = p.id, spacing, {}
		end
		local pts = dotCache.pts
		dbg.view = true
		local k0 = floor((total - base) / spacing + 0.5) -- the anchor's number
		local kLast = max(0, k0 - math.ceil((reach + back) / spacing))
		local missing = false
		for k = k0 - 1, kLast, -1 do if not pts[k] then missing = true break end end
		-- Looked at again every couple of seconds as you go, so a dot put on the wrong level is put right; a
		-- dot only moves if its height is off by more than RECHECK_DIFF (smaller changes would bring back the
		-- wobble).
		local now = GetTime()
		if missing or now - (dotCache.t or 0) > RECHECK_EVERY then
			dotCache.t = now
			-- the walk starts on the ground at the anchor, on the route's own level there
			local lineZ0 = p.z and select(3, PF.PointOnSeg(p, view.seg, view.segT)) or pz
			local z0 = hasGround and (PF.Graph.GroundZ(instance, ax, ay, lineZ0, 1) or lineZ0) or nil
			PF.SampleGround(view, instance, ax, ay, z0, spacing, reach + back, function(x, y, z, along, lineZ, unsure)
				local k = floor((total - base - along) / spacing + 0.5)
				if k < 0 then return end
				-- the ground walk can step onto another level (the hillside over a cave, a bridge over the
				-- path): far from the route's own height, the route's height is the one to trust
				if p.graph and p.z and lineZ and abs(z - lineZ) > LAYER_JUMP then
					z = PF.Graph.GroundZ(instance, x, y, lineZ, 0) or lineZ
					if abs(z - lineZ) > LAYER_JUMP then z = lineZ end
				end
				-- a straight line (no walk grid here) says nothing about the ground it crosses: following the height
				-- map along it climbs onto roofs and over buildings, so keep the dots level with the player
				if not p.graph then z = pz end
				local old = pts[k]
				if not old then
					pts[k] = { -x, y, z, unsure }
				elseif abs(old[3] - z) > RECHECK_DIFF then
					old[3], old[4] = z, unsure
				end
			end)
		end
		for k = k0 - 1, kLast, -1 do
			local pt = pts[k]
			if not pt then break end
			dbg.cached = dbg.cached + 1
			if pt[4] then dbg.unsure = dbg.unsure + 1 end
			if not dbg.firstZ then dbg.firstZ = pt[3] end
			local a = (k0 - k) * spacing - back -- yards ahead of the player along the route
			if a >= 0.5 then
				if nAhead < aheadMax and (nAhead == 0 or a <= lookahead) then
					nAhead = nAhead + 1
					ahead[nAhead], aheadA[nAhead] = pt, a
				end
				if drawDots and n < MAX_DOTS and a >= 1.5 and a <= range and not pt[4] then
					local sx, sy, cf, dirz = project(pt[1], pt[2], pt[3] + 0.05)
					if not sx then dbg.offscreen = dbg.offscreen + 1 end
					if sx then
						dbg.drawn = dbg.drawn + 1
						if dbg.drawn == 1 then dbg.sx, dbg.sy = sx, sy end
						n = n + 1
						local t = dot(n)
						local sz = min(40, max(3, size * focal / cf))
						t:SetSize(sz, sz * min(1, max(0.15, -dirz)))
						t:ClearAllPoints()
						t:SetPoint("CENTER", UIParent, "BOTTOMLEFT", sx, sy)
						t:SetVertexColor(colour[1], colour[2], colour[3])
						local fadeIn = min(1, (a - 1.5) / 4) -- the ones you reach fade out under your feet
						local fadeOut = min(1, (range - a) / (range * 0.35))
						t:SetAlpha(alpha * fadeIn * fadeOut)
						t:Show()
					end
				end
			end
		end
	end

	if noPath then clearMinimapDots() else updateMinimapDots(p, px, py, instance) end

	-- the arrow: from the player's feet to the average of the next dots (or the route's end, nearly there)
	local aE, aN, aU
	if nAhead > 0 then
		-- Aim at the far end of the look-ahead (the last 30% of it, averaged for steadiness). Averaging every
		-- point from the player's feet outwards aimed at about half the distance.
		local from = 1
		while from < nAhead and aheadA[from] < lookahead * 0.7 do from = from + 1 end
		aE, aN, aU = 0, 0, 0
		for i = from, nAhead do aE, aN, aU = aE + ahead[i][1], aN + ahead[i][2], aU + ahead[i][3] end
		local cnt = nAhead - from + 1
		aE, aN, aU = aE / cnt, aN / cnt, aU / cnt
	else
		aE, aN, aU = -p.x[p.n], p.y[p.n], p.z and p.z[p.n] or pz
	end
	local dE, dN, dU = aE + px, aN - py, aU - pz
	-- Close to the target: point straight at it and give the straight distance. The walked route can wind round a
	-- counter or a corner (22 yd of route to someone 4 yd away), which is no help once you can see them.
	smooth.nearDist = nil
	if target.instance == instance then
		local sd = dist(px, py, target.x, target.y)
		if sd < 12 then
			dE, dN, dU = px - target.x, target.y - py, 0
			smooth.nearDist = sd
		end
	end
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
	return n, true, p.graph and (aU - pz) or 0
end

local errors = {}
local function report(err)
	dbg.err = tostring(err)
	if not errors[err] then errors[err] = true; Print("|cffff4040error:|r " .. tostring(err)) end
end

-- What to do at the start of the trip's next ride (a flight, boat, zeppelin, the tram, a lift, a portal), once
-- you are within RIDE_NEAR yards of it.
local RIDE_NEAR = 5
local RIDE_TEXT = {
	flight = "Talk to the flight master and %s",
	boat = "Wait here for the boat and get on (%s)",
	zeppelin = "Wait here for the zeppelin and get on (%s)",
	tram = "Wait here for the tram and get on (%s)",
	lift = "Step onto the lift when it comes (%s)",
	portal = "Step into the portal (%s)",
}
local function rideInstruction()
	local l = PF.trip and PF.trip.next
	local f = l and l.from
	if not f or not PF.LegText then return end
	local px, py, instance = HBD():GetPlayerWorldPosition()
	if not px or instance ~= f.instance or dist(px, py, f.x, f.y) > RIDE_NEAR then return end
	local ok, what = pcall(PF.LegText, l)
	what = ok and what or "ride on"
	return format(RIDE_TEXT[l.kind] or "Here: %s", what)
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt)
	local ok, n, guiding, climb = pcall(frame, dt)
	if not ok then report(n); n, guiding = 0, false end
	for i = n + 1, #pool do pool[i]:Hide() end

	if not arrow:IsShown() then return end
	local ax, ay = arrowAnchor()
	if guiding and smooth.E then
		-- The arrow ignores the camera's pitch: it is always drawn as seen from the default tilt, turned only by
		-- which way the camera faces. (The dots were drawn with the real camera just before.)
		setCamera(cam.yaw or GetPlayerFacing() or 0, rad(ARROW_TILT), 0, 0, 0, 1)
		local okA, err = pcall(renderArrow, ax, ay, smooth.E, smooth.N, smooth.U)
		if not okA then report(err); return hideArrowShape() end
		local ride = rideInstruction()
		if ride then
			-- at a flight master, a dock, the tram: what to do here (shown even with the arrow's text off)
			arrow.climb:SetText("|cff66ccff" .. ride .. "|r")
			local p = PF.path
			local rem = smooth.nearDist or (p and p.remaining)
			arrow.dist:SetText(cfg("arrowText") and rem and format("%d yd", floor(rem + 0.5)) or "")
		elseif cfg("arrowText") then
			if climb and climb > CLIMB then
				arrow.climb:SetText("^ up")
			elseif climb and climb < -CLIMB then
				arrow.climb:SetText("v down")
			else
				arrow.climb:SetText("")
			end
			local p = PF.path
			local rem = smooth.nearDist or (p and p.remaining)
			arrow.dist:SetText(rem and format("%d yd", floor(rem + 0.5)) or "")
		else
			arrow.climb:SetText("")
			arrow.dist:SetText("")
		end
		local warn = not ride and Walked.warning()
		if warn then arrow.climb:SetText("|cffff9933Pathy: " .. warn .. "|r") end
	elseif target and not handle:IsShown() then
		hideArrowShape()
		local why = noRouteText() or dbg.reason
		if why then
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
S:SetSize(600, 770)
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
	if key == "usePin" and target and PF and PF.db then
		PF.db.marker = cfg("usePin")
		if not cfg("usePin") and PF.Marker and PF.Marker.IsActive and PF.Marker.IsActive() then
			PF.Marker.Release() -- takes away only the pin Pathfinder placed
			restorePlayerPin()
		elseif cfg("usePin") then
			savePlayerPin()
			if PF.Marker and PF.Marker.ResetOverride then PF.Marker.ResetOverride() end
		end
	end
	if key == "arrow" then updateArrowShown() end
	if key == "windowAlpha" or key == "uiScale" then f.ApplyLook() end
	if key == "minimapButton" then updateMinimapButton() end

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
	fs:SetWidth((x < 300 and 296 or 586) - x - 30) -- wraps inside its column and the window
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
	fs:SetWidth(250) -- long labels wrap instead of running off the window
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

-- left column: the arrow
local L, R = 16, 316
header(S, "Arrow", L, -42)
checkbox(S, "arrow", "Show the arrow", L, -60)
slider(S, "arrowSize", "Size", L + 4, -92, 0.2, 2, 0.05, "%d%%", 100)
slider(S, "arrowAlpha", "Opacity", L + 4, -132, 0.05, 1, 0.05, "%d%%", 100)
swatch(S, "arrowColour", "Colour", L + 4, -172)
checkbox(S, "arrowDirColour", "Colour by direction (green ahead, red behind)", L, -198)
checkbox(S, "arrowText", "Show up / down and the distance under it", L, -222)
slider(S, "arrowX", "Across the screen", L + 4, -254, 0, 1, 0.01, "%d%%", 100)
slider(S, "arrowY", "Up the screen", L + 4, -294, 0, 1, 0.01, "%d%%", 100)
local unlockBtn
unlockBtn = button(S, "Drag to move", 130, L + 4, -334, function()
	setArrowUnlocked(not handle:IsShown())
	unlockBtn:SetText(handle:IsShown() and "Lock in place" or "Drag to move")
end)
button(S, "Reset position", 120, L + 140, -334, function()
	PathyDB.arrowX, PathyDB.arrowY = nil, nil
	applied("arrowX")
	refreshSettings()
end)

-- right column: the dots, and the rest
header(S, "Dots", R, -42)
checkbox(S, "dots", "Show the ground dots", R, -60)
slider(S, "dotSize", "Size", R + 4, -92, 0.2, 2, 0.05, "%.2f yd")
slider(S, "dotAlpha", "Opacity", R + 4, -132, 0.05, 1, 0.05, "%d%%", 100)
swatch(S, "dotColour", "Colour", R + 4, -172)
slider(S, "dotSpacing", "Spacing", R + 4, -204, 2, 10, 1, "%d yd")
slider(S, "dotRange", "How far ahead", R + 4, -244, 20, 150, 5, "%d yd")
slider(S, "smooth", "Steadiness (lower = steadier, slower to follow the camera)", R + 4, -284, 2, 60, 1, "%d")
header(S, "Minimap", R, -330)
checkbox(S, "minimapButton", "Pathy button on the minimap", R, -348)
checkbox(S, "minimapTrail", "Route dots on the minimap", R, -372)

header(S, "Text under the arrow", L, -372)
slider(S, "textAlpha", "Opacity", L + 4, -392, 0.05, 1, 0.05, "%d%%", 100)
swatch(S, "textColour", "Colour", L + 4, -432)
slider(S, "textX", "Across the screen", L + 4, -464, 0, 1, 0.01, "%d%%", 100)
slider(S, "textY", "Up the screen", L + 4, -504, 0, 1, 0.01, "%d%%", 100)
button(S, "Reset text position", 150, L + 4, -544, function()
	PathyDB.textX, PathyDB.textY = nil, nil
	refreshSettings()
end)

slider(S, "windowAlpha", "Pathy window background opacity", L + 4, -584, 0, 1, 0.05, "%d%%", 100)
slider(S, "uiScale", "Pathy window size (UI scale)", L + 4, -624, 0.5, 1.5, 0.05, "%d%%", 100)
header(S, "Lining up the dots", R, -402)
checkbox(S, "usePin", "Move my map pin along the route (exact dots)", R, -420)
checkbox(S, "estimate", "Show dots with no map pin to line up with", R, -444)
slider(S, "camPitch", "Camera tilt to assume then", R + 4, -476, 0, 70, 1, "%d")
header(S, "Questie", R, -514)
checkbox(S, "followTracked", "Guide to the quest I focus in Questie's tracker", R, -532)
slider(S, "arrowAhead", "Arrow looks ahead (short follows bends, long is steadier)", R + 4, -562, 10, 120, 5, "%d yd")
header(S, "Walked paths", R, -612)
checkbox(S, "recordWalk", "Remember where I walk", R, -630)
checkbox(S, "useWalked", "Use it to route (no path, or shorter than the usual one)", R, -654)
checkbox(S, "recordOthers", "Also remember where my group members walk (positions only)", R, -678)

button(S, "Reset everything to defaults", 220, 190, -726, function()
	for k in pairs(DEFAULTS) do PathyDB[k] = nil end
	for k in pairs(DEFAULTS) do applied(k) end
	refreshSettings()
end)

S:SetScript("OnShow", refreshSettings)
S:SetScript("OnHide", function()
	setArrowUnlocked(false)
	unlockBtn:SetText("Drag to move")
end)

function toggleSettings()
	if S:IsShown() then S:Hide() else S:Show() end
end

-- An entry in the game's own options (Esc > Options > AddOns > Pathy) that opens the settings window.
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
	d:SetText("Ground dots and a 3D arrow that walk you to quest givers, turn-ins, your map pin or your target.\n\n"
		.. "Pathy's settings are in their own window, so you can see the arrow and dots change while you adjust them. "
		.. "You can also open it with /pathy config, or by shift-clicking Pathy's minimap button.")
	local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b:SetSize(200, 26)
	b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -16)
	b:SetText("Open Pathy settings")
	b:SetScript("OnClick", function()
		if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
		if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then HideUIPanel(InterfaceOptionsFrame) end
		if GameMenuFrame and GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame) end
		S:Show()
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
events:RegisterEvent("TAXIMAP_OPENED")
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
		if not PF or not PF.GetTarget then
			return Print("|cffff4040Guidelime Pathfinder is not loaded|r: enable Guidelime and Guidelime Pathfinder in the AddOns list.")
		end
		hookPathfinder()
		hookKnownTaxi()
		pcall(ctx.install)
		-- the window was open when you left: open it again (after Questie has had a moment to load)
		if PathyDB.shown then C_Timer.After(2, function() if not f:IsShown() then f:Show() end end) end
		C_Timer.After(6, function() followReady = true end)
		-- Questie's tracker: sending a quest to TomTom (its click binding) guides there too
		local TU = questie("TrackerUtils")
		if TU and TU.SetQuestTomTomTarget then
			hooksecurefunc(TU, "SetQuestTomTomTarget", function(questId) pcall(guideToQuest, questId) end)
		end
		-- a route planned before the hook (Pathfinder starts on login too) is planned again with the real flights
		C_Timer.After(1, function()
			if target and PF.Plan and PF.player and PF.player.x then pcall(PF.Plan, PF.player.x, PF.player.y) end
		end)
		-- Older versions moved your map pin while guiding and kept yours aside: give it back once, after
		-- Pathfinder has taken away the one it moved (it looks ten times a second).
		if not cfg("usePin") and PathyDB.savedPin then
			local pin = PathyDB.savedPin
			C_Timer.After(2, function()
				PathyDB.savedPin = nil
				if PF.Marker and PF.Marker.IsActive() then PF.Marker.Release() end
				if not (C_Map.HasUserWaypoint and C_Map.HasUserWaypoint()) then
					pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(pin[1], pin[2], pin[3]))
					if pin[4] and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
				end
			end)
		end
		-- after Pathfinder's own hook of the same function (it hooks on login too)
		C_Timer.After(1, hookDestinationReached)
		local saved = PathyDB.target
		if not saved then -- settings or a pin left behind by a crash
			restorePlayerPin()
			setQuiet(false)
		else
			C_Timer.After(5, function() -- once Questie has loaded its database
				if not target and PathyDB.target == saved then pcall(resume, saved) end
				if not target then restorePlayerPin(); setQuiet(false) end
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
	elseif event == "TAXIMAP_OPENED" then
		C_Timer.After(0, learnTaxiMap) -- once the flight map has its nodes
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
	elseif lower == "arrow" or lower == "dots" or lower == "minimap" then
		local key = lower == "minimap" and "minimapButton" or lower
		PathyDB[key] = not cfg(key)
		applied(key)
		Print(({ arrow = "arrow", dots = "ground dots", minimapButton = "minimap button" })[key] .. " " .. onOff(cfg(key)))
	elseif lower == "debug" then
		local function v(x) if type(x) == "number" then return format("%.2f", x) end return tostring(x) end
		Print("why nothing is drawn: " .. (dbg.reason or "(nothing stopping it)") .. (dbg.err and ("  |cffff4040last error:|r " .. dbg.err) or ""))
		Print(format("guiding %s, route %s (seg %s, walk grid %s, heights %s), Pathfinder service %s",
			v(dbg.target), v(dbg.path), v(dbg.seg), v(dbg.graph), v(dbg.pathZ), v(dbg.service)))
		Print(format("dots setting %s, camera solved lately %s, allowed to draw %s, estimate allowed %s, tracked pin %s",
			v(cfg("dots")), v(dbg.known), v(dbg.fresh), v(cfg("estimate")),
			v(C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint())))
		Print(format("camera: tilt %s rad, turn from facing %s, zoom %s; ground under you %s (height map %s)",
			v(dbg.pitch), v(dbg.off), v(dbg.zoom), v(dbg.pz), v(dbg.ground)))
		Print(format("dots: anchor %s, kept ahead %s, unsure %s, first height %s, behind camera %s, drawn %s (first at %s, %s)",
			v(dbg.view), v(dbg.cached), v(dbg.unsure), v(dbg.firstZ), v(dbg.offscreen), v(dbg.drawn), v(dbg.sx), v(dbg.sy)))
		local p = PF.path
		if p and p.x then Print(format("route: %d corners, %.0f yd left", p.n or 0, p.remaining or 0)) end
	elseif lower == "walked" or lower == "walked clear" or lower == "walked show" then
		if lower == "walked clear" then
			Walked.clear()
			Print("forgot every place you had walked")
		elseif lower == "walked show" then
			Print("walked-spot window " .. onOff(Walked.radar()) .. ": the spots remembered within 25 yd of you, north up and you in the middle (gold: joined to others, red: alone). Drag it to move; |cffffff00/pathy walked show|r again closes it.")
		else
			for _, line in ipairs(Walked.explain()) do Print(line) end
			Print("|cffffff00/pathy walked clear|r forgets everything remembered.")
		end
	elseif lower == "help" then
		Print("/pathy  - open the quest list (click one to walk to its NPC)")
		Print("/pathy pin  - walk to your map pin    /pathy target  - walk to the NPC you have targeted")
		Print("/pathy <name>  - walk to the first quest or NPC in the list matching that text")
		Print("/pathy stop  - stop guiding")
		Print("/pathy walked  - how much of your walking is remembered    /pathy walked show  - see the spots near you    /pathy walked clear  - forget it")
		Print("/pathy arrow | dots | minimap  - turn the arrow / the ground dots / the minimap button on or off")
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
