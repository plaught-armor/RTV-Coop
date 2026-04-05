//go:build !windows

package main

import "net"

// createUDPBridge on non-Windows just uses standard net.ListenUDP.
func createUDPBridge() (udpBridge, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		return nil, err
	}
	return newNetUDPBridge(conn), nil
}
