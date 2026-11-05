"""等待指定分支的云端构建完成并下载 APK 产物。

用法：
    GITHUB_TOKEN=xxx python3 tools/fetch_apk.py [分支名]

注意：GitHub 的 artifact 下载会 302 到 Azure Blob，带 Authorization 头会被
Blob 拒绝（401 InvalidAuthenticationInfo），必须剥离该头。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

REPO = "zhangxiao439/subcase"
API = "https://api.github.com/repos/" + REPO
TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "apk_out")
OUT = os.path.abspath(OUT)

H = {
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "WorkBuddy-Sync",
}
if TOKEN:
    H["Authorization"] = "Bearer " + TOKEN


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """重定向到 Azure Blob 时剥离 Authorization 头，否则 Blob 返回 401。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            drop = ("authorization", "accept")
            new.headers = {k: v for k, v in new.headers.items()
                           if k.lower() not in drop}
            new.unredirected_hdrs = {k: v for k, v in new.unredirected_hdrs.items()
                                     if k.lower() not in drop}
        return new


_opener = urllib.request.build_opener(NoAuthRedirect)


def req(method, url, data=None, raw=False):
    body = json.dumps(data).encode() if data is not None else None
    for attempt in range(4):
        r = urllib.request.Request(url, data=body, headers=H, method=method)
        try:
            with _opener.open(r, timeout=180) as resp:
                content = resp.read()
                if raw:
                    return resp.status, content
                txt = content.decode("utf-8", "replace")
                return resp.status, (json.loads(txt) if txt.strip() else {})
        except urllib.error.HTTPError as e:
            txt = e.read().decode("utf-8", "replace")
            try:
                txt = json.loads(txt).get("message", txt)
            except Exception:
                pass
            return e.code, {"message": txt}
        except Exception as e:
            if attempt == 3:
                return 0, {"message": str(e)}
            time.sleep(3)
    return 0, {"message": "unknown"}


def main():
    branch = sys.argv[1] if len(sys.argv) > 1 else "feature/custom-backend"
    if not TOKEN:
        print("!! 未设置 GITHUB_TOKEN")
        return 1

    print("[1/3] 查找 %s 的最新 workflow run ..." % branch)
    run = None
    for _ in range(40):
        st, r = req("GET", API + "/actions/runs?branch=%s&per_page=10" % branch)
        if st == 200:
            runs = r.get("workflow_runs", [])
            if runs:
                run = runs[0]
                break
        time.sleep(6)
    if not run:
        print("!! 没找到 workflow run（可能未触发，检查 workflow 是否 push 到该分支）")
        return 1

    print("      run #%d %s  (%s / %s)" % (
        run["id"], run["name"], run["status"], run.get("conclusion")))
    if run["status"] != "completed":
        print("[2/3] 构建进行中，等待完成 ...")
        last = None
        for _ in range(240):
            st, r = req("GET", API + "/actions/runs/%d" % run["id"])
            if st != 200:
                time.sleep(15)
                continue
            cur = (r["status"], r.get("conclusion"))
            if cur != last:
                print("      状态: %s / %s" % cur)
                last = cur
            if cur[0] == "completed":
                if cur[1] != "success":
                    st, jobs = req("GET", API + "/actions/runs/%d/jobs" % run["id"])
                    for j in jobs.get("jobs", []):
                        if j.get("conclusion") != "success":
                            print("      失败 job: %s (%s)" % (j["name"], j.get("conclusion")))
                    print("!! 构建未成功: https://github.com/%s/actions/runs/%d"
                          % (REPO, run["id"]))
                    return 1
                break
            time.sleep(15)

    print("[3/3] 下载 APK 产物 ...")
    st, arts = req("GET", API + "/actions/runs/%d/artifacts" % run["id"])
    if st != 200:
        print("!! 读取 artifact 失败:", arts)
        return 1
    os.makedirs(OUT, exist_ok=True)
    found = False
    # SubCase 的 workflow 上传名为 release / debug 的 artifact
    wanted = ("release", "debug")
    for a in arts.get("artifacts", []):
        if a["name"] not in wanted:
            continue
        st, blob = req("GET", API + "/actions/artifacts/%d/zip" % a["id"], raw=True)
        if st != 200:
            print("!! 下载失败:", blob[:200] if isinstance(blob, bytes) else blob)
            continue
        zp = os.path.join(OUT, "APKs.zip")
        with open(zp, "wb") as f:
            f.write(blob)
        with zipfile.ZipFile(zp) as z:
            z.extractall(OUT)
        os.remove(zp)
        found = True

    if not found:
        print("!! 未找到名为 release/debug 的 artifact")
        return 1

    print("产物目录: %s" % OUT)
    for root, _, fs in os.walk(OUT):
        for f in fs:
            if f.lower().endswith(".apk"):
                p = os.path.join(root, f)
                print("  %s  (%.1f MB)" % (p, os.path.getsize(p) / 1048576.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
