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

package models_test

import (
	"github.com/dflow-sh/kube-poc/packages/dflow/helpers"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"gopkg.in/yaml.v2"
)

var _ = Describe("ApplicationOrigin String()", func() {
	It("correctly reports a bogus origin kind", func() {
		o := &models.ApplicationOrigin{
			Kind: 22,
		}
		s := o.String()
		Expect(s).To(Equal("<<undefined>>"))
	})

	It("correctly stringifies path origin", func() {
		o := &models.ApplicationOrigin{
			Kind: models.OriginPath,
			Path: "/foo",
		}
		s := o.String()
		Expect(s).To(Equal(helpers.AbsPath("/foo")))
	})

	It("correctly stringifies archive path origin", func() {
		o := &models.ApplicationOrigin{
			Kind:    models.OriginPath,
			Archive: true,
			Path:    "/foo",
		}
		s := o.String()
		Expect(s).To(Equal(helpers.AbsPath("/foo") + " (archive)"))
	})

	It("correctly stringifies a container origin", func() {
		o := &models.ApplicationOrigin{
			Kind:      models.OriginContainer,
			Container: "snafu",
		}
		s := o.String()
		Expect(s).To(Equal("snafu"))
	})

	// git: 4 cases :: +/- revision, +/- branch, url is mandatory
	It("correctly stringifies a git origin, url only", func() {
		o := &models.ApplicationOrigin{
			Kind: models.OriginGit,
			Git: &models.GitRef{
				URL: "somewhere",
			},
		}
		s := o.String()
		Expect(s).To(Equal("somewhere"))
	})

	It("correctly stringifies a git origin, url + revision", func() {
		o := &models.ApplicationOrigin{
			Kind: models.OriginGit,
			Git: &models.GitRef{
				URL:      "somewhere",
				Revision: "efi258945kda",
			},
		}
		s := o.String()
		Expect(s).To(Equal("somewhere @ efi258945kda"))
	})

	It("correctly stringifies a git origin, url + branch", func() {
		o := &models.ApplicationOrigin{
			Kind: models.OriginGit,
			Git: &models.GitRef{
				URL:    "somewhere",
				Branch: "subtotal",
			},
		}
		s := o.String()
		Expect(s).To(Equal("somewhere on subtotal"))
	})

	It("correctly stringifies a git origin, url + revision and branch", func() {
		o := &models.ApplicationOrigin{
			Kind: models.OriginGit,
			Git: &models.GitRef{
				URL:      "somewhere",
				Revision: "efi258945kda",
				Branch:   "subtotal",
			},
		}
		s := o.String()
		Expect(s).To(Equal("somewhere @ efi258945kda (on subtotal)"))
	})

	Describe("NewApplicationUpdateRequest", func() {
		It("copies ReplaceEnv when set", func() {
			replace := true
			m := models.ApplicationManifest{
				Configuration: models.ApplicationConfiguration{
					ReplaceEnv: &replace,
				},
			}

			update := models.NewApplicationUpdateRequest(m)
			Expect(update.ReplaceEnv).ToNot(BeNil())
			Expect(*update.ReplaceEnv).To(BeTrue())
		})

		It("keeps ReplaceEnv nil when unset", func() {
			m := models.ApplicationManifest{}

			update := models.NewApplicationUpdateRequest(m)
			Expect(update.ReplaceEnv).To(BeNil())
		})
	})
})

var _ = Describe("ApplicationManifest YAML", func() {
	It("exports bound configurations with their types", func() {
		m := models.ApplicationManifest{
			Name: "myapp",
			Configuration: models.ApplicationConfiguration{
				Configurations: []string{"mycfg", "mysvc-cfg"},
				BoundConfigurations: []models.BoundConfiguration{
					{Name: "mycfg", Type: "custom"},
					{Name: "mysvc-cfg", Type: "service"},
				},
			},
		}

		out, err := yaml.Marshal(m)
		Expect(err).ToNot(HaveOccurred())
		Expect(string(out)).To(Equal(`name: myapp
configuration:
  configurations:
  - mycfg
  - mysvc-cfg
  bound_configurations:
  - name: mycfg
    type: custom
  - name: mysvc-cfg
    type: service
`))
	})

	It("omits bound configurations when there are none", func() {
		m := models.ApplicationManifest{
			Name: "myapp",
			Configuration: models.ApplicationConfiguration{
				BoundConfigurations: []models.BoundConfiguration{},
			},
		}

		out, err := yaml.Marshal(m)
		Expect(err).ToNot(HaveOccurred())
		Expect(string(out)).ToNot(ContainSubstring("bound_configurations"))
	})

	It("reads bound configurations back without feeding them to push", func() {
		// The field round-trips so a re-read manifest is not lossy, but push binds
		// from `configurations` only -- see NewApplicationUpdateRequest.
		var m models.ApplicationManifest
		err := yaml.Unmarshal([]byte(`name: myapp
configuration:
  configurations:
  - mycfg
  bound_configurations:
  - name: mycfg
    type: custom
`), &m)
		Expect(err).ToNot(HaveOccurred())
		Expect(m.Configuration.BoundConfigurations).To(HaveLen(1))
		Expect(m.Configuration.BoundConfigurations[0].Name).To(Equal("mycfg"))
		Expect(m.Configuration.BoundConfigurations[0].Type).To(Equal("custom"))

		update := models.NewApplicationUpdateRequest(m)
		Expect(update.Configurations).To(Equal([]string{"mycfg"}))
	})
})

