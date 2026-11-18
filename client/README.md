# Godot 客户端

用 Godot 4.5 打开此目录的 `project.godot`，运行主场景。连接页填世界服地址和角色通行口令。测试服务允许本机 `ws://127.0.0.1:7670`，对外服务器使用 `wss://`。

环境变量 `FERRY_URL`、`FERRY_TOKEN` 可直接设定启动连接。Linux 缺少中文字库时可设 `FERRY_FONT` 指向本机 CJK 字体文件。只分发客户端目录或 Godot 导出包给玩家。

方向键或 WASD 移动，E 交互，空格攻击，鼠标点击相邻格也能操作。

`assets/ferry-grid-concept.png` 用于入口画面。`assets/animal-atlas.png` 是游戏内角色图集。关卡网格由世界服传入。
