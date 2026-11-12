-- Pathy's HUD: a copy of BV Addon Suite's guide window, made by BV's own code.
--
-- BV's guide (the medallion with its disc, ring and arrow markers, the step type and count, the big "what to do
-- now", where to, "THEN ...", the time left, and its buttons: safe way, log, export, search anew, end the way) is
-- built and painted by Routing.Guide. Pathy runs those same functions on a frame of its own, so it looks exactly
-- like BV's and says exactly what BV's says, and follows BV's changes, with none of BV's code copied here. What is
-- Pathy's: where it stands (drag it anywhere; it is not BV's window and does not move that one), the right-click
-- menu, and that it is never over the game's windows.
--
-- If BV's guide cannot be built (BV's interface not ready, or a BV version this does not fit), BV.lua shows its
-- plain text panel instead.

local ADDON, ns = ...

local HUD = {}
ns.HUD = HUD

local obj -- BV's Guide, with a frame of Pathy's: obj.frame
local failed

local function reportOnce(err)
	if not HUD.err then
		HUD.err = err
		ns.Print("|cffff4040HUD error (a plain panel is shown instead):|r " .. tostring(err))
	end
end

-- Anchored only when the spot has changed: anchoring the frame again (even to the same place) makes the game think
-- the mouse has left whatever it was over, and a tooltip on one of the HUD's buttons vanishes at once
local function place(f)
	local at = PathyDB.hudAt
	local point, x, y
	if type(at) == "table" and type(at.x) == "number" and type(at.y) == "number" then
		point, x, y = "CENTER", at.x, at.y
	else
		-- not moved yet: under the arrow's own text, wherever that stands
		point = "TOP"
		x, y = ns.cfg("textX") * UIParent:GetWidth(), ns.cfg("textY") * UIParent:GetHeight() - 40
	end
	local was = f.pathyAt
	if was and was[1] == point and math.abs(was[2] - x) < 0.5 and math.abs(was[3] - y) < 0.5 then return end
	f.pathyAt = { point, x, y }
	f:ClearAllPoints()
	f:SetPoint(point, UIParent, "BOTTOMLEFT", x, y)
end

function HUD.menu(owner)
	local R = ns.routing()
	if not (R and obj) then return end
	owner.bvMenuStyle = obj.style
	local cfg = R:Config()
	R.ns.UI:ContextMenu(owner, {
		{ value = "ground", label = "Show background", checked = cfg.guideGround == true },
		{ value = "reset", label = "Reset position" },
		{ value = "off", label = "Hide this HUD" },
	}, function(value)
		if value == "ground" then
			obj:SetBare(cfg.guideGround == true) -- BV's own setting, shared with its window
		elseif value == "reset" then
			PathyDB.hudAt = nil
			place(owner)
		elseif value == "off" then
			PathyDB.guidePanel = false
			HUD.hide()
			ns.Print("The HUD is hidden: |cffffff00/pathy hud|r shows it again.")
		end
	end)
end

