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
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"
)

const (
	defaultK3sNodeToken = "/var/lib/rancher/k3s/server/node-token"
	defaultK3sConfig    = "/etc/rancher/k3s/config.yaml"
)

// JoinInfo is the worker join URL and token for the first k3s server.
type JoinInfo struct {
	Server string
	Token  string
}

// NewJoinInfoCmd prints the k3s join URL and token from this server.
func NewJoinInfoCmd() *cobra.Command {
	var tokenFile, configFile, serverIP string
	cmd := &cobra.Command{
		Use:   "join-info",
		Short: "Print the k3s worker join URL and token",
		Long: `Print the URL and token a worker needs to join this k3s server.

Run it on the first server, after scripts/install.sh. The URL is
https://<first-server-ip>:6443. Workers join with scripts/join-node.sh.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			cmd.SilenceUsage = true
			info, err := ReadJoinInfo(tokenFile, configFile, serverIP)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "server: %s\ntoken: %s\n\n", info.Server, info.Token)
			fmt.Fprintf(cmd.OutOrStdout(), "On another Ubuntu machine, from a checkout of this repository:\n\n  sudo ./scripts/join-node.sh --server %s --token '%s'\n", info.Server, info.Token)
			return nil
		},
	}
	cmd.Flags().StringVar(&tokenFile, "token-file", defaultK3sNodeToken, "k3s server node token file")
	cmd.Flags().StringVar(&configFile, "k3s-config", defaultK3sConfig, "k3s server config used to read node-external-ip")
	cmd.Flags().StringVar(&serverIP, "server-ip", "", "IP workers use to reach this server (default: node-external-ip from the k3s config)")
	return cmd
}

// ReadJoinInfo reads the k3s node token and builds https://<ip>:6443.
func ReadJoinInfo(tokenFile, configFile, serverIP string) (JoinInfo, error) {
	raw, err := os.ReadFile(tokenFile)
	if err != nil {
		return JoinInfo{}, fmt.Errorf("k3s node token %s is not readable. Run this on the first server after scripts/install.sh: %w", tokenFile, err)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return JoinInfo{}, fmt.Errorf("k3s node token %s is empty", tokenFile)
	}

	ip := strings.TrimSpace(serverIP)
	if ip == "" {
		ip, err = nodeExternalIP(configFile)
		if err != nil {
			return JoinInfo{}, err
		}
	}
	if ip == "" || strings.ContainsAny(ip, " \t/") {
		return JoinInfo{}, fmt.Errorf("server IP %q is not a host address. Pass --server-ip", ip)
	}
	return JoinInfo{
		Server: "https://" + ip + ":6443",
		Token:  token,
	}, nil
}

func nodeExternalIP(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("cannot read %s for node-external-ip. Pass --server-ip: %w", path, err)
	}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "node-external-ip:") {
			continue
		}
		value := strings.TrimSpace(strings.TrimPrefix(line, "node-external-ip:"))
		value = strings.Trim(value, `"'`)
		if value == "" {
			break
		}
		return value, nil
	}
	return "", fmt.Errorf("node-external-ip is not set in %s. Pass --server-ip", path)
}
