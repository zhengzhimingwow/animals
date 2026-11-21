local World = {}
World.__index = World

local width = 12
local tiles = {
    '############',
    '##....#~~~~#',
    '#......~D~~#',
    '#..........#',
    '#....#.....#',
    '#....#..,,,#',
    '##......,,##',
    '############',
}
local features = {
    apothecary = {x = 2, y = 3, label = '兔药师'},
    boatman = {x = 7, y = 3, label = '牛船工'},
    reed_trail = {x = 9, y = 5, label = '空药箱'},
    reed_snake = {x = 11, y = 4, label = '芦滩蛇'},
}

local function error_reply(code)
    return {type = 'error', code = code}, nil
end

local function facing_name(dx, dy)
    if dx < 0 then return 'left' end
    if dx > 0 then return 'right' end
    if dy < 0 then return 'up' end
    return 'down'
end

local function facing_towards(from, to, fallback)
    local dx, dy = to.x - from.x, to.y - from.y
    if dx == 0 and dy == 0 then return fallback end
    if math.abs(dx) >= math.abs(dy) then
        return dx > 0 and 'right' or 'left'
    end
    return dy > 0 and 'down' or 'up'
end

local function walkable(x, y)
    if math.type(x) ~= 'integer' or math.type(y) ~= 'integer'
        or x < 1 or x > width or y < 1 or y > #tiles then return false end
    local tile = tiles[y]:sub(x, x)
    if not (tile == '.' or tile == ',' or tile == 'D') then return false end
    for _, feature in pairs(features) do
        if feature.x == x and feature.y == y then return false end
    end
    return true
end

local function nearby(player, target)
    return math.abs(player.x - target.x) + math.abs(player.y - target.y) <= 1
end

function World.new(load_record, save_record, clock)
    return setmetatable({
        load_record = load_record,
        save_record = save_record,
        clock = clock,
        players = {},
        joining = {},
        monster_hp = 3,
        monster_locking = false,
        respawn_at = 0,
    }, World)
end

function World:commit(id, changes)
    local player = self.players[id]
    local next_state = {}
    for key, value in pairs(player.state) do next_state[key] = value end
    for key, value in pairs(changes or {}) do next_state[key] = value end
    next_state.revision = player.state.revision + 1

    if not self.save_record(id, next_state, player.state.revision) then return false end
    player.state = next_state
    player.dirty = false
    return true
end

function World:join(id)
    if self.players[id] or self.joining[id] then return error_reply('already_online') end
    self.joining[id] = true
    local state, load_error = self.load_record(id)
    self.joining[id] = nil
    if load_error then return error_reply('store_unavailable') end
    if not state then
        state = {x = 2, y = 4, quest = 'new', found_trail = false, gall = 0, coins = 0, revision = 0}
    elseif not walkable(state.x, state.y) then
        state.x, state.y = 2, 4
    end
    self.players[id] = {state = state, facing = 'down', next_move = 0, next_attack = 0}
    local event = {type = 'event', event = 'player_joined', id = id,
        x = state.x, y = state.y, facing = 'down'}
    return {type = 'joined', id = id, map = {id = 'ferry', tiles = tiles, features = features},
        player = self:private(id)}, event
end

function World:leave(id)
    local player = self.players[id]
    if not player then return nil, true end
    self.players[id] = nil
    local event = {type = 'event', event = 'player_left', id = id}
    if not player.dirty then return event, true end
    local next_state = {}
    for key, value in pairs(player.state) do next_state[key] = value end
    next_state.revision = player.state.revision + 1
    local saved = self.save_record(id, next_state, player.state.revision)
    return event, saved
end

function World:private(id)
    local state = self.players[id].state
    return {quest = state.quest, gall = state.gall, coins = state.coins}
end

function World:snapshot()
    local players = {}
    for id, player in pairs(self.players) do
        players[id] = {x = player.state.x, y = player.state.y, facing = player.facing}
    end
    return {type = 'world', players = players, monster = {
        hp = self.monster_hp, alive = self.monster_hp > 0,
    }}
end

function World:tick()
    if self.monster_hp == 0 and self.clock() >= self.respawn_at then
        self.monster_hp = 3
        return {type = 'event', event = 'monster_respawned', hp = self.monster_hp, alive = true}
    end
    return nil
end

