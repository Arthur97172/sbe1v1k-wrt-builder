// SSH 侧子命令：连接恢复系统（root、空密码），推送镜像、校验 sha256、
// 触发 sysupgrade，并等待新固件启动。连接显式绑定本地源地址，
// 避免多网卡主机把 192.168.1.1 的路由选到别的网卡上。
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

const defaultPassword = ""

// syncWriter 让 stdout 与 stderr 安全地合流进同一个缓冲区。
// x/crypto 用两个 goroutine 分别拷贝 stdout 和 stderr，直接把同一个
// bytes.Buffer 交给会话会并发读写它（不是并发安全的），实测表现为
// 偶发输出全空或整段 NUL 字节（2026-11-27 SBE1V1K 真机复现）。
// x/crypto 自己的 CombinedOutput 也是用带锁的写入器解决同一问题。
type syncWriter struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (w *syncWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.Write(p)
}

func (w *syncWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.String()
}

func runWait(args []string) {
	fs := flag.NewFlagSet("wait", flag.ExitOnError)
	host := fs.String("host", "192.168.1.1", "设备地址")
	local := fs.String("local", "", "本机在该网段上的源地址（必填）")
	timeout := fs.Duration("timeout", 300*time.Second, "总超时")
	fs.Parse(args)
	if *local == "" {
		logf("必须提供 --local")
		os.Exit(1)
	}

	deadline := time.Now().Add(*timeout)
	attempt := 0
	for {
		attempt++
		c, err := sshDial(*host, *local, 6*time.Second)
		if err == nil {
			out, rerr := runCommand(c, "echo READY", 10*time.Second)
			c.Close()
			if rerr == nil && strings.Contains(out, "READY") {
				logf("设备已响应：%s（第 %d 次尝试）", *host, attempt)
				return
			}
		}
		if time.Now().After(deadline) {
			logf("超时：%v 内未能通过 SSH 登录 %s", *timeout, *host)
			os.Exit(4)
		}
		time.Sleep(3 * time.Second)
	}
}

func runCheck(args []string) {
	fs := flag.NewFlagSet("check", flag.ExitOnError)
	host := fs.String("host", "192.168.1.1", "设备地址")
	local := fs.String("local", "", "本机在该网段上的源地址（必填）")
	expect := fs.String("expect", "any", "ram|firmware|any")
	fs.Parse(args)
	if *local == "" {
		logf("必须提供 --local")
		os.Exit(1)
	}

	c, err := sshDial(*host, *local, 10*time.Second)
	if err != nil {
		logf("SSH 连接失败：%v", err)
		os.Exit(2)
	}
	defer c.Close()

	const probe = `. /etc/openwrt_release 2>/dev/null; ` +
		`echo "MODEL=$(cat /tmp/sysinfo/model 2>/dev/null)"; ` +
		`echo "REV=$DISTRIB_REVISION"; ` +
		`echo "DESC=$DISTRIB_DESCRIPTION"; ` +
		`echo "KERNEL=$(uname -r)"; ` +
		`echo "CMDLINE=$(cat /proc/cmdline)"; ` +
		`echo "ROOTFS=$(awk '$2=="/"{print $3}' /proc/mounts)"; ` +
		`echo "ROOTSRC=$(awk '$2=="/"{print $1}' /proc/mounts)"; ` +
		`echo "OVERLAY=$(awk '$2=="/overlay"{print $1}' /proc/mounts)"`
	out, err := runCommand(c, probe, 20*time.Second)
	if err != nil {
		logf("读取设备指纹失败：%v", err)
		os.Exit(2)
	}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		fmt.Printf("  %s\n", line)
	}

	model, rootfs := "", ""
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "MODEL=") {
			model = strings.TrimPrefix(line, "MODEL=")
		}
		if strings.HasPrefix(line, "ROOTFS=") {
			rootfs = strings.TrimPrefix(line, "ROOTFS=")
		}
	}
	// 恢复系统的 cmdline 同样带着 root=/dev/mmcblk0p27（FIT 的 config），
	// 不能拿 cmdline 判断；真正的判据是根文件系统类型：恢复系统跑在 tmpfs，
	// 新固件从 eMMC 上的 squashfs 启动。
	isRAM := rootfs == "tmpfs"

	switch *expect {
	case "ram":
		if !strings.Contains(model, "SBE1V1K") {
			logf("指纹不符：设备型号 %q 不是 SBE1V1K", model)
			os.Exit(3)
		}
		if !isRAM {
			logf("指纹不符：期望 RAM 恢复系统，但根文件系统是 %q（已从 eMMC 启动）", rootfs)
			os.Exit(3)
		}
		logf("已确认：当前是 RAM 恢复系统（rootfs=tmpfs，尚未动 eMMC）")
	case "firmware":
		if !strings.Contains(model, "SBE1V1K") {
			logf("指纹不符：设备型号 %q 不是 SBE1V1K", model)
			os.Exit(3)
		}
		if isRAM {
			logf("指纹不符：期望新固件从 eMMC 启动，但根文件系统是 tmpfs（仍在恢复系统）")
			os.Exit(3)
		}
		logf("已确认：新固件已从 eMMC 启动（rootfs=%s）", rootfs)
	default:
	}
}

