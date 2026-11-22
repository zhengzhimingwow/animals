local World = dofile('lua/world.lua')

-- Minimal JSON reader so tests load the exact same server/data/*.json files as production
local function parse_json(text)
    local pos = 1
    local function skip()
        pos = text:match('^%s*()', pos)
    end
    local parse_val
    local function parse_str()
        pos = pos + 1
        local out = {}
        while pos <= #text do
            local ch = text:sub(pos, pos)
            if ch == '"' then pos = pos + 1; return table.concat(out) end
            if ch == '\\' then
                local esc = text:sub(pos + 1, pos + 1)
                local map = {n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/'}
                out[#out + 1] = map[esc] or esc
                pos = pos + 2
            else
                out[#out + 1] = ch
                pos = pos + 1
            end
        end
        error('unterminated string')
    end
    parse_val = function()
        skip()
        local ch = text:sub(pos, pos)
        if ch == '"' then return parse_str() end
        if ch == '{' then
            pos = pos + 1
            local obj = {}
            skip()
            if text:sub(pos, pos) == '}' then pos = pos + 1; return obj end
            while true do
                skip()
                local k = parse_str()
                skip()
                assert(text:sub(pos, pos) == ':')
                pos = pos + 1
                obj[k] = parse_val()
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == '}' then return obj end
                assert(sep == ',')
            end
        end
        if ch == '[' then
            pos = pos + 1
            local arr = {}
            skip()
            if text:sub(pos, pos) == ']' then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parse_val()
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == ']' then return arr end
                assert(sep == ',')
            end
        end
        if text:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true end
        if text:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false end
        if text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil end
        local num, next_pos = text:match('^(-?%d+%.?%d*)()', pos)
        assert(num, 'unexpected token at ' .. pos)
        pos = next_pos
        return tonumber(num)
    end
    return parse_val()
end

local function load_json_file(path)
    local f = assert(io.open(path, 'rb'))
    local raw = f:read('*a')
    f:close()
    return parse_json(raw)
end

local content = {
    maps = { ferry = load_json_file('data/maps/ferry.json') },
    quests = load_json_file('data/quests.json'),
}

local clock, fail_save = 0, false
local records = {}
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = copy(entry) end
    return result
end

local function world()
    return World.new(function(id) return copy(records[id]) end,
        function(id, state, revision)
            local current = records[id]
            if fail_save or (current and current.revision or 0) ~= revision then return false end
            records[id] = copy(state)
            return true
        end,
        function() return clock end,
        content)
end

local game = world()
local join_reply, join_event = game:join('a')
assert(join_reply.type == 'joined' and join_event.event == 'player_joined' and join_event.facing == 'down')
assert(game:join('b').type == 'joined')
assert(game:join('a').code == 'already_online')
assert(game:snapshot().players.a.x == 3 and game:snapshot().players.a.facing == 'down')
assert(game:request('a', {type = 'move', dx = 20, dy = 0}).code == 'invalid_step')
assert(game:request('a', {type = 'move', dx = 0, dy = -1}).code == 'blocked') -- apothecary at (3, 3)
assert(game:request('a', {type = 'interact', target = 'reed_trail'}).code == 'too_far')

local function move(id, dx, dy, count)
    for _ = 1, count or 1 do
        clock = clock + 250
        local reply, event = game:request(id, {type = 'move', dx = dx, dy = dy})
        assert(reply.type == 'moved', reply.code)
        assert(event.type == 'event' and event.event == 'player_moved' and event.id == id)
    end
end

local function act(id, kind, target)
    return game:request(id, {type = kind, target = target})
end

local dlg_reply, face_event = act('a', 'interact', 'apothecary')
assert(dlg_reply.type == 'dialogue' and face_event.event == 'player_faced' and face_event.facing == 'up')
assert(game:private('a').quest == 'search')
assert(game:private('b').quest == 'new')
move('a', 1, 0, 11) -- (3,4) -> (14,4)
move('a', 0, 1, 3)  -- (14,4) -> (14,7)
assert(game:snapshot().players.a.x == 14 and game:snapshot().players.a.y == 7)
assert(act('a', 'interact', 'reed_trail').type == 'dialogue')
move('a', 1, 0) -- (15,7), adjacent to reed_snake at (16,7)
local hit1, atk_event = act('a', 'attack', 'reed_snake')
assert(hit1.hp == 2 and atk_event.event == 'player_attacked' and atk_event.hp == 2 and atk_event.alive)
clock = clock + 600
assert(act('a', 'attack', 'reed_snake').hp == 1)
clock = clock + 600
fail_save = true
assert(act('a', 'attack', 'reed_snake').code == 'save_failed')
assert(game:snapshot().monster.hp == 1)
fail_save = false
local kill_reply, kill_event = act('a', 'attack', 'reed_snake')
assert(kill_reply.hp == 0 and kill_event.event == 'player_attacked' and not kill_event.alive)
assert(not game:snapshot().monster.alive)
assert(game:private('a').gall == 1 and game:private('b').gall == 0)
clock = clock + 10000
local respawn_event = game:tick()
assert(respawn_event and respawn_event.event == 'monster_respawned' and respawn_event.hp == 3 and respawn_event.alive)
move('a', 0, -1, 3) -- (15,4)
move('a', -1, 0, 12) -- (3,4)
assert(act('a', 'interact', 'apothecary').type == 'dialogue')
assert(act('a', 'interact', 'apothecary').type == 'dialogue')
assert(game:private('a').coins == 12 and game:private('a').gall == 0)
assert(game:private('b').coins == 0)

local left_event, left_saved = game:leave('a')
assert(left_event.event == 'player_left' and left_event.id == 'a' and left_saved)
assert(not game:snapshot().players.a)
local restarted = world()
assert(restarted:join('a').type == 'joined')
assert(restarted:private('a').quest == 'done' and restarted:private('a').coins == 12)

-- Verify Lua coroutine suspension across async load_record / save_record
local async_world = World.new(
    function(id)
        local loaded = coroutine.yield('load', id)
        return loaded
    end,
    function(id, state, revision)
        return coroutine.yield('save', id, state, revision)
    end,
    function() return clock end,
    content)

local join_a1 = coroutine.create(function() return async_world:join('c') end)
local ok1, op1, id1 = coroutine.resume(join_a1)
assert(ok1 and op1 == 'load' and id1 == 'c')
-- Concurrent duplicate login while first load_record is in flight must be rejected
local join_a2 = coroutine.create(function() return async_world:join('c') end)
local ok2, reply2 = coroutine.resume(join_a2)
assert(ok2 and reply2.code == 'already_online')
local ok3, reply3 = coroutine.resume(join_a1, nil)
assert(ok3 and reply3.type == 'joined')

-- Concurrent killing blow while save_record is in flight must not double-kill
local join_d = coroutine.create(function() return async_world:join('d') end)
coroutine.resume(join_d)
coroutine.resume(join_d, {x = 15, y = 7, quest = 'hunt', found_trail = true, gall = 0, coins = 0, revision = 1})
local join_e = coroutine.create(function() return async_world:join('e') end)
coroutine.resume(join_e)
coroutine.resume(join_e, {x = 15, y = 7, quest = 'hunt', found_trail = true, gall = 0, coins = 0, revision = 1})
assert(async_world:request('d', {type = 'attack', target = 'reed_snake'}).hp == 2)
assert(async_world:request('e', {type = 'attack', target = 'reed_snake'}).hp == 1)
clock = clock + 600
local kill_d = coroutine.create(function() return async_world:request('d', {type = 'attack', target = 'reed_snake'}) end)
local okk1, kop = coroutine.resume(kill_d)
assert(okk1 and kop == 'save')
local kill_e = coroutine.create(function() return async_world:request('e', {type = 'attack', target = 'reed_snake'}) end)
local okk2, kreply = coroutine.resume(kill_e)
assert(okk2 and kreply.code == 'already_defeated')
local okk3, kdone = coroutine.resume(kill_d, true)
assert(okk3 and kdone.hp == 0 and async_world:private('d').gall == 1 and async_world:private('e').gall == 0)

-- Verify hot-reload preserves live player & monster runtime state while applying new config
local reloaded_content = copy(content)
reloaded_content.quests.move_cooldown_ms = 200
reloaded_content.quests.interactions.boatman = {{when = {}, text = '热更新后的牛船工台词。'}}
local hot_update = game:reload(reloaded_content)
assert(hot_update.type == 'map_updated' and hot_update.map.id == 'ferry')
assert(game:snapshot().players.b ~= nil)
assert(game.move_cooldown_ms == 200)

print('shared world, server validation, isolated quests, atomic reward, reload, async guards and hot-reload passed')
