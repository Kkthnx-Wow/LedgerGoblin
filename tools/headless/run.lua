-- Headless LedgerGoblin tests (Lua 5.1, no game client).
-- Usage: lua5.1 run.lua <path to the LedgerGoblin addon folder>
local addonDir = assert(arg[1], "addon dir")
package.path = arg[0]:gsub("run%.lua$", "") .. "?.lua;" .. package.path
local env = require("wowenv")
env.install()

local failures, passes = 0, 0
local function check(cond, label)
	if cond then
		passes = passes + 1
	else
		failures = failures + 1
		print("FAIL  " .. label)
	end
end
local function eq(a, b, label)
	check(a == b, label .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

-- ------------------------------------------------------------------ items
local ITEMS = {
	[2447] = { name = "Peacebloom", quality = 1, bind = 0, class = 7, sub = 9 },
	[2770] = { name = "Copper Ore", quality = 1, bind = 0, class = 7, sub = 7 },
	[2589] = { name = "Linen Cloth", quality = 1, bind = 0, class = 7, sub = 5 },
	[100] = { name = "Bound Sword", quality = 2, bind = 1, class = 2, sub = 7 },
	[101] = { name = "Fancy Ring", quality = 3, bind = 2, class = 4, sub = 0 },
	[102] = { name = "Warband Tabard", quality = 1, bind = 8, class = 4, sub = 0 },
}

local function link(id)
	return "|cffffffff|Hitem:" .. id .. "::::|h[" .. ITEMS[id].name .. "]|h|r"
end

C_Item = {
	GetItemInfo = function(x)
		local id = type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
		if not id then
			for k, v in pairs(ITEMS) do
				if v.name == x then
					id = k
				end
			end
		end
		local d = id and ITEMS[id]
		if not d then
			return nil
		end
		return d.name, link(id), d.quality, 1, 1, "", "", 200, "", 1, 1, d.class, d.sub, d.bind
	end,
	GetItemInfoInstant = function(x)
		local id = type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
		local d = ITEMS[id]
		return id, "", "", "", 1000 + id, d.class, d.sub
	end,
	RequestLoadItemDataByID = function() end,
}

-- ------------------------------------------------------------------- bags
local bags = {}
local SIZES = { [0] = 16, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
local cursor
local actions = {}

local function put(bag, slot, id, count, extra)
	bags[bag] = bags[bag] or {}
	local it = { id = id, count = count or 1 }
	for k, v in pairs(extra or {}) do
		it[k] = v
	end
	bags[bag][slot] = it
end

C_Container = {
	GetContainerNumSlots = function(bag)
		return SIZES[bag] or 0
	end,
	GetContainerNumFreeSlots = function(bag)
		local used = 0
		for _ in pairs(bags[bag] or {}) do
			used = used + 1
		end
		return (SIZES[bag] or 0) - used
	end,
	GetContainerItemInfo = function(bag, slot)
		local it = bags[bag] and bags[bag][slot]
		if not it then
			return nil
		end
		return {
			itemID = it.id,
			stackCount = it.count,
			hyperlink = link(it.id),
			quality = ITEMS[it.id].quality,
			isLocked = it.locked or false,
			isBound = it.bound or false,
		}
	end,
	PickupContainerItem = function(bag, slot)
		cursor = { bag = bag, slot = slot, count = bags[bag][slot].count }
		actions[#actions + 1] = "pickup " .. bag .. ":" .. slot
	end,
	SplitContainerItem = function(bag, slot, n)
		cursor = { bag = bag, slot = slot, count = n }
		actions[#actions + 1] = "split " .. bag .. ":" .. slot .. " x" .. n
	end,
}

-- -------------------------------------------------------------- send mail
local staged, stagedMoney, sent = {}, 0, {}
ClickSendMailItemButton = function(i)
	if cursor then
		local it = bags[cursor.bag][cursor.slot]
		staged[i] = { id = it.id, count = cursor.count }
		cursor = nil
	end
end
GetSendMailItem = function(i)
	local s = staged[i]
	if s then
		return ITEMS[s.id].name, s.id, 1, s.count, 1
	end
end
HasSendMailItem = function(i)
	return staged[i] ~= nil
end
GetSendMailItemLink = function(i)
	return staged[i] and link(staged[i].id)
end
SetSendMailMoney = function(c)
	stagedMoney = c
end
GetSendMailMoney = function()
	return stagedMoney
end
GetSendMailPrice = function()
	local n = 0
	for _ in pairs(staged) do
		n = n + 1
	end
	return 30 * math.max(1, n) + stagedMoney
end
ClearSendMail = function()
	staged, stagedMoney = {}, 0
end
SendMail = function(to, subject)
	local units = 0
	for _, s in pairs(staged) do
		units = units + s.count
	end
	sent[#sent + 1] = { to = to, subject = subject, units = units, money = stagedMoney }
end
local selectedTab = 1
MailFrameTab2 = {
	Click = function()
		selectedTab = 2
	end,
}
PanelTemplates_GetSelectedTab = function()
	return selectedTab
end

-- ------------------------------------------------------------------ inbox
local inbox = {}
local commands = {}
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"
AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"

GetInboxNumItems = function()
	return #inbox, #inbox
end
GetInboxHeaderInfo = function(i)
	local m = inbox[i]
	if not m then
		return
	end
	local count = 0
	for _ in pairs(m.items or {}) do
		count = count + 1
	end
	return nil, nil, m.sender, m.subject or "", m.money or 0, m.cod or 0, m.days or 20, count > 0 and count or nil, false, false, false, m.canReply ~= false, m.gm or false
end
GetInboxInvoiceInfo = function(i)
	local m = inbox[i]
	if not m then
		return nil
	end
	return m.invoice, m.item, m.who, m.bid, nil, nil, nil, nil, nil, nil, m.count
end
HasInboxItem = function(i, a)
	return inbox[i] and inbox[i].items and inbox[i].items[a] ~= nil
end
GetInboxItem = function(i, a)
	local it = inbox[i].items[a]
	return ITEMS[it.id].name, it.id, 1, it.count
end
local function dropIfEmpty(i)
	local m = inbox[i]
	if (m.money or 0) == 0 and not next(m.items or {}) then
		table.remove(inbox, i)
	end
end
TakeInboxMoney = function(i)
	commands[#commands + 1] = "money " .. inbox[i].tag
	env.money = env.money + inbox[i].money
	inbox[i].money = 0
	dropIfEmpty(i)
	env.fire("PLAYER_MONEY")
end
AutoLootMailItem = function(i)
	commands[#commands + 1] = "loot " .. inbox[i].tag
	env.money = env.money + (inbox[i].money or 0)
	inbox[i].money = 0
	inbox[i].items = {}
	dropIfEmpty(i)
	env.fire("PLAYER_MONEY")
end
TakeInboxItem = function(i, a)
	commands[#commands + 1] = "item " .. inbox[i].tag .. ":" .. a
	inbox[i].items[a] = nil
	dropIfEmpty(i)
end
CheckInbox = function() end
C_Mail = {
	IsCommandPending = function()
		return false
	end,
	CanCheckInbox = function()
		return true, 0
	end,
}

-- --------------------------------------------------------------- load TOC
local ns = {}
local toc = io.open(addonDir .. "/LedgerGoblin.toc"):read("*a")
for line in toc:gmatch("[^\r\n]+") do
	if line:match("%.lua$") then
		local path = addonDir .. "/" .. line:gsub("\\", "/")
		local chunk = assert(loadfile(path))
		chunk("LedgerGoblin", ns)
	end
end

MailFrame = CreateFrame("Frame")
rawset(MailFrame, "GetWidth", function()
	return 384
end)
env.fire("ADDON_LOADED", "LedgerGoblin")
env.fire("PLAYER_LOGIN")
env.flushTimers()

local F, C = ns.F, ns.C
local Planner, Sender, Inbox, Rules, Ledger = ns:GetModule("Planner"), ns:GetModule("Sender"), ns:GetModule("Inbox"), ns:GetModule("Rules"), ns:GetModule("Ledger")

-- ------------------------------------------------------------------ utils
eq(F.ParseMoney("100"), 1000000, "bare number is gold")
eq(F.ParseMoney("1g 2s 3c"), 10203, "g s c")
eq(F.ParseMoney("50s"), 5000, "silver only")
eq(F.ParseMoney("abc"), nil, "junk rejected")
eq(F.MailRecipient("Alchemist-Realm"), "Alchemist", "own realm stripped")
eq(F.MailRecipient("Alchemist-Other"), "Alchemist-Other", "other realm kept")
eq(F.SenderKey("Banker"), "Banker-Realm", "bare sender gets realm")
eq(F.ItemIDFromText(link(2770)), 2770, "item id from link")
local pat = Inbox._SubjectPattern("Auction expired: %s")
check(("Auction expired: Copper Ore"):find(pat) ~= nil, "subject pattern matches")
check(("Auction expired"):find(pat) == nil, "subject pattern needs the item")
check(("x(.)y: Ore"):find(Inbox._SubjectPattern("x(.)y: %s")) ~= nil, "subject pattern escapes magic")
check(("xAy: Ore"):find(Inbox._SubjectPattern("x(.)y: %s")) == nil, "escaped dot is literal")

eq(ns.State.playerName, "Main-Realm", "player stamped")

-- ----------------------------------------------------------------- planner
local G = ns.global
G.roster["Alchemist-Realm"] = { class = "MAGE", gold = 0 }
G.roster["Banker-Realm"] = { class = "PRIEST", gold = 0 }
G.inventory["Alchemist-Realm"] = { bags = { [2770] = 12 }, bank = {} }
G.mailbox["Alchemist-Realm"] = { pending = { [2770] = 3 } }
G.repairCost["Main-Realm"] = 50 * 10000

local db = ns.db
Rules.EnsureTypeEntries()
db.typeRules[C.TypeKey(7, 9)] = { enabled = true, target = "Alchemist-Realm" }
db.typeRules = db.typeRules -- herbs to the alchemist
db.bind.boe = { enabled = true, target = "Banker-Realm" }
db.quality.common = { enabled = true, target = "Banker-Realm" }
db.exclusions[2589] = true
db.keep[2447] = 10
db.itemRules[1] = { match = 2770, target = "Alchemist-Realm", max = 30 }
db.gold.enabled, db.gold.target, db.gold.mode, db.gold.keepCopper = true, "Banker-Realm", "keep", 100 * 10000
db.confirmGold = false
Rules.Changed()

put(0, 1, 2447, 20)
put(0, 2, 2447, 15)
put(0, 3, 100, 1, { bound = true })
put(0, 4, 101, 1)
put(0, 5, 2770, 20)
put(0, 6, 2589, 20)
put(0, 7, 2447, 5, { locked = true })
put(0, 8, 102, 1, { bound = true })
env.money = 500 * 10000
env.fire("BAG_UPDATE_DELAYED")

local jobs, abort, warnings = Planner.Build()
eq(abort, nil, "no abort")
eq(#warnings, 0, "no warnings")
local byTarget = {}
for _, job in ipairs(jobs) do
	local t = byTarget[job.target] or { units = 0, money = 0, mails = 0, ids = {} }
	byTarget[job.target] = t
	t.mails = t.mails + 1
	t.money = t.money + job.money
	for _, it in ipairs(job.items) do
		t.units = t.units + it.sendCount
		t.ids[it.itemID] = (t.ids[it.itemID] or 0) + it.sendCount
	end
end
local alch, bank = byTarget["Alchemist-Realm"], byTarget["Banker-Realm"]
eq(alch.ids[2447], 25, "herbs minus keep 10, locked stack ignored")
eq(alch.ids[2770], 15, "restock to 30 with 12 held and 3 on the way")
eq(alch.ids[2589], nil, "excluded cloth not sent")
eq(bank.ids[101], 1, "BoE ring to banker")
eq(bank.ids[100], nil, "soulbound sword never sent")
eq(bank.ids[102], 1, "warband bound item still mailable, falls to quality rule")
eq(bank.ids[2589], nil, "exclusion beats quality rule")
eq(bank.money, 400 * 10000, "keep 100g of 500g, reserve 50g fits")
eq(jobs[1].target, "Alchemist-Realm", "jobs sorted by target")

-- Postage is per attachment. 12 stacks of 1 to one target = 360c.
eq(Planner.Postage(12), 360, "postage per attachment")
eq(Planner.Postage(0), 30, "money-only mail costs one postage")

-- Funds gate: not enough gold for postage.
db.gold.enabled = false
env.money = 50
local _, abort2 = Planner.Build()
check(abort2 ~= nil, "abort when postage is not covered")
db.gold.enabled = true
env.money = 500 * 10000

-- Restock with an unknown target inventory warns and sends none.
G.inventory["Alchemist-Realm"] = nil
local jobs3, _, warn3 = Planner.Build()
local ore = 0
for _, job in ipairs(jobs3) do
	for _, it in ipairs(job.items) do
		if it.itemID == 2770 then
			ore = ore + it.sendCount
		end
	end
end
eq(ore, 0, "restock skipped without a snapshot")
check(#warn3 == 1, "restock warning given")
G.inventory["Alchemist-Realm"] = { bags = { [2770] = 12 }, bank = {} }

-- Tooltip preview agrees with the plan.
local status, target, category = Planner.PreviewTarget(2447)
eq(status, "routed", "preview herb routed")
eq(target, "Alchemist-Realm", "preview herb target")
eq(category, "type", "preview herb category")
eq((Planner.PreviewTarget(2589)), "excluded", "preview exclusion")
eq((Planner.PreviewTarget(100)), "notmailable", "preview soulbound")

-- ------------------------------------------------------------------ sender
env.fire("MAIL_SHOW")
env.flushTimers()
Sender.Run()
for _ = 1, 10 do
	env.flushTimers()
	if #sent > 0 and sent[#sent].confirmed == nil then
		sent[#sent].confirmed = true
		env.fire("MAIL_SEND_SUCCESS")
	end
end
eq(#sent, 2, "two mails sent")
eq(sent[1].to, "Alchemist", "first mail to alchemist, realm stripped")
eq(sent[1].units, 40, "alchemist units")
eq(sent[2].money, 400 * 10000, "gold rides with banker mail")
eq(G.sendCount, 2, "send counter committed")
check(sent[1].subject:find("#1$") ~= nil, "subject carries counter")
local splits = 0
for _, a in ipairs(actions) do
	if a:find("^split") then
		splits = splits + 1
	end
end
eq(splits, 2, "one split for herbs, one for ore")
eq(G.mailbox["Alchemist-Realm"].pending[2770], 18, "pending ore grows by 15")
eq(G.log[#G.log].items, 2, "log counts units, ring and warband tabard")
eq(ns.State.sending, false, "run finished")

-- ------------------------------------------------------------------- inbox
inbox = {
	{ tag = "alt", sender = "Banker", money = 100 * 10000 },
	{ tag = "cod", sender = "Stranger", cod = 500, items = { [1] = { id = 2770, count = 5 } } },
	{ tag = "sale", sender = "Auction House", money = 50 * 10000, invoice = "seller", canReply = false, item = "Copper Ore", who = "Buyer", count = 20 },
	{ tag = "gm", sender = "GM", gm = true, items = { [1] = { id = 2770, count = 1 } } },
	{ tag = "expired", sender = "Auction House", subject = "Auction expired: Copper Ore", canReply = false, items = { [1] = { id = 2770, count = 3 } } },
	{ tag = "pending", sender = "Auction House", money = 30 * 10000, invoice = "seller_temp_invoice", canReply = false },
}
env.fire("MAIL_INBOX_UPDATE")
env.flushTimers()
eq(G.mailbox["Main-Realm"].count, 6, "inbox scanned")
eq(G.mailbox["Main-Realm"].money, 150 * 10000, "pending sale money not counted as waiting")

local driver
for _, f in ipairs(env.frames) do
	if f.scripts.OnUpdate then
		driver = f
	end
end
local startMoney = env.money
Inbox.Collect("all")
for _ = 1, 50 do
	if not Inbox.IsCollecting() then
		break
	end
	driver.scripts.OnUpdate(driver, 1)
end
eq(table.concat(commands, ","), "loot expired,money sale,money alt", "collect order, skips COD GM pending")
check(table.concat(env.chat, " "):find("Collected 3 mail") ~= nil, "collect summary counts gold-only mail")
eq(env.money - startMoney, 150 * 10000, "gold collected")
local totals = Ledger.IncomeTotals(1)
eq(totals[C.SOURCE.SALE], 50 * 10000, "sale income recorded")
eq(totals[C.SOURCE.ALT], 100 * 10000, "alt income recorded")
eq(#inbox, 3, "COD, GM and pending sale left")
local trade = G.trades[#G.trades]
check(trade ~= nil and trade.kind == "sale" and trade.item == "Copper Ore" and trade.count == 20 and trade.copper == 50 * 10000, "sale trade recorded from invoice")

-- Bag floor: no free slots means item mail is skipped, money still taken.
commands = {}
for s = 1, 16 do
	put(0, s, 2447, 1)
end
inbox = {
	{ tag = "gift", sender = "Banker", money = 10, items = { [1] = { id = 2770, count = 2 } } },
}
Inbox.Collect("all")
for _ = 1, 50 do
	if not Inbox.IsCollecting() then
		break
	end
	driver.scripts.OnUpdate(driver, 1)
end
eq(table.concat(commands, ","), "money gift", "full bags take money only")
eq(#inbox, 1, "item mail stays")

-- Gold filter leaves items.
commands = {}
bags[0] = {}
inbox = { { tag = "both", sender = "Banker", money = 10, items = { [1] = { id = 2770, count = 2 } } } }
Inbox.Collect("gold")
for _ = 1, 50 do
	if not Inbox.IsCollecting() then
		break
	end
	driver.scripts.OnUpdate(driver, 1)
end
eq(table.concat(commands, ","), "money both", "gold filter takes money only")

-- Items only filter leaves gold.
commands = {}
inbox = { { tag = "both2", sender = "Banker", money = 10, items = { [1] = { id = 2770, count = 2 }, [2] = { id = 2447, count = 1 } } } }
Inbox.Collect("items")
for _ = 1, 50 do
	if not Inbox.IsCollecting() then
		break
	end
	driver.scripts.OnUpdate(driver, 1)
end
eq(table.concat(commands, ","), "item both2:2,item both2:1", "items filter takes items, keeps gold")
eq(inbox[1] and inbox[1].money, 10, "gold left in the mail")

-- One item type per mail.
inbox = {}
bags[0] = {}
put(0, 1, 2447, 20)
put(0, 2, 2770, 5)
db.keep[2447] = nil
db.itemRules[1].max = nil
db.gold.enabled = false
db.sendIndividually = true
env.fire("BAG_UPDATE_DELAYED")
local jobsInd = Planner.Build()
local alchMails = 0
for _, job in ipairs(jobsInd) do
	if job.target == "Alchemist-Realm" then
		alchMails = alchMails + 1
		eq(#job.items, 1, "one item type per mail")
	end
end
eq(alchMails, 2, "herbs and ore in separate mails")
db.sendIndividually = false

-- Expiry list
G.mailbox["Banker-Realm"] = { count = 2, expires = env.now + 2 * 86400 }
local soon = Inbox.ExpiringList(3)
check(#soon >= 1 and soon[1].character == "Banker-Realm", "expiring mail listed")

-- Forever names: unique across the region, "First Surname", no realm.
RegionalUniqueNamesEnabled = function()
	return true
end
env.name, env.second = "Miley", "Skyrus"
eq(F.FullName("player"), "Miley Skyrus", "forever full name joins surname with a space")
eq(F.NormalizeTarget("  Brewgrin   Ironbrew "), "Brewgrin Ironbrew", "forever target keeps surname, no realm")
eq(F.MailRecipient("Brewgrin Ironbrew"), "Brewgrin Ironbrew", "forever mail address is the full name")
eq(F.SenderKey("Brewgrin Ironbrew"), "Brewgrin Ironbrew", "forever sender key is the full name")
RegionalUniqueNamesEnabled = nil

print(("%d passed, %d failed"):format(passes, failures))
os.exit(failures == 0 and 0 or 1)
