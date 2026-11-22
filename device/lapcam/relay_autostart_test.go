package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// "Start streaming when the camera boots" is also kept in the relay's config
// ("autostart"), where S93youtube-relay and the supervisor read it: the file
// on the SD card survives a formatted data partition, the init script's
// executable bit does not.
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

	// on again
	if err := setAutostartFlag(path, true); err != nil {
		t.Fatal(err)
	}
	if !autostartFlag(path) {
		t.Fatal("after setting it on the flag says off")
	}

	// what a hand-edited file may hold: the init script reads the value with
	// jct, which prints the string "false" like the boolean
	for content, want := range map[string]bool{
		`{"autostart":"false"}`: false,
		`{"autostart":"true"}`:  true,
		`{"autostart":null}`:    true,
		`{"autostart":0}`:       true,
	} {
		p := filepath.Join(t.TempDir(), relayCfgName)
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := autostartFlag(p); got != want {
			t.Errorf("%s: flag %v, want %v", content, got, want)
		}
	}

	// a config that does not exist yet gets just the key (no stream key: the relay does nothing with it)
	fresh := t.TempDir()
	if err := setAutostartFlag(filepath.Join(fresh, relayCfgName), false); err != nil {
		t.Fatal(err)
	}
	if autostartFlag(filepath.Join(fresh, relayCfgName)) || newRelay(fresh).configured() {
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

// The state the page shows, and the two places enable / disable write to.
// The init script and "service" are stand-ins: a file whose executable bit the
// fake service sets and clears, as Thingino's does.
func TestAutostartBothPlaces(t *testing.T) {
	sd := t.TempDir()
	path := filepath.Join(sd, relayCfgName)
	if err := os.WriteFile(path, []byte(`{"stream_key":"k"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	init := filepath.Join(t.TempDir(), "S93youtube-relay")
	if err := os.WriteFile(init, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	oldInit, oldService := relayInit, serviceCmd
	t.Cleanup(func() { relayInit, serviceCmd = oldInit, oldService })
	relayInit = init
	var calls []string
	var serviceErr error
	serviceCmd = func(op string) (string, error) {
		calls = append(calls, op)
		if serviceErr != nil {
			return "", serviceErr
		}
		mode := os.FileMode(0o755)
		if op == "disable" {
			mode = 0o644
		}
		return "", os.Chmod(init, mode)
	}
	rl := newRelay(sd)

	// executable and no flag: on
	if !rl.autostart() {
		t.Fatal("executable init script, no flag: must be on")
	}

	// disable: both places
	if _, err := rl.op("disable"); err != nil {
		t.Fatal(err)
	}
	if rl.autostart() || autostartFlag(path) {
		t.Fatal("after disable: still on")
	}
	if fi, _ := os.Stat(init); fi.Mode()&0o100 != 0 {
		t.Fatal("after disable: the init script is still executable")
	}

	// the data partition is lost: the init script from the rootfs is
	// executable again, the card still says off
	if err := os.Chmod(init, 0o755); err != nil {
		t.Fatal(err)
	}
	if rl.autostart() {
		t.Fatal("executable again, the card says off: the page must say off")
	}

	// enable: both places
	if _, err := rl.op("enable"); err != nil {
		t.Fatal(err)
	}
	if !rl.autostart() || !autostartFlag(path) {
		t.Fatal("after enable: still off")
	}

	// the config cannot be written (here: it is not JSON): the executable
	// bit is still set, and the error says the choice is not on the card
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	calls = nil
	_, err := rl.op("disable")
	if err == nil || !strings.Contains(err.Error(), "not saved in") {
		t.Fatalf("unwritable config: %v", err)
	}
	if len(calls) != 1 || calls[0] != "disable" {
		t.Fatalf("unwritable config: service calls %v", calls)
	}
	if fi, _ := os.Stat(init); fi.Mode()&0o100 != 0 {
		t.Fatal("unwritable config: the init script is still executable")
	}

	// "service" fails: its error comes back
	if err := os.WriteFile(path, []byte(`{"stream_key":"k"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	serviceErr = errors.New("boom")
	if _, err := rl.op("enable"); err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("failing service: %v", err)
	}
}
