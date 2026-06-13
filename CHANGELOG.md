# Changelog

<!-- markdownlint-disable MD024 -->

All notable changes to **LedgerGoblin** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-06-13

Focused on visibility: seeing where items will go before you send, reaching the
addon faster, and clearer feedback when a rule won't do what you expect.

### Added

- **Bag tooltip routing hints.** Hover an item in your bags and the tooltip shows
  where LedgerGoblin would mail it — the target name in its class colour (and with
  the realm suffix dropped for same-realm alts), or that the item is excluded. The
  hint only appears when a rule actually claims the item, so unconfigured items
  stay quiet. Toggle it under Routing Rules in the settings panel.
- **Minimap button.** A draggable minimap button (self-rolled, no library): left
  click opens settings, right-click opens the Rule Editor. Toggle it with
  `/ledger minimap`; its position is saved account-wide.
- **Rule Editor search box.** Filter long route lists by itemID, item name, or
  target — sits on the action-button row with a magnifier icon.
- **Unknown-target warning.** Adding a rule whose target this account has never
  seen now prints a heads-up (e.g. catching `Kkthnx-Area52x` typos). It's a soft
  warning — brand-new alts still work, you just get a nudge to double-check.
- **Specific "why not" feedback.** When a rule can't be added, the message now
  says *why* — soulbound to this character, Bind on Pickup, or a quest item —
  instead of a generic refusal.

### Fixed

- **Category routes no longer look like phantom item rules.** A tooltip hint from
  a Bind-on-Equip, Warband, or quality rule is now tagged as such, so removing a
  specific item rule and seeing the item still route (via a category rule) is no
  longer confusing.

### Changed

- **Lighter tooltip scanning.** The Rule Editor's item-info refresh listener now
  only runs while the editor is open, instead of waking for every item load in the
  world all session.
- **Search icon is flavor-safe.** Falls back to a universal magnifier texture on
  clients that lack the retail search atlas.

## [1.2.0] - 2026-06-12

Focused on hardening the mail send queue for large batches and fixing item
classification edge cases surfaced in live use.

### Added

- **Check All / Uncheck All** buttons in the Rule Editor for quickly toggling
  long route lists.
- **Copy** menu in the Rule Editor (next to Pick) for merging another character's
  saved specific item routes into the current character without duplicating exact
  matches.
- **Flavoured mail subjects** — each mail now gets a random goblin one-liner plus
  an account-wide lifetime send number (e.g. `Goblin's cut #142`). The counter
  only advances on confirmed sends, so it's a real running tally.
- **Lifetime mails sent** is now shown in `/ledger stats`.
- **`/ledger trace`** — an opt-in, verbose send-pipeline diagnostic. Off by
  default; narrates every step of a run (attach results, recipient, the
  `SendMail` call, and which of success/fail/timeout/lock events arrive) so a
  stuck batch can be diagnosed instead of guessed at.

### Fixed

- **Warband / account-bound reagents are no longer wrongly blocked.** Items like
  *Arden Lumber* report an unreliable static bind type; a tooltip-based fallback
  (`C_TooltipInfo`) now correctly detects warband binding so they route to alts.
- **Reagent bag is now scanned.** The carry-inventory sweep skipped the reagent
  bag (container 5), so ore/herbs/lumber stored there reported "nothing to
  route." It's now included explicitly.
- **Same-realm mail no longer silently fails.** Addressing a recipient as
  `Name-OwnRealm` produced no success or failure event; the sender's own realm
  is now stripped so same-realm mail delivers.
- **Large batches no longer stall** mid-run requiring the mailbox to be closed
  and reopened.
- **Uncheck All button layout** no longer stretches or spills off the Rule Editor
  frame.

### Changed

- **Mail queue is now lock-aware.** It tracks `MAIL_LOCK_SEND_ITEMS` /
  `MAIL_UNLOCK_SEND_ITEMS` and won't compose into a locked send frame, with a
  fail-open guard if the unlock event never arrives.
- **Latency-aware pacing.** The compose-settle and post-send cooldowns now scale
  with connection latency (with conservative floors) instead of fixed delays, so
  fast connections stay snappy and laggy ones get more breathing room.
- **Attachment retries and clean cancellation.** Transient attach failures retry
  before skipping a chunk, and closing the mailbox mid-run cancels cleanly
  without leaving stale timers.
- **Per-day analytics are capped at 90 days** so the saved-variables file can't
  grow without bound over time.
- **Missing locale strings degrade to readable English** instead of erroring, via
  a fallback on the locale table.

## [1.0.0] - 2026-06-11

First stable release. LedgerGoblin is a complete, rule-based mail routing system
for sending gold and items to your alts.

### Added

- **Rule-based routing pipeline** — resolves every item in priority order:
  exclusions → specific item rules → bind routing → quality routing.
- **Gold routing** — keep-and-send, fixed amount, or percentage modes, with a
  repair reserve that's *learned* from your actual full-repair cost at vendors.
- **Bind routing** — send Bind-on-Equip gear (while unequipped) and
  account/warband-bound items to your own alts.
- **Quality routing** — a catch-all destination per item quality (Poor → Epic).
- **Specific item rules & exclusions** — route exact items by ID or name, and a
  never-mail list for everything you want to keep.
- **Keep reserves** — hold back `N` of an item and send only the surplus.
- **Rule Editor window** — a movable panel that works alongside open bags;
  drag or shift-click items straight in to fill their ID, and pick targets from a
  class-coloured roster menu.
- **Auto-run on mailbox open** (opt-in, off by default), with hold-Shift to skip.
- **Confirmation prompt** for sends above a configurable gold threshold.
- **Preview & Debug** commands — see what would send, and why each item does or
  doesn't route.
- **Transfer log and lifetime/daily stats.**
- **Roster awareness** — learns your alts so route targets validate before sending.
- **AddOn Compartment** support — left-click for settings, right-click for the
  Rule Editor.
- **Midnight (12.0) ready** — secret-value safe throughout.

### Security & safety

- **Soulbound / Bind-on-Pickup and quest items are never routed.** Rules for
  un-mailable items are now blocked at creation time — by itemID, item link, **or**
  exact name — using the item's live inventory binding when it's in your bags,
  falling back to its static bind type otherwise.
- **Locked slots** (items mid-move or pending a server action) are skipped during
  planning, sending, and rule validation, so a transient state can't cause a
  misrouted or mis-blocked item.
- **Shift-click item entry** now works reliably via a taint-free secure post-hook
  on `ChatEdit_InsertLink`, resolving links down to a clean itemID.
- **Paced sending** — a short cooldown between confirmed mails (on top of the
  one-in-flight, wait-for-success queue) avoids locked-slot races and rapid-fire
  mailbox issues.

[1.3.0]: https://github.com/Kkthnx-Wow/LedgerGoblin/releases/tag/v1.3.0
[1.2.0]: https://github.com/Kkthnx-Wow/LedgerGoblin/releases/tag/v1.2.0
[1.0.0]: https://github.com/Kkthnx-Wow/LedgerGoblin/releases/tag/v1.0.0
