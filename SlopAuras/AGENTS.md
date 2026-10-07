# Maintaining SlopAuras

For anyone changing SlopAuras' code, agent or person. SlopAuras is an aura tracker for
World of Warcraft: Forever, a Classic-based client (game type `camelot`) with
Midnight-style secret values. It draws rows of aura icons on any frame. It builds them from
Blizzard's AuraContainers, so it keeps working while aura data is secret.

## Files

Load order is the `.toc` order.

| File | What it does |
|---|---|
| `Libs/` | LibStub, CallbackHandler, AceGUI-3.0, AceConfig-3.0 (editor only). |
| `Ranks.lua` | Spell rank families (class spells), generated from talentsforever.com data (CC BY 4.0, credited in the file). Regenerate rather than hand-edit. `ns.SpellRanks(id)`. |
| `Chain.lua` | Builds a group's lines out of AuraContainers and links them; buttons, borders, glow, missing icons, loss of control. No saved-data knowledge beyond a display's keys. |
| `SlopAuras.lua` | Saved settings and inheritance (`DEFAULTS`, `ns.Prepare`), rows and hosts, show/hide conditions, applying editor changes, events. |
| `Share.lua` | Import/export strings: validation, export, import. |
| `Options.lua` | The in-game editor (`/slop`), an AceConfig options table. |

## Platform rules that shape the code

The game enforces secret values. In combat, aura data, counts, spell IDs and durations are
secret, and addon Lua can't read or compare them. Check an API's `SecretWhen*` / `SecretReturns`
tags in `Blizzard_APIDocumentationGenerated` before relying on it.

- **Never read auras.** Matching, counting, sorting and layout all happen inside Blizzard's
  `CustomAuraContainerTemplate` (Blizzard_AuraContainer). SlopAuras only configures
  containers (filter string, candidate filters, sort, max, layout) and anchors frames to
  their geometry. Presence and counts show up as container *size*, never as values.
- **Containers refuse changes while auras are secret** (`C_Secrets.ShouldAurasBeSecret()`,
  i.e. combat). Building and restyling go through `WhenSafe` and wait for
  `PLAYER_REGEN_ENABLED`; the editor locks until then (`ns.Locked`).
- **Frames anchored to a container** (or to anything inside one) need
  `DisableUntrustedLayoutScriptsTemplate`, or the game refuses the anchor.
- **You can only set up a button in `initializeFrame`.** Register its regions there
  (`SetIcon`, `SetDurationCooldown`, `SetApplicationCount`, `AddDispelTypeTexture`);
  Blizzard fills them from secret data. Out of combat you can change size, tint and the
  like later, through the parts kept per button (`StyledButton`, `StyleButton`).
- **Animations inside buttons** go through `AddAuraShownAnimation`; Blizzard plays them
  when the button shows. A registered texture's alpha, vertex color and tex
  coords become secret aspects; its Shown state does not.
- **Child frames draw over parent textures.** The cooldown swipe is a child frame, so the
  count, borders and glow live on an overlay frame one level above it.
- **Spell ID filters** (`includeSpellIDs` / `excludeSpellIDs`) only apply to buffs on
  friendly units and debuffs on enemies, plus never-secret spells
  (`CanApplyIdentityCandidateFilters`, Blizzard_AuraContainerUtil.lua). Elsewhere an
  include list matches nothing and an exclude list is skipped.
- **Filters need `HELPFUL` or `HARMFUL`**, or they match nothing, even though
  `AuraUtil.IsValidFilterString` accepts them.
- **Aura groups don't dedupe.** An aura matching two displays shows twice; configs split
  displays by filter and dispel type instead.
- **Addon code can't look up an aura's dispel type in combat**:
  `C_UnitAuras.GetAuraDispelTypeColor` errors when called from tainted code while auras are
  secret. Loss of control gets its border from a one-slot aura container under its icon
  (`HARMFUL|CROWD_CONTROL`, longest remaining first) whose button carries only the dispel
  border.
- **Range is secret**: `UnitInRange` feeds `SetAlphaFromBoolean` on the glow.
- Edit Mode fills every container with placeholder auras (`editModePreviewEnabled` in the
  template). SlopAuras keeps that preview on.

