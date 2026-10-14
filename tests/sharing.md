# Focused regression tests

Requires Python and `lupa==2.6` with its Lua 5.1 runtime. Use a dedicated Python
environment and install with `python -m pip install lupa==2.6`, then run:

```sh
python tests/sharing.py
```

For an existing isolated Lupa installation, pass `--dependency-path PATH`.
The harness loads actual addon Lua and syntax-checks all addon Lua files.
It stubs game APIs; its JSON bridge uses Python JSON. It does not reproduce
native secret values, Blizzard rendering, or a complete game environment.

Covers empty class/power overrides across group, config and display exports,
empty targets, legacy class values, discrete-count boundaries, continuous
fractional settings, empty ID omission, and v0.6.1 bundle membership.

## Client evidence

The patched live addon rejected max=1.5 and preserved empty class/power/target
lists through native JSON export and import parsing. Full-config application
choices were not applied during that check.
These observations were on addon 0.5.0 with the same focused fix and Forever Beta
1.60.1.70338/interface 16001. This branch is based on upstream 0.6.1 and tested
offline; the updated editor/bundle version has not been retested in the game.
