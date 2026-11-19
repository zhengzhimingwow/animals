# Godot 客户端

用 Godot 4.5 打开此目录的 `project.godot`，运行主场景。连接页填世界服地址和角色通行口令。测试服务允许本机 `ws://127.0.0.1:7670`，对外服务器使用 `wss://`。

环境变量 `FERRY_URL`、`FERRY_TOKEN` 可直接设定启动连接。Linux 缺少中文字库时可设 `FERRY_FONT` 指向本机 CJK 字体文件。只分发客户端目录或 Godot 导出包给玩家。

短按方向键或 WASD 走一格，按住连续走。左键点击地面自动寻路，点人物会走近对话。靠近后也可以按 E 对话或调查，按空格攻击。

溪桥渡的地形、建筑和动物角色来自 `assets/models/`。Godot 在独立的 3D 视口里实时渲染这些模型，固定正交相机与世界服下发的格子共用坐标。旧角色图集和布局图可用于美术对照。Blender 源文件分别保存在项目根目录的 `art/ferry/` 和 `art/characters/`。

小虎侠会播放模型自带的站姿和走路骨骼动画。`walk_motion.gd` 用世界服确认的相邻坐标推进移动和朝向。

在此目录运行 `godot --headless --path . --script res://tests/modeled_ferry_test.gd` 可验证模型载入、骨骼动作、同图角色和点击坐标。
