extends SceneTree

const InputBuffer = preload("res://grid_input.gd")
const MAP := ["#######", "#.....#", "#.##..#", "#.....#", "#######"]
const ORIGIN := Vector2i(2, 2)

func _initialize() -> void:
    var drive := InputBuffer.new()
    drive.observe(ORIGIN)
    drive.press(KEY_D, Vector2i.RIGHT)
    if not check(drive.next_step(MAP, 1000) == Vector2i.RIGHT, "a fresh tap can leave in the same input event"):
        return
    drive.begin_step(Vector2i.RIGHT, 1000)
    drive.press(KEY_S, Vector2i.DOWN)
    drive.release(KEY_S)
    if not check(drive.next_step(MAP, 1100) == Vector2i.ZERO and drive.pending == Vector2i(3, 2),
            "short turns wait without interrupting the prediction"):
        return
    drive.observe(ORIGIN)
    if not check(drive.pending == Vector2i(3, 2), "unrelated snapshots preserve the local prediction"):
        return
    drive.observe(Vector2i(3, 2))
    if not check(drive.pending == InputBuffer.OUTSIDE and drive.next_step(MAP, 1179) == Vector2i.ZERO,
            "the buffered turn may not walk into a blocked tile"):
        return
    if not check(drive.next_step(MAP, 1180) == Vector2i.RIGHT, "the remaining held key repeats"):
        return

    drive.observe(ORIGIN)
    drive.press(KEY_S, Vector2i.DOWN)
    drive.release(KEY_S)
    if not check(drive.next_step(MAP, 1300) == Vector2i.DOWN, "the released tap wins over an earlier held key once"):
        return
    drive.begin_step(Vector2i.DOWN, 1300)
    drive.reject()
    if not check(drive.cell == ORIGIN and drive.pending == InputBuffer.OUTSIDE, "a rejected turn keeps server authority"):
        return

    if not check(drive.seek(MAP, Vector2i(4, 4), 1)
            and drive.next_step(MAP, 1600) == Vector2i.DOWN, "mouse walking can route around a blocked corner"):
        return
    if not check(not drive.seek(MAP, Vector2i(1, 1), 0), "unreachable wall clicks are not sent"):
        return
    drive.observe(Vector2i(5, 3))
    if not check(drive.seek(MAP, Vector2i(5, 4), 1) and drive.at_goal()
            and drive.next_step(MAP, 1700) == Vector2i.ZERO, "approaching an NPC stops in interaction range"):
        return
    drive.press(KEY_W, Vector2i.UP)
    if not check(drive.goal == InputBuffer.OUTSIDE, "fresh keyboard input cancels a click route"):
        return

    print("Buffered taps, held-key order, predictive confirmations and click routes passed")
    quit(0)

func check(value: bool, message: String) -> bool:
    if not value:
        printerr(message)
        quit(1)
    return value