## Data model

- **Group:** placement (`target`, `anchorTo`, `anchor`, `growth`, `lines`, `lineSpacing`,
  `lineMax`) and an ordered `displays` list. Any display key on a group is a default.
- **Display:** one aura group in a line (or a missing / loss-of-control icon).
- **Inheritance:** display → group → `DEFAULTS`, via metatables (`ns.Prepare`). SlopAuras
  saves only raw values. Read a display's own value with `rawget` when inheritance would
  give the wrong answer (`name`, the editor's asterisks).
- **"Off" overrides:** a display that must drop a group value saves an explicit off value
  (`false` for `tint`, `glow`, `borderColor`; `"always"` for `combat`, `glowCombat`;
  `"auto"` for `hideWhenNotVisible`; `"any"` for `resting`, `mounted`; `"enemy"` for
  `nameplateUnits`; `"blizzard"` for `borderStyle`).
- `SlopAuras.toc` `## SavedVariables: SlopAurasDB` = `{ nextID, groups = { ... } }`, shared by
  all characters; `class` and the load keys decide where groups apply.

## How a group becomes frames

- **Host:** one unit's place on screen (player, target, focus, each party or raid frame,
  each nameplate). Every host gets its own copy of each row meant for it.
- **Row:** one group on one host. **Line:** one AuraContainer with one aura group per list
  display on it; its flow layout gives each display its own icon size and collapses empty
  ones. The container is 1px when empty.
- **Missing displays** (`mode = "missing"`): the game only lays out buttons for auras that
  exist, so each missing display is a presence container (one invisible slot, anchored backwards so it only takes room while
  the aura is missing), a fixed clip window, and a slide container that moves the icon out
  of the window when the aura shows up (`NewMissing`, `Link`). They draw at the end of
  their line.
- **Loss of control** (`mode = "loc"`) reads `C_LossOfControl` for the player only (other
  units are secret), on its own frame at the end of the line.
- **Centering** (`growth = "CENTER"`, or `"CENTER_VERTICAL"` for a column): Lua can't halve
  a secret width, so each container has a half-size shadow copy. The shadows chain backwards
  from the center (left, or up), and the visible line starts where they end.
- **Icons per line** (`lineMax`): the line's container sits in a clip window anchored to its
  own start.
- **Anchoring:** `anchorTo = "unit"` rows hang off the host's frame (unit frames, compact
  party/raid frames, the nameplate itself, not Blizzard's UnitFrame inside it, which
  nameplate addons hide). Screen/frame rows of all hosts join one strand (`Strand`).
  Nameplate lines add `INCLUDE_NAME_PLATE_ONLY` to their filters, as Blizzard's plates do.

## Applying changes

- The editor writes into the saved tables and calls `ns.Changed(structural)`; changes apply
  0.1s later, out of combat (`Apply`).
- Each row has a **signature** (`ComputeRows`): group identity, growth, lines, cap, and each
  display's mode and line break. SlopAuras rebuilds a row whose signature changed and
  updates the rest in place (`Chain.Configure`). Reordering same-mode displays keeps the
  row and rebinds it (`RebindRow`, `Chain.SetDisplays`).
- WoW can't destroy frames. A rebuilt row's old containers get hidden and disabled, and
  stay in memory until `/reload`. Past `RELOAD_HINT` retired containers, the editor
  suggests a reload.
- `UpdateAll` polls the **conditions** (combat, resting, mounted, dead, offline, visible,
  hostility, known spells...) every 0.25s, because several have no event. Frames change
  only when a result changes.

## The editor (Options.lua)

- Options.lua rebuilds its AceConfig options table from `ns.groups` on every redraw.
  Per-page UI state (open import boxes, pickers) lives in upvalues keyed by page.
- Tree: each group has a gold "Settings" entry (tabs) followed by its displays. A node can't
  have both tree children and tabs, so selecting a group redirects to its Settings entry (a
  `FeedGroup` hook). Displays are keyed by position (`d1`, `d2`...).
