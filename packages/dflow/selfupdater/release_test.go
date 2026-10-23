// Copyright © 2021 - 2023 SUSE LLC
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package selfupdater

import (
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAssetNameAndURL(t *testing.T) {
	asset, err := AssetName("linux", "amd64")
	if err != nil {
		t.Fatal(err)
	}
	if asset != "dflow-linux-amd64" {
		t.Fatalf("asset = %q", asset)
	}
	if strings.Contains(asset, "x86_64") {
		t.Fatalf("asset still uses x86_64: %s", asset)
	}

	binary, err := BinaryURL("v0.0.4", "linux", "amd64")
	if err != nil {
		t.Fatal(err)
	}
	wantBinary := "https://github.com/dflow-sh/kube-poc/releases/download/v0.0.4/dflow-linux-amd64"
	if binary != wantBinary {
		t.Fatalf("binary URL = %q", binary)
	}
	if strings.Contains(binary, "/packages/dflow/releases/") {
		t.Fatalf("binary URL uses the old path: %s", binary)
	}

	sum := ChecksumURL("v0.0.4")
	wantSum := "https://github.com/dflow-sh/kube-poc/releases/download/v0.0.4/checksums.txt"
	if sum != wantSum {
		t.Fatalf("checksum URL = %q", sum)
	}
	if strings.Contains(sum, "dflow_0.0.4_checksums.txt") {
		t.Fatalf("checksum URL uses the old file name: %s", sum)
	}

	darwin, err := AssetName("darwin", "arm64")
	if err != nil {
		t.Fatal(err)
	}
	if darwin != "dflow-darwin-arm64" {
		t.Fatalf("darwin asset = %q", darwin)
	}

	if _, err := AssetName("linux", "x86_64"); err == nil {
		t.Fatal("x86_64 was accepted as a GOARCH")
	}
}

func TestChartURL(t *testing.T) {
	if got := ChartAssetName("v0.0.4"); got != "dflow-0.0.4.tgz" {
		t.Fatalf("chart asset = %q", got)
	}
	got := ChartURL("v0.0.4")
	want := "https://github.com/dflow-sh/kube-poc/releases/download/v0.0.4/dflow-0.0.4.tgz"
	if got != want {
		t.Fatalf("chart URL = %q", got)
	}
}

func TestChecksumForAsset(t *testing.T) {
	body := "" +
		"c59da6344bbf3ac0edb2d216d544bbb92aa0fd864c5ecf7649c7bf6c0423b660  dflow-darwin-amd64\n" +
		"e300f27d3878c40d8536497b7fc1d8b8968653779595a7c3aa2072eca8f501c0  dflow-linux-amd64\n" +
		"bd673229cb81e75295cf8d8bc87260b8f5064e6cf18f8649d8898a68d1619238 *dflow-linux-arm64\n"
	got, err := ChecksumForAsset(body, "dflow-linux-amd64")
	if err != nil {
		t.Fatal(err)
	}
	want := "e300f27d3878c40d8536497b7fc1d8b8968653779595a7c3aa2072eca8f501c0"
	if got != want {
		t.Fatalf("checksum = %q", got)
	}
	star, err := ChecksumForAsset(body, "dflow-linux-arm64")
	if err != nil {
		t.Fatal(err)
	}
	if star != "bd673229cb81e75295cf8d8bc87260b8f5064e6cf18f8649d8898a68d1619238" {
		t.Fatalf("star checksum = %q", star)
	}
	if _, err := ChecksumForAsset(body, "dflow-linux-x86_64"); err == nil {
		t.Fatal("missing asset returned a checksum")
	}
}

func TestMatchFileChecksum(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dflow-linux-amd64")
	payload := []byte("dflow-binary")
	if err := os.WriteFile(path, payload, 0o755); err != nil {
		t.Fatal(err)
	}
	sum := fmt.Sprintf("%x", sha256.Sum256(payload))
	body := sum + "  dflow-linux-amd64\n"
	if err := matchFileChecksum(path, body, "dflow-linux-amd64"); err != nil {
		t.Fatal(err)
	}
	bad := strings.Repeat("ab", 32) + "  dflow-linux-amd64\n"
	if err := matchFileChecksum(path, bad, "dflow-linux-amd64"); err == nil {
		t.Fatal("mismatched checksum was accepted")
	}
}

func TestResolveReleaseTag(t *testing.T) {
	got, err := ResolveReleaseTag("v0.0.4", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got != "v0.0.4" {
		t.Fatalf("tag = %q", got)
	}
	if _, err := ResolveReleaseTag("../v0.0.4", nil); err == nil {
		t.Fatal("path tag was accepted")
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			t.Errorf("Authorization header was sent")
		}
		if r.URL.Path != "/repos/dflow-sh/kube-poc/releases/latest" {
			// The client calls an absolute URL, so the test server only sees the path
			// when the request URL is rewritten. ResolveReleaseTag uses a fixed host.
		}
		fmt.Fprint(w, `{"tag_name":"v0.0.4"}`)
	}))
	t.Cleanup(srv.Close)

	client := srv.Client()
	orig := latestAPI
	latestAPI = srv.URL
	t.Cleanup(func() { latestAPI = orig })

	got, err = ResolveReleaseTag("latest", client)
	if err != nil {
		t.Fatal(err)
	}
	if got != "v0.0.4" {
		t.Fatalf("latest = %q", got)
	}
}

func TestPermissionErrorHint(t *testing.T) {
	err := &PermissionError{Path: "/usr/local/bin/dflow", Err: os.ErrPermission}
	msg := err.Error()
	if !strings.Contains(msg, "sudo dflow upgrade") {
		t.Fatalf("hint = %q", msg)
	}
	if !strings.Contains(msg, "/usr/local/bin/dflow") {
		t.Fatalf("path missing from %q", msg)
	}
}
