--[[
	LedgerGoblin - Popups
	-------------------------------------------------------------------------
	Confirmation dialogs and the cross-account alt add, import and export.
--]]

local _, ns = ...
local L, F = ns.L, ns.F

local StaticPopupDialogs = StaticPopupDialogs
local tconcat = table.concat
local tsort = table.sort

-- Retail dialogs have GetEditBox / GetButton1, older ones the fields.
local function PopupEditBox(dialog)
	return dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
end

local function PopupButton1(dialog)
	return dialog.GetButton1 and dialog:GetButton1() or dialog.button1
end

local function EnableWhenTyped(self)
	local dialog = self:GetParent()
	local b1 = dialog and PopupButton1(dialog)
	if b1 then
		b1:SetEnabled(((self:GetText() or ""):gsub("%s", "")) ~= "")
	end
end

local function Base(t)
	t.timeout = 0
	t.whileDead = true
	t.hideOnEscape = true
	t.preferredIndex = 3
	return t
end

StaticPopupDialogs["LEDGERGOBLIN_CONFIRM_SEND"] = Base({
	text = "",
	button1 = YES,
	button2 = NO,
	showAlert = true,
	OnAccept = function()
		ns:GetModule("Sender").RunConfirmed()
	end,
})

StaticPopupDialogs["LEDGERGOBLIN_CONFIRM_RESET"] = Base({
	text = L["Clear all LedgerGoblin transfer history and income? This cannot be undone."],
	button1 = YES,
	button2 = NO,
	showAlert = true,
	OnAccept = function()
		ns:GetModule("Ledger").ClearHistory()
	end,
})

function ns.AddManualAltFromText(raw)
	local target = F.NormalizeTarget(raw)
	if not target then
		F.Print(L["Enter a target character."])
		return
	end
	local Roster = ns:GetModule("Roster")
	if Roster.IsKnown(target) then
		F.Print(L["%s is already a known mail target."], target)
		return
	end
	Roster.AddManual(target)
	F.Print(L["Added cross-account alt %s. Auto-run will ask before mailing it."], target)
end

-- Every character this account knows plus the hand-added ones, so one paste
-- seeds the other account.
function ns.ExportAlts()
	local Roster = ns:GetModule("Roster")
	local seen, out = {}, {}
	for _, list in ipairs({ Roster.List(true), Roster.ManualList() }) do
		for i = 1, #list do
			if not seen[list[i]] then
				seen[list[i]] = true
				out[#out + 1] = list[i]
			end
		end
	end
	tsort(out)
	return tconcat(out, "; ")
end

function ns.ImportAlts(raw)
	if type(raw) ~= "string" then
		return
	end
	local Roster = ns:GetModule("Roster")
	local added, skipped = 0, 0
	for token in raw:gmatch("[^;,\r\n]+") do
		local target = F.NormalizeTarget(token)
		if target then
			if Roster.IsKnown(target) or target == ns.State.playerName then
				skipped = skipped + 1
			else
				Roster.AddManual(target)
				added = added + 1
			end
		end
	end
	F.Print(L["Imported %d cross-account alt(s), %d already known."], added, skipped)
end

function ns.ShowExportAlts()
	local text = ns.ExportAlts()
	if text == "" then
		F.Print(L["No characters to export yet."])
		return
	end
	_G["StaticPopup_Show"]("LEDGERGOBLIN_EXPORT_ALTS", nil, nil, { text = text })
end

-- Heavy on purpose. The game can't confirm a name on another account exists,
-- so the player types it and reads the warning first.
StaticPopupDialogs["LEDGERGOBLIN_ADD_MANUAL_ALT"] = Base({
	text = L["Add a cross-account mail target. Type the exact name as the game shows it, Name-Realm on Retail or First Last on Forever.\n\nMail can't be undone. A typo can send your gold and items to a stranger, so only add characters you own.\n\nYou take full responsibility. LedgerGoblin and its author are not liable for gold or items lost to hand-added targets."],
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = true,
	editBoxWidth = 220,
	showAlert = true,
	OnShow = function(self, data)
		local eb = PopupEditBox(self)
		eb:SetText((data and data.prefill) or "")
		eb:HighlightText()
		eb:SetFocus()
		PopupButton1(self):SetEnabled(eb:GetText() ~= "")
	end,
	EditBoxOnTextChanged = EnableWhenTyped,
	EditBoxOnEnterPressed = function(self)
		local dialog = self:GetParent()
		if PopupButton1(dialog):IsEnabled() then
			ns.AddManualAltFromText(self:GetText())
			dialog:Hide()
		end
	end,
	EditBoxOnEscapePressed = function(self)
		self:GetParent():Hide()
	end,
	OnAccept = function(self)
		ns.AddManualAltFromText(PopupEditBox(self):GetText())
	end,
})

StaticPopupDialogs["LEDGERGOBLIN_EXPORT_ALTS"] = Base({
	text = L["Copy this list with Ctrl+C and import it on your other account. Duplicates are skipped."],
	button1 = CLOSE,
	hasEditBox = true,
	editBoxWidth = 350,
	OnShow = function(self, data)
		local eb = PopupEditBox(self)
		eb:SetText((data and data.text) or "")
		eb:HighlightText()
		eb:SetFocus()
	end,
	EditBoxOnEnterPressed = function(self)
		self:GetParent():Hide()
	end,
	EditBoxOnEscapePressed = function(self)
		self:GetParent():Hide()
	end,
})

StaticPopupDialogs["LEDGERGOBLIN_IMPORT_ALTS"] = Base({
	text = L["Paste a character list with Ctrl+V, then Accept.\n\nOnly import characters you own."],
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = true,
	editBoxWidth = 350,
	showAlert = true,
	OnShow = function(self)
		local eb = PopupEditBox(self)
		eb:SetText("")
		eb:SetFocus()
		PopupButton1(self):Disable()
	end,
	EditBoxOnTextChanged = EnableWhenTyped,
	EditBoxOnEnterPressed = function(self)
		local dialog = self:GetParent()
		if PopupButton1(dialog):IsEnabled() then
			ns.ImportAlts(self:GetText())
			dialog:Hide()
		end
	end,
	EditBoxOnEscapePressed = function(self)
		self:GetParent():Hide()
	end,
	OnAccept = function(self)
		ns.ImportAlts(PopupEditBox(self):GetText())
	end,
})
