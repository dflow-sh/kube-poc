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
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"

	"github.com/dflow-sh/kube-poc/packages/dflow/selfupdater"
	"github.com/pkg/errors"
)

const hostValuesPath = "/var/lib/dflow/values.yaml"
const hostKubeconfigPath = "/etc/rancher/k3s/k3s.yaml"

// HostServerUpgrader runs the same helm upgrade scripts/update.sh uses,
// against a cluster this machine can already read.
type HostServerUpgrader struct {
	Kubeconfig       string
	ValuesFile       string
	ChartPath        string
	SkipImageImport  bool
	IgnoreHostValues bool
	Output           io.Writer
	Runner           func(ctx context.Context, kubeconfig, name string, args ...string) error
	// SecretValue reads one decoded key from Secret dflow-generated-passwords.
	// The default is kubectl. Tests set this.
	SecretValue func(ctx context.Context, kubeconfig, key string) (string, error)
}

const replacedAdminPasswordWarning = "warning: replaced the old default admin password. It no longer works. " +
	"Read the new one with: kubectl -n dflow get secret dflow-generated-passwords " +
	"-o jsonpath='{.data.adminPassword}' | base64 -d; echo\n"

// HelmUpgradeArgs is the helm invocation for one release tag.
func HelmUpgradeArgs(chartPath, valuesFile, tag string) []string {
	args := []string{
		"upgrade", "--install", "dflow", chartPath,
		"--namespace", "dflow",
		"--create-namespace",
	}
	if valuesFile != "" {
		args = append(args, "--values", valuesFile)
	} else {
		args = append(args, "--reuse-values")
	}
	args = append(args, "--set", "image.dflow.tag="+tag, "--timeout", "15m")
	return args
}

func (h HostServerUpgrader) Upgrade(version string, dryRun bool) error {
	tag, err := selfupdater.NormalizeTag(version)
	if err != nil {
		return err
	}
	if tag == "latest" {
		return errors.New("server upgrade needs a resolved release tag")
	}

	kube, kubeErr := h.kubeconfig()
	values := h.valuesPath()
	state, valuesErr := h.inspectValuesFile(values)
	chartURL := selfupdater.ChartURL(tag)
	image := selfupdater.ServerImage(tag)
	if dryRun {
		fmt.Fprintf(h.out(), "server image %s\nchart %s\nhelm %s\n", image, chartURL, strings.Join(HelmUpgradeArgs("<chart>", values, tag), " "))
		if state.replacedDefault {
			fmt.Fprint(h.out(), replacedAdminPasswordWarning)
		}
		if state.replacedDefault || state.missingChecksum {
			fmt.Fprintf(h.out(), "Dex would be restarted so it loads the current admin password\n")
		}
		if valuesErr != nil {
			fmt.Fprintf(h.out(), "server upgrade would stop: %s\n", valuesErr.Error())
		}
		if kubeErr != nil {
			fmt.Fprintf(h.out(), "server upgrade would stop: %s\n", kubeErr.Error())
		}
		return nil
	}
	if valuesErr != nil {
		return valuesErr
	}
	if kubeErr != nil {
		return kubeErr
	}
	if err := restrictValuesFile(values); err != nil {
		return err
	}
	if _, err := exec.LookPath("helm"); err != nil && h.Runner == nil {
		return errors.Errorf("helm is not installed. On the server run: sudo ./scripts/update.sh %s", tag)
	}
	if _, err := exec.LookPath("kubectl"); err != nil && h.Runner == nil {
		return errors.Errorf("kubectl is not installed. On the server run: sudo ./scripts/update.sh %s", tag)
	}

	chartPath := h.ChartPath
	if chartPath == "" {
		chartPath, err = downloadChart(tag)
		if err != nil {
			return err
		}
		defer os.Remove(chartPath)
	}
	if err := h.importImage(context.Background(), tag); err != nil {
		return err
	}
	if err := h.run(context.Background(), kube, "helm", HelmUpgradeArgs(chartPath, values, tag)...); err != nil {
		return errors.Wrap(err, "helm upgrade failed")
	}
	if err := h.run(context.Background(), kube, "kubectl", "-n", "dflow", "rollout", "status", "deploy/dflow-server", "--timeout=15m"); err != nil {
		return errors.Wrap(err, "dflow-server did not become ready")
	}
	if state.replacedDefault {
		fmt.Fprint(h.out(), replacedAdminPasswordWarning)
	}
	if err := h.run(context.Background(), kube, "kubectl", "-n", "dflow", "get", "deploy", "dex"); err == nil {
		if err := h.rollDex(context.Background(), kube, chartPath, values, tag, state); err != nil {
			return err
		}
	}
	if err := h.run(context.Background(), kube, "kubectl", "-n", "dflow", "get", "certificate", "dflow"); err == nil {
		if err := h.run(context.Background(), kube, "kubectl", "-n", "dflow", "wait", "--for=condition=Ready", "certificate/dflow", "--timeout=10m"); err != nil {
			return errors.Wrap(err, "certificate/dflow did not become Ready")
		}
	}
	return restrictValuesFile(values)
}

