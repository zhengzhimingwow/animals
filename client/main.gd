extends Control

const GridView = preload("res://world_view.gd")
const GridInput = preload("res://grid_input.gd")
const MOVE_KEYS := {
    KEY_A: Vector2i.LEFT, KEY_LEFT: Vector2i.LEFT,
    KEY_D: Vector2i.RIGHT, KEY_RIGHT: Vector2i.RIGHT,
    KEY_W: Vector2i.UP, KEY_UP: Vector2i.UP,
    KEY_S: Vector2i.DOWN, KEY_DOWN: Vector2i.DOWN,
}
const GOLD := Color("#e5bd77")
const PAPER := Color("#e9dec9")
const MUTE := Color("#a6b4a2")
const QUESTS := {
    "new": "去客栈门口，和兔药师说话。",
    "search": "问问牛船工，沿东边河岸寻找药箱。",
    "hunt": "在芦苇滩击败芦滩蛇，带蛇胆回去。",
    "done": "药师已经配好了药。渡口恢复了往日的秩序。",
}
const ERRORS := {
    "bad_token": "通行口令不正确。",
    "already_online": "这个角色已经在线。",
    "save_failed": "存档暂时失败，请再试一次。",
    "store_unavailable": "存档服务暂时不可用。",
    "blocked": "前面走不通。",
    "too_far": "走近一格再互动。",
    "already_defeated": "芦滩蛇已经被击退，稍后会回来。",
}

var view = GridView.new()
var my_id := ""
var socket: WebSocketPeer
var login_sent := false
var pending_token := ""
var login: Control
var url_field: LineEdit
var token_field: LineEdit
var connection_message: Label
var link_button: Button
var location_title: Label
var world_status: Label
var bag_status: Label
var quest_hints: Dictionary = QUESTS.duplicate()
var dialogue_title: Label
var dialogue_body: Label
var _movement := GridInput.new()
var _approach_target := ""
var _next_seq := 1
var _inflight: Dictionary = {}
var connect_clock := 0.0
var body_font: Font

func _ready() -> void:
    body_font = _find_font()
    var shared_theme := Theme.new()
    shared_theme.default_font = body_font
    shared_theme.default_font_size = 16
    theme = shared_theme
    _build_world()
    _build_login()
    get_window().focus_exited.connect(_clear_input)
    var default_url := OS.get_environment("FERRY_URL")
    var default_token := OS.get_environment("FERRY_TOKEN")
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--server="):
            default_url = arg.trim_prefix("--server=")
    if default_url != "":
        url_field.text = default_url
    if default_token != "":
        token_field.text = default_token
        connect_to_world(url_field.text, default_token)

func _find_font() -> Font:
    var configured := OS.get_environment("FERRY_FONT")
    if configured != "":
        var local := FontFile.new()
        if local.load_dynamic_font(configured) == OK:
            return local
    var fallback := SystemFont.new()
    fallback.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "Noto Sans CJK", "Arial Unicode MS", "SimHei"])
    return fallback

func _card_style() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color("#1d2a23")
    style.border_color = Color("#796448")
    style.set_border_width_all(1)
    style.set_corner_radius_all(6)
    style.content_margin_left = 22
    style.content_margin_right = 22
    style.content_margin_top = 17
    style.content_margin_bottom = 17
    return style

func _text(container: Container, value: String, font_size: int, ink: Color) -> Label:
    var label := Label.new()
    label.text = value
    label.add_theme_font_size_override("font_size", font_size)
    label.add_theme_color_override("font_color", ink)
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    container.add_child(label)
    return label

func _hud_panel() -> PanelContainer:
    var panel := PanelContainer.new()
    var style := _card_style()
    style.bg_color = Color(0.075, 0.115, 0.09, 0.88)
    style.content_margin_left = 16
    style.content_margin_right = 16
    style.content_margin_top = 10
    style.content_margin_bottom = 10
    panel.add_theme_stylebox_override("panel", style)
    panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(panel)
    return panel

