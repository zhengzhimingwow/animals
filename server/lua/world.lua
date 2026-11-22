local World = {}
World.__index = World

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

local function nearby(player, target)
    return math.abs(player.x - target.x) + math.abs(player.y - target.y) <= 1
end

local function matches_when(state, when)
    if not when then return true end
    if when.quest ~= nil and state.quest ~= when.quest then return false end
    if when.found_trail ~= nil and state.found_trail ~= when.found_trail then return false end
    if when.min_gall ~= nil and (state.gall or 0) < when.min_gall then return false end
    if when.min_coins ~= nil and (state.coins or 0) < when.min_coins then return false end
    return true
end

local function compute_changes(state, spec)
    if not spec then return nil end
    local changes = {}
    local has_any = false
    if spec.quest ~= nil then changes.quest = spec.quest; has_any = true end
    if spec.found_trail ~= nil then changes.found_trail = spec.found_trail; has_any = true end
    if spec.delta_gall ~= nil then changes.gall = (state.gall or 0) + spec.delta_gall; has_any = true end
    if spec.delta_coins ~= nil then changes.coins = (state.coins or 0) + spec.delta_coins; has_any = true end
    return has_any and changes or nil
end

local function init_map(def)
    local walkable_set = {}
    for _, ch in ipairs(def.walkable_tiles or {'.', ',', 'D'}) do
        walkable_set[ch] = true
    end
    local monsters = {}
    local primary_monster = nil
    for fid, feat in pairs(def.features or {}) do
        if feat.kind == 'monster' then
            local max_hp = feat.max_hp or 3
            monsters[fid] = {
                id = fid,
                hp = max_hp,
                max_hp = max_hp,
                respawn_ms = feat.respawn_ms or 10000,
                respawn_at = 0,
                locking = false,
                drop_item = feat.drop_item or 'gall',
                drop_count = feat.drop_count or 1,
            }
            if not primary_monster then primary_monster = fid end
        end
    end
    local tiles = def.tiles or {}
    local width = #tiles > 0 and #tiles[1] or 0
    return {
        id = def.id,
        name = def.name or def.id,
        scene = def.scene or def.id,
        spawn = def.spawn or {x = 2, y = 4},
        tiles = tiles,
        width = width,
        height = #tiles,
        walkable_set = walkable_set,
        features = def.features or {},
        plaques = def.plaques or {},
        portals = def.portals or {},
        monsters = monsters,
        primary_monster = primary_monster,
    }
end

function World.new(load_record, save_record, clock, content)
    assert(type(content) == 'table' and type(content.maps) == 'table', 'World requires data-driven content table')
    local quests = content.quests or {}
    local maps = {}
    local first_map = nil
    for map_id, def in pairs(content.maps) do
        maps[map_id] = init_map(def)
        if not first_map then first_map = map_id end
    end
    local default_map = quests.default_map or first_map
    assert(maps[default_map], 'Default map missing from content.maps')
    return setmetatable({
        load_record = load_record,
        save_record = save_record,
        clock = clock,
        maps = maps,
        default_map = default_map,
        move_cooldown_ms = quests.move_cooldown_ms or 230,
        attack_cooldown_ms = quests.attack_cooldown_ms or 600,
        quest_hints = quests.quest_hints or {},
        interactions = quests.interactions or {},
        players = {},
        joining = {},
    }, World)
end

function World:reload(content)
    assert(type(content) == 'table' and type(content.maps) == 'table', 'Invalid content table')
    local quests = content.quests or {}
    local next_maps = {}
    local first_map = nil
    for map_id, def in pairs(content.maps) do
        local m = init_map(def)
        assert(m.width > 0 and m.height > 0, 'Map tiles cannot be empty: ' .. tostring(map_id))
        local old_map = self.maps[map_id]
        if old_map then
            for mid, monster in pairs(m.monsters) do
                local prev = old_map.monsters[mid]
                if prev then
                    monster.hp = math.min(prev.hp, monster.max_hp)
                    monster.respawn_at = prev.respawn_at
                    monster.locking = prev.locking
                end
            end
        end
        next_maps[map_id] = m
        if not first_map then first_map = map_id end
    end
    local next_default = quests.default_map or first_map
    assert(next_maps[next_default], 'Default map missing in reloaded content')

    self.maps = next_maps
    self.default_map = next_default
    self.move_cooldown_ms = quests.move_cooldown_ms or 230
    self.attack_cooldown_ms = quests.attack_cooldown_ms or 600
    self.quest_hints = quests.quest_hints or {}
    self.interactions = quests.interactions or {}

    for _, player in pairs(self.players) do
        local map = self.maps[player.state.map] or self.maps[self.default_map]
        player.state.map = map.id
        if not self:walkable(map, player.state.x, player.state.y) then
            player.state.x, player.state.y = map.spawn.x, map.spawn.y
            player.dirty = true
        end
    end

    local active_map = self.maps[self.default_map]
    return {
        type = 'map_updated',
        map = self:map_payload(active_map),
        world = self:snapshot(active_map.id),
    }
end

function World:walkable(map, x, y)
    if math.type(x) ~= 'integer' or math.type(y) ~= 'integer'
        or x < 1 or x > map.width or y < 1 or y > map.height then return false end
    local tile = map.tiles[y]:sub(x, x)
    if not map.walkable_set[tile] then return false end
    for _, feature in pairs(map.features) do
        if feature.blocking ~= false and feature.x == x and feature.y == y then
            return false
        end
    end
    return true
end

function World:player_map(player)
    local map_id = player and player.state and player.state.map or self.default_map
    return self.maps[map_id] or self.maps[self.default_map]
end

