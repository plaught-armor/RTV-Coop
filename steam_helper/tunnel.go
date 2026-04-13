package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	sw "github.com/plaught-armor/go-steamworks"
)

// peerTunnel represents a UDP tunnel for one remote Steam peer.
type peerTunnel struct {
	steamConn  sw.HSteamNetConnection
	udp        udpBridge
	done       chan struct{}
	closeOnce  sync.Once
	clientAddr atomic.Pointer[net.UDPAddr]
}

func (pt *peerTunnel) closeTunnel() {
	pt.closeOnce.Do(func() { close(pt.done) })
}

// Aliases for readability.
const (
	stateNone                   = int32(sw.ESteamNetworkingConnectionState_None)
	stateConnecting             = int32(sw.ESteamNetworkingConnectionState_Connecting)
	stateFindingRoute           = int32(sw.ESteamNetworkingConnectionState_FindingRoute)
	stateConnected              = int32(sw.ESteamNetworkingConnectionState_Connected)
	stateClosedByPeer           = int32(sw.ESteamNetworkingConnectionState_ClosedByPeer)
	stateProblemDetectedLocally = int32(sw.ESteamNetworkingConnectionState_ProblemDetectedLocally)
)

var (
	listenSocket   sw.HSteamListenSocket
	pollGroup      sw.HSteamNetPollGroup
	tunnelMu       sync.RWMutex
	hostTunnels    map[sw.HSteamNetConnection]*peerTunnel
	knownConns     map[sw.HSteamNetConnection]bool
	clientTunnel   *peerTunnel
	enetServerAddr *net.UDPAddr
	tunnelActive   atomic.Bool

	// Raw symbol for GetConnectionInfo (not wrapped by go-steamworks)
	fnGetConnectionInfo uintptr
	socketsPtr          uintptr
)


func init() {
	hostTunnels = make(map[sw.HSteamNetConnection]*peerTunnel)
	knownConns = make(map[sw.HSteamNetConnection]bool)
}

// initNetworkingSymbols loads raw symbols for APIs not wrapped by go-steamworks.
// Called on the Steam thread after Init().
func initNetworkingSymbols() {
	ptr, err := sw.LookupSymbol("SteamAPI_ISteamNetworkingSockets_GetConnectionInfo")
	if err != nil {
		log.Printf("Cannot resolve GetConnectionInfo: %v", err)
		return
	}
	fnGetConnectionInfo = ptr
	log.Println("Resolved GetConnectionInfo symbol")

	// Resolve the ISteamNetworkingSockets interface pointer
	factoryPtr, err := sw.LookupSymbol("SteamAPI_SteamNetworkingSockets_SteamAPI_v012")
	if err != nil {
		log.Printf("Cannot resolve SteamNetworkingSockets factory: %v", err)
		return
	}
	socketsPtr = sw.CallSymbolPtr(factoryPtr)
	log.Printf("Networking raw symbols loaded (socketsPtr: %x)", socketsPtr)
}

func getConnectionState(conn sw.HSteamNetConnection) int32 {
	if fnGetConnectionInfo == 0 || socketsPtr == 0 {
		return stateNone
	}
	var info sw.SteamNetConnectionInfo_t
	ret := sw.CallSymbolPtr(fnGetConnectionInfo, socketsPtr, uintptr(conn), uintptr(unsafe.Pointer(&info)))
	if ret != 0 {
		return int32(info.State)
	}
	return stateNone
}

// --- Commands (called on the Steam thread) ---

