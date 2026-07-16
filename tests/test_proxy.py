import http.client
import json
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from proxy.codex_imagegen_proxy import ProxyHandler
from proxy.codex_imagegen_proxy import ProxyServer
from proxy.codex_imagegen_proxy import TOOL_VERSION
from proxy.codex_imagegen_proxy import config_status
from proxy.codex_imagegen_proxy import install_config
from proxy.codex_imagegen_proxy import parse_upstream_response
from proxy.codex_imagegen_proxy import provider_bearer_token
from proxy.codex_imagegen_proxy import uninstall_config


class UpstreamHandler(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, _format, *_args):
        return

    def read_body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def do_GET(self):
        self.__class__.requests.append(("GET", self.path, b"", dict(self.headers)))
        body = b'{"models":[]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.read_body()
        self.__class__.requests.append(("POST", self.path, body, dict(self.headers)))
        if self.path == "/api/responses":
            response = {
                "output": [
                    {
                        "type": "image_generation_call",
                        "status": "completed",
                        "result": "iVBORw0KGgo=",
                    }
                ]
            }
        else:
            response = {"ok": True}
        encoded = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class ProxyTest(unittest.TestCase):
    def setUp(self):
        UpstreamHandler.requests = []
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
        self.upstream_thread = threading.Thread(
            target=self.upstream.serve_forever, daemon=True
        )
        self.upstream_thread.start()
        upstream_url = f"http://127.0.0.2:{self.upstream.server_port}/api"
        state = {
            "upstream_base_url": upstream_url.replace("127.0.0.2", "127.0.0.1"),
            "bridge_model": "gpt-test",
            "port": 17891,
        }
        self.proxy = ProxyServer(("127.0.0.1", 0), ProxyHandler, state)
        self.proxy_thread = threading.Thread(target=self.proxy.serve_forever, daemon=True)
        self.proxy_thread.start()

    def tearDown(self):
        self.proxy.shutdown()
        self.proxy.server_close()
        self.upstream.shutdown()
        self.upstream.server_close()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.proxy.server_port, timeout=5
        )
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, data

    def test_transparently_forwards_regular_requests(self):
        status, body = self.request("GET", "/api/models?client_version=1")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"models": []})
        method, path, _, _ = UpstreamHandler.requests[-1]
        self.assertEqual((method, path), ("GET", "/api/models?client_version=1"))

    def test_bridges_images_generation_to_responses(self):
        request = json.dumps(
            {
                "prompt": "a puppy",
                "model": "gpt-image-2",
                "quality": "auto",
                "size": "auto",
            }
        ).encode()
        status, body = self.request(
            "POST",
            "/api/images/generations",
            request,
            {"Content-Type": "application/json", "Authorization": "Bearer test"},
        )
        self.assertEqual(status, 200)
        response = json.loads(body)
        self.assertEqual(response["data"][0]["b64_json"], "iVBORw0KGgo=")
        method, path, upstream_body, headers = UpstreamHandler.requests[-1]
        self.assertEqual((method, path), ("POST", "/api/responses"))
        payload = json.loads(upstream_body)
        self.assertEqual(payload["model"], "gpt-test")
        self.assertEqual(payload["tools"][0]["type"], "image_generation")
        self.assertEqual(headers["Authorization"], "Bearer test")


class ConfigTest(unittest.TestCase):
    def test_installer_and_proxy_versions_match(self):
        installer = Path("install-codex-imagegen-patch.sh").read_text()
        self.assertIn(f'TOOL_VERSION="{TOOL_VERSION}"', installer)

    def test_install_status_and_uninstall_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.toml"
            state = root / "state.json"
            original = (
                'model_provider = "relay"\n'
                'model = "gpt-test"\n\n'
                '[model_providers.relay]\n'
                'base_url = "https://relay.example/api"\n'
                'wire_api = "responses"\n'
            )
            config.write_text(original)
            installed = install_config(config, state, 17891)
            self.assertEqual(installed["bridge_model"], "gpt-test")
            self.assertIn("http://127.0.0.1:17891/api", config.read_text())
            self.assertTrue(config_status(state)["configured"])
            result = uninstall_config(state)
            self.assertTrue(result["restored"])
            self.assertEqual(config.read_text(), original)

    def test_parses_json_even_when_upstream_mislabels_it_as_event_stream(self):
        body = json.dumps(
            {"output": [{"type": "image_generation_call", "result": "png"}]}
        ).encode()
        parsed = parse_upstream_response(body, "text/event-stream")
        self.assertEqual(parsed["output"][0]["result"], "png")

    def test_reads_provider_bearer_token_without_persisting_it(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            config.write_text(
                '[model_providers.relay]\nexperimental_bearer_token = "secret"\n'
            )
            self.assertEqual(provider_bearer_token(config, "relay"), "secret")


if __name__ == "__main__":
    unittest.main()
