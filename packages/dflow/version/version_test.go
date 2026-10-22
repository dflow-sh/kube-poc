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

package version

import "testing"

func TestUnreleasedVersionMatchesChartVersion(t *testing.T) {
	if Version != "v0.0.0-dev" {
		t.Fatalf("Version = %q, want v0.0.0-dev", Version)
	}
	if ChartVersion != Version {
		t.Fatalf("ChartVersion = %q, want %q", ChartVersion, Version)
	}
}

func TestChartVersionFromEnv(t *testing.T) {
	if got := ChartVersionFromEnv(""); got != Version {
		t.Fatalf("empty env = %q, want %q", got, Version)
	}
	if got := ChartVersionFromEnv("  "); got != Version {
		t.Fatalf("blank env = %q, want %q", got, Version)
	}
	if got := ChartVersionFromEnv("0.0.0-dev"); got != "v0.0.0-dev" {
		t.Fatalf("chart version = %q", got)
	}
	if got := ChartVersionFromEnv("v0.0.4"); got != "v0.0.4" {
		t.Fatalf("tagged chart version = %q", got)
	}
}
