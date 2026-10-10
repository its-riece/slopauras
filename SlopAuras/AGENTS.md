# Maintaining SlopAuras

For anyone changing SlopAuras' code, agent or person. SlopAuras is an aura tracker for
World of Warcraft: Forever, a Classic-based client (game type `camelot`) with
Midnight-style secret values. It draws rows of aura icons on any frame. It builds them from
Blizzard's AuraContainers, so it keeps working while aura data is secret.

## Files

Load order is the `.toc` order.

| File | What it does |
|---|---|
| `Libs/` | LibStub, CallbackHandler, AceGUI-3.0, AceConfig-3.0 (editor only), LibSharedMedia-3.0 (fonts, LGPL v2.1). |
| `Ranks.lua` | Spell rank families (class spells), generated from talentsforever.com data (CC BY 4.0, credited in the file). Regenerate rather than hand-edit. `ns.SpellRanks(id)`. |
| `Chain.lua` | Builds a group's lines out of AuraContainers and links them; buttons, borders, glow, missing icons. No saved-data knowledge beyond a display's keys. |
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
- **Texts on a button:** the countdown (`GetCountdownFontString`) and the stack count are
  styled after Masque, so their settings win over the skin (`StyleString`). The count's
  Text and Shown are Blizzard's (`SetApplicationCount`), so hiding it sets its alpha to 0.
  Fonts are fetched from LibSharedMedia by saved name, falling back to the text's own; a
  font registered later restyles everything (`LibSharedMedia_Registered`).
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
  secret. Dispel borders come from textures handed to aura buttons (`AddDispelTypeTexture`).
- **Range is secret**: `UnitInRange` feeds `SetAlphaFromBoolean` on the glow.
- Edit Mode fills every container with placeholder auras (`editModePreviewEnabled` in the
  template). SlopAuras keeps that preview on.
- **Test mode** flips the same global switch, `C_UnitAuras.SwitchAuraDataProvider` /
  `ResetAuraDataProvider`, so Blizzard's aura frames fill too. It runs while the test window
  (its own AceConfigDialog app, Options.lua) is open and at least one group is ticked
  (`SyncTesting`); untested groups are hidden (`UpdateHost`) and tested nameplate rows show on
  any plate (`Shows`). It must never stay on in combat: `UpdateAll` ends it and closes the
  window when combat starts (`PLAYER_REGEN_DISABLED` runs it) and on any poll that finds
  combat or secret auras. Placeholders have no dispel type, spell ID or duration, so while
  testing list displays get no candidate filters and missing displays get one nothing passes
  (`Chain.SetTestFilters`), so every display fills and missing icons show. Putting the real
  filters back is a container change, so displays that were changed stay hidden
  (`restoring`) until the next `Apply`, which waits out combat.

## Data model

- **Group:** placement (`target`, `anchorTo`, `anchor`, `growth`, `lines`, `lineSpacing`,
  `firstLine`) and an ordered `displays` list. Any display key on a group is a default.
- **Line break:** a `{ mode = "break" }` entry in `displays`; the displays after it start a
  new line. One before the first display, after the last or right after another is
  ignored. Loops that want displays only use `ns.Displays(group)`, which skips breaks and
  numbers the displays as the editor does.
- **Display:** one aura group in a line (or a missing icon).
- **Inheritance:** display → group → `DEFAULTS`, via metatables (`ns.Prepare`). SlopAuras
  saves only raw values. Read a display's own value with `rawget` when inheritance would
  give the wrong answer (`name`, the editor's asterisks).
- **"Off" overrides:** a display that must drop a group value saves an explicit off value
  (`false` for `tint`, `glow`, `borderColor`; `"always"` for `combat`, `glowCombat`;
  `"never"` for `tooltip`;
  `"auto"` for `hideWhenNotVisible`; `"any"` for `resting`, `mounted`; `"enemy"` for
  `nameplateUnits`; `"blizzard"` for `borderStyle`).
- `SlopAuras.toc` `## SavedVariables: SlopAurasDB` = `{ nextID, groups = { ... } }`, shared by
  all characters; `class` and the load keys decide where groups apply.

## How a group becomes frames

Wording: the editor calls a line a **row**, or a **column** when icons grow up or down
(`RowWord` in Options.lua), because players found it clearer than "line". A line break is
always a "line break". In the code, "line" is a line and "row" is one group on one host, as
below.

- **Host:** one unit's place on screen (player, target, focus, each party or raid
  frame, members and pets, each nameplate). Every host gets its own copy of each row meant for it.
