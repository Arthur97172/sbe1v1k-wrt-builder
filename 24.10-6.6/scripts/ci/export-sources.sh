#!/usr/bin/env bash
# 把装配好的源码树打成**一个**可复现的 tar.zst，并产出发布用的三个资产。
#
# 用法：scripts/ci/export-sources.sh --stage <stage> [--out <目录>]
#
#   --stage   assemble-sources.sh 的产出目录：要有 sources/、fingerprint.json、
#             fingerprint.tsv。本脚本不重新装配、不重新计算指纹。
#   --out     输出目录（默认 <stage>/dist）。
#
# 产出（恰好三个文件，都相对 --out）：
#   sbe1v1k-sources-24.10-6.6.tar.zst   源码树（顶层：buildroot/ luci/ apps/
#                                       thirdparty/ thirdparty-feed/ passwall-selected/
#                                       local-relayout/ README.md PROVENANCE.md
#                                       TREE-FINGERPRINT.json TREE-FINGERPRINT.tsv）
#   SHA256SUMS                           只含上面那个 tar
#   TREE-FINGERPRINT.json                指纹（与 tar 内副本一致），供构建端 --compare
#
# 排除项与 tree-fingerprint.sh 共用 build/fingerprint-exclude.conf：排除的东西
# 都能由构建过程重建（build_dir、dl、feeds 索引、VCS 元数据…），且被排除的部分
# 由构建端的断言单独检查。
#
# 确定性：--sort=name --mtime=@1792557977 --owner=0 --group=0 --numeric-owner，
# 不写 pax 扩展头（--format=gnu），zstd 单线程 -19。tar 字节数因此只随内容变化；
# 但**不承诺**与历史发布逐字节相同（zstd 版本会变），指纹才是可比的那一层。
#
# 退出码：0 PASS、4 ASSERTION_FAILED、6 SIZE_LIMIT。

set -Eeuo pipefail
LC_ALL=C
export LC_ALL

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ=$(CDPATH= cd -- "$SELF/../.." && pwd)
BUILD="$PROJ/build"
EPOCH=1792557977
MAX_BYTES=${SBE_MAX_TAR_BYTES:-1900000000}
NAME=sbe1v1k-sources-24.10-6.6.tar.zst

die() { printf 'FAIL  %s\n' "$*" >&2; exit "${2:-4}"; }

STAGE=""; OUT=""
while [ $# -gt 0 ]; do
	case "$1" in
	--stage) STAGE=${2:?--stage 需要目录}; shift 2 ;;
	--out)   OUT=${2:?--out 需要目录}; shift 2 ;;
	-h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "未知参数：$1" ;;
	esac
done
[ -n "$STAGE" ] || die "需要 --stage <目录>"
STAGE=$(CDPATH= cd -- "$STAGE" && pwd)
SRC="$STAGE/sources"
OUT=${OUT:-$STAGE/dist}
mkdir -p "$OUT"

[ -d "$SRC" ] || die "缺少 $SRC"
[ -f "$STAGE/fingerprint.json" ] || die "缺少 $STAGE/fingerprint.json（先跑 assemble-sources.sh）"
[ -f "$STAGE/fingerprint.tsv" ] || die "缺少 $STAGE/fingerprint.tsv"
[ -f "$BUILD/fingerprint-exclude.conf" ] || die "缺少 build/fingerprint-exclude.conf"
command -v zstd >/dev/null || die "缺少 zstd"

# ---------------------------------------------------------------- 排除清单翻译
# fingerprint-exclude.conf 的三种规则 → tar --exclude 模式：
#   dir  <前缀>/   → <前缀>          （GNU tar 命中目录即整棵跳过）
#   path <路径>     → <路径>
#   glob <通配>     → <通配>          （tar 的 * 默认跨 /）
EXCL=$(mktemp)
trap 'rm -f "$EXCL"' EXIT
while IFS=$'\t' read -r kind pat; do
	[ -n "${kind:-}" ] || continue
	case "$kind" in \#*) continue ;; esac
	case "$kind" in
	dir)  printf '%s\n' "${pat%/}" >> "$EXCL" ;;
	path) printf '%s\n' "$pat" >> "$EXCL" ;;
	glob) printf '%s\n' "$pat" >> "$EXCL" ;;
	*) die "排除清单 kind 非法：$kind" ;;
	esac
done < "$BUILD/fingerprint-exclude.conf"
n_excl=$(wc -l < "$EXCL")
[ "$n_excl" -gt 0 ] || die "排除清单为空"

# ---------------------------------------------------------------- 打包
# 指纹文件先落进 sources/ 再打包：它们不在指纹的子树清单里，所以先放后放
# 都不影响聚合值，但必须在 tar 之前放，否则包里没有可比对的基准。
cp -f "$STAGE/fingerprint.json" "$SRC/TREE-FINGERPRINT.json"
cp -f "$STAGE/fingerprint.tsv"  "$SRC/TREE-FINGERPRINT.tsv"

