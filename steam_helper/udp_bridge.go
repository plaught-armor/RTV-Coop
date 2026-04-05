package main

import (
	"net"
	"time"
)

// udpBridge abstracts UDP socket operations so we can swap implementations.
// Native Windows/Linux uses net.UDPConn. Proton uses raw Windows syscalls
// to bypass Go's wsaioctl(SIO_UDP_CONNRESET) which Wine doesn't support.
type udpBridge interface {
	// SendTo sends data to the specified address.
	SendTo(data []byte, addr *net.UDPAddr) error
	// Recv reads a datagram into buf. Returns bytes read and sender address.
	Recv(buf []byte) (int, *net.UDPAddr, error)
	// SetReadDeadline sets the read timeout.
	SetReadDeadline(t time.Time) error
	// LocalPort returns the local port the socket is bound to.
	LocalPort() int
	// Close closes the socket.
	Close() error
}

// netUDPBridge wraps a standard net.UDPConn.
type netUDPBridge struct {
	conn *net.UDPConn
}

func newNetUDPBridge(conn *net.UDPConn) *netUDPBridge {
	return &netUDPBridge{conn: conn}
}

func (b *netUDPBridge) SendTo(data []byte, addr *net.UDPAddr) error {
	_, err := b.conn.WriteToUDP(data, addr)
	return err
}

func (b *netUDPBridge) Recv(buf []byte) (int, *net.UDPAddr, error) {
	return b.conn.ReadFromUDP(buf)
}

func (b *netUDPBridge) SetReadDeadline(t time.Time) error {
	return b.conn.SetReadDeadline(t)
}

func (b *netUDPBridge) LocalPort() int {
	return b.conn.LocalAddr().(*net.UDPAddr).Port
}

func (b *netUDPBridge) Close() error {
	return b.conn.Close()
}
