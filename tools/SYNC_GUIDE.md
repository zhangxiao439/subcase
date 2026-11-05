# SubCase 自定义后端 —— 同步与维护手册

## 一、这个 fork 做了什么

在官方 SubCase 基础上增加「**自定义后端地址**」功能：App 内置的前端不再只连
App 自带的本地后端（`http://127.0.0.1:8081`），而是可以指向你自己部署在服务器上的
Sub-Store 后端。

数据（订阅、组合、脚本）因此保存在你自己的服务器上，多设备共享；
App 的原生能力（WebView 文件导入订阅、通知栏、快捷设置磁贴）全部保留。

改动文件（6 个）：

| 文件 | 改动 |
|---|---|
| `app/.../util/ConfigStore.kt` | 新增 `remoteBackendUrl` 配置项（State 支撑，保存后首页自动重组） |
| `app/.../ui/components/SubStoreWebView.kt` | `buildSubStoreUrl()` 远程优先 + URL 编码；新增 `resolveBackendAddress()` |
| `app/.../ui/screens/HomeScreen.kt` | 传入 `ConfigStore.remoteBackendUrl` |
| `app/.../ui/screens/SettingsScreen.kt` | 新增自定义后端输入区；后端地址卡片改为显示实际生效地址 |
| `app/.../res/values/strings.xml` | 新增 4 条英文字符串 |
| `app/.../res/values-zh-rCN/strings.xml` | 新增 4 条中文字符串 |

## 二、分支模型

```
upstream/main                    官方上游 sub-store-org/subcase，永不改
     │ reset --hard
origin/main                      你的 fork 的 main = 上游镜像
     │ rebase upstream/main
origin/feature/custom-backend    上游最新 + 你的自定义后端改动
```

## 三、日常同步上游（一条命令）

```bash
cd /c/Users/Administrator/WorkBuddy/gh-work/subcase-dev
./tools/sync.sh
```

依次执行：拉上游 → main 镜像上游 → rebase 你的分支 → **静态校验** → 推送 → 云端构建 → 下 APK。

其他用法：

```bash
./tools/sync.sh --no-push    # 只同步+校验，不推送
./tools/sync.sh --no-build   # 同步但不触发云端构建
./tools/sync.sh --help       # 查看用法
```

token 已存放在 `~/.workbuddy/secrets/github_token.sh`（脚本自动加载）和
`~/.git-credentials`（git push 直接可用），**不需要每次手动传**。

## 四、静态校验做了什么

`tools/verify.sh` 是推送前的保险丝，4 项：

1. **XML 格式** —— 改动的 strings.xml 等能否被解析
2. **字符串资源引用** —— Kotlin 里所有 `R.string.xxx` 是否都在 strings.xml 中定义
   （改文案最容易漏，是本项目最高频的编译失败原因）
3. **style parent 链** —— parent 指向的样式是否定义
4. **Kotlin 结构** —— 括号配平、`ano.subcase.*` import 是否存在、自定义顶层函数是否定义

> ⚠️ 第 4 项**不做真正的类型检查**。本地便携版 kotlinc 是 1.9.x，而 SubCase 用
> Kotlin 2.x + Compose + miuix，缺 Android SDK 和全部依赖会产生海量
> `unresolved reference` 连带错误，无法区分真实问题。
> **真正的类型检查由云端 Gradle 构建完成**——所以推送后一定要看构建结果。

校验器本身经过「注入错误」反向验证：故意制造括号不配平，检查器能准确报出。

## 五、服务器端必做的一件事：CORS

App 内置前端托管在 `http://127.0.0.1:8080`，访问你的远端后端属于**跨域**，
后端必须允许这个 origin：

```yaml
environment:
  - SUB_STORE_CORS_ALLOWED_ORIGINS=https://sub-store.vercel.app,http://substore.stash,https://substore.stash,http://127.0.0.1:8080
```

注意：

- **不要有多余空格**。origin 是精确匹配，末尾一个空格就会失效。
- 因为只自己用，App 里保持「允许局域网访问」**关闭**，origin 恒为 `http://127.0.0.1:8080`。
  一旦开了 LAN 开关，origin 变成 `http://192.168.x.x:8080`，白名单还得跟着加 IP。

验证：

```bash
curl -i -H "Origin: http://127.0.0.1:8080" \
  "https://你的域名/你的前缀/api/utils/env" | grep -i "access-control"
# 期望：Access-Control-Allow-Origin: http://127.0.0.1:8080
```

## 六、在 App 里填写后端地址

设置 → 「自定义后端」→ 填入**后端**地址（不是前端页面地址）：

```
https://你的域名/你的前缀
```