- **Row:** one group on one host. **Line:** one AuraContainer with one aura group per list
  display on it; its flow layout gives each display its own icon size and collapses empty
  ones. The container is 1px when empty.
- **Missing displays** (`mode = "missing"`): the game only lays out buttons for auras that
  exist, so each missing display is a presence container (one invisible slot, anchored backwards so it only takes room while
  the aura is missing), a fixed clip window, and a slide container that moves the icon out
  of the window when the aura shows up (`NewMissing`, `Link`). They draw at the end of
  their line.
- **Centering** (`growth = "CENTER"`, or `"CENTER_VERTICAL"` for a column): Lua can't halve
  a secret width, so each container has a half-size shadow copy. The shadows chain backwards
  from the center (left, or up), and the visible line starts where they end.
- **Show only the first line** (`firstLine`, per group; the editor's "Show only the first row/column"): the row's containers sit in one clip
  window at the row's origin (`Chain.StyleFirstLine`), one line of the biggest icon deep.
  Empty lines collapse, so it shows the first line that has auras. Only for rows on their
  own (`ns.SingleRow`); lines don't wrap while it's on. A smaller line on top would let the
  edge of the next one show, so only the last line may be smaller: otherwise
  (`ns.FirstLineConflict`) the window clips nothing and the editor says why.
- **Priority stacks:** a group showing only its first line, where every line is one list
  display showing one icon (`ns.StackDisplays`; not centered, not while the first-line
  window is ignored), is built as one container of aura slots (`Chain.NewStack`,
  `AddAuraSlot`): one button per display where an aura group makes ten. The slots sit on
  one spot, earlier displays on top, so it shows what the first-line window would.
  Whether a group qualifies is part of `BuildFlags`, since the edits that change it (Max
  icons shown, icon size) are sent as look changes.
- **Never load** displays aren't built (`SplitLines` leaves them out); turning it on or off
  is structural.
- **Wrapping lines** (`wrap` on the display that starts a line): the container's flow layout
  wraps by length (`Chain.SetWrap`), so the next line follows its last row. Only for lines
  without missing displays, in groups not showing only their first line, whose strands are
  a single row (`ns.SingleRow`, `LineWrap`): other lines keep a fixed height.
- **Anchoring:** `anchorTo = "unit"` rows hang off the host's frame (unit frames, compact
  party/raid frames, the nameplate itself, not Blizzard's UnitFrame inside it, which
  nameplate addons hide). Nameplate rows are only anchored to the plate and parented to
  UIParent: as plate descendants they cost every frame, hidden or not (a city full of plates
  went from 140 to 50 fps). `FollowPlate` copies the plate's alpha and scale onto rows that
  show something, in 0.05 steps. Screen/frame rows of all hosts join one strand (`Strand`).
  Nameplate lines add `INCLUDE_NAME_PLATE_ONLY` to their filters, as Blizzard's plates do.

## Masque (optional)

- `skin = "masque"` (the default when Masque is loaded) skins a display; the border color
  then goes on the skin's ring and `borderStyle` (Blizzard / Plain) is unused. The flag
  is in the row signature, and `Apply` rebuilds when any display's flag changed
  (`BuildFlags`), since the editor sends it as a look change.