type hostValuesState struct {
	replacedDefault bool
	missingChecksum bool
}

func (h HostServerUpgrader) inspectValuesFile(path string) (hostValuesState, error) {
	if path == "" {
		return hostValuesState{}, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return hostValuesState{}, errors.Wrapf(err, "reading %s", path)
	}
	return inspectHostValues(string(data)), nil
}

func inspectHostValues(data string) hostValuesState {
	state := hostValuesState{
		missingChecksum: !strings.Contains(data, "checksum/generated-passwords:"),
	}
	for _, line := range strings.Split(data, "\n") {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "#") || !strings.HasPrefix(trim, "adminPassword:") {
			continue
		}
		value := strings.TrimSpace(strings.TrimPrefix(trim, "adminPassword:"))
		if knownDefaultSecret(value) {
			state.replacedDefault = true
		}
	}
	return state
}

func knownDefaultSecret(value string) bool {
	value = strings.TrimSpace(value)
	value = strings.Trim(value, `"'`)
	return value == "password" || value == "changeme"
}

func (h HostServerUpgrader) rollDex(ctx context.Context, kube, chartPath, values, tag string, state hostValuesState) error {
	if state.replacedDefault || state.missingChecksum {
		applied, err := h.applyDexChecksum(ctx, kube, chartPath, values, tag, state)
		if err != nil {
			return err
		}
		if !applied {
			fmt.Fprintf(h.out(), "restarting Dex so it loads the current admin password\n")
			if err := h.run(ctx, kube, "kubectl", "-n", "dflow", "rollout", "restart", "deploy/dex"); err != nil {
				return errors.Wrap(err, "restarting dex")
			}
			if state.replacedDefault && values != "" {
				if err := clearSavedDefault(values); err != nil {
					fmt.Fprintf(h.out(), "could not remove the old default from %s (%s)\n", values, err.Error())
				}
			}
		}
	}
	if err := h.run(ctx, kube, "kubectl", "-n", "dflow", "rollout", "status", "deploy/dex", "--timeout=10m"); err != nil {
		return errors.Wrap(err, "dex did not become ready")
	}
	return nil
}

// applyDexChecksum writes the bcrypt checksum into a copy of the values file
// and helm-upgrades with that copy. The saved file is replaced only after
// helm succeeds, so a failed roll leaves the old defaults in place for a retry.
func (h HostServerUpgrader) applyDexChecksum(ctx context.Context, kube, chartPath, values, tag string, state hostValuesState) (bool, error) {
	if values == "" {
		return false, nil
	}
	sum, err := h.adminBcryptChecksum(ctx, kube)
	if err != nil {
		fmt.Fprintf(h.out(), "could not read the generated admin password hash (%s); restarting Dex\n", err.Error())
		return false, nil
	}
	data, err := os.ReadFile(values)
	if err != nil {
		return false, errors.Wrapf(err, "reading %s", values)
	}
	next := string(data)
	if state.replacedDefault {
		next = clearDefaultAdminPassword(next)
	}
	next = addDexChecksum(next, sum)
	addedChecksum := !strings.Contains(string(data), "checksum/generated-passwords:") && strings.Contains(next, "checksum/generated-passwords:")
	if !addedChecksum {
		return false, nil
	}
	tmp := values + ".next"
	if err := os.WriteFile(tmp, []byte(next), 0o600); err != nil {
		return false, errors.Wrap(err, "writing the Dex checksum values")
	}
	defer os.Remove(tmp)
	fmt.Fprintf(h.out(), "applying the Dex checksum so the Deployment rolls\n")
	if err := h.run(ctx, kube, "helm", HelmUpgradeArgs(chartPath, tmp, tag)...); err != nil {
		return false, errors.Wrap(err, "helm upgrade failed while rolling Dex")
	}
	if err := os.WriteFile(values, []byte(next), 0o600); err != nil {
		return false, errors.Wrapf(err, "saving %s", values)
	}
	return true, nil
}

