# Working on SlopAuras

For coding agents making a change to SlopAuras. `SlopAuras/AGENTS.md` describes how the
addon works and the platform rules behind it: read it before changing code.
`CONTRIBUTING.md` says which pull requests are wanted.

## Prose for people

People write the Markdown that people read: `README.md`, `CHANGELOG.md`,
`CONTRIBUTING.md` and any other `.md` written for a human reader. Don't create or edit
those files. You can help the person you're working with: point out typos and mistakes,
check claims against the code, or outline what a section should cover. They write the
prose. `AGENTS.md` files are written for agents and stay yours to keep current.

## Changes and pull requests

- Don't change the version in `SlopAuras/SlopAuras.toc`. The maintainer sets it at
  release.
- One change per PR.
- The PR description says how to reproduce the bug, what was checked in game and on which
  game build.
- Changed Lua files have no Lua language server warnings under the repo's `.luarc.json`.
- The repo holds the addon and its docs. Add no scripts, test harnesses, build tools or CI
  files. Releases are zips of the addon folder, and addon sites reject anything else that
  executes.
- Don't edit `SlopAuras/Libs/` (other projects' libraries) or `SlopAuras/Ranks.lua`
  (generated from talentsforever.com data).
- When a change removes, renames or replaces something `SlopAuras/AGENTS.md` describes,
  update it in the same change. It states how things work now, with no history.
- `SlopAuras/AGENTS.md` ships to players, whose agents use it to set up configs. It never
  tells an agent to run anything (commands, scripts, exports); it says where information
  lives. In-game lookups are fine phrased as something the person can do (`/api search`).
- Commit messages: one short lowercase line saying what a player would notice ("fix loss of
  control dispel border", "improve nameplate performance"). No body, no code identifiers.
  Describe the effect, not the implementation.

## Secret values

Forever enforces secret values in full. Treat aura data, spell IDs, cooldown times, power
and the like as secret by default.

- Don't hedge ("might be off in this build") and don't use
  `C_Secrets.HasSecretRestrictions()` as a test.
- Claim an exemption only with evidence, such as a `NeverSecret = true` field tag
  (`SpellCooldownInfo.isActive`).
- Prefer answers the game computes (`C_ActionBar.IsUsableAction`,
  `C_Spell.GetSpellPowerCost`) and secret-safe sinks (`*FromBoolean` setters, StatusBar
  geometry, container filter strings) over comparing values in Lua. `C_Secrets` has no
  helpers for comparing secret numbers, only `Should*BeSecret` predicates.
- Reading an API that is only sometimes secret is acceptable for a side detail with one
  harmless fallback. The two existing cases set the bar: `UnitClassBase("player")` for the
  class load condition (read once and cached), and `UnitIsUnit` in `IsMe` (one
  `issecretvalue` check; the fallback treats the unit as someone else). A feature that
  hinges on such a read for other units is out: find an untagged API, or say there isn't
  one. Don't design around per-unit `Should*BeSecret` checks.
- Secret is not the same as combat (`SlopAuras/AGENTS.md`, "Platform rules"). The person
  testing can force secrecy outside a battleground with
  `/console addonPvPMatchRestrictionsForced 1` and a `/reload` (siblings:
  `addon{Combat,Encounter,ChallengeMode,Map,Chat}RestrictionsForced`).

## Code

- Keep code lean. Delete debug scaffolding and diagnostic slash commands once they've done
  their job; don't leave them switched off.
- Comments describe the code as it is now. No history: no dates, "before X", "used to",
  "(tested)", "changed from", or which addon an idea came from.
- Comments explain; they don't teach. Write them for the next developer: why it's done this
  way, which game constraint forces it (secret values, combat lockdown, Blizzard file and
  line), what a non-obvious value means. No tutorials, and no walkthroughs of what the code
  plainly says.
- Don't work around Ace3. If AceConfig or AceGUI can't do a layout or behaviour, say so and
  use what it offers (`SetDefaultSize`, `GetStatusTable`, `NotifyChange`). No buttons
  anchored onto AceGUI's pooled frames, no reaching into widgets to move them. The existing
  hooks (`HookWidgets`, `HookTree` in Options.lua) aren't a pattern to extend.
- Pick the control that fits each setting: a checkbox where one direction matters, a
  dropdown where both do, even when its neighbours use another kind.

## Adding a setting

1. A default in `DEFAULTS` (SlopAuras.lua) if it needs one.
2. Use it where it acts (`Chain.Configure` / `StyleButton` for looks, `Shows` for
   conditions). A key `StyleButton` reads also goes in `STYLE_KEYS` (Chain.lua):
   `Configure` skips buttons whose keys there haven't changed.
3. A control in Options.lua, wrapped in `Resettable` for right-click. An Appearance
   control also gets a row in its section (`Section` calls in `SharedTabs`).
4. A validator in Share.lua's spec tables, plus `SharedValue` if the saved form differs
   from JSON.
5. Update "Saved keys" in `SlopAuras/AGENTS.md`.
6. If it changes which containers exist, include it in the row signature and pass
   `structural = true`.

## Text a player sees

Tooltips, labels, descriptions, status lines, confirm prompts and chat prints.

- A tooltip only when it says something the label, or the confirm behind it, doesn't.
  Otherwise none: the control shows just its name.
- Same thing, same words. Once a concept has wording, reuse it exactly everywhere it
  appears: a hover and its page, every button that does the same thing, every confirm.
- Labels name their object ("Delete display", "Delete line break"). Tooltips start with a
  verb and say "this <thing>" ("Opens this group in test mode").
- Tooltips state what the control does in one or two flat sentences. No asides, hints about
  other settings, or personality. A checkbox tooltip says what ticking does; never
  "Untick to …".
- Say only what happens. Check each claim against the code.
- Ask the person you're working with to review every tooltip longer than one short
  sentence before it's committed.
- A lone sentence has no trailing period ("Moves this display up one"). Two or more
  sentences keep normal punctuation.
- No serial comma: "a group, a full config or another bundle".
- Active voice, no adverbs, no em dashes, no "not X but Y". Name the specific thing.

## Settings layout (AceConfig)

AceConfigDialog flows controls left to right and wraps wherever it runs out of room, which
makes panels look messy. Lay every panel out deliberately:

- Every row is explicit: end it with a full-width empty description
  (`{ type = "description", name = "", width = "full" }`). Never rely on wrapping.
- One kind of control per row. Dropdowns, sliders and text inputs (label above) go
  together, at most three per row at normal width. Checkboxes (label beside) get their own
  rows, two per row at `width = 1.5` (numeric widths are multiples of 170px) so long labels
  aren't cut off.
- A control alone in its row stays alone: don't pair it with something unrelated to fill
  space.
- Buttons that belong together sit together; reset and action buttons go on their own row,
  usually last.
- Before handing over a layout, write out the rows it produces and check each against these
  rules.
