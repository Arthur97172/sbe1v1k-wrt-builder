// sbe1v1k-flash-tool：SBE1V1K 恢复模式刷机用的自包含辅助工具。
//
// 子命令：
//
//	serve       通过指定网卡提供 DHCP(option 43="askey") + TFTP 服务，
//	            把启动器与 RAM 恢复系统交给原厂 APPSBL，传完预期文件后退出。
//	wait        轮询等待恢复系统（或刷机后的新固件）的 SSH 就绪。
//	check       登录并打印设备指纹；按 --expect 校验是 RAM 系统还是新固件。
//	push        上传 sysupgrade 镜像到设备 /tmp，并在设备端做 sha256 比对。
//	sysupgrade  在设备上执行 sysupgrade -F -n，等待会话被重启打断。
//
// 运行时不访问互联网；只与直连设备交换 DHCP/TFTP/SSH 流量。
package main

import (
	"fmt"
	"os"
	"time"
)

const toolVersion = "1.0.3"

func logf(format string, a ...any) {
	fmt.Printf("[%s] ", time.Now().Format("15:04:05"))
	fmt.Printf(format+"\n", a...)
}

func usage() {
	fmt.Fprintf(os.Stderr, `sbe1v1k-flash-tool %s

用法:
  sbe1v1k-flash-tool serve --iface <网卡> --ip 172.16.252.252 --root <TFTP根目录> [--expect initramfs.itb] [--timeout 900]
  sbe1v1k-flash-tool wait  --host 192.168.1.1 --local 192.168.1.2 [--timeout 300]
  sbe1v1k-flash-tool check --host 192.168.1.1 --local 192.168.1.2 [--expect ram|firmware|any]
  sbe1v1k-flash-tool push  --host 192.168.1.1 --local 192.168.1.2 --src <固件.bin> [--remote /tmp/fw.bin]
  sbe1v1k-flash-tool sysupgrade --host 192.168.1.1 --local 192.168.1.2 [--remote /tmp/fw.bin]
  sbe1v1k-flash-tool version

退出码: 0 成功 | 2 运行错误 | 3 指纹不符 | 4 超时
`, toolVersion)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "serve":
		runServe(args)
	case "wait":
		runWait(args)
	case "check":
		runCheck(args)
	case "push":
		runPush(args)
	case "sysupgrade":
		runSysupgrade(args)
	case "version", "--version", "-version":
		fmt.Printf("sbe1v1k-flash-tool %s\n", toolVersion)
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "未知子命令：%s\n\n", cmd)
		usage()
		os.Exit(1)
	}
}