- One Masque group per SlopAuras group with skinned displays (`SyncSkins`,
  SlopAuras.lua; static ID = group id), passed to `Chain.NewList` / `NewMissing` as
  `skin`. A Masque option change bumps `skinEpoch` (part of `StyleText`) and restyles
  everything.
- List buttons register `{ Icon, Cooldown, Count, Border }` as type "Aura"; missing icons
  register their holder with `{ Icon, Border }` (the ring only carries a custom color
  there). Masque draws the skin's frame art (Normal) itself.
- `StyleButton` tells Masque the size (`Group:SetFrameSize`: container buttons can report
  secret sizes), then zooms inside the skin's icon crop (`SkinCrop`, from the skin data).
- Dispel colors go on the skin's Border layer (`NewRing`): handed to the button with
  `PreserveAsset`, so Blizzard tints it; the frame art is never tinted. A custom border
  color goes on a copy of the ring (`ring.custom`).
- Sizes follow Masque's `GetScaleSize`: skin width × icon size ÷ 36 × the group's Scale
  option (`SkinSize`). Skinned glows use Masque's spell alert rule (`SpellAlert` size
  × 1.4); clip windows reach as far as the skin's widest layer, the icon included
  (`SkinReach`). The group's skin and Scale come from `group.db` (no public getter).

## Applying changes

- The editor writes into the saved tables and calls `ns.Changed(structural)`; changes apply
  0.1s later, out of combat (`Apply`).
- Each row has a **signature** (`ComputeRows`): group identity, growth, lines, cap, and each
  display's mode and line break. SlopAuras updates rows in place (`Chain.Configure`) and
  rebuilds only what it must. A row whose signature changed but whose **shape** didn't (group
  identity, growth, where lines go, first line only) is kept, and `AssignLines` hands its
  containers to the lines as they are now: a list line takes a container that fits
  (`Chain.CanResize`; `Chain.Resize` turns extra aura groups off as spare slots), a missing
  display one with the same Masque registration (`Chain.CanSetDisplay`). Containers no line
  takes stay on the row, turned off, as spares for later edits. Only what's missing is
  built, so editing displays and line breaks rarely builds anything. Building is slow: each
  aura group makes 10 buttons up front. Reused containers keep their `/fstack` names.
- WoW can't destroy frames. A rebuilt row's old containers get hidden and disabled, and
  stay in memory until `/reload`. Past `RELOAD_HINT` retired containers, the editor
  suggests a reload.
- `UpdateAll` polls the **conditions** (combat, resting, mounted, dead, offline, visible,
  hostility, known spells...) every 0.25s, because several have no event. Frames change
  only when a result changes.

## The editor (Options.lua)

- `/slop` toggles AceConfigDialog's standalone window, the editor's only home: it isn't in
  the game's Options → AddOns, which is too narrow for its two trees. `Refresh`
  (`NotifyChange`) redraws it.
- Options.lua rebuilds its AceConfig options table from `ns.groups` on every redraw.
  Per-page UI state (open import boxes, pickers) lives in upvalues keyed by page.
- Tree: groups only, in name order (`SortedGroups`; their order in `ns.groups` does
  nothing outside the editor). Above a group's tabs: Name, Units (a multiselect dropdown)
  and the group buttons: Test group, Duplicate, Export, Delete. Tabs: "Displays" has Add
  display / Add line break / Import display above a second tree of the group's displays and
  line breaks (a tab's own options draw above its tree); Layout (group-only); "Shared settings" has its own tabs, the Appearance
  and Load conditions every display uses unless it sets its own. Above a display's tabs:
  its text links (`Link`), then Name and Shows; its Import / export tab also holds Move to group. A node's child groups go either in the tree
  or in tabs (`childGroups`), never both; AceConfigDialog draws a new tree for a tree group
  under a tab. Displays are keyed by position (`d1`, `d2`...), so their path is
  `{ "g<id>", "displays", "d<i>" }`.
- Right-click on a control clears a display's own value (`HookWidgets`, `Resettable`).
- Appearance is built flat in `SharedTabs`, then grouped into sections (Arrangement, Icon,
  Text, Border, Glow) by `Section` at its end; Text holds one `TextBox` each for the timer
  and stacks: a new Appearance control needs a row
  there too, or it won't show. A group's Layout tab (`LayoutTab`) holds the Lines section
  (`LineControls`: Grow, New rows go, Row spacing, Show only the first row; "column" for
  vertical growth) and Anchor.
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
  values; start from the player's own export (the editor's Export buttons) and change
  only what was asked. Filter tokens and sort methods are Blizzard's (`AuraUtil.AuraFilters`,
  `AuraContainerSortMethod`), and the platform rules above decide what can match.
