extends SceneTree

func _initialize() -> void:
    call_deferred("_check")

func _check() -> void:
    var game = load("res://main.tscn").instantiate()
    root.add_child(game)
    for window_size in [Vector2i(1280, 800), Vector2i(1580, 800)]:
        root.size = window_size
        await process_frame
        await process_frame
        if game.view.position != Vector2.ZERO or not game.view.size.is_equal_approx(game.size):
            _fail("The map must occupy the whole gameplay window at %s, got %s" % [window_size, game.view.get_rect()])
            return

    for node in game.find_children("*", "Label", true, false):
        if node.text in ["行囊", "见闻"]:
            _fail("The gameplay layout still contains a sidebar label")
            return

    game.my_id = "tester"
    game._apply({"type": "dialogue", "speaker": "兔药师", "text": "药箱落在了芦苇滩。", "player": {"quest": "search", "coins": 0, "gall": 0}})
    if game.dialogue_title.text != "兔药师" or game.dialogue_body.text != "药箱落在了芦苇滩。":
        _fail("NPC dialogue must still appear in the HUD")
        return

    print("Full-window map, no sidebar and NPC dialogue passed")
    quit(0)

func _fail(message: String) -> void:
    printerr(message)
    quit(1)
