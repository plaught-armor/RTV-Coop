//go:build windows

package main

import (
	"fmt"
	"log"
	"net"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// rawUDPBridge uses raw Windows syscalls to create and operate a UDP socket.
// Bypasses Go's net.ListenUDP which calls WSAIoctl(SIO_UDP_CONNRESET) — unsupported by Wine.
type rawUDPBridge struct {
	sock windows.Handle
	port int
}

func newRawUDPBridge() (*rawUDPBridge, error) {
	sock, err := windows.Socket(windows.AF_INET, windows.SOCK_DGRAM, windows.IPPROTO_UDP)
	if err != nil {
		return nil, fmt.Errorf("socket: %w", err)
	}

	sa := &windows.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}
	if err = windows.Bind(sock, sa); err != nil {
		windows.Closesocket(sock)
		return nil, fmt.Errorf("bind: %w", err)
	}

	localSa, err := windows.Getsockname(sock)
	if err != nil {
		windows.Closesocket(sock)
		return nil, fmt.Errorf("getsockname: %w", err)
	}
	localAddr := localSa.(*windows.SockaddrInet4)

	log.Printf("Raw UDP socket created on 127.0.0.1:%d", localAddr.Port)
	return &rawUDPBridge{sock: sock, port: localAddr.Port}, nil
}

func (r *rawUDPBridge) SendTo(data []byte, addr *net.UDPAddr) error {
	sa := &windows.SockaddrInet4{Port: addr.Port}
	copy(sa.Addr[:], addr.IP.To4())
	return windows.Sendto(r.sock, data, 0, sa)
}

func (r *rawUDPBridge) Recv(buf []byte) (int, *net.UDPAddr, error) {
	n, from, err := windows.Recvfrom(r.sock, buf, 0)
	if err != nil {
		return 0, nil, err
	}
	var addr *net.UDPAddr
	if sa, ok := from.(*windows.SockaddrInet4); ok {
		addr = &net.UDPAddr{
			IP:   net.IPv4(sa.Addr[0], sa.Addr[1], sa.Addr[2], sa.Addr[3]),
			Port: sa.Port,
		}
	}
	return int(n), addr, nil
}

func (r *rawUDPBridge) SetReadDeadline(t time.Time) error {
	var ms int32
	if t.IsZero() {
		ms = 0 // No timeout
	} else {
		d := time.Until(t)
		if d <= 0 {
			ms = 1
		} else {
			ms = int32(d.Milliseconds())
		}
	}
	// SO_RCVTIMEO expects milliseconds as DWORD on Windows
	return windows.SetsockoptInt(r.sock, windows.SOL_SOCKET, windows.SO_RCVTIMEO, int(ms))
}

func (r *rawUDPBridge) LocalPort() int {
	return r.port
}

func (r *rawUDPBridge) Close() error {
	return windows.Closesocket(r.sock)
}

// createUDPBridge tries net.ListenUDP first, falls back to raw syscalls for Wine/Proton.
func createUDPBridge() (udpBridge, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err == nil {
		return newNetUDPBridge(conn), nil
	}
	log.Printf("net.ListenUDP failed (%v), using raw socket", err)
	return newRawUDPBridge()
}

// SetReadDeadline for raw sockets uses SetsockoptInt with SO_RCVTIMEO.
// The DWORD size is platform-dependent. Ensure correct size:
func init() {
	// Verify DWORD is 4 bytes (sanity check)
	if unsafe.Sizeof(int32(0)) != 4 {
		panic("unexpected int32 size")
	}
}
