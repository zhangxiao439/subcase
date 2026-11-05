#!/usr/bin/env python3
"""把固定 keystore 写入 GitHub Actions Secrets。

GitHub 要求用仓库的 libsodium public key 对明文做 sealed box 加密，
再以 base64 提交。这里用 pynacl 的 SealedBox 完成。

用法：
    python3 tools/set_secrets.py <keystore路径> <alias> <storepass>
环境变量：
    GITHUB_TOKEN
    GITHUB_REPO   形如 owner/repo
"""
import base64
import json
import os
import subprocess
import sys
import time

from nacl.public import PublicKey, SealedBox
from nacl.encoding import Base64Encoder

API = "https://api.github.com"


def req(method, url, data=None):
    """走 curl 子进程：Python 内置 ssl 在本机会抛 UNEXPECTED_EOF，curl 稳定。"""
    cmd = [
        "curl", "-sS", "--retry", "3", "--retry-delay", "2",
        "--max-time", "40",
        "-w", "\n%{http_code}",
        "-X", method,
        "-H", "Authorization: Bearer " + os.environ["GITHUB_TOKEN"],
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2022-11-28",
    ]
    if data is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(data)]
    cmd.append(url)

    last = None
    for attempt in range(4):
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        except Exception as e:
            last = e
            time.sleep(2 * (attempt + 1))
            continue
        out = p.stdout
        if "\n" not in out:
            last = RuntimeError("bad output: " + out[:200])
            time.sleep(2 * (attempt + 1))
            continue
        body, _, code = out.rpartition("\n")
        try:
            status = int(code.strip())
        except ValueError:
            last = RuntimeError("bad status: " + code[:80])
            time.sleep(2 * (attempt + 1))
            continue
        if status >= 500:
            last = RuntimeError(f"{status}: {body[:200]}")
            time.sleep(2 * (attempt + 1))
            continue
        try:
            return status, (json.loads(body) if body.strip() else {})
        except Exception:
            return status, body
    raise RuntimeError(f"request failed after retries: {last}")


def seal(public_key_b64, plaintext: bytes) -> str:
    pk = PublicKey(public_key_b64.encode(), encoder=Base64Encoder)
    sealed = SealedBox(pk).encrypt(plaintext)
    return base64.b64encode(sealed).decode()


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    keystore_path, alias, password = sys.argv[1], sys.argv[2], sys.argv[3]
    repo = os.environ.get("GITHUB_REPO", "zhangxiao439/subcase")

    with open(keystore_path, "rb") as f:
        keystore_bytes = f.read()
    keystore_b64 = base64.b64encode(keystore_bytes).decode()

    st, pk = req("GET", f"{API}/repos/{repo}/actions/secrets/public-key")
    if st != 200:
        print("!! 取 public key 失败:", st, pk)
        return 1
    key_id, key_b64 = pk["key_id"], pk["key"]

    secrets = {
        "KEYSTORE": keystore_b64,
        "KEYSTORE_PASSWORD": password,
        "KEY_ALIAS": alias,
        "KEY_PASSWORD": password,
    }

    for name, value in secrets.items():
        st, body = req(
            "PUT",
            f"{API}/repos/{repo}/actions/secrets/{name}",
            {"encrypted_value": seal(key_b64, value.encode()), "key_id": key_id},
        )
        if st in (201, 204):
            print(f"  ok  {name}")
        else:
            print(f"!! {name} 失败:", st, body)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