func _build_world() -> void:
    view.ink_font = body_font
    view.tile_pressed.connect(_on_tile)
    add_child(view)
    view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var location := _hud_panel()
    location.position = Vector2(22, 20)
    var location_stack := VBoxContainer.new()
    location_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
    location.add_child(location_stack)
    location_title = _text(location_stack, "溪桥渡", 25, GOLD)
    location_title.autowrap_mode = TextServer.AUTOWRAP_OFF
    world_status = _text(location_stack, "等待进入江湖", 14, MUTE)
    world_status.autowrap_mode = TextServer.AUTOWRAP_OFF
    bag_status = _text(location_stack, "蛇胆 0 · 铜钱 0", 14, PAPER)
    bag_status.autowrap_mode = TextServer.AUTOWRAP_OFF
    bag_status.hide()

    var dialogue := _hud_panel()
    dialogue.anchor_right = 0.70
    dialogue.anchor_top = 1.0
    dialogue.anchor_bottom = 1.0
    dialogue.offset_left = 22
    dialogue.offset_top = -18
    dialogue.offset_bottom = -18
    dialogue.grow_vertical = Control.GROW_DIRECTION_BEGIN
    var dialogue_stack := VBoxContainer.new()
    dialogue_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
    dialogue.add_child(dialogue_stack)
    dialogue_title = _text(dialogue_stack, "", 16, GOLD)
    dialogue_title.hide()
    dialogue_body = _text(dialogue_stack, "", 16, PAPER)
    _text(dialogue_stack, "方向键 / WASD 走格　左键寻路　E 互动　空格攻击", 13, MUTE)

func _build_login() -> void:
    login = Control.new()
    add_child(login)
    login.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var image := TextureRect.new()
    image.texture = load("res://assets/ferry-basin.png")
    image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
    image.mouse_filter = Control.MOUSE_FILTER_IGNORE
    login.add_child(image)
    image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var shade := ColorRect.new()
    shade.color = Color(0.06, 0.09, 0.07, 0.43)
    shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
    login.add_child(shade)
    shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var center := CenterContainer.new()
    login.add_child(center)
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var card := PanelContainer.new()
    card.custom_minimum_size.x = 430
    var style := _card_style()
    style.bg_color = Color(0.11, 0.16, 0.13, 0.98)
    style.content_margin_left = 28
    style.content_margin_right = 28
    style.content_margin_top = 24
    style.content_margin_bottom = 24
    card.add_theme_stylebox_override("panel", style)
    center.add_child(card)
    var form := VBoxContainer.new()
    form.add_theme_constant_override("separation", 10)
    card.add_child(form)
    _text(form, "溪桥渡", 38, GOLD)
    _text(form, "进入多人江湖", 17, PAPER)
    url_field = LineEdit.new()
    url_field.placeholder_text = "世界服地址"
    url_field.text = "ws://127.0.0.1:7670"
    form.add_child(url_field)
    token_field = LineEdit.new()
    token_field.placeholder_text = "角色通行口令"
    token_field.secret = true
    token_field.text_submitted.connect(func(_value): connect_to_world(url_field.text, token_field.text))
    form.add_child(token_field)
    link_button = Button.new()
    link_button.text = "进入渡口"
    link_button.pressed.connect(func(): connect_to_world(url_field.text, token_field.text))
    form.add_child(link_button)
    connection_message = _text(form, "", 14, MUTE)

func connect_to_world(raw_url: String, token: String) -> void:
    if socket:
        socket.close()
        socket = null
    var url := raw_url.strip_edges()
    var local_url := RegEx.new()
    local_url.compile("^ws://(127[.]0[.]0[.]1|localhost):[0-9]{1,5}(/[^ ]*)?$")
    if local_url.search(url) == null and not url.begins_with("wss://"):
        connection_message.text = "公网世界服使用 wss:// 地址。"
        return
    if token.strip_edges().is_empty():
        connection_message.text = "请输入角色通行口令。"
        return
    socket = WebSocketPeer.new()
    pending_token = token.strip_edges()
    login_sent = false
    connect_clock = 9.0
    var result := socket.connect_to_url(url)
    if result != OK:
        _connection_failed("世界服地址不可用。")
        return
    connection_message.text = "正在连接渡口……"
    link_button.disabled = true

func _connection_failed(message: String) -> void:
    if socket:
        socket.close()
    socket = null
    my_id = ""
    pending_token = ""
    _clear_input()
    _movement = GridInput.new()
    _inflight.clear()
    if bag_status:
        bag_status.hide()
    login.show()
    link_button.disabled = false
    connection_message.text = message

func _process(delta: float) -> void:
    if not socket:
        return
    socket.poll()
    var state := socket.get_ready_state()
    if state == WebSocketPeer.STATE_CLOSED:
        _connection_failed("与世界服断开，请重新连接。")
        return
    if my_id.is_empty():
        connect_clock -= delta
        if connect_clock <= 0:
            _connection_failed("世界服响应超时。")
            return
    if state != WebSocketPeer.STATE_OPEN:
        return
    if not login_sent:
        _send({"type": "login", "token": pending_token})
        pending_token = ""
        login_sent = true
    while socket and socket.get_available_packet_count() > 0:
        var packet := socket.get_packet().get_string_from_utf8()
        var message = JSON.parse_string(packet)
        if message is Dictionary:
            _apply(message)
    if my_id.is_empty():
        return
    _pump_movement(Time.get_ticks_msec())

