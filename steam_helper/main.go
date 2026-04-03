package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	sw "github.com/badhex/go-steamworks"
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
	kLobbyCreated  int32 = 513
	kLobbyEnter    int32 = 504
	kLobbyMatchList int32 = 510
)

type Command struct {
	Cmd    string          `json:"cmd"`
	Params json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	OK    bool   `json:"ok"`
	Cmd   string `json:"cmd"`
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

var (
	appID        uint32
	port         int
	mu           sync.Mutex
	currentLobby sw.CSteamID
	done         chan struct{}
)

func main() {
	flag.IntVar(&port, "port", 27099, "TCP port to listen on")
	var appIDFlag uint
	flag.UintVar(&appIDFlag, "appid", 2141300, "Steam App ID (Road to Vostok Demo)")
	flag.Parse()
	appID = uint32(appIDFlag)

	log.SetPrefix("[steam_helper] ")
	log.SetFlags(log.Ltime)

	// Listen FIRST so the game can connect and get status
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		log.Fatalf("Listen failed: %v", err)
	}
	defer listener.Close()
	log.Printf("Listening on 127.0.0.1:%d", port)

	// Init Steam
	if sw.RestartAppIfNecessary(appID) {
		log.Println("Steam requested restart via client")
		os.Exit(0)
	}

	if err := sw.Init(); err != nil {
		log.Fatalf("SteamAPI_Init failed: %v", err)
	}

	name := sw.SteamFriends().GetPersonaName()
	steamID := sw.SteamUser().GetSteamID()
	log.Printf("Logged in as: %s (Steam64: %d)", name, uint64(steamID))

	done = make(chan struct{})

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
		go handleConn(conn, done)
	}
}

var callbackLoopStarted bool

func ensureCallbackLoop(done chan struct{}) {
	if callbackLoopStarted {
		return
	}
	callbackLoopStarted = true
	go callbackLoop(done)
	log.Println("Callback loop started")
}

func callbackLoop(done chan struct{}) {
	ticker := time.NewTicker(33 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			func() {
				defer func() {
					if r := recover(); r != nil {
						log.Printf("PANIC in RunCallbacks: %v", r)
					}
				}()
				mu.Lock()
				sw.RunCallbacks()
				mu.Unlock()
			}()
		}
	}
}

func handleConn(conn net.Conn, done chan struct{}) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	enc := json.NewEncoder(conn)

	for scanner.Scan() {
		var cmd Command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			enc.Encode(Response{OK: false, Error: "invalid json"})
			continue
		}
		enc.Encode(dispatch(cmd))
	}
}

func dispatch(cmd Command) (resp Response) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in dispatch(%s): %v", cmd.Cmd, r)
			resp = fail(cmd.Cmd, fmt.Sprintf("internal panic: %v", r))
		}
	}()
	switch cmd.Cmd {
	case "ping":
		return ok(cmd.Cmd, "pong")
	case "get_user":
		return getUser(cmd)
	case "check_ownership":
		return checkOwnership(cmd)
	case "create_lobby":
		return createLobby(cmd)
	case "list_lobbies":
		return listLobbies(cmd)
	case "join_lobby":
		return joinLobby(cmd)
	case "leave_lobby":
		return leaveLobby(cmd)
	default:
		return fail(cmd.Cmd, "unknown command")
	}
}

func ok(cmd string, data any) Response  { return Response{OK: true, Cmd: cmd, Data: data} }
func fail(cmd, err string) Response     { return Response{OK: false, Cmd: cmd, Error: err} }

// --- Commands ---

func getUser(_ Command) Response {
	mu.Lock()
	defer mu.Unlock()
	return ok("get_user", map[string]any{
		"steam_id": fmt.Sprintf("%d", uint64(sw.SteamUser().GetSteamID())),
		"name":     sw.SteamFriends().GetPersonaName(),
	})
}

func checkOwnership(_ Command) Response {
	mu.Lock()
	defer mu.Unlock()
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

	ensureCallbackLoop(done)
	mu.Lock()
	call := sw.SteamMatchmaking().CreateLobby(sw.ELobbyType_FriendsOnly, p.MaxPlayers)
	mu.Unlock()

	cr := sw.NewCallResult[LobbyCreated](call, kLobbyCreated)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, failed, err := cr.Wait(ctx, 0)
	if err != nil {
		return fail("create_lobby", fmt.Sprintf("timeout: %v", err))
	}
	if failed || result.Result != sw.EResultOK {
		return fail("create_lobby", fmt.Sprintf("failed: result %d", result.Result))
	}

	mu.Lock()
	defer mu.Unlock()
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
	ensureCallbackLoop(done)
	mu.Lock()
	sw.SteamMatchmaking().AddRequestLobbyListStringFilter("mod", "rtv-coop", sw.ELobbyComparisonEqual)
	call := sw.SteamMatchmaking().RequestLobbyList()
	mu.Unlock()

	cr := sw.NewCallResult[LobbyMatchList](call, kLobbyMatchList)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, _, err := cr.Wait(ctx, 0)
	if err != nil {
		return fail("list_lobbies", fmt.Sprintf("timeout: %v", err))
	}

	mu.Lock()
	defer mu.Unlock()
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

	ensureCallbackLoop(done)
	mu.Lock()
	call := sw.SteamMatchmaking().JoinLobby(sw.CSteamID(lobbyID))
	mu.Unlock()

	cr := sw.NewCallResult[LobbyEnter](call, kLobbyEnter)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	result, _, err := cr.Wait(ctx, 0)
	if err != nil {
		return fail("join_lobby", fmt.Sprintf("timeout: %v", err))
	}
	if result.ChatRoomEnterResponse != 1 {
		return fail("join_lobby", fmt.Sprintf("join denied: %d", result.ChatRoomEnterResponse))
	}

	mu.Lock()
	defer mu.Unlock()
	currentLobby = sw.CSteamID(result.SteamIDLobby)
	ownerID := sw.SteamMatchmaking().GetLobbyOwner(currentLobby)
	return ok("join_lobby", map[string]any{
		"lobby_id":      fmt.Sprintf("%d", result.SteamIDLobby),
		"host_steam_id": fmt.Sprintf("%d", uint64(ownerID)),
	})
}

func leaveLobby(_ Command) Response {
	mu.Lock()
	defer mu.Unlock()
	if uint64(currentLobby) != 0 {
		sw.SteamMatchmaking().LeaveLobby(currentLobby)
		currentLobby = 0
	}
	return ok("leave_lobby", nil)
}
