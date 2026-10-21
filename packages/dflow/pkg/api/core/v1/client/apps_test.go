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

package client_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"

	"github.com/dflow-sh/kube-poc/packages/dflow/cli/settings"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/client"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Client Apps", func() {
	Describe("AppRestart", DescribeAppRestart)
	Describe("Apps Errors", DescribeAppsErrors)
})

func DescribeAppsErrors() {

	var dflowClient *client.Client
	var statusCode int
	var responseBody string

	JustBeforeEach(func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(statusCode)
			fmt.Fprint(w, responseBody)
		}))

		dflowClient = client.New(context.Background(), &settings.Settings{
			API:      srv.URL,
			Location: "fake",
		})
	})

	When("a 500 status code and a JSON error was returned", func() {

		BeforeEach(func() {
			statusCode = 500
			responseBody = `{
					"errors": [
						{
							"status": 500,
							"title": "Error title",
							"details": "something bad happened"
						}
					]
				}`
		})

		DescribeTable("the APIs are returning an error",
			func(call func() (any, error)) {
				_, err := call()
				Expect(err).To(HaveOccurred())
			},
			Entry("app create", func() (any, error) {
				return dflowClient.AppCreate(models.ApplicationCreateRequest{}, "namespace")
			}),
			Entry("app get part", func() (any, error) {
				return dflowClient.AppGetPart("namespace", "appname", "values")
			}),
			Entry("apps", func() (any, error) {
				return dflowClient.Apps("namespace")
			}),
			Entry("all apps", func() (any, error) {
				return dflowClient.AllApps()
			}),
			Entry("app show", func() (any, error) {
				return dflowClient.AppShow("namespace", "appname")
			}),
			Entry("app update", func() (any, error) {
				return dflowClient.AppUpdate(models.ApplicationUpdateRequest{}, "namespace", "appname")
			}),
			Entry("app delete", func() (any, error) {
				return dflowClient.AppDelete("namespace", []string{"appname"}, false, false)
			}),
			Entry("app upload", func() (any, error) {
				return dflowClient.AppUpload("namespace", "appname", nil)
			}),
			Entry("app import git", func() (any, error) {
				return dflowClient.AppImportGit("namespace", "appname", models.GitRef{})
			}),
			Entry("app match", func() (any, error) {
				return dflowClient.AppMatch("namespace", "appprefix")
			}),
			Entry("app validate CV", func() (any, error) {
				return dflowClient.AppValidateCV("namespace", "appname")
			}),
			Entry("app stage", func() (any, error) {
				return dflowClient.AppStage(models.StageRequest{})
			}),
			Entry("app deploy", func() (any, error) {
				return dflowClient.AppDeploy(models.DeployRequest{})
			}),
			Entry("app staging complete", func() (any, error) {
				return dflowClient.StagingComplete("namespace", "stageID")
			}),
			Entry("app running", func() (any, error) {
				return dflowClient.AppRunning(models.AppRef{})
			}),
			Entry("authtoken", func() (any, error) {
				return dflowClient.AuthToken()
			}),
		)
	})

	When("the app part return something", func() {

		BeforeEach(func() {
			statusCode = 200
			responseBody = `randomdatabytes`
		})

		It("get the response", func() {
			response, err := dflowClient.AppGetPart("namespace", "appname", "part")
			Expect(err).ToNot(HaveOccurred())
			Expect(response).ToNot(BeNil())

			b, err := io.ReadAll(response.Data)
			Expect(err).ToNot(HaveOccurred())
			Expect(b).To(Equal([]byte("randomdatabytes")))
			Expect(response.ContentLength).To(BeEquivalentTo(len("randomdatabytes")))
		})
	})
}