// handleConnectionStatusChange is called from the callback handler on the Steam thread.
func handleConnectionStatusChange(conn sw.HSteamNetConnection, newState int32, oldState int32) {
	if !tunnelActive.Load() {
		return
	}

	ns := sw.SteamNetworkingSockets()

	switch newState {
	case stateConnecting:
		// Host: incoming peer wants to connect
		if listenSocket != 0 {
			result := ns.AcceptConnection(conn)
			if result != sw.EResultOK {
				log.Printf("AcceptConnection failed: %d", result)
				ns.CloseConnection(conn, 0, "", false)
				return
			}
			ns.SetConnectionPollGroup(conn, pollGroup)
			knownConns[conn] = true
			log.Printf("Accepted P2P connection %d", conn)

			tunnelMu.Lock()
			if _, exists := hostTunnels[conn]; !exists {
				udpConn, err := createUDPBridge()
				if err != nil {
					log.Printf("Failed to create UDP for peer %d: %v", conn, err)
					tunnelMu.Unlock()
					return
				}
				pt := &peerTunnel{
					steamConn: conn,
					udp:       udpConn,
					done:      make(chan struct{}),
				}
				hostTunnels[conn] = pt
				go hostUDPToSteamRelay(pt)
				log.Printf("Host tunnel created for connection %d", conn)
			}
			tunnelMu.Unlock()
		}

	case stateConnected:
		log.Printf("P2P connection %d fully connected", conn)

	case stateClosedByPeer, stateProblemDetectedLocally:
		ns.CloseConnection(conn, 0, "", false)
		// Clean up host tunnel
		tunnelMu.Lock()
		if pt, exists := hostTunnels[conn]; exists {
			pt.closeTunnel()
			pt.udp.Close()
			delete(hostTunnels, conn)
			log.Printf("Host tunnel closed for connection %d", conn)
		}
		tunnelMu.Unlock()
		delete(knownConns, conn)
		// Clean up client tunnel
		if clientTunnel != nil && clientTunnel.steamConn == conn {
			clientTunnel.closeTunnel()
			clientTunnel.udp.Close()
			clientTunnel = nil
			tunnelActive.Store(false)
			log.Println("Client P2P connection lost")
		}
	}
}

func cmdStartP2PHost(cmd Command) Response {
	var p struct {
		ENetPort int `json:"enet_port"`
	}
	p.ENetPort = 9050
	if cmd.Params != nil {
		json.Unmarshal(cmd.Params, &p)
	}

	if tunnelActive.Load() {
		return fail("start_p2p_host", "tunnel already active")
	}

	ns := sw.SteamNetworkingSockets()
	listenSocket = ns.CreateListenSocketP2P(0, nil)
	if listenSocket == 0 {
		return fail("start_p2p_host", "failed to create listen socket")
	}

	pollGroup = ns.CreatePollGroup()
	enetServerAddr = &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: p.ENetPort}
	tunnelActive.Store(true)

	log.Printf("P2P host: listenSocket=%d, pollGroup=%d, ENet on :%d", listenSocket, pollGroup, p.ENetPort)
	return ok("start_p2p_host", nil)
}

func cmdStartP2PClient(cmd Command) Response {
	var p struct {
		HostSteamID string `json:"host_steam_id"`
	}
	if cmd.Params != nil {
		json.Unmarshal(cmd.Params, &p)
	}
	if p.HostSteamID == "" {
		return fail("start_p2p_client", "missing host_steam_id")
	}

	var hostID uint64
	fmt.Sscanf(p.HostSteamID, "%d", &hostID)

	if tunnelActive.Load() {
		return fail("start_p2p_client", "tunnel already active")
	}

	var identity sw.SteamNetworkingIdentity
	identity.SetSteamID64(hostID)
	ns := sw.SteamNetworkingSockets()
	conn := ns.ConnectP2P(&identity, 0, nil)
	log.Printf("P2P client: ConnectP2P returned conn=%d", conn)
	if conn == 0 {
		return fail("start_p2p_client", "ConnectP2P failed")
	}

	// Wait for P2P connection to reach Connected state before opening the tunnel.
	// Pump callbacks on this thread so connection status updates are processed.
	log.Println("P2P client: waiting for connection...")
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		pumpManualCallbacks()
		state := getConnectionState(conn)
		if state == stateConnected {
			log.Println("P2P client: connected!")
			break
		}
		if state == stateClosedByPeer || state == stateProblemDetectedLocally {
			return fail("start_p2p_client", fmt.Sprintf("connection failed (state %d)", state))
		}
		time.Sleep(50 * time.Millisecond)
	}
	if getConnectionState(conn) != stateConnected {
		ns.CloseConnection(conn, 0, "", false)
		return fail("start_p2p_client", "connection timed out")
	}

	udpConn, err := createUDPBridge()
	if err != nil {
		return fail("start_p2p_client", fmt.Sprintf("listen: %v", err))
	}

	tunnelPort := udpConn.LocalPort()

	clientTunnel = &peerTunnel{
		steamConn: conn,
		udp:       udpConn,
		done:      make(chan struct{}),
	}
	tunnelActive.Store(true)

	// UDP->Steam relay runs on its own goroutine (no Steam API calls, just UDP reads)
	go clientUDPToSteamRelay(clientTunnel)

	log.Printf("P2P client tunnel on 127.0.0.1:%d -> host %s", tunnelPort, p.HostSteamID)
	return ok("start_p2p_client", map[string]any{
		"tunnel_port": tunnelPort,
	})
}

