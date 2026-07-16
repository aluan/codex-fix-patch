#!/usr/bin/env python3

import argparse
import base64
import http.client
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


TOOL_VERSION = "1.1.0"
HEALTH_PATH = "/_codex_imagegen_patch/health"
MAX_REQUEST_BYTES = 100 * 1024 * 1024
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class ConfigError(RuntimeError):
    pass


def parse_toml_string(raw_value):
    value = raw_value.strip()
    if value.startswith('"'):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError as error:
            raise ConfigError("无法解析 TOML 字符串") from error
        if not isinstance(parsed, str):
            raise ConfigError("TOML 配置值不是字符串")
        return parsed
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    raise ConfigError("仅支持字符串形式的 Codex 配置值")


def find_top_level_string(lines, key):
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$")
    for line in lines:
        if line.lstrip().startswith("["):
            break
        match = pattern.match(line)
        if match:
            return parse_toml_string(match.group(1))
    raise ConfigError(f"Codex 配置缺少顶层 `{key}`")


def provider_section_name(line):
    match = re.match(
        r'^\s*\[model_providers\.(?:"([^"]+)"|([A-Za-z0-9_-]+))\]\s*$', line
    )
    if not match:
        return None
    return match.group(1) or match.group(2)


def find_provider_base_url(lines, provider_name):
    section_start = None
    for index, line in enumerate(lines):
        if provider_section_name(line) == provider_name:
            section_start = index
            break
    if section_start is None:
        raise ConfigError(f"未找到 `[model_providers.{provider_name}]`")

    pattern = re.compile(r"^(\s*base_url\s*=\s*)(.+?)(\s*)$")
    for index in range(section_start + 1, len(lines)):
        line = lines[index]
        if line.lstrip().startswith("["):
            break
        match = pattern.match(line.rstrip("\n"))
        if match:
            return index, parse_toml_string(match.group(2)), match.group(1)
    raise ConfigError(f"Provider `{provider_name}` 缺少 `base_url`")


def find_provider_string(lines, provider_name, key):
    section_start = None
    for index, line in enumerate(lines):
        if provider_section_name(line) == provider_name:
            section_start = index
            break
    if section_start is None:
        raise ConfigError(f"未找到 `[model_providers.{provider_name}]`")
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$")
    for index in range(section_start + 1, len(lines)):
        line = lines[index]
        if line.lstrip().startswith("["):
            break
        match = pattern.match(line)
        if match:
            return parse_toml_string(match.group(1))
    return None


