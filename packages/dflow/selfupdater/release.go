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
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/pkg/errors"
)

const (
	releaseOwner   = "dflow-sh"
	releaseRepo    = "kube-poc"
	checksumsAsset = "checksums.txt"
)

// ArchToURL maps GOARCH to the architecture used in release asset names.
// Published assets are dflow-<os>-<arch>, for example dflow-linux-amd64.
var ArchToURL = map[string]string{
	"amd64": "amd64",
	"arm64": "arm64",
}

// DownloadClient is used for release metadata and assets. It sends no token.
var DownloadClient = &http.Client{Timeout: 15 * time.Minute}

func releaseDownloadBase() string {
	return fmt.Sprintf("https://github.com/%s/%s/releases/download", releaseOwner, releaseRepo)
}

// NormalizeTag accepts a release tag or "latest". Empty means latest.
func NormalizeTag(tag string) (string, error) {
	tag = strings.TrimSpace(tag)
	if tag == "" || tag == "latest" {
		return "latest", nil
	}
	if strings.Contains(tag, "..") || strings.ContainsAny(tag, "/\\?# \t") {
		return "", errors.Errorf("invalid release tag %q", tag)
	}
	return tag, nil
}

// AssetName is the GitHub release file for this OS and architecture.
func AssetName(goos, goarch string) (string, error) {
	arch, ok := ArchToURL[goarch]
	if !ok {
		return "", errors.Errorf("unknown architecture: %s", goarch)
	}
	switch goos {
	case "linux", "darwin", "windows":
		return fmt.Sprintf("dflow-%s-%s", goos, arch), nil
	default:
		return "", errors.Errorf("unknown operating system: %s", goos)
	}
}

func releaseAssetURL(tag, name string) string {
	return fmt.Sprintf("%s/%s/%s", releaseDownloadBase(), url.PathEscape(tag), url.PathEscape(name))
}

// BinaryURL is the unauthenticated download for one CLI binary.
func BinaryURL(tag, goos, goarch string) (string, error) {
	asset, err := AssetName(goos, goarch)
	if err != nil {
		return "", err
	}
	return releaseAssetURL(tag, asset), nil
}

// ChecksumURL is the unauthenticated download for checksums.txt.
func ChecksumURL(tag string) string {
	return releaseAssetURL(tag, checksumsAsset)
}

// ChartAssetName is the Helm package uploaded next to the CLI binaries.
// Tag v0.0.4 publishes dflow-0.0.4.tgz.
func ChartAssetName(tag string) string {
	return fmt.Sprintf("dflow-%s.tgz", strings.TrimPrefix(tag, "v"))
}

// ChartURL is the unauthenticated download for that Helm package.
func ChartURL(tag string) string {
	return releaseAssetURL(tag, ChartAssetName(tag))
}

// ServerImage is the public server image for a release tag.
func ServerImage(tag string) string {
	return "ghcr.io/dflow-sh/dflow-server:" + tag
}

func latestReleaseAPI() string {
	return fmt.Sprintf("https://api.github.com/repos/%s/%s/releases/latest", releaseOwner, releaseRepo)
}

// latestAPI is the public latest-release endpoint. Tests replace it.
var latestAPI = latestReleaseAPI()

// ChecksumForAsset returns the hex SHA256 for asset from a checksums.txt body.
func ChecksumForAsset(content, asset string) (string, error) {
	if asset == "" {
		return "", errors.New("asset name is empty")
	}
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		name := strings.TrimPrefix(fields[len(fields)-1], "*")
		if name == asset || strings.HasSuffix(name, "/"+asset) {
			sum := fields[0]
			if len(sum) != 64 || !isHex(sum) {
				return "", errors.Errorf("checksum for %s is not SHA256", asset)
			}
			return strings.ToLower(sum), nil
		}
	}
	return "", errors.Errorf("checksums.txt has no entry for %s", asset)
}

func isHex(s string) bool {
	for _, r := range s {
		switch {
		case r >= '0' && r <= '9':
		case r >= 'a' && r <= 'f':
		case r >= 'A' && r <= 'F':
		default:
			return false
		}
	}
	return true
}

// ResolveReleaseTag turns "" or "latest" into the current public tag.
// Any other tag is checked for shape and returned without a network call.
func ResolveReleaseTag(requested string, client *http.Client) (string, error) {
	tag, err := NormalizeTag(requested)
	if err != nil {
		return "", err
	}
	if tag != "latest" {
		return tag, nil
	}
	if client == nil {
		client = DownloadClient
	}
	req, err := http.NewRequest(http.MethodGet, latestAPI, nil)
	if err != nil {
		return "", errors.Wrap(err, "building the latest-release request")
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "dflow")
	resp, err := client.Do(req)
	if err != nil {
		return "", errors.Wrap(err, "reading the latest public release")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", errors.Wrap(err, "reading the latest public release")
	}
	if resp.StatusCode != http.StatusOK {
		return "", errors.Errorf("latest public release returned HTTP %d", resp.StatusCode)
	}
	var parsed struct {
		TagName string `json:"tag_name"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return "", errors.Wrap(err, "parsing the latest public release")
	}
	if parsed.TagName == "" {
		return "", errors.New("latest public release did not include a tag")
	}
	return parsed.TagName, nil
}

// PermissionError means the running user cannot replace the CLI binary.
type PermissionError struct {
	Path string
	Err  error
}

func (e *PermissionError) Error() string {
	return fmt.Sprintf("permission denied replacing %s: %v\nRun the command again with sudo, for example: sudo dflow upgrade", e.Path, e.Err)
}

func (e *PermissionError) Unwrap() error {
	return e.Err
}

func matchFileChecksum(filePath, checksumBody, assetName string) error {
	got, err := calculateChecksum(filePath)
	if err != nil {
		return err
	}
	want, err := ChecksumForAsset(checksumBody, assetName)
	if err != nil {
		return err
	}
	if !strings.EqualFold(got, want) {
		return errors.New("file checksum invalid")
	}
	return nil
}
