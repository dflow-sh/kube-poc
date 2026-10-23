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

package cmd_test

import (
	"bytes"
	"io"
	"os"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/dflow-sh/kube-poc/packages/dflow/cli/cmd"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/usercmd"
	"github.com/dflow-sh/kube-poc/packages/dflow/selfupdater"
	"github.com/dflow-sh/kube-poc/packages/dflow/selfupdater/selfupdaterfakes"
	"github.com/dflow-sh/kube-poc/packages/dflow/version"
	"github.com/spf13/cobra"
	"runtime"
)

type recordingServer struct {
	calls   int
	version string
	dryRun  bool
	err     error
}

func (r *recordingServer) Upgrade(version string, dryRun bool) error {
	r.calls++
	r.version = version
	r.dryRun = dryRun
	return r.err
}

var _ = Describe("Command 'dflow upgrade'", func() {
	var (
		upgradeCmd *cobra.Command
		updater    *selfupdaterfakes.FakeUpdater
		server     *recordingServer
		output     io.ReadWriter
	)

	BeforeEach(func() {
		dflowClient, err := usercmd.New()
		Expect(err).ToNot(HaveOccurred())
		updater = &selfupdaterfakes.FakeUpdater{}
		dflowClient.Updater = updater
		server = &recordingServer{}
		dflowClient.Server = server
		output = &bytes.Buffer{}
		dflowClient.UI().SetOutput(output)
		upgradeCmd = cmd.NewUpgradeCmd(dflowClient)
	})

	It("upgrades the CLI before the server", func() {
		initial := version.Version
		version.Version = "v0.0.3"
		DeferCleanup(func() { version.Version = initial })

		stdout, _, err := executeCmd(upgradeCmd, []string{"upgrade", "--version", "v0.0.4"}, output, nil)
		Expect(err).ToNot(HaveOccurred())
		Expect(updater.UpdateCallCount()).To(Equal(1))
		Expect(updater.UpdateArgsForCall(0)).To(Equal("v0.0.4"))
		Expect(server.calls).To(Equal(1))
		Expect(server.version).To(Equal("v0.0.4"))
		Expect(server.dryRun).To(BeFalse())
		Expect(stdout).To(ContainSubstring("Upgrading the CLI to v0.0.4"))
		cliAt := strings.Index(stdout, "Upgrading the CLI")
		serverAt := strings.Index(stdout, "Upgrading the server")
		Expect(cliAt).To(BeNumerically(">=", 0))
		Expect(serverAt).To(BeNumerically(">", cliAt))
	})

	It("does not download when the CLI is already that version", func() {
		initial := version.Version
		version.Version = "v0.0.4"
		DeferCleanup(func() { version.Version = initial })

		_, _, err := executeCmd(upgradeCmd, []string{"upgrade", "--version", "v0.0.4", "--cli-only"}, output, nil)
		Expect(err).ToNot(HaveOccurred())
		Expect(updater.UpdateCallCount()).To(Equal(0))
		Expect(server.calls).To(Equal(0))
	})

	It("prints a sudo hint when the binary cannot be replaced", func() {
		initial := version.Version
		version.Version = "v0.0.3"
		DeferCleanup(func() { version.Version = initial })
		updater.UpdateReturns(&selfupdater.PermissionError{Path: "/usr/local/bin/dflow", Err: os.ErrPermission})

		_, stderr, err := executeCmd(upgradeCmd, []string{"upgrade", "--version", "v0.0.4", "--cli-only"}, nil, output)
		Expect(err).To(HaveOccurred())
		Expect(server.calls).To(Equal(0))
		Expect(stderr).To(ContainSubstring("sudo dflow upgrade --version v0.0.4 --cli-only"))
		Expect(stderr).To(ContainSubstring("/usr/local/bin/dflow"))
	})

	It("dry-run does not replace the CLI or call helm", func() {
		initial := version.Version
		version.Version = "v0.0.3"
		DeferCleanup(func() { version.Version = initial })

		stdout, _, err := executeCmd(upgradeCmd, []string{"upgrade", "--version", "v0.0.4", "--dry-run"}, output, nil)
		Expect(err).ToNot(HaveOccurred())
		Expect(updater.UpdateCallCount()).To(Equal(0))
		Expect(server.dryRun).To(BeTrue())
		asset, assetErr := selfupdater.AssetName(runtime.GOOS, runtime.GOARCH)
		Expect(assetErr).ToNot(HaveOccurred())
		Expect(stdout).To(ContainSubstring("https://github.com/dflow-sh/kube-poc/releases/download/v0.0.4/" + asset))
		Expect(stdout).To(ContainSubstring("checksums.txt"))
		Expect(stdout).To(ContainSubstring("dry-run: CLI would be upgraded first"))
	})

	It("server-only skips the CLI", func() {
		_, _, err := executeCmd(upgradeCmd, []string{"upgrade", "--version", "v0.0.4", "--server-only"}, output, nil)
		Expect(err).ToNot(HaveOccurred())
		Expect(updater.UpdateCallCount()).To(Equal(0))
		Expect(server.calls).To(Equal(1))
		Expect(server.version).To(Equal("v0.0.4"))
	})
})
