-- Pathy's routing: BV Addon Suite - Routing, and nothing else.
--
-- BV plans the way (its own navmesh planner, which knows walls, slopes, stairs, city levels, lifts, flights, boats
-- and zeppelins, on both continents) and leads along it; Pathy shows it with its 3D arrow. Pathy has no route
-- logic of its own, and no other addon is needed for it: no walked spots, no Pathfinder, no QuestTrail lines. When
-- BV has no route the arrow says so and shows nothing else.
--
-- How it works: BV keeps its plan in BVAddonSuiteCore.Routing.Navigate (steps, the current step, the point you are
-- up to on it). Pathy hands it the destination (Navigate:Start, as /bv route does) and copies the points of the
-- walking leg you are on, with their heights, as the route to draw. BV does the leading: it moves to the next step,
-- plans again when you leave the way, and takes lifts, flights and rides into account. Pathy only reads its state.
--
-- Needs BV Core, Map Data and Routing (CurseForge: "BV Addon Suite").

local ADDON, ns = ...
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local BV = {}
ns.BV = BV
local st = { startAt = -100 }

local function routing()
	local core = rawget(_G, "BVAddonSuiteCore")
	local R = core and core.Routing
	return R and R.ready and R or nil
end

local function safe(fn, ...)
	local ok, a, b, c = pcall(fn, ...)
	if ok then return a, b, c end
end
ns.routing, ns.safe = routing, safe -- (for HUD.lua)

-- BV's chat messages: every BV addon speaks through one function (BVAddonSuiteCore:Print), so one stand-in for it
-- silences them all. They are still in BV's own log (what Routing:Print always writes first), in /pathy bv and in
-- the HUD. Looked at every moment, so the setting takes effect at once, and BV's messages at login are caught too
-- (this file loads before they are said).
local realPrint
local function silenceBV()
	local core = rawget(_G, "BVAddonSuiteCore")
	if not (core and type(core.Print) == "function") then return end
	if ns.cfg("silenceBV") then
		if not realPrint then
			realPrint = core.Print
			core.Print = function() end
		end
	elseif realPrint then
		core.Print = realPrint
		realPrint = nil
	end
end
silenceBV()

-- Your height, from BV's own measurement (the NPCs near you, by the game's range checks): the middle of its band
-- when the band is narrow, else nil
local function heightNow()
	local R = routing()
	local H = R and R.Height
	if not (H and H.Now and H.Span) then return end
	local m = safe(H.Now, H)
	local span, lo, hi = H.Span(m and m.set)
	if span and span <= ((R.Hpa and R.Hpa.ZSPAN) or 6) then return (lo + hi) / 2 end
end

-- BV's goal for a place: the place as a point of its own map, then of its continent, as BV does for
-- "/bv route <x> <y>"
local CONT_MAP = { [0] = 1415, [1] = 1414 } -- a continent's own map, for a place with no map of its own
local function makeGoal(R, t)
	local H = ns.HBD()
	-- the place's own map first (it may be on another continent than you), never the map you stand in for it
	local map = t.uiMap or CONT_MAP[t.instance]
	if not map then return end
	local mx, my = H:GetZoneCoordinatesFromWorld(t.x, t.y, map, true)
	if not mx then return end
	local cont, cx, cy = R:OnContinent(map, mx, my)
	if not cont then return end
	return { cont = cont, x = cx, y = cy, name = t.name or "destination", label = "Pathy's destination" }
end

