# Changelog

All notable changes to **LedgerGoblin** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/Kkthnx-Wow/LedgerGoblin/releases/tag/v1.0.0