function World:map_payload(map)
    return {
        id = map.id,
        name = map.name,
        scene = map.scene,
        tiles = map.tiles,
        features = map.features,
        plaques = map.plaques,
        quest_hints = self.quest_hints,
    }
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

    local default_map = self.maps[self.default_map]
    if not state then
        state = {
            map = default_map.id,
            x = default_map.spawn.x,
            y = default_map.spawn.y,
            quest = 'new',
            found_trail = false,
            gall = 0,
            coins = 0,
            revision = 0,
        }
    else
        local map = self.maps[state.map] or default_map
        state.map = map.id
        if not self:walkable(map, state.x, state.y) then
            state.x, state.y = map.spawn.x, map.spawn.y
        end
    end
    local map = self.maps[state.map]
    self.players[id] = {state = state, facing = 'down', next_move = 0, next_attack = 0}
    local event = {type = 'event', event = 'player_joined', id = id, map = map.id,
        x = state.x, y = state.y, facing = 'down'}
    return {type = 'joined', id = id, map = self:map_payload(map),
        player = self:private(id)}, event
end

function World:leave(id)
    local player = self.players[id]
    if not player then return nil, true end
    local map_id = player.state.map or self.default_map
    self.players[id] = nil
    local event = {type = 'event', event = 'player_left', id = id, map = map_id}
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

function World:snapshot(map_id)
    local map = self.maps[map_id or self.default_map] or self.maps[self.default_map]
    local players = {}
    for id, player in pairs(self.players) do
        if (player.state.map or self.default_map) == map.id then
            players[id] = {x = player.state.x, y = player.state.y, facing = player.facing}
        end
    end
    local monsters = {}
    local primary = {hp = 0, alive = false}
    for mid, m in pairs(map.monsters) do
        local info = {hp = m.hp, max_hp = m.max_hp, alive = m.hp > 0}
        monsters[mid] = info
        if mid == map.primary_monster then
            primary = {hp = m.hp, alive = m.hp > 0}
        end
    end
    return {type = 'world', map = map.id, players = players, monster = primary, monsters = monsters}
end

function World:tick()
    local now = self.clock()
    for map_id, map in pairs(self.maps) do
        for mid, m in pairs(map.monsters) do
            if m.hp == 0 and now >= m.respawn_at then
                m.hp = m.max_hp
                return {type = 'event', event = 'monster_respawned', map = map_id,
                    target = mid, hp = m.hp, alive = true}
            end
        end
    end
    return nil
end

function World:move(id, player, request)
    local dx, dy = request.dx, request.dy
    if math.type(dx) ~= 'integer' or math.type(dy) ~= 'integer'
        or not ((dx == -1 or dx == 1) and dy == 0 or (dy == -1 or dy == 1) and dx == 0) then
        return error_reply('invalid_step')
    end
    local map = self:player_map(player)
    local x, y = player.state.x + dx, player.state.y + dy
    if not self:walkable(map, x, y) then return error_reply('blocked') end
    local now = self.clock()
    if now < player.next_move then return error_reply('too_fast') end
    player.state.x, player.state.y = x, y
    player.facing = facing_name(dx, dy)
    player.next_move = now + self.move_cooldown_ms
    player.dirty = true
    local event = {type = 'event', event = 'player_moved', id = id, map = map.id,
        x = x, y = y, facing = player.facing}
    return {type = 'moved', x = x, y = y, facing = player.facing}, event
end

function World:interact(id, target)
    local player = self.players[id]
    local map = self:player_map(player)
    local feature = map.features[target]
    if not feature or feature.kind == 'monster' then return error_reply('unknown_target') end
    if not nearby(player.state, feature) then return error_reply('too_far') end

    local rules = self.interactions[target]
    if not rules then return error_reply('unknown_target') end
    local text, changes = '', nil
    for _, rule in ipairs(rules) do
        if matches_when(player.state, rule.when) then
            text = rule.text or ''
            changes = compute_changes(player.state, rule.changes)
            break
        end
    end

    if changes and not self:commit(id, changes) then return error_reply('save_failed') end
    local next_facing = facing_towards(player.state, feature, player.facing)
    local event = nil
    if next_facing ~= player.facing then
        player.facing = next_facing
        event = {type = 'event', event = 'player_faced', id = id, map = map.id, facing = player.facing}
    end
    return {type = 'dialogue', speaker = feature.label, text = text, player = self:private(id)}, event
end

function World:attack(id, target)
    local player = self.players[id]
    local map = self:player_map(player)
    local feature = map.features[target]
    local monster = map.monsters[target]
    if not feature or not monster then return error_reply('unknown_target') end
    if not nearby(player.state, feature) then return error_reply('too_far') end
    if monster.hp == 0 or monster.locking then return error_reply('already_defeated') end
    local now = self.clock()
    if now < player.next_attack then return error_reply('too_fast') end

    if monster.hp == 1 then
        monster.locking = true
        local drop_key = monster.drop_item
        local changes = {[drop_key] = (player.state[drop_key] or 0) + monster.drop_count}
        local ok = self:commit(id, changes)
        monster.locking = false
        if not ok then return error_reply('save_failed') end
        now = self.clock()
        monster.respawn_at = now + monster.respawn_ms
    end
    monster.hp = monster.hp - 1
    player.facing = facing_towards(player.state, feature, player.facing)
    player.next_attack = now + self.attack_cooldown_ms
    local event = {type = 'event', event = 'player_attacked', id = id, map = map.id, target = target,
        facing = player.facing, hp = monster.hp, alive = monster.hp > 0}
    return {type = 'hit', target = target, hp = monster.hp, player = self:private(id)}, event
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
