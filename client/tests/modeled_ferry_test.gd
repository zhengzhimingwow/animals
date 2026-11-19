extends SceneTree

const GridMath = preload("res://grid_projection.gd")
const MAP := [
    "############", "##....#~~~~#", "#......~D~~#", "#..........#",
    "#....#.....#", "#....#..,,,#", "##......,,##", "############",
]
const SIZE := Vector2i(12, 8)

func _initialize() -> void:
    call_deferred("_check")

func _check() -> void:
    var game = load("res://main.tscn").instantiate()
    root.add_child(game)
    var view = game.view
    view.tiles = MAP
    view.features = {"apothecary": {"x": 2, "y": 3, "label": "兔药师"},
        "boatman": {"x": 7, "y": 3, "label": "牛船工"},
        "reed_trail": {"x": 9, "y": 5, "label": "空药箱"},
        "reed_snake": {"x": 11, "y": 4, "label": "芦滩蛇"}}
    view.my_id = "hero"
    view.set_world({"players": {"hero": {"x": 2, "y": 4}, "guest": {"x": 7, "y": 4}}, "monster": {"alive": true, "hp": 3}})
    await process_frame
    if not require(view.get("_camera") is Camera3D, "Ferry needs an orthographic 3D camera"):
        return
    if not await check_camera(view):
        return

    var stage: Node3D = view.get("_ferry")
    if not require(stage != null and not stage.find_children("*", "MeshInstance3D", true, false).is_empty(),
            "A Blender-authored ferry mesh must be instantiated"):
        return
    if not check_tiled_ground(stage):
        return
    if not require(view._figures.size() == 3 and view._figures["reed_snake"].visible,
            "The fixed actors must be live models"):
        return
    var hero: Node3D = view._heroes["hero"]
    var guest: Node3D = view._heroes["guest"]
    var bones := hero.find_children("*", "Skeleton3D", true, false)
    if not require(not bones.is_empty() and bones[0].get_bone_count() >= 6,
            "The live tiger must have its exported armature"):
        return
    var animations: AnimationPlayer = view._animation_player(hero)
    var other_animations: AnimationPlayer = view._animation_player(guest)
    if not require(animations != null and animations.has_animation("idle") and animations.has_animation("walk")
            and animations.current_animation == "idle", "Imported idle and walk are played from the model"):
        return

    view.set_world({"players": {"hero": {"x": 3, "y": 4}, "guest": {"x": 7, "y": 5}},
        "monster": {"alive": false, "hp": 0}})
    await create_timer(0.06).timeout
    if not require(animations.current_animation == "walk" and other_animations.current_animation == "walk"
            and not view._figures["reed_snake"].visible,
            "Local and remote models must play Walk and a defeated monster must hide"):
        return
    await create_timer(0.26).timeout
    if not require(animations.current_animation == "idle" and other_animations.current_animation == "idle"
            and hero.position.is_equal_approx(Vector3(2.5, 0, 3.5)),
            "Models must stop at the world-confirmed tile and resume Idle"):
        return

    print("Live Blender models, rig clips, two actors, monster and oblique map clicks passed")
    quit(0)

func check_camera(view: Control) -> bool:
    for window_size in [Vector2i(1280, 800), Vector2i(1536, 800)]:
        root.size = window_size
        await process_frame
        await process_frame
        var camera: Camera3D = view._camera
        for cell in [Vector2i(2, 4), Vector2i(8, 4), Vector2i(10, 6)]:
            var on_screen := camera.unproject_position(Vector3(cell.x - 0.5, 0, cell.y - 0.5))
            on_screen *= view.size / Vector2(camera.get_viewport().size)
            var expected := GridMath.center(GridMath.fit(view.size, SIZE), cell)
            if not require(on_screen.distance_to(expected) < 2.0,
                    "The visible 3D tile must match the hit grid at %s (%s vs %s)" % [cell, on_screen, expected]):
                return false
            if not require(GridMath.pick(GridMath.fit(view.size, SIZE), SIZE, on_screen) == cell,
                    "Clicking the model-space cell must pick its exact world tile"):
                return false
    return true

func check_tiled_ground(stage: Node3D) -> bool:
    var seen := {}
    for node in stage.find_children("*", "MeshInstance3D", true, false):
        for surface in node.mesh.get_surface_count():
            var material = node.mesh.surface_get_material(surface)
            if not material is StandardMaterial3D:
                continue
            if material.resource_name in ["Meadow and wildflowers", "Weathered yellow stone"]:
                if not require(material.albedo_texture and material.texture_repeat,
                        "The modeled ground must tile its texture without clamped stripes"):
                    return false
                seen[material.resource_name] = true
    return require(seen.size() == 2, "Both modeled ground materials must be present")

func require(condition: bool, message: String) -> bool:
    if not condition:
        printerr(message)
        quit(1)
    return condition