var _ = Describe("ResolveDefaultBuilderImage", func() {
	It("defaults an empty configuration to railpack", func() {
		Expect(models.ResolveDefaultBuilderImage("", "")).To(Equal(models.DefaultBuilderImage))
		Expect(models.ResolveDefaultBuilderImage("  ", "  ")).To(Equal("railpack"))
	})

	It("uses a configured builder when no custom resource is the default", func() {
		Expect(models.ResolveDefaultBuilderImage("", "paketobuildpacks/builder-jammy-full:0.3.495")).To(
			Equal("paketobuildpacks/builder-jammy-full:0.3.495"),
		)
	})

	It("lets the default custom resource win over the configured value", func() {
		Expect(models.ResolveDefaultBuilderImage("custom/builder:1", "railpack")).To(Equal("custom/builder:1"))
	})
})

var _ = Describe("ValidateBuildMode", func() {
	It("defaults empty to railpack", func() {
		mode, err := models.ValidateBuildMode("")
		Expect(err).ToNot(HaveOccurred())
		Expect(mode).To(Equal(models.BuildModeRailpack))
	})

	It("rejects a non-railpack DEFAULT_BUILD_MODE", func() {
		t := GinkgoT()
		t.Setenv("DEFAULT_BUILD_MODE", "buildpack")
		mode, err := models.ValidateBuildMode("")
		Expect(err).To(HaveOccurred())
		Expect(mode).To(Equal(""))
		Expect(err.Error()).To(ContainSubstring("DEFAULT_BUILD_MODE"))
		Expect(err.Error()).To(ContainSubstring("railpack"))
	})

	It("accepts railpack case-insensitively", func() {
		mode, err := models.ValidateBuildMode("RailPack")
		Expect(err).ToNot(HaveOccurred())
		Expect(mode).To(Equal(models.BuildModeRailpack))
	})

	It("rejects any builder other than railpack", func() {
		for _, mode := range []string{"buildpack", "BuildPack", "dockerfile", "DockerFile", "kaniko", "dockerfle"} {
			got, err := models.ValidateBuildMode(mode)
			Expect(err).To(HaveOccurred(), mode)
			Expect(got).To(Equal(""))
			Expect(err.Error()).To(ContainSubstring("only"))
			Expect(err.Error()).To(ContainSubstring("railpack"))
			Expect(models.NormalizeBuildMode(mode)).ToNot(Equal(models.BuildModeRailpack))
		}
	})
})

var _ = Describe("ValidateBuilderImage", func() {
	It("allows an empty builder and railpack", func() {
		Expect(models.ValidateBuilderImage("")).ToNot(HaveOccurred())
		Expect(models.ValidateBuilderImage("  railpack  ")).ToNot(HaveOccurred())
	})

	It("rejects any other builder", func() {
		err := models.ValidateBuilderImage("paketobuildpacks/builder-jammy-full:0.3.495")
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("only"))
		Expect(err.Error()).To(ContainSubstring("railpack"))
	})
})

var _ = Describe("ValidateDockerfilePath", func() {
	It("defaults empty to Dockerfile", func() {
		path, err := models.ValidateDockerfilePath("")
		Expect(err).ToNot(HaveOccurred())
		Expect(path).To(Equal("Dockerfile"))
	})

	It("accepts relative paths within app sources", func() {
		path, err := models.ValidateDockerfilePath("Dockerfile")
		Expect(err).ToNot(HaveOccurred())
		Expect(path).To(Equal("Dockerfile"))

		path, err = models.ValidateDockerfilePath("docker/Dockerfile")
		Expect(err).ToNot(HaveOccurred())
		Expect(path).To(Equal("docker/Dockerfile"))
	})

	It("rejects absolute paths and parent directory traversal", func() {
		_, err := models.ValidateDockerfilePath("/etc/passwd")
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("absolute"))

		_, err = models.ValidateDockerfilePath("../Dockerfile")
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring(".."))

		_, err = models.ValidateDockerfilePath("foo/../../bar")
		Expect(err).To(HaveOccurred())
	})

	It("rejects unexpected characters", func() {
		_, err := models.ValidateDockerfilePath("my Dockerfile")
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("only letters"))

		_, err = models.ValidateDockerfilePath("foo*.Dockerfile")
		Expect(err).To(HaveOccurred())
	})
})
