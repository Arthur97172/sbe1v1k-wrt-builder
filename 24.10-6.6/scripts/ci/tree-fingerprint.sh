#!/usr/bin/env bash
# 源码树指纹：把“装配出来的树”和“已审计的树”变成可比较的单一数值。
#
# 为什么不直接用 tar + sha256：tar 的字节取决于 tar/zstd 版本、文件系统里的
# mtime、.git 打包字节，跨机器不可比。这里只看内容本身：
#
#   path<TAB>mode<TAB>type<TAB>sha256<TAB>link<TAB>resolved
#
# 每行一条记录（目录也记，权限变化可见），按 LC_ALL=C 排序后整体取 SHA-256。
# 与 tar 版本无关，与宿主路径无关。
#
# 三个关键归一化，否则审计树与装配树永远对不上：
#   1. 权限位抹掉 g+w（mode & ~022）。审计树是在 umask 002 的机器上装出来的
#      （普通文件 664），CI 的 git checkout / rsync 用 umask 022（644）。组写位
#      对构建没有任何影响，留着只会让指纹随宿主漂移；可执行位、0744/0755 这类
#      真正有意义的差别仍然可见。
#   2. 软链只记**解析后的目标**（link 列恒为 "-"）：审计树的
#      package/feeds/packages/x -> ../../../qca/feeds/packages/x 与装配树的
#      -> ../../../feeds/packages/x 解析结果相同；绝对路径先落回根内相对路径，
#      落到根外直接判失败。原始 link 文本不参与哈希——它正是两种装配方式之间
#      必然不同的那部分。
#   3. buildroot/feeds.conf 按“src-link 目标转成根内相对路径”后的文本哈希：
#      审计树里写的是宿主绝对路径，装配树写相对路径，两者规范化后相同。
#      解析不到根内的 src-link 判失败。
#
# 排除项见 fingerprint-exclude.conf（feeds 索引、编译产物、version.date 等），
# 被排除的东西由装配脚本单独断言。
#
# 用法：
#   tree-fingerprint.sh --root <sources> --out fp.json [--tsv fp.tsv]
#                       [--profile audited|fresh] [--recipe-sha <sha>]
#   tree-fingerprint.sh --root <sources> --out fp.json --compare prev.tsv \
#                       [--known-delta known-delta.conf]
#   tree-fingerprint.sh --check-exclusions \
#                       --clean-root <dir>:<prefix> [--clean-root ...]
#
# 退出码：0 通过、4 断言失败（悬空/越界软链、排除过宽）、5 指纹不一致。

set -euo pipefail

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)      # <repo>/24.10-6.6

exec python3 -I - "$@" <<'PYEOF'
import argparse
import fnmatch
import hashlib
import json
import os
import re
import stat
import sys

SCHEMA = "sbe1v1k-tree-fingerprint/1"
DEFAULT_SUBTREES = [
    "buildroot", "luci", "apps", "thirdparty", "thirdparty-feed",
    "passwall-selected", "local-relayout", "PROVENANCE.md", "README.md",
]
CHUNK = 1 << 20
# 需要“规范化后再哈希”的生成物。目前只有一个：feeds.conf 里写的是宿主
# 绝对路径（审计树）或根内相对路径（装配树），规范化成 src-link <name> <根内相对>
# 之后两边一致。
CANON_FEEDS_CONF = "buildroot/feeds.conf"
SRC_LINK_RE = re.compile(r"^(\s*src-link\s+)(\S+)(\s+)(\S+)(\s*)$")


def die(code, msg):
    print(msg, file=sys.stderr)
    sys.exit(code)


