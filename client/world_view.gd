extends Control

signal tile_pressed(tile: Vector2i)

const Grid = preload("res://grid_projection.gd")
const Walk = preload("res://walk_motion.gd")
const MODEL_ROOT := "res://assets/models/"
const FIGURE_MODELS := {"apothecary": "rabbit", "boatman": "ox", "reed_snake": "snake"}

var tiles: Array = []
var features: Dictionary = {}
var players: Dictionary = {}
var monster: Dictionary = {}
var my_id := ""
var ink_font: Font

var _backdrop: Texture2D
var _scene_window: SubViewport
var _actor_root: Node3D
var _camera: Camera3D
var _ferry: Node3D
var _hover_marker: Node3D
var _player_marker: Node3D
var _hover: Vector2i = Grid.OUTSIDE
var _walks: Dictionary = {}
var _heroes: Dictionary = {}
var _figures: Dictionary = {}
var _render_scale := 1.0
var _framed_size := Vector2.ZERO
var _framed_dimensions := Vector2i.ZERO

func _ready() -> void:
    texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    mouse_filter = Control.MOUSE_FILTER_STOP
    mouse_exited.connect(_clear_hover)
    resized.connect(_fit_camera)
    _backdrop = load("res://assets/ferry-basin.png")
    _build_scene()
    _fit_camera()

func _build_scene() -> void:
    _scene_window = SubViewport.new()
    _scene_window.name = "ModeledFerry"
    _scene_window.transparent_bg = true
    _scene_window.own_world_3d = true
    var adapter := RenderingServer.get_video_adapter_name().to_lower()
    if adapter.contains("llvmpipe") or adapter.contains("swiftshader"):
        _render_scale = 0.76
    _scene_window.msaa_3d = Viewport.MSAA_4X if _render_scale == 1.0 else Viewport.MSAA_DISABLED
    _scene_window.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    add_child(_scene_window)

    var stage := Node3D.new()
    _scene_window.add_child(stage)
    _camera = Camera3D.new()
    _camera.projection = Camera3D.PROJECTION_ORTHOGONAL
    _camera.keep_aspect = Camera3D.KEEP_HEIGHT
    _camera.near = 0.1
    _camera.far = 70.0
    stage.add_child(_camera)
    _camera.make_current()
    _light_scene(stage)

    _ferry = _model("ferry")
    if _ferry:
        stage.add_child(_ferry)
    _actor_root = Node3D.new()
    _actor_root.name = "Actors"
    stage.add_child(_actor_root)

    _hover_marker = _tile_marker(Color(0.97, 0.88, 0.62, 0.64))
    _player_marker = _tile_marker(Color(1.0, 0.78, 0.40, 0.94))
    stage.add_child(_hover_marker)
    stage.add_child(_player_marker)

func _light_scene(stage: Node3D) -> void:
    var atmosphere := WorldEnvironment.new()
    var world_light := Environment.new()
    world_light.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    world_light.ambient_light_color = Color("#d7e2dc")
    world_light.ambient_light_energy = 0.40
    atmosphere.environment = world_light
    stage.add_child(atmosphere)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-53, -36, 0)
    sun.light_color = Color("#fff5e5")
    sun.light_energy = 0.54
    sun.shadow_enabled = true
    sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
    sun.directional_shadow_max_distance = 29.0
    stage.add_child(sun)
    var fill := DirectionalLight3D.new()
    fill.rotation_degrees = Vector3(-18, 138, 0)
    fill.light_color = Color("#c4e1e2")
    fill.light_energy = 0.16
    stage.add_child(fill)

func _model(model_name: String) -> Node3D:
    var path := MODEL_ROOT + model_name + ".glb"
    if not ResourceLoader.exists(path, "PackedScene"):
        return null
    var scene: PackedScene = load(path)
    return scene.instantiate() as Node3D

func _fit_camera() -> void:
    if not _camera or size.x < 2.0 or size.y < 2.0:
        return
    var dimensions := _dimensions()
    if dimensions == Vector2i.ZERO:
        dimensions = Vector2i(12, 8)
    if size == _framed_size and dimensions == _framed_dimensions:
        return
    _framed_size = size
    _framed_dimensions = dimensions
    var backing_size := size * _render_scale
    _scene_window.size = Vector2i(maxi(2, roundi(backing_size.x)), maxi(2, roundi(backing_size.y)))
    var pixel_size := size
    var fit := Grid.fit(pixel_size, dimensions)
    var yaw := atan(-Grid.ROW.x)
    var pitch := asin(Grid.ROW.y)
    var meters_to_pixels := fit.x.x / cos(yaw)
    _camera.size = pixel_size.y / meters_to_pixels
    var center := Vector3(dimensions.x * 0.5, 0.0, dimensions.y * 0.5)
    var direction := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
    _camera.position = center + direction * 21.0
    _camera.look_at(center, Vector3.UP)
    var target_screen := fit * (Vector2(dimensions) * 0.5)
    var shift := target_screen - pixel_size * 0.5
    _camera.position += _camera.transform.basis.y * (shift.y / meters_to_pixels)
    queue_redraw()