TMP="$OUT/.$NAME.tmp"
rm -f "$TMP"
echo "[export] 打包 $SRC → $NAME（排除 $n_excl 条规则）" >&2
tar -C "$SRC" \
	--sort=name --format=gnu \
	--mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner \
	--exclude-from="$EXCL" \
	-cf - . | zstd -19 -T1 -q -o "$TMP" \
	|| die "tar/zstd 失败"
mv -f "$TMP" "$OUT/$NAME"

bytes=$(stat -c '%s' "$OUT/$NAME")
if [ "$bytes" -ge "$MAX_BYTES" ]; then
	die "SIZE_LIMIT：$NAME 为 $((bytes / 1000 / 1000)) MB，超过上限 $((MAX_BYTES / 1000 / 1000)) MB" 6
fi

# ---------------------------------------------------------------- 清单与指纹
( cd "$OUT" && sha256sum "$NAME" > SHA256SUMS ) || die "sha256sum 失败"
cp -f "$STAGE/fingerprint.json" "$OUT/TREE-FINGERPRINT.json"

# 清单只解压一次：156k 条目、218 MB 的 zstd，反复列等于反复解压。更重要的是
# 不能写成 `tar -t … | grep -q …`——grep -q 命中即退出会让 tar 吃到 SIGPIPE，
# 在 pipefail 下这条管道整体判失败，断言就变成了“看谁先跑完”的竞态。
LISTING=$(mktemp)
trap 'rm -f "$EXCL" "$LISTING"' EXIT
tar -tf "$OUT/$NAME" > "$LISTING" 2>/dev/null || die "无法读取 $NAME 的清单"

grep -qx './TREE-FINGERPRINT.json' "$LISTING" || die "tar 里没有 TREE-FINGERPRINT.json（打包顺序错误）"
grep -qx './TREE-FINGERPRINT.tsv'  "$LISTING" || die "tar 里没有 TREE-FINGERPRINT.tsv（打包顺序错误）"

# 反向断言：排除清单里最容易“看起来生效、其实没生效”的几类，必须真的不在包里。
# 少了这一步，一个拼写错的排除规则会让包悄悄胖 1 GB 且带着宿主 .git。
forbidden=$(grep -E '(^|/)\.git/|^\./buildroot/build_dir/|^\./buildroot/dl/|^\./buildroot/staging_dir/|^\./buildroot/tmp/|^\./buildroot/feeds/[^/]*\.tmp/' \
	"$LISTING" | head -5 || true)
if [ -n "$forbidden" ]; then
	die "排除未生效，包里出现不该有的内容：$(printf '\n  %s' $forbidden)"
fi

# ---------------------------------------------------------------- 资产断言
mapfile -t assets < <(find "$OUT" -maxdepth 1 -type f | sed 's|.*/||' | LC_ALL=C sort)
[ "${#assets[@]}" = 3 ] || die "输出目录应恰好 3 个文件，实际 ${#assets[@]}：${assets[*]}"
for want in "$NAME" SHA256SUMS TREE-FINGERPRINT.json; do
	found=0
	for a in "${assets[@]}"; do [ "$a" = "$want" ] && found=1; done
	[ "$found" = 1 ] || die "缺少资产：$want"
done

agg=$(sed -n 's/.*"aggregate_sha256": "\([0-9a-f]*\)".*/\1/p' "$OUT/TREE-FINGERPRINT.json")
entries=$(sed -n 's/.*"entry_count": \([0-9]*\).*/\1/p' "$OUT/TREE-FINGERPRINT.json")
# 对称性断言：tar 成员数 = 指纹条目数 + 3（根目录 ./ 与两份包根指纹副本）。
# 两侧共用同一份排除清单，所以只要有一条规则只在一边生效（比如 dir 规则翻译成
# 前缀后没命中 tar，或指纹那边多排除了东西），这里就会不等。它同时证明包里
# 没有夹带指纹之外的构建产物——那些东西一旦进包，解包后的指纹比对也发现不了。
[ -n "$entries" ] || die "无法从 TREE-FINGERPRINT.json 读出 entry_count"
n_list=$(wc -l < "$LISTING")
[ "$n_list" = "$((entries + 3))" ] || die "tar 成员数 $n_list ≠ 指纹条目数 $entries + 3（排除规则两侧不一致）"

echo "[export] PASS" >&2
echo "  $OUT/$NAME  $((bytes / 1000 / 1000)) MB  sha256=$(cut -d' ' -f1 "$OUT/SHA256SUMS")" >&2
echo "  assets=${#assets[@]}  entries=$entries  aggregate=$agg" >&2