func (h HostServerUpgrader) adminBcryptChecksum(ctx context.Context, kube string) (string, error) {
	bcrypt, err := h.secretValue(ctx, kube, "adminPasswordBcrypt")
	if err != nil {
		return "", err
	}
	if bcrypt == "" {
		return "", errors.New("adminPasswordBcrypt is empty")
	}
	sum := sha256.Sum256([]byte(bcrypt))
	return hex.EncodeToString(sum[:]), nil
}

func (h HostServerUpgrader) secretValue(ctx context.Context, kube, key string) (string, error) {
	if h.SecretValue != nil {
		return h.SecretValue(ctx, kube, key)
	}
	if h.Runner != nil {
		return "", errors.New("no secret reader")
	}
	cmd := exec.CommandContext(ctx, "kubectl", "-n", "dflow", "get", "secret", "dflow-generated-passwords", "-o", "jsonpath={.data."+key+"}")
	cmd.Env = append(os.Environ(), "KUBECONFIG="+kube)
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" {
		return "", errors.New("secret key is empty")
	}
	decoded, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return "", err
	}
	return string(decoded), nil
}

func clearSavedDefault(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	next := clearDefaultAdminPassword(string(data))
	if next == string(data) {
		return restrictValuesFile(path)
	}
	if err := os.WriteFile(path, []byte(next), 0o600); err != nil {
		return err
	}
	return restrictValuesFile(path)
}

func restrictValuesFile(path string) error {
	if path == "" {
		return nil
	}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if info.IsDir() {
		return errors.Errorf("%s is a directory", path)
	}
	return os.Chmod(path, 0o600)
}

func clearDefaultAdminPassword(data string) string {
	lines := strings.Split(data, "\n")
	for i, line := range lines {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "#") || !strings.HasPrefix(trim, "adminPassword:") {
			continue
		}
		value := strings.TrimSpace(strings.TrimPrefix(trim, "adminPassword:"))
		if !knownDefaultSecret(value) {
			continue
		}
		indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
		lines[i] = indent + "adminPassword: ''"
	}
	return strings.Join(lines, "\n")
}

func addDexChecksum(data, sum string) string {
	if sum == "" || strings.Contains(data, "checksum/generated-passwords:") {
		return data
	}
	if !checksumIsHex(sum) {
		return data
	}
	lines := strings.Split(data, "\n")
	dexIdx := -1
	for i, line := range lines {
		if line == "dex:" {
			dexIdx = i
			break
		}
	}
	checksumLine := "    checksum/generated-passwords: '" + sum + "'"
	if dexIdx < 0 {
		if len(lines) > 0 && lines[len(lines)-1] == "" {
			lines = lines[:len(lines)-1]
		}
		lines = append(lines, "dex:", "  podAnnotations:", checksumLine, "")
		return strings.Join(lines, "\n")
	}
	podIdx := -1
	end := len(lines)
	for i := dexIdx + 1; i < len(lines); i++ {
		if lines[i] == "" {
			continue
		}
		if !strings.HasPrefix(lines[i], " ") && !strings.HasPrefix(lines[i], "\t") {
			end = i
			break
		}
		trim := strings.TrimSpace(lines[i])
		if trim == "podAnnotations:" || strings.HasPrefix(trim, "podAnnotations:") {
			podIdx = i
		}
	}
	if podIdx < 0 {
		extra := []string{"  podAnnotations:", checksumLine}
		lines = append(lines[:dexIdx+1], append(extra, lines[dexIdx+1:]...)...)
		return strings.Join(lines, "\n")
	}
	at := podIdx + 1
	if at > end {
		at = end
	}
	lines = append(lines[:at], append([]string{checksumLine}, lines[at:]...)...)
	return strings.Join(lines, "\n")
}

func checksumIsHex(sum string) bool {
	if len(sum) != 64 {
		return false
	}
	for _, r := range sum {
		switch {
		case r >= '0' && r <= '9', r >= 'a' && r <= 'f':
		default:
			return false
		}
	}
	return true
}

