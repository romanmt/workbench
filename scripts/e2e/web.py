#!/usr/bin/env python3
"""E2E tests for web panes (`pane browse` / `pane eval`), the browser pane agents' mods draw their pages in.

Runs a debug Workbench in its own state directory (PANE_STATE_DIR) with one project and drives it through the
control socket and the `pane` CLI. Build first: scripts/bundle.sh --debug. Then: python3 -I scripts/e2e/web.py
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import traceback

REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class App:
    def __init__(self, app, state, log):
        self.app = app
        self.state = state
        self.log = log
        self.sock = os.path.join(state, "pane.sock")
        self.proc = subprocess.Popen([os.path.join(app, "Contents/MacOS/Workbench")],
                                     env=dict(os.environ, PANE_STATE_DIR=state), stdout=log, stderr=subprocess.STDOUT)
        wait(self.ping, 30, "Workbench to answer on its control socket")

    def ping(self):
        try:
            return isinstance(self.call("list"), list)
        except OSError:
            return False

    def call(self, cmd, timeout=30, **args):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock)
            s.sendall(json.dumps({"cmd": cmd, **args}).encode() + b"\n")
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
        finally:
            s.close()
        return json.loads(data)

    def ok(self, cmd, **args):
        reply = self.call(cmd, **args)
        assert not (isinstance(reply, dict) and "error" in reply), f"{cmd}: {reply}"
        return reply

    def rows(self, kind):
        return [r for r in self.call("list") if r["kind"] == kind]

    def cli(self, *args, pane, cwd):
        env = dict(os.environ, PANE_SOCK=self.sock, PANE_ID=pane)
        return subprocess.run([os.path.join(self.app, "Contents/Helpers/pane"), *args], env=env, cwd=cwd,
                              capture_output=True, text=True, timeout=60)

    def quit(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        subprocess.run(["pkill", "-f", os.path.join(self.state, "s") + "/"], check=False)


def wait(cond, timeout, what):
    end = time.time() + timeout
    while time.time() < end:
        v = cond()
        if v:
            return v
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for {what}")


class Fixture:
    def __init__(self, keep):
        self.keep = keep
        self.root = tempfile.mkdtemp(prefix="wb-web-")
        self.state = os.path.join(self.root, "state")
        self.work = os.path.join(self.root, "work")
        os.makedirs(self.state)
        os.makedirs(self.work)
        self.page = os.path.join(self.work, "page.html")
        with open(self.page, "w") as f:
            f.write("<!doctype html><title>Mods</title><script>window.x = 41</script><body>hello</body>")
        terminal = {"id": "11111111-1111-1111-1111-111111111111", "kind": {"terminal": {"cwd": self.work}}}
        layout = {"projects": [{"id": "22222222-2222-2222-2222-222222222222", "path": self.work, "name": "work",
                                "tabs": [{"id": "33333333-3333-3333-3333-333333333333", "title": "work",
                                          "root": {"leaf": {"_0": terminal}}, "focused": terminal["id"]}],
                                "activeTab": 0}],
                  "activeProject": 0, "sidebarVisible": True, "theme": "system-dark"}
        with open(os.path.join(self.state, "layout.json"), "w") as f:
            json.dump(layout, f)
        self.terminal = terminal["id"]

    def layout(self):
        with open(os.path.join(self.state, "layout.json")) as f:
            return json.load(f)

    def cleanup(self):
        if not self.keep:
            shutil.rmtree(self.root, ignore_errors=True)


def browse(app, f, ratio="0.33"):
    url = "file://" + f.page
    return app.ok("browse", url=url, pane=f.terminal, ratio=ratio)["pane"]


# MARK: - Tests

def test_browse_beside_and_eval_before_load(app, f):
    pane = browse(app, f)
    # sent at once, before the page has loaded: it waits and runs against the page
    assert app.ok("eval", pane=pane, code="window.x + 1") == {"result": 42}
    rows = app.rows("web")
    assert [r["pane"] for r in rows] == [pane], rows
    wait(lambda: app.rows("web")[0]["title"] == "Mods", 5, "the page title on its pane")
    # the page takes the right third; the terminal keeps the focus
    root = wait(lambda: (t := f.layout()["projects"][0]["tabs"][0]) and "split" in t["root"] and t, 5, "the layout save")
    split = root["root"]["split"]
    assert split["axis"] == "horizontal" and abs(split["ratio"] - 0.67) < 1e-9, split
    assert split["a"]["leaf"]["_0"]["id"] == f.terminal and split["b"]["leaf"]["_0"]["id"] == pane
    assert root["focused"] == f.terminal, root["focused"]


def test_eval_values(app, f):
    pane = app.rows("web")[0]["pane"]
    assert app.ok("eval", pane=pane, code="({a: [1, 'two'], b: null})") == {"result": {"a": [1, "two"], "b": None}}
    assert app.ok("eval", pane=pane, code="void 0") == {"result": None}
    assert app.ok("eval", pane=pane, code="document.body") == {"result": None}   # no JSON form
    assert "error" in app.call("eval", pane=pane, code="throw new Error('boom')")
    assert app.call("eval", pane="44444444-4444-4444-4444-444444444444", code="1") == {"error": "unknown pane"}
    assert app.call("eval", pane=f.terminal, code="1") == {"error": "unknown pane"}


def test_page_written_by_eval(app, f):
    # what Superset's host does with its whole page: a big document written in one eval
    pane = app.rows("web")[0]["pane"]
    filler = "x" * (2 << 20)
    doc = f"<!doctype html><title>Big</title><body><p id=n>{filler}</p><script>window.y = 7</script></body>"
    write = f"document.open();document.write({json.dumps(doc)});document.close();location.hash='mods'"
    app.ok("eval", pane=pane, code=write)
    assert app.ok("eval", pane=pane, code="[window.y, document.getElementById('n').textContent.length, location.hash]") \
        == {"result": [7, 2 << 20, "#mods"]}


def test_cli(app, f):
    out = app.cli("browse", "page.html", "--ratio", "0.4", pane=f.terminal, cwd=f.work)
    assert out.returncode == 0, out.stderr
    pane = json.loads(out.stdout)["pane"]
    out = app.cli("eval", pane, "window.x", "*", "2", pane=f.terminal, cwd=f.work)
    assert out.returncode == 0 and json.loads(out.stdout) == {"result": 82}, (out.stdout, out.stderr)
    out = app.cli("eval", "44444444-4444-4444-4444-444444444444", "1", pane=f.terminal, cwd=f.work)
    assert out.returncode == 1 and "unknown pane" in out.stderr, (out.stdout, out.stderr)
    out = app.cli("browse", "ftp://x/y", pane=f.terminal, cwd=f.work)
    assert out.returncode == 1, out.stdout


def test_not_restored(app, f):
    assert app.rows("web"), "no web panes to drop"
    time.sleep(1)   # the debounced save
    app.quit()
    app.__init__(app.app, f.state, app.log)
    assert app.rows("web") == [] and [r["pane"] for r in app.rows("terminal")] == [f.terminal], app.call("list")


TESTS = [test_browse_beside_and_eval_before_load, test_eval_values, test_page_written_by_eval, test_cli,
         test_not_restored]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default=os.path.join(REPO_DIR, "build.noindex/Workbench-debug.app"))
    ap.add_argument("--keep", action="store_true", help="keep the temp folder (state, app log)")
    ap.add_argument("-k", dest="only", help="run tests whose name contains this")
    a = ap.parse_args()
    if not os.path.isdir(a.app):
        sys.exit(f"{a.app} not found: run scripts/bundle.sh --debug")

    f = Fixture(a.keep)
    log = open(os.path.join(f.root, "app.log"), "w")
    app = App(a.app, f.state, log)
    failures = 0
    try:
        for t in TESTS:
            if a.only and a.only not in t.__name__:
                continue
            start = time.time()
            try:
                t(app, f)
                print(f"PASS {t.__name__} ({time.time() - start:.1f}s)", flush=True)
            except Exception:
                failures += 1
                print(f"FAIL {t.__name__}\n{traceback.format_exc()}", flush=True)
                f.keep = True
    finally:
        app.quit()
        f.cleanup()
    if f.keep:
        print(f"kept {f.root}")
    print("ok" if not failures else f"{failures} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
