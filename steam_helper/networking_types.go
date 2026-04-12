package main

// Steam Networking Sockets types and constants not yet in upstream go-steamworks.
// These match the Steamworks SDK 1.64 C struct layouts for linux/amd64.

import sw "github.com/badhex/go-steamworks"

// ESteamNetworkingConnectionState mirrors the SDK enum.
const (
	ESteamNetworkingConnectionState_None                      = 0
	ESteamNetworkingConnectionState_Connecting                = 1
	ESteamNetworkingConnectionState_FindingRoute              = 2
	ESteamNetworkingConnectionState_Connected                 = 3
	ESteamNetworkingConnectionState_ClosedByPeer              = 4
	ESteamNetworkingConnectionState_ProblemDetectedLocally    = 5
)

// Assign to sw package namespace so existing code compiles.
func init() {
	// Validate that the types we need exist in the upstream package.
	_ = sw.HSteamNetConnection(0)
	_ = sw.HSteamListenSocket(0)
	_ = sw.HSteamNetPollGroup(0)
}

// SteamNetConnectionInfo_t — only the fields we actually read.
// Full struct is 696 bytes in the SDK; we only need State at offset 208.
// Pad to full size so unsafe.Pointer casts work with GetConnectionInfo.
type SteamNetConnectionInfo_t struct {
	_pad0 [208]byte // offsets 0-207: identity, userData, listenSocket, address, etc.
	State int32     // offset 208: ESteamNetworkingConnectionState
	_pad1 [484]byte // offsets 212-695: endReason, szEndDebug, szConnectionDescription
}

// SteamNetConnectionStatusChangedCallback_t — the callback struct.
// Callback ID is 1221.
type SteamNetConnectionStatusChangedCallback_t struct {
	Conn     sw.HSteamNetConnection // offset 0
	Info     SteamNetConnectionInfo_t // offset 4 (packed after conn)
	OldState int32                    // offset 700
}

// CallbackIDSteamNetConnectionStatusChanged is the Steam callback ID.
const CallbackIDSteamNetConnectionStatusChanged sw.CallbackID = 1221
