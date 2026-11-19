extends SceneTree

const Walk = preload("res://walk_motion.gd")
const START := Vector2i(3, 4)

func _initialize() -> void:
    var motion := Walk.new(START)
    if not check(not motion.is_walking() and motion.position == Vector2(START), "spawn starts idle"):
        return

    motion.observe(START + Vector2i.RIGHT)
    if not check(motion.is_walking() and motion.direction == Vector2i.RIGHT, "east step starts walking east"):
        return
    motion.advance(Walk.STEP_SECONDS * 0.3)
    var halfway := motion.position
    motion.observe(START + Vector2i.RIGHT)
    if not check(motion.position == halfway and motion.is_walking(), "repeat snapshots never restart a step"):
        return

    motion.observe(START + Vector2i.ONE)
    motion.advance(Walk.STEP_SECONDS * 0.25)
    if not check(motion.is_walking() and is_equal_approx(motion.position.x, START.x + 0.55)
            and motion.position.y == START.y, "the first step travels only along the east edge"):
        return

    motion.advance(Walk.STEP_SECONDS * 0.55)
    if not check(motion.is_walking() and motion.direction == Vector2i.DOWN
            and is_equal_approx(motion.position.x, START.x + 1.0) and motion.position.y > START.y,
            "a queued turn takes its own edge and changes direction"):
        return

    motion.advance(Walk.STEP_SECONDS)
    if not check(not motion.is_walking() and motion.position == Vector2(START + Vector2i.ONE),
            "motion finishes at authoritative coordinates and becomes idle"):
        return

    motion.observe(START + Vector2i.RIGHT)
    if not check(motion.direction == Vector2i.UP, "the model turns north"):
        return
    motion.observe(Vector2i(10, 8))
    if not check(not motion.is_walking() and motion.position == Vector2(10, 8),
            "nonneighbor correction snaps without animating missed tiles"):
        return
    motion.observe(Vector2i(9, 8))
    if not check(motion.direction == Vector2i.LEFT, "the model turns west"):
        return

    var preview := Walk.new(START)
    preview.observe(START + Vector2i.RIGHT)
    preview.advance(Walk.STEP_SECONDS * 0.4)
    preview.correct(START)
    preview.advance(Walk.CORRECTION_SECONDS * 0.5)
    if not check(is_equal_approx(preview.position.x, START.x + 0.2) and not preview.wants_walk(),
            "a rejected prediction eases back without taking a backwards stride"):
        return
    preview.advance(Walk.CORRECTION_SECONDS * 0.5)
    preview.observe(START + Vector2i.DOWN)
    preview.advance(Walk.STEP_SECONDS + 0.015)
    if not check(not preview.is_walking() and preview.wants_walk(), "short gaps do not restart the gait"):
        return
    preview.advance(Walk.WALK_RELEASE_SECONDS)
    if not check(not preview.wants_walk(), "a real stop returns to standing"):
        return

    print("Four model facings, queued movement and idle reset passed")
    quit()

func check(condition: bool, message: String) -> bool:
    if not condition:
        printerr(message)
        quit(1)
    return condition
