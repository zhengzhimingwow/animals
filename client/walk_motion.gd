extends RefCounted
## A confirmed world step is interpolated; turns stay on the edges of the grid.

const STEP_SECONDS := 0.245
const CORRECTION_SECONDS := 0.10
const WALK_RELEASE_SECONDS := 0.075
const MAX_PENDING_STEPS := 4

var position: Vector2
var direction := Vector2i.DOWN

var _latest: Vector2i
var _source: Vector2
var _destination: Vector2i
var _pending: Array[Vector2i] = []
var _walking := false
var _elapsed := 0.0
var _duration := STEP_SECONDS
var _release := 0.0
var _correcting := false

func _init(cell: Vector2i) -> void:
    position = Vector2(cell)
    _latest = cell

func observe(cell: Vector2i) -> void:
    var previous := _latest
    if cell == previous:
        return
    _latest = cell

    var step := cell - previous
    if absi(step.x) + absi(step.y) != 1 or _pending.size() >= MAX_PENDING_STEPS:
        _pending.clear()
        _walking = false
        _elapsed = 0.0
        _release = 0.0
        _correcting = false
        position = Vector2(cell)
    elif _walking:
        _pending.push_back(cell)
    else:
        _begin(previous, cell)

func _begin(start: Vector2i, end: Vector2i) -> void:
    _source = Vector2(start)
    _destination = end
    _walking = true
    _elapsed = 0.0
    _duration = STEP_SECONDS
    _correcting = false
    direction = end - start

func correct(cell: Vector2i) -> void:
    _pending.clear()
    _latest = cell
    _destination = cell
    _source = position
    _elapsed = 0.0
    _release = 0.0
    _duration = CORRECTION_SECONDS
    _walking = not position.is_equal_approx(Vector2(cell))
    _correcting = _walking

func advance(delta: float) -> bool:
    var moved := _walking
    while _walking and delta > 0.0:
        var interval := minf(delta, _duration - _elapsed)
        _elapsed += interval
        delta -= interval
        position = _source.lerp(Vector2(_destination), _elapsed / _duration)
        if _elapsed >= _duration:
            position = Vector2(_destination)
            if _pending.is_empty():
                _release = 0.0 if _correcting else WALK_RELEASE_SECONDS
                _walking = false
                _correcting = false
            else:
                _begin(_destination, _pending.pop_front())
    if not _walking:
        _release = maxf(0.0, _release - delta)
    return moved

func is_walking() -> bool:
    return _walking

func wants_walk() -> bool:
    return (_walking and not _correcting) or _release > 0.0
