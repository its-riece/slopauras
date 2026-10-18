# How SlopAuras works

For agents: how SlopAuras works, and the game rules behind it. Helping a player set it up
starts at "Walking a player through the editor" and "Import / export". Changing its code
also follows the rules in `AGENTS.md` at the root of the repo, which isn't part of a
release.

SlopAuras is an aura tracker for World of Warcraft: Forever, a Classic-based client (game
type `camelot`) with Midnight-style secret values. It draws rows of aura icons on any frame.
It builds them from Blizzard's AuraContainers, so it keeps working while aura data is
secret.

Source, issues and changelog: https://github.com/its-riece/slopauras. A downloaded copy may
be older than the repo.

## Files

Load order is the `.toc` order.

| File | What it does |
|---|---|
| `Libs/` | LibStub, CallbackHandler, AceGUI-3.0, AceConfig-3.0 (editor only), LibSharedMedia-3.0 (fonts, LGPL v2.1), LibGetFrame-1.0 (unit frames, GPL v2; ForeverAuras' MINOR 79, which skips aura containers when scanning). |
| `Ranks.lua` | Spell rank families (class spells), generated from talentsforever.com data (CC BY 4.0, credited in the file). Generated; don't hand-edit. `ns.SpellRanks(id)`. |
| `Chain.lua` | Builds a group's lines out of AuraContainers and links them; buttons, borders, glow, missing icons. No saved-data knowledge beyond a display's keys. |
| `SlopAuras.lua` | Saved settings and inheritance (`DEFAULTS`, `ns.Prepare`), rows and hosts, show/hide conditions, applying editor changes, the `SlopAuras` global for other addons, events. |
| `Share.lua` | Import/export strings: validation, export, import. |
| `Options.lua` | The in-game editor (`/slop`), an AceConfig options table. |

## Platform rules that shape the code

The game enforces secret values. While `C_Secrets.ShouldAurasBeSecret()` is true, aura data,
counts, spell IDs and durations are secret, and addon Lua can't read or compare them. That is
any combat, and the whole of a PvP match (battleground), in and out of combat. Secret is not
the same as combat: `PLAYER_REGEN_ENABLED` and `InCombatLockdown()` don't say whether auras
are secret; ask `ShouldAurasBeSecret()` (it changes with `ADDON_RESTRICTION_STATE_CHANGED`).
Check an API's `SecretWhen*` / `SecretReturns` tags in `Blizzard_APIDocumentationGenerated`
before relying on it.

- **Never read auras.** Matching, counting, sorting and layout all happen inside Blizzard's
  `CustomAuraContainerTemplate` (Blizzard_AuraContainer). SlopAuras only configures
  containers (filter string, candidate filters, sort, max, layout) and anchors frames to
  their geometry. Presence and counts show up as container *size*, never as values.
- **While auras are secret, existing buttons can't be touched, but new rows can be built.**
  After `initializeFrame`, every call on an aura button or anything under it (icon,
  cooldown, count, our overlay) raises "forbidden object" (`DenyTaintedAccessWhenAurasAreSecret`,
  Blizzard_AuraContainerFrameProviders.lua:77-86). Building fresh containers works, under
  combat lockdown too, with each button styled in `initializeFrame`. So editor changes
  don't wait for secrecy to end: while secret, `Apply` rebuilds changed rows instead of
  restyling them (`SyncHost` keeps rows whose `fingerprint` matches; the `syncer` frame
  builds a few hosts per frame within `BUILD_BUDGET_MS`) and `ConfigureHost` skips
  `Chain.Configure`. Every apply out of secrecy refreshes each row's fingerprint, so only
  rows changed since are rebuilt. Skin and font changes (`Reskin`) change every row's
  fingerprint, so they wait until auras aren't secret (`reskinPending`). The
  editor never locks; only test mode does (`ns.TestLocked`). Glows that follow combat or
  range can't flip on built buttons: combat glows are two copies with combat loads
  (`GlowCopies`), and range glows show fully while secret (`Chain.HoldRange`).
- **Frames anchored to a container** (or to anything inside one) need
  `DisableUntrustedLayoutScriptsTemplate`, or the game refuses the anchor.
- **You can only set up a button in `initializeFrame`.** Register its regions there
  (`SetIcon`, `SetDurationCooldown`, `SetApplicationCount`, `AddDispelTypeTexture`);
  Blizzard fills them from secret data. While auras aren't secret you can change size, tint and the
  like later, through the parts kept per button (`StyledButton`, `StyleButton`).
- **Animations inside buttons** go through `AddAuraShownAnimation`; Blizzard plays them
  when the button shows. A registered texture's alpha, vertex color and tex
  coords become secret aspects; its Shown state does not.
- **Texts on a button:** the timer and the stack count are font strings on the overlay,
  drawn at `OVERLAY` 7 so they sit over the borders, and styled after Masque, so their
  settings win over the skin (`StyleString`). The cooldown's own countdown is off: as a
  child of the cooldown it would draw under the overlay. The timer is the button's
  duration text (`SetDurationText`, `StyleTimerFormat`): the engine writes the time left
  through our formatter (`TimerFormatter`; "blizzard" is a rule set copying the countdown's
  look) and a flat color curve (`TimerColor`). Its Text, Alpha and VertexColor are
  Blizzard's, so Hide timer uses Shown. The count's Text and Shown are Blizzard's
  (`SetApplicationCount`), so hiding it sets its alpha to 0.
  Fonts are fetched from LibSharedMedia by saved name, falling back to the text's own; a
  font registered later restyles everything if a display uses it
  (`LibSharedMedia_Registered`, `UsesFont`).
- **Icons snap to whole pixels.** At most UI scales a UI unit isn't a whole number of
  screen pixels, so each texture would round on its own and an icon's border could be a
  pixel wider on one side. Every aura button (end of `StyleButton`) and missing icon (end
  of `StyleMissing`) sets `PixelUtil.SetRoundLayoutToNearestPixelRecursively`
  (`RoundToPixels`). It's per region, so it runs after the borders, glow and Masque's art
  exist. Containers aren't rounded, so layout math in UI units is unchanged; in a long
  row an icon or gap can come out 1px bigger.
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
  (`SyncTesting`); untested groups are hidden (`UpdateHost`), and tested rows ignore friend
  or enemy and group size (`Shows`). It must never stay on in combat: `UpdateAll` ends it and closes the
  window when combat starts (`PLAYER_REGEN_DISABLED` runs it) and on any poll that finds
  combat or secret auras. Placeholders have no dispel type, spell ID or duration, so while
  testing list displays get no candidate filters and missing displays get one nothing passes
  (`Chain.SetTestFilters`), so every display fills and missing icons show. Putting the real
  filters back is a container change, so displays that were changed stay hidden
  (`restoring`) until the next `Apply`.

## Data model

- **Group:** placement (`target`, `anchorTo`, `anchor`, `growth`, `lines`, `lineSpacing`,
  `firstLine`) and an ordered `displays` list. Any display key on a group is a default.
- **Suite** (the editor says **bundle**): a name on groups (`suite`), for the editor only:
  it groups them in the tree and lets them be tested and exported together. No table, no
  settings, no inheritance.
- **Line break:** a `{ mode = "break" }` entry in `displays`; the displays after it start a
  new line. One before the first display, after the last or right after another is
  ignored. Loops that want displays only use `ns.Displays(group)`, which skips breaks and
  numbers the displays as the editor does.
- **Display:** one aura group in a line (or a missing icon).
- **Inheritance:** display → group → `DEFAULTS`, via metatables (`ns.Prepare`). SlopAuras
  saves only raw values. Read a display's own value with `rawget` when inheritance would
  give the wrong answer (`name`, the editor's asterisks).
- **"Off" overrides:** a display that must drop a group value saves an explicit off value
  (`false` for `tint`, `glow`, `borderColor`, `dispelBorder`, `glowInRange`, `timerFont`,
  `stackFont`; `"always"` for `combat`, `glowCombat`;
  `"never"` for `tooltip`;
  `"auto"` for `hideWhenNotVisible`; `"any"` for `resting`, `mounted`, `groupSizeOp`,
  `reaction`; `"blizzard"` for `borderStyle`).
- `SlopAuras.toc` `## SavedVariables: SlopAurasDB` = `{ nextID, groups = { ... } }`, shared by
  all characters; `class` and the load keys decide where groups apply.

## How a group becomes frames

Wording: the editor calls a line a **row**, or a **column** when icons grow up or down
(`RowWord` in Options.lua), because players found it clearer than "line". A line break is
always a "line break". In the code, "line" is a line and "row" is one group on one host, as
below.

- **Host:** one unit's place on screen: you, target, focus, each party or raid unit token
  (members and pets), each nameplate, and preview frames (see "Unit frames"). Every host
  gets its own copy of each row meant for it.
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
  Each slot is anchored and given its frame level in its `initializeFrame`: Blizzard
  locks the button right after, so a stack built while auras are secret can't place it
  later. `Chain.Resize` re-levels the slots (`LevelSlots`) when it adds some.
  Whether a group qualifies is part of `BuildFlags`, since the edits that change it (Max
  icons shown, icon size) are sent as look changes.
- **Displays that can't show on this character aren't built** (`Builds`: Never load, a
  class that isn't yours, "Only if you know spell" not met; `SplitLines` leaves them out).
  Each aura group costs 10 buttons per host whether it shows or not
  (`FrameCreationBatchSize`), so a hidden-but-built display is expensive on raid frames.
  Changing any of those three keys is structural. Known spells can change in a session: the
  poll compares them with the last build (`KnownSpellsChanged`) and applies a structural
  change when one is learned or unlearned (level, talent, respec, spells loading after
  login). `knownKey` is part of each row's fingerprint so that works while auras are secret.
- **Dispel-type splits merge** (`MergeDispelSplits`, not in priority stacks): neighbouring
  built list displays on a line whose own settings match except `name`, `knownSpell` and
  `dispelTypes` become one aura group with the types combined. A class-agnostic config
  splits a row per dispel type with different known spells; once `Builds` drops the types
  you can dispel, the rest would otherwise cost 10 buttons each. Max icons shown then
  counts the merged display. `MergedDisplays` puts the merge state in `BuildFlags` and the
  row signature, so an edit that makes two displays differ splits them again.
- **Line settings** (`wrap`, `lineCap`) live on the display that starts the line in the
  list, built or not (`line.lead`, `SplitLines`), which is where the editor shows them.
  `SameButDispel` ignores them, so they don't stop a merge.
- **Wrapping lines** (`wrap`): the container's flow layout
  wraps by length (`Chain.SetWrap`), so the next line follows its last row. Only for lines
  without missing displays, in groups not showing only their first line, whose strands are
  a single row (`ns.SingleRow`, `LineWrap`): other lines keep a fixed height.
- **Capped lines** (`lineCap`): show only the first N icons across the line's displays, in
  display order. No container caps icons across aura groups, so the container sits in a
  clip window anchored to its own start (`StyleCap`, `Chain.NewList`), N slots of the
  line's biggest icon long. Lines across it follow the container, which stays one icon
  deep, so empty lines still collapse. `CapBlock` rules it out for wrapping lines (wrap
  wins), centered growth (the shadow measures the whole line), strands of several rows
  and lines with missing displays (both chain after the whole container), and priority
  stacks. A line is built capped or not for good (`Chain.Capped`): `CapFlags` puts that
  in `BuildFlags`, and `AssignLines` only reuses a container of the same kind. The window
  size follows edits (`Chain.SetCap` in `ConfigureHost`), while auras are secret too.
- **Anchoring:** `anchorTo = "unit"` rows hang off the host's frame (whatever frame shows
  the unit, see "Unit frames"; the nameplate itself, not Blizzard's UnitFrame inside it, which
  nameplate addons hide). Nameplate rows are only anchored to the plate and parented to
  UIParent: as plate descendants they cost every frame, hidden or not (a city full of plates
  went from 140 to 50 fps). `FollowPlate` copies the plate's alpha and scale onto rows that
  show something, in 0.05 steps. Screen/frame rows of all hosts join one strand (`Strand`).
  Nameplate lines add `INCLUDE_NAME_PLATE_ONLY` to their filters, as Blizzard's plates do.

## For other addons (SlopAuras.lua, "For other addons")

The `SlopAuras` global lets another addon place a frame by a group's rows, as a cast bar
that moves with the target's auras. Groups are asked for by name: names are what a player
picks, and imports assign new IDs.

- `SlopAuras.GetTrailingAnchor(groupName, unit)`: a 1px frame on `UIParent`, centred where
  a line after the group's last one would start on that unit's host (player, target,
  focus, party and raid units; not nameplates), or nil (no such group, not built on this
  character or that unit, no host yet). Made on first request, one per host and group
  (`host.trails`, keyed by the group's table), and placed at the end of every `Relink`
  (`PlaceTrail`, which uses `PlaceLine`'s rule through `PlaceAfter`). A row showing only
  its first line puts it one line of its biggest icon past the origin while any line
  shows, since Lua can't tell which line has auras. Its position can be secret; frames
  anchored to it need `DisableUntrustedLayoutScriptsTemplate`.
- `SlopAuras.GetGroups()`: `{ name, units, loaded }` for every named group, sorted by name;
  `units` is the set from `target`, `loaded` whether a row config exists for it.
- `SlopAuras.RegisterCallback(self, "GroupsChanged", method)` (CallbackHandler): fired at
  most once per frame (`GroupsChanged`) after every apply (`Applied`, where `ns.OnApplied`
  also runs), at the end of `Build` and when a unit host is added. Callers ask for anchors
  again then: a renamed or deleted group's anchor stays where it last was.

## Masque (optional)

- `skin = "masque"` (the default when Masque is loaded) skins a display; the border color
  then goes on the skin's ring and `borderStyle` (Blizzard / Plain) is unused. The flag
  is in the row signature, and `Apply` rebuilds when any display's flag changed
  (`BuildFlags`), since the editor sends it as a look change.
- One Masque group per SlopAuras group with skinned displays (`SyncSkins`,
  SlopAuras.lua; static ID = group id), passed to `Chain.NewList` / `NewMissing` as
  `skin`. A Masque option change bumps `skinEpoch` (part of `StyleText`) and restyles
  everything (`Reskin`; while auras are secret, once they aren't).
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

## Unit frames (SlopAuras.lua, "Unit frames")

- Hosts belong to unit tokens, not frames: `singleHosts` (player, target, focus) and
  `unitHosts` (`GROUP_UNITS`: player and party1-4, pet and partypet1-4, raid1-40,
  raidpet1-40). A unit host is built the first time its unit has a frame, through a
  budgeted queue (`QueueHost`, `BUILD_BUDGET_MS`).
- Each host's frame comes from LibGetFrame (`FindUnitFrame`): the frames it lists for the
  unit that show exactly that token (`ShowsUnit`; its lookup also matches the same person
  under another token, e.g. a raid frame for `party1`), whose name is on LibGetFrame's
  list for the kind (`accepted`: its player/target/focus lists, the focus one plus
  `^oUF_.-Focus$`, which it lacks, or its party + raid lists
  for group units, which keeps pet groups off `PetFrame`), best ranked first (`ranking`).
  A frame dropped from its list but still showing the unit is kept (`BestFrame`): it
  lists visible frames only.
- `Rebind` gives every host its frame; `SetHostFrame` moves rows (`PlaceOrigin`
  reparents via `RowParent` and re-anchors), which works in combat and while auras are
  secret. Rebinds are requested (`RequestRebind`, once per frame) by LibGetFrame's
  `GETFRAME_REFRESH`, the roster refresh, target/focus changes while the host has no
  frame, `AURA_DATA_PROVIDER_SWITCH`, and hooks on `CompactUnitFrame_SetUnit` and
  `Grid2:SetFrameUnit`. The hooks also ask LibGetFrame to rescan: its list only updates
  on a scan (about a second after its own events), but it reads listed frames' units
  live, so the hooks make unit changes on those frames immediate.
- Party and raid hosts show only while they have a visible frame (`FRAMED` in
  `ReadState`); rows anchored to "each unit's own frame" hide while the host has no frame
  (`UpdateHost`). On party/raid hosts every row is a child of the frame; on you, target
  and focus only unit-anchored rows are.
- **Previews:** Edit Mode's party/raid frames and Grid2's test mode show unit "player" in
  empty slots. While placeholder auras are on (`placeholders`: Edit Mode or test mode),
  every party/raid-list frame showing "player", except your own party host's frame, gets
  a preview host (`previewHosts`, `SyncPreviews`): party rows on party-list frames, raid
  rows on the rest (`PreviewKind`).
- `EachGroupHost` visits unit and preview hosts.

## Applying changes

- The editor writes into the saved tables and calls `ns.Changed(structural)`; changes apply
  0.1s later (`Apply`), in combat too (see "While auras are secret" above).
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
- `UpdateAll` polls the **conditions** (combat, resting, mounted, group size, dead, offline,
  visible, hostility, the unit's combat, power type...) every 0.25s, because several have no event. Frames change
  only when a result changes. Class and known spells aren't polled per display: they
  decide what's built (above).

## The editor (Options.lua)

- `/slop` toggles AceConfigDialog's standalone window, the editor's only home: it isn't in
  the game's Options → AddOns, which is too narrow for its tree. `Refresh`
  (`NotifyChange`) redraws it.
- Options.lua rebuilds its AceConfig options table from `ns.groups` on every redraw.
  Per-page UI state (open import boxes, pickers) lives in upvalues keyed by page.
- One tree: groups in no suite first, then suites (`SuiteOptions`, keyed `s:<name>`) with
  their groups, each in name order (`SortedGroups`, `SuiteGroups`; order in `ns.groups`
  does nothing outside the editor). Under a group: Shared display settings and Displays; under
  Displays, the displays and line breaks, keyed by list position (`d<i>`, `b<i>`). A
  display's path is `{ [ "s:<name>", ] "g<id>", "displays", "d<i>" }`; build paths with `GroupPath` and open pages with
  `OpenPage`. A node's child groups go either in the tree or in tabs (`childGroups`), never
  both, so the group page has no tabs: its own options and inline boxes (Rows, Anchor:
  `LayoutBoxes`) draw on it, and Shared display settings and each display carry the tabs. The
  pages are laid out in "Walking a player through the editor" below.
- Gray in the tree means not built on this character (`ns.NotBuiltReason`: Never load,
  class, "Only if you know spell"); the entry's `desc` says why (`NotLoadedText`,
  `GroupNotLoadedText`). A group is gray when none of its displays build or its own class
  rules it out. Show/hide conditions don't count.
- Right-click on a control clears a display's own value (`HookWidgets`, `Resettable`).
- `SharedTabs` builds the three tabs a group and a display share: Appearance, Text and Load
  conditions. Appearance is built flat, then grouped into sections (Arrangement, Icon,
  Border, Glow) by `Section` at its end: a new Appearance control needs a row there too, or
  it won't show. Text holds one `TextBox` each for the timer and stacks.
- AceConfigDialog lays controls out left to right and wraps; numeric widths are multiples
  of 170px; a tab group fills to the panel bottom (nothing can sit below it); a description
  has one font size.
- WoW edit boxes double a typed `|`; `CleanFilter` collapses the runs when a filter saves.

## Walking a player through the editor

Use the labels exactly as below; they are what the player sees. The editor says **row**, or
**column** for a group that grows up or down, where the code says line. `/slop` opens it.

- **Top of the window:** New group, Test mode; Export full config, Import full config,
  Import a group. The tree on the left lists groups (with their number of displays, as
  loaded/total while some don't load), then
  bundles (a bag icon before the name) with their groups. Clicking an entry also opens its
  children (`HookTree` sets the tree's `OnClick` callback, which AceConfigDialog leaves
  unused); its +/- closes it. Under a group:
  Shared display settings and Displays. Under Displays: the displays, numbered, and line breaks
  (a gray rule). Gray
  entries don't load on this character; hovering one says why.
- **A bundle's page:** buttons Test mode (this bundle's groups), Export, Import (a bundle,
  a full config or one group; it goes into the bundle), Unbundle, Delete bundle (with its
  groups); then Name and Add group (a group not in the bundle, or New group).
- **A group's page:** buttons Add display, Test mode (this group only), Duplicate, Export,
  Delete group; then Name; Units (a dropdown of checkboxes: You, Your target, Your focus,
  Party members, Party pets, Raid members, Raid pets, Nameplates); Bundle (None, your
  bundles, or New bundle, which puts the group in a bundle called "New bundle" and opens
  its page to rename it). Then the Rows and Anchor boxes (see Layout below).
- **Displays** (under the group): Add display, Add line break, Import display.
- **A line break's page:** Move up, Move down and Delete line break.
- **A display's page**, above its tabs: Move up, Move down, Duplicate, Delete display; Name; Shows
  (Matching auras, or Icon when none match). Tabs:
  - **Filters:** Filter, with Pick filters (checkboxes for each token; click again to
    exclude it); Spell IDs (exact); Spell IDs (all ranks); Maximum aura duration; Dispel
    types (Magic, Curse, Disease, Poison, Bleed, No type; none ticked: any);
    Icon (only for Icon when none match).
  - **Appearance**, in sections. Arrangement: Max icons shown, Spacing; Wrap after (only on a
    display that starts a row with no Icon when none match in it, in a group with one row
    per unit and not showing only its first row; locked while a cap is set), Max icons per
    row (on a display that starts a row; hidden where a cap can't apply unless one is set,
    locked while the row wraps); a warning when the cap is ignored or the row mixes icon
    sizes; Sort, Reverse sort. Icon: Size, Zoom, Alpha; Tint
    (then Tint color); Desaturate, Hide swipe; Tooltips. Border: Skin (only with Masque
    installed), Border (None, Dispel color, Custom), Border style; Border width; Color.
    Glow: Glow (None, Gold, Custom), Glow color, and Glow when (In combat, Out of combat,
    Out of range). Icon when none match hides Max icons shown, Sort, Hide swipe and
    Tooltips.
  - **Text** (not for Icon when none match): a Timer box (Hide timer; Format, Increase
    precision below, Precision; Font, Size, Outline; Position, Alignment; X, Y; Color) and
    a Stacks box (the same, without the three format controls).
  - **Load conditions:** a "Your character" box (Classes; Combat state, Resting state,
    Mounted state; Group size (Any, At least, At most, Exactly) and Players, shown once a
    comparison is picked; Only if you know spell; Hide while you're dead, Never load) and
    a "Show on units that are" box (Alive, Online; Friend or enemy (Either, Enemies,
    Friends), In sight (Automatic, Yes, Either), Combat state (the unit's: Any, In combat,
    Out of combat); Power types, checkboxes for Mana, Rage, Energy, Focus).
  - **Import / export:** Move to group (with two or more groups), Export
    (with Include the group's values), Import new settings.
- **Layout** (on the group's page): a Rows (or Columns) box: Grow, New rows go, Row spacing, Show only the
  first row (only for a group with one row per unit: anchored to each unit's own frame, or
  showing just one of You, Your target, Your focus; `ns.SingleRow`). An Anchor box: Anchor to (Each
  unit's own frame, Screen, A named frame), Frame name (named frame only), Group's point,
  To the frame's, X, Y, Layer.
- **Shared display settings** (under the group in the tree): the same Appearance, Text and Load conditions tabs as a
  display's, holding the group's values. Every display uses them unless it sets its own.
  On a display, an asterisk after a label marks its own value; right-clicking the control
  goes back to the group's.

## Import / export (Share.lua)

- `SlopAuras:<VERSION>:<addon version>:<kind>:<json>`, kind `config`, `group` or `display`.
  `VERSION` is the string format version (now `2`); the addon version is the `.toc`
  `## Version` of the copy that exported it. Format `1` strings
  (`SlopAuras:1:<kind>:<json>`) have no addon version and still import. Every format from
  `2` on must keep the addon version right after `VERSION`, so older copies can name it
  when they can't read the rest. When a string fails validation and its addon version is
  later than this copy's, the error names both versions and suggests updating; a string
  from a later format is refused with the same suggestion. Config strings (a full config, a
  bundle's export) keep each group's `suite`; a single group's string doesn't. Importing on
  a bundle's page puts everything in that bundle. Bump `VERSION` only for incompatible
  changes; a new key doesn't need one. Where each kind is pasted: `config` in Import full config (then Replace all my
  groups, Update existing (replaces same-named groups, adds the rest; only when names match), or Add as new groups), `group` in Import a group, `display` in a group's Import
  display (added at the end) or a display's Import new settings (replaces it).
- Import is strict: every key must be in the spec tables (`SHARED`, `DISPLAY_ONLY`,
  `GROUP_ONLY`), Share.lua checks every value and range, and nothing changes until the
  whole string passes. Parsing uses `C_EncodingUtil`, so nothing pasted runs as code.
  Counts (`max`, `wrap`, `lineCap`) and `layer` must be whole numbers. Export keeps
  empty `class`, `unitPower` and `target` lists: a display's empty `unitPower` overrides
  its group's, and an empty `target` is a group on no units.
- JSON is the saved table (see "Saved keys") with these differences:
  - A config is `{ "groups": [ ... ] }`. Group names must be unique.
  - No `id`: the importer assigns one. A group needs `name`.
  - `target` and `class` are lists: `"target": ["party", "raid"]`.
  - `anchor` is `{ "point", "relativePoint", "x", "y" }`, plus `"frame"` (a global frame
    name) only with `"anchorTo": "frame"`. Points: `TOPLEFT`, `TOP`, `TOPRIGHT`, `LEFT`,
    `CENTER`, `RIGHT`, `BOTTOMLEFT`, `BOTTOM`, `BOTTOMRIGHT`.
  - `spellIDs` and `rankSpellIDs` are lists of IDs, an excluded one as `"!12345"`.
    `knownSpell` is one ID or a list, `"!588"` for "must not know".
  - Colors are `[r, g, b]`, each 0 to 1.
  - A line break is `{ "mode": "break" }` in a group's `displays`, with no other keys. A
    display string can't be one.
- Values Share.lua checks against game tables, listed here for anyone without the source:
  - `filter`: tokens joined with `|`, `!` before one excludes it. Every filter needs
    `HELPFUL` or `HARMFUL`. Tokens (`AuraUtil.AuraFilters`): `HELPFUL`, `HARMFUL`,
    `PLAYER`, `RAID`, `CANCELABLE`, `INCLUDE_NAME_PLATE_ONLY`, `MAW`, `EXTERNAL_DEFENSIVE`,
    `CROWD_CONTROL`, `RAID_IN_COMBAT`, `RAID_PLAYER_DISPELLABLE`, `BIG_DEFENSIVE`,
    `IMPORTANT`, `DISPELLABLE`.
  - `sort` (`AuraContainerSortMethod`): `Default`, `BigDefensive`, `UnitFrameDebuff`,
    `ImportantOnly`, `Expiration`, `ExpirationOnly`, `Name`, `NameOnly`,
    `AuraInstanceIDOnly`.
  - `class`: class tokens (`CLASS_SORT_ORDER`): `WARRIOR`, `PRIEST`, `MAGE` and so on.
  - `dispelTypes`: `Magic`, `Curse`, `Disease`, `Poison`, `Bleed`, `None` (typeless).
- Writing a config for a player: start from the player's own export (the editor's Export
  buttons) and change only what was asked. Leave out keys that would equal the default
  (`DEFAULTS` in SlopAuras.lua) or the group's value. The platform rules above decide what
  can match: spell ID lists only work for buffs on friendly units and debuffs on enemies,
  and auras matching two displays show twice.
- Giving a player a string: put the whole string in your reply, in a code block, however
  long, so they can copy it.

## Saved keys

Shared (group or display): `size`, `spacing`, `alpha`, `zoom`,
`max`, `sort`, `sortReverse`, `desaturate`, `hideSwipe`, `tint`, `dispelBorder`,
`borderColor`, `skin`, `borderStyle`, `borderWidth`, `hideTimer`, `hideStacks`, `tooltip`
(`"never"`, `"always"`, `"out"`), and per text
(`timer…` for the timer, `stack…` for the count): `Size`, `Font` (a LibSharedMedia name,
`false` for the text's own), `Outline` (`NONE`, `OUTLINE`, `THICKOUTLINE`), `Color`, `Point`,
`Align` (`LEFT`, `CENTER`, `RIGHT`), `X`, `Y`; `timerFormat` (`blizzard`, `clock`, `short`,
`long`), `timerDecimals` (0-60 seconds; absent: the game's own threshold), `timerPrecision`
(1-3); `glow`, `glowCombat` (`"never"`
too), `glowInRange`, `combat`, `neverLoad`, `knownSpell` (an ID or list; negative = must not
know; at least one positive must be known), `hideWhenPlayerDead`, `class`, `reaction`
(`"enemy"`, `"friendly"`, `"any"`: `UnitIsFriend("player", unit)`, so neutral creatures are
enemies; absent: enemies on nameplates, any unit elsewhere),
`resting`, `mounted` and `unitCombat` (the unit's `UnitAffectingCombat`) (`true` only
while, `false` only while not, `"any"`), `groupSizeOp`
(`"atLeast"`, `"atMost"`, `"exactly"`, `"any"`) and `groupSize` (1-40), compared with
`GetNumGroupMembers()` (solo counts as 1; ignored without both), `hideWhenDead`,
`hideWhenOffline`, `hideWhenNotVisible`, `unitPower` (a list of `MANA`, `RAGE`, `ENERGY`,
`FOCUS`: shows only on units whose current `UnitPowerType` token is listed; a unit with no
token matches nothing; empty or absent: any; a display's empty list overrides its group's).

Display only: `name`, `mode` (`list`, `missing`), `filter` (absent = `"HELPFUL"`; a group
`filter` from older saves or strings moves to its displays, `ns.MoveGroupFilter`), `wrap` (icons per row on
the line this display starts), `lineCap` (1-40: icons shown across the line this display
starts), `spellIDs` and
`rankSpellIDs` (sets `{ [id] = true }`, `false` = exclude), `dispelTypes`, `maxDuration`
(seconds, the container's `maxDuration` candidate filter), `icon`.

On load, `LoadSettings` drops displays with any other `mode` and the retired keys in
`RETIRED_KEYS` (SlopAuras.lua). A key that stops being used goes there, so old saves still
export strings that import accepts. A group's `lineMax` (older saves and strings) is
converted on load and import by `ns.ConvertLineMax`, and a display's `newLine` becomes a
line break before it (`ns.ConvertNewLine`; a single display's string just drops it).
`nameplateUnits` (`"enemy"`, `"friendly"`, `"all"`, nameplates only) becomes `reaction` on
load and import (`ns.ConvertNameplateUnits`, `ns.ConvertReaction`; `"all"` becomes `"any"`).

Group only: `id` (saved only, never in strings), `name`, `target` (one or a list of `player`,
`target`, `focus`, `party`, `partypet`, `raid`, `raidpet`, `nameplate`), `anchorTo` (`unit`,
`screen`, `frame`), `anchor` (saved `{ point, frameName, relativePoint, x, y }`; x and y
-2000 to 2000), `growth` (`RIGHT`, `LEFT`, `DOWN`, `UP`, `CENTER`, `CENTER_VERTICAL`),
`lines` (where new lines go: `UP` or `DOWN` for sideways growth, `LEFT` or `RIGHT` for up or
down), `lineSpacing`, `firstLine` (`true`: show only the first line that has auras),
`layer` (1-10, draw order among groups on one frame, `PlaceOrigin`), `displays`, `suite` (a
name, editor only; in config strings, not group strings; not in row fingerprints).

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