func set_world(snapshot: Dictionary, predicted: Vector2i = Grid.OUTSIDE) -> void:
    players = snapshot.get("players", {})
    monster = snapshot.get("monster", {})
    _fit_camera()
    _sync_fixed_actors()
    for id in _walks.keys():
        if not players.has(id):
            _walks.erase(id)
            if _heroes.has(id):
                _heroes[id].queue_free()
                _heroes.erase(id)
    for id in players:
        var cell := predicted if id == my_id and predicted != Grid.OUTSIDE else _coords(players[id])
        if _walks.has(id):
            _walks[id].observe(cell)
        else:
            _walks[id] = Walk.new(cell)
            var model := _model("tiger")
            if model:
                _actor_root.add_child(model)
                _heroes[id] = model
                model.position = _ground(Vector2(cell))
                _animate_hero(model, false)
    _update_markers()
    queue_redraw()

func preview_step(cell: Vector2i) -> void:
    if _walks.has(my_id):
        _walks[my_id].observe(cell)

func correct_step(cell: Vector2i) -> void:
    if _walks.has(my_id):
        _walks[my_id].correct(cell)

func face_local(direction: Vector2i) -> void:
    if _walks.has(my_id) and not _walks[my_id].is_walking():
        _walks[my_id].direction = direction

func _sync_fixed_actors() -> void:
    for id in _figures.keys():
        if not features.has(id):
            _figures[id].queue_free()
            _figures.erase(id)
    for id in FIGURE_MODELS:
        if not features.has(id):
            continue
        if not _figures.has(id):
            var figure := _model(FIGURE_MODELS[id])
            if not figure:
                continue
            _actor_root.add_child(figure)
            figure.rotation.y = 0.30
            _figures[id] = figure
        _figures[id].position = _ground(Vector2(_coords(features[id])))
    if _figures.has("reed_snake"):
        _figures["reed_snake"].visible = monster.get("alive", false)

func _animation_player(model: Node3D) -> AnimationPlayer:
    return model.find_child("AnimationPlayer", true, false) as AnimationPlayer

func _animate_hero(model: Node3D, walking: bool) -> void:
    var animation := _animation_player(model)
    var clip := "walk" if walking else "idle"
    if not animation or not animation.has_animation(clip) or animation.current_animation == clip:
        return
    var animation_clip := animation.get_animation(clip)
    animation_clip.loop_mode = Animation.LOOP_LINEAR
    animation.speed_scale = minf(2.4, animation_clip.length / (Walk.STEP_SECONDS * 2.0)) if walking else 1.0
    animation.play(clip, 0.045 if walking else 0.07)

func _process(delta: float) -> void:
    var moved := false
    for id in _walks:
        var walk: Walk = _walks[id]
        if walk.advance(delta):
            moved = true
        if _heroes.has(id):
            var model: Node3D = _heroes[id]
            model.position = _ground(walk.position)
            var yaw := atan2(float(walk.direction.x), float(walk.direction.y))
            model.rotation.y = lerp_angle(model.rotation.y, yaw, 1.0 - exp(-28.0 * delta))
            _animate_hero(model, walk.wants_walk())
    if moved:
        queue_redraw()

func _coords(data: Dictionary) -> Vector2i:
    return Vector2i(int(data["x"]), int(data["y"]))

func _ground(cell: Vector2) -> Vector3:
    return Vector3(cell.x - 0.5, 0.0, cell.y - 0.5)

func _dimensions() -> Vector2i:
    if tiles.is_empty():
        return Vector2i.ZERO
    return Vector2i(String(tiles[0]).length(), tiles.size())

func _gui_input(event: InputEvent) -> void:
    var dimensions := _dimensions()
    if dimensions == Vector2i.ZERO or not event is InputEventMouse:
        return
    var picked := Grid.pick(Grid.fit(size, dimensions), dimensions, event.position)
    if event is InputEventMouseMotion and _hover != picked:
        _hover = picked
        _update_markers()
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        var figure_tile := _pick_figure(event.position)
        if figure_tile != Grid.OUTSIDE:
            picked = figure_tile
        if picked != Grid.OUTSIDE:
            tile_pressed.emit(picked)
            accept_event()

