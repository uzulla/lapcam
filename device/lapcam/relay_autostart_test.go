package main

import (
	"os"
	"path/filepath"
	"testing"
)

// "Start streaming when the camera boots" is also kept in the relay's config
// ("autostart"), where S93youtube-relay reads it: the file on the SD card
// survives a formatted data partition, the init script's executable bit does not.
func TestAutostartFlag(t *testing.T) {
	sd := t.TempDir()
	path := filepath.Join(sd, relayCfgName)

	// no file, and a file without the key: left to the init script
	if !autostartFlag(path) {
		t.Fatal("no config: the flag must not say off")
	}
	if err := os.WriteFile(path, []byte(`{"stream_key":"k","rtmp_url":"rtmp://h/app","enabled":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if !autostartFlag(path) {
		t.Fatal("config without the key: the flag must not say off")
	}

	// off, and the other keys are kept
	if err := setAutostartFlag(path, false); err != nil {
		t.Fatal(err)
	}
	if autostartFlag(path) {
		t.Fatal("after setting it off the flag still says on")
	}
	cfg, err := readJSONFile(path)
	if err != nil || cfg["stream_key"] != "k" || cfg["rtmp_url"] != "rtmp://h/app" || cfg["enabled"] != true || cfg["autostart"] != false {
		t.Fatalf("config after setting the flag: %v %v", cfg, err)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("the config holds the stream key and must stay 0600: %v %v", fi, err)
	}

	// saving the profiles (a new stream key) does not lose it
	rl := newRelay(sd)
	old := isMounted
	isMounted = func(string) bool { return true }
	t.Cleanup(func() { isMounted = old })
	if _, err := rl.saveProfiles(lapcamConfig{Profiles: []profile{{Name: "A", RTMPURL: "rtmp://h/app", StreamKey: "k2"}}, Active: "A"}); err != nil {
		t.Fatal(err)
	}
	if autostartFlag(path) {
		t.Fatal("saving the profiles turned autostart back on")
	}
	if rl.autostart() {
		t.Fatal("autostart() says on although the config says off")
	}

	// on again
	if err := setAutostartFlag(path, true); err != nil {
		t.Fatal(err)
	}
	if !autostartFlag(path) {
		t.Fatal("after setting it on the flag says off")
	}

	// a config that does not exist yet gets just the key (no stream key: the relay does nothing with it)
	fresh := filepath.Join(t.TempDir(), relayCfgName)
	if err := setAutostartFlag(fresh, false); err != nil {
		t.Fatal(err)
	}
	if autostartFlag(fresh) || newRelayAt(fresh).configured() {
		t.Fatal("a fresh config with only the flag: must be off and not configured")
	}

	// a broken file is not overwritten
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := setAutostartFlag(path, false); err == nil {
		t.Fatal("a config that is not JSON was overwritten")
	}
	if b, _ := os.ReadFile(path); string(b) != "{not json" {
		t.Fatalf("the broken config changed: %q", b)
	}
}

// newRelayAt - a relay whose SD card is the directory of path
func newRelayAt(path string) *relay { return newRelay(filepath.Dir(path)) }
