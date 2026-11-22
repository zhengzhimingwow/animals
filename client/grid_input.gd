extends RefCounted
## The world confirms cells. At most one request may be previewed locally.

const OUTSIDE := Vector2i(-1, -1)
const STEP_INTERVAL_MS := 255
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]

var cell := OUTSIDE
var pending := OUTSIDE
var goal := OUTSIDE
var _goal_radius := 0
var _held: Dictionary = {}
var _tap := Vector2i.ZERO
var _next_step_at := 0

func observe(confirmed: Vector2i) -> bool:
    if cell == confirmed:
        return false
    var correction := pending != OUTSIDE and pending != confirmed
    cell = confirmed
    pending = OUTSIDE
    return correction

func press(key: int, direction: Vector2i) -> void:
    goal = OUTSIDE
    _held.erase(key)
    _held[key] = direction
    _tap = direction

func release(key: int) -> void:
    _held.erase(key)

func clear_intent() -> void:
    _held.clear()
    _tap = Vector2i.ZERO
    goal = OUTSIDE

func seek(tiles: Array, target: Vector2i, radius: int, blocked: Dictionary = {}) -> bool:
    clear_intent()
    var previous := pending if pending != OUTSIDE else cell
    if route_step(tiles, previous, target, radius, blocked) == OUTSIDE:
        return false
    goal = target
    _goal_radius = radius
    return true

func at_goal() -> bool:
    return pending == OUTSIDE and goal != OUTSIDE and distance(cell, goal) <= _goal_radius

func next_step(tiles: Array, now: int, blocked: Dictionary = {}) -> Vector2i:
    if cell == OUTSIDE or pending != OUTSIDE or now < _next_step_at:
        return Vector2i.ZERO
    if goal != OUTSIDE:
        return route_step(tiles, cell, goal, _goal_radius, blocked)
    var step := _tap
    _tap = Vector2i.ZERO
    if step == Vector2i.ZERO and not _held.is_empty():
        step = _held[_held.keys().back()]
    if step != Vector2i.ZERO and walkable(tiles, cell + step, blocked):
        return step
    return Vector2i.ZERO

func begin_step(step: Vector2i, now: int) -> void:
    pending = cell + step
    _next_step_at = now + STEP_INTERVAL_MS

func reject() -> void:
    pending = OUTSIDE

static func distance(from: Vector2i, to: Vector2i) -> int:
    return absi(from.x - to.x) + absi(from.y - to.y)

static func walkable(tiles: Array, tile: Vector2i, blocked: Dictionary = {}) -> bool:
    if tile.y < 1 or tile.y > tiles.size() or blocked.has(tile):
        return false
    var row := String(tiles[tile.y - 1])
    return tile.x >= 1 and tile.x <= row.length() and row.substr(tile.x - 1, 1) in [".", ",", "D"]

static func route_step(tiles: Array, start: Vector2i, finish: Vector2i, radius: int, blocked: Dictionary = {}) -> Vector2i:
    if not walkable(tiles, start, blocked):
        return OUTSIDE
    if distance(start, finish) <= radius:
        return Vector2i.ZERO
    var frontier: Array[Vector2i] = [start]
    var first_steps := {start: Vector2i.ZERO}
    var head := 0
    while head < frontier.size():
        var tile := frontier[head]
        head += 1
        for direction in DIRECTIONS:
            var neighbor: Vector2i = tile + direction
            if first_steps.has(neighbor) or not walkable(tiles, neighbor, blocked):
                continue
            var step: Vector2i = direction if tile == start else first_steps[tile]
            if distance(neighbor, finish) <= radius:
                return step
            first_steps[neighbor] = step
            frontier.append(neighbor)
    return OUTSIDE