-- "THEN <where>" says nothing new on the last step, where the line above already names the destination ("to
-- Warden Thelwater" and then "there: Warden Thelwater"): then the label and its line both go
local function tidy(f, N)
	local goal = N and N.goal and N.goal.name
	local last = N and N.steps and not N.steps[(N.current or 1) + 1]
	local redundant = false
	if last and goal and goal ~= "" then
		for _, label in ipairs({ f.target, f.now }) do
			local text = label:GetText()
			if text and text:find(goal, 1, true) then redundant = true end
		end
	end
	f.thenLabel:SetShown(not redundant)
	f.next:SetShown(not redundant)
end

-- The buttons along the top: the export button is not wanted, the log button only if the setting says so, and the
-- others close up over the gaps
local function layout(f)
	local R = ns.routing()
	local M = R and R.ns.DesignSystem and R.ns.DesignSystem.Metrics
	local function at(frame, point, rel, relPoint, x, y)
		frame:ClearAllPoints()
		if M and M.Point then M.Point(frame, point, rel, relPoint, x, y) else frame:SetPoint(point, rel, relPoint, x, y) end
	end
	if f.export then f.export:Hide() end
	local showLog = ns.cfg("showLogButton") and true or false
	f.log:SetShown(showLog)
	at(f.log, "RIGHT", f.restart, "LEFT", -4, 0)
	at(f.safe, "RIGHT", showLog and f.log or f.restart, "LEFT", -4, 0)
	at(f.count, "RIGHT", f.safe, "LEFT", -6, 0)
end

function HUD.refresh()
	local f = obj and obj.frame
	if f then layout(f) end
end

-- BV's constructor on Pathy's own object: the frame it makes is ours
local function build(R)
	if failed then return end
	local G = R.Guide
	local UI = R.ns and R.ns.UI
	if not (G and G.Build and G.Paint and UI and UI.InterfaceStyle) then return end
	-- BV's painting helpers read the style from the module, not from the object: it must be there
	G.style = G.style or UI:InterfaceStyle()
	if not G.style then return end -- BV's interface is not ready yet: tried again
	-- (its own empty frame and preview slots: else it would find BV's own window, if that was ever built, through G)
	local o = setmetatable({ frame = false, preview = false }, { __index = G })
	local ok, f = pcall(G.Build, o)
	if not ok then
		failed = true
		return reportOnce(f)
	end
	if not f then return end
	obj = o
	f.forward:Hide()
	-- BV's is DIALOG, over everything; this stays under the game's windows, and under Pathy's arrow, which is drawn
	-- in its medallion (the arrow's frame is at level 60)
	f:SetFrameStrata("LOW")
	f:SetFrameLevel(10)
	f:SetToplevel(false)
	-- the buttons' tooltips in Pathy's words, and the layout without the export button
	local UI2 = R.ns.UI
	local function tip(widget, title, body)
		if widget then pcall(UI2.AttachTooltip, UI2, widget, title, body) end
	end
	tip(f.stop, "End the way", "Ends the way and the guide.")
	tip(f.restart, "Search anew", "The way to the same place searched again from where you are now.")
	tip(f.log, "Log", "What the route planner did for this way: the plan, its steps, levels, new searches.")
	tip(f.safe, "Safe way", "Switches this way between safe (keeps to roads, swims little, goes round zones above your level) and normal, and searches it again.")
	tip(f.flightTip, "Flight points not known", "A flight map shows only its own continent. Talk to a flight master there and open the flight map once: the way then uses the flight points you have.")
	f.guideHelp = "The arrow points along the route. Drag the guide to move it; right-click it for its menu."
	layout(f)
	-- The painter hides the small "flight points not known" strip and shows it again every time it paints (twenty
	-- times a second) whenever there is a flight note; hiding a control that has a tooltip also hides the shared
	-- tooltip, so a tooltip on any button vanished within a twentieth of a second. That one Hide is made to do
	-- nothing: the painter's own SetShown still shows and hides the strip as the note comes and goes.
	if f.flightTip then f.flightTip.Hide = function() end end
	-- not BV's window: its own placement, ticker and menu are not wanted
	f:SetScript("OnShow", nil)
	f:SetScript("OnHide", nil)
	f:SetScript("OnDragStart", function(self)
		self.pathyMoving = true
		self:StartMoving()
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self.pathyMoving = nil
		local x, y = self:GetCenter()
		if x and y then PathyDB.hudAt = { x = x, y = y } end
	end)
	f:SetScript("OnMouseUp", function(self, button)
		if button == "RightButton" then HUD.menu(self) end
	end)
	-- the button that ends the way ends Pathy's guiding too (else Pathy would plan it again)
	if f.stop and f.stop.SetScript then
		pcall(f.stop.SetScript, f.stop, "OnClick", function()
			local R2 = ns.routing()
			if R2 and R2.Navigate then pcall(R2.Navigate.Stop, R2.Navigate) end
			ns.stop("stopped")
		end)
	end
	-- painted twenty times a second, as BV's is, while it is shown
	local acc = 0
	f:SetScript("OnUpdate", function(self, dt)
		acc = acc + dt
		if acc < 0.05 then return end
		acc = 0
		local R2 = ns.routing()
		local N = R2 and R2.Navigate
		if N and (N.steps or N.busy) and ns.getTarget() then
			local good, err = pcall(o.Paint, o)
			if not good then reportOnce(err) end
			-- BV's flat arrow (the filled "course") gives way to Pathy's 3D arrow in the same place, and its
			-- hollow target point (the diamond on the ring) is not shown: it was not clear what it meant. The
			-- forward tick and the symbols (a lift, a flight) stay as BV draws them
			f.course:Hide()
			f.point:Hide()
			f.forward:Hide() -- the short white line at the top of the circle
			-- already aboard a tram (BV does not notice that one and says "departure time not known yet")
			local step = N.steps and N.steps[N.current or 1]
			if step and step.kind == "transport" and ns.riding and ns.riding() then
				local parts = ns.safe(N.Parts, N, step) or {}
				o:SetNow("Riding " .. (parts.target or ""))
				f.target:SetText("You are on it: stay on until you arrive.")
			end
			tidy(f, N)
		end
	end)
	place(f)
	return f
end

function HUD.hide()
	if obj and obj.frame then obj.frame:Hide() end
end

-- For Pathy's 3D arrow: where the medallion is (screen units from the bottom left), the arrow's length there, and
-- the HUD's accent colour, so the arrow takes the flat arrow's place and looks like the rest of the window. false
-- while the medallion shows a symbol instead (a lift, a flight, a ride, "?"); nothing when the HUD is not shown.
function HUD.arrowSpot()
	local f = obj and obj.frame
	if not (f and f:IsShown() and f.medal and f.arrow and ns.getTarget()) then return end
	if f.arrow:IsShown() then
		-- a symbol for a lift, flight or ride stays; BV's "?" (it has no direction to give) does not: Pathy's own
		-- arrow has one
		if f.arrowSymbol ~= "circle-help" then return false end
		f.arrow:Hide()
	end
	local x, y = f.medal:GetCenter()
	if not x then return end
	local s = f.medal:GetEffectiveScale() / UIParent:GetEffectiveScale()
	local r, g, b = 1, 0.82, 0
	local style = obj.style
	if style and style.Color then
		local key = style.materialProfile == "interface" and "accentText" or "accent" -- as BV's own course arrow
		local ok, cr, cg, cb = pcall(style.Color, style, key)
		if ok and cr then r, g, b = cr, cg, cb end
	end
	if ns.cfg("hudColourOn") then
		local c = ns.cfg("hudColour")
		r, g, b = c[1], c[2], c[3]
	end
	return x * s, y * s, f.medal:GetWidth() * s * 0.9, r, g, b
end

-- Called ten times a second by BV.lua while Pathy guides. True when this HUD is what is shown (else BV.lua shows
-- its plain panel).
function HUD.paint(R, N, t)
	if not ns.cfg("guidePanel") then
		HUD.hide()
		return false
	end
	local f = obj and obj.frame or build(R)
	if not f then return false end
	if not f.pathyMoving and not (type(PathyDB.hudAt) == "table") then place(f) end -- following the arrow's text
	if not f:IsShown() then f:Show() end
	if not (N.steps or N.busy) then
		-- no route: BV's own window would be gone here; this one says so
		obj:SetHead("NO ROUTE", "")
		obj:SetNow(ns.bvText or "No route")
		f.target:SetText("")
		f.next:SetText("")
		f.time:SetText("")
		f.clock:Hide()
		f.flight:Hide()
		f.flightIcon:Hide()
		f.flightTip:Hide()
		f.course:Hide()
		f.point:Hide()
		f.thenLabel:Hide()
		f.next:Hide()
		obj:NeutralDirection("circle-help")
	end
	return true
end
