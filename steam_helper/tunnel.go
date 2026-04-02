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

	sw "github.com/assemblaj/purego-steamworks"
)

// peerTunnel represents a UDP tunnel for one remote Steam peer.
type peerTunnel struct {
	steamConn  sw.HSteamNetConnection
	udpConn    *net.UDPConn
	done       chan struct{}
	closeOnce  sync.Once
	clientAddr atomic.Pointer[net.UDPAddr] // learned from first incoming UDP packet (client side)
}

// closeTunnel safely closes the done channel exactly once.
func (pt *peerTunnel) closeTunnel() {
	pt.closeOnce.Do(func() { close(pt.done) })
}

// Lock ordering: mu before tunnelMu. Never acquire mu while holding tunnelMu.
var (
	listenSocket sw.HSteamListenSocket
	pollGroup    sw.HSteamNetPollGroup
	tunnelMu     sync.Mutex
	// Host: maps Steam connection -> peerTunnel (one per remote peer)
	hostTunnels map[sw.HSteamNetConnection]*peerTunnel
	// Client: single tunnel
	clientTunnel *peerTunnel
	// ENet server address on localhost (host side)
	enetServerAddr *net.UDPAddr
	tunnelActive   atomic.Bool
	hostDone       chan struct{} // closed to stop hostSteamToUDPLoop
)

func init() {
	hostTunnels = make(map[sw.HSteamNetConnection]*peerTunnel)
}

// cmdStartP2PHost sets up a Steam NS listen socket and prepares to relay
// incoming connections to the local ENet server.
func cmdStartP2PHost(cmd Command) Response {
	var p struct {
		ENetPort int `json:"enet_port"`
	}
	p.ENetPort = 9050
	if cmd.Params != nil {
		_ = json.Unmarshal(cmd.Params, &p)
	}

	mu.Lock()
	defer mu.Unlock()

	if tunnelActive.Load() {
		return fail("start_p2p_host", "tunnel already active")
	}

	// Register connection status callback
	sw.SteamNetworkingUtils().SetGlobalCallback_SteamNetConnectionStatusChanged(onConnectionStatusChanged)

	// Create P2P listen socket
	listenSocket = sw.SteamNetworkingSockets().CreateListenSocketP2P(0, nil)
	if listenSocket == sw.HSteamListenSocket_Invalid {
		return fail("start_p2p_host", "failed to create listen socket")
	}

	// Create poll group for receiving messages from all peers
	pollGroup = sw.SteamNetworkingSockets().CreatePollGroup()

	enetServerAddr = &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: p.ENetPort}
	tunnelActive.Store(true)
	hostDone = make(chan struct{})

	// Start Steam→UDP relay goroutine for all host peers
	go hostSteamToUDPLoop()

	log.Printf("P2P host listening (ENet on :%d)", p.ENetPort)
	return ok("start_p2p_host", nil)
}

// cmdStartP2PClient connects to a host via Steam NS P2P and creates a local
// UDP tunnel that the game's ENet client can connect to.
func cmdStartP2PClient(cmd Command) Response {
	var p struct {
		HostSteamID string `json:"host_steam_id"`
	}
	if cmd.Params != nil {
		_ = json.Unmarshal(cmd.Params, &p)
	}
	if p.HostSteamID == "" {
		return fail("start_p2p_client", "missing host_steam_id")
	}

	var hostID uint64
	fmt.Sscanf(p.HostSteamID, "%d", &hostID)

	mu.Lock()
	defer mu.Unlock()

	if tunnelActive.Load() {
		return fail("start_p2p_client", "tunnel already active")
	}

	// Register connection status callback
	sw.SteamNetworkingUtils().SetGlobalCallback_SteamNetConnectionStatusChanged(onConnectionStatusChanged)

	// Connect to host via Steam P2P
	var identity sw.SteamNetworkingIdentity
	identity.SetSteamID64(hostID)
	conn := sw.SteamNetworkingSockets().ConnectP2P(identity, 0, nil)
	if conn == sw.HSteamNetConnection_Invalid {
		return fail("start_p2p_client", "ConnectP2P failed")
	}

	// Create local UDP "server" socket for the game's ENet client to connect to
	udpAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		return fail("start_p2p_client", fmt.Sprintf("resolve: %v", err))
	}
	udpConn, err := net.ListenUDP("udp", udpAddr)
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

	// Start relay goroutines
	go clientUDPToSteamLoop(clientTunnel)
	go clientSteamToUDPLoop(clientTunnel)

	log.Printf("P2P client tunnel on 127.0.0.1:%d -> host %s", tunnelPort, p.HostSteamID)
	return ok("start_p2p_client", map[string]any{
		"tunnel_port": tunnelPort,
	})
}