func _send(message: Dictionary) -> bool:
    if not socket or socket.get_ready_state() != WebSocketPeer.STATE_OPEN or _inflight.size() >= 24:
        return false
    var payload := message.duplicate()
    var seq := _next_seq
    _next_seq += 1
    payload["seq"] = seq
    if socket.send(JSON.stringify(payload).to_utf8_buffer(), WebSocketPeer.WRITE_MODE_TEXT) != OK:
        return false
    if message["type"] != "login":
        _inflight[seq] = message["type"]
    return true

func _apply(message: Dictionary) -> void:
    var kind: String = message.get("type", "")
    var reply_to := ""
    if message.has("seq"):
        var seq := int(message["seq"])
        reply_to = String(_inflight.get(seq, ""))
        _inflight.erase(seq)
    match kind:
        "joined":
            my_id = message["id"]
            _movement = GridInput.new()
            _inflight.clear()
            _approach_target = ""
            var map_info: Dictionary = message["map"]
            view.my_id = my_id
            view.tiles = map_info["tiles"]
            view.features = map_info["features"]
            view.plaques = map_info.get("plaques", [])
            if map_info.has("name") and location_title:
                location_title.text = String(map_info["name"])
            if map_info.has("quest_hints") and map_info["quest_hints"] is Dictionary:
                quest_hints = map_info["quest_hints"]
            view.set_world({})
            login.hide()
            link_button.disabled = false
            _show_dialogue("", String(quest_hints.get(message["player"]["quest"], "")))
            _update_bag(message["player"])
        "world":
            var own: Dictionary = message["players"].get(my_id, {})
            if not own.is_empty():
                var cell := Vector2i(int(own["x"]), int(own["y"]))
                if _movement.observe(cell):
                    view.correct_step(cell)
            view.set_world(message, _movement.pending)
            world_status.text = "%d 人在线" % view.players.size()
        "map_updated":
            var map_info: Dictionary = message.get("map", {})
            if not map_info.is_empty():
                view.tiles = map_info.get("tiles", view.tiles)
                view.features = map_info.get("features", view.features)
                view.plaques = map_info.get("plaques", view.plaques)
                if map_info.has("name") and location_title:
                    location_title.text = String(map_info["name"])
                if map_info.has("quest_hints") and map_info["quest_hints"] is Dictionary:
                    quest_hints = map_info["quest_hints"]
            var world_snap: Dictionary = message.get("world", {})
            if not world_snap.is_empty():
                var own: Dictionary = world_snap.get("players", {}).get(my_id, {})
                if not own.is_empty():
                    var cell := Vector2i(int(own["x"]), int(own["y"]))
                    if _movement.observe(cell):
                        view.correct_step(cell)
                view.set_world(world_snap, _movement.pending)
                world_status.text = "%d 人在线" % view.players.size()
        "moved":
            if message.has("x") and message.has("y"):
                var cell := Vector2i(int(message["x"]), int(message["y"]))
                if _movement.observe(cell):
                    view.correct_step(cell)
                if message.has("facing"):
                    view.set_player_facing(my_id, String(message["facing"]))
        "event":
            if String(message.get("event", "")) == "player_moved" and String(message.get("id", "")) == my_id:
                var cell := Vector2i(int(message["x"]), int(message["y"]))
                if _movement.observe(cell):
                    view.correct_step(cell)
            view.apply_event(message, _movement.pending)
            world_status.text = "%d 人在线" % view.players.size()
        "dialogue":
            _show_dialogue(message["speaker"], message["text"])
            if message.has("player"):
                _update_bag(message["player"])
        "hit":
            if int(message["hp"]) == 0:
                _show_dialogue("", "击退芦滩蛇，拿到一枚蛇胆。")
            else:
                _show_dialogue("", "击中芦滩蛇，剩余 %d 点体力。" % int(message["hp"]))
            if message.has("player"):
                _update_bag(message["player"])
        "error":
            var code: String = message["code"]
            var reason: String = ERRORS.get(code, "这个动作暂时无法完成。")
            if my_id.is_empty():
                _connection_failed(reason)
            else:
                if reply_to == "move" and _movement.pending != GridInput.OUTSIDE:
                    _movement.reject()
                    view.correct_step(_movement.cell)
                    if code != "too_fast":
                        _clear_input()
                if code != "too_fast":
                    _show_dialogue("", reason)

