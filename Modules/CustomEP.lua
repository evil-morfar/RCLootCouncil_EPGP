--@debug@
if LibDebug then LibDebug() end
--@end-debug@

local Ambiguate = Ambiguate
local C_Calendar = C_Calendar
local CopyTable = CopyTable
local GetGameTime = GetGameTime
local GetGuildInfo = GetGuildInfo
local GetGuildRosterInfo = GetGuildRosterInfo
local GetMapNameByID = GetMapNameByID
local GetNumGroupMembers = GetNumGroupMembers
local GetNumGuildMembers = GetNumGuildMembers
local GetRaidRosterInfo = GetRaidRosterInfo
local GetTime = GetTime
local GuildRoster = GuildRoster
local IsInGuild = IsInGuild
local IsInRaid = IsInRaid
local SecondsToTimeAbbrev = SecondsToTimeAbbrev
local UnitGUID = UnitGUID
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitInParty = UnitInParty
local UnitInRaid = UnitInRaid
local UnitIsVisible = UnitIsVisible
local _G = _G
local format = format
local ipairs = ipairs
local math = math
local pairs = pairs
local random = random
local select = select
local string = string
local strsplit = strsplit
local tContains = tContains
local table = table
local time = time
local tinsert = tinsert
local tonumber = tonumber
local tremove = tremove
local type = type
local unpack = unpack
local wipe = wipe

local addon = LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil")
local RCEPGP = addon:GetModule("RCEPGP")
local RCCustomEP = RCEPGP:NewModule("RCCustomEP", "AceConsole-3.0", "AceEvent-3.0", "AceHook-3.0", "AceComm-3.0", "AceBucket-3.0", "AceTimer-3.0")
local LEP = LibStub("AceLocale-3.0"):GetLocale("RCEPGP")
local EPGP = LibStub("AceAddon-3.0"):GetAddon("EPGP")
local LibSpec = LibStub("LibGroupInSpecT-1.1")
local GS = LibStub("LibGuildStorage-1.2")

RCCustomEP.MaxFormulas = 100 -- Maxmium formulas

function RCCustomEP:OnInitialize()
	self.candidateInfos = {} -- The information of everyone in the guild or group
	self.eventInfos = {} -- The inforamation of events within += 12h, including the invite list
	self.eventOpenQueue = {} -- The event that is waiting for process

	self.lastOtherCalendarOpenEvent = 0 -- THe time when other program runs CalendarOpenEvent()
	self:RegisterEvent("CALENDAR_OPEN_EVENT", "OPEN_CALENDAR")
	self:RegisterBucketEvent({"CALENDAR_UPDATE_EVENT_LIST", "CALENDAR_UPDATE_INVITE_LIST"}, 20, "UPDATE_CALENDAR")
	self:ScheduleRepeatingTimer("GROUP_ROSTER_UPDATE", 15, "GROUP_ROSTER_UPDATE")
	self:RegisterBucketEvent("GUILD_ROSTER_UPDATE", 20, "GUILD_ROSTER_UPDATE")
	self:SecureHook(_G.C_Calendar, "OpenEvent", "OnCalendarOpenEvent")
	EPGP.RegisterCallback(self, "StartRecurringAward", "OnStartRecurringAward")
	EPGP.RegisterCallback(self, "StopRecurringAward", "OnStopRecurringAward")
	EPGP.RegisterCallback(self, "ResumeRecurringAward", "OnResumeRecurringAward")
	GuildRoster()
	self:ProcessEventOpenQueue()
	self:ScheduleTimer("UPDATE_CALENDAR", 10)
	self:ScheduleTimer("GROUP_ROSTER_UPDATE", 2)
	self:ScheduleTimer("GUILD_ROSTER_UPDATE", 2)
	LibSpec:Rescan()
	if not EPGP.db.profile.next_award then
		self:OnStopRecurringAward()
	end
	self.defaultFormula = CopyTable(RCEPGP.defaults.profile.customEP.EPFormulas["**"])
	self.defaultFormula.standby = EPGP.db.profile.extras_p * 0.01
	self.initialize = true
end

function RCCustomEP:UnitInGroup(name)
	name = RCEPGP:GetEPGPName(name)
	return UnitInRaid(Ambiguate(name, "short")) or UnitInParty(Ambiguate(name, "short"))
end