// onConnectionStatusChanged handles Steam NS connection events.
// Called from the RunCallbacks goroutine (mu is held).
func onConnectionStatusChanged(data *sw.SteamNetConnectionStatusChangedCallback) {
	ns := sw.SteamNetworkingSockets()
	conn := data.Conn
	state := data.Info.State

	log.Printf("Steam NS connection %d: state %d -> %d", conn, data.OldState, state)

	switch state {
	case sw.ESteamNetworkingConnectionState_Connecting:
		// Host: incoming peer wants to connect
		if listenSocket != sw.HSteamListenSocket_Invalid {
			result := ns.AcceptConnection(conn)
			if result != sw.EResultOK {
				log.Printf("AcceptConnection failed: %d", result)
				ns.CloseConnection(conn, 0, "", false)
				return
			}
			ns.SetConnectionPollGroup(conn, pollGroup)
			log.Printf("Accepted P2P connection %d", conn)
		}

	case sw.ESteamNetworkingConnectionState_Connected:
		// Host: create a local UDP socket for this peer → ENet server
		if listenSocket != sw.HSteamListenSocket_Invalid {
			tunnelMu.Lock()
			if _, exists := hostTunnels[conn]; !exists {
				udpConn, err := net.DialUDP("udp", nil, enetServerAddr)
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
				go hostUDPToSteamLoop(pt)
				log.Printf("Host tunnel created for connection %d", conn)
			}
			tunnelMu.Unlock()
		}

	case sw.ESteamNetworkingConnectionState_ClosedByPeer,
		sw.ESteamNetworkingConnectionState_ProblemDetectedLocally:
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
		// Clean up client tunnel
		if clientTunnel != nil && clientTunnel.steamConn == conn {
			clientTunnel.closeTunnel()
			clientTunnel.udpConn.Close()
			clientTunnel = nil
			tunnelActive.Store(false)
			log.Println("Client tunnel closed")
		}
	}
}

// --- Host relay goroutines ---

// hostSteamToUDPLoop receives messages from ALL Steam peers via the poll group
// and forwards them to the correct local UDP socket for each peer.
func hostSteamToUDPLoop() {
	for {
		select {
		case <-hostDone:
			return
		default:
		}

		mu.Lock()
		msgs := sw.SteamNetworkingSockets().ReceiveMessagesOnPollGroup(pollGroup, 32)
		mu.Unlock()

		for _, msg := range msgs {
			tunnelMu.Lock()
			pt, exists := hostTunnels[msg.Conn]
			tunnelMu.Unlock()
			if exists {
				pt.udpConn.Write(msg.GetData())
			}
		}

		if len(msgs) == 0 {
			time.Sleep(time.Millisecond)
		}
	}
}

// hostUDPToSteamLoop reads from a peer's local UDP socket (connected to ENet server)
// and forwards to that peer's Steam connection.
func hostUDPToSteamLoop(pt *peerTunnel) {
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
		mu.Lock()
		sw.SteamNetworkingSockets().SendMessageToConnection(
			pt.steamConn, buf[:n], sw.SteamNetworkingSend_UnreliableNoNagle,
		)
		mu.Unlock()
	}
}

// --- Client relay goroutines ---

// clientUDPToSteamLoop reads from the local UDP socket (game's ENet client)
// and forwards to the host via Steam.
func clientUDPToSteamLoop(pt *peerTunnel) {
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
		// Remember where ENet client sends from so we can reply
		pt.clientAddr.Store(addr)
		mu.Lock()
		sw.SteamNetworkingSockets().SendMessageToConnection(
			pt.steamConn, buf[:n], sw.SteamNetworkingSend_UnreliableNoNagle,
		)
		mu.Unlock()
	}
}

// clientSteamToUDPLoop receives from the host via Steam and forwards to the
// local UDP socket where the game's ENet client is listening.
func clientSteamToUDPLoop(pt *peerTunnel) {
	for {
		select {
		case <-pt.done:
			return
		default:
		}
		mu.Lock()
		msgs := sw.SteamNetworkingSockets().ReceiveMessagesOnConnection(pt.steamConn, 32)
		mu.Unlock()

		for _, msg := range msgs {
			if ca := pt.clientAddr.Load(); ca != nil {
				pt.udpConn.WriteToUDP(msg.GetData(), ca)
			}
		}

		if len(msgs) == 0 {
			time.Sleep(time.Millisecond)
		}
	}
}