function World:move(id, player, request)
    local dx, dy = request.dx, request.dy
    if math.type(dx) ~= 'integer' or math.type(dy) ~= 'integer'
        or not ((dx == -1 or dx == 1) and dy == 0 or (dy == -1 or dy == 1) and dx == 0) then
        return error_reply('invalid_step')
    end
    local x, y = player.state.x + dx, player.state.y + dy
    if not walkable(x, y) then return error_reply('blocked') end
    local now = self.clock()
    if now < player.next_move then return error_reply('too_fast') end
    player.state.x, player.state.y = x, y
    player.facing = facing_name(dx, dy)
    player.next_move = now + 150
    player.dirty = true
    local event = {type = 'event', event = 'player_moved', id = id,
        x = x, y = y, facing = player.facing}
    return {type = 'moved', x = x, y = y, facing = player.facing}, event
end

function World:interact(id, target)
    local player = self.players[id]
    local state = player.state
    local feature = features[target]
    if not feature or target == 'reed_snake' then return error_reply('unknown_target') end
    if not nearby(state, feature) then return error_reply('too_far') end

    local text, changes
    if target == 'apothecary' then
        if state.quest == 'new' and state.found_trail then
            changes = {quest = 'hunt'}
            text = '你已经发现了空药箱？原来的药救不了急。药箱旁有芦滩蛇，取一枚蛇胆就能配药。'
        elseif state.quest == 'new' then
            changes = {quest = 'search'}
            text = '替渡口治伤的药没到。你去找牛船工问问，或者沿河看看有没有留下什么。'
        elseif state.quest == 'search' then
            text = '船从东边过来。芦苇滩水浅，东西落水常搁在那儿。'
        elseif state.quest == 'hunt' and state.gall > 0 then
            changes = {quest = 'done', gall = state.gall - 1, coins = state.coins + 12}
            text = '药能配齐了。这十二枚铜钱你收下，渡口的人记得你的情。'
        elseif state.quest == 'hunt' then
            text = '在芦苇滩找一枚蛇胆，回来我就能配药。'
        else
            text = '伤药已经配好了。路过的话，来喝盏茶。'
        end
    elseif target == 'boatman' then
        text = state.found_trail and '你找到了空箱？昨夜在滩上搁浅，原来的药全浸了水。'
            or '昨夜雾大，船在东边搁浅了。你沿着河岸下去看看。'
    else
        text = '空药箱卡在断缆旁，芦苇深处有蛇爬过的痕迹。'
        if not state.found_trail then
            changes = {found_trail = true}
            if state.quest == 'search' then
                changes.quest = 'hunt'
                text = text .. ' 箱盖夹着药师的便笺，上面写着急用时可用蛇胆替代。'
            end
        end
    end

    if changes and not self:commit(id, changes) then return error_reply('save_failed') end
    local next_facing = facing_towards(player.state, feature, player.facing)
    local event = nil
    if next_facing ~= player.facing then
        player.facing = next_facing
        event = {type = 'event', event = 'player_faced', id = id, facing = player.facing}
    end
    return {type = 'dialogue', speaker = feature.label, text = text, player = self:private(id)}, event
end

function World:attack(id, target)
    local player = self.players[id]
    if target ~= 'reed_snake' then return error_reply('unknown_target') end
    if not nearby(player.state, features.reed_snake) then return error_reply('too_far') end
    if self.monster_hp == 0 or self.monster_locking then return error_reply('already_defeated') end
    local now = self.clock()
    if now < player.next_attack then return error_reply('too_fast') end

    if self.monster_hp == 1 then
        self.monster_locking = true
        local ok = self:commit(id, {gall = player.state.gall + 1})
        self.monster_locking = false
        if not ok then return error_reply('save_failed') end
        now = self.clock()
        self.respawn_at = now + 10000
    end
    self.monster_hp = self.monster_hp - 1
    player.facing = facing_towards(player.state, features.reed_snake, player.facing)
    player.next_attack = now + 600
    local event = {type = 'event', event = 'player_attacked', id = id, target = target,
        facing = player.facing, hp = self.monster_hp, alive = self.monster_hp > 0}
    return {type = 'hit', hp = self.monster_hp, player = self:private(id)}, event
end

function World:request(id, request)
    local player = self.players[id]
    if not player then return error_reply('unauthenticated') end
    if type(request) ~= 'table' then return error_reply('invalid_request') end
    if request.type == 'move' then return self:move(id, player, request) end
    if type(request.target) ~= 'string' then return error_reply('invalid_target') end
    if request.type == 'interact' then return self:interact(id, request.target) end
    if request.type == 'attack' then return self:attack(id, request.target) end
    return error_reply('unknown_action')
end

return World