func _pick_figure(pointer: Vector2) -> Vector2i:
    var result := Grid.OUTSIDE
    var nearest := -INF
    for id in _figures:
        var model: Node3D = _figures[id]
        if not model.visible:
            continue
        var feet := _screen(model.position)
        var head := _screen(model.position + Vector3.UP * (0.79 if id == "reed_snake" else 1.29))
        var half_width := clampf((feet.y - head.y) * 0.32, 11.0, 38.0)
        var bounds := Rect2(Vector2(feet.x - half_width, head.y), Vector2(half_width * 2.0, feet.y - head.y + 7.0))
        if bounds.has_point(pointer) and feet.y > nearest:
            nearest = feet.y
            result = _coords(features[id])
    return result

func _clear_hover() -> void:
    _hover = Grid.OUTSIDE
    _update_markers()

func _tile_marker(color: Color) -> Node3D:
    var marker := Node3D.new()
    marker.hide()
    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.albedo_color = color
    for side in [Vector2(0.0, -0.43), Vector2(0.43, 0.0), Vector2(0.0, 0.43), Vector2(-0.43, 0.0)]:
        var edge := MeshInstance3D.new()
        var strip := BoxMesh.new()
        strip.size = Vector3(0.88, 0.008, 0.025) if side.x == 0.0 else Vector3(0.025, 0.008, 0.88)
        edge.mesh = strip
        edge.material_override = material
        edge.position = Vector3(side.x, 0.0, side.y)
        edge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        marker.add_child(edge)
    return marker

func _update_markers() -> void:
    if not _hover_marker or not _player_marker:
        return
    var dimensions := _dimensions()
    var walkable := false
    if _hover.x > 0 and _hover.y > 0 and _hover.x <= dimensions.x and _hover.y <= dimensions.y:
        walkable = String(tiles[_hover.y - 1]).substr(_hover.x - 1, 1) in [".", ",", "D"]
    _hover_marker.visible = walkable
    if walkable:
        _hover_marker.position = _ground(Vector2(_hover)) + Vector3.UP * 0.025
    _player_marker.visible = players.has(my_id)
    if _player_marker.visible:
        _player_marker.position = _ground(Vector2(_coords(players[my_id]))) + Vector3.UP * 0.035

func _draw() -> void:
    if _dimensions() == Vector2i.ZERO:
        return
    if _backdrop:
        var image_size := _backdrop.get_size()
        var scale_factor := maxf(size.x / image_size.x, size.y / image_size.y)
        if scale_factor > 0.0:
            var shown := size / scale_factor
            draw_texture_rect_region(_backdrop, Rect2(Vector2.ZERO, size), Rect2((image_size - shown) * 0.5, shown),
                Color("#c2c5a7"))
    else:
        draw_rect(Rect2(Vector2.ZERO, size), Color("#536c5f"))
    if _scene_window:
        draw_texture_rect(_scene_window.get_texture(), Rect2(Vector2.ZERO, size), false)
    _draw_labels()

func _screen(world: Vector3) -> Vector2:
    return _camera.unproject_position(world) * (size / Vector2(_scene_window.size))

func _draw_labels() -> void:
    for id in features:
        if id == "reed_snake" and not monster.get("alive", false):
            continue
        var point := _ground(Vector2(_coords(features[id])))
        _draw_name(features[id]["label"], _screen(point))
        if id == "reed_snake":
            var bar := Rect2(_screen(point + Vector3.UP * 0.69) - Vector2(15, 6), Vector2(30, 4))
            draw_rect(bar, Color("#382c24"))
            var fraction := clampf(float(monster.get("hp", 0)) / 3.0, 0.0, 1.0)
            draw_rect(Rect2(bar.position, Vector2(bar.size.x * fraction, bar.size.y)), Color("#cc7b53"))
    for id in players:
        if _walks.has(id):
            _draw_name("你" if id == my_id else id, _screen(_ground(_walks[id].position)))

func _draw_name(title: String, ground: Vector2) -> void:
    if not ink_font:
        return
    var font_size := clampi(int(size.y * 0.018), 11, 16)
    var text_width := ink_font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
    var baseline := ground + Vector2(-text_width * 0.5, font_size + 4)
    draw_rect(Rect2(baseline - Vector2(5, font_size), Vector2(text_width + 10, font_size + 5)),
        Color(0.10, 0.15, 0.11, 0.86))
    draw_string(ink_font, baseline, title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("#f1e2b4"))
