// serve 子命令：DHCP(option 43="askey") + TFTP，等待 APPSBL 取走启动器与
// RAM 恢复系统；预期文件传完即退出。
package main

import (
	"flag"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"time"
)

func runServe(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	iface := fs.String("iface", "", "网卡名；留空=测试模式（接受所有来源，回复单播）")
	ipStr := fs.String("ip", "", "本机在该网卡上的地址，如 172.16.252.252")
	root := fs.String("root", "", "TFTP 根目录（只提供该目录下的平坦文件名）")
	expect := fs.String("expect", "initramfs.itb", "传完该文件后退出")
	timeout := fs.Duration("timeout", 900*time.Second, "总超时")
	fs.Parse(args)

	if *ipStr == "" || *root == "" {
		logf("必须提供 --ip 与 --root")
		os.Exit(1)
	}
	serverIP := net.ParseIP(*ipStr).To4()
	if serverIP == nil {
		logf("--ip 不是合法的 IPv4 地址：%s", *ipStr)
		os.Exit(1)
	}
	if st, err := os.Stat(filepath.Join(*root, *expect)); err != nil || !st.Mode().IsRegular() {
		logf("TFTP 根目录里缺少预期文件 %s", *expect)
		os.Exit(1)
	}

	dhcp := newDHCPServer(*iface, serverIP)
	dhcpConn, err := dhcp.listen()
	if err != nil {
		logf("启动 DHCP 服务失败（UDP 67 需要管理员权限）：%v", err)
		os.Exit(2)
	}
	tftp := &tftpServer{root: *root, serverIP: serverIP, expected: *expect}
	tftpConn, err := tftp.listen()
	if err != nil {
		logf("启动 TFTP 服务失败（UDP 69 需要管理员权限）：%v", err)
		os.Exit(2)
	}

	done := make(chan string, 1)
	tftp.done = func(name string) {
		select {
		case done <- name:
		default:
		}
	}

	go dhcp.serve(dhcpConn)
	go tftp.serve(tftpConn)

	if dhcp.testMode {
		logf("测试模式：不绑定网卡、不过滤来源（仅供本机自测）")
	} else if canBindDevice {
		logf("已绑定网卡 %s", *iface)
	} else {
		logf("本平台无网卡绑定能力，DHCP 采用客户端指纹过滤；" +
			"若恢复时无响应，请临时禁用其他网卡后重试")
	}
	logf("DHCP/TFTP 已启动：本机 %s/16，地址池 %s–%s，TFTP 根 %s",
		serverIP.String(), u32ToIP(dhcp.poolStart).String(), u32ToIP(dhcp.poolEnd).String(), *root)
	logf("现在请：路由器断电 → 按住 Reset → 上电 → 约 12 秒后松手（等待设备请求…）")

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)

	select {
	case name := <-done:
		logf("%s 已发送完毕，恢复系统正在启动", name)
		time.Sleep(500 * time.Millisecond)
		os.Exit(0)
	case <-time.After(*timeout):
		logf("超时：%v 内没有完成 %s 的传输", *timeout, *expect)
		os.Exit(4)
	case <-sig:
		fmtPrintln()
		logf("已取消")
		os.Exit(130)
	}
}

func fmtPrintln() {
	// 中断时补一个换行，保持后续输出可读
	os.Stdout.WriteString("\n")
}
