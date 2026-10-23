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

package middleware_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"

	v1 "github.com/dflow-sh/kube-poc/packages/dflow/api/v1"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/middleware"
	"github.com/dflow-sh/kube-poc/packages/dflow/auth"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	"github.com/gin-gonic/gin"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Authorization Middleware", func() {
	var c *gin.Context
	var ctx context.Context
	var w *httptest.ResponseRecorder
	var url string

	BeforeEach(func() {
		gin.SetMode(gin.TestMode)
		w = httptest.NewRecorder()
		c, _ = gin.CreateTestContext(w)
		ctx = context.Background()
		url = "http://url.com/endpoint"

		err := v1.InitAuth()
		Expect(err).ToNot(HaveOccurred())
	})

	JustBeforeEach(func() {
		req, err := http.NewRequest(http.MethodGet, url, nil)
		Expect(err).ToNot(HaveOccurred())
		c.Request = req.Clone(ctx)
	})

	Context("user has Role 'user'", func() {

		BeforeEach(func() {
			userRole := auth.Role{
				ID: "user",
				// Namespace-scoped role to validate namespace restrictions.
				Namespace: "workspace",
				Actions: []auth.Action{
					auth.ActionsMap["namespace"],
				},
			}

			ctx = requestctx.WithUser(ctx, auth.User{
				Roles:      []auth.Role{userRole},
				Namespaces: []string{"workspace"},
			})
		})

		When("url is not restricted", func() {
			It("returns status code 200", func() {
				middleware.NamespaceAuthorization(c)
				Expect(w.Code).To(Equal(http.StatusOK))
			})
		})

		When("url is restricted", func() {
			BeforeEach(func() {
				v1.AdminRoutes = map[string]struct{}{
					"/restricted": {},
				}
				url = "http://url.com/restricted"
			})

			It("returns status code 403", func() {
				middleware.NamespaceAuthorization(c)
				Expect(w.Code).To(Equal(http.StatusForbidden))
			})
		})

		When("url is namespaced", func() {
			It("returns status code 403 for another namespace", func() {
				c.Params = []gin.Param{{Key: "namespace", Value: "another-workspace"}}

				middleware.NamespaceAuthorization(c)
				Expect(w.Code).To(Equal(http.StatusForbidden))
			})

			It("returns status code 200 for its namespace", func() {
				c.Params = []gin.Param{{Key: "namespace", Value: "workspace"}}

				middleware.NamespaceAuthorization(c)
				Expect(w.Code).To(Equal(http.StatusOK))
			})
		})
	})

	Describe("websocket namespace authorization", func() {
		var (
			owner auth.User
			admin auth.User
		)

		routes := []string{
			"/wapi/v1/namespaces/:namespace/applications/:app/logs",
			"/wapi/v1/namespaces/:namespace/applications/:app/exec",
			"/wapi/v1/namespaces/:namespace/applications/:app/portforward",
		}

		BeforeEach(func() {
			owner = auth.User{
				Username:   "ada",
				Namespaces: []string{"mine"},
				Roles:      auth.Roles{{ID: "user"}},
			}
			admin = auth.User{
				Username: "admin",
				Roles:    auth.Roles{{ID: "admin"}},
			}
		})

		DescribeTable("refuses a namespace the user does not own",
			func(route string) {
				Expect(websocketStatus(route, "other", owner)).To(Equal(http.StatusForbidden))
			},
			Entry("logs", routes[0]),
			Entry("exec", routes[1]),
			Entry("port-forward", routes[2]),
		)

		DescribeTable("allows the owner and an admin",
			func(route string) {
				Expect(websocketStatus(route, "mine", owner)).To(Equal(http.StatusOK))
				Expect(websocketStatus(route, "other", admin)).To(Equal(http.StatusOK))
			},
			Entry("logs", routes[0]),
			Entry("exec", routes[1]),
			Entry("port-forward", routes[2]),
		)

		It("does not intermittently refuse exec or port-forward for the owner", func() {
			for try := 0; try < 40; try++ {
				Expect(websocketStatus(routes[1], "mine", owner)).To(Equal(http.StatusOK))
				Expect(websocketStatus(routes[2], "mine", owner)).To(Equal(http.StatusOK))
			}
		})
	})
})

func websocketStatus(route, namespace string, user auth.User) int {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Request = c.Request.WithContext(requestctx.WithUser(c.Request.Context(), user))
	})
	router.GET(route, middleware.NamespaceAuthorization, func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	url := route
	url = strings.ReplaceAll(url, ":namespace", namespace)
	url = strings.ReplaceAll(url, ":app", "demo")

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, url, nil))
	return response.Code
}
