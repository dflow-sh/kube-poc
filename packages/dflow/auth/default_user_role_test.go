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

package auth_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	v1 "github.com/dflow-sh/kube-poc/packages/dflow/api/v1"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/middleware"
	"github.com/dflow-sh/kube-poc/packages/dflow/auth"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	"github.com/gin-gonic/gin"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("default user role", func() {
	var (
		actionIDs []string
		userRole  auth.Role
		user      auth.User
		admin     auth.User
	)

	BeforeEach(func() {
		gin.SetMode(gin.TestMode)

		actionIDs = defaultUserRoleActions()
		Expect(actionIDs).To(ContainElement("builderimage_read"))
		Expect(actionIDs).NotTo(ContainElement("builderimage_write"))
		Expect(userRoleChart()).NotTo(ContainSubstring("builderimage_write"))
		Expect(userRoleChart()).To(ContainSubstring(`include "dflow.defaultUserRoleActions"`))
		Expect(serverChart()).To(ContainSubstring("checksum/dflow-user-role"))

		err := v1.InitAuth()
		Expect(err).NotTo(HaveOccurred())
		Expect(auth.ActionsMap).To(HaveKey("builderimage_write"))

		userRole, err = auth.NewRole("user", "dFlow User Role", "true", actionIDs)
		Expect(err).NotTo(HaveOccurred())

		user = auth.User{Username: "ada", Roles: auth.Roles{userRole}}
		admin = auth.User{Username: "admin", Roles: auth.Roles{{ID: "admin"}}}
	})

	Describe("builder image routes", func() {
		It("lets the user role read builder images", func() {
			Expect(user.IsAllowed(http.MethodGet, "/api/v1/builderimages", nil)).To(BeTrue())
			Expect(user.IsAllowed(http.MethodGet, "/api/v1/builderimages/:name", nil)).To(BeTrue())
		})

		It("refuses builder image create, update, and delete for the user role", func() {
			Expect(user.IsAllowed(http.MethodPost, "/api/v1/builderimages", nil)).To(BeFalse())
			Expect(user.IsAllowed(http.MethodPatch, "/api/v1/builderimages/:name", nil)).To(BeFalse())
			Expect(user.IsAllowed(http.MethodDelete, "/api/v1/builderimages/:name", nil)).To(BeFalse())
		})

		It("still allows an admin to create, update, and delete builder images", func() {
			Expect(admin.IsAllowed(http.MethodPost, "/api/v1/builderimages", nil)).To(BeTrue())
			Expect(admin.IsAllowed(http.MethodPatch, "/api/v1/builderimages/:name", nil)).To(BeTrue())
			Expect(admin.IsAllowed(http.MethodDelete, "/api/v1/builderimages/:name", nil)).To(BeTrue())
		})

		DescribeTable("returns 403 for a user-role account and 200 for an admin",
			func(method, route, url string) {
				userResponse := callWithRole(method, route, url, user)
				Expect(userResponse.Code).To(Equal(http.StatusForbidden))

				adminResponse := callWithRole(method, route, url, admin)
				Expect(adminResponse.Code).To(Equal(http.StatusOK))
			},
			Entry("create", http.MethodPost, "/api/v1/builderimages", "/api/v1/builderimages"),
			Entry("update", http.MethodPatch, "/api/v1/builderimages/:name", "/api/v1/builderimages/standard"),
			Entry("delete", http.MethodDelete, "/api/v1/builderimages/:name", "/api/v1/builderimages/standard"),
		)
	})
})

func chartPath(parts ...string) string {
	_, thisFile, _, ok := runtime.Caller(0)
	Expect(ok).To(BeTrue())
	root := filepath.Join(filepath.Dir(thisFile), "..", "..", "helm-chart")
	return filepath.Join(append([]string{root}, parts...)...)
}

func readChart(parts ...string) string {
	contents, err := os.ReadFile(chartPath(parts...))
	Expect(err).NotTo(HaveOccurred())
	return string(contents)
}

func userRoleChart() string {
	contents := readChart("templates", "default-user.yaml")
	start := strings.Index(contents, `name: "dflow-user-role"`)
	Expect(start).To(BeNumerically(">", 0))
	rest := contents[start:]
	end := strings.Index(rest, "\n---")
	Expect(end).To(BeNumerically(">", 0))
	return rest[:end]
}

func serverChart() string {
	return readChart("templates", "server.yaml")
}

func defaultUserRoleActions() []string {
	contents := readChart("templates", "_helpers.tpl")
	const marker = `define "dflow.defaultUserRoleActions"`
	start := strings.Index(contents, marker)
	Expect(start).To(BeNumerically(">", 0))
	rest := contents[start+len(marker):]
	end := strings.Index(rest, "{{- end }}")
	Expect(end).To(BeNumerically(">", 0))

	actions := []string{}
	for _, line := range strings.Split(rest[:end], "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.Contains(trimmed, "{{") || strings.Contains(trimmed, "}}") {
			continue
		}
		actions = append(actions, trimmed)
	}
	Expect(actions).NotTo(BeEmpty())
	return actions
}

func callWithRole(method, route, url string, user auth.User) *httptest.ResponseRecorder {
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Request = c.Request.WithContext(requestctx.WithUser(c.Request.Context(), user))
	})
	router.Handle(method, route, middleware.RoleAuthorization, func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	response := httptest.NewRecorder()
	request := httptest.NewRequest(method, url, nil)
	router.ServeHTTP(response, request)
	return response
}
