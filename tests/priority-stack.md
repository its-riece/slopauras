# Focused regression tests

Requires Python and `lupa==2.6` with its Lua 5.1 runtime. Use a dedicated Python
environment and install with `python -m pip install lupa==2.6`, then run:

```sh
python tests/priority_stack.py
```

For an existing isolated Lupa installation, pass `--dependency-path PATH`.
The harness loads actual addon Lua and syntax-checks all addon Lua files.
It stubs game APIs; its JSON bridge uses Python JSON. It does not reproduce
native secret values, Blizzard rendering, or a complete game environment.

Exercises actual NewStack and Resize with a narrow access-timing model: slots
become inaccessible after initializeFrame. Decorative styling and frame
creation are substituted. Checks initial anchors, frame priority before styled
children, growth, shrink and retained spare slots.

## Client evidence

Before the fix, the larger icon disappeared after a user-run combat size change
while the ordinary buff row remained visible. After the fix, the user reported
the reload/combat-resize procedure worked; the agent did not capture that retest.

Manual reproduction: import tests/fixtures/priority-stack.txt while out of combat,
cast Power Word: Shield on yourself, enter combat manually, and change shared
icon size from 48 to 64 in the editor. The icon should remain anchored, resize,
and preserve shield priority. PvP restriction behavior is not verified.
These observations were on addon 0.5.0 with the same focused fix and Forever Beta
1.60.1.70338/interface 16001. This branch is based on upstream 0.6.1 and tested
offline; the updated editor/bundle version has not been retested in the game.
