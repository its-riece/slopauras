"""Offline Lua 5.1 harness; mocks do not reproduce WoW secrecy or rendering.

Run with Python and lupa==2.6 (Lua 5.1); see the documentation in tests/.
"""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--dependency-path', type=Path)
args = parser.parse_args()
if args.dependency_path:
    sys.path.insert(0, str(args.dependency_path))
from lupa.lua51 import LuaRuntime, lua_type

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
local function noop() end
local dummy = {RegisterCallback = noop}
function LibStub(name, optional)
  if name == 'Masque' then return nil end
  return dummy
end
AnchorUtil = {FlowDirection = {Left=1,Right=2,Up=3,Down=4}, FlowLayoutAxis={Horizontal=1,Vertical=2}}
Enum = setmetatable({}, {__index=function(t,k)
  local group=setmetatable({}, {__index=function(g,n) rawset(g,n,1); return 1 end})
  rawset(t,k,group); return group
end})
function CreateFrame() return setmetatable({}, {__index=function() return noop end}) end
function hooksecurefunc() end
function UnitClassBase() return 'PRIEST' end
C_SpellBook = {IsSpellKnown=function(id) return id==527 end}
C_EventUtils = {IsEventValid=function() return true end}
CLASS_SORT_ORDER={'WARRIOR','PRIEST','MAGE','DRUID','HUNTER','PALADIN','ROGUE','SHAMAN','WARLOCK'}
AuraContainerSortMethod={Default=1,ExpirationOnly=2,Name=3}
AuraContainerSortDirection={Normal=1,Reverse=2}
function tContains(t, v) for _, x in ipairs(t) do if x==v then return true end end return false end
function wipe(t) for k in pairs(t) do t[k]=nil end end
function strtrim(s) return s:match('^%s*(.-)%s*$') end
function CopyTable(t)
  local copy={}; for k,v in pairs(t) do copy[k]=type(v)=='table' and CopyTable(v) or v end
  return copy
end
AuraUtil={AuraFilters={IncludeNameplateOnly='INCLUDE_NAME_PLATE_ONLY'}}
function AuraUtil.IsValidFilterString(s) return type(s)=='string' and s~='', 'mock invalid filter' end
''')

def to_python(value):
    if lua_type(value) != 'table':
        return value
    keys = list(value.keys())
    if not keys or set(keys) == set(range(1, len(keys)+1)):
        return [to_python(value[i]) for i in range(1, len(keys)+1)]
    return {str(k): to_python(value[k]) for k in keys}

def to_lua(value):
    if isinstance(value, dict):
        return lua.table_from({k: to_lua(v) for k,v in value.items()})
    if isinstance(value, list):
        return lua.table_from([to_lua(v) for v in value])
    return value

lua.globals().C_EncodingUtil = lua.table_from({
    'SerializeJSON': lambda x: json.dumps(to_python(x), separators=(',', ':')),
    'DeserializeJSON': lambda x: to_lua(json.loads(x)),
})
ns = lua.table()
syntax = []
compile_lua = lua.eval('function(s,n) local f,e=loadstring(s,n); return f~=nil,e end')
for path in sorted((ROOT/'SlopAuras').rglob('*.lua')):
    ok, error = compile_lua(path.read_text(encoding='utf-8-sig'), str(path))
    if not ok:
        raise AssertionError(f'{path}: {error}')
    syntax.append(str(path.relative_to(ROOT)))
for name in ['Ranks.lua', 'Chain.lua', 'SlopAuras.lua', 'Share.lua']:
    lua.execute((ROOT/'SlopAuras'/name).read_text(encoding='utf-8-sig'), 'SlopAuras', ns)

observations = []
def observe(name, status, details):
    observations.append(dict(name=name, status=status, details=details))
    print(f"PASS: {name}")