function RCCustomEP:GROUP_ROSTER_UPDATE()
	GuildRoster()
	for i = 1, GetNumGroupMembers() or 0 do
		local name, rank, subgroup, level, _, classFileName, zone, online, isDead, groupRole, isML = GetRaidRosterInfo(i)
		if name then
			local unitID
			if IsInRaid() then
				unitID = "raid"..i
			else
				unitID = "party"..i
			end
			local fullName = RCEPGP:GetEPGPName(name)
			local guildName, guildRankName, guildRankIndex = GetGuildInfo(unitID)
			if not self.candidateInfos[fullName] then
				self.candidateInfos[fullName] = {}
			end
			local info = self.candidateInfos[fullName]
			info["guid"] = UnitGUID(unitID)
			info["fullName"] = fullName
			info["raidRank"] = rank
			info["subgroup"] = subgroup
			info["level"] = level
			info["class"] = classFileName
			info["zone"] = zone
			info["online"] = online
			info["isDead"] = isDead
			info["groupRole"] = groupRole
			info["isML"] = isML
			info["role"] = UnitGroupRolesAssigned(unitID)
			info["guid"] = UnitGUID(unitID)
			if guildName and guildRankName and guildRankIndex then -- Must check this because this is not available when offline
				info["guildName"] = guildName
				info["guildRank"] = guildRankName
				info["guildRankIndex"] = guildRankIndex
			end
			if UnitIsVisible(unitID) then
				local guid = info["guid"]
				local specInfo = LibSpec:GetCachedInfo(guid)
				if not specInfo or not specInfo.spec_role_detailed then
					LibSpec:Rescan(guid)
				end
			end
		else
			RCEPGP:DebugPrint("GROUP_ROSTER_UPDATE uncached, retry after 1s.")
			self:ScheduleTimer("GROUP_ROSTER_UPDATE", 1)
		end
	end
end

function RCCustomEP:GUILD_ROSTER_UPDATE()
	if not IsInGuild() then return end
	if (not GetNumGuildMembers()) or (GetNumGuildMembers() == 0) then
		RCEPGP:DebugPrint("RCCustomEP", "GUILD_ROSTER_UPDATE", "but no infomation is fetched.")
		return
	end
	local guildName, _, _ = GetGuildInfo("player")
	self.playerGuild = guildName

	for i = 1, GetNumGuildMembers() do
		local fullName, rank, rankIndex, level, _, zone, note, officernote, online,
		status, classFileName, achievementPoints, achievementRank, isMobile, canSoR, reputation = GetGuildRosterInfo(i)
		if fullName then
			fullName = RCEPGP:GetEPGPName(fullName)
			if not self.candidateInfos[fullName] then
				self.candidateInfos[fullName] = {}
			end
			local info = self.candidateInfos[fullName]

			info["fullName"] = fullName
			info["guildRank"] = rank
			info["guildRankIndex"] = rankIndex
			info["note"] = note
			info["officernote"] = officernote
			info["status"] = status
			info["class"] = classFileName -- NonLocalizedClassName
			info["achievementPoints"] = achievementPoints
			info["achievementRank"] = achievementRank
			info["isMobile"] = isMobile
			info["canSoR"] = canSoR
			info["reputation"] = reputation
			info["guildName"] = guildName
			if (not self:UnitInGroup(fullName)) then
				info["online"] = online
				info["level"] = level
				info["zone"] = zone
			end
		end
	end
	GuildRoster()
end

function RCCustomEP:GetEventTimeDiff(month, day, year, hour, min)
	local _
	if year < 100 then year = year + 2000 end
	local eventTime = time({year=year, month=month, day=day, hour=hour, min=min, sec=0})
	-- Get current server time
	_, month, day, year = CalendarGetDate()
	hour, min = GetGameTime()
	local now = time({year=year, month=month, day=day, hour=hour, min=min, sec=0})
	return eventTime - now
end

function RCCustomEP:GenerateEventID(offset, day, i)
	if offset >= 0 then
		return offset*10000+day*100+i
	else
		return offset*10000-day*100-i
	end
end