def esc(s):
    return (s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n"))


def load_rules(path):
    rules = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                die(4, "排除清单第 %d 行格式错误（应为 <kind>TAB<pattern>）：%s"
                       % (lineno, line))
            kind, pattern = parts
            if kind not in ("dir", "path", "glob"):
                die(4, "排除清单第 %d 行 kind 非法：%s" % (lineno, kind))
            if kind == "dir" and not pattern.endswith("/"):
                die(4, "排除清单第 %d 行 dir 规则须以 / 结尾：%s" % (lineno, pattern))
            rules.append({"kind": kind, "pattern": pattern, "line": lineno, "count": 0})
    return rules


def match_rule(rule, path):
    kind, pat = rule["kind"], rule["pattern"]
    if kind == "dir":
        return path == pat[:-1] or path.startswith(pat)
    if kind == "path":
        return path == pat
    return fnmatch.fnmatchcase(path, pat)


def matched_rule(rules, path):
    for r in rules:
        if match_rule(r, path):
            return r
    return None


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def canon_feeds_conf(root, abs_path, errors):
    """把 feeds.conf 的 src-link 目标规范化成根内相对路径，返回 sha256。

    任何解析到根外、或形态认不出的 src-link 行都记 error（调用方会据此判失败），
    不能静默原样保留——那等于把宿主路径写进指纹。
    """
    root_abs = os.path.abspath(root)
    base = os.path.dirname(os.path.abspath(abs_path))
    out = []
    with open(abs_path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            s = line.rstrip("\n")
            if not s.lstrip().startswith("src-link"):
                out.append(s)
                continue
            m = SRC_LINK_RE.match(s)
            if not m:
                errors.append("feeds.conf 第 %d 行无法解析：%s" % (lineno, s))
                out.append(s)
                continue
            name, target = m.group(2), m.group(4)
            cand = target if os.path.isabs(target) else os.path.join(base, target)
            cand = os.path.normpath(cand)
            if cand != root_abs and not cand.startswith(root_abs + os.sep):
                errors.append("feeds.conf 第 %d 行指到根外：%s -> %s"
                              % (lineno, name, target))
                out.append(s)
                continue
            rel = os.path.relpath(cand, root_abs).replace(os.sep, "/")
            if not os.path.lexists(cand):
                errors.append("feeds.conf 第 %d 行目标不存在：%s -> %s"
                              % (lineno, name, rel))
            out.append("%s%s%s%s%s" % (m.group(1), name, m.group(3), rel, m.group(5)))
    blob = ("\n".join(out) + "\n").encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def visit(root, rp, rules, lines, errors, counters):
    r = matched_rule(rules, rp)
    if r is not None:
        r["count"] += 1
        return
    abs_path = os.path.join(root, rp)
    try:
        st = os.lstat(abs_path)
    except OSError as ex:
        errors.append("无法 stat %s: %s" % (rp, ex))
        return
    mode = "%04o" % (stat.S_IMODE(st.st_mode) & ~0o022)
    if stat.S_ISLNK(st.st_mode):
        target = os.readlink(abs_path)
        resolved, outside, dangling = resolve_link(root, abs_path, target)
        if outside:
            errors.append("软链指向根外: %s -> %s" % (rp, target))
        elif dangling:
            errors.append("悬空软链: %s -> %s" % (rp, target))
        # 只记解析后的目标：绝对/相对写法的差别（审计树 vs 装配树）不应影响指纹。
        lines.append("\t".join([esc(rp), mode, "l", "-", "-", esc(resolved)]))
        counters["links"] += 1
    elif stat.S_ISDIR(st.st_mode):
        lines.append("\t".join([esc(rp), mode, "d", "-", "-", "-"]))
        counters["dirs"] += 1
        try:
            names = sorted(os.listdir(abs_path))
        except OSError as ex:
            errors.append("无法读取 %s: %s" % (rp, ex))
            return
        for name in names:
            visit(root, rp + "/" + name, rules, lines, errors, counters)
    elif stat.S_ISREG(st.st_mode):
        try:
            if rp == CANON_FEEDS_CONF:
                digest = canon_feeds_conf(root, abs_path, errors)
                counters["canonicalized"] += 1
            else:
                digest = sha256_file(abs_path)
        except OSError as ex:
            errors.append("无法读取 %s: %s" % (rp, ex))
            return
        lines.append("\t".join([esc(rp), mode, "f", digest, "-", "-"]))
        counters["files"] += 1
    else:
        errors.append("非常规文件（fifo/设备/套接字）: %s" % rp)


def resolve_link(root, path, target):
    """返回 (根内相对解析路径, 是否越界, 是否悬空)。"""
    root_abs = os.path.abspath(root)
    if os.path.isabs(target):
        cand = os.path.normpath(target)
    else:
        cand = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(path)), target))
    real = os.path.realpath(cand)
    if real != root_abs and not real.startswith(root_abs + os.sep):
        return "", True, False
    return os.path.relpath(real, root_abs), False, not os.path.exists(real)


def load_known_delta(path):
    out = []
    if not path:
        return out
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                die(4, "known-delta 第 %d 行格式错误：%s" % (lineno, line))
            out.append({"glob": parts[0], "direction": parts[1],
                        "reason": parts[2] if len(parts) > 2 else ""})
    return out


def parse_tsv(path):
    d = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            d[line.split("\t", 1)[0]] = line
    return d


