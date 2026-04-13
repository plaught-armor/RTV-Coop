//go:build ignore

// Packages the co-op mod into a .vmz archive for the Metro Mod Loader.
//
// Usage:
//
//	go run build.go [output_name] [release] [no-deploy]
//
// Examples:
//
//	go run build.go                        # dev build, auto-deploy
//	go run build.go rtv-coop release       # release build, auto-deploy
//	go run build.go rtv-coop release no-deploy
package main

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

var modDirs = []string{"autoload", "network", "patches", "presentation", "ui", "bin"}

var helperBins = []string{"steam_helper_linux", "steam_helper.exe"}
var sdkLibs = []string{"libsteam_api.so", "libsteam_api64.so", "steam_api64.dll"}

var excludeDirs = map[string]bool{".git": true, "steam_helper": true}
var excludeFiles = map[string]bool{".gitignore": true, "build.sh": true, "build.py": true, "build.go": true, "README.md": true, "INSTALLATION.md": true, "mod.txt": true}
var excludeExts = map[string]bool{".vmz": true, ".uid": true}

func main() {
	args := os.Args[1:]
	outputName := "rtv-coop"
	appID := "480"
	skipDeploy := false

	for _, arg := range args {
		switch arg {
		case "release":
			appID = "1963610"
		case "no-deploy":
			skipDeploy = true
		default:
			if !strings.HasPrefix(arg, "-") {
				outputName = arg
			}
		}
	}

	scriptDir, err := filepath.Abs(filepath.Dir(os.Args[0]))
	if err != nil {
		// Fallback: use working directory
		scriptDir, _ = os.Getwd()
	}
	// When run via `go run`, os.Args[0] points to a temp dir. Use cwd instead.
	if _, err := os.Stat(filepath.Join(scriptDir, "mod.txt")); err != nil {
		scriptDir, _ = os.Getwd()
	}

	outputFile := filepath.Join(scriptDir, outputName+".vmz")

	fmt.Println("Copying steam helper binaries...")
	copyHelpers(scriptDir)

	fmt.Printf("  Steam App ID: %s\n", appID)
	os.MkdirAll(filepath.Join(scriptDir, "bin"), 0755)
	os.WriteFile(filepath.Join(scriptDir, "bin", "steam_appid.txt"), []byte(appID+"\n"), 0644)

	os.Remove(outputFile)

	fmt.Printf("Building %s...\n", filepath.Base(outputFile))
	if err := buildArchive(scriptDir, outputFile); err != nil {
		fmt.Fprintf(os.Stderr, "Build failed: %v\n", err)
		os.Exit(1)
	}

	info, _ := os.Stat(outputFile)
	size := info.Size()
	var sizeStr string
	if size > 1024*1024 {
		sizeStr = fmt.Sprintf("%.1f MB", float64(size)/(1024*1024))
	} else {
		sizeStr = fmt.Sprintf("%d KB", size/1024)
	}
	fmt.Printf("Built: %s (%s)\n", filepath.Base(outputFile), sizeStr)

	if skipDeploy {
		fmt.Println("Skipping deploy (no-deploy flag)")
	} else {
		deploy(outputFile, outputName)
	}
}

func copyHelpers(scriptDir string) {
	binDir := filepath.Join(scriptDir, "bin")
	os.MkdirAll(binDir, 0755)
	helperBinDir := filepath.Join(scriptDir, "steam_helper", "bin")

	for _, name := range append(helperBins, sdkLibs...) {
		src := filepath.Join(helperBinDir, name)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		dst := filepath.Join(binDir, name)
		if err := copyFile(src, dst); err == nil {
			fmt.Printf("  Included: %s\n", name)
		}
	}
}

func shouldExclude(rel string) bool {
	parts := strings.Split(filepath.ToSlash(rel), "/")
	for _, part := range parts {
		if excludeDirs[part] || excludeFiles[part] {
			return true
		}
	}
	if excludeExts[filepath.Ext(rel)] {
		return true
	}
	return false
}

func buildArchive(scriptDir, outputFile string) error {
	f, err := os.Create(outputFile)
	if err != nil {
		return err
	}
	defer f.Close()

	zw := zip.NewWriter(f)
	defer zw.Close()

	// mod.txt at archive root
	modTxt := filepath.Join(scriptDir, "mod.txt")
	if _, err := os.Stat(modTxt); err == nil {
		if err := addFileToZip(zw, modTxt, "mod.txt"); err != nil {
			return fmt.Errorf("adding mod.txt: %w", err)
		}
		fmt.Println("  Added: mod.txt")
	}

	// mod/* directories
	for _, dirName := range modDirs {
		dirPath := filepath.Join(scriptDir, dirName)
		if _, err := os.Stat(dirPath); err != nil {
			continue
		}
		err := filepath.Walk(dirPath, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() {
				return nil
			}
			rel, _ := filepath.Rel(scriptDir, path)
			if shouldExclude(rel) {
				return nil
			}
			archivePath := filepath.ToSlash(filepath.Join("mod", rel))
			return addFileToZip(zw, path, archivePath)
		})
		if err != nil {
			return fmt.Errorf("walking %s: %w", dirName, err)
		}
	}

	return nil
}

func addFileToZip(zw *zip.Writer, srcPath, archivePath string) error {
	src, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer src.Close()

	info, err := src.Stat()
	if err != nil {
		return err
	}

	header, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	header.Name = archivePath
	header.Method = zip.Deflate

	w, err := zw.CreateHeader(header)
	if err != nil {
		return err
	}
	_, err = io.Copy(w, src)
	return err
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func deploy(outputFile, outputName string) {
	home, _ := os.UserHomeDir()
	var candidates []string

	switch runtime.GOOS {
	case "linux":
		candidates = []string{
			filepath.Join(home, ".local/share/Steam/steamapps/common/Road to Vostok/mods"),
			filepath.Join(home, ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Road to Vostok/mods"),
		}
	case "windows":
		prog := os.Getenv("PROGRAMFILES(X86)")
		if prog == "" {
			prog = `C:\Program Files (x86)`
		}
		candidates = []string{
			filepath.Join(prog, "Steam", "steamapps", "common", "Road to Vostok", "mods"),
		}
		if up := os.Getenv("USERPROFILE"); up != "" {
			candidates = append(candidates, filepath.Join(up, "Steam", "steamapps", "common", "Road to Vostok", "mods"))
		}
	case "darwin":
		candidates = []string{
			filepath.Join(home, "Library/Application Support/Steam/steamapps/common/Road to Vostok/mods"),
		}
	}

	if lib := os.Getenv("STEAM_LIBRARY"); lib != "" {
		candidates = append(candidates, filepath.Join(lib, "steamapps", "common", "Road to Vostok", "mods"))
	}

	for _, dir := range candidates {
		if info, err := os.Stat(dir); err == nil && info.IsDir() {
			dst := filepath.Join(dir, outputName+".vmz")
			if err := copyFile(outputFile, dst); err == nil {
				fmt.Printf("Deployed to: %s\n", dst)
				return
			}
		}
	}

	fmt.Println("\nNo mods directory found. Copy manually:")
	fmt.Printf("  %s\n", outputFile)
	fmt.Println("  -> <steam>/steamapps/common/Road to Vostok/mods/")
	fmt.Println("  Set STEAM_LIBRARY env var for custom Steam library folders.")
}
