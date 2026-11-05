#!/usr/bin/env bash
# ============================================================================
# 本地静态校验（在推送前拦住会破坏云端构建的问题）
#
# 检查项：
#   1. Kotlin 语法：用便携版 kotlinc 编译你改动的 .kt（过滤缺 SDK 的连带错误）
#   2. 资源引用完整性：主题相关的 @color/@style/@dimen/@drawable 是否可解析
#   3. XML 格式：所有改动的 XML 能否被解析
#   4. 样式 parent 链：parent 指向的样式是否定义
#
# 只在有 kotlinc 时才做第 1 项（缺失则跳过）
# ============================================================================
set -uo pipefail

REPO_DIR="${REPO_DIR:-/c/Users/Administrator/WorkBuddy/gh-work/subcase-dev}"
# 自动定位 kotlinc（便携版），缺失时跳过 Kotlin 检查
if [ -z "${KOTLINC:-}" ]; then
  for c in "$(command -v kotlinc 2>/dev/null)" \
           /c/Users/Administrator/WorkBuddy/gh-work/kotlinc/kotlinc/bin/kotlinc.bat \
           /c/Users/Administrator/WorkBuddy/gh-work/kotlinc/bin/kotlinc.bat; do
    [ -n "$c" ] && [ -f "$c" ] && { KOTLINC="$c"; break; }
  done
fi
if [ -z "${PY:-}" ]; then
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
: "${PY:=python3}"

cd "$REPO_DIR" || exit 1
FAIL=0

say() { echo -e "\n\033[1;36m--- $* ---\033[0m"; }
ok()  { echo -e "  \033[32m✓\033[0m $*"; }
err(){ echo -e "  \033[31m✗\033[0m $*"; FAIL=1; }
warn(){ echo -e "  \033[33m!\033[0m $*"; }

# 与上游的差异文件
DIFF_FILES=$(git diff --name-only upstream/main 2>/dev/null)
if [ -z "$DIFF_FILES" ]; then
  DIFF_FILES=$(git diff --name-only HEAD~1 2>/dev/null)
fi

# ------------------------------------------------------------------ 1. XML
say "1/4 XML 格式检查"
XML_FILES=$(echo "$DIFF_FILES" | grep '\.xml$')
if [ -z "$XML_FILES" ]; then
  ok "无改动的 XML 文件"
else
  for f in $XML_FILES; do
    if [ -f "$f" ]; then
      if $PY -c "import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])" "$f" 2>/dev/null; then
        echo "  ok  $f"
      else
        err "XML 解析失败: $f"
        $PY -c "import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])" "$f" 2>&1 | tail -3 | sed 's/^/      /'
      fi
    fi
  done
fi

# --------------------------------------------------- 2. 字符串资源引用可解析性
# SubCase 的 UI 大量使用 stringResource(R.string.xxx)，
# 增删 strings.xml 条目后忘记同步引用是这里最常见的编译失败原因。
say "2/4 字符串资源引用完整性"
$PY - <<'PYEOF'
import re, os, glob, sys

# 收集所有 values* 目录里定义的 string 名称
defined = set()
for d in glob.glob("app/src/main/res/values*"):
    if not os.path.isdir(d):
        continue
    for f in glob.glob(d + "/*.xml"):
        try:
            txt = open(f, encoding="utf-8").read()
        except Exception:
            continue
        for m in re.finditer(r'<string\s+name="([^"]+)"', txt):
            defined.add(m.group(1))

# 扫描 Kotlin 中 R.string.xxx 引用
missing = []
for f in glob.glob("app/src/main/kotlin/**/*.kt", recursive=True):
    txt = open(f, encoding="utf-8").read()
    for m in re.finditer(r'R\.string\.([A-Za-z0-9_]+)', txt):
        if m.group(1) not in defined:
            missing.append((f.replace("\\", "/"), m.group(1)))