func (h HostServerUpgrader) kubeconfig() (string, error) {
	candidates := []string{}
	if h.Kubeconfig != "" {
		candidates = append(candidates, h.Kubeconfig)
	} else {
		if env := os.Getenv("KUBECONFIG"); env != "" {
			candidates = append(candidates, env)
		}
		candidates = append(candidates, hostKubeconfigPath)
	}
	var last error
	for _, path := range candidates {
		info, err := os.Stat(path)
		if err != nil {
			last = err
			continue
		}
		if info.IsDir() {
			last = errors.Errorf("%s is a directory", path)
			continue
		}
		return path, nil
	}
	return "", errors.Errorf("this machine cannot read the cluster kubeconfig (%v). The CLI does not install k3s, cert-manager, or Traefik, and it cannot upgrade a cluster it cannot read. On the server run: sudo ./scripts/update.sh <tag>", last)
}

func (h HostServerUpgrader) valuesPath() string {
	if h.ValuesFile != "" {
		return h.ValuesFile
	}
	if h.IgnoreHostValues {
		return ""
	}
	if _, err := os.Stat(hostValuesPath); err == nil {
		return hostValuesPath
	}
	return ""
}

func (h HostServerUpgrader) out() io.Writer {
	if h.Output != nil {
		return h.Output
	}
	return os.Stderr
}

func (h HostServerUpgrader) run(ctx context.Context, kubeconfig, name string, args ...string) error {
	if h.Runner != nil {
		return h.Runner(ctx, kubeconfig, name, args...)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig)
	cmd.Stdout = h.out()
	cmd.Stderr = h.out()
	return cmd.Run()
}

func (h HostServerUpgrader) importImage(ctx context.Context, tag string) error {
	if h.SkipImageImport {
		return nil
	}
	image := selfupdater.ServerImage(tag)
	if _, err := exec.LookPath("docker"); err != nil {
		fmt.Fprintf(h.out(), "docker is not installed; the cluster will pull %s\n", image)
		return nil
	}
	if _, err := exec.LookPath("k3s"); err != nil {
		fmt.Fprintf(h.out(), "k3s is not installed; the cluster will pull %s\n", image)
		return nil
	}
	fmt.Fprintf(h.out(), "pulling %s\n", image)
	if err := h.run(ctx, "", "docker", "pull", image); err != nil {
		return errors.Wrapf(err, "could not pull %s. Refusing to upgrade the server to an image that was not pulled", image)
	}
	save := exec.CommandContext(ctx, "docker", "save", image)
	imp := exec.CommandContext(ctx, "k3s", "ctr", "images", "import", "-")
	pipe, err := save.StdoutPipe()
	if err != nil {
		return errors.Wrap(err, "piping the server image into k3s")
	}
	imp.Stdin = pipe
	imp.Stdout = h.out()
	imp.Stderr = h.out()
	save.Stderr = h.out()
	if err := imp.Start(); err != nil {
		return errors.Wrap(err, "importing the server image into k3s")
	}
	if err := save.Start(); err != nil {
		return errors.Wrap(err, "saving the server image")
	}
	saveErr := save.Wait()
	impErr := imp.Wait()
	if saveErr != nil {
		return errors.Wrapf(saveErr, "saving %s", image)
	}
	if impErr != nil {
		return errors.Wrapf(impErr, "importing %s into k3s", image)
	}
	return nil
}

func downloadChart(tag string) (string, error) {
	chartURL := selfupdater.ChartURL(tag)
	req, err := http.NewRequest(http.MethodGet, chartURL, nil)
	if err != nil {
		return "", errors.Wrap(err, "building the chart download request")
	}
	req.Header.Set("User-Agent", "dflow")
	resp, err := selfupdater.DownloadClient.Do(req)
	if err != nil {
		return "", errors.Wrapf(err, "downloading %s", chartURL)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", errors.Errorf("downloading %s returned HTTP %d", chartURL, resp.StatusCode)
	}
	file, err := os.CreateTemp("", "dflow-chart-*.tgz")
	if err != nil {
		return "", errors.Wrap(err, "creating a chart file")
	}
	if _, err := io.Copy(file, resp.Body); err != nil {
		file.Close()
		os.Remove(file.Name())
		return "", errors.Wrap(err, "saving the chart")
	}
	if err := file.Close(); err != nil {
		os.Remove(file.Name())
		return "", err
	}
	return file.Name(), nil
}
