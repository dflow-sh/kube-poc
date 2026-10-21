// Copyright © 2021 - 2023 SUSE LLC
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//     http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadJoinInfo(t *testing.T) {
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "node-token")
	configFile := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(tokenFile, []byte("K10abc::server:secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configFile, []byte("node-external-ip: 203.0.113.10\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	info, err := ReadJoinInfo(tokenFile, configFile, "")
	if err != nil {
		t.Fatal(err)
	}
	if info.Server != "https://203.0.113.10:6443" {
		t.Fatalf("server = %q", info.Server)
	}
	if info.Token != "K10abc::server:secret" {
		t.Fatalf("token = %q", info.Token)
	}

	info, err = ReadJoinInfo(tokenFile, configFile, "198.51.100.8")
	if err != nil {
		t.Fatal(err)
	}
	if info.Server != "https://198.51.100.8:6443" {
		t.Fatalf("override server = %q", info.Server)
	}
}

func TestReadJoinInfoMissingToken(t *testing.T) {
	dir := t.TempDir()
	_, err := ReadJoinInfo(filepath.Join(dir, "missing"), filepath.Join(dir, "config.yaml"), "203.0.113.10")
	if err == nil {
		t.Fatal("expected an error for a missing token file")
	}
}

func TestReadJoinInfoEmptyToken(t *testing.T) {
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "node-token")
	if err := os.WriteFile(tokenFile, []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := ReadJoinInfo(tokenFile, filepath.Join(dir, "config.yaml"), "203.0.113.10")
	if err == nil {
		t.Fatal("expected an error for an empty token")
	}
}

func TestReadJoinInfoMissingAddress(t *testing.T) {
	dir := t.TempDir()
	tokenFile := filepath.Join(dir, "node-token")
	configFile := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(tokenFile, []byte("token"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configFile, []byte("flannel-backend: vxlan\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := ReadJoinInfo(tokenFile, configFile, "")
	if err == nil {
		t.Fatal("expected an error when node-external-ip is missing")
	}
}
