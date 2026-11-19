extends SceneTree

const Grid = preload("res://grid_projection.gd")
const DIMENSIONS := Vector2i(12, 8)

func _initialize() -> void:
    for viewport in [Vector2(930, 550), Vector2(660, 470), Vector2(1280, 660)]:
        var projection := Grid.fit(viewport, DIMENSIONS)
        var first := Grid.center(projection, Vector2i(1, 1))
        var east := Grid.center(projection, Vector2i(2, 1))
        var south := Grid.center(projection, Vector2i(1, 2))
        if not _check(east.x > first.x and east.y > first.y and south.x < first.x and south.y > first.y,
                "both axes must project diagonally down"):
            return
        for y in range(1, DIMENSIONS.y + 1):
            for x in range(1, DIMENSIONS.x + 1):
                var cell := Vector2i(x, y)
                if not _check(Grid.pick(projection, DIMENSIONS, Grid.center(projection, cell)) == cell,
                        "center must click the exact server cell %s" % cell):
                    return
                var corner := projection * (Vector2(cell) - Vector2(0.91, 0.18))
                if not _check(Grid.pick(projection, DIMENSIONS, corner) == cell,
                        "clicks close to a diamond edge stay in that cell %s" % cell):
                    return
        if not _check(Grid.pick(projection, DIMENSIONS, projection * Vector2(-0.1, 4.0)) == Grid.OUTSIDE,
                "background cannot be selected as a tile"):
            return
        if not _check(Grid.pick(projection, DIMENSIONS, projection * Vector2(11.5, 8.3)) == Grid.OUTSIDE,
                "foreground cannot be selected as a tile"):
            return
    print("Oblique grid projection and tile hit-testing passed")
    quit()

func _check(condition: bool, message: String) -> bool:
    if not condition:
        printerr(message)
        quit(1)
    return condition
