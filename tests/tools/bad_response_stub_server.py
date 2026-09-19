#!/usr/bin/env python3
"""
Malformed-response stub (issue #111).

Answers HTTP 200 with a body the plugin cannot turn into an answer, so the
non-streaming failure paths can be walked without waiting for a provider to
misbehave. Before the #111 fix an empty body crashed KOReader outright
(json.decode("") returns nil WITHOUT raising, and the nil reached the provider
transform); every shape below must now end in a message and a usable app.

Shapes:
    empty         200, Content-Length: 0                  <- the reported crash
    headers-only  200, no body, rate-limit headers        <- empty after the marker strip
    whitespace    200, body "\\r\\n\\r\\n"
    null          200, body "null"                        <- truthy function sentinel
    scalar        200, body "5"
    truncated     200, a JSON object cut mid-key
    html          200, an HTML error page (proxy in front of the model)
    hangup        200 headers, then the connection closed with no body
    ok            a normal answer (valid X-Ray JSON, so a ladder round stays clean)

--heal serves ONE empty body and then answers normally for the rest of the run:
the shape an X-Ray checkpoint chain needs to prove it heals, since the ladder
retries a failed rung once (after 60s) and that retry must find a real answer.
--cycle cannot show this -- the retry would land on the next broken shape.

Usage:
    python3 tests/tools/bad_response_stub_server.py                  # port 8766, empty
    python3 tests/tools/bad_response_stub_server.py 8766 null
    python3 tests/tools/bad_response_stub_server.py 8766 --cycle     # a different shape each request
    python3 tests/tools/bad_response_stub_server.py 8766 --heal      # empty once, then normal answers

Then in KOAssistant (desktop build):
  1. Settings -> Advanced -> Streaming -> Enable Streaming OFF. The crash lives in
     the NON-streaming path; with streaming on the request never reaches it.
  2. Settings -> Provider -> Add custom provider, base URL
     http://127.0.0.1:8766/v1/chat/completions, no API key, any model name.
  3. Run any action.
Expected per shape: "Empty response from <provider>. Please try again." for empty,
headers-only, whitespace and hangup; "Failed to parse response from <provider>" for
null, scalar, truncated and html. No crash in any of them. The log prints the shape
it served for each request.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SHAPES = ["empty", "headers-only", "whitespace", "null", "scalar",
          "truncated", "html", "hangup", "ok"]

# The "ok" answer is valid X-Ray JSON, not prose. A ladder rung whose answer does
# not parse is cached AS-IS when the book has no X-Ray yet (koassistant_dialogs.lua,
# the round-28 ruling: some models produce usable prose), so a prose "ok" writes a
# junk X-Ray into whatever book the round is run against and every later rung then
# aborts with "incremental update not applicable". Valid JSON keeps the ladder round
# on the path it is meant to test, and still reads as a sane answer in a chat.
OK_CONTENT = json.dumps({
    "characters": [{"name": "Stub Character",
                    "description": "Placed by bad_response_stub_server.py. Not a real X-Ray."}],
    "current_state": {"summary": "The stub is wired up correctly."},
}, ensure_ascii=False)

PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 8766
CYCLE = "--cycle" in sys.argv
HEAL = "--heal" in sys.argv
SHAPE = next((a for a in sys.argv[1:] if a in SHAPES), "empty")
_next = 0


def pick_shape():
    global _next
    _next += 1
    if HEAL:
        # One failure, then a provider that works: the retry must succeed.
        return "empty" if _next == 1 else "ok"
    if not CYCLE:
        return SHAPE
    return SHAPES[(_next - 1) % len(SHAPES)]


class Handler(BaseHTTPRequestHandler):
    def _ratelimit_headers(self):
        self.send_header("x-ratelimit-limit-tokens", "8000")
        self.send_header("x-ratelimit-remaining-tokens", "7000")
        self.send_header("x-ratelimit-reset-tokens", "1m0s")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        shape = pick_shape()
        print(f"[stub] serving shape={shape}", flush=True)

        if shape == "hangup":
            # Headers promise a body that never arrives, then the socket closes.
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.close_connection = True
            return

        bodies = {
            "empty": b"",
            "headers-only": b"",
            "whitespace": b"\r\n\r\n",
            "null": b"null",
            "scalar": b"5",
            "truncated": b'{"choices":[{"message":{"content":"half an ans',
            "html": b"<html><head><title>502 Bad Gateway</title></head><body>502</body></html>",
            "ok": json.dumps({"id": "stub", "object": "chat.completion", "model": "stub-model",
                              "choices": [{"index": 0,
                                           "message": {"role": "assistant", "content": OK_CONTENT},
                                           "finish_reason": "stop"}]}).encode(),
        }
        payload = bodies[shape]
        content_type = "text/html" if shape == "html" else "application/json"

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        if shape == "headers-only":
            self._ratelimit_headers()
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def do_GET(self):
        payload = json.dumps({"object": "list", "data": [{"id": "stub-model", "object": "model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"[stub] listening on http://127.0.0.1:{PORT}  "
          f"{'empty once then ok' if HEAL else 'cycling every shape' if CYCLE else 'shape=' + SHAPE}",
          flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
