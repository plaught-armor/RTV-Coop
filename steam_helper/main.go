package main

import (
	"bufio"
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

	sw "github.com/assemblaj/purego-steamworks"
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
	currentLobby sw.Uint64SteamID
)

func main() {
	flag.IntVar(&port, "port", 27099, "TCP port to listen on")
	var appIDFlag uint
	flag.UintVar(&appIDFlag, "appid", 2141300, "Steam App ID (Road to Vostok Demo)")
	flag.Parse()
	appID = uint32(appIDFlag)

	log.SetPrefix("[steam_helper] ")
	log.SetFlags(log.Ltime)

	if sw.RestartAppIfNecessary(appID) {
		log.Println("Steam requested restart via client")
		os.Exit(0)
	}

	if err := sw.Init(); err != nil {
		log.Fatalf("SteamAPI_Init failed: %v", err)
	}
	defer sw.Shutdown()

	name := sw.SteamFriends().GetPersonaName()
	steamID := sw.SteamUser().GetSteamID()
	log.Printf("Logged in as: %s (Steam64: %d)", name, steamID)

	done := make(chan struct{})
	go callbackLoop(done)

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		log.Fatalf("Listen failed: %v", err)
	}
	defer listener.Close()
	log.Printf("Listening on 127.0.0.1:%d", port)

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

func callbackLoop(done chan struct{}) {
	ticker := time.NewTicker(33 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			mu.Lock()
			sw.RunCallbacks()
			mu.Unlock()
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

func dispatch(cmd Command) Response {
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
	case "start_p2p_host":
		return cmdStartP2PHost(cmd)
	case "start_p2p_client":
		return cmdStartP2PClient(cmd)
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
		"steam_id": fmt.Sprintf("%d", sw.SteamUser().GetSteamID()),
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
		MaxPlayers int32 `json:"max_players"`
	}
	p.MaxPlayers = 4
	if cmd.Params != nil {
		json.Unmarshal(cmd.Params, &p)
	}

	ch := make(chan sw.LobbyCreated, 1)
	mu.Lock()
	cr := sw.SteamMatchmaking().CreateLobby(sw.ELobbyType_FriendsOnly, p.MaxPlayers)
	sw.RegisterCallResult(cr, func(result sw.LobbyCreated, failed bool) {
		if failed {
			result.Result = sw.EResultFail
		}
		ch <- result
	})
	mu.Unlock()

	select {
	case result := <-ch:
		mu.Lock()
		defer mu.Unlock()
		if result.Result != sw.EResultOK {
			return fail("create_lobby", fmt.Sprintf("failed: result %d", result.Result))
		}
		currentLobby = sw.Uint64SteamID(result.SteamIDLobby)
		mm := sw.SteamMatchmaking()
		mm.SetLobbyData(currentLobby, "host_name", sw.SteamFriends().GetPersonaName())
		mm.SetLobbyData(currentLobby, "mod", "rtv-coop")
		mm.SetLobbyData(currentLobby, "host_steam_id", fmt.Sprintf("%d", sw.SteamUser().GetSteamID()))
		return ok("create_lobby", map[string]any{
			"lobby_id": fmt.Sprintf("%d", currentLobby),
		})
	case <-time.After(10 * time.Second):
		return fail("create_lobby", "timeout")
	}
}

func listLobbies(_ Command) Response {
	ch := make(chan sw.LobbyMatchList, 1)
	mu.Lock()
	sw.SteamMatchmaking().AddRequestLobbyListStringFilter("mod", "rtv-coop", sw.ELobbyComparisonE_Equal)
	cr := sw.SteamMatchmaking().RequestLobbyList()
	sw.RegisterCallResult(cr, func(result sw.LobbyMatchList, failed bool) {
		if failed {
			result.LobbiesMatching = 0
		}
		ch <- result
	})
	mu.Unlock()

	select {
	case result := <-ch:
		mu.Lock()
		defer mu.Unlock()
		mm := sw.SteamMatchmaking()
		lobbies := make([]map[string]any, 0, result.LobbiesMatching)
		for i := int32(0); i < int32(result.LobbiesMatching); i++ {
			id := mm.GetLobbyByIndex(i)
			lobbies = append(lobbies, map[string]any{
				"lobby_id":      fmt.Sprintf("%d", id),
				"host_name":     string(mm.GetLobbyData(id, "host_name")),
				"host_steam_id": string(mm.GetLobbyData(id, "host_steam_id")),
				"players":       mm.GetNumLobbyMembers(id),
				"max_players":   mm.GetLobbyMemberLimit(id),
			})
		}
		return ok("list_lobbies", lobbies)
	case <-time.After(10 * time.Second):
		return fail("list_lobbies", "timeout")
	}
}

func joinLobby(cmd Command) Response {
	var p struct {
		LobbyID string `json:"lobby_id"`
	}
	if err := json.Unmarshal(cmd.Params, &p); err != nil || p.LobbyID == "" {
		return fail("join_lobby", "missing lobby_id")
	}

	var lobbyID sw.Uint64SteamID
	fmt.Sscanf(p.LobbyID, "%d", &lobbyID)

	ch := make(chan sw.LobbyEnter, 1)
	mu.Lock()
	cr := sw.SteamMatchmaking().JoinLobby(lobbyID)
	sw.RegisterCallResult(cr, func(result sw.LobbyEnter, failed bool) {
		ch <- result
	})
	mu.Unlock()

	select {
	case result := <-ch:
		mu.Lock()
		defer mu.Unlock()
		if result.ChatRoomEnterResponse != 1 { // EChatRoomEnterResponse_Success
			return fail("join_lobby", fmt.Sprintf("join denied: %d", result.ChatRoomEnterResponse))
		}
		currentLobby = sw.Uint64SteamID(result.SteamIDLobby)
		mm := sw.SteamMatchmaking()
		ownerID := mm.GetLobbyOwner(currentLobby)
		return ok("join_lobby", map[string]any{
			"lobby_id":      fmt.Sprintf("%d", currentLobby),
			"host_steam_id": fmt.Sprintf("%d", ownerID),
		})
	case <-time.After(10 * time.Second):
		return fail("join_lobby", "timeout")
	}
}

func leaveLobby(_ Command) Response {
	mu.Lock()
	defer mu.Unlock()
	if currentLobby != 0 {
		sw.SteamMatchmaking().LeaveLobby(currentLobby)
		currentLobby = 0
	}
	return ok("leave_lobby", nil)
}
