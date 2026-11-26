#!/bin/sh
# 重新生成 bin/ 下的两个自包含二进制（Linux / Windows amd64）。
# 需要 Go 1.26 或更新版本（golang.org/x/crypto 的要求）。
# 纯静态链接、无 CGO，产物可直接拷到离线机器运行。
set -eu

cd "$(dirname "$0")"
GO=${GO:-go}
if ! command -v "$GO" >/dev/null 2>&1 && [ -x /usr/local/go/bin/go ]; then
    GO=/usr/local/go/bin/go
fi

"$GO" mod tidy
"$GO" vet ./...

LDFLAGS='-s -w'
COMMON='-trimpath -buildvcs=false'

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    "$GO" build $COMMON -ldflags="$LDFLAGS" -o ../bin/sbe-flash-tool_linux_amd64 .

CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
    "$GO" build $COMMON -ldflags="$LDFLAGS" -o ../bin/sbe-flash-tool_windows_amd64.exe .

cd ../bin
sha256sum sbe-flash-tool_linux_amd64 sbe-flash-tool_windows_amd64.exe > SHA256SUMS
echo "已生成 bin/SHA256SUMS："
cat SHA256SUMS
