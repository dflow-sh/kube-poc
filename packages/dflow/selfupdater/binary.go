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
	stderrors "errors"
	"os"

	"github.com/pkg/errors"
)

func updateRunningBinary(targetVersion, goos, goarch string) error {
	asset, err := AssetName(goos, goarch)
	if err != nil {
		return err
	}
	binaryURL, err := BinaryURL(targetVersion, goos, goarch)
	if err != nil {
		return err
	}

	binaryInfo, err := currentBinaryInfo()
	if err != nil {
		return errors.Wrap(err, "extracting information from the current binary")
	}

	tmpFile, err := downloadFile(binaryURL, binaryInfo.Dir)
	if err != nil {
		if isPermission(err) {
			return &PermissionError{Path: binaryInfo.Path, Err: err}
		}
		return errors.Wrapf(err, "downloading the binary for version %s", targetVersion)
	}
	defer os.Remove(tmpFile)

	if err := validateFileChecksum(tmpFile, ChecksumURL(targetVersion), asset); err != nil {
		return errors.Wrap(err, "validating file checksum")
	}
	return replaceBinary(tmpFile, binaryInfo)
}

func replaceBinary(tmpFile string, info BinaryInfo) error {
	err := os.Rename(tmpFile, info.Path)
	if err != nil {
		if isPermission(err) {
			return &PermissionError{Path: info.Path, Err: err}
		}
		var linkErr *os.LinkError
		if stderrors.As(err, &linkErr) {
			contents, readErr := os.ReadFile(tmpFile)
			if readErr != nil {
				return errors.Wrap(readErr, "reading the downloaded binary")
			}
			if writeErr := os.WriteFile(info.Path, contents, info.Permissions); writeErr != nil {
				if isPermission(writeErr) {
					return &PermissionError{Path: info.Path, Err: writeErr}
				}
				return errors.Wrap(writeErr, "copying the new binary into place")
			}
		} else {
			return errors.Wrap(err, "moving the downloaded binary into place")
		}
	}
	if err := os.Chmod(info.Path, info.Permissions); err != nil {
		if isPermission(err) {
			return &PermissionError{Path: info.Path, Err: err}
		}
		return errors.Wrap(err, "setting the new file permissions")
	}
	return nil
}

func isPermission(err error) bool {
	return err != nil && stderrors.Is(err, os.ErrPermission)
}
