"""把 GitHub Release 的最新未签名 IPA 同步到本机目录。

公开仓库，无需 token。仅当 Release 的 SHA-256 与本地文件一致时跳过，
否则下载到临时文件、校验后再原子替换，避免拿到半个文件。

用法: python scripts/sync_ipa.py [目标目录，默认 Z:\\iOS]
"""
import hashlib
import json
import os
import shutil
import sys
import urllib.request

REPO = "mionmiao/homecam"
TAG = "ios-unsigned"
IPA_NAME = "HomeCamCamera.ipa"
DEST_DIR = sys.argv[1] if len(sys.argv) > 1 else r"Z:\iOS"
DEST = os.path.join(DEST_DIR, IPA_NAME)
TMP = DEST + ".download"
UA = {"User-Agent": "homecam-ipa-sync"}


def api(url, accept="application/vnd.github+json"):
    req = urllib.request.Request(url, headers={**UA, "Accept": accept})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    rel = json.loads(api(f"https://api.github.com/repos/{REPO}/releases/tags/{TAG}"))
    assets = {a["name"]: a for a in rel["assets"]}
    if IPA_NAME not in assets or IPA_NAME + ".sha256" not in assets:
        raise SystemExit("Release 缺少 IPA 或 sha256 资产")

    expected = api(
        f"https://api.github.com/repos/{REPO}/releases/assets/{assets[IPA_NAME + '.sha256']['id']}",
        accept="application/octet-stream",
    ).decode().split()[0].strip()

    if os.path.exists(DEST) and sha256(DEST) == expected:
        print(f"UP_TO_DATE {expected[:12]} {DEST}")
        return

    os.makedirs(DEST_DIR, exist_ok=True)
    data = api(
        f"https://api.github.com/repos/{REPO}/releases/assets/{assets[IPA_NAME]['id']}",
        accept="application/octet-stream",
    )
    with open(TMP, "wb") as f:
        f.write(data)
    if sha256(TMP) != expected:
        os.remove(TMP)
        raise SystemExit("SHA256 校验失败，已丢弃下载文件")
    shutil.move(TMP, DEST)
    print(f"UPDATED {expected[:12]} {len(data)} bytes -> {DEST}")


if __name__ == "__main__":
    main()
