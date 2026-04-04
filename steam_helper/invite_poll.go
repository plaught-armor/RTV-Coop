package main

import (
	"fmt"
	"os"
	"runtime"

	sw "github.com/badhex/go-steamworks"
)

// isProton detects Wine/Proton on Windows by checking for STEAM_COMPAT_DATA_PATH.
func isProton() bool {
	return runtime.GOOS == "windows" && os.Getenv("STEAM_COMPAT_DATA_PATH") != ""
}

// checkLaunchInvite checks if the game was launched with +connect_lobby from a Steam invite.
// Gated for Proton where GetLaunchCommandLine segfaults.
func checkLaunchInvite(_ Command) Response {
	if isProton() {
		return ok("check_launch_invite", map[string]any{"lobby_id": ""})
	}
	cmdLine := sw.SteamApps().GetLaunchCommandLine(512)
	lobbyParam := sw.SteamApps().GetLaunchQueryParam("connect_lobby")
	return ok("check_launch_invite", map[string]any{
		"command_line": cmdLine,
		"lobby_id":     fmt.Sprintf("%s", lobbyParam),
	})
}
