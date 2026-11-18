extends Control

signal tile_pressed(tile: Vector2i)

var tiles: Array = []
var features: Dictionary = {}
var players: Dictionary = {}
var monster: Dictionary = {}
var my_id := ""
var ink_font: Font
var sprites: Array[Texture2D] = []
var hover := Vector2i(-1, -1)
var positions: Dictionary = {}

const PATH := [Color("#b2a183"), Color("#bbad91"), Color("#a99a7e"), Color("#afa286")]
const MOSS := [Color("#56664e"), Color("#617156"), Color("#51614b"), Color("#65745a")]

func _ready() -> void:
    custom_minimum_size = Vector2(660, 470)
    mouse_filter = Control.MOUSE_FILTER_STOP
    mouse_exited.connect(_clear_hover)
    resized.connect(queue_redraw)
    var atlas: Texture2D = load("res://assets/animal-atlas.png")
    if atlas:
        var image := atlas.get_image()
        var crops := [
            Rect2i(22, 72, 510, 598), Rect2i(643, 35, 345, 636),
            Rect2i(1073, 57, 554, 615), Rect2i(1690, 156, 421, 505)
        ]
        for rectangle in crops:
            sprites.append(ImageTexture.create_from_image(image.get_region(rectangle)))

func set_world(snapshot: Dictionary) -> void:
    players = snapshot.get("players", {})
    monster = snapshot.get("monster", {})
    for id in positions.keys():
        if not players.has(id):
            positions.erase(id)
    for id in players:
        if not positions.has(id):
            positions[id] = Vector2(_coords(players[id]))
    queue_redraw()

func _process(delta: float) -> void:
    for id in players:
        var destination := Vector2(_coords(players[id]))
        if positions[id].distance_to(destination) > 0.005:
            positions[id] = positions[id].lerp(destination, minf(1.0, delta * 18.0))
            queue_redraw()

func _coords(data: Dictionary) -> Vector2i:
    return Vector2i(int(data["x"]), int(data["y"]))

func _board() -> Rect2:
    if tiles.is_empty():
        return Rect2()
    var dimensions := Vector2(String(tiles[0]).length(), tiles.size())
    var scale_factor := floorf(minf((size.x - 18) / dimensions.x, (size.y - 18) / dimensions.y))
    return Rect2((size - dimensions * scale_factor) * 0.5, dimensions * scale_factor)

func _gui_input(event: InputEvent) -> void:
    var board := _board()
    if board.size.x <= 0:
        return
    var local_mouse := get_local_mouse_position()
    var cell := board.size.y / tiles.size()
    if event is InputEventMouseMotion:
        hover = Vector2i(((local_mouse - board.position) / cell).floor()) + Vector2i.ONE if board.has_point(local_mouse) else Vector2i(-1, -1)
        queue_redraw()
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and board.has_point(local_mouse):
        tile_pressed.emit(Vector2i(((local_mouse - board.position) / cell).floor()) + Vector2i.ONE)
        accept_event()

func _clear_hover() -> void:
    hover = Vector2i(-1, -1)
    queue_redraw()

func _draw() -> void:
    var board := _board()
    if board.size.x <= 0:
        return
    var cell := board.size.y / tiles.size()
    draw_rect(board.grow(4), Color("#101b16"))
    for y in range(tiles.size()):
        var row := String(tiles[y])
        for x in range(row.length()):
            var position := board.position + Vector2(x, y) * cell
            var rectangle := Rect2(position, Vector2.ONE * cell)
            _paint_tile(row.substr(x, 1), rectangle, x, y)
    var tower := board.position + Vector2(1.0, 0.34) * cell
    _roof(tower, cell * 4.85, cell * 0.7)
    _roof(board.position + Vector2(0.07, 7.66) * cell, cell * 4.5, cell * 0.51)

    if hover.x >= 1:
        var highlight := board.position + Vector2(hover - Vector2i.ONE) * cell
        draw_rect(Rect2(highlight + Vector2(2, 2), Vector2.ONE * (cell - 4)), Color(0.96, 0.79, 0.44, 0.57), false, 2)
    if players.has(my_id):
        var own := board.position + (Vector2(_coords(players[my_id])) - Vector2.ONE) * cell
        draw_rect(Rect2(own + Vector2.ONE * 3, Vector2.ONE * (cell - 6)), Color("#e8bf73"), false, 2)

    var actors: Array = []
    for id in features:
        var info: Dictionary = features[id]
        if id == "reed_snake" and not monster.get("alive", false):
            continue
        actors.append({"id": id, "position": Vector2(_coords(info)), "label": info["label"], "is_player": false})
    for id in players:
        actors.append({"id": id, "position": positions[id], "label": "你" if id == my_id else id, "is_player": true})
    actors.sort_custom(func(a, b): return a["position"].y < b["position"].y)
    for actor in actors:
        _paint_actor(actor, board.position, cell)
    draw_rect(board.grow(3), Color("#766449"), false, 2)

