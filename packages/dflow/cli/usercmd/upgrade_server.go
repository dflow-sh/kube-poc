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
}

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
	chartURL := selfupdater.ChartURL(tag)
	image := selfupdater.ServerImage(tag)
	if dryRun {
		fmt.Fprintf(h.out(), "server image %s\nchart %s\nhelm %s\n", image, chartURL, strings.Join(HelmUpgradeArgs("<chart>", values, tag), " "))
		if kubeErr != nil {
			fmt.Fprintf(h.out(), "server upgrade would stop: %s\n", kubeErr.Error())
		}
		return nil
	}
	if kubeErr != nil {
		return kubeErr
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
	if err := h.run(context.Background(), kube, "kubectl", "-n", "dflow", "get", "deploy", "dex"); err == nil {
		if err := h.run(context.Background(), kube, "kubectl", "-n", "dflow", "rollout", "status", "deploy/dex", "--timeout=10m"); err != nil {
			return errors.Wrap(err, "dex did not become ready")
		}
	}
	if err := h.run(context.Background(), kube, "kubectl", "-n", "dflow", "get", "certificate", "dflow"); err == nil {
		if err := h.run(context.Background(), kube, "kubectl", "-n", "dflow", "wait", "--for=condition=Ready", "certificate/dflow", "--timeout=10m"); err != nil {
			return errors.Wrap(err, "certificate/dflow did not become Ready")
		}
	}
	return nil
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