- Giving a player a string: put the whole string in your reply, in a code block, however
  long, so they can copy it.

## Saved keys

Shared (group or display): `size`, `spacing`, `alpha`, `zoom`,
`max`, `sort`, `sortReverse`, `desaturate`, `hideSwipe`, `tint`, `dispelBorder`,
`borderColor`, `skin`, `borderStyle`, `borderWidth`, `hideTimer`, `hideStacks`, `tooltip`
(`"never"`, `"always"`, `"out"`), and per text
(`timer…` for the countdown, `stack…` for the count): `Size`, `Font` (a LibSharedMedia name,
`false` for the text's own), `Outline` (`NONE`, `OUTLINE`, `THICKOUTLINE`), `Color`, `Point`,
`Align` (`LEFT`, `CENTER`, `RIGHT`), `X`, `Y`; `timerFormat` (`blizzard`, `clock`, `short`,
`long`), `timerDecimals` (0-60 seconds; absent: the game's own threshold), `timerPrecision`
(1-3); `glow`, `glowCombat` (`"never"`
too), `glowInRange`, `combat`, `neverLoad`, `knownSpell` (an ID or list; negative = must not
know; at least one positive must be known), `hideWhenPlayerDead`, `class`, `nameplateUnits`,
`resting` and `mounted` (`true` only while, `false` only while not, `"any"`), `hideWhenDead`,
`hideWhenOffline`, `hideWhenNotVisible`.

Display only: `name`, `mode` (`list`, `missing`), `filter` (absent = `"HELPFUL"`; a group
`filter` from older saves or strings moves to its displays, `ns.MoveGroupFilter`), `wrap` (icons per row on
the line this display starts), `spellIDs` and
`rankSpellIDs` (sets `{ [id] = true }`, `false` = exclude), `dispelTypes`, `maxDuration`
(seconds, the container's `maxDuration` candidate filter), `icon`.

On load, `LoadSettings` drops displays with any other `mode` and the retired keys in
`RETIRED_KEYS` (SlopAuras.lua). A key that stops being used goes there, so old saves still
export strings that import accepts. A group's `lineMax` (older saves and strings) is
converted on load and import by `ns.ConvertLineMax`, and a display's `newLine` becomes a
line break before it (`ns.ConvertNewLine`; a single display's string just drops it).

Group only: `id`, `name`, `target`, `anchorTo`, `anchor` (`{ point, frameName, relativePoint,
x, y }`), `growth`, `lines`, `lineSpacing`, `firstLine` (`true`: show only the first
line that has auras), `layer` (draw order among groups on
one frame, `PlaceOrigin`), `displays`.

## Adding a setting

1. A default in `DEFAULTS` (SlopAuras.lua) if it needs one.
2. Use it where it acts (`Chain.Configure` / `StyleButton` for looks, `Shows` for
   conditions). A key `StyleButton` reads also goes in `STYLE_KEYS` (Chain.lua):
   `Configure` skips buttons whose keys there haven't changed.
3. A control in Options.lua, wrapped in `Resettable` for right-click. An Appearance
   control also gets a row in its section (`Section` calls in `SharedTabs`).
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
