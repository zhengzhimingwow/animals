# 世界服

构建依赖为 CMake 3.22+、支持 C++20 的编译器、Boost 1.74+、Lua 5.4、nlohmann/json、官方 MongoDB C 驱动 libmongoc 2.x。C++ 宿主管连接、协议和 MongoDB 访问，`lua/world.lua` 管格子、怪物、剧情与背包。

从此目录构建和运行。

```sh
cmake -S . -B build
cmake --build build --parallel
./build/ferry-server
```

启动前在服务端环境配置以下值。

| 变量 | 内容 |
| --- | --- |
| `FERRY_MONGO_URI` | 私有 MongoDB 连接串，开发单独使用测试库 |
| `FERRY_MONGO_DB` | 存档库名，默认 `ferry_demo` |
| `FERRY_PLAYERS` | 角色 ID 到高熵通行口令的 JSON 对象。测试需准备两个角色 |
| `FERRY_BIND` | 监听地址，默认 `127.0.0.1` |
| `FERRY_PORT` | 世界服端口，默认 `7670` |

MongoDB 采用每角色一份文档和条件修订号。交任务的材料扣减、奖励和任务进度在一次单文档写入中提交。服务端启动会检查 MongoDB 连接。正式部署时，MongoDB 只接受服务端网络连接并启用认证，公开的 WSS 入口反代世界服连接。此切片使用一个世界进程，单线程运行 Lua 规则，存档 I/O 随事务执行。

## 验证

从服务端目录用 `lua5.4 tests/world_test.lua` 验证规则。启动一个独立的测试库和世界服，在测试进程为 `test-a` 和 `test-b` 使用对应口令，安装 Python `websockets` 后执行下面的双玩家测试。

```sh
python tests/e2e.py ws://127.0.0.1:7670
```

重启世界服并保留同一个测试库后，加 `--resume` 验证背包和任务进度恢复。
