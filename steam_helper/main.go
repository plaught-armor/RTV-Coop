package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"

	sw "github.com/plaught-armor/go-steamworks"
)

// Callback result structs matching Steamworks SDK layout.
type LobbyCreated struct {
	Result       sw.EResult
	_            uint32
	SteamIDLobby uint64
}

type LobbyEnter struct {
	SteamIDLobby          uint64
	_                     uint32
	_                     bool
	ChatRoomEnterResponse uint32
}

type LobbyMatchList struct {
	LobbiesMatching uint32
}

// Callback IDs from Steamworks SDK headers.
const (
	kLobbyCreated   int32 = 513
	kLobbyEnter     int32 = 504
	kLobbyMatchList int32 = 510
)

type Command struct {
	Cmd    string          `json:"cmd"`
	ReqID  int             `json:"req_id,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	OK    bool   `json:"ok"`
	Cmd   string `json:"cmd"`
	ReqID int    `json:"req_id,omitempty"`
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

// steamJob sends a function to execute on the Steam thread and waits for the result.
type steamJob struct {
	fn     func() Response
	result chan Response
}

var (
	appID        uint32
	port         int
	currentLobby sw.CSteamID
	done         chan struct{}
	steamCh      chan steamJob // All Steam API calls go through this channel
	activeConnMu sync.Mutex
	activeConn   net.Conn // Current TCP client connection for push events
)

func main() {
	flag.IntVar(&port, "port", 27099, "TCP port to listen on")
	var appIDFlag uint
	flag.UintVar(&appIDFlag, "appid", 1963610, "Steam App ID (Road to Vostok)")
	var logFileFlag string
	flag.StringVar(&logFileFlag, "log-file", "", "Log file path (optional; defaults to <exe_dir>/steam_helper.log)")
	flag.Parse()
	appID = uint32(appIDFlag)

	log.SetPrefix("[steam_helper] ")
	log.SetFlags(log.Ltime)

	// Self-locate the log file at <exe_dir>/logs/steam_helper.log so it sits
	// next to godot.log (both end up in user://logs/ when launched by the mod).
	// Self-locating avoids passing space-containing paths through Proton/Wine
	// arg parsing.
	logFilePath := logFileFlag
	if logFilePath == "" {
		if exePath, err := os.Executable(); err == nil {
			logsDir := filepath.Join(filepath.Dir(exePath), "logs")
			_ = os.MkdirAll(logsDir, 0755)
			logFilePath = filepath.Join(logsDir, "steam_helper.log")
		} else {
			logFilePath = "steam_helper.log"
		}
	}

	logFile, logErr := os.OpenFile(logFilePath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if logErr != nil {
		fmt.Fprintf(os.Stderr, "[steam_helper] failed to open %q: %v (logging to stderr)\n", logFilePath, logErr)
	} else {
		log.SetOutput(logFile)
		log.Printf("Log file opened: %s", logFilePath)
	}

	// Listen FIRST so the game can connect and get status
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		log.Fatalf("Listen failed: %v", err)
	}
	defer listener.Close()
	log.Printf("Listening on 127.0.0.1:%d", port)

	done = make(chan struct{})
	steamCh = make(chan steamJob, 16)

	// Steam thread: locked to OS thread, owns ALL Steam API calls.
	var steamReady sync.WaitGroup
	steamReady.Add(1)
	go steamThread(&steamReady)
	steamReady.Wait()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		close(done)
		listener.Close()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			select {
			case <-done:
				return
			default:
				log.Printf("Accept error: %v", err)
				continue
			}
		}
		log.Printf("Client connected: %s", conn.RemoteAddr())
		go handleConn(conn)
	}
}

// steamThread is the ONLY goroutine that touches the Steam API.
// It is locked to an OS thread as required by Steamworks.
func steamThread(ready *sync.WaitGroup) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	log.Printf("Steam thread started (OS thread locked, proton: %v)", isProton())

	if sw.RestartAppIfNecessary(appID) {
		log.Println("Steam requested restart via client")
		os.Exit(0)
	}
	log.Println("RestartAppIfNecessary passed")

	if err := sw.Init(); err != nil {
		log.Fatalf("SteamAPI_Init failed: %v", err)
	}
	log.Println("SteamAPI_Init OK")

	name := sw.SteamFriends().GetPersonaName()
	steamID := sw.SteamUser().GetSteamID()
	log.Printf("Logged in as: %s (Steam64: %d)", name, uint64(steamID))

	initNetworkingSymbols()
	initManualDispatch()

	ready.Done()

	// Main loop: process Steam jobs and pump callbacks
	var mainTickCount int64
	callbackTicker := time.NewTicker(33 * time.Millisecond)
	defer callbackTicker.Stop()

	for {
		select {
		case <-done:
			sw.Shutdown()
			return
		case job := <-steamCh:
			resp := job.fn()
			job.result <- resp
		case <-callbackTicker.C:
			mainTickCount++
			func() {
				defer func() {
					if r := recover(); r != nil {
						log.Printf("PANIC in callbacks (tick %d): %v", mainTickCount, r)
					}
				}()
				pumpManualCallbacks()
			}()
			if mainTickCount <= 3 {
				log.Printf("Callbacks OK (tick %d, tunnel=%v)", mainTickCount, tunnelActive.Load())
			}
			drainSendQueue()
			tickTunnel()
		}
	}
}

// runOnSteamThread sends a function to the Steam thread and blocks until it completes.
func runOnSteamThread(fn func() Response) Response {
	job := steamJob{fn: fn, result: make(chan Response, 1)}
	select {
	case steamCh <- job:
	case <-done:
		return Response{OK: false, Error: "shutting down"}
	}
	select {
	case resp := <-job.result:
		if !resp.OK {
			log.Printf("CMD result: error: %s", resp.Error)
		}
		return resp
	case <-done:
		return Response{OK: false, Error: "shutting down"}
	}
}

// runOnSteamThreadAsync sends a function that needs RunCallbacks pumping.
// The function is called on the steam thread, and RunCallbacks continues
// pumping between polls until the context expires or the fn returns.
func runOnSteamThreadAsync(fn func() Response) Response {
	job := steamJob{fn: fn, result: make(chan Response, 1)}
	select {
	case steamCh <- job:
	case <-done:
		return Response{OK: false, Error: "shutting down"}
	}
	select {
	case resp := <-job.result:
		return resp
	case <-done:
		return Response{OK: false, Error: "shutting down"}
	}
}

func handleConn(conn net.Conn) {
	activeConnMu.Lock()
	activeConn = conn
	activeConnMu.Unlock()

	defer func() {
		activeConnMu.Lock()
		if activeConn == conn {
			activeConn = nil
		}
		activeConnMu.Unlock()
		conn.Close()
	}()

	scanner := bufio.NewScanner(conn)
	enc := json.NewEncoder(conn)

	for scanner.Scan() {
		var cmd Command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			enc.Encode(Response{OK: false, Error: "invalid json"})
			continue
		}
		resp := dispatch(cmd)
		resp.ReqID = cmd.ReqID
		enc.Encode(resp)
	}
}

func dispatch(cmd Command) (resp Response) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in dispatch(%s): %v", cmd.Cmd, r)
			resp = fail(cmd.Cmd, fmt.Sprintf("internal panic: %v", r))
		}
	}()
	log.Printf("CMD: %s", cmd.Cmd)
	switch cmd.Cmd {
	case "ping":
		return ok(cmd.Cmd, "pong")
	case "get_user":
		return runOnSteamThread(func() Response { return getUser(cmd) })
	case "check_ownership":
		return runOnSteamThread(func() Response { return checkOwnership(cmd) })
	case "create_lobby":
		return runOnSteamThread(func() Response { return createLobby(cmd) })
	case "list_lobbies":
		return runOnSteamThread(func() Response { return listLobbies(cmd) })
	case "join_lobby":
		return runOnSteamThread(func() Response { return joinLobby(cmd) })
	case "leave_lobby":
		return runOnSteamThread(func() Response { return leaveLobby(cmd) })
	case "get_friends":
		return runOnSteamThread(func() Response { return getFriends(cmd) })
	case "invite_friend":
		return runOnSteamThread(func() Response { return inviteFriend(cmd) })
	case "open_invite_dialog":
		return runOnSteamThread(func() Response { return openInviteDialog(cmd) })
	case "get_avatar":
		return runOnSteamThread(func() Response { return getAvatar(cmd) })
	case "get_avatar_bin":
		return runOnSteamThread(func() Response { return getAvatarBinary(cmd) })
	case "check_launch_invite":
		return runOnSteamThread(func() Response { return checkLaunchInvite(cmd) })
	case "set_rich_presence":
		return runOnSteamThread(func() Response { return setRichPresence(cmd) })
	case "clear_rich_presence":
		return runOnSteamThread(func() Response { return clearRichPresence(cmd) })
	case "set_lobby_data":
		return runOnSteamThread(func() Response { return setLobbyData(cmd) })
	case "get_lobby_data":
		return runOnSteamThread(func() Response { return getLobbyData(cmd) })
	case "start_p2p_host":
		return runOnSteamThread(func() Response { return cmdStartP2PHost(cmd) })
	case "start_p2p_client":
		return runOnSteamThread(func() Response { return cmdStartP2PClient(cmd) })
	default:
		return fail(cmd.Cmd, "unknown command")
	}
}

func ok(cmd string, data any) Response  { return Response{OK: true, Cmd: cmd, Data: data} }
func fail(cmd, err string) Response     { return Response{OK: false, Cmd: cmd, Error: err} }

// pushEvent sends an unsolicited event to the connected client.
func pushEvent(resp Response) {
	activeConnMu.Lock()
	conn := activeConn
	activeConnMu.Unlock()
	if conn == nil {
		return
	}
	data, err := json.Marshal(resp)
	if err != nil {
		return
	}
	data = append(data, '\n')
	conn.Write(data)
}

// --- Commands (ALL called on the Steam thread, no locking needed) ---

func getUser(_ Command) Response {
	return ok("get_user", map[string]any{
		"steam_id": fmt.Sprintf("%d", uint64(sw.SteamUser().GetSteamID())),
		"name":     sw.SteamFriends().GetPersonaName(),
	})
}

func checkOwnership(_ Command) Response {
	if isProton() {
		return ok("check_ownership", map[string]any{"owns": true, "app_id": appID})
	}
	return ok("check_ownership", map[string]any{
		"owns":   sw.SteamApps().BIsSubscribedApp(sw.AppId_t(appID)),
		"app_id": appID,
	})
}

func createLobby(cmd Command) Response {
	var p struct {
		MaxPlayers int `json:"max_players"`
	}
	p.MaxPlayers = 4
	if cmd.Params != nil {
		json.Unmarshal(cmd.Params, &p)
	}

	call := sw.SteamMatchmaking().CreateLobby(sw.ELobbyType_Public, p.MaxPlayers)
	log.Printf("CreateLobby call: %d", call)

	cr := sw.NewCallResult[LobbyCreated](call, kLobbyCreated)

	// Poll without pumping RunCallbacks here — let the main loop handle it.
	// This means we need to release the Steam thread temporarily.
	// Return a pending marker and handle the result asynchronously.
	// For now, pump carefully with logging.
	result, failed, err := pumpUntilCompleteLogged(cr, 10*time.Second)
	if err != nil {
		return fail("create_lobby", fmt.Sprintf("timeout: %v", err))
	}
	if failed || result.Result != sw.EResultOK {
		return fail("create_lobby", fmt.Sprintf("failed: result %d", result.Result))
	}

	currentLobby = sw.CSteamID(result.SteamIDLobby)
	mm := sw.SteamMatchmaking()
	mm.SetLobbyData(currentLobby, "host_name", sw.SteamFriends().GetPersonaName())
	mm.SetLobbyData(currentLobby, "mod", "rtv-coop")
	mm.SetLobbyData(currentLobby, "host_steam_id", fmt.Sprintf("%d", uint64(sw.SteamUser().GetSteamID())))
	return ok("create_lobby", map[string]any{
		"lobby_id": fmt.Sprintf("%d", result.SteamIDLobby),
	})
}

func listLobbies(_ Command) Response {
	sw.SteamMatchmaking().AddRequestLobbyListStringFilter("mod", "rtv-coop", sw.ELobbyComparisonEqual)
	call := sw.SteamMatchmaking().RequestLobbyList()

	cr := sw.NewCallResult[LobbyMatchList](call, kLobbyMatchList)
	result, _, err := pumpUntilComplete(cr, 10*time.Second)
	if err != nil {
		return fail("list_lobbies", fmt.Sprintf("timeout: %v", err))
	}

	mm := sw.SteamMatchmaking()
	lobbies := make([]map[string]any, 0, result.LobbiesMatching)
	for i := 0; i < int(result.LobbiesMatching); i++ {
		id := mm.GetLobbyByIndex(i)
		lobbies = append(lobbies, map[string]any{
			"lobby_id":      fmt.Sprintf("%d", uint64(id)),
			"host_name":     mm.GetLobbyData(id, "host_name"),
			"host_steam_id": mm.GetLobbyData(id, "host_steam_id"),
			"players":       mm.GetNumLobbyMembers(id),
			"max_players":   mm.GetLobbyMemberLimit(id),
			"map":           mm.GetLobbyData(id, "map"),
		})
	}
	return ok("list_lobbies", lobbies)
}

func joinLobby(cmd Command) Response {
	var p struct {
		LobbyID string `json:"lobby_id"`
	}
	if err := json.Unmarshal(cmd.Params, &p); err != nil || p.LobbyID == "" {
		return fail("join_lobby", "missing lobby_id")
	}

	var lobbyID uint64
	fmt.Sscanf(p.LobbyID, "%d", &lobbyID)

	call := sw.SteamMatchmaking().JoinLobby(sw.CSteamID(lobbyID))

	cr := sw.NewCallResult[LobbyEnter](call, kLobbyEnter)
	result, _, err := pumpUntilComplete(cr, 10*time.Second)
	if err != nil {
		return fail("join_lobby", fmt.Sprintf("timeout: %v", err))
	}
	if result.ChatRoomEnterResponse != 1 {
		return fail("join_lobby", fmt.Sprintf("join denied: %d", result.ChatRoomEnterResponse))
	}

	currentLobby = sw.CSteamID(result.SteamIDLobby)
	ownerID := sw.SteamMatchmaking().GetLobbyOwner(currentLobby)
	return ok("join_lobby", map[string]any{
		"lobby_id":      fmt.Sprintf("%d", result.SteamIDLobby),
		"host_steam_id": fmt.Sprintf("%d", uint64(ownerID)),
	})
}

func leaveLobby(_ Command) Response {
	if uint64(currentLobby) != 0 {
		sw.SteamMatchmaking().LeaveLobby(currentLobby)
		currentLobby = 0
	}
	return ok("leave_lobby", nil)
}

// --- Friend / Invite Commands ---

func getFriends(_ Command) Response {
	friends := sw.SteamFriends()
	count := friends.GetFriendCount(sw.EFriendFlagImmediate)
	result := make([]map[string]any, 0, count)
	for i := 0; i < count; i++ {
		id := friends.GetFriendByIndex(i, sw.EFriendFlagImmediate)
		state := friends.GetFriendPersonaState(id)
		if state == sw.EPersonaStateOffline {
			continue
		}
		name := friends.GetFriendPersonaName(id)
		log.Printf("get_friends: [%d] %s (state %d)", i, name, state)
		entry := map[string]any{
			"steam_id": fmt.Sprintf("%d", uint64(id)),
			"name":     name,
			"state":    int(state),
		}
		gameInfo, inGame := friends.GetFriendGamePlayed(id)
		if inGame {
			entry["game_id"] = fmt.Sprintf("%d", gameInfo.GameID)
		}
		// Avatars stripped from friends list — fetch via get_avatar_bin instead
		result = append(result, entry)
	}
	return ok("get_friends", result)
}

func inviteFriend(cmd Command) Response {
	var p struct {
		SteamID string `json:"steam_id"`
	}
	if err := json.Unmarshal(cmd.Params, &p); err != nil || p.SteamID == "" {
		return fail("invite_friend", "missing steam_id")
	}
	if uint64(currentLobby) == 0 {
		return fail("invite_friend", "no active lobby")
	}
	var friendID uint64
	fmt.Sscanf(p.SteamID, "%d", &friendID)
	success := sw.SteamMatchmaking().InviteUserToLobby(currentLobby, sw.CSteamID(friendID))
	if !success {
		return fail("invite_friend", "invite failed")
	}
	return ok("invite_friend", map[string]any{"steam_id": p.SteamID})
}

func openInviteDialog(_ Command) Response {
	if uint64(currentLobby) == 0 {
		return fail("open_invite_dialog", "no active lobby")
	}
	sw.SteamFriends().ActivateGameOverlayInviteDialog(currentLobby)
	return ok("open_invite_dialog", nil)
}

func getAvatar(cmd Command) Response {
	var p struct {
		SteamID string `json:"steam_id"`
	}
	if err := json.Unmarshal(cmd.Params, &p); err != nil || p.SteamID == "" {
		return fail("get_avatar", "missing steam_id")
	}
	var id uint64
	fmt.Sscanf(p.SteamID, "%d", &id)

	handle := sw.SteamFriends().GetSmallFriendAvatar(sw.CSteamID(id))
	if handle <= 0 {
		return fail("get_avatar", "no avatar available")
	}
	w, h, sizeOk := sw.SteamUtils().GetImageSize(int(handle))
	if !sizeOk || w == 0 || h == 0 {
		return fail("get_avatar", "invalid image size")
	}
	buf := make([]byte, w*h*4)
	if !sw.SteamUtils().GetImageRGBA(int(handle), buf) {
		return fail("get_avatar", "GetImageRGBA failed")
	}
	return ok("get_avatar", map[string]any{
		"steam_id": p.SteamID,
		"avatar":   base64.StdEncoding.EncodeToString(buf),
		"avatar_w": w,
		"avatar_h": h,
	})
}

// --- Binary Avatar ---

func getAvatarBinary(cmd Command) Response {
	var p struct {
		SteamID string `json:"steam_id"`
	}
	if err := json.Unmarshal(cmd.Params, &p); err != nil || p.SteamID == "" {
		return fail("get_avatar_bin", "missing steam_id")
	}
	var id uint64
	fmt.Sscanf(p.SteamID, "%d", &id)

	handle := sw.SteamFriends().GetSmallFriendAvatar(sw.CSteamID(id))
	if handle <= 0 {
		return fail("get_avatar_bin", "no avatar available")
	}
	w, h, sizeOk := sw.SteamUtils().GetImageSize(int(handle))
	if !sizeOk || w == 0 || h == 0 {
		return fail("get_avatar_bin", "invalid image size")
	}
	buf := make([]byte, w*h*4)
	if !sw.SteamUtils().GetImageRGBA(int(handle), buf) {
		return fail("get_avatar_bin", "GetImageRGBA failed")
	}

	// Send binary: [0x00][4 bytes total len BE][0x01 type][1 byte id_len][steam_id][2 bytes w BE][2 bytes h BE][RGBA]
	idBytes := []byte(p.SteamID)
	payloadLen := 1 + 1 + len(idBytes) + 2 + 2 + len(buf) // type + id_len + id + w + h + rgba
	msg := make([]byte, 0, 5+payloadLen)
	msg = append(msg, 0x00) // binary marker
	msg = append(msg, byte(payloadLen>>24), byte(payloadLen>>16), byte(payloadLen>>8), byte(payloadLen))
	msg = append(msg, 0x01)            // type: avatar
	msg = append(msg, byte(len(idBytes))) // steam_id length
	msg = append(msg, idBytes...)
	msg = append(msg, byte(w>>8), byte(w))
	msg = append(msg, byte(h>>8), byte(h))
	msg = append(msg, buf...)

	pushBinary(msg)
	return ok("get_avatar_bin", map[string]any{"steam_id": p.SteamID, "binary": true})
}

// pushBinary writes raw bytes to the active TCP connection.
func pushBinary(data []byte) {
	activeConnMu.Lock()
	conn := activeConn
	activeConnMu.Unlock()
	if conn == nil {
		return
	}
	conn.Write(data)
}

// --- Rich Presence ---

func setRichPresence(cmd Command) Response {
	var p struct {
		Key   string `json:"key"`
		Value string `json:"value"`
	}
	if err := json.Unmarshal(cmd.Params, &p); err != nil || p.Key == "" {
		return fail("set_rich_presence", "missing key")
	}
	sw.SteamFriends().SetRichPresence(p.Key, p.Value)
	return ok("set_rich_presence", nil)
}

func clearRichPresence(_ Command) Response {
	// go-steamworks doesn't bind ClearRichPresence — set keys to empty instead
	sw.SteamFriends().SetRichPresence("status", "")
	sw.SteamFriends().SetRichPresence("steam_display", "")
	return ok("clear_rich_presence", nil)
}

// --- Lobby Data ---

func setLobbyData(cmd Command) Response {
	var p struct {
		LobbyID string `json:"lobby_id"`
		Key     string `json:"key"`
		Value   string `json:"value"`
	}
	if err := json.Unmarshal(cmd.Params, &p); err != nil || p.Key == "" {
		return fail("set_lobby_data", "missing key")
	}
	lobby := currentLobby
	if p.LobbyID != "" {
		var id uint64
		fmt.Sscanf(p.LobbyID, "%d", &id)
		lobby = sw.CSteamID(id)
	}
	if uint64(lobby) == 0 {
		return fail("set_lobby_data", "no active lobby")
	}
	success := sw.SteamMatchmaking().SetLobbyData(lobby, p.Key, p.Value)
	if !success {
		return fail("set_lobby_data", "SetLobbyData failed")
	}
	return ok("set_lobby_data", nil)
}

func getLobbyData(cmd Command) Response {
	var p struct {
		LobbyID string `json:"lobby_id"`
		Key     string `json:"key"`
	}
	if err := json.Unmarshal(cmd.Params, &p); err != nil || p.LobbyID == "" || p.Key == "" {
		return fail("get_lobby_data", "missing lobby_id or key")
	}
	var id uint64
	fmt.Sscanf(p.LobbyID, "%d", &id)
	value := sw.SteamMatchmaking().GetLobbyData(sw.CSteamID(id), p.Key)
	return ok("get_lobby_data", map[string]any{
		"key":   p.Key,
		"value": value,
	})
}

// --- Helpers ---

func pumpUntilCompleteLogged[T any](cr *sw.CallResult[T], timeout time.Duration) (T, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	ticker := time.NewTicker(33 * time.Millisecond)
	defer ticker.Stop()

	var zero T
	var pumpCount int
	for {
		select {
		case <-ctx.Done():
			return zero, false, ctx.Err()
		case <-ticker.C:
			pumpCount++
			if pumpCount <= 5 {
				log.Printf("pumpUntilComplete: about to RunCallbacks (pump %d)", pumpCount)
			}
			func() {
				defer func() {
					if r := recover(); r != nil {
						log.Printf("PANIC in pumpUntilComplete (pump %d): %v", pumpCount, r)
					}
				}()
				pumpManualCallbacks()
			}()
			if pumpCount <= 5 {
				log.Printf("pumpUntilComplete: RunCallbacks OK (pump %d)", pumpCount)
			}
			if _, complete := cr.IsComplete(); complete {
				log.Printf("pumpUntilComplete: complete after %d pumps", pumpCount)
				return cr.Result()
			}
		}
	}
}

// pumpUntilComplete pumps RunCallbacks on the current (Steam) thread
// while waiting for a CallResult to complete.
func pumpUntilComplete[T any](cr *sw.CallResult[T], timeout time.Duration) (T, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	ticker := time.NewTicker(33 * time.Millisecond)
	defer ticker.Stop()

	var zero T
	for {
		select {
		case <-ctx.Done():
			return zero, false, ctx.Err()
		case <-ticker.C:
			// Pump manual dispatch callbacks (not RunCallbacks — manual dispatch is active)
			func() {
				defer func() {
					if r := recover(); r != nil {
						log.Printf("PANIC in pumpUntilComplete: %v", r)
					}
				}()
				pumpManualCallbacks()
			}()
			if _, complete := cr.IsComplete(); complete {
				return cr.Result()
			}
		}
	}
}