def check_exclusions(clean_roots, rules):
    total_bad = 0
    for spec in clean_roots:
        if ":" not in spec:
            die(4, "--clean-root 需要 <目录>:<前缀>，收到：%s" % spec)
        base, prefix = spec.rsplit(":", 1)
        if prefix and not prefix.endswith("/"):
            prefix += "/"
        seen = 0
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            rel = os.path.relpath(dirpath, base)
            rp = prefix + ("" if rel == "." else rel.replace(os.sep, "/") + "/")
            for name in sorted(dirnames):
                p = rp + name
                for r in rules:
                    if match_rule(r, p) or match_rule(r, p + "/"):
                        r["count"] += 1
                        if r["count"] <= 5:
                            print("EXCLUSION_TOO_BROAD 第 %d 行 [%s] 命中干净上游：%s"
                                  % (r["line"], r["pattern"], p))
            for name in sorted(filenames):
                p = rp + name
                seen += 1
                for r in rules:
                    if match_rule(r, p):
                        r["count"] += 1
                        if r["count"] <= 5:
                            print("EXCLUSION_TOO_BROAD 第 %d 行 [%s] 命中干净上游：%s"
                                  % (r["line"], r["pattern"], p))
        print("checked %s (%d files) prefix=%s" % (base, seen, prefix or "-"))
    bad = [r for r in rules if r["count"] > 0]
    print("rules=%d too_broad=%d" % (len(rules), len(bad)))
    total_bad = len(bad)
    return total_bad


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root")
    ap.add_argument("--exclude")
    ap.add_argument("--out")
    ap.add_argument("--tsv")
    ap.add_argument("--profile", default="fresh")
    ap.add_argument("--recipe-sha", default="-")
    ap.add_argument("--epoch", default="-")
    ap.add_argument("--subtrees", default="")
    ap.add_argument("--compare")
    ap.add_argument("--known-delta", default="")
    ap.add_argument("--check-exclusions", action="store_true")
    ap.add_argument("--clean-root", action="append", default=[])
    ap.add_argument("--allow-dangling", action="store_true")
    args = ap.parse_args()

    if not args.exclude:
        die(4, "缺少 --exclude")
    rules = load_rules(args.exclude)

    if args.check_exclusions:
        if not args.clean_root:
            die(4, "--check-exclusions 需要至少一个 --clean-root")
        sys.exit(4 if check_exclusions(args.clean_root, rules) else 0)

    if not args.root or not args.out:
        die(4, "需要 --root 与 --out")
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        die(4, "根目录不存在：%s" % root)

    subtrees = (args.subtrees.split(",") if args.subtrees else DEFAULT_SUBTREES)

    lines, errors = [], []
    counters = {"files": 0, "dirs": 0, "links": 0, "canonicalized": 0}
    for name in subtrees:
        p = os.path.join(root, name)
        if not os.path.exists(p) and not os.path.islink(p):
            errors.append("缺少子树：%s" % name)
            continue
        visit(root, name, rules, lines, errors, counters)

    lines.sort()
    blob = ("\n".join(lines) + "\n").encode("utf-8")
    aggregate = hashlib.sha256(blob).hexdigest()

    sub = {}
    for name in subtrees:
        sel = [l for l in lines if l.split("\t", 1)[0] == name
               or l.startswith(esc(name) + "/")]
        sub[name] = {
            "entries": len(sel),
            "sha256": hashlib.sha256(
                ("\n".join(sel) + ("\n" if sel else "")).encode("utf-8")).hexdigest(),
        }

    summary = {
        "schema": SCHEMA,
        "profile": args.profile,
        "root_subtrees": subtrees,
        "source_date_epoch": args.epoch,
        "recipe_sha256": args.recipe_sha,
        "entry_count": len(lines),
        "file_count": counters["files"],
        "dir_count": counters["dirs"],
        "link_count": counters["links"],
        "canonicalized_count": counters["canonicalized"],
        "canonicalized_files": [CANON_FEEDS_CONF] if counters["canonicalized"] else [],
        "aggregate_sha256": aggregate,
        "subtrees": sub,
        "excluded": [
            {"kind": r["kind"], "pattern": r["pattern"], "matches": r["count"]}
            for r in rules if r["count"]
        ],
        "errors": errors,
    }

    tsv = args.tsv or (args.out + ".tsv")
    with open(tsv, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
        f.write("\n")

    print("profile=%s entries=%d files=%d dirs=%d links=%d"
          % (args.profile, len(lines), counters["files"], counters["dirs"],
             counters["links"]))
    print("aggregate=%s" % aggregate)
    print("tsv=%s json=%s" % (tsv, args.out))

    hard = [e for e in errors if not (args.allow_dangling and e.startswith("悬空软链"))]
    if hard:
        for e in hard[:100]:
            print("ERROR %s" % e, file=sys.stderr)
        die(4, "发现 %d 个结构问题（软链越界/悬空/非常规文件/缺子树）" % len(hard))

    if args.compare:
        prev = parse_tsv(args.compare)
        cur = parse_tsv(tsv)
        deltas = []
        for p in sorted(set(prev) | set(cur)):
            if p not in cur:
                deltas.append((p, "audited-only"))
            elif p not in prev:
                deltas.append((p, "fresh-only"))
            elif prev[p] != cur[p]:
                deltas.append((p, "changed"))
        known = load_known_delta(args.known_delta)
        unexplained = []
        for p, d in deltas:
            hit = None
            for k in known:
                if k["direction"] in ("any", d) and fnmatch.fnmatchcase(p, k["glob"]):
                    hit = k
                    break
            if hit is None:
                unexplained.append((p, d))
        print("compare: deltas=%d explained=%d unexplained=%d"
              % (len(deltas), len(deltas) - len(unexplained), len(unexplained)))
        for p, d in deltas[:200]:
            print("DELTA %s %s" % (d, p))
        if unexplained:
            die(5, "指纹与参考值不一致：%d 条未解释差异" % len(unexplained))
        print("FINGERPRINT_MATCH")


if __name__ == "__main__":
    main()
PYEOF
