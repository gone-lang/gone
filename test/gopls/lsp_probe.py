#!/usr/bin/env python3
"""极简 LSP 客户端：给 gopls 发 didOpen，收集诊断后退出。

用来在命令行里模拟"编辑器打开一个文件"的场景：

    lsp_probe.py --gopls /path/to/gopls --root /tmp/m5 --lang go main.gone

输出的每行诊断形如：

    <相对路径>:<行>:<列>: <消息>

只依赖标准库。gopls 的命令行子命令是按扩展名猜 languageId 的
(gopls/internal/cmd)，与编辑器传的值不一致，所以这里直接说 LSP。
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.parse


class Client:
    def __init__(self, gopls, root, logfile=None):
        args = [gopls]
        if logfile:
            args.append("-logfile=" + logfile)
        args.append("serve")
        self.proc = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=root,
        )
        self.next_id = 1
        self.lock = threading.Lock()
        self.pending = {}
        self.diagnostics = {}
        self.done = threading.Event()
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    # ---- 传输层 ----
    def _send(self, payload):
        body = json.dumps(payload).encode()
        with self.lock:
            self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            self.proc.stdin.flush()

    def _read_loop(self):
        stream = self.proc.stdout
        while True:
            headers = {}
            while True:
                line = stream.readline()
                if not line:
                    return
                line = line.strip()
                if not line:
                    break
                key, _, value = line.decode().partition(":")
                headers[key.strip().lower()] = value.strip()
            length = int(headers.get("content-length", 0))
            if not length:
                return
            msg = json.loads(stream.read(length))
            if "id" in msg and "method" not in msg:
                with self.lock:
                    self.pending[msg["id"]] = msg
            elif msg.get("method") == "textDocument/publishDiagnostics":
                params = msg["params"]
                self.diagnostics[params["uri"]] = params.get("diagnostics", [])
                self.done.set()

    def request(self, method, params, timeout=180):
        self.next_id += 1
        rid = self.next_id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if rid in self.pending:
                    return self.pending.pop(rid)
            time.sleep(0.02)
        raise TimeoutError(method)

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def shutdown(self):
        try:
            self.notify("exit", None)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def to_uri(path):
    return "file://" + urllib.parse.quote(os.path.abspath(path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gopls", required=True)
    ap.add_argument("--root", required=True, help="工作区目录(模块根)")
    ap.add_argument("--lang", default="go", help="didOpen 的 languageId, 编辑器会传 go")
    ap.add_argument("--wait", type=float, default=1.5, help="收集诊断的静默等待秒数")
    ap.add_argument("--timeout", type=float, default=120, help="整体超时秒数")
    ap.add_argument("--logfile")
    ap.add_argument("path", nargs="+", help="相对于 root 的文件")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    c = Client(args.gopls, root, args.logfile)
    try:
        c.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": to_uri(root),
                "workspaceFolders": [{"uri": to_uri(root), "name": os.path.basename(root)}],
                "capabilities": {
                    "textDocument": {
                        "publishDiagnostics": {"relatedInformation": True},
                        "hover": {"contentFormat": ["markdown", "plaintext"]},
                    }
                },
            },
        )
        c.notify("initialized", {})

        for rel in args.path:
            full = os.path.join(root, rel)
            with open(full, encoding="utf-8") as f:
                text = f.read()
            c.notify(
                "textDocument/didOpen",
                {
                    "textDocument": {
                        "uri": to_uri(full),
                        "languageId": args.lang,
                        "version": 1,
                        "text": text,
                    }
                },
            )

        # 先等到至少一条诊断通知(gopls 对打开的文件总会发一条, 哪怕是空的),
        # 再等到安静下来。冷缓存时首次加载要几秒, 不能一上来就判断"安静"。
        deadline = time.time() + args.timeout
        seen = False
        stable_since = None
        while time.time() < deadline:
            got = c.done.wait(timeout=0.2)
            if got:
                c.done.clear()
                seen = True
                stable_since = time.time()
            elif seen and time.time() - stable_since >= args.wait:
                break
        if not seen:
            print("lsp_probe: 等不到任何诊断通知 (gopls 可能启动失败)", file=sys.stderr)
            return 1

        out = []
        for uri, diags in c.diagnostics.items():
            rel = urllib.parse.unquote(uri.replace("file://", ""))
            if rel.startswith(root + os.sep):
                rel = os.path.relpath(rel, root)
            for d in diags:
                rng = d["range"]["start"]
                out.append(
                    "%s:%d:%d: %s" % (rel, rng["line"] + 1, rng["character"] + 1, d["message"])
                )
        for line in sorted(out):
            print(line)
        return 0
    finally:
        c.shutdown()


if __name__ == "__main__":
    sys.exit(main())
