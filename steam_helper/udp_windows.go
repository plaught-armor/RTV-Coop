//go:build windows

package main

import (
	"fmt"
	"log"
	"net"

	"golang.org/x/sys/windows"
)

// listenUDPCompat creates a UDP socket compatible with Wine/Proton.
// Go's net.ListenUDP unconditionally calls WSAIoctl(SIO_UDP_CONNRESET)
// which Wine doesn't support, causing socket creation to fail.
// We fall back to raw syscalls, bypassing Go's net package entirely.
func listenUDPCompat() (*net.UDPConn, error) {
	// Try standard first (works on native Windows)
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err == nil {
		return conn, nil
	}
	log.Printf("ListenUDP failed (%v), using raw socket fallback", err)

	// Raw syscall fallback for Wine/Proton
	sock, sErr := windows.Socket(windows.AF_INET, windows.SOCK_DGRAM, windows.IPPROTO_UDP)
	if sErr != nil {
		return nil, fmt.Errorf("raw socket: %w", sErr)
	}

	// Try the ioctl but ignore failure (Wine returns WSAEOPNOTSUPP)
	var bytesReturned uint32
	rawFalse := [4]byte{0, 0, 0, 0}
	_ = windows.WSAIoctl(sock, 0x9800000C, // SIO_UDP_CONNRESET
		&rawFalse[0], 4, nil, 0, &bytesReturned, nil, 0)

	sa := windows.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}
	if sErr = windows.Bind(sock, &sa); sErr != nil {
		windows.Closesocket(sock)
		return nil, fmt.Errorf("raw bind: %w", sErr)
	}

	// Set non-blocking for Go's runtime poller
	if sErr = windows.SetNonblock(sock, true); sErr != nil {
		windows.Closesocket(sock)
		return nil, fmt.Errorf("nonblock: %w", sErr)
	}

	// Wrap raw socket as net.UDPConn via net.FilePacketConn
	// On Windows, we need to use the approach of creating a net.Conn from a raw handle
	// Unfortunately net.FilePacketConn doesn't work on Windows.
	// Instead, wrap with our own UDPConn-like type using Recvfrom/Sendto.
	// But tunnel.go expects *net.UDPConn...

	// Alternative: just use the raw handle directly through a thin wrapper
	// For now, store the handle and use rawUDP functions
	windows.Closesocket(sock)

	// Since we can't get a net.UDPConn from a raw Windows handle,
	// return nil and let the caller use rawUDPConn instead
	return nil, fmt.Errorf("wine-compat: use rawUDPConn")
}

// rawUDPConn wraps a raw Windows socket handle for UDP operations.
type rawUDPConn struct {
	sock windows.Handle
	port int
}

func newRawUDPConn() (*rawUDPConn, error) {
	sock, err := windows.Socket(windows.AF_INET, windows.SOCK_DGRAM, windows.IPPROTO_UDP)
	if err != nil {
		return nil, fmt.Errorf("socket: %w", err)
	}

	sa := &windows.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}
	if err = windows.Bind(sock, sa); err != nil {
		windows.Closesocket(sock)
		return nil, fmt.Errorf("bind: %w", err)
	}

	// Get assigned port
	localSa, err := windows.Getsockname(sock)
	if err != nil {
		windows.Closesocket(sock)
		return nil, fmt.Errorf("getsockname: %w", err)
	}
	localAddr := localSa.(*windows.SockaddrInet4)

	return &rawUDPConn{sock: sock, port: localAddr.Port}, nil
}

func (r *rawUDPConn) sendTo(data []byte, addr *net.UDPAddr) error {
	sa := &windows.SockaddrInet4{Port: addr.Port}
	copy(sa.Addr[:], addr.IP.To4())
	return windows.Sendto(r.sock, data, 0, sa)
}

func (r *rawUDPConn) recvFrom(buf []byte) (int, error) {
	// Set a read timeout via select
	n, _, err := windows.Recvfrom(r.sock, buf, 0)
	return n, err
}

func (r *rawUDPConn) close() {
	windows.Closesocket(r.sock)
}
