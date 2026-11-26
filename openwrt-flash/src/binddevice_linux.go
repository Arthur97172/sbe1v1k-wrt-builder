//go:build linux

package main

import "syscall"

const canBindDevice = true
const soBindToDevice = 25 // linux: SOL_SOCKET 下的 SO_BINDTODEVICE

// applySocketOptions 在 DHCP 套接字创建时调用：
// 必须打开 SO_BROADCAST，否则发往 255.255.255.255 / 定向广播的应答会被内核拒绝；
// 指定网卡时再用 SO_BINDTODEVICE 把套接字钉在那张网卡上。
func applySocketOptions(fd uintptr, iface string) error {
	if err := syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_BROADCAST, 1); err != nil {
		return err
	}
	if iface != "" {
		return syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, soBindToDevice, iface)
	}
	return nil
}
