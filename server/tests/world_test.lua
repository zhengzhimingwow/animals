local World = dofile('lua/world.lua')

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
        function() return clock end)
end

local game = world()
assert(game:join('a').type == 'joined')
assert(game:join('b').type == 'joined')
assert(game:join('a').code == 'already_online')
assert(game:snapshot().players.a.x == 2)
assert(game:request('a', {type = 'move', dx = 20, dy = 0}).code == 'invalid_step')
assert(game:request('a', {type = 'move', dx = -1, dy = 0}).code == 'blocked')
assert(game:request('a', {type = 'interact', target = 'reed_trail'}).code == 'too_far')

local function move(id, dx, dy, count)
    for _ = 1, count or 1 do
        clock = clock + 250
        local reply = game:request(id, {type = 'move', dx = dx, dy = dy})
        assert(reply.type == 'moved', reply.code)
    end
end

local function act(id, kind, target)
    return game:request(id, {type = kind, target = target})
end

assert(act('a', 'interact', 'apothecary').type == 'dialogue')
assert(game:private('a').quest == 'search')
assert(game:private('b').quest == 'new')
move('a', 1, 0, 7)
assert(game:snapshot().players.a.x == 9)
assert(act('a', 'interact', 'reed_trail').type == 'dialogue')
move('a', 1, 0)
assert(act('a', 'attack', 'reed_snake').hp == 2)
clock = clock + 600
assert(act('a', 'attack', 'reed_snake').hp == 1)
clock = clock + 600
fail_save = true
assert(act('a', 'attack', 'reed_snake').code == 'save_failed')
assert(game:snapshot().monster.hp == 1)
fail_save = false
assert(act('a', 'attack', 'reed_snake').hp == 0)
assert(not game:snapshot().monster.alive)
assert(game:private('a').gall == 1 and game:private('b').gall == 0)
move('a', -1, 0, 8)
assert(act('a', 'interact', 'apothecary').type == 'dialogue')
assert(act('a', 'interact', 'apothecary').type == 'dialogue')
assert(game:private('a').coins == 12 and game:private('a').gall == 0)
assert(game:private('b').coins == 0)

assert(game:leave('a'))
assert(not game:snapshot().players.a)
local restarted = world()
assert(restarted:join('a').type == 'joined')
assert(restarted:private('a').quest == 'done' and restarted:private('a').coins == 12)
print('shared world, server validation, isolated quests, atomic reward and reload passed')
