extends Control

signal tile_pressed(tile: Vector2i)

const Grid = preload("res://grid_projection.gd")
const Walk = preload("res://walk_motion.gd")
const MODEL_ROOT := "res://assets/models/"
const FIGURE_MODELS := {"apothecary": "rabbit", "boatman": "ox", "reed_snake": "snake"}
const FACING_VECTORS := {
    "up": Vector2i.UP,
    "down": Vector2i.DOWN,
    "left": Vector2i.LEFT,
    "right": Vector2i.RIGHT,
}
const ATTACK_LUNGE_SECONDS := 0.22
const SNAKE_HIT_SECONDS := 0.24

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
var _attack_pulses: Dictionary = {}
var _snake_hit_pulse := 0.0
var _lantern_lights: Array[OmniLight3D] = []
var _motes: Array[Dictionary] = []
var _clock := 0.0
var _pill_style: StyleBoxFlat
var _render_scale := 1.0
var _framed_size := Vector2.ZERO
var _framed_dimensions := Vector2i.ZERO

func _ready() -> void:
    texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    mouse_filter = Control.MOUSE_FILTER_STOP
    mouse_exited.connect(_clear_hover)
    resized.connect(_fit_camera)
    _backdrop = load("res://assets/ferry-basin.png")
    _pill_style = StyleBoxFlat.new()
    _pill_style.bg_color = Color(0.08, 0.13, 0.10, 0.84)
    _pill_style.border_color = Color(0.66, 0.54, 0.36, 0.72)
    _pill_style.set_border_width_all(1)
    _pill_style.set_corner_radius_all(8)
    _init_motes()
    _build_scene()
    _fit_camera()

func _init_motes() -> void:
    _motes.clear()
    var rng := RandomNumberGenerator.new()
    rng.seed = 20261121
    for i in range(24):
        _motes.append({
            "x": rng.randf(),
            "y": rng.randf(),
            "vx": rng.randf_range(0.008, 0.022),
            "vy": rng.randf_range(0.004, 0.014),
            "phase": rng.randf_range(0.0, TAU),
            "size": rng.randf_range(1.6, 3.2),
            "warm": rng.randf() > 0.35,
        })