func runPush(args []string) {
	fs := flag.NewFlagSet("push", flag.ExitOnError)
	host := fs.String("host", "192.168.1.1", "设备地址")
	local := fs.String("local", "", "本机在该网段上的源地址（必填）")
	src := fs.String("src", "", "本地 sysupgrade 镜像路径")
	remote := fs.String("remote", "/tmp/fw.bin", "设备上的临时路径")
	fs.Parse(args)
	if *local == "" || *src == "" {
		logf("必须提供 --local 与 --src")
		os.Exit(1)
	}

	f, err := os.Open(*src)
	if err != nil {
		logf("打开镜像失败：%v", err)
		os.Exit(2)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		logf("读取镜像信息失败：%v", err)
		os.Exit(2)
	}
	size := st.Size()

	c, err := sshDial(*host, *local, 10*time.Second)
	if err != nil {
		logf("SSH 连接失败：%v", err)
		os.Exit(2)
	}
	defer c.Close()

	sess, err := c.NewSession()
	if err != nil {
		logf("建立会话失败：%v", err)
		os.Exit(2)
	}
	defer sess.Close()
	var remoteOut syncWriter
	sess.Stdout = &remoteOut
	sess.Stderr = &remoteOut
	stdin, err := sess.StdinPipe()
	if err != nil {
		logf("建立管道失败：%v", err)
		os.Exit(2)
	}
	if err := sess.Start("cat > " + *remote + ".part"); err != nil {
		logf("启动上传命令失败：%v", err)
		os.Exit(2)
	}

	h := sha256.New()
	buf := make([]byte, 1<<20)
	var sent int64
	nextMark := int64(0)
	start := time.Now()
	for {
		n, rerr := f.Read(buf)
		if n > 0 {
			if _, werr := stdin.Write(buf[:n]); werr != nil {
				logf("上传中断：%v", werr)
				os.Exit(2)
			}
			h.Write(buf[:n])
			sent += int64(n)
			if sent >= nextMark {
				elapsed := time.Since(start).Seconds()
				rate := float64(sent) / (1 << 20) / elapsed
				logf("上传 %.1f / %.1f MiB（%d%%，%.1f MiB/s）",
					float64(sent)/(1<<20), float64(size)/(1<<20), sent*100/size, rate)
				nextMark = sent + (8 << 20)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			logf("读取镜像失败：%v", rerr)
			os.Exit(2)
		}
	}
	stdin.Close()
	if err := sess.Wait(); err != nil {
		logf("上传命令返回错误：%v（设备输出：%s）", err, strings.TrimSpace(remoteOut.String()))
		os.Exit(2)
	}
	localSum := hex.EncodeToString(h.Sum(nil))

	// 设备端二次校验
	out, err := runCommand(c, "mv "+*remote+".part "+*remote+" && sha256sum "+*remote, 120*time.Second)
	if err != nil {
		logf("设备端 sha256 计算失败：%v", err)
		os.Exit(2)
	}
	fields := strings.Fields(strings.TrimSpace(out))
	if len(fields) == 0 {
		logf("设备端 sha256 输出为空")
		os.Exit(2)
	}
	remoteSum := fields[0]
	fmt.Printf("  本地 sha256：%s\n  设备 sha256：%s\n", localSum, remoteSum)
	if !strings.EqualFold(localSum, remoteSum) {
		logf("sha256 不一致！请勿继续刷写，重新上传后再试")
		os.Exit(2)
	}
	logf("镜像已就绪：%s（sha256 双端一致）", *remote)
}

func runSysupgrade(args []string) {
	fs := flag.NewFlagSet("sysupgrade", flag.ExitOnError)
	host := fs.String("host", "192.168.1.1", "设备地址")
	local := fs.String("local", "", "本机在该网段上的源地址（必填）")
	remote := fs.String("remote", "/tmp/fw.bin", "设备上的镜像路径")
	fs.Parse(args)
	if *local == "" {
		logf("必须提供 --local")
		os.Exit(1)
	}

	c, err := sshDial(*host, *local, 10*time.Second)
	if err != nil {
		logf("SSH 连接失败：%v", err)
		os.Exit(2)
	}
	defer c.Close()

	sess, err := c.NewSession()
	if err != nil {
		logf("建立会话失败：%v", err)
		os.Exit(2)
	}
	defer sess.Close()
	var out syncWriter
	sess.Stdout = &out
	sess.Stderr = &out

	logf("执行 sysupgrade -F -n %s（-F 放行板名差异，-n 不保留旧配置）", *remote)
	runErr := sess.Run("sysupgrade -F -n " + *remote)
	if txt := strings.TrimSpace(out.String()); txt != "" {
		for _, line := range strings.Split(txt, "\n") {
			fmt.Printf("  | %s\n", line)
		}
	}

	if runErr != nil {
		var exitErr *ssh.ExitError
		if errors.As(runErr, &exitErr) {
			// 真机实测（2026-11-27）：恢复系统的 sysupgrade 已经打印
			// "Commencing upgrade" 并进入 do_stage2 后，它在重启过程中对 ubus
			// 的调用会断开，命令以非零状态收尾（实测 246）——但固件实际刷写
			// 成功。是否真正刷写以重启后的指纹为准（脚本会在新系统上做
			// --expect firmware 校验），这里只提示、不当失败。
			logf("sysupgrade 以非零状态收尾（%v）；恢复系统在重启阶段会这样，", runErr)
			logf("不代表未刷写——以设备重启后的指纹校验为准")
			return
		}
		// EOF / ExitMissing 等：设备在刷写过程中重启，属预期
		logf("SSH 会话已断开（设备重启，属正常）")
		return
	}
	logf("sysupgrade 命令已正常返回（未观察到会话断开）")
}

func sshDial(host, localIP string, timeout time.Duration) (*ssh.Client, error) {
	d := net.Dialer{Timeout: timeout}
	if localIP != "" {
		ip := net.ParseIP(localIP)
		if ip == nil {
			return nil, fmt.Errorf("非法的本地地址：%s", localIP)
		}
		d.LocalAddr = &net.TCPAddr{IP: ip}
	}
	addr := net.JoinHostPort(host, "22")
	conn, err := d.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	conn.SetDeadline(time.Now().Add(timeout))

	cfg := &ssh.ClientConfig{
		User:            "root",
		Auth:            []ssh.AuthMethod{ssh.Password(defaultPassword)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(), // 恢复系统每次启动的主机密钥都不同
		Timeout:         timeout,
	}
	cc, chans, reqs, err := ssh.NewClientConn(conn, addr, cfg)
	if err != nil {
		conn.Close()
		return nil, err
	}
	conn.SetDeadline(time.Time{})
	return ssh.NewClient(cc, chans, reqs), nil
}

func runCommand(c *ssh.Client, cmd string, timeout time.Duration) (string, error) {
	sess, err := c.NewSession()
	if err != nil {
		return "", err
	}
	defer sess.Close()

	var out syncWriter
	sess.Stdout = &out
	sess.Stderr = &out

	done := make(chan error, 1)
	go func() { done <- sess.Run(cmd) }()
	select {
	case err := <-done:
		return out.String(), err
	case <-time.After(timeout):
		sess.Close()
		return out.String(), fmt.Errorf("命令超时（%v）", timeout)
	}
}
