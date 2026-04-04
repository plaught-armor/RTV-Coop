package main

import (
	"fmt"
	"log"
	"unsafe"

	sw "github.com/badhex/go-steamworks"
)

// Callback IDs from Steamworks SDK.
const kGameLobbyJoinRequested sw.CallbackID = 333

type GameLobbyJoinRequested struct {
	SteamIDLobby  uint64
	SteamIDFriend uint64
}

// CallbackMsg_t mirrors the Steam internal callback message struct.
type callbackMsg struct {
	SteamUser int32
	Callback  int32
	Param     uintptr
	ParamSize int32
}

// Raw symbol function pointers for manual dispatch.
var (
	fnManualDispatchInit             uintptr
	fnManualDispatchRunFrame         uintptr
	fnManualDispatchGetNextCallback  uintptr
	fnManualDispatchFreeLastCallback uintptr
	manualDispatchReady              bool
	steamPipe                        int32
)

// initManualDispatch sets up manual callback dispatch. Must be called BEFORE
// any RunCallbacks call. Called on the Steam thread after Init().
func initManualDispatch() {
	var err error
	fnManualDispatchInit, err = sw.LookupSymbol("SteamAPI_ManualDispatch_Init")
	if err != nil {
		log.Printf("Cannot resolve ManualDispatch_Init: %v", err)
		return
	}
	fnManualDispatchRunFrame, err = sw.LookupSymbol("SteamAPI_ManualDispatch_RunFrame")
	if err != nil {
		log.Printf("Cannot resolve ManualDispatch_RunFrame: %v", err)
		return
	}
	fnManualDispatchGetNextCallback, err = sw.LookupSymbol("SteamAPI_ManualDispatch_GetNextCallback")
	if err != nil {
		log.Printf("Cannot resolve ManualDispatch_GetNextCallback: %v", err)
		return
	}
	fnManualDispatchFreeLastCallback, err = sw.LookupSymbol("SteamAPI_ManualDispatch_FreeLastCallback")
	if err != nil {
		log.Printf("Cannot resolve ManualDispatch_FreeLastCallback: %v", err)
		return
	}

	pipeSymbol, err := sw.LookupSymbol("SteamAPI_GetHSteamPipe")
	if err != nil {
		log.Printf("Cannot resolve GetHSteamPipe: %v", err)
		return
	}
	steamPipe = int32(sw.CallSymbolPtr(pipeSymbol))

	sw.CallSymbolPtr(fnManualDispatchInit)
	manualDispatchReady = true
	log.Printf("Manual dispatch initialized (pipe: %d)", steamPipe)
}

// pumpManualCallbacks runs one frame of manual dispatch and processes callbacks.
func pumpManualCallbacks() {
	if !manualDispatchReady {
		return
	}

	sw.CallSymbolPtr(fnManualDispatchRunFrame, uintptr(steamPipe))

	// Drain pending callbacks (capped to prevent infinite loop)
	var msg callbackMsg
	for i := 0; i < 64; i++ {
		ret := sw.CallSymbolPtr(fnManualDispatchGetNextCallback, uintptr(steamPipe), uintptr(unsafe.Pointer(&msg)))
		if ret == 0 {
			break
		}

		handleCallback(msg)

		sw.CallSymbolPtr(fnManualDispatchFreeLastCallback, uintptr(steamPipe))
	}
}

var lastInviteLobby string

func handleCallback(msg callbackMsg) {
	switch sw.CallbackID(msg.Callback) {
	case kGameLobbyJoinRequested:
		if msg.ParamSize >= int32(unsafe.Sizeof(GameLobbyJoinRequested{})) {
			req := (*GameLobbyJoinRequested)(unsafe.Pointer(msg.Param))
			lobbyID := fmt.Sprintf("%d", req.SteamIDLobby)
			if lobbyID == lastInviteLobby || lobbyID == "0" {
				return
			}
			lastInviteLobby = lobbyID
			log.Printf("GameLobbyJoinRequested: lobby=%s friend=%d", lobbyID, req.SteamIDFriend)
			pushEvent(Response{
				OK:  true,
				Cmd: "invite_received",
				Data: map[string]any{
					"lobby_id":  lobbyID,
					"friend_id": fmt.Sprintf("%d", req.SteamIDFriend),
				},
			})
		}

	case sw.CallbackIDSteamNetConnectionStatusChanged:
		if msg.ParamSize >= int32(unsafe.Sizeof(sw.SteamNetConnectionStatusChangedCallback_t{})) {
			cb := (*sw.SteamNetConnectionStatusChangedCallback_t)(unsafe.Pointer(msg.Param))
			log.Printf("NetConnectionStatusChanged: conn=%d state=%d->%d",
				cb.Conn, cb.OldState, cb.Info.State)
			handleConnectionStatusChange(cb.Conn, int32(cb.Info.State), int32(cb.OldState))
		}

	default:
		if msg.Callback != 0 && msg.Callback != 1298 {
			log.Printf("Callback %d (size %d)", msg.Callback, msg.ParamSize)
		}
	}
}
