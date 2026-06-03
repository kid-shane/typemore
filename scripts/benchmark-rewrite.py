#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


SAMPLE_TEXT = (
    "最近我们在整理 Typemore 的使用体验时，发现一个看似很小但实际影响很大的问题："
    "用户在聊天、文档或者邮件里写下一段内容后，往往只是希望快速把表达变得更清楚、更自然，"
    "而不是打开一个新的网页、复制文本、等待模型返回、再手动粘贴回原来的地方。"
    "如果这个过程超过几秒钟，用户就会明显感到被打断。因此，我们需要验证在两三百字的真实文本场景下，"
    "模型接口是否会稳定返回，以及耗时主要集中在网络请求、模型生成还是本地处理流程中。"
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def settings_paths() -> list[Path]:
    return [
        Path.home() / "Library/Application Support/Typemore/settings.json",
        repo_root() / ".typemore/settings.json",
    ]


def load_settings() -> dict:
    for path in settings_paths():
        if path.exists():
            with path.open("r", encoding="utf-8") as file:
                return json.load(file)
    return {}


def env_or_setting(env_name: str, settings: dict, key: str, default: str = "") -> str:
    return os.environ.get(env_name) or str(settings.get(key) or default)


def chat_completions_endpoint(base_url: str) -> str:
    value = base_url.strip().rstrip("/")
    if not value:
        value = "https://ark.cn-beijing.volces.com/api/v3"
    if value.endswith("/chat/completions"):
        return value
    return f"{value}/chat/completions"


def dynamic_timeout(text: str) -> int:
    if len(text) < 80:
        return 35
    if len(text) < 400:
        return 60
    if len(text) < 1200:
        return 90
    return 120


def max_output_tokens(text: str) -> int:
    estimated_input_tokens = max(24, len(text) // 2)
    return min(900, max(96, estimated_input_tokens * 2 + 48))


def build_payload(model: str, text: str) -> dict:
    system_prompt = (
        "Rewrite the text to be clearer, accurate, and natural. "
        "Preserve the original meaning, facts, tone, names, numbers, and links.\n\n"
        "Return only the rewritten text.\n"
        "Do not explain, label, quote, or wrap the result.\n"
        "If no change is needed, return the source text exactly."
    )
    user_prompt = "Make it clearer and easier to understand.\n\nText:\n\n" + text
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.2,
        "max_tokens": max_output_tokens(text),
    }


def read_text(args: argparse.Namespace) -> str:
    if args.text:
        return args.text
    if args.text_file:
        return Path(args.text_file).read_text(encoding="utf-8").strip()
    return SAMPLE_TEXT


def request_once(endpoint: str, api_key: str, model: str, text: str, timeout: int) -> tuple[int, str, float]:
    payload = json.dumps(build_payload(model, text), ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )

    started_at = time.perf_counter()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode("utf-8")
        duration_ms = (time.perf_counter() - started_at) * 1000
        return response.status, body, duration_ms


def extract_preview(response_body: str) -> str:
    try:
        decoded = json.loads(response_body)
        content = decoded["choices"][0]["message"]["content"]
        if isinstance(content, list):
            content = "".join(part.get("text", "") for part in content)
        return str(content).strip().replace("\n", " ")[:160]
    except Exception:
        return response_body.strip().replace("\n", " ")[:160]


def safe_error_message(body: str) -> str:
    try:
        decoded = json.loads(body)
        message = decoded.get("error", {}).get("message") or decoded.get("message") or ""
        return str(message).replace("\n", " ")[:180]
    except Exception:
        return ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark Typemore rewrite API with a 200-300 Chinese character sample.")
    parser.add_argument("--text", help="Custom text to rewrite.")
    parser.add_argument("--text-file", help="Read custom text from a UTF-8 file.")
    parser.add_argument("--repeat", type=int, default=1, help="Number of requests to send.")
    parser.add_argument("--timeout", type=int, help="Override request timeout in seconds.")
    args = parser.parse_args()

    settings = load_settings()
    base_url = env_or_setting("TYPEMORE_BASE_URL", settings, "endpoint", "https://ark.cn-beijing.volces.com/api/v3")
    model = env_or_setting("TYPEMORE_MODEL", settings, "model", "deepseek-v4-pro")
    api_key = env_or_setting("TYPEMORE_API_KEY", settings, "apiKey")
    text = read_text(args)
    timeout = args.timeout or dynamic_timeout(text)
    endpoint = chat_completions_endpoint(base_url)

    if not api_key:
        print("Missing API key. Configure Typemore settings or set TYPEMORE_API_KEY.", file=sys.stderr)
        return 1

    print(f"Text chars: {len(text)}")
    print(f"Endpoint: {endpoint}")
    print(f"Model: {model}")
    print(f"Timeout: {timeout}s")
    print(f"Repeat: {args.repeat}")

    durations = []
    for index in range(1, args.repeat + 1):
        try:
            status, body, duration_ms = request_once(endpoint, api_key, model, text, timeout)
            durations.append(duration_ms)
            print(f"[{index}] status={status} duration={duration_ms:.0f}ms preview={extract_preview(body)}")
        except TimeoutError:
            print(f"[{index}] TIMEOUT after {timeout}s")
            return 2
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            print(f"[{index}] HTTP_ERROR status={error.code} message={safe_error_message(body)}", file=sys.stderr)
            return 4
        except urllib.error.URLError as error:
            reason = getattr(error, "reason", error)
            if isinstance(reason, TimeoutError):
                print(f"[{index}] TIMEOUT after {timeout}s")
                return 2
            print(f"[{index}] URL_ERROR {reason}", file=sys.stderr)
            return 3

    if durations:
        avg = sum(durations) / len(durations)
        print(f"Average: {avg:.0f}ms")
        print(f"Min/Max: {min(durations):.0f}ms / {max(durations):.0f}ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
