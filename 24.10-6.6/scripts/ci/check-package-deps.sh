#!/usr/bin/env bash
# 在编译前核对：.config 选中的每个包，它的运行时依赖是否都能被选中集合满足。
#
# 为什么需要这道门禁（2026-11-07，run 42401311130）：
#   kconfig 只解析 DEPENDS；对 Makefile 里写错名字/未接线的依赖只打印一行
#   WARNING（"has a dependency on 'X', which does not exist"）然后静默丢弃。
#   编译照样能过（包本身能编出来），直到 package/install 才由 opkg 以
#   "cannot find dependency X for Y" 失败——而 include/verbose.mk 在非 V=s
#   模式下把子 make 的输出全丢进 /dev/null，报错根本看不见，一轮 85 分钟。
#   另有 EXTRA_DEPENDS：它不进 kconfig、不进 tmp/.packageinfo，只在生成 ipk
#   时写进 control（tar 的 xz 就是这样漏掉的），所以这里读 Makefile 原文补查。
#
# 用法：scripts/ci/check-package-deps.sh <buildroot> [.config]
#   默认 .config 取 <buildroot>/.config；要求先跑过 defconfig（tmp/.packageinfo 存在）。
#
# 退出码：0 PASS / 4 ASSERTION_FAILED（有无法满足的依赖或缺输入）
#
# 只读本地文件；不联网；不接触设备。

set -Eeuo pipefail
LC_ALL=C

ROOT=${1:?用法: check-package-deps.sh <buildroot> [.config]}
CONFIG=${2:-$ROOT/.config}
INFO=$ROOT/tmp/.packageinfo

die() { echo "FAIL  $*" >&2; exit 4; }

[ -d "$ROOT" ]   || die "buildroot 不存在：$ROOT"
[ -f "$CONFIG" ] || die ".config 不存在：$CONFIG（先跑 defconfig）"
[ -f "$INFO" ]   || die "tmp/.packageinfo 不存在：$INFO（先跑 defconfig）"

if ! python3 -I - "$ROOT" "$CONFIG" "$INFO" <<'PY'
import os
import re
import sys

root, config_path, info_path = sys.argv[1:4]

# ---- 选中集合：CONFIG_PACKAGE_<名字>=y ------------------------------------
config = {}
for line in open(config_path, errors="replace"):
    m = re.match(r"(CONFIG_[A-Za-z0-9_.+-]+)=(y|m)\s*$", line.strip())
    if m:
        config[m.group(1)] = m.group(2)

def on(sym):
    return config.get(sym) == "y"

selected = {k[len("CONFIG_PACKAGE_"):] for k in config if k.startswith("CONFIG_PACKAGE_")}

# ---- .packageinfo：每个包的 Depends / Provides ------------------------------
stanzas = {}
for block in re.split(r"\n\n+", open(info_path, errors="replace").read()):
    m = re.search(r"^Package:\s*(\S+)\s*$", block, re.M)
    if not m:
        continue
    name = m.group(1)
    dep = re.search(r"^Depends:\s*(.*)$", block, re.M)
    pro = re.search(r"^Provides:\s*(.*)$", block, re.M)
    stanzas[name] = (
        dep.group(1).split() if dep else [],
        pro.group(1).split() if pro else [],
    )

provided = set()
for name in selected:
    if name in stanzas:
        provided.update(p.strip() for p in stanzas[name][1] if p.strip())

def satisfied(dep):
    return dep in selected or dep in provided

def norm(tok):
    tok = tok.strip().lstrip("+").strip()
    tok = re.sub(r"\(.*?\)", "", tok).strip()   # 去掉版本约束
    return tok

def cond_ok(cond):
    # +PACKAGE_X:dep 形式的条件；CONFIG_PACKAGE_X 没开就整条不要
    return on("CONFIG_" + cond)

problems = []