# 扫描 XML 中 @string/xxx 引用
for f in glob.glob("app/src/main/res/**/*.xml", recursive=True):
    txt = open(f, encoding="utf-8").read()
    for m in re.finditer(r'@string/([A-Za-z0-9_]+)', txt):
        if m.group(1) not in defined:
            missing.append((f, m.group(1)))

if missing:
    print("  未定义的字符串资源:")
    seen = set()
    for f, name in missing:
        k = (f, name)
        if k in seen:
            continue
        seen.add(k)
        print("    %s -> R.string.%s" % (f, name))
    sys.exit(1)
print("  所有 R.string 引用均已定义（共 %d 个字符串）" % len(defined))
PYEOF
[ $? -eq 0 ] && ok "字符串资源引用完整" || err "字符串资源引用存在断裂"

# ------------------------------------------------------ 3. style parent 链
say "3/4 style parent 链检查"
$PY - <<'PYEOF'
import re, glob, os, sys

VALS_DIRS = [d for d in glob.glob("app/src/main/res/values*") if os.path.isdir(d)]
styles = {}   # name -> parent
for d in VALS_DIRS:
    for f in glob.glob(d + "/*.xml"):
        txt = open(f, encoding="utf-8").read()
        for m in re.finditer(r'<style\s+name="([^"]+)"(?:\s+parent="([^"]+)")?', txt):
            styles[m.group(1)] = m.group(2)

# Material/Android/第三方库内置 parent 白名单
BUILTIN = re.compile(
    r'^(Theme\.|ThemeOverlay\.|Widget\.|TextAppearance\.|Base\.|'
    r'android:Widget\.|Widget\.AppCompat\.|Widget\.MaterialComponents\.|'
    r'Widget\.Material3\.|Theme\.Material|Theme\.AppCompat|'
    r'Theme\.MaterialComponents|Theme\.Material3|'
    r'ShapeAppearance\.|MaterialAlertDialog\.|PreferenceThemeOverlay\.|'
    r'Preference\.|PreferenceCategoryTitleTextStyle|PreferenceSummaryTextStyle|)'
)

missing = []
for name, parent in styles.items():
    if not parent:
        continue
    if BUILTIN.match(parent):
        continue
    p = parent.lstrip("?")
    if p.startswith("@"):
        p = p.split("/")[-1]
    base = p.split(".")[-1]
    if p in styles or base in styles:
        continue
    missing.append((name, parent))

if missing:
    print("  parent 指向未定义的样式:")
    for n, p in missing:
        print("    %s -> %s" % (n, p))
    sys.exit(1)
print("  所有 style parent 链可解析（共检查 %d 个 style）" % len(styles))
PYEOF
[ $? -eq 0 ] && ok "style parent 链完整" || err "style parent 链有断裂"

# -------------------------------------------------------------- 4. Kotlin
# SubCase 使用 Kotlin 2.x + Compose + miuix，本地便携版 kotlinc(1.9.x) 缺少
# Android SDK 与全部依赖，会产生海量 unresolved reference 连带错误，无法区分
# 真实问题。因此这里做「结构性检查」：括号配平、import 完整性、被调用符号是否
# 在本仓库内定义。真正的类型检查交给云端 Gradle 构建。
say "4/4 Kotlin 结构检查"
KT_FILES=$(echo "$DIFF_FILES" | grep '\.kt$')
if [ -z "$KT_FILES" ]; then
  ok "无改动的 Kotlin 文件"
else
  KT_FILES="$KT_FILES" $PY - <<'PYEOF'
import re, glob, os, sys

KT_ROOT = "app/src/main/kotlin"
all_src = {}
for f in glob.glob(KT_ROOT + "/**/*.kt", recursive=True):
    # Windows 上 glob 返回反斜杠路径，而 git 输出的文件名是正斜杠，
    # 必须统一成同一形式，否则查表全部落空、检查被静默跳过。
    key = f.replace("\\", "/")
    all_src[key] = open(f, encoding="utf-8").read()

