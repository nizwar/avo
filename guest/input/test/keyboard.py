"""Device-side integration of the signed Avo Input APK with real Android editors."""
import argparse
import contextlib
import json
import re
import socket
import struct
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("adb")
parser.add_argument("display", type=int)
parser.add_argument("--android-keyboard", action="store_true")
options = parser.parse_args()
package = "com.avodroid.tests.input"
uri = "content://com.avodroid.input.editor"
private_clip = "content://" + package + ".files/item"


def adb(*args):
    return subprocess.check_output([options.adb, *args], text=True).strip()


def shell(command):
    return adb("shell", command)


def wait_file(name):
    shell(f"for i in $(seq 1 100); do run-as {package} test -f files/{name} && exit 0; sleep .05; done; exit 1")


def editor(web=False, clip="text", password=False, unknown_selection=False):
    shell(f"am force-stop {package}; run-as {package} rm -f files/ready files/page files/result")
    shell(f"am start -W --display {options.display} -n {package}/.Editor --ez web {str(web).lower()} "
          f"--es clip {clip} --ez password {str(password).lower()} --ez unknownSelection {str(unknown_selection).lower()}")
    wait_file("ready")
    if web:
        wait_file("page")
        shell(f"input -d {options.display} tap 110 160")


def expect(text, clip, pastes=0):
    for _ in range(15):
        shell(f"run-as {package} rm -f files/result; am broadcast -a {package}.READ -p {package}")
        wait_file("result")
        value = shell(f"run-as {package} cat files/result")
        if value == f"{text}|{clip}|{pastes}|false":
            return
        time.sleep(.05)
    raise AssertionError((text, clip, pastes, value))


class AvoInputClient:
    def __init__(self, stream):
        self.stream = stream
        self.session = None
        self.sequence = 0

    def read(self):
        length, = struct.unpack(">I", self.stream.read(4))
        return json.loads(self.stream.read(length))

    def send(self, **values):
        body = json.dumps(dict(session=self.session, **values), ensure_ascii=False).encode()
        self.stream.write(struct.pack(">I", len(body)) + body)
        self.stream.flush()

    def attach(self):
        self.session = None
        pid = int(shell(f"pidof -s {package}"))
        while True:
            msg = self.read()
            if msg["kind"] == "focus" and (msg.get("pid") == pid or msg.get("package") == package):
                self.session = msg["session"]
                self.sequence = 0
                self.send(action="attach")
            if msg["kind"] == "state" and msg["session"] == self.session:
                return msg

    def edit(self, action, **args):
        self.sequence += 1
        self.send(action=action, sequence=self.sequence, **args)
        while True:
            msg = self.read()
            if msg.get("session") == self.session and msg.get("ack") == self.sequence:
                return msg


@contextlib.contextmanager
def connection():
    result = shell(f"content call --uri {uri} --method connect")
    name = re.search(r"socket=(avo-input-[0-9a-f-]+)", result).group(1)
    port = adb("forward", "tcp:0", "localabstract:" + name)
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=6) as sock, sock.makefile("rwb") as stream:
            yield AvoInputClient(stream)
    finally:
        adb("forward", "--remove", "tcp:" + port)


def utf16(text):
    return len(text.encode("utf-16-le")) // 2


samples = [
    ("nihao", "你好，AI助手 2.0"), ("にほんご", "日本語"), ("하", "한글"), ("e", "cafe\u0301"),
    ("при", "Привет"), ("κα", "Καλημέρα"), ("مر", "مَرْحَبًا"), ("ש", "שָׁלוֹם"),
    ("नम", "नमस्ते"), ("বা", "বাংলা"), ("สว", "สวัสดี"), ("tok", "Tokyo 2026"), ("👩🏽", "👩🏽‍💻"),
]

selected = shell("settings get secure default_input_method")
assert (selected == "com.avodroid.input/.AvoInputService") != options.android_keyboard, selected
with connection() as keyboard:
    if options.android_keyboard:
        editor()
        assert keyboard.read() == {"kind": "focus"}
        shell(f"input -d {options.display} keyevent KEYCODE_A")
        expect("a", "SEED")
    else:
        editor(unknown_selection=True)
        initial = keyboard.attach()
        assert initial["start"] == initial["end"] == -1
        keyboard.edit("commit", text="A")
        keyboard.edit("mark", text="かな")
        expect("Aかな", "SEED")
        keyboard.edit("cancel")
        expect("A", "SEED")
        keyboard.edit("mark", text="に")
        keyboard.edit("finish")
        keyboard.edit("cancel")
        expect("Aに", "SEED")
        previous = None
        for web in (False, True):
            editor(web, "uri")
            keyboard.attach()
            if previous:
                assert previous != keyboard.session
                session = keyboard.session
                keyboard.session = previous
                keyboard.send(action="commit", sequence=1, text="stale")
                keyboard.session = session
            previous = keyboard.session
            value = ""
            for typed, final in samples:
                keyboard.edit("mark", text=typed)
                expect(value + typed, private_clip)
                keyboard.edit("commit", text=final)
                value += final
            expect(value, private_clip)
            keyboard.edit("mark", text="かな", caretStart=1, caretEnd=1)
            expect(value + "かな", private_clip)
            keyboard.edit("cancel")
            expect(value, private_clip)
            keyboard.edit("commit", text="A👩🏽‍💻B", **{"from": 0, "to": utf16(value)})
            keyboard.edit("mark", text="あい", caretStart=1, caretEnd=1, **{"from": 1, "to": 1 + utf16("👩🏽‍💻")})
            keyboard.edit("finish")
            expect("AあいB", private_clip)

            editor(web)
            keyboard.attach()
            keyboard.edit("commit", text="甲")
            adb("shell", "input", "-d", str(options.display), "keycombination", "KEYCODE_CTRL_LEFT", "KEYCODE_V")
            expect("甲SEED", "SEED", pastes=1)
            shell(f"run-as {package} rm -f files/busy; am broadcast --async -a {package}.BUSY -p {package}")
            wait_file("busy")
            keyboard.edit("keyDown", keyCode=21)  # KEYCODE_DPAD_LEFT
            keyboard.edit("keyUp", keyCode=21)
            keyboard.edit("commit", text="汉")
            expect("甲SEE汉D", "SEED", pastes=1)
        editor(clip="empty", password=True)
        assert keyboard.attach()["privateEditor"]
        state = keyboard.edit("commit", text="secret")
        assert "text" not in state
        expect("secret", "empty")
assert shell("settings get secure default_input_method") == selected
print("Avo Input device tests passed")
