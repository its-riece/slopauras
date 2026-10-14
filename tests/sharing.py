from harness import ns, lua, lua_type, to_lua, observe, observations, json, syntax

group = to_lua({'name':'override probe', 'unitPower':['MANA'], 'class':['PRIEST'],
               'displays':[{'unitPower':[], 'class':[]}]})
ns.Prepare(group)
text = ns.Share.ExportGroup(group)
restored = ns.Share.Import(text, 'group')
if isinstance(restored, tuple):
    raise AssertionError(restored)
ns.Prepare(restored)
assert len(group.displays[1].unitPower) == 0
assert len(restored.displays[1].unitPower) == 0, 'Export lost the display power override'
assert len(restored.displays[1]['class']) == 0, 'Export lost the display class override'
observe('empty override group round-trip', 'passed', 'Explicit empty power/class overrides survive inheritance.')

for with_group in [False, True]:
    exported = ns.Share.ExportDisplay(group.displays[1], with_group)
    imported = ns.Share.Import(exported, 'display')
    assert not isinstance(imported, tuple)
    parent = to_lua({'displays':[], 'unitPower':['RAGE'], 'class':['WARRIOR']})
    parent.displays[1] = imported
    ns.Prepare(parent)
    assert len(imported.unitPower) == 0 and len(imported['class']) == 0
observe('display export with/without group values', 'passed', 'Empty overrides survive transfer to a differently restricted group.')

ns.groups = lua.table_from([group])
config = ns.Share.Import(ns.Share.ExportConfig(), 'config')
assert not isinstance(config, tuple)
ns.Prepare(config[1])
assert len(config[1].displays[1].unitPower) == 0
assert len(config[1].displays[1]['class']) == 0
empty_target = to_lua({'name':'no units', 'target':[], 'displays':[{}]})
ns.Prepare(empty_target)
empty_target_copy = ns.Share.Import(ns.Share.ExportGroup(empty_target), 'group')
assert not isinstance(empty_target_copy, tuple)
ns.Prepare(empty_target_copy)
assert lua_type(empty_target_copy.target) == 'table' and len(empty_target_copy.target) == 0
observe('config and empty-target group round-trip', 'passed', 'Explicitly selecting no units stays empty instead of loading on player.')

group.displays[1]['class'] = ''
legacy_class = ns.Share.Import(ns.Share.ExportGroup(group), 'group')
assert not isinstance(legacy_class, tuple)
ns.Prepare(legacy_class)
assert len(legacy_class.displays[1]['class']) == 0
observe('legacy empty-string class override', 'passed', 'Legacy all-classes override is exported as an empty list.')

for key in ['max', 'wrap', 'lineCap']:
    value = ns.Share.Import('SlopAuras:1:display:'+json.dumps({key:1.5}), 'display')
    assert isinstance(value, tuple) and value[0] is None, f'Fractional {key} was accepted'
    assert 'whole number' in value[1]
    for bound in [1, 40]:
        accepted = ns.Share.Import('SlopAuras:1:display:'+json.dumps({key:bound}), 'display')
        assert not isinstance(accepted, tuple) and accepted[key] == bound
    observe('integer '+key+' import', 'passed', 'Fraction rejected; both integer boundaries accepted.')

for key, upper in [('layer',10), ('lineMax',40)]:
    value = ns.Share.Import('SlopAuras:1:group:'+json.dumps({'name':'count check',key:1.5}), 'group')
    assert isinstance(value, tuple) and value[0] is None and 'whole number' in value[1]
    for bound in [1, upper]:
        accepted = ns.Share.Import('SlopAuras:1:group:'+json.dumps({'name':'count check',key:bound}), 'group')
        assert not isinstance(accepted, tuple)
observe('integer layer and legacy lineMax', 'passed', 'Discrete group values reject fractions and accept bounds.')

fractional_pixels = ns.Share.Import('SlopAuras:1:display:{"size":24.5,"spacing":2.5,"maxDuration":30.5}', 'display')
assert not isinstance(fractional_pixels, tuple) and fractional_pixels.size == 24.5
assert fractional_pixels.spacing == 2.5 and fractional_pixels.maxDuration == 30.5
observe('continuous settings retain fractions', 'passed', 'Pixel geometry and duration still accept fractional values.')

empty_ids = to_lua({'spellIDs':{}, 'rankSpellIDs':{}})
exported_ids = json.loads(ns.Share.ExportDisplay(empty_ids, False).split(':',3)[3])
assert 'spellIDs' not in exported_ids and 'rankSpellIDs' not in exported_ids
assert not isinstance(ns.Share.Import(ns.Share.ExportDisplay(empty_ids,False),'display'), tuple)
observe('empty spell-ID sets stay omitted', 'passed', 'No invalid empty ID lists introduced.')

invalid = ns.Share.Import('SlopAuras:1:display:{"size":999}', 'display')
assert isinstance(invalid, tuple) and invalid[0] is None
observe('out-of-range size rejection', 'passed', invalid[1])
invalid = ns.Share.Import('SlopAuras:1:display:{"unknown":true}', 'display')
assert isinstance(invalid, tuple) and invalid[0] is None
observe('unknown setting rejection', 'passed', invalid[1])

# v0.6.1 bundle exports retain bundle membership; standalone groups omit it.
group.suite = 'QA bundle'
bundle = ns.Share.Import(ns.Share.ExportConfig(lua.table_from([group])), 'config')
assert not isinstance(bundle, tuple) and bundle[1].suite == 'QA bundle'
ns.Prepare(bundle[1])
assert len(bundle[1].displays[1].unitPower) == 0 and len(bundle[1].displays[1]['class']) == 0
assert 'suite' not in json.loads(ns.Share.ExportGroup(group).split(':', 3)[3])
observe('bundle and standalone-group export', 'passed', 'Bundle membership and explicit overrides survive config exports.')
print(f'{len(observations)} sharing checks passed; {len(syntax)} addon Lua files compiled.')