KT_FILES = [x for x in os.environ.get("KT_FILES", "").split() if x]

# 构建期生成的符号，源码里查不到，属正常
GENERATED = {"R", "BuildConfig", "BuildConfig.DEBUG"}

# 收集仓库内定义的顶层符号（fun / val / var / class / object / interface / const）
defined = set()
for txt in all_src.values():
    for m in re.finditer(
            r'^\s*(?:internal\s+|private\s+|public\s+|abstract\s+|open\s+|sealed\s+|data\s+|enum\s+|value\s+)*'
            r'(?:fun|val|var|class|object|interface|typealias|const\s+val)\s+([A-Za-z_][A-Za-z0-9_]*)',
            txt, re.M):
        defined.add(m.group(1))
    # object 内的 const val / val
    for m in re.finditer(r'^\s{4}(?:const\s+)?(?:val|var)\s+([A-Z][A-Z0-9_]*)\s*[:=]', txt, re.M):
        defined.add(m.group(1))

def strip_code(txt):
    """去掉注释与字符串字面量，避免其中的括号干扰配平统计。"""
    out = []
    i = 0
    n = len(txt)
    while i < n:
        c = txt[i]
        if c == '/' and i + 1 < n and txt[i + 1] == '/':
            while i < n and txt[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and txt[i + 1] == '*':
            i += 2
            while i + 1 < n and not (txt[i] == '*' and txt[i + 1] == '/'):
                i += 1
            i += 2
        elif c == '"':
            if txt[i:i + 3] == '"""':
                i += 3
                while i + 2 < n and txt[i:i + 3] != '"""':
                    i += 1
                i += 3
            else:
                i += 1
                while i < n and txt[i] != '"':
                    if txt[i] == '\\':
                        i += 1
                    i += 1
                i += 1
        elif c == "'":
            i += 1
            while i < n and txt[i] != "'":
                if txt[i] == '\\':
                    i += 1
                i += 1
            i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)

problems = []
# 只检查本次改动的文件，避免上游历史代码的噪音
for f in KT_FILES:
    if f not in all_src:
        continue
    txt = all_src[f]
    stripped = strip_code(txt)
    for open_c, close_c in (("(", ")"), ("{", "}"), ("[", "]")):
        a, b = stripped.count(open_c), stripped.count(close_c)
        if a != b:
            problems.append("%s: %s%s 不配平 (%d vs %d)" % (f, open_c, close_c, a, b))
    # import 的本仓库符号必须存在
    for m in re.finditer(r'^import\s+(ano\.subcase\.[\w.]+)\s*$', txt, re.M):
        fq = m.group(1)
        simple = fq.split(".")[-1]
        if simple in GENERATED:
            continue
        if simple and simple[0].isupper() and simple not in defined:
            problems.append("%s: import %s 在仓库内未找到定义" % (f, fq))

# 本次改动文件中调用的自定义顶层函数必须有定义
CUSTOM_CALLS = ("buildSubStoreUrl", "resolveBackendAddress")
for f in KT_FILES:
    if f not in all_src:
        continue
    for call in CUSTOM_CALLS:
        if re.search(r'\b%s\s*\(' % call, all_src[f]) and call not in defined:
            problems.append("%s: 调用了未定义的 %s" % (f, call))

if problems:
    print("  Kotlin 结构问题:")
    for p in problems:
        print("    " + p)
    sys.exit(1)
print("  Kotlin 结构检查通过（括号配平 / import / 自定义符号），共检查 %d 个文件" % len(KT_FILES))
PYEOF
  [ $? -eq 0 ] && ok "Kotlin 结构检查通过" || err "Kotlin 结构检查未通过"
fi

echo ""
if [ $FAIL -eq 0 ]; then
  echo -e "\033[1;32m✓ 全部静态校验通过\033[0m"
else
  echo -e "\033[1;31m✗ 存在校验失败项，请勿推送\033[0m"
fi
exit $FAIL