-- Check the events in yesterday, today and tomorrow and open all guild events within +-12h of now.
function RCCustomEP:UPDATE_CALENDAR()
	if _G.CalendarFrame and (not self:IsHooked(_G.CalendarFrame, "OnHide")) then
		self:SecureHookScript(_G.CalendarFrame, "OnHide", function() self:UPDATE_CALENDAR() end)
	end
	if _G.CalendarFrame and _G.CalendarFrame:IsShown() then
		return -- Don't update when Blizzard calendar is shown
	end
	local lastMonthInfo = C_Calendar.GetMonthInfo(-1)
	local nextMonthInfo = C_Calendar.GetMonthInfo(1)
	local monthInfo = C_Calendar.GetMonthInfo()

	local prevMonth, prevYear, prevNumDays = lastMonthInfo.month, lastMonthInfo.year,lastMonthInfo.numDays
	local nextMonth, nextYear, nextNumDays = nextMonthInfo.month, nextMonthInfo.year,nextMonthInfo.numDays
	local month	   , year	 , numDays 	   = monthInfo.month, monthInfo.year, monthInfo.numDays

	local date = C_DateAndTime.GetCurrentCalendarTime()
	local weekday, month, day, year =date.weekday, date.month,date.monthDay,date.year
	local existEvents = {}
	wipe(self.eventOpenQueue)

	local monthYesterday, dayYesterday, yearYesterday, offsetYesterday
	if day == 1 then
		offsetYesterday = -1
		monthYesterday = prevMonth
		dayYesterday = prevNumDays
		yearYesterday = prevYear
	else
		offsetYesterday = 0
		monthYesterday = month
		dayYesterday = day - 1
		yearYesterday = year
	end

	local monthTomorrow, dayTomorrow, yearTomorrow, offsetTomorrow
	if day == numDays then
		offsetTomorrow = 1
		monthTomorrow = nextMonth
		dayTomorrow = 1
		yearTomorrow = nextYear
	else
		offsetTomorrow = 0
		monthTomorrow = month
		dayTomorrow = day + 1
		yearTomorrow = year
	end

	-- Check yesterday
	for i=1, _G.C_Calendar.GetNumDayEvents(offsetYesterday, dayYesterday) do
		local event = _G.C_Calendar.GetDayEvent(offsetYesterday, dayYesterday, i)
		local id = self:GenerateEventID(offsetYesterday, dayYesterday, i)
		if event then
			local title, startTime, calendarType = event.title, event.startTime, event.calendarType
			if event and event.calendarType == "GUILD_EVENT" and math.abs(self:GetEventTimeDiff(startTime.month, startTime.monthDay, startTime.year, startTime.hour, startTime.minute)) < 12*60*60 then -- within +- 12h
				existEvents[id] = true
				tinsert(self.eventOpenQueue, {offsetYesterday, dayYesterday, i})
			end
		end
	end

	-- Check today
	for i=1, _G.C_Calendar.GetNumDayEvents(0, day) do
		local event = _G.C_Calendar.GetDayEvent(0, day, i)
		local id = self:GenerateEventID(0, day, i)
		if event then
			local title, startTime, calendarType = event.title, event.startTime, event.calendarType
			if event and event.calendarType == "GUILD_EVENT" and math.abs(self:GetEventTimeDiff(startTime.month, startTime.monthDay, startTime.year, startTime.hour, startTime.minute)) < 12*60*60 then -- within +- 12h
				existEvents[id] = true
				tinsert(self.eventOpenQueue, {0, day, i})
			end
		end
	end

	-- Check yesterday
	for i=1, _G.C_Calendar.GetNumDayEvents(offsetTomorrow, dayTomorrow) do
		local event = _G.C_Calendar.GetDayEvent(offsetTomorrow, dayTomorrow, i)
		local id = self:GenerateEventID(offsetTomorrow, dayTomorrow, i)
		if event then
			local title, startTime, calendarType = event.title, event.startTime, event.calendarType
			if event and event.calendarType == "GUILD_EVENT" and math.abs(self:GetEventTimeDiff(startTime.month, startTime.monthDay, startTime.year, startTime.hour, startTime.minute)) < 12*60*60 then -- within +- 12h
				existEvents[id] = true
				tinsert(self.eventOpenQueue, {offsetTomorrow, dayTomorrow, i})
			end
		end
	end

	for id, _ in pairs(self.eventInfos) do
		if not existEvents[id] then
			self.eventInfos[id] = nil
		end
	end
end

