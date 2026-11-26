//go:build windows

package main

import "golang.org/x/sys/windows"

const canBindDevice = false

// applySocketOptions 在 DHCP 套接字创建时调用：
// Windows 没有 SO_BINDTODEVICE；DHCP 侧改用客户端指纹过滤（见 dhcp.go），
// 发送侧改用子网定向广播。这里只需要打开 SO_BROADCAST。
func applySocketOptions(fd uintptr, iface string) error {
	return windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_BROADCAST, 1)
}
