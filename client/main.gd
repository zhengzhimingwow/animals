extends Control

const GridView = preload("res://world_view.gd")
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
var world_status: Label
var quest_status: Label
var inventory: Label
var dialogue_title: Label
var dialogue_body: Label
var activity: Label
var movement_clock := 0.0
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
    container.add_child(label)
    return label

func _spacer(container: Container, height: float) -> void:
    var space := Control.new()
    space.custom_minimum_size.y = height
    container.add_child(space)

func _build_world() -> void:
    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 30)
    margin.add_theme_constant_override("margin_right", 30)
    margin.add_theme_constant_override("margin_top", 18)
    margin.add_theme_constant_override("margin_bottom", 19)
    add_child(margin)
    margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var layout := VBoxContainer.new()
    layout.add_theme_constant_override("separation", 11)
    margin.add_child(layout)
    _text(layout, "溪桥渡", 34, GOLD)
    world_status = _text(layout, "等待进入江湖", 15, MUTE)

    var body := HBoxContainer.new()
    body.add_theme_constant_override("separation", 17)
    body.size_flags_vertical = Control.SIZE_EXPAND_FILL
    layout.add_child(body)
    view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    view.ink_font = body_font
    view.tile_pressed.connect(_on_tile)
    body.add_child(view)
    var panel := PanelContainer.new()
    panel.custom_minimum_size.x = 290
    panel.add_theme_stylebox_override("panel", _card_style())
    body.add_child(panel)
    var quest_column := VBoxContainer.new()
    quest_column.add_theme_constant_override("separation", 7)
    panel.add_child(quest_column)
    _text(quest_column, "渡口丢药", 23, GOLD)
    quest_status = _text(quest_column, QUESTS["new"], 16, PAPER)
    _spacer(quest_column, 13)
    _text(quest_column, "行囊", 19, GOLD)
    inventory = _text(quest_column, "铜钱 0  ·  蛇胆 0", 16, PAPER)
    _spacer(quest_column, 13)
    _text(quest_column, "见闻", 19, GOLD)
    activity = _text(quest_column, "沿着河岸走，留意可调查的东西。", 15, MUTE)

    var dialogue := PanelContainer.new()
    dialogue.add_theme_stylebox_override("panel", _card_style())
    dialogue.custom_minimum_size.y = 104
    layout.add_child(dialogue)
    var dialogue_stack := VBoxContainer.new()
    dialogue.add_child(dialogue_stack)
    dialogue_title = _text(dialogue_stack, "初到渡口", 16, GOLD)
    dialogue_body = _text(dialogue_stack, "用方向键或 WASD 走格。E 交谈或调查，空格攻击，鼠标也可点相邻格。", 16, PAPER)

func _build_login() -> void:
    login = Control.new()
    add_child(login)
    login.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var image := TextureRect.new()
    image.texture = load("res://assets/ferry-grid-concept.png")
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
    movement_clock -= delta
    if movement_clock > 0:
        return
    var step := Vector2i.ZERO
    if Input.is_physical_key_pressed(KEY_A) or Input.is_action_pressed("ui_left"):
        step = Vector2i.LEFT
    elif Input.is_physical_key_pressed(KEY_D) or Input.is_action_pressed("ui_right"):
        step = Vector2i.RIGHT
    elif Input.is_physical_key_pressed(KEY_W) or Input.is_action_pressed("ui_up"):
        step = Vector2i.UP
    elif Input.is_physical_key_pressed(KEY_S) or Input.is_action_pressed("ui_down"):
        step = Vector2i.DOWN
    if step != Vector2i.ZERO:
        _move(step)

func _send(message: Dictionary) -> void:
    if socket and socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
        socket.send(JSON.stringify(message).to_utf8_buffer(), WebSocketPeer.WRITE_MODE_TEXT)

func _apply(message: Dictionary) -> void:
    match message.get("type"):
        "joined":
            my_id = message["id"]
            var map_info: Dictionary = message["map"]
            view.my_id = my_id
            view.tiles = map_info["tiles"]
            view.features = map_info["features"]
            view.set_world({})
            _private_state(message["player"])
            login.hide()
            link_button.disabled = false
            dialogue_title.text = "初到渡口"
            dialogue_body.text = "方向键或 WASD 走格，E 交谈或调查，空格攻击。也可以点击相邻格。"
        "world":
            view.set_world(message)
            world_status.text = "多人世界   ·   渡口在线 %d 人" % view.players.size()
        "dialogue":
            dialogue_title.text = message["speaker"]
            dialogue_body.text = message["text"]
            _private_state(message["player"])
        "hit":
            _private_state(message["player"])
            if int(message["hp"]) == 0:
                activity.text = "击退芦滩蛇，拿到一枚蛇胆。"
            else:
                activity.text = "击中芦滩蛇，剩余 %d 点体力。" % int(message["hp"])
        "error":
            var code: String = message["code"]
            var reason: String = ERRORS.get(code, "这个动作暂时无法完成。")
            if my_id.is_empty():
                _connection_failed(reason)
            elif code != "too_fast":
                activity.text = reason

func _private_state(record: Dictionary) -> void:
    quest_status.text = QUESTS.get(record["quest"], "")
    inventory.text = "铜钱 %d  ·  蛇胆 %d" % [int(record["coins"]), int(record["gall"])]

func _move(step: Vector2i) -> void:
    movement_clock = 0.19
    _send({"type": "move", "dx": step.x, "dy": step.y})

func _my_tile() -> Vector2i:
    var me: Dictionary = view.players.get(my_id, {"x": -99, "y": -99})
    return Vector2i(int(me["x"]), int(me["y"]))

func _on_tile(tile: Vector2i) -> void:
    var step := tile - _my_tile()
    if abs(step.x) + abs(step.y) > 1:
        activity.text = "点击相邻格移动，走近后可以调查。"
        return
    for id in view.features:
        var item: Dictionary = view.features[id]
        if tile == Vector2i(int(item["x"]), int(item["y"])):
            if id == "reed_snake" and not view.monster.get("alive", false):
                break
            _send({"type": "attack" if id == "reed_snake" else "interact", "target": id})
            return
    if step != Vector2i.ZERO and movement_clock <= 0:
        _move(step)

func _unhandled_key_input(event: InputEvent) -> void:
    if my_id.is_empty() or not event.pressed or event.echo:
        return
    if event.physical_keycode == KEY_SPACE:
        _send({"type": "attack", "target": "reed_snake"})
        get_viewport().set_input_as_handled()
    if event.physical_keycode == KEY_E:
        var position := _my_tile()
        var best := ""
        var best_distance := 2
        for id in view.features:
            if id == "reed_snake":
                continue
            var item: Dictionary = view.features[id]
            var distance: int = absi(position.x - int(item["x"])) + absi(position.y - int(item["y"]))
            if distance < best_distance:
                best_distance = distance
                best = id
        if best == "":
            activity.text = "附近没有可以调查的东西。"
        else:
            _send({"type": "interact", "target": best})
        get_viewport().set_input_as_handled()
