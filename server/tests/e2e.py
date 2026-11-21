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
    expect(player_a, "event", lambda message: message["event"] == "player_joined" and message["id"] == "test-b")

    send(player_a, type="move", dx=12, dy=0, seq=10)
    err = expect(player_a, "error")
    assert err["code"] == "invalid_step" and err["seq"] == 10
    send(player_a, type="interact", target="reed_trail", seq=11)
    err = expect(player_a, "error")
    assert err["code"] == "too_far" and err["seq"] == 11

    send(player_a, type="interact", target="apothecary", seq=12)
    dlg = expect(player_a, "dialogue")
    assert dlg["player"]["quest"] == "search" and dlg["seq"] == 12
    move(player_a, 7, 1)
    moved_event = expect(player_b, "event",
        lambda message: message["event"] == "player_moved" and message["id"] == "test-a" and message["x"] == 9)
    assert moved_event["facing"] == "right"

    send(player_a, type="interact", target="reed_trail")
    assert expect(player_a, "dialogue")["player"]["quest"] == "hunt"
    move(player_a, 1, 1)
    for health in (2, 1, 0):
        send(player_a, type="attack", target="reed_snake", damage=100, id="test-b")
        assert expect(player_a, "hit")["hp"] == health
        if health:
            time.sleep(0.62)
    expect(player_b, "event",
        lambda message: message["event"] == "player_attacked" and message["id"] == "test-a" and not message["alive"])

    move(player_a, 8, -1)
    for _ in range(2):
        send(player_a, type="interact", target="apothecary")
        assert expect(player_a, "dialogue")["player"] == {"quest": "done", "gall": 0, "coins": 12}
    send(player_b, type="interact", target="apothecary")
    assert expect(player_b, "dialogue")["player"] == {"quest": "search", "gall": 0, "coins": 0}

print("two authenticated clients share movements and monster state; quests and rewards are private")