# ---- 1) .packageinfo 的 Depends（DEPENDS 的展开结果） -----------------------
for name in sorted(selected):
    deps = stanzas.get(name)
    if deps is None:
        continue            # 选中的虚拟包（provides 名）不在 stanzas 里，正常
    for tok in deps[0]:
        if tok.lstrip("+").startswith("@"):   # @DRIVER_* / @!foo 之类的构建期条件，跳过
            continue
        if ":" in tok:
            cond, dep = tok.lstrip("+").split(":", 1)
            if not cond.startswith("PACKAGE_"):
                continue
            if not cond_ok(cond):
                continue
            dep = norm(dep)
        else:
            dep = norm(tok)
        if not dep or dep.startswith("$"):
            continue
        if not satisfied(dep):
            problems.append("%s 依赖 %s（未选中，也没有被选中包 provides）" % (name, dep))

# ---- 2) EXTRA_DEPENDS：只在 Makefile 原文里，生成 ipk 时才进 control  -------
def eval_if(expr):
    # 支持 $(if $(CONFIG_X),A) 与 $(if $(CONFIG_X),A,B)；其余函数返回 None
    m = re.fullmatch(r"\$\(if\s+\$\((CONFIG_[A-Za-z0-9_.+-]+)\),([^(),]*)(?:,([^(),]*))?\)", expr.strip())
    if not m:
        return None
    return m.group(2) if on(m.group(1)) else (m.group(3) or "")

seen = set()
for dirpath, _dirnames, filenames in os.walk(root, followlinks=True):
    if "Makefile" not in filenames:
        continue
    rel = os.path.relpath(os.path.join(dirpath, "Makefile"), root)
    # 只扫 package/ 下的 Makefile（feeds 都是 package/feeds 软链，会被走进来）
    if not (rel == "package/Makefile" or rel.startswith("package/")):
        continue
    try:
        txt = open(os.path.join(dirpath, "Makefile"), errors="replace").read()
    except OSError:
        continue
    for pm in re.finditer(r"define Package/([A-Za-z0-9_.+-]+)\n(.*?)\nendef", txt, re.S):
        pkg, body = pm.group(1), pm.group(2)
        if pkg not in selected:
            continue
        em = re.search(r"^\s*EXTRA_DEPENDS\s*:?=\s*(.*)$", body, re.M)
        if not em:
            continue
        val = em.group(1).strip()
        # 逐个 $(if ...) 求值，其余 $(...) 原样丢弃并记为未检查
        unknown = [False]
        def sub(m):
            r = eval_if(m.group(0))
            if r is None:
                unknown[0] = True
                return ""
            return r
        resolved = re.sub(r"\$\(if[^()]*(?:\([^()]*\)[^()]*)*\)", sub, val)
        if "$(" in resolved:
            unknown[0] = True
            resolved = re.sub(r"\$\([^()]*\)", "", resolved)
        key = (pkg, resolved)
        if key in seen:
            continue
        seen.add(key)
        for tok in resolved.replace(",", " ").split():
            dep = norm(tok)
            if not dep or dep.startswith(("$", "-")):
                continue
            if ":" in dep:
                cond, dep = dep.split(":", 1)
                if cond.startswith("PACKAGE_") and not cond_ok(cond):
                    continue
                dep = norm(dep)
            if not dep or not re.fullmatch(r"[A-Za-z0-9_.+-]+", dep):
                continue
            if not satisfied(dep):
                problems.append(
                    "%s 的 EXTRA_DEPENDS 依赖 %s（未选中；EXTRA_DEPENDS 不进 kconfig，"
                    "opkg 安装该包时会失败）：%s" % (pkg, dep, rel))
        if unknown[0]:
            print("NOTE  %s 的 EXTRA_DEPENDS 含无法静态求值的表达式，已跳过：%s" % (rel, val))

# 去重保序
uniq = list(dict.fromkeys(problems))

if uniq:
    print("FAIL  选中包存在无法满足的运行时依赖（%d 条）：" % len(uniq))
    for p in uniq:
        print("  -", p)
    sys.exit(1)

print("PASS  选中包 %d 个，运行时依赖全部可满足（含 EXTRA_DEPENDS 静态求值）" % len(selected))
PY
then
	die "存在无法满足的运行时依赖（详见上文）"
fi
echo "PASS  check-package-deps  $CONFIG"