func _paint_tile(tile: String, rect: Rect2, x: int, y: int) -> void:
    var p := rect.position
    var c := rect.size.x
    var shade_index := posmod(x * 7 + y * 11 + x * y, 4)
    if tile == ".":
        draw_rect(rect, PATH[shade_index])
        draw_rect(rect.grow(-1), Color(0.92, 0.87, 0.69, 0.26), false, 1)
        for detail in range(5):
            var offset := Vector2(posmod(x * 29 + y * 3 + detail * 137, 89), posmod(y * 11 + x * 13 + detail * 31, 79)) / 100.0
            draw_line(p + (offset + Vector2(0.05, 0.12)) * c, p + (offset + Vector2(0.11, 0.12)) * c, Color(0.34, 0.35, 0.27, 0.18), 1)
    elif tile == "~":
        var greens := [Color("#31605c"), Color("#386761"), Color("#3b6d64"), Color("#315d58")]
        draw_rect(rect, greens[shade_index])
        for n in range(4):
            var start := p + Vector2(0.11 + 0.07 * posmod(x + n, 4), 0.15 + n * 0.20) * c
            draw_line(start, start + Vector2((0.36 + 0.09 * n) * c, 0), Color(0.66, 0.82, 0.70, 0.16), 1.3, true)
    elif tile == "D":
        draw_rect(rect, Color("#71543b"))
        for n in range(7):
            var board := Rect2(p + Vector2(c * 0.08, n * c / 7.0), Vector2(c * 0.84, c / 7.0 - 1))
            draw_rect(board, Color("#a78357"))
            draw_line(board.position, board.position + Vector2(board.size.x, 0), Color("#c39d69"), 1, true)
    else:
        draw_rect(rect, MOSS[shade_index].darkened(0.28 if tile == "#" else 0.0))
        for n in range(5):
            var point := p + Vector2(posmod((n + 2) * 41 + x * 13, 92), posmod(n * 23 + y * 9, 91)) * c / 100.0
            draw_line(point, point + Vector2(0.05, -0.13) * c, Color("#879469"), 1.25, true)
            draw_line(point, point + Vector2(-0.035, -0.09) * c, Color("#4b5e41"), 1.25, true)
        if tile == "#":
            var shade := Color("#293e32")
            draw_circle(p + Vector2(c * 0.28, c * 0.58), c * 0.15, shade)
            draw_circle(p + Vector2(c * 0.47, c * 0.48), c * 0.17, shade.lightened(0.1))
            draw_circle(p + Vector2(c * 0.66, c * 0.65), c * 0.15, shade)

func _roof(p: Vector2, width: float, height: float) -> void:
    draw_rect(Rect2(p + Vector2(3, 5), Vector2(width, height + 6)), Color("#293329"))
    draw_rect(Rect2(p, Vector2(width, height)), Color("#55594f"))
    for n in range(int(width / 10)):
        var rib := p + Vector2(8 + n * 10, 0)
        draw_line(rib, rib + Vector2(-3, height), Color("#797b6e"), 1.1, true)
    draw_line(p, p + Vector2(width, 0), Color("#a19d85"), 2)
    draw_line(p + Vector2(0, height), p + Vector2(width, height), Color("#a88c5d"), 2)
    for offset in [0.24, 0.77]:
        var lantern := p + Vector2(width * offset, height * 1.08)
        draw_circle(lantern, 9, Color(0.92, 0.59, 0.29, 0.19))
        draw_circle(lantern, 4.3, Color("#f0be6e"))

func _paint_actor(actor: Dictionary, origin: Vector2, cell: float) -> void:
    var position: Vector2 = actor["position"]
    var center := origin + (position - Vector2(0.5, 0.5)) * cell
    var id: String = actor["id"]
    var sprite_index := -1
    if actor["is_player"]:
        sprite_index = 0
    else:
        sprite_index = {"apothecary": 1, "boatman": 2, "reed_snake": 3}.get(id, -1)
    var feet := center + Vector2(0, cell * 0.31)
    var shadow := PackedVector2Array()
    for n in range(20):
        var angle := TAU * n / 20
        shadow.append(feet + Vector2(cos(angle) * cell * 0.27, sin(angle) * cell * 0.08))
    draw_colored_polygon(shadow, Color(0.08, 0.10, 0.07, 0.43))
    if sprite_index >= 0 and sprite_index < sprites.size():
        var texture := sprites[sprite_index]
        var height := cell * (0.71 if id == "reed_snake" else 0.99)
        var width := height * texture.get_size().aspect()
        var tint := Color.WHITE if id == my_id or not actor["is_player"] else Color("#d4d9ff")
        draw_texture_rect(texture, Rect2(feet - Vector2(width * 0.5, height), Vector2(width, height)), false, tint)
    else:
        draw_rect(Rect2(feet - Vector2(cell * 0.24, cell * 0.35), Vector2(cell * 0.48, cell * 0.30)), Color("#947048"))
        draw_rect(Rect2(feet - Vector2(cell * 0.24, cell * 0.35), Vector2(cell * 0.48, cell * 0.30)), Color("#e1b77c"), false, 2)
    if ink_font:
        var title: String = actor["label"]
        var name_size := ink_font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
        var label_at := Vector2(feet.x - name_size.x * 0.5, feet.y + 14)
        draw_rect(Rect2(label_at - Vector2(4, 11), Vector2(name_size.x + 8, 15)), Color(0.08, 0.12, 0.09, 0.85))
        draw_string(ink_font, label_at, title, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#f4e4c1"))
    if id == "reed_snake":
        var bar := Rect2(center - Vector2(cell * 0.28, cell * 0.49), Vector2(cell * 0.56, 4))
        draw_rect(bar, Color("#302725"))
        draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(monster.get("hp", 0)) / 3.0, 4)), Color("#c87959"))