def validate_upstream_url(value):
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ConfigError("上游 base_url 必须是有效的 HTTP(S) URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ConfigError("上游 base_url 不能包含认证信息、查询参数或片段")
    if parsed.hostname in {"127.0.0.1", "localhost", "::1"}:
        raise ConfigError("当前 base_url 已指向本机，无法推断原始上游")
    return parsed


def local_base_url(upstream_base_url, port):
    parsed = validate_upstream_url(upstream_base_url)
    path = parsed.path.rstrip("/")
    return f"http://127.0.0.1:{port}{path}"


def inspect_config(config_path, port, bridge_model=None):
    path = Path(config_path).expanduser().resolve()
    try:
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    except OSError as error:
        raise ConfigError(f"无法读取 Codex 配置：{path}") from error
    provider_name = find_top_level_string(lines, "model_provider")
    model = bridge_model or find_top_level_string(lines, "model")
    base_url_index, upstream_base_url, base_url_prefix = find_provider_base_url(
        lines, provider_name
    )
    validate_upstream_url(upstream_base_url)
    return {
        "config_path": str(path),
        "provider_name": provider_name,
        "bridge_model": model,
        "upstream_base_url": upstream_base_url.rstrip("/"),
        "local_base_url": local_base_url(upstream_base_url, port),
        "port": port,
        "base_url_index": base_url_index,
        "base_url_prefix": base_url_prefix,
        "lines": lines,
    }


def atomic_write_text(path, text, mode=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if mode is not None:
            os.chmod(temp_path, mode)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def install_config(config_path, state_path, port, bridge_model=None):
    state_file = Path(state_path).expanduser().resolve()
    if state_file.exists():
        state = json.loads(state_file.read_text(encoding="utf-8"))
        status = config_status(state_file)
        if status["configured"]:
            if int(state["port"]) != int(port):
                raise ConfigError(
                    "更改已安装代理端口前请先卸载，再使用新的 --port 重新安装"
                )
            state["tool_version"] = TOOL_VERSION
            if bridge_model:
                state["bridge_model"] = bridge_model
            atomic_write_text(
                state_file,
                json.dumps(state, ensure_ascii=False, indent=2) + "\n",
                0o600,
            )
            return state
        raise ConfigError("发现已有状态文件，但 Codex 配置与之不一致；请先卸载或修复")

    info = inspect_config(config_path, port, bridge_model)
    config_file = Path(info["config_path"])
    timestamp = time.strftime("%Y%m%d%H%M%S")
    backup_path = config_file.with_name(
        f"{config_file.name}.codex-imagegen-patch.{timestamp}.bak"
    )
    shutil.copy2(config_file, backup_path)

    lines = info.pop("lines")
    base_url_index = info.pop("base_url_index")
    base_url_prefix = info.pop("base_url_prefix")
    newline = "\n" if lines[base_url_index].endswith("\n") else ""
    lines[base_url_index] = (
        f"{base_url_prefix}{json.dumps(info['local_base_url'])}{newline}"
    )
    atomic_write_text(config_file, "".join(lines), config_file.stat().st_mode & 0o777)

    state = {
        "tool_version": TOOL_VERSION,
        "installed_at": int(time.time()),
        "backup_path": str(backup_path),
        **info,
    }
    atomic_write_text(state_file, json.dumps(state, ensure_ascii=False, indent=2) + "\n", 0o600)
    return state


def current_provider_base_url(config_path, provider_name):
    path = Path(config_path)
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    _, base_url, _ = find_provider_base_url(lines, provider_name)
    return base_url.rstrip("/")


def config_status(state_path):
    state_file = Path(state_path).expanduser().resolve()
    if not state_file.exists():
        return {"configured": False, "reason": "状态文件不存在"}
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
        current = current_provider_base_url(
            state["config_path"], state["provider_name"]
        )
    except (OSError, KeyError, ValueError, ConfigError) as error:
        return {"configured": False, "reason": str(error)}
    expected = state["local_base_url"].rstrip("/")
    return {
        "configured": current == expected,
        "current_base_url": current,
        "expected_base_url": expected,
        "provider_name": state["provider_name"],
        "bridge_model": state["bridge_model"],
        "port": state["port"],
    }


def uninstall_config(state_path):
    state_file = Path(state_path).expanduser().resolve()
    if not state_file.exists():
        return {"restored": False, "reason": "状态文件不存在"}
    state = json.loads(state_file.read_text(encoding="utf-8"))
    config_file = Path(state["config_path"])
    lines = config_file.read_text(encoding="utf-8").splitlines(keepends=True)
    index, current, prefix = find_provider_base_url(lines, state["provider_name"])
    if current.rstrip("/") != state["local_base_url"].rstrip("/"):
        return {
            "restored": False,
            "reason": "当前 base_url 已被用户修改，未自动覆盖",
            "current_base_url": current,
        }
    newline = "\n" if lines[index].endswith("\n") else ""
    lines[index] = f"{prefix}{json.dumps(state['upstream_base_url'])}{newline}"
    atomic_write_text(config_file, "".join(lines), config_file.stat().st_mode & 0o777)
    state_file.unlink()
    return {"restored": True, "base_url": state["upstream_base_url"]}


def provider_bearer_token(config_path, provider_name):
    lines = Path(config_path).read_text(encoding="utf-8").splitlines(keepends=True)
    token = find_provider_string(lines, provider_name, "experimental_bearer_token")
    if token:
        return token
    env_key = find_provider_string(lines, provider_name, "env_key")
    if env_key:
        token = os.environ.get(env_key)
        if token:
            return token
        raise ConfigError(f"环境变量 `{env_key}` 未设置，无法执行自检")
    raise ConfigError(
        "自检目前支持 experimental_bearer_token 或 env_key 认证；代理运行本身不受影响"
    )


def self_test(state_path, output_path):
    state = json.loads(Path(state_path).expanduser().read_text(encoding="utf-8"))
    token = provider_bearer_token(state["config_path"], state["provider_name"])
    endpoint = f"{state['local_base_url'].rstrip('/')}/images/generations"
    body = json.dumps(
        {
            "prompt": "A minimal test image: one solid blue circle centered on a plain white square background, no text.",
            "model": "gpt-image-2",
            "quality": "auto",
            "size": "auto",
            "background": "auto",
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "originator": "codex_chatgpt_desktop",
            "User-Agent": f"codex_chatgpt_desktop/{TOOL_VERSION} codex-imagegen-proxy-self-test",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=360) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        message = error.read().decode("utf-8", "replace")[:2000]
        raise ConfigError(f"自检请求失败（HTTP {error.code}）：{message}") from error
    try:
        image = base64.b64decode(payload["data"][0]["b64_json"], validate=True)
    except (KeyError, IndexError, TypeError, ValueError) as error:
        raise ConfigError("自检响应不包含有效的 b64_json") from error
    if not image.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ConfigError("自检响应不是 PNG")
    output = Path(output_path).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(image)
    return output


def filtered_request_headers(headers):
    result = {}
    for name, value in headers.items():
        lower = name.lower()
        if lower in HOP_BY_HOP_HEADERS or lower in {"host", "content-length"}:
            continue
        result[name] = value
    return result


def upstream_connection(parsed, timeout=600):
    port = parsed.port
    if parsed.scheme == "https":
        return http.client.HTTPSConnection(parsed.hostname, port or 443, timeout=timeout)
    return http.client.HTTPConnection(parsed.hostname, port or 80, timeout=timeout)


def find_image_result(value):
    if isinstance(value, dict):
        if value.get("type") == "image_generation_call":
            result = value.get("result")
            if isinstance(result, str) and result:
                return result
        for nested in value.values():
            result = find_image_result(nested)
            if result:
                return result
    elif isinstance(value, list):
        for nested in value:
            result = find_image_result(nested)
            if result:
                return result
    return None


def response_diagnostic(value):
    if isinstance(value, list):
        return [response_diagnostic(item) for item in value[:10]]
    if not isinstance(value, dict):
        return type(value).__name__
    diagnostic = {"keys": sorted(value.keys())}
    for key in ("type", "status", "error"):
        if key in value:
            diagnostic[key] = value[key]
    if "output" in value:
        diagnostic["output"] = response_diagnostic(value["output"])
    if "item" in value:
        diagnostic["item"] = response_diagnostic(value["item"])
    if "response" in value:
        diagnostic["response"] = response_diagnostic(value["response"])
    return diagnostic


def parse_upstream_response(body, content_type):
    text = body.decode("utf-8")
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        return json.loads(text)
    if "text/event-stream" not in content_type.lower():
        return json.loads(text)
    events = []
    for line in text.splitlines():
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            events.append(json.loads(payload))
        except json.JSONDecodeError:
            continue
    return events


class ProxyServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, state):
        self.state = state
        self.upstream = urlsplit(state["upstream_base_url"])
        super().__init__(address, handler)


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def do_GET(self):
        if urlsplit(self.path).path == HEALTH_PATH:
            self.send_json(
                200,
                {
                    "ok": True,
                    "tool_version": TOOL_VERSION,
                    "bridge_model": self.server.state["bridge_model"],
                },
            )
            return
        self.forward_request()

    def do_POST(self):
        path = urlsplit(self.path).path.rstrip("/")
        if path.endswith("/images/generations"):
            self.bridge_image_request(edit=False)
            return
        if path.endswith("/images/edits"):
            self.bridge_image_request(edit=True)
            return
        self.forward_request()

    def do_PUT(self):
        self.forward_request()

    def do_PATCH(self):
        self.forward_request()

    def do_DELETE(self):
        self.forward_request()

    def do_OPTIONS(self):
        self.forward_request()

    def read_body(self):
        raw_length = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_length)
        except ValueError as error:
            raise ConfigError("无效的 Content-Length") from error
        if length < 0 or length > MAX_REQUEST_BYTES:
            raise ConfigError("请求正文超过 100 MiB 限制")
        return self.rfile.read(length) if length else b""

    def upstream_target(self, path=None):
        requested = urlsplit(path or self.path)
        target = requested.path or "/"
        if requested.query:
            target += f"?{requested.query}"
        return target

    def responses_target(self):
        base_path = self.server.upstream.path.rstrip("/")
        return f"{base_path}/responses"

    def forward_request(self):
        try:
            body = self.read_body()
            headers = filtered_request_headers(self.headers)
            if body:
                headers["Content-Length"] = str(len(body))
            connection = upstream_connection(self.server.upstream)
            connection.request(
                self.command,
                self.upstream_target(),
                body=body if body else None,
                headers=headers,
            )
            response = connection.getresponse()
            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                lower = name.lower()
                if lower in HOP_BY_HOP_HEADERS or lower == "content-length":
                    continue
                self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
            self.close_connection = True
            connection.close()
        except Exception as error:
            self.send_proxy_error(502, f"上游转发失败：{error}")

    def bridge_image_request(self, edit):
        try:
            request = json.loads(self.read_body().decode("utf-8"))
            prompt = request.get("prompt")
            if not isinstance(prompt, str) or not prompt.strip():
                raise ConfigError("Images 请求缺少 prompt")
            content = [{"type": "input_text", "text": prompt}]
            if edit:
                images = request.get("images") or []
                for image in images:
                    image_url = image.get("image_url") if isinstance(image, dict) else None
                    if isinstance(image_url, str) and image_url:
                        content.append(
                            {"type": "input_image", "image_url": image_url, "detail": "high"}
                        )
            payload = {
                "model": self.server.state["bridge_model"],
                "input": [{"role": "user", "content": content}],
                "tools": [{"type": "image_generation", "output_format": "png"}],
                "tool_choice": {"type": "image_generation"},
                "stream": False,
                "store": False,
            }
            encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers = filtered_request_headers(self.headers)
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/json"
            headers["Accept-Encoding"] = "identity"
            headers["Content-Length"] = str(len(encoded))
            connection = upstream_connection(self.server.upstream)
            connection.request(
                "POST", self.responses_target(), body=encoded, headers=headers
            )
            response = connection.getresponse()
            response_body = response.read()
            content_type = response.getheader("Content-Type", "application/json")
            connection.close()
            if response.status < 200 or response.status >= 300:
                self.send_raw(response.status, response_body, content_type)
                return
            parsed = parse_upstream_response(response_body, content_type)
            result = find_image_result(parsed)
            if not result:
                diagnostic = json.dumps(response_diagnostic(parsed), ensure_ascii=False)
                raise ConfigError(
                    "Responses 返回中没有 image_generation_call.result；"
                    f"content-type={content_type} bytes={len(response_body)} "
                    f"结构={diagnostic}"
                )
            now = int(time.time())
            output = {"created": now, "data": [{"b64_json": result}]}
            for key in ("background", "quality", "size"):
                value = request.get(key)
                if value is not None:
                    output[key] = value
            self.send_json(200, output)
        except ConfigError as error:
            self.send_proxy_error(502, str(error))
        except (ValueError, OSError, http.client.HTTPException) as error:
            self.send_proxy_error(502, f"生图桥接失败：{error}")

    def send_raw(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def send_json(self, status, value):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_raw(status, body, "application/json; charset=utf-8")

    def send_proxy_error(self, status, message):
        if self.wfile.closed:
            return
        try:
            self.send_json(
                status,
                {
                    "error": {
                        "message": message,
                        "type": "codex_imagegen_proxy_error",
                    }
                },
            )
        except (BrokenPipeError, ConnectionResetError):
            return


def serve(state_path):
    state = json.loads(Path(state_path).expanduser().read_text(encoding="utf-8"))
    validate_upstream_url(state["upstream_base_url"])
    port = int(state["port"])
    if not 1024 <= port <= 65535:
        raise ConfigError("代理端口必须在 1024 到 65535 之间")
    server = ProxyServer(("127.0.0.1", port), ProxyHandler, state)
    print(
        f"[codex-imagegen-proxy] listening on 127.0.0.1:{port}",
        file=sys.stderr,
        flush=True,
    )
    server.serve_forever(poll_interval=0.5)


def safe_state(state):
    return {
        key: state[key]
        for key in (
            "tool_version",
            "config_path",
            "provider_name",
            "bridge_model",
            "upstream_base_url",
            "local_base_url",
            "port",
            "backup_path",
        )
        if key in state
    }


def build_parser():
    parser = argparse.ArgumentParser(description="Codex ImageGen local compatibility proxy")
    parser.add_argument("--version", action="version", version=TOOL_VERSION)
    subparsers = parser.add_subparsers(dest="command", required=True)

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--state", required=True)

    inspect_parser = subparsers.add_parser("config-inspect")
    inspect_parser.add_argument("--config", required=True)
    inspect_parser.add_argument("--port", type=int, default=17891)
    inspect_parser.add_argument("--bridge-model")

    install_parser = subparsers.add_parser("config-install")
    install_parser.add_argument("--config", required=True)
    install_parser.add_argument("--state", required=True)
    install_parser.add_argument("--port", type=int, default=17891)
    install_parser.add_argument("--bridge-model")

    status_parser = subparsers.add_parser("config-status")
    status_parser.add_argument("--state", required=True)

    uninstall_parser = subparsers.add_parser("config-uninstall")
    uninstall_parser.add_argument("--state", required=True)

    state_parser = subparsers.add_parser("print-state")
    state_parser.add_argument("--state", required=True)

    test_parser = subparsers.add_parser("self-test")
    test_parser.add_argument("--state", required=True)
    test_parser.add_argument("--output", required=True)
    return parser


def main():
    args = build_parser().parse_args()
    try:
        if args.command == "serve":
            serve(args.state)
            return 0
        if args.command == "config-inspect":
            info = inspect_config(args.config, args.port, args.bridge_model)
            info.pop("lines")
            info.pop("base_url_index")
            info.pop("base_url_prefix")
            print(json.dumps(info, ensure_ascii=False, indent=2))
            return 0
        if args.command == "config-install":
            state = install_config(
                args.config, args.state, args.port, args.bridge_model
            )
            print(json.dumps(safe_state(state), ensure_ascii=False, indent=2))
            return 0
        if args.command == "config-status":
            status = config_status(args.state)
            print(json.dumps(status, ensure_ascii=False, indent=2))
            return 0 if status.get("configured") else 1
        if args.command == "config-uninstall":
            result = uninstall_config(args.state)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0 if result.get("restored") or result.get("reason") == "状态文件不存在" else 2
        if args.command == "print-state":
            state = json.loads(
                Path(args.state).expanduser().read_text(encoding="utf-8")
            )
            print(json.dumps(safe_state(state), ensure_ascii=False, indent=2))
            return 0
        if args.command == "self-test":
            output = self_test(args.state, args.output)
            print(output)
            return 0
    except (ConfigError, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"[codex-imagegen-proxy] 错误：{error}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
