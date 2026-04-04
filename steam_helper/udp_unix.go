//go:build !windows

package main

import "net"

// listenUDPCompat on non-Windows just uses standard ListenUDP.
func listenUDPCompat() (*net.UDPConn, error) {
	return net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
}