func _build_scene() -> void:
    _scene_window = SubViewport.new()
    _scene_window.name = "ModeledFerry"
    _scene_window.transparent_bg = true
    _scene_window.own_world_3d = true
    var adapter := RenderingServer.get_video_adapter_name().to_lower()
    var software := adapter.contains("llvmpipe") or adapter.contains("swiftshader")
    _render_scale = 0.76 if software else 1.25
    _scene_window.msaa_3d = Viewport.MSAA_DISABLED if software else Viewport.MSAA_4X
    _scene_window.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED if software else Viewport.SCREEN_SPACE_AA_FXAA
    _scene_window.anisotropic_filtering_level = Viewport.ANISOTROPY_DISABLED if software else Viewport.ANISOTROPY_8X
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
    var adapter := RenderingServer.get_video_adapter_name()
    var software := adapter.to_lower().contains("llvmpipe") or adapter.to_lower().contains("swiftshader")
    var atmosphere := WorldEnvironment.new()
    var world_light := Environment.new()
    # Physical-feeling Jiangnan sky for IBL specular reflections on brass, eyes, and jade scales
    var sky := Sky.new()
    var sky_mat := ProceduralSkyMaterial.new()
    sky_mat.sky_top_color = Color("#7da0a6")
    sky_mat.sky_horizon_color = Color("#e8d9be")
    sky_mat.ground_bottom_color = Color("#3a4d3f")
    sky_mat.ground_horizon_color = Color("#9aa98d")
    sky_mat.sun_angle_max = 35.0
    sky.sky_material = sky_mat
    world_light.sky = sky
    world_light.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
    world_light.ambient_light_sky_contribution = 0.65
    world_light.ambient_light_color = Color("#cadad4")
    world_light.ambient_light_energy = 0.42
    world_light.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
    world_light.tonemap_mode = Environment.TONE_MAPPER_ACES
    world_light.tonemap_exposure = 1.02
    world_light.tonemap_white = 4.2
    world_light.ssao_enabled = not software
    world_light.ssao_radius = 0.72
    world_light.ssao_intensity = 1.55
    world_light.ssao_power = 1.35
    world_light.ssao_detail = 0.45
    world_light.ssil_enabled = not software
    world_light.ssil_radius = 2.4
    world_light.ssil_intensity = 0.55
    world_light.glow_enabled = true
    world_light.glow_intensity = 0.36
    world_light.glow_bloom = 0.09
    world_light.glow_hdr_threshold = 0.90
    world_light.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
    world_light.adjustment_enabled = true
    world_light.adjustment_brightness = 1.01
    world_light.adjustment_contrast = 1.08
    world_light.adjustment_saturation = 1.13
    atmosphere.environment = world_light
    stage.add_child(atmosphere)

    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-49, -38, 0)
    sun.light_color = Color("#ffe7c4")
    sun.light_energy = 0.96
    sun.shadow_enabled = true
    sun.shadow_bias = 0.025
    sun.shadow_normal_bias = 1.15
    sun.shadow_blur = 2.2
    sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
    sun.directional_shadow_max_distance = 22.0
    stage.add_child(sun)

    var fill := DirectionalLight3D.new()
    fill.rotation_degrees = Vector3(-20, 136, 0)
    fill.light_color = Color("#a6d4de")
    fill.light_energy = 0.22
    stage.add_child(fill)

    var rim := DirectionalLight3D.new()
    rim.rotation_degrees = Vector3(-24, -148, 0)
    rim.light_color = Color("#ffd699")
    rim.light_energy = 0.28
    stage.add_child(rim)

    _lantern_lights.clear()
    for lantern_pos in [Vector3(2.05, 1.45, 1.85), Vector3(7.45, 1.15, 2.35)]:
        var lamp := OmniLight3D.new()
        lamp.position = lantern_pos
        lamp.light_color = Color("#ffb35c")
        lamp.light_energy = 1.35
        lamp.omni_range = 4.4
        lamp.omni_attenuation = 1.35
        lamp.shadow_enabled = not software
        stage.add_child(lamp)
        _lantern_lights.append(lamp)

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
    players = snapshot.get("players", {}).duplicate(true)
    monster = snapshot.get("monster", {}).duplicate(true)
    _fit_camera()
    _sync_fixed_actors()
    for id in _walks.keys():
        if not players.has(id):
            _remove_hero(id)
    for id in players:
        var info: Dictionary = players[id]
        var cell := predicted if id == my_id and predicted != Grid.OUTSIDE else _coords(info)
        _upsert_hero(id, cell, String(info.get("facing", "")))
    _update_markers()
    queue_redraw()

