extends SceneTree
# Drive the same scene and WebSocket that players use.
func _initialize() -> void:
    call_deferred("_check")

func _check() -> void:
    var args := OS.get_cmdline_user_args()
    if args.size() != 2:
        push_error("Pass a server URL and player token")
        quit(1)
        return
    var game = load("res://main.tscn").instantiate()
    root.add_child(game)
    game.connect_to_world(args[0], args[1])
    for n in range(300):
        await process_frame
        if game.my_id != "" and game.view.players.has(game.my_id):
            print("Godot client authenticated and displayed the server's grid")
            quit(0)
            return
        await create_timer(0.02).timeout
    push_error("Godot client did not receive a usable world snapshot")
    quit(1)