-- This module calls CalendarOpenEvent with additional argument identifer to know if the call if made by us.
function RCCustomEP:OnCalendarOpenEvent(offset, day, index, identifier)
	if identifier ~= "RCCustomEP" then
		self.lastOtherCalendarOpenEvent = GetTime()
	end
end

-- Process event open queue (open one event in the queue) every several second.
function RCCustomEP:ProcessEventOpenQueue()
	self:ScheduleTimer("ProcessEventOpenQueue", 2)
	if _G.CalendarFrame and _G.CalendarFrame:IsShown() then
		return -- Don't update when Blizzard calendar is shown
	end
	if GetTime() < self.lastOtherCalendarOpenEvent + 20 then  -- temporary supends this module open events when other program open events for 20s
		return
	end
	local entry = tremove(self.eventOpenQueue, 1)
	if entry then
		CalendarOpenEvent(entry[1], entry[2], entry[3], "RCCustomEP")
	end
end

function RCCustomEP:OPEN_CALENDAR()
	local event = _G.C_Calendar.GetEventInfo()
	if not event then return end
	local day, month,year, hour,minute = event.time.monthDay,event.time.month,event.time.year,event.time.hour,event.time.minute


	if event.calendarType == "GUILD_EVENT" and math.abs(self:GetEventTimeDiff(month, day, year, hour, minute)) < 12*60*60 then
		local eventIndex = _G.C_Calendar.GetEventIndex()
		local monthOffset, day, index = eventIndex.offsetMonths, eventIndex.monthDay,eventIndex.eventIndex
		local id = self:GenerateEventID(monthOffset, day, index)
		if not self.eventInfos[id] then
			self.eventInfos[id] = {}
		end
		self.eventInfos[id].title = event.title
		self.eventInfos[id].month = month
		self.eventInfos[id].day = day
		self.eventInfos[id].year = year
		self.eventInfos[id].hour = hour
		self.eventInfos[id].minute = minute

		if not self.eventInfos[id].signupList then
			self.eventInfos[id].signupList = {}
		end
		wipe(self.eventInfos[id].signupList)

		for i = 1, _G.C_Calendar.GetNumInvites() do
			local inv = _G.C_Calendar.EventGetInvite(i)
			local name, level, className, classFileName, inviteStatus, modStatus, inviteIsMine, inviteType = inv.name, inv.level,inv.className,inv.classFileName,inv.inviteStatus,inv.modStatus,inv.inviteIsMine,inv.type
			if name then
				name = RCEPGP:GetEPGPName(name)
				local info
				if not self.eventInfos[id].signupList[name] then
					self.eventInfos[id].signupList[name] = {}
				end
				info = self.eventInfos[id].signupList[name]
				local invRespTime = _G.C_Calendar.EventGetInviteResponseTime(i)
				info.month = invRespTime.month
				info.day = invRespTime.monthDay
				info.year = invRespTime.year
				info.hour = invRespTime.hour
				info.minute = invRespTime.minute
				info.inviteStatus = inviteStatus --_G.CALENDAR_INVITESTATUS_OUT _G.CALENDAR_INVITESTATUS_TENTATIVE
				info.modStatus = modStatus
				info.inviteIsMine = inviteIsMine
			end
		end
	end
end

----- Modified from EPGP/epgp_recurring.lua ----------------------------------

RCCustomEP.recurTickFrame = CreateFrame("Frame", "RCCustomEP_Recur_Tick_Frame")
RCCustomEP.recurTickFrame.timeout = 0

RCCustomEP.recurTickFrame:SetScript("OnUpdate", function(self, elapsed)
	if _G["EPGP_RecurringAwardFrame"]:IsShown() then
		-- This frame is used by EPGP to do the same thing as RCCustomEP.recurTickFrame. Let's not conflict with it
		return
	end
	if not EPGP.db then return end

	local vars = EPGP.db.profile
	if not vars.next_award then return end

	local now = GetTime()
	if now > vars.next_award and GS:IsCurrentState() then
		RCCustomEP:IncMassEPBy(vars.next_award_reason, vars.next_award_amount, unpack(vars.next_formulas or {}))
		vars.next_award = vars.next_award + vars.recurring_ep_period_mins * 60
	end
	self.timeout = self.timeout + elapsed
	if self.timeout > 0.5 then
		EPGP.callbacks:Fire("RecurringAwardUpdate",
		vars.next_award_reason,
		vars.next_award_amount,
		vars.next_award - now)
		self.timeout = 0
	end
end)
RCCustomEP.recurTickFrame:Hide()