// --- Tunnel tick (called from Steam thread every 33ms) ---

// tickTunnel is called from the Steam thread's main loop.
// It handles all Steam Networking Sockets polling — no separate goroutines needed.
func tickTunnel() {
	if !tunnelActive.Load() {
		return
	}

	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in tickTunnel: %v", r)
		}
	}()

	ns := sw.SteamNetworkingSockets()

	if listenSocket != 0 {
		tickHost(ns)
	}
	if clientTunnel != nil {
		tickClient(ns)
	}
}

// --- Tunnel stats (logged periodically, never spams) ---
var (
	hostTickCount        int64
	hostSteamRecvTotal   int64
	hostSteamRecvBytes   int64
	hostToENetSendTotal  int64
	hostToENetSendErrors int64
	clientTickCount      int64
	clientSteamRecvTotal int64
	clientSteamRecvBytes int64
	clientToUDPSendTotal int64
	clientToUDPDropped   int64 // dropped because clientAddr not set
)

func tickHost(ns sw.ISteamNetworkingSockets) {
	hostTickCount++

	msgs := ns.ReceiveMessagesOnPollGroup(pollGroup, 32)

	for _, msg := range msgs {
		conn := msg.Connection

		if !knownConns[conn] {
			knownConns[conn] = true
			ns.AcceptConnection(conn)
			ns.SetConnectionPollGroup(conn, pollGroup)
			log.Printf("[host] Accepted P2P connection %d", conn)

			tunnelMu.Lock()
			if _, exists := hostTunnels[conn]; !exists {
				udpConn, err := createUDPBridge()
				if err != nil {
					log.Printf("[host] Failed to create UDP bridge for conn %d: %v", conn, err)
					tunnelMu.Unlock()
					msg.Release()
					continue
				}
				pt := &peerTunnel{
					steamConn: conn,
					udp:       udpConn,
					done:      make(chan struct{}),
				}
				hostTunnels[conn] = pt
				go hostUDPToSteamRelay(pt)
				log.Printf("[host] Tunnel created for conn %d (UDP port %d -> ENet %s)",
					conn, udpConn.LocalPort(), enetServerAddr)
			}
			tunnelMu.Unlock()
		}

		data := copyMsgData(msg)
		msg.Release()
		if data != nil {
			hostSteamRecvTotal++
			hostSteamRecvBytes += int64(len(data))
			tunnelMu.RLock()
			if pt, exists := hostTunnels[conn]; exists {
				err := pt.udp.SendTo(data, enetServerAddr)
				if err != nil {
					hostToENetSendErrors++
					if hostToENetSendErrors <= 5 {
						log.Printf("[host] SendTo ENet failed: %v", err)
					}
				} else {
					hostToENetSendTotal++
				}
			}
			tunnelMu.RUnlock()
		}
	}

	// Periodic stats
	if hostTickCount%1000 == 0 && (hostSteamRecvTotal > 0 || len(knownConns) > 0) {
		log.Printf("[host] stats: tick=%d peers=%d steam_recv=%d/%dB enet_send=%d errors=%d",
			hostTickCount, len(knownConns), hostSteamRecvTotal, hostSteamRecvBytes,
			hostToENetSendTotal, hostToENetSendErrors)
	}

	// Check for disconnected peers
	for conn := range knownConns {
		state := getConnectionState(conn)
		if state == stateClosedByPeer || state == stateProblemDetectedLocally {
			log.Printf("[host] Peer disconnected: conn=%d state=%d", conn, state)
			ns.CloseConnection(conn, 0, "", false)
			tunnelMu.Lock()
			if pt, exists := hostTunnels[conn]; exists {
				pt.closeTunnel()
				pt.udp.Close()
				delete(hostTunnels, conn)
			}
			tunnelMu.Unlock()
			delete(knownConns, conn)
		}
	}
}