- Right-click on a control clears a display's own value (`HookWidgets`, `Resettable`).
- AceConfigDialog lays controls out left to right and wraps; numeric widths are multiples
  of 170px; a tab group fills to the panel bottom (nothing can sit below it); a description
  has one font size.
- WoW edit boxes double a typed `|`; `CleanFilter` collapses the runs when a filter saves.

## Import / export (Share.lua)

- `SlopAuras:<VERSION>:<kind>:<json>`, kind `config`, `group` or `display`. `VERSION` is the
  string format version, not the addon version. Bump it only for incompatible changes.
- JSON is the saved table with two changes: spell ID sets become lists (excluded IDs as
  `"!id"` strings) and the anchor becomes named fields. `knownSpell` negatives travel as
  `"!id"`. Parsing uses `C_EncodingUtil`, so nothing pasted runs as code.
- Import is strict: every key must be in the spec tables (`SHARED`, `DISPLAY_ONLY`,
  `GROUP_ONLY`), Share.lua checks every value, and nothing changes until the whole string
  passes.
- Writing a config for a player: those spec tables are the authority for keys, ranges and
  values; start from the player's own export (the editor's Import / export tabs) and change
  only what was asked. Filter tokens and sort methods are Blizzard's (`AuraUtil.AuraFilters`,
  `AuraContainerSortMethod`), and the platform rules above decide what can match.
- Giving a player a string: put the whole string in your reply, in a code block, however
  long, so they can copy it.

## Saved keys

Shared (group or display): `filter`, `size`, `spacing`, `alpha`, `zoom`, `timerSize`,
`labelSize`, `max`, `sort`, `sortReverse`, `desaturate`, `tint`, `dispelBorder`,
`borderColor`, `borderStyle`, `borderWidth`, `hideTimer`, `glow`, `glowCombat` (`"never"`
too), `glowInRange`, `combat`, `neverLoad`, `knownSpell` (an ID or list; negative = must not
know; at least one positive must be known), `hideWhenPlayerDead`, `class`, `nameplateUnits`,
`resting` and `mounted` (`true` only while, `false` only while not, `"any"`), `hideWhenDead`,
`hideWhenOffline`, `hideWhenNotVisible`.

Display only: `name`, `mode` (`list`, `missing`, `loc`), `newLine`, `spellIDs` and
`rankSpellIDs` (sets `{ [id] = true }`, `false` = exclude), `dispelTypes`, `icon`, `locHide`.

Group only: `id`, `name`, `target`, `anchorTo`, `anchor` (`{ point, frameName, relativePoint,
x, y }`), `growth`, `lines`, `lineSpacing`, `lineMax`, `displays`.

## Adding a setting

1. A default in `DEFAULTS` (SlopAuras.lua) if it needs one.
2. Use it where it acts (`Chain.Configure` / `StyleButton` for looks, `Shows` for
   conditions).
3. A control in Options.lua, added to `LOOK_KEYS` or `LOAD_KEYS` so "Reset to
   group settings" clears it, and wrapped in `Resettable` for right-click.
4. A validator in Share.lua's spec tables, plus `SharedValue` if the saved form differs
   from JSON.
5. Update "Saved keys" above.
6. If it changes which containers exist, include it in the row signature and pass
   `structural = true`.

## References

- Blizzard's UI source. SlopAuras doesn't ship it. A public mirror lives at
  https://github.com/Gethe/wow-ui-source, with a branch per game version; its Classic
  branches are the closest match, though Forever's own files may differ. Ask the person
  you're working with before relying on a detail that matters.
- In Forever's own source, `[Family]` resolves to Mainline, so templates come from `Mainline/`
  variants. Key places: `Blizzard_AuraContainer/`, `Blizzard_FrameXMLUtil/AuraUtil.lua`
  (filters, sort comparators, dispel colors), `Blizzard_NamePlates/`,
  `Blizzard_APIDocumentationGenerated/` (API signatures and secret tags).
- Without the source: the person you're working with can type `/api search <name>` in game to
  see the same API documentation. The file and function names in this guide say where to
  look once you have the source.
- `/fstack` shows SlopAuras frames by name (`Name()` sets parent keys like
  "SlopAuras party bigdebuffs line 1").
