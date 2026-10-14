from harness import ns, lua, ROOT, observe, observations, syntax

text = (ROOT/'tests'/'fixtures'/'priority-stack.txt').read_text(encoding='utf-8').strip()
priority = ns.Share.Import(text, 'group')
assert not isinstance(priority, tuple), priority
ns.Prepare(priority)
slots = ns.StackDisplays(priority)
assert slots is not None and len(slots) == 2
assert slots[1].name == 'Shield first' and slots[2].name == 'Other buff fallback'
priority.growth = 'CENTER'
assert ns.StackDisplays(priority) is None
priority.growth = 'RIGHT'
priority.displays[1].max = 2
assert ns.StackDisplays(priority) is None
observe('priority-stack fixture qualification', 'passed', 'Two ordered slots; centered/multi-icon controls use regular containers.')
lua.execute((ROOT/'tests'/'stack-restriction.lua').read_text(encoding='utf-8'), ns)
observe('stack initialization and resize', 'passed', 'No post-initialization restricted access; grow/shrink preserves priority.')
print(f'{len(observations)} stack checks passed; {len(syntax)} addon Lua files compiled.')
