"""把 GitHub Release 的最新 Android Debug APK 同步到本机目录。

公开仓库，无需 token。仅当 Release 的 SHA-256 与本地文件一致时跳过，
否则下载到临时文件、校验后再原子替换，避免拿到半个文件。

用法: python scripts/sync_apk.py [目标目录，默认 Z:\\Android]
"""
import hashlib
import json
import os
import shutil
import sys
import urllib.request

REPO = "mionmiao/homecam"
TAG = "android-debug"
APK_NAME = "HomeCamCamera-debug.apk"
DEST_DIR = sys.argv[1] if len(sys.argv) > 1 else r"Z:\Android"
DEST = os.path.join(DEST_DIR, "HomeCamCamera.apk")
TMP = DEST + ".download"
UA = {"User-Agent": "homecam-apk-sync"}


def api(url, accept="application/vnd.github+json"):
    req = urllib.request.Request(url, headers={**UA, "Accept": accept})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def download(url, path):
    req = urllib.request.Request(url, headers={**UA, "Accept": "application/octet-stream"})
    with urllib.request.urlopen(req, timeout=180) as r, open(path, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    rel = json.loads(api(f"https://api.github.com/repos/{REPO}/releases/tags/{TAG}"))
    assets = {a["name"]: a for a in rel["assets"]}
    if APK_NAME not in assets:
        raise SystemExit("Release 缺少 APK 资产")

    expected = ""
    if APK_NAME + ".sha256" in assets:
        expected = api(
            f"https://api.github.com/repos/{REPO}/releases/assets/{assets[APK_NAME + '.sha256']['id']}",
            accept="application/octet-stream",
        ).decode().split()[0].strip()
    elif assets[APK_NAME].get("digest", "").startswith("sha256:"):
        expected = assets[APK_NAME]["digest"].split(":", 1)[1].strip()
    if not expected:
        raise SystemExit("Release asset 未提供 SHA-256")

    if os.path.exists(DEST) and sha256(DEST) == expected:
        print(f"UP_TO_DATE {expected[:12]} {DEST}")
        return

    os.makedirs(DEST_DIR, exist_ok=True)
    download(
        f"https://api.github.com/repos/{REPO}/releases/assets/{assets[APK_NAME]['id']}",
        TMP,
    )
    if sha256(TMP) != expected:
        os.remove(TMP)
        raise SystemExit("SHA256 校验失败，已丢弃下载文件")
    os.replace(TMP, DEST)
    print(f"UPDATED {expected[:12]} {os.path.getsize(DEST)} bytes -> {DEST}")


if __name__ == "__main__":
    main()
