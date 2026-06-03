#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional


BASE_TEXT = (
    "今天我们继续验证 Typemore 的长文本改写体验。用户在飞书、浏览器、文档或邮件里输入一段内容时，"
    "通常希望它能在当前编辑位置快速完成润色，而不是打断工作流。一个理想的改写工具应该先稳定读取选中文本，"
    "再把文本发送给模型服务，并在模型返回后尽快粘贴回原处。为了判断慢点是否集中在模型请求阶段，"
    "这个脚本会构造三百字左右的真实中文文本，使用本地配置里的 Base URL、Model 和 API Key 发起请求，"
    "并打印各个阶段的耗时。这样我们可以区分本地处理、请求编码、网络传输、模型生成和响应解析分别花了多久。"
)


def now() -> float:
    return time.perf_counter()


def ms(start: float, end: Optional[float] = None) -> float:
    return ((end or now()) - start) * 1000


def log(stage: str, duration_ms: float) -> None:
    print(f"[Typemore][bench300] {stage}: {duration_ms:.0f}ms")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def exact_300_text() -> str:
    filler = "本次测试重点关注端到端响应速度和模型接口稳定性。"
    text = BASE_TEXT
    while len(text) < 300:
        text += filler
    return text[:300]


def load_settings() -> dict:
    for path in [
        Path.home() / "Library/Application Support/Typemore/settings.json",
        repo_root() / ".typemore/settings.json",
    ]:
        if path.exists():
            with path.open("r", encoding="utf-8") as file:
                return json.load(file)
    return {}


def value(settings: dict, env_name: str, key: str, default: str = "") -> str:
    return os.environ.get(env_name) or str(settings.get(key) or default)


def endpoint_from(base_url: str) -> str:
    endpoint = base_url.strip().rstrip("/") or "https://ark.cn-beijing.volces.com/api/v3"
    if endpoint.endswith("/chat/completions"):
        return endpoint
    return f"{endpoint}/chat/completions"


def max_output_tokens(text: str) -> int:
    estimated_input_tokens = max(24, len(text) // 2)
    return min(900, max(96, estimated_input_tokens * 2 + 48))


def timeout_for(text: str) -> int:
    if len(text) < 80:
        return 35
    if len(text) < 400:
        return 60
    if len(text) < 1200:
        return 90
    return 120


def build_payload(model: str, text: str, thinking: str) -> dict:
    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Rewrite the text to be clearer, accurate, and natural. "
                    "Preserve the original meaning, facts, tone, names, numbers, and links.\n\n"
                    "Return only the rewritten text.\n"
                    "Do not explain, label, quote, or wrap the result.\n"
                    "If no change is needed, return the source text exactly."
                ),
            },
            {
                "role": "user",
                "content": "Make it clearer and easier to understand.\n\nText:\n\n" + text,
            },
        ],
        "temperature": 0.2,
        "max_tokens": max_output_tokens(text),
    }
    if thinking != "none":
        payload["thinking"] = {"type": thinking}
    return payload


def response_preview(body: str) -> tuple[str, int]:
    decoded = json.loads(body)
    content = decoded["choices"][0]["message"]["content"]
    if isinstance(content, list):
        content = "".join(part.get("text", "") for part in content)
    text = str(content)
    return text.strip().replace("\n", " ")[:180], len(text)


def safe_error_message(body: str) -> str:
    try:
        decoded = json.loads(body)
        message = decoded.get("error", {}).get("message") or decoded.get("message") or ""
        return str(message).replace("\n", " ")[:180]
    except Exception:
        return ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark Typemore with an exact 300-character text.")
    parser.add_argument(
        "--thinking",
        choices=["none", "disabled", "enabled", "auto"],
        default="none",
        help="Thinking mode field to send. 'none' keeps the original payload unchanged.",
    )
    args = parser.parse_args()

    total_start = now()

    stage_start = now()
    settings = load_settings()
    base_url = value(settings, "TYPEMORE_BASE_URL", "endpoint", "https://ark.cn-beijing.volces.com/api/v3")
    model = value(settings, "TYPEMORE_MODEL", "model", "deepseek-v4-pro")
    api_key = value(settings, "TYPEMORE_API_KEY", "apiKey")
    text = exact_300_text()
    endpoint = endpoint_from(base_url)
    timeout = timeout_for(text)
    log("load settings", ms(stage_start))

    if not api_key:
        print("Missing API key. Configure Typemore settings or set TYPEMORE_API_KEY.", file=sys.stderr)
        return 1

    print(f"Text chars: {len(text)}")
    print(f"Endpoint: {endpoint}")
    print(f"Model: {model}")
    print(f"Timeout: {timeout}s")
    print(f"Thinking: {args.thinking}")

    stage_start = now()
    payload = build_payload(model, text, args.thinking)
    log("build payload", ms(stage_start))

    stage_start = now()
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    log("encode payload", ms(stage_start))
    print(f"Payload bytes: {len(body)}")

    request = urllib.request.Request(
        endpoint,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )

    stage_start = now()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_body = response.read().decode("utf-8")
            http_duration = ms(stage_start)
            log("http request", http_duration)
            print(f"HTTP status: {response.status}")
            print(f"Response bytes: {len(response_body.encode('utf-8'))}")
    except TimeoutError:
        log("http request", ms(stage_start))
        print(f"TIMEOUT after {timeout}s")
        return 2
    except urllib.error.HTTPError as error:
        log("http request", ms(stage_start))
        error_body = error.read().decode("utf-8", errors="replace")
        print(f"HTTP_ERROR status={error.code} message={safe_error_message(error_body)}", file=sys.stderr)
        return 3
    except urllib.error.URLError as error:
        log("http request", ms(stage_start))
        print(f"URL_ERROR {getattr(error, 'reason', error)}", file=sys.stderr)
        return 4

    stage_start = now()
    preview, output_chars = response_preview(response_body)
    log("decode response", ms(stage_start))
    print(f"Output chars: {output_chars}")
    print(f"Preview: {preview}")
    log("total", ms(total_start))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
