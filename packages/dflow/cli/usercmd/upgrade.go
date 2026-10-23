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

package usercmd

import (
	stderrors "errors"
	"runtime"
	"strings"

	"github.com/dflow-sh/kube-poc/packages/dflow/selfupdater"
	"github.com/dflow-sh/kube-poc/packages/dflow/version"
	"github.com/pkg/errors"
)

// UpgradeOptions selects the CLI binary, the server, or both.
type UpgradeOptions struct {
	Version    string
	CLIOnly    bool
	ServerOnly bool
	DryRun     bool
}

// ServerUpgrader upgrades the in-cluster dflow server to a release tag.
type ServerUpgrader interface {
	Upgrade(version string, dryRun bool) error
}

// Upgrade replaces the CLI from a public GitHub release, then upgrades the server.
func (c *DFlowClient) Upgrade(opts UpgradeOptions) error {
	if opts.CLIOnly && opts.ServerOnly {
		return errors.New("--cli-only and --server-only cannot be combined")
	}

	tag, err := selfupdater.ResolveReleaseTag(opts.Version, nil)
	if err != nil {
		return err
	}

	if !opts.ServerOnly {
		if err := c.upgradeCLI(opts, tag); err != nil {
			return err
		}
	}
	if !opts.CLIOnly {
		if err := c.upgradeServer(opts, tag); err != nil {
			return err
		}
	}
	if !opts.DryRun {
		c.ui.Success().Msgf("dflow %s is current", tag)
	}
	return nil
}

func (c *DFlowClient) upgradeCLI(opts UpgradeOptions, tag string) error {
	asset, err := selfupdater.AssetName(runtime.GOOS, runtime.GOARCH)
	if err != nil {
		return err
	}
	binaryURL, err := selfupdater.BinaryURL(tag, runtime.GOOS, runtime.GOARCH)
	if err != nil {
		return err
	}
	checksumURL := selfupdater.ChecksumURL(tag)

	if opts.DryRun {
		c.ui.Note().Msg("dry-run: CLI would be upgraded first")
		c.ui.Note().Msgf("asset %s", asset)
		c.ui.Note().Msgf("download %s", binaryURL)
		c.ui.Note().Msgf("checksum %s", checksumURL)
		if version.Version == tag {
			c.ui.Note().Msgf("CLI is already %s; the binary would not be replaced", tag)
		}
		return nil
	}

	if version.Version == tag {
		c.ui.Success().Msgf("CLI is already %s", tag)
		return nil
	}

	c.ui.Note().Msgf("Upgrading the CLI to %s", tag)
	if err := c.Updater.Update(tag); err != nil {
		var perm *selfupdater.PermissionError
		if stderrors.As(err, &perm) {
			return errors.Errorf("%s\n  %s", err.Error(), sudoUpgradeLine(opts, tag))
		}
		return errors.Wrap(err, "upgrading the CLI")
	}
	c.ui.Success().Msgf("Replaced the CLI binary with %s", tag)
	return nil
}

func (c *DFlowClient) upgradeServer(opts UpgradeOptions, tag string) error {
	server := c.Server
	if server == nil {
		server = HostServerUpgrader{}
	}
	if opts.DryRun {
		c.ui.Note().Msgf("dry-run: server would be upgraded to %s after the CLI", tag)
	} else {
		c.ui.Note().Msgf("Upgrading the server to %s", tag)
	}
	if err := server.Upgrade(tag, opts.DryRun); err != nil {
		return errors.Wrap(err, "upgrading the server")
	}
	return nil
}

func sudoUpgradeLine(opts UpgradeOptions, tag string) string {
	parts := []string{"sudo", "dflow", "upgrade", "--version", tag}
	if opts.CLIOnly {
		parts = append(parts, "--cli-only")
	}
	if opts.ServerOnly {
		parts = append(parts, "--server-only")
	}
	if opts.DryRun {
		parts = append(parts, "--dry-run")
	}
	return strings.Join(parts, " ")
}