func tickClient(ns sw.ISteamNetworkingSockets) {
	pt := clientTunnel
	clientTickCount++

	state := getConnectionState(pt.steamConn)
	if state == stateClosedByPeer || state == stateProblemDetectedLocally {
		log.Printf("[client] Connection lost: conn=%d state=%d", pt.steamConn, state)
		ns.CloseConnection(pt.steamConn, 0, "", false)
		pt.closeTunnel()
		pt.udp.Close()
		clientTunnel = nil
		tunnelActive.Store(false)
		return
	}

	msgs := ns.ReceiveMessagesOnConnection(pt.steamConn, 32)
	ca := pt.clientAddr.Load()

	for _, msg := range msgs {
		data := copyMsgData(msg)
		msg.Release()
		if data == nil {
			continue
		}
		clientSteamRecvTotal++
		clientSteamRecvBytes += int64(len(data))
		if ca != nil {
			pt.udp.SendTo(data, ca)
			clientToUDPSendTotal++
		} else {
			clientToUDPDropped++
		}
	}

	// Log first receive and periodic stats
	if clientSteamRecvTotal > 0 && clientSteamRecvTotal <= 5 {
		log.Printf("[client] Receiving from Steam: %d msgs so far, clientAddr=%v", clientSteamRecvTotal, ca)
	}
	if clientTickCount%1000 == 0 {
		log.Printf("[client] stats: tick=%d conn=%d state=%d steam_recv=%d/%dB udp_send=%d dropped=%d clientAddr=%v",
			clientTickCount, pt.steamConn, state, clientSteamRecvTotal, clientSteamRecvBytes,
			clientToUDPSendTotal, clientToUDPDropped, ca)
	}
}

// --- UDP relay goroutines (no Steam API calls, safe on any goroutine) ---

// hostUDPToSteamRelay reads from a peer's UDP socket and queues data
// to be sent on the Steam thread via a channel.
func hostUDPToSteamRelay(pt *peerTunnel) {
	buf := make([]byte, 2048)
	var recvCount int64
	var recvBytes int64
	var errCount int64
	log.Printf("[host-relay] Started for conn %d (reading ENet responses)", pt.steamConn)
	for {
		select {
		case <-pt.done:
			log.Printf("[host-relay] Stopped for conn %d (recv=%d/%dB errors=%d)", pt.steamConn, recvCount, recvBytes, errCount)
			return
		default:
		}
		pt.udp.SetReadDeadline(time.Now().Add(5 * time.Millisecond))
		n, _, err := pt.udp.Recv(buf)
		if err != nil {
			if !isTimeoutError(err) {
				errCount++
				if errCount <= 3 {
					log.Printf("[host-relay] UDP read error (conn %d): %v", pt.steamConn, err)
				}
			}
			continue
		}
		recvCount++
		recvBytes += int64(n)
		if recvCount <= 3 || recvCount%5000 == 0 {
			log.Printf("[host-relay] ENet -> Steam: %d bytes (total: %d/%dB)", n, recvCount, recvBytes)
		}
		data := make([]byte, n)
		copy(data, buf[:n])
		sendViaSteam(pt.steamConn, data)
	}
}