- 不要带 `/api`、不要带 `/subs`、末尾不要加 `/`
- 前端页面地址不需要填，App 仍然使用自己内置的前端
- 留空 = 恢复使用 App 内置的本地后端

App 内部会拼成：

```
http://127.0.0.1:8080/subs?api=<URL编码后的后端地址>
```

**为什么要 URL 编码**：Sub-Store 前端按 `&` 和 `=` 切分查询串后只取 `api=` 后的
第一段，不编码的话，含 `=` 或 `&` 的地址会被静默截断。

## 七、已知限制

- **App 内置的本地后端仍在运行**。配置远程后端后它不再被使用，属于纯耗电。
  清理它需要改动前台服务与通知触发逻辑，回归面较大，留作第二阶段。
- **「后端版本」卡片显示的仍是内置脚本版本**，不是远程后端版本。
- **token 存于明文**：`SharedPreferences` 和 WebView `localStorage`。
  路径 token 请用足够长的随机串，且不要外泄该 URL。
- **AGPL-3.0**：保留 LICENSE 与原始版权头；对外分发时需提供修改后源码
  （fork 公开在 GitHub 上即满足）。

## 八、发布与签名

上游自带的 workflow：

- `.github/workflows/build-apks.yml` —— push 到 main 触发，出 debug/release APK
- `.github/workflows/release.yml` —— 打 `v*` tag 触发，出 GitHub Release

签名走 `org.lsposed.lsplugin.apksign` 插件，读取 `gradle.properties` 里的：

```
KEYSTORE_FILE / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD
```

这些由 CI 从仓库 Secrets 注入，需要配置 4 个 Secret：

| Secret | 内容 |
|---|---|
| `KEYSTORE` | keystore 文件的 base64 编码 |
| `KEYSTORE_PASSWORD` | keystore 口令 |
| `KEY_ALIAS` | 密钥别名 |
| `KEY_PASSWORD` | 密钥口令 |

未配置时构建出的是未签名 APK，**无法覆盖安装官方版**。

### 本 fork 的构建 workflow

`.github/workflows/build-apks-signed.yml` —— push 到 `main` 或 `feature/custom-backend`
触发，也可手动 dispatch。签名密钥来源按优先级：

1. **仓库 Secrets 中的固定 keystore**（推荐）：`KEYSTORE`（base64）、
   `KEYSTORE_PASSWORD`、`KEY_ALIAS`、`KEY_PASSWORD`。
   证书长期不变，**新版本可以覆盖安装旧版本**。
2. **回落：临时 keystore**：没有配置 Secrets 时在 runner 上现场生成。
   每次构建证书都不同，只能安装一次，之后的版本无法覆盖它。

配置 Secrets 用 `tools/set_secrets.py`（需 `pynacl`，本机已装）：

```bash
export GITHUB_TOKEN=...
python3 tools/set_secrets.py <keystore路径> <alias> <口令>
```

它会取仓库的 libsodium public key，把 4 个值用 sealed box 加密后写入。
本地生成 keystore：

```bash
keytool -genkeypair -v -keystore subcase.p12 -alias subcase \
        -keyalg RSA -keysize 2048 -validity 10000
```

下载产物：

```bash
python3 tools/fetch_apk.py feature/custom-backend
```

输出到 `apk_out/`，含 `release`（约 6 MB，已签名、已混淆）和 `debug`（约 28 MB）。

### 两个必须保留的 CI 细节

1. `fetch-depth: 0` —— 根 `build.gradle.kts` 用 JGit 读
   `refs/remotes/origin/main` 的提交数来算 `versionCode`。
   `actions/checkout` 默认浅克隆，没有 remote-tracking ref，
   构建会以 `RefDatabase.exactRef(String) is null` 直接失败。
2. `setup-android@v4` —— v3 会执行 `sdkmanager tools`，
   而 `tools` 包已从 SDK 仓库下架，action 会以退出码 1 失败。

本地生成 keystore：

```bash
keytool -genkeypair -v -keystore subcase.jks -keyalg RSA -keysize 2048 \
        -validity 10000 -alias subcase
base64 -w0 subcase.jks > subcase.b64
```

## 九、出现冲突时

脚本会停下并打印冲突文件。解决流程：

```bash
git status                          # 看哪些文件冲突
# 编辑文件：删掉 <<<<<<< ======= >>>>>>> 标记，
# 保留「上游的新内容」+「你自己的改动」两部分
git add <冲突文件>
git rebase --continue                # 重复直到完成
git rebase --abort                   # 想放弃重来
```

最可能冲突的文件：`SettingsScreen.kt`、`ConfigStore.kt`
（上游若也新增设置项或修改同一区块）。
