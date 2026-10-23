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

package testenv

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	"github.com/dflow-sh/kube-poc/acceptance/helpers/machine"
	"github.com/dflow-sh/kube-poc/acceptance/helpers/proc"
	"github.com/onsi/gomega"
	"github.com/pkg/errors"
)

const (
	registryUsernameEnv = "REGISTRY_USERNAME"
	registryPasswordEnv = "REGISTRY_PASSWORD"

	// afterEachSleepPath is the path (relative to the test
	// directory) of a file which, when it, is readable, and
	// contains an integer number (*) causes the the system to
	// wait that many seconds after each test.
	//
	// (*) A number, i.e. just digits. __No trailing newline__
	afterEachSleepPath = "/tmp/after_each_sleep"

	// Namespace is the namespace used for the dflow server and staging setup
	Namespace = "dflow"
)

type DFlowEnv struct {
	machine.Machine
	nodeTmpDir      string
	DFlowUser       string
	DFlowPassword   string
	DFlowAdminToken string
	DFlowUserToken  string
}

func New(nodeDir string, rootDir, username, password, adminToken, userToken string) DFlowEnv {
	return DFlowEnv{
		nodeTmpDir:      nodeDir,
		DFlowUser:       username,
		DFlowPassword:   password,
		DFlowAdminToken: adminToken,
		DFlowUserToken:  userToken,
		Machine:         machine.New(nodeDir, username, password, adminToken, userToken, root, DFlowBinaryPath()),
	}
}

// BinaryName returns the name of the dflow binary for the current platform
func BinaryName() string {
	return fmt.Sprintf("dflow-%s-%s", runtime.GOOS, runtime.GOARCH)
}

// ServerBinaryName returns the name of the dflow binary for the server
// platform. Currently only linux servers are supported.
func ServerBinaryName() string {
	return "dflow-linux-amd64"
}

// DFlowBinaryPath returns the absolute path to the dist/dflow binary
func DFlowBinaryPath() string {
	p, _ := filepath.Abs(filepath.Join(Root(), "dist", BinaryName()))
	return p
}

// GeneratedCredential reads one key from Secret dflow-generated-passwords.
// DFLOW_ADMIN_PASSWORD and DFLOW_USER_PASSWORD override the Secret.
func GeneratedCredential(key string) (string, error) {
	switch key {
	case "adminPassword":
		if v := os.Getenv("DFLOW_ADMIN_PASSWORD"); v != "" {
			return v, nil
		}
	case "dflowPassword":
		if v := os.Getenv("DFLOW_USER_PASSWORD"); v != "" {
			return v, nil
		}
	default:
		return "", fmt.Errorf("unknown generated credential %q", key)
	}
	out, err := proc.Kubectl("get", "secret", "-n", Namespace, "dflow-generated-passwords", "-o", "jsonpath={.data."+key+"}")
	if err != nil {
		return "", err
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(out))
	if err != nil {
		return "", err
	}
	if len(raw) == 0 {
		return "", fmt.Errorf("secret dflow-generated-passwords key %s is empty", key)
	}
	return string(raw), nil
}

// DFlowYAML returns the absolute path to the dflow settings YAML
func DFlowYAML() string {
	if os.Getenv("DFLOW_SETTINGS") == "" {
		return os.ExpandEnv("${HOME}/.config/dflow/settings.yaml")
	}

	return os.Getenv("DFLOW_SETTINGS")
}

// BuilddFlow builds the dflow binaries for the server and if platforms are different also for the CLI
func BuilddFlow() {
	targets := []string{"build-linux-amd64"}
	if runtime.GOOS != "linux" || runtime.GOARCH != "amd64" {
		// we need a different binary to run locally
		targets = append(targets, fmt.Sprintf("build-%s-%s", runtime.GOOS, runtime.GOARCH))
	}

	output, err := proc.Run(Root(), false, "make", targets...)
	if err != nil {
		panic(fmt.Sprintf("Couldn't build dFlow: %s\n %s\n"+err.Error(), output))
	}
}

func CheckDependencies() error {
	ok := true

	dependencies := []struct {
		CommandName string
	}{
		{CommandName: "wget"},
		{CommandName: "tar"},
	}

	for _, dependency := range dependencies {
		_, err := exec.LookPath(dependency.CommandName)
		if err != nil {
			fmt.Printf("Not found: %s\n", dependency.CommandName)
			ok = false
		}
	}

	if ok {
		return nil
	}

	return errors.New("Please check your PATH, some of our dependencies were not found")
}

const DefaultWorkspace = "workspace"

func EnsureDefaultWorkspace(dflowBinary string) {
	gomega.Eventually(func() string {
		out, err := proc.Run("", false, dflowBinary, "namespace", "create", DefaultWorkspace)
		if err != nil {
			if exists, err := regexp.Match(`Namespace 'workspace' already exists`, []byte(out)); err == nil && exists {
				return ""
			}
			return errors.Wrap(err, out).Error()
		}
		return ""
	}, "1m").Should(gomega.BeEmpty())
}

func AppRouteFromOutput(out string) string {
	// Match route URL with either sslip.io or nip.io (environment-specific)
	routeRegexp := regexp.MustCompile(`Routes: .*\n.*(https:\/\/[^\s]+(?:sslip\.io|nip\.io))`)
	matches := routeRegexp.FindStringSubmatch(out)
	if len(matches) < 2 {
		return ""
	}
	return matches[1]
}

// AppRouteWithPort ensures the route URL has the correct port for the environment.
// In k3d, the loadbalancer maps host port 8443 to container 443, so app routes
// must use :8443 when curling from the host. Routes without a port default to 443
// which causes "connection refused".
func AppRouteWithPort(route string) string {
	if route == "" {
		return route
	}
	port := os.Getenv("DFLOW_PORT")
	if port == "" {
		port = "8443" // k3d default
	}
	// If route already has a port, return as-is (avoid double-adding)
	if regexp.MustCompile(`:\d+/?($|\?)`).MatchString(route) {
		return route
	}
	// Insert port after hostname (after "://" and up to path or end)
	schemeEnd := strings.Index(route, "://")
	if schemeEnd < 0 {
		return route + ":" + port
	}
	hostStart := schemeEnd + 3 // after "://"
	pathIdx := strings.Index(route[hostStart:], "/")
	if pathIdx < 0 {
		return route + ":" + port
	}
	insertAt := hostStart + pathIdx
	return route[:insertAt] + ":" + port + route[insertAt:]
}
