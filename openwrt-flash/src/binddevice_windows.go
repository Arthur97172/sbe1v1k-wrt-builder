//go:build windows

package main

import (
	"errors"

	"golang.org/x/sys/windows"
)

const canBindDevice = false

// applySocketOptions 在 DHCP 套接字创建时调用：
// Windows 没有 SO_BINDTODEVICE；DHCP 侧改用客户端指纹过滤（见 dhcp.go），
// 发送侧改用子网定向广播。这里只需要打开 SO_BROADCAST。
func applySocketOptions(fd uintptr, iface string) error {
	return windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_BROADCAST, 1)
}

// isAddrNotAvailable 报告 bind 具体地址失败是否属于"地址尚未出现在本机"。
// Windows 上 netsh 设置地址后由 DHCP Client 服务异步生效，脚本设置完
// 立刻 bind 可能命中 WSAEADDRNOTAVAIL（10049，即 "The requested address
// is not valid in its context"）；注意 syscall.EADDRNOTAVAIL 在 Windows 上
// 是 Go 自己发明的值，不等于该 errno，必须用 WSA 常量比较。
func isAddrNotAvailable(err error) bool {
	return errors.Is(err, windows.WSAEADDRNOTAVAIL)
}