func apply_event(message: Dictionary, predicted: Vector2i = Grid.OUTSIDE) -> void:
    var kind := String(message.get("event", ""))
    match kind:
        "player_joined":
            var id := String(message.get("id", ""))
            if id.is_empty():
                return
            var info := {"x": int(message["x"]), "y": int(message["y"]), "facing": String(message.get("facing", "down"))}
            players[id] = info
            _upsert_hero(id, _coords(info), info["facing"])
            _update_markers()
            queue_redraw()
        "player_left":
            var id := String(message.get("id", ""))
            players.erase(id)
            _remove_hero(id)
            _update_markers()
            queue_redraw()
        "player_moved":
            var id := String(message.get("id", ""))
            if id.is_empty():
                return
            var info := {"x": int(message["x"]), "y": int(message["y"]), "facing": String(message.get("facing", "down"))}
            players[id] = info
            var cell := predicted if id == my_id and predicted != Grid.OUTSIDE else _coords(info)
            _upsert_hero(id, cell, info["facing"])
            _update_markers()
            queue_redraw()
        "player_faced":
            var id := String(message.get("id", ""))
            var facing := String(message.get("facing", ""))
            if players.has(id):
                players[id]["facing"] = facing
            set_player_facing(id, facing)
        "player_attacked":
            var id := String(message.get("id", ""))
            var facing := String(message.get("facing", ""))
            if players.has(id) and not facing.is_empty():
                players[id]["facing"] = facing
            set_player_facing(id, facing)
            if _heroes.has(id):
                _attack_pulses[id] = ATTACK_LUNGE_SECONDS
                var animation := _animation_player(_heroes[id])
                if animation and animation.has_animation("attack"):
                    var clip := animation.get_animation("attack")
                    clip.loop_mode = Animation.LOOP_NONE
                    animation.speed_scale = 1.8
                    animation.play("attack", 0.03)
            monster = {"hp": int(message.get("hp", 0)), "alive": bool(message.get("alive", false))}
            _snake_hit_pulse = SNAKE_HIT_SECONDS if monster["alive"] else 0.0
            _sync_fixed_actors()
            queue_redraw()
        "monster_respawned":
            monster = {"hp": int(message.get("hp", 3)), "alive": bool(message.get("alive", true))}
            _snake_hit_pulse = 0.0
            _sync_fixed_actors()
            queue_redraw()

func set_player_facing(id: String, facing: String) -> void:
    if FACING_VECTORS.has(facing) and _walks.has(id):
        var walk: Walk = _walks[id]
        if not walk.is_walking():
            walk.direction = FACING_VECTORS[facing]

func _upsert_hero(id: String, cell: Vector2i, facing: String) -> void:
    if _walks.has(id):
        _walks[id].observe(cell)
        if FACING_VECTORS.has(facing) and not _walks[id].is_walking():
            _walks[id].direction = FACING_VECTORS[facing]
    else:
        var walk := Walk.new(cell)
        if FACING_VECTORS.has(facing):
            walk.direction = FACING_VECTORS[facing]
        _walks[id] = walk
        var model := _model("tiger")
        if model:
            _actor_root.add_child(model)
            _heroes[id] = model
            model.position = _ground(Vector2(cell))
            model.rotation.y = atan2(float(walk.direction.x), float(walk.direction.y))
            _animate_hero(model, false)

func _remove_hero(id: String) -> void:
    _walks.erase(id)
    _attack_pulses.erase(id)
    if _heroes.has(id):
        _heroes[id].queue_free()
        _heroes.erase(id)

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
    if not animation:
        return
    if animation.current_animation == "attack" and animation.is_playing():
        return
    var clip := "walk" if walking else "idle"
    if not animation.has_animation(clip) or animation.current_animation == clip:
        return
    var animation_clip := animation.get_animation(clip)
    animation_clip.loop_mode = Animation.LOOP_LINEAR
    animation.speed_scale = minf(2.4, animation_clip.length / (Walk.STEP_SECONDS * 2.0)) if walking else 1.0
    animation.play(clip, 0.045 if walking else 0.07)

