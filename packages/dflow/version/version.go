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

// Package version contains the product version string.
package version

import "strings"

// Version is the product version. Unreleased builds keep this value.
// A release tag replaces it at link time (-X, see .goreleaser.yaml).
var Version = "v0.0.0-dev"

// ChartVersion is the Helm chart version the server reports.
// The chart sets CHART_VERSION from its own version, which a release tag
// rewrites. Unreleased builds match Version.
var ChartVersion = "v0.0.0-dev"

// ChartVersionFromEnv returns Version when the chart did not set
// CHART_VERSION. A chart version without a leading v gets one, so 0.0.4
// from a release tag matches the stamped Version v0.0.4.
func ChartVersionFromEnv(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return Version
	}
	if !strings.HasPrefix(raw, "v") {
		return "v" + raw
	}
	return raw
}
