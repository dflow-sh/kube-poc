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

package services

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/engine"
)

func TestGetdFlowValuesRoundTrip(t *testing.T) {
	got, err := getdFlowValues("db", "postgresql-dev")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got, "{}") {
		t.Fatalf("dflow values marshaled as an empty mapping: %q", got)
	}

	vals, err := chartutil.ReadValues([]byte(got))
	if err != nil {
		t.Fatal(err)
	}
	dflow, ok := vals["dflow"].(map[string]interface{})
	if !ok {
		t.Fatalf("dflow values = %#v", vals["dflow"])
	}
	if dflow["serviceName"] != "db" {
		t.Fatalf("serviceName = %#v", dflow["serviceName"])
	}
	if dflow["catalogServiceName"] != "postgresql-dev" {
		t.Fatalf("catalogServiceName = %#v", dflow["catalogServiceName"])
	}

	// A normal values mapping must still parse after DeployOrUpdate appends
	// the dflow document. An empty `{}` in that position does not.
	combined := "image:\n  registry: docker.io\n" + got
	if _, err := chartutil.ReadValues([]byte(combined)); err != nil {
		t.Fatal(err)
	}
}

// TestShippedCatalogValuesParse renders every catalog service shipped in the
// Helm chart and parses its values the same way DeployOrUpdate does.
func TestShippedCatalogValuesParse(t *testing.T) {
	chartDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(chartDir, "Chart.yaml"), []byte("apiVersion: v2\nname: dflow\nversion: 0.0.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	templateRoot := filepath.Join("..", "..", "helm-chart", "templates")
	sources := []string{filepath.Join(templateRoot, "_helpers.tpl")}
	catalogDir := filepath.Join(templateRoot, "service-catalog")
	entries, err := os.ReadDir(catalogDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".yaml") {
			continue
		}
		sources = append(sources, filepath.Join(catalogDir, entry.Name()))
	}
	if len(sources) != 6 {
		t.Fatalf("expected the helper plus five catalog services, got %d files", len(sources))
	}

	for _, src := range sources {
		body, err := os.ReadFile(src)
		if err != nil {
			t.Fatal(err)
		}
		rel := strings.TrimPrefix(src, templateRoot+string(filepath.Separator))
		dst := filepath.Join(chartDir, "templates", rel)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(dst, body, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	chrt, err := loader.Load(chartDir)
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]interface{}{
		"serviceCatalog": map[string]interface{}{
			"enableDevServices": true,
		},
		"image": map[string]interface{}{
			"kubectl": map[string]interface{}{
				"repository": "rancher/kubectl",
				"tag":        "v1.22.6",
			},
		},
		"global": map[string]interface{}{
			"cattle": map[string]interface{}{
				"systemDefaultRegistry": "",
			},
		},
	}
	renderValues, err := chartutil.ToRenderValues(chrt, values, chartutil.ReleaseOptions{
		Name:      "dflow",
		Namespace: "dflow",
		IsInstall: true,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := engine.Render(chrt, renderValues)
	if err != nil {
		t.Fatal(err)
	}

	parsed := 0
	for name, manifest := range rendered {
		if !strings.Contains(name, "service-catalog/") {
			continue
		}
		serviceName, valuesYAML, err := catalogServiceValues(manifest)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if serviceName == "" || valuesYAML == "" {
			t.Fatalf("%s: empty catalog service values", name)
		}
		extra, err := getdFlowValues("db", serviceName)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := chartutil.ReadValues([]byte(valuesYAML)); err != nil {
			t.Fatalf("%s values: %v", serviceName, err)
		}
		combined, err := chartutil.ReadValues([]byte(valuesYAML + extra))
		if err != nil {
			t.Fatalf("%s values plus dflow suffix: %v", serviceName, err)
		}
		dflow, ok := combined["dflow"].(map[string]interface{})
		if !ok || dflow["catalogServiceName"] != serviceName {
			t.Fatalf("%s dflow suffix = %#v", serviceName, combined["dflow"])
		}
		parsed++
	}
	if parsed != 5 {
		t.Fatalf("parsed %d catalog services, want 5", parsed)
	}
}

func catalogServiceValues(manifest string) (string, string, error) {
	vals, err := chartutil.ReadValues([]byte(manifest))
	if err != nil {
		return "", "", err
	}
	spec, ok := vals["spec"].(map[string]interface{})
	if !ok {
		return "", "", fmt.Errorf("spec is %T", vals["spec"])
	}
	name, _ := spec["name"].(string)
	values, _ := spec["values"].(string)
	return name, values, nil
}
