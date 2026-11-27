// TFTP 服务器：把 TFTP 根目录下的文件交给 APPSBL 的 tftpboot。
// 只读，只接受平坦文件名（防目录穿越）；支持 blksize/timeout/tsize 选项。
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const tftpMaxBlkSize = 1468 // 与启动器中的 tftpblocksize 一致，限制内存占用

type tftpServer struct {
	root     string
	serverIP net.IP
	expected string
	done     func(name string)
}

func (s *tftpServer) listen() (*net.UDPConn, error) {
	// 地址配置完成到 socket 层可用之间可能有延迟（Windows 经 DHCP Client
	// 服务异步应用地址），此时 bind 具体地址会返回 EADDRNOTAVAIL。重试一段
	// 时间等地址生效；其他错误（端口占用、权限）立即返回。
	deadline := time.Now().Add(30 * time.Second)
	for {
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: s.serverIP, Port: 69})
		if err == nil {
			return conn, nil
		}
		if !isAddrNotAvailable(err) || time.Now().After(deadline) {
			return nil, err
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func (s *tftpServer) serve(conn *net.UDPConn) {
	buf := make([]byte, 2048)
	for {
		conn.SetReadDeadline(time.Now().Add(1 * time.Second))
		n, raddr, err := conn.ReadFromUDP(buf)
		if err != nil || n < 4 {
			continue
		}
		data := make([]byte, n)
		copy(data, buf[:n])
		go s.handle(data, raddr)
	}
}

func (s *tftpServer) handle(data []byte, raddr *net.UDPAddr) {
	opcode := binary.BigEndian.Uint16(data[0:2])
	switch opcode {
	case 2: // WRQ
		s.sendError(raddr, 2, "write not supported")
		return
	case 1: // RRQ
	default:
		return
	}

	parts := splitNul(data[2:])
	if len(parts) < 2 {
		s.sendError(raddr, 4, "bad request")
		return
	}
	filename := parts[0]
	base := filepath.Base(filename)
	if filename == "" || base != filename || strings.ContainsAny(filename, "/\\") || strings.HasPrefix(filename, ".") {
		s.sendError(raddr, 2, "access violation")
		return
	}

	opts := map[string]string{}
	for i := 2; i+1 < len(parts); i += 2 {
		opts[strings.ToLower(parts[i])] = parts[i+1]
	}

	path := filepath.Join(s.root, base)
	f, err := os.Open(path)
	if err != nil {
		logf("TFTP 请求 %s：文件不存在", filename)
		s.sendError(raddr, 1, "file not found")
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		s.sendError(raddr, 2, "access violation")
		return
	}

	blksize := 512
	oack := make([]string, 0, 6)
	if v, ok := opts["blksize"]; ok {
		if n, err := strconv.Atoi(v); err == nil && n >= 8 {
			if n > tftpMaxBlkSize {
				n = tftpMaxBlkSize
			}
			blksize = n
			oack = append(oack, "blksize", strconv.Itoa(n))
		}
	}
	timeout := 1 * time.Second
	if v, ok := opts["timeout"]; ok {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 5 {
			timeout = time.Duration(n) * time.Second
			oack = append(oack, "timeout", strconv.Itoa(n))
		}
	}
	if v, ok := opts["tsize"]; ok && v == "0" {
		oack = append(oack, "tsize", strconv.FormatInt(st.Size(), 10))
	}

	logf("TFTP 请求 %s（%d 字节，blksize %d）← %s", filename, st.Size(), blksize, raddr.IP)

	if err := s.sendFile(f, st.Size(), blksize, timeout, oack, raddr); err != nil {
		logf("TFTP 传输 %s 失败：%v", filename, err)
		return
	}
	logf("TFTP 完成 %s（%d 字节）", filename, st.Size())
	if s.done != nil && filename == s.expected {
		s.done(filename)
	}
}

func (s *tftpServer) sendFile(f *os.File, size int64, blksize int, timeout time.Duration, oack []string, raddr *net.UDPAddr) error {
	xfer, err := net.ListenUDP("udp4", &net.UDPAddr{IP: s.serverIP})
	if err != nil {
		return err
	}
	defer xfer.Close()

	send := func(pkt []byte) error {
		_, err := xfer.WriteToUDP(pkt, raddr)
		return err
	}
	waitAck := func(block uint16) error {
		ack := make([]byte, 128)
		for {
			xfer.SetReadDeadline(time.Now().Add(timeout))
			n, from, err := xfer.ReadFromUDP(ack)
			if err != nil {
				return err
			}
			if !from.IP.Equal(raddr.IP) || n < 4 {
				continue
			}
			switch binary.BigEndian.Uint16(ack[0:2]) {
			case 4:
				if binary.BigEndian.Uint16(ack[2:4]) == block {
					return nil
				}
				// 其它块的 ACK（重复 ACK）忽略
			case 5:
				return fmt.Errorf("客户端报错：%s", strings.TrimRight(string(ack[4:n]), "\x00"))
			}
		}
	}

	// OACK 先导（若客户端请求了可协商的选项）
	if len(oack) > 0 {
		pkt := []byte{0, 6}
		for _, opt := range oack {
			pkt = append(pkt, []byte(opt)...)
			pkt = append(pkt, 0)
		}
		for try := 0; ; try++ {
			if err := send(pkt); err != nil {
				return err
			}
			if err := waitAck(0); err == nil {
				break
			} else if try >= 5 {
				return err
			}
		}
	}

	var block uint16 = 1
	var sent int64
	nextMark := int64(0)
	buf := make([]byte, 4+blksize)
	for {
		n := int64(blksize)
		if left := size - sent; left < n {
			n = left
			if n < 0 {
				n = 0
			}
		}
		if _, err := io.ReadFull(f, buf[4:4+n]); err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
			return err
		}
		binary.BigEndian.PutUint16(buf[0:2], 3)
		binary.BigEndian.PutUint16(buf[2:4], block)
		pkt := buf[:4+n]
		for try := 0; ; try++ {
			if err := send(pkt); err != nil {
				return err
			}
			err := waitAck(block)
			if err == nil {
				break
			}
			if _, ok := err.(net.Error); !ok || try >= 5 {
				return fmt.Errorf("等待 ACK 块 %d 失败：%v", block, err)
			}
		}
		sent += n
		block++
		if size > 0 && sent >= nextMark {
			logf("TFTP 进度 %.1f / %.1f MiB（%d%%）", float64(sent)/(1<<20), float64(size)/(1<<20), sent*100/size)
			nextMark = sent + (2 << 20)
		}
		if n < int64(blksize) {
			return nil
		}
	}
}

func (s *tftpServer) sendError(raddr *net.UDPAddr, code uint16, msg string) {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: s.serverIP})
	if err != nil {
		return
	}
	defer c.Close()
	pkt := []byte{0, 5}
	pkt = binary.BigEndian.AppendUint16(pkt, code)
	pkt = append(pkt, []byte(msg)...)
	pkt = append(pkt, 0)
	c.WriteToUDP(pkt, raddr)
}

func splitNul(b []byte) []string {
	var out []string
	start := 0
	for i, c := range b {
		if c == 0 {
			out = append(out, string(b[start:i]))
			start = i + 1
		}
	}
	if start < len(b) {
		out = append(out, string(b[start:]))
	}
	return out
}
