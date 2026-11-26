// DHCP 服务器：复刻 dnsmasq 恢复配置（option 43="askey"、地址池 .10–.20、
// 无网关/无 DNS、租期 5 分钟、总是广播回复），供原厂 APPSBL 取得恢复地址。
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"sync"
	"syscall"
	"time"
)

const dhcpMagicCookie = 0x63825363

type dhcpServer struct {
	iface    string
	testMode bool

	serverIP net.IP
	mask     net.IP

	poolStart uint32
	poolEnd   uint32

	mu     sync.Mutex
	offers map[[6]byte]uint32
	next   uint32
}

func newDHCPServer(iface string, serverIP net.IP) *dhcpServer {
	v4 := serverIP.To4()
	// 与原厂验证过的 dnsmasq 配置一致：地址池取服务器地址前三段，
	// 172.16.252.252 -> 172.16.252.10–172.16.252.20（不是 /16 网段的首地址）
	ip24 := binary.BigEndian.Uint32(v4) & 0xFFFFFF00

	s := &dhcpServer{
		iface:    iface,
		testMode: iface == "",
		serverIP: v4,
		mask:     net.IPv4(255, 255, 0, 0).To4(),
		offers:   map[[6]byte]uint32{},
	}
	s.poolStart = ip24 | 10
	s.poolEnd = ip24 | 20
	s.next = s.poolStart
	return s
}

func (s *dhcpServer) listen() (*net.UDPConn, error) {
	lc := net.ListenConfig{
		Control: func(network, address string, c syscall.RawConn) error {
			var inner error
			if err := c.Control(func(fd uintptr) {
				inner = applySocketOptions(fd, s.iface)
			}); err != nil {
				return err
			}
			return inner
		},
	}
	pc, err := lc.ListenPacket(context.Background(), "udp4", "0.0.0.0:67")
	if err != nil {
		return nil, err
	}
	return pc.(*net.UDPConn), nil
}

func (s *dhcpServer) serve(conn *net.UDPConn) {
	buf := make([]byte, 4096)
	for {
		conn.SetReadDeadline(time.Now().Add(1 * time.Second))
		n, raddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		if n >= 240 {
			s.handle(buf[:n], raddr, conn)
		}
	}
}

func (s *dhcpServer) handle(pkt []byte, raddr *net.UDPAddr, conn *net.UDPConn) {
	if pkt[0] != 1 { // BOOTREQUEST
		return
	}
	if binary.BigEndian.Uint32(pkt[236:240]) != dhcpMagicCookie {
		return
	}
	msgType, prl, vendorClass := parseDHCPOptions(pkt)
	if msgType != 1 && msgType != 3 { // DISCOVER / REQUEST
		return
	}
	// Windows 没有 SO_BINDTODEVICE，无法按网卡过滤接收到的广播，
	// 因此用客户端指纹过滤，避免应答同一台电脑其他网卡（如 Wi-Fi）上的广播。
	if !s.testMode && !canBindDevice && !acceptClient(prl, vendorClass) {
		return
	}

	var mac [6]byte
	copy(mac[:], pkt[28:34])
	yiaddr := s.offerFor(mac)

	replyType := byte(2) // DHCPOFFER
	if msgType == 3 {
		replyType = 5 // DHCPACK
	}
	reply := buildDHCPReply(pkt, replyType, yiaddr, s.serverIP, s.mask)
	s.send(conn, reply, raddr)

	kind := "DISCOVER"
	if msgType == 3 {
		kind = "REQUEST"
	}
	logf("DHCP%s 来自 %s → 分配 %s", kind, net.HardwareAddr(mac[:]).String(), u32ToIP(yiaddr).String())
}

// acceptClient 是跨网卡风险下的客户端指纹过滤：
//   - U-Boot 系 DHCP 客户端会带 vendor class "U-Boot"；
//   - 原厂 APPSBL 的 DISCOVER 不带 vendor class，但参数请求列表（PRL）包含 option 43。
func acceptClient(prl, vendorClass []byte) bool {
	if bytes.Contains(vendorClass, []byte("U-Boot")) {
		return true
	}
	if !bytes.Contains(prl, []byte{43}) {
		return false
	}
	return len(vendorClass) == 0 || bytes.Contains(vendorClass, []byte("U-Boot"))
}

