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

// Package selfupdater is used to replace the current running binary, with
// a given version. It is used to sync the cli to the server version.
package selfupdater

//go:generate go run github.com/maxbrunsfeld/counterfeiter/v6 -generate

import (
	"crypto/sha256"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"

	"github.com/dflow-sh/kube-poc/packages/dflow/helpers"
	"github.com/pkg/errors"
	progressbar "github.com/schollz/progressbar/v3"
)

type BinaryInfo struct {
	Path        string
	Dir         string
	Permissions fs.FileMode
}

//counterfeiter:generate -header ../../LICENSE_HEADER . Updater
type Updater interface {
	Update(string) error
}

// downloadFile downloads a remote file to the specified directory, using
// a "random" name. It returns the new file path and/or and error if one occurs.
func downloadFile(remoteURL, dir string) (string, error) {
	// remoteURL is obtained from the dFlow release metadata and not from arbitrary users.
	//nolint:gosec // G704 - controlled URL from trusted release metadata
	tmpFile, err := os.CreateTemp(dir, "dflow")
	if err != nil {
		return "", errors.Wrap(err, "creating a temporary file")
	}

	defer func() {
		if err := tmpFile.Close(); err != nil {
			if helpers.Logger != nil {
				helpers.Logger.Errorw("failed to close temp file", "error", err)
			}
		}
	}()

	req, err := http.NewRequest("GET", remoteURL, nil)
	if err != nil {
		return "", errors.Wrap(err, "constructing a request")
	}
	req.Header.Set("User-Agent", "dflow")
	resp, err := DownloadClient.Do(req) // nolint:gosec // remoteURL is a public release asset, not user input
	if err != nil {
		return "", errors.Wrap(err, "making the request")
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			if helpers.Logger != nil {
				helpers.Logger.Errorw("failed to close response body", "error", err)
			}
		}
	}()

	if resp.StatusCode != 200 {
		return "", errors.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	if helpers.Logger != nil {
		helpers.Logger.Infow("Downloading file", "url", remoteURL)
	}
	bar := progressbar.DefaultBytes(
		resp.ContentLength,
		"Progress",
	)

	_, err = io.Copy(io.MultiWriter(tmpFile, bar), resp.Body)
	if err != nil {
		return "", errors.Wrap(err, "downloading the remote file")
	}

	return tmpFile.Name(), nil
}

// currentBinaryInfo returns a BinaryInfo with information about the currently
// running binary or an error if one occurs.
func currentBinaryInfo() (BinaryInfo, error) {
	var err error
	result := BinaryInfo{}

	result.Path, err = os.Executable()
	if err != nil {
		return result, errors.Wrap(err, "getting the current executable path")
	}
	result.Dir = filepath.Dir(result.Path)

	info, err := os.Stat(result.Path)
	if err != nil {
		return result, errors.Wrap(err, "getting the current executable permissions")
	}
	result.Permissions = info.Mode()

	return result, nil
}

func validateFileChecksum(filePath, checksumFileURL, assetName string) error {
	tmpDir, err := os.MkdirTemp("", "dflow")
	if err != nil {
		return errors.Wrap(err, "creating temporary directory")
	}

	defer func() {
		if err := os.RemoveAll(tmpDir); err != nil {
			if helpers.Logger != nil {
				helpers.Logger.Errorw("failed to remove temp directory", "error", err)
			}
		}
	}()

	tmpChecksumFile, err := downloadFile(checksumFileURL, tmpDir)
	if err != nil {
		return errors.Wrap(err, "downloading checksum file")
	}

	checksumFileContents, err := os.ReadFile(tmpChecksumFile)
	if err != nil {
		return errors.Wrap(err, "reading the checksum file")
	}

	return matchFileChecksum(filePath, string(checksumFileContents), assetName)
}

func calculateChecksum(filePath string) (string, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return "", errors.Wrapf(err, "opening file %s", filePath)
	}

	defer func() {
		if err := f.Close(); err != nil {
			if helpers.Logger != nil {
				helpers.Logger.Errorw("failed to close file", "error", err)
			}
		}
	}()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", errors.Wrap(err, "calculating checksum")
	}

	return fmt.Sprintf("%x", h.Sum(nil)), nil
}