func _process(delta: float) -> void:
    _clock += delta
    for i in range(_lantern_lights.size()):
        _lantern_lights[i].light_energy = 1.15 + 0.18 * sin(_clock * (3.1 + i * 0.9) + i * 1.7)
    for mote in _motes:
        mote["x"] = fposmod(float(mote["x"]) + float(mote["vx"]) * delta, 1.0)
        mote["y"] = fposmod(float(mote["y"]) + float(mote["vy"]) * delta, 1.0)
    var moved := not _motes.is_empty()
    for id in _walks:
        var walk: Walk = _walks[id]
        if walk.advance(delta):
            moved = true
        if _heroes.has(id):
            var model: Node3D = _heroes[id]
            var base_pos := _ground(walk.position)
            if _attack_pulses.has(id):
                var remaining: float = maxf(0.0, float(_attack_pulses[id]) - delta)
                var progress := 1.0 - remaining / ATTACK_LUNGE_SECONDS
                var lunge := sin(progress * PI) * 0.28
                base_pos += Vector3(float(walk.direction.x), 0.0, float(walk.direction.y)) * lunge
                if remaining <= 0.0:
                    _attack_pulses.erase(id)
                else:
                    _attack_pulses[id] = remaining
                moved = true
            model.position = base_pos
            var yaw := atan2(float(walk.direction.x), float(walk.direction.y))
            model.rotation.y = lerp_angle(model.rotation.y, yaw, 1.0 - exp(-28.0 * delta))
            _animate_hero(model, walk.wants_walk())
    if _figures.has("reed_snake") and features.has("reed_snake"):
        var snake: Node3D = _figures["reed_snake"]
        var snake_base := _ground(Vector2(_coords(features["reed_snake"])))
        if _snake_hit_pulse > 0.0 and snake.visible:
            _snake_hit_pulse = maxf(0.0, _snake_hit_pulse - delta)
            var t := 1.0 - _snake_hit_pulse / SNAKE_HIT_SECONDS
            var shake := sin(t * PI * 3.0) * 0.10 * (1.0 - t)
            snake.position = snake_base + Vector3(shake, sin(t * PI) * 0.08, 0.0)
            moved = true
        else:
            snake.position = snake_base
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
        if walkable:
            for id in features:
                if _coords(features[id]) == _hover:
                    walkable = false
                    break
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
    _draw_atmosphere()
    _draw_labels()

func _draw_atmosphere() -> void:
    for mote in _motes:
        var sway := sin(_clock * 1.8 + float(mote["phase"])) * 8.0
        var pos := Vector2(float(mote["x"]) * size.x + sway, float(mote["y"]) * size.y)
        var alpha := 0.22 + 0.14 * sin(_clock * 2.1 + float(mote["phase"]))
        var color := Color(0.98, 0.88, 0.62, alpha) if bool(mote["warm"]) else Color(0.84, 0.93, 0.80, alpha * 0.85)
        draw_circle(pos, float(mote["size"]), color)
    var edge := 44.0
    var shade := Color(0.05, 0.08, 0.06, 0.24)
    draw_rect(Rect2(0.0, 0.0, size.x, edge * 0.55), shade)
    draw_rect(Rect2(0.0, size.y - edge * 0.65, size.x, edge * 0.65), shade)

func _screen(world: Vector3) -> Vector2:
    return _camera.unproject_position(world) * (size / Vector2(_scene_window.size))

func _draw_labels() -> void:
    for id in features:
        if id == "reed_snake" and not monster.get("alive", false):
            continue
        var point := _ground(Vector2(_coords(features[id])))
        _draw_name(features[id]["label"], _screen(point))
        if id == "reed_snake":
            var bar := Rect2(_screen(point + Vector3.UP * 0.78) - Vector2(20, 7), Vector2(40, 6))
            draw_rect(bar.grow(1.5), Color(0.14, 0.11, 0.09, 0.90))
            draw_rect(bar, Color("#33261f"))
            var fraction := clampf(float(monster.get("hp", 0)) / 3.0, 0.0, 1.0)
            draw_rect(Rect2(bar.position, Vector2(bar.size.x * fraction, bar.size.y)), Color("#d96b43"))
    for id in players:
        if _walks.has(id):
            _draw_name("你" if id == my_id else id, _screen(_ground(_walks[id].position)))

func _draw_name(title: String, ground: Vector2) -> void:
    if not ink_font:
        return
    var font_size := clampi(int(size.y * 0.018), 12, 16)
    var text_width := ink_font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
    var baseline := ground + Vector2(-text_width * 0.5, font_size + 6)
    var pill := Rect2(baseline - Vector2(8, font_size + 1), Vector2(text_width + 16, font_size + 7))
    if _pill_style:
        draw_style_box(_pill_style, pill)
    else:
        draw_rect(pill, Color(0.08, 0.13, 0.10, 0.84))
    draw_string(ink_font, baseline + Vector2(1, 1), title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.55))
    draw_string(ink_font, baseline, title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("#f5e6ba"))