func (s *dhcpServer) offerFor(mac [6]byte) uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ip, ok := s.offers[mac]; ok {
		return ip
	}
	for i := 0; i <= int(s.poolEnd-s.poolStart); i++ {
		cand := s.poolStart + uint32(i)
		inUse := false
		for _, v := range s.offers {
			if v == cand {
				inUse = true
				break
			}
		}
		if !inUse {
			s.offers[mac] = cand
			return cand
		}
	}
	ip := s.next
	s.next++
	s.offers[mac] = ip
	return ip
}

func (s *dhcpServer) send(conn *net.UDPConn, reply []byte, raddr *net.UDPAddr) {
	if s.testMode {
		conn.WriteToUDP(reply, &net.UDPAddr{IP: raddr.IP, Port: 68})
		return
	}
	if canBindDevice {
		// 套接字已绑定到指定网卡，255.255.255.255 只会从该网卡发出。
		if _, err := conn.WriteToUDP(reply, &net.UDPAddr{IP: net.IPv4bcast, Port: 68}); err == nil {
			return
		}
	}
	// Windows / 绑定不可用时：发子网定向广播，路由按网卡上的 /16 地址落到正确接口。
	ip16 := binary.BigEndian.Uint32(s.serverIP.To4()) | 0x0000FFFF
	bcast := u32ToIP(ip16)
	conn.WriteToUDP(reply, &net.UDPAddr{IP: bcast, Port: 68})
}

// parseDHCPOptions 返回消息类型（option 53）、参数请求列表（option 55）、
// vendor class（option 60）。缺少 option 53 时返回 0。
func parseDHCPOptions(pkt []byte) (msgType byte, prl, vendorClass []byte) {
	i := 240
	for i < len(pkt) {
		code := pkt[i]
		if code == 0 {
			i++
			continue
		}
		if code == 255 {
			break
		}
		if i+1 >= len(pkt) {
			break
		}
		l := int(pkt[i+1])
		if i+2+l > len(pkt) {
			break
		}
		val := pkt[i+2 : i+2+l]
		switch code {
		case 53:
			if l >= 1 {
				msgType = val[0]
			}
		case 55:
			prl = val
		case 60:
			vendorClass = val
		}
		i += 2 + l
	}
	return
}

func buildDHCPReply(req []byte, msgType byte, yiaddr uint32, serverIP, mask net.IP) []byte {
	b := make([]byte, 240)
	b[0] = 2                   // BOOTREPLY
	b[1] = 1                   // 以太网
	b[2] = 6                   // 地址长度
	copy(b[4:8], req[4:8])     // xid
	copy(b[10:12], req[10:12]) // flags（保留广播位）
	binary.BigEndian.PutUint32(b[16:20], yiaddr)
	copy(b[20:24], serverIP)   // siaddr
	copy(b[28:44], req[28:44]) // chaddr
	binary.BigEndian.PutUint32(b[236:240], dhcpMagicCookie)

	opts := make([]byte, 0, 64)
	opts = append(opts, 53, 1, msgType)
	opts = append(opts, 54, 4)
	opts = append(opts, serverIP...)
	opts = append(opts, 51, 4, 0, 0, 0x01, 0x2c) // 租期 300 s
	opts = append(opts, 1, 4)
	opts = append(opts, mask...)
	opts = append(opts, 43, 5)
	opts = append(opts, []byte("askey")...)
	opts = append(opts, 255)

	b = append(b, opts...)
	for len(b) < 300 {
		b = append(b, 0)
	}
	return b
}

func u32ToIP(v uint32) net.IP {
	ip := make(net.IP, 4)
	binary.BigEndian.PutUint32(ip, v)
	return ip
}
