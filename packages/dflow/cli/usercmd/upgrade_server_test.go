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
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHelmUpgradeArgsUsesSavedValues(t *testing.T) {
	args := HelmUpgradeArgs("/tmp/dflow-0.0.4.tgz", "/var/lib/dflow/values.yaml", "v0.0.4")
	got := strings.Join(args, " ")
	want := "upgrade --install dflow /tmp/dflow-0.0.4.tgz --namespace dflow --create-namespace --values /var/lib/dflow/values.yaml --set image.dflow.tag=v0.0.4 --timeout 15m"
	if got != want {
		t.Fatalf("args = %q", got)
	}
}

func TestHelmUpgradeArgsReusesReleaseValues(t *testing.T) {
	args := HelmUpgradeArgs("/tmp/dflow-0.0.4.tgz", "", "v0.0.4")
	got := strings.Join(args, " ")
	if !strings.Contains(got, "--reuse-values") {
		t.Fatalf("args = %q", got)
	}
	if strings.Contains(got, "--values") {
		t.Fatalf("empty values file was passed: %s", got)
	}
}

func TestServerUpgradeDryRunDoesNotRunHelm(t *testing.T) {
	var calls []string
	var buf bytes.Buffer
	up := HostServerUpgrader{
		Kubeconfig:       filepath.Join(t.TempDir(), "missing"),
		IgnoreHostValues: true,
		SkipImageImport:  true,
		Output:           &buf,
		Runner: func(ctx context.Context, kubeconfig, name string, args ...string) error {
			calls = append(calls, name)
			return nil
		},
	}
	if err := up.Upgrade("v0.0.4", true); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 0 {
		t.Fatalf("dry-run ran %v", calls)
	}
	text := buf.String()
	if !strings.Contains(text, "ghcr.io/dflow-sh/dflow-server:v0.0.4") {
		t.Fatalf("dry-run output: %s", text)
	}
	if !strings.Contains(text, "https://github.com/dflow-sh/kube-poc/releases/download/v0.0.4/dflow-0.0.4.tgz") {
		t.Fatalf("dry-run output: %s", text)
	}
	if !strings.Contains(text, "scripts/update.sh") {
		t.Fatalf("missing server hint: %s", text)
	}
}

func TestServerUpgradeHelmCommand(t *testing.T) {
	kube := filepath.Join(t.TempDir(), "kubeconfig")
	if err := os.WriteFile(kube, []byte("apiVersion: v1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	values := filepath.Join(t.TempDir(), "values.yaml")
	if err := os.WriteFile(values, []byte("image:\n  dflow:\n    tag: v0.0.3\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	chart := filepath.Join(t.TempDir(), "dflow-0.0.4.tgz")
	if err := os.WriteFile(chart, []byte("chart"), 0o644); err != nil {
		t.Fatal(err)
	}
	var got []string
	up := HostServerUpgrader{
		Kubeconfig:      kube,
		ValuesFile:      values,
		ChartPath:       chart,
		SkipImageImport: true,
		Output:          ioDiscard(),
		Runner: func(ctx context.Context, kubeconfig, name string, args ...string) error {
			if kubeconfig != kube {
				t.Errorf("kubeconfig = %s", kubeconfig)
			}
			got = append(got, name+" "+strings.Join(args, " "))
			if name == "kubectl" && len(args) > 0 && args[0] == "-n" && len(args) >= 4 && args[3] == "dex" {
				return os.ErrNotExist
			}
			if name == "kubectl" && strings.Contains(strings.Join(args, " "), "certificate") {
				return os.ErrNotExist
			}
			return nil
		},
	}
	if err := up.Upgrade("v0.0.4", false); err != nil {
		t.Fatal(err)
	}
	if len(got) < 2 {
		t.Fatalf("commands = %#v", got)
	}
	if !strings.Contains(got[0], "helm upgrade --install dflow "+chart) {
		t.Fatalf("helm = %s", got[0])
	}
	if !strings.Contains(got[0], "--set image.dflow.tag=v0.0.4") {
		t.Fatalf("helm = %s", got[0])
	}
	if !strings.Contains(got[1], "rollout status deploy/dflow-server") {
		t.Fatalf("rollout = %s", got[1])
	}
}

func ioDiscard() *bytes.Buffer {
	return &bytes.Buffer{}
}
