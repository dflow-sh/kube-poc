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
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/usercmd"
	"github.com/spf13/cobra"
)

// NewUpgradeCmd implements `dflow upgrade`.
func NewUpgradeCmd(client *usercmd.DFlowClient) *cobra.Command {
	opts := usercmd.UpgradeOptions{Version: "latest"}
	cmd := &cobra.Command{
		Use:   "upgrade",
		Short: "Upgrade the CLI and the server from a public GitHub release",
		Long: `Upgrade the dflow CLI first, then the server, to the same public release.

The CLI binary is downloaded from
https://github.com/dflow-sh/kube-poc/releases/download/<tag>/dflow-<os>-<arch>
and checked against checksums.txt in that release. No token is sent.
The new file replaces this executable. If that file cannot be written,
the command prints a sudo line and stops before the server changes.

The server step runs helm upgrade --install for release dflow in namespace
dflow. It downloads dflow-<version>.tgz from the same release, sets
image.dflow.tag to the release, and waits until dflow-server is ready.
When docker and k3s are on this machine it pulls
ghcr.io/dflow-sh/dflow-server:<tag> and imports it into k3s first.

This command does not install k3s, cert-manager, or Traefik, does not
change the saved domain or admin password, and does not run the login
and sample-push self-test. scripts/update.sh still does those.
A machine that cannot read the cluster kubeconfig is told to run
sudo ./scripts/update.sh <tag> on the server.

--version selects a tag or latest. --cli-only and --server-only limit
the work. --dry-run prints the asset URL and the helm command.
`,
		RunE: func(cmd *cobra.Command, args []string) error {
			cmd.SilenceUsage = true
			return client.Upgrade(opts)
		},
	}
	cmd.Flags().StringVar(&opts.Version, "version", "latest", "release tag, or latest")
	cmd.Flags().BoolVar(&opts.CLIOnly, "cli-only", false, "upgrade only the CLI binary")
	cmd.Flags().BoolVar(&opts.ServerOnly, "server-only", false, "upgrade only the server")
	cmd.Flags().BoolVar(&opts.DryRun, "dry-run", false, "print the CLI download and helm upgrade without changing anything")
	return cmd
}