-- Which of several places BV reaches soonest (its own estimate: walking, flights, boats, zeppelins, lifts; other
-- continents too): cb(place), or cb(false) when BV finds no way to any of them. Worked out in BV's scheduler, a few
-- milliseconds a frame, so the game does not stop for it.
function BV.choose(spots, cb)
	local R = routing()
	local N = R and R.Navigate
	if not N then
		ns.Print("The route planner is not loaded, so nothing can be planned: enable its three addons (Core, Map Data, Routing) and restart the game.")
		return cb(false)
	end
	if #spots == 1 then return cb(spots[1]) end
	local list, index = {}, {}
	for i, s in ipairs(spots) do
		local g = makeGoal(R, s)
		if g then
			list[#list + 1] = g
			index[#list] = i
		end
	end
	local cont, cx, cy, level = N:Here()
	if #list == 0 or not cont then return cb(spots[1]) end -- cannot estimate: the first; BV says if it cannot reach it
	local ok = pcall(R.Scheduler.Run, function() return N:EstimateMany({ cont = cont, x = cx, y = cy, level = level }, list) end,
		function(times)
			local best, bestT
			for k = 1, #list do
				local tt = type(times) == "table" and times[k]
				if tt and (not bestT or tt < bestT) then best, bestT = spots[index[k]], tt end
			end
			cb(best or false)
		end, false)
	if not ok then cb(spots[1]) end
end

-- the heights of a route's corners, the unknown ones from the nearest known (nil when none is known)
local function fillZ(zs, n)
	local any = false
	for i = 1, n do
		if zs[i] then any = true break end
	end
	if not any then return nil end
	local prev
	for i = 1, n do
		if zs[i] then prev = zs[i] elseif prev then zs[i] = prev end
	end
	local nextz
	for i = n, 1, -1 do
		if zs[i] then nextz = zs[i] elseif nextz then zs[i] = nextz end
	end
	return zs
end

-- Douglas-Peucker: drops the points within tol yards of the line between their neighbours (a change of height
-- counts, so a stair keeps its corners). BV's points lie a yard or two apart; the arrow follows a route of real bends,
-- and a few corners are cheaper to follow than hundreds of points.
local function simplify(xs, ys, zs, tol)
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
			local d, f
			if len2 < 1e-9 then
				f = 0
				d = ns.dist(xs[k], ys[k], ax, ay)
			else
				f = max(0, min(1, ((xs[k] - ax) * dx + (ys[k] - ay) * dy) / len2))
				d = ns.dist(xs[k], ys[k], ax + dx * f, ay + dy * f)
			end
			if zs then d = max(d, abs(zs[k] - (zs[i] + (zs[j] - zs[i]) * f)) * 0.5) end
			if d > bestD then bestD, bestK = d, k end
		end
		if bestK and bestD > tol then
			keep[bestK] = true
			stack[sp + 1], stack[sp + 2], stack[sp + 3], stack[sp + 4] = i, bestK, bestK, j
			sp = sp + 4
		end
	end
	local ox, oy, oz = {}, {}, zs and {} or nil
	for i = 1, n do
		if keep[i] then
			ox[#ox + 1], oy[#oy + 1] = xs[i], ys[i]
			if zs then oz[#oz + 1] = zs[i] end
		end
	end
	return ox, oy, oz
end

ns.height = heightNow -- (for the arrow, in Pathy.lua)

-- The walking leg you are on, as a Pathy route (world coordinates, heights), reduced to its real bends. It starts from
-- the point of BV's path nearest to you (never earlier than where BV says you are up to, less two), so a point
-- of the path that lies behind you, or a jog back at its start, is not part of it: the arrow never starts out
-- pointing backwards for that. Built once per leg: Pathy follows it from there, and BV replaces the leg when it
-- plans again.
local function applyWalk(N, step, px, py)
	local H = ns.HBD()
	local cont, pts = step.from.cont, step.path
	local first = max(1, (N.ahead or 1) - 2)
	local wx, wy = {}, {}
	for j = first, #pts do
		local x, y = H:GetWorldCoordinatesFromZone(pts[j][1], pts[j][2], cont)
		wx[j], wy[j] = x, y
	end
	-- the leg of the path nearest to you; the route goes on from its far end
	local near, nearD = first, math.huge
	for j = first, #pts - 1 do
		if wx[j] and wx[j + 1] then
			local ax, ay, bx, by = wx[j], wy[j], wx[j + 1], wy[j + 1]
			local dx, dy = bx - ax, by - ay
			local len2 = dx * dx + dy * dy
			local f = len2 > 1e-9 and max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) or 0
			local d = ns.dist(px, py, ax + dx * f, ay + dy * f)
			if d < nearD then near, nearD = j, d end
		end
	end
	local xs, ys, zs = { px }, { py }, { heightNow() or false }
	for j = near + 1, #pts do
		if wx[j] then xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = wx[j], wy[j], pts[j].z or false end
	end
	local ex, ey = H:GetWorldCoordinatesFromZone(step.to.x, step.to.y, step.to.cont)
	if ex and ns.dist(xs[#xs], ys[#ys], ex, ey) > 1 then xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = ex, ey, step.to.z or false end
	if #xs < 2 then return false end
	local fz = fillZ(zs, #xs)
	xs, ys, fz = simplify(xs, ys, fz, 1)
	st.path = ns.setRoute(xs, ys, fz)
	return true
end

-- one line saying what BV is doing, for the window and the arrow
local function describe(R, N, t)
	if not N.steps then
		if N.busy then return "Calculating the way..." end
		local last = R.log and R.log[#R.log]
		if st.sawSteps then return "The route has ended" end
		return "No route to " .. (t.name or "here") .. (last and (" - " .. last:gsub("^%d+:%d+:%d+%s+", "")) or "")
	end
	local step = N.steps[N.current]
	if not step then return "No current step" end
	local left
	if step.kind == "walk" and type(step.path) == "table" then left = step.yards end
	local say = safe(N.Say, N, step, left) or step.kind
	return string.format("Route: step %d of %d - %s", N.current or 0, #N.steps, say)
end

-- The guide panel ---------------------------------------------------------------------------------------------
-- BV's own guide window (a medallion with a flat arrow, what to do now, what comes next, the time left) is hidden
-- through its own setting while Pathy guides, and given back afterwards; this panel says the same things, under
-- Pathy's smoothed 3D arrow, from BV's own functions (Navigate:Parts, :Say, :SecondsLeft). Move the arrow (settings,
-- "Drag to move") and the panel goes with it.
local panel
local PANEL_W, PANEL_H = 270, 98

local function buildPanel()
	local f = CreateFrame("Frame", "PathyGuide", UIParent, "BackdropTemplate")
	f:SetSize(PANEL_W, PANEL_H)
	f:SetFrameStrata("LOW") -- under the game's windows, like the arrow
	f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
	local function line(template, point, x, y, width, justify)
		local fs = f:CreateFontString(nil, "OVERLAY", template)
		fs:SetPoint(point, x, y)
		if width then fs:SetWidth(width) end
		fs:SetJustifyH(justify or "LEFT")
		fs:SetWordWrap(false)
		return fs
	end
	f.head = line("GameFontNormalSmall", "TOPLEFT", 10, -8, PANEL_W - 70)
	f.count = line("GameFontHighlightSmall", "TOPRIGHT", -10, -8, 50, "RIGHT")
	f.now = line("GameFontNormalLarge", "TOPLEFT", 10, -23, PANEL_W - 20)
	f.target = line("GameFontHighlight", "TOPLEFT", 10, -47, PANEL_W - 20)
	f.next = line("GameFontDisableSmall", "TOPLEFT", 10, -64, PANEL_W - 20)
	f.level = line("GameFontDisableSmall", "BOTTOMLEFT", 10, 8, PANEL_W - 90)
	f.time = line("GameFontHighlightSmall", "BOTTOMRIGHT", -10, 8, 80, "RIGHT")
	f:Hide()
	return f
end

-- what the panel says, from BV's state (the same things BV's own guide says)
local function content(R, N, t)
	local level = safe(function() return R.Level:Name(R.Level:Current()) end)
	local goal = (N.goal and N.goal.name) or t.name or "?"
	if not N.steps then
		if N.busy then return "FINDING THE WAY", "", goal, "", "", level, "" end
		return "NO ROUTE", "", ns.bvText or "No route", "", "", level, ""
	end
	local i = N.current or 1
	local step = N.steps[i]
	if not step then return "NO ROUTE", "", "No current step", "", "", level, "" end
	local parts = safe(N.Parts, N, step) or {}
	local head = tostring(parts.head or step.kind or ""):upper()
	local count = #N.steps > 1 and string.format("%d/%d", i, #N.steps) or ""
	local now, target
	if step.kind == "walk" then
		local yards = N.left or step.yards
		now = yards and (floor(yards + 0.5) .. " yd") or "Walk"
		target = parts.target or ""
	elseif step.kind == "flight" then
		now, target = "Fly " .. (parts.target or ""), "Talk to the flight master. Wait here until you land."
	elseif step.kind == "transport" then
		if st.riding then
			now, target = "Riding " .. (parts.target or ""), "You are on it: stay on until you arrive."
		else
			now = (parts.verb or "Ride") .. " " .. (parts.target or "")
			target = (R.Timetable and safe(R.Timetable.GuideText, R.Timetable, step)) or "Wait for it here and ride along until you are there."
		end
	else
		now = parts.verb or "Go"
		target = parts.name and (parts.name .. "  -  " .. (parts.target or "")) or (parts.target or "")
	end
	local after = N.steps[i + 1]
	-- what comes after; on the last step nothing does, and "there: <destination>" would only repeat the line above
	-- when that already names it
	local nextText
	if after then
		nextText = "then: " .. (safe(N.Say, N, after, nil, true) or "")
	elseif target:find(goal, 1, true) or now:find(goal, 1, true) then
		nextText = ""
	else
		nextText = "there: " .. goal
	end
	local secs = safe(N.SecondsLeft, N)
	return head, count, now, target, nextText, level, secs and (safe(N.Clock, secs) or "") or ""
end

local function paintPanel(R, N, t)
	panel = panel or buildPanel()
	local f = panel
	-- under the arrow's own text (the up/down hint and the yards), wherever the player put that
	local tx, ty = ns.cfg("textX") * UIParent:GetWidth(), ns.cfg("textY") * UIParent:GetHeight()
	f:ClearAllPoints()
	f:SetPoint("TOP", UIParent, "BOTTOMLEFT", tx, ty - 40)
	local a = ns.cfg("windowAlpha")
	f:SetBackdropColor(0.05, 0.05, 0.08, a)
	f:SetBackdropBorderColor(1, 1, 1, a)
	local head, count, now, target, nextText, level, time = content(R, N, t)
	f.head:SetText(head)
	f.count:SetText(count)
	f.now:SetText(now)
	f.target:SetText(target)
	f.next:SetText(nextText)
	f.level:SetText(level and ("on " .. level) or "")
	f.time:SetText(time)
	f:Show()
end

-- BV's own guide: hidden while Pathy guides (its own "Hide the guide" setting), what it was put back afterwards
-- (also after a reload or a crash in between: what it was is kept)
local function manageBVGuide(R, hide)
	local G = R and R.Guide
	if not (G and G.SetSide and R.Config) then return end
	local c = safe(R.Config, R)
	if not c then return end
	if hide then
		if c.guide ~= "off" then
			PathyDB.bvGuideWas = c.guide
			safe(G.SetSide, G, "off")
		end
	elseif PathyDB.bvGuideWas then
		if c.guide == "off" then safe(G.SetSide, G, PathyDB.bvGuideWas) end
		PathyDB.bvGuideWas = nil
	end
end

-- the settings changed (the panel's, BV's window's)
function BV.refresh()
	silenceBV()
	manageBVGuide(routing(), ns.getTarget() ~= nil)
	if panel and not ns.cfg("guidePanel") then panel:Hide() end
	if not ns.cfg("guidePanel") and ns.HUD then ns.HUD.hide() end
	if ns.HUD and ns.HUD.refresh then ns.HUD.refresh() end
end

-- Riding something that carries you (a tram, a boat, a zeppelin): your position changes fast while your own speed
-- does not. BV watches ships and zeppelins this way but not the tram, and tells you to "wait here, departure time not
-- known yet" while you are already sitting in it; this notices it instead. Inside the tram's own map (which has no
-- place on a continent) a tram step also means you are aboard.
local function watchRide(R, N, step, now)
	local mapID, mx, my = R:Position()
	local cont, cx, cy
	if mapID then cont, cx, cy = R:OnContinent(mapID, mx, my) end
	if mapID and not cont and step and step.kind == "transport" and type(step.by) == "table" and step.by.kind == "tram" then
		st.riding, st.rideSample = true, nil
		return
	end
	if not cont then
		st.rideSample = nil
		return
	end
	local s = st.rideSample
	if s and s.cont == cont then
		local dt = now - s.t
		if dt < 0.25 then return end
		local yards = N.Yards(cont, cx, cy, s.x, s.y)
		local speed = yards / dt
		local own = GetUnitSpeed("player") or 0
		if yards > 60 then
			st.rideSince, st.riding = nil, false -- a jump (a teleport, a loading screen), not a ride
		elseif speed > 3 and own < speed * 0.5 and not UnitOnTaxi("player") and not (IsFalling and IsFalling()) then
			st.rideSince = st.rideSince or now
			if now - st.rideSince > 1 then st.riding = true end
		elseif speed < 1.5 or own >= speed * 0.8 then
			st.rideSince, st.riding = nil, false
		end
	end
	st.rideSample = { cont = cont, x = cx, y = cy, t = now }
end
ns.riding = function() return st.riding == true end -- (for HUD.lua)
ns.ended = function() return st.ended == true end -- the route has ended (for the arrow)

local function route(now)
	local t = ns.getTarget()
	local R = routing()
	local N = R and R.Navigate
	silenceBV()
	manageBVGuide(R, t ~= nil)
	-- the way ended by hand (the HUD's button, /bv route stop) stays ended: not planned again behind your back
	if N and not st.stopWrapped then
		st.stopWrapped = true
		local original = N.Stop
		N.Stop = function(self, quiet, ...)
			if not quiet then st.stoppedByUser = true end
			return original(self, quiet, ...)
		end
	end
	if not t then
		if N and st.goal then safe(N.Stop, N, true) end
		st.goal, st.key, st.sawSteps, st.path, st.ended = nil, nil, nil, nil, nil
		ns.bvText = nil
		return
	end
	if not N then
		ns.bvText = "The route planner is not loaded: enable its three addons (Core, Map Data, Routing) and restart the game"
		return
	end
	local px, py = ns.HBD():GetPlayerWorldPosition()
	if not px then
		ns.bvText = "the game gives no position here"
		return
	end
	local key = t.instance .. ":" .. floor(t.x) .. ":" .. floor(t.y)
	-- a new destination: BV plans it
	if key ~= st.key then
		if N.busy then
			ns.bvText = "Still working on the last route..."
			return
		end
		local goal = makeGoal(R, t)
		if not goal then
			ns.bvText = "This destination cannot be placed on a continent map"
			return
		end
		st.key, st.goal, st.startAt, st.sawSteps, st.stoppedByUser = key, goal, now, nil, nil
		local ok, err = pcall(N.Start, N, goal)
		if not ok then
			st.goal = nil
			ns.bvText = "Route error: " .. tostring(err)
		end
		return
	end
	-- BV dropped its route (stopped, or ended) while you still have a destination far away: plan it again, not
	-- more than once in 10 seconds, and never when BV said it has no way (nothing was ever planned)
	if st.goal and N.goal ~= st.goal and not N.busy and st.sawSteps and not st.stoppedByUser and ns.dist(px, py, t.x, t.y) > 25 and now - st.startAt > 10 then
		st.startAt = now
		st.sawSteps = nil
		safe(N.Start, N, st.goal)
		return
	end
	if N.steps and N.goal == st.goal then st.sawSteps = true end
	watchRide(R, N, N.steps and N.goal == st.goal and N.steps[N.current] or nil, now)
	ns.bvText = describe(R, N, t)
	-- the route has ended (arrived, or ended by hand): the HUD closes and the arrow has nothing left to follow. While
	-- you are still far off and did not end it, it is planned again instead (above), and the HUD stays
	st.ended = (st.sawSteps and not N.steps and not N.busy and (st.stoppedByUser or ns.dist(px, py, t.x, t.y) <= 25)) or false
	local step = N.steps and N.goal == st.goal and N.steps[N.current]
	if step and step.kind == "walk" and type(step.path) == "table" and #step.path >= 2 then
		-- the leg you walk: only when it is another leg or BV planned it again (its path is a new table), or something
		-- else put a route there. Not as you walk along it: Pathy follows the leg from where you are
		if st.sigSteps ~= N.steps or st.sigCurrent ~= N.current or st.sigPath ~= step.path or ns.getRoute() ~= st.path then
			if applyWalk(N, step, px, py) then
				st.sigSteps, st.sigCurrent, st.sigPath = N.steps, N.current, step.path
			end
		end
	elseif step then
		-- a lift, a flight, a ride: nothing to draw, the line says what to do
		st.sigSteps, st.path = nil, nil
		ns.clearRoute()
	elseif not N.busy then
		-- no route (none found, or it has ended): nothing for the arrow to follow
		st.sigSteps, st.path = nil, nil
		ns.clearRoute()
	end
end

-- The planner draws the way as a line on the world map and the minimap (a map-pin source of its own). Pathy has its
-- own arrow and HUD, so that line is taken away: the source is left registered but given no points (the setting
-- brings it back)
local function mapLine(R)
	local P = R and R.ns and R.ns.MapPins
	local source = P and P.providers and P.providers["routing:way"]
	if not source then return end
	if ns.cfg("showMapLine") then
		if source.pathyPoints then
			source.points, source.pathyPoints = source.pathyPoints, nil
			P:Refresh()
		end
	elseif not source.pathyPoints and type(source.points) == "function" then
		source.pathyPoints = source.points
		source.points = function() return {} end
		P:Refresh()
	end
end

local function tick(now)
	route(now)
	pcall(mapLine, routing())
	local t = ns.getTarget()
	local R = routing()
	local N = R and R.Navigate
	-- for the simple UI (just the arrow, with the instructions under it): what to do now, and where to
	if t and N and not st.ended and ns.cfg("arrow") then
		local _, _, now, target = content(R, N, t)
		ns.simpleNow, ns.simpleTarget = now, target
	else
		ns.simpleNow, ns.simpleTarget = nil, nil
	end
	if t and N and ns.cfg("guidePanel") and not st.ended then
		-- the HUD (BV's own guide window, built by BV's own code, HUD.lua); the plain panel only if that cannot be
		if ns.HUD and ns.HUD.paint(R, N, t) then
			if panel then panel:Hide() end
		else
			paintPanel(R, N, t)
		end
	else
		if panel then panel:Hide() end
		if ns.HUD then ns.HUD.hide() end
	end
end

local driver = CreateFrame("Frame")
local acc = 0
driver:SetScript("OnUpdate", function(_, dt)
	acc = acc + dt
	if acc < 0.15 then return end
	acc = 0
	if not (PathyDB and ns.HBD and ns.HBD()) then return end
	local ok, err = pcall(tick, GetTime())
	if not ok and not st.err then
		st.err = err
		ns.Print("|cffff4040routing error:|r " .. tostring(err))
	end
end)

-- /pathy bv: what BV planned and what Pathy did with it
function BV.report()
	local P = ns.Print
	local R = routing()
	P("Route planner: " .. (R and "loaded" or "|cffff4040not loaded|r (enable its three addons: Core, Map Data, Routing; then restart the game)"))
	if not R then return end
	local N = R.Navigate
	local t = ns.getTarget()
	P("destination: " .. (t and (t.name or "?") or "none (pick a quest or NPC in Pathy)"))
	P("planner's state: " .. (N.busy and "calculating" or N.steps and "has a route" or "no route"))
	local level = safe(function() return R.Level:Name(R.Level:Current()) end)
	local z = heightNow()
	P(string.format("you are on level: %s; height measurement: %s", tostring(level or "unknown"), z and string.format("%.1f yd", z) or "none (too few NPCs near)"))
	if N.steps then
		P(string.format("plan: %d steps, about %s in all", #N.steps, N.seconds and safe(N.Clock, N.seconds) or "?"))
		for i, step in ipairs(N.steps) do
			local say = safe(N.Say, N, step, step.kind == "walk" and step.yards or nil) or step.kind
			P(string.format("  %s%d. %s%s", i == N.current and "> " or "  ", i, say,
				step.kind == "walk" and string.format("  [%s, %d yd, %d points]", tostring(step.status or "ok"), floor(step.yards or 0), type(step.path) == "table" and #step.path or 0) or ""))
		end
	end
	local p = ns.getRoute()
	P(string.format("Pathy is following: %s", p and string.format("the walking leg (%d points, %s, %d yd left)", p.n, p.z and "with heights" or "no heights", floor(p.remaining or 0)) or "nothing"))
	for i = max(1, #(R.log or {}) - 4), #(R.log or {}) do P("  planner log: " .. R.log[i]) end
end