function RCCustomEP:GetFormula(formulaIndexOrName)
	if formulaIndexOrName == "EPGP_Default" or tonumber(formulaIndexOrName) == 0 then
		return self.defaultFormula
	end
	for index=0,RCEPGP.db.customEP.EPFormulas.count do -- Start from 0 to include EPGP_Default
		local f = RCEPGP.db.customEP.EPFormulas[index]
		if index == tonumber(formulaIndexOrName) or f.name == formulaIndexOrName then
			return f
		end
	end
end

--@param ... formulas
function RCCustomEP:StartRecurringEP(reason, amount, periodMin, ...)
	if not tonumber(periodMin) and tonumber(periodMin) <= 0 then
		RCEPGP:Print(LEP["period_not_positive_error"])
		return false
	end
	amount = tonumber(amount)
	if not amount then
		RCEPGP:Print(LEP["amount_must_be_number"])
		return false
	end
	if type(reason) ~= "string" or type(amount) ~= "number" or #reason == 0 then
		return false
	end
	if select(1, ...) then
		for _, formulaIndexOrName in ipairs({...}) do
			local formula = self:GetFormula(formulaIndexOrName)
			if not formula then
				return RCEPGP:Print(format(LEP["Formula 'formula' does not exist"], formulaIndexOrName))
			end
		end
	end

	local vars = EPGP.db.profile

	local formulas = vars.next_formulas
	if not formulas then
		formulas = {}
	end
	if select(1, ...) then
		for _, formulaIndexOrName in ipairs({...}) do
			tinsert(formulas, self:GetFormula(formulaIndexOrName).name)
		end
	else
		tinsert(formulas, "EPGP_Default")
	end
	if vars.next_award then -- already running.
		if not vars.next_formulas then
			tinsert(formulas, 1, "EPGP_Default")
		end
		RCEPGP:Print(LEP["recurring_award_running"])
	else
		if tonumber(periodMin) then
			vars.recurring_ep_period_mins = tonumber(periodMin)
		end
	end

	 local fmt, val = SecondsToTimeAbbrev(vars.recurring_ep_period_mins * 60)
	RCEPGP:Print(format(LEP["recurring_award_formulas"], table.concat(formulas, ", ")).." ("..fmt:format(val)..")")

	EPGP:StartRecurringEP(reason, amount)
	vars.next_formulas = formulas
	_G["EPGP_RecurringAwardFrame"]:Hide()
	self.recurTickFrame:Show()

	return true
end

function RCCustomEP:OnStartRecurringAward()
	local vars = EPGP.db.profile
	vars.next_formulas = nil
	self.recurTickFrame:Hide()
end

function RCCustomEP:OnStopRecurringAward()
	local vars = EPGP.db.profile
	vars.next_formulas = nil
	self.recurTickFrame:Hide()
end

function RCCustomEP:OnResumeRecurringAward()
	local vars = EPGP.db.profile
	if vars.next_formulas then
		self.recurTickFrame:Show()
		local frame = _G["EPGP_RecurringAwardFrame"]
		local RecurringTicker = frame:GetScript("OnUpdate")
		frame:SetScript("OnUpdate", nil)
		self:ScheduleTimer(function()
			frame:Hide()
			frame:SetScript("OnUpdate", RecurringTicker )
		end, 0)
	end
end

-------------------------------------------------------------------------------

