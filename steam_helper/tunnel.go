package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	sw "github.com/badhex/go-steamworks"
)

// peerTunnel represents a UDP tunnel for one remote Steam peer.
type peerTunnel struct {
	steamConn  sw.HSteamNetConnection
	udpConn    *net.UDPConn
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
				udpConn, err := listenUDPCompat()
				if err != nil {
					log.Printf("Failed to create UDP for peer %d: %v", conn, err)
					tunnelMu.Unlock()
					return
				}
				pt := &peerTunnel{
					steamConn: conn,
					udpConn:   udpConn,
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
			pt.udpConn.Close()
			delete(hostTunnels, conn)
			log.Printf("Host tunnel closed for connection %d", conn)
		}
		tunnelMu.Unlock()
		delete(knownConns, conn)
		// Clean up client tunnel
		if clientTunnel != nil && clientTunnel.steamConn == conn {
			clientTunnel.closeTunnel()
			clientTunnel.udpConn.Close()
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

	udpConn, err := listenUDPCompat()
	if err != nil {
		return fail("start_p2p_client", fmt.Sprintf("listen: %v", err))
	}

	tunnelPort := udpConn.LocalAddr().(*net.UDPAddr).Port

	clientTunnel = &peerTunnel{
		steamConn: conn,
		udpConn:   udpConn,
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

var hostTickCount int

func tickHost(ns sw.ISteamNetworkingSockets) {
	hostTickCount++
	if hostTickCount <= 3 {
		log.Printf("tickHost: about to ReceiveMessagesOnPollGroup (tick %d, pollGroup=%d)", hostTickCount, pollGroup)
	}
	// Receive messages from all peers via poll group
	msgs := ns.ReceiveMessagesOnPollGroup(pollGroup, 32)
	if hostTickCount <= 3 {
		log.Printf("tickHost: ReceiveMessagesOnPollGroup returned %d msgs (tick %d)", len(msgs), hostTickCount)
	}
	if len(msgs) > 0 {
		log.Printf("tickHost: received %d messages (tick %d)", len(msgs), hostTickCount)
	}

	for _, msg := range msgs {
		conn := msg.Connection

		if !knownConns[conn] {
			// New connection — accept it
			knownConns[conn] = true
			ns.AcceptConnection(conn)
			ns.SetConnectionPollGroup(conn, pollGroup)
			log.Printf("Accepted P2P connection %d", conn)

			tunnelMu.Lock()
			if _, exists := hostTunnels[conn]; !exists {
				udpConn, err := listenUDPCompat()
				if err != nil {
					log.Printf("Failed to create UDP for peer %d: %v", conn, err)
					tunnelMu.Unlock()
					// Release this message and continue
					msg.Release()
					continue
				}
				pt := &peerTunnel{
					steamConn: conn,
					udpConn:   udpConn,
					done:      make(chan struct{}),
				}
				hostTunnels[conn] = pt
				go hostUDPToSteamRelay(pt)
				log.Printf("Host tunnel created for connection %d", conn)
			}
			tunnelMu.Unlock()
		}

		// Relay Steam -> UDP
		data := copyMsgData(msg)
		msg.Release()
		if data != nil {
			tunnelMu.RLock()
			if pt, exists := hostTunnels[conn]; exists {
				pt.udpConn.WriteToUDP(data, enetServerAddr)
			}
			tunnelMu.RUnlock()
		}
	}

	// Check for disconnected peers
	for conn := range knownConns {
		state := getConnectionState(conn)
		if state == stateClosedByPeer || state == stateProblemDetectedLocally {
			ns.CloseConnection(conn, 0, "", false)
			tunnelMu.Lock()
			if pt, exists := hostTunnels[conn]; exists {
				pt.closeTunnel()
				pt.udpConn.Close()
				delete(hostTunnels, conn)
				log.Printf("Host tunnel closed for connection %d", conn)
			}
			tunnelMu.Unlock()
			delete(knownConns, conn)
		}
	}
}

var clientTickCount int

func tickClient(ns sw.ISteamNetworkingSockets) {
	pt := clientTunnel

	// Check connection state
	state := getConnectionState(pt.steamConn)
	clientTickCount++
	if clientTickCount%100 == 1 {
		log.Printf("tickClient: conn=%d state=%d (tick %d)", pt.steamConn, state, clientTickCount)
	}
	if state == stateClosedByPeer || state == stateProblemDetectedLocally {
		ns.CloseConnection(pt.steamConn, 0, "", false)
		pt.closeTunnel()
		pt.udpConn.Close()
		clientTunnel = nil
		tunnelActive.Store(false)
		log.Println("Client P2P connection lost")
		return
	}

	// Receive messages from host and relay to local UDP
	msgs := ns.ReceiveMessagesOnConnection(pt.steamConn, 32)
	for _, msg := range msgs {
		data := copyMsgData(msg)
		msg.Release()
		if data != nil {
			if ca := pt.clientAddr.Load(); ca != nil {
				pt.udpConn.WriteToUDP(data, ca)
			}
		}
	}
}

// --- UDP relay goroutines (no Steam API calls, safe on any goroutine) ---

// hostUDPToSteamRelay reads from a peer's UDP socket and queues data
// to be sent on the Steam thread via a channel.
func hostUDPToSteamRelay(pt *peerTunnel) {
	buf := make([]byte, 2048)
	for {
		select {
		case <-pt.done:
			return
		default:
		}
		pt.udpConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		n, err := pt.udpConn.Read(buf)
		if err != nil {
			if !errors.Is(err, os.ErrDeadlineExceeded) {
				log.Printf("Host UDP read error (conn %d): %v", pt.steamConn, err)
			}
			continue
		}
		// Copy and send on the Steam thread
		data := make([]byte, n)
		copy(data, buf[:n])
		sendViaSteam(pt.steamConn, data)
	}
}

// clientUDPToSteamRelay reads from the local UDP socket and queues data
// for the Steam thread.
func clientUDPToSteamRelay(pt *peerTunnel) {
	buf := make([]byte, 2048)
	for {
		select {
		case <-pt.done:
			return
		default:
		}
		pt.udpConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		n, addr, err := pt.udpConn.ReadFromUDP(buf)
		if err != nil {
			if !errors.Is(err, os.ErrDeadlineExceeded) {
				log.Printf("Client UDP read error: %v", err)
			}
			continue
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
		// Drop if queue full — unreliable transport anyway
	}
}

// drainSendQueue is called from the Steam thread to flush pending sends.
var sendCount int64

func drainSendQueue() {
	ns := sw.SteamNetworkingSockets()
	for {
		select {
		case msg := <-steamSendCh:
			res, _ := ns.SendMessageToConnection(msg.conn, msg.data,
				sw.SteamNetworkingSend_Unreliable|sw.SteamNetworkingSend_NoNagle)
			sendCount++
			if sendCount <= 5 || sendCount%1000 == 0 {
				log.Printf("drainSendQueue: sent %d bytes to conn %d (result: %d, total: %d)",
					len(msg.data), msg.conn, res, sendCount)
			}
		default:
			return
		}
	}
}

// --- Helpers ---

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
