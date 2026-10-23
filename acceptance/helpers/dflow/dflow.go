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

package dflow

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/dflow-sh/kube-poc/acceptance/helpers/proc"
	"github.com/dflow-sh/kube-poc/acceptance/testenv"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type DFlow struct {
	DFlowBinaryPath string
}

func localChartPath() string {
	// Prefer the workspace root chart when present, fallback to the bundled submodule path.
	candidates := []string{
		"../helm-charts/chart/dflow",
		"helm-charts/chart/dflow",
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(filepath.Join(testenv.Root(), candidate)); err == nil {
			return candidate
		}
	}
	return "helm-charts/chart/dflow"
}

func NewdFlowHelper(dflowBinaryPath string) DFlow {
	return DFlow{
		DFlowBinaryPath: dflowBinaryPath,
	}
}

func (e *DFlow) Run(cmd string, args ...string) (string, error) {
	out, err := proc.RunW(e.DFlowBinaryPath, append([]string{cmd}, args...)...)
	if err != nil {
		return out, err
	}
	return out, nil
}

func (e *DFlow) Upgrade() {
	// Redundant, done by prepare_environment_k3d in flow setup (upgrade.yml)
	// Build image with latest dflow-server binary
	By("Upgrading ...")

	By("Rebuilding client side")
	testenv.BuilddFlow()

	// NOTE: Client has to be rebuild first. Because its result is also what goes into the
	// server image to be assembled in the coming step below. Not doing so causes the new server
	// image to contain the old binary.

	tag := os.Getenv("DFLOW_CURRENT_TAG")
	By("Tag: " + tag)

	By("Building server image ...")
	serverTag := fmt.Sprintf("ghcr.io/dflow-sh/dflow-server:%s", tag)
	out, err := proc.Run("../..", false, "docker", "build", "-t", serverTag, "-f", "images/Dockerfile", ".")
	Expect(err).NotTo(HaveOccurred(), out)
	By(out)

	By("Building unpacker image ...")
	unpackerTag := fmt.Sprintf("ghcr.io/dflow-sh/dflow-unpacker:%s", tag)
	out, err = proc.Run("../..", false, "docker", "build", "-t", unpackerTag, "-f", "images/unpacker-Dockerfile", ".")
	Expect(err).NotTo(HaveOccurred(), out)
	By(out)

	By("Image: " + serverTag)
	By("Image: " + unpackerTag)

	if os.Getenv("PUBLIC_CLOUD") == "" {
		// Local k3ds/k3d-based cluster. Talk directly to it. Import the new images into k3d
		By("Importing server image ...")
		out, err = proc.RunW("k3d", "image", "import", "-c", "dflow-acceptance", serverTag)
		Expect(err).NotTo(HaveOccurred(), out)
		By(out)

		By("Importing unpacker image ...")
		out, err = proc.RunW("k3d", "image", "import", "-c", "dflow-acceptance", unpackerTag)
		Expect(err).NotTo(HaveOccurred(), out)
		By(out)
	} else {
		By("Pushing server image to GHCR ...")
		// PUBLIC_CLOUD is present
		// Pushing new images into ghcr for the public cluster to pull from
		out, err = proc.RunW("docker", "push", serverTag)
		Expect(err).NotTo(HaveOccurred(), out)
		By(out)

		out, err = proc.RunW("docker", "push", unpackerTag)
		Expect(err).NotTo(HaveOccurred(), out)
		By(out)
	}

	// If the chart has new defaults Helm will not get these values when using --set and --reuse-values
	// To get the new defaults, the previous values and the --set we need to fetch the values and pass them.
	// See: https://shipmight.com/blog/understanding-helm-upgrade-reset-reuse-values
	// also: https://github.com/helm/helm/issues/8085

	By("Get old Helm values")
	prevValuesFile := filepath.Join(testenv.Root(), "prev-values.yaml")
	chart := localChartPath()

	out, err = proc.Run(testenv.Root(), false, "helm", "get", "values", "dflow", "-n", "dflow", "-o", "yaml")
	Expect(err).NotTo(HaveOccurred(), out)
	By("Old values = ((" + out + "))")
	err = os.WriteFile(prevValuesFile, []byte(out), 0600)
	Expect(err).NotTo(HaveOccurred(), out)

	By("Upgrading server side")
	out, err = proc.Run(testenv.Root(), false, "helm", "upgrade", "dflow",
		"-n", "dflow",
		chart,
		"--values", prevValuesFile,
		"--set", "image.dflow.registry=ghcr.io/",
		"--set", fmt.Sprintf("image.dflow.tag=%s", tag),
		"--set", fmt.Sprintf("image.bash.tag=%s", tag),
		"--wait",
	)
	Expect(err).NotTo(HaveOccurred(), out)

	By("... Upgrade complete")
}

func (e *DFlow) Install(args ...string) (string, error) {

	// Default is install from local chart
	chart := localChartPath()

	// If requested by the environment, switch to latest release instead, which is older
	released := os.Getenv("DFLOW_RELEASED")
	isreleased := released == "true"
	upgraded := os.Getenv("DFLOW_UPGRADED")
	isupgraded := upgraded == "true"

	if isupgraded || isreleased {
		out, err := proc.RunW("helm", "repo", "add", "dflow", "https://dflow.github.io/helm-charts")
		if err != nil {
			return out, err
		}
		chart = "dflow/dflow"
	}

	// Update helm repos -- Assumes existence of helm repository providing the helm charts
	out, err := proc.RunW("helm", "repo", "update")
	if err != nil {
		return out, err
	}

	opts := []string{
		"upgrade",
		"--install",
		"-n",
		"dflow",
		"--create-namespace",
		"dflow",
		chart,
		"--wait",
	}

	// The released chart still ships the upgrade-responder client, so tracking
	// stays off here until a release without it is published.
	if isupgraded || isreleased {
		opts = append(opts, "--set", "server.disableTracking=true")
	}

	out, err = proc.Run(testenv.Root(), false, "helm", append(opts, args...)...)
	if err != nil {
		return out, err
	}
	return out, nil
}

func (e *DFlow) Uninstall() (string, error) {
	out, err := proc.RunW("helm", "uninstall", "-n", "dflow", "dflow")
	if err != nil {
		return out, err
	}
	return out, nil
}