-- Process the table "[name] = amount" and do the actual awarding.
function RCCustomEP:ProcessAwardedAmount(reason, awarded_amount)
	for name, amount in pairs(awarded_amount) do
		awarded_amount[name] = math.floor(awarded_amount[name] + 0.5)
	end

	local awarded_mains_amount = {} -- [mainname] = {amount, name}
	for name, amount in pairs(awarded_amount) do
		name = RCEPGP:GetEPGPName(name)
		local ep, _, main = EPGP:GetEPGP(name)
		main = main or name
		if ep then
			if not awarded_mains_amount[main] then
				awarded_mains_amount[main] = {amount=amount, name=name}
			elseif awarded_mains_amount[main].amount < amount then
				awarded_mains_amount[main] = {amount=amount, name=name}
			end
		end
	end

	local unsorted_list = {} -- [amount] = {[name1]=true, [name2]=true, ...}
	for main, entry in pairs(awarded_mains_amount) do
		local amount = entry.amount
		local name = entry.name
		if not unsorted_list[amount] then
			unsorted_list[amount] = {[name]=true}
		else
			unsorted_list[amount][name] = true
		end
	end

	local sorted_list = {} -- [index] = {amount=amount, names={[name1]=true, [name2]=true, ...}}, sorted by amount
	for amount, names in pairs(unsorted_list) do
		tinsert(sorted_list, {amount=amount, names=names})
	end
	table.sort(sorted_list, function(a, b) return a.amount > b.amount end)

	for _, entry in ipairs(sorted_list) do
		local amount = entry.amount
		local awarded = entry.names
		if amount ~= 0 then
			for name, _ in pairs(awarded) do
				RCEPGP:IncEPSecure(name, reason, amount, true)
			end
			EPGP.callbacks:Fire("MassEPAward", awarded, reason, amount)
		end
	end
end

function RCCustomEP:ParseZonesStr(zonesStr)
	local zones = {strsplit(",", zonesStr)}
	for k, zone in ipairs(zones) do
		zones[k] = zone:gsub("^ +", "") -- remove prefix spaces
		zones[k] = zone:gsub(" +$", "") -- remove trailing spaces
		if tonumber(zone) then
			zones[k] = GetMapNameByID(tonumber(zone)) or "Unknown"
		end
	end
	return zones
end


--@param ... the formulas
function RCCustomEP:IncMassEPBy(reason, amount, ...)
	amount = tonumber(amount)
	if not amount then
		RCEPGP:Print(LEP["amount_must_be_number"])
		return
	end

	if not select(1, ...) then
		RCEPGP:Debug("Run Origin IncMassEPBy", reason, amount)
		return EPGP:IncMassEPBy(reason, amount)
	end

	if not self.initialize then return end

	self:GROUP_ROSTER_UPDATE()
	local awarded_amount = {}
	RCEPGP:Debug("Custom MassEP", reason, amount, ...)

	local formulas = {...}
	for k, formulaIndexOrName in ipairs(formulas) do
		local formula = self:GetFormula(formulaIndexOrName)
		if not formula then
			return RCEPGP:Print(format(LEP["Formula 'formula' does not exist"], formulaIndexOrName))
		end
		formulas[k] = formula.name

		for name, info in pairs(self.candidateInfos) do
			name = RCEPGP:GetEPGPName(name)
			local ep, _, main = EPGP:GetEPGP(name)
			main = main or name
			if ep then
				local onlineCoeff
				if info["online"] then
					onlineCoeff = formula.online
				else
					onlineCoeff = formula.offline
				end
				local groupCoeff
				if UnitInRaid(Ambiguate(name, "short")) or UnitInParty(Ambiguate(name, "short")) then
					groupCoeff = formula.inGroup
				elseif EPGP:IsMemberInExtrasList(name) then
					groupCoeff = formula.standby
				else
					local signedUpInEvent = false
					for _, event in pairs(self.eventInfos) do
						local signupStatus = event.signupList[name]
						if signupStatus then
							local inviteStatus = signupStatus.inviteStatus
							if inviteStatus ~= _G.CALENDAR_INVITESTATUS_OUT
							and inviteStatus ~= _G.CALENDAR_INVITESTATUS_TENTATIVE then
								signedUpInEvent = true
							end
						end
					end
					if signedUpInEvent then
						groupCoeff = formula.calendarSignedUp
					else
						groupCoeff = formula.completelyNotInGroup
					end
				end
				local rankCoeff
				if info["guildName"] ~= self.playerGuild then
					rankCoeff = formula.notInGuild
				else
					local rankIndex = info["guildRankIndex"] or ""
					rankCoeff = formula["isRank"..rankIndex] or 0
				end
				local zonesCoeff
				local zones = self:ParseZonesStr(formula.zones)
				if tContains(zones, info["zone"] or "") then
					zonesCoeff = formula.inZones
				else
					zonesCoeff = formula.notInZones
				end

				local amountWithCoeff = amount*onlineCoeff*groupCoeff*rankCoeff*zonesCoeff
				if amountWithCoeff ~= 0 then
					awarded_amount[name] = awarded_amount[name] and (awarded_amount[name] + amountWithCoeff) or amountWithCoeff
				end
			end
		end
	end

	RCEPGP:Print(format(LEP["customEP_massEP_by_formulas"], table.concat(formulas, ", ")))
	self:ProcessAwardedAmount(reason, awarded_amount)
