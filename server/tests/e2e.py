"""Two independent clients exercise the actual WebSocket and database boundaries."""
import json
import os
import sys
import time

from websockets.sync.client import connect

URL = sys.argv[1]
TOKENS = json.loads(os.environ["FERRY_PLAYERS"])


def send(socket, **payload):
    socket.send(json.dumps(payload))


def expect(socket, kind, condition=lambda _: True):
    deadline = time.monotonic() + 8
    while True:
        message = json.loads(socket.recv(timeout=max(0.01, deadline - time.monotonic())))
        if message["type"] == kind and condition(message):
            return message
        if message["type"] == "error":
            raise AssertionError(message)


def login(socket, name):
    send(socket, type="login", token=TOKENS[name])
    return expect(socket, "joined")


def move(socket, count, direction):
    for _ in range(count):
        send(socket, type="move", dx=direction, dy=0)
        expect(socket, "moved")
        time.sleep(0.17)


if sys.argv[2:] == ["--resume"]:
    with connect(URL, open_timeout=5) as player:
        snapshot = login(player, "test-a")
        assert snapshot["player"] == {"quest": "done", "gall": 0, "coins": 12}
    print("MongoDB restored private progress after a world-server restart")
    sys.exit()

with connect(URL, open_timeout=5) as guest:
    send(guest, type="move", dx=1, dy=0)
    assert expect(guest, "error")["code"] == "unauthenticated"
    send(guest, type="login", token="invalid")
    assert expect(guest, "error")["code"] == "bad_token"

with connect(URL, open_timeout=5) as player_a, connect(URL, open_timeout=5) as player_b:
    assert login(player_a, "test-a")["map"]["id"] == "ferry"
    assert login(player_b, "test-b")["player"]["quest"] == "new"
    expect(player_a, "world", lambda message: len(message["players"]) == 2)

    send(player_a, type="move", dx=12, dy=0)
    assert expect(player_a, "error")["code"] == "invalid_step"
    send(player_a, type="interact", target="reed_trail")
    assert expect(player_a, "error")["code"] == "too_far"

    send(player_a, type="interact", target="apothecary")
    assert expect(player_a, "dialogue")["player"]["quest"] == "search"
    move(player_a, 7, 1)
    snapshot = expect(player_b, "world", lambda message: message["players"]["test-a"]["x"] == 9)
    assert snapshot["players"]["test-b"]["x"] == 2

    send(player_a, type="interact", target="reed_trail")
    assert expect(player_a, "dialogue")["player"]["quest"] == "hunt"
    move(player_a, 1, 1)
    for health in (2, 1, 0):
        send(player_a, type="attack", target="reed_snake", damage=100, id="test-b")
        assert expect(player_a, "hit")["hp"] == health
        if health:
            time.sleep(0.62)
    expect(player_b, "world", lambda message: not message["monster"]["alive"])

    move(player_a, 8, -1)
    for _ in range(2):
        send(player_a, type="interact", target="apothecary")
        assert expect(player_a, "dialogue")["player"] == {"quest": "done", "gall": 0, "coins": 12}
    send(player_b, type="interact", target="apothecary")
    assert expect(player_b, "dialogue")["player"] == {"quest": "search", "gall": 0, "coins": 0}

print("two authenticated clients share movements and monster state; quests and rewards are private")