func _update_bag(player: Dictionary) -> void:
    if not bag_status:
        return
    bag_status.text = "蛇胆 %d · 铜钱 %d" % [int(player.get("gall", 0)), int(player.get("coins", 0))]
    bag_status.show()

func _show_dialogue(speaker: String, message: String) -> void:
    dialogue_title.text = speaker
    dialogue_title.visible = not speaker.is_empty()
    dialogue_body.text = message

func _clear_input() -> void:
    _movement.clear_intent()
    _approach_target = ""

func _blocked_tiles() -> Dictionary:
    var blocked := {}
    for id in view.features:
        var item: Dictionary = view.features[id]
        blocked[Vector2i(int(item["x"]), int(item["y"]))] = true
    return blocked

func _is_monster(id: String) -> bool:
    if view.features.has(id) and view.features[id].has("kind"):
        return String(view.features[id]["kind"]) == "monster"
    return id == "reed_snake"

func _monster_alive(id: String) -> bool:
    if view.monsters.has(id):
        return bool(view.monsters[id].get("alive", false))
    return bool(view.monster.get("alive", false))

func _pump_movement(now: int) -> void:
    if _movement.at_goal():
        var target := _approach_target
        _clear_input()
        if target != "" and (not _is_monster(target) or _monster_alive(target)):
            _send({"type": "attack" if _is_monster(target) else "interact", "target": target})
        return
    var step := _movement.next_step(view.tiles, now, _blocked_tiles())
    if step == GridInput.OUTSIDE:
        _clear_input()
        _show_dialogue("", "到不了这个位置。")
    elif step != Vector2i.ZERO:
        _move(step, now)

func _move(step: Vector2i, now: int = -1) -> void:
    if _movement.pending != GridInput.OUTSIDE or _movement.cell == GridInput.OUTSIDE:
        return
    if _send({"type": "move", "dx": step.x, "dy": step.y}):
        _movement.begin_step(step, Time.get_ticks_msec() if now < 0 else now)
        view.preview_step(_movement.pending)

func _my_tile() -> Vector2i:
    var me: Dictionary = view.players.get(my_id, {"x": -99, "y": -99})
    return Vector2i(int(me["x"]), int(me["y"]))

func _on_tile(tile: Vector2i) -> void:
    if _movement.cell == GridInput.OUTSIDE:
        return
    var target := ""
    for id in view.features:
        var item: Dictionary = view.features[id]
        if tile == Vector2i(int(item["x"]), int(item["y"])):
            if _is_monster(id) and not _monster_alive(id):
                break
            target = id
            break
    _approach_target = ""
    if not _movement.seek(view.tiles, tile, 0 if target.is_empty() else 1, _blocked_tiles()):
        _show_dialogue("", "到不了这个位置。")
        return
    _approach_target = target
    _pump_movement(Time.get_ticks_msec())

func _unhandled_key_input(event: InputEvent) -> void:
    if my_id.is_empty():
        return
    if MOVE_KEYS.has(event.physical_keycode):
        if not event.echo:
            if event.pressed:
                var direction: Vector2i = MOVE_KEYS[event.physical_keycode]
                _approach_target = ""
                _movement.press(event.physical_keycode, direction)
                view.face_local(direction)
                _pump_movement(Time.get_ticks_msec())
            else:
                _movement.release(event.physical_keycode)
        get_viewport().set_input_as_handled()
        return
    if not event.pressed or event.echo:
        return
    if event.physical_keycode == KEY_SPACE:
        var position := _my_tile()
        var best := ""
        var best_distance := 2
        for id in view.features:
            if not _is_monster(id):
                continue
            var item: Dictionary = view.features[id]
            var distance: int = absi(position.x - int(item["x"])) + absi(position.y - int(item["y"]))
            if distance < best_distance:
                best_distance = distance
                best = id
        if best == "":
            _show_dialogue("", "附近没有可以攻击的目标。")
        else:
            _send({"type": "attack", "target": best})
        get_viewport().set_input_as_handled()
    if event.physical_keycode == KEY_E:
        var position := _my_tile()
        var best := ""
        var best_distance := 2
        for id in view.features:
            if _is_monster(id):
                continue
            var item: Dictionary = view.features[id]
            var distance: int = absi(position.x - int(item["x"])) + absi(position.y - int(item["y"]))
            if distance < best_distance:
                best_distance = distance
                best = id
        if best == "":
            _show_dialogue("", "附近没有可以调查的东西。")
        else:
            _send({"type": "interact", "target": best})
        get_viewport().set_input_as_handled()