end

-----------------------------------------------------------------------------------------------

function RCCustomEP:EPFormulaGetUnrepeatedName(name, index)
	name = string.gsub(name, " ", "_") -- We don't allow space in the name, so replace it by "_"
	local function isRepeated(name)
		for i=1,RCEPGP.db.customEP.EPFormulas.count do
			local entry = RCEPGP.db.customEP.EPFormulas[i]
			if entry.name == name and i ~= index then
				return true
			end
		end
		return false
	end
	if not isRepeated(name) then
		return name
	else
		local i = 2
		while isRepeated(name.."_"..i) do
			i = i + 1
		end
		return name.."_"..i
	end
end

----- ZeroSum ------
-- Convert float to int by probability
local function FloatToIntByProb(float)
	local floor = math.floor(float)
	local rem = float - floor
	local rand = random()
	if rand < rem then
		return floor + 1
	else
		return floor
	end
end

-- Award amount to the target, and award -amount to people satisfy pred(name, target) to keep zerosum.
function RCCustomEP:IncMassEPZeroSum(reason, amount, target, pred)
	amount = tonumber(amount)
	if not amount then
		RCEPGP:Print(LEP["amount_must_be_number"])
		return
	end

	if not self.initialize then return end

	target = RCEPGP:GetEPGPName(target)

	local awarded_amount = {}
	RCEPGP:Debug("RCCustomEP:IncMassEPZeroSum", reason, amount, target, pred)

	self:GROUP_ROSTER_UPDATE()
	local count = 0
	for name, info in pairs(self.candidateInfos) do
		name = RCEPGP:GetEPGPName(name)
		local ep, _, main = EPGP:GetEPGP(name)
		if ep then
			if name ~= target and pred(name, target) then
				awarded_amount[name] = 0
				count = count + 1
			elseif name == target then
				awarded_amount[name] = amount
			end
		end
	end

	if count > 0 then
		local averageAmount = FloatToIntByProb(-amount/count)
		for name, amount in pairs(awarded_amount) do
			if name ~= target then
				awarded_amount[name] = averageAmount
			end
		end
	end

	self:ProcessAwardedAmount(reason, awarded_amount)
end

-- ZerSum award to people in the same zone in the group as you
function RCCustomEP:IncMassEPZeroSumGeneral(reason, amount, target)
	local function pred(name, target)
		return self:UnitInGroup(name) and self.candidateInfos[target].zone and self.candidateInfos[name].zone == self.candidateInfos[target].zone
	end
	self:IncMassEPZeroSum(reason, amount, target, pred)
end

-- ZerSum award to people in the same zone in the group as you
function RCCustomEP:IncMassEPZeroSumRole(reason, amount, target)
	local function pred(name, target)
		return self:UnitInGroup(name) and self.candidateInfos[target].zone and self.candidateInfos[name].zone == self.candidateInfos[target].zone
			and self.candidateInfos[target].role == self.candidateInfos[name].role
	end
	self:IncMassEPZeroSum(reason, amount, target, pred)
end

-- tank, healer, melee, ranged
function RCCustomEP:GetDetailedRole(name)
	local name = RCEPGP:GetEPGPName(name)
	local guid = self.candidateInfos[name] and self.candidateInfos[name].guid
	return guid and LibSpec:GetCachedInfo(guid) and LibSpec:GetCachedInfo(guid).spec_role_detailed
end

-- ZerSum award to people in the same zone in the group as you (ONLY WORK IN RAID. LibSpec not working in party)
function RCCustomEP:IncMassEPZeroSumDetailedRole(reason, amount, target)
	local function pred(name, target)
		local target = RCEPGP:GetEPGPName("player")
		return self:UnitInGroup(name) and self.candidateInfos[target].zone and self.candidateInfos[name].zone == self.candidateInfos[target].zone
			and self:GetDetailedRole(target) == self:GetDetailedRole(name)
	end
	self:IncMassEPZeroSum(reason, amount, target, pred)
end