// clientUDPToSteamRelay reads from the local UDP socket and queues data
// for the Steam thread.
func clientUDPToSteamRelay(pt *peerTunnel) {
	buf := make([]byte, 2048)
	var recvCount int64
	var recvBytes int64
	var errCount int64
	log.Printf("[client-relay] Started (reading ENet client packets on port %d)", pt.udp.LocalPort())
	for {
		select {
		case <-pt.done:
			log.Printf("[client-relay] Stopped (recv=%d/%dB errors=%d)", recvCount, recvBytes, errCount)
			return
		default:
		}
		pt.udp.SetReadDeadline(time.Now().Add(5 * time.Millisecond))
		n, addr, err := pt.udp.Recv(buf)
		if err != nil {
			if !isTimeoutError(err) {
				errCount++
				if errCount <= 3 {
					log.Printf("[client-relay] UDP read error: %v", err)
				}
			}
			continue
		}
		recvCount++
		recvBytes += int64(n)
		if recvCount <= 3 || recvCount%5000 == 0 {
			log.Printf("[client-relay] ENet -> Steam: %d bytes from %v (total: %d/%dB)", n, addr, recvCount, recvBytes)
		}
		pt.clientAddr.Store(addr)
		data := make([]byte, n)
		copy(data, buf[:n])
		sendViaSteam(pt.steamConn, data)
	}
}

// sendViaSteam queues a message to be sent on the Steam thread.
// Uses a non-blocking send to avoid deadlocking if the channel is full.
var steamSendCh = make(chan steamSendMsg, 256)

type steamSendMsg struct {
	conn sw.HSteamNetConnection
	data []byte
}

func sendViaSteam(conn sw.HSteamNetConnection, data []byte) {
	select {
	case steamSendCh <- steamSendMsg{conn: conn, data: data}:
	default:
		sendDropped++
	}
}

// drainSendQueue is called from the Steam thread to flush pending sends.
var (
	sendCount      int64
	sendBytes      int64
	sendErrors     int64
	sendDropped    int64
)

func drainSendQueue() {
	ns := sw.SteamNetworkingSockets()
	for {
		select {
		case msg := <-steamSendCh:
			res, _ := ns.SendMessageToConnection(msg.conn, msg.data,
				sw.SteamNetworkingSend_Unreliable|sw.SteamNetworkingSend_NoNagle)
			sendCount++
			sendBytes += int64(len(msg.data))
			if res != sw.EResultOK {
				sendErrors++
				if sendErrors <= 3 {
					log.Printf("[send] Error: %d bytes to conn %d result=%d", len(msg.data), msg.conn, res)
				}
			}
			if sendCount <= 3 || sendCount%5000 == 0 {
				log.Printf("[send] stats: total=%d/%dB errors=%d dropped=%d", sendCount, sendBytes, sendErrors, sendDropped)
			}
		default:
			return
		}
	}
}

// --- Helpers ---

// isTimeoutError checks if an error is a read timeout (works for both net.UDPConn
// and raw Windows sockets which return WSAETIMEDOUT instead of os.ErrDeadlineExceeded).
func isTimeoutError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, os.ErrDeadlineExceeded) {
		return true
	}
	// net.Error timeout interface
	if ne, ok := err.(interface{ Timeout() bool }); ok && ne.Timeout() {
		return true
	}
	// Raw Windows WSAETIMEDOUT (10060) — string match as fallback
	errStr := err.Error()
	return len(errStr) > 0 && (errStr == "winapi error #10060" || strings.Contains(errStr, "10060"))
}

// copyMsgData copies the payload from a SteamNetworkingMessage before Release().
func copyMsgData(msg *sw.SteamNetworkingMessage) []byte {
	if msg.Size <= 0 || msg.Data == 0 {
		return nil
	}
	src := unsafe.Slice((*byte)(unsafe.Pointer(msg.Data)), msg.Size)
	dst := make([]byte, msg.Size)
	copy(dst, src)
	return dst
}
